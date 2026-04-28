# -*- coding: utf-8 -*-
import torch
import torch.nn as nn
import math


class PositionalEncoding(nn.Module):
    def __init__(self, d_model, max_len=512):
        super().__init__()
        pe = torch.zeros(max_len, d_model)
        position = torch.arange(0, max_len, dtype=torch.float).unsqueeze(1)
        div_term = torch.exp(torch.arange(0, d_model, 2).float() * (-math.log(10000.0) / d_model))
        pe[:, 0::2] = torch.sin(position * div_term)
        pe[:, 1::2] = torch.cos(position * div_term)
        self.register_buffer('pe', pe.unsqueeze(0))

    def forward(self, x):
        return x + self.pe[:, :x.size(1), :]


class PinyinTransformer(nn.Module):  # d_model是Transformer的隐藏维度，nhead是多头注意力机制中的头数，num_layers是编码器和解码器的层数
    def __init__(self, char_vocab_size, pinyin_vocab_size, d_model=256, nhead=8, num_layers=3):
        super().__init__()
        self.d_model = d_model

        # 拆分 Embedding：拼音和汉字使用不同的词表
        # char_vocab_size: 汉字词表大小 (约6000) + 特殊符号 ([CLS], [SEP], [PAD]) + 英文字符
        # pinyin_vocab_size: 拼音字符大小 (a-z + 特殊符号, 约30-40)
        self.char_embedding = nn.Embedding(char_vocab_size, d_model, padding_idx=0)
        self.pinyin_embedding = nn.Embedding(pinyin_vocab_size, d_model, padding_idx=0)

        self.pos_encoder = PositionalEncoding(d_model)

        # 关键修改 1：将 nn.Transformer 拆解为 Encoder 和 Decoder 独立模块
        encoder_layer = nn.TransformerEncoderLayer(d_model=d_model, nhead=nhead, dim_feedforward=d_model*4, batch_first=True, norm_first=True)
        self.transformer_encoder = nn.TransformerEncoder(encoder_layer, num_layers=num_layers)

        decoder_layer = nn.TransformerDecoderLayer(d_model=d_model, nhead=nhead, dim_feedforward=d_model*4, batch_first=True, norm_first=True)
        self.transformer_decoder = nn.TransformerDecoder(decoder_layer, num_layers=num_layers)

        self.fc_out = nn.Linear(d_model, char_vocab_size)

        # 初始化 Encoder 和 Cross-Attention 权重，防止 Stage 2 梯度爆炸
        self._init_encoder_weights()

    def _init_encoder_weights(self):
        """对 Encoder 和 Decoder Cross-Attention 做 Xavier 初始化，降低初始激活值方差"""
        for p in self.transformer_encoder.parameters():
            if p.dim() > 1:
                nn.init.xavier_uniform_(p)
        for layer in self.transformer_decoder.layers:
            for p in layer.multihead_attn.parameters():
                if p.dim() > 1:
                    nn.init.xavier_uniform_(p)
        nn.init.xavier_uniform_(self.fc_out.weight)

    '''
    def generate_square_subsequent_mask(self, sz, device):  # sz 是目标序列的长度，device 是设备类型（如 'cuda' 或 'cpu'）
        mask = (torch.triu(torch.ones((sz, sz), device=device)) == 1).transpose(0, 1)   # triu 生成一个上三角矩阵，transpose 转置后得到下三角矩阵
        mask = mask.float().masked_fill(mask == 0, float('-inf')).masked_fill(mask == 1, float(0.0))    # 将下三角部分（允许关注的部分）设置为 0，上三角部分（禁止关注的部分）设置为 -inf，这样在 softmax 中就会被忽略
        return mask
    '''

    def generate_square_subsequent_mask(self, sz, device):
        # 生成 bool 类型的因果掩码，True 表示该位置需要被屏蔽（不可关注未来位置）
        # 与 key_padding_mask 的 bool 类型保持一致，避免 type mismatch 警告
        return torch.triu(torch.ones(sz, sz, device=device, dtype=torch.bool), diagonal=1)

    # ==========================================
    # 阶段一专用：纯 Decoder 预训练模式
    # ==========================================
    # ==========================================
    # 阶段一专用：纯 Decoder 预训练模式
    # ==========================================
    def forward_decoder_only(self, tgt, tgt_key_padding_mask=None):
        """
        仅训练 Decoder 的语言模型能力。
        技巧：构造一个全零的 memory 给 Cross-Attention，
        迫使模型忽略 Cross-Attention，只依赖 Self-Attention 学习汉字接龙。
        """
        # 1. 汉字 Embedding + Positional Encoding
        tgt_emb = self.char_embedding(tgt) * math.sqrt(self.d_model)
        tgt_emb = self.pos_encoder(tgt_emb)

        # 2. 生成掩码
        tgt_mask = self.generate_square_subsequent_mask(tgt.size(1), tgt.device)
        
        # tgt_key_padding_mask: (B, L), True where pad.
        # If input is None, no padding mask.
        
        # 3. 构造“安慰剂” Memory (全零)
        # 形状必须是 (Batch_Size, 1, d_model)，让 Cross-Attention 算出来的全是 0
        dummy_memory = torch.zeros(tgt.size(0), 1, self.d_model, device=tgt.device)

        # 4. 只跑 Decoder
        # memory_key_padding_mask 不需要，因为 memory 全是 0，没有意义
        out = self.transformer_decoder(
            tgt=tgt_emb,
            memory=dummy_memory,
            tgt_mask=tgt_mask,
            tgt_key_padding_mask=tgt_key_padding_mask
        )

        return self.fc_out(out)

    # ==========================================
    # 阶段二专用：完整的 Seq2Seq 模式
    # ==========================================
    def forward(self, src, tgt, src_key_padding_mask=None, tgt_key_padding_mask=None):
        """
        Standards Encoder-Decoder Forward.
        src_key_padding_mask: (B, S), True for PAD
        tgt_key_padding_mask: (B, T), True for PAD
        """
        # 1. 处理 Encoder (拼音端)
        src_emb = self.pinyin_embedding(src) * math.sqrt(self.d_model)
        src_emb = self.pos_encoder(src_emb)

        # 得到包含拼音特征的 Memory
        memory = self.transformer_encoder(src_emb, src_key_padding_mask=src_key_padding_mask)

        # 2. 处理 Decoder (汉字端)
        tgt_emb = self.char_embedding(tgt) * math.sqrt(self.d_model)
        tgt_emb = self.pos_encoder(tgt_emb)

        tgt_mask = self.generate_square_subsequent_mask(tgt.size(1), tgt.device)

        # 3. 联合解码
        out = self.transformer_decoder(
            tgt=tgt_emb,
            memory=memory,
            tgt_mask=tgt_mask,
            tgt_key_padding_mask=tgt_key_padding_mask,
            memory_key_padding_mask=src_key_padding_mask # 关键：让 Decoder 知道拼音里哪些是填充符，不要看
        )

        return self.fc_out(out)
