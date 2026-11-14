#!/bin/bash
# =============================================================================
# jetson-jp62.sh — JetPack 6.2 (L4T 36.4.3) 一键安装/刷机，全程无图形界面
#
#   交互菜单          bash jetson-jp62.sh
#   QSPI only         bash jetson-jp62.sh --mode qspi      (UEFI/bootloader，保留系统数据)
#   整机刷 NVMe       bash jetson-jp62.sh --mode nvme      (官方 initrd flash)
#   只下载+解压       bash jetson-jp62.sh --mode prep
#   板内升计算栈      bash jetson-jp62.sh --mode target    (在 Jetson 本机跑)
#   只做体检          bash jetson-jp62.sh --mode detect    (不下载、不刷机)
#
# 特性：
#   - 自动识别板子（板内读 TNSPEC / 主机端看 recovery）并自动挑板型配置
#   - 刷前逐条门槛检查（架构/依赖/磁盘/recovery/USB 链路/BSP 版本/rootfs/权限）
#   - 下载源可换（--mirror / JETSON_MIRROR，http/https/file/本地目录），断点续传+双校验
#   - 首次运行须agree《使用协议与安全声明》，agree后记在 ~/.config/jetson-jp62/
#   - 所有动盘动作先打印再执行；--dry-run 只体检不改动
# =============================================================================

set -o pipefail

# 版本不写死：默认 auto = 运行时向上游探测"存在 BSP 包的最高 L4T 版本"
L4T_VERSION="${L4T_VERSION:-}"   # 空 = 交互时让你选版本；非交互才回落 auto(最新可刷)
L4T_TAG="${L4T_TAG:-}"
BSP_FILENAME=""
ROOTFS_FILENAME=""
BSP_SIZE=""            # 空 = 不预判大小,下完用 bzip2 -t + TOFU 校验
ROOTFS_SIZE=""
BSP_SHA256=""          # 空 = 用本机 TOFU 清单(首次下载后记录),可用 --manifest-url 指外部清单

NV_REPO="https://repo.download.nvidia.com/jetson"
NV_DL_BASE="https://developer.nvidia.com/downloads/embedded"
SUITES="${JETSON_SUITES:-r35.4 r35.5 r35.6 r36.2 r36.3 r36.4 r36.5 r36.6}"   # 可配置,缺的自动跳过
MATRIX_TTL=604800      # 7 天缓存在 ~/.config/jetson-jp62/matrix.cache
MATRIX_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/jetson-jp62/matrix.cache"
MANIFEST_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/jetson-jp62/manifest.sha256"
MANIFEST_URL=""

DEFAULT_MIRROR=""
MIRRORS="${JETSON_MIRROR:-}"

# 支持 `bash <(curl -fsSL URL)` / `curl ... | bash` 这种一条命令运行：
# 这两种情况下脚本本体在 /dev/fd/N 或 stdin，拿它当工作目录会写不进去 → 退回当前目录
_self="${BASH_SOURCE[0]:-$0}"
case "$_self" in
    /dev/fd/*|/proc/*/fd/*|/dev/stdin|-|bash|"") SCRIPT_DIR="$(pwd)" ;;
    *) SCRIPT_DIR="$(cd "$(dirname "$_self")" 2>/dev/null && pwd)" ;;
esac
[ -n "$SCRIPT_DIR" ] && [ -w "$SCRIPT_DIR" ] || SCRIPT_DIR="$(pwd)"
WORK_DIR="${JETSON_DIR:-${SCRIPT_DIR}}"
CACHE_DIR="${JETSON_CACHE:-}"      # 下载包存放/复用目录；空 = 跟 WORK_DIR
BOARD="${JETSON_BOARD:-}"          # 留空 = 自动识别
CONFIG_FILE="${JETSON_CONFIG:-}"
AUTO_DIR=0
REFRESH=0
SPEC_FROM=""        # l4t | jp | auto(决定版本不满足时的处理方式)
UPDATE_FROM=""
OPEN_DOC=1          # 跑完是否提示/自动打开 HTML 说明页(0=关)
DOC_URL="${JETSON_DOC_URL:-}"
WARN_LOW=15                        # 余量低于此百分比时提示"冗余不足"
ROOTDEV=""
MODE=""
YES=0
DRY_RUN=0
OFFLINE_SRC=""
WITH_ROOTFS=0
SKIP_DEPS=0
ACCEPTED=0
RECOVERY_SKIP=0        # 1 = 不检查 recovery 直接刷
AGREE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/jetson-jp62"
AGREE_STAMP="$AGREE_DIR/agreed-v2"

C_R=$'\033[31m'; C_G=""; C_Y=$'\033[33m'; C_B=""; C_D=$'\033[2m'; C_N=$'\033[0m'
{ [ -t 1 ] && [ -z "${NO_COLOR+x}" ] && [ "${TERM:-}" != dumb ]; } || { C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_N=""; }

# ---------------- UI language: English by default; --lang / JETSON_JP62_LANG opt into zh ---
# Never infer from LC_ALL/LANG: a zh_CN locale on a non-UTF8 terminal is exactly
# what turns every message into mojibake.
UI_LANG="${JETSON_JP62_LANG:-en}"
case "$UI_LANG" in zh|en) ;; *) UI_LANG=en ;; esac
# T "中文" "English"  → 按当前界面语言取一条；两参数都必给，避免漏译时静默出错
T() { if [ "$UI_LANG" = en ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

# ---------------- 英文消息表：只覆盖固定文案（含变量的诊断明细仍为中文，便于与文档对照）----
declare -A EN_MSG=(
  ["recovery device 0955:7523 (Orin family, t234)"]="recovery device 0955:7523 (Orin family, t234)"
  ["主机架构 x86_64"]="host architecture x86_64"
  ["基础命令 curl/tar/bzip2/python3 齐全"]="base commands curl/tar/bzip2/python3 present"
  ["BSP 未解压(detect 模式不拦)"]="BSP not extracted (detect does not block)"
  ["BSP 未解压,本次会下载解压"]="BSP not extracted; it will be downloaded and extracted"
  ["rootfs 已 apply_binaries"]="rootfs already has apply_binaries applied"
  ["rootfs 未准备,本次会下 1.83G sample rootfs 并 apply_binaries"]="rootfs missing; this run downloads the 1.83G sample rootfs and applies binaries"
  ["读不到 USB 链路速率(不影响刷,但慢)"]="USB link speed unreadable (flashing still works, but slowly)"
  ["当前没有 recovery 设备(不致命:刷写前会等你短接,按回车一直刷新到检测到为止)"]="no recovery device yet (not fatal: before flashing you short the pins, press Enter to re-check)"
  ["sudo 可用(免密)"]="sudo available without a password"
  ["sudo 需要输入密码,运行时会提示你输入"]="sudo requires a password; you will be prompted when needed"
  ["extlinux 未指定自定义 FDT(用 UEFI 按 TNSPEC 自动选 dtb)"]="extlinux specifies no custom FDT (UEFI selects the dtb from TNSPEC)"
  ["检查项全部通过"]="all checks passed"
  ["用 --jetpack <版本> 或 --l4t <L4T版本>"]="use --jetpack <version> or --l4t <L4T version>"
  ["--mode 只能是 detect / qspi / nvme / prep / target(另有 --matrix / --self-update / --doc 三个动作)"]="--mode accepts detect / qspi / nvme / prep / target (plus the --matrix / --self-update / --doc actions)"
  ["跳过依赖安装(--no-deps)"]="skipping dependency install (--no-deps)"
  ["安装 NVIDIA 官方列出的主机依赖"]="installing the host dependencies listed by NVIDIA"
  ["依赖安装失败；可手工装好后加 --no-deps 重跑"]="dependency install failed; install them manually and rerun with --no-deps"
  ["基础依赖安装失败"]="base dependency install failed"
  ["主机依赖就绪"]="host dependencies ready"
  ["该源失败,换下一个"]="source failed, trying the next one"
  ["解压 BSP 失败"]="BSP extraction failed"
  ["rootfs 看起来已经 apply 过,跳过解压"]="rootfs looks already applied; skipping extraction"
  ["解压 sample rootfs"]="extracting the sample rootfs"
  ["解压 rootfs 失败"]="rootfs extraction failed"
  ["apply_binaries.sh 失败"]="apply_binaries.sh failed"
  ["rootfs 准备完成"]="rootfs ready"
  ["[dry-run] 跳过 recovery 检测"]="[dry-run] recovery check skipped"
  ["recovery 设备已就位"]="recovery device ready"
  ["按 --skip-recovery-check 跳过检测,直接刷(recovery 没进的话刷写必然失败)"]="use --skip-recovery-check to bypass the check (flashing will fail if the board is not in recovery)"
  ["没有检测到 recovery 设备,且当前不是交互终端(无法按键刷新)"]="no recovery device and no interactive terminal (cannot poll by keypress)"
  ["请在终端里重跑本命令,或先在别的终端把板子切到 recovery 再回来"]="rerun this command in a terminal, or switch the board to recovery from another terminal first"
  ["输入结束,放弃"]="input closed; aborting"
  ["已退出(板子没进 recovery)"]="exited (board never entered recovery)"
  ["跳过 recovery 检测,直接进入刷写(失败请回来重跑)"]="recovery check skipped, flashing starts (rerun if it fails)"
  ["还是没进 recovery.常见原因:没在断电状态下保持短接就上电 / 短错脚位 / USB 线只充电不传数据"]="still no recovery. Usual causes: pins not held while powering on / wrong pins / charge-only USB cable"
  ["弄好后继续按 [回车] 刷新,我这边一直等着"]="press Enter to re-check once the board is ready; this side keeps waiting"
  ["已取消"]="cancelled"
  ["no Board ID line in the flash log; cannot cross-check the board model"]="no Board ID line in the flash log; cannot cross-check the board"
  ["缺 flash.sh,先跑 --mode prep"]="flash.sh missing; run --mode prep first"
  ["没有进入 recovery,已放弃本次刷写(板子就绪后重跑同一条命令即可)"]="board never entered recovery; flashing abandoned (rerun the same command once it is ready)"
  ["[dry-run] 到此为止,不执行"]="[dry-run] stopping here, nothing executed"
  ["QSPI flash完成"]="QSPI flash complete"
  ["缺 l4t_initrd_flash.sh(先 --mode prep --with-rootfs)"]="l4t_initrd_flash.sh missing (run --mode prep --with-rootfs first)"
  ["rootfs 未准备:先 --mode prep --with-rootfs"]="rootfs not prepared: run --mode prep --with-rootfs first"
  ["整机刷写完成(用户名/密码在首启创建,可用 tools/l4t_create_default_user.sh 预置)"]="full flash complete (user/password are created on first boot; tools/l4t_create_default_user.sh can preset them)"
  ["[dry-run] 把 nvidia-l4t-apt-source.list 里的 r36.x 改成 r36.4 后 apt dist-upgrade"]="[dry-run] change r36.x to r36.4 in nvidia-l4t-apt-source.list, then apt dist-upgrade"
  ["这条会升级板上 BSP 包:TensorRT 8.x->10.x,cuDNN 8.x->9.x,自编 engine 需重建"]="this upgrades onboard BSP packages: TensorRT 8.x->10.x, cuDNN 8.x->9.x; self-built engines must be rebuilt"
  ["dist-upgrade 有报错,继续尝试修复"]="dist-upgrade reported errors; attempting repair"
  ["完成,物理重启后 nvbootctrl dump-slots-info 应显示 36.4.x"]="done; after a physical reboot nvbootctrl dump-slots-info should show 36.4.x"
  ["模式:板内诊断(系统已启动)"]="mode: onboard diagnostics (system booted)"
  ["CSI 相机(i2c 9/10) 探测失败 -> 相机排线/供电/设备树,与刷机无关"]="CSI camera (i2c 9/10) probe failed -> camera cable/power/device tree; unrelated to flashing"
  ["fusb301(USB-C PD) 读不到 ID -> 载板没这颗器件或板型号不匹配"]="fusb301 (USB-C PD) ID unreadable -> carrier lacks the part or the board model does not match"
  ["注意:这一层能看内核/系统报错,但看不到 UEFI 与 DDR 训练的日志"]="note: this layer shows kernel/system errors but not UEFI or DDR training logs"
  ["缺 Linux_for_Tegra/bootloader 工具,先跑 --mode prep(只下载解压即可)"]="Linux_for_Tegra/bootloader tools missing; run --mode prep (download and extract only)"
  ["模式:recovery 诊断(板子未启动)"]="mode: recovery diagnostics (board not booted)"
  ["recovery mode shows no kernel/UEFI runtime log, nor DDR training or power issues"]="recovery mode exposes no kernel/UEFI runtime log, nor DDR training or power issues"
  ["既不在板内(无 /etc/nv_tegra_release),也没有 recovery 设备"]="neither onboard (no /etc/nv_tegra_release) nor in recovery"
  ["把板子接上:正常启动 -> 本机可 ssh,脚本走板内诊断；未启动 -> 短接进 recovery 走 EEPROM/BCT 诊断"]="connect the board: normal boot -> ssh in and run onboard diagnostics; not booted -> short the pins and run EEPROM/BCT diagnostics"
  ["stty 设置失败(可能不是 TTY),继续尝试读取"]="stty failed (possibly not a TTY); still trying to read"
  ["可用串口设备:"]="available serial devices:"
  ["没检测到串口.接线(Orin Nano DevKit 40-pin):Pin 6=GND,Pin 8=UART1_TX,Pin 10=UART1_RX,115200 8N1"]="no serial device found. Wiring (Orin Nano DevKit 40-pin): Pin 6=GND, Pin 8=UART1_TX, Pin 10=UART1_RX, 115200 8N1"
  ["接好后重跑:--mode uart --uart /dev/ttyUSB0 --uart-seconds 60"]="once wired, rerun: --mode uart --uart /dev/ttyUSB0 --uart-seconds 60"
  ["to analyse an existing log: --mode uart --uart-log boot.log"]="to analyse an existing log: --mode uart --uart-log boot.log"
  ["运行在 Jetson 本机(板内识别最准)"]="running on the Jetson itself (most accurate identification)"
  ["主机端看到 recovery 设备(板子型号需刷写时由 EEPROM 读出)"]="recovery device visible from the host (model is read from EEPROM during flashing)"
  ["既不在板内,也没有 recovery 设备(板子没连,或没进 recovery)"]="neither onboard nor in recovery (board not connected, or not in recovery)"
  ["当前板子不是 super 版；要 Super 必须先刷 QSPI 到 36.4,再 nvpmodel 切 MAXN_SUPER"]="this board is not the Super variant; for Super you must flash QSPI to 36.4, then switch nvpmodel to MAXN_SUPER"
  ["取不到可用版本列表,回落 auto"]="available versions unavailable; falling back to auto"
  ["探测不到上游版本(代理/网络？)-> 使用内置兜底清单(可能不是最新)"]="upstream unreachable (proxy/network?) -> using the built-in fallback list (may not be the newest)"
  ["有网后跑 --refresh 重新探测；下载失败时用 --mirror 指向内网源"]="rerun --refresh once online; if downloads fail, point --mirror at an internal source"
  ["矩阵缓存里没有可用版本(上次探测失败？)-> 重取一次"]="matrix cache holds no usable version (last probe failed?) -> probing once more"
  ["离线兜底模式:跳过版本存在性探测,直接尝试下载"]="offline fallback: skipping the version probe and trying the download directly"
  ["已退出"]="exited"
  ["请输入序号或版本号"]="enter an index or a version"
  ["序号超出范围"]="index out of range"
  ["换个版本:--l4t <版本>,或 --l4t latest 自动挑最新的"]="pick another version: --l4t <version>, or --l4t latest to take the newest"
  ["文件不在,跳过校验"]="file absent; verification skipped"
  ["没给更新源:--update-from <url|路径>,或配 JETSON_SCRIPT_URL"]="no update source: --update-from <url|path>, or set JETSON_SCRIPT_URL"
  ["新版本语法检查没过,放弃更新"]="new version failed the syntax check; update abandoned"
  ["已经是当前最新版(sha256 相同)"]="already the current version (identical sha256)"
  ["新版本说明(头部 12 行):"]="new version notes (first 12 lines):"
  ["没找到 index.html(应与脚本同目录),也没配 --doc-url；跳过"]="no index.html (expected next to the script) and no --doc-url; skipping"
  ["非交互环境,版本回落 auto(最新可刷)"]="non-interactive; version falls back to auto (newest flashable)"
  ["板内体检通过.板内只能 --mode target(升计算栈)；要刷 QSPI/整机请接 x86_64 主机"]="onboard check passed. Only --mode target (compute stack) works onboard; use an x86_64 host to flash QSPI or the whole system"
  ["主机侧体检通过.板子进 recovery 后:--mode qspi(写入启动固件)或 --mode nvme(整机重刷)"]="host check passed. Once the board is in recovery: --mode qspi (boot firmware) or --mode nvme (full reflash)"
  ["全部完成"]="all done"
)
en_msg() {  # 中文原文 -> 英文；没有映射时原样返回
    [ "$UI_LANG" = en ] || { printf '%s' "$1"; return; }
    local v="${EN_MSG[$1]:-}"
    printf '%s' "${v:-$1}"
}
log()  { printf '%s[%s]%s %s\n' "$C_B" "$(T 信息 info)" "$C_N" "$(en_msg "$*")"; }
ok()   { printf '%s[%s]%s %s\n' "$C_G" "$(T 完成 done)" "$C_N" "$(en_msg "$*")"; }
warn() { printf '%s[%s]%s %s\n' "$C_Y" "$(T 注意 warn)" "$C_N" "$(en_msg "$*")"; }
die()  { printf '%s[%s]%s %s\n' "$C_R" "$(T 错误 error)" "$C_N" "$(en_msg "$*")" >&2; exit 1; }

FAILS=0
chk_ok()   { printf '  %s[ ok ]%s %s\n' "$C_G" "$C_N" "$(en_msg "$*")"; }
chk_bad()  { printf '  %s[ xx ]%s %s\n' "$C_R" "$C_N" "$1"; [ -n "${2:-}" ] && printf '        %s%s: %s%s\n' "$C_D" "$(T 修法 fix)" "$2" "$C_N"; FAILS=$((FAILS+1)); }
chk_warn() { printf '  %s[ ! ]%s %s\n' "$C_Y" "$C_N" "$(en_msg "$*")"; }
chk_info() { printf '  %s[ - ]%s %s\n' "$C_D" "$C_N" "$(en_msg "$*")"; }

banner() {
cat <<'ART'

                   ,----,
                 .'   .' \
               ,----,'    |
               |    :  .  ;   .---.
   ,--.--.     ;    |.'  /  /.  ./|  ,---.     ,---.
  /       \    `----'/  ; .-' . ' | /     \   /     \
 .--.  .-. |     /  ;  / /___/ \: |/    /  | /    / '
  \__\/: . .    ;  /  /-,.   \  ' .    ' / |.    ' /
  ," .--.; |   /  /  /.`| \   \   '   ;   /|'   ; :__
 /  /  ,.  | ./__;      :  \   \  '   |  / |'   | '.'|
;  :   .'   \|   :    .'    \   \ |   :    ||   :    :
|  ,     .-./;   | .'        '---" \   \  /  \   \  /
 `--`---'    `---'                  `----'    `----'
ART
    printf '  %sA2VEC%s | FIELD TOOLS / JETSON | jetson-jp62.sh\n' "$C_B" "$C_N"
    printf '  %s\n' "----------------------------------------------------------------"
    printf '  %s\n' "$(T "Jetson 固件维护(QSPI / NVMe / 诊断)" "Jetson firmware maintenance (QSPI / NVMe / diagnostics)")"
    printf '  L4T: %s  |  %s: %s\n' "${L4T_VERSION:-$(T 待选择 to-select)}" "$(T 模式 mode)" "${MODE:-$(T 交互菜单 interactive-menu)}"
    printf '  %s\n' "$(T "独立维护工具 . MIT License . 非 NVIDIA 官方产品" "Independent tool . MIT License . not an NVIDIA product")"
    printf '\n'
}

# ============================================================ 协议与安全声明
agreement_text_en() {
cat <<EOF
Statement of use / version 2
--------------------------------------------------------------

1. Tool and licence
   An independent A2VEC maintenance tool. Script and documentation are
   provided under the MIT License.
   Copyright (c) 2026 Shippuurl. Redistributions must keep the copyright
   and licence notice.
   Licence text: https://github.com/Shippuurl/jetson-jp62/blob/main/LICENSE
   This tool has no affiliation with or endorsement by NVIDIA. NVIDIA,
   Jetson and JetPack are trademarks of NVIDIA Corporation.

2. Third-party components
   The published script contains no NVIDIA firmware or proprietary SDK.
   Components downloaded at runtime are governed by their own licences.
   Check those licences before downloading, using or redistributing.
   Accepting this statement does not replace third-party licence terms.

3. Operational risk
   The NVMe mode rewrites the target storage and erases data. The QSPI mode
   writes boot firmware; it does not target the system disk, but faulty
   firmware or a power loss can leave the board unbootable. Confirm that you
   are authorised to service the device, and that you have backups, stable
   power and a recovery path. Third-party carrier boards must use the
   vendor's adaptation files. Package upgrades may require rebuilding
   applications and models. A reachable download, a version probe or a
   passing pre-check is not a guarantee of compatibility or success.

4. Warranty and liability
   The software is provided AS IS. To the maximum extent permitted by
   applicable law no express or implied warranty is given; liability of the
   authors and copyright holders is limited as stated in the MIT text. This
   statement does not exclude or limit liability that applicable law does
   not allow to be excluded or limited.

Reference: NVIDIA Jetson Linux R36.4.3 / Flashing Support
https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/FlashingSupport.html
For other versions consult the matching documentation.

EOF
}

agreement_text() { if [ "$UI_LANG" = en ]; then agreement_text_en; else agreement_text_zh; fi; }

agreement_text_zh() {
cat <<EOF
USAGE NOTICE / revision 2
--------------------------------------------------------------

1. Tool and licence
   A2VEC is an independent maintenance tool, provided under the MIT License.
   Copyright (c) 2026 Shippuurl. Redistributions must keep this notice.
   Licence text: https://github.com/Shippuurl/jetson-jp62/blob/main/LICENSE
   This tool is not affiliated with or endorsed by NVIDIA. NVIDIA, Jetson and
   JetPack are trademarks of NVIDIA Corporation.

2. Third-party components
   Public releases contain no NVIDIA firmware or proprietary SDK. Components
   downloaded at runtime are bound by their own licences; check them before
   downloading, using or redistributing. Accepting this notice does not replace
   any third-party licence requirement.

3. Operational risk
   NVMe mode rewrites the target storage and erases data. QSPI mode writes boot
   firmware and does not target the system disk, but wrong firmware or power loss
   can make the device unbootable. Confirm permissions, backups, stable power and
   a recovery path. Third-party carrier boards need the vendor's config. Package
   upgrades may require rebuilding applications and models. A working download,
   version probe or pre-flight check is not a compatibility or success guarantee.

4. Warranty and liability
   The software is provided AS IS. To the maximum extent permitted by law there
   is no express or implied warranty; the authors' and copyright holders' limits
   follow the MIT text. Nothing here excludes liability that law does not allow
   to be excluded.

Reference: NVIDIA Jetson Linux R36.4.3 / Flashing Support
https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/FlashingSupport.html
See the matching documentation for other releases.

EOF
}

ensure_agreement() {
    [ "$ACCEPTED" = 1 ] && return 0
    [ -f "$AGREE_STAMP" ] && return 0
    banner
    agreement_text
    if [ "$YES" = 1 ]; then
        warn "$(T "--yes 已给出,视为agree上述协议" "--yes supplied; treated as agreement")"
    else
        printf '%s' "$(T "输入 agree 继续(其他任何输入则退出): " "Type agree to continue (anything else exits): ")"
        local a; read -r a
        [ "$a" = "agree" ] || [ "$a" = "agree" ] || { log "$(T "未agree协议,退出" "Agreement not accepted; exiting")"; exit 0; }
    fi
    mkdir -p "$AGREE_DIR" 2>/dev/null && date -Is > "$AGREE_STAMP" 2>/dev/null
    ok "consent recorded ($AGREE_STAMP); delete that file to show the agreement again"
}

# ================================================================ 板子识别
DET_MODE=""        # onboard | recovery | none
DET_TNSPEC=""
DET_MODULE=""
DET_BOARD_SUGGEST=""
DET_L4T=""
DET_UEFI=""
DET_SUPER="no"
DET_STORAGE=""
DET_ROOTDEV_SUGGEST=""
DET_IS_SUPER_MODEL="no"

detect_onboard() {
    # 只有在本机就是 Jetson 时才成立
    [ -r /etc/nv_tegra_release ] || return 1
    DET_MODE="onboard"
    DET_L4T="$(sed -nE 's/^# ?R([0-9]+).*REVISION:? *([0-9]+\.[0-9]+).*/R\1.\2/p' /etc/nv_tegra_release 2>/dev/null | head -1)"
    [ -n "$DET_L4T" ] || DET_L4T="$(grep -oE 'R[0-9]+' /etc/nv_tegra_release | head -1)"
    if [ -r /etc/nv_boot_control.conf ]; then
        DET_TNSPEC="$(awk '/^TNSPEC/{print $2}' /etc/nv_boot_control.conf)"
        DET_STORAGE="$(awk '/^TEGRA_BOOT_STORAGE/{print $2}' /etc/nv_boot_control.conf)"
    fi
    case "$DET_TNSPEC" in
        *orin-nano-devkit-super*) DET_BOARD_SUGGEST="jetson-orin-nano-devkit-super"; DET_SUPER="yes"; DET_IS_SUPER_MODEL="yes" ;;
        *orin-nano-devkit*)       DET_BOARD_SUGGEST="jetson-orin-nano-devkit" ;;
        *orin-nx-devkit*)         DET_BOARD_SUGGEST="jetson-orin-nx-devkit" ;;
        *agx-orin-devkit*)        DET_BOARD_SUGGEST="jetson-agx-orin-devkit" ;;
    esac
    DET_MODULE="$(printf '%s' "$DET_TNSPEC" | cut -d- -f1)"
    case "$DET_STORAGE" in
        nvme*)   DET_ROOTDEV_SUGGEST="nvme0n1p1" ;;
        mmcblk1*) DET_ROOTDEV_SUGGEST="mmcblk1p1" ;;
        mmcblk0*) DET_ROOTDEV_SUGGEST="mmcblk0p1" ;;
    esac
    if command -v nvpmodel >/dev/null 2>&1; then
        local m; m="$(nvpmodel -q 2>/dev/null | head -1)"
        case "$m" in *SUPER*) DET_SUPER="yes" ;; esac
    fi
    if command -v nvbootctrl >/dev/null 2>&1; then
        DET_UEFI="$(sudo -n nvbootctrl dump-slots-info 2>/dev/null | awk -F': ' '/Current version/{print $2}')"
    fi
    return 0
}

