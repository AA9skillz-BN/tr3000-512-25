#!/bin/bash
# Description: OpenWrt DIY script part 2 (After Update feeds)

# 1. 修改默认后台 IP 为 192.168.6.1
sed -i 's/192.168.1.1/192.168.6.1/g' package/base-files/files/bin/config_generate || true

# 2. 部署 512MB 专属设备树 (DTS)
DTS_SRC="$GITHUB_WORKSPACE/openwrt-mod/mt7981b-cudy-tr3000-512mb-v1.dts"
if [ -f "$DTS_SRC" ]; then
    mkdir -p target/linux/mediatek/dts || true
    cp -f "$DTS_SRC" target/linux/mediatek/dts/mt7981b-cudy-tr3000-512mb-v1.dts
fi

# 3. 注入 512MB 机型定义 (IMAGE_SIZE 采用 502272k 避开 Python 整数解析异常)
FILOGIC_MK="target/linux/mediatek/image/filogic.mk"
if [ -f "$FILOGIC_MK" ]; then
    HAS_DEV=$(grep -c "cudy_tr3000-512mb-v1" "$FILOGIC_MK" || true)
    if [ "$HAS_DEV" -eq 0 ]; then
        echo "Injecting cudy_tr3000-512mb-v1 definition into $FILOGIC_MK"
        cat << 'EOF' >> "$FILOGIC_MK"

define Device/cudy_tr3000-512mb-v1
  DEVICE_VENDOR := Cudy
  DEVICE_MODEL := TR3000
  DEVICE_VARIANT := 512mb v1
  DEVICE_DTS := mt7981b-cudy-tr3000-512mb-v1
  DEVICE_DTS_DIR := ../dts
  SUPPORTED_DEVICES += R47 cudy,tr3000-v1
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 502272k
  KERNEL_IN_UBI := 1
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7981-firmware mt7981-wo-firmware
endef
TARGET_DEVICES += cudy_tr3000-512mb-v1
EOF
    fi
fi

# 4. 在线升级核心脚本 (加入直连失败自动切国内加速镜像、sha256 校验、OOM 防护)
mkdir -p package/base-files/files/usr/bin || true
cat << 'EOF' > package/base-files/files/usr/bin/auto-update-firmware.sh
#!/bin/sh

REPO="AA9skillz-BN/tr3000-512-25"
LOG_FILE="/tmp/firmware_update.log"
TMP_BIN="/tmp/firmware_upgrade.bin"
TMP_SHA="/tmp/sha256sums"

# 国内高可用备选镜像代理前缀
PROXIES="https://ghfast.top/ https://ghproxy.net/"

> "$LOG_FILE"

log() {
    echo "$@" >> "$LOG_FILE"
}

log "=========================================="
log "目标仓库: https://github.com/$REPO"
log "正在检测网络并连接 GitHub API..."
log "=========================================="

API_URL="https://api.github.com/repos/$REPO/releases/latest"
RELEASE_JSON=$(curl -sL -m 15 -H "User-Agent: Cudy-TR3000-OTA" "$API_URL")

# API 直连失败时，尝试走加速节点拉取元数据
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

# 内存预防性清理，释放缓冲区防止 OOM
sync
echo 3 > /proc/sys/vm/drop_caches
rm -f "$TMP_BIN" "$TMP_SHA"

# 下载文件函数 (直连失败自动切国内加速镜像)
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

# 1. 下载哈希清单
if [ -n "$SHA_URL" ]; then
    download_file "$SHA_URL" "$TMP_SHA" "校验清单 (sha256sums)"
fi

# 2. 下载系统固件
download_file "$DOWNLOAD_URL" "$TMP_BIN" "系统固件镜像 (请勿断电)"
if [ $? -ne 0 ] || [ ! -s "$TMP_BIN" ]; then
    log "❌ 固件下载失败，直连及所有加速通道均不可达，请检查网络！"
    rm -f "$TMP_BIN" "$TMP_SHA"
    exit 1
