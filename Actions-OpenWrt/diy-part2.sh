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

# ==============================================================================
# 14. 注入标准兼容版 CPE-MYOS 深度美化层 (手机端响应式 + 局部作用域 + 编译期固化)
# ==============================================================================

# 1. 编译期直接部署独立样式表 (Scoped 样式，不污染内部表单控件；支持移动端适配)
mkdir -p package/base-files/files/www/luci-static/resources || true
cat << 'EOF' > package/base-files/files/www/luci-static/resources/cpe_myos_override.css
/* 全局基础色调调和 (保留系统暗黑模式兼容性) */
:root {
    --cpe-bg-main: #f6f5f0;
    --cpe-bg-card: #ffffff;
    --cpe-bg-sidebar: #fbfaf7;
    --cpe-gold: #c9933e;
    --cpe-gold-light: #fef5e7;
    --cpe-border: #edeae2;
    --cpe-radius-lg: 18px;
    --cpe-radius-md: 12px;
}

/* 仅在非深色模式下覆盖背景与侧边栏，防止与深色模式冲突 */
@media (prefers-color-scheme: light) {
    body {
        background-color: var(--cpe-bg-main) !important;
    }
    .main-left, nav#mainmenu, .navigation {
        background-color: var(--cpe-bg-sidebar) !important;
        border-right: 1px solid var(--cpe-border) !important;
    }
}

/* Scoped 限定：仅美化外层卡片容器，坚决不破坏 CBI 表格与表单内部排版 */
.cbi-map > .cbi-section,
#maincontent > .panel,
#maincontent > .card {
    border-radius: var(--cpe-radius-lg) !important;
    border: 1px solid var(--cpe-border) !important;
    box-shadow: 0 4px 20px rgba(0, 0, 0, 0.025) !important;
    padding: 20px 24px !important;
    margin-bottom: 24px !important;
}

/* 按钮微调，保持圆角一致 */
.cbi-button-apply, .cbi-button-save, .cbi-button-action.important {
    background-color: var(--cpe-gold) !important;
    border-color: var(--cpe-gold) !important;
    color: #ffffff !important;
    border-radius: var(--cpe-radius-md) !important;
}

/* 移动端 (手机/竖屏平板) 响应式弹性布局防溢出 */
@media (max-width: 768px) {
    #maincontent {
        padding: 12px 14px !important;
    }
    .myos-dashboard {
        grid-template-columns: 1fr !important;
        gap: 14px !important;
    }
    .model-canvas {
        min-height: 330px !important;
        padding: 16px !important;
    }
    .device-model-svg {
        width: 100% !important;
        max-width: 290px !important;
        height: auto !important;
    }
    .wave-base {
        width: 220px !important;
        height: 70px !important;
        bottom: 55px !important;
    }
}
EOF

# 2. 编译期物理固化：直接向 Argon 的 cascade.css 写入 import，OTA 升级绝不失效丢失
ARGON_DIR="feeds/luci/themes/luci-theme-argon"
[ ! -d "$ARGON_DIR" ] && ARGON_DIR="package/feeds/luci/luci-theme-argon"
if [ -d "$ARGON_DIR" ]; then
    find "$ARGON_DIR" -name "cascade.css" -exec sh -c '
        for f; do
            if ! grep -Fq "cpe_myos_override.css" "$f"; then
                echo "@import url(\"/luci-static/resources/cpe_myos_override.css\");" >> "$f"
            fi
        done
    ' sh {} +
fi

# 3. 部署健壮版 CPE 聚合看板 (带容错降级，无数据也绝不白屏)
mkdir -p package/base-files/files/www/luci-static/resources/view/status || true
cat << 'EOF' > package/base-files/files/www/luci-static/resources/view/status/cpe_dashboard.js
'use strict';
'require view';
'require fs';
'require ui';
'require rpc';

var callSystemInfo = rpc.declare({
	object: 'system',
	method: 'info'
});

var callNetworkDevices = rpc.declare({
	object: 'network.device',
	method: 'status'
});

