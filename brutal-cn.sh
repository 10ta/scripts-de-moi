#!/usr/bin/env bash
# brutal-cn — 用中国大陆 IP 段维护 TCP Brutal v2 规则（定时更新 + 自愈）
# 单文件：所有配置都在本文件顶部，改完下一轮同步自动生效（REPAIR_INTERVAL 除外，需重跑 install）。
# 用法: bash brutal-cn.sh {install|update|status|uninstall}，不带参数查看说明。
# 运行时只会生成两类非配置文件: systemd 定时器单元，和 /var/lib/brutal-cn 下的列表缓存与状态。

# ═══════════════════════════ 用户配置 ═══════════════════════════
MAX_MBPS=55                 # 最大带宽 (Mbps)：发往大陆地址的速率，填客户端实际能接收的下行带宽
ENABLE_IPV6=auto            # 是否启用 IPv6：auto = 本机有 IPv6 默认路由才启用 / yes / no
IPV6_SOURCE=bigblock        # IPv6 数据源：bigblock = 内置运营商大段 IPV6_BIGBLOCK（推荐）
                            #              apnic    = APNIC 完整数据，合并到 MAX_RULES_V6 条
                            #              manual   = 只用你自己写的 IPV6_MANUAL
UPDATE_INTERVAL_HOURS=24    # 更新间隔 (小时)：多久去 APNIC 检查一次大陆列表

# ─── 个性化（每行一个前缀，可加 # 注释）───
IPV6_MANUAL=(               # IPV6_SOURCE=manual 时使用的 IPv6 列表
)
EXTRA_PREFIXES=(            # 任何模式下都额外加上的前缀，IPv4/IPv6 均可（如出门在港澳台时的网络）
)
EXCLUDE_PREFIXES=(          # 任何模式下都排除的前缀，合并时也不会被覆盖进去（如需要大量上传的大陆机房）
)

# ─── 进阶 ───
MAX_RULES_V4=1000           # IPv4 规则上限。越小合并越粗，误覆盖的非大陆地址越多
                            #   参考（公开大陆列表实测）: 300≈47%  500≈31%  1000≈13%  2000≈4%
MAX_RULES_V6=300            # IPv6 规则上限（仅 IPV6_SOURCE=apnic 时起作用）
REPAIR_INTERVAL=10min       # 自愈检查间隔（规则或路由丢失后多久补回）。改了需重跑 install
APNIC_URLS="https://ftp.apnic.net/stats/apnic/delegated-apnic-latest"   # 可写多个，空格分隔
MIN_V4_PREFIXES=1000        # 解析出的 IPv4 前缀少于此数视为数据异常，继续用旧列表

# ─── 内置数据：大陆 IPv6 运营商大段（IPV6_SOURCE=bigblock）───
# 每次同步都会和 APNIC 大陆数据核对，日志报告覆盖率、没收录的大段、以及不属于大陆分配的段
IPV6_BIGBLOCK=(
    240e::/18          # 中国电信
    2408:8000::/20     # 中国联通
    2409:8000::/20     # 中国移动
    240a:8000::/21     # 中国铁通（移动）
    240a:4000::/21     # 中国广电
    2001:250::/30      # 教育网（原表为 /31，按实际路由扩为 /30）
    2001:da8::/31      # 教育网
    240a:a000::/20     # 教育网
    240c:c000::/20     # 教育网
    240d:4000::/21     # 赛尔
    2400:a980::/29     # 赛尔
    2400:dd00::/28     # 科技网 CSTNET
    2001:4510::/29     # 长城宽带
    240c::/28          # 天地互连
    2406:cf00::/30     # 天地祥云
    2408:4000::/22     # 阿里云
    240c:4000::/22     # 百度
    240f:4000::/24     # 腾讯
    240f:8000::/24     # 亚马逊（北京）
    240f:c000::/24     # 京东
    240a:2000::/24     # 光环新网
    2409:2000::/21     # 华为
    2408:6000::/24     # 中电飞华
    240a:c000::/20     # 中石化
    240c:8000::/21     # 中石油
    240b:2000::/22     # 国家管网
    240b:8000::/21     # 中国经济信息网 / 国家信息中心
    2403:800::/31      # 南方电网
    2409:6000::/20     # 吉利
    240a:6000::/24     # 水利部信息中心
    240d:8000::/24     # 交通运输部公路院
    2409:1000::/20     # 原表未收录，公开大陆 IPv6 列表中存在
    240b:6000::/20     # 原表未收录，公开大陆 IPv6 列表中存在
)
# ════════════════════════════════════════════════════════════════

