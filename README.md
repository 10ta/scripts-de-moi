# scripts-de-moi

自用的服务器脚本和笔记合集。脚本都是单文件、可重复运行，配置写在脚本顶部。

> 这些脚本按我自己的环境编写和测试（Debian + systemd）。用在别处之前，请先读一遍代码。

| 文件 | 说明 |
|---|---|
| [`debian-init.sh`](debian-init.sh) | 新 Debian 13 初始化：SSH 密钥、防火墙、fish、Go、Node.js、Caddy 等，模块可勾选 |
| [`debian-note.md`](debian-note.md) | Debian 服务器笔记：重装、初始化、网络调优、代理服务、维护升级、PVE |
| [`brutal-cn.sh`](brutal-cn.sh) | 用中国大陆 IP 段自动维护 TCP Brutal v2 规则，定时更新并自愈 |
| [`upsing.sh`](upsing.sh) | 从 GitHub Release 下载并安装 sing-box 的 `.deb` 包 |

---

## debian-init

新装 Debian 13 后的初始化脚本，对应 [`debian-note.md`](debian-note.md) 第 2 章中标注 📜 的步骤。

### 功能

- **模块化**：16 个模块，可以在菜单里勾选，也可以用参数指定。无论选了哪些，都按固定顺序执行。
- **幂等**：可以反复运行。修改文件前先备份为 `<文件>.bak.<时间>`；追加的配置用标记块包住，重复运行时整块替换，不会重复追加。
- **互不影响**：每个模块在独立的子进程中运行，一个失败不影响其他模块。结束时列出失败的模块，并给出重跑命令。
- **远程脚本先下载再执行**：避免网络中断时执行半截脚本。
- **结束时打印待办清单**：列出需要手动处理的事项（sing-box 配置、DNS、网络调优等）。

### 用法

```bash
chmod +x debian-init.sh
./debian-init.sh                    # 勾选菜单
./debian-init.sh --all              # 按顺序执行全部
./debian-init.sh --only ssh,ufw     # 只执行指定模块
./debian-init.sh --list             # 列出模块
```

需要 root 权限，并且必须以文件方式运行（不支持 `curl | bash`），因为每个模块要调用脚本自身。

SSH 端口会在运行时提示输入，也可以提前传入：

```bash
SSH_PORT=xxxx ./debian-init.sh --all
```

### 模块

| 模块 | 内容 |
|---|---|
| `grub` | 串口控制台 + GRUB 等待时间设为 0（串口参数追加到原有参数后，不覆盖） |
| `packages` | 基础软件，含 iperf3；clang / llvm / lld 使用系统默认版本 |
| `chrony` | 时间同步 |
| `ssh` | 粘贴密钥 → 写入密钥文件并设置权限 → GitHub 走 443 端口 → 修改 sshd 端口、只允许密钥登录 |
| `brutal` | TCP Brutal |
| `ufw` | 先放行 SSH 端口，再添加规则，最后启用防火墙 |
| `fish` | fish 4（openSUSE Build Service 源）+ fisher + `config.fish`，设为 root 默认 shell |
| `lsd` | lsd 配置 |
| `nvim` | Neovim，从 GitHub Release 安装到 `/opt` |
| `go` | Go 官方二进制，默认安装最新稳定版 |
| `node` | Node.js LTS（NodeSource 源）+ pnpm |
| `logs` | journald 与 logrotate 限额，日志总量控制在 100MB 以内 |
| `timezone` | 设置时区 |
| `exim4` | 已安装时卸载 exim4 |
| `caddy` | Caddy（[lxhao61/integrated-examples](https://github.com/lxhao61/integrated-examples) 构建版），校验 sha256 后安装并启动 |
| `singbox` | 调用 [`upsing.sh`](upsing.sh) 安装 sing-box |

### 配置

脚本顶部的配置区：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `SSH_PORT` | 空 | 留空时运行到 `ssh` 或 `ufw` 模块会提示输入 |
| `TIMEZONE` | `Asia/Taipei` | 时区 |
| `GO_VERSION` | 空 | 留空安装最新稳定版；也可以指定，如 `go1.26.1` |
| `UFW_RULES` | 80、443 及两个端口段 | 需要放行的端口，SSH 端口会自动放行 |
| `JOURNAL_SYSTEM_MAX` 等 | `50M` / `10M` | journald 与 logrotate 的大小限制 |

### 注意事项

- **`ssh` 模块会关闭密码登录。** 重启 sshd 后脚本会暂停，请**保留当前窗口**，新开一个终端测试密钥登录。确认成功后才会继续；测试失败时自动恢复密码登录。
- **每台服务器放同一把私钥**时，任何一台被入侵都会连带其他服务器和 GitHub 账号。请自行权衡。
- **更换内核后要重新安装 Brutal**：`./debian-init.sh --only brutal`。
- `grub`、默认 shell 等设置需要重启后才生效。

---

## upsing

下载并安装 sing-box 的官方 `.deb` 包，首次安装和更新都可以用。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/10ta/scripts-de-moi/main/upsing.sh)
```

- 自动识别架构：`amd64`、`arm64`、`armv7`。
- 取 GitHub Release 列表中的**第一个版本**安装。这个版本可能是 alpha 或 beta 预发布版。
- 只安装程序，不修改配置文件。配置放在 `/etc/sing-box/config.json`，服务由你自己启用和启动。
- 执行日志写在 `/tmp/upsing.log`。

---

## brutal-cn

[TCP Brutal v2](https://github.com/HyNetworks/tcp-brutal) 可以按目的地址设置发送速率：给某个网段加一条规则后，服务器发往这个网段的所有 TCP 连接都会使用 Brutal，不需要应用程序支持。

brutal-cn 会自动为中国大陆的 IP 段维护这些规则。这样客户端的 IP 怎么变（比如手机切换网络）都已经被覆盖，第一条连接就能生效，不用等待或断线重连。

### 功能

- **自动获取大陆 IP 段**：从 APNIC 官方分配数据生成大陆 IPv4/IPv6 列表，按设定的间隔检查更新。数据没变时服务器返回 304，不会重复下载；下载失败或数据异常时，继续使用本地缓存。
- **规则数量可控**：把几千条前缀贪心合并到设定的上限以内，每一步都选额外覆盖非大陆地址最少的合并方式。合并出的网段不会覆盖私网、保留地址、本机地址、网关，以及你排除的网段。
- **多种 IPv6 数据源**：内置运营商大段（约 30 条）、APNIC 完整数据、完全自定义，三选一。
- **增量同步**：每次只增删有变化的规则，先加新规则再删旧规则，中间不会出现没有规则的空窗。
- **自愈**：以下情况会在下一轮同步时自动修复：
  - 重启后规则丢失
  - 路由被清掉（比如重启了网络服务）
  - 默认网关变化
  - 改了带宽设置
- **只管理自己创建的规则**：不会删除你手动添加的 brutal 规则；发现这类规则时会在日志里提醒。
- **幂等**：`install` 可以反复运行，既用于首次安装，也用于更新和修复。

### 工作原理

```
APNIC 分配数据 ──▶ 大陆 IPv4 / IPv6 前缀 ──▶ 合并到规则上限 ──▶ 与内核中现有规则和路由对比 ──▶ brutalctl add / del
     ▲                                                                                     │
     └─────────────────────────── systemd timer（开机 20 秒后，之后每 10 分钟）──────────────┘
