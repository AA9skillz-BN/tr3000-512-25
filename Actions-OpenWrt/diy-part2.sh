#!/bin/bash
# Description: OpenWrt DIY script part 2 (After Update feeds)

# 1. 修改默认后台 IP 为 192.168.6.1
sed -i 's/192.168.1.1/192.168.6.1/g' package/base-files/files/bin/config_generate || true

# ==============================================================================
# 2. 基于源码原版 mt7981b-cudy-tr3000-v1.dts 原地无损扩容 ubi 分区至 512MB
# ==============================================================================
ORIG_DTS="target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1.dts"
if [ -f "$ORIG_DTS" ]; then
    sed -i 's/reg = <0x5c0000 0x[0-9a-fA-F]*>/reg = <0x5c0000 0x1da40000>/g' "$ORIG_DTS"
    sed -i 's/Cudy TR3000 v1/Cudy TR3000 512MB v1/g' "$ORIG_DTS"
    echo "✔ 设备树 ubi 分区扩容修正完毕！"
fi

# ==============================================================================
# 3. 注入 512MB 专属机型定义 (移除无用的 automount 磁盘挂载依赖)
# ==============================================================================
FILOGIC_MK="target/linux/mediatek/image/filogic.mk"
if [ -f "$FILOGIC_MK" ] && ! grep -q "cudy_tr3000-512mb-v1" "$FILOGIC_MK"; then
    cat << 'EOF' >> "$FILOGIC_MK"

define Device/cudy_tr3000-512mb-v1
  DEVICE_VENDOR := Cudy
  DEVICE_MODEL := TR3000
  DEVICE_VARIANT := 512MB v1
  DEVICE_DTS := mt7981b-cudy-tr3000-v1
  DEVICE_DTS_DIR := ../dts
  SUPPORTED_DEVICES += R47 cudy,tr3000-v1 cudy,tr3000-512mb-v1
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 485632k
  KERNEL_IN_UBI := 1
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
endef
TARGET_DEVICES += cudy_tr3000-512mb-v1
EOF
fi

# ==============================================================================
# 4. 在线升级核心脚本与 LuCI 视图 (去除冗余的 openbox 停止命令)
# ==============================================================================
mkdir -p package/base-files/files/usr/bin || true
cat << 'EOF' > package/base-files/files/usr/bin/auto-update-firmware.sh
#!/bin/sh

REPO="AA9skillz-BN/tr3000-512-25"
LOG_FILE="/tmp/firmware_update.log"
TMP_BIN="/tmp/firmware_upgrade.bin"
TMP_SHA="/tmp/sha256sums"

UPGRADE_OPTS=""
MODE_DESC="保留当前配置 (无缝升级)"
if [ "$1" = "-n" ]; then
    UPGRADE_OPTS="-n"
    MODE_DESC="不保留配置 (恢复出厂全新刷入)"
fi

PROXIES="https://ghfast.top/ https://ghproxy.net/"
> "$LOG_FILE"
log() { echo "$@" >> "$LOG_FILE"; }

log "=========================================="
log "目标仓库: https://github.com/$REPO"
log "升级模式: $MODE_DESC"
log "正在检测网络并连接 GitHub API..."
log "=========================================="

API_URL="https://api.github.com/repos/$REPO/releases/latest"
RELEASE_JSON=$(curl -sL -m 15 -H "User-Agent: Cudy-TR3000-OTA" "$API_URL")

if [ -z "$RELEASE_JSON" ] || ! echo "$RELEASE_JSON" | grep -q "tag_name"; then
    log "⚠ 直连 GitHub API 超时，正在尝试加速镜像通道..."
    for P in $PROXIES; do
        RELEASE_JSON=$(curl -sL -m 15 -H "User-Agent: Cudy-TR3000-OTA" "${P}${API_URL}")
        if echo "$RELEASE_JSON" | grep -q "tag_name"; then
            log "✔ 成功通过加速镜像获取元数据: $P"
            break
        fi
    done
fi

DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o 'https://[^" ]*cudy_tr3000-512mb-v1[^" ]*sysupgrade\.bin' | head -n 1)
[ -z "$DOWNLOAD_URL" ] && DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o 'https://[^" ]*sysupgrade\.bin' | head -n 1)
SHA_URL=$(echo "$RELEASE_JSON" | grep -o 'https://[^" ]*sha256sums' | head -n 1)
TAG_NAME=$(echo "$RELEASE_JSON" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | cut -d'"' -f4)

if [ -z "$DOWNLOAD_URL" ]; then
    log "❌ 检查失败: 未能在最新 Release 中找到匹配的固件！"
    exit 1
fi

log "✔ 发现可用版本: ${TAG_NAME:-最新发布}"
log "固件直连源: $DOWNLOAD_URL"
echo "" >> "$LOG_FILE"

sync
echo 3 > /proc/sys/vm/drop_caches
rm -f "$TMP_BIN" "$TMP_SHA"

download_file() {
    local remote_url="$1"
    local output_path="$2"
    local desc="$3"

    log "正在下载 $desc (优先直连)..."
    curl -L -k --connect-timeout 8 -m 300 --progress-bar -o "$output_path" "$remote_url" 2>> "$LOG_FILE"
    [ $? -eq 0 ] && [ -s "$output_path" ] && return 0

    log "⚠ 直连下载异常或超时，自动切换至国内加速镜像重试..."
    for P in $PROXIES; do
        local proxy_url="${P}${remote_url}"
        log "尝试镜像通道: $proxy_url"
        rm -f "$output_path"
        curl -L -k --connect-timeout 10 -m 300 --progress-bar -o "$output_path" "$proxy_url" 2>> "$LOG_FILE"
        if [ $? -eq 0 ] && [ -s "$output_path" ]; then
            log "✔ 镜像通道拉取成功"
            return 0
        fi
    done
    return 1
}

[ -n "$SHA_URL" ] && download_file "$SHA_URL" "$TMP_SHA" "校验清单 (sha256sums)"

download_file "$DOWNLOAD_URL" "$TMP_BIN" "系统固件镜像 (请勿断电)"
if [ $? -ne 0 ] || [ ! -s "$TMP_BIN" ]; then
    log "❌ 固件下载失败，直连及所有加速通道均不可达，请检查网络！"
    rm -f "$TMP_BIN" "$TMP_SHA"
    exit 1
fi

BIN_SIZE=$(ls -lh "$TMP_BIN" | awk '{print $5}')
log "✔ 固件下载成功，文件大小: $BIN_SIZE"
echo "" >> "$LOG_FILE"

if [ -s "$TMP_SHA" ]; then
    log "正在进行 SHA256 完整性比对..."
    BIN_NAME=$(basename "$DOWNLOAD_URL")
    EXPECTED_HASH=$(grep "$BIN_NAME" "$TMP_SHA" | awk '{print $1}')
    if [ -n "$EXPECTED_HASH" ]; then
        ACTUAL_HASH=$(sha256sum "$TMP_BIN" | awk '{print $1}')
        if [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]; then
            log "❌ 校验失败: 固件哈希不匹配！"
            rm -f "$TMP_BIN" "$TMP_SHA"
            exit 1
        fi
        log "✔ SHA256 哈希校验完全一致 ($ACTUAL_HASH)"
    fi
fi

if command -v fwtool >/dev/null 2>&1; then
    if ! fwtool -q -i /dev/null "$TMP_BIN" 2>/dev/null; then
        log "❌ 固件 Header 校验不通过，非合法 OpenWrt 固件！已终止。"
        rm -f "$TMP_BIN" "$TMP_SHA"
        exit 1
    fi
fi

log "✔ 安全校验通过！即将以【$MODE_DESC】模式在 3 秒后写入并重启..."
log "=========================================="

/etc/init.d/openclash stop 2>/dev/null || true
sync
echo 3 > /proc/sys/vm/drop_caches

( sleep 3 && sysupgrade $UPGRADE_OPTS "$TMP_BIN" ) >/dev/null 2>&1 &
exit 0
EOF
chmod +x package/base-files/files/usr/bin/auto-update-firmware.sh || true

