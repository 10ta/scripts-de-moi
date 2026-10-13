#!/usr/bin/env python3
"""流量监控 Telegram Bot：BWH + AWS Lightsail + AWS CloudFront + Cloudflare(Workers/Pages、R2、D1、CDN) + Oracle Cloud
                         + 阿里云 CDT

依赖：pip install "python-telegram-bot[job-queue]" boto3 requests oci

全部配置来自环境变量（systemd 部署时见 /etc/traffic-bot.env），必填：
  BOT_TOKEN、ALLOWED_CHAT_IDS
选填：AWS_ACCESS_KEY / AWS_SECRET_KEY、BWH_API_KEY / BWH_VEID、
      CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID（填了才会查询并显示 Cloudflare）
      OCI_TENANCY / OCI_USER / OCI_FINGERPRINT / OCI_KEY_FILE / OCI_REGION（填了才会查询并显示 Oracle）
      CDT_STATE_PATH（默认 /var/lib/cdt-guard/state.json，文件存在才显示阿里云 CDT；
                      数据由同机的 cdt-guard 写入，bot 不需要阿里云 AK）
"""
import asyncio
import calendar
import json
import logging
import math
import os
import re
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from functools import wraps
from zoneinfo import ZoneInfo

import boto3
import requests
from botocore.config import Config
from telegram import Update
from telegram.ext import Application, CommandHandler, ContextTypes

# ---------------------------------------------------------------- 配置
BOT_TOKEN = os.getenv("BOT_TOKEN", "")
AWS_ACCESS_KEY = os.getenv("AWS_ACCESS_KEY", "")  # 留空则走 boto3 默认凭证链
AWS_SECRET_KEY = os.getenv("AWS_SECRET_KEY", "")
BWH_API_KEY = os.getenv("BWH_API_KEY", "")
BWH_VEID = os.getenv("BWH_VEID", "")

BWH_TOTAL_GB = float(os.getenv("BWH_TOTAL_GB", "2000"))
LIGHTSAIL_REGION = os.getenv("LIGHTSAIL_REGION", "ap-northeast-1")

# CloudFront 免费额度（按 UTC 自然月）。兼容旧变量名 CF_LIMIT_*
CLOUDFRONT_LIMIT_GB = float(os.getenv("CLOUDFRONT_LIMIT_GB", os.getenv("CF_LIMIT_GB", "1024")))
CLOUDFRONT_LIMIT_REQUESTS = int(os.getenv("CLOUDFRONT_LIMIT_REQUESTS", os.getenv("CF_LIMIT_REQUESTS", "10000000")))

# Cloudflare（变量名与 wrangler 一致）
CLOUDFLARE_API_TOKEN = os.getenv("CLOUDFLARE_API_TOKEN", "")
CLOUDFLARE_ACCOUNT_ID = os.getenv("CLOUDFLARE_ACCOUNT_ID", "")
# 要统计 CDN 流量的域名 Zone ID，逗号分隔，每项可写成 "名称=ZoneID"。留空则自动列出账号下全部域名（需要 Zone Read 权限）
CLOUDFLARE_ZONES = os.getenv("CLOUDFLARE_ZONES", "")
CLOUDFLARE_PAGES_FUNCTIONS = os.getenv("CLOUDFLARE_PAGES_FUNCTIONS", "1") not in ("0", "false", "no", "")
# 账期起始日（UTC）：控制台 Workers & Pages → Usage 里显示 "Oct 8 - Nov 8" 就填 8，用来统计账期内的请求数 / CPU 时间
CLOUDFLARE_BILLING_DAY = min(max(int(os.getenv("CLOUDFLARE_BILLING_DAY", "8")), 1), 31)
CF_WORKERS_DAILY_LIMIT = int(os.getenv("CF_WORKERS_DAILY_LIMIT", "100000"))
CF_R2_STORAGE_GB = float(os.getenv("CF_R2_STORAGE_GB", "10"))
CF_R2_CLASS_A = int(os.getenv("CF_R2_CLASS_A", "1000000"))
CF_R2_CLASS_B = int(os.getenv("CF_R2_CLASS_B", "10000000"))
# D1 免费额度：整个账号共享，每天 00:00 UTC 重置；存储为账号总量，单库另有 500MB 上限
CF_D1_ROWS_READ = int(os.getenv("CF_D1_ROWS_READ", "5000000"))
CF_D1_ROWS_WRITTEN = int(os.getenv("CF_D1_ROWS_WRITTEN", "100000"))
CF_D1_STORAGE_GB = float(os.getenv("CF_D1_STORAGE_GB", "5"))
CF_D1_DB_MAX_MB = float(os.getenv("CF_D1_DB_MAX_MB", "500"))

# Oracle Cloud（API Key 认证）。免费资源只能在 home region，所以只查一个区域
OCI_TENANCY = os.getenv("OCI_TENANCY", "")
OCI_USER = os.getenv("OCI_USER", "")
OCI_FINGERPRINT = os.getenv("OCI_FINGERPRINT", "")
OCI_KEY_FILE = os.getenv("OCI_KEY_FILE") or "/etc/traffic-bot/oci_api_key.pem"
OCI_REGION = os.getenv("OCI_REGION") or "ap-seoul-1"
OCI_EGRESS_LIMIT_TB = float(os.getenv("OCI_EGRESS_LIMIT_TB", "10"))       # 每月出站 10TB
# 闲置回收检测（默认关闭：不显示、不告警、也不查 CPU/网络指标）。设为 1 重新开启
OCI_IDLE_CHECK = os.getenv("OCI_IDLE_CHECK", "0") not in ("0", "false", "no", "")
OCI_IDLE_LINE = float(os.getenv("OCI_IDLE_LINE", "20"))   # Oracle 的回收线：7 天 CPU p95 / 网络 < 20%
OCI_IDLE_WARN = float(os.getenv("OCI_IDLE_WARN", "25"))   # CPU p95 低于它就提醒（比回收线高一点，留余量）

# 阿里云 CDT：只读 cdt-guard（scripts-de-moi/script/CDT-Management）每 5 分钟写出的状态快照
CDT_STATE_PATH = os.getenv("CDT_STATE_PATH", "/var/lib/cdt-guard/state.json")
CDT_STALE_MIN = float(os.getenv("CDT_STALE_MIN", "15"))  # 快照超过这么多分钟没更新就提醒（cdt-guard 可能停了）
CDT_TZ = ZoneInfo("Asia/Shanghai")  # CDT 免费额度按北京时间自然月重置

# 定时播报间隔（小时，0 = 关闭）。兼容旧变量 REPORT_INTERVAL（秒）
if os.getenv("REPORT_INTERVAL_HOURS"):
    REPORT_INTERVAL_SEC = int(float(os.environ["REPORT_INTERVAL_HOURS"]) * 3600)
else:
    REPORT_INTERVAL_SEC = int(os.getenv("REPORT_INTERVAL", "7200"))
REPORT_TZ = ZoneInfo(os.getenv("REPORT_TZ", "America/New_York"))  # 仅用于显示时间

# 告警：已用比例首次越过某个阈值时立刻推送；每个周期（天/月）每个阈值只推一次
ALERT_THRESHOLDS = sorted({float(x) for x in os.getenv("ALERT_THRESHOLDS", "80,95").split(",") if x.strip()})
ALERT_CHECK_SEC = max(int(float(os.getenv("ALERT_CHECK_MINUTES", "10")) * 60), 60)
STATE_PATH = os.path.join(os.getenv("STATE_DIRECTORY", "."), "alerts.json")  # systemd 的 StateDirectory 会设置它

# 允许使用 bot 的 chat id，逗号分隔；留空 = 不限制（不推荐）
ALLOWED_CHAT_IDS = {
    int(x) for x in os.getenv("ALLOWED_CHAT_IDS", "").replace(" ", "").split(",") if x
}

logging.basicConfig(format="%(asctime)s - %(name)s - %(levelname)s - %(message)s", level=logging.INFO)
logging.getLogger("httpx").setLevel(logging.WARNING)  # httpx 的日志会带上 bot token
logger = logging.getLogger("traffic-bot")

BOTO_CFG = Config(connect_timeout=5, read_timeout=20, retries={"max_attempts": 3, "mode": "standard"})
HEX32 = re.compile(r"^[0-9a-fA-F]{32}$")
MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")


# ---------------------------------------------------------------- 数据结构与工具函数
@dataclass
class Metric:
    """一个有额度的指标，用于告警"""
    key: str      # 稳定标识
    label: str    # 告警里显示的名字
    pct: float    # 已用百分比
    period: str   # 周期标识（天/月/重置时间），变化后告警记录自动清零
    detail: str   # 例如 "12,345 / 100,000"
    text: str = ""  # 自定义告警文本（如闲置提醒）；留空则用通用的"已用 x%"格式


@dataclass
class Section:
    text: str
    metrics: list = field(default_factory=list)


def aws_client(service: str, region: str):
    return boto3.client(
        service,
        region_name=region,
        aws_access_key_id=AWS_ACCESS_KEY or None,
        aws_secret_access_key=AWS_SECRET_KEY or None,
        config=BOTO_CFG,
    )


