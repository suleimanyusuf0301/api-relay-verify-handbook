#!/usr/bin/env bash
# 缓存命中探针（中转验真手册配套，见 methods/03）
#
# 作用：对一个 OpenAI 兼容接口连发两次「完全相同」的长 prompt，
#       打印两次响应的 usage 字段，对比第二次的 cached_tokens 是否 > 0。
#
# 配置只走环境变量，脚本内不硬编码任何站点 / 密钥，也不会打印密钥：
#   RELAY_BASE_URL   接入地址，如 https://your-relay.example.com （不要带末尾 /）
#   RELAY_API_KEY    你的密钥，如 sk-xxxx（只从环境变量读）
#   RELAY_MODEL      要测的模型名（用服务商列表里的确切名称）
#
# 用法：
#   export RELAY_BASE_URL="https://your-relay.example.com"
#   export RELAY_API_KEY="sk-xxxx"
#   export RELAY_MODEL="your-model-name"
#   ./cache_probe.sh                    # 用脚本内置的示例长文本
#   ./cache_probe.sh --file prompt.txt  # 用你自己的长文本（建议 >=2000 token）
#
# 退出码：0 两次请求都完成；2 缺配置/参数错误；3 请求或解析失败。
set -u

PROMPT_FILE=""

usage() {
  tail -n +2 "$0" | grep '^#' | sed 's/^# \{0,1\}//' | head -n 22
}

while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      [ $# -ge 2 ] || { echo "错误：--file 后要跟文件路径" >&2; exit 2; }
      PROMPT_FILE="$2"; shift 2 ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      echo "错误：未知参数 $1（看 --help）" >&2; exit 2 ;;
  esac
done

missing=""
[ -n "${RELAY_BASE_URL:-}" ] || missing="$missing RELAY_BASE_URL"
[ -n "${RELAY_API_KEY:-}" ]  || missing="$missing RELAY_API_KEY"
[ -n "${RELAY_MODEL:-}" ]    || missing="$missing RELAY_MODEL"
if [ -n "$missing" ]; then
  echo "错误：缺少环境变量:$missing" >&2
  echo "示例：" >&2
  echo '  export RELAY_BASE_URL="https://your-relay.example.com"' >&2
  echo '  export RELAY_API_KEY="sk-xxxx"' >&2
  echo '  export RELAY_MODEL="your-model-name"' >&2
  exit 2
fi

command -v curl    >/dev/null 2>&1 || { echo "错误：需要 curl" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "错误：需要 python3（用于组装/解析 JSON）" >&2; exit 2; }

if [ -n "$PROMPT_FILE" ]; then
  [ -f "$PROMPT_FILE" ] || { echo "错误：文件不存在：$PROMPT_FILE" >&2; exit 2; }
  PROMPT_TEXT="$(cat "$PROMPT_FILE")"
else
  # 内置示例长文本：同一段落重复拼接成约数千 token，保证达到常见缓存门槛。
  SEGMENT="缓存验证说明：本段文本用于缓存命中探针。同一段足够长的文本在短时间内被重复发送时，服务端应将前缀写入缓存并在第二次请求中命中读取，从而降低计费。判读时只看响应 usage 中缓存字段是否为非零，以及第二次费用是否明显下降。文本内容本身没有意义，重要的是两次请求一字不差。"
  PROMPT_TEXT="$SEGMENT"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    PROMPT_TEXT="$PROMPT_TEXT$SEGMENT"
  done
  PROMPT_TEXT="${PROMPT_TEXT}问题：用一句话概括上面这段话在说什么。"
fi

# 用 python3 组装请求体，避免长文本/中文的转义问题。密钥不进请求文件以外的任何输出。
REQ_BODY="$(mktemp)"
trap 'rm -f "$REQ_BODY"' EXIT
PROMPT_TEXT="$PROMPT_TEXT" RELAY_MODEL="$RELAY_MODEL" python3 - "$REQ_BODY" <<'PYEOF'
import json, os, sys
body = {
    "model": os.environ["RELAY_MODEL"],
    "messages": [{"role": "user", "content": os.environ["PROMPT_TEXT"]}],
    "max_tokens": 64,
    "temperature": 0,
}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(body, fh, ensure_ascii=False)
PYEOF
[ -s "$REQ_BODY" ] || { echo "错误：请求体组装失败" >&2; exit 3; }

ENDPOINT="${RELAY_BASE_URL%/}/v1/chat/completions"

send_once() {
  curl -sS --max-time 120 -X POST "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${RELAY_API_KEY}" \
    --data @"$REQ_BODY"
}

print_usage() {
  # $1 = 响应 JSON，$2 = 第几次。经临时文件传给 python，避免引号/转义问题。
  local resp_file
  resp_file="$(mktemp)"
  printf '%s' "$1" > "$resp_file"
  python3 - "$resp_file" "$2" <<'PYEOF'
import json, sys
path, label = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    raw = fh.read()
try:
    data = json.loads(raw)
except Exception:
    print(f"[{label}] 响应不是 JSON（前 300 字符）：{raw[:300]}")
    sys.exit(3)
if data.get("error"):
    print(f"[{label}] 接口返回 error：{json.dumps(data['error'], ensure_ascii=False)[:300]}")
    sys.exit(3)
usage = data.get("usage") or {}
details = usage.get("prompt_tokens_details") or {}
cached = details.get("cached_tokens",
                     usage.get("cache_read_input_tokens", "（响应未给缓存字段）"))
print(f"[{label}] prompt_tokens={usage.get('prompt_tokens')} "
      f"completion_tokens={usage.get('completion_tokens')} "
      f"cached_tokens={cached}")
PYEOF
  local rc=$?
  rm -f "$resp_file"
  return $rc
}

echo "接口：$ENDPOINT"
echo "模型：$RELAY_MODEL（密钥已从 RELAY_API_KEY 读取，不显示）"
echo "--- 第一次请求（写缓存）---"
RESP1="$(send_once)" || { echo "错误：第一次请求网络失败" >&2; exit 3; }
print_usage "$RESP1" "1st" || exit 3
echo "--- 第二次请求（应命中缓存，间隔 2 秒）---"
sleep 2
RESP2="$(send_once)" || { echo "错误：第二次请求网络失败" >&2; exit 3; }
print_usage "$RESP2" "2nd" || exit 3
echo "判读：第二次 cached_tokens > 0 且费用在控制台明显下降 = 通过；多次恒为 0 = 红旗（见 methods/03-cache-check.md）。"