mkdir -p package/base-files/files/usr/share/luci/menu.d || true
cat << 'EOF' > package/base-files/files/usr/share/luci/menu.d/luci-app-autoupdate.json
{
	"admin/autoupdate": {
		"title": "固件升级",
		"order": 90,
		"action": {
			"type": "view",
			"path": "autoupdate/index"
		}
	}
}
EOF

mkdir -p package/base-files/files/usr/share/rpcd/acl.d || true
cat << 'EOF' > package/base-files/files/usr/share/rpcd/acl.d/luci-app-autoupdate.json
{
	"luci-app-autoupdate": {
		"description": "Grant access to autoupdate procedures",
		"read": {
			"file": {
				"/tmp/firmware_update.log": [ "read" ]
			}
		},
		"write": {
			"file": {
				"/usr/bin/auto-update-firmware.sh": [ "exec" ],
				"/bin/sh": [ "exec" ]
			}
		}
	}
}
EOF

mkdir -p package/base-files/files/www/luci-static/resources/view/autoupdate || true
cat << 'EOF' > package/base-files/files/www/luci-static/resources/view/autoupdate/index.js
'use strict';
'require view';
'require fs';
'require ui';

return view.extend({
	load: function() {
		return Promise.all([
			fs.read_direct('/tmp/firmware_update.log').catch(function() { return ''; }),
			fs.lines('/etc/openwrt_release').catch(function() { return []; })
		]);
	},

	render: function(data) {
		var logText = data[0] || '等待操作：请选择升级模式并点击下方按钮开始同步最新构建...';

		var styleNode = E('style', {}, [
			'@keyframes pulse-bar { 0% { background-position: 0% 50%; } 50% { background-position: 100% 50%; } 100% { background-position: 0% 50%; } }',
			'@keyframes blink-dot { 0%, 100% { opacity: 1; transform: scale(1); } 50% { opacity: 0.4; transform: scale(0.85); } }',
			'.ota-progress-container { width: 100%; background: #222; border-radius: 8px; height: 12px; overflow: hidden; margin: 15px 0; display: none; border: 1px solid #444; }',
			'.ota-progress-bar { width: 100%; height: 100%; background: linear-gradient(90deg, #00c6ff, #0072ff, #00ff87, #60efff); background-size: 300% 300%; animation: pulse-bar 2s ease infinite; }',
			'.ota-badge { display: inline-flex; align-items: center; padding: 4px 10px; border-radius: 20px; font-size: 12px; margin-right: 10px; background: #2a2a2a; color: #eaeaea; border: 1px solid #444; }',
			'.ota-dot { width: 8px; height: 8px; border-radius: 50%; margin-right: 6px; }',
			'.ota-dot.active { animation: blink-dot 1s infinite; }',
			'.dot-idle { background: #888; }',
			'.dot-down { background: #00b4d8; }',
			'.dot-check { background: #ffb703; }',
			'.dot-flash { background: #ef233c; }',
			'.keep-config-box { display: flex; align-items: center; gap: 8px; padding: 10px 14px; border-radius: 10px; background: rgba(0, 180, 216, 0.08); border: 1px solid rgba(0, 180, 216, 0.3); margin-bottom: 15px; width: fit-content; }'
		]);

		var progressBar = E('div', { 'class': 'ota-progress-container', 'id': 'ota_progress' }, [
			E('div', { 'class': 'ota-progress-bar' })
		]);

		var statusBadges = E('div', { 'style': 'margin-bottom: 12px; display: flex; flex-wrap: wrap; gap: 8px;' }, [
			E('span', { 'class': 'ota-badge', 'id': 'badge_status' }, [
				E('span', { 'class': 'ota-dot dot-idle', 'id': 'dot_status' }),
				E('span', { 'id': 'text_status' }, _('待机中'))
			]),
			E('span', { 'class': 'ota-badge' }, [
				E('strong', { 'style': 'color: #00ff87;' }, 'MT7981B'),
				' (512MB / mod-490)'
			])
		]);

		var keepConfigCheckbox = E('input', {
			'type': 'checkbox',
			'id': 'chk_keep_config',
			'checked': 'checked',
			'style': 'width: 16px; height: 16px; cursor: pointer;',
			'change': function(ev) {
				var hint = document.getElementById('keep_config_hint');
				if (ev.target.checked) {
					hint.innerText = '（推荐：保留拨号、无线密码及备份名单内的插件设置）';
					hint.style.color = '';
				} else {
					hint.innerText = '（⚠️ 警告：将清空所有个人数据并恢复出厂设置，适合大版本跨度更新）';
					hint.style.color = '#ef233c';
				}
			}
		});

		var viewDOM = E('div', { 'class': 'cbi-map' }, [
			styleNode,
			E('h2', {}, _('在线固件升级')),
			E('div', { 'class': 'cbi-map-descr' }, _('一键拉取 AA9skillz-BN/tr3000-512-25 仓库最新 Release 固件，支持国内镜像智能故障转移与刷机模式自由切换。')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('升级控制台')),
				E('div', { 'class': 'cbi-section-node' }, [
					statusBadges,
					E('div', { 'class': 'keep-config-box' }, [
						keepConfigCheckbox,
						E('label', { 'for': 'chk_keep_config', 'style': 'font-weight: 600; cursor: pointer; user-select: none;' }, _('保留当前系统配置')),
						E('span', { 'id': 'keep_config_hint', 'style': 'font-size: 12px; opacity: 0.8;' }, _('（推荐：保留拨号、无线密码及备份名单内的插件设置）'))
					]),
					E('div', { 'style': 'margin-bottom: 15px;' }, [
						E('button', {
							'id': 'btn_start_update',
							'class': 'cbi-button cbi-button-action important',
							'click': function(ev) {
								var keep = document.getElementById('chk_keep_config').checked;
								if (!keep && !window.confirm('⚠️ 确定要【不保留配置】升级吗？\n\n这将会抹除路由器上所有的个人配置，恢复到初始出厂状态！')) {
									return;
								}
								ev.target.disabled = true;
								document.getElementById('chk_keep_config').disabled = true;
								document.getElementById('ota_progress').style.display = 'block';
								
								var dot = document.getElementById('dot_status');
								var txt = document.getElementById('text_status');
								dot.className = 'ota-dot dot-down active';
								txt.innerText = keep ? '正在拉取固件 (保留配置模式)...' : '正在拉取固件 (全新恢复出厂模式)...';

								var cmd = keep ? '/usr/bin/auto-update-firmware.sh >/dev/null 2>&1 &' : '/usr/bin/auto-update-firmware.sh -n >/dev/null 2>&1 &';
								fs.exec('/bin/sh', ['-c', cmd]);

								var poll = window.setInterval(function() {
									var logArea = document.getElementById('update_log_area');
									if (!logArea) { window.clearInterval(poll); return; }
									fs.read_direct('/tmp/firmware_update.log').then(function(res) {
										if (res) {
											logArea.value = res;
											logArea.scrollTop = logArea.scrollHeight;
											if (res.indexOf('加速镜像') !== -1) txt.innerText = '已切换国内加速通道下载中...';
											if (res.indexOf('SHA256 完整性比对') !== -1) {
												dot.className = 'ota-dot dot-check active';
												txt.innerText = '正在校验固件哈希一致性...';
											}
											if (res.indexOf('安全校验通过') !== -1) {
												dot.className = 'ota-dot dot-flash active';
												txt.innerText = '⚠️ 正在刷入闪存并重启，请勿断电！';
												document.getElementById('btn_start_update').innerText = '正在写入闪存中...';
											}
											if (res.indexOf('❌') !== -1) {
												dot.className = 'ota-dot dot-flash';
												txt.innerText = '升级失败，已安全终止';
												document.getElementById('ota_progress').style.display = 'none';
												document.getElementById('btn_start_update').disabled = false;
												document.getElementById('chk_keep_config').disabled = false;
												window.clearInterval(poll);
											}
										}
									});
								}, 1200);
							}
						}, _('⚡ 立即拉取并在线升级'))
					]),
					progressBar,
					E('textarea', {
						'id': 'update_log_area',
						'class': 'cbi-input-textarea',
						'style': 'width: 100%; height: 280px; font-family: monospace; background: #121212; color: #00ff87; padding: 12px; border-radius: 6px; border: 1px solid #333; line-height: 1.4;',
						'readonly': 'readonly'
					}, logText)
				])
			])
		]);
		return viewDOM;
	},
	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
