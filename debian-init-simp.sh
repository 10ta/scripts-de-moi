#!/usr/bin/env bash
# =============================================================================
# debian-init.sh — 新 Debian 13 初始化脚本（小磁盘友好版）
#
# 用法（root 执行，必须以文件方式运行，不支持 curl | bash）:
#   ./debian-init.sh              交互菜单，勾选要执行的模块
#   --all                         按顺序执行全部模块
#   --only a,b,c                  只执行指定模块
#   --list                        列出全部模块
#
# 特点:
#   - 幂等：可重复运行；改动文件前备份为 <文件>.bak.<时间>
#   - 追加的配置用标记块包裹，重复运行时整块替换
#   - 每个模块在独立子进程中运行，一个失败不影响其他模块
#   - 小磁盘友好：
#       * apt 安装前用 apt-get -s 精确估算空间（下载 + 解压），不够就不动手
#       * 每次 apt 安装后自动 apt-get clean，不让 .deb 缓存堆积
#       * 下载用的临时目录在磁盘（/var/tmp）而不是内存 tmpfs，退出时自动清理
#       * 写配置文件先写同目录临时文件再 mv 替换，磁盘满时原文件不会被截断
#       * 各模块自带依赖（curl/gpg/ufw/chrony...），软件清单由 PACKAGES 自己决定
# =============================================================================

# ============================== 配置区 =======================================

# SSH 端口：留空则运行时提示输入；也可以这样传入：SSH_PORT=xxxx ./debian-init.sh
SSH_PORT="${SSH_PORT:-}"

TIMEZONE="Asia/Taipei"

# Go 版本：留空则安装最新稳定版；也可指定，如 "go1.26.1"
GO_VERSION=""

# 额外安装的 apt 软件（packages 模块只装这里的）。
# 各模块需要的依赖（curl、gpg、ufw、chrony 等）会在模块里自动补装，不必写在这里。
# 体积参考：clang+llvm+lld 约 0.5~1GB，小磁盘建议用到时再装。
PACKAGES=(
  vim htop lsd bind9-host git unzip wget iperf3 fuse3
  # clang llvm lld
)

# 磁盘余量：任何安装动作完成后，至少要给系统留下这么多 MB
RESERVE_MB=200

# 非 apt 模块的磁盘需求估算（MB，下载 + 解压；apt 软件在安装时动态估算）
declare -A NEED_MB=(
  [nvim]=120
  [go]=450
  [caddy]=120
  [singbox]=100
)

# UFW 放行规则（SSH 端口会自动放行，无需写在这里）
UFW_RULES=(
  "80"
  "443"
  "27000:27050/tcp"
  "27000:27050/udp"
  "65000:65500/tcp"
  "65000:65500/udp"
)

# 日志总量控制（目标：全部日志 < 100MB；小磁盘可以再调小）
JOURNAL_SYSTEM_MAX="50M"
JOURNAL_RUNTIME_MAX="10M"
JOURNAL_FILE_MAX="10M"
LOGROTATE_MAXSIZE="10M"

# 串口控制台内核参数（合并进 GRUB_CMDLINE_LINUX，不覆盖原有参数）
SERIAL_CMDLINE="console=tty0 console=ttyS0,115200 earlyprintk=ttyS0,115200 consoleblank=0"

# =============================================================================

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export HOME=/root

readonly SELF="$(readlink -f "$0")"
readonly ROOT_HOME="/root"
readonly TS="$(date +%Y%m%d%H%M%S)"
readonly MARK="debian-init"

# 临时目录放在磁盘上（Debian 13 的 /tmp 默认是占内存的 tmpfs），退出时自动清理
TMP_ROOT="$(mktemp -d "/var/tmp/${MARK}.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