set -euo pipefail

SELF=$(readlink -f "${BASH_SOURCE[0]}")
STATE_DIR=/var/lib/brutal-cn
RAW=$STATE_DIR/delegated-apnic-latest
CN4=$STATE_DIR/cn4.txt
CN6=$STATE_DIR/cn6.txt
MANAGED=$STATE_DIR/managed.txt
GWFP_FILE=$STATE_DIR/gateway.fp
RATE_FILE=$STATE_DIR/applied_rate
LAST_CHECK=$STATE_DIR/last_check
LOCK=/run/brutal-cn.lock
SVC=/etc/systemd/system/brutal-cn-update.service
TMR=/etc/systemd/system/brutal-cn-update.timer
PROC_RULES=/proc/net/tcp_brutal/rules
LEGACY_BIN=/usr/local/sbin/brutal-cn
LEGACY_CONF=/etc/brutal-cn

log()  { printf '[brutal-cn] %s\n' "$*"; }
warn() { printf '[brutal-cn] WARN %s\n' "$*" >&2; }
die()  { printf '[brutal-cn] ERROR %s\n' "$*" >&2; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请以 root 运行"; }

check_consts() {
    [[ $MAX_MBPS =~ ^[0-9]+([.][0-9]+)?$ ]]  || die "MAX_MBPS 必须是正数: $MAX_MBPS"
    [[ ${ENABLE_IPV6,,} =~ ^(auto|yes|no)$ ]] || die "ENABLE_IPV6 只能是 auto / yes / no"
    [[ $UPDATE_INTERVAL_HOURS =~ ^[0-9]+$ ]] || die "UPDATE_INTERVAL_HOURS 必须是整数"
    [[ $MAX_RULES_V4 =~ ^[0-9]+$ ]] && (( MAX_RULES_V4 >= 10 )) || die "MAX_RULES_V4 至少为 10"
    [[ $MAX_RULES_V6 =~ ^[0-9]+$ ]] && (( MAX_RULES_V6 >= 10 )) || die "MAX_RULES_V6 至少为 10"
    [[ $MIN_V4_PREFIXES =~ ^[0-9]+$ ]] || die "MIN_V4_PREFIXES 必须是整数"
    [[ ${IPV6_SOURCE,,} =~ ^(bigblock|apnic|manual)$ ]] || die "IPV6_SOURCE 只能是 bigblock / apnic / manual"
    if [[ ${IPV6_SOURCE,,} == manual ]] && (( ${#IPV6_MANUAL[@]} == 0 )); then
        die "IPV6_SOURCE=manual 但 IPV6_MANUAL 为空"
    fi
}

# ─── Python 辅助：解析 APNIC、合并前缀、计算增删计划 ────────────────
PY_HELPER=$(cat <<'PY'
import sys, os, ipaddress, heapq, bisect

BOGON4 = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
          "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.168.0.0/16", "198.18.0.0/15",
          "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/3"]
BOGON6 = ["2001:db8::/32"]

def key(n):
    return (n.version, int(n.network_address), n.prefixlen)

def read_nets(path):
    out = []
    if not path or not os.path.isfile(path):
        return out
    with open(path, errors="replace") as f:
        for line in f:
            s = line.split("#", 1)[0].strip()
            if not s:
                continue
            try:
                out.append(ipaddress.ip_network(s, strict=False))
            except ValueError:
                print("WARN 忽略无效前缀: " + s, file=sys.stderr)
    return out

def collapse(nets):
    v4 = ipaddress.collapse_addresses([n for n in nets if n.version == 4])
    v6 = ipaddress.collapse_addresses([n for n in nets if n.version == 6])
    return list(v4) + list(v6)

def subtract(nets, excl):
    if not excl:
        return nets
    out = []
    for n in nets:
        parts = [n]
        for e in excl:
            if e.version != n.version:
                continue
            nxt = []
            for p in parts:
                if p.subnet_of(e):
                    continue
                if e.subnet_of(p):
                    nxt.extend(p.address_exclude(e))
                else:
                    nxt.append(p)
            parts = nxt
        out.extend(parts)
    return out

def write(path, nets):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.writelines(str(n) + "\n" for n in sorted(nets, key=key))
    os.replace(tmp, path)

def merged_intervals(nets):
    iv = sorted((int(n.network_address), int(n.broadcast_address)) for n in nets)
    out = []
    for f, l in iv:
        if out and f <= out[-1][1] + 1:
            out[-1][1] = max(out[-1][1], l)
        else:
            out.append([f, l])
    return [x[0] for x in out], [x[1] for x in out]

def aggregate(nets, max_n, forbid, version):
    """把前缀合并到 max_n 条以内。
    贪心：每一步选"每减少一条规则、新增覆盖的非目标地址最少"的相邻合并。
    不会合并出覆盖 forbid（保留地址、本机地址、排除列表）的前缀。
    返回 (前缀列表, 额外覆盖的地址数)"""
    nets = sorted(nets, key=key)
    n = len(nets)
    if n <= max_n or n < 2:
        return nets, 0
    total = sum(x.num_addresses for x in nets)
    bits_max = 32 if version == 4 else 128
    min_len = 8 if version == 4 else 16
    if version == 4:
        uni = (0, (1 << 32) - 1)
    else:  # 只在全球单播 2000::/3 内合并
        uni = (int(ipaddress.IPv6Address("2000::")),
               int(ipaddress.IPv6Address("3fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff")))
    fs, ls = merged_intervals(forbid)

    def forbidden(a, b):
        k = bisect.bisect_right(fs, b) - 1
        return k >= 0 and ls[k] >= a

    first = [int(x.network_address) for x in nets]
    last = [int(x.broadcast_address) for x in nets]
    plen = [x.prefixlen for x in nets]
    cover = [x.num_addresses for x in nets]
    prv = list(range(-1, n - 1))
    nxt = list(range(1, n + 1))
    nxt[-1] = -1
    alive = [True] * n
    ver = [0] * n

    def cand(i):
        if i < 0 or nxt[i] < 0:
            return None
        j = nxt[i]
        f, l = first[i], last[j]
        bits = bits_max - (f ^ l).bit_length()
        if bits < min_len:
            return None
        host = (1 << (bits_max - bits)) - 1
        sf = f & ~host
        sl = sf | host
        if sf < uni[0] or sl > uni[1] or forbidden(sf, sl):
            return None
        L = i
        while prv[L] >= 0 and first[prv[L]] >= sf:
            L = prv[L]
        R = j
        while nxt[R] >= 0 and last[nxt[R]] <= sl:
            R = nxt[R]
        cnt, s, k = 0, 0, L
        while True:
            cnt += 1
            s += cover[k]
            if k == R:
                break
            k = nxt[k]
        return ((sl - sf + 1 - s) / (cnt - 1), L, R, bits, sf, sl, s, cnt, j)

    heap = []

    def push(i):
        c = cand(i)
        if c:
            heapq.heappush(heap, (c[0], i, ver[i], c[8], ver[c[8]]))

    for i in range(n - 1):
        push(i)
    count = n
    while count > max_n and heap:
        m, i, vi, j, vj = heapq.heappop(heap)
        if not (alive[i] and alive[j] and ver[i] == vi and ver[j] == vj and nxt[i] == j):
            continue
        c = cand(i)
        if c is None:
            continue
        if c[0] != m:  # 周边已变化，按新代价重新排队
            heapq.heappush(heap, (c[0], i, ver[i], j, ver[j]))
            continue
        _, L, R, bits, sf, sl, s, cnt, _ = c
        k = nxt[L]
        while True:
            alive[k] = False
            if k == R:
                break
            k = nxt[k]
        first[L], last[L], plen[L], cover[L] = sf, sl, bits, s
        ver[L] += 1
        nxt[L] = nxt[R]
        if nxt[R] >= 0:
            prv[nxt[R]] = L
        count -= cnt - 1
        push(prv[L])
        push(L)

    Net = ipaddress.IPv4Network if version == 4 else ipaddress.IPv6Network
    out = [Net((first[k], plen[k])) for k in range(n) if alive[k]]
    return out, sum(x.num_addresses for x in out) - total

mode = sys.argv[1]

if mode == "build":
    raw, out4, out6 = sys.argv[2:5]
    nets = []
    with open(raw, errors="replace") as f:
        for line in f:
            p = line.strip().split("|")
            if len(p) < 7 or p[1] != "CN" or p[6] not in ("allocated", "assigned"):
                continue
            try:
                if p[2] == "ipv4":
                    start = ipaddress.IPv4Address(p[3])
                    nets.extend(ipaddress.summarize_address_range(start, start + int(p[4]) - 1))
                elif p[2] == "ipv6":
                    nets.append(ipaddress.IPv6Network(p[3] + "/" + p[4], strict=False))
            except ValueError:
                continue
    nets = collapse(nets)
    v4 = [n for n in nets if n.version == 4]
    v6 = [n for n in nets if n.version == 6]
    write(out4, v4)
    write(out6, v6)
    print(len(v4), len(v6))

elif mode == "plan":
    E = os.environ
    excl = read_nets(E["EXCLUDE"]) + read_nets(E["LOCAL"])
    want = read_nets(E["CN4"]) + read_nets(E["EXTRA"])
    cov6 = miss6 = notcn6 = "-"
    if E["USE_V6"] == "1" and E["V6SRC"] in ("bigblock", "manual"):
        man = read_nets(E["HAND6"])
        want += man
        # 和 APNIC 大陆 IPv6 核对：覆盖率、没收录的大段、不属于大陆的段
        cn6 = list(ipaddress.collapse_addresses(read_nets(E["CN6"])))
        if cn6:
            ms, me = merged_intervals(man)
            cs, ce = merged_intervals(cn6)

            def overlap(n, starts, ends):
                a, b = int(n.network_address), int(n.broadcast_address)
                tot, k = 0, bisect.bisect_right(starts, b) - 1
                while k >= 0 and ends[k] >= a:
                    tot += min(b, ends[k]) - max(a, starts[k]) + 1
                    k -= 1
                return tot

            total = sum(n.num_addresses for n in cn6)
            cov6 = "%.1f" % (sum(overlap(n, ms, me) for n in cn6) / total * 100)
            miss = sorted((n for n in cn6 if overlap(n, ms, me) == 0), key=key)
            miss = sorted(miss, key=lambda n: n.prefixlen)[:5]
            miss6 = ",".join(map(str, miss)) or "-"
            notcn6 = ",".join(str(n) for n in man if overlap(n, cs, ce) == 0) or "-"
    elif E["USE_V6"] == "1":
        want += read_nets(E["CN6"])
    else:
        want = [n for n in want if n.version == 4]
    want = collapse(subtract(collapse(want), excl))

    desired, stats = [], []
    for v, mx, bog in ((4, int(E["MAX4"]), BOGON4), (6, int(E["MAX6"]), BOGON6)):
        part = [n for n in want if n.version == v]
        forbid = [n for n in excl if n.version == v] + [ipaddress.ip_network(b) for b in bog]
        tot = sum(n.num_addresses for n in part)
        agg, extra = aggregate(part, mx, forbid, v)
        desired += agg
        pct = extra / (tot + extra) * 100 if part else 0.0
        stats += [len(part), len(agg), "%.1f" % pct]
    desired = set(desired)

    present = set()
    with open(E["PROC"], errors="replace") as f:
        for line in f:
            for tok in line.split():
                if tok.startswith("dst="):
                    try:
                        present.add(ipaddress.ip_network(tok[4:], strict=False))
                    except ValueError:
                        pass
                    break

    routes = set()
    with open(E["ROUTES"], errors="replace") as f:
        for line in f:
            for tok in line.split()[:2]:
                try:
                    routes.add(ipaddress.ip_network(tok, strict=False))
                    break
                except ValueError:
                    continue

    managed = set(read_nets(E["MANAGED"]))
    force = E.get("FORCE_ALL") == "1"

    adds = [n for n in desired if force or n not in present or n not in routes]
    dels = [n for n in managed - desired if n in present or n in routes]
    unmanaged = [n for n in present if n not in managed and n not in desired]

    # 先 ADD 再 DEL：合并粒度变化时，新旧规则短暂共存，不会出现空窗
    with open(E["PLAN"], "w") as f:
        f.writelines("ADD %s\n" % n for n in sorted(adds, key=key))
        f.writelines("DEL %s\n" % n for n in sorted(dels, key=key))
    write(E["NEW_MANAGED"], desired)
    write(E["UNMANAGED"], unmanaged)
    print(*stats, len(adds), len(dels), len(unmanaged), cov6, miss6, notcn6)
PY
)
run_py() { python3 -c "$PY_HELPER" "$@"; }

# ─── 内核模块 ────────────────────────────────────────────────────────
ensure_module() {
    command -v brutalctl >/dev/null 2>&1 || die "未找到 brutalctl，请先运行: bash brutal-cn.sh install"
    if [[ ! -e $PROC_RULES ]]; then
        local m
        for m in brutal tcp_brutal; do
            if modprobe "$m" 2>/dev/null; then break; fi
        done
    fi
    [[ -e $PROC_RULES ]] || die "TCP Brutal v2 模块未加载（$PROC_RULES 不存在）。内核升级后请检查: dkms status"
}

decide_v6() {
    case ${ENABLE_IPV6,,} in
        yes) echo 1 ;;
        no)  echo 0 ;;
        *)   if [[ -n $(ip -6 route show default 2>/dev/null) ]]; then echo 1; else echo 0; fi ;;
    esac
}

