# Cudy TR3000 (512MiB 硬改) + 中兴 F50 5G CPE 固件

[![OpenWrt](https://img.shields.io/badge/ImmortalWrt-owrt-blue.svg)](https://github.com/VIKINGYFY/immortalwrt)
[![SoC](https://img.shields.io/badge/SoC-MediaTek%20MT7981B-orange.svg)]()
[![Flash](https://img.shields.io/badge/Flash-512MiB%20SPI--NAND-brightgreen.svg)]()
[![Modem](https://img.shields.io/badge/Modem-ZTE%20F50-blueviolet.svg)]()
[![Release](https://img.shields.io/github/v/release/AA9skillz-BN/tr3000-512-25?style=flat-square)](https://github.com/AA9skillz-BN/tr3000-512-25/releases)

针对 **512MiB SPI-NAND 硬改版 Cudy TR3000** 的定制固件，面向 **中兴 F50 5G 随身 WiFi** 的便携 CPE 场景。由 GitHub Actions 全自动编译，带一键在线升级。

---

## ⚠️ 刷机前必读

**本固件只适用于已硬改 512MiB 闪存的机器。**

设备树里 ubi 分区被扩到 480MiB 布局，`SUPPORTED_DEVICES` 同时包含 `cudy,tr3000-v1`（为了让本机 sysupgrade 能通过校验）。这意味着**未硬改的 128MiB 原机也能刷进去并且一定变砖**。刷之前先确认已经换过闪存颗粒。

---

## 硬件要求

| 项 | 要求 |
|---|---|
| 机型 | Cudy TR3000（MT7981B） |
| 闪存 | 512MiB SPI-NAND（实测 Winbond，128KiB block / 2048B page） |
| U-Boot | 支持 480MiB 分区布局的改版 U-Boot（Web 恢复页面） |
| 5G 模块 | 中兴 F50（RNDIS/ECM/NCM 免驱） |

> F50 峰值电流约 1.5–2A，超过路由器 USB 口的供电余量时会反复断电重连（dmesg 里每 5–10 秒一轮枚举）。**建议配带独立电源的 USB HUB**，详见文末排查一节。

---

## 功能一览

| 模块 | 内容 |
|---|---|
| **存储** | 512MiB 闪存 → ubi 480MiB 布局，overlay 实测约 410MiB |
| **系统** | ImmortalWrt（VIKINGYFY `owrt` 分支），LuCI + **Aurora 主题** |
| **中文** | 7 个 `-zh-cn` 语言包（base / firewall / aurora / aurora-config / upnp / ttyd / openclash），首启自动匹配 `luci.main.lang` |
| **无线** | Wi-Fi 6：5GHz `ch36 / HE80`（全在非 DFS 信道，不用等雷达检测），2.4GHz `ch6 / HE40`；国家码见 `diy-part2.sh` 里的 `WIFI_COUNTRY` |
| **F50** | RNDIS / ECM / NCM + usb-serial + modeswitch 驱动，自动探测绑定，热插拔自识别 |
| **防限速** | **TTL=65**（IPv6 同为 hop limit=65）改写，postrouting，出口 eth1/eth2/usb0；ICMPv6 不改，否则会破坏邻居发现 |
| **看门狗** | cron 每 3 分钟：链路状态 + 多目标连通性探测。失败先 `ifdown/ifup` 重连（带 120 秒冷却），仍失败则软复位 USB 设备；可选连续失败多次后重启 |
| **USB** | 禁用 USB runtime suspend，避免模块被挂起后无法唤醒 |
| **代理** | OpenClash（源码编译）+ 内置 ARM64 Meta 内核 + Country.mmdb / GeoSite / GeoIP |
| **拥塞控制** | BBR（`kmod-tcp-bbr` + sysctl），作用于路由器本机终结的 TCP（如 OpenClash 的代理连接），纯转发流量不受影响 |
| **在线升级** | LuCI 页面一键拉取最新 Release；哈希只信 GitHub API 直连（镜像只搬运文件），SHA256 + `sysupgrade -T` 双重校验，后台执行 |

---

## 默认配置

| 参数 | 默认值 | 说明 |
|---|---|---|
| 管理地址 | `192.168.6.1` | 避开 F50 的 192.168.0.x 网段 |
| 账号 | `root` | **无密码**，首次登录后请立即设置 |
| 无线 | `Cudy-TR3000-5G` / `Cudy-TR3000-2.4G` | **默认开放无密码**，建议立即加密 |
| 时区 / NTP | `Asia/Shanghai` / 阿里 + 腾讯 | |
| F50 接口 | `network.f50`，DHCP，MTU 1420，metric 20 | 自动加入 wan 防火墙区域 |
| 转发模式 | TTL=65 防限速优先，flow offload 关闭 | 二选一，见下文 |
| 首启初始化 | 只在首次启动执行一次 | SSID / 信道 / NTP / MTU / 防火墙等只在首次设置，之后保留配置的 OTA 不会还原你的修改（标记文件 `/etc/.custom-init-done`）；**不保留配置升级**会清掉标记，重新初始化 |

---

## 存储布局

```
0x000000  BL2            1 MiB
0x100000  u-boot-env   512 KiB
0x180000  Factory        2 MiB
0x380000  bdinfo       256 KiB
0x3c0000  FIP            2 MiB
0x5c0000  ubi        474.25 MiB   (0x1da40000)
          └ 未分配      32 MiB     (0x1E000000 – 0x20000000)
                                 合计 0x5c0000 + 0x1da40000 = 480 MiB
```

`IMAGE_SIZE := 450000k`：UBI 扣除坏块预留和 layout LEB 后的实际上限是 461156 KiB（约 450.3 MiB），留了约 10 MiB 余量。**不要改回分区大小 485632k**，那等于关掉镜像尺寸检查。

---

## 编译

### GitHub Actions（推荐）

仓库自带工作流 `Build Cudy TR3000 Firmware`，手动触发参数：

| 参数 | 说明 |
|---|---|
| `repo_source` | 源码仓库：`VIKINGYFY/immortalwrt`（默认）/ `immortalwrt/immortalwrt` |
| `repo_branch` | 分支：VIKINGYFY 填 `owrt`，官方源填 `master` 或 `openwrt-24.10` |
| `repo_commit` | 固定上游 commit，留空=分支最新。每次发布说明里都会记录实际用的 commit，某次构建出问题时填上一个好版本的 commit 即可锁定 |
| `extra_config` | 临时追加的 `.config` 片段，换行分隔 |
| `only_config` | 只跑 defconfig 并输出 `.config`，不编译（约 15 分钟） |
| `clean_release` | 编译前清理旧 Release，保留最近 2 个（默认开，迭代调试时可关） |

单次全量编译约 **2 小时**，产物：

```
immortalwrt-mediatek-filogic-cudy_tr3000-512mb-v1-squashfs-sysupgrade.bin   ← U-Boot 刷这个
immortalwrt-mediatek-filogic-cudy_tr3000-512mb-v1-initramfs-kernel.bin
sha256sums
```

另有每周一 19:00 UTC（周二 03:00 北京时间）的定时构建。定时构建跟随上游分支最新代码，会随上游漂移；想稳定就用 `repo_commit` 固定。

### 构建期自动校验

脚本对每一步都做了断言，任何一项不满足**直接让构建失败**，不会产出"看起来成功、实际缺功能"的固件：

- DTS ubi 分区确实扩到了 `0x1da40000`
- 机型定义确实注入 `filogic.mk`
- 中文语言包确实生效（缺失会打印 4 段诊断）
- OTA 三件套（菜单 / ACL / 视图）确实生成
- USB 禁休眠脚本 + rc.d 链接确实存在
- BBR 的 sysctl 配置确实生成
- 产物里确实有 `.bin`

另外 `make defconfig` 前后会做一次 diff，列出所有被静默丢弃的包。发布说明里的"BBR 拥塞控制"只在 `kmod-tcp-bbr` 确实留在最终 `.config` 里时才会写。

---

## 刷机

1. 下载 `...squashfs-sysupgrade.bin`，先核对哈希：

   ```powershell
   Get-FileHash .\immortalwrt-mediatek-filogic-cudy_tr3000-512mb-v1-squashfs-sysupgrade.bin -Algorithm SHA256
   ```

2. 长按 Reset 上电进入 U-Boot Web 恢复页面（通常 `192.168.1.1`），选择该 `sysupgrade.bin` 刷入
3. 重启后访问 `192.168.6.1`

也可以在本机已装旧版时走 **系统 → 在线升级**。

---

## 在线升级

LuCI：**系统 → 在线升级**，两个按钮：

- **⚡ 立即拉取并升级（保留配置）**
- **不保留配置升级**（等价 `sysupgrade -n`）

脚本启动后立即转入后台并返回（LuCI 调用有超时限制，下载慢时前台执行会被杀掉），进度看页面日志。

后端流程：

```
GitHub API 直连取 latest Release
  → 检查 /tmp 空间（下载前 ≥32MiB，下载后留 16MiB）
  → 下载固件（主站失败自动切 ghfast.top / ghproxy.net 镜像，镜像只搬运文件）
  → SHA256 校验，哈希来源只认：
       ① API 直连返回的 asset digest
       ② 直连下载的 sha256sums
  → tar 结构校验
  → sysupgrade -T 镜像合规性预检
  → 后台执行 sysupgrade
```

**信任模型**：镜像不可信，所以哈希绝不从镜像取。如果 api.github.com 直连不了、只能走镜像，或 Release 里拿不到可信哈希，脚本会**拒绝升级**，而不是跳过校验继续刷。

页面每 3 秒刷新 `/tmp/firmware_update.log`，能看到每一步。命令行等价：

```sh
auto-update-firmware.sh        # 保留配置
auto-update-firmware.sh -n     # 不保留配置
auto-update-firmware.sh -f     # 无法验证哈希时仍放行（风险自负，仅限确实连不上 GitHub API 时使用）
tail -f /tmp/firmware_update.log
```

`-n` 和 `-f` 可以组合使用。想让 `-f` 的行为变成默认，把脚本里的 `ALLOW_UNVERIFIED` 改成 1。

---

## 工作模式：TTL 防限速 vs 硬件加速

两者**物理上互斥**。开启 flow offload 后，已建连的包由 PPE 直接转发、不再经过 netfilter，TTL 改写只在每个流的头几个包生效，之后恢复原始 TTL——同一个连接 TTL 忽 65 忽 63，比不改写更容易被识别。

开关在 `Actions-OpenWrt/diy-part2.sh` 第 5 段：

```sh
F50_ACCEL=0   # 默认：TTL=65 防限速，flow offload 关闭
F50_ACCEL=1   # 硬件加速优先，不生成 TTL 规则（运营商侧看到 TTL=63）
```

> F50 走 USB 共享，实测上限 300–500 Mbps，而 MT7981 纯软件转发可跑 1 Gbps+，所以加速对吞吐基本没有提升，主要是降低 CPU 占用。

---

## 排查

| 现象 | 原因 | 处理 |
|---|---|---|
| **后台全英文** | `luci-i18n-*-zh-cn` 没进固件 | 检查 `ls /usr/lib/lua/luci/i18n/ \| grep '^base\.'`，构建日志会断言 |
| **菜单里没有 TurboACC** | 该包在当前 feeds 中不存在 | 正常现象。加速功能已用 uci 直接实现，不需要那个界面 |
| **F50 每 5–10 秒重连一次** | USB 供电不足（峰值 1.5–2A） | 换带独立电源的 USB HUB；或换 12V/2A 以上适配器；或换短粗 USB3 线 |
| **overlay 只有一百多 MB** | DTS 扩容没生效 | 构建期的 DTS 断言会拦截，正常不会出现 |
| **在线升级提示找不到 Release** | 路由器访问不了 api.github.com | 检查 DNS / 代理配置 |
| **在线升级提示"拒绝升级：无法验证固件完整性"** | 直连不了 api.github.com，或 Release 没有可信哈希 | 先让路由器能直连 GitHub API（例如通过 OpenClash）；确认风险后可 SSH 执行 `auto-update-firmware.sh -f` |
| **IPv6 时好时坏** | 邻居发现包的 hop limit 被改动 | 本固件已排除 ICMPv6；用 `nft list ruleset \| grep -iE 'ttl\|hoplimit'` 确认规则只有一份且带 `!= icmpv6` |
| **看门狗频繁重连** | 模组本身不稳定 | 日志在 `logread -e f50-watchdog`，已内置 120 秒冷却；第 2 次失败会软复位 USB。需要自动重启兜底时创建 `/etc/f50-watchdog.conf`，写入 `REBOOT_AFTER=6`（升级会保留） |
| **OTA 之后 SSID / 信道被改回默认** | 旧版首启脚本每次升级都会重跑 | 新版只在首次初始化执行；从旧版升级到新版时会最后重置一次，之后保留 |

---

## 仓库结构

```text
├── .github/workflows/
│   └── build-immortalwrt25.yml     # 云编译流水线
├── Actions-OpenWrt/
│   ├── diy-part1.sh                # feeds 前：加 feed、clone 主题与 OpenClash
│   └── diy-part2.sh                # feeds 后：DTS 扩容、机型注入、OTA、F50、首启脚本
├── openwrt-mod/config/
│   └── .config                     # 编译配置
└── README.md
```

`diy-part2.sh` 会把运行时文件写进 `package/base-files/files/`，随固件一起安装：

```
/etc/init.d/usb-nosuspend                       关闭 USB 自动休眠
/etc/hotplug.d/net/99-f50-auto                  F50 热插拔自动绑定（带防抖）
/etc/uci-defaults/99-custom-init                首启初始化（只执行一次，见"默认配置"）
/etc/sysctl.d/99-bbr.conf                       BBR 拥塞控制
/usr/share/nftables.d/table-post/99-f50-ttl.nft TTL / hop limit 改写规则（F50_ACCEL=0 时生成）
/etc/sysupgrade.conf                            保留 /etc/openclash/、/etc/f50-watchdog.conf、/etc/.custom-init-done
/usr/bin/f50-watchdog.sh                        链路看门狗
/usr/bin/auto-update-firmware.sh                在线升级脚本
/usr/share/luci/menu.d/luci-app-autoupdate.json OTA 菜单
/usr/share/rpcd/acl.d/luci-app-autoupdate.json  OTA 权限
/www/luci-static/resources/view/autoupdate/index.js  OTA 页面
```

---

## 已知限制

- **无 TurboACC**：`luci-app-turboacc` 不在可用 feeds 中，且其依赖的内核模块不兼容当前内核。
- **BBR 需要刷机后确认**：通过 `kmod-tcp-bbr` 提供，用 `sysctl net.ipv4.tcp_available_congestion_control` 应能看到 `bbr`。如果该包被 defconfig 丢弃，构建日志会有警告，发布说明里也不会写 BBR。
- **在线升级依赖直连 GitHub API**：直连不了时默认拒绝升级，见"在线升级"一节。
- **无 root 密码、Wi-Fi 默认开放**：首次登录后请自行设置。
- **末尾 32 MiB 闪存未分配**：要利用需改 `UBI_SIZE_512M=0x1fa40000`，但必须先确认 U-Boot 没在 flash 尾部存放 env/备份。

---

## 致谢

- [VIKINGYFY/immortalwrt](https://github.com/VIKINGYFY/immortalwrt) — 底包与 MTK Filogic 优化
- [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) / [OpenWrt](https://github.com/openwrt/openwrt) — 固件基石
- [eamonxg/luci-theme-aurora](https://github.com/eamonxg/luci-theme-aurora) — Aurora 主题
- [vernesong/OpenClash](https://github.com/vernesong/OpenClash) — 代理客户端
