#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cdt-guard — 阿里云 CDT 流量熔断 + ECS 保活。零依赖（只用 Python 标准库）。

  cdt_guard.py check     # systemd timer 每 5 分钟跑一次：查流量 → 熔断/恢复/保活 → 写快照
  cdt_guard.py report    # 立即查一次 API，打印报告（--json 输出 JSON）
  cdt_guard.py hold      # 暂停自动开机（手动关机维护时用；Telegram 里发 /cdt hold 也行）
  cdt_guard.py release   # 取消暂停（/cdt release）
  cdt_guard.py list      # 列出 ALI_REGION 下的实例（验证 AK、找实例 ID）
  cdt_guard.py unlock    # 手动解除熔断（sg 模式会删掉 drop 规则）
  cdt_guard.py komari    # 测试 Komari：没配 KOMARI_UUID 时列出节点，配了就打印本月上行

配置：/etc/cdt-guard.env（或 CDT_GUARD_ENV 指定），见 cdt-guard.env.example
状态：$STATE_DIR/state.json —— traffic-bot 只读这个文件，不需要 AK。
"""
import base64
import hashlib
import hmac
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

GIB = 1024 ** 3
QUERY_BUDGET = 60  # 秒：流量 + 实例查询超过这么久就跳过本轮账单查询（systemd 超时 300 秒）
CN_TZ = timezone(timedelta(hours=8))  # 阿里云账期 / CDT 按北京时间
RULE_TAG = "cdt-guard"


# ───────────────────────── 配置 ─────────────────────────
def load_env(path):
    env = {}
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                v = v.split(" #", 1)[0]  # 允许行尾注释
                env[k.strip()] = v.strip().strip('"').strip("'")
    env.update({k: v for k, v in os.environ.items() if k in env or k.startswith(("ALI_", "CDT_", "TG_", "GUARD_", "STOP_", "SG_", "STATE_", "COST_", "KOMARI_", "KEEPALIVE_"))})
    return env


def traffic_class(region):
    # 和 CDT 免费额度口径一致：中国内地 20GB 一池，香港+海外 200GB 一池
    return "china" if region.startswith("cn-") and region != "cn-hongkong" else "international"


class Config:
    def __init__(self, env):
        self.ak = env["ALI_AK"]
        self.sk = env["ALI_SK"]
        self.region = env["ALI_REGION"]
        self.instance = env.get("ALI_INSTANCE_ID", "")
        self.cls = env.get("CDT_CLASS") or traffic_class(self.region)
        self.quota = float(env.get("CDT_QUOTA_GB", 200 if self.cls == "international" else 20))
        self.limit = float(env.get("CDT_LIMIT_GB", 199))
        self.release = float(env.get("CDT_RELEASE_GB", self.limit - 10))  # 掉到这以下才解除熔断（=月初重置）
        self.lookahead = float(env.get("CDT_LOOKAHEAD_MIN", 30))
        self.mode = env.get("GUARD_MODE", "stop")  # stop | sg
        self.stop_mode = env.get("STOP_MODE", "KeepCharging")  # KeepCharging | StopCharging
        self.sg_id = env.get("SG_ID", "")
        self.keepalive = env.get("GUARD_KEEPALIVE", "1") == "1"
        # 发现不明原因的停机，等这么多分钟再开机，给手动关机的人留时间发 /cdt hold（0 = 立刻开机）
        self.grace = float(env.get("KEEPALIVE_GRACE_MIN", 10))
        # traffic-bot 收到 /cdt hold|release 后写这个文件（bot 没有 AK，只能请求暂停/恢复自动开机）
        self.request_file = env.get("GUARD_REQUEST_FILE", "/var/lib/traffic-bot/cdt-request.json")
        # Komari：实例上 agent 报的本月上行，实时；CDT 接口的数据会滞后好几个小时
        self.komari_url = env.get("KOMARI_URL", "").rstrip("/")
        self.komari_uuid = env.get("KOMARI_UUID", "")
        self.komari_key = env.get("KOMARI_API_KEY", "")  # 节点设为隐藏时需要（Komari 后台 → 设置 → API 密钥）
        self.tg_token = env.get("TG_BOT_TOKEN", "")
        self.tg_chat = env.get("TG_CHAT_ID", "")
        self.state_dir = env.get("STATE_DIR", "/var/lib/cdt-guard")
        # 费用熔断：本月应付 ≥ COST_LIMIT 就关机（0 = 关闭）。国际站 USD，中国站 CNY
        self.cost_limit = float(env.get("COST_LIMIT", 0))
        self.cost_warn = float(env.get("COST_WARN_PCT", 50))
        self.cost_every = float(env.get("COST_CHECK_MIN", 30))
        self.site = env.get("ALI_SITE", "intl")  # intl = 国际站（alibabacloud.com），cn = 中国站
        self.bss_host = "business.ap-southeast-1.aliyuncs.com" if self.site == "intl" else "business.aliyuncs.com"
        self.endpoint = env.get("ALI_ENDPOINT_OVERRIDE", "")  # 仅测试用
        self.sonde_url = env.get("SONDE_URL", "").rstrip("/")  # Sonde 面板的 Worker 地址，留空不上报
        self.sonde_token = env.get("SONDE_TOKEN", "")
        if self.mode not in ("stop", "sg"):
            raise SystemExit("GUARD_MODE 只能是 stop 或 sg")


# ───────────────────────── 阿里云 RPC 签名（V1, HMAC-SHA1）─────────────────────────
class AliError(Exception):
    def __init__(self, code, msg):
        super().__init__(f"{code}: {msg}")
        self.code = code


def _pe(s):
    return urllib.parse.quote(str(s), safe="~")


def rpc(cfg, host, version, action, attempts=3, **params):
    """attempts：查询类默认重试 3 次；开关机、改安全组这类会改状态的操作传 1，免得超时后重复执行"""
    p = {
        "Format": "JSON", "Version": version, "AccessKeyId": cfg.ak,
        "SignatureMethod": "HMAC-SHA1", "SignatureVersion": "1.0",
        "SignatureNonce": uuid.uuid4().hex,
        "Timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "Action": action, **{k: str(v) for k, v in params.items()},
    }
    canon = "&".join(f"{_pe(k)}={_pe(p[k])}" for k in sorted(p))
    sts = "POST&%2F&" + _pe(canon)
    p["Signature"] = base64.b64encode(hmac.new((cfg.sk + "&").encode(), sts.encode(), hashlib.sha1).digest()).decode()
    url = (cfg.endpoint.rstrip("/") + "/" + host) if cfg.endpoint else f"https://{host}/"
    body = urllib.parse.urlencode(p).encode()

    last = None
    for attempt in range(attempts):
        try:
            req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/x-www-form-urlencoded"})
            with urllib.request.urlopen(req, timeout=20) as r:
                data = json.loads(r.read())
        except urllib.error.HTTPError as e:
            try:
                data = json.loads(e.read())
            except Exception:
                data = {"Code": f"HTTP{e.code}", "Message": str(e)}
            err = AliError(data.get("Code", e.code), data.get("Message", ""))
            if e.code < 500 and "Throttl" not in str(data.get("Code", "")):
                raise err
            last = err
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            last = e
        else:
            code = str(data.get("Code", ""))
            if code and code not in ("200", "OK", "Success", "success"):
                raise AliError(code, data.get("Message", ""))
            return data
        if attempt + 1 < attempts:
            time.sleep(1.5 * (attempt + 1))
    raise last


def ecs(cfg, action, **p):
    return rpc(cfg, f"ecs.{cfg.region}.aliyuncs.com", "2014-05-26", action, RegionId=cfg.region, **p)


def ecs_once(cfg, action, **p):
    """会改状态的 ECS 操作：只发一次。超时时可能已经生效，下一轮 check 会按实际状态处理"""
    return rpc(cfg, f"ecs.{cfg.region}.aliyuncs.com", "2014-05-26", action, attempts=1, RegionId=cfg.region, **p)


# ───────────────────────── 查询 ─────────────────────────
def get_traffic(cfg):
    """返回 (本池已用 GiB, {region: GiB})。API 异常直接抛出 —— 绝不把失败当成 0。"""
    data = rpc(cfg, "cdt.aliyuncs.com", "2021-08-13", "ListCdtInternetTraffic", RegionId="cn-hongkong")
    details = data.get("TrafficDetails")
    if details is None:
        raise AliError("NoTrafficDetails", "CDT 返回里没有 TrafficDetails")
    by_region = {}
    for d in details:
        r = d.get("BusinessRegionId", "?")
        if traffic_class(r) == cfg.cls:
            by_region[r] = by_region.get(r, 0) + float(d.get("Traffic", 0)) / GIB
    return sum(by_region.values()), by_region


def get_instance(cfg):
    data = ecs(cfg, "DescribeInstances", InstanceIds=json.dumps([cfg.instance]))
    items = data.get("Instances", {}).get("Instance", [])
    if not items:
        raise AliError("InstanceNotFound", cfg.instance)
    i = items[0]
    ips = i.get("PublicIpAddress", {}).get("IpAddress", [])
    eip = i.get("EipAddress", {}).get("IpAddress", "")
    return {
        "status": i.get("Status", "Unknown"),
        "ip": eip or (ips[0] if ips else ""),
        "name": i.get("InstanceName", ""),
        "charge": i.get("InstanceChargeType", ""),
        "sgs": i.get("SecurityGroupIds", {}).get("SecurityGroupId", []),
        "bw_out": i.get("InternetMaxBandwidthOut", 0),
    }


# ───────────────────────── Komari（实时流量）─────────────────────────
KOMARI_FRESH = 900  # 秒：Komari 最新上报在这个时间内才算「实时」


def _parse_ts(s):
    """RFC3339（Komari 的 updated_at，可能带纳秒和时区）→ 时间戳；解析不了返回 None"""
    m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.\d+)?(Z|[+-]\d\d:\d\d)?$", str(s or ""))
    if not m:
        return None
    tz = m.group(2) or "Z"
    off = 0 if tz == "Z" else (1 if tz[0] == "+" else -1) * (int(tz[1:3]) * 60 + int(tz[4:6]))
    return datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone(timedelta(minutes=off))).timestamp()


def komari_get(cfg, path):
    headers = {"User-Agent": "cdt-guard"}
    if cfg.komari_key:
        headers["Authorization"] = f"Bearer {cfg.komari_key}"
    req = urllib.request.Request(cfg.komari_url + path, headers=headers)
    with urllib.request.urlopen(req, timeout=15) as r:
        data = json.loads(r.read())
    if data.get("status") != "success":
        raise ValueError(f"Komari 返回 {data.get('status')}: {data.get('message', '')}")
    return data.get("data")


def get_komari(cfg):
    """返回 (agent 报的 totalUp GiB, 上报时间)；节点最近没有上报（离线 / 关机）返回 None。出错直接抛出"""
    best = None
    for r in komari_get(cfg, "/api/recent/" + urllib.parse.quote(cfg.komari_uuid)) or []:
        up = (r.get("network") or {}).get("totalUp")
        if isinstance(up, (int, float)) and not isinstance(up, bool):
            best = (float(up) / GIB, _parse_ts(r.get("updated_at")) or time.time())
    return best


def komari_track(st, raw, cycle, bound=None):
    """把 agent 的计数换算成「本账单月上行」，存在 st["komari"]。只累计增量，所以不依赖 agent 在几点轮换月度计数：
    - 计数变小（agent 重启 / 月度轮换）：之后的读数从 0 起算，已经累计的不丢
    - 新的账单月：从 0 开始；如果 agent 已经轮换过（读数比上次小），读数本身就是本月的
    - 第一次接入：直接用读数（agent 的 totalUp 是本月上行），但不超过从月初到现在带宽能跑出的上限 bound"""
    k = st.get("komari") or {}
    if k.get("cycle") != cycle:
        if not k:
            gb = min(raw, bound) if bound is not None else raw
        else:
            gb = raw if raw < k.get("raw", 0) else 0.0
        k = {"cycle": cycle, "gb": gb}
    else:
        d = raw - k.get("raw", 0)
        k["gb"] += d if d >= 0 else raw
    k["raw"] = raw
    st["komari"] = k
    return k["gb"]


def apply_request(cfg, st):
    """traffic-bot 写的 /cdt hold|release 请求：比上一次 hold/release 新才生效。返回要推送的消息，没有新请求返回 None"""
    try:
        with open(cfg.request_file, encoding="utf-8") as f:
            req = json.load(f)
        hold, ts = bool(req["hold"]), float(req["ts"])
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if ts <= st.get("hold_ts", 0):
        return None
    st["hold"], st["hold_ts"] = hold, ts
    return "⏸ 已按 Telegram 请求暂停自动开机" if hold else "▶️ 已按 Telegram 请求恢复自动开机"


# ───────────────────────── 动作 ─────────────────────────
def stop_instance(cfg, inst):
    p = {"InstanceId": cfg.instance, "ForceStop": "false"}
    if inst["charge"] == "PostPaid":  # 包年包月不支持 StoppedMode
        p["StoppedMode"] = cfg.stop_mode
    ecs_once(cfg, "StopInstance", **p)


def start_instance(cfg):
    ecs_once(cfg, "StartInstance", InstanceId=cfg.instance)


def _sg(cfg, inst):
    sg = cfg.sg_id or (inst["sgs"][0] if inst["sgs"] else "")
    if not sg:
        raise AliError("NoSecurityGroup", "实例没有安全组，且未配置 SG_ID")
    return sg


def find_lock_rule(cfg, sg):
    data = ecs(cfg, "DescribeSecurityGroupAttribute", SecurityGroupId=sg, Direction="ingress")
    for perm in data.get("Permissions", {}).get("Permission", []):
        if perm.get("Description") == RULE_TAG:
            return perm.get("SecurityGroupRuleId")
    return None


def sg_lock(cfg, inst):
    sg = _sg(cfg, inst)
    if find_lock_rule(cfg, sg):
        return False
    ecs_once(cfg, "AuthorizeSecurityGroup", SecurityGroupId=sg, **{
        "Permissions.1.IpProtocol": "ALL", "Permissions.1.PortRange": "-1/-1",
        "Permissions.1.SourceCidrIp": "0.0.0.0/0", "Permissions.1.Policy": "drop",
        "Permissions.1.Priority": "1", "Permissions.1.Description": RULE_TAG,
    })
    return True


def sg_unlock(cfg, inst):
    sg = _sg(cfg, inst)
    rid = find_lock_rule(cfg, sg)
    if not rid:
        return False
    ecs_once(cfg, "RevokeSecurityGroup", SecurityGroupId=sg, **{"SecurityGroupRuleId.1": rid})
    return True


# ───────────────────────── 状态 & 通知 ─────────────────────────
def state_path(cfg):
    return os.path.join(cfg.state_dir, "state.json")


def load_state(cfg):
    try:
        with open(state_path(cfg), encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_state(cfg, st):
    os.makedirs(cfg.state_dir, exist_ok=True)
    tmp = state_path(cfg) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f, ensure_ascii=False, indent=1)
    os.chmod(tmp, 0o644)  # 无密钥，traffic-bot 可读
    os.replace(tmp, state_path(cfg))


# TG 消息脱敏：不出现 IP、网址、域名（错误信息里常带 aliyuncs.com 的接口地址）
_SCRUB = [re.compile(r"[a-zA-Z][a-zA-Z0-9+.-]*://[^\s<>\"）)]*"),
          re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?\b"),
          re.compile(r"\b[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{0,4}){2,7}(?:/\d{1,3})?\b"),
          re.compile(r"\b(?:[a-zA-Z0-9-]+\.)+(?:com|net|org|xyz|io|dev|app|cn|me|top|cc|co|info|cloud|site|tech|link"
                     r"|one|uk|jp|kr|hk|tw|us|de|fr)\b")]


def _redact(text):
    for rx in _SCRUB:
        text = rx.sub("***", text)
    return text


def notify(cfg, text):
    print(text)
    if not (cfg.tg_token and cfg.tg_chat):
        return
    text = _redact(text)
    for chat in (c.strip() for c in cfg.tg_chat.split(",") if c.strip()):
        try:
            body = urllib.parse.urlencode({"chat_id": chat, "text": text, "disable_web_page_preview": "true"}).encode()
            urllib.request.urlopen(f"https://api.telegram.org/bot{cfg.tg_token}/sendMessage", data=body, timeout=15).read()
        except Exception as e:
            print(f"[tg] 发送到 {chat} 失败: {type(e).__name__}", file=sys.stderr)  # 不打印 e，URL 里有 token


SONDE_HEARTBEAT = 900  # 状态没变化时多久上报一次（秒）；Sonde 按这个间隔判断数据是否过期


def sonde_due(cfg, st, now):
    """这一轮要不要上报 Sonde：熔断 / 运行状态 / 出错情况有变化就报，否则每 SONDE_HEARTBEAT 秒报一次。
    流量、速率这些数字每轮都在变，不算「变化」，跟着心跳更新。决定上报时顺便把时间和指纹记进 st"""
    if not (cfg.sonde_url and cfg.sonde_token):
        return False
    fp = "|".join(str(x) for x in (st.get("status"), st.get("locked"), st.get("cost_locked"), st.get("hold"),
                                    bool(st.get("fail")), bool(st.get("cost_error")), bool(st.get("start_fail")),
                                    st.get("komari_fail", 0) >= 3))
    if fp == st.get("sonde_fp") and now - st.get("sonde_ts", 0) < SONDE_HEARTBEAT - 30:
        return False
    st["sonde_fp"], st["sonde_ts"] = fp, now
    return True


def sonde_report(cfg, st):
    """把当前状态上报到 Sonde 面板（可选，失败只打日志）。只报展示需要的字段，不含 IP、实例 ID"""
    if not (cfg.sonde_url and cfg.sonde_token):
        return
    scrub = lambda t: _redact(str(t))[:160]
    cycle_ok = st.get("cost_cycle") == bill_cycle(time.time())
    data = {k: st.get(k) for k in ("name", "status", "cls", "mode", "region", "used_gb", "quota_gb", "limit_gb",
                                   "rate_gbh", "locked", "cost_locked", "hold", "cost_limit", "currency", "fail",
                                   "cdt_gb", "komari_gb", "komari_fresh")}
    data["by_region"] = st.get("by_region") or {}
    data["cost"] = st.get("cost", 0.0) if cycle_ok else 0.0
    data["cost_error"] = scrub(st["cost_error"]) if st.get("cost_error") else ""
    data["last_error"] = scrub(st["last_error"]) if st.get("last_error") else ""
    data["komari_error"] = scrub(st["komari_error"]) if st.get("komari_fail", 0) >= 3 else ""
    series = {k: float(data[k]) for k in ("used_gb", "rate_gbh", "cost") if isinstance(data.get(k), (int, float))}
    body = json.dumps({"source": "cdt-guard", "ts": int(time.time()), "interval": SONDE_HEARTBEAT,
                       "data": data, "series": series}).encode()
    req = urllib.request.Request(cfg.sonde_url + "/ingest", data=body, method="POST", headers={
        "Authorization": f"Bearer {cfg.sonde_token}", "Content-Type": "application/json",
        "User-Agent": "cdt-guard"})
    try:
        urllib.request.urlopen(req, timeout=5).read()
    except Exception as e:
        print(f"[sonde] 上报失败: {type(e).__name__}: {getattr(e, 'code', '')}", file=sys.stderr)


def rate_per_hour(samples, now, bw_mbps=0, span=5400, min_span=2400):
    """近 span 秒窗口的平均速率（GiB/h），不超过实例出网带宽的物理上限。
    CDT 默认窗口 90 分钟、不足 40 分钟不算（CDT 数据是成批补上来的，短窗口会把一次补数算成超高速率误熔断）；
    Komari 是实时数据，用 60 / 10 分钟。"""
    window = [s for s in samples if now - s[0] <= span]
    if len(window) < 2 or window[-1][0] - window[0][0] < min_span:
        return 0.0
    (t0, g0), (t1, g1) = window[0], window[-1]
    rate = max(0.0, (g1 - g0) / ((t1 - t0) / 3600))
    if bw_mbps:
        rate = min(rate, bw_mbps * 1e6 / 8 * 3600 / GIB)
    return rate


# ───────────────────────── 主逻辑 ─────────────────────────
def bill_cycle(ts=None):
    """账单月份按北京时间（阿里云账期口径）"""
    return datetime.fromtimestamp(ts or time.time(), CN_TZ).strftime("%Y-%m")


def get_month_cost(cfg, cycle):
    """本月应付金额（PretaxAmount 合计，已扣优惠）。按量账单按小时生成，有几小时延迟"""
    data = rpc(cfg, cfg.bss_host, "2017-12-14", "QueryBillOverview", BillingCycle=cycle)
    items = (data.get("Data") or {}).get("Items", {}).get("Item", [])
    total = sum(float(i.get("PretaxAmount") or 0) for i in items)
    currency = next((i.get("Currency") for i in items if i.get("Currency")), "USD" if cfg.site == "intl" else "CNY")
    return total, currency


def check(cfg):
    st = load_state(cfg)
    now = time.time()
    tag = f"[CDT {st.get('name') or 'ECS'}]"  # 用实例名称区分，不用实例 ID
    msg = apply_request(cfg, st)  # 查询失败也照样生效：hold 只会减少动作
    if msg:
        notify(cfg, f"{msg} {tag}")

    try:
        used, by_region = get_traffic(cfg)
        inst = get_instance(cfg)
    except Exception as e:
        # 查询失败：什么都不做（不开机、不关机），连续 3 次才告警一次
        st["fail"] = st.get("fail", 0) + 1
        st["last_error"] = str(e)
        if st["fail"] == 3:
            notify(cfg, f"⚠️ {tag} 连续 3 次查询阿里云失败，守护暂停动作\n{e}")
        report = sonde_due(cfg, st, now)
        save_state(cfg, st)
        if report:
            sonde_report(cfg, st)
        print(f"query failed: {e}", file=sys.stderr)
        return 1
    if st.get("fail", 0) >= 3:
        notify(cfg, f"✅ {tag} 阿里云 API 恢复")
    st["fail"] = 0
    st.pop("last_error", None)

    events = []
    cycle = bill_cycle(now)
    bw = float(inst.get("bw_out") or 0)

    # ── Komari 实时流量：和 CDT 取大值。读不到时只剩 CDT（滞后），不会因此放行或开机
    cdt_used, k_gb, k_fresh = used, None, False
    if cfg.komari_url and cfg.komari_uuid:
        try:
            got = get_komari(cfg)
            if st.pop("komari_fail", 0) >= 3:
                events.append(f"✅ {tag} Komari 恢复，实时流量重新生效")
            st.pop("komari_error", None)
            if got:
                start = datetime.strptime(cycle, "%Y-%m").replace(tzinfo=CN_TZ).timestamp()
                komari_track(st, got[0], cycle, bw * 1e6 / 8 * (now - start) / GIB if bw else None)
                st["komari"]["ts"] = got[1]
        except Exception as e:
            st["komari_fail"] = st.get("komari_fail", 0) + 1
            st["komari_error"] = str(e)[:200]
            if st["komari_fail"] == 3:
                events.append(f"⚠️ {tag} 连续 3 次读不到 Komari，实时流量失效，熔断只能靠滞后的 CDT 数据：{e}")
        k = st.get("komari") or {}
        if k.get("cycle") == cycle:
            k_gb, k_fresh = k["gb"], now - k.get("ts", 0) <= KOMARI_FRESH
    used = max(cdt_used, k_gb or 0.0)

    # ── 费用：每 COST_CHECK_MIN 分钟查一次账单（账单本身是小时级的，查太勤没意义）
    # 前面的查询已经很慢（接口卡顿）时，这一轮先不查账单，把时间留给熔断动作，免得整轮超过 systemd 的超时被杀掉
    slow = time.time() - now > QUERY_BUDGET
    if slow and cfg.cost_limit > 0:
        print(f"前面的查询用了 {time.time() - now:.0f}s，本轮跳过账单查询", file=sys.stderr)
    if cfg.cost_limit > 0 and not slow and (now - st.get("cost_ts", 0) >= cfg.cost_every * 60 or st.get("cost_cycle") != cycle):
        try:
            cost, cur = get_month_cost(cfg, cycle)
            st.update({"cost": round(cost, 4), "currency": cur, "cost_cycle": cycle, "cost_ts": now})
            if st.pop("cost_error", None):
                events.append(f"✅ {tag} 账单查询恢复")
        except Exception as e:
            if "cost_error" not in st:
                events.append(f"⚠️ {tag} 查询账单失败，费用熔断暂时失效：{e}"
                              + ("\n（RAM 用户缺少 bss:DescribeBillList 权限？）" if "Forbidden" in str(e) or "NoPermission" in str(e) else ""))
            st["cost_error"] = str(e)[:200]
    cost = st.get("cost", 0.0) if st.get("cost_cycle") == cycle else 0.0
    cur = st.get("currency", "USD")

    # 速率 & 预测（CDT 数据本身有延迟，用速率往前看 LOOKAHEAD 分钟）
    samples = [s for s in st.get("samples", []) if now - s[0] <= 7200 and s[1] <= cdt_used + 0.001]
    samples.append([now, round(cdt_used, 4)])
    rate = rate_per_hour(samples, now, bw)
    if k_fresh:  # 有实时数据就用实时速率
        ks = [s for s in st.get("ksamples", []) if now - s[0] <= 3600 and s[1] <= k_gb + 0.001]
        ks.append([now, round(k_gb, 4)])
        st["ksamples"] = ks[-15:]
        rate = rate_per_hour(ks, now, bw, span=3600, min_span=600)
    projected = used + rate * cfg.lookahead / 60
    src = f"Komari 实时 {used:.2f} GB（CDT 还显示 {cdt_used:.2f} GB）" if k_gb is not None and k_gb > cdt_used \
        else f"{used:.2f} GB"
    locked = st.get("locked", False)
    cost_locked = st.get("cost_lock") == cycle  # 费用熔断只在本账单月有效，换月自动失效
    status = inst["status"]
    just_unlocked = False
    if st.get("cost_lock") and not cost_locked:  # 新的账单月
        st.pop("cost_lock")
        just_unlocked = True
        events.append(f"🔓 {tag} 新账单月 {cycle}，解除费用熔断")

    try:
        # ── 费用熔断：不管 GUARD_MODE 都关机（安全组封禁省不了钱）
        if cfg.cost_limit > 0:
            if not cost_locked and cost >= cfg.cost_limit:
                if status == "Running":
                    stop_instance(cfg, inst)
                cost_locked = True
                st["cost_lock"] = cycle
                events.append(f"🛑 {tag} 费用熔断：本月应付 {cost:.2f} {cur} ≥ {cfg.cost_limit:g} {cur}，已关机。"
                              f"\n关机只能止住 ECS 算力和流量，云盘/EIP/OSS 仍会计费，请到控制台查明原因。"
                              f"\n确认无误后：cdt_guard.py unlock")
            elif cost_locked and status == "Running":
                stop_instance(cfg, inst)
                events.append(f"🛑 {tag} 费用熔断期间实例被启动，已再次关机")
            elif not cost_locked and cost >= cfg.cost_limit * cfg.cost_warn / 100 and st.get("cost_warned") != cycle:
                st["cost_warned"] = cycle
                events.append(f"💰 {tag} 本月应付已到 {cost:.2f} {cur}（费用熔断线 {cfg.cost_limit:g} {cur} 的 {cfg.cost_warn:g}%）")

        # ── 流量熔断
        if locked:
            # 只在换了账单月（北京时间）之后才解除：同一个月里读数突然变低（接口返回空列表、数据补算）
            # 不是真的重置，按异常处理，保持熔断。月中想放行：调高 CDT_LIMIT_GB 后运行 cdt_guard.py unlock
            lock_cycle = st.setdefault("lock_cycle", cycle)
            if used < cfg.release and lock_cycle != cycle:  # stop 模式的开机交给下面的保活段
                if cfg.mode == "sg":
                    sg_unlock(cfg, inst)
                locked = False
                just_unlocked = True
                st.pop("lock_cycle", None)
                events.append(f"🔓 {tag} 新的月份流量已重置（{used:.2f} GB），解除流量熔断")
            else:  # 维持熔断：有人手动开机/删规则就再执行一次
                if used < cfg.release:
                    print(f"读数 {used:.2f} GB 低于解除线 {cfg.release:g} GB，但熔断发生在本月（{lock_cycle}），"
                          f"按数据异常处理，保持熔断", file=sys.stderr)
                if cfg.mode == "stop" and status == "Running" and not cost_locked:
                    stop_instance(cfg, inst)
                    events.append(f"🛑 {tag} 流量熔断期间实例被启动，已再次关机（{used:.2f} GB）")
                elif cfg.mode == "sg" and sg_lock(cfg, inst):
                    events.append(f"🛑 {tag} 熔断规则丢失，已重新加上")
        elif used >= cfg.limit or projected >= cfg.limit:
            why = src + (f"，按 {rate:.1f} GB/h 预计 {cfg.lookahead:.0f} 分钟内到 {projected:.1f}" if used < cfg.limit else "")
            if cfg.mode == "stop":
                if status == "Running" and not cost_locked:
                    stop_instance(cfg, inst)
                events.append(f"🛑 {tag} 流量熔断：{why} ≥ {cfg.limit:g} GB，已关机（{cfg.stop_mode if inst['charge'] == 'PostPaid' else '包年包月'}）")
            else:
                sg_lock(cfg, inst)
                events.append(f"🛑 {tag} 流量熔断：{why} ≥ {cfg.limit:g} GB，已在安全组 {_sg(cfg, inst)} 加 drop-all 入站规则")
            locked = True
            st["lock_cycle"] = cycle

        # ── 保活 / 解除熔断后开机（sg 模式流量熔断期间也照样保活，反正规则挡着）
        # 不明原因的停机先等 KEEPALIVE_GRACE_MIN 分钟：手动关机的人有时间发 /cdt hold；解除熔断后的开机不等
        may_run = not cost_locked and (not locked or cfg.mode == "sg")
        if status != "Stopped":
            st.pop("stopped_seen", None)
            st.pop("grace_told", None)
        if (cfg.keepalive or just_unlocked) and status == "Stopped" and not st.get("hold") and may_run:
            seen = st.setdefault("stopped_seen", now)
            if not just_unlocked and now - seen < cfg.grace * 60:
                if not st.get("grace_told"):
                    st["grace_told"] = True
                    events.append(f"⏳ {tag} 检测到实例停机，{cfg.grace:g} 分钟后自动开机。\n"
                                  f"如果是你手动关的：在 Telegram 发 /cdt hold（或运行 cdt_guard.py hold）")
            elif just_unlocked or now - st.get("last_start", 0) > 600:  # 10 分钟冷却，防止库存不足时狂刷
                st["last_start"] = now
                try:
                    start_instance(cfg)
                    events.append(f"🔄 {tag} 实例处于停机，已发送开机指令（{used:.2f} GB）")
                    st.pop("start_fail", None)
                except AliError as e:
                    if not st.get("start_fail"):  # 开机失败只报第一次，之后每 10 分钟静默重试
                        events.append(f"❌ {tag} 开机失败，之后每 10 分钟自动重试：{e}"
                                      + ("\n库存不足（抢占式/节省停机常见），等库存恢复会自动开起来" if "NoStock" in str(e) else ""))
                    st["start_fail"] = str(e)[:200]
        elif status == "Running" and st.pop("start_fail", None):
            events.append(f"✅ {tag} 实例已恢复运行")
    except AliError as e:
        events.append(f"❌ {tag} 操作失败：{e}")

    st.update({
        "locked": locked, "samples": samples[-30:], "updated": now,
        "used_gb": round(used, 3), "by_region": {k: round(v, 3) for k, v in by_region.items()},
        "cdt_gb": round(cdt_used, 3), "komari_gb": None if k_gb is None else round(k_gb, 3), "komari_fresh": k_fresh,
        "rate_gbh": round(rate, 3), "quota_gb": cfg.quota, "limit_gb": cfg.limit, "cls": cfg.cls,
        "mode": cfg.mode, "instance": cfg.instance, "region": cfg.region,
        "status": status, "ip": inst["ip"], "name": inst["name"], "bw_out": inst.get("bw_out", 0),
        "cost_limit": cfg.cost_limit, "cost_locked": cost_locked,
    })
    report = sonde_due(cfg, st, now)
    save_state(cfg, st)
    if report:
        sonde_report(cfg, st)
    for ev in events:
        notify(cfg, ev)
    print(f"{datetime.now():%F %T} used={used:.3f}GB rate={rate:.2f}GB/h proj={projected:.2f} status={status} "
          f"locked={locked} cost={cost:.4f}{cur} cost_locked={cost_locked} hold={st.get('hold', False)}")
    return 0


def format_report(st, now=None):
    """report 命令的纯文本报告（traffic-bot 有自己的展示，读同一份 state.json）"""
    if not st or "used_gb" not in st:
        return "☁️ Aliyun CDT：暂无数据（cdt-guard 还没跑过）"
    now = now or time.time()
    used, quota, limit = st["used_gb"], st["quota_gb"], st["limit_gb"]
    pct = used / quota * 100 if quota else 0
    bar = "▓" * min(10, int(pct / 10)) + "░" * (10 - min(10, int(pct / 10)))
    age = int((now - st["updated"]) / 60)
    if st.get("cost_locked"):
        guard = "🛑 费用熔断（关机）"
    elif st.get("locked"):
        guard = "🛑 流量熔断" + ("（关机）" if st.get("mode") == "stop" else "（安全组封禁）")
    elif st.get("hold"):
        guard = "⏸ 暂停自启"
    else:
        guard = "✅ 正常"
    lines = [
        f"☁️ Aliyun CDT · {'海外/香港' if st.get('cls') == 'international' else '中国内地'}",
        f"{bar} {pct:.1f}%",
        f"已用 {used:.2f} / {quota:g} GB · 熔断线 {limit:g} GB · 余 {max(0, limit - used):.2f} GB",
        f"速率 {st.get('rate_gbh', 0):.2f} GB/h",
        *([f"实时 {st['komari_gb']:.2f} GB（Komari）· CDT 口径 {st.get('cdt_gb', 0):.2f} GB"]
          if st.get("komari_gb") is not None else []),
        f"{st.get('name') or st.get('instance')} · {st.get('status')} · {st.get('ip') or '无公网IP'}",
        f"守护 {guard}",
    ]
    if len(st.get("by_region", {})) > 1:
        lines.append(" / ".join(f"{r} {g:.1f}" for r, g in sorted(st["by_region"].items())))
    if st.get("cost_limit"):
        cur = st.get("currency", "USD")
        lines.append(f"本月应付 {st.get('cost', 0):.2f} / 熔断 {st['cost_limit']:g} {cur}"
                     + (" · 🛑 已费用熔断" if st.get("cost_locked") else ""))
    if st.get("fail"):
        lines.append(f"⚠️ 最近 {st['fail']} 次查询失败：{st.get('last_error', '')[:80]}")
    lines.append(f"更新于 {age} 分钟前" if age > 0 else "刚刚更新")
    return "\n".join(lines)


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "check"
    cfg = Config(load_env(os.environ.get("CDT_GUARD_ENV", "/etc/cdt-guard.env")))
    if cmd == "list":  # 列出该地域的实例（init.sh 用来选实例；也顺便验证 AK 是否可用）
        data = ecs(cfg, "DescribeInstances", PageSize="100")
        for i in data.get("Instances", {}).get("Instance", []):
            ips = i.get("PublicIpAddress", {}).get("IpAddress", []) or [i.get("EipAddress", {}).get("IpAddress", "")]
            print("\t".join([i.get("InstanceId", ""), i.get("Status", ""), i.get("InstanceName", ""),
                             ips[0] or "-", i.get("InstanceChargeType", "")]))
        return 0
    if cmd == "komari":
        if not cfg.komari_url:
            raise SystemExit("未配置 KOMARI_URL")
        if not cfg.komari_uuid:
            for n in komari_get(cfg, "/api/nodes") or []:
                print(f"{n.get('uuid', '')}\t{n.get('name', '')}")
            return 0
        got = get_komari(cfg)
        print("节点最近没有上报（离线或关机）" if got is None else f"{got[0]:.2f}")
        return 0
    if cmd in ("check", "report") and not cfg.instance:
        raise SystemExit("未配置 ALI_INSTANCE_ID")
    if cmd == "check":
        return check(cfg)
    if cmd == "report":
        st = load_state(cfg)
        used, by_region = get_traffic(cfg)
        inst = get_instance(cfg)
        st.update({"used_gb": used, "by_region": by_region, "quota_gb": cfg.quota, "limit_gb": cfg.limit,
                   "cls": cfg.cls, "mode": cfg.mode, "instance": cfg.instance, "updated": time.time(), **inst})
        print(json.dumps(st, ensure_ascii=False, indent=1) if "--json" in argv else format_report(st))
        return 0
    if cmd == "unlock":  # 手动解除熔断（卸载前、或临时放行）；超线的话下次 check 会再次熔断
        st = load_state(cfg)
        if cfg.mode == "sg" and cfg.instance:
            print("已删除安全组 drop 规则" if sg_unlock(cfg, get_instance(cfg)) else "安全组里没有 cdt-guard 规则")
        st["locked"] = False
        st.pop("lock_cycle", None)
        st.pop("cost_lock", None)  # 费用熔断也一并解除；本月再超线会再次熔断——想放行就把 COST_LIMIT 调高
        st["cost_ts"] = 0
        save_state(cfg, st)
        print("已解除流量/费用熔断状态")
        return 0
    if cmd in ("hold", "release"):
        st = load_state(cfg)
        st["hold"], st["hold_ts"] = cmd == "hold", time.time()  # 比之前的 Telegram 请求新，覆盖它
        save_state(cfg, st)
        print("已暂停自动开机" if st["hold"] else "已恢复自动开机")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