def month_start(dt: datetime) -> datetime:
    return datetime(dt.year, dt.month, 1, tzinfo=timezone.utc)


def next_month_start(dt: datetime) -> datetime:
    return datetime(dt.year + (dt.month == 12), dt.month % 12 + 1, 1, tzinfo=timezone.utc)


def billing_period(now: datetime, day: int):
    """Cloudflare 账期 [起, 止)：每月 day 号 0 点（UTC）切换；短月份自动取当月最后一天"""
    def at(y: int, m: int) -> datetime:
        return datetime(y, m, min(day, calendar.monthrange(y, m)[1]), tzinfo=timezone.utc)

    y, m = now.year, now.month
    start = at(y, m)
    if start > now:
        y, m = (y - 1, 12) if m == 1 else (y, m - 1)
        start = at(y, m)
    ny, nm = (y + 1, 1) if m == 12 else (y, m + 1)
    return start, at(ny, nm)


def status_icon(pct: float) -> str:
    """已用比例 -> 状态图标"""
    if pct >= 95:
        return "🚨"
    if pct >= 80:
        return "⚠️"
    return "✅"


def fmt_bytes(n: float) -> str:
    """十进制单位，和 Cloudflare 控制台一致"""
    n = float(n)
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1000:
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.2f}".rstrip("0").rstrip(".") + unit
        n /= 1000
    return f"{n:.2f}".rstrip("0").rstrip(".") + "TB"


def fmt_num(n: float) -> str:
    """次数的紧凑写法：999 / 12.3K / 1.06M"""
    n = float(n)
    if n < 1e4:
        return f"{n:,.0f}"
    if n < 999_950:
        return f"{n / 1e3:.1f}".rstrip("0").rstrip(".") + "K"
    return f"{n / 1e6:.2f}".rstrip("0").rstrip(".") + "M"


def fmt_gb(n: float) -> str:
    """GB 数值：小于 100 保留一位小数，否则取整"""
    return f"{n:.1f}GB" if n < 100 else f"{n:.0f}GB"


def fmt_ms(us: float) -> str:
    """微秒 -> 毫秒 / 秒"""
    ms = float(us) / 1000
    if ms <= 0:
        return "0ms"
    if ms < 1000:
        return f"{ms:.2f}".rstrip("0").rstrip(".") + "ms"
    return f"{ms / 1000:.2f}".rstrip("0").rstrip(".") + "s"


def fmt_date(dt: datetime) -> str:
    """Nov.1 形式；不用 strftime('%b')，避免受系统语言环境影响"""
    return f"{MONTHS[dt.month - 1]}.{dt.day}"


def bar(pct: float, width: int = 10) -> str:
    filled = min(width, max(0, round(pct / 100 * width)))
    return "▰" * filled + "▱" * (width - filled)


def quota(name: str, pct: float, used: str, total: str, remain: str) -> list:
    """统一的额度展示：两行，已用比例 + 已用/总量 + 剩余"""
    return [f"{status_icon(pct)} {name} {bar(pct)} {pct:.1f}%", f"└ {used} / {total} · 剩 {remain}"]


def fmt_reset(dt: datetime) -> str:
    """距重置还有多久"""
    hours = (dt - datetime.now(timezone.utc)).total_seconds() / 3600
    return f"{hours:.0f}小时" if hours < 48 else f"{math.ceil(hours / 24)}天"


# ---------------------------------------------------------------- BWH
def get_bwh_data() -> Section:
    try:
        resp = requests.get(
            "https://api.64clouds.com/v1/getServiceInfo",
            params={"veid": BWH_VEID, "api_key": BWH_API_KEY},
            timeout=10,
        )
        resp.raise_for_status()
        data = resp.json()
        if data.get("error") not in (0, None):
            return Section(f"🖥 BWH\n❌ 接口返回错误：{data.get('message', data.get('error'))}")

        used_gb = data["data_counter"] / 1024**3
        remain_gb = max(BWH_TOTAL_GB - used_gb, 0)
        reset_ts = data["data_next_reset"]
        reset_dt = datetime.fromtimestamp(reset_ts, timezone.utc)
        remain_days = max(math.ceil((reset_ts - time.time()) / 86400), 1)
        pct = used_gb / BWH_TOTAL_GB * 100

        lines = ["🖥 BWH"]
        lines += quota("流量", pct, fmt_gb(used_gb), fmt_gb(BWH_TOTAL_GB), fmt_gb(remain_gb))
        lines.append(f"🔄 {fmt_reset(reset_dt)}后重置({fmt_date(reset_dt.astimezone(REPORT_TZ))}) · "
                     f"日均可用 {fmt_gb(remain_gb / remain_days)}")
        metric = Metric("bwh", "BWH 流量", pct, str(reset_ts), f"{used_gb:.1f} / {BWH_TOTAL_GB:.0f}GB")
        return Section("\n".join(lines), [metric])
    except Exception as e:
        # 异常信息里可能带有含 api_key 的 URL，必须脱敏后再记录/回显
        safe = str(e).replace(BWH_API_KEY, "***") if BWH_API_KEY else str(e)
        logger.error("BWH 查询失败: %s", safe)
        return Section(f"🖥 BWH\n❌ 查询失败：{type(e).__name__}")


# ---------------------------------------------------------------- AWS Lightsail
def get_aws_data() -> Section:
    """Lightsail 本月流量（入+出），按 UTC 自然月重置"""
    try:
        client = aws_client("lightsail", LIGHTSAIL_REGION)
        now = datetime.now(timezone.utc)
        start, next_reset = month_start(now), next_month_start(now)

        instances, token = [], None
        while True:
            resp = client.get_instances(**({"pageToken": token} if token else {}))
            instances += resp.get("instances", [])
            token = resp.get("nextPageToken")
            if not token:
                break
        if not instances:
            return Section("☁️ Lightsail\n无活跃实例（若有实例，请检查 LIGHTSAIL_REGION）")

        remain_days = max(math.ceil((next_reset - now).total_seconds() / 86400), 1)

        def metric_sum(name: str, metric: str) -> float:
            res = client.get_instance_metric_data(
                instanceName=name, metricName=metric, period=86400,
                startTime=start, endTime=now, unit="Bytes", statistics=["Sum"],
            )
            return sum(p.get("Sum", 0) for p in res.get("metricData", []))

        lines, metrics = ["☁️ Lightsail · 本月"], []
        for inst in instances:
            name = inst["name"]
            quota_gb = inst["networking"]["monthlyTransfer"]["gbPerMonthAllocated"]
            used_gb = (metric_sum(name, "NetworkIn") + metric_sum(name, "NetworkOut")) / 1024**3
            if not quota_gb:
                lines.append(f"{name}：已用 {fmt_gb(used_gb)}（无额度信息）")
                continue
            remain_gb = max(quota_gb - used_gb, 0)
            pct = used_gb / quota_gb * 100
            lines += quota(name, pct, fmt_gb(used_gb), fmt_gb(quota_gb), fmt_gb(remain_gb))
            lines.append(f"   日均可用 {fmt_gb(remain_gb / remain_days)}")
            metrics.append(Metric(f"lightsail:{name}", f"Lightsail {name} 流量", pct,
                                  now.strftime("%Y-%m"), f"{used_gb:.1f} / {quota_gb}GB"))
        lines.append(f"🔄 {fmt_reset(next_reset)}后重置({fmt_date(next_reset)})")
        return Section("\n".join(lines), metrics)
    except Exception as e:
        logger.exception("AWS 查询失败")
        return Section(f"☁️ Lightsail\n❌ 查询失败：{type(e).__name__}: {e}")


