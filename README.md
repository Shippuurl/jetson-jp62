# jetson-jp62.sh

> 一条命令在 Jetson Orin 上刷 JetPack 6.2 的 QSPI（UEFI/bootloader），不装 SDK Manager、不点图形界面。

```bash
bash <(curl -fsSL https://tool.kervein.club/jetson/jetson-jp62.sh)
# 或
curl -fsSL https://tool.kervein.club/jetson/jetson-jp62.sh | bash -s -- --mode detect
```

详细说明（支持矩阵 / 参数 / 免责声明 / FAQ）：**<https://tool.kervein.club/jetson/>**
GitHub 镜像：`https://raw.githubusercontent.com/Shippuurl/jetson-jp62/main/jetson-jp62.sh`

## 它做什么

| 模式 | 说明 |
|---|---|
| `--mode detect` | 只体检：自动识别板子 + 10 项刷前检查，不改任何东西 |
| `--mode qspi` | 只刷 QSPI（走官方 `flash.sh -c flash_t234_qspi.xml`），NVMe/系统盘数据不动 |
| `--mode nvme` | 整机刷到 NVMe（官方 initrd flash，会格式化目标盘） |
| `--mode prep` | 只下载 + 解压 BSP（离线缓存、多台设备复用） |
| `--mode target` | 在 Jetson 本机执行，apt 把计算栈升到 6.2（不重刷） |
| `--matrix` | 打印 QSPI / 刷机支持矩阵（上游实时探测） |
| `--self-update` | 更新脚本自身（先 `bash -n` 再比 sha256，旧版留 .bak） |

特性一览：

- **版本不写死**：`--l4t auto` 向上游探测「存在 BSP 包的最高版本」，不给你下不下来的号
- **校验不写死**：首次下载后记 TOFU 清单（`~/.config/jetson-jp62/manifest.sha256`），也可 `--manifest-url` 挂统一清单
- **自动识别板子**：板内读 TNSPEC，主机端看 recovery PID 与 USB 链路速率，据此挑板型配置
- **刷前 10 项体检**：架构 / 依赖 / 磁盘冗余 / 文件系统类型 / BSP 版本 / 板型 conf / rootfs / recovery / USB 速率 / sudo
- **recovery 手动刷新**：没检测到就停下来让你按回车反复刷新，不自动轮询、不超时；`s` 跳过、`q` 退出
- **下载源可换**：`--mirror` 支持 http/https/`file://`/本地目录，自定义源优先、官方兜底
- **磁盘冗余检测**：按模式算峰值，校验 ext4/xfs/btrfs，不够时列其它分区，`--auto-dir` 自动换盘
- **跑完提示打开说明页**：有图形环境直接开浏览器，headless 只打印路径

## 支持矩阵（运行时向上游探测，实测 2026-11-13）

| suite | L4T（apt） | BSP 可下载 | QSPI capsule 包 | 只刷 QSPI |
|---|---|---|---|---|
| r35.4 | 35.4.1 | 35.4.1 | 无 | 是 |
| r35.5 | 35.5.0 | 35.5.0 | 有 36.3.0 | 是 |
| r35.6 | 35.6.5 | 35.6.5 | 有 36.4.3 | 是 |
| r36.2 | 36.2.0 | 36.2.0 | 无 | 是 |
| r36.3 | 36.3.0 | 36.3.0 | 有 36.3.0 | 是 |
| r36.4 | 36.4.7 | 36.4.4 | 有 36.4.7 | 是 |
| r36.5 | 36.5.2 | 36.5.0 | 有 36.5.2 | 是 |

数据源：`repo.download.nvidia.com/jetson/t234/dists/<suite>/Packages.gz` + 官方下载目录 HEAD 探测。
**apt 版本 ≠ 能刷的版本**：r36.4 的 apt 已 36.4.7，但 BSP 只到 36.4.4；那些 patch 只走 apt/OTA。

## 快速开始

```bash
# 1) 板子进 recovery：FC REC 与 GND 短接后上电，USB-C 接主机
lsusb | grep 0955      # 应出现 0955:7523 NVIDIA Corp. APX

# 2) 体检
bash jetson-jp62.sh --mode detect

# 3) 只刷 QSPI（保留系统数据）
bash jetson-jp62.sh --mode qspi

# 4) 板内自检
nvbootctrl dump-slots-info   # Current version 应为 36.4.x
nvpmodel -q                  # 期望 MAXN_SUPER
```

## 硬盘预算（冷启动最坏情况，实测口径）

| 模式 | 峰值占用 | 说明 |
|---|---|---|
| `--mode detect` | 1.4 GB | 只体检，不下载 |
| `--mode prep` | 2.8 GB | 只有 BSP |
| `--mode prep --with-rootfs` | 8.5 GB | BSP + rootfs + apply_binaries |
| `--mode qspi` | 9.3 GB | 含 rootfs（拼 recovery ramdisk）+ 临时镜像 |
| `--mode nvme` | 12.4 GB | 额外生成 system.img |
| `--mode target` | 系统盘 ≥ 9 GB | 板内 apt 升级 |

