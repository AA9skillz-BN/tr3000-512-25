#!/bin/bash
# Description: OpenWrt DIY script part 2 (After Update feeds)

# 1. 修改默认后台 IP 为 192.168.6.1
sed -i 's/192.168.1.1/192.168.6.1/g' package/base-files/files/bin/config_generate

# 2. 复制 512MB 专属设备树 (DTS) 到内核源码目录
if [ -f "$GITHUB_WORKSPACE/openwrt-mod/mt7981b-cudy-tr3000-512m.dts" ]; then
    cp -f "$GITHUB_WORKSPACE/openwrt-mod/mt7981b-cudy-tr3000-512m.dts" target/linux/mediatek/dts/
fi

# 3. 寻找目标 Makefile (优先找 mt7981.mk，找不到则找 filogic.mk)
MK_FILE=""
if [ -f "target/linux/mediatek/image/mt7981.mk" ]; then
    MK_FILE="target/linux/mediatek/image/mt7981.mk"
elif [ -f "target/linux/mediatek/image/filogic.mk" ]; then
    MK_FILE="target/linux/mediatek/image/filogic.mk"
fi

# 4. 动态向 .mk 文件追加 512M 机型定义
if [ -n "$MK_FILE" ]; then
    if ! grep -q "cudy_tr3000-512m" "$MK_FILE"; then
        echo "Appending cudy_tr3000-512m definition to $MK_FILE"
        cat << 'EOF' >> "$MK_FILE"

define Device/cudy_tr3000-512m
  DEVICE_VENDOR := Cudy
  DEVICE_MODEL := TR3000 (512MB Mod)
  DEVICE_DTS := mt7981b-cudy-tr3000-512m
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 490M
  $(call Device/FitImage)
endef
TARGET_DEVICES += cudy_tr3000-512m
EOF
    fi
fi