EOF

# ==============================================================================
# 5. 部署 F50 防限速 TTL=65 (原生 fw4 挂载) 与 USB 热插拔自愈看门狗
# ==============================================================================
mkdir -p package/base-files/files/usr/share/nftables.d/table-post || true
cat << 'EOF' > package/base-files/files/usr/share/nftables.d/table-post/99-f50-ttl.nft
chain f50_ttl {
    type filter hook postrouting priority 300; policy accept;
    oifname { "eth2", "usb0" } ip ttl set 65
    oifname { "eth2", "usb0" } ip6 hoplimit set 65
}
EOF

mkdir -p package/base-files/files/etc/hotplug.d/net || true
cat << 'EOF' > package/base-files/files/etc/hotplug.d/net/99-f50-auto
case "$ACTION" in
    add)
        if [ "$INTERFACE" = "usb0" ] || [ "$INTERFACE" = "eth2" ]; then
            if [ "$(uci -q get network.f50)" != "interface" ]; then
                uci set network.f50=interface
                uci set network.f50.proto='dhcp'
                uci set network.f50.metric='20'
                uci set network.f50.mtu='1420'
            fi
            CURRENT_DEV=$(uci -q get network.f50.device)
            if [ "$CURRENT_DEV" != "$INTERFACE" ]; then
                uci set network.f50.device="$INTERFACE"
                uci commit network
                /etc/init.d/network reload
            fi
            ( sleep 2 && ifup f50 ) >/dev/null 2>&1 &
        fi
        ;;
