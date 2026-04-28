# -*- coding: utf-8 -*-
import torch
import torch.nn.functional as F

from IMETokenizer import IMETokenizerGB2312, PinyinTokenizer
from pinyinModel import PinyinTransformer
from train_easy import DMODEL, NHEAD, NUM_LAYERS

# ==========================================
# Beam Search Inference for Pinyin Transformer
# ==========================================
print("\n>>> Beam Search Decoding <<<")
print("Format: <Context>|<Pinyin>")
print("Example: 最近|zenmeyang (Context=最近, Pinyin=zenmeyang)")
print("Type 'exit' or 'q' to quit.")

MODEL_SAVE_PATH = "best_model_stage_2_large.pth"

device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
char_tokenizer = IMETokenizerGB2312()
py_tokenizer = PinyinTokenizer()

model = PinyinTransformer(char_vocab_size=char_tokenizer.vocab_size,
                          pinyin_vocab_size=py_tokenizer.vocab_size,
                          d_model=DMODEL, nhead=NHEAD, num_layers=NUM_LAYERS).to(device)
try:
    model.load_state_dict(torch.load(MODEL_SAVE_PATH, map_location=device))
    print("Model loaded successfully.")
except Exception as e:
    print(f"Error loading model: {e}. Make sure the path is correct.")

def beam_search_decode(model, char_tok, py_tok, context_text, pinyin_text, beam_width=5, max_len=20, device='cpu'):
    """
    使用 Beam Search 进行解码。
    核心思想：在每一步生成时，保留得分最高的前 `beam_width` 个序列，而不是只挑概率最大的 1 个。
    这能有效缓解“局部极其高频，但整体不通顺”的“人工智障”现象。
    """
    model.eval()

    # 1. 编码 Pinyin (Encoder Input)
    py_enc = py_tok(pinyin_text, return_tensors="pt")
    src = py_enc['input_ids'].to(device)
    src_key_padding_mask = (src == py_tok.pad_token_id)

    # 2. 预先计算 Encoder Memory (由于拼音输入是固定的，Memory 也是固定的，可以直接复用，节省算力)
    with torch.no_grad():
        src_emb = model.pinyin_embedding(src) * (model.d_model ** 0.5)
        src_emb = model.pos_encoder(src_emb)
        memory = model.transformer_encoder(src_emb, src_key_padding_mask=src_key_padding_mask)

    # 3. 初始化 Decoder 的起步输入序列
    # 格式：[CLS] c o n t e x t
    start_ids = [char_tok.cls_token_id] + [char_tok.v2i.get(c, char_tok.unk_token_id) for c in context_text]
    
    # 建立一条起始的 Beam。
    # 每个 Beam 是一个 tuple: (累积对数概率总得分分数 score, 当前已生成的 Token 序列 sequence)
    # 对数概率(Log Probability)：因为概率连乘会越来越小导致下溢，所以在代码里加起来，起步是 0.0 (相当于概率 1.0)
    beams = [(0.0, start_ids)]

    context_length = len(start_ids) # 记录一下前缀长度，方便最后提取纯输出

    with torch.no_grad():
        for step in range(max_len):
            all_candidates = []

            # 遍历当前存活的所有 Beam（路径）
            for score, seq in beams:
                # 检查这条路径是否已经生成了 [SEP]，也就是“翻译完毕”了
                if seq[-1] == char_tok.sep_token_id:
                    all_candidates.append((score, seq)) # 完成的路径直接保留
                    continue

                # 提取这条路径当前的 tgt_ids
                tgt_ids = torch.tensor([seq], dtype=torch.long).to(device)
                tgt_key_padding_mask = (tgt_ids == char_tok.pad_token_id)

                # Decoder 的输入处理 (我们只调用 Decoder，因为 Memory 已经算好了！)
                tgt_emb = model.char_embedding(tgt_ids) * (model.d_model ** 0.5)
                tgt_emb = model.pos_encoder(tgt_emb)
                tgt_mask = model.generate_square_subsequent_mask(tgt_ids.size(1), device)

                # 运行 Decoder
                out = model.transformer_decoder(
                    tgt=tgt_emb,
                    memory=memory, # 重点：所有的 beam 共享同一个 Pinyin Memory
                    tgt_mask=tgt_mask,
                    tgt_key_padding_mask=tgt_key_padding_mask,
                    memory_key_padding_mask=src_key_padding_mask
                )
                
                # 获取最后一个预测词的概率分布 (LogITS)
                logits = model.fc_out(out)
                next_token_logits = logits[:, -1, :] # 取最后一个时间步
                
                # 为了防止概率溢出，计算 log_softmax，得到每个词在当前步的对数概率
                log_probs = F.log_softmax(next_token_logits, dim=-1).squeeze(0) # shape: (vocab_size)

                # 贪心搜索是直接 torch.argmax
                # Beam Search 是取 Top-K 个最大的概率，探索 K 种可能的未来
                topk_log_probs, topk_indices = torch.topk(log_probs, beam_width)
                
                # 为当前路径衍生出 K 条新路径
                for i in range(beam_width):
                    next_token = topk_indices[i].item()
                    step_prob = topk_log_probs[i].item()
                    
                    # 路径的累积得分 = 老路径得分 + 当前步得分 (因为是 Log，所以相加)
                    new_score = score + step_prob
                    new_seq = seq + [next_token]
                    
                    all_candidates.append((new_score, new_seq))

            # 根据累加的得分 (score)，对所有候选路径进行降序排序
            # 选出这一轮得分最高的 Top-K 条路径，进入下一轮迭代
            ordered = sorted(all_candidates, key=lambda tup: tup[0], reverse=True)
            beams = ordered[:beam_width]

            # 提前停止机制：如果所有存活的 Beam 都已经结束了 (都输出了 SEP)
            if all(seq[-1] == char_tok.sep_token_id for _, seq in beams):
                break

    # 循环结束后，beams[0] 就是得分最高、从全局来看最通顺的路径
    best_score, best_seq = beams[0]
    
    # 调试信息：打印 Top-N 的结果，让你直观感受到为什么选第一个
    print(f"--- Beam Search Top {len(beams)} Candidates ---")
    for idx, (s, seq) in enumerate(beams):
        # 截掉 [CLS] 和 context，只看生成部分
        gen_seq = seq[context_length:]
        # 去掉 [SEP]
        if gen_seq and gen_seq[-1] == char_tok.sep_token_id:
            gen_seq = gen_seq[:-1]
        decoded_text = char_tok.decode(gen_seq)
        
        # 为了美观，限制一下长度或者打印一下
        if decoded_text == "":
            decoded_text = "<空>"
        print(f"  Rank {idx+1}: Score={s:.4f} | Result='{decoded_text}'")
    print("--------------------------------------")

    # 返回最好的结果的文本
    final_output_ids = best_seq[context_length:]
    if final_output_ids and final_output_ids[-1] == char_tok.sep_token_id:
         final_output_ids = final_output_ids[:-1]
    return char_tok.decode(final_output_ids)

