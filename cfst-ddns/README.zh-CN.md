# cfst-ddns

[English](README.md) · **简体中文**

从你自己的线路找出最快的 Cloudflare（或 CloudFront / Fastly）节点 IP，并让一条 DNS 记录始终指向它。

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
*晚高峰巡检发现当前 IP 变差，复测榜单后换了 IP。*

## 目录

- [为什么是 cfst-ddns？](#-为什么是-cfst-ddns)
- [亮点](#-亮点)
- [快速开始](#-快速开始)
- [安装](#-安装)
- [使用](#-使用)
- [配置](#-配置)
- [更新与维护](#-更新与维护)
- [工作原理](#-工作原理)
- [开发](#-开发)
- [文档地图](#-文档地图)
- [致谢](#-致谢)
- [许可](#-许可)

## 💡 为什么是 cfst-ddns？

哪个 CDN 节点 IP 快，取决于你所在运营商的路由和时段，上午最好的 IP 到晚上九点往往就堵了。cfst-ddns 在你线路上的一台机器上定时运行 [CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)，通过 Cloudflare API 把胜出的 IP 写进一条灰云记录。

- ✅ 适用：家里一台 Debian，为代理或挂在 Cloudflare / CloudFront 后面的自建站点选优选 IP。
- ❌ 不适用：开了代理（橙云）的记录；或者测速必须在客户端以外的线路上进行。

## ✨ 亮点

- **三级流程**：平时只巡检当前 IP；变差了才复测榜单；每天晚高峰前做一次全量扫描。
- **按时段调度**：晚高峰每 30 分钟巡检一次，其余时间每 2 小时，按你设的时区。
- **不来回跳**：新 IP 要比当前的好 `SWITCH_MARGIN`（20%）以上才会替换。
- **按下载、上传或延迟选**：由 `RANK_BY` 决定；可以按延迟分段，比较两条线路。
- **种子**：公共优选域名和网页里的 IP 会在你的线路上重测，并和官方扫描对比（`stats`）。
- **多个 CDN**：`TARGETS` 里的每个目标各有自己的记录、榜单和时间表；内置 CloudFront、Fastly 的官方 IP 列表。
- **默认安全**：没有结果、速度为 0、API 报错时，一律不动现有解析。

## 🚀 快速开始

需要带 systemd 的 Debian、`curl` 和 `jq`，以 root 运行。先用 **Edit zone DNS** 模板创建一个只限这一个域名的 Cloudflare API Token。

```bash
git clone https://github.com/10ta/scripts-de-moi.git /opt/scripts-de-moi
cd /opt/scripts-de-moi/cfst-ddns
./install.sh
nano /etc/cfst-ddns.env
systemctl start cfst-ddns@full
```

填好 `CF_API_TOKEN`、`CF_ZONE_ID` 和 `CF_RECORD_NAME`，然后手动跑一次全量扫描。用 `journalctl -fu 'cfst-ddns@*' --output cat` 跟踪，最后会看到 `已更新 <记录> (A): … -> …` 或 `解析保持 …`。然后启用定时：`systemctl enable --now cfst-ddns.timer`。

## 📦 安装

### 前置要求

| 组件 | 版本 | 说明 |
|---|---|---|
| 带 systemd 的 Debian | — | `flock` 属于 util-linux |
| `curl`、`jq` | — | 没有的话 `install.sh` 会装 |
| CloudflareSpeedTest | 最新 release | 首次安装时 `install.sh` 下载 |
| Cloudflare API Token | — | **Edit zone DNS**，只给一个域名；绝不用 Global API Key |

### `install.sh` 会改动什么

- 创建用户 `cfst-ddns`，固定 UID 950（另选：`CFST_UID=951 ./install.sh`）。
- 把 `cfst` 和脚本装到 `/opt/cfst-ddns/`，单元文件装到 `/etc/systemd/system/`。
- 只在首次安装时把 `cfst-ddns.env.example` 复制成 `/etc/cfst-ddns.env`。
- GitHub 下载慢时设 `GH_PROXY=https://<你的镜像>/`；`UPDATE_CFST=1` 会重新下载 cfst。

### 配合 sing-box TUN

测速必须直连。在 TUN 里排除这个服务用户，API 和 Telegram 请求走本机代理：

```json
{ "type": "tun", "auto_route": true, "exclude_uid": [950] }
```

```bash
API_PROXY=socks5h://127.0.0.1:2080
```

详见[手册 · 配合 sing-box TUN](docs/MANUAL.zh-CN.md#3-配合-sing-box-tun)。

## 🧭 使用

### 立即跑某一级

```bash
systemctl start cfst-ddns@check
systemctl start cfst-ddns@pool
systemctl start cfst-ddns@full:cloudfront
```

`start` 会立即返回，进度看 `journalctl -fu 'cfst-ddns@*' --output cat`。后面加 `:<目标>` 只跑这一个目标。

### 对比种子和官方扫描

```bash
/opt/cfst-ddns/cfst-ddns.sh stats:30
```

按目标、按晚高峰 / 非高峰，打印最近 30 天官方扫描和种子的平均最佳成绩。

### 改时间表

改 `/etc/cfst-ddns.env` 里的 `FULL_AT`、`PEAK_HOURS`、`PEAK_EVERY` 或 `OFFPEAK_EVERY`，下一次触发就生效，不用重启。

## 🔧 配置

配置在 `/etc/cfst-ddns.env`。带注释的完整列表见 [`cfst-ddns.env.example`](cfst-ddns.env.example)，常用的几项：

| 名称 | 必填 | 默认值 | 说明 |
|---|---|---|---|
| `CF_API_TOKEN` | ✅ | — | 有这个域名 DNS 编辑权限的 Token |
| `CF_ZONE_ID` | ✅ | — | Zone ID |
| `CF_RECORD_NAME` | ✅ | — | 专用的、会被反复覆盖的记录，如 `cf.example.com` |
| `TARGETS` | ❌ | `cloudflare` | 空格分隔的 CDN，如 `"cloudflare cloudfront"` |
| `TIMEZONE` | ❌ | `Asia/Taipei` | 时间表和消息用的时区 |
| `FULL_AT` | ❌ | `18:30` | 每天全量扫描的时间 |
| `PEAK_HOURS` / `PEAK_EVERY` / `OFFPEAK_EVERY` | ❌ | `19-24` / `30` / `120` | 晚高峰时段和巡检间隔（分钟） |
| `RANK_BY` | ❌ | `download` | `download`、`upload` 或 `latency` |
| `LATENCY_SPLIT` / `PICK_PER_GROUP` | ❌ | `0` / `5` | 延迟分段界限（ms）和每段榜单大小 |
| `MIN_SPEED` / `SWITCH_MARGIN` / `HEALTH_RATIO` | ❌ | `0` / `20` / `70` | 速度底线（MB/s）、切换门槛（%）、健康比例（%） |
| `CFST_ARGS` | ❌ | `-tl 250` | 额外的 cfst 参数；不要写 `-f -o -p -dn -dd` |
| `SEEDS_DNS` / `SEEDS_URL` | ❌ | — | 种子来源 |
| `API_PROXY` | ❌ | 直连 | API 和 Telegram 请求用的代理 |
| `TG_BOT_TOKEN` / `TG_CHAT_ID` / `TG_NOTIFY` | ❌ | — / — / `all` | Telegram 简报（`all`、`change`、`off`） |
| `SONDE_URL` / `SONDE_TOKEN` | ❌ | — | 上报 Sonde 面板 |
| `<目标>_XXX` | ❌ | — | 按目标覆盖，如 `CLOUDFRONT_RECORD_NAME` |

## 🔄 更新与维护

### 更新

```bash
cd /opt/scripts-de-moi
./cfst-ddns/update.sh
```

### 数据与备份

配置：`/etc/cfst-ddns.env`（600）。每个目标的状态在 `/var/lib/cfst-ddns/<目标>/`：`pool.csv`（榜单）、`state`（上次运行时间、基准）、`history.csv`（`stats` 用）、`colo.cache`、`cfst.log`。

### 日志

```bash
journalctl -fu 'cfst-ddns@*' --output cat
```

定时器每 5 分钟启动一次 `cfst-ddns@auto`；没到时间时几毫秒就退出，所以 journal 里有很短的启动 / 结束记录是正常的。

### 卸载

```bash
./cfst-ddns/uninstall.sh
```

删除定时器、单元和 `/opt/cfst-ddns`。配置、历史和 `cfst-ddns` 用户保留，并打印删除命令。DNS 记录停在最后一次的 IP。

## 🧠 工作原理

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

- **路由几天才变，拥堵按小时变** → 全量延迟扫描一天一次；频繁运行的只是巡检当前 IP。
- **延迟限制由脚本筛，不交给 cfst** → 日志能说清楚一个 IP 是连不上还是超出限制。
- **两轮不会重叠** → `flock` 让新的一轮在上一轮没结束时直接跳过；每次运行最长 30 分钟。
- **种子必须落在该 CDN 的官方网段内** → 被劫持的公共域名混不进别的 IP（除非 `SEED_ALLOW_OUTSIDE=1`）。
- **消息里写机房代码，不写 IP** → Telegram 和 Sonde 里不会出现 IP 和域名。

## 🔨 开发

```bash
bash -n cfst-ddns/cfst-ddns.sh
```

没有自动化测试。改动后用一条临时记录手动跑一次，看 journal 验证。

## 📚 文档地图

- [docs/MANUAL.zh-CN.md](docs/MANUAL.zh-CN.md)：完整中文手册——选 IP 规则、种子、上传测速、CloudFront / Fastly、排错、流量消耗。
- [cfst-ddns.env.example](cfst-ddns.env.example)：全部配置项和注释。
- [../AGENTS.md](../AGENTS.md)：给 AI 编码代理的约定和检查清单。

## 🙏 致谢

- [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)：测速引擎。

## 📄 许可

还没有许可证文件，默认保留所有权利。见[仓库 README](../README.zh-CN.md#-许可)。