# 默认路由指纹：只取 via/dev，忽略 expires 等会变动的字段
gateway_fp() {
    {
        ip -4 -o route show default 2>/dev/null
        ip -6 -o route show default 2>/dev/null
    } | awk '{ s=""; for (i=1;i<=NF;i++) if ($i=="via" || $i=="dev") s = s $i " " $(i+1) " "; print s }' \
      | sort | sha256sum | cut -c1-16
}

# 本机地址和网关：合并时绝不覆盖它们
local_addrs() {
    ip -o addr show scope global 2>/dev/null | awk '{ split($4, a, "/"); print a[1] }'
    { ip -4 -o route show default; ip -6 -o route show default; } 2>/dev/null \
        | awk '{ for (i=1;i<NF;i++) if ($i=="via") print $(i+1) }'
}

# ─── 下载并生成大陆列表 ──────────────────────────────────────────────
refresh_list() {
    local force=$1 due=0
    if [[ $force == 1 || ! -s $CN4 || ! -f $LAST_CHECK ]]; then
        due=1
    elif [[ -n $(find "$LAST_CHECK" -mmin +$(( UPDATE_INTERVAL_HOURS * 60 )) 2>/dev/null) ]]; then
        due=1
    fi
    if [[ $due != 1 ]]; then return 0; fi

    local tmp url code got=0
    tmp=$(mktemp "$STATE_DIR/dl.XXXXXX")
    for url in $APNIC_URLS; do
        local zopt=()
        if [[ -s $RAW && $force != 1 ]]; then zopt=(-z "$RAW"); fi
        code=$(curl -sSL --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 300 \
                    -R "${zopt[@]}" -o "$tmp" -w '%{http_code}' "$url") || code=000
        if [[ $code == 200 && -s $tmp ]]; then got=1; break; fi
        if [[ $code == 304 ]]; then log "APNIC 数据未变化"; got=2; break; fi
        warn "下载失败: $url (HTTP $code)"
    done

    local src
    case $got in
        1) src=$tmp ;;
        2) if [[ -s $CN4 ]]; then rm -f "$tmp"; touch "$LAST_CHECK"; return 0; fi
           src=$RAW ;;
        *) rm -f "$tmp"
           if [[ -s $CN4 ]]; then warn "下载失败，继续使用缓存列表"; return 0; fi
           return 1 ;;
    esac

    local counts c4 c6
    if ! counts=$(run_py build "$src" "$CN4.new" "$CN6.new"); then
        warn "解析 APNIC 数据失败，保留旧列表"
        rm -f "$tmp" "$CN4.new" "$CN6.new"
        return 0
    fi
    read -r c4 c6 <<<"$counts"
    if (( c4 < MIN_V4_PREFIXES )); then
        warn "只解析出 $c4 条 IPv4 前缀，疑似数据异常，保留旧列表"
        rm -f "$tmp" "$CN4.new" "$CN6.new"
        return 0
    fi
    mv -f "$CN4.new" "$CN4"
    mv -f "$CN6.new" "$CN6"
    if [[ $got == 1 ]]; then mv -f "$tmp" "$RAW"; fi
    rm -f "$tmp"
    touch "$LAST_CHECK"
    log "大陆列表已更新: 原始 IPv4 $c4 条 / IPv6 $c6 条（合并前）"
}

