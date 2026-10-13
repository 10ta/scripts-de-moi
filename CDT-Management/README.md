# CDT-Management

阿里云 CDT 流量熔断 + ECS 保活。不需要 Docker，也不需要安装阿里云 SDK，只用 Python 标准库和 systemd timer。

- **流量熔断**：本月 CDT 流量达到阈值（默认 199GB）后，自动关机，或者在安全组里封禁入站。
- **提前熔断**：按近 90 分钟的速率预测，如果 30 分钟内会过线，就提前熔断，用来弥补 CDT 数据的延迟。
- **自动开机**：实例被停（抢占回收、误关、平台维护）后自动拉起；每月 1 号流量重置后自动解除熔断。
- **Telegram 通知**：熔断、恢复、开机、API 故障都会推送。
- **traffic-bot 集成**：bot 直接读取状态文件，bot 本身不需要阿里云 AK。

```
┌──────────── 你的 Debian（常开）────────────┐            ┌──── 阿里云 ────┐
│ cdt-guard.timer  每 5 分钟                 │  阿里云API  │                │
│   └─ cdt_guard.py check  ─────────────────────────────►  │ CDT 流量查询   │
│        ├─ 超线 → 关机 / 安全组加 drop 规则  │            │ ECS 开关机     │
│        ├─ 被停 → 开机                       │            │ 安全组规则     │
│        └─ 写 /var/lib/cdt-guard/state.json │            └────────────────┘
│                        │                   │
│ traffic-bot ◄──────────┘ 只读，展示 + 额度告警                │
└────────────────────────────────────────────┘
```

---

## 前置准备

开始之前，先确认下面三样东西都准备好了。

### ① 一台阿里云 ECS（被监控的那台）

