#!/usr/bin/env bash
# cfst-ddns —— 定时找出最好的 Cloudflare IP，更新到 Cloudflare 上的一条 DNS 记录
# 由 systemd 调度（cfst-ddns.timer 每 5 分钟触发 cfst-ddns@auto.service），配置在 /etc/cfst-ddns.env
#
# 用法：cfst-ddns.sh [auto|check|pool|full]
#   auto   按 env 里的时间表决定这一轮做什么，不到时间就什么都不做（timer 用这个）
#   check  巡检：只测当前在用的 IP，变差了才升级为 pool
#   pool   复测榜单：重测上次全量扫描留下的榜单，选最好的；榜单全不达标才升级为 full
#   full   全量扫描：测约 6000 个 IP 的延迟，重建榜单，再测速选最好的
#
# 联网情况：
#   cfst       直接连各个 CF IP（不解析域名），必须直连 → sing-box TUN 里 exclude_uid 放行
#   上传测速   curl --resolve 直接连各个 CF IP（不解析域名），同样必须直连
#   API 请求   api.cloudflare.com、api.telegram.org（需要解析域名）→ 可经 API_PROXY 走代理
set -euo pipefail

VERSION="2026.10.22.1"
SELF=$(readlink -f "$0")
MODE_ARG="${1:-auto}"                    # 模式，可带目标：full / full:cloudfront
MODE=${MODE_ARG%%:*}
ONLY=""; [[ "$MODE_ARG" == *:* ]] && ONLY=${MODE_ARG#*:}
case "$MODE" in auto|check|pool|full|stats) ;; *) echo "失败: 用法 cfst-ddns.sh [auto|check|pool|full][:目标] 或 stats[:天数]" >&2; exit 1 ;; esac

# ---------- 多目标：TARGETS 里每个目标各自测速、各自更新一条记录 ----------
# 目标的配置 = <前缀>_XXX（如 CLOUDFRONT_RECORD_NAME）> 内置预设 > 全局的 XXX > 默认值
# cloudflare 直接用不带前缀的全局配置（兼容旧版）
TARGET_KEYS="LABEL RECORD_NAME ZONE_ID TTL IPFILE IPLIST_URL IPLIST_JQ IP_EXCLUDE IP_SAMPLE CFST_ARGS RANK_BY
  MIN_SPEED SPEED_TOLERANCE LATENCY_SPLIT PICK_PER_GROUP UPLOAD_URL UP_SECONDS FULL_AT PEAK_HOURS PEAK_EVERY
  OFFPEAK_EVERY HEALTH_RATIO SWITCH_MARGIN FULL_MIN_GAP TG_NOTIFY TG_NOTIFY_CHECK
  SEEDS_DNS SEEDS_URL SEED_PICK_PER_GROUP SEED_DOH SEED_ALLOW_OUTSIDE"
OWN_KEYS="LABEL RECORD_NAME IPFILE IPLIST_URL IPLIST_JQ IP_EXCLUDE IP_SAMPLE CFST_ARGS UPLOAD_URL SEEDS_DNS SEEDS_URL RANK_BY"   # 非 cloudflare 目标不继承全局
target_prefix() { tr 'a-z-' 'A-Z_' <<<"$1" | tr -cd 'A-Z0-9_'; }
internal_name() {
  case "$1" in
    RECORD_NAME) echo CF_RECORD_NAME ;; ZONE_ID) echo CF_ZONE_ID ;; TTL) echo CF_TTL ;;
    IPFILE) echo CFST_IPFILE ;; LABEL) echo TARGET_LABEL ;; *) echo "$1" ;;
  esac
}
# 内置预设：IP 列表来源都是各家官方发布的地址
preset() {
  case "$1:$2" in
    cloudflare:LABEL)      echo Cloudflare ;;
    cloudfront:LABEL)      echo CloudFront ;;
    cloudfront:IPLIST_URL) echo https://d7uri8nf7uskq.cloudfront.net/tools/list-cloudfront-ips ;;
    cloudfront:IPLIST_JQ)  echo '.CLOUDFRONT_GLOBAL_IP_LIST[]' ;;   # 只要边缘节点，不要 REGIONAL_EDGE
    # 中国大陆节点（宁夏/北京及国内运营商段）：海外账号的分发在这些节点上不可用，但延迟最低，会占满榜单
    cloudfront:IP_EXCLUDE) echo '^(52\.82\.|111\.13\.|116\.129\.|118\.193\.|119\.147\.|120\.52\.|120\.232\.|120\.253\.|180\.163\.|58\.254\.|36\.103\.)' ;;
    cloudfront:IP_SAMPLE)  echo 4000 ;;                              # 约 1.6 万个 /24，每次全量随机抽一部分
    fastly:LABEL)          echo Fastly ;;
    fastly:IPLIST_URL)     echo https://api.fastly.com/public-ip-list ;;
    fastly:IPLIST_JQ)      echo '.addresses[]' ;;
  esac
}
load_target() {
  local t=$1 p k var src v
  p=$(target_prefix "$t")
  for k in $TARGET_KEYS; do
    var=$(internal_name "$k"); src="${p}_${k}"
    if [[ -n "${!src+x}" ]]; then v=${!src}
    elif v=$(preset "$t" "$k") && [[ -n "$v" ]]; then :
    elif [[ "$t" != cloudflare && " $OWN_KEYS " == *" $k "* ]]; then v=""
    else continue                                       # 继承全局
    fi
    export "$var=$v"
  done
  export CFST_TARGET="$t"
}