detect_recovery() {
    local out
    out="$(lsusb 2>/dev/null | grep -iE "0955:" || true)"
    [ -n "$out" ] || return 1
    DET_MODE="recovery"
    local pid; pid="$(printf '%s' "$out" | grep -oiE "0955:[0-9a-f]{4}" | head -1 | cut -d: -f2)"
    DET_MODULE="recovery:$pid"
    case "$pid" in
        7523) DET_BOARD_SUGGEST=""; chk_info "recovery device 0955:7523 (Orin family, t234)" ;;
        *)    chk_warn "recovery device 0955:$pid (unusual for t234; treated as Orin)" ;;
    esac
    return 0
}

usb_speed() {
    local d sp
    for d in /sys/bus/usb/devices/*/idVendor; do
        [ -r "$d" ] || continue
        [ "$(cat "$d")" = "0955" ] || continue
        sp="$(cat "$(dirname "$d")/speed" 2>/dev/null)"
        [ -n "$sp" ] && { printf '%s' "$sp"; return 0; }
    done
    return 1
}

pick_board() {
    if [ -n "$BOARD" ]; then
        log "board model from --board: $BOARD"
    elif [ -n "$DET_BOARD_SUGGEST" ]; then
        BOARD="$DET_BOARD_SUGGEST"
        log "auto-detected board model: $BOARD"
    else
        BOARD="jetson-orin-nano-devkit-super"
        warn "cannot auto-detect the board; using default $BOARD (override with --board; --list-boards lists all)"
    fi
    case "$DET_STORAGE" in
        nvme*) [ -f "$WORK_DIR/Linux_for_Tegra/${BOARD}-nvme.conf" ] && BOARD="${BOARD}-nvme" ;;
    esac
    [ -n "$ROOTDEV" ] || ROOTDEV="${DET_ROOTDEV_SUGGEST:-nvme0n1p1}"
}

# ================================================================ 门槛检查
# ---------------------------------------------------------- 磁盘与空间估算
free_mb()  { df -Pk "$1" 2>/dev/null | awk 'NR==2{printf "%d", $4/1024}'; }
free_gb()  { local m; m="$(free_mb "$1")"; printf '%d' $(( ${m:-0} / 1024 )); }
used_pct() { df -Pk "$1" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}'; }
fs_type()  { df -PT "$1" 2>/dev/null | awk 'NR==2{print $2}'; }
fs_dev()   { df -PT "$1" 2>/dev/null | awk 'NR==2{print $1}'; }
mb2g()     { local m="$1"; if [ "$m" -ge 1024 ] 2>/dev/null; then printf '%.1fG' "$(awk -v m="$m" 'BEGIN{print m/1024}')"; else printf '%dM' "$m"; fi; }

# 各阶段真实占用（MB）：下载包 / 解压膨胀 / apply_binaries / 刷机临时镜像
SPACE_DL_BSP=683; SPACE_DL_ROOTFS=1743
SPACE_EX_BSP=790; SPACE_EX_ROOTFS=3200; SPACE_APPLY=900
SPACE_FLASH_TMP=4000; SPACE_LOG=200; SPACE_SLACK=1200

space_plan() {
    # 输出三行：下载所需 解压所需 合计（MB）
    local mode="$1" dl=0 ex=0 tmp=0
    local have_bsp=0 have_rfs=0
    [ -s "${CACHE_DIR:-$WORK_DIR}/$BSP_FILENAME" ] && have_bsp=1
    [ -s "${CACHE_DIR:-$WORK_DIR}/$ROOTFS_FILENAME" ] && have_rfs=1
    case "$mode" in
        qspi) dl=$((SPACE_DL_BSP+SPACE_DL_ROOTFS)); ex=$((SPACE_EX_BSP+SPACE_EX_ROOTFS+SPACE_APPLY))
              tmp=800 ;;   # QSPI only:不生成 system.img,但要拼 recovery ramdisk
        prep) dl=$SPACE_DL_BSP; ex=$SPACE_EX_BSP
              [ "$WITH_ROOTFS" = 1 ] && { dl=$((dl+SPACE_DL_ROOTFS)); ex=$((ex+SPACE_EX_ROOTFS+SPACE_APPLY)); } ;;
        nvme) dl=$((SPACE_DL_BSP+SPACE_DL_ROOTFS)); ex=$((SPACE_EX_BSP+SPACE_EX_ROOTFS+SPACE_APPLY)); tmp=$SPACE_FLASH_TMP ;;
        target) dl=0; ex=0; tmp=0 ;;
        *) dl=0; ex=0 ;;
    esac
    [ "$have_bsp" = 1 ] && dl=$((dl-SPACE_DL_BSP))
    [ "$have_rfs" = 1 ] && dl=$((dl-SPACE_DL_ROOTFS))
    [ "$dl" -lt 0 ] && dl=0
    printf '%d %d %d %d\n' "$dl" "$ex" $((dl+ex+tmp+SPACE_LOG+SPACE_SLACK)) "$tmp" 
}

# 列出可用的其它挂载点（真实块设备、可写、余量够）
hash_mounts() {
    local need_mb="$1"
    df -PT -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1{print $1"|"$2"|"$7}' | \
    while IFS='|' read -r dev fstype mnt; do
        case "$dev" in /dev/*) ;; *) continue ;; esac
        [ -w "$mnt" ] || continue
        local fm; fm="$(free_mb "$mnt")"
        [ "${fm:-0}" -ge "$need_mb" ] || continue
        printf '% 6s  %-8s %s\n' "$(mb2g "$fm")" "$fstype" "$mnt"
    done | sort -r | head -6
}

auto_pick_dir() {
    local need_mb="$1" best="" bestfree=0 mnt fm
    df -PT -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1{print $1"|"$7}' | \
    while IFS='|' read -r dev mnt; do
        case "$dev" in /dev/*) ;; *) continue ;; esac
        [ -w "$mnt" ] || continue
        fm="$(free_mb "$mnt")"; [ "${fm:-0}" -ge "$need_mb" ] || continue
        printf '%s %s\n' "$fm" "$mnt"
    done | sort -rn | head -1 | while read -r fm mnt; do
        printf '%s|%s\n' "$fm" "$mnt"
    done
}

# 空间总检：下载 / 解压 分两个目录算，文件系统类型也对（exFAT/NTFS 会毁掉 rootfs 权限）
check_disk() {
    local mode="$1"
    local plan dl ex total tmp
    plan="$(space_plan "$mode")"
    dl="$(echo "$plan" | cut -d' ' -f1)"
    ex="$(echo "$plan" | cut -d' ' -f2)"
    total="$(echo "$plan" | cut -d' ' -f3)"
    tmp="$(echo "$plan" | cut -d' ' -f4)"; [ -n "$tmp" ] || tmp=$SPACE_FLASH_TMP
    local cache="${CACHE_DIR:-$WORK_DIR}"
    mkdir -p "$cache" 2>/dev/null; mkdir -p "$WORK_DIR" 2>/dev/null

    if [ "$mode" = "target" ]; then
        local fm; fm="$(free_mb /)"; local pct; pct="$(used_pct /)"
        if [ "${fm:-0}" -ge "$((9*1024))" ] && [ "${pct:-0}" -lt 90 ]; then
            chk_ok "system disk / free $(mb2g "${fm:-0}") (${pct}% used), enough for apt dist-upgrade"
        else
            chk_bad "system disk / free $(mb2g "${fm:-0}"), ${pct}% used; apt upgrade needs >=9G" "sudo apt clean; sudo journalctl --vacuum-size=200M; remove old kernels"
        fi
        return 0
    fi

    local fcache fwork pctc pctw totalg
    fcache="$(free_mb "$cache")"; fwork="$(free_mb "$WORK_DIR")"
    pctc="$(used_pct "$cache")"; pctw="$(used_pct "$WORK_DIR")"
    totalg="$(mb2g "$total")"

    local dl_pct=$(( pctc + 0 ))
    case "$(fs_type "$cache")" in
        ext2|ext3|ext4|xfs|btrfs|zfs) chk_ok "download dir $cache: $(fs_type "$cache"), preserves permissions and symlinks" ;;
        *) chk_bad "download dir $cache is $(fs_type "$cache")" "NTFS/exFAT/vfat loses permissions and symlinks for rootfs; use ext4/xfs/btrfs" ;;
    esac
    case "$(fs_type "$WORK_DIR")" in
        ext2|ext3|ext4|xfs|btrfs|zfs|overlay) chk_ok "work dir $WORK_DIR: $(fs_type "$WORK_DIR")" ;;
        *) chk_bad "work dir $WORK_DIR is $(fs_type "$WORK_DIR")" "use an ext4/xfs/btrfs partition (--dir)" ;;
    esac

    if [ "$cache" = "$WORK_DIR" ]; then
        local need_total=$(( total ))
        if [ "$fwork" -ge "$need_total" ]; then
            chk_ok "work dir $WORK_DIR free $(mb2g "$fwork") (${pctw}% used); this mode peaks at ~$totalg, margin $(mb2g $((fwork-need_total)))"
            [ "$pctw" -lt 85 ] || chk_warn "this partition is ${pctw}% full; writing logs/images mid-flash may fail"
        else
            chk_bad "work dir has only $(mb2g "$fwork"); this mode needs $totalg peak (download $(mb2g $dl) + extract $(mb2g $ex) + temp)" \
                    "switch disk: $(pick_hint "$total"), or add --auto-dir"
        fi
    else
        if [ "$fcache" -ge "$dl" ]; then chk_ok "download dir $cache free $(mb2g "$fcache") (${pctc}% used); must hold $(mb2g $dl)"
        else chk_bad "download dir has only $(mb2g "$fcache"); needs $(mb2g $dl)" "point --cache-dir at a bigger disk, or add --auto-dir"; fi
        if [ "$fwork" -ge "$((ex+tmp+SPACE_LOG+SPACE_SLACK))" ]; then
            chk_ok "work dir $WORK_DIR free $(mb2g "$fwork"); extract + temp about $(mb2g $((ex+tmp+SPACE_LOG)))"
        else
            chk_bad "work dir has only $(mb2g "$fwork"); extract + temp needs $(mb2g $((ex+tmp+SPACE_LOG)))" \
                    "switch disk: $(pick_hint "$total"), or add --auto-dir"
        fi
    fi
}

pick_hint() {
    local need_mb="$1" out
    out="$(hash_mounts "$need_mb")"
    if [ -n "$out" ]; then
        printf 'candidate mount points %s' "$(printf '%s' "$out" | awk '{print $3}' | tr '\n' ' ')"
    else
        printf 'no other partition with enough free space; clean up or attach a disk'
    fi
}

check_requirements() {
    local mode="$1" lt="$WORK_DIR/Linux_for_Tegra"
    FAILS=0
    echo
    printf '%s-- pre-flight checks (%s mode) --%s\n' "$C_B" "$mode" "$C_N"

    # 1 运行位置 / 主机架构
    local arch; arch="$(uname -m)"
    if [ "$DET_MODE" = "onboard" ]; then
        chk_ok "running on the Jetson itself ($arch); onboard detection is valid"
        [ "$mode" = "qspi" ] || [ "$mode" = "nvme" ] && \
            chk_bad "a Jetson cannot flash itself ($arch)" "short FC REC, connect to an x86_64 host, and run the same command there"
    elif [ "$mode" != "target" ]; then
        [ "$arch" = "x86_64" ] && chk_ok "host architecture x86_64" || chk_bad "host architecture $arch is not x86_64" "flashing needs an x86_64 host; on the Jetson itself use --mode target"
    fi

    # 2 系统版本（只提示，不拦）
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        case "${VERSION_ID:-}" in
            20.04|22.04) chk_ok "host OS ${PRETTY_NAME} (NVIDIA-supported)" ;;
            24.04|24.10|25.*) chk_warn "host OS ${PRETTY_NAME}: NVIDIA documents 20.04/22.04, dependencies check out here, treating as supported" ;;
            *) chk_warn "host OS ${PRETTY_NAME}: untested; use --no-deps if dependencies are missing" ;;
        esac
    fi

    # 3 基础命令
    local miss=() p
    for p in curl tar bzip2 python3; do command -v "$p" >/dev/null 2>&1 || miss+=("$p"); done
    [ ${#miss[@]} -eq 0 ] && chk_ok "base commands curl/tar/bzip2/python3 present" || chk_bad "missing commands: ${miss[*]}" "sudo apt install ${miss[*]}"

    # 4 磁盘冗余（下载目录 + 工作目录分开算，含文件系统类型）
    check_disk "$mode"

    # 5 BSP 是否就位且版本对
    if [ -f "$lt/nv_tegra/bsp_version" ]; then
        local have; have="$(awk -F= '/^BSP_BRANCH=/{b=$2}/^BSP_MAJOR=/{m=$2}/^BSP_MINOR=/{n=$2}END{print b"."m"."n}' "$lt/nv_tegra/bsp_version")"
        if [ "$have" = "$L4T_VERSION" ]; then
            chk_ok "BSP already extracted, version ${have}"
        elif [ "$mode" = "detect" ]; then
            chk_warn "existing BSP is ${have}, target ${L4T_VERSION} (not fatal here; a real flash backs up the old dir first)"
        else
            chk_bad "existing BSP is ${have}, target ${L4T_VERSION}" "remove the old dir or use --dir; the script backs up before re-extracting"
        fi
    else
        [ "$mode" = "detect" ] && chk_info "BSP not extracted (detect does not block)" || chk_info "BSP not extracted; it will be downloaded and extracted"
    fi

    # 6 板型配置是否存在
    if [ -d "$lt" ]; then
        [ -f "$lt/${BOARD}.conf" ] && chk_ok "board config present: ${BOARD}.conf" \
            || chk_bad "no ${BOARD}.conf in the BSP" "see --list-boards for available models, then pass --board"
    fi

    # 7 rootfs（qspi 也要：36.x 的 flash.sh 会用 rootfs 生成 recovery ramdisk，
    #   根文件系统本身不会被写到板子上）
    if [ "$mode" = "nvme" ] || [ "$mode" = "qspi" ]; then
        if [ -f "$lt/rootfs/etc/nv_tegra_release" ]; then chk_ok "rootfs already has apply_binaries applied"
        else chk_info "rootfs missing; this run downloads the 1.83G sample rootfs and applies binaries"; fi
    fi

    # 8 recovery 设备 + USB 链路
    if [ "$mode" = "qspi" ] || [ "$mode" = "nvme" ]; then
        if lsusb 2>/dev/null | grep -qiE "0955:7(523|22)"; then
            chk_ok "recovery device detected (0955:$(lsusb | grep -oiE '0955:[0-9a-f]{4}' | head -1 | cut -d: -f2))"
            local sp; sp="$(usb_speed || echo '')"
            case "$sp" in
                5000*|10000*) chk_ok "USB link ${sp} Mbps" ;;
                "") chk_warn "USB link speed unreadable (flashing still works, but slowly)" ;;
                *) chk_warn "USB link ${sp} Mbps (USB2; flashing will be slow, prefer a USB3 port/cable)" ;;
            esac
        else
            chk_warn "no recovery device yet (not fatal: before flashing you short the pins, press Enter to re-check)"
        fi
    fi

    # 9 提权
    if [ "$mode" = "qspi" ] || [ "$mode" = "nvme" ] || [ "$mode" = "target" ]; then
        if [ "$(id -u)" = 0 ] || sudo -n true 2>/dev/null; then chk_ok "sudo available without a password"
        else chk_warn "sudo requires a password; you will be prompted when needed"; fi
    fi

    # 10 板内专属检查
    if [ "$DET_MODE" = "onboard" ]; then
        chk_info "onboard: TNSPEC=${DET_TNSPEC:-unknown} L4T=${DET_L4T:-unknown} Super=${DET_SUPER} boot=${DET_STORAGE:-unknown}"
        local fdt; fdt="$(grep -hiE '^[[:space:]]*(FDT|DEVICETREE)[[:space:]]' /boot/extlinux/extlinux.conf 2>/dev/null | awk '{print $NF}' | head -2 | tr '\n' ' ')"
        if [ -z "$fdt" ]; then
            chk_ok "extlinux specifies no custom FDT (UEFI selects the dtb from TNSPEC)"
        elif printf '%s' "$fdt" | grep -qE 'kernel_tegra234-p(3767|3768)' ; then
            chk_ok "extlinux dtb is in NVIDIA's official dir ($(basename "$fdt"))"
        else
            chk_warn "extlinux points at a non-official dtb ($fdt); back up /boot and vendor patches before flashing QSPI"
        fi
        local uefi_target_major; uefi_target_major="$(printf '%s' "$L4T_VERSION" | cut -d. -f1-2)"
        if [ -n "$DET_UEFI" ]; then
            case "$DET_UEFI" in
                "$uefi_target_major".*) chk_ok "QSPI/UEFI already ${DET_UEFI} (same generation as target ${L4T_VERSION}; no QSPI flash needed)" ;;
                *) chk_warn "QSPI/UEFI is ${DET_UEFI}, target ${L4T_VERSION} -> flash QSPI to get Super/new bootloader" ;;
            esac
        fi
        if [ "$mode" = "target" ]; then
            local f; f="$(free_gb /)"
            if [ "$f" -ge 8 ]; then chk_ok "system disk free ${f}G"
            else chk_bad "system disk has only ${f}G; apt dist-upgrade needs >=8G" "first clear /var/cache/apt and old kernels"; fi
        fi
    fi

    echo
    if [ "$FAILS" -gt 0 ]; then
        die "${FAILS} check(s) failed; apply the suggested fixes above and rerun (checks change nothing)"
    fi
    ok "all checks passed"
    echo
}

# ================================================================ 参数/工具
usage_en() {
cat <<EOF
A2VEC / Jetson firmware maintenance tool
MIT License . not an NVIDIA product

usage: bash jetson-jp62.sh [options]

common:
  bash jetson-jp62.sh                          interactive menu
  bash jetson-jp62.sh --mode detect            pre-flight checks
  bash jetson-jp62.sh --mode qspi --l4t 36.4.3 flash QSPI for a given release

risk: nvme rewrites the target storage; qspi writes boot firmware. Back up and
verify the board model first. Version examples are not compatibility advice; a
download URL existing does not mean it fits your hardware.

options:

  --mode <detect|qspi|nvme|prep|target>  run mode (menu when omitted)
  --board <name>                  force a board config (auto by default; --list-boards)
  --dir <path>                    work dir (default: script dir / \$JETSON_DIR)
  --mirror <src[,src2...]>        download source: http/https/file:// or a local dir
  --offline --src <dir>           fully offline: take tbz2 from a local dir
  --with-rootfs                   prep also fetches the sample rootfs
  --rootdev <dev>                 rootdev for flash.sh (inferred from boot disk)
  --skip-recovery-check           skip the recovery check (may make the flash fail)
  --no-deps                       do not apt-install host dependencies
  --accept                        skip the agreement prompt (same as agreeing)
  --yes                           auto-confirm the notice and later prompts
  --cache-dir <path>              package cache (= --resource; defaults to --dir disk)
  --auto-dir                      pick the partition with the most free space
  --config <file>                 read config (default ~/.config/jetson-jp62/config)
  --l4t <version|latest>          target L4T (menu when omitted; auto when non-interactive)
  --jetpack|--jp <version>        map a JetPack number to L4T (6.2->36.4.3, 6.2.2->36.5.0...)
  --jp-list                       print the JetPack -> L4T table
  --diag                          diagnostics: onboard kernel/system, recovery EEPROM/BCT
  --uart [dev]                    capture BootROM/UEFI/DDR boot log and classify it
  --uart-out <file>               write the capture to a path
  --uart-log <file>               analyse an existing serial log offline
  --uart-baud <baud>              default 115200
  --uart-seconds <sec>            capture length, default 30
  --uart-list                     list serial devices
  --doc                           open the docs page (index.html)
  --doc-url <url>                 online docs URL (when no local index.html)
  --no-doc                        do not offer the docs page at the end
  --matrix                        print the QSPI/flash support matrix (live probe)
  --refresh                       force a fresh upstream matrix probe
  --manifest-url <url>            verify downloads against an external sha256 manifest
  --self-update                   update this script from --update-from / JETSON_SCRIPT_URL
  --update-from <url|path>        update source
  --dry-run                       checks and prints only; changes nothing
  --list-boards                   list board configs in the BSP
  --lang <zh|en>                  UI language (default: en)
  -h, --help                      show this help

environment: JETSON_MIRROR  JETSON_DIR  JETSON_BOARD  L4T_VERSION
             NO_COLOR (disable ANSI colour); colour is off for non-terminals
examples:
  bash jetson-jp62.sh --mode detect
  bash jetson-jp62.sh --mode qspi --mirror http://192.168.1.10/l4t/r36.4.3/
  JETSON_MIRROR=file:///mnt/nas/l4t bash jetson-jp62.sh --mode prep --with-rootfs
EOF
}

usage() { if [ "$UI_LANG" = en ]; then usage_en; else usage_zh; fi; }

usage_zh() {
cat <<EOF
A2VEC / Jetson 固件维护工具
MIT License . 非 NVIDIA 官方产品

用法: bash jetson-jp62.sh [选项]

常用操作:
  bash jetson-jp62.sh                        交互菜单
  bash jetson-jp62.sh --mode detect           环境检查
  bash jetson-jp62.sh --mode qspi --l4t 36.4.3 指定版本刷 QSPI

风险: nvme 将重写目标存储；qspi 将写入启动固件.操作前备份并核对板型.
版本示例不构成兼容性建议；下载地址存在不代表可用于当前硬件.

参数:

  --mode <detect|qspi|nvme|prep|target>  执行模式(不给则进交互菜单)
  --board <名字>                  强制板型配置(默认自动识别,--list-boards 看全部)
  --dir <路径>                    工作目录(默认脚本所在目录 / \$JETSON_DIR)
  --mirror <源[,源2...]>          下载源,支持 http/https/file:// 或本地目录
  --offline --src <目录>          完全离线:从本地目录取 tbz2
  --with-rootfs                   prep 模式顺带下 sample rootfs
  --rootdev <设备>                flash.sh 的 rootdev(默认按启动盘推断)
  --skip-recovery-check           跳过 recovery 检查(可能导致刷写失败)
  --no-deps                       不自动 apt 装主机依赖
  --accept                        跳过协议交互(等同已agree,自动化可用)
  --yes                           自动确认使用声明及后续操作(请先审阅声明)
  --cache-dir <路径>              下载包存放/复用目录(= --resource,默认跟 --dir 同一个盘)
  --auto-dir                      自动挑余量最大的分区当工作目录(含下载缓存)
  --config <文件>                 读取配置(默认 ~/.config/jetson-jp62/config,KEY=VALUE)
  --l4t <版本|latest>             目标 L4T 版本(不给则交互选择,非交互回落 auto)
  --jetpack|--jp <版本>           按 JetPack 号自动映射 L4T(6.2->36.4.3,6.2.1->36.4.4,6.2.2->36.5.0...)
  --jp-list                       打印 JetPack -> L4T 映射表
  --diag                          诊断:板内看内核/系统报错,recovery 看 EEPROM/BCT,均不改动
  --uart [设备]                   串口抓 BootROM/UEFI/DDR 启动日志并分级判断(默认自动找 /dev/ttyUSB*)
  --uart-out <文件>               抓取日志写到指定路径
  --uart-log <文件>               离线分析已有串口日志
  --uart-baud <波特率>            默认 115200
  --uart-seconds <秒>             捕获时长,默认 30
  --uart-list                     列出可用串口设备
  --doc                           打开使用说明页(index.html)
  --doc-url <url>                 在线文档地址(无本地 index.html 时用)
  --no-doc                        跑完不提示打开文档
  --matrix                        打印 QSPI/刷机支持矩阵(上游 apt 仓库 + 官方下载目录实时探测)
  --refresh                       强制重取上游矩阵缓存
  --manifest-url <url>            用外部 sha256 清单校验下载包(默认用本机 TOFU 清单)
  --self-update                   从 --update-from / JETSON_SCRIPT_URL 更新脚本自身
  --update-from <url|路径>        更新源
  --dry-run                       只体检,只打印,不下载不改动
  --list-boards                   列出 BSP 里可用的板型配置
  --lang <zh|en>                  界面语言(默认按 \$LANG 判定)
  -h, --help                      显示本帮助

环境变量: JETSON_MIRROR  JETSON_DIR  JETSON_BOARD  L4T_VERSION
          NO_COLOR(禁用 ANSI 颜色)；非终端输出自动禁用颜色
示例:
  bash jetson-jp62.sh --mode detect
  bash jetson-jp62.sh --mode qspi --mirror http://192.168.1.10/l4t/r36.4.3/
  JETSON_MIRROR=file:///mnt/nas/l4t bash jetson-jp62.sh --mode prep --with-rootfs
EOF
    exit 0
}

# ------------------------------------------------------------- 配置文件
tag_for_version() {   # 36.4.3 -> r36_release_v4.3 ; 36.5.0 -> r36_release_v5.0
    local v="$1" maj rest min pat
    maj="${v%%.*}"; rest="${v#*.}"; min="${rest%%.*}"; pat="${rest#*.}"
    [ "$pat" = "$rest" ] && pat=0
    printf 'r%s_release_v%s.%s' "$maj" "$min" "$pat"
}

bsp_url()    { printf '%s/l4t/%s/release/Jetson_Linux_R%s_aarch64.tbz2' "$NV_DL_BASE" "$(tag_for_version "$1")" "$1"; }
rootfs_url() { printf '%s/l4t/%s/release/Tegra_Linux_Sample-Root-Filesystem_R%s_aarch64.tbz2' "$NV_DL_BASE" "$(tag_for_version "$1")" "$1"; }
url_exists() {
    # 公司代理常把响应降成 HTTP/1.1；只认 "HTTP/2 200" 会全线误判成"不存在"。
    curl -sIL --connect-timeout 6 --max-time 15 "$1" 2>/dev/null |
        grep -qE '^HTTP/[0-9.]+ 200'
}

refresh_filenames() {
    [ -n "$L4T_TAG" ] || L4T_TAG="$(tag_for_version "$L4T_VERSION")"
    BSP_FILENAME="Jetson_Linux_R${L4T_VERSION}_aarch64.tbz2"
    ROOTFS_FILENAME="Tegra_Linux_Sample-Root-Filesystem_R${L4T_VERSION}_aarch64.tbz2"
    DEFAULT_MIRROR="$NV_DL_BASE/l4t/${L4T_TAG}/release"
    BSP_SIZE=""; ROOTFS_SIZE=""        # 不预判大小:bzip2 -t + TOFU 清单校验
}

load_config() {
    local f="${CONFIG_FILE:-$AGREE_DIR/config}"
    [ -n "$CONFIG_FILE" ] && [ ! -f "$f" ] && die "config file not found: $f"
    [ -f "$f" ] || return 0
    log "reading config: $f"
    local k v
    while IFS='=' read -r k v; do
        case "$k" in ""|\#*) continue ;; esac
        k="$(printf '%s' "$k" | tr -d '[:space:]')"
        v="${v%\"}"; v="${v#\"}"; v="${v%\"}"; v="${v#\"}"
        case "$k" in
            JETSON_DIR)      WORK_DIR="$v" ;;
            JETSON_CACHE|JETSON_RESOURCE|JETSON_RESOURCES) CACHE_DIR="$v" ;;
            JETSON_MIRROR)   MIRRORS="${MIRRORS:+$MIRRORS,}$v" ;;
            JETSON_BOARD)    BOARD="$v" ;;
            L4T_VERSION)     L4T_VERSION="$v"; refresh_filenames ;;
            L4T_TAG)         L4T_TAG="$v"; refresh_filenames ;;
            JETSON_OFFLINE_SRC) OFFLINE_SRC="$v" ;;
            *) warn "ignoring unknown config key: $k" ;;
        esac
    done < "$f"
}

# --------------------------------------------------------- 自动挑工作目录
auto_select_dirs() {
    local mode="$1" plan total best
    plan="$(space_plan "$mode")"
    total="$(echo "$plan" | cut -d' ' -f3)"
    best="$(auto_pick_dir "$total")"
    if [ -z "$best" ]; then
        warn "no writable partition with >=$(mb2g "$total") free; staying on the current dir (checks will fail)"
        return 0
    fi
    local fm mnt; fm="${best%%|*}"; mnt="${best#*|}"
    local base="$mnt/jetson-jp62"
    [ "$mnt" = "/" ] && base="/var/tmp/jetson-jp62"
    log "auto-picked disk: $mnt (free $(mb2g "$fm"); this mode peaks at $(mb2g "$total")) -> $base"
    [ "$WORK_DIR" = "$SCRIPT_DIR" ] || warn "work dir $WORK_DIR (from --dir/config) will be overridden to $base"
    WORK_DIR="$base"; CACHE_DIR="$base/cache"
    mkdir -p "$CACHE_DIR" 2>/dev/null || true
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --mode)     MODE="${2:-}"; shift 2 ;;
            --board)    BOARD="${2:-}"; shift 2 ;;
            --dir)      WORK_DIR="${2:-}"; shift 2 ;;
            --cache-dir|--resource|--resources)
                        CACHE_DIR="${2:-}"; shift 2 ;;
            --config)   CONFIG_FILE="${2:-}"; shift 2 ;;
            --auto-dir) AUTO_DIR=1; shift ;;
            --mirror)   MIRRORS="${MIRRORS:+$MIRRORS,}${2:-}"; shift 2 ;;
            --offline)  OFFLINE_SRC="auto"; shift ;;
            --src)      OFFLINE_SRC="${2:-}"; shift 2 ;;
            --with-rootfs) WITH_ROOTFS=1; shift ;;
            --rootdev)  ROOTDEV="${2:-}"; shift 2 ;;
            --no-deps)  SKIP_DEPS=1; shift ;;
            --l4t)      L4T_VERSION="${2:-}"; SPEC_FROM="l4t"; shift 2 ;;
            --jetpack|--jp)
                        local jpv="${2:-}"; shift 2
                        local l4t; if l4t="$(jp_to_l4t "$jpv")"; then
                            L4T_VERSION="$l4t"; SPEC_FROM="jp"
                            log "JetPack $jpv -> L4T $L4T_VERSION"
                        else
                            printf 'unknown JetPack version: %s\n' "$jpv" >&2; jp_list >&2
                            die "use --jetpack <version> or --l4t <L4T version>"
                        fi ;;
            --matrix)   MODE="matrix"; shift ;;
            --jp-list)  MODE="jpmap"; shift ;;
            --uart)     MODE="uart"; UART_DEV="${2:-}"; shift 2 ;;
            --uart-log) MODE="uart"; UART_FILE="${2:-}"; shift 2 ;;
            --uart-out) MODE="uart"; UART_OUT="${2:-}"; shift 2 ;;
            --uart-baud) UART_BAUD="${2:-115200}"; shift 2 ;;
            --uart-seconds) UART_SECONDS="${2:-30}"; shift 2 ;;
            --uart-list) uart_list_ports; echo; exit 0 ;;
            --doc)      MODE="doc"; shift ;;
            --skip-recovery-check|--no-recovery-check) RECOVERY_SKIP=1; shift ;;
            --doc-url)  DOC_URL="${2:-}"; shift 2 ;;
            --no-doc)   OPEN_DOC=0; shift ;;
            --refresh)  REFRESH=1; shift ;;
            --manifest-url) MANIFEST_URL="${2:-}"; shift 2 ;;
            --self-update|--update) MODE="update"; shift ;;
            --update-from) UPDATE_FROM="${2:-}"; shift 2 ;;
            --accept)   ACCEPTED=1; shift ;;
            --yes|-y)   YES=1; shift ;;
            --dry-run)  DRY_RUN=1; shift ;;
            --list-boards) list_boards; exit 0 ;;
            --lang)     UI_LANG="${2:-zh}"; shift 2 ;;
            --lang=*)   UI_LANG="${1#*=}"; shift ;;
            -h|--help)  WANT_HELP=1; shift ;;
            *) die "unknown argument: $1 (see --help)" ;;
        esac
    done
    [ "${WANT_HELP:-0}" = 1 ] && { usage; exit 0; }
    case "$UI_LANG" in zh|en) ;; *) die "--lang accepts zh or en only" ;; esac
    case "$MODE" in
        ""|detect|qspi|nvme|prep|target|matrix|update|doc|jpmap|diag|uart) ;;
        *) die "--mode accepts detect / qspi / nvme / prep / target (plus the --matrix / --self-update / --doc actions)" ;;
    esac
}

list_boards() {
    local d="$WORK_DIR/Linux_for_Tegra"
    [ -d "$d" ] || { warn "BSP not extracted yet; first run: bash $(basename "$0") --mode prep"; return; }
    ( cd "$d" && ls jetson-*.conf 2>/dev/null | sed 's/\.conf$//' )
}

run_root() {
    if [ "$DRY_RUN" = 1 ]; then log "[dry-run] would run: $*"; return 0; fi
    if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi
}

install_deps() {
    [ "$SKIP_DEPS" = 1 ] && { warn "skipping dependency install (--no-deps)"; return 0; }
    local d="$WORK_DIR/Linux_for_Tegra"
    if [ -x "$d/tools/l4t_flash_prerequisites.sh" ]; then
        log "installing the host dependencies listed by NVIDIA"
        run_root "$d/tools/l4t_flash_prerequisites.sh" || die "dependency install failed; install them manually and rerun with --no-deps"
    else
        local miss=() p
        for p in curl bzip2 tar python3 file rsync; do command -v "$p" >/dev/null 2>&1 || miss+=("$p"); done
        [ ${#miss[@]} -eq 0 ] || { run_root apt-get update && run_root apt-get install -y "${miss[@]}" || die "base dependency install failed"; }
    fi
    ok "host dependencies ready"
}

# ==================================================================== 下载
pkg_dir() { printf '%s' "${CACHE_DIR:-$WORK_DIR}"; }

normalize_mirror() {
    local m="$1"
    case "$m" in
        "") return ;;
        http://*|https://*|file://*) printf '%s' "${m%/}" ;;
        /*) [ -d "$m" ] && printf 'file://%s' "${m%/}" || printf '%s' "$m" ;;
        *) printf 'https://%s' "${m%/}" ;;
    esac
}

mirror_list() {
    # 自定义源（--mirror / 配置文件 / JETSON_MIRROR）优先，NVIDIA 官方作最后兜底；
    # 内网用户可以把官方源排到最后、只走自己的镜像。
    local out=() m IFS=','
    for m in $MIRRORS; do [ -n "$m" ] && out+=("$(normalize_mirror "$m")"); done
    out+=("$DEFAULT_MIRROR")
    printf '%s\n' "${out[@]}"
}

# 上游给的真实大小（Content-Length，跟随重定向取最后一条）；取不到返回空
remote_size() {
    local name="$1" m sz
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        sz="$(curl -sIL --max-time 20 "${m}/${name}" 2>/dev/null |
              awk 'BEGIN{IGNORECASE=1} /^content-length:/{v=$2} END{gsub(/[\r ]/,"",v); print v}')"
        case "$sz" in ''|*[!0-9]*) continue ;; esac
        printf '%s' "$sz"; return 0
    done < <(mirror_list)
    return 0
}

human() { local b="${1:-0}"; awk -v b="$b" 'BEGIN{ if (b>=1073741824) printf "%.2f GiB", b/1073741824; else if (b>=1048576) printf "%.1f MiB", b/1048576; else printf "%d B", b }'; }

fetch() {
    local name="$1" size="$2" local_src="${3:-}" dst
    dst="$(pkg_dir)/$1"
    mkdir -p "$(pkg_dir)" 2>/dev/null || true

    # 期望大小：命令行/常量给了就用，否则现场向上游 HEAD 问
    local want="$size"
    [ -n "$want" ] || want="$(remote_size "$name")"

    if [ -s "$dst" ]; then
        local got; got="$(stat -c%s "$dst")"
        if [ -n "$want" ] && [ "$got" = "$want" ]; then
            log "already present and matches upstream size ($(human "$got")), skipping download: $name"
            return 0
        fi
        if [ -z "$want" ]; then
            log "upstream gave no size; local copy is $(human "$got"); leaving it to the archive integrity check: $name"
            return 0
        fi
        if [ "$got" -gt "$want" ]; then
            warn "local file is larger than upstream (local $(human "$got") > upstream $(human "$want")); possibly a different release -> deleting and re-downloading"
            [ "$DRY_RUN" = 1 ] || rm -f "$dst"
        else
            warn "local file is incomplete ($(human "$got") / $(human "$want")) -> resuming"
        fi
    fi

    if [ -n "$local_src" ] && [ -f "$local_src/$name" ]; then
        log "offline copy: $local_src/$name"
        [ "$DRY_RUN" = 1 ] && { log "[dry-run] cp $local_src/$name $dst"; return 0; }
        cp -f "$local_src/$name" "$dst" && return 0
    fi

    local m got
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        log "downloading $name <- $m"
        [ "$DRY_RUN" = 1 ] && { log "[dry-run] curl -fL -C - -o $dst ${m}/${name}"; return 0; }
        if curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -C - -o "$dst" "${m}/${name}"; then
            got="$(stat -c%s "$dst")"
            if [ -n "$want" ] && [ "$got" != "$want" ]; then
                warn "size still mismatched after download ($(human "$got") / $(human "$want")); deleting and moving to the next source"
                rm -f "$dst"; continue
            fi
            return 0
        fi
        warn "source failed, trying the next one"
    done < <(mirror_list)
    die "no source could deliver $name; use --mirror for an internal/local source (file:// and dirs work)"
}

# 取包 + 校验，坏包自动删掉重下一次（不让用户手工 rm）
ensure_pkg() {
    local name="$1" size="${2:-}" src="${3:-}"
    fetch "$name" "$size" "$src"
    if [ "$DRY_RUN" = 1 ]; then verify_tbz2 "$name"; return 0; fi
    if bzip2 -t "$(pkg_dir)/$name" 2>/dev/null; then log "archive verified: $name"; return 0; fi
    warn "archive check failed ($name); deleting and retrying once"
    rm -f "$(pkg_dir)/$name"
    fetch "$name" "$size" "$src"
    log "verifying archive: $name"
    bzip2 -t "$(pkg_dir)/$name" || die "still corrupt after re-download: check network/proxy or switch --mirror (file: $(pkg_dir)/$name)"
    ok "verified after re-download: $name"
}

verify_tbz2() {
    local f; f="$(pkg_dir)/$1"
    if [ "$DRY_RUN" = 1 ]; then log "[dry-run] bzip2 -t $f"; return 0; fi
    [ -s "$f" ] || die "missing file: $f"
    log "verifying archive: $1"
    bzip2 -t "$f" || die "archive corrupt; delete and retry: rm '$f'"
}

# ============================================================ 解压 / 应用
extract_bsp() {
    local lt="$WORK_DIR/Linux_for_Tegra"
    if [ -d "$lt" ] && [ -f "$lt/nv_tegra/bsp_version" ]; then
        local have; have="$(awk -F= '/^BSP_BRANCH=/{b=$2}/^BSP_MAJOR=/{m=$2}/^BSP_MINOR=/{n=$2}END{print b"."m"."n}' "$lt/nv_tegra/bsp_version")"
        [ "$have" = "$L4T_VERSION" ] && { log "BSP extracted and version matches ($have)"; return 0; }
        warn "existing Linux_for_Tegra is $have, not the target $L4T_VERSION -> backing up and re-extracting"
        [ "$DRY_RUN" = 1 ] || run_root mv "$lt" "${lt}.bak.$(date +%s)"
    fi
    log "extracting $BSP_FILENAME"
    [ "$DRY_RUN" = 1 ] && { log "[dry-run] tar -xjf $(pkg_dir)/$BSP_FILENAME -C $WORK_DIR"; return 0; }
    tar -xjf "$(pkg_dir)/$BSP_FILENAME" -C "$WORK_DIR" || die "BSP extraction failed"
    ok "BSP extracted: $lt"
}

extract_rootfs() {
    local lt="$WORK_DIR/Linux_for_Tegra"
    if [ -f "$lt/rootfs/etc/nv_tegra_release" ]; then
        log "rootfs looks already applied; skipping extraction"
    else
        log "extracting the sample rootfs"
        [ "$DRY_RUN" = 1 ] && log "[dry-run] tar -xjpf $(pkg_dir)/$ROOTFS_FILENAME -C $lt/rootfs" \
                          || run_root tar -xjpf "$(pkg_dir)/$ROOTFS_FILENAME" -C "$lt/rootfs" || die "rootfs extraction failed"
    fi
    log "apply_binaries.sh"
    run_root bash -lc "cd '$lt' && ./apply_binaries.sh" || die "apply_binaries.sh failed"
    ok "rootfs ready"
}

# ================================================================ recovery
# recovery 判定别写死 PID：不同模组/载板组合下 APX 的 PID 不一样
# 实测见过 0955:7523、0955:7623（两者 lsusb 描述都是 "NVIDIA Corp. APX"）。
# 所以判据 = 厂商 0955 + 描述里带 APX；再兜一组已知 PID 防止描述缺失。
RECOVERY_PIDS="7523|7522|7623|7418|7c18|7e19|7018"
recovery_present() {
    local lines; lines="$(lsusb 2>/dev/null | grep -iE '0955:[0-9a-f]{4}' || true)"
    [ -n "$lines" ] || return 1
    printf '%s' "$lines" | grep -qiE 'APX' && return 0
    printf '%s' "$lines" | grep -qiE "0955:(${RECOVERY_PIDS})"
}

# 把当前所有 NVIDIA USB 设备分类打出来：区分"进了 recovery"和"其实板子已经正常启动"
usb_state_hint() {
    local lines; lines="$(lsusb 2>/dev/null | grep -i '0955:' || true)"
    [ -n "$lines" ] || { printf '  no NVIDIA device on USB right now (0955:*)\n'; return 0; }
    printf '%s  NVIDIA USB devices currently visible:%s\n' "$C_D" "$C_N"
    local pid
    while IFS= read -r l; do
        [ -n "$l" ] || continue
        pid="$(printf '%s' "$l" | grep -oiE '0955:[0-9a-f]{4}' | head -1 | cut -d: -f2 | tr 'A-F' 'a-f')"
        if printf '%s' "$l" | grep -qiE 'APX'; then
            printf '    %s . 0955:%s -> recovery/APX, this is the one; press Enter\n' "$C_G" "$pid"
            local prod
            prod="$(lsusb -v -d "0955:$pid" 2>/dev/null | grep -i 'iProduct' | head -1 | sed 's/.*iProduct *//; s/^ *[0-9]* *//')"
            case "$prod" in
                ""|APX) printf '      %s product string is "%s"; APX does not expose the module model - use Board ID/sku from the flash log%s\n' "$C_D" "${prod:-none}" "$C_N" ;;
                *)      printf '      %s product string: %s (use it to confirm module/carrier)%s\n' "$C_D" "$prod" "$C_N" ;;
            esac
            continue
        fi
        case "$pid" in
            7523|7522|7623) printf '    %s . 0955:%s -> recovery/APX, this is the one; press Enter\n' "$C_G" "$pid" ;;
            7020|7018|7418)
                printf '    %s . 0955:%s -> L4T is already booted (USB device/gadget mode), not recovery\n' "$C_R" "$pid"
                printf '      %s cable and power are fine, it simply is not in recovery: power off -> hold the short -> power on, release after 2s\n' "$C_D"
                printf '      %s tip: in this mode the host usually has usb0/192.168.55.x; ssh ubuntu@192.168.55.1 to identify the board\n' "$C_D" ;;
            *) printf '    %s . 0955:%s -> unknown/other mode\n' "$C_Y" "$pid" ;;
        esac
    done <<< "$lines"
}

