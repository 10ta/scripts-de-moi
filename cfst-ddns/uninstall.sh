#!/usr/bin/env bash
# 卸载 cfst-ddns：停掉并删除 timer 和服务，删除 /opt/cfst-ddns（程序、测速工具和 IP 段文件）。
# 配置（/etc/cfst-ddns.env）、测速历史（/var/lib/cfst-ddns）和系统用户 cfst-ddns 都保留，重新安装（./install.sh）时直接沿用；
# 最后会打印彻底删除的命令。
# 影响：不再测速、不再更新 DNS，记录停在最后一次写入的 IP。sing-box TUN 里的 exclude_uid 不用改（用户还在）；
# 要删用户的话，记得同时从 exclude_uid 里去掉它的 UID。
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

systemctl disable --now cfst-ddns.timer >/dev/null 2>&1 || true
systemctl stop 'cfst-ddns@*.service' cfst-ddns.service >/dev/null 2>&1 || true
rm -f '/etc/systemd/system/cfst-ddns@.service' /etc/systemd/system/cfst-ddns.timer /etc/systemd/system/cfst-ddns.service
systemctl daemon-reload
rm -rf /opt/cfst-ddns
echo "✔ cfst-ddns 已卸载（timer、服务、/opt/cfst-ddns）"
uid=$(id -u cfst-ddns 2>/dev/null || true)
kept cfst-ddns /etc/cfst-ddns.env /var/lib/cfst-ddns
[[ -n "$uid" ]] && echo "  （删用户后把 sing-box TUN 的 exclude_uid 里的 $uid 也去掉）"
exit 0
