#!/usr/bin/env bash
# cfst-ddns —— 用 CloudflareSpeedTest 选出最快的 CF IP，更新到 Cloudflare 上的一条 DNS 记录
# 由 systemd 调度（cfst-ddns.service + cfst-ddns.timer），配置在 /etc/cfst-ddns.env
#
# 联网情况：
#   cfst     直接连各个 CF IP（不解析域名），必须直连 → sing-box TUN 里 exclude_uid 放行
#   curl     api.cloudflare.com、api.telegram.org（需要解析域名）→ 可经 API_PROXY 走代理
set -euo pipefail

: "${CF_API_TOKEN:?缺少 CF_API_TOKEN}"
: "${CF_ZONE_ID:?缺少 CF_ZONE_ID}"
: "${CF_RECORD_NAME:?缺少 CF_RECORD_NAME}"
CFST_DIR="${CFST_DIR:-/opt/cfst-ddns}"
CFST_IPFILE="${CFST_IPFILE:-$CFST_DIR/ip.txt}"
CFST_ARGS="${CFST_ARGS:--tl 250 -dn 10 -dt 5}"
CF_TTL="${CF_TTL:-60}"
MIN_SPEED="${MIN_SPEED:-0}"              # MB/s；最快 IP 低于此值就不更新
LATENCY_SPLIT="${LATENCY_SPLIT:-0}"      # ms；>0 时按这个延迟把候选分成两段，各取几个做下载测速
PICK_PER_GROUP="${PICK_PER_GROUP:-5}"    # 分段时每段取几个
PROGRESS_EVERY="${PROGRESS_EVERY:-15}"   # 测速期间每隔多少秒往日志打一次进度
API_PROXY="${API_PROXY:-}"               # curl 用的代理，如 socks5h://127.0.0.1:2080；留空则直连
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
TG_NOTIFY="${TG_NOTIFY:-all}"            # all=每次都发  change=只在 IP 变化或失败时发  off=不发
WORK="${STATE_DIRECTORY:-$(mktemp -d)}"  # systemd 下是 /var/lib/cfst-ddns
API="https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records"

CURL_BASE=(-sS --retry 2 --retry-delay 3 --connect-timeout 10 -m 30)
[[ -n "$API_PROXY" ]] && CURL_BASE+=(-x "$API_PROXY")

# 运行状态，结束时用来写日志和 Telegram 简报
KIND=""; REASON=""; IP=""; OLD_IP=""; LAT=""; LOSS=""; SPEED=""; GROUP=""; PID=""; t=0

