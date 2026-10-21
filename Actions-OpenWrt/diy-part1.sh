#!/bin/bash
# Description: OpenWrt DIY script part 1 (Before Update feeds)
#
# 原则：任何一步失败都必须让构建失败。上游仓库改名、分支变动、网络抖动
# 都会让某个包静默缺失，而 make defconfig 对这种缺失是"默默删掉符号"，
# 最终产出全绿但缺功能的固件。这里一律用 die 显式打断。
set -euo pipefail

die() { echo "❌ [diy-part1] $*" >&2; exit 1; }

[ -f feeds.conf.default ] || die "feeds.conf.default 不存在，当前目录不是 OpenWrt 源码根目录"

# 1. 添加 VIKINGYFY 专属软件包源（补齐官方 feed 里没有的包）
if ! grep -q "viking_packages" feeds.conf.default; then
    echo "src-git viking_packages https://github.com/VIKINGYFY/packages.git" >> feeds.conf.default
    echo "✔ 已添加 viking_packages feed"
fi

# 克隆一个包到 package/ 下，并校验确实拿到了 Makefile
clone_pkg() {
    local url="$1"
    local dir="$2"

    rm -rf "$dir"
    git clone --depth=1 "$url" "$dir" || die "clone 失败: $url"
    [ -f "$dir/Makefile" ] || die "$dir 下没有 Makefile，仓库结构可能已变化"
}

# 2. Aurora 主题与 Aurora 配置插件
clone_pkg https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora
clone_pkg https://github.com/eamonxg/luci-app-aurora-config.git package/luci-app-aurora-config

# 3. 最新版 OpenClash（仓库根目录不是包目录，需要取子目录）
rm -rf package/luci-app-openclash package/openclash-tmp
git clone --depth=1 -b master https://github.com/vernesong/OpenClash.git package/openclash-tmp \
    || die "clone OpenClash 失败"
[ -d package/openclash-tmp/luci-app-openclash ] || die "OpenClash 仓库结构变化，未找到 luci-app-openclash 子目录"
mv -f package/openclash-tmp/luci-app-openclash package/luci-app-openclash
rm -rf package/openclash-tmp
[ -f package/luci-app-openclash/Makefile ] || die "luci-app-openclash/Makefile 缺失"

echo "✔ [diy-part1] 全部完成"
exit 0