# stats：汇总各目标的 history.csv，比较「官方扫描」和「种子」谁选出的 IP 更好
show_stats() {
  local days=$1 f since
  since=$(( $(date +%s) - days * 86400 ))
  for f in "$STATE_DIRECTORY"/*/history.csv; do
    [[ -f "$f" ]] || continue
    echo "========== $(basename "$(dirname "$f")")：最近 ${days} 天 =========="
    awk -F, -v since="$since" '
      $1 < since { next }
      { p = ($2 == 1) ? "晚高峰" : "非高峰"; lat = ($4 == "latency"); u = lat ? "ms" : "MB/s"; unit[p] = u
        n[p]++; if ($6 ~ /^种子/) pick_seed[p]++
        if ($9 != "-") { so[p] += $9; co[p]++ }
        if ($12 != "-") { ss[p] += $12; cs[p]++ }
        if ($9 != "-" && $12 != "-") { both[p]++
          if (lat ? ($12 < $9) : ($12 > $9)) { sw[p]++; win[p "|" $11]++ } else ow[p]++ } }
      END {
        split("晚高峰 非高峰", ps, " ")
        for (i = 1; i <= 2; i++) { p = ps[i]; if (!n[p]) continue
          printf "【%s】测速 %d 轮，最终选中种子 IP %d 轮\n", p, n[p], pick_seed[p]
          if (co[p]) printf "  官方扫描最佳：平均 %.2f %s（%d 轮有结果）\n", so[p] / co[p], unit[p], co[p]
          if (cs[p]) printf "  种子最佳：    平均 %.2f %s（%d 轮有结果）\n", ss[p] / cs[p], unit[p], cs[p]
          if (both[p]) printf "  同一轮里比较 %d 次：种子更好 %d 次，官方更好或持平 %d 次\n", both[p], sw[p], ow[p]
          for (k in win) { split(k, kk, "|"); sub(/^种子:/, "", kk[2]); if (kk[1] == p) printf "    种子胜出来源 %s：%d 次\n", kk[2], win[k] } }
      }' "$f"
  done
}

if [[ "$MODE" == stats ]]; then
  export STATE_DIRECTORY="${STATE_DIRECTORY:-/var/lib/cfst-ddns}"
  show_stats "${ONLY:-7}"
  exit 0
fi

if [[ -z "${CFST_TARGET:-}" ]]; then
  TARGETS="${TARGETS:-cloudflare}"; [[ -n "$ONLY" ]] && TARGETS="$ONLY"
  export STATE_DIRECTORY="${STATE_DIRECTORY:-$(mktemp -d)}"
  mkdir -p "$STATE_DIRECTORY"; cd "$STATE_DIRECTORY"
  exec 9>.lock
  flock -n 9 || { echo "另一轮测速正在进行，跳过"; exit 0; }
  # 旧版本的状态文件在根目录，挪进 cloudflare/ 子目录
  if [[ -f state && ! -e cloudflare ]]; then mkdir cloudflare; mv state pool.csv cloudflare/ 2>/dev/null || true; fi
  rc=0
  for tgt in $TARGETS; do
    ( load_target "$tgt"; exec bash "$SELF" "$MODE" ) || rc=1
  done
  exit $rc
fi

# ---------- 以下是单个目标的流程 ----------
TARGET_LABEL="${TARGET_LABEL:-$CFST_TARGET}"
need() { [[ -n "${!1:-}" ]] || { echo "失败: [$TARGET_LABEL] 缺少配置 $2" >&2; exit 1; }; }
need CF_API_TOKEN CF_API_TOKEN
need CF_ZONE_ID CF_ZONE_ID
if [[ "$CFST_TARGET" == cloudflare ]]; then need CF_RECORD_NAME CF_RECORD_NAME
else need CF_RECORD_NAME "$(target_prefix "$CFST_TARGET")_RECORD_NAME（这个目标要更新的记录）"; fi
CFST_DIR="${CFST_DIR:-/opt/cfst-ddns}"
CFST_IPFILE="${CFST_IPFILE-$CFST_DIR/ip.txt}"
CFST_ARGS="${CFST_ARGS--tl 250}"
IPLIST_URL="${IPLIST_URL:-}"; IPLIST_JQ="${IPLIST_JQ:-}"; IP_EXCLUDE="${IP_EXCLUDE:-}"; IP_SAMPLE="${IP_SAMPLE:-0}"
CF_TTL="${CF_TTL:-60}"
RANK_BY="${RANK_BY:-download}"           # download=按下载速度  upload=按上传速度  latency=只看延迟/丢包
MIN_SPEED="${MIN_SPEED:-0}"              # MB/s；选中的 IP 速度低于此值就不更新
SPEED_TOLERANCE="${SPEED_TOLERANCE:-0}"  # %；速度在最快的这个比例以内时，选延迟更低的
LATENCY_SPLIT="${LATENCY_SPLIT:-0}"      # ms；>0 时按这个延迟把候选分成两段
PICK_PER_GROUP="${PICK_PER_GROUP:-5}"    # 全量扫描时每段取几个进榜单（不分段时就是总数）
UPLOAD_URL="${UPLOAD_URL-https://speed.cloudflare.com/__up}"    # 上传测速地址，接受 POST
UP_SECONDS="${UP_SECONDS:-5}"            # 每个 IP 上传测速几秒
# 种子：第三方已经筛过的优选 IP，作为官方扫描之外的补充候选（都要在你的线路上重测）
SEEDS_DNS="${SEEDS_DNS:-}"               # 优选域名，空格分隔，解析出来的 IP 当种子
SEEDS_URL="${SEEDS_URL:-}"               # 网页/接口地址，空格分隔，抓取其中所有 IPv4 当种子
SEED_PICK_PER_GROUP="${SEED_PICK_PER_GROUP:-3}"   # 每段给种子留几个测速名额（和官方的 PICK_PER_GROUP 分开算）
SEED_ALLOW_OUTSIDE="${SEED_ALLOW_OUTSIDE:-0}"     # 1 = 不在官方网段的种子也保留（多半是第三方反代 IP），标「段外」
SEED_DOH="${SEED_DOH:-https://dns.alidns.com/resolve}"   # 解析优选域名用的 DoH（直连，避开 fakeip，拿到你所在运营商的线路）
# 调度
TIMEZONE="${TIMEZONE:-Asia/Taipei}"      # 下面所有时间按这个时区算，日志和简报里的时间也用它
FULL_AT="${FULL_AT:-18:30}"              # 每天几点全量扫描，可写多个，空格分隔
PEAK_HOURS="${PEAK_HOURS:-19-24}"        # 晚高峰时段 [开始, 结束)，留空 = 不区分
PEAK_EVERY="${PEAK_EVERY:-30}"           # 晚高峰每隔多少分钟巡检一次
OFFPEAK_EVERY="${OFFPEAK_EVERY:-120}"    # 其余时间每隔多少分钟巡检一次
HEALTH_RATIO="${HEALTH_RATIO:-70}"       # %；当前 IP 速度 ≥ 基准 × 这个比例算健康
SWITCH_MARGIN="${SWITCH_MARGIN:-20}"     # %；新 IP 比当前 IP 好这么多才切换
FULL_MIN_GAP="${FULL_MIN_GAP:-120}"      # 分钟；距上次全量扫描不到这么久，就不因榜单不达标而补扫
# 其他
PROGRESS_EVERY="${PROGRESS_EVERY:-15}"   # 测速期间每隔多少秒往日志打一次进度
API_PROXY="${API_PROXY:-}"               # API 请求用的代理，如 socks5h://127.0.0.1:2080；留空则直连
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
TG_NOTIFY="${TG_NOTIFY:-all}"            # all=每次都发  change=只在 IP 变化或失败时发  off=不发
TG_NOTIFY_CHECK="${TG_NOTIFY_CHECK:-off}"  # on=巡检结果正常时也发一条  off=不发
SONDE_URL="${SONDE_URL:-}"               # Sonde 面板的 Worker 地址，留空不上报（每次真正测速后上报一份，已脱敏）
SONDE_TOKEN="${SONDE_TOKEN:-}"
WORK="$STATE_DIRECTORY/$CFST_TARGET"     # systemd 下是 /var/lib/cfst-ddns/<目标>
API="https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records"
export TZ="$TIMEZONE"

CURL_BASE=(-sS --retry 2 --retry-delay 3 --connect-timeout 10 -m 30)
[[ -n "$API_PROXY" ]] && CURL_BASE+=(-x "$API_PROXY")

# 下载模式下 CFST_ARGS 里带了 -dd，等同于 latency 模式（兼容旧配置）
[[ "$RANK_BY" == download && " $CFST_ARGS " == *" -dd "* ]] && RANK_BY=latency
case "$RANK_BY" in
  download) METRIC="下载" ;;
  upload)   METRIC="上传" ;;
  latency)  METRIC="" ;;
  *) echo "失败: [$TARGET_LABEL] RANK_BY 只能是 download / upload / latency，当前是 \"$RANK_BY\"" >&2; exit 1 ;;
esac

mode_name() { case "$1" in check) echo 巡检 ;; pool) echo 复测榜单 ;; full) echo 全量扫描 ;; *) echo "$1" ;; esac; }

# 运行状态，结束时用来写日志和 Telegram 简报
KIND=""; REASON=""; WHY=""; PATH_DESC=""; IP=""; OLD_IP=""; LAT=""; LOSS=""; SPEED=""; GROUP=""; SRC=""; COMPARE=""
PID=""; t=0; SCAN_NOTE=""; LAT_RELAXED=""; UP_OK=0; UP_ERR=""; NOGOOD=""; NEXT=""; FASTEST=""

# ---------- 状态文件：上次全量/巡检时间、当前 IP 的基准速度 ----------
STATE="$WORK/state"
state_get() { [[ -f "$STATE" ]] && awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }' "$STATE" || true; }
state_set() {
  local kv k tmp="$STATE.tmp"
  if [[ -f "$STATE" ]]; then cp "$STATE" "$tmp"; else : > "$tmp"; fi
  for kv in "$@"; do
    k=${kv%%=*}
    awk -v k="$k" 'index($0, k "=") != 1' "$tmp" > "$tmp.2"; mv "$tmp.2" "$tmp"
    echo "$kv" >> "$tmp"
  done
  mv "$tmp" "$STATE"
}

# ---------- Telegram 简报（HTML） ----------
# 结构：标题（结果）→ 流程 → 引用块（节点与成绩，最醒目）→ 说明 → 前 5 名表格 → 可展开的参数细节 → 页脚
# 脱敏：简报里不出现 IP、域名、网址。IP 用 CF 机房代码（LAX、HKG…）区分，种子来源只标「种子」
h() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }   # HTML 转义
# 兜底：发出去之前把漏网的 IPv4、网址、常见后缀的域名替换掉
scrub() {
  sed -E -e 's#[a-zA-Z][a-zA-Z0-9+.-]*://[^ <>"）)]*#***#g' \
         -e 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?\b/***/g' \
         -e 's/\b([a-zA-Z0-9-]+\.)+(com|net|org|xyz|io|dev|app|cn|me|top|cc|co|info|cloud|site|tech|link|one|uk|jp|kr|hk|tw|us|de|fr)\b/***/g' <<<"$1"
}
src_name() { sed -E -e 's/^种子:.*\(段外\)$/种子（段外）/' -e 's/^种子:.*/种子/' <<<"$1"; }
colo_of() {     # IP → 机房代码（cfst 结果第 7 列「地区码」）
  local r cc
  r=$(row_of "$1" result.csv 2>/dev/null); [[ -n "$r" ]] || r=$(row_of "$1" latency.all.csv 2>/dev/null)
  IFS=, read -r _ _ _ _ _ _ cc _ <<<"$r"; cc=${cc%$'\r'}
  [[ -n "$cc" && "$cc" != N/A ]] && echo "$cc" || echo "?"
}

