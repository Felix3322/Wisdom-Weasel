# -*- coding: utf-8 -*-
import gc
import torch
import torch.nn as nn
from torch.utils.data import DataLoader
import torch.optim as optim
from torch.optim.lr_scheduler import LambdaLR
import tqdm
import math

from getRawData import split_to_sentences
from AdvancedDataset import AdvancedIME_Dataset
from IMETokenizer import IMETokenizerGB2312
from pinyinModel import PinyinTransformer

BATCH_SIZE = 256  # 大模型显存占用增大，降低 batch_size
LEARNING_RATE = 1e-4  # Stage 1 用
WEIGHT_DECAY = 1e-4
DMODEL = 512  # Transformer 的隐藏维度（大模型）
NHEAD = 8  # 多头注意力机制中的头数
NUM_LAYERS = 6  # 编码器和解码器的层数（大模型）

CONTEXT_LEN = 64  # 上文长度（加大以捕获更多上下文）
TARGET_LEN = 12  # 输出长度（目标文本）
PINYIN_LEN = TARGET_LEN * 6  # 拼音长度（每个汉字最多6个拼音）
PINYIN_STAGE = 2  # 1: 上下文空+全拼 2: 上下文按概率出现，全拼无噪声 3: 上下文按概率出现 + 简拼/混合 + 模糊音/typo 按概率
MODEL_SAVE_PATH = "best_model_stage_2_large.pth"
STAGE1_SAVE_PATH = "best_model_stage_1_large.pth"


def generate_text_autoregressive(model, tokenizer, start_text, max_len=10, device='cpu'):
    model.eval()

    # 1. 编码 Context
    # 加上 [CLS]
    start_ids = [tokenizer.cls_token_id] + [tokenizer.v2i.get(c, tokenizer.unk_token_id) for c in start_text]
    curr_ids = torch.tensor([start_ids], dtype=torch.long).to(device)

    with torch.no_grad():
        for _ in range(max_len):
            # 2. 调用 Decoder
            # 此时 tgt_key_padding_mask=None, 因为我们想让它生成，不需要 mask 掉任何东西
            logits = model.forward_decoder_only(curr_ids)

            # 3. 取最后一个时间步的输出
            next_token_logits = logits[:, -1, :]

            # 4. 贪婪采样 (Greedy Search)
            next_token_id = torch.argmax(next_token_logits, dim=-1).unsqueeze(0)

            # 5. 拼接到当前序列
            curr_ids = torch.cat([curr_ids, next_token_id], dim=1)

            # 如果生成了 [SEP] 可以提前停止 (这里为了演示预测 10 个字，暂时不 break)
            if next_token_id.item() == tokenizer.sep_token_id:
                break

    # 解码
    output_ids = curr_ids.squeeze(0).tolist()
    return tokenizer.decode(output_ids)


def train_stage_1(model, dataloader, optimizer, device, use_amp=False, save_path=STAGE1_SAVE_PATH):
    model.train()
    criterion = nn.CrossEntropyLoss(ignore_index=0)  # PAD index is 0

    accumulated_loss = 0
    batch_count = 0
    print_interval = 3000
    prev_loss = float('inf')
    dataloader = tqdm.tqdm(dataloader, desc="  Training", leave=False)
    for batch in dataloader:
        full_ids = batch['full_ids'].to(device)  # (B, L)

        # 错位操作，经典 Next Token Prediction
        # Input: [CLS] 机 器 学 习
        # Label:  机  器 学 习 [SEP]
        tgt_input = full_ids[:, :-1]
        tgt_label = full_ids[:, 1:]

        # 构造 padding mask: True 表示 PAD 位置（需要被忽略）
        tgt_key_padding_mask = (tgt_input == 0)

        optimizer.zero_grad()

        # Mixed Precision Context
        with torch.amp.autocast(device_type=device.type, dtype=torch.bfloat16, enabled=use_amp):
            # 调用只跑 Decoder 的前向传播（传入 padding mask）
            logits = model.forward_decoder_only(tgt_input, tgt_key_padding_mask=tgt_key_padding_mask)

            # (B, L-1, V) -> (B*(L-1), V)
            loss = criterion(logits.reshape(-1, model.char_embedding.num_embeddings), tgt_label.reshape(-1))

        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)  # 梯度裁剪，防止梯度爆炸
        optimizer.step()
        accumulated_loss += loss.item()
        batch_count += 1

        dataloader.set_postfix({"loss": loss.item()})
        if batch_count % print_interval == 0:
            avg_loss = accumulated_loss / print_interval
            if avg_loss < prev_loss:
                print("  Loss improved from {:.4f} to {:.4f}, saving model...".format(prev_loss, avg_loss))
                torch.save(model.state_dict(), save_path)
                prev_loss = avg_loss
            print(f"  Batch {batch_count}, Avg Loss: {avg_loss:.4f}")
            accumulated_loss = 0
            batch_count = 0


