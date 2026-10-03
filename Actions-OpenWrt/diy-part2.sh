#!/bin/bash

# 1. 将 512MB DTS 复制到 mediatek 目标目录（使用绝对路径）
cp -f "$GITHUB_WORKSPACE/openwrt-mod/mt7981b-cudy-tr3000-512mb-v1.dts" target/linux/mediatek/dts/

# 2. 追加设备编译定义
if ! grep -q "cudy_tr3000-512mb" target/linux/mediatek/image/filogic.mk; then
    cat "$GITHUB_WORKSPACE/openwrt-mod/cudy-tr3000-512.mk" >> target/linux/mediatek/image/filogic.mk
fi