- 已经开通 [CDT](https://cdt.console.aliyun.com/)。免费额度是每月**香港+海外合计 200GB**，**中国内地 20GB**，两池分开计算。
- 记下它的**地域**，例如 `cn-hongkong`，在 ECS 控制台的实例详情里可以看到。

### ② 一个 RAM 用户 + AccessKey

不要用主账号的 AccessKey。

1. 打开 [RAM 控制台 → 用户](https://ram.console.aliyun.com/users)，点 **创建用户**。
   - **登录名称**随便填，例如 `cdt-guard`。
   - 页面下方的 **访问配置**：只勾选右边的 **「使用永久 AccessKey 访问」**，左边的「使用控制台访问」不要勾。
   - 点 **确定**。
2. 跳转到「创建用户」结果页后，在 AccessKey 一列**马上复制 AccessKey ID 和 AccessKey Secret**，或者点 **保存结果** 下载 CSV。页面关掉之后 Secret 就再也看不到了。
   - 如果这一列显示「AccessKey 没有设置」，说明上一步漏勾了，不用删掉用户重建。直接到 **用户** 列表 → 点这个用户名 → **认证管理** 标签 → **创建 AccessKey** 补一个就行。
3. 给这个用户授权：在结果页勾选这个用户 → **新增授权**，或者在用户列表那一行点 **添加权限**。资源范围选 **账号级别**，然后二选一：
   - **推荐：自定义最小权限。**
     先到左侧 **权限管理 → 权限策略** → **创建权限策略** → **脚本编辑** 标签，把本目录的 [`ram-policy.json`](ram-policy.json) 整段粘进去，名称填 `cdt-guard`，保存。
     然后回到授权面板，把策略类型切到 **自定义策略**，搜索 `cdt-guard`，勾选并确认。
     这条策略只能查 CDT 流量、查询和启停 ECS、改安全组规则。如果只用关机模式，可以删掉第三段（安全组）。
   - 省事：在授权面板的搜索框分别搜 `CDT` 和 `ECS`，勾选系统策略 `AliyunCDTFullAccess` 和 `AliyunECSFullAccess`。
     ⚠️ ECSFullAccess 可以**删除或创建整个账号下的任何实例**，一旦 AK 泄露，影响的是整个账号，不只是这一台机器。

### ③ 另一台常开的 Debian / Ubuntu

- 守护程序**不能装在被监控的那台 ECS 上**：它一关机，就没人能把它开起来了。家里的服务器、别家的 VPS 都可以。
- 需要 root、systemd、Python 3.8 及以上。Debian 11/12 自带，没有的话脚本会自动装。
- 机器要能访问 `*.aliyuncs.com` 和 `api.telegram.org`。

### ④（可选）Telegram Bot

如果这台机器上已经跑着 traffic-bot，安装时会自动沿用它的 token 和 chat id，这一步可以跳过。

---

## 安装

在第 ③ 步那台 Debian 上，用 root 执行下面任意一种方式。

```bash
# 方式 A：直接运行
bash (curl -fsSL https://raw.githubusercontent.com/10ta/scripts-de-moi/main/script/CDT-Management/init.sh | psub)

# 方式 B：先 clone 再运行
git clone https://github.com/10ta/scripts-de-moi.git
cd scripts-de-moi/script/CDT-Management
bash init.sh
```

脚本会依次完成以下步骤：

1. 把程序装到 `/opt/cdt-guard/`，把 systemd 单元装到 `/etc/systemd/system/`。
2. 问你要 AccessKey 和地域，**当场验证**，然后列出该地域的实例让你选择。
3. 问熔断线（默认 199GB）、熔断方式（默认关机），以及 Telegram 通知设置。
4. 把配置写入 `/etc/cdt-guard.env`（权限 600），先运行一次，确认没问题后再启用定时器。

最后会打印一份当前用量报告，看到报告就说明安装成功了。

---

## 熔断方式怎么选

| | `stop`（默认） | `sg` |
|---|---|---|
| 做法 | 关机 | 在安全组加一条优先级 1 的 drop-all 入站规则 |
| 公网 IP | 不变（KeepCharging） | 不变 |
| 熔断期间登录 | 不能 | 可以通过控制台 VNC / Workbench 登录 |
| 注意 | — | **该安全组下的所有实例都会断网**，建议给这台实例单独建一个安全组；已经建立的长连接可能不会立刻断，上线前先手动测一次 |

关于按量付费实例的停机模式 `STOP_MODE`：

- `KeepCharging`（默认）：保留公网 IP，开机一定能成功。
- `StopCharging`：停机期间不收算力费，但[固定公网 IP 会被释放，开机后 IP 会变，而且开机可能因为库存不足失败](https://help.aliyun.com/zh/ecs/user-guide/economical-mode)。

包年包月实例不涉及这个选项。

---

## 运行逻辑

每 5 分钟执行一次：

| 情况 | 动作 |
|---|---|
| 用量 ≥ 熔断线，或按速率 30 分钟内会过线 | 熔断（关机 / 加规则）+ 通知 |
| 熔断中有人手动开机或删了规则 | 再执行一次熔断 |
| 熔断中流量掉回熔断线 −10GB 以下（每月 1 号重置） | 解除熔断、开机 + 通知 |
| 未熔断时实例处于 Stopped | 开机 + 通知（10 分钟冷却，避免库存不足时反复请求） |
| 查询阿里云失败 | **什么都不做**；连续失败 3 次通知一次 |

流量按 CDT 的两个池分开统计：香港和海外算一池，中国内地算一池。只统计实例所在的那一池。

---

## 日常命令

```bash
bash init.sh status         # 定时器状态 + 最近日志 + 当前用量
bash init.sh reconfigure    # 重新填写配置
bash init.sh uninstall      # 卸载（sg 模式会先删掉安全组里的规则）

# 程序本身
python3 /opt/cdt-guard/cdt_guard.py report     # 立刻查一次
python3 /opt/cdt-guard/cdt_guard.py hold       # 暂停自动开机（手动关机维护前用）
python3 /opt/cdt-guard/cdt_guard.py release    # 恢复自动开机
python3 /opt/cdt-guard/cdt_guard.py unlock     # 手动解除熔断（如果仍超线，下次检查会再熔断）
journalctl -u cdt-guard -f                     # 看日志
```

> **手动关机维护前，一定要先执行 `hold`。** 否则最多 10 分钟后，实例会被自动开机。

更多参数见 `/opt/cdt-guard/cdt-guard.env.example`，例如：

- `CDT_LOOKAHEAD_MIN`：预测窗口，默认 30 分钟。
- `CDT_RELEASE_GB`：解除熔断的阈值。
- `GUARD_KEEPALIVE=0`：关闭保活。

改完 `/etc/cdt-guard.env` 后不用重启任何服务，下一轮检查会自动生效。

---

## 和 traffic-bot 一起用

把 traffic-bot 更新到带阿里云 CDT 的版本（`sudo cp bot.py /opt/traffic-bot/ && sudo systemctl restart traffic-bot`），**不用给 bot 加任何配置**：

- bot 发现 `/var/lib/cdt-guard/state.json` 存在，就会在报告里显示 🟧 Aliyun CDT 一栏。
- 新增命令 `/aliyun`（或 `/cdt`），单独查看这一栏。
- 用量越过告警线（默认 80% / 95%）时，沿用 bot 现有的告警推送。
- 如果 cdt-guard 超过 15 分钟没有更新状态（说明熔断可能已经失效），bot 每天提醒一次。

分工是这样的：bot 只读文件，不持有阿里云 AK，也不能开关机；熔断、开机这些动作只由 cdt-guard 执行，并由它自己推送通知。

---

## 文件说明

| 文件 | 作用 |
|---|---|
| `init.sh` | 安装、重新配置、查看状态、卸载 |
| `cdt_guard.py` | 主程序（零依赖） |
| `cdt-guard.service` / `.timer` | systemd 单元，每 5 分钟运行一次 |
| `cdt-guard.env.example` | 全部配置项的说明 |
| `ram-policy.json` | RAM 最小权限策略 |

## 常见问题

**为什么熔断线不直接设成 200？**
CDT 数据有延迟，而且是成批补上来的。以 100Mbps 跑满计算，1GB 大约 1.5 分钟就用完了。所以除了留 1GB 余量，程序还会按速率提前熔断。如果你的带宽很大，建议把熔断线再调低一些。

**一个账号下有多台实例？**
CDT 额度是**整个账号共享**的，所有实例的流量加在一起算。程序目前只守护一台实例；如果需要守护多台，可以复制配置、多装一份，或者提 issue。

**参考项目**
[wang4386/CDT-Monitor](https://github.com/wang4386/CDT-Monitor)、[lillinlin/AliCDT-Manager](https://github.com/lillinlin/AliCDT-Manager)：功能更全（Web 面板、多账号、账单），但需要 Docker。