# ---------------------------------------------------------------- AWS CloudFront
def get_cloudfront_data() -> Section:
    """CloudFront 本月（UTC）所有 Distribution 的出流量与请求数合计"""
    try:
        now = datetime.now(timezone.utc)
        start, next_reset = month_start(now), next_month_start(now)

        # CloudFront 是全局服务，指标只存在于 us-east-1
        cf = aws_client("cloudfront", "us-east-1")
        dist_ids = []
        for page in cf.get_paginator("list_distributions").paginate():
            dist_ids += [d["Id"] for d in page.get("DistributionList", {}).get("Items", [])]
        if not dist_ids:
            return Section("🌐 CloudFront\n没有找到任何 Distribution")

        cw = aws_client("cloudwatch", "us-east-1")
        totals = {"Requests": 0.0, "BytesDownloaded": 0.0}

        for i in range(0, len(dist_ids), 100):  # 每次最多 200 个查询
            queries = []
            for j, dist_id in enumerate(dist_ids[i:i + 100]):
                for prefix, metric in (("r", "Requests"), ("b", "BytesDownloaded")):
                    queries.append({
                        "Id": f"{prefix}{j}",
                        "MetricStat": {
                            "Metric": {
                                "Namespace": "AWS/CloudFront",
                                "MetricName": metric,
                                "Dimensions": [
                                    {"Name": "DistributionId", "Value": dist_id},
                                    {"Name": "Region", "Value": "Global"},
                                ],
                            },
                            "Period": 86400,
                            "Stat": "Sum",
                        },
                        "ReturnData": True,
                    })

            kwargs = {"MetricDataQueries": queries, "StartTime": start, "EndTime": now}
            while True:
                resp = cw.get_metric_data(**kwargs)
                for r in resp["MetricDataResults"]:
                    key = "Requests" if r["Id"].startswith("r") else "BytesDownloaded"
                    totals[key] += sum(r["Values"])  # 分页时同一 Id 可能多次出现，累加即可
                if not resp.get("NextToken"):
                    break
                kwargs["NextToken"] = resp["NextToken"]

        used_gb = totals["BytesDownloaded"] / 1024**3
        used_req = totals["Requests"]
        gb_pct = used_gb / CLOUDFRONT_LIMIT_GB * 100
        req_pct = used_req / CLOUDFRONT_LIMIT_REQUESTS * 100

        remain_days = max(math.ceil((next_reset - now).total_seconds() / 86400), 1)
        remain_gb = max(CLOUDFRONT_LIMIT_GB - used_gb, 0)
        remain_req = max(CLOUDFRONT_LIMIT_REQUESTS - used_req, 0)

        # 按本月已过时间线性外推月底用量（第 1 天数据太少，不外推）
        elapsed = (now - start).total_seconds()
        month_sec = (next_reset - start).total_seconds()
        lines = [f"🌐 CloudFront · 本月 · {len(dist_ids)}个分发"]
        lines += quota("流量", gb_pct, fmt_gb(used_gb), fmt_gb(CLOUDFRONT_LIMIT_GB), fmt_gb(remain_gb))
        lines += quota("请求", req_pct, fmt_num(used_req), fmt_num(CLOUDFRONT_LIMIT_REQUESTS), fmt_num(remain_req))
        lines.append(f"🔄 {fmt_reset(next_reset)}后重置({fmt_date(next_reset)}) · "
                     f"日均可用 {fmt_gb(remain_gb / remain_days)} / {fmt_num(remain_req / remain_days)}次")
        if elapsed >= 86400:  # 第 1 天数据太少，不外推
            k = month_sec / elapsed
            lines.append(f"📈 预计月底 {fmt_gb(used_gb * k)} / {fmt_num(used_req * k)}次")
        text = "\n".join(lines)
        period = now.strftime("%Y-%m")
        metrics = [
            Metric("cloudfront:gb", "CloudFront 出流量", gb_pct, period,
                   f"{used_gb:.1f} / {CLOUDFRONT_LIMIT_GB:.0f}GB"),
            Metric("cloudfront:req", "CloudFront 请求数", req_pct, period,
                   f"{used_req:,.0f} / {CLOUDFRONT_LIMIT_REQUESTS:,}"),
        ]
        return Section(text, metrics)
    except Exception as e:
        logger.exception("CloudFront 查询失败")
        return Section(f"🌐 CloudFront\n❌ 查询失败：{type(e).__name__}: {e}")


# ---------------------------------------------------------------- Cloudflare
CF_GQL_URL = "https://api.cloudflare.com/client/v4/graphql"
CF_API_URL = "https://api.cloudflare.com/client/v4"

# R2 操作分类（来自官方定价页）。DeleteObject 等免费操作不计入
R2_CLASS_A = {
    "ListBuckets", "PutBucket", "ListObjects", "PutObject", "CopyObject", "CompleteMultipartUpload",
    "CreateMultipartUpload", "LifecycleStorageTierTransition", "ListMultipartUploads", "UploadPart",
    "UploadPartCopy", "ListParts", "PutBucketEncryption", "PutBucketCors", "PutBucketLifecycleConfiguration",
}
R2_CLASS_B = {
    "HeadBucket", "HeadObject", "GetObject", "UsageSummary", "GetBucketEncryption", "GetBucketLocation",
    "GetBucketCors", "GetBucketLifecycleConfiguration",
}
R2_FREE = {"DeleteObject", "DeleteBucket", "AbortMultipartUpload"}

# __FIELDS__ 先试 "requests cpuTimeUs"，该字段不存在时退回 "requests"
Q_WORKERS = """query { viewer { accounts(filter: {accountTag: "__ACC__"}) {
  workersInvocationsAdaptive(limit: 10000, filter: {datetime_geq: "__START__", datetime_leq: "__END__"}) {
    sum { __FIELDS__ }
    dimensions { scriptName }
  } } } }"""

Q_PAGES = """query { viewer { accounts(filter: {accountTag: "__ACC__"}) {
  pagesFunctionsInvocationsAdaptiveGroups(limit: 10000, filter: {datetime_geq: "__START__", datetime_leq: "__END__"}) {
    sum { __FIELDS__ }
  } } } }"""

Q_R2_STORAGE = """query { viewer { accounts(filter: {accountTag: "__ACC__"}) {
  r2StorageAdaptiveGroups(limit: 10000, orderBy: [datetime_DESC], filter: {datetime_geq: "__START__", datetime_leq: "__END__"}) {
    max { payloadSize metadataSize objectCount }
    dimensions { datetime bucketName }
  } } } }"""

Q_R2_OPS = """query { viewer { accounts(filter: {accountTag: "__ACC__"}) {
  r2OperationsAdaptiveGroups(limit: 10000, filter: {datetime_geq: "__START__", datetime_leq: "__END__"}) {
    sum { requests }
    dimensions { __DIMS__ }
  } } } }"""

Q_ZONE_1D = """query { viewer { zones(filter: {zoneTag: "__ZONE__"}) {
  httpRequests1dGroups(limit: 40, filter: {date_geq: "__START__", date_leq: "__END__"}) {
    dimensions { date }
    sum { requests bytes }
  } } } }"""

Q_ZONE_ADAPTIVE = """query { viewer { zones(filter: {zoneTag: "__ZONE__"}) {
  httpRequestsAdaptiveGroups(limit: 1, filter: {datetime_geq: "__START__", datetime_leq: "__END__"}) {
    count
    sum { edgeResponseBytes }
  } } } }"""


Q_D1_USAGE = """query { viewer { accounts(filter: {accountTag: "__ACC__"}) {
  d1AnalyticsAdaptiveGroups(limit: 10000, filter: {date_geq: "__START__", date_leq: "__END__"}) {
    sum { readQueries writeQueries rowsRead rowsWritten }
    dimensions { databaseId }
  } } } }"""

Q_D1_STORAGE = """query { viewer { accounts(filter: {accountTag: "__ACC__"}) {
  d1StorageAdaptiveGroups(limit: 10000, filter: {date_geq: "__START__", date_leq: "__END__"}) {
    max { databaseSizeBytes }
    dimensions { date databaseId }
  } } } }"""


class CFError(Exception):
    pass


def cf_headers() -> dict:
    return {"Authorization": f"Bearer {CLOUDFLARE_API_TOKEN}"}


def cf_graphql(template: str, **params) -> dict:
    query = template
    for k, v in params.items():
        query = query.replace(f"__{k.upper()}__", str(v))
    try:
        resp = requests.post(CF_GQL_URL, json={"query": query}, headers=cf_headers(), timeout=20)
    except requests.RequestException as e:
        raise CFError(f"网络错误 {type(e).__name__}")
    try:
        body = resp.json()
    except ValueError:
        raise CFError(f"HTTP {resp.status_code}，返回内容不是 JSON")
    if body.get("errors"):
        raise CFError("; ".join(str(e.get("message", "?")) for e in body["errors"]))
    if resp.status_code != 200:
        raise CFError(f"HTTP {resp.status_code}")
    return body.get("data") or {}


def cf_account(data: dict) -> dict:
    accounts = (data.get("viewer") or {}).get("accounts") or []
    if not accounts:
        raise CFError("没有返回账号数据，请检查 Account ID 与 Token 的账号范围")
    return accounts[0]


def iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def cf_hint(msg: str) -> str:
    low = msg.lower()
    if "analytics.read" in low and "zone" in low:
        return "（Token 缺少 Zone → Analytics → Read 权限）"
    if any(w in low for w in ("authoriz", "authenticat", "permission", "forbidden", "not have access", "invalid")):
        return "（请检查 Token 权限与资源范围）"
    return ""


def cf_invocations(template: str, dataset: str, **params):
    """返回 (行列表, 是否带 CPU 时间)。优先同时取 cpuTimeUs；该字段不存在时退回只取 requests"""
    try:
        data, cpu_ok = cf_graphql(template, fields="requests cpuTimeUs", **params), True
    except CFError as e:
        logger.info("%s 不支持 cpuTimeUs（%s），退回只查请求数", dataset, e)
        data, cpu_ok = cf_graphql(template, fields="requests", **params), False
    return cf_account(data).get(dataset) or [], cpu_ok


def sum_field(rows: list, name: str) -> int:
    return sum(int((r.get("sum") or {}).get(name) or 0) for r in rows)


