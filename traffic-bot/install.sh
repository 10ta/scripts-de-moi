#!/usr/bin/env bash
# traffic-bot 一键部署：venv + 专用低权限用户 + 密钥文件 + systemd 服务
#
# 用法（bot.py 与本脚本放在同一目录）：
#   sudo bash install.sh
#
# 之后：
#   journalctl -u traffic-bot -f          # 看日志
#   systemctl restart traffic-bot         # 重启
#   sudo nano /etc/traffic-bot.env        # 改配置（改完要 restart）
#   sudo cp bot.py /opt/traffic-bot/ && sudo systemctl restart traffic-bot   # 更新代码
set -euo pipefail

APP_NAME="traffic-bot"
APP_USER="trafficbot"
APP_DIR="/opt/${APP_NAME}"
ENV_FILE="/etc/${APP_NAME}.env"
KEY_DIR="/etc/${APP_NAME}"
OCI_KEY_DEST="${KEY_DIR}/oci_api_key.pem"
UNIT_FILE="/etc/systemd/system/${APP_NAME}.service"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "错误：$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 root 运行：sudo bash $0"
[[ -f "$SRC_DIR/bot.py" ]] || die "找不到 $SRC_DIR/bot.py，请把它和 install.sh 放在同一目录"
command -v systemctl >/dev/null || die "未检测到 systemd"
command -v python3 >/dev/null || die "未安装 python3"
python3 -c 'import venv, ensurepip' 2>/dev/null \
  || die "缺少 venv 模块，Debian/Ubuntu 请先执行：apt install -y python3-venv"

# ---------------------------------------------------------------- 1. 用户与代码
if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$APP_DIR" --no-create-home --shell /usr/sbin/nologin "$APP_USER"
  echo "已创建系统用户 $APP_USER"
fi

install -d -m 755 "$APP_DIR"
install -m 644 "$SRC_DIR/bot.py" "$APP_DIR/bot.py"

# ---------------------------------------------------------------- 2. 虚拟环境
if [[ ! -x "$APP_DIR/venv/bin/python" ]]; then
  python3 -m venv "$APP_DIR/venv"
fi
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/venv/bin/pip" install --quiet --upgrade "python-telegram-bot[job-queue]" boto3 requests oci
echo "依赖安装完成"

