# scripts-de-moi

[English](README.md) · **简体中文**

自用的 Debian 服务器脚本：额度监控、CDT 费用熔断、CDN 优选 IP、WARP 维护和服务器初始化。

> [!NOTE]
> 这些脚本按我自己的 Debian + systemd 环境编写和测试。用在别处之前，请先读一遍代码。程序输出和 Telegram 消息都是中文。

## 目录

- [是什么 & 为什么](#-是什么--为什么)
- [工具一览](#-工具一览)
- [快速开始](#-快速开始)
- [更新与维护](#-更新与维护)
- [项目结构](#-项目结构)
- [开发](#-开发)
- [局限与路线](#-局限与路线)
- [文档地图](#-文档地图)
- [许可](#-许可)

## 💡 是什么 & 为什么

每个工具是一个脚本或一个小目录，自己装成 systemd 服务或定时器，配置放在 `/etc/<工具>.env`，可以放心重复运行。工具之间共用一套约定：Telegram 消息和 [Sonde](https://github.com/10ta/Sonde) 面板上报都去掉 IP、域名和网址；本机装了的工具用一个 `update.sh` 一起更新。

- ✅ 适用：以 root 管理的几台个人 Debian VPS / 家用服务器。
- ❌ 不适用：多用户或生产集群——没有打包、没有配置管理，也还没有许可证。

## 🧰 工具一览

| 工具 | 作用 | 运行方式 | 文档 |
|---|---|---|---|
| traffic-bot | Telegram 机器人，汇总 BWH、AWS、Cloudflare、Oracle、阿里云 CDT 的免费额度用量 | 常驻服务 | [traffic-bot/](traffic-bot/README.zh-CN.md) |
| cdt-guard | 一台 ECS 的阿里云 CDT 流量 + 费用熔断和保活 | 定时器，5 分钟 | [CDT-Management/](CDT-Management/README.zh-CN.md) |
| cfst-ddns | 选出最快的 Cloudflare / CloudFront 节点 IP 并更新 DNS 记录 | 定时器，5 分钟 | [cfst-ddns/](cfst-ddns/README.zh-CN.md) |
| warp-keeper | 在 sing-box 里维护一个 WARP WireGuard endpoint | 定时器，每小时 | [warp-keeper/](warp-keeper/README.zh-CN.md) |
| brutal-cn | 按中国大陆 IP 段维护 TCP Brutal v2 规则 | 定时器，10 分钟 | [docs/brutal-cn.zh-CN.md](docs/brutal-cn.zh-CN.md) |
| debian-init | Debian 13 的模块化初始化 | 一次性 | [docs/debian-init.zh-CN.md](docs/debian-init.zh-CN.md) |
| upsing | 从 GitHub Release 的 `.deb` 安装 / 更新 sing-box | 一次性 | [docs/upsing.zh-CN.md](docs/upsing.zh-CN.md) |

traffic-bot 读取 cdt-guard 的状态文件，所以这两个必须装在同一台机器上。

## 🚀 快速开始

需要带 systemd 的 Debian，以 root 运行。先把仓库 clone 到固定位置，再按所需工具的「快速开始」操作：

```bash
git clone https://github.com/10ta/scripts-de-moi.git /opt/scripts-de-moi
cd /opt/scripts-de-moi
```

所有安装脚本都是幂等的，不会覆盖已有的 `/etc/<工具>.env`。文档里的命令在 bash 和 fish 里都能直接运行。

## 🔄 更新与维护

### 更新

```bash
cd /opt/scripts-de-moi
./update.sh
```

有未提交的改动或分支分叉时它会拒绝运行；否则快进拉取，再对本机装了的每个工具（程序文件**和** `/etc/<工具>.env` 都在）运行 `<工具>/update.sh`。`./update.sh --status` 只对比仓库版本和已部署版本。brutal-cn、debian-init、upsing 不在其中，见各自的文档。

应用以补丁形式交付的改动：

```bash
git am -3 *.patch && rm *.patch && git push && ./update.sh
```

### 卸载

```bash
./uninstall.sh
```

列出已安装的工具，让你选，输入 `yes` 确认后删除程序、服务和定时器。配置、密钥、状态和服务用户保留，每个工具会打印彻底删除的命令。

## 📁 项目结构

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

每个工具目录里都有 `README.md`、`README.zh-CN.md`、中文的 `docs/MANUAL.zh-CN.md`、`update.sh` 和卸载脚本。

## 🔨 开发

```bash
python3 -m unittest discover CDT-Management/tests
/opt/traffic-bot/venv/bin/python -m unittest discover traffic-bot/tests
bash -n brutal-cn.sh cfst-ddns/cfst-ddns.sh warp-keeper/warp-keeper.sh upsing.sh
bash cfst-ddns/tests/run.sh
```

约定、不变量和提交前检查清单见 [AGENTS.md](AGENTS.md)。

## 🚧 局限与路线

### 环境事实与待确认事项

代码依赖、但从代码里看不出来的事实。确认了或者变了，就更新这张表。

| 事项 | 值 | 状态 |
|---|---|---|
| Sonde 存储后端 | Cloudflare D1 | 仓库主人确认，2026-11-01。Sonde 的代码在 [10ta/Sonde](https://github.com/10ta/Sonde)，不在这里 |
| Sonde 上报量 | 约 320 次/天：traffic-bot ≈ 156、cdt-guard ≈ 96、cfst-ddns ≈ 40、warp-keeper 每台 24 | 按调度估算；D1 免费额度是每天写 10 万行，余量取决于每次上报写几行——未核实 |
| Sonde 离线判断 | 每次上报都带 `interval`（cdt-guard 现在是 900 秒） | 假定 Sonde 用它判断来源是否过期——到 Sonde 仓库确认 |
| 阿里云 CDT 返回空的 `TrafficDetails` | 熔断期间按数据异常处理 | 不确定接口会不会这样返回；守护程序已不会因此解除熔断 |
| Cloudflare API 限额 | GraphQL 300 次 / 5 分钟，REST 1200 次 / 5 分钟 | 凭记忆，未核实；traffic-bot 每 10 分钟约 10–15 次 GraphQL |
| AWS CloudWatch 免费 API 次数 | 100 万次 / 月 | 来自代码注释，未核实；traffic-bot 每月约 1.6 万次 |
| OCI SDK 默认重试 | 8 次 / 600 秒 | 已用 `oci` 2.189.0 核实；traffic-bot 现在限制为 3 次 / 60 秒 |
| 性能基线 | 还没有记录 | traffic-bot 现在每轮记录各来源耗时；收集一天的数据 |
| cfst-ddns 两个目标的全量扫描 | 必须在 `RuntimeMaxSec=30min` 内跑完 | 仓库主人实测，2026-10-20：Cloudflare 159–189 秒、CloudFront 120 秒、复测榜单约 50 秒，两个目标合计约 5 分钟 |

### 已知局限

- warp-keeper、brutal-cn、debian-init 没有自动化测试，改动靠在服务器上手动验证。cfst-ddns 有离线测试（`cfst-ddns/tests/run.sh`）。
- warp-keeper 把 Telegram 和 Sonde 的 token 写在 `curl` 命令行里，本机其他用户能在进程列表里看到。cfst-ddns 改为经标准输入传递。

## 📚 文档地图

- [AGENTS.md](AGENTS.md)：给 AI 编码代理的命令、约定、不变量和坑。
- [traffic-bot/README.zh-CN.md](traffic-bot/README.zh-CN.md)：用量机器人；完整中文手册在 `traffic-bot/docs/`。
- [CDT-Management/README.zh-CN.md](CDT-Management/README.zh-CN.md)：cdt-guard；RAM 设置和常见问题在 `CDT-Management/docs/`。
- [cfst-ddns/README.zh-CN.md](cfst-ddns/README.zh-CN.md)：节点 IP 优选；种子、上传测速、CloudFront 在 `cfst-ddns/docs/`。
- [warp-keeper/README.zh-CN.md](warp-keeper/README.zh-CN.md)：WARP 维护；从 wireproxy 迁移在 `warp-keeper/docs/`。
- [docs/brutal-cn.zh-CN.md](docs/brutal-cn.zh-CN.md)：TCP Brutal 规则同步。
- [docs/debian-init.zh-CN.md](docs/debian-init.zh-CN.md)：Debian 13 初始化。
- [docs/upsing.zh-CN.md](docs/upsing.zh-CN.md)：sing-box 安装脚本。
- [debian-note.md](debian-note.md)：服务器笔记——重装、初始化、调优、代理、PVE。

## 📄 许可

还没有许可证文件，所以默认保留所有权利。
<!-- TODO: choose a licence (e.g. MIT) and add LICENSE -->
