#!/usr/bin/env bash
# 安装 / 更新 cfst-ddns。重复运行即可把 cfst 升级到最新版，不会覆盖已有配置。
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "请用 root 运行"; exit 1; }
cd "$(dirname "$0")"

DIR=/opt/cfst-ddns
GH_PROXY="${GH_PROXY:-}"   # GitHub 下载慢时可设为你的反代前缀，如 GH_PROXY=https://xxx/
CFST_UID="${CFST_UID:-950}"  # 专用用户的固定 UID，填进 sing-box TUN 的 exclude_uid

command -v curl >/dev/null && command -v jq >/dev/null || apt-get install -y curl jq

# 专用系统用户：已存在就沿用它的 UID；不存在就用 CFST_UID 创建
if id cfst-ddns >/dev/null 2>&1; then
  CFST_UID=$(id -u cfst-ddns)
else
  if getent passwd "$CFST_UID" >/dev/null || getent group "$CFST_UID" >/dev/null; then
    echo "UID/GID $CFST_UID 已被占用，请换一个：CFST_UID=951 ./install.sh"; exit 1
  fi
  groupadd --system --gid "$CFST_UID" cfst-ddns
  useradd --system --uid "$CFST_UID" --gid cfst-ddns --no-create-home \
    --home-dir /var/lib/cfst-ddns --shell /usr/sbin/nologin cfst-ddns
fi

case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  armv7l)  ARCH=armv7 ;;
  i?86)    ARCH=386 ;;
  *) echo "不支持的架构: $(uname -m)"; exit 1 ;;
esac

mkdir -p "$DIR"
echo "下载 cfst (linux_${ARCH}) ..."
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
curl -fL "${GH_PROXY}https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download/cfst_linux_${ARCH}.tar.gz" \
  | tar -xz -C "$TMP"
# 新版压缩包里多了一层 cfst_linux_<arch>/ 目录，旧版没有，两种都兼容
BIN=$(find "$TMP" -type f -name cfst | head -n1)
[[ -n "$BIN" ]] || { echo "压缩包里没找到 cfst"; exit 1; }
SRC=$(dirname "$BIN")
install -m 755 "$SRC/cfst" "$DIR/cfst"
install -m 644 "$SRC/ip.txt" "$SRC/ipv6.txt" "$DIR/"

install -m 755 cfst-ddns.sh "$DIR/cfst-ddns.sh"
install -m 644 cfst-ddns.service cfst-ddns.timer /etc/systemd/system/
ENV_KEPT=""
if [[ -f /etc/cfst-ddns.env ]]; then ENV_KEPT=1
else install -m 600 cfst-ddns.env.example /etc/cfst-ddns.env; fi
systemctl daemon-reload

cat <<EOF

安装完成，测速用户 cfst-ddns 的 UID 是 ${CFST_UID}。接下来：
  1. sing-box 的 tun inbound 里加上  "exclude_uid": [${CFST_UID}]  然后重启 sing-box
  2. 编辑配置        nano /etc/cfst-ddns.env
  3. 手动跑一次      systemctl start cfst-ddns.service   （立即返回，测速在后台进行）
  4. 看进度和结果    journalctl -fu cfst-ddns --output cat
  5. 没问题就启用    systemctl enable --now cfst-ddns.timer
EOF
if [[ -n "$ENV_KEPT" ]]; then
  echo
  echo "注意：/etc/cfst-ddns.env 已存在，没有覆盖。新增的配置项（API_PROXY、TG_BOT_TOKEN、TG_CHAT_ID、TG_NOTIFY）"
  echo "      请参照 cfst-ddns.env.example 自己补进去。"
fi
