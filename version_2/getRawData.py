# -*- coding: utf-8 -*-
import re


def split_to_pure_sentences(text):
    # 正则表达式：只匹配连续的中文字符、英文字母和数字
    # [\u4e00-\u9fa5] 匹配所有常见汉字
    # a-zA-Z0-9 兼容可能出现的英文和数字
    # + 表示连续匹配
    pattern = r'[\u4e00-\u9fa5a-zA-Z0-9]+'

    # findall 会自动忽略所有不符合 pattern 的字符（即所有标点、换行、空格）
    # 并返回所有匹配成功的纯文本块列表
    pure_sentences = re.findall(pattern, text)

    # 如果有英语直接删除，保留纯中文
    pure_sentences = [s for s in pure_sentences if not re.search(r'[a-zA-Z]', s)]

    return pure_sentences


# 一行切分成一句话(\n分割)
def split_to_sentences(text):
    # 使用换行符分割文本
    sentences = text.split('\n')

    # 去除每句话的前后空白，并过滤掉空行
    sentences = [s.strip() for s in sentences if s.strip()]

    return sentences


if __name__ == '__main__':
    # --- 测试数据 ---
    raw_text = """
你去那儿竟然不喊我生气了快点给我道歉
道歉再有时间找你去
领个搓衣板去吧
我用小时签到一次可以用小时对于我这种每天晚上逛一下的感觉不错
早上刚被禁用还有一个月的路线呢禁了之后才买的另一个买了一年结果用了一下午就挂了现在用了个极速网速差的很
咬咬牙这回要全入了
干完这一票我的会员等级就要升了
    """

    result = split_to_pure_sentences(raw_text)

    # 打印结果查看
    for i, line in enumerate(result):
        print(f"[{i}]: {line}")
