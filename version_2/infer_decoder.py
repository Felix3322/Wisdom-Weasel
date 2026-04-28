# -*- coding: utf-8 -*-
import torch
from IMETokenizer import IMETokenizerGB2312, PinyinTokenizer
from pinyinModel import PinyinTransformer

from train_easy import DMODEL, NHEAD, NUM_LAYERS

# ==========================================
# Interactive Testing (Stage 1 Decoder Only)
# ==========================================
print("\n>>> Stage 1 Decoder Output Testing <<<")
print("Format: <Context>")
print("Example: 今天天气 (Context=今天天气)")
print("Type 'exit' or 'q' to quit.")

MODEL_SAVE_PATH = "best_model_stage_2_large.pth"

device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

char_tokenizer = IMETokenizerGB2312()
py_tokenizer = PinyinTokenizer()

model = PinyinTransformer(char_vocab_size=char_tokenizer.vocab_size,
                          pinyin_vocab_size=py_tokenizer.vocab_size,
                          d_model=DMODEL, nhead=NHEAD, num_layers=NUM_LAYERS).to(device)
                          
model.load_state_dict(torch.load(MODEL_SAVE_PATH, map_location=device))

def generate_text_stage_1(model, tokenizer, start_text, max_len=50, device='cpu'):
    """
    Stage 1 生成：仅使用 Decoder 进行文本续写
    """
    model.eval()

    # 编码 Context (Decoder Start)
    start_ids = [tokenizer.cls_token_id] + [tokenizer.v2i.get(c, tokenizer.unk_token_id) for c in start_text]
    tgt_ids = torch.tensor([start_ids], dtype=torch.long).to(device)

    with torch.no_grad():
        for _ in range(max_len):
            tgt_key_padding_mask = (tgt_ids == tokenizer.pad_token_id)

            # 调用 forward_decoder_only
            logits = model.forward_decoder_only(tgt_ids, tgt_key_padding_mask=tgt_key_padding_mask)

            # 取最后一个 token 的输出
            next_token_logits = logits[:, -1, :]
            next_token_id = torch.argmax(next_token_logits, dim=-1).unsqueeze(0)

            # 拼接到 tgt
            tgt_ids = torch.cat([tgt_ids, next_token_id], dim=1)

            if next_token_id.item() == tokenizer.sep_token_id:
                break

    output_ids = tgt_ids.squeeze(0).tolist()
    full_decoded = tokenizer.decode(output_ids)

    return full_decoded


def infer():
    while True:
        try:
            line = input("\nInput Context: ").strip()
            if line.lower() in ['exit', 'q']:
                break
                
            if not line:
                continue

            ctx = line
            print(f"Generating for Context='{ctx}'...")
            res = generate_text_stage_1(model, char_tokenizer, ctx, max_len=50, device=device)
            print(f"Result: {res}")

        except KeyboardInterrupt:
            break
        except Exception as e:
            print(f"Error: {e}")


if __name__ == '__main__':
    infer()