# ---------------------------------------------------------------- 3. 密钥文件
ask() {  # ask 变量名 "提示" 是否隐藏输入(1/0) 是否必填(1/0)
  local __var=$1 label=$2 secret=$3 required=$4 val=""
  while true; do
    if [[ $secret == 1 ]]; then
      read -r -s -p "$label: " val || true; echo
    else
      read -r -p "$label: " val || true
    fi
    val="${val//[[:space:]]/}"
    if [[ $val == *\"* || $val == *\\* ]]; then
      echo "  值里不能包含双引号或反斜杠，请重新输入"; continue
    fi
    if [[ -n $val || $required == 0 ]]; then break; fi
    echo "  这一项必填"
  done
  printf -v "$__var" '%s' "$val"
}

write_env() {
  ( umask 077
    cat > "$ENV_FILE" <<EOF
# traffic-bot 配置。systemd 的 EnvironmentFile 格式：KEY="value"，不要写 export
BOT_TOKEN="$BOT_TOKEN"
# 只允许这些 chat 使用并接收定时播报，多个用逗号分隔
ALLOWED_CHAT_IDS="$ALLOWED_CHAT_IDS"

# AWS 凭证。留空则使用 boto3 默认凭证链（例如实例角色）
AWS_ACCESS_KEY="$AWS_ACCESS_KEY"
AWS_SECRET_KEY="$AWS_SECRET_KEY"
# AWS 本月账单（总额 + 收费项目）。需在 Billing preferences 勾选 Receive CloudWatch Billing Alerts
AWS_BILL="1"
# 本月账单越过这个金额的 80%/95% 时告警（USD，0=不告警）
AWS_BILL_LIMIT_USD="1"

# 搬瓦工。不用 BWH 可留空（BWH 部分会显示查询失败）
BWH_API_KEY="$BWH_API_KEY"
BWH_VEID="$BWH_VEID"

# Cloudflare（可选，两项都填了才会查询并显示）
CLOUDFLARE_API_TOKEN="$CLOUDFLARE_API_TOKEN"
CLOUDFLARE_ACCOUNT_ID="$CLOUDFLARE_ACCOUNT_ID"
# 要统计 CDN 流量的域名，格式 名称=ZoneID，逗号分隔。留空则自动列出全部域名（需要 Token 有 Zone Read 权限）
#CLOUDFLARE_ZONES="example.com=ZONEID1,other.com=ZONEID2"
# 账期起始日（UTC）：控制台 Workers & Pages → Usage 显示 "Oct 8 - Nov 8" 就填 8
CLOUDFLARE_BILLING_DAY="8"

# Oracle Cloud（可选，三项都填了才会查询并显示）
OCI_TENANCY="$OCI_TENANCY"
OCI_USER="$OCI_USER"
OCI_FINGERPRINT="$OCI_FINGERPRINT"
OCI_REGION="$OCI_REGION"
OCI_KEY_FILE="$OCI_KEY_DEST"
# 闲置回收检测（CPU/网络是否低于回收线）。默认关闭，设为 1 才会显示并告警
OCI_IDLE_CHECK="0"

# 定时播报间隔（小时，0=关闭）
REPORT_INTERVAL_HOURS="24"
# 用量越过这些百分比时立刻推送告警（每个周期每档只推一次）
ALERT_THRESHOLDS="80,95"
# 多久检查一次是否越线（分钟）
ALERT_CHECK_MINUTES="10"

# 以下为可选项，取消注释即可覆盖默认值
#REPORT_TZ="America/Los_Angeles"
# 阿里云 CDT：装了 cdt-guard（scripts-de-moi/script/CDT-Management）就会自动显示，bot 不需要阿里云 AK
#CDT_STATE_PATH="/var/lib/cdt-guard/state.json"

# Sonde 面板（可选）：填了就每次告警检查后上报一份用量（已脱敏）
#SONDE_URL="https://sonde.example.com"
#SONDE_TOKEN=""
#CDT_STALE_MIN="15"
#LIGHTSAIL_REGION="ap-northeast-1"
#BWH_TOTAL_GB="2000"
#CLOUDFRONT_LIMIT_GB="1024"
#CLOUDFRONT_LIMIT_REQUESTS="10000000"
EOF
  )
  chown root:root "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

ask_cloudflare() {
  echo
  echo "--- Cloudflare（可选，Token 处直接回车=跳过）---"
  echo "Token 创建：My Profile → API Tokens → Create Token → Custom token"
  echo "  权限：Account → Account Analytics → Read"
  echo "  Resources：Account 选你的账号；要查 CDN 流量则 Zone Resources 选 All zones（或指定域名）"
  echo "  可选：再加 Account → D1 → Read，D1 才能显示数据库名和大小"
  ask CLOUDFLARE_API_TOKEN "CLOUDFLARE_API_TOKEN" 1 0
  CLOUDFLARE_ACCOUNT_ID=""
  if [[ -n $CLOUDFLARE_API_TOKEN ]]; then
    while true; do
      ask CLOUDFLARE_ACCOUNT_ID "CLOUDFLARE_ACCOUNT_ID（32 位，Workers & Pages 概览页右侧可见）" 0 1
      [[ $CLOUDFLARE_ACCOUNT_ID =~ ^[0-9a-fA-F]{32}$ ]] && break
      echo "  格式不对，应为 32 位十六进制"
    done
  fi
}

OCI_RE_TENANCY='^ocid1\.tenancy\.oc[0-9]+\.\.[a-z0-9]+$'
OCI_RE_USER='^ocid1\.user\.oc[0-9]+\.\.[a-z0-9]+$'
OCI_RE_FP='^([0-9a-f]{2}:){15}[0-9a-f]{2}$'

ask_match() {  # ask_match 变量名 "提示" 正则 "格式说明"
  local __v=$1 label=$2 re=$3 desc=$4
  while true; do
    ask "$__v" "$label" 0 1
    [[ ${!__v} =~ $re ]] && break
    echo "  格式不对，应为 $desc"
  done
}

install_oci_key() {  # 私钥放到 bot 可读、其他用户不可读的位置
  install -d -m 750 -o root -g "$APP_USER" "$KEY_DIR"
  install -m 640 -o root -g "$APP_USER" "$1" "$OCI_KEY_DEST"
}

ask_oracle() {
  OCI_TENANCY="" OCI_USER="" OCI_FINGERPRINT="" OCI_REGION=""
  echo
  echo "--- Oracle Cloud（可选，Tenancy OCID 处直接回车=跳过）---"
  echo "需要先在 OCI 控制台给 traffic-bot 用户生成 API Key，并把下载的私钥 .pem 传到这台服务器"
  ask OCI_TENANCY "OCI_TENANCY（ocid1.tenancy.oc1..开头；头像 → Tenancy 页复制）" 0 0
  [[ -z $OCI_TENANCY ]] && return 0
  until [[ $OCI_TENANCY =~ $OCI_RE_TENANCY ]]; do
    echo "  格式不对，应为 ocid1.tenancy.oc1..xxxx"
    ask OCI_TENANCY "OCI_TENANCY" 0 1
  done
  ask_match OCI_USER "OCI_USER（traffic-bot 用户的 OCID，ocid1.user.oc1..开头）" "$OCI_RE_USER" "ocid1.user.oc1..xxxx"
  ask_match OCI_FINGERPRINT "OCI_FINGERPRINT（xx:xx:...，共 16 组）" "$OCI_RE_FP" "16 组两位十六进制，用冒号分隔"
  ask OCI_REGION "OCI_REGION（回车默认 ap-seoul-1）" 0 0
  OCI_REGION=${OCI_REGION:-ap-seoul-1}
  local key=""
  while true; do
    ask key "私钥 .pem 文件在这台服务器上的路径" 0 1
    if [[ -f $key ]] && grep -q -- '-----BEGIN' "$key"; then break; fi
    echo "  找不到文件或不是 PEM 私钥：$key"
  done
  install_oci_key "$key"
  echo "私钥已复制到 $OCI_KEY_DEST（root:$APP_USER 640）。确认无误后可删除原文件：shred -u $key"
}

ensure_line() {  # 老的 env 文件里缺这个 key 时才追加
  local key=$1 value=$2
  grep -q "^${key}=" "$ENV_FILE" || printf '%s="%s"\n' "$key" "$value" >> "$ENV_FILE"
}

READY=1
CLOUDFLARE_API_TOKEN="" CLOUDFLARE_ACCOUNT_ID=""
OCI_TENANCY="" OCI_USER="" OCI_FINGERPRINT="" OCI_REGION=""
if [[ -f "$ENV_FILE" ]]; then
  echo "检测到已有 $ENV_FILE，保留已有配置（要修改请 sudo nano 它）"
  if ! grep -q '^CLOUDFLARE_API_TOKEN=' "$ENV_FILE" && [[ -t 0 ]]; then
    read -r -p "env 里还没有 Cloudflare 配置，现在添加吗？[y/N] " yn || true
    if [[ ${yn:-} =~ ^[Yy]$ ]]; then
      ask_cloudflare
      if [[ -n $CLOUDFLARE_API_TOKEN ]]; then
        {
          echo
          echo "# Cloudflare（由 install.sh 追加）"
          printf 'CLOUDFLARE_API_TOKEN="%s"\n' "$CLOUDFLARE_API_TOKEN"
          printf 'CLOUDFLARE_ACCOUNT_ID="%s"\n' "$CLOUDFLARE_ACCOUNT_ID"
        } >> "$ENV_FILE"
        echo "已追加 Cloudflare 配置"
      fi
    fi
  fi
  if ! grep -q '^OCI_TENANCY=' "$ENV_FILE" && [[ -t 0 ]]; then
    read -r -p "env 里还没有 Oracle Cloud 配置，现在添加吗？[y/N] " yn || true
    if [[ ${yn:-} =~ ^[Yy]$ ]]; then
      ask_oracle
      if [[ -n $OCI_TENANCY ]]; then
        {
          echo
          echo "# Oracle Cloud（由 install.sh 追加）"
          printf 'OCI_TENANCY="%s"\n' "$OCI_TENANCY"
          printf 'OCI_USER="%s"\n' "$OCI_USER"
          printf 'OCI_FINGERPRINT="%s"\n' "$OCI_FINGERPRINT"
          printf 'OCI_REGION="%s"\n' "$OCI_REGION"
          printf 'OCI_KEY_FILE="%s"\n' "$OCI_KEY_DEST"
        } >> "$ENV_FILE"
        echo "已追加 Oracle Cloud 配置"
      fi
    fi
  fi
  # 已配置 Oracle 但私钥不在（例如换了机器）时提醒
  if grep -q '^OCI_TENANCY="ocid' "$ENV_FILE" && [[ ! -f $OCI_KEY_DEST ]]; then
    echo "⚠️ 已配置 Oracle，但找不到私钥 $OCI_KEY_DEST。把 .pem 传上来后执行："
    echo "   sudo install -d -m 750 -o root -g $APP_USER $KEY_DIR && sudo install -m 640 -o root -g $APP_USER 你的.pem $OCI_KEY_DEST"
  fi
  # 补齐新版本引入的设置项（已有的不动）
  ensure_line REPORT_INTERVAL_HOURS "2"
  ensure_line ALERT_THRESHOLDS "80,95"
  ensure_line ALERT_CHECK_MINUTES "10"
  ensure_line CLOUDFLARE_BILLING_DAY "8"
  ensure_line OCI_IDLE_CHECK "0"
  ensure_line AWS_BILL "1"
  ensure_line AWS_BILL_LIMIT_USD "1"
else
  BOT_TOKEN="" ALLOWED_CHAT_IDS="" AWS_ACCESS_KEY="" AWS_SECRET_KEY="" BWH_API_KEY="" BWH_VEID=""
  if [[ -t 0 ]]; then
    echo
    echo "=== 配置密钥（输入不会回显，会写入 $ENV_FILE，权限 600）==="
    ask BOT_TOKEN        "Telegram BOT_TOKEN（@BotFather 获取）" 1 1
    ask ALLOWED_CHAT_IDS "你的 chat id，多个用逗号分隔（给 @userinfobot 发消息可得到）" 0 1
    ask AWS_ACCESS_KEY   "AWS_ACCESS_KEY（用实例角色可直接回车跳过）" 0 0
    if [[ -n $AWS_ACCESS_KEY ]]; then
      ask AWS_SECRET_KEY "AWS_SECRET_KEY" 1 1
    fi
    ask BWH_API_KEY      "BWH_API_KEY（不用可回车跳过）" 1 0
    if [[ -n $BWH_API_KEY ]]; then
      ask BWH_VEID       "BWH_VEID" 0 1
    fi
    ask_cloudflare
    ask_oracle
  else
    echo "非交互环境：已生成空模板 $ENV_FILE，请手动填写后执行 systemctl restart $APP_NAME"
    READY=0
  fi
  write_env
  echo "已写入 $ENV_FILE"
fi

# ---------------------------------------------------------------- 4. systemd 服务
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Traffic usage Telegram bot (BWH / Lightsail / CloudFront / AWS bill / Cloudflare / Oracle / Aliyun CDT)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
# 告警去重状态存在 /var/lib/${APP_NAME}，重启不会重复告警
StateDirectory=${APP_NAME}
EnvironmentFile=${ENV_FILE}
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStart=${APP_DIR}/venv/bin/python ${APP_DIR}/bot.py
Restart=always
RestartSec=10

# 安全加固
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$APP_NAME" >/dev/null 2>&1
echo "systemd 服务已安装并设为开机自启"

# ---------------------------------------------------------------- 5. 处理旧的 nohup 进程
# 同一个 token 同时只能有一个实例在轮询，否则 Telegram 会报 409 Conflict
OLD_PIDS=""
for p in $(pgrep -f 'python[0-9.]* .*bot\.py' || true); do
  cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)"
  # 跳过 systemd 管理的新进程（走 venv 的那个）
  [[ -n $cmd && $cmd != "${APP_DIR}/venv/"* ]] && OLD_PIDS+="$p "
done
if [[ -n $OLD_PIDS ]]; then
  echo
  echo "发现疑似旧的 nohup 进程："
  for p in $OLD_PIDS; do echo "  PID $p: $(tr '\0' ' ' < /proc/$p/cmdline | cut -c1-100)"; done
  if [[ -t 0 ]]; then
    read -r -p "是否终止这些进程？[y/N] " yn || true
    if [[ ${yn:-} =~ ^[Yy]$ ]]; then
      # shellcheck disable=SC2086
      kill $OLD_PIDS && sleep 2 && echo "已终止"
    else
      echo "未终止。请手动 kill 后再 systemctl restart $APP_NAME，否则会出现 409 Conflict"
      READY=0
    fi
  else
    echo "请手动 kill 这些进程后再 systemctl restart $APP_NAME"
    READY=0
  fi
fi

# ---------------------------------------------------------------- 6. 启动
if [[ $READY == 1 ]]; then
  systemctl restart "$APP_NAME"
  sleep 3
  if systemctl is-active --quiet "$APP_NAME"; then
    echo
    echo "✅ 服务运行中。到 Telegram 给 bot 发 /check 或 /oracle 试试"
    if [[ -f /var/lib/cdt-guard/state.json ]]; then
      echo "   已检测到 cdt-guard，/aliyun 可查看阿里云 CDT"
    else
      echo "   想显示阿里云 CDT：在这台机器上安装 scripts-de-moi/script/CDT-Management（bash init.sh），无需改 bot 配置"
    fi
  else
    echo
    echo "❌ 服务启动失败，最近日志："
    journalctl -u "$APP_NAME" -n 30 --no-pager || true
    exit 1
  fi
else
  echo
  echo "已安装但未启动。处理完上面的提示后执行：systemctl restart $APP_NAME"
fi

cat <<EOF

常用命令：
  journalctl -u ${APP_NAME} -f           实时日志
  systemctl status ${APP_NAME}           状态
  systemctl restart ${APP_NAME}          重启
  sudo nano ${ENV_FILE}                  改配置（改完要 restart）
  sudo cp bot.py ${APP_DIR}/ && sudo systemctl restart ${APP_NAME}    更新代码
EOF
