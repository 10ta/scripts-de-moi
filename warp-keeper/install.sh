#!/usr/bin/env bash
# 安装 / 更新 warp-keeper 的程序和 systemd 单元。重复运行不会覆盖已有配置，也不会碰账户和 sing-box。
# 首次安装后按最后的提示：编辑配置 → init → 启用 timer
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "请用 root 运行"; exit 1; }
cd "$(dirname "$0")"

DIR=/opt/warp-keeper
need=()
for c in curl jq ss flock; do command -v "$c" >/dev/null || need+=("$c"); done
if (( ${#need[@]} )); then
  echo "安装依赖：curl jq iproute2 util-linux ..."
  apt-get install -y curl jq iproute2 util-linux >/dev/null
fi
command -v sing-box >/dev/null || echo "注意：没找到 sing-box。warp-keeper 只管 WARP，不负责安装 sing-box（可以用仓库里的 upsing.sh）"

mkdir -p "$DIR" /var/lib/warp-keeper
chmod 700 /var/lib/warp-keeper
install -m 755 warp-keeper.sh "$DIR/warp-keeper.sh"
ln -sf "$DIR/warp-keeper.sh" /usr/local/bin/warp-keeper
install -m 644 warp-keeper.service warp-keeper.timer /etc/systemd/system/
ENV_KEPT=""
if [[ -f /etc/warp-keeper.env ]]; then ENV_KEPT=1
else install -m 600 warp-keeper.env.example /etc/warp-keeper.env; fi
systemctl daemon-reload
if systemctl is-enabled --quiet warp-keeper.timer 2>/dev/null; then
  systemctl restart warp-keeper.timer
  echo "已重启 warp-keeper.timer"
fi

if [[ -z "$ENV_KEPT" ]]; then
  cat <<'EOF'

安装完成。接下来：
  1. 编辑配置      nano /etc/warp-keeper.env   （tag、端口、WARP+、Telegram、Sonde）
  2. 从 wireproxy 迁移的话，先停掉它：systemctl disable --now wireproxy
     主配置里旧的同名 endpoint（或指向 18650 的 socks 出站）按 README 处理，先别重启 sing-box
  3. 注册并接入    warp-keeper init     （会重载一次 sing-box，所有入站断开一下）
  4. 看状态        warp-keeper status
  5. 启用每小时检查 systemctl enable --now warp-keeper.timer
EOF
else
  echo
  echo "已更新程序。/etc/warp-keeper.env 已存在，没有覆盖。新版本新增的配置项请参照 warp-keeper.env.example 补进去"
  echo "（不补也能跑，都有默认值）。列出 env 里还没有的配置项："
  echo "  bash -c \"comm -23 <(grep -oE '^#?[A-Z_]+=' warp-keeper.env.example | tr -d '#' | sort -u) <(grep -oE '^[A-Z_]+=' /etc/warp-keeper.env | sort -u)\""
fi
