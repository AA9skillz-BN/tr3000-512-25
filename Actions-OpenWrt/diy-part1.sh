#!/bin/bash
# Description: OpenWrt DIY script part 1 (Before Update feeds)

# 取消默认 feeds 中可能被覆写的冲突源（可选）
# sed -i 's/^#\(.*helloworld\)/\1/' feeds.conf.default

# 添加 VIKINGYFY 专属软件包源（包含 PPE 加速及优化插件）
echo "src-git viking_packages https://github.com/VIKINGYFY/packages.git" >> "feeds.conf.default"