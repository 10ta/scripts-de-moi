#!/usr/bin/env bash
# update.sh —— scripts-de-moi 一键更新：本机装了哪几个工具，就更新哪几个
#
#   sudo ./update.sh            同步代码 → 依次更新本机已安装的 cdt-guard、traffic-bot、cfst-ddns
#   sudo ./update.sh --status   只看每个工具的仓库版本、已部署版本、运行状态
#   sudo ./update.sh --no-pull  不同步 git，直接部署磁盘上的代码
#
# 是否已安装按部署目录判断：/opt/cdt-guard、/opt/traffic-bot、/opt/cfst-ddns。没装的跳过，不会帮你新装。
# 影响：会重启本机的 traffic-bot（断开几秒），cdt-guard 会立即执行一次检查，cfst-ddns 的 timer 会重启。
# 只更新其中一个：sudo ./<目录>/update.sh
# ==== 公共部分 v1（各仓库的 update.sh 里这一段完全相同，改的时候一起改）====
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail
SELF="$(readlink -f "$0")"
ARGS=("$@")
if [[ -t 1 ]]; then B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' D=$'\e[2m' N=$'\e[0m'; else B='' G='' Y='' R='' D='' N=''; fi
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '%s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s✘ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }

NO_PULL=0 NO_TEST=0 STATUS=0
for a in "$@"; do
  case "$a" in
    --no-pull) NO_PULL=1 ;;   # 不同步 git、不检查未提交的改动，直接部署磁盘上的代码（比如刚手动打了补丁）
    --no-test) NO_TEST=1 ;;   # 跳过推送前的测试 / 构建检查
    --status)  STATUS=1 ;;    # 只看状态：仓库版本、已部署版本、服务状态，不做任何改动
    -h|--help) sed -n '2,/^# ====/{/^# ====/d;s/^# \{0,1\}//;p}' "$SELF"; exit 0 ;;
    *) die "未知参数：$a（可用：--status / --no-pull / --no-test / --help）" ;;
  esac
done

need_root() { [[ $EUID -eq 0 ]] || die "请用 root 运行：sudo bash $SELF ${ARGS[*]:-}"; }
short() { git rev-parse --short HEAD; }

# sync_repo [允许有改动的文件...]
#   工作区有未提交的改动 → 退出（列出的生成文件除外）；本地和远端分叉 → 退出
#   落后 → 快进拉取；领先 → 记在 AHEAD 里，由调用方决定推送还是只提示
#   拉取后如果 update.sh 自己变了，用新版本重新执行一遍
AHEAD=0
sync_repo() {
  git rev-parse --git-dir >/dev/null 2>&1 || die "$PWD 不是 git 仓库"
  local br bad f behind
  br=$(git rev-parse --abbrev-ref HEAD)
  [[ "$br" != HEAD ]] || die "当前不在任何分支上（detached HEAD），先 git checkout 回主分支"
  if (( NO_PULL )); then   # 明确要求部署磁盘上的代码（比如刚 git apply 了补丁），不检查改动、不同步
    warn "--no-pull：不同步，直接部署磁盘上的代码（$br @ $(short)$(git diff --quiet || echo '，含未提交的改动')）"
    return 0
  fi
  bad=""
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    printf '%s\n' "$@" | grep -qxF -- "$f" || bad+="    $f"$'\n'
  done < <(git status --porcelain --untracked-files=no | cut -c4-)
  [[ -z "$bad" ]] || die "有未提交的改动，先提交或还原（git stash / git checkout -- 文件）：
$bad"
  [[ -n "${UPDATE_REEXEC:-}" ]] && { ok "代码已同步（$br @ $(short)）"; return 0; }   # 刚刚已经同步过（新版本 update.sh 重新执行 / 根目录脚本调用）
  git fetch -q origin "$br" || die "git fetch 失败（网络不通，或远端没有 $br 分支）"
  read -r behind AHEAD < <(git rev-list --left-right --count "origin/$br...HEAD")
  (( behind && AHEAD )) && die "本地和远端分叉了：本地多 $AHEAD 个提交，远端多 $behind 个。
    手动处理：git pull --rebase，解决冲突后再运行本脚本"
  if (( behind )); then
    local before_self after_self old
    old=$(short)
    before_self=$(sha256sum "$SELF" | cut -c1-64)
    git merge -q --ff-only "origin/$br"
    ok "已拉取 $behind 个新提交：$old → $(short)"
    after_self=$(sha256sum "$SELF" 2>/dev/null | cut -c1-64 || true)
    if [[ "$before_self" != "$after_self" && -z "${UPDATE_REEXEC:-}" ]]; then
      warn "update.sh 本身也更新了，用新版本重新执行"
      UPDATE_REEXEC=1 exec bash "$SELF" "${ARGS[@]}"
    fi
  elif (( ! AHEAD )); then
    ok "代码已是最新（$br @ $(short)）"
  fi
  return 0
}

