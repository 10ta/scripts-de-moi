# cfst-ddns

在本地 Debian 上用 [CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)（cfst）找出最好的 CDN 节点 IP（Cloudflare，也支持 CloudFront、Fastly 等；可按下载速度、上传速度或延迟来选），并通过 Cloudflare DNS API 把它更新到自己域名的记录上，可通过 Telegram 发送简报。

- 多个 CDN：`TARGETS` 里每个目标各自测速、各自更新一条记录；CloudFront、Fastly 内置官方 IP 列表来源
- 种子：可以把公共优选域名、优选 IP 网页里的 IP 当作补充候选，和官方扫描一起在你的线路上重测，并统计谁更好
- 三级流程：平时只**巡检**当前 IP，变差了才**复测榜单**，榜单都不行才**全量扫描**；全量每天只在晚高峰前做一次
- 按时段调度：晚高峰巡检更密，其余时间稀疏；时间表、时区都在 env 里配置
- 切换门槛：新 IP 明显更好才换，不在差不多的 IP 之间来回跳
- 可按下载速度、上传速度或纯延迟选 IP；可按延迟分段比较两条线路；可设速度容差兼顾延迟
- 由 systemd timer 调度，没有常驻进程，单次运行有超时保护
- 以固定 UID 的专用用户运行，方便在 sing-box TUN 里用 `exclude_uid` 让测速流量直连
- 没测出结果、速度为 0 / 不达标、API 报错时，一律不动现有解析
- 依赖只有 `curl`、`jq`（和 Debian 自带的 `flock`）

## 工作原理

```
cfst-ddns.timer（每 5 分钟）──▶ cfst-ddns@auto ──▶ 按时间表决定做哪一级，没到时间就直接退出
                                                    │
     ┌──────────────────────────────────────────────┘
     ▼
  到了 FULL_AT ───────────────────────────────────────────▶ ③ 全量扫描
  到了巡检间隔 ─▶ ① 巡检当前 IP ─(变差)─▶ ② 复测榜单 ─(全不达标)─▶ ③ 全量扫描
                      │                       │                      │
                    健康 → 结束       选最好的 → 过切换门槛才换 DNS    重建榜单 → 选最好的
```

IPv4 写 A 记录，IPv6 写 AAAA 记录。记录会被设为 **DNS only（灰云）**，TTL 默认 60。

## 联网与域名

| 谁 | 连哪里 | 需要解析域名吗 | 应该怎么走 |
|---|---|---|---|
| cfst 延迟测速 | CF IP 的 443 端口：全量约 6000 个，巡检/复测只有几个到几十个 | 不需要，直接连 IP | **必须直连** |
| cfst 下载测速 | 被测的 CF IP，`-url` 的域名（默认 `cf.xiu2.xyz`）只用作 SNI/Host | 不需要 | **必须直连** |
| curl 上传测速 | 被测的 CF IP，`UPLOAD_URL` 的域名通过 `--resolve` 钉到该 IP 上 | 不需要 | **必须直连** |
| curl | `api.cloudflare.com` | 需要 | 直连或代理均可 |
| curl | `api.telegram.org`（仅在配置了 TG 时） | 需要 | 国内需要代理 |
| curl | CDN 官方 IP 列表（如 `d7uri8nf7uskq.cloudfront.net`，每天最多一次） | 需要 | 走 `API_PROXY`，没设就直连 |

## 文件

| 文件 | 安装位置 | 作用 |
|---|---|---|
| `install.sh` | — | 安装 / 升级：创建用户，安装脚本和 systemd 单元；首次安装时下载 cfst |
| `cfst-ddns.sh` | `/opt/cfst-ddns/` | 主脚本：调度 + 测速 + 更新 DNS + 发送简报 |
| `cfst-ddns@.service` | `/etc/systemd/system/` | 服务模板，`%i` 是模式（auto / check / pool / full），沙箱化运行，最长 30 分钟 |
| `cfst-ddns.timer` | `/etc/systemd/system/` | 每 5 分钟触发一次 `cfst-ddns@auto` |
| `cfst-ddns.env.example` | `/etc/cfst-ddns.env` | 配置模板（首次安装时复制，之后不会覆盖） |

运行时数据在 `/var/lib/cfst-ddns/<目标>/`（如 `cloudflare/`、`cloudfront/`）：`pool.csv`（榜单）、`origin.map`（榜单里每个 IP 的来源）、`history.csv`（每轮官方/种子最佳，`stats` 用）、`state`（上次全量/巡检时间、当前 IP 的基准速度）、`cfst.log`（cfst 原始输出）、`iplist.txt`（从官方地址下载的 IP 列表，仅 CloudFront 等）。旧版放在根目录的状态文件会自动挪进 `cloudflare/`。