# 模块顺序即执行顺序：名称|说明
MODULES=(
  "grub|串口控制台 + GRUB 等待时间 0"
  "packages|基础软件（由配置区 PACKAGES 决定）"
  "chrony|时间同步"
  "ssh|SSH 密钥、GitHub 走 443、sshd 端口、关闭密码登录"
  "brutal|TCP Brutal"
  "ufw|防火墙"
  "fish|fish 4（OBS 源）+ fisher + config.fish + 设为默认 shell"
  "lsd|lsd 配置"
  "nvim|Neovim（GitHub Release）"
  "go|Go（官方二进制，默认最新稳定版）"
  "node|Node.js LTS（NodeSource）+ pnpm"
  "logs|journald + logrotate 限额"
  "timezone|时区 ${TIMEZONE}"
  "exim4|卸载 exim4"
  "caddy|Caddy（lxhao61 构建版）"
  "singbox|sing-box（upsing.sh）"
  "clean|清理 apt 缓存与旧日志，显示剩余空间"
)

# ============================== 公共函数 =====================================

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_blu=$'\e[36m'; c_off=$'\e[0m'
info() { echo "${c_blu}[*]${c_off} $*"; }
ok()   { echo "${c_grn}[✓]${c_off} $*"; }
warn() { echo "${c_ylw}[!]${c_off} $*" >&2; }
die()  { echo "${c_red}[✗]${c_off} $*" >&2; exit 1; }
trap 'echo "${c_red}[✗]${c_off} 出错：第 ${LINENO} 行：${BASH_COMMAND}" >&2' ERR

confirm() { # confirm "问题" → 返回 0 表示是
  local ans
  read -r -p "${c_ylw}[?]${c_off} $1 [y/N] " ans </dev/tty
  [[ "$ans" =~ ^[Yy]$ ]]
}

backup() { # 每个文件每次运行只备份一次
  local f="$1"
  [[ -e "$f" && ! -e "$f.bak.$TS" ]] && cp -a "$f" "$f.bak.$TS" && info "已备份 $f → $f.bak.$TS"
  return 0
}

# ---- 磁盘 ----------------------------------------------------------------

free_mb() { # free_mb [路径] —— 剩余空间（MB）
  df -Pm "${1:-/}" | awk 'NR==2{print $4}'
}

need_space() { # need_space MB 说明 [路径] —— 空间不够就中止当前模块（含 RESERVE_MB 余量）
  local need=$(( $1 + RESERVE_MB )) desc="$2" path="${3:-/}" free
  free="$(free_mb "$path")"
  if (( free < need )); then
    die "磁盘空间不足：${desc} 需要约 ${need}MB（含 ${RESERVE_MB}MB 余量），${path} 仅剩 ${free}MB"
  fi
  info "磁盘检查通过：${desc} 需要约 ${need}MB，${path} 剩余 ${free}MB"
}

mk_tmpdir() { mktemp -d "$TMP_ROOT/XXXXXX"; }
mk_tmpfile() { mktemp "$TMP_ROOT/XXXXXX"; }

# ---- 文件写入 ------------------------------------------------------------

atomic_write() { # atomic_write 文件 [模式] —— 从 stdin 读内容，先写同目录临时文件再 mv；磁盘满时原文件不受影响
  local f tmp mode="${2:-}"
  f="$(readlink -f "$1")"
  tmp="$(mktemp "$(dirname "$f")/.${MARK}.XXXXXX")"
  if ! cat >"$tmp" || ! sync "$tmp"; then
    rm -f "$tmp"; warn "写入失败（磁盘已满？）：$f，原文件未改动"; return 1
  fi
  if [[ -n "$mode" ]]; then chmod "$mode" "$tmp"
  elif [[ -e "$f" ]]; then chmod --reference="$f" "$tmp"; chown --reference="$f" "$tmp"
  else chmod 644 "$tmp"; fi
  mv -f "$tmp" "$f"
}

write_block() { # write_block 文件 块名 内容 —— 替换或追加标记块
  local file="$1" name="$2" content="$3"
  local begin="# >>> ${MARK}: ${name} >>>" end="# <<< ${MARK}: ${name} <<<"
  mkdir -p "$(dirname "$file")"; touch "$file"; backup "$file"
  {
    awk -v b="$begin" -v e="$end" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$file"
    printf '%s\n%s\n%s\n' "$begin" "$content" "$end"
  } | atomic_write "$file"
}

set_kv() { # set_kv 文件 KEY VALUE —— 设置 KEY=VALUE（存在则替换，否则追加）
  local file="$1" key="$2" val="$3"
  backup "$file"
  if grep -qE "^[#[:space:]]*${key}=" "$file"; then
    sed -i -E "0,/^[#[:space:]]*${key}=.*/s||${key}=${val}|" "$file"
  else
    echo "${key}=${val}" >>"$file"
  fi
}

