#!/bin/bash
# Description: OpenWrt DIY script part 2 (After Update feeds)
#
# 设计原则：任何一步失败都必须让构建失败。
# 不要用 `|| true` 掩盖错误 —— 否则会产出"构建全绿、功能缺失"的固件
# （主题没编进去 / DTS 没扩容 / Meta 内核没打进 / 机型定义没生效）。
set -euo pipefail

die() { echo "❌ [diy-part2] $*" >&2; exit 1; }

# ==============================================================================
# 1. 修改默认后台 IP 为 192.168.6.1
# ==============================================================================
CFG_GEN="package/base-files/files/bin/config_generate"
[ -f "$CFG_GEN" ] || die "$CFG_GEN 不存在，源码结构可能已变化"
sed -i 's/192\.168\.1\.1/192.168.6.1/g' "$CFG_GEN"
grep -q '192\.168\.6\.1' "$CFG_GEN" || die "默认后台 IP 修改失败：$CFG_GEN 中未找到 192.168.1.1"
echo "✔ 默认后台 IP 已改为 192.168.6.1"

# ==============================================================================
# 2. 基于源码原版 mt7981b-cudy-tr3000-v1.dts 原地扩容 ubi 分区（512MiB 颗粒）
#    实测分区表(BL2/u-boot-env/Factory/bdinfo/FIP)之和 = 0x5c0000，
#    与源码 DTS 的 ubi 起始地址一致，所以只改 size 即可。
# ==============================================================================
ORIG_DTS="target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1.dts"
UBI_OFFSET="0x5c0000"      # BL2(1M) + u-boot-env(512K) + Factory(2M) + bdinfo(256K) + FIP(2M)
# 0x1da40000 是本机现有 U-Boot(mod) 布局里的实际取值：
#   0x5c0000 + 0x1da40000 = 0x1E000000 = 480MiB，512MiB 颗粒末尾还有 32MiB 不属于任何分区。
# 想把这 32MiB 也用上，需改成 0x1fa40000 (= 0x20000000 - 0x5c0000)，
# 并先确认 U-Boot 没有在 flash 尾部放 env/备份，否则会直接覆盖掉。
UBI_SIZE_512M="0x1da40000"

[ -f "$ORIG_DTS" ] || die "设备树不存在: $ORIG_DTS（源码分支可能已改名或换了布局）"

UBI_HITS=$(grep -c "reg = <${UBI_OFFSET} " "$ORIG_DTS" || true)
[ "$UBI_HITS" = "1" ] || die "$ORIG_DTS 中匹配到 ${UBI_HITS} 处 reg = <${UBI_OFFSET} ...> 分区（期望正好 1 处），请人工确认分区布局"

sed -i "s/reg = <${UBI_OFFSET} 0x[0-9a-fA-F]*>/reg = <${UBI_OFFSET} ${UBI_SIZE_512M}>/" "$ORIG_DTS"
sed -i 's/Cudy TR3000 v1/Cudy TR3000 512MB v1/g' "$ORIG_DTS"

grep -q "reg = <${UBI_OFFSET} ${UBI_SIZE_512M}>" "$ORIG_DTS" \
    || die "ubi 分区扩容未生效（期望 reg = <${UBI_OFFSET} ${UBI_SIZE_512M}>）"
echo "✔ 设备树 ubi 分区已扩容到 480MiB 布局（512MiB 颗粒）：$ORIG_DTS"

# ==============================================================================
# 3. 注入 512MB 专属机型定义
# ==============================================================================
FILOGIC_MK="target/linux/mediatek/image/filogic.mk"
[ -f "$FILOGIC_MK" ] || die "$FILOGIC_MK 不存在"

if grep -q "cudy_tr3000-512mb-v1" "$FILOGIC_MK"; then
    echo "✔ 机型 cudy_tr3000-512mb-v1 已存在，跳过注入"
else
    cat << 'EOF' >> "$FILOGIC_MK"

