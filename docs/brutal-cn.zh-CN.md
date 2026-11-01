# brutal-cn

[English](brutal-cn.md) · **简体中文**

用 APNIC 的中国大陆 IP 段自动维护 TCP Brutal v2 规则：定时更新，丢了自动补回。

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
*用法说明。*

## 目录

- [为什么是 brutal-cn？](#-为什么是-brutal-cn)
- [亮点](#-亮点)
- [快速开始](#-快速开始)
- [安装](#-安装)
- [使用](#-使用)
- [配置](#-配置)
- [工作原理](#-工作原理)
- [局限与路线](#-局限与路线)
- [更新与维护](#-更新与维护)
- [致谢](#-致谢)
- [许可](#-许可)

## 💡 为什么是 brutal-cn？

[TCP Brutal v2](https://github.com/HyNetworks/tcp-brutal) 可以按目的网段设定发送速率：给一个网段加规则后，服务器发往它的所有 TCP 连接都走 Brutal，不需要应用支持。客户端 IP 经常变（手机切网络）时，按 IP 加规则总是慢一步。brutal-cn 直接覆盖整个中国大陆，第一条连接就能用上 Brutal。

- ✅ 适用：客户端在中国大陆的个人代理服务器。
- ❌ 不适用：多人共用的服务器（同一网段的所有连接共用 `MAX_MBPS`）；把 Brutal 设成系统默认拥塞控制。

## ✨ 亮点

- **APNIC 数据，按需下载**：每 24 小时检查一次；返回 304 就不下载；下载失败继续用缓存。
- **规则数量可控**：把几千条前缀贪心合并到 `MAX_RULES_V4`（1000）以内，每一步选额外覆盖非大陆地址最少的合并；不会覆盖私网、保留地址、本机地址、网关和你排除的网段。
- **增量同步**：先加新规则再删旧规则，中间没有空窗。
- **自愈**：每 10 分钟补回因重启丢失的规则、被重启网络清掉的路由，以及网关变化、速率变化。
- **只管自己的规则**：你手动加的规则不动，只在日志里提醒。

## 🚀 快速开始

需要 Debian（或其他用 `apt` 的 systemd 发行版）、Linux ≥ 5.10、root。脚本要放在固定位置，不能在 `/tmp`。

```bash
git clone https://github.com/10ta/scripts-de-moi.git /opt/scripts-de-moi
bash /opt/scripts-de-moi/brutal-cn.sh install
```

首次同步会加一千条左右的规则，屏幕上显示进度，然后启用定时器。用 `bash /opt/scripts-de-moi/brutal-cn.sh status` 检查。

## 📦 安装

### 前置要求

| 组件 | 版本 | 说明 |
|---|---|---|
| Linux 内核 | ≥ 5.10 | TCP Brutal 的要求 |
| systemd、`apt` | — | 缺少的 `curl`、`iproute2`、`python3` 会自动安装 |
| TCP Brutal | v2 | 没有 `brutalctl` 时通过官方脚本 `https://tcp.hy2.sh/` 安装 |

### `install` 会改动什么

- 写入 `/etc/systemd/system/brutal-cn-update.{service,timer}`（开机 20 秒后一次，之后每 `REPAIR_INTERVAL` 一次）。
- 缓存和规则记录放在 `/var/lib/brutal-cn/`。
- `brutalctl` 为每条规则在主路由表加一条 `proto 233` 路由（`ip route show proto 233` 查看）。
- `install --flush-existing` 会先删掉本机**所有** brutal 规则，包括不是它创建的。

## 🧭 使用

### 立即同步

```bash
bash brutal-cn.sh update --force-download
```

### 查看当前有连接的规则

```bash
bash brutal-cn.sh status
```

### 跟踪同步日志

```bash
journalctl -u brutal-cn-update.service -f
```

## 🔧 配置

改 `brutal-cn.sh` 顶部的常量。下一轮同步自动生效；只有 `REPAIR_INTERVAL` 需要重新 `install`。

| 名称 | 必填 | 默认值 | 说明 |
|---|---|---|---|
| `MAX_MBPS` | ✅ | `55` | 发往大陆地址的速率，填客户端实际的下行带宽 |
| `ENABLE_IPV6` | ❌ | `auto` | `auto`（有 IPv6 默认路由时启用）、`yes`、`no` |
| `IPV6_SOURCE` | ❌ | `bigblock` | `bigblock`（内置约 30 个运营商大段）、`apnic`、`manual` |
| `UPDATE_INTERVAL_HOURS` | ❌ | `24` | 多久检查一次 APNIC |
| `IPV6_MANUAL` | ❌ | 空 | `manual` 模式用的 IPv6 列表 |
| `EXTRA_PREFIXES` / `EXCLUDE_PREFIXES` | ❌ | 空 | 总是加上 / 绝不覆盖的前缀 |
| `MAX_RULES_V4` / `MAX_RULES_V6` | ❌ | `1000` / `300` | 规则上限（v6 只在 `apnic` 模式起作用） |
| `REPAIR_INTERVAL` | ❌ | `10min` | 自愈间隔 |
| `APNIC_URLS` | ❌ | APNIC | 数据源，空格分隔 |
| `MIN_V4_PREFIXES` | ❌ | `1000` | 解析出的 IPv4 前缀少于此数视为数据异常，继续用旧列表 |

合并粒度的参考（用约 7,500 条的公开大陆列表测得；以你自己的同步日志为准）：

| `MAX_RULES_V4` | 覆盖范围中非大陆地址的比例 |
|---|---|
| 300 | ≈ 47% |
| 500 | ≈ 31% |
| 1000 | ≈ 13% |
| 2000 | ≈ 4% |
| 3000 | ≈ 1.6% |

## 🧠 工作原理

```mermaid
flowchart LR
  A[APNIC delegated data] --> L[mainland IPv4 / IPv6 prefixes]
  L --> M[merge to rule cap]
  M --> D[diff with kernel rules + routes]
  D --> B[brutalctl add / del]
  T[systemd timer<br/>boot + every 10 min] --> A
```

- **Python 算计划，bash 执行** → 算增删计划不到 1 秒；只有真的有变化时才调用 `brutalctl`。
- **合并受禁区约束** → 合并出的网段永远不会吞掉本机地址、网关或排除的网段。

## 🚧 局限与路线

- 规则影响发往覆盖地址的**所有** TCP 流量（SSH、网站、往大陆机房的上传），应用没法绕开。这类网段写进 `EXCLUDE_PREFIXES`。
- 合并会覆盖少量非大陆地址；往这些地址的大量上传会被限制在 `MAX_MBPS`。
- 同一条规则里的所有连接共用 `MAX_MBPS`。
- Brutal 只对新建连接生效。
- 不要把 brutal 设为默认拥塞控制：没有匹配规则的连接会被限制在 1 Mbps。
- 升级内核后要重装 Brutal（`./debian-init.sh --only brutal` 或官方脚本）。

## 🔄 更新与维护

### 更新

```bash
cd /opt/scripts-de-moi
git pull
bash brutal-cn.sh install
```

### 卸载

```bash
bash brutal-cn.sh uninstall
```

删除它自己创建的规则、定时器和 `/var/lib/brutal-cn`。脚本文件、`brutalctl`、内核模块和其他规则保留。

## 🙏 致谢

- [HyNetworks/tcp-brutal](https://github.com/HyNetworks/tcp-brutal)：内核模块与 `brutalctl`。
- [APNIC delegated statistics](https://ftp.apnic.net/stats/apnic/)：大陆 IPv4 / IPv6 分配数据。

## 📄 许可

还没有许可证文件，默认保留所有权利。见[仓库 README](../README.zh-CN.md#-许可)。