# ---------- Telegram 简报（MarkdownV2） ----------
md()   { sed 's/[][_*()~`>#+=|{}.!\\-]/\\&/g' <<<"$1"; }        # 普通文本转义
code() { local s=${1//\\/\\\\}; printf '`%s`' "${s//\`/\\\`}"; }  # 行内代码

notify() {
  [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" && "$TG_NOTIFY" != off ]] || return 0
  [[ "$TG_NOTIFY" == change && "$KIND" == unchanged ]] && return 0

  local head msg top resp
  case "$KIND" in
    updated)   head="✅ *CF 优选 IP 已更新*" ;;
    unchanged) head="☑️ *CF 优选 IP 无变化*" ;;
    *)         head="❌ *CF 优选 IP 更新失败*" ;;
  esac
  msg="$head"$'\n\n'"$(md "域名：")$(code "$CF_RECORD_NAME")"
  case "$KIND" in
    updated)   msg+=$'\n'"$(md "IP：")$(code "${OLD_IP:-新建}") → $(code "$IP")" ;;
    unchanged) msg+=$'\n'"$(md "IP：")$(code "$IP")" ;;
    *)         msg+=$'\n'"$(md "原因：$REASON")"
               [[ -n "$OLD_IP" ]] && msg+=$'\n'"$(md "当前解析：")$(code "$OLD_IP")" ;;
  esac
  [[ -n "$IP" ]] && msg+=$'\n'"$(md "延迟 ${LAT} ms${GROUP:+（$GROUP）} · 丢包 ${LOSS} · 下载 ${SPEED} MB/s")"
  if [[ -s "$WORK/result.csv" ]]; then
    top=$(awk -F, -v s="$LATENCY_SPLIT" 'NR>1 && NR<=6 {
      g = (s+0>0) ? (($5+0 < s+0) ? "  <" s : "  ≥" s) : ""
      printf "%-16s %7sms %6sMB/s%s\n", $1, $5, $6, g }' "$WORK/result.csv")
    top=${top//\\/\\\\}; top=${top//\`/\\\`}
    [[ -n "$top" ]] && msg+=$'\n\n'"*前 5 名*"$'\n```\n'"$top"$'\n```'
  fi
  msg+=$'\n'"_$(md "$(cat /proc/sys/kernel/hostname) · 用时 ${t}s · $(date '+%m-%d %H:%M')")_"

  resp=$(curl "${CURL_BASE[@]}" "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" --data-urlencode "text=${msg}" \
    -d parse_mode=MarkdownV2 -d disable_web_page_preview=true 2>&1) || true
  if jq -e '.ok' >/dev/null 2>&1 <<<"$resp"; then
    echo "已发送 Telegram 简报"
  else
    local why; why=$(jq -r '.description // empty' <<<"$resp" 2>/dev/null) || true
    echo "警告: Telegram 发送失败: ${why:-${resp:0:200}}" >&2
  fi
}

# ---------- 收尾：无论成功失败都走这里 ----------
die() { REASON="$*"; echo "失败: $*" >&2; exit 1; }
finish() {
  local rc=$?
  [[ -n "$PID" ]] && kill "$PID" 2>/dev/null
  if [[ $rc -ne 0 ]]; then
    KIND=failed
    [[ -n "$REASON" ]] || REASON="脚本异常退出（退出码 $rc），详见 journalctl -u cfst-ddns"
  fi
  notify || true
}
trap finish EXIT
trap 'REASON="被终止（超时或手动停止）"; exit 143' TERM INT

# cf 方法 URL [JSON] —— 调 Cloudflare API，结果放在全局变量 RESP；success 不为 true 就失败
cf() {
  local args=("${CURL_BASE[@]}" -X "$1" "$2"
    -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")
  [[ $# -ge 3 ]] && args+=(--data "$3")
  RESP=$(curl "${args[@]}" 2>&1) || die "连不上 Cloudflare API：${RESP:0:200}"
  jq -e '.success' >/dev/null 2>&1 <<<"$RESP" \
    || die "Cloudflare API 返回错误：$(jq -c '.errors' <<<"$RESP" 2>/dev/null || echo "${RESP:0:200}")"
}

# cfst 不在终端里时，进度帧之间没有换行，首尾相连写进 cfst.log。
# 这里从日志里解析出当前阶段和进度，翻译成一行人话给 journal。
progress() {
  local log tail phase cur avail hdr lim queue
  log=$(sed 's/\x1b\[[0-9;]*m//g' cfst.log 2>/dev/null) || true
  phase=$(grep -aoE '开始(延迟|下载)测速' <<<"$log" | tail -n1) || true
  tail=$(tail -c 2000 <<<"$log")
  if [[ -n "$phase" ]]; then tail="${tail##*"$phase"}"; fi   # 只看当前阶段，别读到上一阶段的残留
  cur=$(grep -aoE '[0-9]+ / [0-9]+ \[' <<<"$tail" | tail -n1 | tr -d ' [') || true
  case "$phase" in
    开始延迟测速)
      avail=$(grep -aoE '可用: *[0-9]+' <<<"$tail" | tail -n1 | grep -oE '[0-9]+') || true
      echo "  [${1}s] 延迟测速：已测 ${cur:-0/?} 个 IP，延迟合格 ${avail:-0} 个" ;;
    开始下载测速)
      # 标题形如：开始下载测速（下限：5.00 MB/s, 数量：3, 队列：1717）
      hdr=$(grep -aoE '开始下载测速.{0,80}' <<<"$log" | tail -n1) || true
      lim=$(grep -aoE '下限：[0-9.]+' <<<"$hdr" | grep -oE '[0-9.]+$') || true
      queue=$(grep -aoE '队列：[0-9]+' <<<"$hdr" | grep -oE '[0-9]+$') || true
      if awk -v l="${lim:-0}" 'BEGIN{exit !(l+0>0)}'; then
        echo "  [${1}s] 下载测速：已找到 ${cur:-0/?} 个 ≥${lim}MB/s 的 IP（在 ${queue:-?} 个候选里按延迟逐个测，凑够才结束）"
      else
        echo "  [${1}s] 下载测速：已测 ${cur:-0/?} 个 IP"
      fi ;;
    *) echo "  [${1}s] 准备中" ;;
  esac
}
cfst_tail() { tail -c 1500 cfst.log | tr '\r' '\n' | sed 's/\x1b\[[0-9;]*m//g' | tail -n 5 | cut -c1-300; }

