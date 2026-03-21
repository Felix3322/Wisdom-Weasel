import argparse
import os

import torch
from onnxruntime.quantization import QuantType, quantize_dynamic
from transformers import AutoModel, AutoTokenizer


class FeatureExtractionWrapper(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, input_ids, attention_mask):
        outputs = self.model(
            input_ids=input_ids,
            attention_mask=attention_mask,
            use_cache=False,
            return_dict=True,
        )
        return outputs.last_hidden_state


class ManualQwenFeatureWrapper(torch.nn.Module):
    def __init__(self, model, seq_len: int):
        super().__init__()
        self.model = model
        causal_mask = torch.zeros((1, 1, seq_len, seq_len), dtype=torch.float32)
        min_value = torch.finfo(torch.float32).min
        for row in range(seq_len):
            for col in range(row + 1, seq_len):
                causal_mask[0, 0, row, col] = min_value
        self.register_buffer("causal_mask_template", causal_mask, persistent=False)

    def forward(self, input_ids, attention_mask):
        hidden_states = self.model.embed_tokens(input_ids)
        batch_size, seq_len = input_ids.shape
        position_ids = (
            torch.arange(seq_len, device=input_ids.device)
            .unsqueeze(0)
            .expand(batch_size, -1)
        )

        min_value = torch.tensor(
            torch.finfo(hidden_states.dtype).min,
            dtype=hidden_states.dtype,
            device=hidden_states.device,
        )
        causal_mask = self.causal_mask_template.to(hidden_states.dtype)
        if batch_size != 1:
            causal_mask = causal_mask.expand(batch_size, 1, seq_len, seq_len)
        if attention_mask is not None:
            padding_mask = attention_mask[:, None, None, :] == 0
            causal_mask = causal_mask.masked_fill(padding_mask, min_value)

        position_embeddings = self.model.rotary_emb(hidden_states, position_ids)
        for layer in self.model.layers[: self.model.config.num_hidden_layers]:
            hidden_states = layer(
                hidden_states,
                attention_mask=causal_mask,
                position_ids=position_ids,
                past_key_values=None,
                use_cache=False,
                position_embeddings=position_embeddings,
            )
        hidden_states = self.model.norm(hidden_states)
        return hidden_states


def export_model(model_id: str, output_dir: str, quantize: str | None, opset: int):
    os.makedirs(output_dir, exist_ok=True)
    export_seq_length = int(os.environ.get("ALPHA_EXPORT_SEQ_LENGTH", "64"))

    tokenizer = AutoTokenizer.from_pretrained(model_id, trust_remote_code=True)
    tokenizer.save_pretrained(output_dir)

    model = AutoModel.from_pretrained(
        model_id,
        trust_remote_code=True,
        torch_dtype=torch.float32,
        attn_implementation="eager",
        low_cpu_mem_usage=True,
    )
    model.eval()

    class_name = model.__class__.__name__.lower()
    if "qwen3" in class_name:
        wrapper = ManualQwenFeatureWrapper(model, export_seq_length)
    else:
        wrapper = FeatureExtractionWrapper(model)
    sample = tokenizer(
        "今天下午要开会",
        return_tensors="pt",
        padding="max_length",
        truncation=True,
        max_length=export_seq_length,
    )

    model_path = os.path.join(output_dir, "model.onnx")
    torch.onnx.export(
        wrapper,
        (sample["input_ids"], sample["attention_mask"]),
        model_path,
        input_names=["input_ids", "attention_mask"],
        output_names=["last_hidden_state"],
        opset_version=opset,
        do_constant_folding=True,
        training=torch.onnx.TrainingMode.EVAL,
        dynamo=False,
    )

    if quantize == "int8":
        quantized_path = os.path.join(output_dir, "model.int8.onnx")
        quantize_dynamic(model_path, quantized_path, weight_type=QuantType.QInt8)
        os.replace(quantized_path, model_path)

    with open(os.path.join(output_dir, "export_meta.txt"), "w", encoding="utf-8") as fh:
        fh.write(f"export_seq_length={export_seq_length}\n")

    print(f"Exported ONNX model to: {model_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Export a Hugging Face decoder model as feature-extraction ONNX."
    )
    parser.add_argument("--model_id", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--quantize", choices=["int8"], default=None)
    parser.add_argument("--opset", type=int, default=17)
    args = parser.parse_args()

    export_model(args.model_id, args.output, args.quantize, args.opset)


if __name__ == "__main__":
    main()