def generate_text_stage_2(model, tokenizer, pinyin_tokenizer, context_text, pinyin_text, max_len=20, device='cpu'):
    """
    Stage 2 生成：输入 Context 和 Pinyin，预测 Target
    """
    model.eval()

    # 1. 编码 Pinyin (Encoder Input)
    py_enc = pinyin_tokenizer(pinyin_text, return_tensors="pt")
    src = py_enc['input_ids'].to(device)
    src_key_padding_mask = (src == pinyin_tokenizer.pad_token_id)  # True for PAD

    # 2. 编码 Context (Decoder Start)
    # [CLS] Context
    start_ids = [tokenizer.cls_token_id] + [tokenizer.v2i.get(c, tokenizer.unk_token_id) for c in context_text]
    tgt_ids = torch.tensor([start_ids], dtype=torch.long).to(device)

    with torch.no_grad():
        # 预先编码 Encoder，不用在循环里每次都算一遍 (Transformer特性)
        # 但是 pytorch nn.Transformer 模块通常是一起调用的
        # 为了方便，我们这里直接调用 model.forward，稍微低效一点点但逻辑简单
        # 也可以手动调 model.transformer_encoder 拿到 memory

        # 这里的实现：每次循环都跑一遍完整的 forward
        for _ in range(max_len):
            tgt_key_padding_mask = (tgt_ids == tokenizer.pad_token_id)

            # 调用完整的前向传播
            logits = model(src, tgt_ids, src_key_padding_mask=src_key_padding_mask, tgt_key_padding_mask=tgt_key_padding_mask)

            # 取最后一个 token 的输出
            next_token_logits = logits[:, -1, :]
            next_token_id = torch.argmax(next_token_logits, dim=-1).unsqueeze(0)

            # 拼接到 tgt
            tgt_ids = torch.cat([tgt_ids, next_token_id], dim=1)

            if next_token_id.item() == tokenizer.sep_token_id:
                break

    output_ids = tgt_ids.squeeze(0).tolist()
    # 只需要解码新生成的部分? 或者全部解码看看
    full_decoded = tokenizer.decode(output_ids)

    # 去掉 context
    # 简单处理：直接返回 full_decoded
    return full_decoded


