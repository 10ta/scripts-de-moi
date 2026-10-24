#!/usr/bin/env bash
# warp-keeper —— 给 sing-box 自动维护一个 Cloudflare WARP 出口，不需要 wireproxy / wg-quick
#
#   warp-keeper.sh init        注册账户（已有就沿用）→ 写 sing-box 配置片段 → 检查 → 重载 → 验证
#                              改了 /etc/warp-keeper.env（端口、tag、MTU…）后也用它重新生成
#   warp-keeper.sh check       健康检查，不通就按「重载 → 换号」逐级自愈（timer 每小时调用）
#   warp-keeper.sh status      看当前状态：出口、延迟、账户、可用率（会实测一次，不改任何东西）
#   warp-keeper.sh renew       立即换一个新账户（想换出口 IP 时用）
#   warp-keeper.sh plus [KEY]  给当前账户套 WARP+ 许可证；不带 KEY 就从 env 里 WARP_PLUS 指定的来源取
#   warp-keeper.sh sync        按当前版本和 env 重新生成片段，有变化才重载（update.sh 用）
#   warp-keeper.sh remove      删掉配置片段、重载 sing-box、注销账户（主配置还在引用 tag 时会拒绝）
#
# 工作方式：在 sing-box 的配置目录（systemd 里 -C 指定的那个）放一个独立的 JSON 片段：
#   · wireguard endpoint（tag 默认「🧩 <WARP>」，你的路由规则直接引用它）
#   · 一个只监听 127.0.0.1 的 mixed 入站（默认 18650，可以顶替原来 wireproxy 的 socks5 地址）
#   · 一条规则：这个入站的流量全部走上面的 endpoint
# sing-box 按文件名合并目录里的所有 .json，主配置一行不用改。
# 配置在 /etc/warp-keeper.env，状态在 /var/lib/warp-keeper/。
VERSION="1.0.0"