# ─── update：同步规则 ────────────────────────────────────────────────
cmd_update() {
    local force_dl=0
    if [[ ${1:-} == --force-download ]]; then force_dl=1; fi
    need_root
    check_consts
    mkdir -p "$STATE_DIR"
    touch "$MANAGED"

    exec 9>"$LOCK"
    flock -w 900 9 || die "另一次同步仍在运行"

    ensure_module
    refresh_list "$force_dl" || die "没有可用的大陆 IP 列表（下载失败且无缓存）"

    local use6 fp force_all=0 last_rate=""
    use6=$(decide_v6)
    fp=$(gateway_fp)
    if [[ -f $GWFP_FILE && $(cat "$GWFP_FILE") != "$fp" ]]; then
        log "默认路由已变化，重建全部规则的路由"
        force_all=1
    fi
    if [[ -f $RATE_FILE ]]; then last_rate=$(cat "$RATE_FILE"); fi
    if [[ -n $last_rate && $last_rate != "$MAX_MBPS" ]]; then
        log "带宽 ${last_rate} → ${MAX_MBPS} Mbps，更新全部规则"
        force_all=1
    fi

    # 全局变量：EXIT trap 触发时函数的局部变量已经失效
    WORK_DIR=$(mktemp -d)
    trap 'rm -rf "${WORK_DIR:-}"' EXIT
    local work=$WORK_DIR

    cat "$PROC_RULES" > "$work/proc"
    {
        ip -4 -o route show table all proto 233 2>/dev/null || true
        ip -6 -o route show table all proto 233 2>/dev/null || true
    } > "$work/routes"
    local_addrs > "$work/local" || true

    local out raw4 n4 pct4 raw6 n6 n_add n_del n_unm cov6 miss6 notcn6
    local v6src=${IPV6_SOURCE,,} hand_name=IPV6_BIGBLOCK
    if [[ $v6src == manual ]]; then
        hand_name=IPV6_MANUAL
        printf '%s\n' "${IPV6_MANUAL[@]}" > "$work/hand6"
    else
        printf '%s\n' "${IPV6_BIGBLOCK[@]}" > "$work/hand6"
    fi
    printf '%s\n' "${EXTRA_PREFIXES[@]}" > "$work/extra"
    printf '%s\n' "${EXCLUDE_PREFIXES[@]}" > "$work/exclude"
    out=$(CN4=$CN4 CN6=$CN6 EXTRA=$work/extra EXCLUDE=$work/exclude LOCAL=$work/local USE_V6=$use6 \
          MAX4=$MAX_RULES_V4 MAX6=$MAX_RULES_V6 V6SRC=$v6src HAND6=$work/hand6 \
          PROC=$work/proc ROUTES=$work/routes MANAGED=$MANAGED FORCE_ALL=$force_all \
          PLAN=$work/plan NEW_MANAGED=$work/new_managed UNMANAGED=$work/unmanaged \
          run_py plan) || die "生成同步计划失败"
    read -r raw4 n4 pct4 raw6 n6 _ n_add n_del n_unm cov6 miss6 notcn6 <<<"$out"

    local total=$(( n_add + n_del ))
    if (( total > 200 )); then log "需要处理 $total 条规则，请稍候..."; fi

    local act pfx err i=0 added=0 deleted=0 failed=0 v6_broken=0 v6_skipped=0
    : > "$work/failed_del"
    while read -r act pfx; do
        i=$(( i + 1 ))
        case $act in
            ADD)
                if [[ $pfx == *:* && $v6_broken == 1 ]]; then
                    v6_skipped=$(( v6_skipped + 1 ))
                    continue
                fi
                if err=$(brutalctl add "$pfx" "$MAX_MBPS" 2>&1 >/dev/null); then
                    added=$(( added + 1 ))
                else
                    failed=$(( failed + 1 ))
                    if (( failed <= 5 )); then warn "add $pfx 失败: $err"; fi
                    if [[ $pfx == *:* ]]; then
                        v6_broken=1
                        warn "IPv6 规则添加失败，本轮跳过其余 IPv6（本机 IPv6 路由或 brutalctl 可能不支持）"
                    fi
                fi
                ;;
            DEL)
                if brutalctl del "$pfx" >/dev/null 2>&1; then
                    deleted=$(( deleted + 1 ))
                else
                    echo "$pfx" >> "$work/failed_del"
                    failed=$(( failed + 1 ))
                fi
                ;;
        esac
        if (( i % 200 == 0 )); then log "进度 $i/$total"; fi
    done < "$work/plan"

    sort -u "$work/new_managed" "$work/failed_del" > "$MANAGED.tmp"
    mv -f "$MANAGED.tmp" "$MANAGED"
    echo "$fp" > "$GWFP_FILE"
    echo "$MAX_MBPS" > "$RATE_FILE"

    local v6_desc="IPv6 未启用"
    if [[ $use6 == 1 ]]; then v6_desc="IPv6(${IPV6_SOURCE,,}) $raw6→$n6 条"; fi
    log "同步完成 @ ${MAX_MBPS} Mbps | IPv4 $raw4→$n4 条（误覆盖非大陆地址 ${pct4}%）| $v6_desc | 新增/修复 $added, 删除 $deleted, 失败 $failed${v6_skipped:+, 跳过 IPv6 $v6_skipped}"

    if [[ $cov6 != - ]]; then
        log "$hand_name 覆盖 APNIC 大陆 IPv6 地址 ${cov6}%"
        if [[ $miss6 != - ]]; then log "  未收录的最大几段: ${miss6//,/ }（需要的话加进 $hand_name）"; fi
        if [[ $notcn6 != - ]]; then warn "  $hand_name 中这些段不属于 APNIC 大陆分配: ${notcn6//,/ }"; fi
    fi

    if (( n_unm > 0 )); then
        warn "有 $n_unm 条 brutal 规则不是本工具创建的，它们仍然生效（示例）:"
        head -n 5 "$work/unmanaged" | sed 's/^/          /' >&2
        warn "如果是以前手动加的列表，确认不需要后运行: bash $SELF install --flush-existing"
    fi
}