# 进入 recovery 的三种官方方式（NVIDIA Orin Nano DevKit User Guide → Force Recovery Mode）
print_recovery_howto() {
    printf '\n  %s%s%s\n' "$C_Y" "$(T "板子现在不在 recovery 模式.官方三种进入方式:" "The board is not in recovery mode. Three official ways in:")" "$C_N"
    printf '    A  %s\n' "$(T "断电法:断电 -> 短接 Button Header 9,10 脚(FC REC / GND)-> 接回电源" "Power-off: unplug -> short Button Header pins 9 and 10 (FC REC / GND) -> reconnect power")"
    printf '    B  %s\n' "$(T "已开机:短接 9,10 脚 -> 再短接 7,8 脚触发复位" "Already on: short pins 9 and 10 -> then briefly short pins 7 and 8 to reset")"
    printf '    C  %s\n' "$(T "已能登录:sudo reboot --force forced-recovery" "If you can log in: sudo reboot --force forced-recovery")"
    printf '    %s\n' "$(T "短接位置以载板丝印为准；主机检测到设备后拔掉跳线,别一直插着." "Follow the carrier silkscreen; remove the jumper once the host detects the device.")"
    printf '    USB-C %s: %s%s | grep 0955%s -> %s\n' \
        "$(T "要接能传数据的口/线；本机确认" "must be a data port/cable; check on the host with")" "$C_B" "lsusb" "$C_N" \
        "$(T "0955:7523(Orin Nano 8GB)/ 7623(4GB)" "0955:7523 (Orin Nano 8GB) / 7623 (4GB)")"
    printf '    %s\n' "$(T "参考:docs.nvidia.com/jetson/orin-nano-devkit/user-guide/latest/howto.html#force-recovery-mode" "Ref: docs.nvidia.com/jetson/orin-nano-devkit/user-guide/latest/howto.html#force-recovery-mode")"
    printf '    %s\n\n' "$(T "提示:进 recovery 后板子不会显示为新磁盘,只在 lsusb 里出现,属正常." "Note: in recovery the board does not appear as a disk; it only shows up in lsusb.")"
}