# ---- apt -----------------------------------------------------------------

APT_UPDATED=""
apt_update_once() { [[ -n "$APT_UPDATED" ]] || { apt-get update -y; APT_UPDATED=1; }; }

apt_peak_mb() { # apt_peak_mb 包... —— 用 apt-get -s 估算峰值空间（MB）= 下载的 .deb + 解压后增量；不依赖系统语言
  LC_ALL=C apt-get -s install -y --no-install-recommends "$@" 2>/dev/null | awk '
    function mb(v, u) {
      gsub(/,/, "", v)
      if (u == "B")  return v / 1000000
      if (u == "kB") return v / 1000
      if (u == "MB") return v
      if (u == "GB") return v * 1000
      return 0
    }
    /^Need to get / {
      s = $0; sub(/^Need to get /, "", s)
      if (index(s, "/")) s = substr(s, index(s, "/") + 1)   # 取总大小，偏保守
      split(s, a, " "); dl = mb(a[1], a[2])
    }
    /^After this operation, .*additional disk space/ {
      s = $0; sub(/^After this operation, /, "", s)
      split(s, a, " "); inst = mb(a[1], a[2])
    }
    END { printf "%d\n", dl + inst + 1 }'
}

apt_install() { # 安装前估算空间，安装后清缓存
  local est
  apt_update_once
  est="$(apt_peak_mb "$@")" || est=0
  need_space "${est:-0}" "apt 安装 $*"
  apt-get install -y --no-install-recommends "$@"
  apt-get clean
}

