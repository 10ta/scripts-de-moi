# cfst-ddns

在本地 Debian 上定时用 [CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)（cfst）测出最快的 Cloudflare IP，并通过 Cloudflare API 把它更新到自己域名的一条 DNS 记录上，每次运行后可通过 Telegram 发送简报。

- 由 systemd timer 调度，没有常驻进程，单次运行有超时保护
- 以固定 UID 的专用用户运行，方便在 sing-box TUN 里用 `exclude_uid` 让测速流量直连
- 测速期间每 15 秒往 journal 打一行进度
- IP 没变化就不调写接口；没测出结果、下载速度为 0 / 不达标、API 报错时，一律不动现有解析
- 依赖只有 `curl` 和 `jq`

## 工作原理

```
cfst-ddns.timer ──(每小时)──▶ cfst-ddns.service ──▶ cfst-ddns.sh
                                                     ├─ 1. cfst 测速，取结果第一名
                                                     ├─ 2. 读取当前 DNS 记录
                                                     ├─ 3. IP 有变化 → PATCH（记录不存在 → POST）
                                                     └─ 4. 发送 Telegram 简报（可选）
```

IPv4 结果写 A 记录，IPv6 结果写 AAAA 记录。记录会被设为 **DNS only（灰云）**，TTL 默认 60。

## 联网与域名

| 谁 | 连哪里 | 需要解析域名吗 | 应该怎么走 |
|---|---|---|---|
| cfst 延迟测速 | 约 6000 个 CF IP 的 443 端口 | 不需要，直接连 IP | **必须直连** |
| cfst 下载测速 | 被测的 CF IP，`-url` 的域名（默认 `cf.xiu2.xyz`）只用作 SNI/Host | 不需要 | **必须直连** |
| curl | `api.cloudflare.com` | 需要 | 直连或代理均可 |
| curl | `api.telegram.org`（仅在配置了 TG 时） | 需要 | 国内需要代理 |

## 文件

| 文件 | 安装位置 | 作用 |
|---|---|---|
| `install.sh` | — | 安装 / 升级：下载最新 cfst，创建用户，安装脚本和 systemd 单元 |
| `cfst-ddns.sh` | `/opt/cfst-ddns/` | 主脚本：测速 + 更新 DNS + 发送简报 |
| `cfst-ddns.service` | `/etc/systemd/system/` | 服务单元，沙箱化运行，最长 20 分钟 |
| `cfst-ddns.timer` | `/etc/systemd/system/` | 开机 3 分钟后首次运行，之后每小时一次 |
| `cfst-ddns.env.example` | `/etc/cfst-ddns.env` | 配置模板（首次安装时复制，之后不会覆盖） |

## 安装

```bash
git clone https://github.com/10ta/scripts-de-moi.git
cd scripts-de-moi/cfst-ddns
sudo ./install.sh
```

可选环境变量：

- `GH_PROXY=https://你的反代前缀/`：GitHub 下载慢时使用
- `CFST_UID=951`：默认 UID 950 被占用时指定其他值

升级时重新执行 `sudo ./install.sh` 即可，已有的 `/etc/cfst-ddns.env` 不会被覆盖。新版本新增的配置项请参照 `cfst-ddns.env.example` 手动补进去。

## 配置

### 1. Cloudflare API Token

My Profile → API Tokens → Create Token → 使用 **Edit zone DNS** 模板，Zone Resources **只选这一个域名**。

> ⚠️ 不要用 Global API Key：它能操作整个账号，泄露后影响范围远超这一条记录。

### 2. 编辑 `/etc/cfst-ddns.env`

