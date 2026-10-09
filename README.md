# ImmortalWrt for Cudy TR3000 (512MB Flash / mod-490)
针对 **Cudy TR3000 (MT7981B)** 深度定制的 ImmortalWrt 25.x 固件构建工程。专为 **512MB SPI-NAND 改造版** 设计，深度集成中兴 F50 5G 免驱热插拔、MTK 硬件流控加速、OpenClash 25.x 现代化运行协议栈及专属安全 OTA 在线更新机制。
---
## 硬件与系统规格

| 维度 | 参数 / 规格 |
| :--- | :--- |
| **设备型号** | Cudy TR3000 (MediaTek MT7981B / Filogic 820) |
| **硬件存储** | 512MB SPI-NAND (配合 `mod-490` 分区布局) |
| **系统架构** | ImmortalWrt 25.x (Linux 内核 6.x / ARM64 Cortex-A53) |
| **包管理机制** | `apk` (全面兼容 OpenWrt 现代化包管理体系) |
| **防火墙架构** | `firewall4` + `nftables` (全量弃用过时 iptables 栈) |
| **默认网关** | `192.168.6.1` (避开光猫与随身 WiFi 默认网段冲突) |
| **默认密码** | 无密码 (首次登录直接进入或根据提示设置) |

---
## 核心特性
1. **512MB 闪存空间完全释放**
   - 适配 `mod-490` U-Boot 分区定义，提供高达 ~490MB 的可用只读/可写空间。
   - 设备树（DTS）重构为 `0x1ea80000` UBI 布局，编译镜像大小设为 `502272k` 规避解析溢出。
   - 预置 `luci-app-diskman` 与 `block-mount`，支持外接 USB 存储与分区管理。
2. **中兴 F50 5G 免驱即插即用 (动态热插拔)**
   - 编译包含 `kmod-usb-net-rndis`、`cdc-ether`、`cdc-ncm` 核心驱动。
   - 动态 Hotplug 脚本自动侦测并兼容网卡枚举（`usb0` / `eth2`），附带 2 秒 Link-Up 协商缓冲，避免 DHCP 丢包。
   - 动态识别并挂载至 `wan` 防火墙区域，跃点设置为 `20`。
   - 支持 `mwan3`，可与物理有线 WAN 实现多线冗余与断网故障转移。
3. **OpenClash 25.x 原生运行协议栈支持**
   - 预置完整底层依赖：`kmod-tun`、`kmod-nft-tproxy`、`kmod-nft-socket`、`ip-full`、`ruby`、`ruby-yaml`。
   - 针对无板载 RTC 电池的硬件特性，内置 `uci-defaults` 强制预设国内高可用 NTP 源（Aliyun / Tencent）与 `Asia/Shanghai` 时区，彻底解决开机时钟偏差导致的 TLS 证书握手失败。
4. **安全型 OTA 在线升级系统**
   - 深度集成 LuCI Web 前端页面与专属后端脚本。
   - 一键获取本仓库最新 Release 固件，支持进度实时回显。
   - **安全兜底防护**：
     - **防 403 阻断**：注入标准请求头，规避 GitHub API 限制。
     - **下载完整性保障**：强制执行 SHA256 哈希硬比对，拒绝写入断流残损固件。
     - **内存防溢出 (OOM 防护)**：升级前自动清理系统缓存（`drop_caches`），暂停高占用后台服务。
     - **解耦执行**：后台子进程执行 `sysupgrade`，防止前端浏览器关闭导致刷机异常中断。
     - **配置白名单**：原生保留升级脚本与 OpenClash 订阅配置。
---
## 刷机与使用说明
### 1. 首次刷入（前置条件）
> ⚠️ **高危提醒**：本固件专为 **512MB Flash** 及 **`mod-490` U-Boot 布局** 定制。原厂 128MB 分区固件切勿直接使用原厂 Web 直升！
- 路由器必须已通过编程器或 SPI 工具刷入支持 512MB NAND 的开源 U-Boot。
- 拔掉电源，长按 Reset 键通电开机进入 U-Boot 恢复控制台。
- 在 Web 恢复界面中选择 `mod-490` 布局，并上传生成的 `*cudy_tr3000-512mb-v1-sysupgrade.bin` 固件进行刷入。
### 2. 访问控制台
- 路由器启动就绪后，将网线连接至 LAN 口或连接默认 Wi-Fi。
- 浏览器访问：`http://192.168.6.1`。
### 3. 日常 OTA 在线升级
- 登录路由器 Web 管理界面。
- 点击导航栏：**系统 -> 固件升级**。
- 点击 **⚡ 立即检查并拉取最新固件升级** 按钮，系统将自动校验、拉取最新版本并保留现有网络配置完成重载。
---
## 自动化构建说明
本仓库通过 GitHub Actions 执行自动化云端编译：
- **触发机制**：
  - 手动触发（Actions 页面 `Run workflow`）。
  - 定时触发：国际标准时间每周一 19:00（北京时间每周二凌晨 03:00）。
- **保留策略**：
  - 自动保留最新 3 个 Release 资产，自动清理过期标签与构建文件，保障资产空间整洁。
---
## 鸣谢与致敬
- [VIKINGYFY/immortalwrt](https://github.com/VIKINGYFY/immortalwrt) - 现代化底包与 MTK Filogic 优化分支
- [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) & [OpenWrt](https://github.com/openwrt/openwrt) - 开源路由器固件基石
- [vernesong/OpenClash](https://github.com/vernesong/OpenClash) - 优秀的代理客户端环境支持
