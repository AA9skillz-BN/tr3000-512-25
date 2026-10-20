#!/bin/bash
# Description: OpenWrt DIY script part 2 (After Update feeds)

# 1. 修改默认后台 IP 为 192.168.6.1
sed -i 's/192.168.1.1/192.168.6.1/g' package/base-files/files/bin/config_generate || true

# ==============================================================================
# 2. 无损复刻能开机系统的设备树：基于源码原版 mt7981b-cudy-tr3000-v1.dts 原地扩容 ubi
# ==============================================================================
DTS_DIR="target/linux/mediatek/dts"
ORIG_DTS="$DTS_DIR/mt7981b-cudy-tr3000-v1.dts"

if [ -f "$ORIG_DTS" ]; then
    echo "✔ 正在对源码原版设备树进行无损扩容 (保留 flash@0、nmbm 与 nvmem 属性)..."
    sed -i 's/reg = <0x5c0000 0x[0-9a-fA-F]*>/reg = <0x5c0000 0x1da40000>/g' "$ORIG_DTS"
    sed -i 's/Cudy TR3000 v1/Cudy TR3000 512MB v1/g' "$ORIG_DTS"
    echo "✔ 设备树 ubi 分区扩容修正完毕！"
else
    echo "❌ 错误: 未在源码中找到 $ORIG_DTS，请检查分支！"
fi

# ==============================================================================
# 3. 注入 512MB 专属机型定义 (修正 DEVICE_DTS_DIR 为 ../dts)
# ==============================================================================
FILOGIC_MK="target/linux/mediatek/image/filogic.mk"
if [ -f "$FILOGIC_MK" ]; then
    HAS_DEV=$(grep -c "cudy_tr3000-512mb-v1" "$FILOGIC_MK" || true)
    if [ "$HAS_DEV" -eq 0 ]; then
        echo "Injecting cudy_tr3000-512mb-v1 definition into $FILOGIC_MK"
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
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware automount
endef
TARGET_DEVICES += cudy_tr3000-512mb-v1
EOF
    fi
fi

# 4. 在线升级核心脚本 (支持保留配置与 -n 全新刷入切换、国内加速镜像、sha256 校验、OOM 防护)
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

log() {
    echo "$@" >> "$LOG_FILE"
}

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
if [ -z "$DOWNLOAD_URL" ]; then
    DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o 'https://[^" ]*sysupgrade\.bin' | head -n 1)
fi

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
    
    if [ $? -eq 0 ] && [ -s "$output_path" ]; then
        return 0
    fi

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

if [ -n "$SHA_URL" ]; then
    download_file "$SHA_URL" "$TMP_SHA" "校验清单 (sha256sums)"
fi

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
            log "❌ 校验失败: 固件哈希不匹配，可能文件被破坏或篡改！"
            log "期望值: $EXPECTED_HASH"
            log "实际值: $ACTUAL_HASH"
            rm -f "$TMP_BIN" "$TMP_SHA"
            exit 1
        fi
        log "✔ SHA256 哈希校验完全一致 ($ACTUAL_HASH)"
    else
        log "⚠ 校验清单中未检索到同名条目，跳过哈希强制比对"
    fi
fi

log "正在执行固件元数据合规检查..."
if command -v fwtool >/dev/null 2>&1; then
    if ! fwtool -q -i /dev/null "$TMP_BIN" 2>/dev/null; then
        log "❌ 固件 Header 校验不通过，非合法 OpenWrt 固件！已终止。"
        rm -f "$TMP_BIN" "$TMP_SHA"
        exit 1
    fi
fi

log "✔ 安全校验通过！即将以【$MODE_DESC】模式在 3 秒后写入并重启..."
log "提示: 刷入过程中切勿断电，完成后访问 192.168.6.1"
log "=========================================="

/etc/init.d/openclash stop 2>/dev/null || true
/etc/init.d/openbox stop 2>/dev/null || true
sync
echo 3 > /proc/sys/vm/drop_caches

( sleep 3 && sysupgrade $UPGRADE_OPTS "$TMP_BIN" ) >/dev/null 2>&1 &
exit 0
EOF
chmod +x package/base-files/files/usr/bin/auto-update-firmware.sh || true

# 5. 注册 LuCI 菜单
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

# 6. 注册 RPCD 访问控制列表 (ACL)
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