fi

BIN_SIZE=$(ls -lh "$TMP_BIN" | awk '{print $5}')
log "✔ 固件下载成功，文件大小: $BIN_SIZE"
echo "" >> "$LOG_FILE"

# 3. SHA256 强校验
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

# 4. OpenWrt 原生元数据验证
log "正在执行固件元数据合规检查..."
if command -v fwtool >/dev/null 2>&1; then
    if ! fwtool -q -i /dev/null "$TMP_BIN" 2>/dev/null; then
        log "❌ 固件 Header 校验不通过，非合法 OpenWrt 固件！已终止。"
        rm -f "$TMP_BIN" "$TMP_SHA"
        exit 1
    fi
fi

log "✔ 安全校验通过！系统即将在 3 秒后执行写入并重启..."
log "提示: 刷入过程中切勿断电，完成后访问 192.168.6.1"
log "=========================================="

# 杀掉大内存后台服务保障写入稳定性
/etc/init.d/openclash stop 2>/dev/null || true
sync
echo 3 > /proc/sys/vm/drop_caches

# 后台解耦执行刷机
( sleep 3 && sysupgrade "$TMP_BIN" ) >/dev/null 2>&1 &
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
				"/usr/bin/auto-update-firmware.sh": [ "exec" ]
			}
		}
	}
}
EOF

