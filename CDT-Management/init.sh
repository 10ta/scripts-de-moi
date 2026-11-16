#!/usr/bin/env bash
# CDT-Management 一键安装 / 重新配置 / 卸载
#
#   bash init.sh                # 安装（已安装则只更新程序文件，保留配置）
#   bash init.sh reconfigure    # 重新填写配置
#   bash init.sh komari         # 只配置 Komari 实时流量（推荐）
#   bash init.sh status         # 查看运行状态和当前用量
#   bash init.sh uninstall      # 卸载
#
# 也可以不 clone 仓库，直接（bash / zsh / fish 通用）：
#   curl -fsSL https://raw.githubusercontent.com/10ta/scripts-de-moi/main/CDT-Management/init.sh -o /tmp/cdt-init.sh && bash /tmp/cdt-init.sh
set -euo pipefail

RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/10ta/scripts-de-moi/main/CDT-Management}"
APP_DIR=/opt/cdt-guard
ENV_FILE=/etc/cdt-guard.env
STATE_DIR=/var/lib/cdt-guard
UNIT_DIR=/etc/systemd/system
BOT_ENV=/etc/traffic-bot.env
FILES=(cdt_guard.py cdt-guard.service cdt-guard.timer cdt-guard.env.example)

c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_b=$'\e[1m'; c_0=$'\e[0m'
info() { echo "${c_g}==>${c_0} $*"; }
warn() { echo "${c_y}[!]${c_0} $*"; }
die()  { echo "${c_r}[x]${c_0} $*" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- 工具
get_val() {  # get_val KEY FILE -> 值（去掉引号和行尾注释）
    [[ -f "$2" ]] || return 0
    grep -E "^$1=" "$2" | tail -n1 | cut -d= -f2- | sed -E 's/[[:space:]]+#.*$//; s/^["'\'']//; s/["'\'']$//' || true
}

ask() {  # ask VAR "提示" "默认值"
    local _v
    read -r -p "$2${3:+ [${3}]}: " _v </dev/tty
    printf -v "$1" '%s' "${_v:-$3}"
}

ask_secret() {  # ask_secret VAR "提示" "已有值"
    local _v
    read -r -s -p "$2${3:+ [回车保留原值]}: " _v </dev/tty; echo
    printf -v "$1" '%s' "${_v:-$3}"
}

guard() { CDT_GUARD_ENV="$1" python3 "$APP_DIR/cdt_guard.py" "${@:2}"; }

set_val() {  # set_val KEY VALUE FILE：有就替换，没有就追加（保留文件权限）
    local t="$TMP/set_val"
    grep -vE "^$1=" "$3" > "$t" || true
    printf '%s=%s\n' "$1" "$2" >> "$t"
    cat "$t" > "$3"
}

# ---------------------------------------------------------------- 检查环境
preflight() {
    [[ $EUID -eq 0 ]] || die "请用 root 运行（sudo bash init.sh）"
    command -v systemctl >/dev/null || die "需要 systemd"
    if ! command -v python3 >/dev/null; then
        info "安装 python3"
        apt-get update -qq && apt-get install -y -qq python3 >/dev/null
    fi
    python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' || die "需要 Python 3.8+"
}

# ---------------------------------------------------------------- 安装程序文件
install_files() {
    # 只有以文件方式运行（bash init.sh / bash /tmp/cdt-init.sh）时才看脚本旁边有没有程序文件；
    # bash -c / 管道运行时 BASH_SOURCE 为空，直接从 GitHub 下载，不去碰当前目录
    local src="" self="${BASH_SOURCE[0]:-}"
    [[ -n "$self" && -f "$self" ]] && src="$(cd "$(dirname "$self")" && pwd)"
    if [[ -n "$src" && -f "$src/cdt_guard.py" ]]; then
        info "使用本地文件：$src"
    else
        info "从 GitHub 下载文件"
        command -v curl >/dev/null || apt-get install -y -qq curl >/dev/null
        for f in "${FILES[@]}"; do
            curl -fsSL "$RAW_BASE/$f" -o "$TMP/$f" || die "下载失败：$RAW_BASE/$f"
        done
        src="$TMP"
    fi
    install -d -m 755 "$APP_DIR"
    install -m 755 "$src/cdt_guard.py" "$APP_DIR/cdt_guard.py"
    install -m 644 "$src/cdt-guard.env.example" "$APP_DIR/cdt-guard.env.example"
    install -m 644 "$src/cdt-guard.service" "$UNIT_DIR/cdt-guard.service"
    install -m 644 "$src/cdt-guard.timer" "$UNIT_DIR/cdt-guard.timer"
    systemctl daemon-reload
}