[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -uo pipefail
umask 077

ENV_FILE="${WARP_KEEPER_ENV:-/etc/warp-keeper.env}"
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

# ---------- 配置（含义见 warp-keeper.env.example）----------
WARP_NAME="${WARP_NAME:-}"
WARP_TAG="${WARP_TAG:-🧩 <WARP>}"
LOCAL_PORT="${LOCAL_PORT:-18650}"
STACK="${STACK:-dual}"                      # dual / v4 / v6
MTU="${MTU:-1280}"
PEER="${PEER:-auto}"                        # auto = 注册时 Cloudflare 给的地址；也可以写死 IP 或域名
PEER_PORT="${PEER_PORT:-2408}"
KEEPALIVE="${KEEPALIVE:-30}"
WARP_PLUS="${WARP_PLUS:-off}"               # off / auto / tg / 许可证本身
WARP_PLUS_CHANNEL="${WARP_PLUS_CHANNEL:-https://t.me/s/warpplus}"
RENEW_MIN_GAP="${RENEW_MIN_GAP:-360}"       # 分钟：两次自动换号的最小间隔
SB_SERVICE="${SB_SERVICE:-sing-box}"
SB_CONFIG_DIR="${SB_CONFIG_DIR:-}"
FRAGMENT_NAME="${FRAGMENT_NAME:-00-warp-keeper.json}"
TIMEZONE="${TIMEZONE:-Asia/Taipei}"
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
TG_NOTIFY="${TG_NOTIFY:-change}"            # change / all / off
TG_REPEAT_HOURS="${TG_REPEAT_HOURS:-6}"
TG_SUMMARY_HOUR="${TG_SUMMARY_HOUR:-9}"     # 每天几点发日报，留空不发
SONDE_URL="${SONDE_URL:-}"
SONDE_TOKEN="${SONDE_TOKEN:-}"
WARP_API="${WARP_API:-https://api.cloudflareclient.com/v0a2158}"
WARP_UA="${WARP_UA:-okhttp/3.12.1}"
WARP_CLIENT_VER="${WARP_CLIENT_VER:-a-6.10-2158}"

export TZ="$TIMEZONE"
STATE_DIR=/var/lib/warp-keeper
ACC="$STATE_DIR/account.json"
STATE="$STATE_DIR/state"
HIST="$STATE_DIR/checks.log"
BADKEYS="$STATE_DIR/bad-keys"
IN_TAG="warp-keeper-in"
HOST="$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname)"
[[ -n "$WARP_NAME" ]] || WARP_NAME="$HOST"
NOW=$(date +%s)

log()  { printf '%s\n' "$*"; }
warn() { printf '警告: %s\n' "$*" >&2; }
fatal() { printf '错误: %s\n' "$*" >&2; exit 1; }

# ---------- 状态文件（key=value，只有本脚本写）----------
LAST_OK=0 FAIL_SINCE=0 LAST_RENEW=0 RENEW_TOTAL=0 RELOAD_TOTAL=0 LAST_PLUS_TRY=0
LAST_KIND="" LAST_ALERT=0 LAST_SUMMARY_DAY="" LAST_REASON=""
load_state() {
  local k v
  [[ -f "$STATE" ]] || return 0
  while IFS='=' read -r k v; do
    case "$k" in
      LAST_OK|FAIL_SINCE|LAST_RENEW|RENEW_TOTAL|RELOAD_TOTAL|LAST_PLUS_TRY|LAST_ALERT)
        [[ "$v" =~ ^[0-9]+$ ]] && printf -v "$k" '%s' "$v" ;;
      LAST_KIND|LAST_SUMMARY_DAY|LAST_REASON) printf -v "$k" '%s' "$v" ;;
    esac
  done < "$STATE"
}
save_state() {
  local k
  {
    for k in LAST_OK FAIL_SINCE LAST_RENEW RENEW_TOTAL RELOAD_TOTAL LAST_PLUS_TRY LAST_KIND LAST_ALERT LAST_SUMMARY_DAY; do
      printf '%s=%s\n' "$k" "${!k}"
    done
    printf 'LAST_REASON=%s\n' "${LAST_REASON//$'\n'/ }"
  } > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

# 同一时间只跑一个（timer 和手动命令撞上时，手动的等一会儿）
take_lock() {
  exec 9>/run/warp-keeper.lock
  if [[ "${1:-}" == wait ]]; then
    flock -w 180 9 || fatal "另一个 warp-keeper 一直在运行（3 分钟没结束），稍后再试"
  else
    flock -n 9 || { log "另一个 warp-keeper 正在运行，这次跳过"; exit 0; }
  fi
}

need_root() { [[ $EUID -eq 0 ]] || fatal "请用 root 运行"; }
need_deps() {
  local c miss=()
  for c in curl jq ss flock base64 od systemctl; do command -v "$c" >/dev/null || miss+=("$c"); done
  (( ${#miss[@]} == 0 )) || fatal "缺少命令：${miss[*]}（重新运行 install.sh 会自动安装）"
}

# ---------- sing-box：从 systemd 单元里读出它实际的启动参数 ----------
SB_BIN="" SB_ARGS=() SB_DIRS=() SB_DIR=""
sb_detect() {
  local line words i w
  line=$(systemctl show -p ExecStart --value "$SB_SERVICE" 2>/dev/null | sed -n 's/.*argv\[\]=\([^;]*\) ;.*/\1/p' | head -1)
  [[ -n "$line" ]] || fatal "读不到 $SB_SERVICE.service 的启动命令（服务名不对？在 env 里设 SB_SERVICE）"
  read -ra words <<<"$line"
  SB_BIN=${words[0]}
  SB_ARGS=() SB_DIRS=()
  for ((i = 1; i < ${#words[@]}; i++)); do
    w=${words[i]}
    case "$w" in
      run) ;;
      -C|--config-directory) SB_ARGS+=("$w" "${words[i+1]:-}"); SB_DIRS+=("${words[i+1]:-}"); ((i++)) ;;
      --config-directory=*)  SB_ARGS+=("$w"); SB_DIRS+=("${w#*=}") ;;
      *) SB_ARGS+=("$w") ;;
    esac
  done
  if [[ -n "$SB_CONFIG_DIR" ]]; then
    local d ok=""
    for d in "${SB_DIRS[@]}"; do [[ "${d%/}" == "${SB_CONFIG_DIR%/}" ]] && ok=1; done
    [[ -n "$ok" ]] || fatal "SB_CONFIG_DIR=$SB_CONFIG_DIR，但 $SB_SERVICE 的启动命令里没有 -C $SB_CONFIG_DIR：
  sing-box 不会读这个目录里的片段。启动命令：$line"
    SB_DIR=${SB_CONFIG_DIR%/}
  elif (( ${#SB_DIRS[@]} )); then
    SB_DIR=${SB_DIRS[0]%/}
  else
    fatal "$SB_SERVICE 是用单个配置文件启动的（没有 -C 配置目录），sing-box 不会读额外的片段。
  启动命令：$line
  改法（会影响整个 sing-box 服务，改完要重启，期间所有入站断开几秒）：
    systemctl edit $SB_SERVICE    写入下面三行（-c 换成你现在的配置文件）
      [Service]
      ExecStart=
      ExecStart=$SB_BIN -D /var/lib/sing-box -c /etc/sing-box/config.json -C /etc/sing-box run
    然后：$SB_BIN -c /etc/sing-box/config.json -C /etc/sing-box check && systemctl restart $SB_SERVICE"
  fi
  FRAG="$SB_DIR/$FRAGMENT_NAME"
}
sb_check() { "$SB_BIN" "${SB_ARGS[@]}" check 2>&1; }
sb_version() { "$SB_BIN" version 2>/dev/null | sed -n '1s/.*version //p'; }
sb_active() { systemctl is-active --quiet "$SB_SERVICE"; }
port_owner() { ss -Hltnp "sport = :$LOCAL_PORT" 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | head -1 | cut -d'"' -f2; }
wait_port() {   # 重载后等 mixed 入站重新监听（最多 20 秒）
  local i
  for ((i = 0; i < 40; i++)); do [[ "$(port_owner)" == sing-box* ]] && return 0; sleep 0.5; done
  return 1
}
sb_reload() {
  if [[ "$(systemctl show -p CanReload --value "$SB_SERVICE")" == yes ]]; then
    systemctl reload "$SB_SERVICE"
  else
    systemctl kill -s HUP --kill-whom=main "$SB_SERVICE"
  fi || return 1
  sleep 2; wait_port
}

# ---------- Cloudflare WARP API ----------
API_CODE="" API_BODY=""
api() {   # api METHOD PATH [JSON] [TOKEN]；成功（2xx）返回 0
  local m=$1 p=$2 body=${3:-} tok=${4:-} out
  local args=(-sS -m 20 -X "$m" -H "User-Agent: $WARP_UA" -H "CF-Client-Version: $WARP_CLIENT_VER"
              -H 'Content-Type: application/json; charset=UTF-8' -w $'\n%{http_code}')
  [[ -n "$tok" ]] && args+=(-H "Authorization: Bearer $tok")
  [[ -n "$body" ]] && args+=(--data "$body")
  out=$(curl "${args[@]}" "$WARP_API$p" 2>&1) || true
  API_CODE=${out##*$'\n'}; API_BODY=${out%$'\n'*}
  [[ "$API_CODE" =~ ^2[0-9][0-9]$ ]]
}
api_err() {   # 从 API 返回里挑出可读的错误
  local e
  e=$(jq -r '[.errors[]?.message, .error?, .message?] | map(select(. != null and . != "")) | first // empty' <<<"$API_BODY" 2>/dev/null)
  [[ -n "$e" ]] || e=$(head -c 160 <<<"$API_BODY" | tr '\n' ' ')
  printf '%s' "$e"
}

REG_ERR=""
register_to() {   # register_to 文件：注册新设备，把需要的字段存进文件
  local kp priv pub body
  kp=$("$SB_BIN" generate wg-keypair 2>/dev/null) || { REG_ERR="sing-box 生成密钥失败"; return 1; }
  priv=$(awk '/^PrivateKey:/{print $2}' <<<"$kp"); pub=$(awk '/^PublicKey:/{print $2}' <<<"$kp")
  [[ -n "$priv" && -n "$pub" ]] || { REG_ERR="解析不出密钥对"; return 1; }
  body=$(jq -nc --arg k "$pub" --arg t "$(date -u +%FT%T.000Z)" \
    '{key: $k, install_id: "", fcm_token: "", tos: $t, model: "PC", serial_number: "", locale: "en_US"}')
  api POST /reg "$body" || { REG_ERR="注册失败（HTTP ${API_CODE}）$(api_err)"; return 1; }
  jq -e '.id and .token and .config.peers[0].public_key and .config.interface.addresses.v4' >/dev/null 2>&1 <<<"$API_BODY" \
    || { REG_ERR="注册返回的数据不完整：$(head -c 160 <<<"$API_BODY")"; return 1; }
  jq --arg priv "$priv" --argjson now "$NOW" '{
      id, token, private_key: $priv,
      peer_public_key: .config.peers[0].public_key,
      endpoint_v4: ((.config.peers[0].endpoint.v4 // "") | sub(":[0-9]+$"; "")),
      endpoint_v6: ((.config.peers[0].endpoint.v6 // "") | sub(":[0-9]+$"; "") | ltrimstr("[") | rtrimstr("]")),
      endpoint_host: ((.config.peers[0].endpoint.host // "") | sub(":[0-9]+$"; "")),
      v4: .config.interface.addresses.v4, v6: .config.interface.addresses.v6,
      client_id: (.config.client_id // ""),
      account_type: (.account.account_type // "free"),
      created: $now}' <<<"$API_BODY" > "$1.tmp" && mv "$1.tmp" "$1" && chmod 600 "$1"
}
acc() { jq -r ".$1 // empty" "${2:-$ACC}" 2>/dev/null; }
account_alive() {   # alive / dead / unknown
  api GET "/reg/$(acc id)" "" "$(acc token)" && { echo alive; return; }
  case "$API_CODE" in 401|403|404) echo dead ;; *) echo unknown ;; esac
}
cancel_account() {   # cancel_account 账户文件 [说明]：注销设备（失败也无所谓，只是在 Cloudflare 那边留个僵尸设备）
  local id tok what=${2:-旧设备}
  id=$(acc id "$1"); tok=$(acc token "$1")
  [[ -n "$id" && -n "$tok" ]] || return 0
  if api DELETE "/reg/$id" "" "$tok"; then log "已注销$what"; else warn "注销${what}失败（HTTP $API_CODE），不影响使用"; fi
}

# ---------- WARP+ ----------
plus_keys() {   # 候选许可证，一行一个，最新的在前
  case "$WARP_PLUS" in
    off|"") return 0 ;;
    auto|tg)
      curl -fsSL -m 15 "$WARP_PLUS_CHANNEL" 2>/dev/null \
        | grep -oE '[A-Za-z0-9]{8}-[A-Za-z0-9]{8}-[A-Za-z0-9]{8}' | tac | awk '!seen[$0]++' | head -n 15 ;;
    *) tr ' ,' '\n\n' <<<"$WARP_PLUS" | grep -E '^[A-Za-z0-9]{8}-[A-Za-z0-9]{8}-[A-Za-z0-9]{8}$' ;;
  esac
}
PLUS_ERR=""
apply_plus() {   # apply_plus 账户文件 [指定许可证]：套上就返回 0，并把账户类型写回文件
  local f=$1 keys k id tok n=0 type
  id=$(acc id "$f"); tok=$(acc token "$f")
  if [[ -n "${2:-}" ]]; then keys=$2; else keys=$(plus_keys); fi
  [[ -n "$keys" ]] || { PLUS_ERR="没有拿到可用的许可证"; [[ "$WARP_PLUS" == auto || "$WARP_PLUS" == tg ]] && PLUS_ERR+="（频道打不开或页面格式变了）"; return 1; }
  touch "$BADKEYS"
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    [[ -z "${2:-}" ]] && grep -qxF "$k" "$BADKEYS" && continue
    (( n++ >= 10 )) && break
    if api PUT "/reg/$id/account" "$(jq -nc --arg l "$k" '{license: $l}')" "$tok"; then
      api GET "/reg/$id/account" "" "$tok" || true
      type=$(jq -r '.account_type // empty' <<<"$API_BODY" 2>/dev/null)
      if [[ "$type" == limited || "$type" == unlimited ]]; then
        jq --arg t "$type" '.account_type = $t' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
        log "已套用 WARP+ 许可证（账户类型 $type）"
        return 0
      fi
      PLUS_ERR="许可证套上了，但账户类型还是 ${type:-未知}"
    else
      PLUS_ERR="HTTP $API_CODE $(api_err)"
    fi
    echo "$k" >> "$BADKEYS"
    log "许可证不可用：$PLUS_ERR"
  done <<<"$keys"
  tail -n 300 "$BADKEYS" > "$BADKEYS.tmp" && mv "$BADKEYS.tmp" "$BADKEYS"
  [[ -n "$PLUS_ERR" ]] || PLUS_ERR="候选许可证都试过了，没有能用的"
  return 1
}
is_plus() { [[ "$(acc account_type "${1:-$ACC}")" == limited || "$(acc account_type "${1:-$ACC}")" == unlimited ]]; }

# ---------- 配置片段 ----------
build_fragment() {   # build_fragment 账户文件 → stdout
  local f=$1 res rjson host addr allowed
  res=$(acc client_id "$f" | base64 -d 2>/dev/null | od -An -tu1 | xargs)
  rjson=$(jq -nc --arg r "$res" '$r | split(" ") | map(select(length > 0) | tonumber)')
  [[ $(jq length <<<"$rjson") == 3 ]] || rjson='[]'
  host=$PEER
  if [[ "$host" == auto ]]; then
    if ip -4 route show default 2>/dev/null | grep -q .; then host=$(acc endpoint_v4 "$f"); else host=$(acc endpoint_v6 "$f"); fi
    [[ -n "$host" ]] || host="engage.cloudflareclient.com"
  fi
  case "$STACK" in
    v4) addr=$(jq -nc --arg a "$(acc v4 "$f")" '[$a + "/32"]'); allowed='["0.0.0.0/0"]' ;;
    v6) addr=$(jq -nc --arg b "$(acc v6 "$f")" '[$b + "/128"]'); allowed='["::/0"]' ;;
    *)  addr=$(jq -nc --arg a "$(acc v4 "$f")" --arg b "$(acc v6 "$f")" '[$a + "/32", $b + "/128"]'); allowed='["0.0.0.0/0", "::/0"]' ;;
  esac
  jq -n --arg tag "$WARP_TAG" --arg in "$IN_TAG" --argjson port "$LOCAL_PORT" --argjson mtu "$MTU" \
    --argjson addr "$addr" --arg key "$(acc private_key "$f")" --arg host "$host" --argjson pport "$PEER_PORT" \
    --arg pub "$(acc peer_public_key "$f")" --argjson allowed "$allowed" --argjson ka "$KEEPALIVE" --argjson res "$rjson" '{
    inbounds: [{type: "mixed", tag: $in, listen: "127.0.0.1", listen_port: $port}],
    endpoints: [{type: "wireguard", tag: $tag, mtu: $mtu, address: $addr, private_key: $key,
      peers: [({address: $host, port: $pport, public_key: $pub, allowed_ips: $allowed,
                persistent_keepalive_interval: $ka} + (if ($res | length) == 3 then {reserved: $res} else {} end))]}],
    route: {rules: [{inbound: [$in], action: "route", outbound: $tag}]}
  }'
}
# 写片段 → sing-box check → 失败就恢复原样。返回 0 = 已写入并通过检查（还没重载），1 = 失败，2 = 和现在的一样
# 临时文件不能以 .json 结尾：sing-box 会把配置目录里所有 .json 都读进去
CHECK_ERR=""
write_fragment() {   # write_fragment 账户文件
  local tmp="$SB_DIR/.warp-keeper.tmp" out
  build_fragment "$1" > "$tmp" || { rm -f "$tmp"; CHECK_ERR="生成配置片段失败"; return 1; }
  if [[ -f "$FRAG" ]] && cmp -s "$tmp" "$FRAG"; then rm -f "$tmp"; return 2; fi
  rm -f "$STATE_DIR/fragment.prev"
  [[ -f "$FRAG" ]] && cp -p "$FRAG" "$STATE_DIR/fragment.prev"
  chmod 600 "$tmp"; mv "$tmp" "$FRAG"
  if ! out=$(sb_check); then
    CHECK_ERR=$(tail -n 3 <<<"$out")
    restore_fragment
    return 1
  fi
}
restore_fragment() {
  if [[ -f "$STATE_DIR/fragment.prev" ]]; then cp -p "$STATE_DIR/fragment.prev" "$FRAG"; else rm -f "$FRAG"; fi
}

# ---------- 探测：经本机 mixed 入站访问 Cloudflare trace ----------
# 目标直接写 IP，不依赖 DNS；延迟取「TLS 握手完成 → 收到第一个字节」，约等于一个往返
declare -A P_WARP P_COLO P_LOC P_RTT
probe_one() {   # probe_one 4|6
  local url out t meta
  [[ $1 == 4 ]] && url='https://1.1.1.1/cdn-cgi/trace' || url='https://[2606:4700:4700::1111]/cdn-cgi/trace'
  out=$(curl -gsS -m 12 --proxy "socks5://127.0.0.1:$LOCAL_PORT" -w $'\n__T %{time_appconnect} %{time_starttransfer}' "$url" 2>/dev/null) || out=""
  P_WARP[$1]=$(sed -n 's/^warp=//p' <<<"$out"); P_COLO[$1]=$(sed -n 's/^colo=//p' <<<"$out"); P_LOC[$1]=$(sed -n 's/^loc=//p' <<<"$out")
  meta=$(sed -n 's/^__T //p' <<<"$out")
  t=$(awk '{ if ($2 > 0 && $2 >= $1) printf "%d", ($2 - $1) * 1000 + 0.5 }' <<<"$meta")
  P_RTT[$1]=$t
  [[ "${P_WARP[$1]}" == on || "${P_WARP[$1]}" == plus ]]
}
stacks() { case "$STACK" in v4) echo 4 ;; v6) echo 6 ;; *) echo "4 6" ;; esac; }
PROBE_FAIL=""
probe_all() {   # 每个栈最多试 2 次，全部通过返回 0；PROBE_FAIL 写哪个栈不通
  local s ok=0
  PROBE_FAIL=""
  for s in $(stacks); do
    probe_one "$s" || { sleep 5; probe_one "$s"; } || { PROBE_FAIL+="${PROBE_FAIL:+、}IPv$s"; ok=1; }
  done
  return $ok
}
direct_ok() { curl -sS -m 8 -o /dev/null https://1.1.1.1/cdn-cgi/trace 2>/dev/null || curl -gsS -m 8 -o /dev/null 'https://[2606:4700:4700::1111]/cdn-cgi/trace' 2>/dev/null; }

# ---------- 可用率历史 ----------
record() {   # record ok(1/0)
  printf '%s %s %s %s\n' "$NOW" "$1" "${P_RTT[4]:--}" "${P_RTT[6]:--}" >> "$HIST"
  awk -v t=$((NOW - 8 * 86400)) '$1 >= t' "$HIST" > "$HIST.tmp" && mv "$HIST.tmp" "$HIST"
}
uptime_of() {   # uptime_of 秒数 → 「通过 总数」
  [[ -f "$HIST" ]] || { echo "0 0"; return; }
  awk -v t=$((NOW - $1)) '$1 >= t { n++; ok += $2 } END { printf "%d %d\n", ok, n }' "$HIST"
}
avg_rtt() {   # avg_rtt 4|6 秒数
  [[ -f "$HIST" ]] || return 0
  local col=3; [[ $1 == 6 ]] && col=4
  awk -v t=$((NOW - $2)) -v c=$col '$1 >= t && $c != "-" { s += $c; n++ } END { if (n) printf "%d", s / n + 0.5 }' "$HIST"
}

# ---------- 文字 ----------
h() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }
# 发出去之前把漏网的 IP、网址、域名替换掉（和 cfst-ddns / traffic-bot 同一套规则）
scrub() {
  sed -E -e 's#[a-zA-Z][a-zA-Z0-9+.-]*://[^ <>"）)]*#***#g' \
         -e 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?\b/***/g' \
         -e 's/\b[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{0,4}){2,7}(\/[0-9]{1,3})?\b/***/g' \
         -e 's/\b([a-zA-Z0-9-]+\.)+(com|net|org|xyz|io|dev|app|cn|me|top|cc|co|info|cloud|site|tech|link|one|uk|jp|kr|hk|tw|us|de|fr)\b/***/g' <<<"$1"
}
ago() {
  local s=$(( NOW - $1 ))
  (( $1 == 0 )) && { echo "从未"; return; }
  if (( s < 3600 )); then echo "$(( s / 60 )) 分钟前"
  elif (( s < 86400 )); then echo "$(( s / 3600 )) 小时前"
  else echo "$(( s / 86400 )) 天前"; fi
}
acct_label() { is_plus && echo "WARP+" || echo "WARP"; }
acct_days() { local c; c=$(acc created); [[ -n "$c" ]] && echo $(( (NOW - c) / 86400 )) || echo 0; }
pct() { awk -v a="$1" -v b="$2" 'BEGIN { if (b > 0) printf "%.1f%%", a * 100 / b; else printf "–" }'; }
stack_line() {   # IPv4 一行：状态 · 出口机房 · 延迟
  local s=$1 w=${P_WARP[$1]:-}
  case "$w" in
    plus) printf 'IPv%s ✅ WARP+ · 出口 %s（%s）· %s ms' "$s" "${P_COLO[$s]:-?}" "${P_LOC[$s]:-?}" "${P_RTT[$s]:-?}" ;;
    on)   printf 'IPv%s ✅ WARP · 出口 %s（%s）· %s ms' "$s" "${P_COLO[$s]:-?}" "${P_LOC[$s]:-?}" "${P_RTT[$s]:-?}" ;;
    off)  printf 'IPv%s ⚠️ 走到了 Cloudflare 但不是 WARP（%s）' "$s" "${P_COLO[$s]:-?}" ;;
    *)    printf 'IPv%s ❌ 不通' "$s" ;;
  esac
}

