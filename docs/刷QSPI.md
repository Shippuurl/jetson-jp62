# Jetson Orin Nano 刷 QSPI（UEFI/Bootloader）工具包

目录：/media/shippuu/WorkSpace/jetson-qspi
目标版本：默认 `--l4t auto`（向上游探测最新有 BSP 的版本，当前 36.5.0 = JetPack 6.2.2；
也可 `--l4t 36.4.3` 锁到 JetPack 6.2）。模组 SPI-NOR 16MB（Tegra234 / t234）

## 一条命令跑起来

```bash
bash <(curl -fsSL https://tool.kervein.club/jetson/jetson-jp62.sh)
# 或
curl -fsSL https://tool.kervein.club/jetson/jetson-jp62.sh | bash -s -- --mode detect
```

刷写前如果板子还没进 recovery，脚本会停下来让你按回车反复刷新检测（不自动轮询、不超时），
按 `s` 跳过检测强行刷，`q` 退出；非交互环境会提示回终端重跑。

## 首选：一键脚本 jetson-jp62.sh（无图形界面）

```bash
bash jetson-jp62.sh                       # 交互菜单
bash jetson-jp62.sh --mode detect         # 只体检：自动识别板子 + 检查能不能刷
bash jetson-jp62.sh --mode qspi           # 只刷 QSPI（UEFI/bootloader），保留系统数据
bash jetson-jp62.sh --mode nvme           # 整机刷到 NVMe
bash jetson-jp62.sh --mode prep           # 只下载+解压（离线缓存）
bash jetson-jp62.sh --mode target         # 在 Jetson 本机 apt 升计算栈到 6.2
```

能力/行为：
- 自动识别板子：板内读 /etc/nv_boot_control.conf 的 TNSPEC（得出模块号、super 与否、启动存储），
  主机端看 lsusb recovery PID（0955:7523）并读 USB 链路速率；据此自动选板型配置。
- 刷前门槛检查（不满足直接拦，逐条给修法）：主机架构、系统版本、基础命令、磁盘余量、
  BSP 版本是否等于目标、板型配置是否存在、rootfs 是否 apply 过、recovery 是否在位、
  USB 是否掉到 USB2、sudo 是否可用、板内额外查 UEFI 与目标是否同代 / 是否指定非官方 dtb / 系统盘空间。
- 下载：NVIDIA 官方源 + 可叠加 --mirror（http/https/file:// /本地目录），失败自动换源，
  断点续传，bzip2 -t + sha256 双校验，已下好的包自动复用。
- 资源路径可自定义（三种都行，优先级 命令行 > 配置文件 > 环境变量 > 默认）：
    `--dir D`         工作目录（解压/刷机树放这）
    `--cache-dir P`   下载包存放目录（别名 --resource，可分到另一块盘，多台设备复用同一份包）
    `--mirror 源,...` 拉取源；自定义源排在最前，NVIDIA 官方只当兜底，内网可只走自己的镜像
    `--config F`      配置文件（默认 ~/.config/jetson-jp62/config），KEY=VALUE：
                      JETSON_DIR / JETSON_CACHE / JETSON_MIRROR / JETSON_BOARD / L4T_VERSION / JETSON_OFFLINE_SRC
- 硬盘冗余检测：按模式算峰值占用（下载包 + 解压膨胀 + apply_binaries + 刷机临时镜像 + 余量），
  下载目录与工作目录分别核对；同时校验文件系统类型（ext4/xfs/btrfs 才行，NTFS/exFAT 会毁 rootfs 权限）；
  分区已用率 >85% 会警告；不够时自动列出本机其它够用的挂载点，`--auto-dir` 直接帮你切到余量最大的那块盘。
- 刷完解析 flash 日志里的 `Board ID(..) sku(..)` 行，与所选板型再核对一次。
- 首次运行须同意《使用协议与安全声明》（法律/风险/许可），同意后记在
  ~/.config/jetson-jp62/agreed-v1；自动化可用 --accept，--dry-run 全程不落地。
- 跑完会提示打开 index.html 使用说明页：有图形环境直接在浏览器打开，headless 只打印路径；
  立即打开用 `--doc`，别打扰用 `--no-doc`，脚本没和文档放一起时用 `--doc-url <url>`。

实测（2026-11-13）：
- 主机侧 detect：Ubuntu 24.04.4 x86_64，依赖齐全，BSP 36.4.3，通过
- 板内 detect（真板 192.168.11.143）：TNSPEC 3767-300-0004-U.1-1-1-jetson-orin-nano-devkit-super-，
  L4T R36.4.3，UEFI 36.4.0，Super=yes，启动盘 nvme0n1 → 自动选 jetson-orin-nano-devkit-super