esac
EOF
chmod +x package/base-files/files/etc/hotplug.d/net/99-f50-auto || true

cat << 'EOF' > package/base-files/files/usr/bin/f50-watchdog.sh
#!/bin/sh
TARGET_IP="223.5.5.5"
LOG_TAG="F50-Watchdog"
DEV=$(uci -q get network.f50.device)
[ -z "$DEV" ] && exit 0
ip link show "$DEV" 2>/dev/null | grep -q "UP" || exit 0

GATEWAY_IP=$(ip route show default dev "$DEV" 2>/dev/null | awk '/via/ {print $3}' | head -n 1)
if [ -n "$GATEWAY_IP" ]; then
    if ! ping -c 2 -W 1 "$GATEWAY_IP" >/dev/null 2>&1; then
        logger -t "$LOG_TAG" "F50 ($DEV) 网关 $GATEWAY_IP 无响应，重连中..."
        ifup f50
        exit 0
    fi
fi
if ! ping -c 3 -W 2 -I "$DEV" "$TARGET_IP" >/dev/null 2>&1; then
    logger -t "$LOG_TAG" "检测到 F50 ($DEV) 蜂窝失联，重新请求租约..."
    ifup f50
fi
exit 0
EOF
chmod +x package/base-files/files/usr/bin/f50-watchdog.sh || true

# ==============================================================================
# 6. 预置 OpenClash 最新 ARM64 Meta (Mihomo) 内核 (使用软链接代替双份复制，省 25MB 空间)
# ==============================================================================
OC_ROOT="package/luci-app-openclash/root/etc/openclash"
[ ! -d "$OC_ROOT" ] && OC_ROOT="package/base-files/files/etc/openclash"
CORE_DIR="$OC_ROOT/core"
mkdir -p "$CORE_DIR"

META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz"
if curl -sL --connect-timeout 15 --retry 3 "$META_URL" -o /tmp/clash_meta.tar.gz; then
    tar -zxf /tmp/clash_meta.tar.gz -C "$CORE_DIR"
    mv -f "$CORE_DIR/clash" "$CORE_DIR/clash_meta" 2>/dev/null || true
    ln -sf clash_meta "$CORE_DIR/clash"
    chmod 0755 "$CORE_DIR/clash_meta"
    rm -f /tmp/clash_meta.tar.gz
    echo "✔ OpenClash Meta (clash_meta) 内核预置成功！"