# 刷写前的 recovery 闸门：没检测到就一直让用户手动按回车刷新（不自动轮询、不超时）
# 返回 0 = 可以继续刷；1 = 放弃（EOF/非交互时等不到人）
wait_recovery() {
    [ "$DRY_RUN" = 1 ] && { log "[dry-run] recovery check skipped"; return 0; }
    command -v lsusb >/dev/null 2>&1 || run_root apt-get install -y usbutils >/dev/null 2>&1

    if recovery_present; then ok "recovery device ready"; return 0; fi
    if [ "$RECOVERY_SKIP" = 1 ]; then
        warn "use --skip-recovery-check to bypass the check (flashing will fail if the board is not in recovery)"
        return 0
    fi

    print_recovery_howto
    usb_state_hint
    local key n=0
    while :; do
        n=$((n + 1))
        if [ ! -t 0 ]; then
            warn "no recovery device and no interactive terminal (cannot poll by keypress)"
            warn "rerun this command in a terminal, or switch the board to recovery from another terminal first"
            return 1
        fi
        printf '  %s-> short the pins and power on, then [Enter] to re-check%s   [s] skip check and force flash   [q] quit   (poll %d)> ' \
               "$C_Y" "$C_N" "$n"
        if ! IFS= read -rsn1 key; then warn "input closed; aborting"; return 1; fi   # 单键即生效,回车=刷新
        case "$key" in
            q|Q) die "exited (board never entered recovery)" ;;
            s|S) warn "recovery check skipped, flashing starts (rerun if it fails)"; return 0 ;;
        esac
        if recovery_present; then ok "recovery device detected (poll ${n})"; return 0; fi
        warn "still no recovery. Usual causes: pins not held while powering on / wrong pins / charge-only USB cable"
        usb_state_hint
        log "press Enter to re-check once the board is ready; this side keeps waiting"
    done
}

