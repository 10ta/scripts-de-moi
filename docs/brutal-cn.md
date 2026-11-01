# brutal-cn

**English** · [简体中文](brutal-cn.zh-CN.md)

Keeps TCP Brutal v2 per-destination rules in sync with mainland China IP ranges from APNIC, with timed updates and self-repair.

```text
$ bash brutal-cn.sh
brutal-cn — 用中国大陆 IP 段维护 TCP Brutal v2 规则（定时更新 + 自愈）

  bash brutal-cn.sh install [--flush-existing]   安装/重装（幂等，可反复运行）
                                                 --flush-existing 会清空本机全部 brutal 规则
  bash brutal-cn.sh update [--force-download]    立即同步一次
  bash brutal-cn.sh status                       查看状态
  bash brutal-cn.sh uninstall                    删除本工具创建的规则、定时器和缓存

所有配置都在本文件顶部。
```
*Usage text. Output is in Chinese.*

## Contents

- [Why brutal-cn?](#-why-brutal-cn)
- [Highlights](#-highlights)
- [Quick Start](#-quick-start)
- [Installation](#-installation)
- [Usage](#-usage)
- [Configuration](#-configuration)
- [How It Works](#-how-it-works)
- [Limitations & Roadmap](#-limitations--roadmap)
- [Update & Maintenance](#-update--maintenance)
- [Acknowledgements](#-acknowledgements)
- [License](#-license)

## 💡 Why brutal-cn?

[TCP Brutal v2](https://github.com/HyNetworks/tcp-brutal) can pin a send rate per destination prefix, so every TCP connection to that prefix uses Brutal without app support. When the client's IP keeps changing (phone switching networks), per-IP rules always lag behind. brutal-cn covers all of mainland China instead, so the first connection already gets Brutal.

- ✅ Good fit: a personal proxy server whose clients are in mainland China.
- ❌ Not a fit: shared servers (all connections to one prefix share `MAX_MBPS`) or setting Brutal as the system-wide congestion control.

## ✨ Highlights

- **APNIC data, conditional download** — checks every 24 h; a 304 means no download; on failure it keeps the cache.
- **Bounded rule count** — greedily merges thousands of prefixes to `MAX_RULES_V4` (1000), choosing the merge that adds the fewest non-mainland addresses; never covers private, reserved or local addresses, the gateway, or your exclusions.
- **Incremental sync** — adds new rules before deleting old ones, so there is no gap.
- **Self-repair** — every 10 min it restores rules lost to a reboot, routes flushed by a network restart, a changed gateway or a changed rate.
- **Only touches its own rules** — rules you added by hand stay and are reported in the log.

## 🚀 Quick Start

Requires Debian (or another systemd distro with `apt`), Linux ≥ 5.10 and root. The script must live at a fixed path, not `/tmp`.

```bash
git clone https://github.com/10ta/scripts-de-moi.git /opt/scripts-de-moi
bash /opt/scripts-de-moi/brutal-cn.sh install
```

The first sync adds about a thousand rules with progress on screen, then the timer is enabled. Check with `bash /opt/scripts-de-moi/brutal-cn.sh status`.

## 📦 Installation

### Requirements

| Component | Version | Notes |
|---|---|---|
| Linux kernel | ≥ 5.10 | TCP Brutal requirement |
| systemd, `apt` | — | Missing `curl`, `iproute2`, `python3` are installed |
| TCP Brutal | v2 | Installed via the official `https://tcp.hy2.sh/` script if `brutalctl` is missing |

### What `install` changes

- Writes `/etc/systemd/system/brutal-cn-update.{service,timer}` (20 s after boot, then every `REPAIR_INTERVAL`).
- Keeps caches and its rule list in `/var/lib/brutal-cn/`.
- `brutalctl` adds one `proto 233` route per rule to the main table (`ip route show proto 233`).
- `install --flush-existing` first removes **all** brutal rules on the machine, including ones it didn't create.

## 🧭 Usage

### Sync now

```bash
bash brutal-cn.sh update --force-download
```

### See rules with live connections

```bash
bash brutal-cn.sh status
```

### Follow sync logs

```bash
journalctl -u brutal-cn-update.service -f
```

## 🔧 Configuration

Edit the constants at the top of `brutal-cn.sh`. Changes apply on the next sync; only `REPAIR_INTERVAL` needs `install` again.

| Name | Required | Default | Description |
|---|---|---|---|
| `MAX_MBPS` | ✅ | `55` | Send rate to mainland addresses; set to the client's real downlink |
| `ENABLE_IPV6` | ❌ | `auto` | `auto` (if an IPv6 default route exists), `yes`, `no` |
| `IPV6_SOURCE` | ❌ | `bigblock` | `bigblock` (~30 built-in carrier blocks), `apnic`, `manual` |
| `UPDATE_INTERVAL_HOURS` | ❌ | `24` | How often to check APNIC |
| `IPV6_MANUAL` | ❌ | empty | IPv6 list for `manual` |
| `EXTRA_PREFIXES` / `EXCLUDE_PREFIXES` | ❌ | empty | Always add / never cover these prefixes |
| `MAX_RULES_V4` / `MAX_RULES_V6` | ❌ | `1000` / `300` | Rule caps (v6 only in `apnic` mode) |
| `REPAIR_INTERVAL` | ❌ | `10min` | Self-repair interval |
| `APNIC_URLS` | ❌ | APNIC | Data source(s), space-separated |
| `MIN_V4_PREFIXES` | ❌ | `1000` | Fewer parsed IPv4 prefixes means bad data; keep the old list |

How coarse merging gets (measured on a public list of ~7,500 prefixes; check your own sync log):

| `MAX_RULES_V4` | Non-mainland share of covered space |
|---|---|
| 300 | ≈ 47% |
| 500 | ≈ 31% |
| 1000 | ≈ 13% |
| 2000 | ≈ 4% |
| 3000 | ≈ 1.6% |

## 🧠 How It Works

```mermaid
flowchart LR
  A[APNIC delegated data] --> L[mainland IPv4 / IPv6 prefixes]
  L --> M[merge to rule cap]
  M --> D[diff with kernel rules + routes]
  D --> B[brutalctl add / del]
  T[systemd timer<br/>boot + every 10 min] --> A
```

- **Plan in Python, apply in bash** → computing the add/delete plan takes under a second; `brutalctl` runs only for real changes.
- **Merging is bounded by forbidden ranges** → a merged prefix can never swallow a local address, the gateway or an exclusion.

## 🚧 Limitations & Roadmap

- Rules affect **all** TCP traffic to covered addresses (SSH, web, uploads to mainland data centres), and apps cannot opt out. Put such ranges in `EXCLUDE_PREFIXES`.
- Merging covers some non-mainland addresses; big uploads to those are capped at `MAX_MBPS`.
- All connections inside one rule share `MAX_MBPS`.
- Brutal applies to new connections only.
- Don't make brutal the default congestion control: connections without a matching rule are held to 1 Mbps.
- After a kernel upgrade, reinstall Brutal (`./debian-init.sh --only brutal` or the official script).

## 🔄 Update & Maintenance

### Update

```bash
cd /opt/scripts-de-moi
git pull
bash brutal-cn.sh install
```

### Uninstall

```bash
bash brutal-cn.sh uninstall
```

Deletes its own rules, the timer and `/var/lib/brutal-cn`. The script, `brutalctl`, the kernel module and other rules stay.

## 🙏 Acknowledgements

- [HyNetworks/tcp-brutal](https://github.com/HyNetworks/tcp-brutal) — kernel module and `brutalctl`.
- [APNIC delegated statistics](https://ftp.apnic.net/stats/apnic/) — mainland IPv4/IPv6 allocations.

## 📄 License

No license file yet; all rights reserved by default. See the [repository README](../README.md#-license).
