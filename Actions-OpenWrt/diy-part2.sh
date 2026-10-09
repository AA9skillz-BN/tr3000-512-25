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

# 4. 在线升级核心脚本 (加入 sha256 校验、OOM 防护、User-Agent 与后台解耦)
mkdir -p package/base-files/files/usr/bin || true
cat << 'EOF' > package/base-files/files/usr/bin/auto-update-firmware.sh
#!/bin/sh

REPO="AA9skillz-BN/tr3000-512-25"
LOG_FILE="/tmp/firmware_update.log"
TMP_BIN="/tmp/firmware_upgrade.bin"
TMP_SHA="/tmp/sha256sums"

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

DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o 'https://[^" ]*cudy_tr3000-512mb-v1[^" ]*sysupgrade\.bin' | head -n 1)
if [ -z "$DOWNLOAD_URL" ]; then
    DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o 'https://[^" ]*sysupgrade\.bin' | head -n 1)
fi

SHA_URL=$(echo "$RELEASE_JSON" | grep -o 'https://[^" ]*sha256sums' | head -n 1)
TAG_NAME=$(echo "$RELEASE_JSON" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | cut -d'"' -f4)

if [ -z "$DOWNLOAD_URL" ]; then
    log "❌ 检查失败: 未能在最新 Release 中找到匹配的固件！"
    log "API 响应概况: $(echo "$RELEASE_JSON" | head -n 2)"
    exit 1
fi

log "✔ 发现可用版本: ${TAG_NAME:-最新发布}"
log "固件地址: $DOWNLOAD_URL"
echo "" >> "$LOG_FILE"

# 清理内存缓存，防止下载大文件时 OOM
sync
echo 3 > /proc/sys/vm/drop_caches
rm -f "$TMP_BIN" "$TMP_SHA"

log "正在下载校验清单 (sha256sums)..."
if [ -n "$SHA_URL" ]; then
    curl -sL -m 10 -H "User-Agent: Cudy-TR3000-OTA" -o "$TMP_SHA" "$SHA_URL"
fi

log "正在下载系统固件 (请勿断电)..."
curl -L -k --progress-bar -o "$TMP_BIN" "$DOWNLOAD_URL" 2>> "$LOG_FILE"

if [ $? -ne 0 ] || [ ! -s "$TMP_BIN" ]; then
    log "❌ 固件下载失败，请检查路由器网络连接！"
    rm -f "$TMP_BIN" "$TMP_SHA"
    exit 1
fi

BIN_SIZE=$(ls -lh "$TMP_BIN" | awk '{print $5}')
log "✔ 固件下载完成，大小: $BIN_SIZE"
echo "" >> "$LOG_FILE"

# SHA256 强校验
if [ -s "$TMP_SHA" ]; then
    log "正在进行 SHA256 完整性比对..."
    BIN_NAME=$(basename "$DOWNLOAD_URL")
    EXPECTED_HASH=$(grep "$BIN_NAME" "$TMP_SHA" | awk '{print $1}')
    if [ -n "$EXPECTED_HASH" ]; then
        ACTUAL_HASH=$(sha256sum "$TMP_BIN" | awk '{print $1}')
        if [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]; then
            log "❌ 校验失败: 固件哈希不匹配，可能下载已损坏或被截断！"
            log "期望: $EXPECTED_HASH"
            log "实际: $ACTUAL_HASH"
            rm -f "$TMP_BIN" "$TMP_SHA"
            exit 1
        fi
        log "✔ SHA256 校验一致 ($ACTUAL_HASH)"
    else
        log "⚠ 校验清单中未找到对应文件名，跳过哈希硬比对"
    fi
fi

# 使用 OpenWrt 原生元数据工具验证固件架构
log "正在执行固件元数据合规检查..."
if command -v fwtool >/dev/null 2>&1; then
    if ! fwtool -q -i /dev/null "$TMP_BIN" 2>/dev/null; then
        log "❌ 固件 Header 校验不通过，非合法 OpenWrt 固件！已终止。"
        rm -f "$TMP_BIN" "$TMP_SHA"
        exit 1
    fi
fi

log "✔ 安全校验通过！系统即将在 3 秒后执行写入并重启..."
log "提示: 升级过程中千万不要断电，完成后访问 192.168.6.1"
log "=========================================="

# 杀掉大内存后台应用确保刷机时内存充足
/etc/init.d/openclash stop 2>/dev/null || true
sync
echo 3 > /proc/sys/vm/drop_caches

# 脱离当前调用进程并在后台执行刷机
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

# 7. 部署 LuCI 视图 (JavaScript 现代化客户端页面)
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
		var logText = data[0] || '点击下方按钮，开始检查并拉取仓库最新发布的 25.x 固件...';

		var viewDOM = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('在线固件升级')),
			E('div', { 'class': 'cbi-map-descr' }, _('一键拉取 AA9skillz-BN/tr3000-512-25 仓库最新 Release 固件，自动进行安全校验并保留配置升级。')),

			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('目标机型')),
						E('div', { 'class': 'cbi-value-field' }, E('strong', {}, 'Cudy TR3000 (512MB Flash / mod-490)'))
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('升级来源')),
						E('div', { 'class': 'cbi-value-field' }, 'GitHub: AA9skillz-BN/tr3000-512-25 (Releases)')
					])
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('操作面板')),
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'style': 'margin-bottom: 15px;' }, [
						E('button', {
							'class': 'cbi-button cbi-button-action important',
							'click': function(ev) {
								ev.target.disabled = true;
								ui.showModal(_('正在处理'), [
									E('p', { 'class': 'spinning' }, _('已启动在线升级进程，请观察下方控制台输出...'))
								]);
								setTimeout(function() { ui.hideModal(); }, 2500);

								fs.exec('/usr/bin/auto-update-firmware.sh').then(function() {
									ev.target.disabled = false;
								});

								var poll = window.setInterval(function() {
									fs.read_direct('/tmp/firmware_update.log').then(function(res) {
										var logArea = document.getElementById('update_log_area');
										if (logArea && res) {
											logArea.value = res;
											logArea.scrollTop = logArea.scrollHeight;
										}
									});
								}, 1500);
							}
						}, _('⚡ 立即检查并拉取最新固件升级'))
					]),
					E('textarea', {
						'id': 'update_log_area',
						'class': 'cbi-input-textarea',
						'style': 'width: 100%; height: 260px; font-family: monospace; background: #181818; color: #00ff66; padding: 10px; border-radius: 6px; border: 1px solid #333;',
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

# 8. 预置中兴 F50 免驱支持（精准查找 wan 区域名称，不依赖写死下标）
mkdir -p package/base-files/files/etc/uci-defaults || true
cat << 'EOF' > package/base-files/files/etc/uci-defaults/99-f50-hotplug
uci set network.f50=interface
uci set network.f50.proto='dhcp'
uci set network.f50.device='eth2'
uci set network.f50.metric='20'
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

# 10. 声明配置备份白名单（升级时不丢失 OTA 脚本与核心配置）
mkdir -p package/base-files/files/etc/sysupgrade.conf || true
cat << 'EOF' >> package/base-files/files/etc/sysupgrade.conf
/etc/openclash/
/usr/bin/auto-update-firmware.sh
EOF

# 11. 改进项 3: 系统时区与高可用国内 NTP 校准（解决无 RTC 硬件时钟偏差与 TLS 证书死锁）
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

exit 0