| 变量 | 必填 | 默认值 | 说明 |
|---|---|---|---|
| `CF_API_TOKEN` | ✓ | | 上一步创建的 Token |
| `CF_ZONE_ID` | ✓ | | 域名 Overview 页右下角 |
| `CF_RECORD_NAME` | ✓ | | 要更新的记录，如 `cf.example.com` |
| `CF_TTL` | | `60` | 秒 |
| `CFST_ARGS` | | `-tl 250 -dn 10 -dt 5` | cfst 参数，不要写 `-f` `-o` `-p` |
| `MIN_SPEED` | | `0`（模板里是 `1`） | 速度底线 MB/s，见下方「选 IP 的规则」 |
| `LATENCY_SPLIT` | | `0`（模板里是 `150`） | 分段界限 ms，`0` 为不分段，见下方「选 IP 的规则」 |
| `PICK_PER_GROUP` | | `5` | 分段时每段取几个做下载测速 |
| `CFST_IPFILE` | | `/opt/cfst-ddns/ip.txt` | 测 IPv6 时改为 `ipv6.txt` |
| `PROGRESS_EVERY` | | `15` | 测速期间每隔多少秒往日志打一行进度 |
| `API_PROXY` | | 空（直连） | curl 使用的代理，如 `socks5h://127.0.0.1:2080` |
| `TG_BOT_TOKEN` | | | Telegram bot token |
| `TG_CHAT_ID` | | | 接收简报的 chat id |
| `TG_NOTIFY` | | `all` | `all` 每次都发；`change` 仅 IP 变化或失败时发；`off` 不发 |

> ⚠️ `CF_RECORD_NAME` 请用一个**专用子域名**。脚本会反复覆盖它的 IP，并强制设为灰云，不要指向其他服务正在使用的记录。