# ---------------------------------------------------------------- 交互配置
configure() {
    echo
    echo "${c_b}── 阿里云 RAM 用户 AccessKey ──${c_0}"
    echo "（RAM 控制台 → 用户 → 创建 AccessKey；权限见 CDT-Management/ram-policy.json，步骤见 CDT-Management/docs/MANUAL.zh-CN.md）"
    local ak sk region inst limit mode stopmode sg tg_token tg_chat
    while :; do
        ask        ak     "AccessKey ID"     "$(get_val ALI_AK "$ENV_FILE")"
        ask_secret sk     "AccessKey Secret" "$(get_val ALI_SK "$ENV_FILE")"
        ask        region "实例所在地域（如 cn-hongkong / ap-southeast-1 / ap-northeast-1）" \
                          "$(get_val ALI_REGION "$ENV_FILE" | grep . || echo cn-hongkong)"
        [[ -n "$ak" && -n "$sk" ]] || { warn "AK/SK 不能为空"; continue; }

        (umask 077; printf 'ALI_AK=%s\nALI_SK=%s\nALI_REGION=%s\nSTATE_DIR=%s\n' "$ak" "$sk" "$region" "$TMP/state" > "$TMP/probe.env")
        info "验证 AccessKey 并列出 $region 的实例…"
        if guard "$TMP/probe.env" list > "$TMP/instances" 2> "$TMP/err"; then
            break
        fi
        warn "验证失败：$(tail -n1 "$TMP/err")"
        warn "检查 AK/SK 是否正确、RAM 用户是否已授权、地域是否写对。重新输入："
    done

    local n
    n=$(grep -c . "$TMP/instances" || true)
    if [[ "$n" -eq 0 ]]; then
        warn "$region 下没有实例，请确认地域"
        ask inst "手动输入实例 ID" "$(get_val ALI_INSTANCE_ID "$ENV_FILE")"
    else
        echo
        awk -F'\t' '{printf "  %d) %s  %-8s %-20s %-15s %s\n", NR, $1, $2, $3, $4, $5}' "$TMP/instances"
        local pick def=1 old
        old="$(get_val ALI_INSTANCE_ID "$ENV_FILE")"
        [[ -n "$old" ]] && def=$(awk -F'\t' -v id="$old" '$1==id{print NR}' "$TMP/instances" | grep . || echo 1)
        ask pick "选择要守护的实例编号" "$def"
        inst=$(awk -F'\t' -v n="$pick" 'NR==n{print $1}' "$TMP/instances")
        [[ -n "$inst" ]] || die "编号无效"
    fi

    echo
    echo "${c_b}── 熔断设置 ──${c_0}"
    ask limit "流量达到多少 GB 熔断（香港/海外免费 200GB）" "$(get_val CDT_LIMIT_GB "$ENV_FILE" | grep . || echo 199)"
    echo "  stop = 关机（默认，最稳）"
    echo "  sg   = 不关机，在安全组加 drop-all 入站规则（IP 不变；该安全组下的其他实例也会一起断网）"
    while :; do
        ask mode "熔断方式 stop / sg" "$(get_val GUARD_MODE "$ENV_FILE" | grep . || echo stop)"
        [[ "$mode" == stop || "$mode" == sg ]] && break
        warn "只能填 stop 或 sg"
    done
    stopmode="$(get_val STOP_MODE "$ENV_FILE" | grep . || echo KeepCharging)"
    sg="$(get_val SG_ID "$ENV_FILE")"
    if [[ "$mode" == stop ]] && grep -q "^$inst.*PostPaid" "$TMP/instances"; then
        echo "  按量付费实例：KeepCharging 保留公网 IP（推荐）；StopCharging 停机不收算力费，但 IP 会变、开机可能缺库存"
        ask stopmode "停机模式 KeepCharging / StopCharging" "$stopmode"
    fi
    if [[ "$mode" == sg ]]; then
        ask sg "安全组 ID（留空 = 用实例的第一个安全组）" "$sg"
    fi

    echo
    echo "${c_b}── 费用熔断 ──${c_0}"
    echo "  本月应付（已扣优惠）达到这个金额就关机，防止意外刷爆卡。国际站单位 USD，0 = 关闭"
    echo "  需要 RAM 权限 bss:DescribeBillList（ram-policy.json 已包含；用系统策略的话再加 AliyunBSSReadOnlyAccess）"
    local cost_limit site
    ask cost_limit "费用熔断线" "$(get_val COST_LIMIT "$ENV_FILE" | grep . || echo 5)"
    ask site "账号站点 intl（国际站，USD）/ cn（中国站，CNY）" "$(get_val ALI_SITE "$ENV_FILE" | grep . || echo intl)"

    echo
    echo "${c_b}── Telegram 通知（可留空）──${c_0}"
    local def_token def_chat
    def_token="$(get_val TG_BOT_TOKEN "$ENV_FILE")"; def_chat="$(get_val TG_CHAT_ID "$ENV_FILE")"
    if [[ -z "$def_token" && -f "$BOT_ENV" ]]; then
        def_token="$(get_val BOT_TOKEN "$BOT_ENV")"; def_chat="$(get_val ALLOWED_CHAT_IDS "$BOT_ENV" | tr -d ' ')"
        [[ -n "$def_token" ]] && echo "  检测到 traffic-bot，默认沿用它的 token 和 chat id"
    fi
    ask_secret tg_token "Bot Token" "$def_token"
    ask        tg_chat  "Chat ID（多个用逗号分隔）" "$def_chat"

    (umask 077; cat > "$ENV_FILE" <<EOF
# 由 init.sh 生成于 $(date '+%F %T')。说明见 $APP_DIR/cdt-guard.env.example
ALI_AK=$ak
ALI_SK=$sk
ALI_REGION=$region
ALI_INSTANCE_ID=$inst

CDT_LIMIT_GB=$limit
CDT_LOOKAHEAD_MIN=$(get_val CDT_LOOKAHEAD_MIN "$ENV_FILE" | grep . || echo 30)

GUARD_MODE=$mode
STOP_MODE=$stopmode
SG_ID=$sg
GUARD_KEEPALIVE=$(get_val GUARD_KEEPALIVE "$ENV_FILE" | grep . || echo 1)

COST_LIMIT=$cost_limit
COST_WARN_PCT=$(get_val COST_WARN_PCT "$ENV_FILE" | grep . || echo 50)
COST_CHECK_MIN=$(get_val COST_CHECK_MIN "$ENV_FILE" | grep . || echo 30)
ALI_SITE=$site

TG_BOT_TOKEN=$tg_token
TG_CHAT_ID=$tg_chat

STATE_DIR=$STATE_DIR
EOF
    )
    chmod 600 "$ENV_FILE"
    info "配置已写入 $ENV_FILE（权限 600）"
    configure_komari
}

