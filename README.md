# A2VEC · Jetson 维护工具

`jetson-jp62.sh` 是面向 Jetson Orin 的 Bash 维护辅助脚本，用于环境检查、资源准备及调用 NVIDIA 刷写工具。A2VEC 为项目展示品牌；本项目不是 NVIDIA 官方产品。

[工具首页](https://tool.kervein.club/jetson/) · [操作手册](https://tool.kervein.club/jetson/guide.html) · [MIT License](LICENSE)

## 站点与多语言

说明页为左右各占一半的分栏布局：左栏为工具说明与许可，右栏为刷写前的准备清单与实物照片。页面提供中文、English、日本語、Deutsch、Français、한국어 六种语言，切换入口在左栏底部（不使用顶部导航）。

页面由 `build/build_i18n.py` 生成，不要直接手改 `index*.html`：文案集中在该脚本的 `T` 字典中，改完执行

```bash
python3 build/build_i18n.py     # 重新生成 index.html + index.<lang>.html
bash deploy/push.sh             # 上线到 tool.kervein.club
python3 deploy/github-publish.py
```

## 获取与运行

```bash
curl -fL --proto '=https' -o jetson-jp62.sh https://tool.kervein.club/jetson/jetson-jp62.sh
# 审阅下载的脚本后执行
bash jetson-jp62.sh --help
bash jetson-jp62.sh
```

交互菜单提供检查、诊断、资源准备和刷写入口。脚本需要时会使用 sudo；具体主机要求以对应 Jetson Linux 版本的 NVIDIA 文档为准。请勿将某一版本的主机要求推广至全部版本。

## 模式与写入范围

| 模式 | 行为 |
| --- | --- |
| `--mode detect` | 检查环境和设备状态，不执行固件刷写；可能访问上游并更新本地缓存 |
| `--mode prep` | 下载并解压 BSP；`--with-rootfs` 准备 sample rootfs |
| `--mode qspi` | 调用官方 `flash.sh` 写入 QSPI 启动固件，不以重写系统盘为目标 |
| `--mode nvme` | 调用官方 initrd flash，重写目标存储并清除数据 |
| `--mode target` | 在 Jetson 本机通过 apt 更新软件包，不等同于更新 QSPI |

QSPI 和 NVMe 模式均需要准备 rootfs。即使不计划重写系统盘，也应提前备份数据和厂商配置。错误固件、错误板型或供电中断可能导致无法启动。

## 操作顺序

1. 记录模组、载板型号、现有 L4T / UEFI 版本与系统存储位置。第三方载板须先取得厂商适配资料。
2. 依据对应版本的 NVIDIA 文档确认升级路径，完成数据备份并准备 Recovery 恢复条件。
3. 检查主机空间、依赖及 USB 连接。Recovery 引脚和操作方式以具体载板手册为准。
4. 显式指定已核对的 L4T 版本及板型，阅读预检查结果与即将执行的命令后再确认刷写。
5. 完成后检查启动日志、实际版本、存储及外设工作状态；命令退出成功不替代功能验收。

```bash
# 环境检查（示例版本，不构成适配建议）
bash jetson-jp62.sh --mode detect --l4t 36.4.3

# 准备资源
bash jetson-jp62.sh --mode prep --l4t 36.4.3 --with-rootfs

# 已确认适配后，刷写 QSPI
bash jetson-jp62.sh --mode qspi --l4t 36.4.3
```

## 版本与板型

`--l4t <版本>` 指定 L4T；`--jetpack <版本>` 按脚本内映射选择 L4T。交互刷写未指定版本时显示版本菜单；非交互运行可能回落到自动探测，因此自动化任务应显式固定版本。

`--matrix` 读取上游软件包和下载目录信息，`--refresh` 刷新缓存。资源存在仅代表可获取，不能作为当前硬件兼容或可安全刷写的证明。apt 软件包版本与可下载 BSP 版本可能不同；映射目标缺少 BSP 时，脚本可能选择不高于目标的其他版本，请核对输出。

`--board <配置名>` 指定板型，`--list-boards` 列出本地 BSP 配置。USB Recovery 标识不足以确定载板适配关系，不能替代设备型号及厂商配置核验。

## 工作目录与磁盘

- `--dir <路径>`：工作目录，存放解压树与日志。
- `--cache-dir <路径>`：下载包缓存目录；默认与工作目录相同。
- `--auto-dir`：按脚本规则选择空间较充足的分区；执行前核对输出路径。
- `--mirror <源>`：指定下载源，支持 HTTP、HTTPS、file URL 或本地目录；建议使用可信 HTTPS 来源。
- `--offline --src <目录>`：使用本地资源包；主机依赖仍需提前准备。

空间需求随版本、rootfs、解压树及缓存复用情况变化，以运行时预检查为准。仅下载包大小不足以代表峰值空间需求。删除现有刷机树前应确认其中没有厂商补丁、备份或其他任务需要的文件。

## 校验与自动化

默认 TOFU 清单在首次获取资源后记录摘要，后续用于检查一致性；它不能独立证明首次获取文件的真实性。可使用 `--manifest-url <URL>` 指定来自可信渠道的 SHA-256 清单。

首次交互运行需确认使用声明，当前记录位于 `~/.config/jetson-jp62/agreed-v2`（设置 `XDG_CONFIG_HOME` 时使用该目录）。`--accept` 明确接受声明；`--yes` 还会自动确认后续操作，请仅在已审阅命令和参数的自动化流程中使用。

`--dry-run` 用于预检查和查看计划，不替代实际硬件验证。`--no-deps` 禁止自动安装主机依赖。设置 `NO_COLOR=1` 可禁用 ANSI 颜色；重定向输出自动禁用颜色。

## 诊断与日志

```bash
bash jetson-jp62.sh --diag
bash jetson-jp62.sh --uart-list
bash jetson-jp62.sh --uart /dev/ttyUSB0 --uart-seconds 30
bash jetson-jp62.sh --uart-log uart-existing.log
```

诊断可能读取设备信息、生成文件或与 Recovery 设备通信，不应理解为完全没有本地副作用。串口默认波特率为 115200；电平、接线和引脚定义以设备资料为准。日志阶段匹配只提供排查线索，未出现某阶段不等于该阶段故障。

常见输出包括工作目录中的 `flash-qspi.log`、`diag-<时间>/` 和 `uart-<时间>.log`。分享日志前检查设备标识、网络地址及其他敏感信息。

`--doc` 打开操作手册；`--no-doc` 关闭完成后的文档提示。完整参数以 `--help` 为准。

## 许可与责任

脚本与文档依据 MIT License 提供，Copyright (c) 2026 Shippuurl。品牌展示不改变原版权归属。再分发须保留版权与许可声明，全文见 [LICENSE](LICENSE)。

软件按现状（AS IS）提供。在适用法律允许的最大范围内不提供明示或默示担保；作者及版权持有人的责任限制以 MIT 原文为准。本声明不排除或限制适用法律不得排除或限制的责任。

公开发布的脚本不包含 NVIDIA 固件、引导程序或专有 SDK。运行时取得的第三方组件受其随附许可约束；对本工具声明的确认不替代第三方许可要求。使用者应确认设备操作权限、适配条件和备份恢复方案。

NVIDIA、Jetson 和 JetPack 为 NVIDIA Corporation 的商标。本项目与 NVIDIA 无隶属或背书关系；MIT 不授予第三方商标或 NVIDIA 软件的使用权。

## 官方参考

- [Jetson Linux R36.4.3 · Flashing Support](https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/FlashingSupport.html)：刷写工具及存储配置。其他版本应查阅对应版本文档。
- [Jetson Linux R36.4.3 · Software Packages and the Update Mechanism](https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/SoftwarePackagesAndTheUpdateMechanism.html)：软件包与更新机制。
- [JetPack · Install & Setup](https://docs.nvidia.com/jetson/jetpack/install-setup/index.html)：JetPack 安装与升级说明，内容可能随当前版本更新。
- [Orin Nano Developer Kit · Firmware Update](https://docs.nvidia.com/jetson/orin-nano-devkit/user-guide/latest/update_firmware.html)：官方开发套件固件更新路径，不应直接套用于第三方载板。

原始手工命令与排查记录保留在仓库的 `docs/刷QSPI.md`（本地文件 `README-刷QSPI.md`），仅供历史参考，须按实际硬件及版本重新核验。
