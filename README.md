# scripts-de-moi

**English** · [简体中文](README.zh-CN.md)

Personal Debian server scripts: quota watchers, a CDT cost fuse, CDN IP selection, WARP upkeep and server setup.

> [!NOTE]
> Written and tested for my own Debian + systemd machines. Read a script before running it elsewhere. Program output and Telegram messages are in Chinese.

## Contents

- [What & Why](#-what--why)
- [Tools](#-tools)
- [Quick Start](#-quick-start)
- [Update & Maintenance](#-update--maintenance)
- [Project Structure](#-project-structure)
- [Development](#-development)
- [Limitations & Roadmap](#-limitations--roadmap)
- [Documentation](#-documentation)
- [License](#-license)

## 💡 What & Why

Each tool is a single script or a small directory that installs itself as a systemd service or timer, keeps its config in `/etc/<tool>.env`, and can be re-run safely. The tools share conventions: Telegram messages and [Sonde](https://github.com/10ta/Sonde) panel reports are scrubbed of IPs, domains and URLs, and every installed tool updates with one `update.sh`.

- ✅ Good fit: a few personal Debian VPS / home servers run as root.
- ❌ Not a fit: multi-user or production fleets — there is no packaging, no config management and no licence yet.

## 🧰 Tools

| Tool | What it does | Runs as | Docs |
|---|---|---|---|
| traffic-bot | Telegram bot for free-tier usage across BWH, AWS, Cloudflare, Oracle, Aliyun CDT | Service | [traffic-bot/](traffic-bot/README.md) |
| cdt-guard | Aliyun CDT traffic + cost fuse and keep-alive for one ECS instance | Timer, 5 min | [CDT-Management/](CDT-Management/README.md) |
| cfst-ddns | Picks the fastest Cloudflare / CloudFront edge IP and updates a DNS record | Timer, 5 min | [cfst-ddns/](cfst-ddns/README.md) |
| warp-keeper | Keeps a WARP WireGuard endpoint alive inside sing-box | Timer, hourly | [warp-keeper/](warp-keeper/README.md) |
| brutal-cn | TCP Brutal v2 rules for mainland China IP ranges | Timer, 10 min | [docs/brutal-cn.md](docs/brutal-cn.md) |
| debian-init | Modular first-boot setup for Debian 13 | One-off | [docs/debian-init.md](docs/debian-init.md) |
| upsing | Installs / updates sing-box from GitHub release `.deb` | One-off | [docs/upsing.md](docs/upsing.md) |

traffic-bot reads cdt-guard's state file, so those two must run on the same machine.

## 🚀 Quick Start

Requires Debian with systemd, run as root. Clone once to a fixed path, then follow the Quick Start of the tool you need:

```bash
git clone https://github.com/10ta/scripts-de-moi.git /opt/scripts-de-moi
cd /opt/scripts-de-moi
```

Every installer is idempotent and keeps an existing `/etc/<tool>.env`. Commands in these docs run as written in bash or fish.

## 🔄 Update & Maintenance

### Update

```bash
cd /opt/scripts-de-moi
./update.sh
```

It refuses to run with uncommitted changes or a diverged branch, fast-forwards, then runs `<tool>/update.sh` for each tool installed here (program file **and** `/etc/<tool>.env` present). `./update.sh --status` only compares repo and deployed versions. brutal-cn, debian-init and upsing are not covered; see their docs.

To apply changes delivered as patches:

```bash
git am -3 *.patch && rm *.patch && git push && ./update.sh
```

### Uninstall

```bash
./uninstall.sh
```

Lists installed tools, lets you pick, asks for `yes`, then removes programs, services and timers. Config, keys, state and service users stay; the command to delete them is printed per tool.

## 📁 Project Structure

```text
.
├── CDT-Management/   # cdt-guard: cdt_guard.py, init.sh, units, RAM policy, tests/
├── traffic-bot/      # bot.py, install.sh (venv + unit + env template), tests/
├── cfst-ddns/        # cfst-ddns.sh, install.sh, units, env template
├── warp-keeper/      # warp-keeper.sh, install.sh, units, env template
├── docs/             # Pages for the root-level scripts below
├── brutal-cn.sh      # TCP Brutal rule sync (config at the top of the file)
├── debian-init.sh    # Debian 13 setup modules
├── upsing.sh         # sing-box .deb installer
├── debian-note.md    # Server notes (Chinese) behind debian-init
├── update.sh         # Update every installed tool
└── uninstall.sh      # Pick and uninstall tools
```

Each tool directory has `README.md`, `README.zh-CN.md`, a Chinese `docs/MANUAL.zh-CN.md`, `update.sh` and an uninstaller.

## 🔨 Development

```bash
python3 -m unittest discover CDT-Management/tests
/opt/traffic-bot/venv/bin/python -m unittest discover traffic-bot/tests
bash -n brutal-cn.sh cfst-ddns/cfst-ddns.sh warp-keeper/warp-keeper.sh upsing.sh
bash cfst-ddns/tests/run.sh
```

Conventions, invariants and the pre-commit checklist are in [AGENTS.md](AGENTS.md).

## 🚧 Limitations & Roadmap

### Environment facts and open questions

Facts the code depends on but cannot show. Update this table when one is confirmed or changes.

| Item | Value | Status |
|---|---|---|
| Sonde storage backend | Cloudflare D1 | Confirmed by owner, 2026-11-01. Sonde code lives in [10ta/Sonde](https://github.com/10ta/Sonde), not here |
| Sonde ingest volume | ≈ 320 reports/day: traffic-bot ≈ 156, cdt-guard ≈ 96, cfst-ddns ≈ 40, warp-keeper 24 per host | Estimated from schedules; D1 free tier is 100k rows written/day, so writes per report decide the headroom — unverified |
| Sonde offline detection | Each report sends `interval` (cdt-guard now 900 s) | Assumed Sonde uses it to mark a source stale — check in the Sonde repo |
| Aliyun CDT empty `TrafficDetails` | Treated as a data error while fused | Whether the API ever returns it is unknown; the guard no longer releases on it |
| Cloudflare API limits | GraphQL 300 / 5 min, REST 1200 / 5 min | From memory of Cloudflare docs, unverified; traffic-bot uses ≈ 10–15 GraphQL calls per 10 min |
| AWS CloudWatch free API calls | 1M / month | From code comments, unverified; traffic-bot uses ≈ 16k / month |
| OCI SDK default retry | 8 attempts / 600 s | Verified with `oci` 2.189.0; traffic-bot now caps it at 3 / 60 s |
| Performance baseline | None recorded yet | traffic-bot now logs per-provider time each round; collect a day of it |
| cfst-ddns full scan with two targets | Must finish within `RuntimeMaxSec=30min` | Measured by owner, 2026-10-20: Cloudflare 159–189 s, CloudFront 120 s, shortlist re-test ≈ 50 s — about 5 min for both |

### Known limitations

- No automated tests for warp-keeper, brutal-cn and debian-init; changes are verified by hand on a server. cfst-ddns has an offline suite (`cfst-ddns/tests/run.sh`).
- warp-keeper passes its Telegram and Sonde tokens on the `curl` command line, where other local users can see them in the process list. cfst-ddns passes them on stdin.

## 📚 Documentation

- [AGENTS.md](AGENTS.md): Commands, conventions, invariants and gotchas for AI coding agents.
- [traffic-bot/README.md](traffic-bot/README.md): Usage bot; full Chinese manual in `traffic-bot/docs/`.
- [CDT-Management/README.md](CDT-Management/README.md): cdt-guard; RAM setup and FAQ in `CDT-Management/docs/`.
- [cfst-ddns/README.md](cfst-ddns/README.md): Edge IP selection; seeds, upload testing and CloudFront in `cfst-ddns/docs/`.
- [warp-keeper/README.md](warp-keeper/README.md): WARP upkeep; migration from wireproxy in `warp-keeper/docs/`.
- [docs/brutal-cn.md](docs/brutal-cn.md): TCP Brutal rule sync.
- [docs/debian-init.md](docs/debian-init.md): Debian 13 setup.
- [docs/upsing.md](docs/upsing.md): sing-box installer.
- [debian-note.md](debian-note.md): Server notes (Chinese) — reinstall, init, tuning, proxies, PVE.

## 📄 License

No license file yet, so all rights are reserved by default.
<!-- TODO: choose a licence (e.g. MIT) and add LICENSE -->
