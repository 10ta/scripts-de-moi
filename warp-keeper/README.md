# warp-keeper

给 sing-box 自动维护一个 Cloudflare WARP 出口：注册账户、生成 wireguard endpoint、每小时检查，不通就自愈。不需要 wireproxy、wg-quick，也不需要 wireguard-tools。

- **不占额外资源**：WARP 隧道就是 sing-box 自己的 wireguard endpoint（用户态），没有另外的常驻进程。检查由 systemd timer 每小时跑一次，跑完就退出
- **主配置不用改**：在 sing-box 的配置目录里放一个独立的片段文件，sing-box 启动时自动合并
- **兼容原来的 socks5 地址**：片段里带一个只监听 `127.0.0.1:18650` 的 mixed 入站，原来指向 wireproxy `socks5://127.0.0.1:18650` 的东西照常能用
- **逐级自愈**：探测不通 → 先排除 sing-box 没运行、本机断网 → 重载 sing-box → 换新账户。每一步改配置前都先 `sing-box check`，新配置不通就退回原来的
- **WARP+**：可以从公开频道自动取许可证，套不上就用免费账户
- **可观测**：Telegram 告警、恢复通知、每日日报；[Sonde](https://github.com/10ta/Sonde) 面板上每台机器一张卡片
- 依赖只有 `curl`、`jq`（加上 Debian 自带的 `iproute2`、`flock`）

## 工作原理

```
                       ┌──────────── sing-box（一个进程）─────────────────────────────┐
你的路由规则 ──────────▶│                                                               │
（outbound: 🧩 <WARP>） │   endpoint「🧩 <WARP>」(wireguard) ═══════▶ Cloudflare WARP   │
                       │        ▲                                                      │
127.0.0.1:18650 ──────▶│   mixed 入站 warp-keeper-in ── 规则：这个入站全部走 WARP      │
（socks5 / http）       └──────────────────────────────────────────────────────────────┘
        ▲
        │ 每小时经它访问 Cloudflare trace，看 warp=on / plus
warp-keeper.timer ──▶ warp-keeper check ──(不通)──▶ 重载 sing-box ──(还不通)──▶ 注册新账户 → 换片段 → 重载
```

### sing-box 怎么把片段合进来

官方 `.deb` 装的 sing-box 服务就是这样启动的：

```
/usr/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run
```

`-C` 表示读取这个目录里**所有** `.json` 文件，按文件名排序后合并：

- **数组拼接**：`inbounds`、`endpoints`、`route.rules` 等，排在前面的文件的元素在前
- **对象递归合并**；同一个字段两边都有值时，**排在前面的文件**的值生效

片段默认叫 `00-warp-keeper.json`，排在 `config.json` 前面，所以「探测入站 → WARP」这条规则在所有规则的最前面，不会被你的规则截走。它只匹配自己的入站，对其他流量没有影响。片段里没有 `log`、`dns`、`route.final` 这类单值字段，不会覆盖你的设置。

想看合并后的完整配置：

```bash
sing-box merge /tmp/merged.json -C /etc/sing-box && less /tmp/merged.json
```

> 如果你的 sing-box 是用 `-c config.json` 单文件启动的，`warp-keeper init` 会停下来，并打印改成 `-c ... -C /etc/sing-box` 的方法。这一步会影响整个 sing-box 服务（要重启一次，所有入站断开几秒），所以由你自己决定。

### 生成的片段

```jsonc
{
  "inbounds":  [{ "type": "mixed", "tag": "warp-keeper-in", "listen": "127.0.0.1", "listen_port": 18650 }],
  "endpoints": [{ "type": "wireguard", "tag": "🧩 <WARP>", "mtu": 1280,
                  "address": ["172.16.0.2/32", "2606:4700:110:…/128"], "private_key": "…",
                  "peers": [{ "address": "162.159.192.x", "port": 2408, "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
                              "allowed_ips": ["0.0.0.0/0", "::/0"], "persistent_keepalive_interval": 30,
                              "reserved": [151, 54, 152] }] }],
  "route": { "rules": [{ "inbound": ["warp-keeper-in"], "action": "route", "outbound": "🧩 <WARP>" }] }
}
```

- `reserved` 来自注册时分配的 `client_id`。部分地区不带它连不上 WARP，所以总是带上
- peer 地址直接用注册时分配的 IP，不依赖 sing-box 的 DNS 去解析 `engage.cloudflareclient.com`
- 不设 `listen_port`，WireGuard 本地 UDP 端口由系统随机分配，不会和别的端口冲突

## 文件

| 文件 | 安装位置 | 作用 |
|---|---|---|
| `install.sh` | — | 安装 / 升级程序和 systemd 单元，不碰配置、账户和 sing-box |
| `update.sh` | — | 一键更新（和仓库里其他工具同一套约定） |
| `warp-keeper.sh` | `/opt/warp-keeper/`，并链接为 `/usr/local/bin/warp-keeper` | 主脚本 |
| `warp-keeper.service` / `.timer` | `/etc/systemd/system/` | 开机 3 分钟后一次，之后每小时一次（随机延后 0~5 分钟） |
| `warp-keeper.env.example` | `/etc/warp-keeper.env` | 配置模板（首次安装时复制，之后不会覆盖） |

运行时数据在 `/var/lib/warp-keeper/`（权限 700）：`account.json`（设备 ID、令牌、私钥）、`state`（上次结果、换号次数等）、`checks.log`（近 8 天每次检查的结果和延迟，用来算可用率）、`fragment.prev`（上一版片段，回滚用）、`bad-keys`（试过不能用的 WARP+ 许可证）。

## 安装

需要：sing-box **1.11 以上**（wireguard endpoint 是 1.11 引入的），由 systemd 管理，启动参数里有 `-C 配置目录`。

```bash
git clone https://github.com/10ta/scripts-de-moi.git /opt/scripts-de-moi
cd /opt/scripts-de-moi/warp-keeper
sudo ./install.sh
sudo nano /etc/warp-keeper.env          # tag、端口、WARP+、Telegram、Sonde
```

如果是从 wireproxy 迁移过来，先看下一节，再继续：

```bash
sudo warp-keeper init                    # 注册 → 写片段 → sing-box check → 重载 → 验证
sudo warp-keeper status
sudo systemctl enable --now warp-keeper.timer
```

> ⚠️ **影响范围**：`init`、自动换号和片段有变化的更新都会**重载 sing-box**。sing-box 的重载是整体重建：**所有入站的现有连接都会断开一下**（客户端会自动重连），不只是 WARP。每小时的检查本身只读不写，只有确认不通时才会重载。

### 从 fscarmen 脚本的 wireproxy 迁移

原来的做法是：fscarmen 的 `menu.sh` 装了 wireproxy（监听 `127.0.0.1:18650` 的 socks5），sing-box 里再手动填一个 wireguard endpoint，或者用 socks 出站指向 18650。

1. **停掉 wireproxy**，把 18650 让出来：

   ```bash
   systemctl disable --now wireproxy
   ```

   以后不用 fscarmen 的脚本了，可以再运行 `warp u` 把它装的东西都清掉。注意：这会注销它注册的 WARP 账户、删除 `/usr/bin/warp`，还会重启 systemd-resolved。

2. **处理主配置里旧的 WARP**（改文件，**先别重启 sing-box**）。按你现在的写法选一种：

   - **主配置里有一个 tag 是「🧩 <WARP>」的 wireguard endpoint**：删掉这个 endpoint。规则不用改，warp-keeper 的片段会提供同名的 endpoint。
   - **规则指向一个 socks 出站（`127.0.0.1:18650`）**：
     - 最省事：**什么都不改**。片段里的 mixed 入站就在 18650 上，那个 socks 出站会连到它，再进 WARP。缺点是流量在 sing-box 里多绕一圈（同一个进程内，开销很小）。
     - 更干净：删掉那个 socks 出站，把规则里的出站名改成 `WARP_TAG`（或者把 `WARP_TAG` 设成原来 socks 出站的 tag，规则就不用改了）。

3. `warp-keeper init`。它会先 `sing-box check` 合并后的整套配置，不通过就恢复原样并打印错误（最常见的是 tag 重名：主配置里旧的那个还没删）。

## 自愈逻辑

每小时一次 `warp-keeper check`：

| 情况 | 怎么判断 | 处理 |
|---|---|---|
| 正常 | 经 `127.0.0.1:18650` 访问 `1.1.1.1` / `[2606:4700:4700::1111]` 的 `/cdn-cgi/trace`，每个栈都是 `warp=on` 或 `plus`（不通的话 5 秒后再试一次） | 无。免费账户且开了 WARP+ 时，每天试一次套许可证（不用重载） |
| sing-box 没运行 | `systemctl is-active` | 不处理，只告警（重启 sing-box 不是 warp-keeper 该做的事） |
| 片段被删了 | 18650 没在监听，片段文件不在 | 用现有账户重新生成，check 通过后重载 |
| 本机断网 | 直连 `1.1.1.1` 也不通 | 不处理，只告警 |
| 流量没走 WARP | trace 显示 `warp=off` | 不处理：说明路由没把探测入站送进 WARP，换号没用，提示你看合并后的规则 |
| WARP 不通 | 以上都不是 | ① 账户还在：重载 sing-box，再探测 ② 还不通（或账户已被 Cloudflare 删除）：注册新账户 → 写片段 → check → 重载 → 探测；新账户也不通就**退回原来的片段**，注销新账户 |

- 两次自动换号至少隔 `RENEW_MIN_GAP`（默认 6 小时），避免网络抖动时反复注册；原账户已被删除时不受这个限制。急的话手动 `warp-keeper renew`
- 换号成功后注销旧设备，Cloudflare 那边不会越积越多
- 同一时间只跑一个（`flock`），手动命令和 timer 撞上时手动的会等

探测的目标直接写 IP，不依赖 DNS；延迟取「TLS 握手完成 → 收到第一个字节」，约等于经 WARP 的一个往返。

## WARP+

`WARP_PLUS` 三种写法：

| 值 | 行为 |
|---|---|
| `auto`（模板默认） | 从 `WARP_PLUS_CHANNEL`（默认 [t.me/s/warpplus](https://t.me/s/warpplus) 的网页版）抓最新的许可证，从新到旧逐个试，最多 10 个，套上为止。试过不行的记下来，下次跳过 |
| 许可证本身 | 只用你给的（多个用空格隔开） |
| `off` | 只用免费账户 |

- 注册新账户时、`init` 时会试；免费账户每天再试一次。套许可证不换密钥，不用重载 sing-box，下一次握手后生效
- 公开频道的许可证是很多人共用的，随时可能设备数满或失效。套不上不影响正常工作，继续用免费账户
- 手动套一个：`warp-keeper plus xxxxxxxx-xxxxxxxx-xxxxxxxx`

## 通知

**Telegram**（`TG_BOT_TOKEN` + `TG_CHAT_ID`，可以和 traffic-bot、cfst-ddns 用同一个 bot）。每个栈一行：状态、出口机房和国家、延迟、**WARP 出口 IP**（等宽显示，点一下就能复制）。出口 IP 是 Cloudflare 分配的地址，不是本机的；除此之外和仓库里其他工具一样，消息里不会出现本机 IP、域名、网址。

| `TG_NOTIFY` | 什么时候发 |
|---|---|
| `change`（默认） | 出问题、做了自愈动作（重载 / 换号 / 重新生成片段 / 升级 WARP+）、恢复；故障一直没好时每 `TG_REPEAT_HOURS` 小时提醒一次 |
| `all` | 每次检查都发 |
| `off` | 不发 |

另外每天 `TG_SUMMARY_HOUR` 点后的第一次检查发一条**日报**：每个栈的出口和延迟、24 小时 / 7 天可用率、24 小时平均延迟、账户类型和使用天数、换号和重载次数。留空不发。

**Sonde**：填上 `SONDE_URL`、`SONDE_TOKEN`，每次检查后上报。来源名是 `warp-keeper:<WARP_NAME>`（小写）；面板把所有机器汇总在**同一张** WARP 卡片里，每台一行。上报周期 1 小时，两小时没动静那一行就标离线。Sonde 页面是公开的，所以上报里**不带出口 IP**，只有机房代码和国家。

## 命令

```bash
warp-keeper init        # 注册（已有账户就沿用）→ 写片段 → check → 重载 → 验证；改了 env 后也用它（片段没变就不重载）
warp-keeper check       # 健康检查 + 自愈（timer 调用的就是它）
warp-keeper status      # 当前状态，会实测一次，不改任何东西
warp-keeper renew       # 立即换新账户（想换个出口 IP 时）
warp-keeper plus [KEY]  # 套 WARP+ 许可证
warp-keeper sync        # 按当前版本和 env 重新生成片段，有变化才重载（update.sh 调用）
warp-keeper remove      # 删片段 → check → 重载 → 注销账户；主配置还在引用 tag 时会拒绝
```

日志：`journalctl -u warp-keeper --output cat`

## 更新

```bash
cd /opt/scripts-de-moi
git am -3 *.patch && rm *.patch && git push && ./update.sh
```

根目录的 `update.sh` 会更新本机装了的所有工具；只更新这一个：`sudo ./warp-keeper/update.sh`。它会重新安装程序和单元，然后运行 `warp-keeper sync`：新版本生成的片段和现在的一样就什么都不做；不一样时 check → 重载 → 探测，不通就退回原来的片段。`--status` 只看版本和上次检查的结果。

## 卸载

```bash
# 先把主配置里引用「🧩 <WARP>」的规则改掉（否则 remove 会拒绝），然后：
warp-keeper remove
systemctl disable --now warp-keeper.timer
rm -f /etc/systemd/system/warp-keeper.{service,timer} /usr/local/bin/warp-keeper
rm -rf /opt/warp-keeper /var/lib/warp-keeper /etc/warp-keeper.env
systemctl daemon-reload
```

## 注意事项

- **注册接口有频率限制。** 同一个 IP 短时间内注册太多次会被拒绝（HTTP 429）。所以自动换号有最小间隔；注册失败时保持原配置，下一小时再试，并在 Telegram 里写明原因。
- **Cloudflare 的注册接口没有公开文档。** 请求格式参照 [wgcf](https://github.com/ViRb3/wgcf) 和 fscarmen 的脚本；`WARP_API`、`WARP_UA`、`WARP_CLIENT_VER` 可以在 env 里覆盖，接口变动时不用等脚本更新。
- **账户文件里有私钥和令牌**，在 `/var/lib/warp-keeper/account.json`（权限 600）。片段文件里也有私钥，权限同样是 600。
- **出口 IP 是 Cloudflare 分配的**，换号后通常会变；`warp-keeper renew` 可以手动换。