# ---------------------------------------------------------------- Komari 实时流量
configure_komari() {
    echo
    echo "${c_b}── Komari 实时流量（推荐，留空跳过）──${c_0}"
    echo "  CDT 接口的流量数据会滞后好几个小时（实测落后约 70GB），光靠它熔断来不及。"
    echo "  配上 Komari 后，按实例上 agent 报的本月上行熔断，和 CDT 取大值。"
    echo "  要求：实例装了 Komari agent，面板上这个节点开了月度流量统计（显示「RESET 1ST」那种）"
    local url key uuid pick n
    ask url "Komari 面板地址（如 https://komari.example.com，有子路径就带上）" "$(get_val KOMARI_URL "$ENV_FILE")"
    if [[ -z "$url" ]]; then
        set_val KOMARI_URL "" "$ENV_FILE"
        warn "跳过 Komari：熔断只靠 CDT 数据。以后要配：bash init.sh komari"
        return 0
    fi
    ask_secret key "Komari API 密钥（节点设为隐藏时才需要：后台 → 设置 → API 密钥；不需要就回车）" "$(get_val KOMARI_API_KEY "$ENV_FILE")"

    cp "$ENV_FILE" "$TMP/k.env"
    set_val KOMARI_URL "$url" "$TMP/k.env"; set_val KOMARI_API_KEY "$key" "$TMP/k.env"; set_val KOMARI_UUID "" "$TMP/k.env"
    set_val STATE_DIR "$TMP/state" "$TMP/k.env"
    if ! guard "$TMP/k.env" komari > "$TMP/nodes" 2> "$TMP/err"; then
        warn "读不到 Komari 节点列表：$(cat "$TMP/err" "$TMP/nodes" | grep -v '^[[:space:]]*$' | tail -n1)"
        warn "检查面板地址和 API 密钥，然后重新运行：bash init.sh komari"
        return 0
    fi
    n=$(grep -c . "$TMP/nodes" || true)
    if [[ "$n" -eq 0 ]]; then
        warn "列表是空的：节点可能设成了隐藏，需要填 API 密钥。重新运行：bash init.sh komari"
        return 0
    fi
    awk -F'\t' '{printf "  %d) %s  %s\n", NR, $2, $1}' "$TMP/nodes"
    ask pick "选择这台 CDT 实例对应的节点编号" "1"
    uuid=$(awk -F'\t' -v n="$pick" 'NR==n{print $1}' "$TMP/nodes")
    [[ -n "$uuid" ]] || { warn "编号无效，重新运行：bash init.sh komari"; return 0; }

    set_val KOMARI_UUID "$uuid" "$TMP/k.env"
    local kgb cdt
    kgb=$(guard "$TMP/k.env" komari 2>/dev/null || echo "?")
    cdt=$(guard "$ENV_FILE" report --json 2>/dev/null | python3 -c 'import json,sys; print(round(json.load(sys.stdin)["used_gb"], 2))' 2>/dev/null || echo "?")
    echo "  Komari 本月上行：${kgb} GB · CDT 当前：${cdt} GB（CDT 滞后，Komari 通常更大）"
    set_val KOMARI_URL "$url" "$ENV_FILE"; set_val KOMARI_API_KEY "$key" "$ENV_FILE"; set_val KOMARI_UUID "$uuid" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    info "Komari 已写入 $ENV_FILE"
}

