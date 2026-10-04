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

# 1. 清理 libubox 快照补丁冲突
rm -rf package/libs/libubox/patches

# 2. 将默认后台管理 IP 修改为 192.168.6.1
sed -i 's/192.168.1.1/192.168.6.1/g' package/base-files/files/bin/config_generate

# 3. 强制指定目标平台与 Cudy TR3000 512MB 机型（统一保持 512mb 标识，防止冲撞）
cat >> .config <<EOF
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_mediatek_filogic_DEVICE_cudy_tr3000-512mb=y
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_cudy_tr3000-512mb=y
EOF

# 4. 注入中兴 F50 5G 随身 WiFi 的全套驱动与依赖环境
cat >> .config <<EOF
# USB 基础子系统与 USB3.0 控制器驱动
CONFIG_PACKAGE_kmod-usb-core=y
CONFIG_PACKAGE_kmod-usb3=y

# F50 虚拟以太网驱动协议（全覆盖：CDC-Ether / CDC-NCM / RNDIS）
CONFIG_PACKAGE_kmod-usb-net=y
CONFIG_PACKAGE_kmod-usb-net-cdc-ether=y
CONFIG_PACKAGE_kmod-usb-net-cdc-ncm=y
CONFIG_PACKAGE_kmod-usb-net-rndis=y

# 串口与模式切换支持（防虚拟光驱锁死，支持后台 AT 调试）
CONFIG_PACKAGE_kmod-usb-serial=y
CONFIG_PACKAGE_kmod-usb-serial-option=y
CONFIG_PACKAGE_kmod-usb-serial-wwan=y
CONFIG_PACKAGE_usb-modeswitch=y
CONFIG_PACKAGE_usbutils=y
CONFIG_PACKAGE_kmod-nls-base=y
CONFIG_PACKAGE_kmod-nls-utf8=y

# 自动化脚本与 Web 界面依赖
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_jq=y
CONFIG_PACKAGE_luci-app-commands=y
EOF

# 5. 注入开机自启预设 (双频 Wi-Fi 160MHz 满血 + F50 eth2 自动拨号)
mkdir -p package/base-files/files/etc/uci-defaults
cat << 'EOF' > package/base-files/files/etc/uci-defaults/99-custom-settings
#!/bin/sh

# === A. 无线配置 (2.4G 信道 6, 5G 信道 36 满血 160MHz) ===
if [ ! -f /etc/config/wireless ]; then
    wifi config
fi

uci -q delete wireless.radio0
uci -q delete wireless.default_radio0
uci set wireless.radio0=wifi-device
uci set wireless.radio0.type='mac80211'
uci set wireless.radio0.path='platform/soc/18000000.wifi'
uci set wireless.radio0.band='2g'
uci set wireless.radio0.channel='6'
uci set wireless.radio0.htmode='HE20'
uci set wireless.radio0.country='CN'
uci set wireless.radio0.cell_density='0'
uci set wireless.radio0.disabled='0'

uci set wireless.default_radio0=wifi-iface
uci set wireless.default_radio0.device='radio0'
uci set wireless.default_radio0.network='lan'
uci set wireless.default_radio0.mode='ap'
uci set wireless.default_radio0.ssid='ImmortalWrt_2.4G'
uci set wireless.default_radio0.encryption='psk2'
uci set wireless.default_radio0.key='q19980720ZJX#'
uci set wireless.default_radio0.disabled='0'

uci -q delete wireless.radio1
uci -q delete wireless.default_radio1
uci set wireless.radio1=wifi-device
uci set wireless.radio1.type='mac80211'
uci set wireless.radio1.path='platform/soc/18000000.wifi+1'
uci set wireless.radio1.band='5g'
uci set wireless.radio1.channel='36'
uci set wireless.radio1.htmode='HE160'
uci set wireless.radio1.country='CN'
uci set wireless.radio1.cell_density='0'
uci set wireless.radio1.disabled='0'

uci set wireless.default_radio1=wifi-iface
uci set wireless.default_radio1.device='radio1'
uci set wireless.default_radio1.network='lan'
uci set wireless.default_radio1.mode='ap'
uci set wireless.default_radio1.ssid='ImmortalWrt_5G'
uci set wireless.default_radio1.encryption='psk2'
uci set wireless.default_radio1.key='q19980720ZJX#'
uci set wireless.default_radio1.disabled='0'
uci commit wireless

# === B. 中兴 F50 USB 网卡 (eth2) 自动配置与防火墙绑定 ===
uci -q delete network.MODEM
uci set network.MODEM=interface
uci set network.MODEM.proto='dhcp'
uci set network.MODEM.device='eth2'
uci commit network

uci add_list firewall.@zone[1].network='MODEM'
uci commit firewall

# === C. 开启硬件加速流控 ===
if [ -f /etc/config/turboacc ]; then
    uci set turboacc.config.sw_flow='1'
    uci set turboacc.config.hw_flow='1'
    uci set turboacc.config.bbr_cca='1'
    uci set turboacc.config.fullcone_nat='1'
    uci commit turboacc
fi

uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@defaults[0].flow_offloading_hw='1'
uci commit firewall

# 生效所有网络与服务
/etc/init.d/network reload
wifi reload

exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/99-custom-settings

# 6. 植入固件在线一键更新核心脚本（绑定 AA9skillz-BN/tr3000-512-25）
mkdir -p package/base-files/files/usr/bin
cat <<'EOF' > package/base-files/files/usr/bin/autoupdate
#!/sh
# 路由器一键拉取 GitHub 最新 Release 并自动升级

GITHUB_REPO="AA9skillz-BN/tr3000-512-25"

echo "==============================================="
echo "  ImmortalWrt 25.x 自动升级程序"
echo "  目标机型: Cudy TR3000 (512MB)"
echo "==============================================="
echo "[1/3] 正在查询 GitHub 最新构建版本..."

DOWNLOAD_URL=$(curl -sL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | \
  jq -r '.assets[] | select(.name | test("cudy.*tr3000.*sysupgrade\\.bin$")) | .browser_download_url' | head -n 1)

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
  echo "[错误] 未能检测到匹配 cudy_tr3000 的最新 sysupgrade.bin 固件！"
  exit 1
fi

echo "发现最新固件下载地址:"
echo "-> $DOWNLOAD_URL"
echo ""
echo "[2/3] 正在下载固件到路由器内存 (/tmp/sysupgrade.bin) ..."
curl -L -# -o /tmp/sysupgrade.bin "$DOWNLOAD_URL"

if [ $? -ne 0 ] || [ ! -s /tmp/sysupgrade.bin ]; then
  echo "[错误] 固件下载中断或文件为空，请检查网络后重试！"
  rm -f /tmp/sysupgrade.bin
  exit 1
fi

echo "固件下载成功，文件完整！"
echo ""
echo "[3/3] 即将执行升级 (sysupgrade -n)..."
echo "升级期间请勿断电，设备将在 1-2 分钟内自动刷写并重启！"
echo "==============================================="

# 后台延迟 2 秒拉起升级，确保前端 Web 页面能完整输出日志
( sleep 2 && sysupgrade -n /tmp/sysupgrade.bin ) >/dev/null 2>&1 &
exit 0
EOF

chmod +x package/base-files/files/usr/bin/autoupdate

# 7. 配置 Web 界面“自定义命令（luci-app-commands）”菜单卡片
mkdir -p package/base-files/files/etc/config
cat <<'EOF' > package/base-files/files/etc/config/luci_commands
config command
	option name '在线检测并一键更新固件'
	option command '/usr/bin/autoupdate'
	option public '0'
EOF
