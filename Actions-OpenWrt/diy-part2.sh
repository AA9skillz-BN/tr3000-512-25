#!/bin/bash
# Description: OpenWrt DIY script part 2 (After Update feeds)

# 1. 修改默认后台 IP 为 192.168.6.1
sed -i 's/192.168.1.1/192.168.6.1/g' package/base-files/files/bin/config_generate || true

# 2. 复制 512MB 专属设备树 (DTS) 到内核 dts 目录
DTS_SRC="$GITHUB_WORKSPACE/openwrt-mod/mt7981b-cudy-tr3000-512mb-v1.dts"
if [ -f "$DTS_SRC" ]; then
    mkdir -p target/linux/mediatek/dts || true
    cp -f "$DTS_SRC" target/linux/mediatek/dts/ || true
fi

# 3. 精准注入对齐原参考仓库的机型定义 (防御性判断防止 set -e 退出)
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
  IMAGE_SIZE := 490M
  KERNEL_IN_UBI := 1
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7981-firmware mt7981-wo-firmware
endef
TARGET_DEVICES += cudy_tr3000-512mb-v1
EOF
    fi
fi

# =========================================================
# 4. 注入【固件升级】独立顶级菜单与在线升级脚本
# =========================================================

# A. 升级脚本
mkdir -p package/base-files/files/usr/bin || true
cat << 'EOF' > package/base-files/files/usr/bin/auto-update-firmware.sh
#!/bin/sh

REPO="AA9skillz-BN/tr3000-512-25"
LOG_FILE="/tmp/firmware_update.log"

exec > "$LOG_FILE" 2>&1

echo "=========================================="
echo "目标仓库: https://github.com/$REPO"
echo "正在检测网络并连接 GitHub API..."
echo "=========================================="

API_URL="https://api.github.com/repos/$REPO/releases/latest"
RELEASE_JSON=$(curl -sL "$API_URL")

DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o 'https://[^" ]*cudy_tr3000-512mb-v1[^" ]*sysupgrade\.bin' | head -n 1)
if [ -z "$DOWNLOAD_URL" ]; then
    DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o 'https://[^" ]*sysupgrade\.bin' | head -n 1)
fi

TAG_NAME=$(echo "$RELEASE_JSON" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | cut -d'"' -f4)

if [ -z "$DOWNLOAD_URL" ]; then
    echo "❌ 检查失败: 未能在最新 Release 中找到匹配的固件！"
    exit 1
fi

echo "✔ 发现最新可用版本: ${TAG_NAME:-最新发布}"
echo "下载链接: $DOWNLOAD_URL"
echo ""

TMP_FILE="/tmp/firmware_upgrade.bin"
rm -f "$TMP_FILE"

echo "正在下载固件至内存缓存区 (请勿断电)..."
curl -L -k -o "$TMP_FILE" "$DOWNLOAD_URL"

if [ $? -ne 0 ] || [ ! -s "$TMP_FILE" ]; then
    echo "❌ 固件下载失败，请检查路由器网络连接！"
    rm -f "$TMP_FILE"
    exit 1
fi

echo "✔ 固件下载完成，大小: $(ls -lh $TMP_FILE | awk '{print $5}')"
echo ""

echo "正在执行固件安全校验..."
if ! sysupgrade -t "$TMP_FILE"; then
    echo "❌ 固件校验不通过！可能文件损坏或型号不匹配，已终止升级以防止变砖。"
    rm -f "$TMP_FILE"
    exit 1
fi

echo "✔ 校验成功！将在 3 秒后执行自动刷机并重启..."
echo "升级完成后管理地址仍为: 192.168.6.1。"
echo "=========================================="

sleep 3
sysupgrade "$TMP_FILE"
EOF
chmod +x package/base-files/files/usr/bin/auto-update-firmware.sh || true

# B. 注册独立顶级菜单
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

# C. 权限控制 ACL
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

# D. 交互前端 View
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
			E('div', { 'class': 'cbi-map-descr' }, _('一键拉取 AA9skillz-BN/tr3000-512-25 仓库最新 Release 固件，保留配置自动升级。')),

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
						'style': 'width: 100%; height: 240px; font-family: monospace; background: #181818; color: #00ff66; padding: 10px; border-radius: 6px; border: 1px solid #333;',
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

# =========================================================
# 5. 预置中兴 F50 专属即插即用接口 (锁定绑定至 eth2)
# =========================================================
mkdir -p package/base-files/files/etc/uci-defaults || true
cat << 'EOF' > package/base-files/files/etc/uci-defaults/99-f50-hotplug
uci set network.f50=interface
uci set network.f50.proto='dhcp'
uci set network.f50.device='eth2'
uci set network.f50.metric='20'
uci commit network

# 将 f50 接口加入防火墙 WAN 区域
uci add_list firewall.@zone[1].network='f50' 2>/dev/null || true
uci commit firewall
EOF
chmod +x package/base-files/files/etc/uci-defaults/99-f50-hotplug || true

exit 0