fi

curl -sL --connect-timeout 15 --retry 2 "https://raw.githubusercontent.com/alecthw/mmdb_china_ip_list/release/lite/Country.mmdb" -o "$OC_ROOT/Country.mmdb" || true
curl -sL --connect-timeout 15 --retry 2 "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -o "$OC_ROOT/GeoSite.dat" || true
curl -sL --connect-timeout 15 --retry 2 "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -o "$OC_ROOT/GeoIP.dat" || true

mkdir -p package/base-files/files/etc || true
grep -qxF '/etc/openclash/' package/base-files/files/etc/sysupgrade.conf 2>/dev/null || echo '/etc/openclash/' >> package/base-files/files/etc/sysupgrade.conf

# ==============================================================================
# 7. 统一开机初始化脚本 (合并主题、时区、PPE加速、满血Wi-Fi、F50与OpenClash)
# ==============================================================================
mkdir -p package/base-files/files/etc/uci-defaults || true
cat << 'EOF' > package/base-files/files/etc/uci-defaults/99-custom-init
uci set luci.main.lang='zh_cn'
if [ -d "/www/luci-static/aurora" ]; then
    uci set luci.themes.Aurora='/luci-static/aurora'
    uci set luci.main.mediaurlbase='/luci-static/aurora'
fi
uci commit luci

uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].timezone='CST-8'
uci -q delete system.ntp.server
uci add_list system.ntp.server='ntp.aliyun.com'
uci add_list system.ntp.server='time1.cloud.tencent.com'
uci add_list system.ntp.server='cn.pool.ntp.org'
uci commit system

uci set network.f50=interface
uci set network.f50.proto='dhcp'
uci set network.f50.metric='20'
uci set network.f50.mtu='1420'
if [ -d "/sys/class/net/usb0" ]; then
    uci set network.f50.device='usb0'
elif [ -d "/sys/class/net/eth2" ]; then
    uci set network.f50.device='eth2'
fi
uci commit network

uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@defaults[0].flow_offloading_hw='1'
for i in $(seq 0 10); do
    if [ "$(uci -q get firewall.@zone[$i].name)" = "wan" ]; then
        uci del_list firewall.@zone[$i].network='f50' 2>/dev/null
        uci add_list firewall.@zone[$i].network='f50'
        break
    fi
done
uci commit firewall

for r in radio0 radio1; do
    BAND=$(uci -q get wireless.$r.band)
    uci -q delete wireless.$r.country
    uci set wireless.$r.cell_density='0'
    uci set wireless.$r.mu_beamformer='1'
    uci set wireless.$r.disabled='0'
    if [ "$BAND" = "5g" ]; then
        uci set wireless.$r.channel='36'
        uci set wireless.$r.htmode='HE160'
        uci set wireless.default_$r.disassoc_low_ack='0'
    elif [ "$BAND" = "2g" ]; then
        uci set wireless.$r.channel='6'
        uci set wireless.$r.htmode='HE40'
        uci set wireless.$r.noscan='1'
        uci set wireless.default_$r.disassoc_low_ack='0'
    fi
done
uci commit wireless

if [ -f "/etc/config/openclash" ]; then
    uci set openclash.config.core_version='linux-arm64'
    uci set openclash.config.enable_meta_core='1'
    uci commit openclash
fi
chmod 0755 /etc/openclash/core/clash* 2>/dev/null || true

CRON_JOB="*/3 * * * * /usr/bin/f50-watchdog.sh >/dev/null 2>&1"
( crontab -l 2>/dev/null | grep -v "f50-watchdog.sh"; echo "$CRON_JOB" ) | crontab -
/etc/init.d/cron enable
/etc/init.d/cron restart

/etc/init.d/rpcd restart 2>/dev/null || true
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/ 2>/dev/null || true
exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/99-custom-init || true

exit 0