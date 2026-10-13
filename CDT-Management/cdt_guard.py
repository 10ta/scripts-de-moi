#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cdt-guard — 阿里云 CDT 流量熔断 + ECS 保活。零依赖（只用 Python 标准库）。

  cdt_guard.py check     # systemd timer 每 5 分钟跑一次：查流量 → 熔断/恢复/保活 → 写快照
  cdt_guard.py report    # 立即查一次 API，打印报告（--json 输出 JSON）
  cdt_guard.py hold      # 暂停自动开机（手动关机维护时用）
  cdt_guard.py release   # 取消暂停
  cdt_guard.py list      # 列出 ALI_REGION 下的实例（验证 AK、找实例 ID）
  cdt_guard.py unlock    # 手动解除熔断（sg 模式会删掉 drop 规则）

配置：/etc/cdt-guard.env（或 CDT_GUARD_ENV 指定），见 cdt-guard.env.example
状态：$STATE_DIR/state.json —— traffic-bot 只读这个文件，不需要 AK。
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone

GIB = 1024 ** 3
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
    env.update({k: v for k, v in os.environ.items() if k in env or k.startswith(("ALI_", "CDT_", "TG_", "GUARD_", "STOP_", "SG_", "STATE_"))})
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
        self.tg_token = env.get("TG_BOT_TOKEN", "")
        self.tg_chat = env.get("TG_CHAT_ID", "")
        self.state_dir = env.get("STATE_DIR", "/var/lib/cdt-guard")
        self.endpoint = env.get("ALI_ENDPOINT_OVERRIDE", "")  # 仅测试用
        if self.mode not in ("stop", "sg"):
            raise SystemExit("GUARD_MODE 只能是 stop 或 sg")


# ───────────────────────── 阿里云 RPC 签名（V1, HMAC-SHA1）─────────────────────────
class AliError(Exception):
    def __init__(self, code, msg):
        super().__init__(f"{code}: {msg}")
        self.code = code


def _pe(s):
    return urllib.parse.quote(str(s), safe="~")


def rpc(cfg, host, version, action, **params):
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
    for attempt in range(3):
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
        time.sleep(1.5 * (attempt + 1))
    raise last


def ecs(cfg, action, **p):
    return rpc(cfg, f"ecs.{cfg.region}.aliyuncs.com", "2014-05-26", action, RegionId=cfg.region, **p)


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


# ───────────────────────── 动作 ─────────────────────────
def stop_instance(cfg, inst):
    p = {"InstanceId": cfg.instance, "ForceStop": "false"}
    if inst["charge"] == "PostPaid":  # 包年包月不支持 StoppedMode
        p["StoppedMode"] = cfg.stop_mode
    ecs(cfg, "StopInstance", **p)