define Device/cudy_tr3000-512mb-v1
  DEVICE_VENDOR := Cudy
  DEVICE_MODEL := TR3000
  DEVICE_VARIANT := 512MB v1
  DEVICE_DTS := mt7981b-cudy-tr3000-v1
  DEVICE_DTS_DIR := ../dts
  # 注意：cudy,tr3000-v1 必须保留 —— DTS 的 compatible 没有改名，
  # /tmp/sysinfo/board_name 仍上报 cudy,tr3000-v1，删掉会导致本机 sysupgrade 被拒。
  # 副作用：未硬改 128MB 的原机也能刷入本镜像并变砖，对外发布时必须写明限制。
  SUPPORTED_DEVICES += R47 cudy,tr3000-v1 cudy,tr3000-512mb-v1
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  # ubi 分区 = 0x1da40000 = 485632KiB（0x5c0000 + 0x1da40000 = 0x1E000000 = 480MiB，
  # 512MiB 颗粒末尾 32MiB 未分配）。UBI 实际可用上限还要更小：
  #   3794 PEB - 73 坏块预留 - 2 layout LEB = 3719 LEB x 124KiB ≈ 450.3MiB
  # 所以取 450000k 留有约 10MiB 余量。写 485632k(=分区大小) 等于把尺寸检查关掉，
  # 镜像一旦超限只会在写入阶段失败，那才是真正会变砖的时刻。
  IMAGE_SIZE := 450000k
  KERNEL_IN_UBI := 1
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
endef
TARGET_DEVICES += cudy_tr3000-512mb-v1
EOF
    echo "✔ 已注入机型 cudy_tr3000-512mb-v1"
fi

# ==============================================================================
# 4. 在线升级脚本（SSH 执行：auto-update-firmware.sh [-n]）
#    - 全程校验证书，不再用 curl -k
#    - 下载后强制 SHA256 校验 + tar 结构校验 + sysupgrade -T 合规性预检
#    - 下载前/后都检查 /tmp(tmpfs) 剩余空间
# ==============================================================================
mkdir -p package/base-files/files/usr/bin
cat << 'EOF' > package/base-files/files/usr/bin/auto-update-firmware.sh
#!/bin/sh
# Cudy TR3000 512MB 在线升级：拉取最新 Release -> 校验 -> sysupgrade
# 用法: auto-update-firmware.sh        保留当前配置升级
#       auto-update-firmware.sh -n     不保留配置（恢复出厂）

REPO="AA9skillz-BN/tr3000-512-25"
LOG_FILE="/tmp/firmware_update.log"
TMP_BIN="/tmp/firmware_upgrade.bin"
TMP_SHA="/tmp/sha256sums"
MIN_FREE_KB=32768          # 下载前 /tmp 至少要有 32MiB
HEADROOM_KB=16384          # 下载后还要留 16MiB 余量
PROXIES="https://ghfast.top/ https://ghproxy.net/"

UPGRADE_OPTS=""
MODE_DESC="保留当前配置 (无缝升级)"
if [ "${1:-}" = "-n" ]; then
    UPGRADE_OPTS="-n"
    MODE_DESC="不保留配置 (恢复出厂全新刷入)"
fi

: > "$LOG_FILE"
log() { echo "$@" >> "$LOG_FILE"; }
die() { log "❌ $*"; exit 1; }

log "=========================================="
log "目标仓库: https://github.com/$REPO"
log "升级模式: $MODE_DESC"
log "=========================================="

# ---------- 1. 取最新 Release ----------
API_URL="https://api.github.com/repos/$REPO/releases/latest"
RELEASE_JSON=$(curl -fsSL -m 15 -H "User-Agent: Cudy-TR3000-OTA" "$API_URL" 2>>"$LOG_FILE" || true)

if ! echo "$RELEASE_JSON" | grep -q '"tag_name"'; then
    for P in $PROXIES; do
        RELEASE_JSON=$(curl -fsSL -m 15 -H "User-Agent: Cudy-TR3000-OTA" "${P}${API_URL}" 2>>"$LOG_FILE" || true)
        echo "$RELEASE_JSON" | grep -q '"tag_name"' && break
    done
fi
echo "$RELEASE_JSON" | grep -q '"tag_name"' || die "无法获取 Release 信息（GitHub API 与镜像通道均失败）"

TAG=$(echo "$RELEASE_JSON" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | cut -d'"' -f4)
log "最新版本: ${TAG:-unknown}"

DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o 'https://[^" ]*cudy_tr3000-512mb-v1[^" ]*sysupgrade\.bin' | head -n 1)
[ -z "$DOWNLOAD_URL" ] && DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o 'https://[^" ]*sysupgrade\.bin' | head -n 1)
SHA_URL=$(echo "$RELEASE_JSON" | grep -o 'https://[^" ]*sha256sums' | head -n 1)
[ -n "$DOWNLOAD_URL" ] || die "最新 Release 中没有 sysupgrade 镜像"
log "镜像地址: $DOWNLOAD_URL"

