# -*- coding: utf-8 -*-
import torch


class IMETokenizerGB2312:  # INPUT METHOD EDITOR Tokenizer
    def __init__(self):
        self.pad_token = '[PAD]'  # 用于填充，使得输入序列达到指定长度
        self.unk_token = '[UNK]'  # 用于表示词表中没有的字符，确保模型能够处理任何输入
        self.cls_token = '[CLS]'  # 用于标记输入序列的开始，方便模型区分不同输入
        self.sep_token = '[SEP]'  # 用于标记输入序列的结束，帮助模型理解输入边界

        # 1. 初始化特殊 Token
        tokens = [self.pad_token, self.unk_token, self.cls_token, self.sep_token]

        # 2. 基础 ASCII：包含大小写字母 a-z, A-Z, 数字 0-9 以及基本标点 (区段 32 到 126)
        # 这确保了模型能够输入和输出任何英文、数字组合 (如 win10, macOS)
        tokens.extend([chr(i) for i in range(32, 127)])

        # 3. 动态生成 GB2312 简体中文字符表 (6763个汉字)
        tokens.extend(self._generate_gb2312_chars())

        # 4. 去重并构建双向映射表
        self.vocab = list(dict.fromkeys(tokens))
        self.v2i = {char: idx for idx, char in enumerate(self.vocab)}
        self.i2v = {idx: char for idx, char in enumerate(self.vocab)}

        self.vocab_size = len(self.vocab)
        self.pad_token_id = self.v2i[self.pad_token]
        self.unk_token_id = self.v2i[self.unk_token]
        self.cls_token_id = self.v2i[self.cls_token]
        self.sep_token_id = self.v2i[self.sep_token]

        print(f"Tokenizer initialized. vocab_size={self.vocab_size}")  # 大约 6865

    def _generate_gb2312_chars(self):
        """利用 Python 底层字节解码，遍历提取所有 GB2312 汉字"""
        chars = []
        # GB2312 汉字区：16-87区，每区94个字符
        for qu in range(16, 88):
            for wei in range(1, 95):
                try:
                    # 区位码转内码：区码和位码各加上 0xA0
                    b = bytes([qu + 0xA0, wei + 0xA0])
                    chars.append(b.decode('gb2312'))
                except UnicodeDecodeError:
                    pass  # 跳过空缺或无法解码的冷僻字位
        return chars

    def __call__(self, text, max_length=None, padding='max_length', truncation=True, return_tensors="pt"):
        """模拟 HuggingFace Tokenizer 的调用接口，方便直接接入你现有的代码"""
        if "[SEP]" in text:
            parts = text.split("[SEP]")
            context_chars = list(parts[0].strip())
            pinyin_chars = list(parts[1].strip())

            input_ids = [self.cls_token_id] + \
                        [self.v2i.get(c, self.unk_token_id) for c in context_chars] + \
                        [self.sep_token_id] + \
                        [self.v2i.get(c, self.unk_token_id) for c in pinyin_chars] + \
                        [self.sep_token_id]
        else:
            # 容易犯错的点，如果没有上面的if [SEP]会被直接干成文本碎片
            input_ids = [self.cls_token_id] + [self.v2i.get(c, self.unk_token_id) for c in text] + [self.sep_token_id]

        if truncation and max_length is not None:
            input_ids = input_ids[:max_length]
            if input_ids[-1] != self.sep_token_id:
                input_ids[-1] = self.sep_token_id

        attention_mask = [1] * len(input_ids)

        if padding == 'max_length' and max_length is not None:
            pad_len = max_length - len(input_ids)
            if pad_len > 0:
                input_ids.extend([self.pad_token_id] * pad_len)
                attention_mask.extend([0] * pad_len)

        if return_tensors == "pt":
            return {
                "input_ids": torch.tensor([input_ids], dtype=torch.long),
                "attention_mask": torch.tensor([attention_mask], dtype=torch.long)
            }
        return {"input_ids": input_ids, "attention_mask": attention_mask}

    def decode(self, token_ids):
        """将 ID 转回文本，并自动滤除特殊 Token"""
        chars = []
        for tid in token_ids:
            if tid in [self.pad_token_id, self.cls_token_id, self.sep_token_id]:
                continue
            chars.append(self.i2v.get(tid, ''))
        return "".join(chars)