## 安装

```bash
git clone https://github.com/10ta/scripts-de-moi.git
cd scripts-de-moi/cfst-ddns
sudo ./install.sh
```

可选环境变量：

- `GH_PROXY=https://你的反代前缀/`：GitHub 下载慢时使用
- `CFST_UID=951`：默认 UID 950 被占用时指定其他值

升级时 `git pull` 后重新执行 `sudo ./install.sh` 即可，几秒完成：
- cfst 已经装过就不会重新下载；想顺便升级 cfst 用 `sudo UPDATE_CFST=1 ./install.sh`
- 已有的 `/etc/cfst-ddns.env` 不会被覆盖，旧版的 `cfst-ddns.service` 会被自动清理
- 新增的配置项都有默认值，不补也能跑。查看 env 里还缺哪些（bash 和 fish 都能用）：

```bash
bash -c "comm -23 <(grep -oE '^#?[A-Z_]+=' cfst-ddns.env.example | tr -d '#' | sort -u) <(grep -oE '^[A-Z_]+=' /etc/cfst-ddns.env | sort -u)"
```

日志第一行的 `cfst-ddns <版本号>` 可以确认跑的是不是新版。

## 配置

### 1. Cloudflare API Token

My Profile → API Tokens → Create Token → 使用 **Edit zone DNS** 模板，Zone Resources **只选这一个域名**。

> ⚠️ 不要用 Global API Key：它能操作整个账号，泄露后影响范围远超这一条记录。

### 2. 编辑 `/etc/cfst-ddns.env`

**基本**

| 变量 | 必填 | 默认值 | 说明 |
|---|---|---|---|
| `CF_API_TOKEN` | ✓ | | 上一步创建的 Token |
| `CF_ZONE_ID` | ✓ | | 域名 Overview 页右下角 |
| `CF_RECORD_NAME` | ✓ | | Cloudflare 优选 IP 写到这条记录，如 `cf.example.com` |
| `CF_TTL` | | `60` | 秒 |
| `TARGETS` | | `cloudflare` | 要优选哪些 CDN，空格分隔，如 `"cloudflare cloudfront"`，见「5. CloudFront 和其他 CDN」 |

> ⚠️ `CF_RECORD_NAME` 请用一个**专用子域名**。脚本会反复覆盖它的 IP，并强制设为灰云，不要指向其他服务正在使用的记录。

**调度**（见下方「调度」）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `TIMEZONE` | `Asia/Taipei` | 下面所有时间按这个时区算，日志和简报里的时间也用它 |
| `FULL_AT` | `18:30` | 每天几点全量扫描，可写多个，空格分隔，如 `"04:00 18:30"` |
| `PEAK_HOURS` | `19-24` | 晚高峰 [开始, 结束)，跨午夜写 `22-2`，留空 = 不区分 |
| `PEAK_EVERY` | `30` | 晚高峰巡检间隔（分钟） |
| `OFFPEAK_EVERY` | `120` | 其余时间巡检间隔（分钟） |
| `HEALTH_RATIO` | `70` | 健康标准 %：当前 IP 速度 ≥ 基准 × 这个比例 |
| `SWITCH_MARGIN` | `20` | 切换门槛 %：新 IP 至少快这么多才换 |
| `FULL_MIN_GAP` | `120` | 距上次全量不到这么多分钟，就不因榜单不达标而补扫 |

**测速**（见下方「选 IP 的规则」）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `RANK_BY` | `download` | `download` 下载速度 / `upload` 上传速度 / `latency` 只看延迟和丢包 |
| `LATENCY_SPLIT` | `0`（模板里是 `150`） | 分段界限 ms，`0` 为不分段 |
| `PICK_PER_GROUP` | `5` | 榜单大小：每段取几个（不分段时就是总数） |
| `MIN_SPEED` | `0`（模板里是 `1`） | 速度底线 MB/s |
| `SPEED_TOLERANCE` | `0` | 速度容差 % |
| `UPLOAD_URL` | `https://speed.cloudflare.com/__up` | 上传测速地址，见下方「上传测速」 |
| `UP_SECONDS` | `5` | 每个 IP 上传测速几秒 |
| `SEEDS_DNS` | 空 | 种子：优选域名，空格分隔，见下方「种子」 |
| `SEEDS_URL` | 空 | 种子：网页或接口地址，空格分隔，抓取其中所有 IPv4 |
| `SEED_PICK_PER_GROUP` | `3` | 每段给种子留几个测速名额（和 `PICK_PER_GROUP` 分开算） |
| `SEED_ALLOW_OUTSIDE` | `0` | `1` = 不在官方网段的种子也保留，标「(段外)」 |
| `SEED_DOH` | `https://dns.alidns.com/resolve` | 解析种子域名用的 DoH，直连 |
| `CFST_ARGS` | `-tl 250` | cfst 参数，不要写 `-f` `-o` `-p` `-dn` |
| `CFST_IPFILE` | `/opt/cfst-ddns/ip.txt` | 测 IPv6 时改为 `ipv6.txt` |
| `PROGRESS_EVERY` | `15` | 测速期间每隔多少秒往日志打一行进度 |