# ---------- Telegram ----------
KIND="" ACTION="" REASON="" NOTE="" FORCE_TG=""
tg_send() {   # tg_send HTML
  local msg resp why
  [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]] || return 0
  msg=$(scrub "$1")
  resp=$(curl -sS -m 15 "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" --data-urlencode "text=${msg}" \
    -d parse_mode=HTML -d disable_web_page_preview=true 2>&1) || true
  if jq -e '.ok' >/dev/null 2>&1 <<<"$resp"; then log "已发送 Telegram 消息"; return 0; fi
  why=$(jq -r '.description // empty' <<<"$resp" 2>/dev/null)
  warn "Telegram 发送失败：${why:-${resp:0:200}}"
  if [[ "$why" == *"parse entities"* ]]; then   # 格式出错时去掉标签再发一次，别把告警丢了
    msg=$(sed -e 's/<[^>]*>//g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g' <<<"$msg")
    curl -sS -m 15 "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TG_CHAT_ID}" --data-urlencode "text=${msg}" -d disable_web_page_preview=true >/dev/null 2>&1 \
      && log "已改用纯文本重发"
  fi
}
body_lines() {   # 引用块里的内容：每个栈一行 + 可用率 + 账户
  local s a b out="" up24 up7
  for s in $(stacks); do out+="$(h "$(stack_line "$s")")"$'\n'; done
  read -r a b <<<"$(uptime_of 86400)"; up24="$(pct "$a" "$b")（${a}/${b}）"
  read -r a b <<<"$(uptime_of $((7 * 86400)))"; up7=$(pct "$a" "$b")
  out+="📈 可用率 24 小时 <b>${up24}</b> · 7 天 ${up7}"$'\n'
  out+="🪪 $(acct_label) 账户 · 已用 $(acct_days) 天 · 自动换号 ${RENEW_TOTAL} 次"
  (( RENEW_TOTAL )) && out+="（上次 $(ago "$LAST_RENEW")）"
  printf '%s' "$out"
}
notify() {
  local title msg send="" repeat=$(( TG_REPEAT_HOURS * 3600 ))
  [[ "$TG_NOTIFY" == off ]] && return 0
  case "$KIND" in
    ok)        title="🩺 <b>WARP · $(h "$WARP_NAME") · 正常</b>" ;;
    recovered) title="✅ <b>WARP · $(h "$WARP_NAME") · 已恢复</b>" ;;
    init)      title="🆕 <b>WARP · $(h "$WARP_NAME") · 已部署</b>" ;;
    renewed)   title="🔄 <b>WARP · $(h "$WARP_NAME") · 已换号</b>" ;;
    plus)      title="⭐ <b>WARP · $(h "$WARP_NAME") · 已升级 WARP+</b>" ;;
    sbdown)    title="⛔ <b>WARP · $(h "$WARP_NAME") · sing-box 没在运行</b>" ;;
    netdown)   title="📴 <b>WARP · $(h "$WARP_NAME") · 本机断网</b>" ;;
    *)         title="❌ <b>WARP · $(h "$WARP_NAME") · 不可用</b>" ;;
  esac
  # change：出问题、做了自愈动作、故障类型变了；故障一直没好就每隔 TG_REPEAT_HOURS 小时提醒一次。
  # 正常（ok）不发——恢复的那一次已经发过「已恢复」
  if [[ "$TG_NOTIFY" == all || -n "$FORCE_TG" || -n "$ACTION" ]]; then send=1
  elif [[ "$KIND" != ok && "$KIND" != "$LAST_KIND" ]]; then send=1
  elif [[ "$KIND" != ok && "$KIND" != recovered ]] && (( NOW - LAST_ALERT >= repeat )); then send=1; fi
  [[ -n "$send" ]] || return 0
  msg="$title"
  [[ -n "$ACTION" ]] && msg+=$'\n'"🛠 $(h "$ACTION")"
  [[ -n "$REASON" ]] && msg+=$'\n'"⚠️ <b>$(h "$REASON")</b>"
  (( FAIL_SINCE > 0 && NOW - FAIL_SINCE >= 60 )) && [[ "$KIND" != ok && "$KIND" != recovered ]] && msg+=$'\n'"⏳ 已持续 $(ago "$FAIL_SINCE" | sed 's/ *前//')"
  msg+=$'\n'"<blockquote>$(body_lines)</blockquote>"
  [[ -n "$NOTE" ]] && msg+=$'\n'"💡 $(h "$NOTE")"
  msg+=$'\n'"<i>🖥 $(h "$HOST") · $(date '+%m-%d %H:%M') · warp-keeper v${VERSION}</i>"
  tg_send "$msg" && LAST_ALERT=$NOW
}
summary_due() {   # 每天 TG_SUMMARY_HOUR 点后的第一次检查发日报
  [[ -n "$TG_SUMMARY_HOUR" && "$TG_NOTIFY" != off ]] || return 1
  (( 10#$(date +%H) >= 10#$TG_SUMMARY_HOUR )) && [[ "$LAST_SUMMARY_DAY" != "$(date +%F)" ]]
}
send_summary() {
  local msg r4 r6
  r4=$(avg_rtt 4 86400); r6=$(avg_rtt 6 86400)
  msg="📋 <b>WARP · $(h "$WARP_NAME") · 日报</b>"
  msg+=$'\n'"<blockquote>$(body_lines)</blockquote>"
  msg+=$'\n'"⏱ 24 小时平均延迟：IPv4 ${r4:-–} ms · IPv6 ${r6:-–} ms · 重载 ${RELOAD_TOTAL} 次"
  msg+=$'\n'"<i>🖥 $(h "$HOST") · sing-box $(h "$(sb_version)") · warp-keeper v${VERSION}</i>"
  tg_send "$msg" && LAST_SUMMARY_DAY=$(date +%F)
}

# ---------- Sonde ----------
sonde_report() {
  [[ -n "$SONDE_URL" && -n "$SONDE_TOKEN" ]] || return 0
  local id up24 up7 a b series body s stk="[]" r4 r6
  id=$(tr 'A-Z' 'a-z' <<<"$WARP_NAME" | tr -c 'a-z0-9_-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//' | cut -c1-48)
  read -r a b <<<"$(uptime_of 86400)"; up24=$(jq -nc --argjson a "$a" --argjson b "$b" '{ok: $a, n: $b}')
  read -r a b <<<"$(uptime_of $((7 * 86400)))"; up7=$(jq -nc --argjson a "$a" --argjson b "$b" '{ok: $a, n: $b}')
  for s in $(stacks); do
    stk=$(jq -c --arg s "$s" --arg w "${P_WARP[$s]:-}" --arg c "${P_COLO[$s]:-}" --arg l "${P_LOC[$s]:-}" --arg r "${P_RTT[$s]:-}" \
      '. + [{stack: ("IPv" + $s), warp: $w, colo: $c, loc: $l, rtt: ($r | tonumber? // null)}]' <<<"$stk")
  done
  r4=${P_RTT[4]:-}; r6=${P_RTT[6]:-}
  series=$(jq -nc --arg r4 "$r4" --arg r6 "$r6" --argjson up "$([[ "$KIND" == ok || "$KIND" == recovered || "$KIND" == init || "$KIND" == renewed || "$KIND" == plus ]] && echo 1 || echo 0)" \
    '{up: $up} + (if $r4 != "" then {rtt4: ($r4 | tonumber)} else {} end) + (if $r6 != "" then {rtt6: ($r6 | tonumber)} else {} end)')
  body=$(jq -nc --arg source "warp-keeper:${id:-host}" --argjson series "$series" \
    --arg name "$WARP_NAME" --arg host "$HOST" --arg kind "$KIND" --arg action "$(scrub "$ACTION")" --arg reason "$(scrub "$REASON")" \
    --arg note "$(scrub "$NOTE")" --argjson stacks "$stk" --arg account "$(acct_label)" --argjson days "$(acct_days)" \
    --argjson renews "$RENEW_TOTAL" --argjson last_renew "$LAST_RENEW" --argjson reloads "$RELOAD_TOTAL" \
    --argjson fail_since "$FAIL_SINCE" --argjson last_ok "$LAST_OK" --argjson up24 "$up24" --argjson up7 "$up7" \
    --argjson last_fail "$(awk '$2 == 0 { t = $1 } END { print t + 0 }' "$HIST" 2>/dev/null || echo 0)" \
    --arg plus_mode "$( [[ "$WARP_PLUS" =~ ^(off|auto|tg|)$ ]] && echo "${WARP_PLUS:-off}" || echo key)" \
    --arg sb "$(sb_version)" --arg ver "$VERSION" --argjson mtu "$MTU" --arg stack "$STACK" \
    '{source: $source, ts: now | floor, interval: 3600, series: $series,
      data: {name: $name, host: $host, kind: $kind, action: $action, reason: $reason, note: $note,
             stacks: $stacks, account: $account, account_days: $days, renews: $renews, last_renew: $last_renew,
             reloads: $reloads, fail_since: $fail_since, last_ok: $last_ok, last_fail: $last_fail, up24: $up24, up7: $up7,
             plus_mode: $plus_mode, singbox: $sb, version: $ver, mtu: $mtu, stack: $stack}}') \
    || { warn "Sonde 上报数据生成失败"; return 0; }
  if curl -sS -m 10 -o /dev/null -w '%{http_code}' -X POST "${SONDE_URL%/}/ingest" \
       -H "Authorization: Bearer $SONDE_TOKEN" -H 'Content-Type: application/json' --data-binary "$body" 2>/dev/null | grep -q '^200$'; then
    log "已上报 Sonde"
  else
    warn "Sonde 上报失败"
  fi
}

# 一轮结束：记历史、更新状态、发通知、上报
finish() {
  local good=0
  case "$KIND" in ok|recovered|init|renewed|plus) good=1 ;; esac
  if [[ "$KIND" != sbdown && "$KIND" != netdown ]]; then record "$good"; fi
  if (( good )); then LAST_OK=$NOW; FAIL_SINCE=0; else (( FAIL_SINCE )) || FAIL_SINCE=$NOW; fi
  LAST_REASON=$REASON
  log "结果：$KIND${ACTION:+ · $ACTION}${REASON:+ · $REASON}"
  local s; for s in $(stacks); do log "  $(stack_line "$s")"; done
  notify || true
  summary_due && { send_summary || true; }
  LAST_KIND=$KIND
  save_state
  sonde_report || true
  (( good )) && exit 0
  exit 1
}

# ---------- 换号：注册新账户 → 写片段 → 检查 → 重载 → 验证；失败就退回原来的 ----------
RENEW_ERR=""
renew() {
  local new="$STATE_DIR/account.new"
  register_to "$new" || { RENEW_ERR=$REG_ERR; return 1; }
  if [[ "$WARP_PLUS" != off ]]; then apply_plus "$new" || log "WARP+ 没套上（$PLUS_ERR），先用免费账户"; fi
  cp -p "$ACC" "$STATE_DIR/account.prev" 2>/dev/null || true
  local rc=0
  write_fragment "$new" || rc=$?
  if (( rc == 1 )); then RENEW_ERR="sing-box check 不通过：$CHECK_ERR"; cancel_account "$new" 没用上的新设备; rm -f "$new"; return 1; fi
  if ! sb_reload; then
    RENEW_ERR="重载 sing-box 后入站没起来"
    restore_fragment; sb_reload; cancel_account "$new" 没用上的新设备; rm -f "$new"; return 1
  fi
  RELOAD_TOTAL=$((RELOAD_TOTAL + 1))
  sleep 3
  if ! probe_all; then
    RENEW_ERR="新账户也不通（$PROBE_FAIL），已退回原来的配置"
    restore_fragment; sb_reload; cancel_account "$new" 没用上的新设备; rm -f "$new"; return 1
  fi
  [[ -f "$ACC" ]] && cancel_account "$ACC"
  mv "$new" "$ACC"
  LAST_RENEW=$NOW; RENEW_TOTAL=$((RENEW_TOTAL + 1))
  return 0
}

# ---------- 命令 ----------
cmd_init() {
  need_root; need_deps; take_lock wait; load_state
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  sb_detect
  local v; v=$(sb_version)
  [[ -n "$v" ]] || fatal "$SB_BIN 运行不了"
  if [[ "$(printf '%s\n' 1.11.0 "${v%%-*}" | sort -V | head -1)" != 1.11.0 ]]; then fatal "sing-box $v 太旧，wireguard endpoint 需要 1.11 以上"; fi
  log "sing-box $v · 配置目录 $SB_DIR · 片段 $FRAGMENT_NAME"

  # 端口：没被占用，或者已经是本脚本让 sing-box 监听的
  local owner; owner=$(port_owner)
  if [[ -n "$owner" && ! ( "$owner" == sing-box* && -f "$FRAG" ) ]]; then
    fatal "127.0.0.1:$LOCAL_PORT 已经被 $owner 占用。
  如果是原来的 wireproxy：systemctl disable --now wireproxy，再运行一次 init
  （或者在 /etc/warp-keeper.env 里换一个 LOCAL_PORT）"
  fi

  local fresh=""
  if [[ -s "$ACC" ]] && [[ "$(account_alive)" != dead ]]; then
    log "沿用现有账户（$(acct_label)，已用 $(acct_days) 天）"
    if [[ "$WARP_PLUS" != off ]] && ! is_plus; then apply_plus "$ACC" || log "WARP+ 没套上：$PLUS_ERR"; fi
  else
    log "注册 WARP 账户 ..."
    register_to "$ACC.new" || fatal "$REG_ERR"
    if [[ "$WARP_PLUS" != off ]]; then apply_plus "$ACC.new" || log "WARP+ 没套上（$PLUS_ERR），先用免费账户"; fi
    [[ -s "$ACC" ]] && cancel_account "$ACC"
    mv "$ACC.new" "$ACC"; fresh=1
    log "已注册（$(acct_label)）"
  fi

  log "写配置片段 $FRAG 并检查整套配置 ..."
  local rc=0
  write_fragment "$ACC" || rc=$?
  (( rc != 1 )) || fatal "sing-box check 不通过，已恢复原样：
$CHECK_ERR
  常见原因：主配置里还留着同名的「$WARP_TAG」（旧的 endpoint 或 socks 出站），删掉它（先别重启 sing-box），再运行 init"
  sb_active || fatal "$SB_SERVICE 没在运行。片段已经写好并通过检查，启动它：systemctl start $SB_SERVICE，然后运行 $0 status"
  if (( rc == 2 )) && [[ "$(port_owner)" == sing-box* ]]; then
    log "配置片段和现在的一样，不用重载 sing-box"
  else
    log "重载 sing-box（所有入站会断开一下）..."
    sb_reload || { restore_fragment; sb_reload; fatal "重载后 127.0.0.1:$LOCAL_PORT 没有监听，已恢复原来的配置。看日志：journalctl -u $SB_SERVICE -n 50"; }
    RELOAD_TOTAL=$((RELOAD_TOTAL + 1))
    sleep 3
  fi
  KIND=init; FORCE_TG=1
  LAST_SUMMARY_DAY=$(date +%F)          # 刚部署完就不再发今天的日报了
  [[ -n "$fresh" ]] && LAST_RENEW=$NOW   # 新账户也算一次「换号」时间：RENEW_MIN_GAP 内不会再自动换
  if ! probe_all; then
    KIND=failed; REASON="部署后探测不通（$PROBE_FAIL）"
    NOTE="确认 sing-box 版本带 wireguard，或者把 MTU 调小、换 PEER_PORT（500 / 1701 / 4500）后重新 init"
  fi
  finish
}

cmd_check() {
  need_root; need_deps; take_lock; load_state
  [[ -s "$ACC" ]] || fatal "还没有账户，先运行：$0 init"
  sb_detect
  if ! sb_active; then KIND=sbdown; REASON="$SB_SERVICE 没在运行，WARP 不做处理"; finish; fi
  if [[ "$(port_owner)" != sing-box* ]]; then
    if [[ ! -f "$FRAG" ]]; then   # 片段被删了：按现有账户重新写一份
      log "配置片段不见了，重新生成"
      if { write_fragment "$ACC" || [[ $? == 2 ]]; } && sb_reload; then ACTION="配置片段不见了，已重新生成并重载"; RELOAD_TOTAL=$((RELOAD_TOTAL + 1)); sleep 3
      else KIND=failed; REASON="重新生成配置片段失败：${CHECK_ERR:-重载后入站没起来}"; finish; fi
    else
      KIND=failed; REASON="sing-box 没有加载 warp-keeper 的片段（127.0.0.1:$LOCAL_PORT 没在监听）"
      NOTE="检查 $SB_SERVICE 的启动参数里有没有 -C $SB_DIR，或者手动 systemctl reload $SB_SERVICE"
      finish
    fi
  fi

  if probe_all; then
    if (( FAIL_SINCE )); then KIND=recovered; NOTE="${NOTE:-没做任何处理，自己好了}"; else KIND=ok; fi
    # 免费账户：每天试一次套 WARP+（许可证不改密钥，不用重载）
    if [[ "$WARP_PLUS" != off ]] && ! is_plus && (( NOW - LAST_PLUS_TRY >= 86400 )); then
      LAST_PLUS_TRY=$NOW
      if apply_plus "$ACC"; then ACTION="已升级 WARP+（下一次握手后生效，不用重载）"; else log "WARP+ 没套上：$PLUS_ERR"; fi
    fi
    finish
  fi

  log "探测不通（$PROBE_FAIL），开始排查"
  local s
  for s in $(stacks); do
    if [[ "${P_WARP[$s]:-}" == off ]]; then   # 到了 Cloudflare 却不是 WARP：流量没走 endpoint，换号也没用
      KIND=failed; REASON="探测流量没有走 WARP（IPv$s 显示 warp=off）"
      NOTE="sing-box 的路由没把 $IN_TAG 入站送到「$WARP_TAG」，用 sing-box merge 看合并后的规则"
      finish
    fi
  done
  if ! direct_ok; then KIND=netdown; REASON="直连 Cloudflare 也不通，是本机网络的问题，WARP 不做处理"; finish; fi

  local alive; alive=$(account_alive)
  log "账户状态：$alive"
  if [[ "$alive" != dead ]]; then
    log "第 1 步：重载 sing-box"
    if sb_reload; then
      RELOAD_TOTAL=$((RELOAD_TOTAL + 1)); sleep 5
      if probe_all; then KIND=recovered; ACTION="重载 sing-box 后恢复"; finish; fi
    fi
  fi

  local gap=$(( RENEW_MIN_GAP * 60 ))
  if [[ "$alive" != dead ]] && (( NOW - LAST_RENEW < gap )); then
    KIND=failed; REASON="$PROBE_FAIL 不通，重载也没用"
    NOTE="距上次换号不到 $((RENEW_MIN_GAP / 60)) 小时，这次先不换（RENEW_MIN_GAP）；急的话手动运行 warp-keeper.sh renew"
    finish
  fi
  log "第 2 步：换新账户"
  if renew; then
    KIND=recovered; ACTION="换了新账户后恢复（$( [[ $alive == dead ]] && echo "原账户已被 Cloudflare 删除" || echo "重载无效")）"
  else
    KIND=failed; ACTION="试过换号，没成功"; REASON="$PROBE_FAIL 不通，换号失败：$RENEW_ERR"
  fi
  finish
}

# 用现有账户按当前版本、当前 env 重新生成片段；和现在一样就什么都不做（update.sh 调用，不发 Telegram）
cmd_sync() {
  need_root; need_deps; take_lock wait; load_state
  [[ -s "$ACC" ]] || { log "还没有账户，跳过（首次请运行 init）"; exit 0; }
  sb_detect
  local rc=0
  write_fragment "$ACC" || rc=$?
  case $rc in
    2) log "配置片段和现在的一样，不用重载 sing-box"; exit 0 ;;
    1) fatal "新生成的片段 sing-box check 不通过，已保持原样：