# 7. 部署 LuCI 视图 (支持保留/不保留配置勾选切换 + 防误触二次确认)
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
			'.keep-config-box { display: flex; align-items: center; gap: 8px; padding: 10px 14px; border-radius: 10px; background: rgba(201, 147, 62, 0.08); border: 1px solid rgba(201, 147, 62, 0.3); margin-bottom: 15px; width: fit-content; }'
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
			'style': 'width: 16px; height: 16px; cursor: pointer; accent-color: #c9933e;',
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
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('目标机型')),
						E('div', { 'class': 'cbi-value-field' }, E('strong', {}, 'Cudy TR3000 (512MB Flash)'))
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('更新通道')),
						E('div', { 'class': 'cbi-value-field' }, 'GitHub Releases (含国内备用镜像通道)')
					])
				])
			]),

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
								if (!keep) {
									if (!window.confirm('⚠️ 确定要【不保留配置】升级吗？\n\n这将会抹除路由器上所有的个人配置和后装插件，恢复到新固件的初始出厂状态！')) {
										return;
									}
								}

								ev.target.disabled = true;
								document.getElementById('chk_keep_config').disabled = true;
								document.getElementById('ota_progress').style.display = 'block';
								
								var dot = document.getElementById('dot_status');
								var txt = document.getElementById('text_status');
								dot.className = 'ota-dot dot-down active';
								txt.innerText = keep ? '正在拉取固件 (保留配置模式)...' : '正在拉取固件 (全新恢复出厂模式)...';

								ui.showModal(_('正在处理'), [
									E('p', { 'class': 'spinning' }, _('OTA 升级程序已启动，请关注下方动态进度条与实时输出...'))
								]);
								setTimeout(function() { ui.hideModal(); }, 2000);

								var cmd = keep ? '/usr/bin/auto-update-firmware.sh >/dev/null 2>&1 &' : '/usr/bin/auto-update-firmware.sh -n >/dev/null 2>&1 &';
								fs.exec('/bin/sh', ['-c', cmd]);

								var poll = window.setInterval(function() {
									var logArea = document.getElementById('update_log_area');
									if (!logArea) {
										window.clearInterval(poll);
										return;
									}

									fs.read_direct('/tmp/firmware_update.log').then(function(res) {
										if (res) {
											logArea.value = res;
											logArea.scrollTop = logArea.scrollHeight;

											if (res.indexOf('加速镜像') !== -1) {
												txt.innerText = '已切换国内加速通道下载中...';
											}
											if (res.indexOf('SHA256 完整性比对') !== -1) {
												dot.className = 'ota-dot dot-check active';
												txt.innerText = '正在校验固件哈希一致性...';
											}
											if (res.indexOf('安全校验通过') !== -1 || res.indexOf('执行写入') !== -1) {
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

# 8. 预置中兴 F50 免驱支持、MTU 1420 及防限速 TTL/HL=65 精准锁定 (抵消 F50 内部路由扣减 1 点)
mkdir -p package/base-files/files/etc/uci-defaults || true

cat << 'EOF' > package/base-files/files/etc/firewall.ttl
#!/bin/sh
nft add table inet fw4 2>/dev/null
nft add chain inet fw4 f50_ttl '{ type filter hook postrouting priority 300; policy accept; }' 2>/dev/null
nft flush chain inet fw4 f50_ttl 2>/dev/null
nft add rule inet fw4 f50_ttl oifname '{ "eth2", "usb0" }' ip ttl set 65 2>/dev/null
nft add rule inet fw4 f50_ttl oifname '{ "eth2", "usb0" }' ip6 hoplimit set 65 2>/dev/null
EOF
chmod +x package/base-files/files/etc/firewall.ttl || true

mkdir -p package/base-files/files/usr/share/nftables.d/table-post || true
cat << 'EOF' > package/base-files/files/usr/share/nftables.d/table-post/99-f50-ttl.nft
chain f50_ttl {
    type filter hook postrouting priority 300; policy accept;
    oifname { "eth2", "usb0" } ip ttl set 65
    oifname { "eth2", "usb0" } ip6 hoplimit set 65
}
EOF

cat << 'EOF' > package/base-files/files/etc/uci-defaults/99-f50-hotplug
uci set network.f50=interface
uci set network.f50.proto='dhcp'
uci set network.f50.metric='20'
uci set network.f50.mtu='1420'

DEV=""
if [ -d "/sys/class/net/usb0" ]; then
    DEV="usb0"
elif [ -d "/sys/class/net/eth2" ]; then
    DEV="eth2"
fi

if [ -n "$DEV" ]; then
    uci set network.f50.device="$DEV"
fi
uci commit network

uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@defaults[0].flow_offloading_hw='1'

for i in $(seq 0 10); do
    ZNAME=$(uci -q get firewall.@zone[$i].name)
    if [ "$ZNAME" = "wan" ]; then
        uci del_list firewall.@zone[$i].network='f50' 2>/dev/null
        uci add_list firewall.@zone[$i].network='f50'
        break
    fi
done
uci commit firewall

for r in radio0 radio1; do
    BAND=$(uci -q get wireless.$r.band)
    if [ "$BAND" = "5g" ]; then
        uci set wireless.$r.htmode='HE160'
        uci set wireless.$r.country='CN'
        uci set wireless.$r.disabled='0'
    elif [ "$BAND" = "2g" ]; then
        uci set wireless.$r.htmode='HE40'
        uci set wireless.$r.country='CN'
        uci set wireless.$r.disabled='0'
    fi
done
uci commit wireless

/etc/init.d/mwan3 disable 2>/dev/null || true
/etc/init.d/mwan3 stop 2>/dev/null || true

/etc/firewall.ttl 2>/dev/null || true
exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/99-f50-hotplug || true

# 9. 部署 USB 动态热插拔规则
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

            /etc/firewall.ttl 2>/dev/null || true
            ( sleep 2 && ifup f50 ) >/dev/null 2>&1 &
        fi
        ;;
esac
EOF
chmod +x package/base-files/files/etc/hotplug.d/net/99-f50-auto || true

# 10. 声明配置备份白名单
mkdir -p package/base-files/files/etc || true
cat << 'EOF' >> package/base-files/files/etc/sysupgrade.conf
/etc/openclash/
EOF

# 11. 系统时区与高可用国内 NTP 校准
mkdir -p package/base-files/files/etc/uci-defaults || true
cat << 'EOF' > package/base-files/files/etc/uci-defaults/99-timesync
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].timezone='CST-8'
uci -q delete system.ntp.server
uci add_list system.ntp.server='ntp.aliyun.com'
uci add_list system.ntp.server='time1.cloud.tencent.com'
uci add_list system.ntp.server='cn.pool.ntp.org'
uci add_list system.ntp.server='pool.ntp.org'
uci commit system
exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/99-timesync || true

# 12. 部署 F50 自动保活看门狗脚本
cat << 'EOF' > package/base-files/files/usr/bin/f50-watchdog.sh
#!/bin/sh

TARGET_IP="223.5.5.5"
LOG_TAG="F50-Watchdog"

DEV=$(uci -q get network.f50.device)
[ -z "$DEV" ] && exit 0

if ! ip link show "$DEV" 2>/dev/null | grep -q "UP"; then
    exit 0
fi

GATEWAY_IP=$(ip route show default dev "$DEV" 2>/dev/null | awk '/via/ {print $3}' | head -n 1)

if [ -n "$GATEWAY_IP" ]; then
    if ! ping -c 2 -W 1 "$GATEWAY_IP" >/dev/null 2>&1; then
        logger -t "$LOG_TAG" "F50 ($DEV) 本地网关 $GATEWAY_IP 无响应，重新请求连接..."
        ifup f50
        exit 0
    fi
fi

if ! ping -c 3 -W 2 -I "$DEV" "$TARGET_IP" >/dev/null 2>&1; then
    logger -t "$LOG_TAG" "检测到 F50 ($DEV) 蜂窝数据失联，正在重新请求 DHCP 租约..."
    ifup f50
fi
exit 0
EOF
chmod +x package/base-files/files/usr/bin/f50-watchdog.sh || true

# 13. 开机预置看门狗计划任务
cat << 'EOF' > package/base-files/files/etc/uci-defaults/99-f50-watchdog-cron
CRON_JOB="*/3 * * * * /usr/bin/f50-watchdog.sh >/dev/null 2>&1"
( crontab -l 2>/dev/null | grep -v "f50-watchdog.sh"; echo "$CRON_JOB" ) | crontab -
/etc/init.d/cron enable
/etc/init.d/cron restart
exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/99-f50-watchdog-cron || true

# ==============================================================================
# 14. 注入标准兼容版 CPE-MYOS 深度美化层 (无白框透明 SVG + 5秒实时刷新 + 防 FALLBACK)
# ==============================================================================

# 1. 编译期部署独立样式表 (兼容系统级深浅色与 Argon 手动深色切换)
mkdir -p package/base-files/files/www/luci-static/resources || true
cat << 'EOF' > package/base-files/files/www/luci-static/resources/cpe_myos_override.css
:root {
    --cpe-bg-main: #f6f5f0;
    --cpe-bg-card: #ffffff;
    --cpe-bg-sidebar: #fbfaf7;
    --cpe-gold: #c9933e;
    --cpe-gold-light: #fef5e7;
    --cpe-border: #edeae2;
    --myos-text-primary: #1e1e1e;
    --myos-text-secondary: #6e6e73;
    --cpe-radius-lg: 18px;
    --cpe-radius-md: 12px;
}

@media (prefers-color-scheme: light) {
    body:not(.login):not(.login-page):not([data-theme="dark"]):not(.dark) {
        background-color: var(--cpe-bg-main) !important;
    }
    body:not([data-theme="dark"]):not(.dark) .main-left,
    body:not([data-theme="dark"]):not(.dark) nav#mainmenu,
    body:not([data-theme="dark"]):not(.dark) .navigation,
    body:not([data-theme="dark"]):not(.dark) header {
        background-color: var(--cpe-bg-sidebar) !important;
        border-right: 1px solid var(--cpe-border) !important;
    }
}

/* 强制消除 SVG 画布与外层容器在任何主题下的背景白框 */
svg.device-model-svg,
.model-canvas svg,
.model-canvas > div {
    background: transparent !important;
    box-shadow: none !important;
    border: none !important;
}

.cbi-map > .cbi-section,
#maincontent > .panel,
#maincontent > .card {
    border-radius: var(--cpe-radius-lg) !important;
    border: 1px solid var(--cpe-border) !important;
    box-shadow: 0 4px 20px rgba(0, 0, 0, 0.025) !important;
    padding: 20px 24px !important;
    margin-bottom: 24px !important;
}

.myos-card {
    color: var(--myos-text-primary) !important;
}

.cbi-button-apply, .cbi-button-save, .cbi-button-action.important {
    background-color: var(--cpe-gold) !important;
    border-color: var(--cpe-gold) !important;
    color: #ffffff !important;
    border-radius: var(--cpe-radius-md) !important;
}

@keyframes login-wave {
    0% { transform: translateX(-50%) scale(0.7); opacity: 0.8; }
    50% { opacity: 0.4; }
    100% { transform: translateX(-50%) scale(1.35); opacity: 0; }
}

@keyframes float-badge {
    0%, 100% { transform: translateX(-50%) translateY(0); }
    50% { transform: translateX(-50%) translateY(-5px); }
}

body.login, .login-page, body:has(.login-container), body:has(.form-login) {
    background: radial-gradient(circle at 50% 30%, #ffffff 0%, #f6f5f0 75%) !important;
    min-height: 100vh !important;
}

body.login::before, .login-page::before, .login-bg, .main-bg, video#bg-video {
    display: none !important;
}

.login-page .login-container,
body.login .login-container, 
body.login .login-box, 
.login-container .form-login,
body.login form[action*="login"] {
    background: #ffffff !important;
    border-radius: 24px !important;
    border: 1px solid #edeae2 !important;
    box-shadow: 0 12px 40px rgba(27, 42, 74, 0.06), 0 2px 8px rgba(0, 0, 0, 0.02) !important;
    padding: 46px 36px 36px 36px !important;
    max-width: 400px !important;
    width: 90% !important;
    margin: 60px auto 20px auto !important;
    position: relative !important;
    overflow: visible !important;
}

.login-page .login-container::before,
body.login .login-container::before {
    content: "";
    position: absolute;
    top: -45px;
    left: 50%;
    transform: translateX(-50%);
    width: 90px;
    height: 90px;
    border-radius: 50%;
    background: rgba(201, 147, 62, 0.12);
    border: 1px solid rgba(201, 147, 62, 0.35);
    z-index: 1;
    pointer-events: none;
    animation: login-wave 3s infinite cubic-bezier(0, 0.2, 0.8, 1);
}

.login-page .login-container::after,
body.login .login-container::after {
    content: "5G";
    position: absolute;
    top: -35px;
    left: 50%;
    transform: translateX(-50%);
    width: 70px;
    height: 70px;
    border-radius: 50%;
    background: linear-gradient(135deg, #2c4c7a 0%, #182d49 100%);
    color: #ffffff;
    font-weight: 800;
    font-size: 20px;
    letter-spacing: 1px;
    display: flex;
    align-items: center;
    justify-content: center;
    box-shadow: 0 8px 20px rgba(44, 76, 122, 0.28);
    border: 3px solid #ffffff;
    z-index: 2;
    pointer-events: none;
    animation: float-badge 3.5s ease-in-out infinite;
}

.login-container h2,
body.login h2, 
body.login form[action*="login"] legend {
    font-size: 20px !important;
    font-weight: 700 !important;
    color: #1e1e1e !important;
    text-align: center !important;
    margin-top: 25px !important;
    margin-bottom: 6px !important;
}

.login-container input[type="text"],
.login-container input[type="password"],
body.login input[type="text"],
body.login input[type="password"] {
    background: #fbfaf7 !important;
    border: 1px solid #edeae2 !important;
    border-radius: 12px !important;
    padding: 12px 16px !important;
    font-size: 14px !important;
    color: #1e1e1e !important;
    width: 100% !important;
    box-sizing: border-box !important;
    transition: all 0.25s ease !important;
}

.login-container input[type="text"]:focus,
.login-container input[type="password"]:focus,
body.login input[type="text"]:focus,
body.login input[type="password"]:focus {
    border-color: #c9933e !important;
    background: #ffffff !important;
    box-shadow: 0 0 0 3px rgba(201, 147, 62, 0.15) !important;
    outline: none !important;
}

.login-container input[type="submit"],
.login-container .cbi-button-action,
body.login input[type="submit"],
body.login .cbi-button-action {
    background: linear-gradient(135deg, #c9933e 0%, #b8822f 100%) !important;
    border: none !important;
    border-radius: 12px !important;
    color: #ffffff !important;
    font-weight: 600 !important;
    font-size: 15px !important;
    padding: 12px !important;
    width: 100% !important;
    margin-top: 14px !important;
    cursor: pointer !important;
    box-shadow: 0 6px 16px rgba(201, 147, 62, 0.25) !important;
    transition: all 0.25s ease !important;
}

@media (prefers-color-scheme: dark) {
    :root {
        --cpe-bg-main: #121316 !important;
        --cpe-bg-card: rgba(26, 28, 34, 0.92) !important;
        --cpe-bg-sidebar: #181a20 !important;
        --cpe-border: rgba(255, 255, 255, 0.08) !important;
        --myos-text-primary: #F2F2F7 !important;
        --myos-text-secondary: #98989D !important;
    }
    .myos-card { color: #F2F2F7 !important; }
}

body[data-theme="dark"], body.dark {
    --cpe-bg-main: #121316 !important;
    --cpe-bg-card: rgba(26, 28, 34, 0.92) !important;
    --cpe-bg-sidebar: #181a20 !important;
    --cpe-border: rgba(255, 255, 255, 0.08) !important;
    --myos-text-primary: #F2F2F7 !important;
    --myos-text-secondary: #98989D !important;
}

body[data-theme="dark"] .myos-card, body.dark .myos-card {
    color: #F2F2F7 !important;
}

html, body {
    -webkit-tap-highlight-color: transparent !important;
    padding-bottom: env(safe-area-inset-bottom) !important;
}

.cbi-map > .cbi-section,
#maincontent > .panel,
#maincontent > .card,
.myos-card {
    backdrop-filter: blur(20px) !important;
    -webkit-backdrop-filter: blur(20px) !important;
}

@media (max-width: 768px) {
    #maincontent { padding: 12px 14px !important; }
    .myos-dashboard { grid-template-columns: 1fr !important; gap: 14px !important; }
    .model-canvas { min-height: 350px !important; padding: 16px !important; }
    .device-model-svg { width: 100% !important; max-width: 290px !important; height: auto !important; }
    .wave-base { width: 220px !important; height: 70px !important; bottom: 55px !important; }
}
EOF

# 2. 编译期物理固化 (同时兼容 Argon 与 Bootstrap 样式表)
for CSS_FILE in $(find package/ feeds/ -type f -name "cascade.css" 2>/dev/null | grep -E "argon|bootstrap"); do
    chmod +w "$CSS_FILE" 2>/dev/null || true
    if ! grep -Fq "cpe_myos_override.css" "$CSS_FILE"; then
        sed -i '1i@import url("/luci-static/resources/cpe_myos_override.css");' "$CSS_FILE"
    fi
done

# 3. 部署全真动态 + 5秒无感实时刷新版 CPE 聚合看板 (无白框透明 SVG)
mkdir -p package/base-files/files/www/luci-static/resources/view/status || true
cat << 'EOF' > package/base-files/files/www/luci-static/resources/view/status/cpe_dashboard.js
'use strict';
'require view';
'require fs';
'require ui';
'require rpc';
'require uci';
'require poll';

var callSystemInfo = rpc.declare({
	object: 'system',
	method: 'info'
});

var callNetworkInterfaces = rpc.declare({
	object: 'network.interface',
	method: 'dump'
});

function fetchDashboardData() {
	uci.unload('network');
	uci.unload('firewall');
	uci.unload('wireless');
	return Promise.all([
		callSystemInfo().catch(function() { return {}; }),
		fs.lines('/proc/net/arp').catch(function() { return []; }),
		callNetworkInterfaces().catch(function() { return { interface: [] }; }),
		fs.exec('/bin/df', ['-k', '/overlay']).catch(function() { return { stdout: '' }; }),
		uci.load('network').catch(function() {}),
		uci.load('firewall').catch(function() {}),
		uci.load('wireless').catch(function() {})
	]);
}

function formatUptime(sec) {
	if (typeof sec !== 'number' || sec <= 0) return '刚启动';
	var d = Math.floor(sec / 86400);
	var h = Math.floor((sec % 86400) / 3600);
	var m = Math.floor((sec % 3600) / 60);
	var s = sec % 60;
	if (d > 0) return d + '天 ' + h + '小时 ' + m + '分';
	if (h > 0) return h + '小时 ' + m + '分 ' + s + '秒';
	return m + '分 ' + s + '秒';
}

function parseDashboardData(data) {
	var info = (data && typeof data[0] === 'object' && data[0] !== null) ? data[0] : {};
	var arpLines = (data && Array.isArray(data[1])) ? data[1] : [];
	var ifaceData = (data && typeof data[2] === 'object' && data[2] !== null && Array.isArray(data[2].interface)) ? data[2].interface : [];
	var dfOut = (data && data[3] && typeof data[3].stdout === 'string') ? data[3].stdout : '';

	var clientCount = 0;
	if (Array.isArray(arpLines)) {
		clientCount = arpLines.filter(function(line) {
			if (typeof line !== 'string') return false;
			var p = line.trim().split(/\s+/);
			return p.length >= 6 && p[2] === '0x2' && p[3] !== '00:00:00:00:00:00';
		}).length;
	}

	var f50Online = false;
	var f50HasIP = false;
	var activeDevice = '未就绪';
	for (var i = 0; i < ifaceData.length; i++) {
		if (ifaceData[i].interface === 'f50') {
			if (ifaceData[i].up) {
				f50Online = true;
				activeDevice = ifaceData[i].l3_device || ifaceData[i].device || 'eth2';
				if (Array.isArray(ifaceData[i]['ipv4-address']) && ifaceData[i]['ipv4-address'].length > 0) {
					f50HasIP = true;
				}
			}
			break;
		}
	}

	var realMtu = uci.get('network', 'f50', 'mtu') || '1420';
	var fwDefs = uci.sections('firewall', 'defaults');
	var hwOffload = (fwDefs.length > 0 && fwDefs[0].flow_offloading_hw === '1');
	var swOffload = (fwDefs.length > 0 && fwDefs[0].flow_offloading === '1');
	var offloadText = hwOffload ? 'MTK PPE 硬件加速已开启' : (swOffload ? '软件流量分载已开启' : '未开启');

	var wifiUp = true;
	var htMode5g = 'HE160';
	var radios = uci.sections('wireless', 'wifi-device');
	for (var r = 0; r < radios.length; r++) {
		if (radios[r].band === '5g') {
			htMode5g = radios[r].htmode || 'HE80';
			if (radios[r].disabled === '1') wifiUp = false;
		}
	}

	var overlayText = '读取中...';
	if (dfOut) {
		var dfLines = dfOut.trim().split('\n');
		if (dfLines.length >= 2) {
			var cols = dfLines[dfLines.length - 1].trim().split(/\s+/);
			if (cols.length >= 4) {
				var totalMB = Math.round(parseInt(cols[1], 10) / 1024);
				var availMB = Math.round(parseInt(cols[3], 10) / 1024);
				if (!isNaN(availMB) && !isNaN(totalMB)) {
					overlayText = availMB + ' MB 可用 / 共 ' + totalMB + ' MB';
				}
			}
		}
	}

	var mem = info.memory || {};
	var totalMem = Math.round((typeof mem.total === 'number' ? mem.total : 536870912) / 1048576);
	var availMem = Math.round((typeof mem.available === 'number' ? mem.available : ((mem.free || 0) + (mem.buffered || 0) + (mem.cached || 0))) / 1048576);
	var usedMem = Math.max(0, totalMem - availMem);
	var memPercent = totalMem > 0 ? Math.round((usedMem / totalMem) * 100) : 0;

	var loadArr = Array.isArray(info.load) ? info.load : [0, 0, 0];
	var load1m = (loadArr[0] / 65536).toFixed(2);
	var uptimeStr = formatUptime(info.uptime);

	return {
		clientCount: clientCount,
		f50Online: f50Online,
		f50HasIP: f50HasIP,
		activeDevice: activeDevice,
		realMtu: realMtu,
		offloadText: offloadText,
		wifiUp: wifiUp,
		htMode5g: htMode5g,
		overlayText: overlayText,
		usedMem: usedMem,
		totalMem: totalMem,
		memPercent: memPercent,
		load1m: load1m,
		uptimeStr: uptimeStr
	};
}

return view.extend({
	load: function() {
		return fetchDashboardData();
	},

	render: function(data) {
		var st = parseDashboardData(data);

		var styleNode = E('style', {}, [
			'@keyframes ripple-wave { 0% { transform: scale(0.8); opacity: 0.8; } 100% { transform: scale(1.4); opacity: 0; } }',
			'@keyframes led-blink { 0%, 100% { opacity: 1; } 50% { opacity: 0.35; } }',
			'.myos-dashboard { display: grid; grid-template-columns: 1.35fr 1fr; gap: 20px; margin-bottom: 24px; }',
			'.myos-card { background: var(--cpe-bg-card, #ffffff); color: var(--myos-text-primary, #1e1e1e); border-radius: 20px; border: 1px solid var(--cpe-border, #edeae2); box-shadow: 0 4px 20px rgba(0,0,0,0.025); padding: 24px; position: relative; }',
			'.model-canvas { display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 420px; padding-top: 56px; position: relative; overflow: hidden; }',
			'.wave-base { position: absolute; width: 280px; height: 90px; border-radius: 50%; border: 2px solid ' + (st.f50Online ? 'rgba(41, 128, 185, 0.45)' : 'rgba(160, 160, 160, 0.3)') + '; bottom: 65px; z-index: 1; animation: ripple-wave 2.8s infinite cubic-bezier(0, 0.2, 0.8, 1); pointer-events: none; }',
			'.wave-base-2 { animation-delay: 1.4s; }',
			'.device-model-svg { z-index: 2; background: transparent !important; box-shadow: none !important; border: none !important; transition: transform 0.3s ease; }',
			'.device-model-svg:hover { transform: translateY(-3px); }',
			'.stat-grid-right { display: flex; flex-direction: column; gap: 16px; }',
			'.status-pill { display: inline-flex; align-items: center; padding: 4px 12px; border-radius: 20px; font-size: 12px; font-weight: 500; }',
			'.pill-online { background: #eafaf1; color: #27ae60; }',
			'.pill-offline { background: #fdf2e9; color: #e67e22; }'
		]);

		var deviceSvg = '<svg class="device-model-svg" width="340" height="240" viewBox="0 0 340 240" fill="none" style="background:transparent!important;box-shadow:none!important;" xmlns="http://www.w3.org/2000/svg">' +
			'<defs>' +
				'<linearGradient id="trBlueBody" x1="0%" y1="0%" x2="0%" y2="100%">' +
					'<stop offset="0%" stop-color="#2c4c7a" />' +
					'<stop offset="40%" stop-color="#243f66" />' +
					'<stop offset="100%" stop-color="#182d49" />' +
				'</linearGradient>' +
				'<linearGradient id="trAntenna" x1="0%" y1="0%" x2="100%" y2="0%">' +
					'<stop offset="0%" stop-color="#213b61" />' +
					'<stop offset="50%" stop-color="#34588c" />' +
					'<stop offset="100%" stop-color="#1a2e4c" />' +
				'</linearGradient>' +
				'<linearGradient id="f50White" x1="0%" y1="0%" x2="100%" y2="100%">' +
					'<stop offset="0%" stop-color="#FFFFFF" />' +
					'<stop offset="60%" stop-color="#F7F8FA" />' +
					'<stop offset="100%" stop-color="#E5E9F0" />' +
				'</linearGradient>' +
			'</defs>' +
			'<ellipse cx="150" cy="216" rx="100" ry="12" fill="#D6DEE8" opacity="0.45" />' +
			'<g transform="rotate(-18 68 170)">' +
				'<rect x="62" y="45" width="12" height="130" rx="6" fill="url(#trAntenna)" stroke="#1a2e4c" stroke-width="1.2" />' +
				'<circle cx="68" cy="170" r="8" fill="#1b2f4d" stroke="#34588c" stroke-width="1.5" />' +
			'</g>' +
			'<g transform="rotate(18 232 170)">' +
				'<rect x="226" y="45" width="12" height="130" rx="6" fill="url(#trAntenna)" stroke="#1a2e4c" stroke-width="1.2" />' +
				'<circle cx="232" cy="170" r="8" fill="#1b2f4d" stroke="#34588c" stroke-width="1.5" />' +
			'</g>' +
			'<rect x="75" y="140" width="150" height="68" rx="12" fill="url(#trBlueBody)" stroke="#1a2e4c" stroke-width="1.5" />' +
			'<path d="M85 142 L215 142" stroke="#4872a8" stroke-width="2" stroke-linecap="round" opacity="0.65" />' +
			'<text x="150" y="164" text-anchor="middle" font-family="-apple-system, BlinkMacSystemFont, sans-serif" font-size="11" font-weight="700" fill="#E8EEF5" letter-spacing="1.2">cudy</text>' +
			'<text x="150" y="175" text-anchor="middle" font-family="-apple-system, BlinkMacSystemFont, sans-serif" font-size="7.5" font-weight="600" fill="#8CA4C4" letter-spacing="0.5">TR3000 • 512MB</text>' +
			'<circle id="cpe_led_tr" cx="132" cy="192" r="2.5" fill="' + (st.f50Online ? '#00e676' : '#ffab00') + '" style="animation: led-blink 1.8s infinite;" />' +
			'<circle id="cpe_led_wifi1" cx="144" cy="192" r="2.5" fill="' + (st.wifiUp ? '#00e676' : '#ff5252') + '" />' +
			'<circle id="cpe_led_wifi2" cx="156" cy="192" r="2.5" fill="' + (st.wifiUp ? '#00e676' : '#ff5252') + '" />' +
			'<circle cx="168" cy="192" r="2.5" fill="#00e676" />' +
			'<path d="M225 178 C242 178, 245 150, 260 150" stroke="#7A8B9E" stroke-width="3" stroke-linecap="round" fill="none" />' +
			'<g transform="translate(258, 116)">' +
				'<rect x="2" y="4" width="46" height="66" rx="8" fill="#182d49" opacity="0.12" />' +
				'<rect x="0" y="0" width="46" height="66" rx="8" fill="url(#f50White)" stroke="#D0D7DE" stroke-width="1.5" />' +
				'<text x="23" y="20" text-anchor="middle" font-family="-apple-system, sans-serif" font-size="7.5" font-weight="800" fill="#2E3A4B">ZTE</text>' +
				'<text x="23" y="34" text-anchor="middle" font-family="-apple-system, sans-serif" font-size="9" font-weight="900" fill="#C9933E" letter-spacing="0.5">5G+</text>' +
				'<text x="23" y="44" text-anchor="middle" font-family="-apple-system, sans-serif" font-size="6" font-weight="600" fill="#8892A0">F50 Portable</text>' +
				'<circle id="cpe_led_f50_1" cx="17" cy="54" r="2" fill="' + (st.f50Online ? '#00e676' : '#ff5252') + '" style="animation: led-blink 1.5s infinite;" />' +
				'<circle id="cpe_led_f50_2" cx="29" cy="54" r="2" fill="' + (st.f50Online ? '#00e676' : '#999') + '" />' +
			'</g>' +
		'</svg>';

		var modelWrapper = E('div', { 'class': 'myos-card model-canvas' }, [
			E('div', { 'style': 'position: absolute; top: 22px; left: 24px; text-align: left; z-index: 5;' }, [
				E('div', { 'id': 'cpe_title_status', 'style': 'font-size: 20px; font-weight: 700; margin-bottom: 4px;' }, 
					(st.f50Online && st.f50HasIP) ? '蜂窝 5G 聚合网络已连接' : '蜂窝网络重连中 / 未就绪'),
				E('div', { 'style': 'font-size: 13px; opacity: 0.75;' }, 'Cudy TR3000 (哑光蓝双天线) + 中兴 F50 5G 便携联动')
			]),
			E('div', { 'id': 'cpe_wave_1', 'class': 'wave-base' }),
			E('div', { 'id': 'cpe_wave_2', 'class': 'wave-base wave-base-2' }),
			(function() {
				var div = E('div', { 'style': 'position: relative; z-index: 2; background: transparent !important;' });
				div.innerHTML = deviceSvg;
				return div;
			})(),
			E('div', { 'style': 'margin-top: 8px; z-index: 3; background: transparent !important;' }, [
				E('span', { 'id': 'cpe_pill_box', 'class': 'status-pill ' + (st.f50Online ? 'pill-online' : 'pill-offline') }, [
					E('span', { 'id': 'cpe_pill_dot', 'style': 'margin-right: 6px; font-size: 14px;' }, st.f50Online ? '●' : '○'),
					E('span', { 'id': 'cpe_pill_text' }, st.f50Online ? ('5G 全双工透传 • MTU ' + st.realMtu + ' 优化') : 'F50 等待握手或看门狗介入')
				])
			])
		]);

		var rightGrid = E('div', { 'class': 'stat-grid-right' }, [
			E('div', { 'class': 'myos-card', 'style': 'padding: 16px 20px; display: flex; justify-content: space-between; align-items: center;' }, [
				E('div', {}, [
					E('div', { 'style': 'font-size: 15px; font-weight: 600;' }, 'Wi-Fi 6 双频无线'),
					E('div', { 'id': 'cpe_wifi_desc', 'style': 'font-size: 12px; opacity: 0.7; margin-top: 2px;' }, 'AX3000 • 5G 频宽模式: ' + st.htMode5g)
				]),
				E('span', { 'id': 'cpe_wifi_pill', 'class': 'status-pill ' + (st.wifiUp ? 'pill-online' : 'pill-offline') }, st.wifiUp ? '运行中' : '已关闭')
			]),
			E('div', { 'class': 'myos-card', 'style': 'padding: 16px 20px; display: flex; justify-content: space-between; align-items: center;' }, [
				E('div', {}, [
					E('div', { 'style': 'font-size: 15px; font-weight: 600;' }, '已连接设备'),
					E('div', { 'style': 'font-size: 12px; opacity: 0.7; margin-top: 2px;' }, '当前局域网在线客户端 (5秒实时刷新)')
				]),
				E('div', { 'id': 'cpe_client_count', 'style': 'font-size: 22px; font-weight: 700; color: #c9933e;' }, st.clientCount + ' 台')
			]),
			E('div', { 'class': 'myos-card', 'style': 'padding: 18px 20px;' }, [
				E('div', { 'style': 'font-size: 15px; font-weight: 600; margin-bottom: 12px; display: flex; justify-content: space-between;' }, [
					E('span', {}, '5G 调制解调器 (ZTE F50)'),
					E('span', { 'id': 'cpe_f50_proto', 'style': 'font-size: 12px; color: #c9933e; font-weight: 500;' }, st.f50Online ? 'RNDIS / CDC-NCM 正常' : '未连接')
				]),
				E('div', { 'style': 'display: grid; grid-template-columns: 1fr 1fr; gap: 8px; font-size: 12px;' }, [
					E('div', { 'style': 'opacity: 0.7;' }, [ '设备节点: ', E('strong', { 'id': 'cpe_f50_dev' }, st.activeDevice) ]),
					E('div', { 'style': 'opacity: 0.7;' }, [ '当前 MTU: ', E('strong', { 'id': 'cpe_f50_mtu' }, st.realMtu) ]),
					E('div', { 'style': 'opacity: 0.7;' }, [ '保活巡检: ', E('strong', {}, '3分钟心跳自愈') ]),
					E('div', { 'style': 'opacity: 0.7;' }, [ '加速状态: ', E('strong', { 'id': 'cpe_f50_offload' }, st.offloadText) ])
				])
			]),
			E('div', { 'class': 'myos-card', 'style': 'padding: 18px 20px;' }, [
				E('div', { 'style': 'font-size: 15px; font-weight: 600; margin-bottom: 6px; display: flex; justify-content: space-between;' }, [
					E('span', {}, '主控硬件与实时负载'),
					E('span', { 'id': 'cpe_cpu_load', 'style': 'font-size: 12px; color: #c9933e; font-weight: 600;' }, '负载: ' + st.load1m)
				]),
				E('div', { 'id': 'cpe_uptime', 'style': 'font-size: 12px; opacity: 0.8;' }, 'MT7981B 双核 1.3GHz • 已运行: ' + st.uptimeStr)
			])
		]);

		var bottomStorageCard = E('div', { 'class': 'myos-card', 'style': 'margin-top: 4px;' }, [
			E('div', { 'style': 'display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px;' }, [
				E('div', {}, [
					E('strong', { 'style': 'font-size: 15px;' }, '内存与 512MB 闪存空间'),
					E('span', { 'style': 'font-size: 12px; opacity: 0.7; margin-left: 10px;' }, '512MB DDR3 • 512MB SPI-NAND (mod-490)')
				]),
				E('div', { 'id': 'cpe_mem_pct', 'style': 'font-size: 14px; font-weight: 600; color: #c9933e;' }, st.memPercent + '% 内存占用')
			]),
			E('div', { 'width': '100%', 'height': '10px', 'style': 'width: 100%; height: 10px; background: rgba(0,0,0,0.06); border-radius: 6px; overflow: hidden; display: flex; margin-bottom: 8px;' }, [
				E('div', { 'id': 'cpe_mem_bar', 'style': 'width: ' + st.memPercent + '%; background: linear-gradient(90deg, #c9933e, #f1c40f); height: 100%; border-radius: 6px; transition: width 0.4s ease;' })
			]),
			E('div', { 'style': 'display: flex; justify-content: space-between; font-size: 12px; opacity: 0.75;' }, [
				E('span', { 'id': 'cpe_mem_detail' }, 'RAM 真实负载: ' + st.usedMem + ' MB / ' + st.totalMem + ' MB'),
				E('span', {}, [ 'RootFS Overlay 真实空间: ', E('strong', { 'id': 'cpe_overlay_detail', 'style': 'color: #27ae60;' }, st.overlayText) ])
			])
		]);

		poll.add(function() {
			return fetchDashboardData().then(function(newData) {
				var s = parseDashboardData(newData);
				var setTxt = function(id, val) { var el = document.getElementById(id); if (el) el.innerText = val; };

				setTxt('cpe_title_status', (s.f50Online && s.f50HasIP) ? '蜂窝 5G 聚合网络已连接' : '蜂窝网络重连中 / 未就绪');
				setTxt('cpe_pill_dot', s.f50Online ? '●' : '○');
				setTxt('cpe_pill_text', s.f50Online ? ('5G 全双工透传 • MTU ' + s.realMtu + ' 优化') : 'F50 等待握手或看门狗介入');
				setTxt('cpe_wifi_desc', 'AX3000 • 5G 频宽模式: ' + s.htMode5g);
				setTxt('cpe_wifi_pill', s.wifiUp ? '运行中' : '已关闭');
				setTxt('cpe_client_count', s.clientCount + ' 台');
				setTxt('cpe_f50_proto', s.f50Online ? 'RNDIS / CDC-NCM 正常' : '未连接');
				setTxt('cpe_f50_dev', s.activeDevice);
				setTxt('cpe_f50_mtu', s.realMtu);
				setTxt('cpe_f50_offload', s.offloadText);
				setTxt('cpe_cpu_load', '负载: ' + s.load1m);
				setTxt('cpe_uptime', 'MT7981B 双核 1.3GHz • 已运行: ' + s.uptimeStr);
				setTxt('cpe_mem_pct', s.memPercent + '% 内存占用');
				setTxt('cpe_mem_detail', 'RAM 真实负载: ' + s.usedMem + ' MB / ' + s.totalMem + ' MB');
				setTxt('cpe_overlay_detail', s.overlayText);

				var pillBox = document.getElementById('cpe_pill_box');
				if (pillBox) pillBox.className = 'status-pill ' + (s.f50Online ? 'pill-online' : 'pill-offline');

				var wifiPill = document.getElementById('cpe_wifi_pill');
				if (wifiPill) wifiPill.className = 'status-pill ' + (s.wifiUp ? 'pill-online' : 'pill-offline');

				var memBar = document.getElementById('cpe_mem_bar');
				if (memBar) memBar.style.width = s.memPercent + '%';

				var waveColor = s.f50Online ? 'rgba(41, 128, 185, 0.45)' : 'rgba(160, 160, 160, 0.3)';
				var w1 = document.getElementById('cpe_wave_1');
				var w2 = document.getElementById('cpe_wave_2');
				if (w1) w1.style.borderColor = waveColor;
				if (w2) w2.style.borderColor = waveColor;

				var ledTr = document.getElementById('cpe_led_tr');
				if (ledTr) ledTr.setAttribute('fill', s.f50Online ? '#00e676' : '#ffab00');
				var ledW1 = document.getElementById('cpe_led_wifi1');
				if (ledW1) ledW1.setAttribute('fill', s.wifiUp ? '#00e676' : '#ff5252');
				var ledW2 = document.getElementById('cpe_led_wifi2');
				if (ledW2) ledW2.setAttribute('fill', s.wifiUp ? '#00e676' : '#ff5252');
				var ledF501 = document.getElementById('cpe_led_f50_1');
				if (ledF501) ledF501.setAttribute('fill', s.f50Online ? '#00e676' : '#ff5252');
				var ledF502 = document.getElementById('cpe_led_f50_2');
				if (ledF502) ledF502.setAttribute('fill', s.f50Online ? '#00e676' : '#999');
			});
		}, 5);

		return E('div', { 'class': 'cbi-map' }, [
			styleNode,
			E('div', { 'class': 'myos-dashboard' }, [
				modelWrapper,
				rightGrid
			]),
			bottomStorageCard
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
EOF

# 4. 注册菜单 (order 设为 0 并接管 admin/status 首位跳转，实现登录直达 CPE 总览) 与 RPCD 权限
mkdir -p package/base-files/files/usr/share/luci/menu.d || true
cat << 'EOF' > package/base-files/files/usr/share/luci/menu.d/luci-app-cpe-overview.json
{
	"admin/status": {
		"order": 10,
		"action": {
			"type": "firstchild"
		}
	},
	"admin/status/cpe_dashboard": {
		"title": "CPE 总览",
		"order": 0,
		"action": {
			"type": "view",
			"path": "status/cpe_dashboard"
		},
		"depends": {
			"acl": [ "luci-app-cpe-overview" ]
		}
	}
}
EOF

mkdir -p package/base-files/files/usr/share/rpcd/acl.d || true
cat << 'EOF' > package/base-files/files/usr/share/rpcd/acl.d/luci-app-cpe-overview.json
{
	"luci-app-cpe-overview": {
		"description": "Grant access to CPE Dashboard procedures",
		"read": {
			"ubus": {
				"system": [ "info" ],
				"network.interface": [ "dump" ]
			},
			"uci": [ "network", "firewall", "wireless" ],
			"file": {
				"/proc/net/arp": [ "read" ],
				"/bin/df": [ "exec" ]
			}
		}
	}
}
EOF

# 5. 开机预置：安全激活 Argon 主题(防 FALLBACK) + 锁定中文 + 开启 MTK PPE 硬件加速与 5G 160MHz
mkdir -p package/base-files/files/etc/uci-defaults || true
cat << 'EOF' > package/base-files/files/etc/uci-defaults/99-cpe-theme-init
uci set luci.main.lang='zh_cn'

if [ -d "/www/luci-static/argon" ]; then
    uci set luci.themes.Argon='/luci-static/argon'
    uci set luci.main.mediaurlbase='/luci-static/argon'
else
    uci set luci.main.mediaurlbase='/luci-static/bootstrap'
fi
uci commit luci

if uci -q get argon.@global[0] >/dev/null; then
    uci set argon.@global[0].primary='#c9933e'
    uci set argon.@global[0].dark_primary='#c9933e'
    uci set argon.@global[0].mode='normal'
    uci commit argon
fi

uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@defaults[0].flow_offloading_hw='1'
uci commit firewall

for r in radio0 radio1; do
    BAND=$(uci -q get wireless.$r.band)
    if [ "$BAND" = "5g" ]; then
        uci set wireless.$r.htmode='HE160'
        uci set wireless.$r.country='CN'
        uci set wireless.$r.disabled='0'
    elif [ "$BAND" = "2g" ]; then
        uci set wireless.$r.htmode='HE40'
        uci set wireless.$r.country='CN'
        uci set wireless.$r.disabled='0'
    fi
done
uci commit wireless

for CSS_TARGET in /www/luci-static/argon/css/cascade.css /www/luci-static/bootstrap/cascade.css; do
    if [ -f "$CSS_TARGET" ] && ! grep -Fq "cpe_myos_override.css" "$CSS_TARGET"; then
        echo '@import url("/luci-static/resources/cpe_myos_override.css");' | cat - "$CSS_TARGET" > /tmp/cascade.tmp && mv /tmp/cascade.tmp "$CSS_TARGET"
    fi
done

/etc/init.d/rpcd restart 2>/dev/null || true
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/ 2>/dev/null || true
exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/99-cpe-theme-init || true

# ==============================================================================
# 15. 强制兜底锁死 Argon 主题、中文包及核心功能模块 (防 .config 路径遗漏)
# ==============================================================================
cat << 'EOF' >> .config
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-base=y
CONFIG_PACKAGE_luci-compat=y
CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
CONFIG_PACKAGE_luci-theme-argon=y
CONFIG_PACKAGE_luci-app-argon-config=y
CONFIG_PACKAGE_luci-i18n-argon-config-zh-cn=y
CONFIG_PACKAGE_luci-app-turboacc=y
CONFIG_PACKAGE_luci-i18n-turboacc-zh-cn=y
CONFIG_PACKAGE_TURBOACC_INCLUDE_OFFLOADING=y
CONFIG_PACKAGE_luci-app-ttyd=y
CONFIG_PACKAGE_luci-i18n-ttyd-zh-cn=y
CONFIG_PACKAGE_luci-app-diskman=y
CONFIG_PACKAGE_luci-i18n-diskman-zh-cn=y
CONFIG_PACKAGE_kmod-usb-net=y
CONFIG_PACKAGE_kmod-usb-net-rndis=y
CONFIG_PACKAGE_kmod-usb-net-cdc-ether=y
CONFIG_PACKAGE_kmod-usb-net-cdc-ncm=y
CONFIG_PACKAGE_kmod-tun=y
CONFIG_PACKAGE_kmod-nft-tproxy=y
CONFIG_PACKAGE_kmod-nft-socket=y
CONFIG_PACKAGE_kmod-nft-queue=y
CONFIG_PACKAGE_kmod-nft-nat=y
CONFIG_PACKAGE_kmod-veth=y
CONFIG_PACKAGE_ip-full=y
CONFIG_PACKAGE_ca-bundle=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_jq=y
CONFIG_PACKAGE_usb-modeswitch=y
EOF

exit 0
