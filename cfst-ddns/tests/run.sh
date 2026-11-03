#!/usr/bin/env bash
# cfst-ddns 离线测试：用假的 cfst 和假的 curl（Cloudflare API / Telegram / DoH / Sonde）跑完整流程，不联网、不用 root。
# 用法：bash cfst-ddns/tests/run.sh        需要：bash、jq、awk、flock
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../cfst-ddns.sh"
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✔ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ✘ %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/      /'; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "$(tail -n 15 "$T/out.log" 2>/dev/null)"; fi; }

# ---------- 假 cfst：按 $T/table（ip,延迟,丢包,速度,机房）出结果；网段按前三段匹配表里第一个 IP ----------
make_fakes() {
  mkdir -p "$T/bin" "$T/opt" "$T/state"
  cat > "$T/opt/cfst" <<'EOF'
#!/usr/bin/env bash
f=; out=; dd=; prev=
for a in "$@"; do [[ $prev == -f ]] && f=$a; [[ $prev == -o ]] && out=$a; [[ $a == -dd ]] && dd=1; prev=$a; done
echo "cfst $*" >> "$T/cfst.calls"
rows=$(while read -r e; do
  [[ -n "$e" ]] || continue
  if [[ $e == */* ]]; then p=${e%.*}.; r=$(grep -m1 "^${p//./\\.}" "$T/table") || continue
  else r=$(grep -m1 "^${e//./\\.}," "$T/table") || continue; fi
  IFS=, read -r ip lat loss sp colo <<<"$r"
  if [[ -n $dd ]]; then echo "$ip,4,4,$loss,$lat,0.00,N/A"; else echo "$ip,4,4,$loss,$lat,$sp,$colo"; fi
done < "$f" | awk -F, '!s[$1]++')
[[ -n "$rows" ]] || exit 0                      # 真 cfst 一个结果都没有时不写文件
{ echo 'IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码'
  if [[ -n $dd ]]; then sort -t, -k4,4g -k5,5g <<<"$rows"; else sort -t, -k6,6gr <<<"$rows"; fi; } > "$out"
EOF
  # ---------- 假 curl：记下每次的命令行（检查 token 不在里面），读 -K - 传进来的 url / header ----------
  cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$T/argv.log"
url=; hdr=; m=GET; data=; text=; head=; prev=
for a in "$@"; do
  [[ $prev == -X ]] && m=$a; [[ $prev == --data ]] && data=$a
  [[ $prev == -H && $a == Authorization:* ]] && hdr=$a      # 老写法（token 在命令行里）也认，token 检查另外做
  [[ $prev == --data-urlencode && $a == text=* ]] && text=${a#text=}
  [[ $a == -I ]] && head=1
  [[ -z $url && $a =~ ^https?:// ]] && url=$a
  [[ $prev == -K && $a == - ]] && while IFS= read -r l; do
      [[ $l =~ ^url\ =\ \"(.*)\"$ ]] && url=${BASH_REMATCH[1]}
      [[ $l =~ ^header\ =\ \"(.*)\"$ ]] && hdr=${BASH_REMATCH[1]}
    done
  prev=$a
done
if [[ -n $head ]]; then printf 'HTTP/2 200\r\ncf-ray: 8abc-HKG\r\n'; exit 0; fi
case "$url" in
  *dns.alidns.com*) n=$(sed -E 's/.*name=([^&]*).*/\1/' <<<"$url"); cat "$T/doh.$n" 2>/dev/null || echo '{"Status":3}' ;;
  *api.telegram.org/bot*/sendMessage)
    printf '%s\n-----\n' "$text" >> "$T/tg.log"; echo '{"ok":true}' ;;
  *api.cloudflare.com*)
    if [[ -e "$T/cf_fail" || $hdr != "Authorization: Bearer $CF_API_TOKEN" ]]; then
      echo '{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}'; exit 0; fi
    if [[ $m == GET ]]; then
      n=$(sed -E 's/.*name=([^&]*).*/\1/' <<<"$url")
      if [[ -s "$T/dns.$n" ]]; then echo "{\"success\":true,\"result\":[{\"id\":\"r1\",\"content\":\"$(cat "$T/dns.$n")\"}]}"
      else echo '{"success":true,"result":[]}'; fi
    else n=$(jq -r .name <<<"$data"); jq -r .content <<<"$data" > "$T/dns.$n"; echo '{"success":true,"result":{}}'; fi ;;
  */ingest) printf 200 ;;
  *) cat "$T/page" 2>/dev/null ;;
esac
EOF
  chmod +x "$T/opt/cfst" "$T/bin/curl"
}

# 每个场景一个干净的环境
fresh() {
  T=$(mktemp -d); export T
  make_fakes
  printf '%s\n' 104.17.0.0/24 104.18.0.0/24 104.19.0.0/24 104.20.0.0/24 104.21.0.0/24 104.22.0.0/24 > "$T/opt/ip.txt"
  printf '%s\n' 104.17.0.9,52,0.00,8.20,HKG 104.18.0.9,175,0.00,7.60,LAX 104.19.0.9,60,0.00,6.00,HKG \
                104.20.0.9,170,0.00,12.00,SJC 104.21.0.9,80,0.00,5.00,NRT 104.22.0.9,190,0.00,4.00,LHR > "$T/table"
  echo 104.17.0.9 > "$T/dns.cf.example.com"
  export PATH="$T/bin:$PATH" CFST_DIR="$T/opt" STATE_DIRECTORY="$T/state" TIMEZONE=UTC PROGRESS_EVERY=999
  export CF_API_TOKEN=cf-SECRET-token CF_ZONE_ID=zone CF_RECORD_NAME=cf.example.com TARGETS=cloudflare
  export TG_BOT_TOKEN=123:BOT-SECRET TG_CHAT_ID=1 TG_NOTIFY=all TG_NOTIFY_CHECK=off
  export RANK_BY=download LATENCY_SPLIT=150 PICK_PER_GROUP=3 MIN_SPEED=1 SPEED_TOLERANCE=0 SWITCH_MARGIN=20
  export CFST_ARGS="-tl 250 -dt 5" FULL_MIN_GAP=120 FULL_AT=00:00
  unset SEEDS_DNS SEEDS_URL SEED_ALLOW_OUTSIDE SONDE_URL SONDE_TOKEN
}
run() { bash "$SCRIPT" "$@" >> "$T/out.log" 2>&1; }
dns() { cat "$T/dns.cf.example.com"; }
scans() { grep -c -- '-f scan.txt' "$T/cfst.calls" 2>/dev/null || echo 0; }
tg_count() { grep -c "$1" "$T/tg.log" 2>/dev/null || echo 0; }
pool_size() { echo $(( $(wc -l < "$T/state/cloudflare/pool.csv") - 1 )); }