# ─── status ──────────────────────────────────────────────────────────
cmd_status() {
    check_consts
    local v6_now="关闭"
    if [[ $(decide_v6) == 1 ]]; then v6_now="启用"; fi
    echo "── 配置 ─────────────────────────────"
    echo "  最大带宽: ${MAX_MBPS} Mbps   IPv6: ${ENABLE_IPV6}（当前: ${v6_now}，数据源: ${IPV6_SOURCE}）   更新间隔: ${UPDATE_INTERVAL_HOURS}h"
    echo "  规则上限: IPv4 ${MAX_RULES_V4} / IPv6 ${MAX_RULES_V6}   自愈间隔: ${REPAIR_INTERVAL}"
    if [[ -f $LAST_CHECK ]]; then echo "  上次检查列表: $(date -r "$LAST_CHECK" '+%F %T')"; fi
    echo "── 定时器 ───────────────────────────"
    systemctl list-timers brutal-cn-update.timer --no-pager 2>/dev/null | sed 's/^/  /' || true
    echo "── 内核 ─────────────────────────────"
    if [[ -e $PROC_RULES ]]; then
        echo "  规则总数: $(wc -l < "$PROC_RULES")   本工具管理: $(wc -l < "$MANAGED" 2>/dev/null || echo 0)   proto 233 路由: $( { ip -4 -o route show table all proto 233; ip -6 -o route show table all proto 233; } 2>/dev/null | wc -l)"
        echo "  当前有连接的规则:"
        awk '{
                for (i = 1; i <= NF; i++) { split($i, a, "="); k[a[1]] = a[2] }
                if (k["members"] + 0 > 0) printf "    %-26s members=%-4s sent=%.1f MB\n", k["dst"], k["members"], k["sent"] / 1048576
                delete k
             }' "$PROC_RULES"
    else
        echo "  模块未加载"
    fi
    echo "── 最近日志 ─────────────────────────"
    journalctl -u brutal-cn-update.service -n 6 --no-pager -o cat 2>/dev/null | sed 's/^/  /' || true
}