def cf_period_usage(now: datetime):
    """账期内（控制台 Usage 页 "Oct 8 - Nov 8" 那一栏）的 (起, 止, 请求数, CPU 微秒或 None)"""
    p_start, p_end = billing_period(now, CLOUDFLARE_BILLING_DAY)
    params = dict(acc=CLOUDFLARE_ACCOUNT_ID, start=iso(p_start), end=iso(now))
    datasets = [(Q_WORKERS, "workersInvocationsAdaptive")]
    if CLOUDFLARE_PAGES_FUNCTIONS:
        datasets.append((Q_PAGES, "pagesFunctionsInvocationsAdaptiveGroups"))
    req, cpu_us, cpu_known = 0, 0, True
    for template, dataset in datasets:
        try:
            rows, cpu_ok = cf_invocations(template, dataset, **params)
        except CFError as e:
            if dataset == "workersInvocationsAdaptive":
                raise
            logger.warning("账期内 Pages Functions 查询失败，未计入：%s", e)
            continue
        req += sum_field(rows, "requests")
        if cpu_ok:
            cpu_us += sum_field(rows, "cpuTimeUs")
        else:
            cpu_known = False
    return p_start, p_end, req, (cpu_us if cpu_known else None)


def cf_workers_block(now: datetime):
    start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    params = dict(acc=CLOUDFLARE_ACCOUNT_ID, start=iso(start), end=iso(now))

    rows, _ = cf_invocations(Q_WORKERS, "workersInvocationsAdaptive", **params)
    per_script, workers_total = {}, 0
    for r in rows:
        n = int((r.get("sum") or {}).get("requests") or 0)
        name = (r.get("dimensions") or {}).get("scriptName") or "?"
        per_script[name] = per_script.get(name, 0) + n
        workers_total += n

    pages_total, note = None, ""
    if CLOUDFLARE_PAGES_FUNCTIONS:
        try:
            prow, _ = cf_invocations(Q_PAGES, "pagesFunctionsInvocationsAdaptiveGroups", **params)
            pages_total = sum_field(prow, "requests")
        except CFError as e:
            logger.warning("Pages Functions 数据集查询失败：%s", e)
            note = "Pages Functions 查询失败，未计入"

    total = workers_total + (pages_total or 0)
    pct = total / CF_WORKERS_DAILY_LIMIT * 100
    reset_h = (start + timedelta(days=1) - now).total_seconds() / 3600
    detail = f"Workers {fmt_num(workers_total)}"
    if pages_total is not None:
        detail += f" + Pages {fmt_num(pages_total)}"
    if note:
        detail += f"（{note}）"

    lines = ["⚡ Workers & Pages · 今日"]
    lines += quota("请求", pct, fmt_num(total), fmt_num(CF_WORKERS_DAILY_LIMIT),
                   fmt_num(max(CF_WORKERS_DAILY_LIMIT - total, 0)))
    lines.append(f"🔄 {reset_h:.0f}小时后重置 · {detail}")

    # 账期汇总：对应控制台 Usage 页下方的 Requests / CPU time 卡片
    try:
        p_start, p_end, p_req, p_cpu = cf_period_usage(now)
        period_line = f"📅 账期 {fmt_date(p_start)} – {fmt_date(p_end)} · 请求 {fmt_num(p_req)}"
        if p_cpu is not None:
            period_line += f" · CPU {fmt_ms(p_cpu)}"
        lines.append(period_line)
    except CFError as e:
        logger.warning("账期用量查询失败：%s", e)

    top = sorted(per_script.items(), key=lambda kv: kv[1], reverse=True)[:3]
    if len(per_script) > 1:
        lines.append("🏆 " + " · ".join(f"{k} {fmt_num(v)}" for k, v in top))
    metric = Metric("cloudflare:workers", "Cloudflare Workers/Pages 今日请求", pct,
                    start.strftime("%Y-%m-%d"), f"{total:,} / {CF_WORKERS_DAILY_LIMIT:,}")
    return lines, [metric]


def cf_r2_buckets():
    """账号下的 R2 存储桶名称列表；接口不可用（例如 Token 没有 R2 读取权限）时返回 None"""
    try:
        resp = requests.get(f"{CF_API_URL}/accounts/{CLOUDFLARE_ACCOUNT_ID}/r2/buckets",
                            headers=cf_headers(), params={"per_page": 1000}, timeout=15)
        body = resp.json()
    except (requests.RequestException, ValueError) as e:
        logger.warning("列出 R2 存储桶失败：%s", type(e).__name__)
        return None
    if resp.status_code != 200 or not body.get("success"):
        logger.info("R2 存储桶列表接口不可用（HTTP %s），改用分析数据推断", resp.status_code)
        return None
    return [b["name"] for b in ((body.get("result") or {}).get("buckets") or []) if b.get("name")]


def cf_r2_block(now: datetime):
    month = now.strftime("%Y-%m")
    empty = ["🪣 R2", "无存储桶实例"]

    # 先问账号里有没有存储桶：没有就不用查（也避免已删除存储桶的历史数据混进来）
    buckets = cf_r2_buckets()
    if buckets is not None and not buckets:
        return empty, []
    names = set(buckets) if buckets else None  # None = 列不出来，只能靠分析数据推断

    lines, metrics = ["🪣 R2 · 本月"], []

    # --- 存储：取每个 bucket 最新的一条快照（payload + metadata）
    try:
        params = dict(acc=CLOUDFLARE_ACCOUNT_ID, start=iso(now - timedelta(days=7)), end=iso(now))
        rows = cf_account(cf_graphql(Q_R2_STORAGE, **params)).get("r2StorageAdaptiveGroups") or []
        latest = {}  # bucket -> (datetime, bytes)
        for r in rows:
            dims, mx = r.get("dimensions") or {}, r.get("max") or {}
            bucket, dt = dims.get("bucketName") or "?", dims.get("datetime") or ""
            if names is not None and bucket not in names:
                continue
            size = int(mx.get("payloadSize") or 0) + int(mx.get("metadataSize") or 0)
            if bucket not in latest or dt > latest[bucket][0]:
                latest[bucket] = (dt, size)
        if names is None and not latest:  # 列不出存储桶，且近 7 天没有任何存储快照 → 视为没有存储桶
            return empty, []
        total = sum(v[1] for v in latest.values())
        limit_bytes = CF_R2_STORAGE_GB * 1e9  # 1GB 按 10^9 字节，偏保守
        pct = total / limit_bytes * 100
        lines += quota("存储", pct, fmt_bytes(total), f"{CF_R2_STORAGE_GB:g}GB",
                       fmt_bytes(max(limit_bytes - total, 0)))
        if len(latest) > 1:
            top = sorted(latest.items(), key=lambda kv: kv[1][1], reverse=True)[:5]
            lines.append("📦 " + " · ".join(f"{b} {fmt_bytes(v[1])}" for b, v in top))
        metrics.append(Metric("cloudflare:r2_storage", "R2 存储", pct, month,
                              f"{fmt_bytes(total)} / {CF_R2_STORAGE_GB:g}GB"))
    except CFError as e:
        lines.append(f"❌ 存储查询失败：{e}{cf_hint(str(e))}")

    # --- 操作次数：本月累计，按 Class A / B 归类
    try:
        params = dict(acc=CLOUDFLARE_ACCOUNT_ID, start=iso(month_start(now)), end=iso(now))
        # 维度从详细到简单依次尝试：带 actionStatus 才能统计失败请求，带 bucketName 才能排除已删除的存储桶
        dim_sets = ["actionType actionStatus bucketName", "actionType actionStatus", "actionType"]
        if names is None:
            dim_sets = dim_sets[1:]
        gq, used_dims = None, ""
        for dset in dim_sets:
            try:
                gq, used_dims = cf_graphql(Q_R2_OPS, dims=dset, **params), dset
                break
            except CFError:
                if dset == dim_sets[-1]:
                    raise
        rows = cf_account(gq).get("r2OperationsAdaptiveGroups") or []
        a = b = other = failed = 0
        per_action = {}  # 计费操作的明细，用来查"是谁在调用 R2"
        for r in rows:
            n = int((r.get("sum") or {}).get("requests") or 0)
            rdims = r.get("dimensions") or {}
            if names is not None and "bucketName" in used_dims and rdims.get("bucketName") not in names:
                continue
            action = rdims.get("actionType") or ""
            if action in R2_CLASS_A:
                a += n
            elif action in R2_CLASS_B:
                b += n
            elif action not in R2_FREE:
                other += n
                continue
            else:
                continue
            per_action[action] = per_action.get(action, 0) + n
            if rdims.get("actionStatus", "success") != "success":
                failed += n
        pa, pb = a / CF_R2_CLASS_A * 100, b / CF_R2_CLASS_B * 100
        lines += quota("Class A", pa, fmt_num(a), fmt_num(CF_R2_CLASS_A), fmt_num(max(CF_R2_CLASS_A - a, 0)))
        lines += quota("Class B", pb, fmt_num(b), fmt_num(CF_R2_CLASS_B), fmt_num(max(CF_R2_CLASS_B - b, 0)))
        if per_action:
            top = sorted(per_action.items(), key=lambda kv: kv[1], reverse=True)[:4]
            lines.append("🔍 " + " · ".join(f"{k} {fmt_num(v)}" for k, v in top))
        if failed:
            lines.append(f"⚠️ 其中 {fmt_num(failed)} 次为失败请求（如访问不存在的文件）")
        if other:
            lines.append(f"❔ 另有 {fmt_num(other)} 次操作未能归类，未计入")
        metrics.append(Metric("cloudflare:r2_a", "R2 Class A 操作", pa, month, f"{a:,} / {CF_R2_CLASS_A:,}"))
        metrics.append(Metric("cloudflare:r2_b", "R2 Class B 操作", pb, month, f"{b:,} / {CF_R2_CLASS_B:,}"))
    except CFError as e:
        lines.append(f"❌ 操作次数查询失败：{e}{cf_hint(str(e))}")
    return lines, metrics


