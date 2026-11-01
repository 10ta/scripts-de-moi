# upsing

**English** · [简体中文](upsing.zh-CN.md)

Installs or updates sing-box from the official GitHub release `.deb`, and restarts it only when the version actually changed.

```text
$ bash upsing.sh
===== 2026-11-01 02:36:53 开始执行 =====
架构: x86_64 -> linux_amd64
[1/4] 请求 GitHub releases 列表...
[2/4] 最新版本 1.13.0-alpha.9，本机 1.13.0-alpha.9
已是最新版本，不安装、不重启（要重装：FORCE=1 bash upsing.sh）
```
*Run on a machine that is already up to date (sample version). Output is in Chinese.*

## Contents

- [Why upsing?](#-why-upsing)
- [Quick Start](#-quick-start)
- [Usage](#-usage)
- [Limitations & Roadmap](#-limitations--roadmap)
- [License](#-license)

## 💡 Why upsing?

sing-box's newest features (and [warp-keeper](../warp-keeper/)'s requirements) often land in pre-releases that distro repos don't carry. upsing takes the first entry of the GitHub release list, picks the `.deb` for your architecture and installs it, leaving your config alone.

- ✅ Good fit: Debian/Ubuntu servers that track the latest sing-box, including alpha/beta builds.
- ❌ Not a fit: servers that must stay on stable releases only.

## 🚀 Quick Start

Run as root on Debian/Ubuntu (`amd64`, `arm64` or `armv7`):

```bash
curl -fsSL https://raw.githubusercontent.com/10ta/scripts-de-moi/main/upsing.sh -o /tmp/upsing.sh
bash /tmp/upsing.sh
```

It prints the latest and installed versions. If they differ it downloads, installs with `dpkg -i`, and restarts `sing-box` if the service is enabled or running. `sing-box version` then shows the new version.

## 🧭 Usage

### Reinstall the same version

```bash
FORCE=1 bash /tmp/upsing.sh
```

### Read the last run's log

```bash
cat /var/log/upsing.log
```

## 🚧 Limitations & Roadmap

- The first release in the list may be an **alpha or beta** pre-release.
- Only the program is installed. Your config stays in `/etc/sing-box/config.json`; enabling the service is up to you.
- Unauthenticated GitHub API calls are limited to 60 per hour per IP.
- There is no checksum check beyond HTTPS from GitHub.

## 📄 License

No license file yet; all rights reserved by default. See the [repository README](../README.md#-license).