confirm_flash() {
    [ "$YES" = 1 ] && return 0
    [ "$DRY_RUN" = 1 ] && return 0
    printf '%sabout to run: %s - continue? [y/N] %s' "$C_Y" "$1" "$C_N"
    local a; read -r a
    case "$a" in y|Y|yes|YES) ;; *) die "cancelled" ;; esac
}

verify_flash_log() {
    # 刷写日志里 NVIDIA 会打印 EEPROM 读到的板子信息，与所选配置对不上就报警
    local logf="$1" got
    got="$(grep -m1 -oE 'Board ID\([^)]*\) version\([^)]*\) sku\([^)]*\) revision\([^)]*\)' "$logf" 2>/dev/null)"
    [ -n "$got" ] || { chk_warn "no Board ID line in the flash log; cannot cross-check the board"; return 0; }
    log "EEPROM reports: $got"
    local sku; sku="$(printf '%s' "$got" | sed -n 's/.*sku(\([^)]*\)).*/\1/p')"
    case "$BOARD:$sku" in
        *-super*:0004|*-super*:0005) chk_ok "board model matches EEPROM sku ($sku)" ;;
        *devkit*:0004|*devkit*:0005) chk_ok "board model matches EEPROM sku ($sku)" ;;
        *) chk_warn "board $BOARD may not match EEPROM sku($sku); switch --board to the right config and reflash" ;;
    esac
}

# ==================================================================== 刷机
do_qspi() {
    local lt="$WORK_DIR/Linux_for_Tegra" logf="$WORK_DIR/flash-qspi.log"
    [ -x "$lt/flash.sh" ] || die "flash.sh missing; run --mode prep first"
    confirm_flash "QSPI only (UEFI/bootloader), board $BOARD; system disk data untouched"
    wait_recovery || die "board never entered recovery; flashing abandoned (rerun the same command once it is ready)"
    local cmd=(./flash.sh --no-systemimg -c bootloader/generic/cfg/flash_t234_qspi.xml "$BOARD" "$ROOTDEV")
    log "command: sudo ${cmd[*]}"
    if [ "$DRY_RUN" = 1 ]; then log "[dry-run] stopping here, nothing executed"; return 0; fi
    if ! ( cd "$lt" && run_root "${cmd[@]}" 2>&1 | tee "$logf" ); then
        if grep -qE "rootfs/(lib|bin|usr).*(没有那个文件|No such file)" "$logf" 2>/dev/null; then
            die "flash.sh failed: rootfs is empty (sample rootfs missing). Even a QSPI-only
flash needs rootfs to build the recovery ramdisk on 36.x -> run prep --with-rootfs first. log: $logf"
        fi
        die "flash.sh failed (see $logf)"
    fi
    verify_flash_log "$logf"
    ok "QSPI flash complete"
    cat <<EOF

self-check after the board reboots (run onboard, needs sudo):
  sudo nvbootctrl dump-slots-info     # Current version must equal the flashed $L4T_VERSION
                                      # without sudo it prints 0.0.13 and Permission denied
  nvpmodel -q                         # expect MAXN_SUPER (Super board + 36.4+ UEFI)
  head -3 /etc/nv_boot_control.conf   # TNSPEC should carry -super

EOF
}

do_nvme() {
    local lt="$WORK_DIR/Linux_for_Tegra" logf="$WORK_DIR/flash-nvme.log"
    [ -x "$lt/tools/kernel_flash/l4t_initrd_flash.sh" ] || die "l4t_initrd_flash.sh missing (run --mode prep --with-rootfs first)"
    [ -f "$lt/rootfs/etc/nv_tegra_release" ] || die "rootfs not prepared: run --mode prep --with-rootfs first"
    confirm_flash "full flash to NVMe (QSPI + system; target disk will be erased)"
    wait_recovery || die "board never entered recovery; flashing abandoned (rerun the same command once it is ready)"
    local cmd=(./tools/kernel_flash/l4t_initrd_flash.sh
               --external-device nvme0n1p1
               -p "-c ./bootloader/generic/cfg/flash_t234_qspi.xml"
               -c ./tools/kernel_flash/flash_l4t_t234_nvme.xml
               --showlogs --network usb0 "$BOARD" external)
    log "command: sudo ${cmd[*]}"
    if [ "$DRY_RUN" = 1 ]; then log "[dry-run] stopping here, nothing executed"; return 0; fi
    ( cd "$lt" && run_root "${cmd[@]}" 2>&1 | tee "$logf" ) || die "initrd flash failed (see $logf)"
    verify_flash_log "$logf"
    ok "full flash complete (user/password are created on first boot; tools/l4t_create_default_user.sh can preset them)"
}

do_prep() {
    local src=""
    if [ -n "$OFFLINE_SRC" ]; then
        src="$OFFLINE_SRC"; [ "$src" = "auto" ] && src="$WORK_DIR"
        [ -d "$src" ] || die "offline source dir not found: $src"
        log "offline mode: taking packages from $src"
    fi
    ensure_pkg "$BSP_FILENAME" "$BSP_SIZE" "$src"
    verify_checksum "$BSP_FILENAME"
    extract_bsp
    install_deps
    if [ "$WITH_ROOTFS" = 1 ]; then
        ensure_pkg "$ROOTFS_FILENAME" "$ROOTFS_SIZE" "$src"
        extract_rootfs
    fi
    ok "prep done: $WORK_DIR/Linux_for_Tegra"
}

do_target() {
    local rel; rel="$(grep -m1 '^# R' /etc/nv_tegra_release 2>/dev/null)"
    log "current L4T: ${rel:-unknown}"
    if [ "$DRY_RUN" = 1 ]; then
        log "[dry-run] change r36.x to r36.4 in nvidia-l4t-apt-source.list, then apt dist-upgrade"
        return 0
    fi
    warn "this upgrades onboard BSP packages: TensorRT 8.x->10.x, cuDNN 8.x->9.x; self-built engines must be rebuilt"
    confirm_flash "upgrade L4T packages to 36.4 on the Jetson (official apt path)"
    local f=/etc/apt/sources.list.d/nvidia-l4t-apt-source.list
    [ -f "$f" ] || die "no $f; not a standard L4T system"
    run_root cp "$f" "$f.bak.$(date +%s)"
    run_root sed -i -E 's#jetson/(common|t234|ffmpeg) r36\.[0-9]+#jetson/\1 r36.4#g' "$f"
    run_root apt-get update
    run_root apt-get -y dist-upgrade || warn "dist-upgrade reported errors; attempting repair"
    run_root apt-get install -y --fix-broken -o Dpkg::Options::="--force-overwrite" || true
    ok "done; after a physical reboot nvbootctrl dump-slots-info should show 36.4.x"
}

