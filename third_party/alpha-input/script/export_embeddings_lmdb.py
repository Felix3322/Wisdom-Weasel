import os
import struct
import numpy as np
import torch
import lmdb
from transformers import AutoModel, AutoConfig
from tqdm import tqdm
import argparse


def quantize_int8(weights):
    """Quantize weights to int8 with a scaling factor."""
    abs_max = np.max(np.abs(weights), axis=1, keepdims=True)
    # Avoid division by zero
    abs_max[abs_max == 0] = 1.0
    scaled = weights / abs_max * 127
    quantized = scaled.astype(np.int8)
    return quantized, abs_max.astype(np.float32)


def quantize_int4(weights):
    """Quantize weights to int4 (packed into uint8) with a scaling factor."""
    abs_max = np.max(np.abs(weights), axis=1, keepdims=True)
    # Avoid division by zero
    abs_max[abs_max == 0] = 1.0
    # Scale to [-7, 7]
    scaled = np.clip(weights / abs_max * 7, -8, 7)
    quantized = scaled.astype(np.int8)

    # Pack to int4
    packed = np.empty((quantized.shape[0], (quantized.shape[1] + 1) // 2), dtype=np.uint8)
    for i in range(quantized.shape[0]):
        for j in range(0, quantized.shape[1], 2):
            # map from [-8, 7] to [0, 15]
            v1 = quantized[i, j] + 8
            if j + 1 < quantized.shape[1]:
                v2 = quantized[i, j + 1] + 8
            else:
                v2 = 8  # padding
            packed[i, j // 2] = (v1 << 4) | v2
    return packed, abs_max.astype(np.float32)


def export_embeddings_to_lmdb(model_id: str, db_dir: str, batch_size: int = 1000, quantize: str = None):
    """
    Export word embeddings to LMDB with token_id as key.

    Key: 4-byte little-endian unsigned int (token_id)
    Value: float32 array bytes, or quantized bytes with scaling factor.
    """
    print(f"Loading model from: {model_id}")

    # Load model
    config = AutoConfig.from_pretrained(model_id, trust_remote_code=True)
    model = AutoModel.from_pretrained(model_id, trust_remote_code=True)

    # Get input embedding layer
    emb = model.get_input_embeddings()
    vocab_size = emb.num_embeddings
    embedding_dim = emb.embedding_dim

    print(f"Vocab size: {vocab_size}, Embedding dim: {embedding_dim}")
    if quantize:
        print(f"Quantizing to {quantize}")

    # Prepare LMDB directory
    os.makedirs(db_dir, exist_ok=True)

    # Estimate required LMDB map size and add headroom
    value_size = embedding_dim * 4  # float32
    if quantize == 'int8':
        value_size = embedding_dim + 4  # int8 + float32 scale
    elif quantize == 'int4':
        value_size = (embedding_dim + 1) // 2 + 4  # packed int4 + float32 scale

    estimated = vocab_size * value_size + vocab_size * 32 + 64 * 1024 * 1024
    map_size = int(estimated * 1.5)

    print(f"Opening LMDB at: {db_dir}, map_size ~= {map_size / (1024**3):.2f} GB")

    env = lmdb.open(
        db_dir,
        map_size=map_size,
        max_dbs=1,
        subdir=True,
        lock=True,
        readahead=False,
        writemap=False,
        metasync=True,
        sync=True,
    )

    current_map_size = map_size

    # Store metadata
    with env.begin(write=True) as txn:
        meta = struct.pack('<II', vocab_size, embedding_dim)
        txn.put(b"__meta__", meta)
        if quantize:
            txn.put(b"__quantize__", quantize.encode('utf-8'))
        elif txn.get(b"__quantize__"):
            txn.delete(b"__quantize__")

    print("Exporting embeddings to LMDB...")
    with torch.no_grad():
        for start in tqdm(range(0, vocab_size, batch_size)):
            end = min(start + batch_size, vocab_size)
            weights = (
                emb.weight[start:end]
                .detach()
                .float()
                .cpu()
                .numpy()
                .astype(np.float32)
            )

            if quantize == 'int8':
                quantized_weights, scales = quantize_int8(weights)
            elif quantize == 'int4':
                quantized_weights, scales = quantize_int4(weights)

            while True:
                try:
                    with env.begin(write=True) as txn:
                        for i, token_id in enumerate(range(start, end)):
                            key = struct.pack('<I', token_id)
                            if quantize:
                                value = quantized_weights[i].tobytes() + scales[i].tobytes()
                            else:
                                value = weights[i].tobytes()
                            txn.put(key, value)
                    break
                except lmdb.MapFullError:
                    new_size = int(current_map_size * 2)
                    print(
                        f"LMDB map full while writing [{start}, {end}), growing map to {new_size / (1024**3):.2f} GB"
                    )
                    env.set_mapsize(new_size)
                    current_map_size = new_size

    env.sync()
    env.close()

    print("Done.")
    print(f"DB directory: {db_dir}")
    print(f"Entries: {vocab_size}")
    if quantize:
        print(f"Quantization: {quantize}")


def read_embedding_example(db_dir: str, token_id: int):
    """
    Example: read a single embedding back from LMDB.
    """
    env = lmdb.open(db_dir, readonly=True, lock=False, readahead=False)
    with env.begin() as txn:
        meta = txn.get(b"__meta__")
        quantize_type = txn.get(b"__quantize__")
        if quantize_type:
            quantize_type = quantize_type.decode('utf-8')

        if meta:
            vocab_size, embedding_dim = struct.unpack('<II', meta)
            print(f"Meta -> vocab: {vocab_size}, dim: {embedding_dim}, quantize: {quantize_type}")

        val = txn.get(struct.pack('<I', token_id))
        if val is None:
            print(f"Token {token_id} not found")
            return None

        if quantize_type == 'int8':
            quantized_arr = np.frombuffer(val[:-4], dtype=np.int8)
            scale = np.frombuffer(val[-4:], dtype=np.float32)[0]
            arr = (quantized_arr.astype(np.float32) / 127.0) * scale
            print(f"Token {token_id} (int8 quantized) embedding shape: {arr.shape}")
            print(f"Original quantized array: {quantized_arr[:10]}..., scale: {scale}")
        elif quantize_type == 'int4':
            packed_arr = np.frombuffer(val[:-4], dtype=np.uint8)
            scale = np.frombuffer(val[-4:], dtype=np.float32)[0]

            # Unpack
            unpacked = np.empty(embedding_dim, dtype=np.int8)
            for i in range(len(packed_arr)):
                if (i * 2) < embedding_dim:
                    unpacked[i * 2] = (packed_arr[i] >> 4) - 8
                if (i * 2 + 1) < embedding_dim:
                    unpacked[i * 2 + 1] = (packed_arr[i] & 0x0F) - 8

            arr = (unpacked.astype(np.float32) / 7.0) * scale
            print(f"Token {token_id} (int4 quantized) embedding shape: {arr.shape}")
            print(f"Original packed array (first 5 bytes): {packed_arr[:5]}..., scale: {scale}")
        else:
            arr = np.frombuffer(val, dtype=np.float32)
            print(f"Token {token_id} embedding shape: {arr.shape}")

        return arr


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Export transformer embeddings to LMDB.")
    parser.add_argument("--model_id", type=str, default="./model",
                        help="Path to the model.")
    parser.add_argument("--db_dir", type=str, default="./model/embeddings_lmdb",
                        help="Directory to save the LMDB database.")
    parser.add_argument("--batch_size", type=int, default=1000, help="Batch size for processing.")
    parser.add_argument("--quantize", type=str, choices=['int8', 'int4'], default=None,
                        help="Quantization type (int8 or int4).")
    parser.add_argument("--test_token", type=int, default=1000, help="Token ID to test reading back.")
    args = parser.parse_args()

    export_embeddings_to_lmdb(args.model_id, args.db_dir, args.batch_size, args.quantize)

    print("\nTesting read...")
    read_embedding_example(args.db_dir, args.test_token)
