#!/bin/bash
# Description: OpenWrt DIY script part 2 (After Update feeds)

# 1. 修改默认后台 IP 为 192.168.6.1
sed -i 's/192.168.1.1/192.168.6.1/g' package/base-files/files/bin/config_generate || true

# 2. 部署 512MB 专属设备树 (DTS)
DTS_SRC="$GITHUB_WORKSPACE/openwrt-mod/mt7981b-cudy-tr3000-512mb-v1.dts"
if [ -f "$DTS_SRC" ]; then
    mkdir -p target/linux/mediatek/dts || true
    cp -f "$DTS_SRC" target/linux/mediatek/dts/mt7981b-cudy-tr3000-512mb-v1.dts
fi

# 3. 注入 512MB 机型定义 (IMAGE_SIZE 采用 502272k，规避 json_add_image_info.py 大写 M 解析报错)
FILOGIC_MK="target/linux/mediatek/image/filogic.mk"
if [ -f "$FILOGIC_MK" ]; then
    HAS_DEV=$(grep -c "cudy_tr3000-512mb-v1" "$FILOGIC_MK" || true)
    if [ "$HAS_DEV" -eq 0 ]; then
        echo "Injecting cudy_tr3000-512mb-v1 definition into $FILOGIC_MK"
        cat << 'EOF' >> "$FILOGIC_MK"

define Device/cudy_tr3000-512mb-v1
  DEVICE_VENDOR := Cudy
  DEVICE_MODEL := TR3000
  DEVICE_VARIANT := 512mb v1
  DEVICE_DTS := mt7981b-cudy-tr3000-512mb-v1
  DEVICE_DTS_DIR := ../dts
  SUPPORTED_DEVICES += R47 cudy,tr3000-v1
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 502272k
  KERNEL_IN_UBI := 1
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7981-firmware mt7981-wo-firmware
endef
TARGET_DEVICES += cudy_tr3000-512mb-v1
EOF
    fi
fi

# 4. 固件在线升级功能 (脚本、菜单、ACL 与 View)
mkdir -p package/base-files/files/usr/bin || true
cat << 'EOF' > package/base-files/files/usr/bin/auto-update-firmware.sh
#!/bin/sh

REPO="AA9skillz-BN/tr3000-512-25"
LOG_FILE="/tmp/firmware_update.log"

# 重置并清空日志
> "$LOG_FILE"

log() {
    echo "$@" >> "$LOG_FILE"
}

log "=========================================="
log "目标仓库: https://github.com/$REPO"
log "正在检测网络并连接 GitHub API..."
log "=========================================="

API_URL="https://api.github.com/repos/$REPO/releases/latest"
# 注入 User-Agent 防阻断，并设置 10 秒超时
RELEASE_JSON=$(curl -sL -m 10 -H "User-Agent: Cudy-TR3000-Updater" "$API_URL")

DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o 'https://[^" ]*cudy_tr3000-512mb-v1[^" ]*sysupgrade\.bin' | head -n 1)
if [ -z "$DOWNLOAD_URL" ]; then
    DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o 'https://[^" ]*sysupgrade\.bin' | head -n 1)
fi

TAG_NAME=$(echo "$RELEASE_JSON" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | cut -d'"' -f4)

if [ -z "$DOWNLOAD_URL" ]; then
    log "❌ 检查失败: 未能在最新 Release 中找到匹配的固件！"
    log "API 响应概况: $(echo "$RELEASE_JSON" | head -n 2)"
    exit 1
fi

log "✔ 发现最新可用版本: ${TAG_NAME:-最新发布}"
log "下载链接: $DOWNLOAD_URL"
log ""

TMP_FILE="/tmp/firmware_upgrade.bin"
rm -f "$TMP_FILE"

log "正在下载固件至内存缓存区 (请勿断电)..."
curl -L -k --progress-bar -o "$TMP_FILE" "$DOWNLOAD_URL" 2>> "$LOG_FILE"

if [ $? -ne 0 ] || [ ! -s "$TMP_FILE" ]; then
    log "❌ 固件下载失败，请检查路由器网络连接！"
    rm -f "$TMP_FILE"
    exit 1
fi

log "✔ 固件下载完成，大小: $(ls -lh "$TMP_FILE" | awk '{print $5}')"
log ""

log "正在执行固件安全校验..."
if ! sysupgrade -t "$TMP_FILE" >> "$LOG_FILE" 2>&1; then
    log "❌ 固件校验不通过！可能文件损坏或型号不匹配，已终止升级以防止变砖。"
    rm -f "$TMP_FILE"
    exit 1
fi

log "✔ 校验成功！将在 3 秒后执行自动刷机并重启..."
log "升级完成后管理地址仍为: 192.168.6.1。"
log "=========================================="

# 延时 3 秒并脱离父进程执行系统刷机，防止终端挂起
( sleep 3 && sysupgrade "$TMP_FILE" ) >/dev/null 2>&1 &
exit 0
EOF
chmod +x package/base-files/files/usr/bin/auto-update-firmware.sh || true

# 5. 预置中兴 F50 (eth2)
mkdir -p package/base-files/files/etc/uci-defaults || true
cat << 'EOF' > package/base-files/files/etc/uci-defaults/99-f50-hotplug
uci set network.f50=interface
uci set network.f50.proto='dhcp'
uci set network.f50.device='eth2'
uci set network.f50.metric='20'
uci commit network

uci add_list firewall.@zone[1].network='f50' 2>/dev/null || true
uci commit firewall
EOF
chmod +x package/base-files/files/etc/uci-defaults/99-f50-hotplug || true

exit 0