分项：BSP 下载 715 MiB / 解压 ~790 MB；sample rootfs 1.70 GiB / 解压 ~3.1 GB；apply_binaries +~0.9 GB；
刷机临时镜像 QSPI ~0.8 GB、NVMe ~3.9 GB；日志与余量 1.4 GB。已缓存的包自动抵扣。

下载与解压分盘（`--cache-dir`）：qspi 需 2.4 GB + 5.8 GB；nvme 需 2.4 GB + 8.9 GB。

> ⚠️ **QSPI 也要 rootfs**：36.x 的 `flash.sh` 即使只写 QSPI 分区，也会从 `rootfs/` 拼 recovery ramdisk。
> 所以 `--mode qspi` 的预算是 9.3 GB，不是老文档里的 2 GB。

## 参数

```
--mode detect|qspi|nvme|prep|target   执行模式（不给则进交互菜单）
--l4t <版本|latest>                   目标 L4T，默认 auto
--matrix / --refresh                  打印支持矩阵 / 强制重取上游缓存
--board <名字> / --list-boards        强制板型 / 列出 BSP 内全部板型
--dir / --cache-dir / --auto-dir      工作目录 / 下载包目录 / 自动选盘
--mirror <源,...>                     下载源（自定义优先）
--offline --src <目录>                完全离线
--manifest-url <url>                  外部 sha256 清单
--self-update --update-from <url>     更新脚本自身
--config <文件>                       配置文件（默认 ~/.config/jetson-jp62/config）
--doc / --doc-url / --no-doc          打开说明页 / 指定在线文档 / 不提示
--skip-recovery-check                 不检查 recovery 强行刷
--no-deps / --yes / --accept / --dry-run
```

配置文件示例 `~/.config/jetson-jp62/config`：

```
JETSON_DIR=/data/jetson
JETSON_CACHE=/data/jetson/cache
JETSON_MIRROR=file:///mnt/nas/l4t
JETSON_BOARD=jetson-orin-nano-devkit-super
```

## 已知坑

- **Super 不在镜像里**：Orin Nano 的 MAXN_SUPER 来自 36.4 UEFI/QSPI，插系统盘拿不到，必须刷 QSPI
- **apt 升 6.2 没有 Super**：NVIDIA 文档明确 "will not enable Super Mode"
- **计算栈断代**：6.0 → 6.2 是 TensorRT 8.x→10.x、cuDNN 8.x→9.x，自编 engine 要重建
- **厂商底板别用 devkit 配置**：pinmux / 串口 / CSI / 供电不同，先备份 /boot 与自定义 dtb
- **NTFS/exFAT 上准备 rootfs 会坏**（丢权限与软链），脚本会拦
- **刷写中途断电＝变砖**，要回 recovery 重刷

## 免责声明

刷机是破坏性操作：整机刷会格式化目标存储，错误固件可能导致设备无法启动。

本脚本为个人整理的辅助工具，**按现状（AS IS）提供**，不做任何明示或默示担保；因使用本脚本导致的
数据丢失、设备损坏、业务中断、合规问题，作者不承担责任。

脚本**不包含、不再分发**任何 NVIDIA 固件或闭源二进制，仅从 NVIDIA 官方地址下载并调用其官方工具
（`flash.sh` / `l4t_initrd_flash.sh`），下载与使用受 NVIDIA 软件许可协议（EULA）约束。
`Jetson`、`JetPack`、`NVIDIA` 是 NVIDIA Corporation 的商标，本项目与其无隶属或背书关系。

首次运行需输入「同意」确认；`--accept` 仅用于自动化场景（等同你已同意上述条款）。

## 许可

脚本与文档：MIT（见 [LICENSE](LICENSE)）。NVIDIA 固件不随本仓库分发。

## 参考

- JetPack 安装/升级（含 apt 与 Super 说明）：<https://docs.nvidia.com/jetson/jetpack/install-setup/index.html>
- SDK Manager（官方图形工具，只能整机刷）：<https://developer.nvidia.com/sdk-manager>
- Orin Nano DevKit 固件更新路径：<https://docs.nvidia.com/jetson/orin-nano-devkit/user-guide/latest/update_firmware.html>
- L4T 刷写文档（flash.sh / l4t_initrd_flash.sh）：<https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/FlashingSupport.html>
- QSPI-only 量产参考：<https://github.com/osrbot/mfi-qspi-forge>
- 先备份载板 EEPROM 再只刷 QSPI：<https://github.com/Hi5808/turing-pi-2.5-jetson-eeprom-fix>