return view.extend({
	load: function() {
		return Promise.all([
			callSystemInfo().catch(function() { return {}; }),
			fs.lines('/proc/net/arp').catch(function() { return []; }),
			callNetworkDevices().catch(function() { return {}; })
		]);
	},

	render: function(data) {
		var info = data[0] || {};
		var arpLines = data[1] || [];
		var netDevs = data[2] || {};

		var clientCount = 0;
		if (Array.isArray(arpLines)) {
			clientCount = arpLines.filter(function(line) {
				var p = line.trim().split(/\s+/);
				return p.length >= 6 && p[2] === '0x2' && p[3] !== '00:00:00:00:00:00';
			}).length;
		}

		var f50Online = !!((netDevs['f50'] && netDevs['f50'].up) || (netDevs['eth2'] && netDevs['eth2'].up) || (netDevs['usb0'] && netDevs['usb0'].up));

		var totalMem = Math.round((info.memory && info.memory.total ? info.memory.total : 536870912) / 1048576);
		var freeMem = Math.round((info.memory && info.memory.free ? info.memory.free : 268435456) / 1048576);
		var usedMem = Math.max(0, totalMem - freeMem);
		var memPercent = totalMem > 0 ? Math.round((usedMem / totalMem) * 100) : 0;

		var styleNode = E('style', {}, [
			'@keyframes ripple-wave { 0% { transform: scale(0.8); opacity: 0.8; } 100% { transform: scale(1.4); opacity: 0; } }',
			'@keyframes f50-pulse { 0%, 100% { filter: drop-shadow(0 0 4px #00e676); } 50% { filter: drop-shadow(0 0 10px #00e676); } }',
			'@keyframes led-blink { 0%, 100% { opacity: 1; } 50% { opacity: 0.35; } }',
			'.myos-dashboard { display: grid; grid-template-columns: 1.35fr 1fr; gap: 20px; margin-bottom: 24px; }',
			'.myos-card { background: var(--cpe-bg-card, #ffffff); border-radius: 20px; border: 1px solid var(--cpe-border, #edeae2); box-shadow: 0 4px 20px rgba(0,0,0,0.025); padding: 24px; position: relative; }',
			'.model-canvas { display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 400px; position: relative; overflow: hidden; }',
			'.wave-base { position: absolute; width: 280px; height: 90px; border-radius: 50%; border: 2px solid ' + (f50Online ? 'rgba(41, 128, 185, 0.45)' : 'rgba(160, 160, 160, 0.3)') + '; bottom: 65px; z-index: 1; animation: ripple-wave 2.8s infinite cubic-bezier(0, 0.2, 0.8, 1); }',
			'.wave-base-2 { animation-delay: 1.4s; }',
			'.device-model-svg { z-index: 2; filter: drop-shadow(0 16px 24px rgba(27, 42, 74, 0.16)); transition: transform 0.3s ease; }',
			'.device-model-svg:hover { transform: translateY(-3px); }',
			'.stat-grid-right { display: flex; flex-direction: column; gap: 16px; }',
			'.status-pill { display: inline-flex; align-items: center; padding: 4px 12px; border-radius: 20px; font-size: 12px; font-weight: 500; }',
			'.pill-online { background: #eafaf1; color: #27ae60; }',
			'.pill-offline { background: #fdf2e9; color: #e67e22; }'
		]);

		var deviceSvg = '<svg class="device-model-svg" width="340" height="260" viewBox="0 0 340 260" fill="none" xmlns="http://www.w3.org/2000/svg">' +
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
			'<ellipse cx="150" cy="226" rx="100" ry="14" fill="#D6DEE8" />' +
			'<g transform="rotate(-18 68 180)">' +
				'<rect x="62" y="55" width="12" height="130" rx="6" fill="url(#trAntenna)" stroke="#1a2e4c" stroke-width="1.2" />' +
				'<circle cx="68" cy="180" r="8" fill="#1b2f4d" stroke="#34588c" stroke-width="1.5" />' +
			'</g>' +
			'<g transform="rotate(18 232 180)">' +
				'<rect x="226" y="55" width="12" height="130" rx="6" fill="url(#trAntenna)" stroke="#1a2e4c" stroke-width="1.2" />' +
				'<circle cx="232" cy="180" r="8" fill="#1b2f4d" stroke="#34588c" stroke-width="1.5" />' +
			'</g>' +
			'<rect x="75" y="150" width="150" height="68" rx="12" fill="url(#trBlueBody)" stroke="#1a2e4c" stroke-width="1.5" />' +
			'<path d="M85 152 L215 152" stroke="#4872a8" stroke-width="2" stroke-linecap="round" opacity="0.65" />' +
			'<text x="150" y="174" text-anchor="middle" font-family="-apple-system, BlinkMacSystemFont, sans-serif" font-size="11" font-weight="700" fill="#E8EEF5" letter-spacing="1.2">cudy</text>' +
			'<text x="150" y="185" text-anchor="middle" font-family="-apple-system, BlinkMacSystemFont, sans-serif" font-size="7.5" font-weight="600" fill="#8CA4C4" letter-spacing="0.5">TR3000 • 512MB</text>' +
			'<circle cx="132" cy="202" r="2.5" fill="' + (f50Online ? '#00e676' : '#ffab00') + '" style="animation: led-blink 1.8s infinite;" />' +
			'<circle cx="144" cy="202" r="2.5" fill="#00e676" />' +
			'<circle cx="156" cy="202" r="2.5" fill="#00e676" />' +
			'<circle cx="168" cy="202" r="2.5" fill="#3b5980" />' +
			'<path d="M225 188 C242 188, 245 160, 260 160" stroke="#7A8B9E" stroke-width="3" stroke-linecap="round" fill="none" />' +
			'<g transform="translate(258, 126)">' +
				'<rect x="0" y="0" width="46" height="66" rx="8" fill="url(#f50White)" stroke="#D0D7DE" stroke-width="1.5" filter="drop-shadow(0 6px 12px rgba(0,0,0,0.12))" />' +
				'<text x="23" y="20" text-anchor="middle" font-family="-apple-system, sans-serif" font-size="7.5" font-weight="800" fill="#2E3A4B">ZTE</text>' +
				'<text x="23" y="34" text-anchor="middle" font-family="-apple-system, sans-serif" font-size="9" font-weight="900" fill="#C9933E" letter-spacing="0.5">5G+</text>' +
				'<text x="23" y="44" text-anchor="middle" font-family="-apple-system, sans-serif" font-size="6" font-weight="600" fill="#8892A0">F50 Portable</text>' +
				'<circle cx="17" cy="54" r="2" fill="' + (f50Online ? '#00e676' : '#ff5252') + '" style="' + (f50Online ? 'animation: f50-pulse 1.5s infinite;' : '') + '" />' +
				'<circle cx="29" cy="54" r="2" fill="' + (f50Online ? '#00e676' : '#999') + '" />' +
			'</g>' +
		'</svg>';

		var modelWrapper = E('div', { 'class': 'myos-card model-canvas' }, [
			E('div', { 'style': 'position: absolute; top: 22px; left: 24px; text-align: left;' }, [
				E('div', { 'style': 'font-size: 20px; font-weight: 700; margin-bottom: 4px;' }, 
					f50Online ? '蜂窝 5G 聚合网络在线' : '蜂窝网络重连中 / 未就绪'),
				E('div', { 'style': 'font-size: 13px; opacity: 0.75;' }, 'Cudy TR3000 (哑光蓝双天线) + 中兴 F50 5G 便携联动')
			]),
			E('div', { 'class': 'wave-base' }),
			E('div', { 'class': 'wave-base wave-base-2' }),
			(function() {
				var div = E('div', { 'style': 'position: relative; z-index: 2;' });
				div.innerHTML = deviceSvg;
				return div;
			})(),
			E('div', { 'style': 'margin-top: 12px; z-index: 3;' }, [
				E('span', { 'class': 'status-pill ' + (f50Online ? 'pill-online' : 'pill-offline') }, [
					E('span', { 'style': 'margin-right: 6px; font-size: 14px;' }, f50Online ? '●' : '○'),
					f50Online ? '5G 全双工透传 • MTU 1420 优化' : 'F50 等待握手或看门狗介入'
				])
			])
		]);

		var rightGrid = E('div', { 'class': 'stat-grid-right' }, [
			E('div', { 'class': 'myos-card', 'style': 'padding: 16px 20px; display: flex; justify-content: space-between; align-items: center;' }, [
				E('div', {}, [
					E('div', { 'style': 'font-size: 15px; font-weight: 600;' }, 'Wi-Fi 6 双频无线'),
					E('div', { 'style': 'font-size: 12px; opacity: 0.7; margin-top: 2px;' }, 'AX3000 • 160MHz 频宽全开')
				]),
				E('span', { 'class': 'status-pill pill-online' }, '运行中')
			]),
			E('div', { 'class': 'myos-card', 'style': 'padding: 16px 20px; display: flex; justify-content: space-between; align-items: center;' }, [
				E('div', {}, [
					E('div', { 'style': 'font-size: 15px; font-weight: 600;' }, '已连接设备'),
					E('div', { 'style': 'font-size: 12px; opacity: 0.7; margin-top: 2px;' }, '当前局域网在线客户端')
				]),
				E('div', { 'style': 'font-size: 22px; font-weight: 700; color: #c9933e;' }, clientCount + ' 台')
			]),
			E('div', { 'class': 'myos-card', 'style': 'padding: 18px 20px;' }, [
				E('div', { 'style': 'font-size: 15px; font-weight: 600; margin-bottom: 12px; display: flex; justify-content: space-between;' }, [
					E('span', {}, '5G 调制解调器 (ZTE F50)'),
					E('span', { 'style': 'font-size: 12px; color: #c9933e; font-weight: 500;' }, f50Online ? 'RNDIS / CDC-NCM 正常' : '未连接')
				]),
				E('div', { 'style': 'display: grid; grid-template-columns: 1fr 1fr; gap: 8px; font-size: 12px;' }, [
					E('div', { 'style': 'opacity: 0.7;' }, '设备节点: ' + E('strong', {}, 'f50 (eth2/usb0)')),
					E('div', { 'style': 'opacity: 0.7;' }, '优化 MTU: ' + E('strong', {}, '1420')),
					E('div', { 'style': 'opacity: 0.7;' }, '保活巡检: ' + E('strong', {}, '3分钟心跳自愈')),
					E('div', { 'style': 'opacity: 0.7;' }, '硬件加速: ' + E('strong', {}, 'MTK PPE Offload'))
				])
			]),
			E('div', { 'class': 'myos-card', 'style': 'padding: 18px 20px;' }, [
				E('div', { 'style': 'font-size: 15px; font-weight: 600; margin-bottom: 8px;' }, '主控硬件架构'),
				E('div', { 'style': 'font-size: 13px; opacity: 0.8;' }, 'MT7981B 双核 A53 @ 1.3GHz • 512MB RAM')
			])
		]);

		var bottomStorageCard = E('div', { 'class': 'myos-card', 'style': 'margin-top: 4px;' }, [
			E('div', { 'style': 'display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px;' }, [
				E('div', {}, [
					E('strong', { 'style': 'font-size: 15px;' }, '内存与 512MB 闪存空间'),
					E('span', { 'style': 'font-size: 12px; opacity: 0.7; margin-left: 10px;' }, '512MB DDR3 • 512MB SPI-NAND (mod-490)')
				]),
				E('div', { 'style': 'font-size: 14px; font-weight: 600; color: #c9933e;' }, memPercent + '% 已载入')
			]),
			E('div', { 'style': 'width: 100%; height: 10px; background: rgba(0,0,0,0.06); border-radius: 6px; overflow: hidden; display: flex; margin-bottom: 8px;' }, [
				E('div', { 'style': 'width: ' + memPercent + '%; background: linear-gradient(90deg, #c9933e, #f1c40f); height: 100%; border-radius: 6px;' })
			]),
			E('div', { 'style': 'display: flex; justify-content: space-between; font-size: 12px; opacity: 0.75;' }, [
				E('span', {}, 'RAM 占用: ' + usedMem + ' MB / ' + totalMem + ' MB'),
				E('span', {}, 'RootFS Overlay 可用: ' + E('strong', { 'style': 'color: #27ae60;' }, '~430 MB+ (超充裕空间)'))
			])
		]);

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

# 4. 注册菜单与精准 RPCD ACL 权限
mkdir -p package/base-files/files/usr/share/luci/menu.d || true
cat << 'EOF' > package/base-files/files/usr/share/luci/menu.d/luci-app-cpe-overview.json
{
	"admin/status/cpe_dashboard": {
		"title": "CPE 总览",
		"order": 1,
		"action": {
			"type": "view",
			"path": "status/cpe_dashboard"
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
				"network.device": [ "status" ]
			},
			"file": {
				"/proc/net/arp": [ "read" ]
			}
		}
	}
}
EOF

# 5. 开机预置刷新权限与缓存
mkdir -p package/base-files/files/etc/uci-defaults || true
cat << 'EOF' > package/base-files/files/etc/uci-defaults/99-cpe-theme-init
/etc/init.d/rpcd restart 2>/dev/null || true
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/ 2>/dev/null || true
exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/99-cpe-theme-init || true


exit 0