def cf_d1_databases():
    """{database_id: (名称, 字节数或 None)}；接口不可用（Token 没有 D1 读取权限）时返回 None"""
    dbs, page = {}, 1
    try:
        while True:
            resp = requests.get(f"{CF_API_URL}/accounts/{CLOUDFLARE_ACCOUNT_ID}/d1/database",
                                headers=cf_headers(), params={"page": page, "per_page": 100}, timeout=15)
            body = resp.json()
            if resp.status_code != 200 or not body.get("success"):
                logger.info("D1 数据库列表接口不可用（HTTP %s），改用分析数据", resp.status_code)
                return None
            result = body.get("result") or []
            for d in result:
                size = d.get("file_size")
                dbs[d.get("uuid")] = (d.get("name") or d.get("uuid", "?")[:8], int(size) if size is not None else None)
            if len(result) < 100:
                return dbs
            page += 1
    except (requests.RequestException, ValueError) as e:
        logger.warning("列出 D1 数据库失败：%s", type(e).__name__)
        return None


def cf_d1_block(now: datetime):
    today = now.strftime("%Y-%m-%d")
    dbs = cf_d1_databases()
    if dbs is not None and not dbs:
        return ["🗄 D1", "无数据库"], []
    names = {k: v[0] for k, v in (dbs or {}).items()}

    # --- 今日读写行数（整个账号合计，按数据库细分）
    rows = cf_account(cf_graphql(Q_D1_USAGE, acc=CLOUDFLARE_ACCOUNT_ID, start=today, end=today)) \
        .get("d1AnalyticsAdaptiveGroups") or []
    per_db = {}
    for r in rows:
        dbid = (r.get("dimensions") or {}).get("databaseId") or "?"
        sm = r.get("sum") or {}
        acc = per_db.setdefault(dbid, [0, 0, 0, 0])
        for i, k in enumerate(("rowsRead", "rowsWritten", "readQueries", "writeQueries")):
            acc[i] += int(sm.get(k) or 0)
    read = sum(v[0] for v in per_db.values())
    written = sum(v[1] for v in per_db.values())

    # --- 存储：优先用数据库列表里的 file_size，取不到时用分析数据里最近一天的快照
    sizes = {k: v[1] for k, v in (dbs or {}).items() if v[1] is not None}
    if dbs is None or len(sizes) < len(dbs):
        try:
            start = (now - timedelta(days=3)).strftime("%Y-%m-%d")
            srows = cf_account(cf_graphql(Q_D1_STORAGE, acc=CLOUDFLARE_ACCOUNT_ID, start=start, end=today)) \
                .get("d1StorageAdaptiveGroups") or []
            latest = {}
            for r in srows:
                dims = r.get("dimensions") or {}
                dbid, d = dims.get("databaseId") or "?", dims.get("date") or ""
                if dbs is not None and dbid not in dbs:
                    continue  # 已删除的数据库
                if dbid not in latest or d > latest[dbid][0]:
                    latest[dbid] = (d, int((r.get("max") or {}).get("databaseSizeBytes") or 0))
            for dbid, (_, size) in latest.items():
                sizes.setdefault(dbid, size)
        except CFError as e:
            logger.warning("D1 存储数据查询失败：%s", e)
    if dbs is None and not per_db and not sizes:
        return ["🗄 D1", "无数据库（或近 3 天没有任何数据）"], []

    storage = sum(sizes.values())
    lines, metrics = ["🗄 D1 · 今日（全账号共享）"], []
    pr, pw = read / CF_D1_ROWS_READ * 100, written / CF_D1_ROWS_WRITTEN * 100
    lines += quota("读取行", pr, fmt_num(read), fmt_num(CF_D1_ROWS_READ), fmt_num(max(CF_D1_ROWS_READ - read, 0)))
    lines += quota("写入行", pw, fmt_num(written), fmt_num(CF_D1_ROWS_WRITTEN),
                   fmt_num(max(CF_D1_ROWS_WRITTEN - written, 0)))
    limit_bytes = CF_D1_STORAGE_GB * 1e9
    ps = storage / limit_bytes * 100
    lines += quota("存储", ps, fmt_bytes(storage), f"{CF_D1_STORAGE_GB:g}GB", fmt_bytes(max(limit_bytes - storage, 0)))
    reset_h = (now.replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(days=1) - now).total_seconds() / 3600
    lines.append(f"🔄 读写 {reset_h:.0f}小时后重置 · 超额当天查询会报错，不扣费")

    # 每个数据库一行：今日读/写行数、查询次数、大小（单库上限 500MB）
    db_max = CF_D1_DB_MAX_MB * 1e6
    for dbid in sorted(set(per_db) | set(sizes) | set(names),
                       key=lambda k: -(per_db.get(k, [0])[0])):
        r_, w_, rq, wq = per_db.get(dbid, [0, 0, 0, 0])
        size = sizes.get(dbid)
        size_txt = f"{fmt_bytes(size)}/{CF_D1_DB_MAX_MB:g}MB" if size is not None else "大小未知"
        lines.append(f"📁 {names.get(dbid, dbid[:8])} · 读 {fmt_num(r_)} · 写 {fmt_num(w_)} · "
                     f"查询 {fmt_num(rq + wq)} · {size_txt}")
        if size is not None:
            metrics.append(Metric(f"cloudflare:d1_db:{dbid}", f"D1 {names.get(dbid, dbid[:8])} 大小",
                                  size / db_max * 100, "size", f"{fmt_bytes(size)} / {CF_D1_DB_MAX_MB:g}MB"))
    if dbs is None:
        lines.append("ℹ️ Token 没有 D1 Read 权限，数据库名用 ID 前 8 位显示")

    metrics += [
        Metric("cloudflare:d1_read", "D1 今日读取行", pr, today, f"{read:,} / {CF_D1_ROWS_READ:,}"),
        Metric("cloudflare:d1_write", "D1 今日写入行", pw, today, f"{written:,} / {CF_D1_ROWS_WRITTEN:,}"),
        Metric("cloudflare:d1_storage", "D1 存储", ps, "size", f"{fmt_bytes(storage)} / {CF_D1_STORAGE_GB:g}GB"),
    ]
    return lines, metrics


def cf_zone_list():
    """返回 [(显示名, zone_id)]"""
    zones = []
    if CLOUDFLARE_ZONES.strip():
        for item in CLOUDFLARE_ZONES.split(","):
            item = item.strip()
            if not item:
                continue
            label, _, zid = item.rpartition("=")
            zid = zid.strip()
            if not HEX32.match(zid):
                raise CFError(f"CLOUDFLARE_ZONES 里的 Zone ID 格式不对：{item[:40]}")
            zones.append((label.strip() or zid[:8], zid))
        return zones

    try:
        resp = requests.get(f"{CF_API_URL}/zones", headers=cf_headers(), timeout=15,
                            params={"account.id": CLOUDFLARE_ACCOUNT_ID, "per_page": 50, "status": "active"})
        body = resp.json()
    except (requests.RequestException, ValueError) as e:
        raise CFError(f"列出域名失败 {type(e).__name__}")
    if not body.get("success"):
        msg = "; ".join(str(e.get("message", "?")) for e in body.get("errors", []))
        raise CFError(f"自动列出域名失败：{msg}。请给 Token 加 Zone Read 权限，或在配置里填 CLOUDFLARE_ZONES")
    return [(z["name"], z["id"]) for z in body.get("result", [])]


def zone_traffic(zid: str, now: datetime):
    """返回 (本月请求, 本月字节, 今日请求, 今日字节)"""
    ms, today = now.strftime("%Y-%m-01"), now.strftime("%Y-%m-%d")
    try:
        data = cf_graphql(Q_ZONE_1D, zone=zid, start=ms, end=today)
        zones = (data.get("viewer") or {}).get("zones") or []
        if not zones:
            raise CFError("没有返回数据，Token 的 Zone 范围可能不包含此域名")
        rows = zones[0].get("httpRequests1dGroups") or []
        m_req = sum(int((r.get("sum") or {}).get("requests") or 0) for r in rows)
        m_bytes = sum(int((r.get("sum") or {}).get("bytes") or 0) for r in rows)
        t_req = t_bytes = 0
        for r in rows:
            if (r.get("dimensions") or {}).get("date") == today:
                t_req = int((r.get("sum") or {}).get("requests") or 0)
                t_bytes = int((r.get("sum") or {}).get("bytes") or 0)
        return m_req, m_bytes, t_req, t_bytes
    except CFError as e:
        logger.warning("httpRequests1dGroups 失败(%s)，改用 httpRequestsAdaptiveGroups", e)

    # 备用：Adaptive 数据集（至少保留 31 天，本月累计足够）
    def adaptive(start: datetime):
        d = cf_graphql(Q_ZONE_ADAPTIVE, zone=zid, start=iso(start), end=iso(now))
        zs = (d.get("viewer") or {}).get("zones") or []
        if not zs:
            raise CFError("没有返回数据，Token 的 Zone 范围可能不包含此域名")
        rows = zs[0].get("httpRequestsAdaptiveGroups") or []
        if not rows:
            return 0, 0
        return int(rows[0].get("count") or 0), int((rows[0].get("sum") or {}).get("edgeResponseBytes") or 0)

    m_req, m_bytes = adaptive(month_start(now))
    t_req, t_bytes = adaptive(now.replace(hour=0, minute=0, second=0, microsecond=0))
    return m_req, m_bytes, t_req, t_bytes