**网络与简报**

| 变量 | 默认值 | 说明 |
|---|---|---|
| `API_PROXY` | 空（直连） | API 请求使用的代理，如 `socks5h://127.0.0.1:2080` |
| `TG_BOT_TOKEN` / `TG_CHAT_ID` | | Telegram bot token 和接收简报的 chat id |
| `TG_NOTIFY` | `all` | `all` 每次都发；`change` 仅 IP 变化或失败时发；`off` 不发 |
| `TG_NOTIFY_CHECK` | `off` | 巡检结果正常时要不要也发一条 |

常用 cfst 参数：`-tl` 平均延迟上限（ms），`-tlr` 丢包率上限，`-n` 延迟测速并发数（默认 200，调小发包更平缓），`-dt` 单个下载测速时长（秒），`-url` 自定义下载测速地址。完整说明见 [cfst 文档](https://github.com/XIU2/CloudflareSpeedTest)。

### 调度

| 级别 | 做什么 | 开销 | 什么时候做 |
|---|---|---|---|
| ① 巡检 | 只测当前解析的 IP：延迟 + 一次测速 | 几个包 + 一次测速的流量 | 晚高峰每 `PEAK_EVERY` 分钟，其余时间每 `OFFPEAK_EVERY` 分钟 |
| ② 复测榜单 | 榜单里的 IP（加上当前 IP）重测延迟和速度，选最好的 | 榜单大小 × 一次测速 | 巡检发现当前 IP 变差时 |
| ③ 全量扫描 | 测约 6000 个 IP 的延迟，重建榜单，再测速选最好的 | 约 2.4 万次 TCP 握手 + 一轮测速 | 每天 `FULL_AT`；还没有榜单时；榜单全不达标时（受 `FULL_MIN_GAP` 限制） |

- **健康**：当前 IP 速度 ≥ 基准 × `HEALTH_RATIO`%，且不低于 `MIN_SPEED`。基准 = 它上次被选中或被确认留用时测到的速度。晚高峰整体变慢时，复测后如果还是留用它，基准会更新为当时的速度，所以不会每次巡检都触发复测
- **切换门槛**：复测/全量后，只有新的第一名比当前 IP 快 `SWITCH_MARGIN`% 以上，或当前 IP 已经不达标，才更新 DNS。设了 `SPEED_TOLERANCE` 时，速度相当且延迟低 `SWITCH_MARGIN`% 以上也会切换
- **为什么这样分级**：哪些 IP 能连、延迟多少取决于路由，几天才变；拥堵则随时段变化。所以全量延迟扫描一天一次就够，频繁要看的只是「当前 IP 还行不行」。全量放在晚高峰前，进入高峰时榜单是新的；闲时上行/下行往往被自家宽带跑满，任何 IP 都差不多，也就没必要频繁重选
- 两轮之间不会重叠：上一轮还没跑完时，新触发的一轮会直接跳过

### 选 IP 的规则

1. **延迟测速**：cfst 先测出所有能连通的 IP，脚本再按 `-tl`（延迟上限）、`-tll`（延迟下限）、`-tlr`（丢包率上限）筛选。日志会分别写出可连通多少、满足限制条件多少、种子各多少，以及当前 IP 本轮的实际延迟，能直接看出是连不上还是超出限制
   - 全量扫描时如果一个都不满足，就放宽为全部可连通的 IP 继续测速（简报里会注明「已放宽」）；巡检和复测榜单不放宽，直接升级到下一级
2. **挑候选**（全量扫描时，结果就是榜单）
   - **分段**（`LATENCY_SPLIT > 0`）：以该延迟为界分两段，每段取丢包最少、延迟最低的 `PICK_PER_GROUP` 个
   - **不分段**（`LATENCY_SPLIT = 0`）：取延迟最低的 `PICK_PER_GROUP` 个
3. **速度测速**（`RANK_BY=latency` 时跳过，直接按丢包、延迟排序）：`download` 用 cfst 下载测速，每个 `-dt` 秒；`upload` 用 curl 上传测速，每个 `UP_SECONDS` 秒。结果按速度排序
4. **选第一名**，也就是测过的里面最快的。没有 5 MB/s 的就用 4.9 的，这本身就是兜底
   - 设了 `SPEED_TOLERANCE`（%）时，在「速度 ≥ 最快 × (1 − 容差)」的 IP 里选延迟最低的
5. **和当前 IP 比较**：没过切换门槛就留用当前 IP（见上方「调度」）
6. **底线**：选中的低于 `MIN_SPEED` 或速度为 0 时，不动现有解析并发送失败简报

**为什么要分段：** 在国内，延迟最低的 CF IP 往往走香港等近距离线路，晚高峰拥堵严重，经常握手很快、下载却几乎为 0；延迟较高的（比如 170ms 左右走美国的）反而带宽充裕。不分段时只会测到延迟最低的那一批，全部落在拥堵线路上。分段后两条线路都有候选，谁快选谁。界限请按你实测的两条线路延迟来定，日志和简报里会标出每个 IP 属于哪一段。

**更在乎上传和延迟时**，例如往 CF 节点推流、上传文件、跑对上行敏感的代理：

```bash
RANK_BY=upload
LATENCY_SPLIT=150
PICK_PER_GROUP=5
SPEED_TOLERANCE=15          # 上传速度差不多时选延迟低的
MIN_SPEED=1
CFST_ARGS="-tl 250 -tlr 0"  # 有丢包的直接淘汰
```

只在乎延迟、不在乎带宽（例如游戏、SSH）：`RANK_BY=latency`，配合 `-tlr 0`。

> 不建议使用 cfst 的 `-sl`（下载速度下限）。它会在全部候选里逐个测，直到凑够要求的数量为止，高峰期可能要几十分钟；而且一个都不达标时 cfst 不输出任何结果，没有兜底。速度底线请用 `MIN_SPEED`。

### 种子（第三方优选来源）

全量扫描是自己在几千个 IP 里一个个试；公共优选域名（如 `cf.090227.xyz`）和优选 IP 网页（如 wetest）是别人已经在国内三网试过、挑出来的几十个 IP。这些就是「种子」。

种子只是**补充候选**，不照搬别人的排名：别人测的是他们的探针，主要按延迟排（往往偏向香港、东京这些晚高峰容易拥堵的机房），测速也限在 5 MB/s。脚本把种子和官方扫描出来的 IP 放在一起，在你的线路上重新测延迟、测速，谁快用谁。

```bash
SEEDS_DNS="cf.090227.xyz cloudflare.182682.xyz bestcf.top"
SEEDS_URL="https://www.wetest.vip/page/cloudflare/address_v4.html https://www.wetest.vip/page/cloudflare/total_v4.html"
CLOUDFRONT_SEEDS_DNS="cloudfront.182682.xyz"
CLOUDFRONT_SEEDS_URL="https://www.wetest.vip/page/cloudfront/address_v4.html https://www.wetest.vip/page/cloudfront/total_v4.html"
```

- **采集**：复测榜单和全量扫描时现采（每次都是最新的），巡检不用。域名用 `SEED_DOH`（默认阿里 DoH）直连解析，避开 sing-box 的 fakeip，拿到的是你所在运营商那条线路的结果；网页抓取返回内容里所有的 IPv4
- **校验**：只保留落在该 CDN 官方网段内的 IP。公共域名可能被劫持、污染，混进来的别的 IP 直接丢弃，日志里会写丢了几个。网段外的多半是第三方「反代 IP」（别人的服务器转发到 CDN），设 `SEED_ALLOW_OUTSIDE=1` 可以保留，来源会标「(段外)」；代价是流量先经过一个陌生人的服务器（看不到 TLS 内容，但看得到你连的域名和流量大小），也随时可能下线
- **参赛**：每段给种子单独留 `SEED_PICK_PER_GROUP` 个测速名额，和官方的 `PICK_PER_GROUP` 分开算，保证每轮两边都有 IP 参加测速。当前 IP 另外加入，不占名额
- **记来源**：每个 IP 第一次进榜单时记下它是「官方」还是「种子:哪个来源」，之后一直沿用（种子源不再返回它也不变）。日志结果表、简报都会标出来源，并给出本轮「官方最佳 vs 种子最佳」

跑几天后看汇总（分晚高峰 / 非高峰）：

```bash
sudo /opt/cfst-ddns/cfst-ddns.sh stats        # 最近 7 天
sudo /opt/cfst-ddns/cfst-ddns.sh stats:30     # 最近 30 天
```

```
========== cloudflare：最近 7 天 ==========
【晚高峰】测速 12 轮，最终选中种子 IP 3 轮
  官方扫描最佳：平均 6.10 MB/s（12 轮有结果）
  种子最佳：    平均 5.20 MB/s（12 轮有结果）
  同一轮里比较 12 次：种子更好 4 次，官方更好或持平 8 次
    种子胜出来源 cf.090227.xyz：3 次
```

> 比较时要注意名额：官方每段 `PICK_PER_GROUP` 个、种子每段 `SEED_PICK_PER_GROUP` 个，名额多的一方天然更容易测出高分。想比得公平，可以临时把两者设成一样。

**hostmonit**：它的页面是 JS 渲染的，IP 不在网页源码里，直接把页面地址放进 `SEEDS_URL` 抓不到。需要在浏览器开发者工具的 Network 里找到它取数据的接口，确认是 GET 还是 POST 后再接入。

### 上传测速

cfst 只能测下载，上传测速由脚本用 curl 完成：对每个候选 IP，用 `--resolve` 把 `UPLOAD_URL` 的域名钉到这个 IP 上，直连 POST 一个 64 MB 的空文件（稀疏文件，不占磁盘），`UP_SECONDS` 秒后断开，按实际发送的字节数和传输时间（不含握手）算速度。服务器返回非 2xx、提前结束连接、连不上，都记为失败，速度算 0。全部失败时放弃本次更新并在简报里写明原因。

默认的 `https://speed.cloudflare.com/__up` 是 Cloudflare 自己测速页用的接口，不保证一直可用、也不保证所有 CF IP 都能访问到它。日志里如果大面积出现 `服务器返回 HTTP 4xx` 或 `服务器中途断开`，就换成自建的 Worker：

```js
// Workers & Pages → Create → Hello World → 替换成下面的代码 → Deploy
// 再在 Settings → Domains & Routes 绑一个自己的域名（如 up.example.com），然后
// UPLOAD_URL=https://up.example.com/
export default {
  async fetch(request) {
    if (request.method === "POST" && request.body) {
      const reader = request.body.getReader();   // 边收边丢，不占内存
      while (!(await reader.read()).done) {}
    }
    return new Response("ok");
  },
};
```

> Worker 免费计划每天 10 万次请求，这里每轮十来次，够用。免费计划对单次请求的 CPU 时间有限制，如果自建 Worker 也频繁出现 `服务器中途断开`，可以把 `UP_SECONDS` 调小一些。

测量误差：上传速度是在客户端统计的，刚开始会有一部分数据先进系统发送缓冲区，所以结果会略偏高，延迟越高偏得越多（几个百分点）。`UP_SECONDS` 越长误差越小。

**和浏览器里的 speed.cloudflare.com 对不上？** 浏览器测的是另一条路：域名按正常 DNS 解析（不是你的优选 IP），流量经过路由器和旁路由，可能还按规则走了代理。可以在那台设备上打开 `https://speed.cloudflare.com/cdn-cgi/trace`，看 `ip=` 是不是你家的出口 IP、`colo=` 是哪个机房。要验证脚本的数字，在 Debian 上用同一个用户把 64 MB 完整传完、由服务器确认：

```bash
sudo -u cfst-ddns bash -c 'truncate -s 64M /tmp/up.bin; curl -sS --noproxy "*" -o /dev/null -H "Expect:" -w "HTTP %{http_code}  传完 %{size_upload} 字节用了 %{time_total}s\n" --resolve speed.cloudflare.com:443:你的优选IP -X POST -T /tmp/up.bin https://speed.cloudflare.com/__up; rm /tmp/up.bin'
```

### 3. 配合 sing-box TUN

测速（包括上传测速）必须直连，否则测出来的是代理线路的速度。服务以专用用户 `cfst-ddns`（默认 UID 950）运行，在 sing-box 的 tun inbound 中排除它：

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

这样测速走直连，API 和 Telegram 请求走 sing-box 的路由规则。

### 4. Telegram 简报

两项都填才会发送。拿到 chat id 的方法：先给 bot 发一条消息，然后打开 `https://api.telegram.org/bot<TOKEN>/getUpdates`，找到其中的 `chat.id`。

简报使用 MarkdownV2 格式，内容包括结果（已更新 / 无变化 / 巡检正常 / 失败及原因）、流程（如「巡检 → 复测榜单」）、域名、新旧 IP、为什么换或不换、延迟 / 丢包 / 速度、前 5 名、主机名和时间。

- 巡检结果正常时默认不发（`TG_NOTIFY_CHECK=off`），否则晚高峰每 30 分钟就有一条；巡检发现变差、换 IP、失败时照常发
- `TG_NOTIFY=change` 时只在 IP 变化或失败时发，优先于 `TG_NOTIFY_CHECK`
- Telegram 发送失败只会在日志里记一条警告，不影响 DNS 更新的结果

### 5. CloudFront 和其他 CDN

在 `TARGETS` 里加上 `cloudfront`，再配两项就能用：

```bash
TARGETS="cloudflare cloudfront"
CLOUDFRONT_RECORD_NAME=cfr.example.com
CLOUDFRONT_CFST_ARGS="-tl 300 -dt 5 -url https://xxxx.cloudfront.net/cfst/50mb.bin"
```

每个目标走的流程和 Cloudflare 完全一样（三级调度、分段、底线、切换门槛、简报），状态、榜单各自独立，简报标题会写明是哪个 CDN。

**配置规则：** `<前缀>_XXX` 覆盖全局的 `XXX`，例如 `CLOUDFRONT_PICK_PER_GROUP=3`、`CLOUDFRONT_OFFPEAK_EVERY=240`、`CLOUDFRONT_RANK_BY=latency`；没写的项沿用全局配置。下面这几项和具体 CDN 绑定，**不继承**全局，要单独写（或用内置预设）：`RECORD_NAME`、`CFST_ARGS`、`UPLOAD_URL`、`IPFILE`、`IPLIST_URL`、`IPLIST_JQ`、`IP_EXCLUDE`、`IP_SAMPLE`、`SEEDS_DNS`、`SEEDS_URL`、`RANK_BY`（不写默认 `download`）。

例如上下行分离：Cloudflare 走上行、CloudFront 走下行，就是全局 `RANK_BY=upload`、`CLOUDFRONT_RANK_BY=download`（后者不写也是 download），两边各测各的方向。DNS 记录默认写在同一个 `CF_ZONE_ID`，不同域名可以用 `CLOUDFRONT_ZONE_ID` 单独指定。

**CloudFront 内置了什么：**

| 项 | 内置值 | 说明 |
|---|---|---|
| IP 列表 | `https://d7uri8nf7uskq.cloudfront.net/tools/list-cloudfront-ips` 的 `CLOUDFRONT_GLOBAL_IP_LIST` | AWS 官方列表，只取边缘节点，不要 `REGIONAL_EDGE`（区域缓存层，不面向客户端）。每次全量扫描前检查，超过一天就重新下载；下载失败时沿用上次的列表 |
| 排除 | `52.82.`、`111.13.`、`120.52.` 等 11 个开头的网段 | 中国大陆节点（宁夏、北京及国内运营商的段）。海外账号的分发在这些节点上用不了，但它们延迟最低，不排除的话会占满榜单 |
| 抽样 | `IP_SAMPLE=4000` | 列表展开后约 1.6 万个 /24，是 Cloudflare 的近 3 倍。每次全量随机抽 4000 个测延迟（每天换一批），上一轮榜单里的 IP 总会一起测，所以之前找到的好 IP 不会丢 |

**测速文件（必填）：** cfst 默认的测速地址在 Cloudflare 上，CloudFront 节点不认，所以必须用 `-url` 指定一个**你自己分发上**的文件。cfst 会用这个域名做 SNI/Host 去连每个候选 IP，能下载就说明这个节点能服务你的分发。

- 在源站放一个文件，例如 `head -c 50M /dev/urandom > /你的站点目录/cfst/50mb.bin`
- 在 CloudFront 分发里给 `/cfst/*` 单独加一个行为，缓存策略用 `CachingOptimized`。这样每个节点只回源一次，之后测的都是「家 → CloudFront 节点」这一段，和 Cloudflare 的测法一致
- 文件大小就是单个 IP 每次测速流量的上限，建议 50 MB 左右

> ⚠️ **测速流量会计入你 AWS 账号的 CloudFront 用量。** 按默认时间表粗算：巡检每次 1 个文件（50 MB），复测榜单每次 `榜单大小 × 50 MB`，全量一轮测速同理，一天大约几 GB、一个月一两百 GB 量级，主要看晚高峰复测了几次。CloudFront 免费额度够用，但如果你有别的服务也在用这个账号的 CloudFront 流量，或者在监控它的用量，会看到这部分增长。不想耗流量可以用 `CLOUDFRONT_RANK_BY=latency` 只按延迟选（不需要 `-url`，也不产生下载流量）。

**IP 列表从哪来：** CloudFront 内置的列表来自 [XIU2/CloudflareSpeedTest#180](https://github.com/XIU2/CloudflareSpeedTest/issues/180) 里提到的 AWS 官方地址；那条讨论是几年前的，网段已经变了很多（现在是 118 段，其中 27 段在国内），所以脚本每天直接从官方地址拉最新的，不内置固定网段。

**其他 CDN：** Fastly 也内置了官方列表（`https://api.fastly.com/public-ip-list` 的 `addresses`），配法同上，前缀是 `FASTLY_`。没有内置的 CDN，起个名字加进 `TARGETS`，再给出 IP 来源即可：

```bash
TARGETS="cloudflare cloudfront gcore"
GCORE_LABEL=Gcore
GCORE_RECORD_NAME=gc.example.com
GCORE_IPLIST_URL=https://该CDN官方发布的IP列表地址
GCORE_IPLIST_JQ='.addresses[]'        # 列表是 JSON 时，用 jq 取出网段；是纯文本（一行一个网段）时留空
GCORE_CFST_ARGS="-tl 300 -dt 5 -url https://你在该CDN上的测速文件"
# 或者不下载，直接用本地文件：GCORE_IPFILE=/etc/cfst-ddns/gcore.txt（要放在服务能读的位置）
```

## 启用

`systemctl start` 会立即返回，测速在后台进行，进度通过日志查看：

```bash
sudo systemctl start cfst-ddns@full               # 先手动全量跑一次，建立榜单
journalctl -fu 'cfst-ddns@*' --output cat         # 跟踪日志，Ctrl+C 退出
sudo systemctl enable --now cfst-ddns.timer       # 没问题再启用定时
```

全量扫描输出示例：

```
10-20 18:30 非高峰，每 120 分钟巡检
当前解析: cf.example.com (A) = 104.18.x.x（API 经代理 socks5h://127.0.0.1:2080）
===== 全量扫描 =====
延迟测速（全部 IP）: cfst -tl 250 -dt 5 -dd
  [15s] 延迟测速：已测 881/5955 个 IP，可连通 292 个（限制条件最后统一筛）
  ...
  测了 6044 个 IP：可连通 1893 个（最低延迟 52ms），满足限制条件（延迟 ≤250ms）1696 个
  其中种子 78 个：可连通 70 个（最低延迟 61ms），满足限制条件 66 个
  参与挑选 1696 个（其中种子 66 个）：<150ms 段 420 个，≥150ms 段 1276 个
  新榜单 10 个 IP
下载测速: 11 个 IP
结果（IP / 延迟ms / 丢包 / 下载MB/s）：
  104.18.x.x         183.87   0.00     9.78  ≥150ms  ← 当前
  ...
选中: 104.18.x.x  延迟 183.87ms（≥150ms 段）  丢包 0.00  下载 9.78MB/s
说明: 当前 IP 就是第一名
解析保持 104.18.x.x，无需更新
```

晚高峰巡检发现变差、换 IP 的输出示例：

```
10-20 21:00 晚高峰（19-24），每 30 分钟巡检
===== 巡检 =====
巡检当前 IP: 104.17.x.x
变差：下载 0.30 MB/s，健康线 5.74 MB/s（基准 8.20 的 70%）
===== 复测榜单 =====
复测榜单: 10 个 IP（含当前 IP）
  ...
选中: 104.18.x.x  延迟 170ms（≥150ms 段）  丢包 0.00  下载 6.00MB/s
说明: 当前 IP 只有 0.30 MB/s，低于底线 1
已更新 cf.example.com (A): 104.17.x.x -> 104.18.x.x
```

上传模式每个 IP 测完就打印一行：

```
上传测速: 10 个 IP，每个 5s，地址 https://speed.cloudflare.com/__up
  [上传 1/10] 104.17.x.x          62.13ms <150ms 段  5.84 MB/s
  [上传 2/10] 104.17.x.x          65.40ms <150ms 段  失败：服务器返回 HTTP 403
```

## Sonde 面板（可选）

在 `/etc/cfst-ddns.env` 里填上 [Sonde](https://github.com/10ta/Sonde) 的 API 地址和上报密钥，之后每次真正测速后上报一次（IP 换成机房代码，种子不带域名），网页上就会出现这里的状态：

```bash
SONDE_URL=https://sonde-api.example.com
SONDE_TOKEN=<Sonde 的 .sonde.env 里的 INGEST_TOKEN>
```

上报内容和 Telegram 消息一样脱敏（不含 IP、域名、网址、实例 ID）；不填就不上报，上报失败只记一行日志，不影响本来的工作。

## 日常运维

模式后面加 `:目标` 只跑这一个目标，例如 `sudo systemctl start cfst-ddns@full:cloudfront`；不加就按 `TARGETS` 依次跑所有目标。

```bash
systemctl list-timers cfst-ddns.timer       # timer 是否在跑（每 5 分钟）
journalctl -fu 'cfst-ddns@*' --output cat   # 实时日志
sudo systemctl start cfst-ddns@check        # 立即巡检一次
sudo systemctl start cfst-ddns@pool         # 立即复测榜单
sudo systemctl start cfst-ddns@full         # 立即全量扫描
cat /var/lib/cfst-ddns/cloudflare/state     # 上次全量/巡检时间（Unix 时间戳）、当前 IP 的基准
```

改时间表：只改 `/etc/cfst-ddns.env` 里的 `FULL_AT` / `PEAK_HOURS` / `PEAK_EVERY` / `OFFPEAK_EVERY`，下一次触发就生效，不用重启任何东西。

timer 每 5 分钟会启动一次 `cfst-ddns@auto`，没到时间时几毫秒就退出，journal 里会留下 systemd 的启动/结束记录，这是正常的。

## 排错

| 现象 | 可能原因 |
|---|---|
| `curl: (28) Connection timed out` | API 请求被排除在 TUN 外但连不上，见上文配置 `API_PROXY` |
| `curl: (6) Could not resolve host` | 排除后的 DNS 不可用，检查 `/etc/resolv.conf`，或配置 `API_PROXY` 使用 `socks5h://` |
| 测速很慢、延迟合格数一直接近 0 | 测速流量仍然经过了代理，检查 `exclude_uid` 和 UID 是否一致，并确认已重启 sing-box |
| 下载速度全部为 0 | 默认测速地址不可用，用 `-url` 换成自己挂在 CF 后面的文件 |
| 上传测速大面积 `HTTP 4xx` / `服务器中途断开` | 默认上传地址不可用，换成自建 Worker，见「上传测速」 |
| 上传测速 `连接失败（curl 退出码 7）` | 连不上这些 IP，多半是上传流量没被 `exclude_uid` 放行 |
| `榜单里没有达标的 IP，且 … 刚做过全量扫描` | 高峰期整体都很差，低于 `MIN_SPEED`；保留现有解析，等下一轮。可适当调低 `MIN_SPEED` |
| `Telegram 发送失败` | 通常是直连不通，配置 `API_PROXY` |
| 时间表和预期差几个小时 | 检查 `TIMEZONE` |
| `种子 xxx：0 个` | 域名解析不到（DoH 连不上或域名已失效），或网页里没有 IP（比如页面是 JS 渲染的） |
| `… 个不在官方网段，已丢弃` | 种子源返回了不属于该 CDN 的 IP，正常的保护行为；如果某个来源长期大量被丢弃，换掉它 |
| `[CloudFront] 下载测速需要 … -url` | 非 Cloudflare 目标必须在 `<前缀>_CFST_ARGS` 里指定自己分发上的测速文件 |
| CloudFront 下载速度全部为 0 | `-url` 的文件访问不到（403/404），先在浏览器里确认能下载；或者分发的价格等级限制了部分地区节点 |
| 新增 CloudFront 记录时 API 报冲突 | 同名记录已经是 CNAME，换一个新的子域名 |

## 流量消耗

按默认时间表（晚高峰 5 小时每 30 分钟、其余每 2 小时巡检，每天 1 次全量），一天大约：

- 巡检约 20 次，每次只测 1 个 IP（一次测速的流量，约 `测速秒数 × 速度`）
- 复测榜单只在巡检发现变差时做，每次约 `榜单大小 × 测速秒数 × 速度`，主要集中在晚高峰
- 全量扫描 1 次：约 2.4 万次 TCP 握手 + 一轮榜单测速

例如上传模式、60 Mbps 上行、`UP_SECONDS=5`：巡检每次约 37 MB；榜单 10 个时复测一次约 370 MB。

## 卸载

```bash
sudo systemctl disable --now cfst-ddns.timer
sudo rm -f /etc/systemd/system/cfst-ddns.timer '/etc/systemd/system/cfst-ddns@.service'
sudo systemctl daemon-reload
sudo rm -rf /opt/cfst-ddns /var/lib/cfst-ddns /etc/cfst-ddns.env
sudo userdel cfst-ddns
```

别忘了把 sing-box 配置里的 `exclude_uid` 一并删掉。

## 致谢

- [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)
