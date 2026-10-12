# Cudy TR3000 5G CPE 专属定制固件 (512MB Mod)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-25.x-blue.svg)](https://openwrt.org/)
[![SoC](https://img.shields.io/badge/SoC-MediaTek%20MT7981B-orange.svg)]()
[![Flash](https://img.shields.io/badge/Flash-512MB%20SPI--NAND-brightgreen.svg)]()
[![Modem](https://img.shields.io/badge/Modem-ZTE%20F50%205G-blueviolet.svg)]()
[![GitHub Release](https://img.shields.io/github/v/release/AA9skillz-BN/tr3000-512-25?style=flat-square)](https://github.com/AA9skillz-BN/tr3000-512-25/releases)
专为 **Cudy TR3000（硬改 512MB 闪存）** 与 **中兴 ZTE F50 5G 随身 WiFi** 强强联手打造的企业级便携 5G CPE 定制固件。基于现代 OpenWrt/ImmortalWrt 25.x 底层开发，兼具高度硬件适配、蜂窝防断流自愈机制以及深度定制的 MYOS 暖白质感拟真交互大屏。
---
## 🌟 核心特性
### 1. 512MB SPI-NAND 空间完全释放
* **专用设备树（DTS）适配**：精确定义 512MB 物理闪存分区布局，根除小容量镜像裁切导致的坏块或溢出报错。
* **海量 Overlay 空间**：刷机即得 **~430MB+** 超大可用持久化存储，无需外挂 U 盘即可随心安装 Docker、OpenClash、各类 Python 依赖与服务。
### 2. 中兴 ZTE F50 5G 蜂窝全链路优化
* **免驱热插拔自识别**：内核级集成 RNDIS / CDC-NCM 驱动支持，热插拔自动侦测 `usb0` / `eth2` 网卡并拉起。
* **蜂窝黄金 MTU 1420 锁定**：针对国内 5G 移动蜂窝网络封装开销优化，杜绝因分片导致的握手缓慢、网页假死与高延迟。
* **3 分钟心跳看门狗自愈**：后台守护进程周期性检测外网连通性，突发断流时自动协商重拨与重启协议栈，实现全天候无人值守保活。
* **硬件转发分载（PPE Offload）**：启用联发科 Filogic 820 芯片硬件加速通道，超大流量转发时 CPU 占用近乎为 0。
### 3.  暖白质感 UI 与拟真实物动效
* **专属 5G 动态登录页**：定制悬浮圆角卡片、TR3000 经典深蓝徽标与缓慢律动的 5G 能量呼吸环。
* **1:1 矢量拟真硬件总览**：
  * 精准还原哑光冷蓝折叠双天线 **TR3000** 与超薄白卡 **ZTE F50** 外观。
  * 根据网卡在线状态实时呈现**动态波纹声波**与 **LED 脉冲微光**。
* **防崩 Scoped 隔离机制**：样式表完全隔离，不破坏防火墙、路由表等原生复杂的 CBI 选项卡与插件表格排版。
* **多端响应式适配**：完美适配 iPhone、Android 手机及平板竖屏操作，杜绝横向滚动与元素错位。
### 4. 智能 OTA 在线无感升级
* **后台一键升级面板**：在 LuCI 控制台即可视化拉取仓库最新构建。
* **国内加速镜像双通道**：直连 GitHub API 超时时自动无缝切换国内镜像通道（ghfast / ghproxy）。
* **双重校验防变砖**：刷入前强制执行 SHA256 完整性哈希校验与 `fwtool` 系统镜像合规性检查。
* **配置白名单热保留**：升级时自动留存网络规则、代理配置与看门狗脚本。
---
## ⚙️ 默认系统配置

| 参数项 | 默认值 | 说明 |
| :--- | :--- | :--- |
| **管理 IP** | `192.168.6.1` | 避开中兴 F50 原生管理网段，防止 IP 冲突 |
| **默认账户** | `root` | 首次登录需在页面中设置密码 |
| **无线 SSID** | `OpenWrt_2.4G` / `OpenWrt_5G` | 默认开放（建议登录后立即配置密码） |
| **Wi-Fi 规格** | Wi-Fi 6 (AX3000) | 支持 160MHz 频宽全开 |
| **时区 / NTP** | `Asia/Shanghai` (CST-8) | 预置阿里云、腾讯云、高校 NTP 高可用池 |

---
## 🚀 刷机与更新说明
### 首次刷机 / U-Boot 刷入
1. 将网线连接至路由器 LAN 口，长按 Reset 键通电进入 U-Boot Web 恢复页面（通常为 `192.168.1.1`）。
2. 在 Releases 页面下载 `*-cudy_tr3000-512mb-v1-initramfs-recovery.bin` 或 `*-sysupgrade.bin`。
3. 选择镜像上传并等待系统刷入完成（请勿断电），待灯光常亮后访问 `192.168.6.1`。
### 在线一键升级（已装本固件）
1. 登录路由器后台 `192.168.6.1`。
2. 依次进入 **系统** -> **固件升级**。
3. 点击 **⚡ 立即拉取并在线升级** 按钮。
4. 系统将自动拉取、校验并写入闪存，重启后完成无缝升级。
---
## 🛠️ 项目仓库结构
```text
├── .github/workflows/          # GitHub Actions 自动化云编译流
├── openwrt-mod/
│   └── mt7981b-cudy-tr3000-512mb-v1.dts   # 512MB 专属设备树补丁
├── diy-part1.sh                # 源码拉取与自定义 Feeds 扩展脚本
├── diy-part2.sh                # 核心定制、F50 驱动、看板与 OTA 注入脚本
└── README.md
```

---
## 鸣谢与致敬
- [VIKINGYFY/immortalwrt](https://github.com/VIKINGYFY/immortalwrt) - 现代化底包与 MTK Filogic 优化分支
- [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) & [OpenWrt](https://github.com/openwrt/openwrt) - 开源路由器固件基石
- [vernesong/OpenClash](https://github.com/vernesong/OpenClash) - 优秀的代理客户端环境支持