# ---------- 2. 空间检查 ----------
AVAIL_KB=$(df -k /tmp 2>/dev/null | awk 'NR==2 {print $4}')
[ -n "${AVAIL_KB:-}" ] || AVAIL_KB=0
log "/tmp 可用空间: ${AVAIL_KB} KiB"
[ "$AVAIL_KB" -ge "$MIN_FREE_KB" ] || die "/tmp 可用空间不足 ${MIN_FREE_KB}KiB，请清理后重试"

rm -f "$TMP_BIN" "$TMP_SHA"

# ---------- 3. 下载（主站失败自动走镜像，全程校验证书） ----------
download_file() {
    local url="$1"
    local out="$2"
    local desc="$3"

    curl -fsSL --connect-timeout 8 -m 300 -o "$out" "$url" 2>>"$LOG_FILE"
    if [ $? -eq 0 ] && [ -s "$out" ]; then
        log "✔ $desc 下载完成: $(wc -c < "$out") 字节"
        return 0
    fi

    for P in $PROXIES; do
        rm -f "$out"
        curl -fsSL --connect-timeout 10 -m 300 -o "$out" "${P}${url}" 2>>"$LOG_FILE"
        if [ $? -eq 0 ] && [ -s "$out" ]; then
            log "✔ $desc 经镜像 ${P} 下载完成: $(wc -c < "$out") 字节"
            return 0
        fi
    done

    log "✖ $desc 下载失败: $url"
    return 1
}

download_file "$DOWNLOAD_URL" "$TMP_BIN" "系统固件镜像" || die "固件下载失败"

IMG_KB=$(( ($(wc -c < "$TMP_BIN") + 1023) / 1024 ))
log "镜像大小: ${IMG_KB} KiB"
[ $((IMG_KB + HEADROOM_KB)) -le "$AVAIL_KB" ] \
    || die "/tmp 空间不足：镜像 ${IMG_KB}KiB + 余量 ${HEADROOM_KB}KiB > 可用 ${AVAIL_KB}KiB"

# ---------- 4. SHA256 校验 ----------
FNAME=$(basename "$DOWNLOAD_URL")
if [ -n "$SHA_URL" ] && download_file "$SHA_URL" "$TMP_SHA" "校验清单"; then
    WANT=$(awk -v f="$FNAME" '$2 == f || $2 == "*" f {print $1; exit}' "$TMP_SHA")
    if command -v sha256sum >/dev/null 2>&1; then
        GOT=$(sha256sum "$TMP_BIN" | awk '{print $1}')
    else
        GOT=$(busybox sha256sum "$TMP_BIN" | awk '{print $1}')
    fi
    if [ -z "$WANT" ]; then
        log "⚠ sha256sums 中没有 $FNAME，跳过哈希校验"
    elif [ "$WANT" != "$GOT" ]; then
        rm -f "$TMP_BIN"
        die "SHA256 校验失败：期望 $WANT，实际 $GOT"
    else
        log "✔ SHA256 校验通过"
    fi
else
    log "⚠ 未能获取 sha256sums，跳过哈希校验"
fi

# ---------- 5. 镜像合规性校验 ----------
tar -tf "$TMP_BIN" >/dev/null 2>&1 || die "镜像不是合法的 tar 包，已中止"
sysupgrade -T "$TMP_BIN" >>"$LOG_FILE" 2>&1 \
    || die "sysupgrade -T 预检失败：镜像与本机不匹配或已损坏"
log "✔ 镜像预检通过"

# ---------- 6. 提交升级 ----------
/etc/init.d/openclash stop 2>/dev/null || true
sync
if command -v nohup >/dev/null 2>&1; then
    nohup sh -c 'sleep 3; exec sysupgrade "$@"' _ $UPGRADE_OPTS "$TMP_BIN" >/dev/null 2>&1 &
else
    ( sleep 3 && sysupgrade $UPGRADE_OPTS "$TMP_BIN" ) >/dev/null 2>&1 &
fi
log "✔ 已提交升级任务，设备即将重启（日志: $LOG_FILE）"
exit 0
EOF
chmod +x package/base-files/files/usr/bin/auto-update-firmware.sh

# --- 4.1 LuCI 前端：菜单 + ACL + 视图（系统 → 在线升级） ---
mkdir -p package/base-files/files/usr/share/luci/menu.d \
         package/base-files/files/usr/share/rpcd/acl.d \
         package/base-files/files/www/luci-static/resources/view/autoupdate

