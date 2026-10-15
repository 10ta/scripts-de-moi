# traffic-bot

一个 Telegram 机器人，汇总各家云服务的免费额度用量：

- **定时播报**：每隔一段时间把全部用量推送到 Telegram。
- **越线告警**：任何一项用量越过 80% / 95%，立即推送。

单文件 Python，由 systemd 托管。所有密钥只存在服务器上的 `/etc/traffic-bot.env`（权限 600）。

| 来源 | 显示内容 | 重置周期 |
|---|---|---|
| 🖥 搬瓦工 BWH | 流量已用 / 套餐总量、日均可用 | 按 VPS 自己的重置日 |
| ☁️ AWS Lightsail | 每台实例的流量（入+出）/ 套餐额度 | UTC 自然月 |
| 🌐 AWS CloudFront | 出流量 / 1TB，请求数 / 1000 万，月底预测 | UTC 自然月 |
| 💵 AWS 账单 | 本月预估总额、每个收费服务的金额，可设金额告警 | UTC 自然月 |
| ⚡ Cloudflare Workers & Pages | 今日请求 / 10 万，账期内请求数与 CPU 时间 | 每天 00:00 UTC |
| 🪣 Cloudflare R2 | 存储 / 10GB，Class A / 100 万，Class B / 1000 万 | 自然月 |
| 🗄 Cloudflare D1 | 今日读取行 / 500 万，写入行 / 10 万，存储 / 5GB，每个库的大小 / 500MB | 每天 00:00 UTC |
| 📈 Cloudflare CDN | 每个域名本月的请求数和流量（免费计划无上限，仅供参考） | 自然月 |
| 🔴 Oracle Cloud | 出站流量 / 10TB；可选：闲置回收检测 | UTC 自然月 |
| 🟧 阿里云 CDT | 流量 / 免费额度、熔断状态、本月费用（数据来自 [cdt-guard](../CDT-Management/)） | 北京时间自然月 |

> **Vercel 不支持。** Vercel 没有为任何套餐提供公开的用量接口；`/v1/billing/charges` 和 `vercel usage` 只返回账单金额，Hobby 账号没有费用，所以查不到数据。

---

## 目录