$CHECK_ERR" ;;
  esac
  sb_active || { log "片段已更新；$SB_SERVICE 没在运行，下次启动时生效"; exit 0; }
  log "配置片段有变化，重载 sing-box（所有入站会断开一下）..."
  if ! sb_reload; then restore_fragment; sb_reload; fatal "重载后入站没起来，已退回原来的片段"; fi
  RELOAD_TOTAL=$((RELOAD_TOTAL + 1)); sleep 3
  if ! probe_all; then restore_fragment; sb_reload; save_state; fatal "新片段探测不通（$PROBE_FAIL），已退回原来的片段"; fi
  save_state
  log "已更新配置片段，WARP 正常"
}

cmd_renew() {
  need_root; need_deps; take_lock wait; load_state
  [[ -s "$ACC" ]] || fatal "还没有账户，先运行：$0 init"
  sb_detect
  sb_active || fatal "$SB_SERVICE 没在运行"
  log "换新账户（sing-box 会重载一次）..."
  if renew; then KIND=renewed; ACTION="手动换号"; FORCE_TG=1
  else fatal "$RENEW_ERR"; fi
  finish
}

cmd_plus() {
  need_root; need_deps; take_lock wait; load_state
  [[ -s "$ACC" ]] || fatal "还没有账户，先运行：$0 init"
  sb_detect
  local key=${1:-}
  if [[ -z "$key" && "$WARP_PLUS" == off ]]; then fatal "env 里 WARP_PLUS=off：要么在命令后面带上许可证，要么把 WARP_PLUS 设成 auto"; fi
  LAST_PLUS_TRY=$NOW
  apply_plus "$ACC" "$key" || { save_state; fatal "没套上：$PLUS_ERR"; }
  KIND=plus; ACTION="已套用 WARP+ 许可证"; FORCE_TG=1
  probe_all || true
  finish
}

