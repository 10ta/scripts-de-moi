# upsing

[English](upsing.md) · **简体中文**

从 GitHub Release 安装或更新 sing-box 的官方 `.deb` 包，只有版本真的变了才重启。

```text
$ bash upsing.sh
===== 2026-11-01 02:36:53 开始执行 =====
架构: x86_64 -> linux_amd64
[1/4] 请求 GitHub releases 列表...
[2/4] 最新版本 1.13.0-alpha.9，本机 1.13.0-alpha.9
已是最新版本，不安装、不重启（要重装：FORCE=1 bash upsing.sh）
```
*在已是最新版本的机器上运行（示例版本号）。*

## 目录

- [为什么是 upsing？](#-为什么是-upsing)
- [快速开始](#-快速开始)
- [使用](#-使用)
- [局限与路线](#-局限与路线)
- [许可](#-许可)

## 💡 为什么是 upsing？

sing-box 的新功能（以及 [warp-keeper](../warp-keeper/) 需要的功能）常常先出现在预发布版里，发行版的软件源没有。upsing 取 GitHub Release 列表里的第一个版本，按架构挑出 `.deb` 安装，不碰你的配置。

- ✅ 适用：跟踪最新 sing-box（包括 alpha / beta）的 Debian / Ubuntu 服务器。
- ❌ 不适用：只能用正式版的服务器。

## 🚀 快速开始

在 Debian / Ubuntu（`amd64`、`arm64` 或 `armv7`）上以 root 运行：

```bash
curl -fsSL https://raw.githubusercontent.com/10ta/scripts-de-moi/main/upsing.sh -o /tmp/upsing.sh
bash /tmp/upsing.sh
```

它会打印最新版本和本机版本。不一样就下载、用 `dpkg -i` 安装，服务已启用或在运行时重启 `sing-box`。之后 `sing-box version` 显示新版本。

## 🧭 使用

### 重装同一个版本

```bash
FORCE=1 bash /tmp/upsing.sh
```

### 看上一次运行的日志

```bash
cat /var/log/upsing.log
```

## 🚧 局限与路线

- 列表里的第一个版本可能是 **alpha 或 beta** 预发布版。
- 只安装程序。配置仍在 `/etc/sing-box/config.json`，服务由你自己启用。
- 未登录的 GitHub API 每个 IP 每小时限 60 次。
- 除了从 GitHub 走 HTTPS 下载，没有额外的校验和检查。

## 📄 许可

还没有许可证文件，默认保留所有权利。见[仓库 README](../README.zh-CN.md#-许可)。