def train_stage_2(model, dataloader, optimizer, device, use_amp=False, scheduler=None, char_tokenizer=None, py_tokenizer=None):
    """
    Stage 2: 联合训练 Encoder (Pinyin) 和 Decoder (Context + Target)
    """
    model.train()
    criterion = nn.CrossEntropyLoss(ignore_index=0)  # PAD

    accumulated_loss = 0
    batch_count = 0
    skipped_count = 0
    print_interval = 3000
    prev_loss = float('inf')
    dataloader = tqdm.tqdm(dataloader, desc="  Training Stage 2", leave=False)
    for batch in dataloader:
        full_ids = batch['full_ids'].to(device)  # (B, L_tgt) -> Decoder Input
        tgt_y = batch['tgt_y'].to(device)  # (B, L_tgt) -> Label (Context masked)
        py_ids = batch['py_ids'].to(device)  # (B, L_src) -> Encoder Input

        # 1. 构造 Decoder Input / Label
        tgt_input = full_ids[:, :-1]
        tgt_label = tgt_y[:, 1:]

        # 2. Mask
        # Pytorch Transformer 的 src_key_padding_mask: True 表示 PAD (被忽略)
        src_key_padding_mask = (py_ids == 0)
        tgt_key_padding_mask = (tgt_input == 0)

        optimizer.zero_grad()

        with torch.amp.autocast(device_type=device.type, dtype=torch.bfloat16, enabled=use_amp):
            # 3. Model Forward
            logits = model(py_ids, tgt_input,
                           src_key_padding_mask=src_key_padding_mask,
                           tgt_key_padding_mask=tgt_key_padding_mask)

            # 4. Loss
            loss = criterion(logits.reshape(-1, model.char_embedding.num_embeddings), tgt_label.reshape(-1))
        # === 梯度安全检查 ===
        # 检测 loss 是否为 NaN/Inf, 如果是则跳过该 batch
        if not torch.isfinite(loss):
            optimizer.zero_grad()
            skipped_count += 1
            print("  Warning: Non-finite loss detected, skipping batch. Total skipped: {}".format(skipped_count))
            continue

        loss.backward()
        grad_norm = torch.nn.utils.clip_grad_norm_(model.parameters(), 1)  # 加上梯度裁剪
        dataloader.set_postfix({"loss": loss.item(), "grad_norm": grad_norm.item()})

        if (not torch.isfinite(grad_norm) or grad_norm > 100) and batch_count > 4000:
            optimizer.zero_grad()
            skipped_count += 1
            print("暴毙了！梯度范数: {:.2f}, 跳过这个 batch. Total skipped: {}".format(grad_norm, skipped_count))
            continue

        optimizer.step()
        if scheduler:
            scheduler.step()

        batch_count += 1
        accumulated_loss += loss.item()
        if batch_count % print_interval == 0:
            avg_loss = accumulated_loss / print_interval  # 修复：移到 if 内，确保分母正确
            if avg_loss < prev_loss:
                print("  Loss improved from {:.4f} to {:.4f}, saving model...".format(prev_loss, avg_loss))
                torch.save(model.state_dict(), MODEL_SAVE_PATH)
                prev_loss = avg_loss
            print(f"  Batch {batch_count}, Avg Loss: {avg_loss:.4f}, Skipped Batches: {skipped_count}")

            # Test Stage 2
            # Context: "最近", Pinyin: "mangwanle" (忙完了)
            print("  Test Stage 2 (Ctx='中国有一个古都叫', Py='xian') ->",
                  generate_text_stage_2(model, char_tokenizer, py_tokenizer, "中国有一个古都叫", "xian", device=device))
            print("  Test Stage 2 (Ctx='搞毛', Py='xian') ->",
                  generate_text_stage_2(model, char_tokenizer, py_tokenizer, "搞毛", "xian", device=device))
            print("  Test Stage 2 (Ctx='你是不是很', Py='xian') ->",
                  generate_text_stage_2(model, char_tokenizer, py_tokenizer, "你是不是很", "xian", device=device))
            print("  Test Stage 2 (Ctx='', Py='zheshishenmegoupiwaner') ->",
                  generate_text_stage_2(model, char_tokenizer, py_tokenizer, "", "zheshishenmegoupiwaner", device=device))

            accumulated_loss = 0
            batch_count = 0
            if avg_loss > 150:
                print("LOSS炸了")
                exit()


