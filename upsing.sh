#!/usr/bin/env bash
set -uo pipefail

REPO="SagerNet/sing-box"
LOG="/tmp/upsing.log"

# 自动探测架构，映射到 sing-box release 文件命名规则
case "$(uname -m)" in
    x86_64)
        ARCH="linux_amd64"
        ;;
    aarch64|arm64)
        ARCH="linux_arm64"
        ;;
    armv7l)
        ARCH="linux_armv7"
        ;;
    *)
        echo "[错误] 不支持的架构: $(uname -m)"
        exit 1
        ;;
esac

echo "===== $(date '+%Y-%m-%d %H:%M:%S') 开始执行 =====" | tee "$LOG"
echo "检测到架构: $(uname -m) -> ${ARCH}" | tee -a "$LOG"

echo "[1/5] 请求 GitHub releases 列表..." | tee -a "$LOG"
HTTP_CODE=$(curl -sL -o /tmp/releases.json -w "%{http_code}" "https://api.github.com/repos/${REPO}/releases")
echo "HTTP 状态码: ${HTTP_CODE}" | tee -a "$LOG"

if [ "$HTTP_CODE" != "200" ]; then
    echo "[错误] GitHub API 请求失败" | tee -a "$LOG"
    cat /tmp/releases.json | tee -a "$LOG"
    exit 1
fi

echo "[2/5] 响应体大小: $(wc -c < /tmp/releases.json) 字节" | tee -a "$LOG"

echo "[3/5] 解析 tag_name..." | tee -a "$LOG"
TAG=$(grep -m1 '"tag_name":' /tmp/releases.json | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
echo "解析结果 TAG='${TAG}'" | tee -a "$LOG"

if [ -z "$TAG" ]; then
    echo "[错误] 未能解析出 tag_name，完整响应见 /tmp/releases.json" | tee -a "$LOG"
    exit 1
fi

VERSION="${TAG#v}"
DEB_NAME="sing-box_${VERSION}_${ARCH}.deb"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${DEB_NAME}"

echo "[4/5] 版本: ${VERSION}" | tee -a "$LOG"
echo "下载文件名: ${DEB_NAME}" | tee -a "$LOG"
echo "下载地址: ${DOWNLOAD_URL}" | tee -a "$LOG"

echo "[5/5] 开始下载..." | tee -a "$LOG"
DL_HTTP_CODE=$(curl -sL -o "/tmp/${DEB_NAME}" -w "%{http_code}" "${DOWNLOAD_URL}")
echo "下载 HTTP 状态码: ${DL_HTTP_CODE}" | tee -a "$LOG"

if [ "$DL_HTTP_CODE" != "200" ]; then
    echo "[错误] 下载失败，该版本可能没有 ${ARCH} 对应的 .deb 包" | tee -a "$LOG"
    exit 1
fi

echo "下载完成，文件大小: $(wc -c < /tmp/${DEB_NAME}) 字节" | tee -a "$LOG"
echo "开始安装..." | tee -a "$LOG"

dpkg -i "/tmp/${DEB_NAME}" 2>&1 | tee -a "$LOG"

echo "===== $(date '+%Y-%m-%d %H:%M:%S') 执行结束 =====" | tee -a "$LOG"