```

每次同步都会检查规则和路由是否完整。计算增删计划只需不到 1 秒；只有需要增删规则时才会调用 brutalctl。

### 环境要求

- Debian 或其他使用 systemd 的发行版（依赖用 `apt` 安装）
- Linux 5.10 及以上（TCP Brutal 的要求）
- root 权限

缺少的依赖（`curl`、`iproute2`、`python3`）和 TCP Brutal 本身，会在安装时自动安装。TCP Brutal 通过官方脚本 `https://tcp.hy2.sh/` 安装。

### 安装

定时器会直接调用脚本文件本身，所以脚本需要放在固定位置，不能放在 `/tmp` 下。推荐直接 clone 仓库：

```bash
git clone https://github.com/10ta/scripts-de-moi.git /opt/scripts-de-moi
bash /opt/scripts-de-moi/brutal-cn.sh install
```

也可以只下载这一个脚本：

```bash
curl -fsSL -o /opt/brutal-cn.sh \
  https://raw.githubusercontent.com/10ta/scripts-de-moi/main/brutal-cn.sh
bash /opt/brutal-cn.sh install
```

首次同步大约需要处理一千多条规则，会在前台显示进度。

如果之前手动加过 brutal 规则（比如一份宽泛的大陆列表），可以在安装时一并清掉：

```bash
bash brutal-cn.sh install --flush-existing
```

> ⚠️ `--flush-existing` 会清空本机**所有** brutal 规则，包括不是本脚本创建的。

### 命令

| 命令 | 说明 |
|---|---|
| `bash brutal-cn.sh install [--flush-existing]` | 安装、更新或修复（幂等） |
| `bash brutal-cn.sh update [--force-download]` | 立即同步一次；加 `--force-download` 会强制重新下载 APNIC 数据 |
| `bash brutal-cn.sh status` | 查看配置、定时器、规则数量、当前有连接的规则和最近日志 |
| `bash brutal-cn.sh uninstall` | 删除本脚本创建的规则、定时器和缓存。脚本文件、brutalctl、内核模块，以及其他规则都会保留 |

同步日志：

```bash
journalctl -u brutal-cn-update.service -f
```

### 配置

所有配置都在脚本顶部。改完后下一轮同步会自动生效，只有 `REPAIR_INTERVAL` 需要重新运行 `install`。

