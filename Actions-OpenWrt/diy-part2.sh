#!/bin/bash
# Description: OpenWrt DIY script part 2 (After Update feeds)

# 1. 设置管理后台默认 IP 为 192.168.1.1
sed -i 's/192.168.1.1/192.168.1.1/g' package/base-files/files/bin/config_generate

# 2. 复制 512MB 专属设备树 (DTS) 到内核目录
if [ -f "$GITHUB_WORKSPACE/openwrt-mod/mt7981b-cudy-tr3000-512m.dts" ]; then
    cp -f "$GITHUB_WORKSPACE/openwrt-mod/mt7981b-cudy-tr3000-512m.dts" target/linux/mediatek/dts/
fi

# 3. 在 target/linux/mediatek/image/mt7981.mk 追加 512M 设备定义
if ! grep -q "cudy_tr3000-512m" target/linux/mediatek/image/mt7981.mk; then
cat << 'EOF' >> target/linux/mediatek/image/mt7981.mk

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