# ==================================================================== 诊断
# 刷机模式(recovery)能查什么、查不到什么，这里分两路：
#   板内已启动 → 内核/系统日志、bootloader 槽位、功耗模式
#   recovery   → 芯片信息、EEPROM(板号/sku/fab/MAC)、BCT；看不到内核与 UEFI 运行时日志
# 真正的"底层开机报错"(UEFI/DDR训练/BPAM/电源) 只能从串口 ttyTCU0 @115200 看。
uart_help() {
cat <<EOF

  ${C_B}Lowest-level boot output (UEFI / DDR training / BPMP / power) needs serial:${C_N}
    Orin Nano DevKit 40-pin: Pin 6 = GND, Pin 8 = UART1_TX, Pin 10 = UART1_RX
    115200 8N1, console ttyTCU0; with a USB-TTL adapter:
      screen /dev/ttyUSB0 115200     # or picocom -b 115200 /dev/ttyUSB0
    A cold boot walks BootROM -> MB1/MB2 -> UEFI -> kernel; the stage it stops at tells you where it broke.

EOF
}

do_diag() {
    local d="$WORK_DIR/diag-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$d" 2>/dev/null || true
    printf '\n%s-- diagnostics report (output %s) --%s\n' "$C_B" "$d" "$C_N"

    if [ -r /etc/nv_tegra_release ]; then
        # ---------- 板内（已启动）：这层才看得到内核与系统日志 ----------
        chk_info "mode: onboard diagnostics (system booted)"
        {
            echo "## version"; grep -m1 '^# R' /etc/nv_tegra_release; uname -a
            echo; echo "## TNSPEC"; head -4 /etc/nv_boot_control.conf 2>/dev/null
            echo; echo "## bootloader slots"; sudo -n nvbootctrl dump-slots-info 2>&1 | head -8
            echo; echo "## power mode"; nvpmodel -q 2>&1 | head -3
            echo; echo "## cmdline"; cat /proc/cmdline
            echo; echo "## dmesg err"; (sudo -n dmesg -l err,crit,alert,emerg 2>/dev/null || dmesg 2>/dev/null | grep -iE 'error|fail' | tail -40)
            echo; echo "## journal -b -p err"; sudo -n journalctl -b -p err --no-pager 2>/dev/null | tail -30
            echo; echo "## failed services"; systemctl --failed --no-legend 2>/dev/null | head -10
            echo; echo "## probe failures for key peripherals"
            (sudo -n dmesg 2>/dev/null || true) | grep -icE 'board setup failed|probe failed|failed to read device id' | sed 's/^/  failures=/' || true
        } > "$d/onboard.txt" 2>&1
        local uefi; uefi="$(sudo -n nvbootctrl dump-slots-info 2>/dev/null | awk -F': ' '/Current version/{print $2}')"
        local l4t_short; l4t_short="$(sed -nE 's/^# ?R([0-9]+).*REVISION:? *([0-9]+\.[0-9]+).*/R\1.\2/p' /etc/nv_tegra_release 2>/dev/null | head -1)"
        chk_ok "system L4T/kernel: ${l4t_short:-?} / $(uname -r)"
        chk_info "UEFI (QSPI) version: ${uefi:-not readable}"
        if [ -n "$uefi" ] && [ -n "$l4t_short" ]; then
            local sysv="${l4t_short#R}" uefimaj="${uefi%.*}"
            if [ "${sysv%.*}" = "$uefimaj" ]; then
                chk_ok "QSPI/UEFI ($uefi) matches system ($sysv)"
            else
                chk_warn "QSPI/UEFI ($uefi) differs from system ($sysv): typically QSPI was flashed alone; align them with --mode nvme or upgrade in place with --mode target"
            fi
        fi
        chk_info "power mode: $(nvpmodel -q 2>/dev/null | head -1)"
        local nerr; nerr="$(grep -c . "$d/onboard.txt" 2>/dev/null || echo 0)"
        grep -q "imx219_board_setup" "$d/onboard.txt" 2>/dev/null && chk_warn "CSI camera (i2c 9/10) probe failed -> camera cable/power/device tree; unrelated to flashing"
        grep -q "fusb301" "$d/onboard.txt" 2>/dev/null && chk_warn "fusb301 (USB-C PD) ID unreadable -> carrier lacks the part or the board model does not match"
        chk_ok "full log: $d/onboard.txt"
        log "note: this layer shows kernel/system errors but not UEFI or DDR training logs"
        uart_help
        return 0
    fi

    if recovery_present; then
        # ---------- recovery：只能查设备身份/EEPROM/BCT ----------
        local lt="$WORK_DIR/Linux_for_Tegra"
        if [ ! -x "$lt/bootloader/tegrarcm_v2" ]; then
            die "Linux_for_Tegra/bootloader tools missing; run --mode prep (download and extract only)"
        fi
        chk_info "mode: recovery diagnostics (board not booted)"
        ( cd "$lt" && run_root ./bootloader/tegrarcm_v2 --chip 0x23 0 --oem platformdetails chip "$d/chip_info.bin" ) 2>&1 | tail -2
        ( cd "$lt" && run_root ./bootloader/tegrarcm_v2 --chip 0x23 0 --oem platformdetails eeprom cvm "$d/cvm.bin" ) 2>&1 | tail -2
        ( cd "$lt" && run_root ./bootloader/tegrarcm_v2 --chip 0x23 0 --oem dump bct "$d/tmp.bct" ) 2>&1 | tail -2
        if [ -s "$d/cvm.bin" ] && [ -x "$lt/bootloader/chkbdinfo" ]; then
            local ci="$lt/bootloader/chkbdinfo"
            {
                echo "## EEPROM"
                printf '  BoardID: %s\n  SKU: %s\n  FAB: %s\n  Revision: %s\n' \
                    "$("$ci" -i "$d/cvm.bin" 2>&1)" "$("$ci" -k "$d/cvm.bin" 2>&1)" \
                    "$("$ci" -f "$d/cvm.bin" 2>&1)" "$("$ci" -r "$d/cvm.bin" 2>&1)"
                printf '  board part number: %s\n  AssetID: %s\n' "$("$ci" -p "$d/cvm.bin" 2>&1)" "$("$ci" -a "$d/cvm.bin" 2>&1)"
                printf '  GB MAC: %s\n  WiFi MAC: %s\n' "$("$ci" -g "$d/cvm.bin" 2>&1)" "$("$ci" -w "$d/cvm.bin" 2>&1)"
            } | tee "$d/eeprom.txt"
            local sku; sku="$("$ci" -k "$d/cvm.bin" 2>&1)"
            case "$BOARD:$sku" in
                *-super*:0004|*devkit*:0004|*:0005) chk_ok "EEPROM sku=$sku matches board $BOARD" ;;
                *) chk_warn "EEPROM sku=$sku may not match board $BOARD -> pick the right --board config" ;;
            esac
        fi
        chk_info "BCT exported: $d/tmp.bct (corrupt info / BCT mismatch is a common reason for recovery-only boots)"
        chk_warn "recovery mode exposes no kernel/UEFI runtime log, nor DDR training or power issues"
        uart_help
        return 0
    fi

    chk_warn "neither onboard (no /etc/nv_tegra_release) nor in recovery"
    usb_state_hint
    chk_info "connect the board: normal boot -> ssh in and run onboard diagnostics; not booted -> short the pins and run EEPROM/BCT diagnostics"
    uart_help
}

# ================================================================ 串口诊断
# 底层开机日志(UEFI/DDR/BPMP/电源)只有串口看得到。这里做两件事：
#   1) 实时抓串口日志（115200 8N1，ttyTCU0），存文件
#   2) 对抓到的日志做分级判断：卡在 BootROM / MB1 / MB2 / UEFI / kernel 哪一段
UART_BAUD="${UART_BAUD:-115200}"
UART_SECONDS="${UART_SECONDS:-30}"
UART_DEV="${UART_DEV:-}"
UART_LOG="${UART_LOG:-}"
UART_FILE="${UART_FILE:-}"
UART_OUT="${UART_OUT:-}"

# L4T 的 USB gadget（ttyACM0 / "*Linux_for_Tegra*"）不是串口控制台，抓到的是空数据，必须排除
is_l4t_gadget() {
    case "$1" in
        *Linux_for_Tegra*|*NVIDIA*L4T*) return 0 ;;
    esac
    local dev; dev="$(readlink -f "$1" 2>/dev/null)"
    case "$dev" in /dev/ttyACM*) return 0 ;; esac
    return 1
}

