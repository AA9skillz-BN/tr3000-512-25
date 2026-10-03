#!/bin/bash

# 1. 添加 iStore 官方商店源（适配 25.x apk 架构）
if ! grep -q "linkease/istore" feeds.conf.default; then
    echo 'src-git istore https://github.com/linkease/istore.git;main' >> feeds.conf.default
fi

# 2. 添加 iStoreOS QuickStart 与配套后端组件官方真实源
if ! grep -q "linkease/nas-packages" feeds.conf.default; then
    echo 'src-git nas https://github.com/linkease/nas-packages.git;master' >> feeds.conf.default
    echo 'src-git nas_luci https://github.com/linkease/nas-packages-luci.git;main' >> feeds.conf.default
fi