top_table() {   # 前 5 名，等宽表格；用排名 + 机房代码代替 IP，标出这次选用的和原来的
  awk -F, -v s="$LATENCY_SPLIT" -v m="$METRIC" -v pick="$IP" -v cur="$OLD_IP" -v kind="$KIND" '
    FILENAME == ARGV[1] { lab[$1] = $2; next }
    FNR == 1 { g = (s + 0 > 0) ? "   段 " : ""
               if (m != "") printf "%-2s %-2s %5s %6s%s  来源\n", "#", "机房", "ms", "MB/s", g
               else         printf "%-2s %-2s %5s %5s%s  来源\n", "#", "机房", "ms", "loss", g
               next }
    FNR <= 6 {
      cc = $7; sub(/\r$/, "", cc); if (cc == "" || cc == "N/A") cc = "?"
      g = (s + 0 > 0) ? (($5 + 0 < s + 0) ? "  <" s : "  ≥" s) : ""
      l = ($1 in lab) ? lab[$1] : "官方"
      if (l ~ /^种子/) l = (l ~ /\(段外\)$/) ? "种子（段外）" : "种子"
      mk = ""
      if (kind != "failed" && $1 == pick) mk = (pick == cur) ? "  ◀ 保持" : "  ◀ 选用"
      else if ($1 == cur) mk = "  ◀ 原"
      if (m != "") printf "%-2d %-4s %5.0f %6.2f%s  %s%s\n", FNR - 1, cc, $5, $6, g, l, mk
      else         printf "%-2d %-4s %5.0f %5s%s  %s%s\n", FNR - 1, cc, $5, $4, g, l, mk }' "$WORK/origin.map" "$WORK/result.csv" 2>/dev/null
}

notify() {
  [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" && "$TG_NOTIFY" != off ]] || return 0
  [[ "$KIND" == skip || -z "$KIND" ]] && return 0
  [[ "$KIND" == healthy && "$TG_NOTIFY_CHECK" != on ]] && return 0
  [[ "$TG_NOTIFY" == change && ( "$KIND" == unchanged || "$KIND" == healthy ) ]] && return 0

  local l msg box stat top det resp cmp brief
  l=$(h "$TARGET_LABEL")
  case "$KIND" in
    updated)   msg="🔄 <b>${l} · 优选 IP 已更新</b>" ;;
    unchanged) msg="☑️ <b>${l} · 优选 IP 无变化</b>" ;;
    healthy)   msg="🩺 <b>${l} · 巡检正常</b>" ;;
    *)         msg="❌ <b>${l} · 更新失败</b>" ;;
  esac
  [[ -n "$PATH_DESC" ]] && msg+=$'\n'"🧭 <i>$(h "$PATH_DESC")</i>"

  # 引用块：这一轮最重要的东西
  if [[ "$KIND" == failed ]]; then
    box="⚠️ <b>$(h "$REASON")</b>"
    [[ -n "$OLD_IP" ]] && box+=$'\n'"当前解析保持不变（机房 <b>$(h "$(colo_of "$OLD_IP")")</b>）"
  else
    if [[ "$KIND" == updated ]]; then
      if [[ -n "$OLD_IP" ]]; then box="🔀 机房 <b>$(h "$(colo_of "$OLD_IP")")</b>  ➜  <b>$(h "$(colo_of "$IP")")</b>"
      else box="🆕 新建解析 · 机房 <b>$(h "$(colo_of "$IP")")</b>"; fi
    else box="📍 机房 <b>$(h "$(colo_of "$IP")")</b>"; fi
    if [[ -n "$IP" ]]; then
      if [[ -n "$METRIC" ]]; then stat="⚡ <b>${METRIC} $(h "$SPEED") MB/s</b> · 🕒 $(h "$LAT") ms"
      else stat="🕒 <b>$(h "$LAT") ms</b>"; fi
      stat+="$(h "${GROUP:+（$GROUP）}") · 丢包 $(h "$LOSS")${SRC:+ · $(h "$(src_name "$SRC")")}"
      box+=$'\n'"$stat"
    fi
  fi
  msg+=$'\n'"<blockquote>${box}</blockquote>"
  [[ -n "$WHY" && "$KIND" != failed ]] && msg+=$'\n'"💡 $(h "$WHY")"
  if [[ -n "$COMPARE" && -n "$IP" && "$KIND" != healthy && "$KIND" != failed ]]; then
    cmp=$(sed 's/（[^）]*）//g' <<<"$COMPARE")             # 去掉种子来源（域名）
    msg+=$'\n'"🆚 $(h "$cmp")"
  fi

  if [[ "$KIND" != healthy && -s "$WORK/result.csv" && $(wc -l < "$WORK/result.csv") -ge 3 ]]; then
    top=$(top_table)
    [[ -n "$top" ]] && msg+=$'\n\n'"📊 <b>前 5 名</b>${METRIC:+ <i>按${METRIC}</i>}"$'\n'"<pre>$(h "$top")</pre>"
  fi

  # 细节默认折叠，点开才看；cfst 参数里的测速地址去掉
  brief=$(sed -E 's/ -url [^ ]+//' <<<"$(config_brief)")
  det="⚙️ 参数：$(h "$brief")"
  [[ -n "$SCAN_NOTE" && "$KIND" != healthy ]] && det="🔎 延迟筛选：$(h "$SCAN_NOTE")"$'\n'"$det"
  msg+=$'\n'"<blockquote expandable>${det}</blockquote>"
  msg+=$'\n'"<i>🖥 $(h "$(cat /proc/sys/kernel/hostname)") · ⏱ ${t}s · $(date '+%m-%d %H:%M') · v${VERSION}</i>"
  msg=$(scrub "$msg")

  resp=$(curl "${CURL_BASE[@]}" "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" --data-urlencode "text=${msg}" \
    -d parse_mode=HTML -d disable_web_page_preview=true 2>&1) || true
  if jq -e '.ok' >/dev/null 2>&1 <<<"$resp"; then
    echo "已发送 Telegram 简报"
    return
  fi
  local why; why=$(jq -r '.description // empty' <<<"$resp" 2>/dev/null) || true
  echo "警告: Telegram 发送失败: ${why:-${resp:0:200}}" >&2
  # 格式出错（比如某段文字没转义干净）时，去掉标签再发一次纯文本，至少别丢了这条简报
  if [[ "$why" == *"parse entities"* ]]; then
    msg=$(sed -e 's/<[^>]*>//g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g' <<<"$msg")
    curl "${CURL_BASE[@]}" "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TG_CHAT_ID}" --data-urlencode "text=${msg}" \
      -d disable_web_page_preview=true >/dev/null 2>&1 && echo "已改用纯文本重发简报"
  fi
}

