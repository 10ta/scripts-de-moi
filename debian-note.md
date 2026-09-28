# Debian 服务器笔记

> [!NOTE]
> 第 2 章是新 Debian 的初始化流程，按执行顺序排列，可配合 [`debian-init.sh`](./debian-init.sh) 使用。其余章节按主题查阅。
> 标注 🐟 的命令是 fish 语法（初始化时已安装 fish）。
> 文中的 IP、域名均为示例地址（`203.0.113.x`、`198.51.100.x`、`2001:db8::`、`example.com`），`<SSH_PORT>` 替换为你自己的 SSH 端口。

## 目录

1. [系统重装（DD）](#1-系统重装dd)
2. [新 Debian 初始化](#2-新-debian-初始化)
3. [网络调优](#3-网络调优)
4. [代理与转发服务](#4-代理与转发服务)
5. [网络测试与排障](#5-网络测试与排障)
6. [系统维护与升级](#6-系统维护与升级)
7. [Proxmox VE](#7-proxmox-ve)
8. [Windows 相关](#8-windows-相关)

---

## 1. 系统重装（DD）

### 1.1 重装前置组件

| 系统 | 命令 |
|---|---|
| Debian / Ubuntu | `apt-get install -y xz-utils openssl gawk file wget screen && screen -S os` |
| RedHat / CentOS | `yum install -y xz openssl gawk file glibc-common wget screen && screen -S os` |

安装出错时，刷新镜像缓存或更换镜像源：

| 系统 | 命令 |
|---|---|
| Debian / Ubuntu | `apt update -y && apt dist-upgrade -y` |
| RedHat / CentOS | `yum makecache && yum update -y` |

### 1.2 bin456789/reinstall（常用）

```bash
curl -O https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh || wget -O reinstall.sh $_
bash reinstall.sh debian 13 --ssh-port <SSH_PORT>
```

- 重装后登录：用户 `root`，密码 `123@@@`
- 重装后执行：`source /etc/network/interfaces.d/*`

### 1.3 MoeClub InstallNET（纯 IPv6 机器）

公共参数：`-d 12`（Debian 12）、`-v 64`、`-port "<SSH_PORT>"`、`-p "123@@@"`（root 密码）。

**🇫🇷 IPv6 机器**

```bash
bash <(wget --no-check-certificate -qO- 'https://raw.githubusercontent.com/MoeClub/Note/master/InstallNET.sh') \
  -a -d 12 -v 64 -p "123@@@" -port "<SSH_PORT>" \
  --ip-addr 2001:db8:1::1/64 \
  --ip-gate 2001:db8:1:: \
  --ip-mask 255.255.255.254 \
  --ip-dns 2001:67c:2b0::4
```

**AWS IPv6 机器**

```bash
bash <(wget --no-check-certificate -qO- 'https://raw.githubusercontent.com/MoeClub/Note/master/InstallNET.sh') \
  -a -d 12 -v 64 -p "123@@@" -port "<SSH_PORT>" \
  --ip-addr 2001:db8:2::10/64 \
  --ip-gate fe80::1 \
  --ip-dns 2001:4860:4860::8888
```

> 备用 DNS：`--ip-dns 172.26.0.2`

### 1.4 NewReinstall（阿里云 DD Windows）

阿里云 DD 安装 Windows 选 **27** 或 **31**。来源：https://git.beta.gs/

```bash
wget --no-check-certificate -O NewReinstall.sh https://git.io/newbetags && chmod a+x NewReinstall.sh && bash NewReinstall.sh
```

国内主机下载失败时（部分主机商已不能使用）：

```bash
wget --no-check-certificate -O NewReinstall.sh https://cdn.jsdelivr.net/gh/fcurrk/reinstall@master/NewReinstall.sh && chmod a+x NewReinstall.sh && bash NewReinstall.sh
```

### 1.5 netboot.xyz EFI 引导

重装前的最后一步：把 EFI 引导文件下载到 VPS 的 `/boot/efi/EFI/` 目录下。

| 架构 | 下载地址 |
|---|---|
| x86_64 | https://boot.netboot.xyz/ipxe/netboot.xyz.efi |
| arm64 | https://boot.netboot.xyz/ipxe/netboot.xyz-arm64.efi |

---

## 2. 新 Debian 初始化

> [!TIP]
> 标注 📜 的步骤可以用本仓库的 [`debian-init.sh`](./debian-init.sh) 一键完成（root 执行，适用于 Debian 13）：
>
> ```bash
> chmod +x debian-init.sh
> ./debian-init.sh                  # 勾选菜单
> ./debian-init.sh --all            # 按顺序执行全部
> ./debian-init.sh --only ssh,ufw   # 只执行指定模块
> ```
>
> SSH 端口在运行时输入，也可以用 `SSH_PORT=xxxx ./debian-init.sh` 传入。执行结束后会打印需要手动处理的清单。
> 下文命令中的 `<SSH_PORT>` 替换为你自己的端口。

### 2.1 GRUB：串口控制台与启动等待 📜

串口控制台让服务商网页上的 Serial Console（以及 PVE 的 xterm.js 终端）能看到启动信息并登录。SSH 或防火墙配置出错被锁在外面时，这是唯一的补救渠道。没有串口的机器上配置了也没有副作用。

编辑 `/etc/default/grub`，把串口参数**追加**到 `GRUB_CMDLINE_LINUX` 已有的参数后面（不要删掉原有参数，重装脚本可能在里面写了 `net.ifnames=0` 等），并设置：

```ini
GRUB_CMDLINE_LINUX="<原有参数> console=tty0 console=ttyS0,115200 earlyprintk=ttyS0,115200 consoleblank=0"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200"
GRUB_TIMEOUT=0
```

```bash
update-grub
```

### 2.2 基础软件 📜

```bash
apt update -y
apt install -y ca-certificates vim curl wget unzip ufw htop lsd bind9-host git \
               chrony fuse3 gpg clang llvm lld iperf3
```

> clang / llvm / lld 使用 Debian 13 默认版本（19）。iperf3 安装时询问是否作为守护进程运行，选否。

### 2.3 时间同步（chrony）📜

```bash
systemctl enable --now chrony
chronyc tracking      # 检查同步状态
```

### 2.4 SSH 密钥与登录 📜

**① 密钥文件**（文件名按密钥类型：`id_rsa` / `id_ed25519`）

| 文件 | 内容 | 权限 |
|---|---|---|
| `~/.ssh/` | 目录 | `700` |
| `~/.ssh/id_ed25519` | 私钥 | `600` |
| `~/.ssh/id_ed25519.pub` | 公钥 | `644` |
| `~/.ssh/authorized_keys` | 同一份公钥（追加，不覆盖已有公钥） | `600` |
| `~/.ssh/config` | 客户端配置 | `600` |

校验私钥与公钥是否配对：

```bash
ssh-keygen -y -f ~/.ssh/id_ed25519    # 输出应与 .pub 文件一致
```

**② GitHub 走 443 端口**（`~/.ssh/config`）

```ssh-config
Host github.com
  HostName ssh.github.com
  User git
  Port 443
  IdentityFile ~/.ssh/id_ed25519
```

**③ sshd：修改端口，仅允许密钥登录**

先注释掉 `/etc/ssh/sshd_config` 里的 `Port` 行，再新建 `/etc/ssh/sshd_config.d/00-init.conf`：

```
Port <SSH_PORT>
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
```

> [!NOTE]
> 文件名用 `00-` 开头：sshd 对同一参数只取**第一次**读到的值，要排在云镜像自带的 `50-cloud-init.conf`（通常写着 `PasswordAuthentication yes`）之前。

```bash
sshd -t && systemctl restart ssh
```

> [!WARNING]
> 重启 sshd 后**不要关闭当前窗口**，新开一个终端测试密钥登录：`ssh -p <SSH_PORT> root@<服务器IP>`，成功后再继续。

### 2.5 TCP Brutal 📜

项目：https://github.com/apernet/tcp-brutal

```bash
bash <(curl -fsSL https://tcp.hy2.sh/)
```

> [!WARNING]
> 每次更换内核后都要重新安装 Brutal（`./debian-init.sh --only brutal`）。

### 2.6 防火墙（UFW）📜

```bash
ufw allow <SSH_PORT>/tcp     # 先放行 SSH，再启用防火墙
ufw allow 80
ufw allow 443
ufw allow 27000:27050/tcp
ufw allow 27000:27050/udp
ufw allow 65000:65500/tcp
ufw allow 65000:65500/udp
ufw --force enable
```

按需添加（不在脚本中）：

```bash
ufw route allow in on enp0s1 out on utun    # 转发：内网 → TUN
ufw allow from 172.31.255.0/30              # 隧道对端
ufw allow from fcae:acba:11::1/126
```

#### 旁路由附加规则（小米 → Debian → iKuai）

仅适用于 PVE 内网的 sing-box 旁路由，不属于通用初始化。

**① 放行内网转发**

```bash
ufw route allow in on ens18 out on ens18 to 10.0.0.0/8
```

允许从 ens18 进、又从 ens18 出的内网流量通过。只放行私有地址，sing-box 停止时公网流量仍会被丢弃，不会绕过代理。

**② 回程对称**

加在 `/etc/ufw/before.rules` 开头（`*filter` 之前）：

```
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -o ens18 -s 10.17.0.0/16 -d 10.1.0.0/16 -j MASQUERADE
COMMIT
```

执行 `ufw reload` 生效。源地址被改成 10.17.0.5，回包也经过 Debian，避免不对称路由的隐患。代价是 iKuai 上看到的来源都是 Debian；不过小米本来就做了 NAT，iKuai 原本也分不出小米下面的具体设备，实际损失不大。

### 2.7 fish 📜

使用 openSUSE Build Service 的 fish 4 源（比 Debian 官方源新）：

```bash
echo 'deb http://download.opensuse.org/repositories/shells:/fish:/release:/4/Debian_13/ /' \
  > /etc/apt/sources.list.d/shells:fish:release:4.list
curl -fsSL https://download.opensuse.org/repositories/shells:fish:release:4/Debian_13/Release.key \
  | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/shells_fish_release_4.gpg
apt update && apt install -y fish
```

安装 fisher，并设为 root 默认 shell：

```fish
# 🐟
curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher
```

```bash
chsh -s /usr/bin/fish root
```

`~/.config/fish/config.fish`：

```fish
alias ls="lsd"
alias vi="nvim"
```

### 2.8 lsd 配置 📜

`~/.config/lsd/config.yaml`：

```yaml
icons:
  separator: " "
```

### 2.9 Neovim 📜

```bash
curl -LO https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz   # arm64：nvim-linux-arm64
rm -rf /opt/nvim-linux-x86_64
tar -C /opt -xzf nvim-linux-x86_64.tar.gz
ln -sf /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim
```

> 链接到 `/usr/local/bin`，所有 shell 和程序都能直接使用，无需修改 PATH。

### 2.10 Go 📜

官方二进制，安装到 `/usr/local/go`：

```bash
VER=$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1)    # 最新稳定版，如 go1.26.1
curl -LO "https://dl.google.com/go/${VER}.linux-amd64.tar.gz"
rm -rf /usr/local/go && tar -C /usr/local -xzf "${VER}.linux-amd64.tar.gz"
ln -sf /usr/local/go/bin/go /usr/local/bin/go
ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
```

`go install` 安装的程序在 `~/go/bin`，加入 PATH：

```fish
# 🐟 config.fish
fish_add_path -a $HOME/go/bin
```

> 升级：重新执行 `./debian-init.sh --only go`。

### 2.11 Node.js 与 pnpm 📜

Node.js 使用 NodeSource 的 LTS 源，通过 apt 管理，所有 shell 和 systemd 服务都能用：

```bash
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt install -y nodejs
```

pnpm（安装脚本会自动向 `config.fish` 写入 `PNPM_HOME` 配置）：

```bash
curl -fsSL https://get.pnpm.io/install.sh | env SHELL=/usr/bin/fish sh -
```

> LTS 大版本切换时（约每年一次），重新执行 `./debian-init.sh --only node`。

### 2.12 日志限额 📜

目标：整个系统的日志控制在 100MB 以内。

**journald**：`/etc/systemd/journald.conf.d/00-init.conf`（drop-in，系统更新不会覆盖）

```ini
[Journal]
SystemMaxUse=50M
SystemMaxFileSize=10M
RuntimeMaxUse=10M
```

```bash
systemctl restart systemd-journald
journalctl --vacuum-size=50M
```

**logrotate**：在 `/etc/logrotate.conf` 的 `include /etc/logrotate.d` **之前**加上（写在后面不会作用于各软件包的日志）：

```conf
compress
maxsize 10M
```

把 logrotate 改为每小时检查（`/etc/systemd/system/logrotate.timer.d/override.conf`）：

```ini
[Timer]
OnCalendar=
OnCalendar=hourly
```

```bash
systemctl daemon-reload && systemctl restart logrotate.timer
```

### 2.13 时区与时间 📜

```bash
timedatectl list-timezones               # 列出所有时区
timedatectl set-timezone Asia/Taipei     # 设置时区
```

手动设置时间（二选一）：

```bash
date -s "2026-07-05 14:30:00"
timedatectl set-time "2026-07-05 14:30:00"
```

### 2.14 卸载 exim4 📜

```bash
systemctl disable --now exim4
apt purge -y exim4 exim4-base exim4-config exim4-daemon-light
apt autoremove -y
```

### 2.15 DNS（手动）

sing-box 的 DNS 就绪后，`/etc/resolv.conf` 指向本机：

```conf
nameserver 127.0.0.1
```

### 2.16 内核与网络优化（手动）

```fish
# 🐟 一批网络优化 sysctl（写入 /etc/sysctl.conf）
bash (curl -Lso- https://git.io/kernel.sh | psub)

# 🐟 更换 BBRv3 内核（相比 BBRv1 公平性和收敛速度更好）
bash (curl -fsSL https://raw.githubusercontent.com/ZhangSir9901/BBRv3-Onekey/main/bbr_tune.sh | psub)

# 🐟 TCP 调优
bash (curl -fsSL https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh | psub)
```

sysctl 的计算方法和完整参数见 [第 3 章](#3-网络调优)。

### 2.17 网络配置（ifupdown，仅旧系统）

> [!NOTE]
> Debian 13 已不再使用 ifupdown 管理网络，这里只作旧系统参考。新系统的 networkd 配置见 [6.1](#61-更新系统的注意事项)。

`/etc/network/interfaces`：

```conf
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

allow-hotplug enp0s1
iface enp0s1 inet static
        address 10.1.0.154/16
        gateway 10.1.0.1
        # dns-* options are implemented by the resolvconf package, if installed
        dns-nameservers 8.8.8.8
        #dns-search debian
iface enp0s1 inet6 dhcp
```

-e ---

## 3. 网络调优

### 3.1 缓冲区计算（BDP）

参考：https://www.nodeseek.com/post-197087-1 ・ 计算器：https://tcp-cal.mereith.com/

**公式**：BDP（时延带宽积）= 瓶颈带宽（bit/s）× RTT（秒）

> **例**：本地 600 Mbps，VPS 1.5 Gbps，RTT 170 ms，瓶颈带宽取 600 Mbps
> 600 × 1000 × 1000 × 0.17 = 102,000,000 bit ÷ 8 = **12,750,000 byte**

> [!NOTE]
> ping 值本身就是往返时延（RTT）：ping 发出 ICMP 回显请求，并等待回显应答。

用理论值临时测试：

```bash
sysctl -w net.ipv4.tcp_wmem="4096 16384 <BDP值>"
sysctl -w net.ipv4.tcp_rmem="4096 87380 <BDP值>"
```

### 3.2 iperf3 测速

```bash
iperf3 -s -p 27048                         # 服务端
iperf3 -c <服务端IP> -R -t 30 -p 27048      # 客户端（-R：测下行）
```

### 3.3 当前 sysctl 配置

> [!IMPORTANT]
> 最上面的 `tcp_wmem` / `tcp_rmem` 按 BDP 计算结果调整，是最关键的两行。

```conf
# ===== TCP 缓冲区（按 BDP 调整）=====
net.ipv4.tcp_wmem = 131072 335544 28500000
net.ipv4.tcp_rmem = 131072 335544 28500000

# ===== 内核 =====
kernel.pid_max = 65535
kernel.panic = 1
kernel.sysrq = 1
kernel.core_pattern = core_%e
kernel.printk = 3 4 1 3
kernel.numa_balancing = 0
kernel.sched_autogroup_enabled = 0
kernel.msgmax = 65536
kernel.msgmnb = 163840

# ===== 拥塞控制与队列 =====
net.ipv4.route.flush = 1
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_ecn = 2

# ===== 文件与内存 =====
fs.file-max = 1000000
fs.inotify.max_user_instances = 8192
vm.swappiness = 5
vm.dirty_ratio = 5
vm.dirty_background_ratio = 2
vm.panic_on_oom = 1
vm.overcommit_memory = 1
vm.min_free_kbytes = 131072

# ===== 网络核心 =====
net.core.netdev_max_backlog = 52877
net.core.rmem_max = 259522560
net.core.wmem_max = 423540817
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.somaxconn = 13220
net.core.optmem_max = 262144

# ===== TCP 行为 =====
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_tw_buckets = 32768
net.ipv4.tcp_sack = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 524288
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 3
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_no_metrics_save = 1

# ===== 连接队列与重试 =====
net.ipv4.tcp_max_syn_backlog = 105754
net.ipv4.tcp_max_orphans = 32768
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_stdurg = 0
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_syncookies = 1

# ===== 端口、路由与邻居表 =====
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.route.gc_timeout = 100
net.ipv4.neigh.default.gc_stale_time = 120
net.ipv4.neigh.default.gc_thresh3 = 4096
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh1 = 512

# ===== 安全 =====
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.default.arp_ignore = 1
```

> [!WARNING]
> `rp_filter = 1`（严格模式）不适合做旁路由的机器，会丢弃非对称路径的包。旁路由上应改为 `2` 或 `0`。

### 3.4 历史 sysctl 配置

<details>
<summary>旧版 1（fq_pie）</summary>

```conf
net.ipv4.tcp_notsent_lowat = 4294967295
net.ipv4.tcp_slow_start_after_idle = 0

net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mem = 131072 196608 204800
net.ipv4.udp_mem = 131072 196608 204800
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 131072 16777216
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

kernel.msgmax = 65536
kernel.msgmnb = 163840

net.ipv4.route.flush = 1

net.core.default_qdisc = fq_pie
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_ecn = 2

fs.file-max = 1000000
fs.inotify.max_user_instances = 8192

net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 6000
net.ipv4.route.gc_timeout = 100

net.ipv4.tcp_syn_retries = 1
net.ipv4.tcp_synack_retries = 1
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_max_orphans = 32768
```

</details>

<details>
<summary>旧版 2（cake）</summary>

```conf
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_notsent_lowat = 4294967295
net.ipv6.tcp_congestion_control = bbr
net.ipv6.tcp_notsent_lowat = 4294967295

#net.ipv6.conf.all.disable_ipv6 = 1
#net.ipv6.conf.default.disable_ipv6 = 1
#net.ipv6.conf.lo.disable_ipv6 = 1
#net.ipv6.conf.eth0.disable_ipv6 = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.ip_local_port_range = 32768 65000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000

net.core.rmem_max = 1677216
net.core.wmem_max = 1677216
```

</details>

<details>
<summary>旧版 3（fq_pie + tcp_retries2）</summary>

```conf
net.ipv4.tcp_notsent_lowat = 4294967295
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_slow_start_after_idle = 0

net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mem = 131072 196608 204800
net.ipv4.udp_mem = 131072 196608 204800
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 131072 16777216
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

kernel.msgmax = 65536
kernel.msgmnb = 163840

net.ipv4.route.flush = 1

net.core.default_qdisc = fq_pie
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_ecn = 2

fs.file-max = 1000000
fs.inotify.max_user_instances = 8192

net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 6000
net.ipv4.route.gc_timeout = 100

net.ipv4.tcp_syn_retries = 1
net.ipv4.tcp_synack_retries = 1
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_max_orphans = 32768
```

</details>

### 3.5 ~~vps-tcp-tune~~（已弃用）

项目：https://github.com/Eric86777/vps-tcp-tune ，曾用功能「安装/更新 XanMod 内核 + BBR v3」。

```bash
wget -O net-tcp-tune.sh "https://raw.githubusercontent.com/Eric86777/vps-tcp-tune/main/net-tcp-tune.sh?$(date +%s)"
chmod +x net-tcp-tune.sh
./net-tcp-tune.sh
```

---

## 4. 代理与转发服务

### 4.1 sing-box

下载：https://github.com/SagerNet/sing-box/releases

安装 / 更新（📜 `--only singbox`）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/10ta/scripts-de-moi/main/upsing.sh)
```

配置文件放在 `/etc/sing-box/config.json`，然后 `systemctl enable --now sing-box`。

```bash
# 重载并重启，同时跟踪日志
systemctl daemon-reload && systemctl restart sing-box && journalctl --output cat -fu sing-box

# 仅跟踪日志
journalctl --output cat -fu sing-box

# 只看新日志（不显示历史）
journalctl -n 0 --no-pager -o cat -fu sing-box
```

### 4.2 Xray

安装脚本：https://github.com/XTLS/Xray-install

```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --beta
```

新特性教程（Vision Seed、DNS 优化）：https://idcflare.com/t/topic/43912

### 4.3 realm 端口转发

下载：https://github.com/zhboner/realm/releases/

`/etc/systemd/system/realm.service`：

```ini
[Unit]
Description=realm
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
DynamicUser=true
Restart=on-failure
RestartSec=5s
ExecStart=/usr/bin/realm -c /etc/realm/config.toml

[Install]
WantedBy=multi-user.target
```

`/etc/realm/config.toml`（先 `mkdir /etc/realm`）：

```toml
[log]
level = "debug"
output = "stdout"

[network]
no_tcp = false
use_udp = false

[[endpoints]]
listen = "::0:27044"
remote = "198.51.100.20:27015"
```

```bash
systemctl enable realm && systemctl restart realm && journalctl -fu realm --output cat
```

### 4.4 Caddy

使用 [lxhao61/integrated-examples](https://github.com/lxhao61/integrated-examples/releases) 构建的版本（📜 `--only caddy`）：

```bash
curl -LO https://github.com/lxhao61/integrated-examples/releases/latest/download/caddy-linux-amd64.tar.gz
tar -xzf caddy-linux-amd64.tar.gz && sha256sum -c sha256     # 校验
install -m 755 caddy /usr/bin/caddy
mkdir -p /etc/caddy && touch /etc/caddy/Caddyfile
```

`/etc/systemd/system/caddy.service`：

```ini
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
```

```bash
systemctl daemon-reload && systemctl enable --now caddy
```

证书目录：`/root/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/`

### 4.5 自签证书

```bash
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -sha256 -days 3650 -nodes \
  -subj "/CN=example.com"
```

### 4.6 VPNGate 代理

项目：https://github.com/baoweise-bot/aimili-vpngate

---

## 5. 网络测试与排障

### 5.1 TLS 1.3 支持

```bash
echo | openssl s_client -connect gateway.icloud.com:443 -tls1_3 2>/dev/null | grep "Protocol"
# 应输出：Protocol  : TLSv1.3
```

### 5.2 连接延迟

```bash
# 仅连接时间（越低越好）
curl -so /dev/null -w "%{time_connect}\n" https://gateway.icloud.com

# 分阶段耗时
curl -o /dev/null -s -w "\n连接时间: %{time_connect}s\nTLS握手: %{time_appconnect}s\n首字节: %{time_starttransfer}s\n总时间: %{time_total}s\n" https://example.com
```

### 5.3 路由追踪（NextTrace）

```bash
curl nxtrace.org/nt | bash    # 安装
nexttrace <目标>
```

### 5.4 VPS 综合检测

```fish
# 🐟
bash (curl -sL Check.Place | psub)
```

---

## 6. 系统维护与升级

### 6.1 更新系统的注意事项

> [!WARNING]
> - 更新过内核后，要重新安装 [TCP Brutal](#25-tcp-brutal-)。
> - 系统更新可能会重置 `sysctl.conf` 和 networkd 配置，更新后记得检查。

networkd 配置示例 `/etc/systemd/network/10-ens18.network`：

```ini
[Match]
Name=ens18

[Network]
Address=203.0.113.10/24
Gateway=203.0.113.1
Address=2001:db8:3::10/64
DNS=127.0.0.1
IPv6AcceptRA=no

[Route]
Gateway=2001:db8:3::1
GatewayOnLink=yes
```

### 6.2 内核管理

```bash
uname -r              # 当前运行的内核
ls /lib/modules/      # 已安装的内核

apt purge linux-image-6.1.0-35-cloud-amd64    # 删除不需要的内核
```

安装指定版本（Debian 11 backports 的 6.1 内核）：

```bash
apt install -y linux-image-6.1.0-0.deb11.21-amd64
apt install -y linux-headers-6.1.0-0.deb11.21-amd64
```

内核下载：
- https://packages.debian.org/bullseye-backports/amd64/linux-image-6.1.0-0.deb11.11-amd64/download
- http://ftp.debian.org/debian/pool/main/l/linux-signed-arm64/

### 6.3 Debian 11（bullseye）→ 12（bookworm）

```bash
apt update -y && apt upgrade -y
cat /etc/os-release                                  # 确认当前版本

sed -i 's|bullseye|bookworm|g' /etc/apt/sources.list
cat /etc/apt/sources.list                            # 确认替换结果

apt update -y && apt upgrade -y                      # 提示 restart service 时选 yes
```

### 6.4 Debian 12（bookworm）→ 13（trixie）

参考：https://u.sb/debian-upgrade-13/

**① 先更新当前系统**

```bash
apt update
apt upgrade -y
apt dist-upgrade -y
apt autoclean
apt autoremove -y
```

**② 改软件源** `/etc/apt/sources.list.d/debian.sources`：

```
Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie trixie-updates trixie-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
```

> 国内服务器可把 `deb.debian.org` 和 `security.debian.org` 替换为 `mirrors.tuna.tsinghua.edu.cn`。

**③ 执行升级**

```bash
apt update
apt upgrade -y
apt dist-upgrade -y
```

升级过程中的提示：
- 询问是否自动重启服务：选 **Yes**。
- 询问是否更新配置文件：按自己的情况选择，直接回车表示保留旧配置，一般出现在 OpenSSH 等软件上。
- `apt-listchanges: News` 界面：按 `q` 退出。

**④ 清理**

```bash
apt autoclean
apt autoremove -y
```

### 6.5 更新 Intel microcode

```bash
# 第一步：安装发行版的 microcode
apt update
apt install intel-microcode
reboot
# 重启后版本应为 0x24000023

# 第二步：用 Intel 官方最新文件
wget https://github.com/intel/Intel-Linux-Processor-Microcode-Data-Files/archive/main.zip
unzip main.zip -d MCU
cp -r /root/MCU/Intel-Linux-Processor-Microcode-Data-Files-main/intel-ucode/. /lib/firmware/intel-ucode/
update-initramfs -u
reboot
# 重启后应更新至 0x24000024
```

检查版本（二选一）：

```bash
dmesg -T | grep microcode
grep 'stepping\|model\|microcode' /proc/cpuinfo
```

---

## 7. Proxmox VE

### 7.1 虚拟机关闭 Secure Boot

1. 启动虚拟机，出现 Proxmox 画面时按 **ESC** 进入 BIOS。
2. 依次进入 **Device Manager** → **Secure Boot Configuration**。
3. 取消勾选 **Attempt Secure Boot**。

### 7.2 固定 6.5 内核

```bash
apt install proxmox-kernel-6.5.13-5-pve
pve-efiboot-tool kernel pin 6.5.13-5-pve
reboot
```

### 7.3 网卡断流（Detected Hardware Unit Hang）

**现象**：宿主机网络全部断开，PVE 的 Web 管理界面也无法登录，终端不断打印 `Detected Hardware Unit Hang`。

**原因**：与 TCP checksum offload 有关。

**解决**：用 ethtool 关闭 checksum offload：

```bash
ethtool -K enp0s25 tx off rx off
```

重启后永久生效：写入 `/etc/network/if-up.d/ethtool`，并加上执行权限（`chmod +x`）：

```sh
#!/bin/sh
ethtool -K enp0s25 tx off rx off
```

> 另一种办法：把网卡虚拟化方式从 VirtIO 改为 E1000，副作用是 CPU 占用上升。

参考：
- https://jhartman.pl/2018/08/06/proxmox-enp0s31f6-detected-hardware-unit-hang/
- https://ovear.info/post/356
- https://serverfault.com/questions/616485/e1000e-reset-adapter-unexpectedly-detected-hardware-unit-hang
- https://superuser.com/questions/1270723/how-to-fix-eth0-detected-hardware-unit-hang-in-debian-9

### 7.4 常见故障修复

| 故障 | 解决 |
|---|---|
| 用了「去除订阅提示」后每隔两天死机 | `apt install --reinstall proxmox-widget-toolkit` |
| 管理界面白屏 | `apt install --reinstall pve-manager` |

---

## 8. Windows 相关

### 8.1 为指定 IP 绑定网关（持久静态路由）

```bat
:: 添加（-p 表示重启后保留）
route -p add 198.51.100.30 mask 255.255.255.255 192.168.3.1

:: 删除
route -p delete 198.51.100.30
```