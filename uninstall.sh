#!/usr/bin/env bash
# uninstall.sh —— 卸载本机装的 scripts-de-moi 工具：列出装了哪些，选要卸载的，确认后逐个卸载
#
#   sudo ./uninstall.sh
#
# 只删程序、服务和定时器；配置、密钥、状态（历史数据）和专用系统用户都保留，重新安装时直接沿用。
# 每个工具卸载完会打印彻底删除这些的命令，需要的话自己执行。
# 各工具也可以单独卸载：sudo ./<目录>/uninstall.sh（CDT-Management 是 bash CDT-Management/init.sh uninstall，
# brutal-cn 是 bash brutal-cn.sh uninstall）
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail
if [[ -t 1 ]]; then B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' N=$'\e[0m'; else B='' G='' Y='' R='' N=''; fi
ok()   { printf '%s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s✘ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "请用 root 运行：sudo ./uninstall.sh"
[[ -t 0 ]] || die "需要在终端里运行（要选择和确认）"
cd "$(dirname "$(readlink -f "$0")")"

# 名字 | 判断已安装的路径（任一存在就算，没装完的也能卸） | 卸载命令 | 卸载的影响
TOOLS=(
  "cdt-guard|/opt/cdt-guard /etc/systemd/system/cdt-guard.timer|bash CDT-Management/init.sh uninstall|停止阿里云 CDT 流量检查；sg 模式会先删掉安全组里 cdt-guard 加的规则。实例本身不动，处于关机熔断时要自己去控制台开机"
  "traffic-bot|/opt/traffic-bot /etc/systemd/system/traffic-bot.service|bash traffic-bot/uninstall.sh|Telegram 流量机器人停止响应和告警（cdt-guard 的通知不受影响）"
  "cfst-ddns|/opt/cfst-ddns /etc/systemd/system/cfst-ddns.timer /etc/systemd/system/cfst-ddns@.service|bash cfst-ddns/uninstall.sh|不再测速、不再更新 DNS，记录停在最后一次的 IP"
  "warp-keeper|/opt/warp-keeper /etc/systemd/system/warp-keeper.timer|bash warp-keeper/uninstall.sh|从 sing-box 删掉 WARP 片段并重载 sing-box（所有入站断开一下）、注销 WARP 账户；主配置还有路由引用 WARP 出口时会拒绝、什么都不删"
  "brutal-cn|/etc/systemd/system/brutal-cn-update.timer /var/lib/brutal-cn|bash brutal-cn.sh uninstall|删除本工具创建的 TCP Brutal 规则、定时器和缓存（brutalctl 和内核模块保留，其他规则不动）"
)

found=()
for t in "${TOOLS[@]}"; do
  IFS='|' read -r name paths _ _ <<<"$t"
  for p in $paths; do [[ -e "$p" ]] && { found+=("$t"); break; }; done
done
(( ${#found[@]} )) || { ok "本机没有装任何一个工具，不用卸载"; exit 0; }

echo "${B}本机装了：${N}"
for i in "${!found[@]}"; do
  IFS='|' read -r name _ _ impact <<<"${found[$i]}"
  printf '  %s%d)%s %-12s %s\n' "$B" $((i + 1)) "$N" "$name" "$impact"
done
echo
read -r -p "要卸载哪几个？输入编号（空格分开，a = 全部，直接回车 = 取消）：" ans
[[ -n "$ans" ]] || { echo "已取消"; exit 0; }
pick=()
if [[ "$ans" == a || "$ans" == A ]]; then
  pick=("${found[@]}")
else
  for n in $ans; do
    [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#found[@]} )) || die "没有这个编号：$n"
    pick+=("${found[$((n - 1))]}")
  done
fi

echo
echo "${B}将要卸载：${N}"
for t in "${pick[@]}"; do IFS='|' read -r name _ _ impact <<<"$t"; echo "  · $name：$impact"; done
echo "配置、密钥、状态和专用用户都保留。"
read -r -p "确认卸载？输入 yes 继续：" yn
[[ "$yn" == yes ]] || { echo "已取消，什么都没动"; exit 0; }

done_=() failed=()
for t in "${pick[@]}"; do
  IFS='|' read -r name _ cmd _ <<<"$t"
  printf '\n%s━━━━━━━━ %s ━━━━━━━━%s\n' "$B" "$name" "$N"
  if $cmd; then done_+=("$name"); else failed+=("$name"); fi
done

echo
(( ${#done_[@]} )) && ok "已卸载：${done_[*]}"
(( ${#failed[@]} )) && { warn "没卸载成功：${failed[*]}（见上面的输出）"; exit 1; }
exit 0
