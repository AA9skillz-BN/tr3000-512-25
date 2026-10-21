#!/bin/bash
# Description: OpenWrt DIY script part 2 (After Update feeds)

# 1. 修改默认后台 IP 为 192.168.6.1
sed -i 's/192.168.1.1/192.168.6.1/g' package/base-files/files/bin/config_generate || true

# ==============================================================================
# 2. 基于源码原版 mt7981b-cudy-tr3000-v1.dts 原地无损扩容 ubi 分区至 512MB
# ==============================================================================
ORIG_DTS="target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1.dts"
if [ -f "$ORIG_DTS" ]; then
    sed -i 's/reg = <0x5c0000 0x[0-9a-fA-F]*>/reg = <0x5c0000 0x1da40000>/g' "$ORIG_DTS"
    sed -i 's/Cudy TR3000 v1/Cudy TR3000 512MB v1/g' "$ORIG_DTS"
    echo "✔ 设备树 ubi 分区扩容修正完毕！"
fi

# ==============================================================================
# 3. 注入 512MB 专属机型定义
# ==============================================================================
FILOGIC_MK="target/linux/mediatek/image/filogic.mk"
if [ -f "$FILOGIC_MK" ] && ! grep -q "cudy_tr3000-512mb-v1" "$FILOGIC_MK"; then
    cat << 'EOF' >> "$FILOGIC_MK"

define Device/cudy_tr3000-512mb-v1
  DEVICE_VENDOR := Cudy
  DEVICE_MODEL := TR3000
  DEVICE_VARIANT := 512MB v1
  DEVICE_DTS := mt7981b-cudy-tr3000-v1
  DEVICE_DTS_DIR := ../dts
  SUPPORTED_DEVICES += R47 cudy,tr3000-v1 cudy,tr3000-512mb-v1
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 485632k
  KERNEL_IN_UBI := 1
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
endef
TARGET_DEVICES += cudy_tr3000-512mb-v1
EOF
fi

# ==============================================================================
# 4. 在线升级核心脚本与 LuCI 视图
# ==============================================================================
mkdir -p package/base-files/files/usr/bin || true
cat << 'EOF' > package/base-files/files/usr/bin/auto-update-firmware.sh
#!/bin/sh

REPO="AA9skillz-BN/tr3000-512-25"
LOG_FILE="/tmp/firmware_update.log"
TMP_BIN="/tmp/firmware_upgrade.bin"
TMP_SHA="/tmp/sha256sums"

UPGRADE_OPTS=""
MODE_DESC="保留当前配置 (无缝升级)"
[ "$1" = "-n" ] && UPGRADE_OPTS="-n" && MODE_DESC="不保留配置 (恢复出厂全新刷入)"

PROXIES="https://ghfast.top/ https://ghproxy.net/"
> "$LOG_FILE"
log() { echo "$@" >> "$LOG_FILE"; }

log "=========================================="
log "目标仓库: https://github.com/$REPO"
log "升级模式: $MODE_DESC"
log "正在检测网络并连接 GitHub API..."
log "=========================================="

API_URL="https://api.github.com/repos/$REPO/releases/latest"
RELEASE_JSON=$(curl -sL -m 15 -H "User-Agent: Cudy-TR3000-OTA" "$API_URL")

if [ -z "$RELEASE_JSON" ] || ! echo "$RELEASE_JSON" | grep -q "tag_name"; then
    for P in $PROXIES; do
        RELEASE_JSON=$(curl -sL -m 15 -H "User-Agent: Cudy-TR3000-OTA" "${P}${API_URL}")
        echo "$RELEASE_JSON" | grep -q "tag_name" && break
    done
fi

DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o 'https://[^" ]*cudy_tr3000-512mb-v1[^" ]*sysupgrade\.bin' | head -n 1)
[ -z "$DOWNLOAD_URL" ] && DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o 'https://[^" ]*sysupgrade\.bin' | head -n 1)
SHA_URL=$(echo "$RELEASE_JSON" | grep -o 'https://[^" ]*sha256sums' | head -n 1)

[ -z "$DOWNLOAD_URL" ] && log "❌ 检查失败: 未能在最新 Release 中找到匹配的固件！" && exit 1

sync
echo 3 > /proc/sys/vm/drop_caches
rm -f "$TMP_BIN" "$TMP_SHA"

download_file() {
    local remote_url="$1" local output_path="$2" local desc="$3"
    curl -L -k --connect-timeout 8 -m 300 --progress-bar -o "$output_path" "$remote_url" 2>> "$LOG_FILE"
    [ $? -eq 0 ] && [ -s "$output_path" ] && return 0
    for P in $PROXIES; do
        rm -f "$output_path"
        curl -L -k --connect-timeout 10 -m 300 --progress-bar -o "$output_path" "${P}${remote_url}" 2>> "$LOG_FILE"
        [ $? -eq 0 ] && [ -s "$output_path" ] && return 0
    done
    return 1
}