# run_cfst 输出文件 cfst参数...  —— 后台跑 cfst，定时打进度，出错就退出
run_cfst() {
  local out=$1; shift
  rm -f "$out"
  "$CFST_DIR/cfst" "$@" -o "$out" -p 0 >cfst.log 2>&1 &
  PID=$!
  while kill -0 "$PID" 2>/dev/null; do
    sleep 1; t=$((t + 1))
    if (( t % PROGRESS_EVERY == 0 )); then progress "$t"; fi
  done
  if ! wait "$PID"; then PID=""; cfst_tail >&2; die "cfst 运行出错"; fi
  PID=""
}

# 给 IP 标上所在的延迟段，例如 "<150ms 段"
group_of() { awk -v l="$1" -v s="$LATENCY_SPLIT" 'BEGIN{ if (s+0>0) printf (l+0<s+0 ? "<%sms 段" : "≥%sms 段"), s }'; }

# ---------- 1. 测速 ----------
cd "$WORK"
rm -f result.csv latency.csv candidates.txt
read -ra ARGS <<<"$CFST_ARGS"

if awk -v s="$LATENCY_SPLIT" 'BEGIN{exit !(s+0>0)}' && [[ " $CFST_ARGS " != *" -dd "* ]]; then
  # 分段模式：先只测延迟，再从 "低于 LATENCY_SPLIT" 和 "不低于" 两段各取 PICK_PER_GROUP 个做下载测速。
  # 例如低延迟段走香港、高延迟段走美国：高峰期香港拥堵时自然选美国，闲时香港更快就选香港。
  echo "第 1 步 延迟测速: cfst $CFST_ARGS -dd"
  run_cfst latency.csv "${ARGS[@]}" -f "$CFST_IPFILE" -dd
  [[ -s latency.csv && $(wc -l < latency.csv) -ge 2 ]] || die "延迟测速没有结果（全部超出延迟/丢包条件？）"
  # cfst 的结果已按 丢包率、延迟 从低到高排好，每段取前 N 个即可
  tail -n +2 latency.csv | awk -F, -v s="$LATENCY_SPLIT" -v k="$PICK_PER_GROUP" \
    '{ if ($5+0 < s+0) { if (lo++ < k) print $1 } else { if (hi++ < k) print $1 } }' > candidates.txt
  read -r NLO NHI < <(tail -n +2 latency.csv | awk -F, -v s="$LATENCY_SPLIT" \
    '{ if ($5+0 < s+0) a++; else b++ } END { print a+0, b+0 }')
  N=$(wc -l < candidates.txt)
  echo "  延迟合格 $((NLO + NHI)) 个：<${LATENCY_SPLIT}ms 段 ${NLO} 个，≥${LATENCY_SPLIT}ms 段 ${NHI} 个"
  echo "第 2 步 下载测速: 每段取 ${PICK_PER_GROUP} 个，共 ${N} 个候选"
  run_cfst result.csv "${ARGS[@]}" -f candidates.txt -dn "$N"