- 镜像源回退：把官方源改成无效 tag，脚本自动降到 --mirror file://…，682MB 下完、bzip2+sha256 通过、解压成功
- 主机上没有 recovery 设备时跑 --mode qspi：被拦下并给出短接修法

## QSPI / 刷机支持矩阵（脚本运行时向上游实时生成，不写死）

数据源只有两个上游，脚本每次按需拉、结果缓存 7 天（`--refresh` 强刷）：
1. `repo.download.nvidia.com/jetson/t234/dists/<suite>/Packages.gz` → 该 suite 实际 L4T 版本、
   bootloader、有没有 `nvidia-l4t-jetson-orin-nano-qspi-updater`（QSPI capsule 更新包）
2. 官方 BSP 下载目录 HEAD 探测 → 这个 L4T 版本是否真有可直接刷机的 BSP tarball

`bash jetson-jp62.sh --accept --matrix --refresh` 实测输出（2026-11-13）：

```
suite    L4T(apt)   BSP可下    QSPI胶囊包  只刷QSPI
r35.4    35.4.1     35.4.1     无           是
r35.5    35.5.0     35.5.0     有 36.3.0    是
r35.6    35.6.5     35.6.5     有 36.4.3    是
r36.2    36.2.0     36.2.0     无           是
r36.3    36.3.0     36.3.0     有 36.3.0    是
r36.4    36.4.7     36.4.4     有 36.4.7    是
r36.5    36.5.2     36.5.0     有 36.5.2    是
```

两个必须知道的坑（矩阵自动暴露出来的）：
- apt 里的版本 ≠ 能下载的 BSP 版本。r36.4 的 apt 已到 36.4.7，但官方下载目录只有到 36.4.4；
  r36.5 的 apt 是 36.5.2，BSP 只有 36.5.0。差的那几个 patch 只走 apt/OTA，没有 host 端刷机包。
- QSPI capsule 更新包在 r35.x 的套件里也存在，且里面装的就是 36.x 的固件（5.x→6.x 跳板用），
  所以"能不能在板内升 QSPI"要看这个包，不看 suite 号。

平台侧能力：t234（Orin Nano/NX/AGX Orin）有 19 个 QSPI 分区配置（nvme / sd / sdmmc / ab / enc /
industrial / safety / c7 等），脚本会列本机 BSP 实际带的那份，而不是假设。

参考实现：
- 官方图形工具（整机刷，**没有**只刷 QSPI 的选项）https://developer.nvidia.com/sdk-manager
- `osrbot/mfi-qspi-forge`：从已有 MFI 量产包里派生 QSPI-only 包（去掉 rootfs 索引、校验 QSPI 索引
  与 SHA-1、Fast/Full 擦除、Zenity GUI），面向两阶段量产：先只刷 QSPI，再单独刷 SSD
- `Hi5808/turing-pi-2.5-jetson-eeprom-fix`：Turing Pi 2/2.5 上 Orin NX/Nano 起不来时，先备份
  载板 EEPROM，再只重刷 QSPI，NVMe 数据不动
两者思路与本脚本一致：QSPI 与 rootfs 解耦，先只动 bootloader。

## 版本与校验不再写死

- `--l4t auto`（默认）向上游探测"存在 BSP 包的最高版本"，当前会选到 36.5.0；
  `--l4t latest` 同义；`--l4t 36.4.3` 指定；给一个只有 apt 发布、没有 BSP 的版本会直接提示
  并列出所有可选版本。
- sha256 不内置：首次下载成功后记入 `~/.config/jetson-jp62/manifest.sha256`（TOFU），
  之后每次下载都对照；团队可挂统一清单 `--manifest-url https://内网/manifest.sha256`。
- 脚本自身可更新：`--self-update --update-from <url|路径>`（或配 `JETSON_SCRIPT_URL`），
  先 `bash -n` 语法检查、再比对 sha256、旧版留 `.bak.<时间戳>`。

## 手工路线（脚本不可用时）

## 文件清单

| 文件 | 大小 | 说明 |
|---|---|---|
| Jetson_Linux_R36.4.3_aarch64.tbz2 | 715,765,074 B | 官方 BSP（含 flash.sh、bootloader、QSPI 分区配置）已 bzip2 校验 ok |
| Linux_for_Tegra/ | 787 MB | 上面解压出来的刷机树，可直接 flash.sh |
| nvidia-l4t-jetson-orin-nano-qspi-updater_36.4.3-20250107174145_arm64.deb | 9.2 MB | 板内 capsule 升级包（不走主机） |
| deb-x/ | - | 该 deb 的 control/postinst/preinst，便于审查 |

sha256
```
949a44049c4ce6a8efdf572ea0820c874f6ee5d41ca3e4935b9f0e38d11873d2  Jetson_Linux_R36.4.3_aarch64.tbz2
f0a99de8822d20769ec4b18ee79f240a3fabd91533f3aad5a9ed19e32c0f8d5e  nvidia-l4t-jetson-orin-nano-qspi-updater_36.4.3-20250107174145_arm64.deb
```