# ---------- Sonde 面板上报（和简报一样脱敏：IP 换成机房代码，种子不带域名）----------
sonde_report() {
  [[ -n "$SONDE_URL" && -n "$SONDE_TOKEN" ]] || return 0
  [[ "$KIND" == skip || -z "$KIND" ]] && return 0
  local top="[]" cur="" old="" body series iv
  [[ -n "$IP" ]] && cur=$(colo_of "$IP")
  [[ -n "$OLD_IP" ]] && old=$(colo_of "$OLD_IP")
  [[ "$KIND" == failed && -z "$cur" ]] && cur=$old
  if [[ "$KIND" != healthy && -s "$WORK/result.csv" ]]; then
    top=$(awk -F, -v s="$LATENCY_SPLIT" -v pick="$IP" -v cur="$OLD_IP" -v kind="$KIND" '
      FILENAME == ARGV[1] { lab[$1] = $2; next }
      FNR > 1 && FNR <= 6 {
        cc = $7; sub(/\r$/, "", cc); if (cc == "" || cc == "N/A") cc = "?"
        g = (s + 0 > 0) ? (($5 + 0 < s + 0) ? "<" s : "≥" s) : ""
        l = ($1 in lab) ? lab[$1] : "官方"
        if (l ~ /^种子/) l = (l ~ /\(段外\)$/) ? "种子（段外）" : "种子"
        mk = ""; if (kind != "failed" && $1 == pick) mk = "pick"; else if ($1 == cur) mk = "old"
        sp = $6; sub(/\r$/, "", sp)
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", cc, $5 + 0, sp + 0, $4 + 0, g, l, mk }' \
      "$WORK/origin.map" "$WORK/result.csv" 2>/dev/null \
      | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t")
          | {colo: .[0], lat: (.[1] | tonumber), speed: (.[2] | tonumber), loss: (.[3] | tonumber),
             group: .[4], src: .[5], mark: .[6]})') || top="[]"
  fi
  series="{}"
  if [[ "$KIND" != failed && -n "$IP" ]]; then
    series=$(jq -nc --arg l "$LAT" --arg sp "$SPEED" --arg m "$METRIC" \
      '{lat: ($l | tonumber? // empty)} + (if $m != "" then {speed: ($sp | tonumber? // 0)} else {} end)')
  fi
  iv=$(( (PEAK_EVERY > OFFPEAK_EVERY ? PEAK_EVERY : OFFPEAK_EVERY) * 60 ))
  body=$(jq -nc \
    --arg source "cfst-ddns:$CFST_TARGET" --argjson iv "$iv" --argjson series "$series" --argjson top "$top" \
    --arg label "$TARGET_LABEL" --arg kind "$KIND" --arg path "$PATH_DESC" --arg colo "$cur" --arg old "$old" \
    --arg metric "$METRIC" --arg speed "$SPEED" --arg lat "$LAT" --arg loss "$LOSS" --arg group "$GROUP" \
    --arg src "$(src_name "$SRC")" --arg why "$(scrub "$WHY")" --arg reason "$(scrub "$REASON")" \
    --arg compare "$(scrub "$(sed 's/（[^）]*）//g' <<<"$COMPARE")")" --arg ver "$VERSION" \
    --arg host "$(cat /proc/sys/kernel/hostname)" --argjson t "${t:-0}" --arg peak "$(is_peak && echo 1)" \
    '{source: $source, ts: now | floor, interval: $iv, series: $series,
      data: {label: $label, kind: $kind, path: $path, colo: $colo, old_colo: $old, metric: $metric,
             speed: ($speed | tonumber? // null), lat: ($lat | tonumber? // null), loss: ($loss | tonumber? // null),
             group: $group, src: $src, why: $why, reason: $reason, compare: $compare, top: $top,
             version: $ver, host: $host, elapsed: $t, peak: ($peak == "1")}}') || { echo "警告: Sonde 上报数据生成失败" >&2; return 0; }
  if curl "${CURL_BASE[@]}" --retry 0 -m 8 -o /dev/null -w '%{http_code}' -X POST "$SONDE_URL/ingest" \
       -H "Authorization: Bearer $SONDE_TOKEN" -H 'Content-Type: application/json' --data-binary "$body" 2>/dev/null | grep -q '^200$'; then
    echo "已上报 Sonde"
  else
    echo "警告: Sonde 上报失败" >&2
  fi
}

# ---------- 收尾：无论成功失败都走这里 ----------
die() { REASON="$*"; echo "失败: $*" >&2; exit 1; }
finish() {
  local rc=$?
  [[ -n "$PID" ]] && kill "$PID" 2>/dev/null
  t=$SECONDS
  if [[ $rc -ne 0 ]]; then
    KIND=failed
    [[ -n "$REASON" ]] || REASON="脚本异常退出（退出码 $rc），详见 journalctl -u 'cfst-ddns@*'"
  fi
  notify || true
  sonde_report || true
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

# ---------- 调度（auto 模式） ----------
is_peak() {
  [[ "$PEAK_HOURS" == *-* ]] || return 1
  local h s e
  h=$((10#$(date +%H))); s=$((10#${PEAK_HOURS%-*})); e=$((10#${PEAK_HOURS#*-}))
  if (( s < e )); then (( h >= s && h < e )); else (( h >= s || h < e )); fi
}
full_due() {
  local now last tt at
  [[ -s "$WORK/pool.csv" ]] || return 0                 # 还没有榜单 → 先做一次全量
  now=$(date +%s); last=$(state_get LAST_FULL); last=${last:-0}
  for tt in $FULL_AT; do
    at=$(date -d "today $tt" +%s 2>/dev/null) || continue
    if (( at <= now && last < at )); then return 0; fi
  done
  return 1
}
check_due() {
  local now last iv
  now=$(date +%s); last=$(state_get LAST_CHECK); last=${last:-0}
  if is_peak; then iv=$PEAK_EVERY; else iv=$OFFPEAK_EVERY; fi
  (( now - last >= iv * 60 - 90 ))                      # 留 90 秒余量，免得因为几秒误差错过一个周期
}

# ---------- cfst 相关 ----------
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
      echo "  [${1}s] 延迟测速：已测 ${cur:-0/?} 个 IP，可连通 ${avail:-0} 个（限制条件最后统一筛）" ;;
    开始下载测速)
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

rows() { [[ -s "$1" ]] && echo $(($(wc -l < "$1") - 1)) || echo 0; }   # CSV 去掉表头的行数
split_on() { awk -v s="$LATENCY_SPLIT" 'BEGIN{exit !(s+0>0)}'; }
group_of() { awk -v l="$1" -v s="$LATENCY_SPLIT" 'BEGIN{ if (s+0>0) printf (l+0<s+0 ? "<%sms 段" : "≥%sms 段"), s }'; }
row_of()   { awk -F, -v ip="$1" 'NR>1 && $1==ip { print; exit }' "$2"; }

# 延迟限制条件（来自 CFST_ARGS 的 -tl / -tll / -tlr）的一句话描述
limits_desc() {
  local s
  if awk -v a="$TL" 'BEGIN{exit !(a+0 >= 9999)}'; then s="延迟不限"; else s="延迟 ≤${TL}ms"; fi
  awk -v a="$TLL" 'BEGIN{exit !(a+0 > 0)}' && s+=" 且 ≥${TLL}ms"
  awk -v a="$TLR" 'BEGIN{exit !(a+0 < 1)}' && s+=" · 丢包率 ≤${TLR}"
  echo "$s"
}

# 某个 IP 本轮的延迟情况（给"为什么没入选"用）
ip_lat_desc() {
  local r loss lat
  r=$(row_of "$1" latency.all.csv)
  if [[ -z "$r" ]]; then echo "连不上（TCP 握手全部失败）"; return; fi
  IFS=, read -r _ _ _ loss lat _ <<<"$r"
  echo "延迟 ${lat}ms · 丢包率 ${loss}"
}

# ping_list 文件 [relax] —— 测这些 IP 的延迟。cfst 不带 -tl/-tll/-tlr 跑，拿到全部能连通的 IP（latency.all.csv），
# 再由脚本按限制条件筛到 latency.csv：这样能说清楚每个 IP 是连不上还是超出限制。
# 带 relax 时（全量扫描），一个都不满足就放宽：用全部能连通的 IP 继续，免得整轮白跑。
ping_list() {
  local reach pass min seed
  run_cfst latency.all.csv "${LAT_ARGS[@]}" -f "$1" -dd
  [[ -s latency.all.csv ]] || : > latency.all.csv            # 一个都连不上时 cfst 不写文件
  LAT_RELAXED=""
  if [[ -s latency.all.csv ]]; then
    awk -F, -v tl="$TL" -v tll="$TLL" -v tlr="$TLR" \
      'NR == 1 || ($5 + 0 <= tl + 0 && $5 + 0 >= tll + 0 && $4 + 0 <= tlr + 0)' latency.all.csv > latency.csv
  else : > latency.csv; fi
  reach=$(rows latency.all.csv); pass=$(rows latency.csv)
  min=$(awk -F, 'NR > 1 && (m == "" || $5 + 0 < m) { m = $5 + 0 } END { if (m != "") printf "%.0f", m }' latency.all.csv)
  echo "  测了 $(awk 'NF' "$1" | wc -l) 个 IP：可连通 ${reach} 个${min:+（最低延迟 ${min}ms）}，满足限制条件（$(limits_desc)）${pass} 个"
  SCAN_NOTE="可连通 ${reach}${min:+（最低 ${min}ms）}，满足 $(limits_desc) 的 ${pass} 个"
  # 种子单独统计：到底是连不上、超出限制，还是被官方 IP 比下去了
  if [[ "$MODE" != check && -s seeds.txt ]]; then
    seed=$(awk -F, '
      FILENAME == ARGV[1] { s[$1] = 1; n++; next }
      FILENAME == ARGV[2] { if (FNR > 1 && ($1 in s)) { r++; if (m == "" || $5 + 0 < m) m = $5 + 0 }; next }
      FNR > 1 && ($1 in s) { p++ }
      END { printf "%d %d %d %s", n, r + 0, p + 0, (m == "" ? "" : sprintf("%.0f", m)) }' seeds.txt latency.all.csv latency.csv)
    read -r sn sr sp sm <<<"$seed"
    echo "  其中种子 ${sn} 个：可连通 ${sr} 个${sm:+（最低延迟 ${sm}ms）}，满足限制条件 ${sp} 个"
    SCAN_NOTE+="；种子 ${sn} 个，可连通 ${sr}，满足 ${sp}"
  fi
  if (( pass == 0 && reach > 0 )) && [[ "${2:-}" == relax ]]; then
    cp latency.all.csv latency.csv; LAT_RELAXED=1
    echo "  没有 IP 满足限制条件，本轮放宽：用全部 ${reach} 个可连通的 IP 继续（按丢包、延迟排序）"
    SCAN_NOTE+="；无 IP 满足限制，已放宽"
  fi
}

# ---------- 来源：官方扫描 / 种子 ----------
# origin.map：榜单里每个 IP 是从哪来的（"官方" 或 "种子:来源名"），第一次发现时记下，之后一直沿用
label_of() { local l; l=$(awk -F, -v ip="$1" '$1==ip { print $2; exit }' origin.map 2>/dev/null) || l=""; echo "${l:-官方}"; }

# 只保留落在官方网段里的 IP（防止公共优选域名被劫持、污染后混进别的 IP）
# in_ranges 网段文件 < "ip,来源" 行
in_ranges() {
  awk -F, '
    function n(s,  a) { split(s, a, "."); return ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4] }
    { sub(/\r$/, "") }                                  # cfst 自带的 ip.txt 是 Windows 换行
    FNR == NR { if ($0 !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/) next
                split($0, c, "/"); len = (c[2] == "") ? 32 : c[2] + 0; sz = 2 ^ (32 - len)
                net[++k] = int(n(c[1]) / sz) * sz; size[k] = sz; next }
    { if ($1 !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || seen[$1]++) next
      x = n($1); for (i = 1; i <= k; i++) if (x >= net[i] && x < net[i] + size[i]) { print; break } }' "$1" -
}

# 采集种子，写到 seeds.txt（"ip,种子:来源"）
collect_seeds() {
  local d u lab ips raw all ok u2 host b
  : > seeds.txt
  [[ -n "$SEEDS_DNS$SEEDS_URL" ]] || return 0
  : > seeds.raw
  for d in $SEEDS_DNS; do
    # 直连国内 DoH：不经过 sing-box 的 fakeip，拿到的是你所在运营商那条线路的解析结果
    ips=$(curl -sS --noproxy '*' --connect-timeout 5 -m 10 -H 'accept: application/dns-json' \
            "${SEED_DOH}?name=${d}&type=1" 2>/dev/null | jq -r '.Answer[]? | select(.type == 1) | .data' 2>/dev/null) || ips=""
    if [[ -z "$ips" ]]; then ips=$(getent ahostsv4 "$d" 2>/dev/null | awk '{ print $1 }' | sort -u) || ips=""; fi
    printf '%s\n' $ips | awk -v l="种子:$d" 'NF { print $1 "," l }' >> seeds.raw
    echo "  种子 $d：$(printf '%s\n' $ips | grep -c .) 个"
  done
  for u in $SEEDS_URL; do
    u2=${u#*://}; host=${u2%%/*}; host=${host#www.}; b=""
    [[ "$u2" == */* ]] && { b=${u2##*/}; b=${b%%\?*}; b=${b%.html}; b=${b%.json}; }
    lab="种子:${host}${b:+/$b}"
    raw=$(curl "${CURL_BASE[@]}" "$u" 2>/dev/null) || raw=""
    ips=$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' <<<"$raw" | sort -u) || ips=""
    printf '%s\n' $ips | awk -v l="$lab" 'NF { print $1 "," l }' >> seeds.raw
    echo "  种子 ${lab#种子:}：$(printf '%s\n' $ips | grep -c .) 个"
  done
  all=$(awk -F, '!s[$1]++' seeds.raw | wc -l)
  prepare_iplist
  if [[ -s "$CFST_IPFILE" ]]; then
    in_ranges "$CFST_IPFILE" < seeds.raw > seeds.txt
    if [[ "$SEED_ALLOW_OUTSIDE" == 1 ]]; then
      # 段外种子：不是该 CDN 自己的 IP（常见是第三方反代），流量会先经过别人的服务器，标出来便于区分
      awk -F, -v OFS=, 'FILENAME == ARGV[1] { in_[$1] = 1; next }
        $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && !($1 in in_) && !s[$1]++ { print $1, $2 "(段外)" }' seeds.txt seeds.raw >> seeds.txt
    fi
  else
    echo "警告: 没有官方网段列表可以校验种子，本轮不用种子" >&2
  fi
  ok=$(wc -l < seeds.txt)
  local inside; inside=$(grep -vc '(段外)$' seeds.txt) || inside=0
  if [[ "$SEED_ALLOW_OUTSIDE" == 1 ]]; then
    echo "  种子共 ${all} 个：官方网段内 ${inside} 个，段外 $((ok - inside)) 个（SEED_ALLOW_OUTSIDE=1，保留）"
  else
    echo "  种子共 ${all} 个，落在官方网段内 ${inside} 个$( (( all > inside )) && echo "（$((all - inside)) 个不在官方网段，已丢弃；SEED_ALLOW_OUTSIDE=1 可保留）")"
  fi
  rm -f seeds.raw
}

# latency.csv 每行加上来源列，写到 labeled.csv：已知的沿用 origin.map，本轮种子标种子，其余是官方扫描
label_rows() {
  touch origin.map seeds.txt
  awk -F, -v OFS=, '
    FILENAME == ARGV[1] { if (!($1 in m)) m[$1] = $2; next }
    FILENAME == ARGV[2] { if (!($1 in sd)) sd[$1] = $2; next }
    FNR > 1 { print $0, (($1 in m) ? m[$1] : (($1 in sd) ? sd[$1] : "官方")) }' origin.map seeds.txt latency.csv > labeled.csv
}

# 从 latency.csv 挑候选：每段官方取前 k 个、种子取前 SEED_PICK_PER_GROUP 个（各按延迟），写到 candidates.lab
pick_candidates() {
  local k=$1 nlo nhi ns
  label_rows
  awk -F, -v s="$LATENCY_SPLIT" -v k="$k" -v ks="$SEED_PICK_PER_GROUP" -v cur="$OLD_IP" '$1 != cur {
      g = (s + 0 > 0 && $5 + 0 >= s + 0) ? "hi" : "lo"
      c = ($8 ~ /^种子/) ? "seed" : "off"
      if (cnt[g c]++ < ((c == "seed") ? ks : k)) print }' labeled.csv > candidates.lab
  ns=$(grep -c ',种子:' labeled.csv) || ns=0
  if split_on; then
    read -r nlo nhi < <(awk -F, -v s="$LATENCY_SPLIT" '{ if ($5 + 0 < s + 0) a++; else b++ } END { print a + 0, b + 0 }' labeled.csv)
    echo "  参与挑选 $((nlo + nhi)) 个（其中种子 ${ns} 个）：<${LATENCY_SPLIT}ms 段 ${nlo} 个，≥${LATENCY_SPLIT}ms 段 ${nhi} 个"
  else
    echo "  参与挑选 $(rows latency.csv) 个（其中种子 ${ns} 个）"
  fi
}

# 当前 IP 也一起测，好跟新候选比较（它没通过延迟筛选就不管它）
add_current() {
  [[ -n "$OLD_IP" ]] || return 0
  awk -F, -v ip="$OLD_IP" '$1 == ip { f = 1 } END { exit !f }' candidates.lab && return 0
  awk -F, -v ip="$OLD_IP" '$1 == ip { print; exit }' labeled.csv >> candidates.lab
}

# 定下候选：写 candidates.csv（给测速用）、新榜单 pool.csv、来源表 origin.map
finish_candidates() {
  cut -d, -f1-7 candidates.lab > candidates.csv
  { head -n1 latency.csv; cat candidates.csv; } > pool.csv
  awk -F, -v OFS=, '{ print $1, $8 }' candidates.lab > origin.map
  local cur=""
  [[ -n "$OLD_IP" ]] && awk -F, -v ip="$OLD_IP" '$1 == ip { f = 1 } END { exit !f }' candidates.lab && cur="，含当前 IP"
  echo "  候选 $(wc -l < candidates.csv) 个：官方 $(grep -vc ',种子:' candidates.lab) 个，种子 $(grep -c ',种子:' candidates.lab) 个${cur}"
}

# 上传测速：对 candidates.csv 里每个 IP 用 curl 直连上传 UP_SECONDS 秒，结果写到 result.csv
upload_pass() {
  local scheme rest hostport host port addr n=0 total row ip lat r rc code size tt pre tcp sp full g
  scheme=${UPLOAD_URL%%://*}; rest=${UPLOAD_URL#*://}; hostport=${rest%%/*}
  host=${hostport%%:*}; port=${hostport#*:}
  [[ "$port" == "$hostport" ]] && { [[ "$scheme" == http ]] && port=80 || port=443; }
  truncate -s 64M upload.bin      # 稀疏文件，不占磁盘空间
  full=$(stat -c %s upload.bin)
  total=$(wc -l < candidates.csv)
  UP_OK=0; UP_ERR=""
  echo "上传测速: ${total} 个 IP，每个 ${UP_SECONDS}s，地址 ${UPLOAD_URL}"
  head -n1 latency.csv > result.csv
  while IFS= read -r row; do
    n=$((n + 1))
    IFS=, read -r ip _ _ _ lat _ <<<"$row"
    [[ "$ip" == *:* ]] && addr="[$ip]" || addr="$ip"
    rc=0
    # --resolve 把域名钉到这个 IP 上：不查 DNS、不走代理；超时（退出码 28）是正常结束方式
    r=$(curl -sS -v --noproxy '*' -o /dev/null \
          -w '%{http_code} %{size_upload} %{time_total} %{time_pretransfer}' \
          -H 'Expect:' -H 'Content-Type: application/octet-stream' \
          --resolve "$host:$port:$addr" --connect-timeout 5 -m $((UP_SECONDS + 3)) \
          -X POST -T upload.bin "$UPLOAD_URL" 2>curl.err) || rc=$?
    read -r code size tt pre <<<"${r:-000 0 0 0}"
    tcp=0; grep -q '^\* Connected to' curl.err && tcp=1   # curl 把 TLS 握手也算进"连接"，只能从详细日志看 TCP 连没连上
    # 只按真正传输的那段时间算（去掉 TCP/TLS 握手），单位 MB/s
    sp=$(awk -v s="${size:-0}" -v t="${tt:-0}" -v p="${pre:-0}" \
           'BEGIN{ d=t-p; printf "%.2f", (d>0.2 && s>0) ? s/d/1048576 : 0 }')
    if (( rc == 28 )) && [[ "$code" == 000 ]] && awk -v s="${size:-0}" 'BEGIN{exit !(s>0)}'; then
      :                                               # 时间到时还在上传 → 有效
    elif (( rc == 0 )) && [[ "$code" == 2* ]] && [[ "$size" == "$full" ]]; then
      :                                               # 64MB 全部传完 → 有效
    else
      if (( rc == 55 || rc == 56 )); then UP_ERR="服务器中途断开（curl 退出码 $rc，测速地址可能不接受大文件上传）"
      elif (( rc != 0 && rc != 28 )); then UP_ERR="连接失败（curl 退出码 $rc）"
      elif [[ "$code" != 000 && "$code" != 2* ]]; then UP_ERR="服务器返回 HTTP $code"
      elif (( rc == 28 && tcp == 0 )); then UP_ERR="TCP 连接超时"
      elif (( rc == 28 )) && [[ "$scheme" == https ]] && ! grep -qiE 'SSL connection using|TLS handshake, Finished' curl.err; then
        UP_ERR="TLS 握手超时（TCP 连上了但握手卡住：这个 IP 上该域名可能被干扰）"
      elif (( rc == 28 )); then UP_ERR="超时，一点数据都没传出去"
      elif (( rc == 35 )); then UP_ERR="TLS 握手失败（curl 35）"
      else UP_ERR="服务器提前结束（只收了 $(awk -v s="$size" 'BEGIN{printf "%.1f", s/1048576}') MB，测速地址不适合上传测速）"
      fi
      sp="0.00"
    fi
    g=$(group_of "$lat")
    if [[ "$sp" == "0.00" ]]; then
      echo "  [上传 ${n}/${total}] $(printf '%-16s %7sms' "$ip" "$lat")${g:+ $g}  失败：${UP_ERR:-速度为 0}"
    else
      UP_OK=$((UP_OK + 1))
      echo "  [上传 ${n}/${total}] $(printf '%-16s %7sms' "$ip" "$lat")${g:+ $g}  ${sp} MB/s"
    fi
    awk -F, -v OFS=, -v sp="$sp" '{ $6 = sp; print }' <<<"$row" >> result.csv
  done < candidates.csv
  rm -f upload.bin curl.err
}

# 对 candidates.csv 测速（或只按延迟），结果写到 result.csv，并排好序
speed_test() {
  local n
  case "$RANK_BY" in
    latency) { head -n1 latency.csv; cat candidates.csv; } > result.csv ;;
    upload)  upload_pass ;;
    download)
      cut -d, -f1 candidates.csv > candidates.txt
      n=$(wc -l < candidates.txt)
      echo "下载测速: ${n} 个 IP"
      run_cfst result.csv "${LAT_ARGS[@]}" -f candidates.txt -dn "$n" ;;   # 候选已按限制条件筛过，这里不让 cfst 再筛一遍
  esac
  [[ $(rows result.csv) -ge 1 && -n "$METRIC" ]] || return 0
  # 按速度从高到低排序（表头保持在第一行）
  { head -n1 result.csv; tail -n +2 result.csv | sort -t, -k6,6gr -s; } > result.tmp && mv result.tmp result.csv
  FASTEST=$(sed -n 2p result.csv | cut -d, -f1)
  # 速度容差：在 "速度 ≥ 最快 × (1 - 容差%)" 的 IP 里选延迟最低的，挪到第一行
  if awk -v t="$SPEED_TOLERANCE" 'BEGIN{exit !(t+0>0)}'; then
    awk -F, -v tol="$SPEED_TOLERANCE" '
      NR == 1 { print; next }
      { row[++n] = $0; sp[n] = $6 + 0; la[n] = $5 + 0; lo[n] = $4 + 0 }
      END {
        pick = 1
        for (i = 2; i <= n; i++) if (sp[i] >= sp[1] * (1 - tol / 100) && (lo[i] < lo[pick] || (lo[i] == lo[pick] && la[i] < la[pick]))) pick = i
        print row[pick]; for (i = 1; i <= n; i++) if (i != pick) print row[i]
      }' result.csv > result.tmp && mv result.tmp result.csv
  fi
}

print_results() {
  echo "结果（IP / 延迟ms / 丢包${METRIC:+ / ${METRIC}MB/s}）："
  touch origin.map
  awk -F, -v s="$LATENCY_SPLIT" -v m="$METRIC" -v cur="$OLD_IP" '
    FILENAME == ARGV[1] { lab[$1] = $2; next }
    FNR > 1 && FNR <= 13 {
    g = (s+0>0) ? (($5+0 < s+0) ? "  <" s "ms" : "  ≥" s "ms") : ""
    c = ($1 == cur) ? "  ← 当前" : ""
    l = "  " (($1 in lab) ? lab[$1] : "官方")
    if (m != "") printf "  %-16s %8s %6s %8s%s%s%s\n", $1, $5, $4, $6, g, l, c
    else         printf "  %-16s %8s %6s%s%s%s\n", $1, $5, $4, g, l, c }' origin.map result.csv
}

# 读一行结果到 IP / LAT / LOSS / SPEED / GROUP
load_row() {
  IFS=, read -r IP _ _ LOSS LAT SPEED _ <<<"$1"
  SPEED="${SPEED%$'\r'}"; SPEED="${SPEED:-0}"; GROUP=$(group_of "$LAT")
}

# 本轮官方扫描最佳 vs 种子最佳，写进日志、简报和 history.csv（stats 命令用它来汇总）
record_compare() {
  local oi ov si ss sv u val
  read -r oi ov si ss sv < <(awk -F, -v m="$RANK_BY" '
    FILENAME == ARGV[1] { lab[$1] = $2; next }
    FNR > 1 { l = ($1 in lab) ? lab[$1] : "官方"; c = (l ~ /^种子/) ? "s" : "o"
      v = (m == "latency") ? $5 + 0 : $6 + 0
      if (m != "latency" && v <= 0) next
      if (!(c in bv) || (m == "latency" ? v < bv[c] : v > bv[c])) { bv[c] = v; bi[c] = $1; bl[c] = l } }
    END { printf "%s %s %s %s %s\n", ("o" in bi) ? bi["o"] : "-", ("o" in bv) ? bv["o"] : "-",
                  ("s" in bi) ? bi["s"] : "-", ("s" in bl) ? bl["s"] : "-", ("s" in bv) ? bv["s"] : "-" }' origin.map result.csv)
  if [[ "$RANK_BY" == latency ]]; then u=ms; val=$LAT; else u=MB/s; val=$SPEED; fi
  if [[ "$si" != - || -n "$SEEDS_DNS$SEEDS_URL" ]]; then
    COMPARE="官方最佳 $([[ $ov != - ]] && echo "$ov $u" || echo 无) · 种子最佳 $([[ $sv != - ]] && echo "$sv $u（${ss#种子:}）" || echo 无)"
    echo "对比: $COMPARE"
  fi
  echo "$(date +%s),$(is_peak && echo 1 || echo 0),$MODE,$RANK_BY,$IP,$SRC,$val,$oi,$ov,$si,$ss,$sv" >> history.csv
  if (( $(wc -l < history.csv) > 6000 )); then tail -n 5000 history.csv > history.tmp && mv history.tmp history.csv; fi
}

# 这个目标正在用的主要参数，一行，写进日志和简报
config_brief() {
  local b args
  case "$RANK_BY" in download) b="按下载" ;; upload) b="按上传 ${UP_SECONDS}s" ;; *) b="只看延迟" ;; esac
  split_on && b+=" · 分段 ${LATENCY_SPLIT}ms"
  b+=" · 每段官方 ${PICK_PER_GROUP}"
  [[ -n "$SEEDS_DNS$SEEDS_URL" ]] && b+="+种子 ${SEED_PICK_PER_GROUP}"
  [[ -n "$METRIC" ]] && b+=" · 底线 ${MIN_SPEED}MB/s · 容差 ${SPEED_TOLERANCE}%"
  b+=" · 切换 ${SWITCH_MARGIN}% · 健康 ${HEALTH_RATIO}%"
  args=$(sed -E 's#(-url )https?://([^/ ]+)[^ ]*#\1\2/…#' <<<"$CFST_ARGS")
  echo "$b · cfst ${args:-默认}"
}

# 当前 IP 为什么不在测速结果里
missing_reason() {
  if [[ -n "$(row_of "$OLD_IP" latency.csv)" ]]; then echo "当前 IP 满足限制条件，但测速没有结果"
  elif [[ -z "$(row_of "$OLD_IP" latency.all.csv)" ]]; then echo "当前 IP 本轮连不上（TCP 握手全部失败），换掉"
  else echo "当前 IP 本轮$(ip_lat_desc "$OLD_IP")，限制条件：$(limits_desc)，换掉"
  fi
}

# ---------- 选 IP 并更新 DNS（pool / full 共用） ----------
select_and_update() {
  local c k cip cs cl ks kl best action
  NOGOOD=""
  if [[ $(rows result.csv) -lt 1 ]]; then
    [[ " $CFST_ARGS " == *" -sl "* ]] && die "测速没有结果：没有任何 IP 达到 -sl 下载速度下限"
    if [[ "$MODE" == pool ]]; then NOGOOD=1; return; fi
    die "测速没有结果（全部超出延迟/丢包条件？）"
  fi
  print_results

  c=$(sed -n 2p result.csv); IFS=, read -r cip _ _ _ cl cs _ <<<"$c"; cs=${cs%$'\r'}
  best=$(awk -F, -v ip="$FASTEST" 'NR>1 && $1==ip { print $6; exit }' result.csv)
  k=""; [[ -n "$OLD_IP" ]] && k=$(row_of "$OLD_IP" result.csv)
  ks=0; kl=0; [[ -n "$k" ]] && IFS=, read -r _ _ _ _ kl ks _ <<<"$k" && ks=${ks%$'\r'}

  local why_missing=""; [[ -z "$k" && -n "$OLD_IP" ]] && why_missing=$(missing_reason)
  [[ -z "$OLD_IP" ]] && why_missing="还没有解析记录，新建"
  # 切换门槛：新 IP 明显更好才换，避免在差不多的 IP 之间来回跳
  read -r action WHY < <(awk -v mode="$RANK_BY" -v same="$([[ "$cip" == "$OLD_IP" ]] && echo 1)" -v miss="$why_missing" \
      -v kin="$([[ -n "$k" ]] && echo 1)" -v cs="$cs" -v cl="$cl" -v ks="$ks" -v kl="$kl" \
      -v best="${best:-0}" -v tol="$SPEED_TOLERANCE" -v m="$SWITCH_MARGIN" -v floor="$MIN_SPEED" 'BEGIN {
    if (same)  { print "keep 当前 IP 就是第一名"; exit }
    if (!kin)  { print "switch " miss; exit }
    if (mode == "latency") {
      if (cl+0 <= kl * (1 - m/100)) printf "switch 延迟 %s → %s ms，低了 %.0f%%\n", kl, cl, (1 - cl/kl) * 100
      else printf "keep 第一名延迟只低 %.0f%%，未达切换门槛 %s%%\n", (kl > 0 ? (1 - cl/kl) * 100 : 0), m
      exit
    }
    if (ks+0 <= 0)           { print "switch 当前 IP 测速失败"; exit }
    if (ks+0 < floor+0)      { printf "switch 当前 IP 只有 %s MB/s，低于底线 %s\n", ks, floor; exit }
    if (cs+0 >= ks * (1 + m/100)) { printf "switch 速度 %s → %s MB/s，快了 %.0f%%\n", ks, cs, (cs/ks - 1) * 100; exit }
    if (tol+0 > 0 && ks+0 >= best * (1 - tol/100) && cl+0 <= kl * (1 - m/100)) {
      printf "switch 速度相当（%s vs %s MB/s），延迟 %s → %s ms\n", ks, cs, kl, cl; exit }
    printf "keep 第一名 %s MB/s，比当前 %s MB/s 只快 %.0f%%，未达切换门槛 %s%%\n", cs, ks, (cs/ks - 1) * 100, m
  }')

  if [[ "$action" == keep ]]; then load_row "${k:-$c}"; else load_row "$c"; fi
  [[ -n "$FASTEST" && "$IP" != "$FASTEST" && "$action" == switch ]] \
    && echo "（速度在最快的 ${SPEED_TOLERANCE}% 以内，选了丢包更少、延迟更低的这个；最快的是 ${FASTEST}）"
  SRC=$(label_of "$IP")
  echo "选中: $IP  延迟 ${LAT}ms${GROUP:+（$GROUP）}  丢包 $LOSS${METRIC:+  ${METRIC} ${SPEED}MB/s}  来源 $SRC"
  echo "说明: $WHY"
  record_compare

  # 兜底底线：选中的 IP 速度为 0 或低于 MIN_SPEED 时不动现有解析
  if [[ -n "$METRIC" ]]; then
    if awk -v s="$SPEED" 'BEGIN{exit !(s+0<=0)}'; then
      [[ "$RANK_BY" == upload && "$UP_OK" -eq 0 ]] \
        && die "上传测速全部失败：${UP_ERR:-未知原因}（检查 UPLOAD_URL，或改成自建的上传地址），保留现有解析"
      die "${METRIC}速度全部为 0（测速地址可能不可用），保留现有解析"
    elif awk -v s="$SPEED" -v m="$MIN_SPEED" 'BEGIN{exit !(s+0<m+0)}'; then
      if [[ "$MODE" == pool ]]; then NOGOOD=1; return; fi
      die "选中的也只有 ${SPEED} MB/s，低于底线 MIN_SPEED=${MIN_SPEED}，保留现有解析"
    fi
  fi

  state_set "BASE_IP=$IP" "BASE_SPEED=$SPEED" "BASE_LAT=$LAT"
  if [[ "$IP" == "$OLD_IP" ]]; then
    KIND=unchanged
    echo "解析保持 $IP，无需更新"
    return
  fi
  BODY=$(jq -nc --arg t "$TYPE" --arg n "$CF_RECORD_NAME" --arg c "$IP" --argjson ttl "$CF_TTL" \
    '{type:$t, name:$n, content:$c, ttl:$ttl, proxied:false}')
  if [[ -n "$REC_ID" ]]; then cf PATCH "$API/$REC_ID" "$BODY"; else cf POST "$API" "$BODY"; fi
  KIND=updated
  echo "已更新 $CF_RECORD_NAME ($TYPE): ${OLD_IP:-<新建>} -> $IP"
}

# ---------- 三级流程 ----------
# 巡检：只测当前 IP。健康就结束，变差了升级为复测榜单
do_check() {
  local k base_ip base_sp base_lat need
  [[ -s pool.csv ]] || { echo "还没有榜单"; NEXT=full; return; }
  [[ -n "$OLD_IP" ]] || { echo "当前没有解析记录"; NEXT=pool; return; }
  echo "巡检当前 IP: $OLD_IP"
  echo "$OLD_IP" > check.txt
  ping_list check.txt
  if [[ $(rows latency.csv) -lt 1 ]]; then
    echo "当前 IP 本轮$(ip_lat_desc "$OLD_IP")，限制条件：$(limits_desc)"; NEXT=pool; return
  fi
  tail -n +2 latency.csv > candidates.csv
  speed_test
  k=$(row_of "$OLD_IP" result.csv)
  [[ -n "$k" ]] || { echo "当前 IP 测速没有结果"; NEXT=pool; return; }
  load_row "$k"; SRC=$(label_of "$IP")

  base_ip=$(state_get BASE_IP); base_sp=$(state_get BASE_SPEED); base_lat=$(state_get BASE_LAT)
  if [[ "$base_ip" != "$OLD_IP" ]]; then base_sp=""; base_lat=""; fi   # 基准不是这个 IP 的，作废

  if [[ -z "$METRIC" ]]; then
    # 只看延迟：延迟没有比基准高出太多就算健康
    if [[ -z "$base_lat" ]] || awk -v l="$LAT" -v b="$base_lat" -v r="$HEALTH_RATIO" 'BEGIN{exit !(l+0 <= b*100/r)}'; then
      WHY="延迟 ${LAT} ms${base_lat:+（基准 ${base_lat} ms）}"
      [[ -n "$base_lat" ]] || state_set "BASE_IP=$IP" "BASE_LAT=$LAT"
      KIND=healthy; echo "健康：$WHY"; return
    fi
    echo "变差：延迟 ${LAT} ms，基准 ${base_lat} ms"; NEXT=pool; return
  fi

  need=$(awk -v b="${base_sp:-0}" -v r="$HEALTH_RATIO" -v f="$MIN_SPEED" \
           'BEGIN{ n = b * r / 100; if (n < f+0) n = f+0; printf "%.2f", n }')
  if awk -v s="$SPEED" -v n="$need" 'BEGIN{exit !(s+0 > 0 && s+0 >= n+0)}'; then
    WHY="${METRIC} ${SPEED} MB/s${base_sp:+，基准 ${base_sp} MB/s}，健康线 ${need} MB/s"
    [[ -n "$base_sp" ]] || state_set "BASE_IP=$IP" "BASE_SPEED=$SPEED" "BASE_LAT=$LAT"
    KIND=healthy; echo "健康：$WHY"; return
  fi
  echo "变差：${METRIC} ${SPEED} MB/s，健康线 ${need} MB/s${base_sp:+（基准 ${base_sp} 的 ${HEALTH_RATIO}%）}"
  NEXT=pool
}

# 复测榜单：重测上次留下的榜单（加上当前 IP 和本轮的新种子），选最好的
do_pool() {
  [[ -s pool.csv ]] || { echo "还没有榜单"; NEXT=full; return; }
  collect_seeds
  { tail -n +2 pool.csv | cut -d, -f1; cut -d, -f1 seeds.txt; if [[ -n "$OLD_IP" ]]; then echo "$OLD_IP"; fi; } \
    | awk 'NF && !seen[$0]++' > pool.txt
  echo "复测榜单: $(wc -l < pool.txt) 个 IP（榜单 + 种子 + 当前 IP）"
  ping_list pool.txt
  if [[ $(rows latency.csv) -lt 1 ]]; then
    echo "榜单里没有满足限制条件的 IP"; NEXT=full; return
  fi
  pick_candidates "$PICK_PER_GROUP"
  add_current
  finish_candidates
  speed_test
  select_and_update
  if [[ -n "$NOGOOD" ]]; then echo "榜单里没有达标的 IP"; NEXT=full; fi
}

# 把网段展开成 /24（cfst 每个 /24 随机测 1 个 IP）；比 /24 小的网段、单个 IP、IPv6 原样保留
expand_24() {
  awk -F'[./]' '
    NF == 5 && $0 !~ /:/ && $5+0 <= 24 {
      cnt = 2 ^ (24 - $5); base = int((($1 * 256 + $2) * 256 + $3) / cnt) * cnt
      for (i = 0; i < cnt; i++) { b = base + i; printf "%d.%d.%d.0/24\n", int(b / 65536), int(b / 256) % 256, b % 256 }
      next }
    { print }'
}

# 设了 IPLIST_URL 的目标（如 CloudFront）：每天从官方地址更新一次 IP 列表，存到状态目录
prepare_iplist() {
  [[ -n "$IPLIST_URL" ]] || return 0
  local f="$WORK/iplist.txt" raw="" list="" n
  if [[ ! -s "$f" ]] || (( $(date +%s) - $(stat -c %Y "$f") > 86400 )); then
    echo "更新 IP 列表: $IPLIST_URL"
    raw=$(curl "${CURL_BASE[@]}" "$IPLIST_URL" 2>/dev/null) || raw=""
    if [[ -n "$IPLIST_JQ" ]]; then list=$(jq -r "$IPLIST_JQ" <<<"$raw" 2>/dev/null) || list=""; else list=$raw; fi
    list=$(tr -d '\r' <<<"$list" | grep -E '^[0-9a-fA-F:.]+(/[0-9]+)?$') || list=""
    if [[ -n "$list" && -n "$IP_EXCLUDE" ]]; then list=$(grep -vE "$IP_EXCLUDE" <<<"$list") || list=""; fi
    if [[ -n "$list" ]]; then
      n=$(wc -l <<<"$list")
      expand_24 <<<"$list" > "$f.tmp" && mv "$f.tmp" "$f"
      echo "  ${n} 个网段（已排除 IP_EXCLUDE）→ $(wc -l < "$f") 个 /24"
    elif [[ -s "$f" ]]; then
      echo "警告: IP 列表更新失败，沿用上次的列表" >&2
    else
      die "下载 IP 列表失败：$IPLIST_URL"
    fi
  fi
  CFST_IPFILE="$f"
}

# 全量扫描：官方网段（可抽样）+ 种子 + 上一轮榜单，测延迟，重建榜单，再测速选最好的
do_full() {
  local total
  state_set "LAST_FULL=$(date +%s)"
  prepare_iplist
  [[ -s "$CFST_IPFILE" ]] || die "IP 列表不存在或为空：$CFST_IPFILE"
  expand_24 < "$CFST_IPFILE" > all24.txt
  total=$(wc -l < all24.txt)
  # IP_SAMPLE：每次随机抽一部分 /24（每天换一批）；上一轮榜单和种子总会一起测，好的不会丢
  if (( IP_SAMPLE > 0 && total > IP_SAMPLE )); then
    shuf -n "$IP_SAMPLE" all24.txt > scan.txt
    echo "官方网段：从 ${total} 个 /24 里随机抽 ${IP_SAMPLE} 个（IP_SAMPLE）"
  else
    cp all24.txt scan.txt
    echo "官方网段：${total} 个 /24"
  fi
  rm -f all24.txt
  collect_seeds
  cut -d, -f1 seeds.txt >> scan.txt
  if [[ -n "$OLD_IP" ]]; then echo "$OLD_IP" >> scan.txt; fi        # 当前 IP 一定参加，好跟新候选比较
  if [[ -s pool.csv ]]; then tail -n +2 pool.csv | cut -d, -f1 >> scan.txt; fi
  echo "延迟测速（全量）: cfst $CFST_ARGS -dd"
  ping_list scan.txt relax
  [[ $(rows latency.csv) -ge 1 ]] || die "延迟测速：扫描的 $(wc -l < scan.txt) 个 IP 全部连不上（TCP 端口 ${TP}），检查本机网络或 sing-box 的 exclude_uid"
  pick_candidates "$PICK_PER_GROUP"
  add_current
  finish_candidates
  speed_test
  select_and_update
}

# ---------- 主流程 ----------
mkdir -p "$WORK"; cd "$WORK"; touch origin.map
read -ra ARGS <<<"$CFST_ARGS"
# 拆出延迟限制条件：cfst 延迟测速时不带它们，由脚本自己筛（见 ping_list）
TL=9999; TLL=0; TLR=1; TP=443; LAT_ARGS=()
for ((i = 0; i < ${#ARGS[@]}; i++)); do
  case "${ARGS[i]}" in
    -tl)  TL=${ARGS[i+1]:-9999}; i=$((i + 1)) ;;
    -tll) TLL=${ARGS[i+1]:-0}; i=$((i + 1)) ;;
    -tlr) TLR=${ARGS[i+1]:-1}; i=$((i + 1)) ;;
    -tp)  TP=${ARGS[i+1]:-443}; LAT_ARGS+=("${ARGS[i]}" "${ARGS[i+1]}"); i=$((i + 1)) ;;
    *)    LAT_ARGS+=("${ARGS[i]}") ;;
  esac
