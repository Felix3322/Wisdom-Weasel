# -*- coding: utf-8 -*-
import torch
import torch.nn as nn
from torch.utils.data import DataLoader
import torch.optim as optim
from torch.optim.lr_scheduler import LambdaLR
import tqdm

from getRawData import split_to_sentences
from AdvancedDataset import AdvancedIME_Dataset
from IMETokenizer import IMETokenizerGB2312, PinyinTokenizer
from pinyinModel import PinyinTransformer

from train_easy import DMODEL, NHEAD, NUM_LAYERS

# ==========================================
# Interactive Testing
# ==========================================
print("\n>>> All Training Finished! Enter Interactive Mode <<<")
print("Format: <Context>|<Pinyin>")
print("Example: 最近|zenmeyang (Context=最近, Pinyin=zenmeyang)")
print("Type 'exit' or 'q' to quit.")

# DMODEL = 192
# NHEAD = 6
# NUM_LAYERS = 2

MODEL_SAVE_PATH = "best_model_stage_2_large.pth"  # 这里假设你已经保存了训练好的模型权重

device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
char_tokenizer = IMETokenizerGB2312()
py_tokenizer = PinyinTokenizer()
model = PinyinTransformer(char_vocab_size=char_tokenizer.vocab_size,
                          pinyin_vocab_size=py_tokenizer.vocab_size,
                          d_model=DMODEL, nhead=NHEAD, num_layers=NUM_LAYERS).to(device)
model.load_state_dict(torch.load(MODEL_SAVE_PATH, map_location=device))


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


def infer():
    while True:
        try:
            line = input("\nInput (Context | Pinyin): ").strip()
            if line.lower() in ['exit', 'q']:
                break

            if "|" in line:
                ctx, py = line.split("|", 1)
                ctx = ctx.strip()
                py = py.strip()
            else:
                print("Format Error! Use '|' to separate Context and Pinyin.")
                continue

            print(f"Generating for Context='{ctx}', Pinyin='{py}'...")
            res = generate_text_stage_2(model, char_tokenizer, py_tokenizer, ctx, py, device=device)
            print(f"Result: {res}")

        except KeyboardInterrupt:
            break
        except Exception as e:
            print(f"Error: {e}")


if __name__ == '__main__':
    infer()