# 7. 部署 LuCI 视图 (现代化动效升级控制台)
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
		var logText = data[0] || '等待操作：点击下方按钮开始检查并同步最新构建...';

		var styleNode = E('style', {}, [
			'@keyframes pulse-bar { 0% { background-position: 0% 50%; } 50% { background-position: 100% 50%; } 100% { background-position: 0% 50%; } }',
			'@keyframes blink-dot { 0%, 100% { opacity: 1; transform: scale(1); } 50% { opacity: 0.4; transform: scale(0.85); } }',
			'.ota-progress-container { width: 100%; background: #222; border-radius: 8px; height: 12px; overflow: hidden; margin: 15px 0; display: none; border: 1px solid #444; }',
			'.ota-progress-bar { width: 100%; height: 100%; background: linear-gradient(90deg, #00c6ff, #0072ff, #00ff87, #60efff); background-size: 300% 300%; animation: pulse-bar 2s ease infinite; }',
			'.ota-badge { display: inline-flex; align-items: center; padding: 4px 10px; border-radius: 20px; font-size: 12px; margin-right: 10px; background: #2a2a2a; border: 1px solid #444; }',
			'.ota-dot { width: 8px; height: 8px; border-radius: 50%; margin-right: 6px; }',
			'.ota-dot.active { animation: blink-dot 1s infinite; }',
			'.dot-idle { background: #888; }',
			'.dot-down { background: #00b4d8; }',
			'.dot-check { background: #ffb703; }',
			'.dot-flash { background: #ef233c; }'
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

		var viewDOM = E('div', { 'class': 'cbi-map' }, [
			styleNode,
			E('h2', {}, _('在线固件升级')),
			E('div', { 'class': 'cbi-map-descr' }, _('一键拉取 AA9skillz-BN/tr3000-512-25 仓库最新 Release 固件，支持国内镜像智能故障转移，保留配置无感升级。')),

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
					E('div', { 'style': 'margin-bottom: 15px;' }, [
						E('button', {
							'id': 'btn_start_update',
							'class': 'cbi-button cbi-button-action important',
							'click': function(ev) {
								ev.target.disabled = true;
								document.getElementById('ota_progress').style.display = 'block';
								
								var dot = document.getElementById('dot_status');
								var txt = document.getElementById('text_status');
								dot.className = 'ota-dot dot-down active';
								txt.innerText = '正在连接云端并拉取固件...';

								ui.showModal(_('正在处理'), [
									E('p', { 'class': 'spinning' }, _('OTA 升级程序已启动，请关注下方动态进度条与实时输出...'))
								]);
								setTimeout(function() { ui.hideModal(); }, 2000);

								fs.exec('/usr/bin/auto-update-firmware.sh');

								var poll = window.setInterval(function() {
									fs.read_direct('/tmp/firmware_update.log').then(function(res) {
										var logArea = document.getElementById('update_log_area');
										if (logArea && res) {
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

# 8. 预置中兴 F50 免驱支持与 MTU 1420 蜂窝网优化
mkdir -p package/base-files/files/etc/uci-defaults || true
cat << 'EOF' > package/base-files/files/etc/uci-defaults/99-f50-hotplug
uci set network.f50=interface
uci set network.f50.proto='dhcp'
uci set network.f50.device='eth2'
uci set network.f50.metric='20'
uci set network.f50.mtu='1420'
uci commit network

for i in $(seq 0 10); do
    ZNAME=$(uci -q get firewall.@zone[$i].name)
    if [ "$ZNAME" = "wan" ]; then
        uci add_list firewall.@zone[$i].network='f50'
        uci commit firewall
        break
    fi
done

exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/99-f50-hotplug || true

# 9. 部署 USB 动态热插拔规则（引入 2 秒 Link-Up 缓冲，防止 DHCP 超时丢包）
mkdir -p package/base-files/files/etc/hotplug.d/net || true
cat << 'EOF' > package/base-files/files/etc/hotplug.d/net/99-f50-auto
case "$ACTION" in
    add)
        if [ "$INTERFACE" = "usb0" ] || [ "$INTERFACE" = "eth2" ]; then
            CURRENT_DEV=$(uci -q get network.f50.device)
            if [ "$CURRENT_DEV" != "$INTERFACE" ]; then
                uci set network.f50.device="$INTERFACE"
                uci commit network
                /etc/init.d/network reload
            fi
            ( sleep 2 && ifup f50 ) &
        fi
        ;;
esac
EOF
chmod +x package/base-files/files/etc/hotplug.d/net/99-f50-auto || true

# 10. 声明配置备份白名单（升级时不丢失 OTA 脚本、看门狗与核心配置）
mkdir -p package/base-files/files/etc/sysupgrade.conf || true
cat << 'EOF' >> package/base-files/files/etc/sysupgrade.conf
/etc/openclash/
/usr/bin/auto-update-firmware.sh
/usr/bin/f50-watchdog.sh
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

# 检查 f50 接口是否存在且已启动
if ! ip link show f50 >/dev/null 2>&1 && ! ip link show eth2 >/dev/null 2>&1 && ! ip link show usb0 >/dev/null 2>&1; then
    exit 0
fi

# 连续检测 3 次，超时 2 秒
if ! ping -c 3 -W 2 -I f50 $TARGET_IP >/dev/null 2>&1; then
    logger -t "$LOG_TAG" "检测到 F50 网络失联，正在尝试重新协商 DHCP 与拉起接口..."
    ifdown f50
    sleep 2
    ifup f50
    
    # 二次检测，若仍不通则尝试重载网络子系统
    sleep 8
    if ! ping -c 2 -W 2 -I f50 $TARGET_IP >/dev/null 2>&1; then
        logger -t "$LOG_TAG" "网络仍未恢复，执行网络协议栈重载..."
        /etc/init.d/network restart
    fi
fi
exit 0
EOF
chmod +x package/base-files/files/usr/bin/f50-watchdog.sh || true

# 13. 开机预置看门狗计划任务 (每 3 分钟自动执行一次)
cat << 'EOF' > package/base-files/files/etc/uci-defaults/99-f50-watchdog-cron
CRON_JOB="*/3 * * * * /usr/bin/f50-watchdog.sh >/dev/null 2>&1"
( crontab -l 2>/dev/null | grep -v "f50-watchdog.sh"; echo "$CRON_JOB" ) | crontab -
/etc/init.d/cron enable
/etc/init.d/cron restart
exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/99-f50-watchdog-cron || true

exit 0