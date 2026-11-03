# cfst-ddns

**English** · [简体中文](README.zh-CN.md)

Finds the fastest Cloudflare (or CloudFront / Fastly) edge IP from your own line and keeps a DNS record pointed at it.

```text
10-20 21:00 晚高峰（19-24），每 30 分钟巡检
===== 巡检 =====
巡检当前 IP: 104.17.x.x
变差：下载 0.30 MB/s，健康线 5.74 MB/s（基准 8.20 的 70%）
===== 复测榜单 =====
复测榜单: 10 个 IP（含当前 IP）
选中: 104.18.x.x  延迟 170ms（≥150ms 段）  丢包 0.00  下载 6.00MB/s
说明: 当前 IP 只有 0.30 MB/s，低于底线 1
已更新 cf.example.com (A): 104.17.x.x -> 104.18.x.x
```
*An evening-peak check finds the current IP degraded, re-tests the shortlist and switches. Logs are in Chinese.*

## Contents

- [Why cfst-ddns?](#-why-cfst-ddns)
- [Highlights](#-highlights)
- [Quick Start](#-quick-start)
- [Installation](#-installation)
- [Usage](#-usage)
- [Configuration](#-configuration)
- [Update & Maintenance](#-update--maintenance)
- [How It Works](#-how-it-works)
- [Development](#-development)
- [Documentation](#-documentation)
- [Acknowledgements](#-acknowledgements)
- [License](#-license)

## 💡 Why cfst-ddns?

Which CDN edge IP is fast depends on your ISP's routing and the time of day, and the best IP at 10 am is often congested at 9 pm. cfst-ddns runs [CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) on a schedule from a machine on your line and writes the winner into one DNS-only record through the Cloudflare API.

- ✅ Good fit: a home Debian box that picks preferred IPs for a proxy or a self-hosted site behind Cloudflare / CloudFront.
- ❌ Not a fit: proxied (orange-cloud) records, or when the measurement must run somewhere other than the client's own line.

## ✨ Highlights

- **Three levels of work** — usually only the current IP is checked; the shortlist is re-tested when it degrades; a full scan runs once a day before the evening peak.
- **Peak-aware schedule** — checks every 30 min during peak hours and every 2 h otherwise, in your time zone.
- **No flapping** — a new IP must beat the current one by `SWITCH_MARGIN` (20%) to replace it.
- **Download, upload or latency** — rank by `RANK_BY`; split candidates by latency to compare two routes.
- **Seeds** — public "preferred IP" domains and pages are re-tested on your line and tracked against the official scan (`stats`).
- **Several CDNs** — each target in `TARGETS` keeps its own record, shortlist and schedule; CloudFront and Fastly IP lists are built in.
- **Safe by default** — no result, zero speed or an API error never changes the existing record.

## 🚀 Quick Start

Requires Debian with systemd, `curl` and `jq`, run as root. Create a Cloudflare API token from the **Edit zone DNS** template, scoped to one zone.

```bash
git clone https://github.com/10ta/scripts-de-moi.git /opt/scripts-de-moi
cd /opt/scripts-de-moi/cfst-ddns
./install.sh
nano /etc/cfst-ddns.env
systemctl start cfst-ddns@full
```

Fill in `CF_API_TOKEN`, `CF_ZONE_ID` and `CF_RECORD_NAME`, then start one full scan. Follow it with `journalctl -fu 'cfst-ddns@*' --output cat`; it ends with `已更新 <record> (A): … -> …` or `解析保持 …`. Then enable the schedule: `systemctl enable --now cfst-ddns.timer`.

## 📦 Installation

### Requirements

| Component | Version | Notes |
|---|---|---|
| Debian with systemd | — | `flock` is part of util-linux |
| `curl`, `jq` | — | Installed by `install.sh` if missing |
| CloudflareSpeedTest | latest release | Downloaded by `install.sh` on first install |
| Cloudflare API token | — | **Edit zone DNS**, one zone only; never the Global API Key |

### What `install.sh` changes

- Creates the user `cfst-ddns` with fixed UID 950 (`CFST_UID=951 ./install.sh` to pick another).
- Installs `cfst` and the script to `/opt/cfst-ddns/`, units to `/etc/systemd/system/`.
- Copies `cfst-ddns.env.example` to `/etc/cfst-ddns.env` on first install only.
- Set `GH_PROXY=https://<your-mirror>/` if GitHub downloads are slow; `UPDATE_CFST=1` re-downloads cfst.

### With sing-box TUN

Speed tests must go direct. Exclude the service user from TUN, and send API / Telegram requests through a local proxy:

```json
{ "type": "tun", "auto_route": true, "exclude_uid": [950] }
```

```bash
API_PROXY=socks5h://127.0.0.1:2080
```

Details: [manual § sing-box TUN](docs/MANUAL.zh-CN.md#3-配合-sing-box-tun).

## 🧭 Usage

### Run a level now

```bash
systemctl start cfst-ddns@check
systemctl start cfst-ddns@pool
systemctl start cfst-ddns@full:cloudfront
```

`start` returns at once; progress goes to `journalctl -fu 'cfst-ddns@*' --output cat`. Add `:<target>` to run a single target.

### Compare seeds with the official scan

```bash
/opt/cfst-ddns/cfst-ddns.sh stats:30
```

Prints, per target and per peak/off-peak, the average best result from the official scan vs. seeds over 30 days.

### Change the schedule

Edit `FULL_AT`, `PEAK_HOURS`, `PEAK_EVERY` or `OFFPEAK_EVERY` in `/etc/cfst-ddns.env`; the next timer tick uses it, nothing to restart.

## 🔧 Configuration

Settings live in `/etc/cfst-ddns.env`. The full commented list is [`cfst-ddns.env.example`](cfst-ddns.env.example); the most used keys:

| Name | Required | Default | Description |
|---|---|---|---|
| `CF_API_TOKEN` | ✅ | — | Token with DNS edit on the zone |
| `CF_ZONE_ID` | ✅ | — | Zone ID |
| `CF_RECORD_NAME` | ✅ | — | Dedicated record to overwrite, e.g. `cf.example.com` |
| `TARGETS` | ❌ | `cloudflare` | Space-separated CDNs, e.g. `"cloudflare cloudfront"` |
| `TIMEZONE` | ❌ | `Asia/Taipei` | Time zone for the schedule and messages |
| `FULL_AT` | ❌ | `18:30` | Daily full-scan time(s) |
| `PEAK_HOURS` / `PEAK_EVERY` / `OFFPEAK_EVERY` | ❌ | `19-24` / `30` / `120` | Peak window and check intervals (min) |
| `RANK_BY` | ❌ | `download` | `download`, `upload` or `latency` |
| `LATENCY_SPLIT` / `PICK_PER_GROUP` | ❌ | `0` / `5` | Latency split (ms) and shortlist size per group |
| `MIN_SPEED` / `SWITCH_MARGIN` / `HEALTH_RATIO` | ❌ | `0` / `20` / `70` | Floor (MB/s), switch margin (%), health ratio (%) |
| `SPEED_TOLERANCE` | ❌ | `0` | Within this % of the fastest, prefer lower loss, then lower latency |
| `FULL_MIN_GAP` | ❌ | `120` | Minutes between full scans after a failed one or a failed shortlist |
| `CFST_ARGS` | ❌ | `-tl 250` | Extra cfst flags; never `-f -o -p -dn -dd` |
| `SEEDS_DNS` / `SEEDS_URL` | ❌ | — | Seed sources |
| `API_PROXY` | ❌ | direct | Proxy for API and Telegram requests |
| `TG_BOT_TOKEN` / `TG_CHAT_ID` / `TG_NOTIFY` | ❌ | — / — / `all` | Telegram summaries (`all`, `change`, `off`) |
| `TG_NOTIFY_CHECK` | ❌ | `off` | Also send a message when a check finds the current IP healthy |
| `SONDE_URL` / `SONDE_TOKEN` | ❌ | — | Sonde panel reporting |
| `<TARGET>_XXX` | ❌ | — | Per-target override, e.g. `CLOUDFRONT_RECORD_NAME` |

## 🔄 Update & Maintenance

### Update

```bash
cd /opt/scripts-de-moi
./cfst-ddns/update.sh
```

### Data & backup

Config: `/etc/cfst-ddns.env` (600). Per-target state in `/var/lib/cfst-ddns/<target>/`: `pool.csv` (shortlist), `state` (last runs, baseline), `history.csv` (for `stats`), `colo.cache`, `cfst.log`.

### Logs

```bash
journalctl -fu 'cfst-ddns@*' --output cat
```

The timer starts `cfst-ddns@auto` every 5 minutes; when nothing is due it exits in milliseconds, so short start/stop lines in the journal are normal.

### Uninstall

```bash
./cfst-ddns/uninstall.sh
```

Removes the timer, units and `/opt/cfst-ddns`. Config, history and the `cfst-ddns` user are kept, and the delete commands are printed. The DNS record keeps its last IP.

## 🧠 How It Works

```mermaid
flowchart LR
  T[cfst-ddns.timer<br/>every 5 min] --> A[cfst-ddns@auto]
  A -->|FULL_AT reached| F[③ full scan]
  A -->|check due| C[① check current IP]
  C -->|degraded| P[② re-test shortlist]
  P -->|nothing good| F
  P & F -->|beats current by SWITCH_MARGIN| D[Cloudflare DNS API]
  C & P & F --> N[Telegram / Sonde]
```

- **Routes change over days, congestion over hours** → full latency scans once a day; frequent runs only re-check the current IP.
- **Latency limits are applied by the script, not cfst** → logs say whether an IP was unreachable or just over the limit.
- **Runs never overlap** → a `flock` makes a new round skip while one is running; each run is capped at 30 minutes.
- **A failed full scan waits before retrying** → at most one full scan per `FULL_MIN_GAP`, so a broken direct route does not turn into thousands of probes every 5 minutes. The same failure goes to Telegram once per 2 hours.
- **Re-testing never shrinks the shortlist** → IPs that are unreachable for one round stay until the next full scan.
- **Seeds must fall inside the CDN's official ranges** → a hijacked public domain cannot inject foreign IPs (unless `SEED_ALLOW_OUTSIDE=1`).
- **Messages show the edge's colo code, not the IP** → Telegram and Sonde never carry IPs or domains.

## 🔨 Development

```bash
bash cfst-ddns/tests/run.sh
```

Runs the whole flow offline with a fake cfst and a fake Cloudflare / Telegram API, no root needed; it ends with `通过 25 项，失败 0 项`. Before relying on a change, also run it once against a throw-away record and watch the journal.

## 📚 Documentation

- [docs/MANUAL.zh-CN.md](docs/MANUAL.zh-CN.md): Full Chinese manual — selection rules, seeds, upload testing, CloudFront/Fastly, troubleshooting, traffic cost.
- [cfst-ddns.env.example](cfst-ddns.env.example): Every config key with comments.
- [../AGENTS.md](../AGENTS.md): Conventions and checks for AI coding agents working on this repo.

## 🙏 Acknowledgements

- [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) — the speed-test engine.

## 📄 License

No license file yet; all rights reserved by default. See the [repository README](../README.md#-license).