1. [准备凭据](#准备凭据)（逐个平台说明在哪里拿）
2. [安装](#安装)
3. [使用](#使用)
4. [配置项](#配置项)
5. [更新与维护](#更新与维护)
6. [常见问题](#常见问题)

---

## 准备凭据

除 Telegram 外，下面每一项都是**可选**的，不填的平台不显示。只有 AWS 例外，见 ③。

安装脚本会逐项询问。每一项都标出了**安装时要填的变量名**，建议先把值记在本地，不要发到任何聊天里。

### ① Telegram（必填）

**`BOT_TOKEN`**

1. 在 Telegram 里搜 **@BotFather**，发送 `/newbot`。
2. 按提示输入机器人的显示名称，再输入用户名（必须以 `bot` 结尾，例如 `my_traffic_bot`）。
3. BotFather 回复的消息里有一串 `123456789:AAH...` 格式的字符串，这就是 `BOT_TOKEN`。

**`ALLOWED_CHAT_IDS`**

只有这些 chat 能使用 bot、接收播报和告警。

1. 在 Telegram 里搜 **@userinfobot**，随便发一条消息。
2. 它回复的 `Id:` 后面那串数字就是你的 chat id。
3. 想推送到群组：先把 bot 拉进群，群组的 id 是负数（如 `-100xxxxxxxxxx`）。可以把 **@RawDataBot** 拉进群查看，查完踢掉。
4. 多个 id 用英文逗号分隔：`11111111,-1002222222222`。

最后，**先给你的 bot 发一条 `/start`**，否则 bot 没法主动给你发消息。

---

### ② 搬瓦工 BWH

**`BWH_API_KEY`、`BWH_VEID`**

1. 登录 [bandwagonhost.com](https://bandwagonhost.com/clientarea.php) → **Services → My Services**，在你的 VPS 那一行点 **KiwiVM Control Panel**。
2. 在 KiwiVM 左侧菜单里点 **API**。
3. 页面上：
   - **VEID**：一串数字，就是 `BWH_VEID`。
   - **API KEY**：如果是空的，点 **Generate new API key** 生成，复制下来就是 `BWH_API_KEY`。

> 重新生成 API Key 会让旧 Key 失效。如果别的脚本（例如面板、监控）也在用这个 Key，它们也要一起更新。

**`BWH_TOTAL_GB`**（可选，默认 `2000`）

套餐每月的流量总量，单位 GB。在 KiwiVM 主页的 **Bandwidth Usage** 可以看到，例如 `0 / 2000 GB`。

---

### ③ AWS Lightsail + CloudFront

**`AWS_ACCESS_KEY`、`AWS_SECRET_KEY`**

> Lightsail 和 CloudFront 两项**始终启用**。不用 AWS 的话，这两块会显示“查询失败”，不影响其他平台。

建议单独建一个**只读**的 IAM 用户。以后删掉这个用户，也不会影响你自己的账号和其他程序。

**第 1 步：建权限策略**

1. 登录 [AWS 控制台](https://console.aws.amazon.com/)，顶部搜索框输入 **IAM** 进入。
2. 左侧 **Policies → Create policy**，切到 **JSON** 标签，把内容整个替换为：

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "lightsail:GetInstances",
           "lightsail:GetInstanceMetricData",
           "cloudfront:ListDistributions",
           "cloudwatch:GetMetricStatistics",
           "cloudwatch:ListMetrics"
         ],
         "Resource": "*"
       }
     ]
   }
   ```

3. **Next**，策略名填 `traffic-bot-readonly`，点 **Create policy**。

**第 2 步：建用户并绑定策略**

1. 左侧 **Users → Create user**，用户名填 `traffic-bot`，**不要**勾选 “Provide user access to the AWS Management Console”。
2. **Next**，选 **Attach policies directly**，搜索并勾选 `traffic-bot-readonly`。
3. **Next → Create user**。

**第 3 步：生成 Access Key**

1. 在用户列表里点 `traffic-bot`，切到 **Security credentials** 标签。
2. 找到 **Access keys** 区块，点 **Create access key**。
3. Use case 选 **Application running outside AWS**，**Next → Create access key**。
4. 页面上显示的两个值：
   - **Access key**（`AKIA...` 开头）→ `AWS_ACCESS_KEY`
   - **Secret access key** → `AWS_SECRET_KEY`。**只显示这一次**，关掉页面就看不到了，丢了只能删掉重建。

**`LIGHTSAIL_REGION`**（可选，默认 `ap-northeast-1`，东京）

Lightsail 实例所在的区域。在 [Lightsail 控制台](https://lightsail.aws.amazon.com/) 的实例卡片上能看到位置，例如 “Tokyo, Zone A (ap-northeast-1a)”，去掉最后的字母 `a` 就是区域代码。不在东京的话，安装后到 `/etc/traffic-bot.env` 里取消这一行的注释并修改。

CloudFront 是全局服务，不需要填区域。

> bot 只调用 CloudWatch 的 `GetMetricStatistics` / `ListMetrics`，它们算在每月 100 万次免费 API 请求里。**不要**换成 `GetMetricData`：它不在免费范围内，按请求的指标数收费（每 1000 个 $0.01）。旧版本用的是它，每 10 分钟查一次，一个月会产生几美分账单。

**AWS 账单（开启一次即可）**

账单数据来自 CloudWatch 的账单指标，默认是关闭的，要用主账号（root）或有账单权限的用户开启一次：

1. 打开 [Billing and Cost Management 控制台](https://console.aws.amazon.com/costmanagement/)。
2. 左侧 **Billing preferences**（账单首选项）。
3. **Alert preferences**（提醒首选项）右边点 **Edit**。
4. 勾选 **Receive CloudWatch Billing Alerts**（接收 CloudWatch 账单提醒），点 **Save preferences**。
5. 约 15 分钟后开始有数据。这个选项开启后不能关闭，但它本身不收费。

账单显示的是本月税前预估，AWS 每天更新几次，所以会比控制台“账单”页面晚几个小时。不想看账单就把 `AWS_BILL` 设为 `0`。

---

### ④ Cloudflare（Workers & Pages、R2、D1、CDN）

**`CLOUDFLARE_ACCOUNT_ID`**

32 位十六进制字符串。任选一种方法：

- 登录 [Cloudflare 控制台](https://dash.cloudflare.com/)，进入 **Workers & Pages**，概览页右侧栏有 **Account ID**，点复制。
- 或者浏览器地址栏 `dash.cloudflare.com/` 后面那一段 32 位字符就是。

**`CLOUDFLARE_API_TOKEN`**

1. 右上角头像 → **My Profile → API Tokens**（或直接打开 [这个页面](https://dash.cloudflare.com/profile/api-tokens)）。
2. 点 **Create Token**，滚到最下面 **Custom token → Get started**。
3. **Token name**：`traffic-bot`。
4. **Permissions** 按下表逐行添加。每行左边选 Account 或 Zone，中间选项目，右边选 **Read**：

   | 类别 | 项目 | 用途 | 不加会怎样 |
   |---|---|---|---|
   | Account | **Account Analytics** | Workers / Pages 请求数、R2 用量、D1 读写行数和存储 | **必须**，否则大部分数据都查不到 |
   | Account | **Workers R2 Storage** | 列出 R2 存储桶（排除已删除的桶） | 改用分析数据推断，可能把已删除的桶也算进去 |
   | Account | **D1** | 显示数据库名称和大小 | 数据库名显示为 ID 前 8 位 |
   | Zone | **Zone** | 自动列出你的域名 | 要手动填 `CLOUDFLARE_ZONES` |
   | Zone | **Analytics** | 每个域名的 CDN 请求数和流量 | CDN 这一块报错 |

5. **Account Resources**：`Include` → 选你的账号。
6. **Zone Resources**：`Include` → `All zones`（或者只选你想统计的域名）。
7. **Continue to summary → Create Token**，复制显示的 Token。**只显示这一次。**

> 以后要补权限，在 API Tokens 列表里点这个 Token 的 **Edit**，加完保存即可，Token 的值不会变，不用改 bot 配置。

**`CLOUDFLARE_BILLING_DAY`**（可选，默认 `8`）

Workers & Pages 板块里“账期内请求数 / CPU 时间”这一行的统计起点。打开 **Workers & Pages**，概览页的用量卡片上会显示类似 `Oct 8 - Nov 8` 的日期范围，开头那个日期的“日”就填在这里。

**`CLOUDFLARE_ZONES`**（可选）

不想给 Token 加 Zone Read 权限时，手动列出要统计的域名，格式为 `名称=ZoneID`，逗号分隔：

```
CLOUDFLARE_ZONES="example.com=0123456789abcdef0123456789abcdef,other.net=..."
```

Zone ID 在控制台点进某个域名，**Overview** 页右下角 **API** 区块里有 **Zone ID**。

---

### ⑤ Oracle Cloud

**`OCI_TENANCY`、`OCI_USER`、`OCI_FINGERPRINT`、`OCI_REGION`、私钥 `.pem` 文件**

同样建一个只读用户。下面所有操作都在 [Oracle Cloud 控制台](https://cloud.oracle.com/) 里完成。

**第 1 步：建用户和组**

1. 左上角菜单 ☰ → **Identity & Security → Domains**，点 **Default**。
2. 切到 **User management** 标签：
   - **Users → Create**：First name / Last name 随便填，**Username** 填 `traffic-bot`，邮箱可以留空。点 **Create**。
   - **Groups → Create group**：名称填 `traffic-bot-readers`，创建后在组详情里点 **Users → Assign user to group**，选 `traffic-bot`。

**第 2 步：加权限策略**

1. 菜单 ☰ → **Identity & Security → Policies**。
2. 确认页面上方的 **Applied filters** 里 Compartment 显示的是 `你的租户名 (root)`。这就是根 compartment，不用改。
3. 点 **Create Policy**：
   - **Name**：`traffic-bot-read`
   - **Description**：随便写
   - **Compartment**：保持 `(root)`
   - 在 **Policy Builder** 区域打开 **Show manual editor** 开关，粘贴下面四行：

   ```
   Allow group 'Default'/'traffic-bot-readers' to read metrics in tenancy
   Allow group 'Default'/'traffic-bot-readers' to read instance-family in tenancy
   Allow group 'Default'/'traffic-bot-readers' to read virtual-network-family in tenancy
   Allow group 'Default'/'traffic-bot-readers' to inspect compartments in tenancy
   ```

4. 点 **Create**。

**第 3 步：生成 API Key**

1. 回到 **Domains → Default → User management → Users**，点 `traffic-bot`。
2. 切到 **API keys** 标签，点 **Add API key**。
3. 选 **Generate API key pair**，点 **Download private key**，下载得到一个 `.pem` 文件。**这是唯一一次下载机会。**
4. 点 **Add**。弹出的 **Configuration file preview** 里有这几行：

   ```
   user=ocid1.user.oc1..aaaa...        → OCI_USER
   fingerprint=12:34:56:...:ef          → OCI_FINGERPRINT
   tenancy=ocid1.tenancy.oc1..aaaa...  → OCI_TENANCY
   region=ap-seoul-1                    → OCI_REGION
   ```

   全部复制下来。关掉弹窗以后也能找回：
   - `OCI_USER`：用户详情页 **Details** 标签里的 **OCID**，点 **Copy**。
   - `OCI_FINGERPRINT`：用户详情页 **API keys** 标签的列表里。
   - `OCI_TENANCY`：右上角头像 → **Tenancy: 你的租户名** → 详情页 **OCID** 旁点 **Copy**。

5. 用 scp 把 `.pem` 传到要运行 bot 的服务器，例如：

   ```bash
   scp ~/Downloads/xxxx.pem root@你的服务器:/root/oci.pem
   ```

**`OCI_REGION`**

实例所在的区域。免费资源只能建在 home region，所以通常就是上面配置预览里的那个，例如首尔是 `ap-seoul-1`。

**`OCI_IDLE_CHECK`**（可选，默认 `0` 关闭）

设为 `1` 后，bot 会检查每台实例近 7 天的 CPU p95 和网络。如果接近 Oracle 的闲置回收线（20%），就提醒你，避免免费账号的实例被回收。

CPU 数据来自实例上 Oracle Cloud Agent 的 **Compute Instance Monitoring** 插件，在实例详情页 **Management → Oracle Cloud Agent** 里可以看到它的状态：

- 状态为 **Running** 才有 CPU 数据。
- 状态为 **Invalid / Stale**：在实例上重启 agent。Ubuntu 用 `sudo snap restart oracle-cloud-agent`，Oracle Linux 用 `sudo systemctl restart oracle-cloud-agent`。
- 自己 DD 重装过系统（例如换成 Debian）的实例通常没有 agent，这台实例的 CPU 一栏会显示“无数据”。

出站流量来自虚拟网卡，不依赖这个插件。

---

### ⑥ 阿里云 CDT

**bot 这边不需要任何配置，也不需要阿里云 AccessKey。**

在**同一台服务器**上安装 [CDT-Management](../CDT-Management/)（`bash init.sh`）。它每 5 分钟把状态写到 `/var/lib/cdt-guard/state.json`，bot 检测到这个文件就会自动显示阿里云 CDT 板块。阿里云的凭据怎么获取，见 [CDT-Management 的 README](../CDT-Management/README.md#前置准备)。

---

## 安装

环境要求：Debian / Ubuntu，systemd，Python 3.9+。

```bash
apt install -y python3-venv          # 没有 venv 模块时
git clone https://github.com/10ta/scripts-de-moi
cd scripts-de-moi/traffic-bot
sudo bash install.sh
```

脚本会：

1. 创建低权限系统用户 `trafficbot`，把 `bot.py` 安装到 `/opt/traffic-bot/`。
2. 建虚拟环境，安装依赖（`python-telegram-bot[job-queue]`、`boto3`、`requests`、`oci`）。
3. **逐项询问上面准备好的凭据**，密钥类输入不会回显，写入 `/etc/traffic-bot.env`（root 600）。
   - 不用的平台直接回车跳过。
   - Oracle 会问私钥 `.pem` 在服务器上的路径，然后复制到 `/etc/traffic-bot/oci_api_key.pem`（root:trafficbot 640）。确认 bot 能查到 Oracle 数据后，删掉原文件：`shred -u /root/oci.pem`。
4. 安装 systemd 服务 `traffic-bot`，设为开机自启并启动。
5. 发现旧的 `nohup python bot.py` 进程时，询问是否终止（同一个 Token 只能有一个进程在轮询）。

装好后在 Telegram 里给 bot 发 `/check`。

---

## 使用

| 命令 | 作用 |
|---|---|
| `/start` | 显示说明（白名单里的 chat 启动时就会自动注册定时播报） |
| `/check` | 查询全部平台 |
| `/cloudfront`、`/cf` | 只查 CloudFront |
| `/bill`、`/awsbill` | 只查 AWS 本月账单（总额和收费项目） |
| `/cloudflare` | 只查 Cloudflare（Workers & Pages、R2、D1、CDN） |
| `/oracle`、`/oci` | 只查 Oracle Cloud |
| `/aliyun`、`/cdt` | 只查阿里云 CDT |
| `/help` | 命令列表 |

**告警规则**

- 每 `ALERT_CHECK_MINUTES` 分钟（默认 10）检查一次。
- 某项用量**第一次**越过 `ALERT_THRESHOLDS` 里的某一档时推送，每个周期每档只推一次。
- 周期（天 / 月）切换后，告警记录自动清零。
- 告警记录保存在 `/var/lib/traffic-bot/alerts.json`，重启 bot 不会重复告警。

---

## 配置项

全部写在 `/etc/traffic-bot.env`，格式为 `KEY="value"`（不要写 `export`）。**改完必须重启**：`sudo systemctl restart traffic-bot`。

> 改的是 `/etc/traffic-bot.env`，**不是** `install.sh` 里的模板。这个文件已存在时，重新运行 install.sh 不会覆盖它，只会在末尾补上新版本新增的配置项。

**通用**

| 变量 | 默认值 | 说明 |
|---|---|---|
| `BOT_TOKEN` | — | 必填 |
| `ALLOWED_CHAT_IDS` | — | 必填，逗号分隔 |
| `REPORT_INTERVAL_HOURS` | `2` | 定时播报间隔（小时），`0` 关闭 |
| `ALERT_THRESHOLDS` | `80,95` | 告警档位（%） |
| `ALERT_CHECK_MINUTES` | `10` | 告警检查频率（分钟） |
| `REPORT_TZ` | `America/New_York` | 播报里显示时间用的时区 |

**各平台**

| 变量 | 默认值 | 说明 |
|---|---|---|
| `BWH_API_KEY`、`BWH_VEID` | — | 见 ② |
| `BWH_TOTAL_GB` | `2000` | BWH 套餐流量（GB） |
| `AWS_ACCESS_KEY`、`AWS_SECRET_KEY` | — | 见 ③；留空则用 boto3 默认凭证链 |
| `LIGHTSAIL_REGION` | `ap-northeast-1` | Lightsail 区域 |
| `AWS_BILL` | `1` | 显示 AWS 本月账单，`0` 关闭 |
| `AWS_BILL_LIMIT_USD` | `1` | 本月账单越过这个金额的 80% / 95% 时告警，`0` 不告警 |
| `AWS_BILL_CACHE_MIN` | `60` | 账单查询结果缓存多久（分钟） |
| `CLOUDFRONT_LIMIT_GB` | `1024` | CloudFront 免费流量（GB） |
| `CLOUDFRONT_LIMIT_REQUESTS` | `10000000` | CloudFront 免费请求数 |
| `CLOUDFLARE_API_TOKEN`、`CLOUDFLARE_ACCOUNT_ID` | — | 见 ④ |
| `CLOUDFLARE_ZONES` | 空（自动列出） | `名称=ZoneID`，逗号分隔 |
| `CLOUDFLARE_BILLING_DAY` | `8` | Workers 账期起始日 |
| `CLOUDFLARE_PAGES_FUNCTIONS` | `1` | 是否把 Pages Functions 计入 Workers 请求数 |
| `CF_WORKERS_DAILY_LIMIT` | `100000` | Workers 每日免费请求数 |
| `CF_R2_STORAGE_GB` / `CF_R2_CLASS_A` / `CF_R2_CLASS_B` | `10` / `1000000` / `10000000` | R2 免费额度 |
| `CF_D1_ROWS_READ` / `CF_D1_ROWS_WRITTEN` | `5000000` / `100000` | D1 每日免费读写行数 |
| `CF_D1_STORAGE_GB` / `CF_D1_DB_MAX_MB` | `5` / `500` | D1 账号总存储 / 单库上限 |
| `OCI_TENANCY`、`OCI_USER`、`OCI_FINGERPRINT` | — | 见 ⑤，三项都填才启用 |
| `OCI_REGION` | `ap-seoul-1` | Oracle 区域 |
| `OCI_KEY_FILE` | `/etc/traffic-bot/oci_api_key.pem` | 私钥路径 |
| `OCI_EGRESS_LIMIT_TB` | `10` | 每月免费出站流量（TB） |
| `OCI_IDLE_CHECK` | `0` | 闲置回收检测，`1` 开启 |
| `OCI_IDLE_LINE` / `OCI_IDLE_WARN` | `20` / `25` | 回收线 / 提醒线（CPU p95 %） |
| `CDT_STATE_PATH` | `/var/lib/cdt-guard/state.json` | cdt-guard 状态文件 |
| `CDT_STALE_MIN` | `15` | 状态文件超过多少分钟没更新就提醒 |

---

## 更新与维护

```bash
cd scripts-de-moi && git pull
sudo cp traffic-bot/bot.py /opt/traffic-bot/ && sudo systemctl restart traffic-bot
```

新版本增加了依赖或配置项时，改为重新运行 `sudo bash install.sh`。已有的配置会保留，缺少的配置项会追加到末尾。

```bash
journalctl -u traffic-bot -f                    # 实时日志
journalctl -u traffic-bot -n 20 | grep 播报间隔  # 确认生效的播报间隔和告警线
systemctl status traffic-bot                    # 运行状态
sudo nano /etc/traffic-bot.env                  # 改配置（改完 restart）
```

| 位置 | 内容 |
|---|---|
| `/opt/traffic-bot/` | `bot.py` 和虚拟环境 |
| `/etc/traffic-bot.env` | 所有配置和密钥（root 600） |
| `/etc/traffic-bot/oci_api_key.pem` | Oracle 私钥（root:trafficbot 640） |
| `/var/lib/traffic-bot/alerts.json` | 告警去重记录 |
| `/etc/systemd/system/traffic-bot.service` | systemd 服务 |

---

## 常见问题

**改了播报间隔没有生效**

底部那行“⏱ 播报间隔 …”显示的是 bot 实际读到的值。检查 `sudo grep -n REPORT_INTERVAL /etc/traffic-bot.env`：

- 改错文件：改的是 install.sh 里的模板，而不是 `/etc/traffic-bot.env`。
- 有重复行：同一个变量出现两次，以最后一行为准。

改完要 `sudo systemctl restart traffic-bot`。

**日志里出现 `409 Conflict`**

同一个 `BOT_TOKEN` 有两个进程在轮询，通常是旧的 nohup 进程还在。用 `pgrep -af bot.py` 找到旧进程并 kill 掉，再重启服务。

**Cloudflare 某一块报权限错误**

报错信息后面会提示缺哪项权限。对照 ④ 的权限表，编辑 Token 补上即可，不用改 bot 配置，也不用重启。

**Oracle 报错**

| 提示 | 原因 |
|---|---|
| 认证失败 | `OCI_USER`、`OCI_FINGERPRINT`、私钥三者不是同一对，或这个 API Key 已被删除 |
| 没有权限 | 第 2 步的策略没建，或组名 / 域名写错（`'Default'/'traffic-bot-readers'`） |
| 找不到私钥 / 读不了私钥 | 检查 `/etc/traffic-bot/oci_api_key.pem` 是否存在，权限应为 `root:trafficbot 640` |
| 没有找到实例 | `OCI_REGION` 和实例所在区域不一致 |

**AWS 显示 `AccessDenied`**

IAM 策略缺少某个 Action。对照 ③ 的策略，检查五个 Action 是否都在。Lightsail 显示“无活跃实例”时，检查 `LIGHTSAIL_REGION`。

**AWS 账单显示“没有账单数据”**

还没开启 CloudWatch 账单指标，按 ③ 里“AWS 账单”的步骤开启，等 15 分钟。

**阿里云 CDT 提示数据未更新**

cdt-guard 可能停了。在服务器上进入 CDT-Management 目录运行 `bash init.sh status` 检查。