done
[[ -n "$IPLIST_URL" && -s iplist.txt ]] && CFST_IPFILE="$WORK/iplist.txt"

# 非 Cloudflare 目标的必填项检查（cfst 默认的下载测速地址在 Cloudflare 上，换 CDN 必须自己给）
if [[ "$CFST_TARGET" != cloudflare ]]; then
  P=$(target_prefix "$CFST_TARGET")
  [[ -n "$IPLIST_URL" || -n "$CFST_IPFILE" ]] || die "[$TARGET_LABEL] 没有 IP 来源：请设置 ${P}_IPLIST_URL 或 ${P}_IPFILE"
  if [[ "$RANK_BY" == download && " $CFST_ARGS " != *" -url "* ]]; then
    die "[$TARGET_LABEL] 下载测速需要在 ${P}_CFST_ARGS 里用 -url 指定一个该 CDN 上的测速文件"
  fi
  if [[ "$RANK_BY" == upload && -z "$UPLOAD_URL" ]]; then
    die "[$TARGET_LABEL] 上传测速需要设置 ${P}_UPLOAD_URL（该 CDN 上一个接受 POST 的地址）"
  fi
fi

if [[ "$MODE" == auto ]]; then
  if full_due; then MODE=full
  elif check_due; then MODE=check
  else KIND=skip; exit 0                                 # 还没到时间，安静退出
  fi
