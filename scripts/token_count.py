#!/usr/bin/env python3
"""本地 token 计数小工具（中转验真手册配套）。

用途：数一段文本的 token 数，与中转控制台的计费 token 对账（见 methods/02）。
- 优先用 tiktoken 计数（pip install tiktoken）；未安装时回退到字符估算，
  并明确标注为估算（估算只看量级，不能用于 5% 级对账）。
- 不联网、不需要任何密钥、不读取任何站点配置。

用法：
    python3 token_count.py "要计数的文本"
    python3 token_count.py --file prompt.txt
    cat prompt.txt | python3 token_count.py -
    python3 token_count.py --encoding o200k_base "text"

退出码：0 成功；2 参数/读取错误。
"""
import argparse
import sys


def count_with_tiktoken(text: str, encoding_name: str):
    """返回 (token 数, 方法说明)。tiktoken 不可用时返回 (None, 原因)。"""
    try:
        import tiktoken
    except ImportError:
        return None, "tiktoken 未安装"
    try:
        enc = tiktoken.get_encoding(encoding_name)
    except Exception as exc:  # 编码名不存在等
        return None, f"tiktoken 编码 {encoding_name} 不可用: {exc}"
    return len(enc.encode(text)), f"tiktoken/{encoding_name}"


def estimate_tokens(text: str):
    """无依赖估算：CJK 字符约 1 token/字，其余约 4 字符/token。仅供看量级。"""
    cjk = sum(1 for ch in text if '\u4e00' <= ch <= '\u9fff' or '\u3400' <= ch <= '\u4dbf')
    other = len(text) - cjk
    return cjk + (other + 3) // 4


def read_input(args) -> str:
    if args.file:
        with open(args.file, "r", encoding="utf-8") as fh:
            return fh.read()
    if args.text is None or args.text == "-":
        return sys.stdin.read()
    return args.text


def main() -> int:
    parser = argparse.ArgumentParser(
        description="本地 token 计数（与中转计费对账用）。文本可来自参数、--file 或标准输入（-）。")
    parser.add_argument("text", nargs="?", default=None,
                        help="要计数的文本；省略或传 - 时从标准输入读")
    parser.add_argument("--file", metavar="PATH", help="从文件读取文本")
    parser.add_argument("--encoding", default="cl100k_base",
                        help="tiktoken 编码（默认 cl100k_base；GPT-4o 系可用 o200k_base）")
    args = parser.parse_args()

    if args.file and args.text:
        print("错误：--file 与文本参数只能二选一", file=sys.stderr)
        return 2
    try:
        text = read_input(args)
    except OSError as exc:
        print(f"错误：读取输入失败：{exc}", file=sys.stderr)
        return 2

    tokens, method = count_with_tiktoken(text, args.encoding)
    chars = len(text)
    if tokens is None:
        est = estimate_tokens(text)
        print(f"chars: {chars}")
        print(f"tokens: ~{est} （估算，{method}；装 tiktoken 后可精确计数：pip install tiktoken）")
        print("注意：估算只看量级，不能用于 5% 级对账。", file=sys.stderr)
    else:
        print(f"chars: {chars}")
        print(f"tokens: {tokens} （{method}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