def infer():
    print("Beam Search Initialized. Ready for input.\n")
    while True:
        try:
            line = input("Input (Context | Pinyin): ").strip()
            if line.lower() in ['exit', 'q']:
                break

            if "|" in line:
                ctx, py = line.split("|", 1)
                ctx = ctx.strip()
                py = py.strip()
            else:
                print("Format Error! Use '|' to separate Context and Pinyin.")
                continue

            print(f"\n[Greedy vs Beam] Context='{ctx}', Pinyin='{py}'...")
            
            # 引入贪心搜索进行对比（从 infer.py 拿过来的逻辑）
            # ----------------------------------------------------
            # （为了保持脚本独立，这里简化贴一下贪心逻辑作为对比）
            # ----------------------------------------------------
            from infer import generate_text_stage_2
            greedy_res = generate_text_stage_2(model, char_tokenizer, py_tokenizer, ctx, py, device=device)
            # 因为贪心带了 context，我们把它截掉
            if greedy_res.startswith(ctx):
                greedy_out = greedy_res[len(ctx):]
            else:
                greedy_out = greedy_res
            print(f"-> 传统贪心 (Greedy): {greedy_out}")
            
            # 执行 Beam Search
            print(f"-> 开始束搜索 (Beam Width=5):")
            best_res = beam_search_decode(model, char_tokenizer, py_tokenizer, ctx, py, beam_width=5, device=device)
            print(f"\n✅ 最终选择输出: {best_res}\n")

        except KeyboardInterrupt:
            break
        except Exception as e:
            print(f"\nError: {e}\n")


if __name__ == '__main__':
    infer()