def cf_cdn_block(now: datetime):
    lines = ["📈 CDN · 本月（免费计划无上限，仅供参考）"]
    zones = cf_zone_list()
    if not zones:
        return lines + [
            "❔ 没有找到域名。可能原因：① 账号下没有托管域名（只用 pages.dev / R2 就没有 CDN 流量可查）；"
            "② Token 缺少 Zone Read 权限，或 Zone Resources 没包含域名。"
            "不想加权限的话，在配置里填 CLOUDFLARE_ZONES=名称=ZoneID 即可"
        ], []
    tot_req = tot_bytes = 0
    for label, zid in zones:
        try:
            m_req, m_bytes, t_req, t_bytes = zone_traffic(zid, now)
        except CFError as e:
            lines.append(f"❌ {label}：查询失败 {e}{cf_hint(str(e))}")
            continue
        tot_req += m_req
        tot_bytes += m_bytes
        lines.append(f"🌍 {label} · 请求 {fmt_num(m_req)} · 流量 {fmt_bytes(m_bytes)}")
        lines.append(f"└ 今日 {fmt_num(t_req)} · {fmt_bytes(t_bytes)}")
    if len(zones) > 1:
        lines.append(f"Σ 合计 · 请求 {fmt_num(tot_req)} · 流量 {fmt_bytes(tot_bytes)}")
    return lines, []


def get_cloudflare_data() -> Section:
    if not HEX32.match(CLOUDFLARE_ACCOUNT_ID):
        return Section("🟠 Cloudflare\n❌ CLOUDFLARE_ACCOUNT_ID 格式不对（应为 32 位十六进制）")
    now = datetime.now(timezone.utc)
    blocks, metrics = [], []
    for name, block in (("Workers & Pages", cf_workers_block), ("R2", cf_r2_block), ("D1", cf_d1_block),
                        ("CDN 流量", cf_cdn_block)):
        try:
            blk_lines, blk_metrics = block(now)
            blocks.append("\n".join(blk_lines))
            metrics += blk_metrics
        except CFError as e:
            blocks.append(f"❌ {name} 查询失败：{e}{cf_hint(str(e))}")
        except Exception as e:
            logger.exception("Cloudflare %s 查询异常", name)
            blocks.append(f"❌ {name} 查询异常：{type(e).__name__}")
    return Section("🟠 Cloudflare\n\n" + "\n\n".join(blocks), metrics)


# ---------------------------------------------------------------- Oracle Cloud
def oci_enabled() -> bool:
    return bool(OCI_TENANCY and OCI_USER and OCI_FINGERPRINT)


def p95(values: list):
    if not values:
        return None
    s = sorted(values)
    return s[max(0, math.ceil(0.95 * len(s)) - 1)]


def oci_hint(e) -> str:
    """把 OCI 的常见错误翻译成能照着改的提示"""
    status, code = getattr(e, "status", None), getattr(e, "code", "")
    if status == 401:
        return "认证失败：OCI_USER / OCI_FINGERPRINT / 私钥三者不匹配，或 API Key 已删除"
    if status == 404 or code == "NotAuthorizedOrNotFound":
        return "没有权限：检查 Policies 里给 traffic-bot-readers 的策略是否已创建"
    if status == 429:
        return "请求过于频繁，稍后会自动恢复"
    if isinstance(e, FileNotFoundError):
        return f"找不到私钥文件 {OCI_KEY_FILE}"
    if isinstance(e, PermissionError):
        return f"bot 读不了私钥文件 {OCI_KEY_FILE}（权限应为 root:trafficbot 640）"
    return f"{type(e).__name__}: {getattr(e, 'message', None) or e}"


def get_oracle_data() -> Section:
    title = f"🔴 Oracle Cloud · {OCI_REGION}"
    try:
        import oci
    except ImportError:
        return Section(f"{title}\n❌ 未安装 oci 库，请重新运行 install.sh")

    try:
        cfg = {"user": OCI_USER, "fingerprint": OCI_FINGERPRINT, "tenancy": OCI_TENANCY,
               "region": OCI_REGION, "key_file": OCI_KEY_FILE}
        oci.config.validate_config(cfg)
        kw = dict(timeout=(5, 30), retry_strategy=oci.retry.DEFAULT_RETRY_STRATEGY)
        identity = oci.identity.IdentityClient(cfg, **kw)
        compute = oci.core.ComputeClient(cfg, **kw)
        monitoring = oci.monitoring.MonitoringClient(cfg, **kw)
        pager = oci.pagination.list_call_get_all_results

        # --- 列出所有 compartment 里的实例，以及 VNIC -> 实例 的对应关系（网络指标按 VNIC 统计）
        comps = [OCI_TENANCY] + [c.id for c in pager(
            identity.list_compartments, OCI_TENANCY, compartment_id_in_subtree=True,
            access_level="ANY", lifecycle_state="ACTIVE").data]
        instances, vnic_owner = [], {}
        for cid in comps:
            instances += [i for i in pager(compute.list_instances, cid).data
                          if i.lifecycle_state not in ("TERMINATED", "TERMINATING")]
            for va in pager(compute.list_vnic_attachments, cid).data:
                if va.lifecycle_state == "ATTACHED":
                    vnic_owner[va.vnic_id] = va.instance_id
        if not instances:
            return Section(f"{title}\n没有找到实例（若有实例，请检查 OCI_REGION）")

        now = datetime.now(timezone.utc)
        start, next_reset = month_start(now), next_month_start(now)
        week_ago = now - timedelta(days=7)

        def mql(namespace: str, query: str, since: datetime) -> dict:
            """返回 {resourceId: [(时间, 值), ...]}；没有数据时返回空 dict"""
            details = oci.monitoring.models.SummarizeMetricsDataDetails(
                namespace=namespace, query=query, start_time=since, end_time=now)
            out = {}
            for md in monitoring.summarize_metrics_data(OCI_TENANCY, details, compartment_id_in_subtree=True).data:
                rid = (md.dimensions or {}).get("resourceId", "?")
                out.setdefault(rid, []).extend((p.timestamp, p.value) for p in md.aggregated_datapoints or [])
            return out

        def by_instance(data: dict) -> dict:
            """VNIC 维度 -> 实例维度，同一时间点的值相加"""
            out = {}
            for vnic, pts in data.items():
                inst = vnic_owner.get(vnic)
                if inst:
                    bucket = out.setdefault(inst, {})
                    for ts, v in pts:
                        bucket[ts] = bucket.get(ts, 0) + v
            return out

        # --- 本月出站（VnicToNetworkBytes = 从实例发往网络的字节）
        egress = {k: sum(v.values()) for k, v in
                  by_instance(mql("oci_vcn", "VnicToNetworkBytes[1d].sum()", start)).items()}
        # --- 近 7 天：CPU（来自 Cloud Agent 监控插件）与网络（来自虚拟网卡，不依赖插件）；仅闲置检测开启时才查
        cpu, net_out, net_in = {}, {}, {}
        if OCI_IDLE_CHECK:
            cpu = {k: [v for _, v in pts] for k, pts in
                   mql("oci_computeagent", "CpuUtilization[5m].mean()", week_ago).items()}
            net_out = by_instance(mql("oci_vcn", "VnicToNetworkBytes[5m].sum()", week_ago))
            net_in = by_instance(mql("oci_vcn", "VnicFromNetworkBytes[5m].sum()", week_ago))

        lines, metrics = [title], []
        period = now.strftime("%Y-%m")
        remain_days = max(math.ceil((next_reset - now).total_seconds() / 86400), 1)

        # --- 出站流量（整个账号合计）
        limit_bytes = OCI_EGRESS_LIMIT_TB * 1e12
        out_total = sum(egress.values())
        pct = out_total / limit_bytes * 100
        lines += quota("出站流量", pct, fmt_bytes(out_total), f"{OCI_EGRESS_LIMIT_TB:g}TB",
                       fmt_bytes(max(limit_bytes - out_total, 0)))
        metrics.append(Metric("oci:egress", "Oracle 出站流量", pct, period,
                              f"{fmt_bytes(out_total)} / {OCI_EGRESS_LIMIT_TB:g}TB"))
        lines.append(f"🔄 {fmt_reset(next_reset)}后重置({fmt_date(next_reset)}) · "
                     f"出站日均可用 {fmt_bytes(max(limit_bytes - out_total, 0) / remain_days)}")

        # --- 闲置回收检测（默认隐藏，OCI_IDLE_CHECK=1 开启）
        if OCI_IDLE_CHECK:
            lines.append("")
            lines.append(f"💤 闲置检测 · 近 7 天（回收线 {OCI_IDLE_LINE:g}%）")
            today = now.strftime("%Y-%m-%d")
            for i in sorted(instances, key=lambda x: x.display_name):
                name = i.display_name
                sc = i.shape_config
                if "A1" in i.shape and sc:
                    shape = f"A1 {sc.ocpus:g}C{sc.memory_in_gbs:g}G"
                elif "Micro" in i.shape:
                    shape = "AMD Micro"
                else:
                    shape = i.shape
                out_line = f"   本月出站 {fmt_bytes(egress.get(i.id, 0))}"
                if i.lifecycle_state != "RUNNING":
                    lines.append(f"⏸ {name}（{shape}）状态 {i.lifecycle_state}")
                    continue

                # 网络利用率 = 每 5 分钟收/发中较大的那个，换算成 bps 后除以实例带宽
                bw_gbps = (sc.networking_bandwidth_in_gbps if sc and sc.networking_bandwidth_in_gbps else 0.05)
                o, n_in = net_out.get(i.id, {}), net_in.get(i.id, {})
                net = [max(o.get(t, 0), n_in.get(t, 0)) * 8 / 300 / (bw_gbps * 1e9) * 100 for t in set(o) | set(n_in)]
                net95 = p95(net)
                samples = cpu.get(i.id, [])
                cpu95 = p95(samples) if len(samples) >= 288 else None  # 不足 1 天的数据不判断
                net_txt = f"网络 {net95:.2f}%" if net95 is not None else "网络 无数据"
                young = " · 开机不满 7 天" if now - i.time_created < timedelta(days=7) else ""

                if cpu95 is None:
                    why = "CPU 无数据" if not samples else "CPU 数据不足 1 天"
                    lines.append(f"❔ {name}（{shape}）{why} · {net_txt}{young}")
                    lines.append("   Cloud Agent 的 Compute Instance Monitoring 插件没在上报，无法判断")
                    lines.append(out_line)
                    continue

                net_low = net95 is None or net95 < OCI_IDLE_LINE
                at_risk = cpu95 < OCI_IDLE_WARN and net_low   # A1 的内存没监控，按最坏情况（偏低）处理
                icon = "🚨" if at_risk and cpu95 < OCI_IDLE_LINE else ("⚠️" if at_risk else "✅")
                lines.append(f"{icon} {name}（{shape}）CPU p95 {cpu95:.1f}% · {net_txt}{young}")
                lines.append(out_line)
                text = ""
                if at_risk:
                    where = f"已低于 {OCI_IDLE_LINE:g}% 回收线" if cpu95 < OCI_IDLE_LINE else f"接近 {OCI_IDLE_LINE:g}% 回收线"
                    text = (f"💤 Oracle {name}（{shape}）近 7 天 CPU p95 只有 {cpu95:.1f}%，{where}，"
                            f"有被当作闲置实例回收的风险。可以跑点持续负载把 CPU 拉上去")
                # 有风险时每天提醒一次；恢复后记录清零
                metrics.append(Metric(f"oci_idle:{i.id}", f"Oracle {name} 闲置", 100 if at_risk else 0,
                                      today, "", text))
            lines.append("ℹ️ 回收需 CPU、网络（A1 还有内存）同时偏低；内存未监控，A1 按最坏情况算")
        return Section("\n".join(lines), metrics)
    except Exception as e:
        logger.exception("Oracle 查询失败")
        return Section(f"{title}\n❌ 查询失败：{oci_hint(e)}")