# ─── install ─────────────────────────────────────────────────────────
# 清理旧版本留下的文件（旧版会复制脚本到 /usr/local/sbin，并用 /etc/brutal-cn 放列表）
cleanup_legacy() {
    if [[ -e $LEGACY_BIN && $(readlink -f "$LEGACY_BIN") != "$SELF" ]]; then
        rm -f "$LEGACY_BIN"
        log "已删除旧版副本 $LEGACY_BIN"
    fi
    if [[ -d $LEGACY_CONF ]]; then
        local leftover
        leftover=$(grep -hv '^[[:space:]]*\(#\|$\)' "$LEGACY_CONF"/extra.txt "$LEGACY_CONF"/exclude.txt 2>/dev/null || true)
        if [[ -n $leftover ]]; then
            warn "$LEGACY_CONF 里还有你写的前缀，请搬到脚本的 EXTRA_PREFIXES / EXCLUDE_PREFIXES 后手动删除该目录:"
            printf '%s\n' "$leftover" | sed 's/^/          /' >&2
        else
            rm -rf "$LEGACY_CONF"
            log "已删除旧版配置目录 $LEGACY_CONF"
        fi
    fi
}

write_units() {
    cat > "$SVC" <<EOF
[Unit]
Description=TCP Brutal 大陆 IP 规则同步
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash "$SELF" update
TimeoutStartSec=30min
Nice=10
EOF
    cat > "$TMR" <<EOF
[Unit]
Description=TCP Brutal 大陆 IP 规则定时同步与自愈

[Timer]
OnBootSec=20s
OnUnitActiveSec=${REPAIR_INTERVAL}
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
}