def start_instance(cfg):
    ecs(cfg, "StartInstance", InstanceId=cfg.instance)


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
    ecs(cfg, "AuthorizeSecurityGroup", SecurityGroupId=sg, **{
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
    ecs(cfg, "RevokeSecurityGroup", SecurityGroupId=sg, **{"SecurityGroupRuleId.1": rid})
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


def notify(cfg, text):
    print(text)
    if not (cfg.tg_token and cfg.tg_chat):
        return
    for chat in (c.strip() for c in cfg.tg_chat.split(",") if c.strip()):
        try:
            body = urllib.parse.urlencode({"chat_id": chat, "text": text, "disable_web_page_preview": "true"}).encode()
            urllib.request.urlopen(f"https://api.telegram.org/bot{cfg.tg_token}/sendMessage", data=body, timeout=15).read()
        except Exception as e:
            print(f"[tg] 发送到 {chat} 失败: {type(e).__name__}", file=sys.stderr)  # 不打印 e，URL 里有 token


def rate_per_hour(samples, now, bw_mbps=0):
    """近 90 分钟窗口的平均速率（GiB/h）。
    窗口不足 40 分钟不算（CDT 数据是成批补上来的，短窗口会把一次补数算成超高速率误熔断）；
    并且不超过实例出网带宽的物理上限。"""
    window = [s for s in samples if now - s[0] <= 5400]
    if len(window) < 2 or window[-1][0] - window[0][0] < 2400:
        return 0.0
    (t0, g0), (t1, g1) = window[0], window[-1]
    rate = max(0.0, (g1 - g0) / ((t1 - t0) / 3600))
    if bw_mbps:
        rate = min(rate, bw_mbps * 3600 / 8 / 1024)
    return rate


# ───────────────────────── 主逻辑 ─────────────────────────
def check(cfg):
    st = load_state(cfg)
    now = time.time()
    tag = f"[CDT {cfg.instance[-6:]}]"

    try:
        used, by_region = get_traffic(cfg)
        inst = get_instance(cfg)
    except Exception as e:
        # 查询失败：什么都不做（不开机、不关机），连续 3 次才告警一次
        st["fail"] = st.get("fail", 0) + 1
        st["last_error"] = str(e)
        if st["fail"] == 3:
            notify(cfg, f"⚠️ {tag} 连续 3 次查询阿里云失败，守护暂停动作\n{e}")
        save_state(cfg, st)
        print(f"query failed: {e}", file=sys.stderr)
        return 1
    if st.get("fail", 0) >= 3:
        notify(cfg, f"✅ {tag} 阿里云 API 恢复")
    st["fail"] = 0
    st.pop("last_error", None)

    # 速率 & 预测（CDT 数据本身有延迟，用速率往前看 LOOKAHEAD 分钟）
    samples = [s for s in st.get("samples", []) if now - s[0] <= 7200 and s[1] <= used + 0.001]
    samples.append([now, round(used, 4)])
    rate = rate_per_hour(samples, now, float(inst.get("bw_out") or 0))
    projected = used + rate * cfg.lookahead / 60
    locked = st.get("locked", False)
    status = inst["status"]
    events = []
    just_unlocked = False

    try:
        if locked:
            if used < cfg.release:  # 月初重置；stop 模式的开机交给下面的保活段
                if cfg.mode == "sg":
                    sg_unlock(cfg, inst)
                locked = False
                just_unlocked = True
                events.append(f"🔓 {tag} 流量已重置（{used:.2f} GB），解除熔断")
            else:  # 维持熔断：有人手动开机/删规则就再执行一次
                if cfg.mode == "stop" and status == "Running":
                    stop_instance(cfg, inst)
                    events.append(f"🛑 {tag} 熔断期间实例被启动，已再次关机（{used:.2f} GB）")
                elif cfg.mode == "sg" and sg_lock(cfg, inst):
                    events.append(f"🛑 {tag} 熔断规则丢失，已重新加上")
        elif used >= cfg.limit or projected >= cfg.limit:
            why = f"{used:.2f} GB" + (f"，按 {rate:.1f} GB/h 预计 {cfg.lookahead:.0f} 分钟内到 {projected:.1f}" if used < cfg.limit else "")
            if cfg.mode == "stop":
                if status == "Running":
                    stop_instance(cfg, inst)
                events.append(f"🛑 {tag} 流量熔断：{why} ≥ {cfg.limit:g} GB，已关机（{cfg.stop_mode if inst['charge'] == 'PostPaid' else '包年包月'}）")
            else:
                sg_lock(cfg, inst)
                events.append(f"🛑 {tag} 流量熔断：{why} ≥ {cfg.limit:g} GB，已在安全组 {_sg(cfg, inst)} 加 drop-all 入站规则")
            locked = True

        # 保活 / 解除熔断后开机（sg 模式熔断期间也照样保活，反正规则挡着）
        if (cfg.keepalive or just_unlocked) and status == "Stopped" and not st.get("hold") and (not locked or cfg.mode == "sg"):
            if just_unlocked or now - st.get("last_start", 0) > 600:  # 10 分钟冷却，防止库存不足时狂刷
                st["last_start"] = now
                start_instance(cfg)
                events.append(f"🔄 {tag} 实例处于停机，已发送开机指令（{used:.2f} GB）")
    except AliError as e:
        events.append(f"❌ {tag} 操作失败：{e}" + ("\n库存不足：节省停机释放了算力，换时段/换可用区或改 KeepCharging" if "NoStock" in str(e) else ""))

    st.update({
        "locked": locked, "samples": samples[-30:], "updated": now,
        "used_gb": round(used, 3), "by_region": {k: round(v, 3) for k, v in by_region.items()},
        "rate_gbh": round(rate, 3), "quota_gb": cfg.quota, "limit_gb": cfg.limit, "cls": cfg.cls,
        "mode": cfg.mode, "instance": cfg.instance, "region": cfg.region,
        "status": status, "ip": inst["ip"], "name": inst["name"],
    })
    save_state(cfg, st)
    for ev in events:
        notify(cfg, ev)
    print(f"{datetime.now():%F %T} used={used:.3f}GB rate={rate:.2f}GB/h proj={projected:.2f} status={status} locked={locked} hold={st.get('hold', False)}")
    return 0


def format_report(st, now=None):
    """traffic-bot 可以直接复制这个函数：只读 state.json，不需要 AK。"""
    if not st or "used_gb" not in st:
        return "☁️ Aliyun CDT：暂无数据（cdt-guard 还没跑过）"
    now = now or time.time()
    used, quota, limit = st["used_gb"], st["quota_gb"], st["limit_gb"]
    pct = used / quota * 100 if quota else 0
    bar = "▓" * min(10, int(pct / 10)) + "░" * (10 - min(10, int(pct / 10)))
    age = int((now - st["updated"]) / 60)
    if st.get("locked"):
        guard = "🛑 已熔断" + ("（关机）" if st.get("mode") == "stop" else "（安全组封禁）")
    elif st.get("hold"):
        guard = "⏸ 暂停自启"
    else:
        guard = "✅ 正常"
    lines = [
        f"☁️ Aliyun CDT · {'海外/香港' if st.get('cls') == 'international' else '中国内地'}",
        f"{bar} {pct:.1f}%",
        f"已用 {used:.2f} / {quota:g} GB · 熔断线 {limit:g} GB · 余 {max(0, limit - used):.2f} GB",
        f"速率 {st.get('rate_gbh', 0):.2f} GB/h",
        f"{st.get('name') or st.get('instance')} · {st.get('status')} · {st.get('ip') or '无公网IP'}",
        f"守护 {guard}",
    ]
    if len(st.get("by_region", {})) > 1:
        lines.append(" / ".join(f"{r} {g:.1f}" for r, g in sorted(st["by_region"].items())))
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
        save_state(cfg, st)
        print("已解除熔断状态")
        return 0
    if cmd in ("hold", "release"):
        st = load_state(cfg)
        st["hold"] = cmd == "hold"
        save_state(cfg, st)
        print("已暂停自动开机" if st["hold"] else "已恢复自动开机")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
