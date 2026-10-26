#!/usr/bin/env bash
# 卸载 traffic-bot：停掉并删除 systemd 服务，删除 /opt/traffic-bot（程序和 venv）。
# 配置（/etc/traffic-bot.env）、密钥（/etc/traffic-bot/）、告警状态（/var/lib/traffic-bot）和系统用户 trafficbot 都保留，
# 重新安装（./install.sh）时直接沿用；最后会打印彻底删除的命令。
# 影响：Telegram 上的流量机器人停止响应和告警。cdt-guard 发通知读的是 /etc/traffic-bot.env，保留着所以不受影响。
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

systemctl disable --now traffic-bot >/dev/null 2>&1 || true
rm -f /etc/systemd/system/traffic-bot.service
systemctl daemon-reload
rm -rf /opt/traffic-bot
echo "✔ traffic-bot 已卸载（服务、/opt/traffic-bot）"
kept trafficbot /etc/traffic-bot.env /etc/traffic-bot /var/lib/traffic-bot