fi
echo "########## ${TARGET_LABEL} ##########  cfst-ddns ${VERSION}"
echo "参数: $(config_brief)"
if is_peak; then echo "$(date '+%m-%d %H:%M') 晚高峰（${PEAK_HOURS}），每 ${PEAK_EVERY} 分钟巡检"
else echo "$(date '+%m-%d %H:%M') 非高峰，每 ${OFFPEAK_EVERY} 分钟巡检"; fi
state_set "LAST_CHECK=$(date +%s)"

# 先读当前解析：巡检要测它，复测和全量要拿它做比较
if grep -q ':' "$CFST_IPFILE" 2>/dev/null; then TYPE=AAAA; else TYPE=A; fi
cf GET "${API}?type=${TYPE}&name=${CF_RECORD_NAME}"
REC_ID=$(jq -r '.result[0].id // empty' <<<"$RESP")
OLD_IP=$(jq -r '.result[0].content // empty' <<<"$RESP")
echo "当前解析: $CF_RECORD_NAME ($TYPE) = ${OLD_IP:-<无>}${API_PROXY:+（API 经代理 $API_PROXY）}"

rm -f result.csv latency.csv latency.all.csv candidates.csv candidates.txt
while :; do
  PATH_DESC+="${PATH_DESC:+ → }$(mode_name "$MODE")"
  echo "===== $(mode_name "$MODE") ====="
  NEXT=""
  case "$MODE" in
    check) do_check ;;
    pool)  do_pool ;;
    full)  do_full ;;
  esac
  [[ -n "$NEXT" ]] || break
  if [[ "$NEXT" == full && "$MODE" == pool ]]; then
    last=$(state_get LAST_FULL); last=${last:-0}
    if (( $(date +%s) - last < FULL_MIN_GAP * 60 )); then
      die "榜单里没有达标的 IP，且 ${FULL_MIN_GAP} 分钟内刚做过全量扫描，本轮不再补扫，保留现有解析"
    fi
  fi
  MODE=$NEXT
done
t=$SECONDS
echo "完成，用时 ${t}s"