cmd_remove() {
  need_root; need_deps; take_lock wait
  sb_detect
  if [[ -f "$FRAG" ]]; then
    cp -p "$FRAG" "$STATE_DIR/fragment.prev"; rm -f "$FRAG"
    local out
    if ! out=$(sb_check); then
      cp -p "$STATE_DIR/fragment.prev" "$FRAG"
      fatal "去掉片段后 sing-box check 不通过，已放回原处：
$(tail -n 3 <<<"$out")
  多半是主配置的路由还在引用「$WARP_TAG」，先改掉引用再 remove"
    fi
    sb_active && sb_reload >/dev/null 2>&1
    log "已删除配置片段并重载 sing-box"
  fi
  [[ -s "$ACC" ]] && cancel_account "$ACC" && mv "$ACC" "$STATE_DIR/account.removed"
  log "完成。状态和历史留在 $STATE_DIR，不需要可以手动删除"
}

cmd_status() {
  need_root; need_deps; load_state
  sb_detect
  [[ -s "$ACC" ]] || { echo "还没有账户，先运行：$0 init"; exit 1; }
  local s a b alive
  echo "warp-keeper v$VERSION · $WARP_NAME · sing-box $(sb_version)（$( sb_active && echo 运行中 || echo 没在运行)）"
  echo "片段     $FRAG $( [[ -f "$FRAG" ]] && echo '' || echo '（不存在！）')"
  echo "入站     127.0.0.1:$LOCAL_PORT（$(port_owner || true)）→ $WARP_TAG"
  alive=$(account_alive)
  echo "账户     $(acct_label) · 已用 $(acct_days) 天 · Cloudflare 侧：$alive · WARP+ 来源：$WARP_PLUS"
  echo "换号     累计 $RENEW_TOTAL 次（上次 $(ago "$LAST_RENEW")）· 重载 $RELOAD_TOTAL 次 · 上次正常 $(ago "$LAST_OK")"
  read -r a b <<<"$(uptime_of 86400)";        echo "可用率   24 小时 $(pct "$a" "$b")（$a/$b）"
  read -r a b <<<"$(uptime_of $((7 * 86400)))"; echo "         7 天   $(pct "$a" "$b")（$a/$b）"
  [[ -n "$LAST_REASON" ]] && echo "上次问题 $LAST_REASON"
  echo "实测："
  probe_all >/dev/null 2>&1 || true
  for s in $(stacks); do echo "  $(stack_line "$s")"; done
  echo "下次检查：$(systemctl show -p NextElapseUSecRealtime --value warp-keeper.timer 2>/dev/null || echo '?')"
}

case "${1:-}" in
  init)   cmd_init ;;
  sync)   cmd_sync ;;
  check)  cmd_check ;;
  status) cmd_status ;;
  renew)  cmd_renew ;;
  plus)   cmd_plus "${2:-}" ;;
  remove) cmd_remove ;;
  -v|--version) echo "$VERSION" ;;
  *) sed -n '2,/^VERSION=/{/^VERSION=/d;s/^# \{0,1\}//;p}' "$0"; [[ -z "${1:-}" || "$1" == -h || "$1" == --help ]] || exit 2 ;;
esac