cat << 'EOF' > package/base-files/files/usr/share/luci/menu.d/luci-app-autoupdate.json
{
	"admin/system/autoupdate": {
		"title": "在线升级",
		"order": 91,
		"action": {
			"type": "view",
			"path": "autoupdate/index"
		},
		"depends": {
			"acl": [ "luci-app-autoupdate" ]
		}
	}
}
EOF

cat << 'EOF' > package/base-files/files/usr/share/rpcd/acl.d/luci-app-autoupdate.json
{
	"luci-app-autoupdate": {
		"description": "Grant access to online firmware upgrade",
		"read": {
			"file": {
				"/tmp/firmware_update.log": [ "read" ]
			}
		},
		"write": {
			"file": {
				"/usr/bin/auto-update-firmware.sh": [ "exec" ]
			}
		}
	}
}
EOF

cat << 'EOF' > package/base-files/files/www/luci-static/resources/view/autoupdate/index.js
'use strict';
'require view';
'require fs';
'require ui';
'require poll';

return view.extend({
	load: function() {
		return fs.read('/tmp/firmware_update.log').catch(function() { return ''; });
	},

	render: function(log) {
		var logEl = E('pre', {
			'id': 'ota_log',
			'style': 'height:22rem;overflow:auto;white-space:pre-wrap;word-break:break-all;' +
				'font-family:monospace;font-size:12px;padding:8px;border-radius:4px;margin:0;'
		}, (typeof(log) === 'string') ? log : '');

		function run(noConfig) {
			var args = noConfig ? [ '-n' ] : [];
			return fs.exec('/usr/bin/auto-update-firmware.sh', args).then(function(res) {
				if (res.code !== 0)
					throw new Error('脚本退出码 ' + res.code);
				ui.addNotification(null,
					E('p', {}, '已开始下载并校验，进度见下方日志。升级过程中请勿断电。'), 'info');
			}).catch(function(e) {
				ui.addNotification(null, E('p', {}, '启动失败：' + e.message), 'error');
			});
		}

		poll.add(function() {
			return fs.read('/tmp/firmware_update.log').then(function(data) {
				if (typeof(data) === 'string') {
					logEl.textContent = data;
					logEl.scrollTop = logEl.scrollHeight;
				}
				return null;
			}).catch(function() { return null; });
		}, 3);

		return E([], [
			E('h2', {}, '在线升级'),
			E('div', { 'class': 'cbi-section' }, [
				E('p', {}, '从 GitHub Release 拉取最新固件，自动完成 SHA256 校验与 sysupgrade 合规性预检后再写入。'),
				E('div', { 'class': 'cbi-section-node' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-apply',
						'click': ui.createHandlerFn(this, function() {
							if (!confirm('开始在线升级？过程中请勿断电。'))
								return;
							return run(false);
						})
					}, '⚡ 立即拉取并升级（保留配置）'),
					' ',
					E('button', {
						'class': 'btn cbi-button cbi-button-reset',
						'click': ui.createHandlerFn(this, function() {
							if (!confirm('不保留配置升级，所有设置将被清除，确定继续？'))
								return;
							return run(true);
						})
					}, '不保留配置升级')
				]),
				E('h3', {}, '升级日志'),
				logEl
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
EOF

# ==============================================================================
# 5. F50 防限速 TTL=65 / 硬件加速 —— 二选一 + USB 总线热插拔
#
#    为什么必须二选一：开了 flow offload 后，已建连的包由 PPE 直接转发、
#    不再经过 netfilter，postrouting 里的 TTL 改写只在每个流的头几个包生效，
#    之后恢复原始 TTL(63)——同一个连接 TTL 忽 65 忽 63，比不改写更容易被识别。
#
#    F50_ACCEL=1  硬件加速优先，不生成 TTL 规则（CPU 占用低，运营商侧看到 TTL=63）
#    F50_ACCEL=0  TTL 防限速优先，关闭 flow offload
#
#    参考：F50 走 USB 共享，实测上限 300~500Mbps，而 MT7981 纯软件转发可跑 1Gbps+，
#    所以加速对吞吐基本没有提升，主要是降低 CPU 占用。
# ==============================================================================
F50_ACCEL=0

mkdir -p package/base-files/files/usr/share/nftables.d/table-post package/base-files/files/etc/hotplug.d/net

if [ "$F50_ACCEL" = "0" ]; then
    cat << 'EOF' > package/base-files/files/usr/share/nftables.d/table-post/99-f50-ttl.nft
chain f50_ttl {
    type filter hook postrouting priority 300; policy accept;
    oifname { "eth1", "eth2", "usb0" } ip ttl set 65
    oifname { "eth1", "eth2", "usb0" } ip6 hoplimit set 65
}
EOF
    echo "✔ 模式: TTL=65 防限速（flow offload 关闭）"
else
    rm -f package/base-files/files/usr/share/nftables.d/table-post/99-f50-ttl.nft
    : > package/base-files/files/etc/f50-accel
    echo "✔ 模式: 硬件加速（不生成 TTL 规则，运营商侧看到 TTL=63）"
fi

# USB 自动休眠：必须关掉。
# TR3000 + F50 实测：usbcore.autosuspend=2 时，模块空闲 2 秒即被挂起，
# 唤醒失败后内核直接断开并重新枚举（dmesg 里 usb 1-1 / 2-1 每 5 秒交替一轮），
# 网络完全不可用。关掉后连续 3 分钟零 USB 事件。
mkdir -p package/base-files/files/etc/init.d package/base-files/files/etc/rc.d
cat << 'EOF' > package/base-files/files/etc/init.d/usb-nosuspend
#!/bin/sh /etc/rc.common
# 关闭 USB runtime suspend，避免 5G 模块被挂起后无法唤醒
START=20

start() {
	[ -w /sys/module/usbcore/parameters/autosuspend ] && \
		echo -1 > /sys/module/usbcore/parameters/autosuspend
	for f in /sys/bus/usb/devices/*/power/control; do
		[ -w "$f" ] && echo on > "$f"
	done
}
EOF
chmod +x package/base-files/files/etc/init.d/usb-nosuspend
ln -sf ../init.d/usb-nosuspend package/base-files/files/etc/rc.d/S20usb-nosuspend

cat << 'EOF' > package/base-files/files/etc/hotplug.d/net/99-f50-auto
#!/bin/sh
# F50 5G USB 网卡自动绑定。
# 只认真正从 USB 总线枚举出来的网卡（用 sysfs device 路径判断），
# 不再按 eth1/eth2 这类名字硬匹配 —— 否则插一根网线就会把物理 LAN/WAN 口
# 改写成 5G WAN，直接破坏有线网络。

[ "$ACTION" = "add" ] || exit 0

DEVPATH=$(readlink -f "/sys/class/net/$INTERFACE/device" 2>/dev/null)
case "$DEVPATH" in
    *usb*) ;;
    *)
        # 少数 RNDIS/CDC 驱动的 device 链接里不含 "usb" 字样，退一步只认 usb* 命名；
        # eth* / wan / lan 一律不碰，避免插网线时把物理网口抢去当 5G WAN。
        case "$INTERFACE" in
            usb*) ;;
            *) exit 0 ;;
        esac
        ;;
esac

CHANGED=0
[ "$(uci -q get network.f50)" != "interface" ] && { uci set network.f50=interface; CHANGED=1; }
[ "$(uci -q get network.f50.proto)" != "dhcp" ] && { uci set network.f50.proto='dhcp'; CHANGED=1; }
[ "$(uci -q get network.f50.metric)" != "20" ] && { uci set network.f50.metric='20'; CHANGED=1; }
[ "$(uci -q get network.f50.mtu)" != "1420" ] && { uci set network.f50.mtu='1420'; CHANGED=1; }
CUR_DEV=$(uci -q get network.f50.device)
# 模组同时暴露多个网卡时，已绑定的那个还在就不要来回抢，避免网络反复 reload
if [ -n "$CUR_DEV" ] && [ "$CUR_DEV" != "$INTERFACE" ] && [ -e "/sys/class/net/$CUR_DEV" ]; then
    exit 0
fi
if [ "$CUR_DEV" != "$INTERFACE" ]; then
    uci set network.f50.device="$INTERFACE"
    CHANGED=1
fi

# 之前这里只在 device 变化时才 commit，其余 uci set 会丢失
if [ "$CHANGED" = "1" ]; then
    uci commit network
    logger -t f50-hotplug "绑定 $INTERFACE 到 network.f50 并重载网络"
    /etc/init.d/network reload
fi
exit 0
EOF
chmod +x package/base-files/files/etc/hotplug.d/net/99-f50-auto

cat << 'EOF' > package/base-files/files/usr/bin/f50-watchdog.sh
#!/bin/sh
# F50 蜂窝链路看门狗（cron 每 3 分钟）
#   1) 接口不存在 -> 直接退出（modem 被拔掉时不要误重连/误重启）
#   2) 接口存在但 operstate 不是 up -> 重连
#   3) 连续探测失败 -> 先重连；REBOOT_AFTER 次后重启（默认关闭，见下方说明）
#
# 注意：ifup 对已经 up 的接口是空操作，救不回卡死的 DHCP 租约，
# 所以这里一律先 ifdown 再 ifup。

# 需要自动重启兜底时，创建 /etc/f50-watchdog.conf 并写入： REBOOT_AFTER=6
REBOOT_AFTER=0
[ -f /etc/f50-watchdog.conf ] && . /etc/f50-watchdog.conf

DEV=$(uci -q get network.f50.device)
[ -n "$DEV" ] || exit 0
[ -d "/sys/class/net/$DEV" ] || exit 0

STATE=/tmp/.f50_watchdog_fails
TARGET="${F50_PING_TARGET:-223.5.5.5}"

reconnect() {
    logger -t f50-watchdog "重连 network.f50 ($DEV)"
    ifdown f50 2>/dev/null
    sleep 3
    ifup f50 2>/dev/null
}

OPER=$(cat "/sys/class/net/$DEV/operstate" 2>/dev/null)
if [ "$OPER" != "up" ]; then
    logger -t f50-watchdog "$DEV 链路状态 '${OPER:-unknown}'，执行重连"
    reconnect
    exit 0
fi

if ping -c 3 -W 2 -I "$DEV" "$TARGET" >/dev/null 2>&1; then
    rm -f "$STATE"
    exit 0
fi

FAILS=$(cat "$STATE" 2>/dev/null || echo 0)
case "$FAILS" in ''|*[!0-9]*) FAILS=0 ;; esac
FAILS=$((FAILS + 1))
echo "$FAILS" > "$STATE"
logger -t f50-watchdog "$DEV 探测 $TARGET 失败（连续 ${FAILS} 次）"

reconnect

if [ "${REBOOT_AFTER:-0}" -gt 0 ] 2>/dev/null && [ "$FAILS" -ge "$REBOOT_AFTER" ]; then
    logger -t f50-watchdog "连续 ${FAILS} 次重连无效，重启设备"
    rm -f "$STATE"
    sync
    reboot
fi
exit 0
EOF
chmod +x package/base-files/files/usr/bin/f50-watchdog.sh

# ==============================================================================
# 6. 预置 OpenClash 最新 ARM64 Meta 内核（带完整性校验）
# ==============================================================================
OC_ROOT="package/luci-app-openclash/root/etc/openclash"
if [ ! -d "$OC_ROOT" ]; then
    OC_ROOT="package/base-files/files/etc/openclash"
fi
CORE_DIR="$OC_ROOT/core"
mkdir -p "$CORE_DIR"

META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz"
if curl -fsSL --connect-timeout 15 --retry 3 "$META_URL" -o /tmp/clash_meta.tar.gz 2>/dev/null \
   && tar -tzf /tmp/clash_meta.tar.gz >/dev/null 2>&1 \
   && tar -zxf /tmp/clash_meta.tar.gz -C "$CORE_DIR" \
   && [ -s "$CORE_DIR/clash" ]; then
    mv -f "$CORE_DIR/clash" "$CORE_DIR/clash_meta"
    chmod 0755 "$CORE_DIR/clash_meta"
    ln -sf clash_meta "$CORE_DIR/clash"
    echo "✔ OpenClash Meta 内核预置成功"
else
    echo "⚠ OpenClash Meta 内核预置失败，固件内将不带内核（首启脚本也不会锁定 Meta 内核）" >&2
fi
rm -f /tmp/clash_meta.tar.gz

# 下载 Geo 数据，失败时删掉半截文件，避免 0 字节或 HTML 错误页被当成数据
fetch_data() {
    local url="$1"
    local out="$2"
    local desc="$3"
    if curl -fsSL --connect-timeout 15 --retry 2 "$url" -o "$out" 2>/dev/null && [ -s "$out" ]; then
        echo "✔ $desc 预置完成"
    else
        rm -f "$out"
        echo "⚠ $desc 预置失败（首次启动 OpenClash 时需联网补全）" >&2
    fi
}

fetch_data "https://raw.githubusercontent.com/alecthw/mmdb_china_ip_list/release/lite/Country.mmdb" "$OC_ROOT/Country.mmdb" "Country.mmdb"
fetch_data "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" "$OC_ROOT/GeoSite.dat" "GeoSite.dat"
fetch_data "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" "$OC_ROOT/GeoIP.dat" "GeoIP.dat"

mkdir -p package/base-files/files/etc
grep -qxF '/etc/openclash/' package/base-files/files/etc/sysupgrade.conf 2>/dev/null \
    || echo '/etc/openclash/' >> package/base-files/files/etc/sysupgrade.conf

# ==============================================================================
# 7. 统一开机初始化脚本（中文/主题/BBR/F50/Wi-Fi/OpenClash/看门狗）
# ==============================================================================
mkdir -p package/base-files/files/etc/uci-defaults
cat << 'EOF' > package/base-files/files/etc/uci-defaults/99-custom-init
#!/bin/sh
# 首次启动初始化（执行成功后 OpenWrt 会自动删除本文件）

# 1. 简体中文 + Aurora 主题
#    语言代码必须和固件里实际存在的 base.zh*.lmo 对上，写错就是整片英文。
#    这里直接读翻译目录里的文件名反推，不写死。
LANG_CODE=""
for d in /usr/lib/lua/luci/i18n /usr/share/ucode/luci/i18n /usr/share/luci/i18n; do
    [ -d "$d" ] || continue
    BF=$(ls "$d" 2>/dev/null | grep -E '^base\.zh' | head -n 1)
    [ -n "$BF" ] || continue
    case "$BF" in
        *zh_Hans*) LANG_CODE='zh_Hans' ;;
        *zh_Hant*) LANG_CODE='zh_Hant' ;;
        *)         LANG_CODE='zh_cn' ;;
    esac
    break
done
[ -n "$LANG_CODE" ] || LANG_CODE='zh_cn'
uci set luci.main.lang="$LANG_CODE"

# 第三方包（OpenClash）自带的语言目录用的是老命名 openclash.zh-cn.lmo；
# 本版语言代码若不是 zh_cn，补一份同内容文件，否则 OpenClash 页面会单独回退英文。
if [ "$LANG_CODE" != "zh_cn" ]; then
    for d in /usr/lib/lua/luci/i18n /usr/share/ucode/luci/i18n /usr/share/luci/i18n; do
        [ -d "$d" ] || continue
        for f in "$d"/*.zh-cn.lmo; do
            [ -f "$f" ] || continue
            t="${f%.zh-cn.lmo}.$LANG_CODE.lmo"
            [ -e "$t" ] || cp -f "$f" "$t"
        done
    done
fi
if [ -d "/www/luci-static/aurora" ]; then
    uci set luci.themes.Aurora='/luci-static/aurora'
    uci set luci.main.mediaurlbase='/luci-static/aurora'
fi
uci commit luci

# 2. 转发加速：由构建时的 F50_ACCEL 决定
#    存在 /etc/f50-accel 就是"加速优先"模式（TTL 规则不会生成），否则 TTL 优先。
if [ -f /etc/f50-accel ]; then
    uci set firewall.@defaults[0].flow_offloading='1'
    uci set firewall.@defaults[0].flow_offloading_hw='1'
else
    uci set firewall.@defaults[0].flow_offloading='0'
    uci set firewall.@defaults[0].flow_offloading_hw='0'
fi

# 3. F50 接口：优先选真正挂在 USB 总线上的网卡，找不到先用 usb0（之后由 hotplug 修正）
uci set network.f50=interface
uci set network.f50.proto='dhcp'
uci set network.f50.metric='20'
uci set network.f50.mtu='1420'

USB_DEV=""
for IFACE_PATH in /sys/class/net/*; do
    case "$(readlink -f "$IFACE_PATH/device" 2>/dev/null)" in
        *usb*) USB_DEV=$(basename "$IFACE_PATH"); break ;;
    esac
done
[ -n "$USB_DEV" ] || USB_DEV='usb0'
uci set network.f50.device="$USB_DEV"
uci commit network

# 4. 把 f50 挂到 wan 防火墙区域（不再硬编码 0..10 的索引上限）
ZONE_IDX=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.@zone\[\([0-9]\+\)\]\.name=['\"]\?wan['\"]\?$/\1/p" | head -n 1)
if [ -n "$ZONE_IDX" ]; then
    uci -q del_list "firewall.@zone[$ZONE_IDX].network=f50" 2>/dev/null
    uci add_list "firewall.@zone[$ZONE_IDX].network=f50"
fi
uci commit firewall

# 5. 时区与 NTP
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].timezone='CST-8'
uci -q delete system.ntp.server
uci add_list system.ntp.server='ntp.aliyun.com'
uci add_list system.ntp.server='time1.cloud.tencent.com'
uci commit system

# 6. Wi-Fi 6
for r in radio0 radio1; do
    [ -n "$(uci -q get wireless.$r)" ] || continue
    BAND=$(uci -q get wireless.$r.band)
    uci set wireless.$r.country='US'
    uci set wireless.$r.cell_density='0'
    uci set wireless.$r.mu_beamformer='1'
    uci set wireless.$r.disabled='0'
    uci set wireless.default_$r.disabled='0'
    if [ "$BAND" = "5g" ]; then
        uci set wireless.$r.channel='36'
        uci set wireless.$r.htmode='HE160'
        uci set wireless.default_$r.ssid='Cudy-TR3000-5G'
        uci set wireless.default_$r.disassoc_low_ack='0'
    elif [ "$BAND" = "2g" ]; then
        uci set wireless.$r.channel='6'
        uci set wireless.$r.htmode='HE40'
        uci set wireless.$r.noscan='1'
        uci set wireless.default_$r.ssid='Cudy-TR3000-2.4G'
        uci set wireless.default_$r.disassoc_low_ack='0'
    fi
done
uci commit wireless

# 7. OpenClash：只有内置内核确实存在时才锁定 Meta 内核
if [ -f "/etc/config/openclash" ] && [ -x /etc/openclash/core/clash_meta ]; then
    uci set openclash.config.enable_meta_core='1'
    uci set openclash.config.core_version='linux-arm64'
    uci commit openclash
fi
chmod 0755 /etc/openclash/core/clash* 2>/dev/null || true

# 8. 看门狗计划任务
CRON_JOB="*/3 * * * * /usr/bin/f50-watchdog.sh >/dev/null 2>&1"
( crontab -l 2>/dev/null | grep -v "f50-watchdog.sh"; echo "$CRON_JOB" ) | crontab -
/etc/init.d/cron enable
/etc/init.d/cron restart

rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null || true
exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/99-custom-init

# 说明：中文语言包不在构建期做路径探测（feeds 的安装布局因版本而异，探测容易误杀）。
# .config 里统一用 -zh-cn；真正的校验放在 workflow 的 defconfig 之后，缺了就报错并带诊断输出。

# ==============================================================================
# 8. 产物自检：任何一项缺失都让构建直接失败
# ==============================================================================
[ -f package/luci-theme-aurora/Makefile ]      || die "luci-theme-aurora 未就绪（diy-part1 的 clone 可能失败）"
[ -f package/luci-app-aurora-config/Makefile ] || die "luci-app-aurora-config 未就绪"
[ -f package/luci-app-openclash/Makefile ]     || die "luci-app-openclash 未就绪"
[ -x package/base-files/files/usr/bin/auto-update-firmware.sh ]        || die "OTA 脚本未生成"
[ -x package/base-files/files/usr/bin/f50-watchdog.sh ]                || die "看门狗脚本未生成"
[ -f package/base-files/files/etc/uci-defaults/99-custom-init ]        || die "首启脚本未生成"
[ -f package/base-files/files/www/luci-static/resources/view/autoupdate/index.js ] || die "OTA 视图未生成"
[ -f package/base-files/files/usr/share/luci/menu.d/luci-app-autoupdate.json ]     || die "OTA 菜单未生成"
[ -x package/base-files/files/etc/init.d/usb-nosuspend ]  || die "USB 禁止休眠脚本未生成"
[ -e package/base-files/files/etc/rc.d/S20usb-nosuspend ] || die "USB 禁止休眠未挂到 rc.d"
[ -f package/base-files/files/usr/share/rpcd/acl.d/luci-app-autoupdate.json ]      || die "OTA ACL 未生成"

if [ "$F50_ACCEL" = "0" ]; then
    [ -f package/base-files/files/usr/share/nftables.d/table-post/99-f50-ttl.nft ] || die "TTL 规则未生成"
else
    [ -f package/base-files/files/etc/f50-accel ] || die "加速模式标记文件未生成"
    if [ -f package/base-files/files/usr/share/nftables.d/table-post/99-f50-ttl.nft ]; then
        die "加速模式下不应存在 TTL 规则文件"
    fi
fi
grep -q 'define Device/cudy_tr3000-512mb-v1' "$FILOGIC_MK" || die "机型定义未注入"
grep -q 'IMAGE_SIZE := 450000k' "$FILOGIC_MK"       || die "IMAGE_SIZE 未按 512MiB 实际可用容量设置"
grep -q "${UBI_SIZE_512M}" "$ORIG_DTS"             || die "DTS 未扩容"
grep -q "^CONFIG_PACKAGE_luci-i18n-base-.*=y" .config || die "中文语言包未写入 .config"

echo "✔ [diy-part2] 全部定制项校验通过"
exit 0
