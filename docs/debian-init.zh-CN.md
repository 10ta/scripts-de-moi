# debian-init

[English](debian-init.md) · **简体中文**

新装 Debian 13 服务器的模块化、幂等初始化：SSH 密钥、防火墙、fish、Go、Node.js、Caddy、sing-box 等。

```text
$ ./debian-init.sh --list
   1. grub       串口控制台 + GRUB 等待时间 0
   2. packages   基础软件（含 iperf3，clang/llvm/lld 用系统默认版本）
   3. chrony     时间同步
   4. ssh        SSH 密钥、GitHub 走 443、sshd 端口、关闭密码登录
…
  15. caddy      Caddy（lxhao61 构建版）
  16. singbox    sing-box（upsing.sh）
```
*`--list` 的输出（节选）。*

## 目录

- [为什么是 debian-init？](#-为什么是-debian-init)
- [亮点](#-亮点)
- [快速开始](#-快速开始)
- [使用](#-使用)
- [配置](#-配置)
- [局限与路线](#-局限与路线)
- [许可](#-许可)

## 💡 为什么是 debian-init？

每装一台新 VPS 都是同样的二十来步，漏掉一步（密码登录没关、日志撑满磁盘）迟早出问题。debian-init 把 [`debian-note.md`](../debian-note.md) 第 2 章里标 📜 的步骤做成可勾选的模块，按固定顺序执行，可以放心重复运行。

- ✅ 适用：你以 root 管理的、新装的 Debian 13（trixie）VPS。
- ❌ 不适用：其他发行版，或者已经由配置管理工具接管的机器。

## ✨ 亮点

- **16 个模块**：菜单勾选或参数指定；无论选了哪些，都按固定顺序执行。
- **幂等**：改文件前备份为 `<文件>.bak.<时间>`；追加的配置用标记块包住，重复运行时整块替换，不会重复追加。
- **互不影响**：每个模块在独立子进程中运行；结束时列出失败的模块和精确的重跑命令。
- **先下载再执行**：远程脚本先保存到本地，网络中断不会执行半截脚本。
- **结束时打印待办清单**：还需要手动处理的事（sing-box 配置、DNS、网络调优）。

## 🚀 快速开始

以 root、以文件方式运行（不支持 `curl | bash`），因为每个模块要调用脚本自身。

```bash
curl -fsSL https://raw.githubusercontent.com/10ta/scripts-de-moi/main/debian-init.sh -o debian-init.sh
chmod +x debian-init.sh
./debian-init.sh
```

会打开一个勾选菜单（需要 `whiptail`；没有的话用 `--all` 或 `--only`）。跑完后打印哪些模块成功、哪些失败（附重跑命令），以及手动待办清单。

## 🧭 使用

### 全部执行或只执行一部分

```bash
./debian-init.sh --all
./debian-init.sh --only ssh,ufw
```

### 提前传入 SSH 端口

```bash
SSH_PORT=2222 ./debian-init.sh --all
```

不传的话，`ssh` 和 `ufw` 模块会提示输入。

| 模块 | 做什么 |
|---|---|
| `grub` | 串口控制台 + GRUB 等待时间 0（追加到原有内核参数后，不覆盖） |
| `packages` | 基础软件，含 iperf3；clang / llvm / lld 用系统默认版本 |
| `chrony` | 时间同步 |
| `ssh` | 密钥文件、GitHub 走 443、sshd 端口、只允许密钥登录 |
| `brutal` | TCP Brutal |
| `ufw` | 先放行 SSH，再加规则，最后启用 |
| `fish` | fish 4（openSUSE Build Service 源）+ fisher + `config.fish`，设为 root 默认 shell |
| `lsd` | lsd 配置 |
| `nvim` | Neovim，从 GitHub Release 装到 `/opt` |
| `go` | Go 官方二进制，默认最新稳定版 |
| `node` | Node.js（NodeSource，固定主版本）+ pm2 + pnpm；重复运行即更新 |
| `logs` | journald 与 logrotate 限额（日志总量约 100 MB 以内） |
| `timezone` | 设置时区 |
| `exim4` | 已安装时卸载 exim4 |
| `caddy` | Caddy（[lxhao61/integrated-examples](https://github.com/lxhao61/integrated-examples) 构建版），校验 sha256 |
| `singbox` | 通过 [upsing](upsing.zh-CN.md) 安装 sing-box |

## 🔧 配置

`debian-init.sh` 顶部的常量：

| 名称 | 必填 | 默认值 | 说明 |
|---|---|---|---|
| `SSH_PORT` | ❌ | 空（运行时提示） | sshd 端口；也可以用环境变量传入 |
| `TIMEZONE` | ❌ | `Asia/Taipei` | 时区 |
| `GO_VERSION` | ❌ | 空（最新） | 例如 `go1.26.1` |
| `NODE_MAJOR` | ❌ | `24` | Node.js 主版本；改了之后重跑 `--only node` |
| `UFW_RULES` | ❌ | 80、443 和两个端口段 | 额外放行的端口（SSH 自动放行） |
| `JOURNAL_SYSTEM_MAX` 等 | ❌ | `50M` / `10M` | journald 与 logrotate 的大小限制 |

## 🚧 局限与路线

> [!WARNING]
> `ssh` 模块会关闭密码登录。重启 sshd 后脚本会暂停：**保留当前会话**，新开一个终端测试密钥登录。确认成功后才继续；测试失败时自动恢复密码登录。

- 每台服务器放同一把私钥的话，一台被入侵会连带其他服务器和 GitHub 账号。
- 更换内核后要重装 Brutal：`./debian-init.sh --only brutal`。
- `grub` 和默认 shell 需要重启后才生效。

## 📄 许可

还没有许可证文件，默认保留所有权利。见[仓库 README](../README.zh-CN.md#-许可)。