echo "全量扫描选最快的并更新 DNS"
fresh; run full
check "DNS 改成最快的 104.20.0.9" '[[ $(dns) == 104.20.0.9 ]]'
check "发了「已更新」简报" '(( $(tg_count 已更新) == 1 ))'
check "简报里没有 IP 和域名" '! grep -qE "104\.|example\.com" "$T/tg.log"'
check "token 没出现在任何 curl 命令行里" '! grep -qE "SECRET" "$T/argv.log"'

echo "巡检健康时不发简报（TG_NOTIFY_CHECK=off）"
run check
check "日志写了健康" 'grep -q "^健康" "$T/out.log"'
check "没有多发简报" '(( $(grep -c -- "-----" "$T/tg.log") == 1 ))'

echo "直连不通、还没有榜单：不会每 5 分钟全量扫描（P1）"
fresh; : > "$T/table"
run auto; run auto; run auto
check "3 次 auto 只扫描 1 次" '(( $(scans) == 1 ))'
check "失败简报只发 1 条" '(( $(tg_count 更新失败) == 1 ))'
FULL_MIN_GAP=0 run auto
check "过了 FULL_MIN_GAP 会重试" '(( $(scans) == 2 ))'
check "同样的失败 2 小时内不重复发简报" '(( $(tg_count 更新失败) == 1 ))'

echo "复测时暂时连不上的旧成员留在榜单里（P2）"
fresh; PICK_PER_GROUP=3 run full
before=$(pool_size)
printf '%s\n' 104.17.0.9,52,0.00,8.20,HKG 104.18.0.9,175,0.00,7.60,LAX 104.20.0.9,170,0.00,12.00,SJC > "$T/table"
run pool
check "榜单大小不变（$before 个）" '(( $(pool_size) == before ))'
check "日志说明暂时保留" 'grep -q "暂时保留" "$T/out.log"'

echo "速度容差：速度相当时切到延迟低的"
fresh
printf '%s\n' 104.17.0.9,190,0.00,8.79,LHR 104.18.0.9,55,0.00,7.50,HKG > "$T/table"
SPEED_TOLERANCE=20 run full
check "切到 104.18.0.9" '[[ $(dns) == 104.18.0.9 ]]'
check "说明写「速度相当」" 'grep -q "速度相当" "$T/out.log"'

echo "速度容差：第一名更慢、延迟又没低够时保留，说明不出现负数"
fresh
printf '%s\n' 104.17.0.9,190,0.00,8.79,LHR 104.18.0.9,170,0.00,7.50,HKG > "$T/table"
SPEED_TOLERANCE=20 run full
check "保留 104.17.0.9" '[[ $(dns) == 104.17.0.9 ]]'
check "说明写「比当前 … 慢」" 'grep -q "比当前 8.79 MB/s 慢" "$T/out.log"'
check "没有「只快 -」" '! grep -q "只快 -" "$T/out.log"'

echo "没有 IP 满足延迟限制时，全量扫描放宽继续"
fresh; CFST_ARGS="-tl 40" run full
check "日志写了放宽" 'grep -q "本轮放宽" "$T/out.log"'
check "仍然更新了 DNS" '[[ $(dns) == 104.20.0.9 ]]'

echo "种子：段外的默认丢弃，SEED_ALLOW_OUTSIDE=1 时保留"
fresh
echo '{"Status":0,"Answer":[{"type":1,"data":"104.18.0.9"},{"type":1,"data":"1.2.3.4"}]}' > "$T/doh.seed.example"
SEEDS_DNS=seed.example run full
check "丢弃 1 个段外种子" 'grep -q "1 个不在官方网段，已丢弃" "$T/out.log"'
fresh
echo '{"Status":0,"Answer":[{"type":1,"data":"104.18.0.9"},{"type":1,"data":"1.2.3.4"}]}' > "$T/doh.seed.example"
SEEDS_DNS=seed.example SEED_ALLOW_OUTSIDE=1 run full
check "保留 1 个段外种子" 'grep -q "段外 1 个" "$T/out.log"'

echo "Cloudflare API 报错：不改 DNS，失败简报不重复"
fresh; touch "$T/cf_fail"
run full; run full
check "DNS 没变" '[[ $(dns) == 104.17.0.9 ]]'
check "失败简报只发 1 条" '(( $(tg_count 更新失败) == 1 ))'
rm -f "$T/cf_fail"; run full
check "恢复后正常更新" '[[ $(dns) == 104.20.0.9 ]]'
touch "$T/cf_fail"; run full
check "恢复过一次后，再失败会重新通知" '(( $(tg_count 更新失败) == 2 ))'

echo
echo "通过 $PASS 项，失败 $FAIL 项"
(( FAIL == 0 ))
