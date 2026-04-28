# -*- coding: utf-8 -*-
import random
import torch
from torch.utils.data import Dataset
from pypinyin import pinyin, Style


# 假设你已经有了这两个 Tokenizer
# from your_tokenizers import IMETokenizerGB2312, PinyinTokenizer

class AdvancedIME_Dataset(Dataset):
    def __init__(self, texts, char_tokenizer, py_tokenizer, max_ctx_len=64, max_py_len=64, max_tgt_len=64, stage=1):
        """
        stage 1: 纯 Decoder 训练 (只返回 context + tgt)
        stage 2: 联合训练 (返回 context + pinyin + tgt)
        """
        self.texts = [t for t in texts if len(t) > 1]  # 简单过滤
        self.char_tokenizer = char_tokenizer
        self.py_tokenizer = py_tokenizer

        self.max_ctx_len = max_ctx_len
        self.max_py_len = max_py_len
        self.max_tgt_len = max_tgt_len
        self.stage = stage

    def __len__(self):
        return len(self.texts)

    def __getitem__(self, idx):
        text = self.texts[idx]
        text_len = len(text)

        # -------------------------------------------------------
        # 1. 随机切分 Context / Target
        # -------------------------------------------------------
        # 目标：随机选一段作为 target (要预测的字)，前面的作为 context
        if self.stage == 1:
            # 直接把整句话 tokenizer 编码
            full_enc = self.char_tokenizer(text, max_length=self.max_tgt_len, padding='max_length', truncation=True, return_tensors="pt")

            return {
                "full_ids": full_enc['input_ids'].squeeze(0),
                "full_mask": full_enc['attention_mask'].squeeze(0),
                "tgt_y": full_enc['input_ids'].squeeze(0), # For compatibility if needed, though stage 1 doesn't use it
            }

        # 随机决定 target 长度 (1 到 max_tgt_len)
        upper_bound = min(text_len - 1, self.max_tgt_len)  
        if upper_bound < 1: upper_bound = 1

        tgt_len = random.randint(1, upper_bound)

        # 随机选切分点
        # split_idx 是 target 的开始位置
        # context: text[:split_idx]
        # target:  text[split_idx : split_idx + tgt_len]
        
        split_idx = random.randint(0, text_len - tgt_len) # 允许 context 为空

        raw_context = text[:split_idx]
        raw_target = text[split_idx: split_idx + tgt_len]

        # -------------------------------------------------------
        # 2. 截断 Context (不要太长)
        # -------------------------------------------------------
        if len(raw_context) > self.max_ctx_len:
            raw_context = raw_context[-self.max_ctx_len:]  # 取最后一段

        # -------------------------------------------------------
        # 3. 生成 Pinyin (仅 Stage 2 需要)
        # -------------------------------------------------------
        raw_pinyin = ""
        # 只对 target 生成拼音！因为 Encoder 只负责听 target 的音
        # context 的音不需要，Decoder 自己认字
        py_list = pinyin(raw_target, style=Style.NORMAL, errors='default')
        # 简单的拼接逻辑，你可以加上你的那些噪声函数 (typo, 模糊音等)
        # 这里简化处理，把 list 拼成字符串
        pinyin_segments = [item[0] for item in py_list]
        raw_pinyin = "".join(pinyin_segments)

        # TODO: 在这里加入你的 simulate_typo 等噪声函数
        if self.stage >= 3:
            # raw_pinyin = simulate_typo(raw_pinyin) 
            pass

        # -------------------------------------------------------
        # 4. Tokenization (分开编码)
        # -------------------------------------------------------

        # A. Full Text (Context + Target) -> char_tokenizer
        # Stage 2 Decoder 需要看到的是 [CLS] Context Target [SEP]
        # 用于 Decoder 的 Self-Attention 以及 label 计算
        full_text = raw_context + raw_target
        # max_len = ctx_len + tgt_len
        full_enc = self.char_tokenizer(full_text, max_length=self.max_ctx_len + self.max_tgt_len, padding='max_length', truncation=True, return_tensors="pt")
        
        # 构造 Loss Mask (label):
        # 原始 full_ids: [CLS] c1 c2 t1 t2 [SEP] [PAD]
        # Label (shifted): c1 c2 t1 t2 [SEP] [PAD]
        # 我们希望忽略 c1 c2 (context)，只预测 t1 t2 [SEP]
        # 所以 tgt_y: [PAD] [PAD] t1 t2 [SEP] [PAD]
        
        full_ids = full_enc['input_ids'].squeeze(0)
        tgt_y = full_ids.clone()
        
        # 计算 Context 长度 (不包含 [CLS])
        # chars in context
        ctx_len = len(raw_context)
        
        # So we need to mask full_ids indices [1 ... ctx_len]
        # Note: we also usually mask [CLS] (index 0) but it is dropped by shifting anyway.
        # So masking [0 ... ctx_len] in full_ids constitutes the "Prompt" part.
        if self.stage >= 2:
            # Mask [0, ctx_len] inclusive
            # check boundary
            mask_len = 1 + ctx_len # [CLS] + context chars
            if mask_len < len(tgt_y):
                 tgt_y[:mask_len] = 0 # PAD index
        
        # C. Pinyin (拼音) -> py_tokenizer
        py_enc = self.py_tokenizer(raw_pinyin, max_length=self.max_py_len, padding='max_length', truncation=True, return_tensors="pt")
        pinyin_ids = py_enc['input_ids'].squeeze(0)
        pinyin_mask = py_enc['attention_mask'].squeeze(0)

        # 复用 Stage 1 的 full_ids 逻辑，这样 Stage 2 的 forward 也可以统一处理
        return {
            "full_ids": full_ids, # [CLS] Context Target [SEP] ...
            "tgt_y": tgt_y,       # [PAD]...[PAD] Target [SEP] ...
            "full_mask": full_enc['attention_mask'].squeeze(0),
            
            "py_ids": pinyin_ids,   # [CLS] pinyin [SEP] ...
            "py_mask": pinyin_mask,
        }


if __name__ == '__main__':
    from IMETokenizer import IMETokenizerGB2312, PinyinTokenizer

    char_tokenizer = IMETokenizerGB2312()
    py_tokenizer = PinyinTokenizer()

    sample_texts = [
        "如何正确暴打张昕贝",
        "今天天气真好",
        "我喜欢吃苹果",
        "机器学习是人工智能的一个分支"
    ]

    dataset = AdvancedIME_Dataset(sample_texts, char_tokenizer, py_tokenizer, stage=2)

    for i in range(len(dataset)):
        item = dataset[i]
        print(f"\n[样本 {i}]")
        print("Context:", item['raw_context'])
        print("Target:", item['raw_target'])
        print("Pinyin:", item['raw_pinyin'])
        print("Context IDs:", item['ctx_ids'].tolist())
        print("Target IDs:", item['tgt_ids'].tolist())
        print("Pinyin IDs:", item['py_ids'].tolist())