def main():
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

    # Check for BF16 support
    use_bf16 = False
    if device.type == 'cuda' and torch.cuda.is_bf16_supported():
        use_bf16 = True

    print(f"Using device: {device}, using BF16: {use_bf16}")

    # --- Config ---
    DATA_PATH = [  # 文件名，数据采集百分比
        ["text_pure/merged_vocabulary.txt", 1.0],
        ["text_pure/LCCC-base_train.txt", 1.0],
        ["text_pure/wiki_zh_pure.txt", 1.0]
    ]
    STAGE1_EPOCH = 0  # 大模型需要重新训练 Stage 1
    STAGE2_EPOCH = 5  # 增大 epoch 数以充分学习
    # --------------
    LOAD_STAGE1_MODEL = True  # 是否加载 Stage 1 模型权重，节省训练时间（如果之前已经训练过了）

    # 1. Load Data
    origin_txt_list = []

    for file_name, percentage in DATA_PATH:
        with open(file_name, "r", encoding="utf-8") as f:
            raw_content = f.read()
            sentences = split_to_sentences(raw_content)
            num_sentences = int(len(sentences) * percentage)
            origin_txt_list.extend(sentences[:num_sentences])
            print(f"Loaded {num_sentences} sentences from {file_name} (Total: {len(origin_txt_list)})")

    # 2. Tokenizers
    char_tokenizer = IMETokenizerGB2312()
    from IMETokenizer import PinyinTokenizer
    py_tokenizer = PinyinTokenizer()

    # 3. Model
    model = PinyinTransformer(char_vocab_size=char_tokenizer.vocab_size,
                              pinyin_vocab_size=py_tokenizer.vocab_size,
                              d_model=DMODEL, nhead=NHEAD, num_layers=NUM_LAYERS).to(device)
    # 加载模型（新模型结构不兼容旧 checkpoint，注释掉从头训练）
    # model.load_state_dict(torch.load(MODEL_SAVE_PATH, map_location=device))
    if LOAD_STAGE1_MODEL:
        model.load_state_dict(torch.load("best_model_stage_1_large.pth", map_location=device))
    optimizer = optim.AdamW(model.parameters(), lr=LEARNING_RATE, weight_decay=WEIGHT_DECAY)

    # ==========================================
    # Phase 1: Decoder Only Pre-training
    # ==========================================
    print("\n>>> Start Training Stage 1 (Decoder Only - GPT Style) <<<")

    # 冻结 Decoder 的 Cross-Attention 参数（Stage 1 不需要，避免噪声梯度干扰）
    print("  Freezing Cross-Attention parameters for Stage 1...")
    for layer in model.transformer_decoder.layers:
        for p in layer.multihead_attn.parameters():
            p.requires_grad = False
        for p in layer.norm2.parameters():  # Cross-Attention 对应的 LayerNorm
            p.requires_grad = False

    ds_stage1 = AdvancedIME_Dataset(origin_txt_list, char_tokenizer, py_tokenizer,
                                    max_tgt_len=CONTEXT_LEN + TARGET_LEN, stage=1)
    dl_stage1 = DataLoader(
        ds_stage1,
        batch_size=BATCH_SIZE,
        shuffle=True,
        drop_last=True,
        num_workers=4,  # 减少 worker 数量，每个 worker fork 会复制主进程内存
        pin_memory=True,  # 锁页内存，加速 CPU 向 GPU 传输数据的过程
        prefetch_factor=2  # 减少预取批次，降低内存占用
    )

    for epoch in range(STAGE1_EPOCH):
        print(f"Epoch {epoch + 1}/{STAGE1_EPOCH}")
        train_stage_1(model, dl_stage1, optimizer, device, use_amp=use_bf16)

        # Test
        print("  Test Gen: '最近博' ->", generate_text_autoregressive(model, char_tokenizer, "最近博", device=device))

    # 释放 Stage 1 数据，回收内存
    del ds_stage1, dl_stage1
    gc.collect()
    print("  Stage 1 data released, memory freed.")

    # ==========================================
    # Phase 2: Joint Training (Pinyin + Context)
    # ==========================================
    # 解冻 Cross-Attention 参数，Stage 2 需要用到
    print("\n  Unfreezing Cross-Attention parameters for Stage 2...")
    for layer in model.transformer_decoder.layers:
        for p in layer.multihead_attn.parameters():
            p.requires_grad = True
        for p in layer.norm2.parameters():
            p.requires_grad = True

    # 重新创建 optimizer，避免被冻结参数的 momentum 状态影响
    STAGE2_LR = 3e-5  # 大模型用更小的学习率，避免震荡
    optimizer = optim.AdamW(model.parameters(), lr=STAGE2_LR, weight_decay=WEIGHT_DECAY)
    print(">>> Start Training Stage 2 (Encoder-Decoder - Pinyin Aware) <<<")

    ds_stage2 = AdvancedIME_Dataset(origin_txt_list, char_tokenizer, py_tokenizer,
                                    max_ctx_len=CONTEXT_LEN, max_tgt_len=TARGET_LEN, max_py_len=PINYIN_LEN + 2, stage=2)

    # 释放原始文本列表，Dataset 已持有自己的引用
    del origin_txt_list
    gc.collect()

    dl_stage2 = DataLoader(
        ds_stage2,
        batch_size=BATCH_SIZE,
        shuffle=True,
        drop_last=True,
        num_workers=4,  # 减少 worker 数量，降低内存占用
        pin_memory=True,
        prefetch_factor=2  # 减少预取批次
    )

    # Scheduler 必须在 dl_stage2 创建后定义（需要 len(dl_stage2)）
    warmup_steps = 8000  # 大模型需要更长的 warmup
    total_steps = len(dl_stage2) * STAGE2_EPOCH  # cosine decay 需要总步数
    scheduler = LambdaLR(optimizer, lr_lambda=lambda step: (
        step / warmup_steps if step < warmup_steps  # 线性 warmup
        else 0.5 * (1.0 + math.cos(math.pi * (step - warmup_steps) / (total_steps - warmup_steps)))  # cosine decay
    ))

    for epoch in range(STAGE2_EPOCH):
        print(f"Epoch {epoch + 1}/{STAGE2_EPOCH}")
        train_stage_2(model, dl_stage2, optimizer, device, use_amp=use_bf16, scheduler=scheduler, char_tokenizer=char_tokenizer,
                      py_tokenizer=py_tokenizer)


if __name__ == '__main__':
    main()