uart_list_ports() {
    local f found=0 note
    for f in /dev/serial/by-id/* /dev/ttyUSB* /dev/ttyACM*; do
        [ -e "$f" ] || continue
        found=1
        if is_l4t_gadget "$f"; then
            note="${C_Y}(L4T USB gadget, not a UART console; do not pick this)${C_N}"
        elif [ -r "$f" ]; then
            note="${C_G}readable${C_N}"
        else
            note="${C_Y}(needs dialout group or sudo)${C_N}"
        fi
        printf '   %-46s -> %-14s %b\n' "$f" "$(readlink -f "$f" 2>/dev/null)" "$note"
    done
    [ "$found" = 1 ] || printf '   %sno serial device found. USB-TTL connected? driver installed (FTDI/CP210x/CH340/PL2303)?%s\n' "$C_D" "$C_N"
}

uart_auto_dev() {
    local f base
    for f in /dev/serial/by-id/*; do
        [ -e "$f" ] || continue
        is_l4t_gadget "$f" && continue          # 跳过板子自己的 gadget
        base="$(basename "$f")"
        case "$base" in
            *FTDI*|*Silicon_Labs*|*CP210*|*Prolific*|*PL2303*|*CH340*|*QinHeng*|*USB_Serial*|*UART*)
                printf '%s' "$f"; return 0 ;;
        esac
    done
    # 只回退 ttyUSB*（USB-TTL 桥），不要 ttyACM*（多半是板子的 CDC gadget）
    for f in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do
        [ -e "$f" ] && { printf '%s' "$f"; return 0; }
    done
    return 1
}

# 对串口日志分级：返回最后到达的阶段
uart_analyze() {
    local f="$1"
    [ -s "$f" ] || { warn "log is empty: $f"; return 1; }
    local n=$'\n'
    local stages=(
        "BootROM|BootROM|Tegra Boot|Boot Rom"
        "MB1|MB1|Primary Boot|I2C: rcm|mb1"
        "MB2|MB2|MB2 Applet|Bootloader version|NvBootloader"
        "UEFI|UEFI|Jetson UEFI|L4TLauncher|Device manager|Version 3\.[0-9]+"
        "kernel|Linux version|Booting Linux|Kernel command line"
        "userspace|systemd\[1\]|Reached target|Ubuntu "
    )
    printf '\n  %s-- serial log stages (%s) --%s\n' "$C_B" "$f" "$C_N"
    local last="(none)"
    local entry name pat
    for entry in "${stages[@]}"; do
        name="${entry%%|*}"; pat="${entry#*|}"
        if grep -qiE "$pat" "$f"; then
            printf '    %s[ ok ]%s %-9s seen (first at line %s)\n' "$C_G" "$C_N" "$name" "$(grep -niE -m1 "$pat" "$f" | cut -d: -f1)"
            last="$name"
        else
            printf '    %s[ - ]%s %-9s absent\n' "$C_D" "$C_N" "$name"
        fi
    done

    printf '\n  %s-- suspicious lines (max 15) --%s\n' "$C_B" "$C_N"
    local hits
    hits="$(grep -niE 'error|fail|panic|abort|timeout|assert|unable|not found|invalid|watchdog|DRAM.*(fail|error)|assert' "$f" 2>/dev/null | head -15)"
    if [ -n "$hits" ]; then printf '%s\n' "$hits" | sed 's/^/    /'
    else printf '    %sno obvious error lines%s\n' "$C_D" "$C_N"; fi

    printf '\n  %sverdict: %s' "$C_B" "$C_N"
    case "$last" in
        userspace|kernel) printf '%sthe log reached the %s stage; still verify the running system%s\n' "$C_G" "$last" "$C_N" ;;
        UEFI)             printf '%slast stage UEFI: check boot entries, system partitions and log completeness%s\n' "$C_Y" "$C_N" ;;
        MB2)              printf '%slast stage MB2: check UEFI loading, BCT and log completeness%s\n' "$C_Y" "$C_N" ;;
        MB1)              printf '%slast stage MB1: check DDR, BCT and log completeness%s\n' "$C_Y" "$C_N" ;;
        BootROM)          printf '%sonly BootROM output seen; check power, memory init and capture completeness against the full log%s\n' "$C_R" "$C_N" ;;
        *)                printf '%sno known stage captured; check baud (115200), TX/RX swap and a common GND%s\n' "$C_R" "$C_N" ;;
    esac
}

uart_capture() {
    local dev="$1" log="$2" secs="$3"
    if [ ! -e "$dev" ]; then die "serial device not found: $dev (see --uart-list)"; fi
    if [ ! -r "$dev" ]; then
        warn "$dev is unreadable: add yourself to dialout (sudo usermod -aG dialout $USER, log in again) or run with sudo"
        return 1
    fi
    log "serial $dev @ ${UART_BAUD} 8N1, capturing ${secs}s (power-cycle the board now to capture the full boot chain; Ctrl-C stops early)"
    log "log: $log"
    stty -F "$dev" "$UART_BAUD" cs8 -cstopb -parenb -crtscts raw -echo 2>/dev/null || warn "stty failed (possibly not a TTY); still trying to read"
    printf '  %spress Enter to start capturing...%s ' "$C_Y" "$C_N"
    if [ -t 0 ] && [ "$YES" != 1 ]; then read -r _; fi
    timeout --foreground "$secs" cat "$dev" 2>/dev/null | tee "$log"
    ok "capture finished ($(wc -c < "$log" 2>/dev/null || echo 0) bytes)"
    uart_analyze "$log"
}

# 串口诊断：优先用脚本同目录的采集器（离线可用），否则缓存/下载一次。
# 交互式运行时在脚本内问时长、采完自动给出结果路径并可打开目录。
do_uart() {
    local here runner_dir runner viewer
    here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
    runner_dir="${XDG_CACHE_HOME:-$HOME/.cache}/jetson-uart"
    mkdir -p "$runner_dir"
    runner=""
    if [ -f "$here/uart-logs.sh" ]; then
        runner="$here/uart-logs.sh"                      # 与脚本同目录:完全离线
    elif [ -f "$runner_dir/uart-logs.sh" ]; then
        runner="$runner_dir/uart-logs.sh"                # 上次下载的缓存
    else
        log "$(T "本地没有采集器,下载一次(之后可离线使用)" "No local collector; downloading once (offline afterwards)")"
        if curl -fsSL https://raw.githubusercontent.com/Shippuurl/jetson-jp62/main/uart-logs.sh -o "$runner.tmp"; then
            mv "$runner.tmp" "$runner"
            runner="$runner_dir/uart-logs.sh"
        else
            rm -f "$runner.tmp"
            die "$(T "下载失败；把 uart-logs.sh / uart-logs.py 放到脚本同目录即可离线使用" "Download failed; place uart-logs.sh and uart-logs.py next to this script for offline use")"
        fi
    fi

    # 交互：时长（脚本内一次问完，不用记参数）
    if [ -t 0 ] && [ "$YES" != 1 ] && [ -z "$UART_FILE" ]; then
        printf '  %s [%s] (0 = until Ctrl-C): ' "$(T "采集时长(秒)" "Capture length (seconds)")" "$UART_SECONDS"
        local d; read -r d
        case "$d" in ''|*[!0-9]*) ;; *) UART_SECONDS="$d" ;; esac
        [ "$UART_SECONDS" = 0 ] && warn "$(T "持续采集:抓完按 Ctrl-C,仍会自动打包" "Continuous capture: press Ctrl-C when done, packaging still runs")"
    fi

    local args=(--baud "$UART_BAUD" --seconds "$UART_SECONDS")
    [ -n "$UART_DEV" ]  && args+=(--port "$UART_DEV")
    [ -n "$UART_FILE" ] && args+=(--input "$UART_FILE")
    [ -n "$UART_OUT" ]  && args+=(--output "$UART_OUT")

    printf '\n  %s%s%s\n' "$C_D" "$(T "给板子断电 -> 上电,开始抓完整启动链" "Power-cycle the board now to capture the whole boot chain")" "$C_N"
    bash "$runner" "${args[@]}" 2>&1 | tee "$runner_dir/last-run.txt"
    local rc=${PIPESTATUS[0]}

    # 结果位置：从采集器输出里取会话目录
    local sess
    sess="$(sed -n 's/^Saved locally: //p' "$runner_dir/last-run.txt" | tail -1)"
    if [ -n "$sess" ] && [ -d "$sess" ]; then
        printf '\n  %s\n' "$(T "结果目录" "Results")"
        printf '    %s\n' "$sess"
        printf '    %s %s\n' "$(T "全量日志" "Full log")"    "$sess/full.log"
        printf '    %s %s\n' "$(T "重要日志" "Important")"   "$sess/important.log"
        printf '    %s %s\n' "$(T "压缩包"   "Archives")"    "$sess/all-logs.zip (all logs), $sess/important-logs.zip"
        printf '    %s %s\n' "$(T "本地入口" "Shortcut")"    "file://$sess/index.html"
        viewer=""
        for c in xdg-open open explorer.exe; do command -v "$c" >/dev/null 2>&1 && { viewer="$c"; break; }; done
        if [ -n "$viewer" ] && [ -t 0 ] && [ "$YES" != 1 ]; then
            printf '\n  %s[Enter] %s  [n] %s > ' "$C_Y" "$(T "打开目录" "open folder")" "$(T "不打开" "skip")"
            local o; read -r o
            case "$o" in n|N) ;; *) "$viewer" "$sess" >/dev/null 2>&1 || true ;; esac
        fi
    fi
    [ "$rc" = 0 ] || warn "$(T "采集器返回 $rc(见上面的输出)" "collector exited $rc (see output above)")"
    return 0
}

# ==================================================================== 菜单
menu() {
    banner
    # 中文按字符数补齐（printf 的 %-Ns 对多字节按字节计算，会把中文标签吞掉）
    _pad() { local s="$1" w="$2" n; n=${#s}; printf '%s' "$s"; [ $((w - n)) -gt 0 ] && printf '%*s' $((w - n)) ''; return 0; }
    printf '  %s\n' "$(T "检查与诊断" "Check and diagnose")"
    printf '    1  %s %s\n' "$(_pad "$(T 环境检查 "env check")" 12)"    "$(T "设备识别与运行条件检查" "Device identification and host prerequisites")"
    printf '    2  %s %s\n' "$(_pad "$(T 设备诊断 "diagnose")" 12)"     "$(T "采集身份信息及诊断日志" "Collect identity data and diagnostic logs")"
    printf '    3  %s %s\n' "$(_pad "$(T 串口诊断 "UART diag")" 12)"    "$(T "采集启动日志并提供排查线索" "Capture boot log and localise the stall")"
    printf '\n  %s\n' "$(T "资源与维护" "Resources and upkeep")"
    printf '    4  %s %s\n' "$(_pad "$(T 准备资源 "prepare")" 12)"      "$(T "下载并解压 BSP / 可选 rootfs" "Download and extract BSP / optional rootfs")"
    printf '    5  %s %s\n' "$(_pad "$(T 板内更新 "onboard apt")" 12)"  "$(T "通过 apt 更新软件包" "Update packages on the Jetson via apt")"
    printf '    6  %s %s%s%s\n' "$(_pad "$(T "QSPI flash" "QSPI flash")" 12)" "$C_Y" "$(T "写入启动固件；请核对板型与版本" "Writes boot firmware; verify board and version")" "$C_N"
    printf '    7  %s %s%s%s\n' "$(_pad "$(T "NVMe flash" "NVMe flash")" 12)" "$C_R" "$(T "重写目标存储,清除数据" "Rewrites target storage, erases data")" "$C_N"
    printf '\n    8  %s %s\n' "$(_pad "$(T 操作手册 "manual")" 12)"   "$(T "参数,许可与官方参考" "Options, licence and official references")"
    printf '    0  %s\n' "$(T 退出 quit)"
    printf '\n  %s [0-8] > ' "$(T 选择 select)"
    local a; read -r a
    case "$a" in
        1) MODE=detect ;;
        6) MODE=qspi ;;
        7) MODE=nvme; WITH_ROOTFS=1 ;;
        4) MODE=prep; printf '  %s [y/N] ' "$(T "一并下载 sample rootfs(1.83G,整机刷才需要)？" "Also fetch the sample rootfs (1.83G, only needed for a full flash)?")"; local b; read -r b
           case "$b" in y|Y) WITH_ROOTFS=1 ;; esac ;;
        5) MODE=target ;;
        2) MODE=diag ;;
        3) MODE=uart ;;
        8) MODE=doc ;;
        *) log "$(T 退出 quit)"; exit 0 ;;
    esac
}

report_detect() {
    banner
    echo "  auto-detect result:"
    case "$DET_MODE" in
        onboard)
            chk_ok "running on the Jetson itself (most accurate identification)"
            chk_info "TNSPEC      : ${DET_TNSPEC:-not readable}"
            chk_info "module/type : ${DET_MODULE:-unknown} -> suggested board ${DET_BOARD_SUGGEST:-unknown}"
            chk_info "L4T version : ${DET_L4T:-unknown}"
            chk_info "UEFI version: ${DET_UEFI:-needs sudo; not readable}"
            chk_info "Super enabled: ${DET_SUPER}"
            chk_info "boot storage: ${DET_STORAGE:-unknown} (rootdev ${DET_ROOTDEV_SUGGEST:-unknown})"
            ;;
        recovery) chk_ok "recovery device visible from the host (model is read from EEPROM during flashing)" ;;
        *) chk_warn "neither onboard nor in recovery (board not connected, or not in recovery)" ;;
    esac
    if [ -n "$DET_BOARD_SUGGEST" ]; then
        local want="jetson-orin-nano-devkit-super"
        case "$DET_TNSPEC" in
            *-super*) [ "$want" = "jetson-orin-nano-devkit-super" ] && chk_ok "board supports Super (config ${want})" ;;
            *) chk_warn "this board is not the Super variant; for Super you must flash QSPI to 36.4, then switch nvpmodel to MAXN_SUPER" ;;
        esac
    fi
    echo
}

# ======================================================= 上游矩阵 / 版本解析
# 目标：不写死版本号、不写死校验值。所有"有哪些版本、哪个版本能刷"都在运行时向上游取，
# 结果缓存在 ~/.config/jetson-jp62/matrix.cache，--refresh 可强制重取。
#   数据源1 repo.download.nvidia.com/jetson/<平台>/dists/<suite>/Packages.gz
#          → 该 suite 的实际 L4T 版本(nvidia-l4t-core)、bootloader、QSPI capsule 更新包有无
#   数据源2 官方 BSP 下载目录 HEAD 探测 → 该 L4T 版本是否有可直接刷机的 BSP 包
# 参考: 官方图形工具 https://developer.nvidia.com/sdk-manager
#       mfi-qspi-forge  (QSPI-only 量产包生成/校验/烧写)
#       turing-pi-2.5-jetson-eeprom-fix (先备份再QSPI only，NVMe 数据不动)
matrix_age() {
    [ -f "$MATRIX_FILE" ] || { echo 999999; return; }
    echo $(( $(date +%s) - $(stat -c%Y "$MATRIX_FILE" 2>/dev/null || echo 0) ))
}

suite_core_version() {   # suite -> 该 suite 最新 nvidia-l4t-core 版本
    local s="$1" url="$NV_REPO/t234/dists/$s/main/binary-arm64/Packages.gz"
    curl -s --max-time 25 "$url" | gunzip -c 2>/dev/null | \
        awk '/^Package: nvidia-l4t-core$/{f=1;next} f&&/^Version:/{print $2; exit}'
}

suite_qspi_updater() {   # suite -> QSPI capsule 更新包版本(没有则空)
    local s="$1" url="$NV_REPO/t234/dists/$s/main/binary-arm64/Packages.gz"
    curl -s --max-time 25 "$url" | gunzip -c 2>/dev/null | \
        awk '/^Package: nvidia-l4t-jetson-orin-nano-qspi-updater$/{f=1;next} f&&/^Version:/{print $2; exit}'
}

# 上游全探测不到时用的离线清单：只保证"这些版本当年确实发过 BSP 包"，
# 不是最新。有网后 --refresh 会用真实探测结果覆盖。
FALLBACK_VERSIONS="36.5.0 36.4.4 36.4.3 36.4.0 36.3.0 36.2.0 35.6.5 35.4.1"
NEEDS_FALLBACK=0

matrix_has_versions() {
    [ -s "$MATRIX_FILE" ] || return 1
    awk -F'|' '$4!=""{found=1} END{exit(found?0:1)}' "$MATRIX_FILE"
}

fallback_matrix() {
    mkdir -p "$(dirname "$MATRIX_FILE")" 2>/dev/null
    local newest="${FALLBACK_VERSIONS%% *}"
    local all; all="$(printf '%s' "$FALLBACK_VERSIONS" | tr ' ' ',')"
    printf 'offline|%s||%s|%s\n' "$newest" "$newest" "$all" > "$MATRIX_FILE"
    NEEDS_FALLBACK=1
    warn "upstream unreachable (proxy/network?) -> using the built-in fallback list (may not be the newest)"
    warn "rerun --refresh once online; if downloads fail, point --mirror at an internal source"
}

build_matrix() {
    local force="${1:-0}"
    local age; age="$(matrix_age)"
    if [ "$force" != 1 ] && [ "$age" -ge 0 ] && [ "$age" -lt "$MATRIX_TTL" ]; then
        if matrix_has_versions; then
            # 缓存可能就是上次断网时写的兜底清单：那时不能再做存在性探测
            if awk -F'|' '$1=="offline"{f=1} END{exit(f?0:1)}' "$MATRIX_FILE"; then
                NEEDS_FALLBACK=1
                log "using the offline fallback list from cache ($(( age / 3600 ))h old; --refresh re-probes)"
            else
                log "using cached matrix ($(( age / 3600 ))h old; --refresh forces a re-probe)"
            fi
            return 0
        fi
        warn "matrix cache holds no usable version (last probe failed?) -> probing once more"
    fi
    mkdir -p "$(dirname "$MATRIX_FILE")" 2>/dev/null
    : > "$MATRIX_FILE.tmp"
    local s core qspi maj min pat v best
    local found_any=0 fails=0 empty=0
    for s in $SUITES; do
        core="$(suite_core_version "$s")"
        if [ -z "$core" ]; then
            empty=$((empty + 1))
            if [ "$empty" -ge 2 ]; then
                warn "$empty suites in a row returned no apt metadata; upstream looks unreachable, stopping early"
                break
            fi
            continue
        fi
        empty=0
        qspi="$(suite_qspi_updater "$s")"
        maj="${core%%.*}"; local rest="${core#*.}"; min="${rest%%.*}"; pat="${rest#*.}"; pat="${pat%%-*}"
        best=""; local all=""
        for v in $(seq "$pat" -1 0); do
            if url_exists "$(bsp_url "$maj.$min.$v")"; then
                [ -z "$best" ] && best="$maj.$min.$v"
                all="${all:+$all,}$maj.$min.$v"
            fi
        done
        printf '%s|%s|%s|%s|%s\n' "$s" "$core" "${qspi%%-*}" "$best" "$all" >> "$MATRIX_FILE.tmp"
        log "probe $s: L4T=${core%%-*}, BSP=${best:-none}"
        if [ -n "$best" ]; then
            found_any=1; fails=0
        else
            fails=$((fails + 1))
        fi
        # 连续两个 suite 一个包都探不到，基本可以判定上游不可达；
        # 继续逐个探测只会让客户干等几分钟。
        if [ "$found_any" = 0 ] && [ "$fails" -ge 2 ]; then
            warn "$fails suites in a row probed empty; upstream looks unreachable, stopping early"
            break
        fi
    done
    mv "$MATRIX_FILE.tmp" "$MATRIX_FILE"
    matrix_has_versions || fallback_matrix
}

matrix_print() {
    printf '\n%s-- QSPI / flash support matrix (source: NVIDIA apt repo + download dir, %s) --%s\n' "$C_B" "$(date +%F)" "$C_N"
    printf '%-8s %-10s %-12s %-12s %s\n' "suite" "L4T(apt)" "BSP" "QSPI capsule" "QSPI-only"
    local s core qspi best all
    while IFS='|' read -r s core qspi best all; do
        [ -n "$s" ] || continue
        local ok="yes"; [ -n "$best" ] || ok="no (apt only)"
        local cap="none"; [ -n "$qspi" ] && cap="yes $qspi"
        printf '%-8s %-10s %-12s %-12s %s\n' "$s" "${core%%-*}" "${best:--}" "$cap" "$ok"
    done < "$MATRIX_FILE"
    printf '\nall flashable versions (BSP package really exists, high to low): %s\n' "$(available_versions 2>/dev/null | tr '\n' ' ')"
    printf 'how to pick: --l4t <version>; interactive runs show a menu when --l4t is omitted (never silently newest)\n' 
    local lt="$WORK_DIR/Linux_for_Tegra"
    if [ -d "$lt/bootloader/generic/cfg" ]; then
        printf '\nQSPI partition configs in the local BSP (which storage backends can be flashed):\n'
        ls "$lt/bootloader/generic/cfg/" 2>/dev/null | grep -E '^flash_t234_qspi.*\.xml$' | sed 's/^/  - /'
        printf 'board models available in the local BSP (values for --board):\n'
        ls "$lt"/jetson-*.conf 2>/dev/null | sed 's#.*/##; s/\.conf$//' | sed 's/^/  - /' | head -20
    fi
    printf '\nofficial GUI tool (full flash only, no QSPI-only mode): https://developer.nvidia.com/sdk-manager\n'
    printf 'QSPI-only third-party references: osrbot/mfi-qspi-forge (production MFI package), Hi5808/turing-pi-2.5-jetson-eeprom-fix (back up the carrier EEPROM first)\n\n'
}

# JetPack → Jetson Linux(L4T) 映射。数据源：NVIDIA 各 JetPack 发布页原文
#   JP 6.0    → 36.3.0   "This JetPack 6.0 release includes Jetson Linux 36.3"
#   JP 6.1    → 36.4.0   "This release includes Jetson Linux 36.4"
#   JP 6.2    → 36.4.3   "includes Jetson Linux 36.4.3"
#   JP 6.2.1  → 36.4.4   "includes Jetson Linux 36.4.4"
#   JP 6.2.2  → 36.5.0   "includes Jetson Linux 36.5"
#   JP 6.2.3  → 36.5.2   "includes Jetson Linux 36.5.2"
#   JP 5.1.3  → 35.4.1
# 注意：映射到具体 L4T 后还要校验"这个 L4T 有没有 BSP 包"，没有就退到最近的可用版本。
jp_to_l4t() {
    local v="$1"
    v="${v#jp}"; v="${v#JP}"; v="${v#v}"; v="${v#JetPack}"; v="${v# }"
    case "$v" in
        6.0|6.0.0)      echo 36.3.0 ;;
        6.1|6.1.0)      echo 36.4.0 ;;
        6.2|6.2.0)      echo 36.4.3 ;;
        6.2.1)          echo 36.4.4 ;;
        6.2.2)          echo 36.5.0 ;;
        6.2.3)          echo 36.5.2 ;;
        5.1.3)          echo 35.4.1 ;;
        5.1.1)          echo 35.3.1 ;;
        *)              return 1 ;;
    esac
}

