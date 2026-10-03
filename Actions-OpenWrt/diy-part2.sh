#!/bin/bash

# 1. 复制 512MB 设备树至 target 目录
cp -f "$GITHUB_WORKSPACE/openwrt-mod/mt7981b-cudy-tr3000-512mb-v1.dts" target/linux/mediatek/dts/

# 2. 追加 512MB 编译规则至 filogic.mk
if ! grep -q "cudy_tr3000-512mb" target/linux/mediatek/image/filogic.mk; then
    cat "$GITHUB_WORKSPACE/openwrt-mod/cudy-tr3000-512.mk" >> target/linux/mediatek/image/filogic.mk
fi

# 3. 【核心加速】从 tools 编译链中直接抹除耗时 1.5 小时的 llvm-bpf 编译入口
sed -i '/llvm-bpf/d' tools/Makefile
sed -i 's/CONFIG_TOOLS_LLVM_BPF=y/# CONFIG_TOOLS_LLVM_BPF is not set/g' .config 2>/dev/null || true
sed -i 's/CONFIG_KERNEL_BPF_TOOLCHAIN=y/# CONFIG_KERNEL_BPF_TOOLCHAIN is not set/g' .config 2>/dev/null || true
