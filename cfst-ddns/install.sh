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

# 旧版本是单个 cfst-ddns.service，新版本改成 cfst-ddns@.service（按模式运行），这里清理掉旧的
TIMER_WAS_ON=""
systemctl is-enabled --quiet cfst-ddns.timer 2>/dev/null && TIMER_WAS_ON=1
if [[ -f /etc/systemd/system/cfst-ddns.service ]]; then
  echo "移除旧版 cfst-ddns.service ..."
  systemctl stop cfst-ddns.timer cfst-ddns.service 2>/dev/null || true
  rm -f /etc/systemd/system/cfst-ddns.service
fi
install -m 644 'cfst-ddns@.service' cfst-ddns.timer /etc/systemd/system/
ENV_KEPT=""
if [[ -f /etc/cfst-ddns.env ]]; then ENV_KEPT=1
else install -m 600 cfst-ddns.env.example /etc/cfst-ddns.env; fi
systemctl daemon-reload
if [[ -n "$TIMER_WAS_ON" ]]; then systemctl restart cfst-ddns.timer; echo "已重启 cfst-ddns.timer（新的调度方式已生效）"; fi

cat <<EOF

安装完成，测速用户 cfst-ddns 的 UID 是 ${CFST_UID}。接下来：
  1. sing-box 的 tun inbound 里加上  "exclude_uid": [${CFST_UID}]  然后重启 sing-box
  2. 编辑配置        nano /etc/cfst-ddns.env
  3. 手动全量跑一次  systemctl start cfst-ddns@full   （立即返回，测速在后台进行）
                     其他模式：cfst-ddns@check 巡检 / cfst-ddns@pool 复测榜单
  4. 看进度和结果    journalctl -fu 'cfst-ddns@*' --output cat
  5. 没问题就启用    systemctl enable --now cfst-ddns.timer
                     （每 5 分钟检查一次时间表，按 env 里的 FULL_AT / PEAK_* 决定做什么）
EOF
if [[ -n "$ENV_KEPT" ]]; then
  echo
  echo "注意：/etc/cfst-ddns.env 已存在，没有覆盖。新版本新增的配置项请参照 cfst-ddns.env.example 补进去"
  echo "      （不补也能跑，都有默认值）。可以这样对比缺了哪些："
  echo "      diff <(grep -oE '^#?[A-Z_]+=' cfst-ddns.env.example | tr -d '#' | sort -u) <(grep -oE '^[A-Z_]+=' /etc/cfst-ddns.env | sort -u)"
fi