[ -n "$SHA_URL" ] && download_file "$SHA_URL" "$TMP_SHA" "校验清单"
download_file "$DOWNLOAD_URL" "$TMP_BIN" "系统固件镜像" || exit 1

/etc/init.d/openclash stop 2>/dev/null || true
sync
( sleep 3 && sysupgrade $UPGRADE_OPTS "$TMP_BIN" ) >/dev/null 2>&1 &
exit 0
EOF
chmod +x package/base-files/files/usr/bin/auto-update-firmware.sh || true

mkdir -p package/base-files/files/usr/share/luci/menu.d package/base-files/files/usr/share/rpcd/acl.d package/base-files/files/www/luci-static/resources/view/autoupdate || true
# (OTA 菜单与前端注册保持精简)
cat << 'EOF' > package/base-files/files/usr/share/luci/menu.d/luci-app-autoupdate.json
{
	"admin/autoupdate": {
		"title": "固件升级",
		"order": 90,
		"action": { "type": "view", "path": "autoupdate/index" }
	}
}
EOF

# ==============================================================================
# 5. 部署 F50 防限速 TTL=65 (覆盖 eth1/eth2/usb0) 与 USB 总线智能热插拔
# ==============================================================================
mkdir -p package/base-files/files/usr/share/nftables.d/table-post package/base-files/files/etc/hotplug.d/net || true
cat << 'EOF' > package/base-files/files/usr/share/nftables.d/table-post/99-f50-ttl.nft
chain f50_ttl {
    type filter hook postrouting priority 300; policy accept;
    oifname { "eth1", "eth2", "usb0" } ip ttl set 65
    oifname { "eth1", "eth2", "usb0" } ip6 hoplimit set 65
}
EOF

cat << 'EOF' > package/base-files/files/etc/hotplug.d/net/99-f50-auto
case "$ACTION" in
    add)
        if readlink -f "/sys/class/net/$INTERFACE/device" 2>/dev/null | grep -q "usb" || [ "$INTERFACE" = "usb0" ] || [ "$INTERFACE" = "eth1" ] || [ "$INTERFACE" = "eth2" ]; then
            [ "$(uci -q get network.f50)" != "interface" ] && uci set network.f50=interface && uci set network.f50.proto='dhcp' && uci set network.f50.metric='20' && uci set network.f50.mtu='1420'
            if [ "$(uci -q get network.f50.device)" != "$INTERFACE" ]; then
                uci set network.f50.device="$INTERFACE"
                uci commit network
                /etc/init.d/network reload
            fi
            ( sleep 2 && ifup f50 ) >/dev/null 2>&1 &
        fi
        ;;
esac
EOF
chmod +x package/base-files/files/etc/hotplug.d/net/99-f50-auto || true

cat << 'EOF' > package/base-files/files/usr/bin/f50-watchdog.sh
#!/bin/sh
DEV=$(uci -q get network.f50.device)
[ -z "$DEV" ] && exit 0
ip link show "$DEV" 2>/dev/null | grep -q "UP" || exit 0
GATEWAY_IP=$(ip route show default dev "$DEV" 2>/dev/null | awk '/via/ {print $3}' | head -n 1)
[ -n "$GATEWAY_IP" ] && ! ping -c 2 -W 1 "$GATEWAY_IP" >/dev/null 2>&1 && ifup f50 && exit 0
! ping -c 3 -W 2 -I "$DEV" "223.5.5.5" >/dev/null 2>&1 && ifup f50
exit 0
EOF
chmod +x package/base-files/files/usr/bin/f50-watchdog.sh || true

# ==============================================================================
# 6. 预置 OpenClash 最新 ARM64 Meta 内核 (软链接防冲突)
# ==============================================================================
OC_ROOT="package/luci-app-openclash/root/etc/openclash"
[ ! -d "$OC_ROOT" ] && OC_ROOT="package/base-files/files/etc/openclash"
CORE_DIR="$OC_ROOT/core"
mkdir -p "$CORE_DIR"

META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz"
if curl -sL --connect-timeout 15 --retry 3 "$META_URL" -o /tmp/clash_meta.tar.gz; then
    tar -zxf /tmp/clash_meta.tar.gz -C "$CORE_DIR"
    mv -f "$CORE_DIR/clash" "$CORE_DIR/clash_meta" 2>/dev/null || true
    ln -sf clash_meta "$CORE_DIR/clash"
    chmod 0755 "$CORE_DIR/clash_meta"
    rm -f /tmp/clash_meta.tar.gz
    echo "✔ OpenClash Meta 内核预置成功！"