# push_ahead：把本地领先的提交推到远端（推送即部署的项目用）
push_ahead() {
  local br; br=$(git rev-parse --abbrev-ref HEAD)
  (( NO_PULL )) && return 0
  read -r _ AHEAD < <(git rev-list --left-right --count "origin/$br...HEAD")
  if (( AHEAD )); then
    git push -q origin "$br" || die "git push 失败"
    ok "已推送 $AHEAD 个提交到 origin/$br"
  fi
}

# 部署记录：/opt/<应用>/DEPLOYED 里写「commit 时间」，--status 和下次更新时用来对比
mark_deployed() { printf '%s %s\n' "$(short)" "$(date '+%F %T')" > "$1"; }
deployed_of()   { [[ -f "$1" ]] && cut -d' ' -f1 "$1" || echo "未记录"; }

# same_file 仓库里的文件 已部署的文件：两边不一致就退出
same_file() { cmp -s "$1" "$2" || die "$2 和仓库里的 $1 不一致，部署没有生效"; }

# restarted 服务名：确认服务在运行，而且是本脚本开始之后启动的（不是旧进程）
T0=$(date +%s)
restarted() {
  local s=$1 ts
  systemctl is-active --quiet "$s" || die "$s 没有在运行，看日志：journalctl -u $s -n 50 --no-pager"
  ts=$(date -d "$(systemctl show -p ActiveEnterTimestamp --value "$s")" +%s 2>/dev/null || echo 0)
  (( ts >= T0 - 2 )) || die "$s 还是旧进程（启动于 $(systemctl show -p ActiveEnterTimestamp --value "$s")），没有被重启。手动：systemctl restart $s"
  ok "$s 已重启，运行中"
}
# ==== 公共部分结束 ====

need_root
cd "$(dirname "$SELF")"
TOOLS=(CDT-Management:/opt/cdt-guard/cdt_guard.py traffic-bot:/opt/traffic-bot/bot.py cfst-ddns:/opt/cfst-ddns/cfst-ddns.sh)

found=()
for t in "${TOOLS[@]}"; do [[ -f "${t#*:}" ]] && found+=("${t%%:*}"); done

if (( STATUS )); then
  git fetch -q origin "$(git rev-parse --abbrev-ref HEAD)" 2>/dev/null || warn "fetch 失败，远端版本可能不是最新"
  echo "仓库   $(git rev-parse --abbrev-ref HEAD) @ $(short) · 远端 $(git rev-parse --short '@{u}' 2>/dev/null || echo ?)"
  for d in "${found[@]}"; do echo; bash "$d/update.sh" --status; done
  (( ${#found[@]} )) || echo "本机一个都没装"
  exit 0
fi

(( ${#found[@]} )) || die "本机没有安装任何一个工具（/opt/cdt-guard、/opt/traffic-bot、/opt/cfst-ddns 都不存在）"
echo "本机已安装：${found[*]}"

step "同步代码"
sync_repo

rc=0 done_=() failed=()
for d in "${found[@]}"; do
  printf '\n%s━━━━━━━━ %s ━━━━━━━━%s\n' "$B" "$d" "$N"
  if UPDATE_REEXEC=1 bash "$d/update.sh"; then done_+=("$d"); else failed+=("$d"); rc=1; fi
done

echo
(( ${#done_[@]} )) && ok "已更新到 $(short)：${done_[*]}"
(( ${#failed[@]} )) && warn "失败：${failed[*]}（见上面的输出）"
exit $rc