start_timer() {
    info "首次运行检查…"
    if ! systemctl start cdt-guard.service; then
        journalctl -u cdt-guard -n 20 --no-pager || true
        die "首次运行失败，修好后执行：bash init.sh reconfigure"
    fi
    systemctl enable --now cdt-guard.timer >/dev/null 2>&1
    echo
    guard "$ENV_FILE" report || true
    echo
    info "完成。每 5 分钟检查一次：systemctl list-timers cdt-guard.timer"
    [[ -f "$BOT_ENV" ]] && info "traffic-bot 会自动读取 $STATE_DIR/state.json，重启 bot 即可看到 ☁️ Aliyun CDT 一栏"
    return 0
}

# ---------------------------------------------------------------- 子命令
cmd_install() {
    preflight
    install_files
    if [[ -f "$ENV_FILE" ]]; then
        info "已存在 $ENV_FILE，保留原配置（要重填请运行：bash init.sh reconfigure）"
        if ! grep -qE '^KOMARI_URL=' "$ENV_FILE"; then  # 新版本加的选项：交互运行时问一次，update.sh 里只提示
            if [[ -t 0 ]]; then configure_komari
            else warn "还没配置 Komari 实时流量（CDT 数据滞后，熔断可能来不及）：bash init.sh komari"; fi
        fi
    else
        configure
    fi
    start_timer
}

cmd_reconfigure() {
    preflight
    install_files
    configure
    start_timer
}

cmd_komari() {
    preflight
    [[ -f "$ENV_FILE" ]] || die "还没安装，先运行：bash init.sh"
    install_files  # 总是先装上和本脚本同版本的程序：旧版程序不认识 komari 命令
    configure_komari
    start_timer
}

cmd_status() {
    systemctl list-timers cdt-guard.timer --no-pager || true
    echo
    journalctl -u cdt-guard -n 5 --no-pager -o cat || true
    echo
    guard "$ENV_FILE" report
}

cmd_uninstall() {
    [[ $EUID -eq 0 ]] || die "请用 root 运行"
    if [[ -f "$ENV_FILE" && "$(get_val GUARD_MODE "$ENV_FILE")" == sg ]]; then
        info "sg 模式：先删除安全组里的 cdt-guard 规则"
        guard "$ENV_FILE" unlock || warn "自动删除失败，请到 ECS 控制台 → 安全组 手动删除描述为 cdt-guard 的规则"
    fi
    systemctl disable --now cdt-guard.timer 2>/dev/null || true
    rm -f "$UNIT_DIR/cdt-guard.service" "$UNIT_DIR/cdt-guard.timer"
    systemctl daemon-reload
    rm -rf "$APP_DIR"
    info "已卸载（timer、服务、$APP_DIR）。实例本身没有任何改动；如果当时处于关机熔断状态，需要自己去控制台开机"
    # 配置和状态保留（重新安装时直接沿用），不替你删
    local p have=()
    for p in "$ENV_FILE" "$STATE_DIR"; do [[ -e "$p" ]] && have+=("$p"); done
    if (( ${#have[@]} )); then
        echo "保留（重新安装时直接沿用）：${have[*]}"
        echo "确定不再需要的话，手动删除："
        echo "  rm -rf ${have[*]}"
    fi
}

case "${1:-install}" in
    install)     cmd_install ;;
    reconfigure) cmd_reconfigure ;;
    komari)      cmd_komari ;;
    status)      cmd_status ;;
    uninstall)   cmd_uninstall ;;
    *) echo "用法：bash init.sh [install|reconfigure|komari|status|uninstall]"; exit 2 ;;
esac