fi

curl -sL --connect-timeout 15 --retry 2 "https://raw.githubusercontent.com/alecthw/mmdb_china_ip_list/release/lite/Country.mmdb" -o "$OC_ROOT/Country.mmdb" || true
curl -sL --connect-timeout 15 --retry 2 "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -o "$OC_ROOT/GeoSite.dat" || true
curl -sL --connect-timeout 15 --retry 2 "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -o "$OC_ROOT/GeoIP.dat" || true

mkdir -p package/base-files/files/etc || true
grep -qxF '/etc/openclash/' package/base-files/files/etc/sysupgrade.conf 2>/dev/null || echo '/etc/openclash/' >> package/base-files/files/etc/sysupgrade.conf

# ==============================================================================
# 7. 统一开机初始化脚本 (全中文锁定、Aurora 主题、5G 稳定开启、F50 自动探测)
# ==============================================================================
mkdir -p package/base-files/files/etc/uci-defaults || true
cat << 'EOF' > package/base-files/files/etc/uci-defaults/99-custom-init
# 1. 强制锁定简体中文与 Aurora 主题
uci set luci.main.lang='zh_cn'
if [ -d "/www/luci-static/aurora" ]; then
    uci set luci.themes.Aurora='/luci-static/aurora'
    uci set luci.main.mediaurlbase='/luci-static/aurora'
fi
uci commit luci

# 2. 开启 Turbo ACC (BBR + 软硬 PPE 流量分载)
if [ -f "/etc/config/turboacc" ]; then
    uci set turboacc.config.sw_flow='1'
    uci set turboacc.config.hw_flow='1'
    uci set turboacc.config.bbr_cca='1'
    uci commit turboacc
fi
uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@defaults[0].flow_offloading_hw='1'

# 3. F50 接口自动探测 USB 总线网卡 (兼容 eth1 / eth2 / usb0)
uci set network.f50=interface
uci set network.f50.proto='dhcp'
uci set network.f50.metric='20'
uci set network.f50.mtu='1420'
USB_DEV=$(ls -l /sys/class/net/ 2>/dev/null | grep -i "usb" | awk '{print $9}' | head -n 1)
if [ -n "$USB_DEV" ]; then
    uci set network.f50.device="$USB_DEV"
else
    uci set network.f50.device='usb0'
fi
uci commit network

for i in $(seq 0 10); do
    if [ "$(uci -q get firewall.@zone[$i].name)" = "wan" ]; then
        uci del_list firewall.@zone[$i].network='f50' 2>/dev/null
        uci add_list firewall.@zone[$i].network='f50'
        break
    fi
done
uci commit firewall

# 4. 时区与 NTP
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].timezone='CST-8'
uci -q delete system.ntp.server
uci add_list system.ntp.server='ntp.aliyun.com'
uci add_list system.ntp.server='time1.cloud.tencent.com'
uci commit system

# 5. 满血 Wi-Fi 6 稳定配置 (配合 wireless-regdb 使用 US 监管域，确保 36 信道不锁死)
for r in radio0 radio1; do
    BAND=$(uci -q get wireless.$r.band)
    uci set wireless.$r.country='US'
    uci set wireless.$r.cell_density='0'
    uci set wireless.$r.mu_beamformer='1'
    uci set wireless.$r.disabled='0'
    uci set wireless.default_$r.disabled='0'
    if [ "$BAND" = "5g" ]; then
        uci set wireless.$r.channel='36'
        uci set wireless.$r.htmode='HE160'
        uci set wireless.default_$r.ssid='Cudy-TR3000-5G'
        uci set wireless.default_$r.disassoc_low_ack='0'
    elif [ "$BAND" = "2g" ]; then
        uci set wireless.$r.channel='6'
        uci set wireless.$r.htmode='HE40'
        uci set wireless.$r.noscan='1'
        uci set wireless.default_$r.ssid='Cudy-TR3000-2.4G'
        uci set wireless.default_$r.disassoc_low_ack='0'
    fi
done
uci commit wireless

# 6. OpenClash 默认锁定内置 Meta 内核
if [ -f "/etc/config/openclash" ]; then
    uci set openclash.config.core_version='linux-arm64'
    uci set openclash.config.enable_meta_core='1'
    uci commit openclash
fi
chmod 0755 /etc/openclash/core/clash* 2>/dev/null || true

# 7. 看门狗计划任务
CRON_JOB="*/3 * * * * /usr/bin/f50-watchdog.sh >/dev/null 2>&1"
( crontab -l 2>/dev/null | grep -v "f50-watchdog.sh"; echo "$CRON_JOB" ) | crontab -
/etc/init.d/cron enable
/etc/init.d/cron restart

rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null || true
exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/99-custom-init || true

exit 0