# ---------------------------------------------------------------- 阿里云 CDT
def cdt_enabled() -> bool:
    return os.path.exists(CDT_STATE_PATH)


def get_aliyun_data() -> Section:
    """读 cdt-guard 的状态快照（不调阿里云 API）。熔断/保活事件由 cdt-guard 自己推送，这里只做展示和额度告警"""
    title = "🟧 Aliyun CDT"
    try:
        with open(CDT_STATE_PATH, encoding="utf-8") as f:
            st = json.load(f)
    except PermissionError:
        return Section(f"{title}\n❌ bot 读不了 {CDT_STATE_PATH}（应为 644，目录 755）")
    except (OSError, ValueError) as e:
        return Section(f"{title}\n❌ 读取状态失败：{type(e).__name__}")
    if "used_gb" not in st:
        err = st.get("last_error", "")
        return Section(f"{title}\n❔ cdt-guard 还没成功查询过" + (f"\n❌ {err[:120]}" if err else ""))

    now = datetime.now(timezone.utc)
    used, quota_gb, limit = float(st["used_gb"]), float(st["quota_gb"]), float(st["limit_gb"])
    pct = used / quota_gb * 100 if quota_gb else 0
    cn_now = now.astimezone(CDT_TZ)
    next_reset = datetime(cn_now.year + (cn_now.month == 12), cn_now.month % 12 + 1, 1, tzinfo=CDT_TZ)
    remain_days = max(math.ceil((next_reset - now).total_seconds() / 86400), 1)
    remain_to_limit = max(limit - used, 0)

    if st.get("cost_locked"):
        guard = "🛑 费用熔断（已关机）"
    elif st.get("locked"):
        guard = "🛑 流量熔断" + ("（已关机）" if st.get("mode") == "stop" else "（安全组已封禁）")
    elif st.get("hold"):
        guard = "⏸ 暂停自动开机"
    else:
        guard = "✅ 守护中"
    mode = "关机" if st.get("mode") == "stop" else "安全组封禁"
    pool = "海外/香港" if st.get("cls") == "international" else "中国内地"

    lines = [f"{title} · 本月 · {pool}"]
    lines += quota("流量", pct, fmt_gb(used), fmt_gb(quota_gb), fmt_gb(max(quota_gb - used, 0)))
    lines.append(f"🛡 {guard} · 熔断线 {limit:g}GB（{mode}）· 距熔断 {fmt_gb(remain_to_limit)}")
    host = st.get("name") or st.get("instance", "?")
    lines.append(f"🖥 {host} · {st.get('status', '?')} · {st.get('ip') or '无公网IP'} · "
                 f"速率 {float(st.get('rate_gbh') or 0):.2f}GB/h")
    if len(st.get("by_region") or {}) > 1:
        lines.append("🗺 " + " · ".join(f"{r} {fmt_gb(g)}" for r, g in sorted(st["by_region"].items())))
    lines.append(f"🔄 {fmt_reset(next_reset)}后重置({fmt_date(next_reset.astimezone(REPORT_TZ))}) · "
                 f"日均可用 {fmt_gb(remain_to_limit / remain_days)}")
    cost_limit = float(st.get("cost_limit") or 0)
    cost_pct = None
    if cost_limit and st.get("cost_cycle") == cn_now.strftime("%Y-%m"):
        cost, cur = float(st.get("cost") or 0), st.get("currency", "USD")
        cost_pct = cost / cost_limit * 100
        lines.append(f"💰 本月应付 {cost:.2f} / 熔断 {cost_limit:g} {cur}（账单有几小时延迟）")
    if st.get("cost_error"):
        lines.append(f"⚠️ 账单查询失败，费用熔断暂时失效：{str(st['cost_error'])[:80]}")

    age_min = (time.time() - float(st.get("updated", 0))) / 60
    stale = age_min >= CDT_STALE_MIN
    if st.get("fail"):
        lines.append(f"⚠️ cdt-guard 最近 {st['fail']} 次查询失败：{str(st.get('last_error', ''))[:100]}")
    if stale:
        lines.append(f"⚠️ 数据已 {age_min:.0f} 分钟未更新，检查 cdt-guard.timer")

    period = cn_now.strftime("%Y-%m")
    metrics = [
        Metric("aliyun:cdt", "阿里云 CDT 流量", pct, period, f"{used:.1f} / {quota_gb:g}GB"),
        *([Metric("aliyun:cost", "阿里云本月费用（相对费用熔断线）", cost_pct, period,
                  f"{float(st.get('cost') or 0):.2f} / {cost_limit:g} {st.get('currency', 'USD')}")]
          if cost_pct is not None else []),
        # 快照长时间不更新 = 熔断失效，每天提醒一次
        Metric("aliyun:cdt_stale", "cdt-guard 状态", 100 if stale else 0, now.strftime("%Y-%m-%d"), "",
               f"⚠️ cdt-guard 已 {age_min:.0f} 分钟没有更新状态，阿里云 CDT 熔断可能失效。"
               f"在服务器上运行 bash init.sh status 检查" if stale else ""),
    ]
    return Section("\n".join(lines), metrics)


# ---------------------------------------------------------------- 汇总 / 缓存
PROVIDERS = [
    (lambda: bool(BWH_API_KEY and BWH_VEID), get_bwh_data),
    (lambda: True, get_aws_data),
    (lambda: True, get_cloudfront_data),
    (lambda: bool(CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID), get_cloudflare_data),
    (oci_enabled, get_oracle_data),
    (cdt_enabled, get_aliyun_data),
]

_cache = {"ts": 0.0, "data": []}
_cache_lock = None


