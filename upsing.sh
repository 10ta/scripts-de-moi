#!/usr/bin/env bash
# upsing —— 从 GitHub Release 安装 / 更新 sing-box 的官方 .deb 包
#
#   bash upsing.sh           安装 Release 列表里的第一个版本（可能是 alpha / beta 预发布版）；已是这个版本就什么都不做
#   FORCE=1 bash upsing.sh   版本相同也重新安装
#
# 只装程序、不改配置。装了新版本才会重启 sing-box（所有连接会断开一下）。日志：/var/log/upsing.log
set -uo pipefail

REPO="SagerNet/sing-box"
LOG="/var/log/upsing.log"
FORCE="${FORCE:-0}"

log() { echo "$*" | tee -a "$LOG"; }
fail() { log "[错误] $*"; exit 1; }

[[ $EUID -eq 0 ]] || { echo "[错误] 请用 root 运行"; exit 1; }

# 自动探测架构，映射到 sing-box release 文件命名规则
case "$(uname -m)" in
    x86_64)        ARCH="linux_amd64" ;;
    aarch64|arm64) ARCH="linux_arm64" ;;
    armv7l)        ARCH="linux_armv7" ;;
    *)             echo "[错误] 不支持的架构: $(uname -m)"; exit 1 ;;
esac

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

: > "$LOG"
log "===== $(date '+%Y-%m-%d %H:%M:%S') 开始执行 ====="
log "架构: $(uname -m) -> ${ARCH}"

log "[1/4] 请求 GitHub releases 列表..."
HTTP_CODE=$(curl -sSL -m 30 -o "$WORK/releases.json" -w "%{http_code}" "https://api.github.com/repos/${REPO}/releases?per_page=5") || HTTP_CODE=000
if [[ "$HTTP_CODE" != "200" ]]; then
    head -c 500 "$WORK/releases.json" 2>/dev/null | tee -a "$LOG"; echo
    fail "GitHub API 请求失败（HTTP ${HTTP_CODE}；未登录时每小时限 60 次）"
fi

TAG=$(grep -m1 '"tag_name":' "$WORK/releases.json" | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
[[ -n "$TAG" ]] || fail "没能解析出 tag_name"
VERSION="${TAG#v}"

CURRENT=""
command -v sing-box >/dev/null && CURRENT=$(sing-box version 2>/dev/null | sed -n '1s/.*version //p')
log "[2/4] 最新版本 ${VERSION}，本机 ${CURRENT:-未安装}"
if [[ "$CURRENT" == "$VERSION" && "$FORCE" != 1 ]]; then
    log "已是最新版本，不安装、不重启（要重装：FORCE=1 bash upsing.sh）"
    exit 0
fi

DEB_NAME="sing-box_${VERSION}_${ARCH}.deb"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${DEB_NAME}"
log "[3/4] 下载 ${DEB_NAME}"
DL_HTTP_CODE=$(curl -sSL -m 300 -o "$WORK/${DEB_NAME}" -w "%{http_code}" "${DOWNLOAD_URL}") || DL_HTTP_CODE=000
[[ "$DL_HTTP_CODE" == "200" ]] || fail "下载失败（HTTP ${DL_HTTP_CODE}），这个版本可能没有 ${ARCH} 的 .deb 包"
log "下载完成，$(wc -c < "$WORK/${DEB_NAME}") 字节"

log "[4/4] 安装"
dpkg -i "$WORK/${DEB_NAME}" 2>&1 | tee -a "$LOG"
[[ ${PIPESTATUS[0]} -eq 0 ]] || fail "dpkg 安装失败，sing-box 没有重启（还是原来的版本）"

if systemctl is-enabled --quiet sing-box 2>/dev/null || systemctl is-active --quiet sing-box 2>/dev/null; then
    systemctl restart sing-box && log "已重启 sing-box" || fail "sing-box 重启失败：journalctl -u sing-box -n 50"
else
    log "sing-box 服务没有启用，没有重启（配置好 /etc/sing-box/config.json 后自己启用）"
fi
log "===== $(date '+%Y-%m-%d %H:%M:%S') 完成：$(sing-box version 2>/dev/null | head -n1) ====="