常用 cfst 参数：`-tl` 平均延迟上限（ms），`-dn` 下载测速数量，`-dt` 单个下载测速时长（秒），`-url` 自定义下载测速地址，`-dd` 关闭下载测速。完整说明见 [cfst 文档](https://github.com/XIU2/CloudflareSpeedTest)。

### 选 IP 的规则

1. 延迟测速：约 6000 个 IP，淘汰延迟超过 `-tl` 的（1~2 分钟）
2. 下载测速：挑一批候选，每个测 `-dt` 秒，结果按速度排序
   - **分段**（`LATENCY_SPLIT > 0`）：以该延迟为界分两段，每段取丢包最少、延迟最低的 `PICK_PER_GROUP` 个
   - **不分段**（`LATENCY_SPLIT = 0`）：直接取延迟最低的 `-dn` 个
3. 选第一名，也就是测过的里面最快的。没有 5 MB/s 的就用 4.9 的，这本身就是兜底
4. 只有连第一名都低于 `MIN_SPEED`，或速度为 0（测速地址挂了）时，才放弃本次更新、保留现有解析，并发送失败简报

**为什么要分段：** 在国内，延迟最低的 CF IP 往往走的是香港等近距离线路，晚高峰拥堵严重，经常握手很快、下载却几乎为 0；延迟较高的（比如 170ms 左右走美国的）反而带宽充裕。不分段时只会测到延迟最低的那一批，全部落在拥堵线路上。分段后两条线路都有候选，高峰期自然选到快的那条，闲时如果近线路更快也能选到它。界限请按你实测的两条线路延迟来定，日志和简报里会标出每个 IP 属于哪一段。

> 不建议使用 cfst 的 `-sl`（下载速度下限）。它会在全部候选（可能上千个）里逐个测，直到凑够 `-dn` 个达标的为止，高峰期可能要几十分钟；而且一个都不达标时 cfst 不输出任何结果，没有兜底。

### 3. 配合 sing-box TUN

测速必须直连，否则测出来的是代理线路的速度。服务以专用用户 `cfst-ddns`（默认 UID 950）运行，在 sing-box 的 tun inbound 中排除它：

```json
{
  "type": "tun",
  "auto_route": true,
  "exclude_uid": [950]
}
```

排除是按用户生效的，所以这个用户发出的 Cloudflare API 和 Telegram 请求也会绕过 TUN。这会带来两个问题：

- 如果 `/etc/resolv.conf` 指向 sing-box 的 fakeip DNS，解析出的 `198.18.x.x` 出了 TUN 就连不上，表现为 `curl: (28) Connection timed out`
- `api.telegram.org` 在国内直连不通

解决办法是给 sing-box 加一个只监听本机的 mixed inbound，再在 env 里设置 `API_PROXY`。用 `socks5h://` 可以让域名也交给代理来解析：

```json
{
  "type": "mixed",
  "tag": "mixed-in",
  "listen": "127.0.0.1",
  "listen_port": 2080
}
```

```bash
API_PROXY=socks5h://127.0.0.1:2080
```

这样 cfst 走直连，API 和 Telegram 请求走 sing-box 的路由规则。

### 4. Telegram 简报

两项都填才会发送。拿到 chat id 的方法：先给 bot 发一条消息，然后打开 `https://api.telegram.org/bot<TOKEN>/getUpdates`，找到其中的 `chat.id`。

简报使用 MarkdownV2 格式，内容包括结果（已更新 / 无变化 / 失败及原因）、域名、新旧 IP、延迟 / 丢包 / 速度、前 5 名、主机名和用时。Telegram 发送失败只会在日志里记一条警告，不影响 DNS 更新的结果。

## 启用

`systemctl start` 会立即返回，测速在后台进行，进度通过日志查看：

```bash
sudo systemctl start cfst-ddns.service          # 先手动跑一次
journalctl -fu cfst-ddns --output cat           # 跟踪日志，Ctrl+C 退出
sudo systemctl enable --now cfst-ddns.timer     # 没问题再启用定时
```

正常输出示例：

```
第 1 步 延迟测速: cfst -tl 250 -dt 5 -dd
  [15s] 延迟测速：已测 881/5955 个 IP，延迟合格 292 个
  ...
  延迟合格 1696 个：<150ms 段 420 个，≥150ms 段 1276 个
第 2 步 下载测速: 每段取 5 个，共 10 个候选
  [120s] 下载测速：已测 3/10 个 IP
  ...
测速完成，用时 165s
前几名（IP / 延迟ms / 丢包 / 下载MB/s）：
  104.18.x.x         183.87   0.00     9.78  ≥150ms
  ...
  104.17.x.x          88.85   0.00     0.14  <150ms
最快: 104.18.x.x  延迟 183.87ms（≥150ms 段）  丢包 0.00  下载 9.78MB/s
查询当前解析: cf.example.com (A)，经代理 socks5h://127.0.0.1:2080
已更新 cf.example.com (A): 1.2.3.4 -> 104.19.x.x
已发送 Telegram 简报
```

cfst 的原始输出保存在 `/var/lib/cfst-ddns/cfst.log`。

## 日常运维

```bash
systemctl list-timers cfst-ddns.timer     # 下次运行时间
systemctl status cfst-ddns.service        # 上次运行结果
journalctl -fu cfst-ddns --output cat     # 实时日志
sudo systemctl start cfst-ddns.service    # 立即运行一次
```

修改运行间隔（不改原文件）：

```bash
sudo systemctl edit cfst-ddns.timer
```

```ini
[Timer]
OnUnitActiveSec=
OnUnitActiveSec=2h
```

## 排错

| 现象 | 可能原因 |
|---|---|
| `curl: (28) Connection timed out` | API 请求被排除在 TUN 外但连不上，见上文配置 `API_PROXY` |
| `curl: (6) Could not resolve host` | 排除后的 DNS 不可用，检查 `/etc/resolv.conf`，或配置 `API_PROXY` 使用 `socks5h://` |
| 测速很慢、延迟合格数一直接近 0 | 测速流量仍然经过了代理，检查 `exclude_uid` 和 UID 是否一致，并确认已重启 sing-box |
| 下载速度全部为 0 | 默认测速地址不可用，用 `-url` 换成自己挂在 CF 后面的文件 |
| `Telegram 发送失败` | 通常是直连不通，配置 `API_PROXY` |

## 流量消耗

每轮下载测速约消耗 `-dn × -dt × 下载速度`。例如 200 Mbps 线路、`-dn 3 -dt 5`，每轮约几百 MB，按每小时一次算一天约 10 GB。想省流量可以拉长间隔，或在 `CFST_ARGS` 里加 `-dd` 只按延迟选。

## 卸载

```bash
sudo systemctl disable --now cfst-ddns.timer
sudo rm -f /etc/systemd/system/cfst-ddns.{service,timer}
sudo systemctl daemon-reload
sudo rm -rf /opt/cfst-ddns /var/lib/cfst-ddns /etc/cfst-ddns.env
sudo userdel cfst-ddns
```

别忘了把 sing-box 配置里的 `exclude_uid` 一并删掉。

## 致谢

- [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)
