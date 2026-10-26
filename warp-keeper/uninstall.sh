#!/usr/bin/env bash
# 卸载 warp-keeper：先执行 warp-keeper remove（从 sing-box 配置目录删掉 WARP 片段 → 检查 → 重载 sing-box → 注销 WARP 账户），
# 成功后再停掉并删除 timer 和服务、/opt/warp-keeper、/usr/local/bin/warp-keeper。
# 配置（/etc/warp-keeper.env）和状态（/var/lib/warp-keeper，含已注销账户的记录和可用率历史）保留；最后会打印彻底删除的命令。
# 影响：sing-box 重载一次（所有入站断开一下）。主配置的路由还在引用 WARP 出口时 remove 会拒绝并保持原样，
# 这时卸载也停在这里，什么都不删——先把那些路由改掉再来。
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "请用 root 运行" >&2; exit 1; }

# 保留的东西：列出还在的，并打印彻底删除的命令（不替你删）
kept() {   # kept 用户名或- 路径...
  local user=$1; shift
  local p have=()
  for p in "$@"; do [[ -e "$p" ]] && have+=("$p"); done
  [[ -n "$user" && "$user" != - ]] && id "$user" >/dev/null 2>&1 || user=""
  (( ${#have[@]} )) || [[ -n "$user" ]] || return 0
  echo "保留（重新安装时直接沿用）：${have[*]}${user:+ · 系统用户 $user}"
  echo "确定不再需要的话，手动删除："
  (( ${#have[@]} )) && echo "  rm -rf ${have[*]}"
  [[ -n "$user" ]] && echo "  userdel $user"
  return 0
}

if [[ -x /opt/warp-keeper/warp-keeper.sh ]]; then
  /opt/warp-keeper/warp-keeper.sh remove || { echo "✘ warp-keeper remove 没成功（原因见上面），卸载停在这里，什么都没删" >&2; exit 1; }
fi
systemctl disable --now warp-keeper.timer >/dev/null 2>&1 || true
systemctl stop warp-keeper.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/warp-keeper.service /etc/systemd/system/warp-keeper.timer
systemctl daemon-reload
[[ -L /usr/local/bin/warp-keeper ]] && rm -f /usr/local/bin/warp-keeper
rm -rf /opt/warp-keeper
echo "✔ warp-keeper 已卸载（WARP 片段、timer、服务、/opt/warp-keeper）"
kept - /etc/warp-keeper.env /var/lib/warp-keeper