ensure_pkg() { # ensure_pkg 包... —— 只装缺少的包
  local p miss=()
  for p in "$@"; do
    dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null | grep -qx installed || miss+=("$p")
  done
  ((${#miss[@]})) || return 0
  info "补装依赖：${miss[*]}"
  apt_install "${miss[@]}"
}

ensure_net() { ensure_pkg ca-certificates curl; }

# ---- 其他 ----------------------------------------------------------------

arch() { # 输出 amd64 / arm64
  case "$(uname -m)" in
    x86_64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac
}

fish_run() { fish -c "$1"; }

download() { # download URL 目标文件 —— 带重试
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$2" "$1"
}

run_remote() { # run_remote URL [参数...] —— 先完整下载再执行，下载失败不会执行半截脚本
  local url="$1"; shift
  local tmp; tmp="$(mk_tmpfile)"
  curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp" "$url" || { rm -f "$tmp"; die "下载失败：$url"; }
  local rc=0
  bash "$tmp" "$@" || rc=$?
  rm -f "$tmp"; return $rc
}

# ============================== 第一部分：初始化 =============================

mod_grub() {
  local f=/etc/default/grub
  [[ -f "$f" ]] || { warn "未找到 $f（可能不是 GRUB 引导），跳过"; return 0; }

  # 合并串口参数：保留原有参数，只补充缺少的
  local cur new tok
  cur="$(grep -E '^GRUB_CMDLINE_LINUX=' "$f" | head -1 | sed -E 's/^GRUB_CMDLINE_LINUX="?([^"]*)"?/\1/' || true)"
  new="$cur"
  for tok in $SERIAL_CMDLINE; do
    [[ " $new " == *" $tok "* ]] || new="${new:+$new }$tok"
  done
  set_kv "$f" GRUB_CMDLINE_LINUX "\"$new\""
  set_kv "$f" GRUB_TERMINAL '"console serial"'
  set_kv "$f" GRUB_SERIAL_COMMAND '"serial --speed=115200"'
  set_kv "$f" GRUB_TIMEOUT 0
  if command -v update-grub >/dev/null; then update-grub
  else grub-mkconfig -o /boot/grub/grub.cfg; fi
  ok "GRUB 已更新（重启后生效）"
}

mod_packages() {
  apt_update_once
  # iperf3 安装时会询问是否作为守护进程运行，预先回答"否"
  echo "iperf3 iperf3/start_daemon boolean false" | debconf-set-selections
  if ((${#PACKAGES[@]} == 0)); then info "PACKAGES 为空，跳过"; return 0; fi
  apt_install "${PACKAGES[@]}"
  ok "基础软件已安装：${PACKAGES[*]}"
}

mod_chrony() {
  ensure_pkg chrony
  systemctl enable --now chrony
  sleep 2
  chronyc tracking || true
  ok "chrony 已启用"
}

read_private_key() { # 从终端读取多行私钥，直到 END 行
  local line key=""
  echo "请粘贴私钥（以 -----BEGIN 开头，粘贴完 END 行后自动结束）：" >/dev/tty
  while IFS= read -r line </dev/tty; do
    line="${line%$'\r'}"            # 去掉 Windows 换行符
    key+="$line"$'\n'
    [[ "$line" == -----END*PRIVATE\ KEY----- ]] && break
  done
  printf '%s' "$key"
}

mod_ssh() {
  local dir="$ROOT_HOME/.ssh" priv pub name
  install -d -m 700 "$dir"

  priv="$(read_private_key)"
  [[ "$priv" == -----BEGIN*PRIVATE\ KEY-----* ]] || die "私钥格式不正确"
  read -r -p "请粘贴公钥（一行）：" pub </dev/tty
  pub="${pub%$'\r'}"
  [[ -n "$pub" ]] || die "公钥为空"

  # 按公钥类型命名
  case "${pub%% *}" in
    ssh-ed25519) name=id_ed25519 ;;
    ssh-rsa)     name=id_rsa ;;
    ecdsa-*)     name=id_ecdsa ;;
    *) die "无法识别的公钥类型：${pub%% *}" ;;
  esac

  # 写入密钥文件
  [[ -e "$dir/$name" ]] && backup "$dir/$name" && backup "$dir/$name.pub"
  printf '%s' "$priv" | atomic_write "$dir/$name" 600
  printf '%s\n' "$pub" | atomic_write "$dir/$name.pub" 644

  # 校验私钥和公钥是否配对（有口令的私钥跳过校验）
  local derived
  if derived="$(ssh-keygen -y -P "" -f "$dir/$name" 2>/dev/null)"; then
    [[ "$(awk '{print $1,$2}' <<<"$derived")" == "$(awk '{print $1,$2}' <<<"$pub")" ]] \
      || die "私钥和公钥不配对，请检查粘贴内容"
    ok "私钥与公钥配对校验通过"
  else
    warn "私钥可能设有口令，跳过配对校验"
  fi

  # authorized_keys：追加（不覆盖已有的其他公钥）
  touch "$dir/authorized_keys"
  grep -qxF "$pub" "$dir/authorized_keys" || echo "$pub" >>"$dir/authorized_keys"
  chmod 600 "$dir/authorized_keys"

  # 客户端配置：GitHub 走 443
  write_block "$dir/config" github "Host github.com
  HostName ssh.github.com
  User git
  Port 443
  IdentityFile ~/.ssh/$name"
  chmod 600 "$dir/config"
  chown -R root:root "$dir"
  ok "密钥文件与 ~/.ssh/config 已写入"

  # sshd：端口 + 仅允许密钥登录
  # 00- 开头：sshd 对同一参数只取第一次读到的值，要排在云镜像的 50-cloud-init.conf 之前
  local main=/etc/ssh/sshd_config dropin=/etc/ssh/sshd_config.d/00-init.conf
  backup "$main"
  sed -i -E 's/^[[:space:]]*Port[[:space:]]+/#&/' "$main"   # 注释主配置中的 Port，统一由 drop-in 管理
  if grep -rqsE '^[[:space:]]*Port[[:space:]]' /etc/ssh/sshd_config.d/ --exclude=00-init.conf; then
    warn "sshd_config.d 中其他文件也设置了 Port，请手动检查"
  fi
  backup "$dropin"
  atomic_write "$dropin" 644 <<EOF
# ${MARK}
Port ${SSH_PORT}
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  sshd -t || die "sshd 配置检查失败，未重启 sshd"
  if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    warn "检测到 ssh.socket 已启用：端口由 socket 单元决定，sshd_config 中的 Port 不生效，请手动检查"
  fi

  # 若 UFW 已启用，先放行新端口，防止重启 sshd 后被防火墙挡住
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${SSH_PORT}/tcp"
  fi
  systemctl restart ssh
  ok "sshd 已重启：端口 ${SSH_PORT}，仅允许密钥登录（当前连接不受影响）"

  echo
  warn "请【不要关闭当前窗口】，新开一个终端测试密钥登录："
  echo "  ssh -p ${SSH_PORT} -i <本地私钥> root@<服务器IP>"
  if confirm "新窗口用密钥登录成功了吗？"; then
    ok "SSH 配置完成"
  else
    sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' "$dropin"
    sshd -t && systemctl restart ssh
    die "已恢复密码登录。请排查密钥问题后重新运行：--only ssh"
  fi
}

mod_brutal() {
  ensure_net
  run_remote https://tcp.hy2.sh/
  ok "TCP Brutal 已安装（更换内核后需重新运行：--only brutal）"
}

mod_ufw() {
  ensure_pkg ufw
  ufw allow "${SSH_PORT}/tcp"
  local r
  for r in "${UFW_RULES[@]}"; do ufw allow "$r"; done
  ufw --force enable
  ufw status verbose
  ok "UFW 已启用"
}

mod_fish() {
  ensure_pkg ca-certificates curl gpg
  local list=/etc/apt/sources.list.d/shells:fish:release:4.list
  local key=/etc/apt/trusted.gpg.d/shells_fish_release_4.gpg
  local repo="https://download.opensuse.org/repositories/shells:/fish:/release:/4/Debian_13"

  echo "deb ${repo}/ /" >"$list"
  curl -fsSL "${repo}/Release.key" | gpg --dearmor --yes -o "$key"
  apt-get update -y
  APT_UPDATED=1
  apt_install fish
  ok "fish 已安装：$(fish --version)"

  # fisher
  fish_run 'curl -fsSL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher'

  # config.fish（pnpm 的配置块由 pnpm 安装脚本自行写入，见 node 模块）
  write_block "$ROOT_HOME/.config/fish/config.fish" aliases 'alias ls="lsd"
alias vi="nvim"'

  # 设为 root 默认 shell
  local fish_bin; fish_bin="$(command -v fish)"
  grep -qxF "$fish_bin" /etc/shells || echo "$fish_bin" >>/etc/shells
  chsh -s "$fish_bin" root
  ok "fisher 与 config.fish 已配置，root 默认 shell → ${fish_bin}（重新登录生效）"
}

mod_lsd() {
  local f="$ROOT_HOME/.config/lsd/config.yaml"
  mkdir -p "$(dirname "$f")"; backup "$f"
  atomic_write "$f" 644 <<'EOF'
icons:
  separator: " "
EOF
  ok "lsd 配置已写入"
}

mod_nvim() {
  ensure_net
  local a pkg tmp
  case "$(arch)" in amd64) a=x86_64 ;; arm64) a=arm64 ;; esac
  pkg="nvim-linux-${a}"
  tmp="$(mk_tmpdir)"
  download "https://github.com/neovim/neovim/releases/latest/download/$pkg.tar.gz" "$tmp/$pkg.tar.gz"
  rm -rf "/opt/$pkg"
  tar -C /opt -xzf "$tmp/$pkg.tar.gz"
  rm -rf "$tmp"
  # 软链接到 /usr/local/bin：bash、fish 和其他程序都能直接找到，无需改 PATH
  ln -sf "/opt/$pkg/bin/nvim" /usr/local/bin/nvim
  ok "Neovim 已安装：$(nvim --version | head -1)"
}

mod_go() {
  ensure_net
  # 官方二进制安装到 /usr/local/go，并链接到 /usr/local/bin：所有 shell 和程序都能直接使用
  local a ver tmp sum
  a="$(arch)"
  if [[ -n "$GO_VERSION" ]]; then
    ver="$GO_VERSION"
  else
    ver="$(curl -fsSL 'https://go.dev/VERSION?m=text')"; ver="${ver%%$'\n'*}"
  fi
  [[ "$ver" == go* ]] || die "无法获取 Go 版本号：${ver}"

  if [[ -x /usr/local/go/bin/go && "$(/usr/local/go/bin/go env GOVERSION)" == "$ver" ]]; then
    info "Go ${ver} 已安装，跳过下载"
  else
    tmp="$(mk_tmpdir)"
    download "https://dl.google.com/go/${ver}.linux-${a}.tar.gz" "$tmp/go.tar.gz"
    sum="$(curl -fsSL "https://dl.google.com/go/${ver}.linux-${a}.tar.gz.sha256")"
    echo "${sum}  $tmp/go.tar.gz" | sha256sum -c - >/dev/null || die "Go 安装包校验失败"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "$tmp/go.tar.gz"
    rm -rf "$tmp"
  fi
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

  # go install 装的程序放在 ~/go/bin，加入 PATH
  write_block "$ROOT_HOME/.bashrc" go 'export PATH="$PATH:$HOME/go/bin"'
  if command -v fish >/dev/null; then
    write_block "$ROOT_HOME/.config/fish/config.fish" go 'fish_add_path -a $HOME/go/bin'
  fi
  ok "Go 已安装：$(go version)"
}

mod_node() {
  ensure_net
  # NodeSource LTS：apt 统一管理，所有 shell 和 systemd 服务都能用，apt upgrade 即可跟进同一大版本的更新
  run_remote https://deb.nodesource.com/setup_lts.x
  APT_UPDATED=1
  apt_install nodejs
  ok "Node.js 已安装：$(node --version)"

  # pnpm：以 fish 为目标 shell，安装脚本会自行写入 config.fish 的 pnpm 配置块
  need_space 150 "pnpm"
  curl -fsSL https://get.pnpm.io/install.sh | env SHELL="$(command -v fish || echo /bin/bash)" sh -
  ok "pnpm 已安装（重新登录后生效）"
}

mod_logs() {
  # journald：drop-in 方式，不改主配置，系统更新不会覆盖
  local jd=/etc/systemd/journald.conf.d/00-init.conf
  mkdir -p "$(dirname "$jd")"; backup "$jd"
  atomic_write "$jd" 644 <<EOF
# ${MARK}
[Journal]
SystemMaxUse=${JOURNAL_SYSTEM_MAX}
SystemMaxFileSize=${JOURNAL_FILE_MAX}
RuntimeMaxUse=${JOURNAL_RUNTIME_MAX}
EOF
  systemctl restart systemd-journald
  journalctl --vacuum-size="${JOURNAL_SYSTEM_MAX}" || true

  # logrotate：未安装则跳过（要用请把 logrotate 加进 PACKAGES）
  local lr=/etc/logrotate.conf
  if [[ ! -f "$lr" ]]; then
    warn "未安装 logrotate，跳过 logrotate 限额（需要的话把 logrotate 加进 PACKAGES）"
    ok "journald 限额已设置：${JOURNAL_SYSTEM_MAX}"
    return 0
  fi

  # 全局 maxsize + compress，必须写在 include 之前才会作用于各软件包的日志
  backup "$lr"
  sed -i -E '/^[#[:space:]]*maxsize[[:space:]]/d' "$lr"
  sed -i -E "0,/^include[[:space:]]+\/etc\/logrotate.d/s||maxsize ${LOGROTATE_MAXSIZE}\n&|" "$lr"
  sed -i -E 's/^#[[:space:]]*compress[[:space:]]*$/compress/' "$lr"
  grep -qE '^compress' "$lr" || sed -i -E "0,/^maxsize/s//compress\n&/" "$lr"

  # timer 改为每小时触发（maxsize 在检查时超限即轮转）
  local td=/etc/systemd/system/logrotate.timer.d
  mkdir -p "$td"
  atomic_write "$td/override.conf" 644 <<'EOF'
[Timer]
OnCalendar=
OnCalendar=hourly
EOF
  systemctl daemon-reload
  systemctl restart logrotate.timer
  logrotate -d "$lr" >/dev/null 2>&1 || warn "logrotate 配置检查有警告，请运行 logrotate -d /etc/logrotate.conf 查看"
  ok "日志限额已设置：journal ${JOURNAL_SYSTEM_MAX}，单个日志 ${LOGROTATE_MAXSIZE}，每小时检查"
}

mod_timezone() {
  timedatectl set-timezone "$TIMEZONE"
  ok "时区：$(timedatectl show -p Timezone --value)"
}

mod_exim4() {
  local pkgs=()
  mapfile -t pkgs < <(dpkg-query -W -f='${Package} ${db:Status-Status}\n' 'exim4*' 2>/dev/null | awk '$2=="installed"{print $1}')
  if ((${#pkgs[@]})); then
    systemctl disable --now exim4 2>/dev/null || true
    apt-get purge -y "${pkgs[@]}"
    apt-get autoremove -y
    ok "exim4 已卸载"
  else
    info "exim4 未安装，跳过"
  fi
}

# ============================== 第三部分：软件安装 ===========================

mod_caddy() {
  ensure_net
  local a tmp
  case "$(arch)" in amd64) a=amd64 ;; arm64) a=arm64 ;; esac
  tmp="$(mk_tmpdir)"
  download "https://github.com/lxhao61/integrated-examples/releases/latest/download/caddy-linux-${a}.tar.gz" \
    "$tmp/caddy.tar.gz"
  tar -C "$tmp" -xzf "$tmp/caddy.tar.gz"
  (cd "$tmp" && sha256sum -c sha256) || die "Caddy 校验失败"
  systemctl stop caddy 2>/dev/null || true
  install -m 755 "$tmp/caddy" /usr/bin/caddy
  rm -rf "$tmp"

  mkdir -p /etc/caddy
  touch /etc/caddy/Caddyfile
  local svc=/etc/systemd/system/caddy.service
  backup "$svc"
  atomic_write "$svc" 644 <<'EOF'
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
# StandardOutput=append:/var/log/caddy.log
# StandardError=append:/var/log/caddy.log

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now caddy
  ok "Caddy 已安装并启动：$(caddy version | head -1)"
}

mod_singbox() {
  ensure_net
  run_remote https://raw.githubusercontent.com/10ta/scripts-de-moi/main/upsing.sh
  ok "sing-box 已安装（配置与启动请手动处理）"
}

mod_clean() {
  apt-get clean
  journalctl --vacuum-size="${JOURNAL_SYSTEM_MAX}" >/dev/null 2>&1 || true
  df -h /
  ok "已清理 apt 缓存与超限日志"
}

# ============================== 主流程 =======================================

list_modules() {
  local i=1 m
  for m in "${MODULES[@]}"; do printf ' %2d. %-10s %s\n' "$i" "${m%%|*}" "${m#*|}"; ((i++)); done
}

usage() {
  cat <<'EOF'
用法（root 执行，必须以文件方式运行，不支持 curl | bash）:
  ./debian-init.sh              交互菜单，勾选要执行的模块
  ./debian-init.sh --all        按顺序执行全部模块
  ./debian-init.sh --only a,b,c 只执行指定模块
  ./debian-init.sh --list       列出全部模块
软件清单、磁盘余量等在脚本开头的「配置区」修改。
EOF
  echo; echo "模块："; list_modules
}

select_menu() { # whiptail 勾选菜单；输出选中的模块名
  local args=() m
  for m in "${MODULES[@]}"; do args+=("${m%%|*}" "${m#*|}" ON); done
  whiptail --title "debian-init" --separate-output \
    --checklist "空格勾选/取消，回车确认" 24 90 16 "${args[@]}" 3>&1 1>&2 2>&3
}

ask_ssh_port() { # 选中 ssh 或 ufw 模块且未设置端口时提示输入
  local need=0 m
  for m in "$@"; do [[ "$m" == ssh || "$m" == ufw ]] && need=1; done
  ((need)) || return 0
  while [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || ((SSH_PORT < 1 || SSH_PORT > 65535)); do
    read -r -p "${c_ylw}[?]${c_off} 请输入 SSH 端口（1-65535）：" SSH_PORT </dev/tty
  done
  export SSH_PORT
  info "SSH 端口：${SSH_PORT}"
}

preflight_disk() { # 开始前汇总磁盘情况；非 apt 模块的静态估算超过剩余空间时让人确认
  local m sum=0 free
  for m in "$@"; do sum=$((sum + ${NEED_MB[$m]:-0})); done
  free="$(free_mb /)"
  info "磁盘：/ 剩余 ${free}MB；所选模块中非 apt 部分估算约 ${sum}MB（apt 软件在安装时再逐次精确估算）"
  if (( free < sum + RESERVE_MB )); then
    warn "剩余空间可能不足以装完所选模块（需约 $((sum + RESERVE_MB))MB，含 ${RESERVE_MB}MB 余量）"
    confirm "仍然继续？（空间不够的模块会在动手前自行中止）" || exit 1
  fi
}

print_todo() {
  cat <<'EOF'

==================== 待手动处理 ====================
 1. 修改 root 密码（重装时的临时密码）
 2. sing-box：放入配置文件，启用并启动服务
 3. DNS：sing-box 的 DNS 就绪后，将 /etc/resolv.conf 指向 127.0.0.1
 4. 内核与网络优化（文档 2.10）：按需更换 BBRv3 内核等
    → 更换内核并重启后，重新安装 Brutal：./debian-init.sh --only brutal
 5. 网络调优（文档第 3 章）：按 BDP 计算并写入 sysctl 配置
 6. Caddy：编写 /etc/caddy/Caddyfile，然后 systemctl reload caddy
 7. 仅旁路由机器：UFW 内网转发规则与回程 MASQUERADE（文档 2.9）
 8. 重启一次，使 GRUB 串口控制台、默认 shell 等设置生效
====================================================
EOF
}

run_modules() {
  local failed=() m
  ask_ssh_port "$@"
  preflight_disk "$@"
  for m in "$@"; do
    echo; echo "${c_blu}========== ${m} ==========${c_off}"
    if bash "$SELF" __module "$m"; then :; else failed+=("$m"); warn "模块 ${m} 失败"; fi
  done
  echo
  apt-get clean 2>/dev/null || true
  df -h / | sed 's/^/    /'
  print_todo
  if ((${#failed[@]})); then
    warn "以下模块失败：${failed[*]}"
    warn "排查后可重新运行：$(basename "$SELF") --only $(IFS=,; echo "${failed[*]}")"
    return 1
  fi
  ok "全部模块执行完成。"
}

main() {
  # 子进程入口：执行单个模块
  if [[ "${1:-}" == "__module" ]]; then
    declare -F "mod_$2" >/dev/null || die "未知模块：$2"
    if [[ "$2" == ssh || "$2" == ufw ]]; then [[ -n "$SSH_PORT" ]] || die "SSH_PORT 未设置"; fi
    if [[ -n "${NEED_MB[$2]:-}" ]]; then need_space "${NEED_MB[$2]}" "模块 $2"; fi
    "mod_$2"; exit 0
  fi

  [[ $EUID -eq 0 ]] || die "请以 root 执行"
  [[ -f "$SELF" && "$(basename "$SELF")" != bash ]] || die "请以文件方式运行，不支持 curl | bash"

  if ! grep -q 'VERSION_CODENAME=trixie' /etc/os-release; then
    warn "当前系统不是 Debian 13（trixie），部分模块可能不适用"
    confirm "仍然继续？" || exit 1
  fi

  local all=() m
  for m in "${MODULES[@]}"; do all+=("${m%%|*}"); done

  case "${1:-}" in
    --all) run_modules "${all[@]}" ;;
    --only)
      [[ -n "${2:-}" ]] || die "--only 需要模块名，例如：--only ssh,ufw"
      local sel=() want
      IFS=',' read -r -a want <<<"$2"
      for m in "${want[@]}"; do [[ " ${all[*]} " == *" $m "* ]] || die "未知模块：$m"; done
      for m in "${all[@]}"; do [[ ",$2," == *",$m,"* ]] && sel+=("$m"); done   # 保持标准顺序
      run_modules "${sel[@]}" ;;
    --list) list_modules ;;
    -h|--help) usage ;;
    "")
      command -v whiptail >/dev/null || { usage; die "未安装 whiptail，请使用 --all 或 --only"; }
      local picked; picked="$(select_menu)" || exit 0
      [[ -n "$picked" ]] || exit 0
      mapfile -t sel <<<"$picked"
      run_modules "${sel[@]}" ;;
    *) usage; exit 1 ;;
  esac
}

# 被 source 时不自动执行（便于测试）
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi