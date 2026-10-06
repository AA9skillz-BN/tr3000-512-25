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

echo ">>> 开始执行 diy-part2.sh 自定义配置..."

# -------------------------------------------------------------
# 1. 基础系统与后台管理配置
# -------------------------------------------------------------
# 修改默认管理后台 IP 为 192.168.6.1（避开光猫与 F50 的 192.168.0.1 / 192.168.1.1）
sed -i 's/192.168.1.1/192.168.6.1/g' package/base-files/files/bin/config_generate

# 修改默认主机名
sed -i 's/ImmortalWrt/Cudy-TR3000/g' package/base-files/files/bin/config_generate

# 自定义版本与 Banner 描述
BUILD_DATE=$(date +"%Y.%m.%d")
sed -i "s/DISTRIB_DESCRIPTION='.*'/DISTRIB_DESCRIPTION='ImmortalWrt 25.x (TR3000 512M) Built ${BUILD_DATE}'/g" package/base-files/files/etc/openwrt_release

# -------------------------------------------------------------
# 2. 注入 Cudy TR3000 (512MB Flash) 专属设备树 (DTS)
# -------------------------------------------------------------
DTS_SRC="$GITHUB_WORKSPACE/openwrt-mod/mt7981b-cudy-tr3000-512mb-v1.dts"
DTS_DST="target/linux/mediatek/dts/mt7981b-cudy-tr3000-512mb-v1.dts"
if [ -f "$DTS_SRC" ]; then
    cp -f "$DTS_SRC" "$DTS_DST"
    echo ">>> [OK] 成功注入 512MB 专属设备树: $DTS_DST"
else
    echo ">>> [WARNING] 未在 openwrt-mod/ 找到 DTS 文件，请检查路径！"
fi

# -------------------------------------------------------------
# 3. 注入 filogic.mk 设备构建定义
# -------------------------------------------------------------
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
        echo ">>> [OK] 成功追加 Device/cudy_tr3000-512mb-v1 到 $FILOGIC_MK"
    else
        echo ">>> [INFO] Device/cudy_tr3000-512mb-v1 已存在，跳过注入"
    fi
fi

# -------------------------------------------------------------
# 4. 适配板级网络与升级白名单 (02_network & platform.sh)
# -------------------------------------------------------------
BOARD_NETWORK="target/linux/mediatek/filogic/base-files/etc/board.d/02_network"
if [ -f "$BOARD_NETWORK" ]; then
    if ! grep -q "cudy,tr3000-512mb-v1" "$BOARD_NETWORK"; then
        sed -i 's/cudy,tr3000\\/cudy,tr3000* | \\\n\tcudy,tr3000-512mb-v1\\/g' "$BOARD_NETWORK" 2>/dev/null || true
        echo ">>> [OK] 已将 cudy,tr3000-512mb-v1 加入 02_network 网口映射白名单"
    fi
fi

BOARD_SYSUPGRADE="target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh"
if [ -f "$BOARD_SYSUPGRADE" ]; then
    if ! grep -q "cudy,tr3000-512mb-v1" "$BOARD_SYSUPGRADE"; then
        sed -i 's/cudy,tr3000)/cudy,tr3000 | cudy,tr3000-512mb-v1)/g' "$BOARD_SYSUPGRADE" 2>/dev/null || true
        echo ">>> [OK] 已将 cudy,tr3000-512mb-v1 加入 platform.sh 升级白名单"
    fi
fi

# -------------------------------------------------------------
# 5. 解决 mt76 对 mac80211 autoconf.h 依赖死锁补丁
# -------------------------------------------------------------
if [ -f "package/kernel/mt76/Makefile" ]; then
    sed -i 's|STAMP_CONFIGURED_DEPENDS :=.*|STAMP_CONFIGURED_DEPENDS :=|g' package/kernel/mt76/Makefile
    echo ">>> [OK] 成功解除 mt76 对 autoconf.h 的时序锁 (STAMP_CONFIGURED_DEPENDS)"
fi

# -------------------------------------------------------------
# 6. 预置 OpenClash Meta 核心与默认配置
# -------------------------------------------------------------
mkdir -p package/base-files/files/etc/openclash/core
META_CORE_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz"
echo ">>> 正在预下载 OpenClash Meta 核心..."
curl -sL --connect-timeout 10 --retry 3 "$META_CORE_URL" -o /tmp/clash_meta.tar.gz || true
if [ -s /tmp/clash_meta.tar.gz ]; then
    tar -zxf /tmp/clash_meta.tar.gz -C package/base-files/files/etc/openclash/core/ 2>/dev/null || true
    chmod +x package/base-files/files/etc/openclash/core/clash* 2>/dev/null || true
    rm -f /tmp/clash_meta.tar.gz
    echo ">>> [OK] OpenClash Meta 内核预装完毕"
else
    echo ">>> [WARNING] Meta 内核下载超时或失败，可开机后在 LuCI 页面下载"
fi

# -------------------------------------------------------------
# 7. 预置中兴 F50 即插即用配置 (绑定 eth2)
# -------------------------------------------------------------
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

# -------------------------------------------------------------
# 8. 专属终端一键在线更新脚本 (/bin/autoupdate)
# -------------------------------------------------------------
mkdir -p package/base-files/files/bin
cat << 'EOF' > package/base-files/files/bin/autoupdate
#!/bin/sh
REPO_OWNER="AA9skillz-BN"
REPO_NAME="tr3000-512-25"
API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"

echo "=============================================="
echo "      Cudy TR3000 512M 专属固件在线更新"
echo "=============================================="

echo ">>> 正在检查 GitHub Releases 最新版本..."
DOWNLOAD_URL=$(curl -sL ${API_URL} | grep -o 'https://[^"]*cudy_tr3000-512mb-v1[^"]*sysupgrade\.bin' | head -n 1)

if [ -z "$DOWNLOAD_URL" ]; then
    DOWNLOAD_URL=$(curl -sL ${API_URL} | grep -o 'https://[^"]*sysupgrade\.bin' | head -n 1)
fi

if [ -z "$DOWNLOAD_URL" ]; then
    echo "❌ 错误: 未能在最新 Release 中找到匹配的 sysupgrade 固件！"
    exit 1
fi

echo ">>> 找到最新固件: ${DOWNLOAD_URL}"
echo ">>> 开始下载到 /tmp/sysupgrade.bin ..."
curl -L -o /tmp/sysupgrade.bin "$DOWNLOAD_URL"

if [ ! -s /tmp/sysupgrade.bin ]; then
    echo "❌ 固件下载失败或文件为空！"
    exit 1
fi

echo ">>> 固件下载完成，开始执行系统升级 (保留配置)..."
echo ">>> 请勿断电，设备将在 2 分钟内自动重启！"
sysupgrade /tmp/sysupgrade.bin
EOF
chmod +x package/base-files/files/bin/autoupdate

echo ">>> diy-part2.sh 执行完毕！"