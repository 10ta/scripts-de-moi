# debian-init

**English** · [简体中文](debian-init.zh-CN.md)

Modular, idempotent first-boot setup for a fresh Debian 13 server: SSH keys, firewall, fish, Go, Node.js, Caddy, sing-box and more.

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
*`--list` output (abridged). The script's text is in Chinese.*

## Contents

- [Why debian-init?](#-why-debian-init)
- [Highlights](#-highlights)
- [Quick Start](#-quick-start)
- [Usage](#-usage)
- [Configuration](#-configuration)
- [Limitations & Roadmap](#-limitations--roadmap)
- [License](#-license)

## 💡 Why debian-init?

Setting up a new VPS is the same twenty steps every time, and missing one (password login left on, logs filling the disk) bites later. debian-init turns the 📜-marked steps of [`debian-note.md`](../debian-note.md) chapter 2 into modules you can tick, run in a fixed order, and re-run safely.

- ✅ Good fit: a fresh Debian 13 (trixie) VPS you administer as root.
- ❌ Not a fit: other distributions, or machines already shaped by config management.

## ✨ Highlights

- **16 modules** — pick in a menu or by flag; they always run in a fixed order.
- **Idempotent** — files are backed up as `<file>.bak.<time>` before changes; appended config sits in marked blocks that are replaced, not duplicated.
- **Isolated** — each module runs in its own subprocess; failures are listed at the end with the exact re-run command.
- **Download, then run** — remote scripts are saved first, so a dropped connection never runs half a script.
- **To-do list at the end** — what still needs a human (sing-box config, DNS, network tuning).

## 🚀 Quick Start

Run as root, from a file (not `curl | bash`), because each module re-invokes the script.

```bash
curl -fsSL https://raw.githubusercontent.com/10ta/scripts-de-moi/main/debian-init.sh -o debian-init.sh
chmod +x debian-init.sh
./debian-init.sh
```

A checklist menu opens (needs `whiptail`; otherwise use `--all` or `--only`). After the run it prints which modules succeeded, which failed (with the re-run command) and the manual to-do list.

## 🧭 Usage

### Run everything or a subset

```bash
./debian-init.sh --all
./debian-init.sh --only ssh,ufw
```

### Pass the SSH port up front

```bash
SSH_PORT=2222 ./debian-init.sh --all
```

Without it, the `ssh` and `ufw` modules ask for the port.

| Module | What it does |
|---|---|
| `grub` | Serial console + GRUB timeout 0 (appends to existing kernel args) |
| `packages` | Base packages incl. iperf3; distro clang/llvm/lld |
| `chrony` | Time sync |
| `ssh` | Key file, GitHub over 443, sshd port, key-only login |
| `brutal` | TCP Brutal |
| `ufw` | Allow SSH first, add rules, then enable |
| `fish` | fish 4 (openSUSE Build Service) + fisher + `config.fish`, root's default shell |
| `lsd` | lsd config |
| `nvim` | Neovim from GitHub Releases into `/opt` |
| `go` | Official Go binary, latest stable by default |
| `node` | Node.js (NodeSource, pinned major) + pm2 + pnpm; re-run to update |
| `logs` | journald and logrotate limits (all logs under ~100 MB) |
| `timezone` | Set the time zone |
| `exim4` | Remove exim4 if installed |
| `caddy` | Caddy ([lxhao61/integrated-examples](https://github.com/lxhao61/integrated-examples) build), sha256-checked |
| `singbox` | sing-box via [upsing](upsing.md) |

## 🔧 Configuration

Constants at the top of `debian-init.sh`:

| Name | Required | Default | Description |
|---|---|---|---|
| `SSH_PORT` | ❌ | empty (prompt) | sshd port; also accepted from the environment |
| `TIMEZONE` | ❌ | `Asia/Taipei` | Time zone |
| `GO_VERSION` | ❌ | empty (latest) | e.g. `go1.26.1` |
| `NODE_MAJOR` | ❌ | `24` | Node.js major version; change and re-run `--only node` |
| `UFW_RULES` | ❌ | 80, 443, two port ranges | Extra allowed ports (SSH is added automatically) |
| `JOURNAL_SYSTEM_MAX` etc. | ❌ | `50M` / `10M` | journald and logrotate limits |

## 🚧 Limitations & Roadmap

> [!WARNING]
> The `ssh` module turns off password login. After sshd restarts the script pauses: **keep your current session** and test key login from a new terminal. It continues only after you confirm; if the test fails, password login is restored.

- Using the same private key on every server means one breach exposes the others and your GitHub account.
- After changing the kernel, reinstall Brutal: `./debian-init.sh --only brutal`.
- `grub` and the default shell take effect after a reboot.

## 📄 License

No license file yet; all rights reserved by default. See the [repository README](../README.md#-license).