ensure_deps() {
    local pkgs=()
    command -v curl  >/dev/null 2>&1 || pkgs+=(curl)
    command -v ip    >/dev/null 2>&1 || pkgs+=(iproute2)
    command -v flock >/dev/null 2>&1 || pkgs+=(util-linux)
    if ! python3 -c 'import ipaddress, heapq, bisect' >/dev/null 2>&1; then pkgs+=(python3); fi
    if (( ${#pkgs[@]} > 0 )); then
        log "安装依赖: ${pkgs[*]}"
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
    fi
}

cmd_install() {
    need_root
    check_consts
    command -v systemctl >/dev/null 2>&1 || die "需要 systemd"
    local flush=0
    if [[ ${1:-} == --flush-existing ]]; then flush=1; fi

    [[ -f $SELF ]] || die "请先把脚本保存为本地文件再运行（不支持 curl | bash 方式）"
    case $SELF in
        /tmp/*|/var/tmp/*|/dev/*|/proc/*) die "定时器会直接调用本脚本，请放到固定位置（如 /root 或 /opt）再运行 install" ;;
    esac

    ensure_deps
    if ! command -v brutalctl >/dev/null 2>&1; then
        log "未找到 brutalctl，调用官方安装脚本 https://tcp.hy2.sh/ ..."
        bash <(curl -fsSL https://tcp.hy2.sh/)
        hash -r
    fi
    ensure_module

    mkdir -p "$STATE_DIR"
    cleanup_legacy
    write_units
    systemctl daemon-reload

    if [[ $flush == 1 ]]; then
        warn "--flush-existing: 清空本机全部 brutal 规则（包括不是本工具创建的）"
        brutalctl flush
        : > "$MANAGED"
    fi

    # 先前台同步一次（能看到进度），再启用定时器
    bash "$SELF" update
    systemctl enable --now brutal-cn-update.timer >/dev/null 2>&1
    systemctl restart brutal-cn-update.timer

    log "✅ 安装完成。每 ${REPAIR_INTERVAL} 自愈检查一次，每 ${UPDATE_INTERVAL_HOURS}h 检查列表更新"
    log "   定时器直接调用 $SELF，移动或改名后需要重跑 install"
    log "   查看状态: bash $SELF status    改配置: 编辑本文件顶部"
}

# ─── uninstall ───────────────────────────────────────────────────────
cmd_uninstall() {
    need_root
    systemctl disable --now brutal-cn-update.timer >/dev/null 2>&1 || true
    systemctl stop brutal-cn-update.service >/dev/null 2>&1 || true

    exec 9>"$LOCK"
    flock -w 900 9 || die "同步仍在运行，请稍后再试"

    local p n=0
    if [[ -s $MANAGED ]] && command -v brutalctl >/dev/null 2>&1; then
        log "删除本工具创建的规则..."
        while read -r p; do
            if [[ -n $p ]] && brutalctl del "$p" >/dev/null 2>&1; then n=$(( n + 1 )); fi
        done < "$MANAGED"
    fi
    rm -f "$SVC" "$TMR"
    systemctl daemon-reload
    rm -rf "$STATE_DIR"
    rm -f "$LOCK"
    if [[ -e $LEGACY_BIN && $(readlink -f "$LEGACY_BIN") != "$SELF" ]]; then rm -f "$LEGACY_BIN"; fi
    log "✅ 已卸载，删除规则 $n 条。本脚本文件、brutalctl 和内核模块保留，其他规则未动。"
}

usage() {
    cat <<'EOF'
brutal-cn — 用中国大陆 IP 段维护 TCP Brutal v2 规则（定时更新 + 自愈）

  bash brutal-cn.sh install [--flush-existing]   安装/重装（幂等，可反复运行）
                                                 --flush-existing 会清空本机全部 brutal 规则
  bash brutal-cn.sh update [--force-download]    立即同步一次
  bash brutal-cn.sh status                       查看状态
  bash brutal-cn.sh uninstall                    删除本工具创建的规则、定时器和缓存

所有配置都在本文件顶部。
EOF
}

case ${1:-} in
    install)   shift; cmd_install "$@" ;;
    update)    shift; cmd_update "$@" ;;
    status)    cmd_status ;;
    uninstall) cmd_uninstall ;;
    *)         usage ;;
esac