async def collect_sections(max_age: float = 30) -> list:
    """并发查询所有已启用的来源；max_age 秒内的结果复用，避免定时播报与告警检查撞车时重复请求"""
    global _cache_lock
    if _cache_lock is None:
        _cache_lock = asyncio.Lock()
    async with _cache_lock:
        if _cache["data"] and time.monotonic() - _cache["ts"] < max_age:
            return _cache["data"]
        # 几类查询都是阻塞 IO，放到线程里并发执行，避免卡住 bot 事件循环
        results = await asyncio.gather(*(asyncio.to_thread(fn) for enabled, fn in PROVIDERS if enabled()))
        _cache["ts"], _cache["data"] = time.monotonic(), list(results)
        return _cache["data"]


async def build_report(title: str = "📊 用量报告", max_age: float = 30) -> str:
    sections = await collect_sections(max_age)
    now = datetime.now(REPORT_TZ)
    head = f"{title} · {fmt_date(now)} {now:%H:%M} {now.tzname()}"
    interval = f"{REPORT_INTERVAL_SEC / 3600:g}小时" if REPORT_INTERVAL_SEC > 0 else "已关闭"
    alerts = "/".join(f"{t:g}%" for t in ALERT_THRESHOLDS)
    foot = f"⏱ 播报间隔 {interval} · 告警线 {alerts}"
    return head + "\n\n" + "\n\n".join(s.text for s in sections) + "\n\n" + foot


def chunk_text(text: str, limit: int = 3900) -> list:
    """Telegram 单条消息上限 4096 字符，按行拆分"""
    chunks, cur = [], ""
    for line in text.split("\n"):
        if cur and len(cur) + len(line) + 1 > limit:
            chunks.append(cur)
            cur = ""
        cur = f"{cur}\n{line}" if cur else line
    if cur:
        chunks.append(cur)
    return chunks or [""]


# ---------------------------------------------------------------- 告警
def load_state() -> dict:
    try:
        with open(STATE_PATH, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except (ValueError, OSError) as e:
        logger.warning("读取告警状态失败，按空状态处理：%s", e)
        return {}


def save_state(state: dict) -> None:
    try:
        tmp = STATE_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(state, f, ensure_ascii=False)
        os.replace(tmp, STATE_PATH)
    except OSError as e:
        logger.warning("保存告警状态失败（重启后可能重复告警）：%s", e)


def pick_level(pct: float) -> float:
    reached = [t for t in ALERT_THRESHOLDS if pct >= t]
    return max(reached) if reached else 0


def evaluate_alerts(metrics: list, state: dict) -> list:
    """已用比例首次越过更高一档阈值时返回告警文本；周期变化（新的一天/月）后记录清零。会原地更新 state"""
    messages = []
    for m in metrics:
        prev = state.get(m.key) or {}
        prev_level = prev.get("level", 0) if prev.get("period") == m.period else 0
        level = pick_level(m.pct)
        if level > prev_level:
            if m.text:
                messages.append(m.text)
            else:
                icon = "🚨" if level >= 95 else "⚠️"
                messages.append(f"{icon} {m.label} 已用 {m.pct:.1f}%（{m.detail}），超过 {level:g}% 阈值")
        state[m.key] = {"period": m.period, "level": level}
    return messages


async def alert_job(context: ContextTypes.DEFAULT_TYPE):
    chats = ALLOWED_CHAT_IDS or context.application.bot_data.get("chats", set())
    if not chats:
        return
    sections = await collect_sections(max_age=30)
    metrics = [m for s in sections for m in s.metrics]
    old = load_state()
    state = json.loads(json.dumps(old))
    messages = evaluate_alerts(metrics, state)

    delivered = not messages
    if messages:
        text = "🚨 用量告警\n" + "\n".join(messages)
        for chat_id in chats:
            try:
                await context.bot.send_message(chat_id=chat_id, text=text)
                delivered = True
            except Exception:
                logger.exception("告警发送失败 chat_id=%s", chat_id)
    if delivered and state != old:  # 全部发送失败时不落盘，下个周期会重试
        save_state(state)


# ---------------------------------------------------------------- Bot 指令
def restricted(func):
    """只允许 ALLOWED_CHAT_IDS 中的 chat 使用"""
    @wraps(func)
    async def wrapper(update: Update, context: ContextTypes.DEFAULT_TYPE):
        chat = update.effective_chat
        if ALLOWED_CHAT_IDS and (chat is None or chat.id not in ALLOWED_CHAT_IDS):
            logger.warning("拒绝未授权访问 chat_id=%s", chat.id if chat else None)
            return
        return await func(update, context)
    return wrapper


def schedule_report(job_queue, chat_id: int):
    if REPORT_INTERVAL_SEC <= 0:
        return
    name = f"report-{chat_id}"
    if not job_queue.get_jobs_by_name(name):
        job_queue.run_repeating(send_auto_report, interval=REPORT_INTERVAL_SEC, first=30, chat_id=chat_id, name=name)


async def reply_long(update: Update, placeholder, text: str):
    chunks = chunk_text(text)
    await placeholder.edit_text(chunks[0])
    for c in chunks[1:]:
        await update.message.reply_text(c)


@restricted
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat_id = update.effective_chat.id
    context.application.bot_data.setdefault("chats", set()).add(chat_id)
    schedule_report(context.job_queue, chat_id)
    interval = f"每 {REPORT_INTERVAL_SEC / 3600:g} 小时自动播报一次" if REPORT_INTERVAL_SEC > 0 else "定时播报已关闭"
    thresholds = "/".join(f"{t:g}%" for t in ALERT_THRESHOLDS)
    await update.message.reply_text(
        "流量监控助手已启动。\n"
        "/check - 查询全部\n/cloudfront - 只查 CloudFront\n/cloudflare - 只查 Cloudflare\n"
        "/oracle - 只查 Oracle Cloud\n/aliyun - 只查阿里云 CDT\n"
        f"{interval}；用量越过 {thresholds} 会立即推送告警。"
    )


@restricted
async def check(update: Update, context: ContextTypes.DEFAULT_TYPE):
    msg = await update.message.reply_text("正在查询中...")
    await reply_long(update, msg, await build_report(max_age=10))


async def _single(update: Update, label: str, fn):
    msg = await update.message.reply_text(f"正在查询 {label}...")
    section = await asyncio.to_thread(fn)
    await reply_long(update, msg, section.text)


@restricted
async def cloudfront_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await _single(update, "CloudFront", get_cloudfront_data)


@restricted
async def cloudflare_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not (CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID):
        await update.message.reply_text("未配置 CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID")
        return
    await _single(update, "Cloudflare", get_cloudflare_data)


@restricted
async def oracle_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not oci_enabled():
        await update.message.reply_text("未配置 OCI_TENANCY / OCI_USER / OCI_FINGERPRINT")
        return
    await _single(update, "Oracle Cloud", get_oracle_data)


@restricted
async def aliyun_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not cdt_enabled():
        await update.message.reply_text(f"没有找到 {CDT_STATE_PATH}，cdt-guard 还没安装或还没运行过")
        return
    await _single(update, "阿里云 CDT", get_aliyun_data)


async def send_auto_report(context: ContextTypes.DEFAULT_TYPE):
    report = await build_report("🔔 定时播报")
    for c in chunk_text(report):
        await context.bot.send_message(chat_id=context.job.chat_id, text=c)


@restricted
async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        "/start - 开启定时播报与告警\n/check - 查询全部\n"
        "/cloudfront（或 /cf）- 只查 CloudFront\n/cloudflare - 只查 Cloudflare\n"
        "/oracle（或 /oci）- 只查 Oracle Cloud\n"
        "/aliyun（或 /cdt）- 只查阿里云 CDT"
    )


def main():
    if not BOT_TOKEN:
        raise SystemExit("请设置环境变量 BOT_TOKEN")
    if not ALLOWED_CHAT_IDS:
        logger.warning("未设置 ALLOWED_CHAT_IDS，任何人都能查询你的用量，且重启后告警推送对象会丢失！")

    logger.info("定时播报间隔：%s；告警线 %s；告警检查每 %d 分钟",
                f"{REPORT_INTERVAL_SEC / 3600:g} 小时" if REPORT_INTERVAL_SEC > 0 else "已关闭",
                "/".join(f"{t:g}%" for t in ALERT_THRESHOLDS), ALERT_CHECK_SEC // 60)
    app = Application.builder().token(BOT_TOKEN).build()
    if app.job_queue is None:
        raise SystemExit('缺少 job-queue 组件：pip install "python-telegram-bot[job-queue]"')

    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("check", check))
    app.add_handler(CommandHandler(["cloudfront", "cf"], cloudfront_command))
    app.add_handler(CommandHandler("cloudflare", cloudflare_command))
    app.add_handler(CommandHandler(["oracle", "oci"], oracle_command))
    app.add_handler(CommandHandler(["aliyun", "cdt"], aliyun_command))
    app.add_handler(CommandHandler("help", help_command))

    # 启动时直接为白名单 chat 注册定时播报，重启后无需再发 /start
    for chat_id in ALLOWED_CHAT_IDS:
        schedule_report(app.job_queue, chat_id)
    app.job_queue.run_repeating(alert_job, interval=ALERT_CHECK_SEC, first=60, name="alerts")

    app.run_polling(allowed_updates=[Update.MESSAGE])


if __name__ == "__main__":
    main()
