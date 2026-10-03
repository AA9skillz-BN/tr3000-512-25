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

# 2. 注入中兴 F50 5G 随身 WiFi 的全套驱动与依赖环境
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
EOF