class PinyinTokenizer:
    """
    专用于拼音输入法 Encoder 端的极简分词器。
    只包含：[PAD], [UNK], [CLS], [SEP], a-z, A-Z, 数字, 以及常见符号。
    词表极小 (约100个)，计算效率极高。
    """

    def __init__(self):
        # 1. 定义特殊 Token
        self.pad_token = '[PAD]'
        self.unk_token = '[UNK]'
        self.cls_token = '[CLS]'
        self.sep_token = '[SEP]'

        # 2. 构建基础字符集
        # 包含：
        # - 小写 a-z (拼音主力)
        # - 大写 A-Z (英文缩写、首字母)
        # - 数字 0-9 (输入法有时候会带数字选词，或者型号如 win10)
        # - 常用符号 (C++, #, @, ., _, - 等)
        # 这里的范围覆盖了 ASCII 可打印字符 (32-126)，完全满足 "C++" 这种需求
        chars = [chr(i) for i in range(32, 127)]

        # 3. 组合词表
        # 顺序很重要：0=PAD, 1=UNK, 2=CLS, 3=SEP
        self.vocab = [self.pad_token, self.unk_token, self.cls_token, self.sep_token] + chars

        # 4. 构建映射字典
        self.char2idx = {char: idx for idx, char in enumerate(self.vocab)}
        self.idx2char = {idx: char for idx, char in enumerate(self.vocab)}

        self.vocab_size = len(self.vocab)
        self.pad_token_id = self.char2idx[self.pad_token]
        self.unk_token_id = self.char2idx[self.unk_token]
        self.cls_token_id = self.char2idx[self.cls_token]
        self.sep_token_id = self.char2idx[self.sep_token]

        print(f"Pinyin tokenizer initialized. vocab_size={self.vocab_size} (ASCII)")

    def __call__(self, text, max_length=None, padding='max_length', truncation=True, return_tensors="pt"):
        """
        输入: "zuijinzhengzaixueC++"
        输出: {'input_ids': tensor([[2, 36, ..., 3]]), 'attention_mask': ...}
        """
        # 1. 将字符串转为字符列表
        # list("abc") -> ['a', 'b', 'c']
        # 这一步非常快，是 Python 底层优化的
        chars = list(text)

        # 2. 转换为 ID 序列，加上 [CLS] 和 [SEP]
        input_ids = [self.cls_token_id] + \
                    [self.char2idx.get(c, self.unk_token_id) for c in chars] + \
                    [self.sep_token_id]

        # 3. 截断 (Truncation)
        if truncation and max_length is not None:
            if len(input_ids) > max_length:
                input_ids = input_ids[:max_length]
                input_ids[-1] = self.sep_token_id  # 保证最后一位是 SEP

        # 4. 填充 (Padding)
        attention_mask = [1] * len(input_ids)
        if padding == 'max_length' and max_length is not None:
            pad_len = max_length - len(input_ids)
            if pad_len > 0:
                input_ids.extend([self.pad_token_id] * pad_len)
                attention_mask.extend([0] * pad_len)

        # 5. 返回 Tensor
        if return_tensors == "pt":
            return {
                "input_ids": torch.tensor([input_ids], dtype=torch.long),
                "attention_mask": torch.tensor([attention_mask], dtype=torch.long)
            }

        return {"input_ids": input_ids, "attention_mask": attention_mask}

    def decode(self, token_ids):
        """
        将 ID 序列还原为字符串
        输入: [2, 36, 37, 3]
        输出: "zu"
        """
        chars = []
        # 如果输入是 Tensor，转 list
        if isinstance(token_ids, torch.Tensor):
            token_ids = token_ids.tolist()

        for tid in token_ids:
            # 跳过特殊符号
            if tid in [self.pad_token_id, self.cls_token_id, self.sep_token_id]:
                continue
            chars.append(self.idx2char.get(tid, ''))  # 未知 ID 忽略

        return "".join(chars)


# --- 测试一下 ---
if __name__ == "__main__":
    tokenizer = IMETokenizerGB2312()

    # 模拟输入法混合输入
    test_str = "如何正确暴打张昕贝zxb"
    encoded = tokenizer(test_str)

    print("\n[测试] 输入文本:", test_str)
    print("[测试] Token ID:", encoded['input_ids'].tolist()[0])

    # 我们打印一下中间的 ID 分别对应什么，验证它是不是逐字符的
    for char, tid in zip(['[CLS]'] + list(test_str) + ['[SEP]'], encoded['input_ids'].tolist()[0][:9]):
        print(f"  '{char}' -> ID: {tid}")

    print("[测试] 解码还原:", tokenizer.decode(encoded['input_ids'].tolist()[0]))

    # ----
    pinyin_tokenizer = PinyinTokenizer()

    # 测试你的 Case
    sample_text = "zuijinzhengzaixueC++zhegebianchengyuyan"
    encoded = pinyin_tokenizer(sample_text)

    print("-" * 30)
    print(f"原始拼音: {sample_text}")
    print(f"Token IDs: {encoded['input_ids'][0].tolist()}")
    print(f"解码还原: {pinyin_tokenizer.decode(encoded['input_ids'][0])}")
    print("-" * 30)
