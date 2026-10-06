#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#

# 1. 修改默认管理后台 IP 为 192.168.6.1
sed -i 's/192.168.1.1/192.168.6.1/g' package/base-files/files/bin/config_generate

# 2. 注入 Cudy TR3000 (512MB Flash) 专属设备树 (DTS)
DTS_SRC="$GITHUB_WORKSPACE/openwrt-mod/mt7981b-cudy-tr3000-512mb-v1.dts"
DTS_DST="target/linux/mediatek/dts/mt7981b-cudy-tr3000-512mb-v1.dts"
if [ -f "$DTS_SRC" ]; then
    cp -f "$DTS_SRC" "$DTS_DST"
    echo "Successfully injected 512MB DTS to $DTS_DST"
else
    echo "Warning: $DTS_SRC not found!"
fi

# 3. 动态注入 Makefile 设备构建定义到 filogic.mk
FILOGIC_MK="target/linux/mediatek/image/filogic.mk"
if [ -f "$FILOGIC_MK" ]; then
    HAS_DEV=$(grep -c "cudy_tr3000-512mb-v1" "$FILOGIC_MK" || true)
    if [ "$HAS_DEV" -eq 0 ]; then
        cat << 'EOF' >> "$FILOGIC_MK"

define Device/cudy_tr3000-512mb-v1
  DEVICE_VENDOR := Cudy
  DEVICE_MODEL := TR3000 (512MB Flash)
  DEVICE_DTS := mt7981b-cudy-tr3000-512mb-v1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  SUPPORTED_DEVICES += cudy,tr3000-512mb-v1 cudy,tr3000-512m cudy,tr3000
  UBINIZE_OPTS := -E 5
  IMAGE_SIZE := 490MB
  IMAGES += sysupgrade.bin
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cudy_tr3000-512mb-v1
EOF
        echo "Successfully appended Device/cudy_tr3000-512mb-v1 to $FILOGIC_MK"
    else
        echo "Device/cudy_tr3000-512mb-v1 already present in $FILOGIC_MK, skipping."
    fi
fi

# 4. 彻底解除 mt76 对 mac80211 autoconf.h 的时序死锁
if [ -f "package/kernel/mt76/Makefile" ]; then
    sed -i 's|STAMP_CONFIGURED_DEPENDS :=.*|STAMP_CONFIGURED_DEPENDS :=|g' package/kernel/mt76/Makefile
    echo "Successfully patched mt76 STAMP_CONFIGURED_DEPENDS"
fi

# 5. 预置中兴 F50 专属即插即用配置 (锁定绑定至 eth2)
mkdir -p package/base-files/files/etc/uci-defaults
cat << 'EOF' > package/base-files/files/etc/uci-defaults/99-f50-hotplug
uci set network.f50=interface
uci set network.f50.proto='dhcp'
uci set network.f50.device='eth2'
uci set network.f50.metric='20'
uci commit network

# 将 f50 接口加入防火墙 WAN 区域
uci add_list firewall.@zone[1].network='f50'
uci commit firewall
EOF
chmod +x package/base-files/files/etc/uci-defaults/99-f50-hotplug