| 常量 | 默认值 | 说明 |
|---|---|---|
| `MAX_MBPS` | `55` | 最大带宽（Mbps）。填客户端实际能接收的下行带宽，设得过高只会增加丢包 |
| `ENABLE_IPV6` | `auto` | `auto` 表示本机有 IPv6 默认路由时才启用；也可设为 `yes` 或 `no` |
| `IPV6_SOURCE` | `bigblock` | IPv6 数据源，见下文 |
| `UPDATE_INTERVAL_HOURS` | `24` | 多久检查一次 APNIC 数据 |
| `IPV6_MANUAL` | 空 | `IPV6_SOURCE=manual` 时使用的 IPv6 列表 |
| `EXTRA_PREFIXES` | 空 | 在任何模式下都额外添加的前缀，IPv4/IPv6 均可，比如出门在港澳台时所用网络的网段 |
| `EXCLUDE_PREFIXES` | 空 | 在任何模式下都排除的前缀，合并时也不会被覆盖进去 |
| `MAX_RULES_V4` | `1000` | IPv4 规则上限 |
| `MAX_RULES_V6` | `300` | IPv6 规则上限，只在 `apnic` 模式下起作用 |
| `REPAIR_INTERVAL` | `10min` | 自愈检查的间隔 |
| `APNIC_URLS` | APNIC 官方地址 | 数据源地址，可以写多个，用空格分隔 |
| `MIN_V4_PREFIXES` | `1000` | 解析出的 IPv4 前缀少于这个数时，视为数据异常 |

数组的写法是每行一个前缀，可以加 `#` 注释：

```bash
EXTRA_PREFIXES=(
    198.51.100.0/24    # 某个常用网络
)
```

> 如果你 fork 了本仓库并直接修改配置，`git pull` 时可能会和上游的改动冲突。自用仓库直接提交配置就好。

#### IPv6 数据源

| 值 | 规则数 | 说明 |
|---|---|---|
| `bigblock` | 约 30 | 内置的运营商大段（`IPV6_BIGBLOCK`），覆盖三大运营商、广电、教育网和主要云厂商。推荐 |
| `apnic` | ≤ `MAX_RULES_V6` | APNIC 的完整大陆 IPv6 数据，合并到规则上限以内 |
| `manual` | 自定义 | 只使用 `IPV6_MANUAL` |

`bigblock` 和 `manual` 模式下，每次同步都会拿列表和 APNIC 数据核对，并在日志里报告三件事：

- 覆盖了 APNIC 大陆 IPv6 地址的百分之多少
- 没收录的最大几个网段
- 列表里有哪些网段不属于大陆分配

列表过时或写错时，可以据此修正。

#### IPv4 规则上限怎么选

IPv4 大陆地址很零散，和其他国家的网段交错在一起，所以合并得越粗，覆盖到的非大陆地址就越多。以下数据用公开的大陆 IPv4 列表测得（合并前约 7,500 条），实际数值以同步日志为准：

| `MAX_RULES_V4` | 覆盖范围中非大陆地址的比例 |
|---|---|
| 300 | ≈ 47% |
| 500 | ≈ 31% |
| **1000** | **≈ 13%** |
| 2000 | ≈ 4% |
| 3000 | ≈ 1.6% |

### 注意事项

- **规则影响的不只是代理流量。** 服务器发往规则覆盖地址的**所有** TCP 流量都会走 Brutal，并且是锁定的，应用程序改不了。这包括 SSH、Web 服务，以及往大陆机房的上传或备份。需要避开的网段写进 `EXCLUDE_PREFIXES`。
- **合并会覆盖少量非大陆地址。** 服务器发往这些地址的流量同样会走 Brutal。对代理访问网站的影响很小，因为服务器发出的主要是请求，数据量不大。但往这些地址的大量上传会被限制在 `MAX_MBPS`。
- **同一条规则内的连接共享带宽。** 一个网段里的所有连接加起来共用 `MAX_MBPS`，适合一个人自用。多人共用时，落在同一网段的用户会互相分带宽。
- **Brutal 只对新建连接生效。** 规则加上之后，已经存在的连接不受影响，直到它们断开重连。
- **脚本会添加路由。** brutalctl 为每条规则在主路由表里添加一条 `proto 233` 路由，可以用 `ip route show proto 233` 查看。使用策略路由或 WARP 的机器，请先确认这些路由不会和现有配置冲突。
- **不要把 brutal 设为系统默认的拥塞控制算法。** 没有匹配规则的连接会被限制在 1 Mbps。

### 生成的文件

| 路径 | 内容 |
|---|---|
| `/etc/systemd/system/brutal-cn-update.{service,timer}` | 定时同步 |
| `/var/lib/brutal-cn/` | APNIC 数据缓存、生成的大陆列表、本脚本管理的规则记录 |

`uninstall` 会删除以上所有文件。

### 数据来源与致谢

- [HyNetworks/tcp-brutal](https://github.com/HyNetworks/tcp-brutal)：TCP Brutal 内核模块与 brutalctl
- [APNIC delegated statistics](https://ftp.apnic.net/stats/apnic/)：大陆 IPv4/IPv6 分配数据