## 路线 A：板内直接升级（客户机上一条命令，不用主机）

前提检查（这个包自带 preinst 会强制校验，实测源码在 deb-x/preinst）：
1. COMPATIBLE_SPEC 必须是 `...-jetson-orin-nano-devkit-` 且 board sku = 0005（只有 Orin Nano DevKit）
2. 根文件系统必须挂载在 /dev/mmcblk1p1（即 SD 卡启动）
3. 现有 UEFI 版本 ≥ 35.5.0

不满足上面任一条 → 直接 dpkg -i 会报 ERROR 退出（NVMe/eMMC 启动、厂商自研底板都会卡在 1/2 条）。

满足时：
```
scp nvidia-l4t-jetson-orin-nano-qspi-updater_36.4.3-20250107174145_arm64.deb ubuntu@<客户板IP>:~
ssh ubuntu@<客户板IP>
sudo dpkg -i nvidia-l4t-jetson-orin-nano-qspi-updater_36.4.3-20250107174145_arm64.deb
sudo reboot
```
它干的事：把 /opt/ota_package/t23x/jetson-orin-nano-devkit.Cap 拷到 ESP 的
EFI/UpdateCapsule/，再置 UEFI 变量 OsIndications bit2；重启由 UEFI 自己写入 QSPI。
重启后：`sudo nvbootctrl dump-slots-info` 看 Current version 应是 36.4.x。

## 路线 B：主机 QSPI-only 刷（通用，推荐给厂商底板）

只写 QSPI 分区，不碰 NVMe/eMMC 里的系统和数据。

1) 板子进 recovery 模式：Orin Nano DevKit 上把 FC REC 与 GND 短接（12 针 header 第 9、10 脚），
   上电，USB-C 口接主机；主机确认：
```
lsusb | grep -i 0955:7523
```
2) 刷（在 Linux_for_Tegra 目录）：
```
cd /media/shippuu/WorkSpace/jetson-qspi/Linux_for_Tegra
sudo ./flash.sh -c bootloader/generic/cfg/flash_t234_qspi.xml \
     jetson-orin-nano-devkit-super nvme0n1p1
```
   - NVMe 启动用上面的 `-nvme` 版配置也行：`jetson-orin-nano-devkit-super-nvme`
   - SD 启动：`jetson-orin-nano-devkit-super sdmmc1`（或用 flash_t234_qspi_sdmmc.xml）
   - **板配置必须带 -super**，用 jetson-orin-nano-devkit.conf 刷出来是非 Super，MAXN_SUPER 不会出现
   - 厂商定制底板（机器人整机）：必须换成厂商的 board .conf，否则 pinmux/相机/串口会挂
3) 断电重启，`nvpmodel -q` 应能切到 MAXN_SUPER。

注意：QSPI-only 刷不需要 rootfs，rootfs/ 是空目录也能跑；若脚本报
`rootfs/boot/extlinux/extlinux.conf is not found` 说明误用了整机刷机参数，
那是要下载 Sample Rootfs（1.83 GB，本次未下载，仅整机刷需要）：
https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.3/release/Tegra_Linux_Sample-Root-Filesystem_R36.4.3_aarch64.tbz2

## 刷完怎么验（实测字段，192.168.11.143 这台 6.2+Super 的输出作参照）

```
nvbootctrl dump-slots-info   -> Current version: 36.4.0     (L4T 36.4.3 的 UEFI 报 36.4.0)
nvpmodel -q                  -> NV Power Mode: MAXN_SUPER / 2
head -3 /etc/nv_boot_control.conf -> TNSPEC ...-jetson-orin-nano-devkit-super-
dpkg -l | grep nvidia-l4t-bootloader -> 36.4.3-20250107174145
```

## 风险清单

- 刷 QSPI 全程不能断电（模组供电不稳就先别刷，掉电要 recovery 模式救）
- 不要用非 -super 的 board conf，也不要在厂商底板上用 devkit conf
- 6.0 → 6.2 换的是 UEFI/QSPI + TensorRT 8.6→10.3、cuDNN 8.9→9.3，客户自己编的 TRT engine 要重做
- 刷 QSPI 不改 A/B 分区里的系统；系统仍是 6.0 的话 bootloader 36.4 也能带 36.3 rootfs 跑，但建议一起对齐

## 来源

- BSP / rootfs：https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.3/release/
- QSPI updater deb：https://repo.download.nvidia.com/jetson/t234/pool/main/n/nvidia-l4t-jetson-orin-nano-qspi-updater/
- 文档：NVIDIA JetPack 6.2 install-setup「Upgrade JetPack」；Jetson Orin Nano DevKit User Guide「JetPack 6.x Update Path」