jp_list() {
    cat <<'EOF'
   JetPack -> Jetson Linux(L4T)
     6.0     -> 36.3.0     6.2    -> 36.4.3     5.1.3 -> 35.4.1
     6.1     -> 36.4.0     6.2.1  -> 36.4.4     5.1.1 -> 35.3.1
                          6.2.2  -> 36.5.0
                          6.2.3  -> 36.5.2   (apt/OTA only, no BSP)
EOF
}

# 给定 L4T，取"不高于它、且确实有 BSP 包"的最近版本
nearest_available() {
    local want="$1" v
    available_versions 2>/dev/null | while IFS= read -r v; do
        [ -n "$v" ] || continue
        [ "$(printf '%s\n%s\n' "$v" "$want" | sort -V | head -1)" = "$v" ] && { printf '%s' "$v"; break; }
    done
}

jp_hint() {
    case "$1" in
        36.5.*) printf 'JetPack 6.2.2' ;;
        36.4.4*) printf 'JetPack 6.2.1' ;;
        36.4.3*) printf 'JetPack 6.2' ;;
        36.4.0*) printf 'JetPack 6.1' ;;
        36.3.*) printf 'JetPack 6.0' ;;
        36.2.*) printf 'JetPack 6.0 DP' ;;
        *) printf '' ;;
    esac
}

available_versions() {
    # 来自上游矩阵：每个 suite 里"确实存在 BSP 包"的所有版本，去重后从高到低
    [ -f "$MATRIX_FILE" ] || return 0
    awk -F'|' '$5!=""{n=split($5,a,","); for(i=1;i<=n;i++) print a[i]}' "$MATRIX_FILE" |
        sort -Vu | tac
}

# 交互选版本：默认高亮最新，但必须由你确认/选择，不再偷偷用最新
pick_l4t_interactive() {
    build_matrix 0
    local vers; vers="$(available_versions)"
    [ -n "$vers" ] || { warn "available versions unavailable; falling back to auto"; L4T_VERSION=auto; return 0; }

    printf '\n%s-- choose the L4T / JetPack version to install (probed from the official download dir) --%s\n' "$C_B" "$C_N"
    local i=0 newest; newest="$(printf '%s\n' "$vers" | head -1)"
    local -a arr=()
    while IFS= read -r v; do
        [ -n "$v" ] || continue
        i=$((i+1)); arr+=("$v")
        local hint; hint="$(jp_hint "$v")"
        printf '   %2d) %-9s %s%s\n' "$i" "$v" "${hint:+$hint}" "$([ "$v" = "$newest" ] && printf '   %s<- newest%s' "$C_D" "$C_N")"
    done <<< "$vers"
    printf '    q) quit\n'
    while :; do
        printf '  choose [1-%d] (Enter = 1, newest %s; or type a version such as 36.4.3)> ' "${#arr[@]}" "$newest"
        local a; IFS= read -r a || { L4T_VERSION=auto; return 0; }
        case "$a" in
            q|Q) die "exited" ;;
            "")  L4T_VERSION="${arr[0]}"; break ;;
            *[!0-9]*) ;;   # 非纯数字 -> 当作版本号处理
        esac
        # 先认 L4T 号（36.x），再认 JetPack 号（6.x / 5.x / jp6.2 …）
        if printf '%s' "$a" | grep -qE '^36\.[0-9]+(\.[0-9]+)?$'; then
            case "$a" in
                *.*.*) L4T_VERSION="$a" ;;
                *)     L4T_VERSION="$(printf '%s\n' "$vers" | grep -E "^$a\." | head -1)" ;;
            esac
            [ -n "$L4T_VERSION" ] && break
            L4T_VERSION=""; warn "no flashable version for L4T $a; pick again"; continue
        fi
        if printf '%s' "$a" | grep -qiE '^(jp)?[0-9]+(\.[0-9]+)+$'; then
            local l4t; if l4t="$(jp_to_l4t "$a")"; then
                if printf '%s\n' "$vers" | grep -qx "$l4t"; then L4T_VERSION="$l4t"; break; fi
                local nv; nv="$(nearest_available "$l4t")"
                if [ -n "$nv" ]; then
                    warn "JetPack $a -> L4T $l4t has no BSP package; falling back to $nv"
                    L4T_VERSION="$nv"; break
                fi
                warn "JetPack $a -> L4T $l4t, but no flashable BSP is available"; continue
            fi
            warn "no such JetPack mapping: $a (see --jp-list)"; continue
        fi
        case "$a" in
            ''|*[!0-9]*) warn "enter an index or a version"; continue ;;
        esac
        if [ "$a" -ge 1 ] && [ "$a" -le "${#arr[@]}" ]; then L4T_VERSION="${arr[$((a-1))]}"; break; fi
        warn "index out of range"
    done
    ok "selected L4T $L4T_VERSION$( [ -n "$(jp_hint "$L4T_VERSION")" ] && printf ' (%s)' "$(jp_hint "$L4T_VERSION")" )"
}

resolve_l4t() {
    # L4T_VERSION 支持 auto/latest/<x.y.z>
    case "$L4T_VERSION" in
        auto|latest|"")
            build_matrix 0
            L4T_VERSION="$(awk -F'|' '$4!=""{print $4}' "$MATRIX_FILE" 2>/dev/null | sort -V | tail -1)"
            [ -n "$L4T_VERSION" ] || die "could not resolve a flashable BSP from upstream (network down? matrix cache $MATRIX_FILE)"
            log "auto-selected newest flashable BSP: L4T $L4T_VERSION"
            ;;
        *)  : ;;
    esac
    refresh_filenames
    if [ "$NEEDS_FALLBACK" = 1 ]; then
        warn "offline fallback: skipping the version probe and trying the download directly"
        return 0
    fi
    if ! url_exists "$(bsp_url "$L4T_VERSION")"; then
        if [ "$SPEC_FROM" = "jp" ]; then
            build_matrix 0
            local nv; nv="$(nearest_available "$L4T_VERSION")"
            if [ -n "$nv" ]; then
                warn "the mapped L4T $L4T_VERSION has no downloadable BSP (apt/OTA only) -> falling back to $nv"
                L4T_VERSION="$nv"; refresh_filenames; return 0
            fi
        fi
        if [ "$SPEC_FROM" = "l4t" ]; then
            # 用户已经点名版本，探测失败多半是网络/代理；交给下载环节报真实错误。
            warn "cannot probe the BSP for L4T $L4T_VERSION (proxy/network?); trying the download anyway"
            warn "if the download fails: set https_proxy for curl, or point --mirror at an internal source"
            return 0
        fi
        warn "no BSP package for L4T $L4T_VERSION in the official download dir (apt/OTA only?)"
        build_matrix 0
        printf 'available versions (with BSP): %s\n' "$(awk -F'|' '$4!=""{print $4}' "$MATRIX_FILE" 2>/dev/null | sort -V | tr '\n' ' ')"
        die "pick another version: --l4t <version>, or --l4t latest to take the newest"
    fi
}

# ======================================================= 校验值（不写死）
manifest_get() { [ -f "$MANIFEST_FILE" ] && grep -m1 -E "[[:space:]]+$1\$" "$MANIFEST_FILE" 2>/dev/null | awk '{print $1}'; }
manifest_put() {
    mkdir -p "$(dirname "$MANIFEST_FILE")" 2>/dev/null
    local name="$1" sha="$2" tmp="$MANIFEST_FILE.tmp"
    { [ -f "$MANIFEST_FILE" ] && grep -vE "[[:space:]]+$name\$" "$MANIFEST_FILE"; echo "$sha  $name"; } > "$tmp" 2>/dev/null
    mv "$tmp" "$MANIFEST_FILE"
}

verify_checksum() {
    local name="$1" f; f="$(pkg_dir)/$1"
    [ "$DRY_RUN" = 1 ] && { log "[dry-run] sha256 verify $f"; return 0; }
    [ -s "$f" ] || { warn "file absent; verification skipped"; return 0; }
    local got want=""
    got="$(sha256sum "$f" | awk '{print $1}')"
    if [ -n "$MANIFEST_URL" ]; then
        want="$(curl -fsSL --max-time 20 "$MANIFEST_URL" 2>/dev/null | awk -v n="$name" '$2==n||$2=="*"n{print $1}' | head -1)"
        [ -n "$want" ] || warn "$name absent from the external manifest; falling back to the local TOFU record"
    fi
    [ -n "$want" ] || want="$(manifest_get "$name")"
    if [ -z "$want" ]; then
        manifest_put "$name" "$got"
        ok "first check passed and recorded locally: $name = $got"
        return 0
    fi
    if [ "$got" = "$want" ]; then ok "sha256 matches the manifest: $name"
    else die "sha256 mismatch (local $got != manifest $want); if upstream really republished, drop that line and rerun: rm $MANIFEST_FILE"; fi
}

# ================================================================ 自更新
self_update() {
    local src="${UPDATE_FROM:-${JETSON_SCRIPT_URL:-}}"
    [ -n "$src" ] || die "no update source: --update-from <url|path>, or set JETSON_SCRIPT_URL"
    local tmp; tmp="$(mktemp)"; local new_sha old_sha
    case "$src" in
        http://*|https://*) curl -fsSL --max-time 60 -o "$tmp" "$src" || die "downloading the new version failed: $src" ;;
        *) [ -f "$src" ] || die "update source not found: $src"; cp -f "$src" "$tmp" ;;
    esac
    bash -n "$tmp" || { rm -f "$tmp"; die "new version failed the syntax check; update abandoned"; }
    new_sha="$(sha256sum "$tmp" | awk '{print $1}')"
    old_sha="$(sha256sum "$0" 2>/dev/null | awk '{print $1}')"
    if [ "$new_sha" = "$old_sha" ]; then rm -f "$tmp"; ok "already the current version (identical sha256)"; return 0; fi
    warn "new version found; replacing (old copy backed up as $(basename "$0").bak.$(date +%s))"
    cp -f "$0" "$0.bak.$(date +%s)" 2>/dev/null || true
    chmod 755 "$tmp"
    if mv -f "$tmp" "$0" 2>/dev/null; then ok "updated: $0"
    else warn "cannot write $0 (read-only/permissions); new version left at $tmp, copy it manually"; fi
    log "new version notes (first 12 lines):"; head -12 "$0" | sed 's/^/    /'
}

# =================================================== 说明文档（自动打开）
doc_target() {
    # 优先本地操作手册 guide.html，其次首页与配置的在线地址
    local c
    for c in "$SCRIPT_DIR/guide.html" "$WORK_DIR/guide.html" "$SCRIPT_DIR/index.html" "$WORK_DIR/index.html" "$SCRIPT_DIR/docs/index.html"; do
        [ -f "$c" ] && { printf '%s' "$c"; return 0; }
    done
    [ -n "$DOC_URL" ] && { printf '%s' "$DOC_URL"; return 0; }
    return 1
}

has_display() { [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || [ -S /tmp/.X11-unix/X0 ] || [ -n "${XDG_SESSION_TYPE:-}" ]; }

open_in_browser() {
    local url="$1"
    if command -v xdg-open >/dev/null 2>&1; then (xdg-open "$url" >/dev/null 2>&1 &) ; return 0; fi
    if command -v gio >/dev/null 2>&1; then (gio open "$url" >/dev/null 2>&1 &) ; return 0; fi
    if command -v sensible-browser >/dev/null 2>&1; then (sensible-browser "$url" >/dev/null 2>&1 &) ; return 0; fi
    if command -v python3 >/dev/null 2>&1; then (python3 -m webbrowser "$url" >/dev/null 2>&1 &) ; return 0; fi
    return 1
}

open_doc() {
    local t; if ! t="$(doc_target)"; then
        warn "no index.html (expected next to the script) and no --doc-url; skipping"
        return 0
    fi
    local url="$t"
    case "$t" in http://*|https://*) ;; *) url="file://$t" ;; esac
    if ! has_display; then
        log "no GUI (headless); docs here: $t"
        [ -n "$DOC_URL" ] && log "online: $DOC_URL"
        return 0
    fi
    if open_in_browser "$url"; then log "opened in the browser: $url"
    else warn "could not open a browser; docs at: $t"; fi
}

maybe_open_doc() {
    [ "$OPEN_DOC" = 0 ] && return 0
    [ "$DRY_RUN" = 1 ] && return 0
    local t; t="$(doc_target)" || return 0
    if ! has_display; then
        log "more (matrix/options/pitfalls): $t"
        return 0
    fi
    if [ "$YES" = 1 ] || [ ! -t 0 ]; then
        open_doc
        return 0
    fi
    printf '  open the docs page (matrix / options / disclaimer)? [Y/n] '
    local a; read -r a
    case "$a" in n|N|no|NO) log "docs path: $t" ;; *) open_doc ;; esac
}

prescan_config() {
    # load_config 必须在 parse_args 之前，但 --config 本身是命令行给的 → 先扫一遍
    local a prev=""
    for a in "$@"; do
        [ "$prev" = "--config" ] && CONFIG_FILE="$a"
        prev="$a"
    done
}

main() {
    prescan_config "$@"
    load_config                 # 先读配置
    parse_args "$@"             # 命令行覆盖配置
    ensure_agreement
    [ -z "$MODE" ] && menu

    # 两个独立动作：看矩阵 / 自更新
    case "$MODE" in
        matrix) build_matrix "$REFRESH"; matrix_print; exit 0 ;;
        update) self_update; exit 0 ;;
        doc)    open_doc; exit 0 ;;
        jpmap)  echo "flashable versions: $(available_versions 2>/dev/null | tr '\n' ' ')"; jp_list; exit 0 ;;
        diag)
            detect_onboard || detect_recovery || DET_MODE="none"
            pick_board
            do_diag
            exit 0 ;;
        uart)
            do_uart
            exit 0 ;;
    esac

    case "$MODE" in nvme|qspi) WITH_ROOTFS=1 ;; esac   # 这两种都要 rootfs,先定下来再算空间
    [ "$AUTO_DIR" = 1 ] && auto_select_dirs "$MODE"

    # 版本：没显式给 --l4t 时，交互就让你选；非交互才回落 auto
    if [ -z "$L4T_VERSION" ]; then
        case "$MODE" in
            qspi|nvme|prep)
                if [ -t 0 ] && [ "$YES" != 1 ] && [ "$DRY_RUN" != 1 ]; then pick_l4t_interactive
                else L4T_VERSION=auto; log "non-interactive; version falls back to auto (newest flashable)"; fi ;;
            *) L4T_VERSION=auto ;;
        esac
    fi
    resolve_l4t                    # auto/latest -> 向上游探测最新可刷 BSP(不写死版本)

    detect_onboard || detect_recovery || DET_MODE="none"
    pick_board
    [ -n "$CACHE_DIR" ] || CACHE_DIR="$WORK_DIR"

    case "$MODE" in
        detect)
            report_detect
            check_requirements detect
            if [ "$DET_MODE" = "onboard" ]; then
                log "onboard check passed. Only --mode target (compute stack) works onboard; use an x86_64 host to flash QSPI or the whole system"
            else
                log "host check passed. Once the board is in recovery: --mode qspi (boot firmware) or --mode nvme (full reflash)"
            fi
            ;;
        target)
            report_detect; check_requirements target; do_target ;;
        prep)
            report_detect; check_requirements prep; do_prep ;;
        qspi)
            report_detect; WITH_ROOTFS=1; check_requirements qspi
            do_prep; do_qspi ;;
        nvme)
            report_detect; WITH_ROOTFS=1; check_requirements nvme
            do_prep; do_nvme ;;
    esac
    ok "all done"
    maybe_open_doc      # 跑完自动提示 / 自动用浏览器打开 index.html
}

# 直接 bash 运行 → 正常执行；被 source 进来（source <(curl ...)）→ 放子壳里跑，
# 中途 exit 只结束子壳，不会把你的终端关掉
# 判"被 source 进来"：直接执行/bash <(...) 时 BASH_SOURCE[0] == $0；
# curl | bash 时 BASH_SOURCE[0] 为空 → 也按直接执行处理（不能 return，会报错）
_self_src="${BASH_SOURCE[0]:-}"
if [ -z "$_self_src" ] || [ "$_self_src" = "$0" ]; then
    main "$@"
else
    ( main "$@" )        # source 调用:放子壳跑,中途 exit 不会关掉调用者终端
    return $?
fi