else
  echo "开始测速: cfst $CFST_ARGS"
  run_cfst result.csv "${ARGS[@]}" -f "$CFST_IPFILE"
fi
echo "测速完成，用时 ${t}s"

if ! [[ -s result.csv && $(wc -l < result.csv) -ge 2 ]]; then
  [[ " $CFST_ARGS " == *" -sl "* ]] && die "测速没有结果：没有任何 IP 达到 -sl 下载速度下限（用了 -sl 时，一个都不达标 cfst 就不输出结果）"
  die "测速没有结果（全部超出延迟/丢包条件？）"
fi
echo "前几名（IP / 延迟ms / 丢包 / 下载MB/s）："
awk -F, -v s="$LATENCY_SPLIT" 'NR>1 && NR<=11 {
  g = (s+0>0) ? (($5+0 < s+0) ? "  <" s "ms" : "  ≥" s "ms") : ""
  printf "  %-16s %8s %6s %8s%s\n", $1, $5, $4, $6, g }' result.csv
IFS=, read -r IP _ _ LOSS LAT SPEED _ < <(sed -n 2p result.csv) || true
IP="${IP:-}"; LOSS="${LOSS:-?}"; LAT="${LAT:-?}"; SPEED="${SPEED:-0}"; SPEED="${SPEED%$'\r'}"
[[ -n "$IP" ]] || die "测速没有结果（全部超出延迟/丢包条件？）"
GROUP=$(group_of "$LAT")
echo "最快: $IP  延迟 ${LAT}ms${GROUP:+（$GROUP）}  丢包 $LOSS  下载 ${SPEED}MB/s"

# 兜底底线：结果已按速度排好序，第一名就是测过的里面最快的，正常情况直接用它。
# 只有连第一名都低于 MIN_SPEED（或为 0，多半是测速地址挂了）时才不动现有解析。
if [[ " $CFST_ARGS " != *" -dd "* ]]; then
  if awk -v s="$SPEED" 'BEGIN{exit !(s+0<=0)}'; then
    die "下载速度为 0（测速地址可能不可用，可用 -url 换一个），保留现有解析"
  elif awk -v s="$SPEED" -v m="$MIN_SPEED" 'BEGIN{exit !(s+0<m+0)}'; then
    die "最快的也只有 ${SPEED} MB/s，低于底线 MIN_SPEED=${MIN_SPEED}，保留现有解析"
  fi
fi

# ---------- 2. 更新 DNS ----------
[[ "$IP" == *:* ]] && TYPE=AAAA || TYPE=A
echo "查询当前解析: $CF_RECORD_NAME ($TYPE)${API_PROXY:+，经代理 $API_PROXY}"
cf GET "${API}?type=${TYPE}&name=${CF_RECORD_NAME}"
REC_ID=$(jq -r '.result[0].id // empty' <<<"$RESP")
OLD_IP=$(jq -r '.result[0].content // empty' <<<"$RESP")

if [[ "$OLD_IP" == "$IP" ]]; then
  KIND=unchanged
  echo "解析已是 $IP，无需更新"
  exit 0
fi

BODY=$(jq -nc --arg t "$TYPE" --arg n "$CF_RECORD_NAME" --arg c "$IP" --argjson ttl "$CF_TTL" \
  '{type:$t, name:$n, content:$c, ttl:$ttl, proxied:false}')
if [[ -n "$REC_ID" ]]; then cf PATCH "$API/$REC_ID" "$BODY"; else cf POST "$API" "$BODY"; fi
KIND=updated
echo "已更新 $CF_RECORD_NAME ($TYPE): ${OLD_IP:-<新建>} -> $IP"
