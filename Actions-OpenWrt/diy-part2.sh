#!/bin/bash
# Description: OpenWrt DIY script part 2 (After Update feeds)

# 1. 修正默认主机名
sed -i 's/OpenWrt/ImmortalWrt-TR3000/g' package/base-files/files/bin/config_generate

# 2. 修复 25.x 下 mt76 编译失败问题 (更新 mt76 到最新兼容提交)
sed -i 's/PKG_SOURCE_DATE:=.*/PKG_SOURCE_DATE:=2024-04-06/g' package/kernel/mt76/Makefile || true
# 清理缓存标记，强制重新构建
rm -rf package/kernel/mt76/.ver_*

# 3. 注入开机自启初始化脚本 (修正 Shebang 为 /bin/sh)
mkdir -p files/etc/uci-defaults
cat << 'EOF' > files/etc/uci-defaults/99-custom-settings
#!/bin/sh

# 配置中兴 F50 (MODEM) 即插即用接口
uci -q delete network.MODEM
uci set network.MODEM=interface
uci set network.MODEM.proto='dhcp'
uci set network.MODEM.device='eth2'

# 将 MODEM 加入 WAN 防火墙区域
uci -q del_list firewall.@zone[1].network='MODEM'
uci add_list firewall.@zone[1].network='MODEM'

# 预设双频 Wi-Fi 满血状态
uci set wireless.radio0.disabled='0'
uci set wireless.radio0.country='CN'
uci set wireless.radio0.channel='6'

uci set wireless.radio1.disabled='0'
uci set wireless.radio1.country='CN'
uci set wireless.radio1.channel='36'
uci set wireless.radio1.htmode='HE160'

# 注册 Web 界面一键 OTA 升级按钮
uci -q delete commands.@command[0]
uci add commands command
uci set commands.@command[-1].name='在线更新固件 (OTA)'
uci set commands.@command[-1].command='/usr/bin/autoupdate'

uci commit network
uci commit firewall
uci commit wireless
uci commit commands

exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-settings

# 4. 注入固件在线更新脚本 (修正 Shebang 为 /bin/sh)
mkdir -p files/usr/bin
cat << 'EOF' > files/usr/bin/autoupdate
#!/bin/sh

REPO="AA9skillz-BN/tr3000-512-25"
echo "[OTA] 正在检测 GitHub 最新固件..."

LATEST_TAG=$(curl -sL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$LATEST_TAG" ]; then
    echo "[错误] 无法获取最新 Release 版本号，请检查网络！"
    exit 1
fi

DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${LATEST_TAG}/immortalwrt-mediatek-filogic-cudy_tr3000-v1-squashfs-sysupgrade.bin"
echo "[OTA] 发现最新版本: ${LATEST_TAG}"
echo "[OTA] 正在下载固件..."

curl -L -# -o /tmp/sysupgrade.bin "$DOWNLOAD_URL"
if [ ! -f /tmp/sysupgrade.bin ] || [ ! -s /tmp/sysupgrade.bin ]; then
    echo "[错误] 固件下载失败或文件为空！"
    exit 1
fi

echo "[OTA] 正在进行固件完整性校验..."
if ! sysupgrade -t /tmp/sysupgrade.bin; then
    echo "[错误] 固件兼容性校验未通过，中止升级以保护设备！"
    rm -f /tmp/sysupgrade.bin
    exit 1
fi

echo "[OTA] 校验通过，正在保留配置升级并重启..."
sysupgrade -v -q /tmp/sysupgrade.bin
EOF
chmod +x files/usr/bin/autoupdate
