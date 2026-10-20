#!/bin/bash
# Description: OpenWrt DIY script part 1 (Before Update feeds)

# 1. 添加 VIKINGYFY 专属软件包源（包含 PPE 加速及优化插件）
if ! grep -q "viking_packages" feeds.conf.default; then
    echo "src-git viking_packages https://github.com/VIKINGYFY/packages.git" >> "feeds.conf.default"
fi

# 2. 直接拉取 Aurora 主题与 Aurora 配置插件到 package 目录 (确保 100% 编译进固件)
rm -rf package/luci-theme-aurora package/luci-app-aurora-config
git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora
git clone --depth=1 https://github.com/eamonxg/luci-app-aurora-config.git package/luci-app-aurora-config

# 3. 直接拉取最新版 OpenClash 源码包
rm -rf package/luci-app-openclash
git clone --depth=1 -b master https://github.com/vernesong/OpenClash.git package/openclash-tmp
mv -f package/openclash-tmp/luci-app-openclash package/luci-app-openclash
rm -rf package/openclash-tmp
