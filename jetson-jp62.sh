#!/bin/bash
# =============================================================================
# jetson-jp62.sh — JetPack 6.2 (L4T 36.4.3) 一键安装/刷机，全程无图形界面
#
#   交互菜单          bash jetson-jp62.sh
#   只刷 QSPI         bash jetson-jp62.sh --mode qspi      (UEFI/bootloader，保留系统数据)
#   整机刷 NVMe       bash jetson-jp62.sh --mode nvme      (官方 initrd flash)
#   只下载+解压       bash jetson-jp62.sh --mode prep
#   板内升计算栈      bash jetson-jp62.sh --mode target    (在 Jetson 本机跑)
#   只做体检          bash jetson-jp62.sh --mode detect    (不下载、不刷机)
#
# 特性：
#   - 自动识别板子（板内读 TNSPEC / 主机端看 recovery）并自动挑板型配置
#   - 刷前逐条门槛检查（架构/依赖/磁盘/recovery/USB 链路/BSP 版本/rootfs/权限）
#   - 下载源可换（--mirror / JETSON_MIRROR，http/https/file/本地目录），断点续传+双校验
#   - 首次运行须同意《使用协议与安全声明》，同意后记在 ~/.config/jetson-jp62/
#   - 所有动盘动作先打印再执行；--dry-run 只体检不改动
# =============================================================================

set -o pipefail

# 版本不写死：默认 auto = 运行时向上游探测"存在 BSP 包的最高 L4T 版本"
L4T_VERSION="${L4T_VERSION:-auto}"
L4T_TAG="${L4T_TAG:-}"
BSP_FILENAME=""
ROOTFS_FILENAME=""
BSP_SIZE=""            # 空 = 不预判大小，下完用 bzip2 -t + TOFU 校验
ROOTFS_SIZE=""
BSP_SHA256=""          # 空 = 用本机 TOFU 清单（首次下载后记录），可用 --manifest-url 指外部清单

NV_REPO="https://repo.download.nvidia.com/jetson"
NV_DL_BASE="https://developer.nvidia.com/downloads/embedded"
SUITES="${JETSON_SUITES:-r35.4 r35.5 r35.6 r36.2 r36.3 r36.4 r36.5 r36.6}"   # 可配置，缺的自动跳过
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
UPDATE_FROM=""
OPEN_DOC=1          # 跑完是否提示/自动打开 HTML 说明页（0=关）
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
AGREE_STAMP="$AGREE_DIR/agreed-v1"

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_D=$'\033[2m'; C_N=$'\033[0m'
[ -t 1 ] || { C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_N=""; }

log()  { printf '%s[信息]%s %s\n' "$C_B" "$C_N" "$*"; }
ok()   { printf '%s[完成]%s %s\n' "$C_G" "$C_N" "$*"; }
warn() { printf '%s[注意]%s %s\n' "$C_Y" "$C_N" "$*"; }
die()  { printf '%s[错误]%s %s\n' "$C_R" "$C_N" "$*" >&2; exit 1; }

FAILS=0
chk_ok()   { printf '  %s[ ✓ ]%s %s\n' "$C_G" "$C_N" "$*"; }
chk_bad()  { printf '  %s[ ✗ ]%s %s\n' "$C_R" "$C_N" "$1"; [ -n "${2:-}" ] && printf '        %s修法: %s%s\n' "$C_D" "$2" "$C_N"; FAILS=$((FAILS+1)); }
chk_warn() { printf '  %s[ ! ]%s %s\n' "$C_Y" "$C_N" "$*"; }
chk_info() { printf '  %s[ - ]%s %s\n' "$C_D" "$C_N" "$*"; }

banner() {
cat <<EOF
${C_B}
  ╭──────────────────────────────────────────────────────────────╮
  │   Jetson JetPack 6.2 / L4T ${L4T_VERSION}   一键安装（命令行版）      │
  │   qspi=刷 QSPI  nvme=整机刷  prep=只下载  target=板内升级  detect=体检 │
  ╰──────────────────────────────────────────────────────────────╯
${C_N}
EOF
}

# ============================================================ 协议与安全声明
agreement_text() {
cat <<EOF

${C_Y}┌────────────────────────────────────────────────────────────────────┐
│                使用协议与安全声明（首次运行需同意）                │
└────────────────────────────────────────────────────────────────────┘${C_N}

一、性质
  本脚本是个人整理的辅助工具，按《AS IS》现状提供，仅用于在本机下载 NVIDIA
  公开发布的 JetPack 6.2 / Jetson Linux 36.4.3 组件并调用 NVIDIA 官方
  flash.sh / l4t_initrd_flash.sh 完成刷写。脚本不包含、不分发任何 NVIDIA
  固件或闭源二进制；所有固件版权归 NVIDIA Corporation 所有，其下载与使用受
  NVIDIA 软件许可协议（EULA）及 JetPack 条款约束，下载即表示你接受该等条款。

二、风险（刷机是不可逆的破坏性操作）
  1. 整机刷机（nvme 模式）会格式化目标存储，板上数据、系统与配置全部丢失；
     只刷 QSPI 虽不动系统盘，但错误固件同样可能导致无法开机。
  2. 刷写过程中断电、拔线、USB 接触不良，可能使设备无法启动，需用 recovery
     模式重刷才能恢复。
  3. 在非 NVIDIA 官方底板（第三方载板/机器人整机）上使用官方板型配置，
     可能导致 pinmux、串口、CSI 相机、供电策略异常。
  4. JetPack 6.0/6.1 → 6.2 会带来 TensorRT 8.x→10.x、cuDNN 8.x→9.x 的
     大版本跳变，自编译的 engine、插件与预编译加速库需重新构建。
  5. 以上风险由使用者自行判断与承担。作者不对数据丢失、设备损坏、业务中断、
     合规问题承担任何责任。

三、使用限制
  1. 不得将本脚本用于未经授权的设备、他人资产或任何违法用途。
  2. 二次分发请保留本声明与出处，并自行确保不违反 NVIDIA 许可条款。
  3. "Jetson"、"JetPack"、"NVIDIA" 是 NVIDIA Corporation 的商标，本脚本与
     NVIDIA 无隶属或背书关系。

四、你的确认
  继续即表示你已阅读并同意以上条款，且对目标设备拥有处置权限。

EOF
}

ensure_agreement() {
    [ "$ACCEPTED" = 1 ] && return 0
    [ -f "$AGREE_STAMP" ] && return 0
    banner
    agreement_text
    if [ "$YES" = 1 ]; then
        warn "--yes 已给出，视为同意上述协议"
    else
        printf '输入 %s同意%s 继续（其他任何输入则退出）: ' "$C_G" "$C_N"
        local a; read -r a
        [ "$a" = "同意" ] || [ "$a" = "agree" ] || { log "未同意协议，退出"; exit 0; }
    fi
    mkdir -p "$AGREE_DIR" 2>/dev/null && date -Is > "$AGREE_STAMP" 2>/dev/null
    ok "已记录同意（$AGREE_STAMP，删除该文件可重新显示协议）"
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
        7523) DET_BOARD_SUGGEST=""; chk_info "recovery 设备 0955:7523（Orin 系列 t234）" ;;
        *)    chk_warn "recovery 设备 0955:$pid（非 t234 常见值，本脚本按 Orin 处理）" ;;
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
        log "板型由参数指定: $BOARD"
    elif [ -n "$DET_BOARD_SUGGEST" ]; then
        BOARD="$DET_BOARD_SUGGEST"
        log "自动识别板型: $BOARD"
    else
        BOARD="jetson-orin-nano-devkit-super"
        warn "无法自动识别板型，按默认 $BOARD 处理（可用 --board 指定，--list-boards 看全部）"
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
        qspi) dl=$SPACE_DL_BSP; ex=$SPACE_EX_BSP ;;
        prep) dl=$SPACE_DL_BSP; ex=$SPACE_EX_BSP
              [ "$WITH_ROOTFS" = 1 ] && { dl=$((dl+SPACE_DL_ROOTFS)); ex=$((ex+SPACE_EX_ROOTFS+SPACE_APPLY)); } ;;
        nvme) dl=$((SPACE_DL_BSP+SPACE_DL_ROOTFS)); ex=$((SPACE_EX_BSP+SPACE_EX_ROOTFS+SPACE_APPLY)); tmp=$SPACE_FLASH_TMP ;;
        target) dl=0; ex=0; tmp=0 ;;
        *) dl=0; ex=0 ;;
    esac
    [ "$have_bsp" = 1 ] && dl=$((dl-SPACE_DL_BSP))
    [ "$have_rfs" = 1 ] && dl=$((dl-SPACE_DL_ROOTFS))
    [ "$dl" -lt 0 ] && dl=0
    printf '%d %d %d\n' "$dl" "$ex" $((dl+ex+tmp+SPACE_LOG+SPACE_SLACK))
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
    local plan dl ex total
    plan="$(space_plan "$mode")"
    dl="$(echo "$plan" | cut -d' ' -f1)"
    ex="$(echo "$plan" | cut -d' ' -f2)"
    total="$(echo "$plan" | cut -d' ' -f3)"
    local cache="${CACHE_DIR:-$WORK_DIR}"
    mkdir -p "$cache" 2>/dev/null; mkdir -p "$WORK_DIR" 2>/dev/null

    if [ "$mode" = "target" ]; then
        local fm; fm="$(free_mb /)"; local pct; pct="$(used_pct /)"
        if [ "${fm:-0}" -ge "$((9*1024))" ] && [ "${pct:-0}" -lt 90 ]; then
            chk_ok "系统盘 / 可用 $(mb2g "${fm:-0}")（已用 ${pct}%），apt dist-upgrade 够用"
        else
            chk_bad "系统盘 / 可用 $(mb2g "${fm:-0}")、已用 ${pct}%，apt 升级需要 ≥9G" "sudo apt clean; sudo journalctl --vacuum-size=200M; 清旧内核"
        fi
        return 0
    fi

    local fcache fwork pctc pctw totalg
    fcache="$(free_mb "$cache")"; fwork="$(free_mb "$WORK_DIR")"
    pctc="$(used_pct "$cache")"; pctw="$(used_pct "$WORK_DIR")"
    totalg="$(mb2g "$total")"

    local dl_pct=$(( pctc + 0 ))
    case "$(fs_type "$cache")" in
        ext2|ext3|ext4|xfs|btrfs|zfs) chk_ok "下载目录 $cache：$(fs_type "$cache")，支持权限/软链" ;;
        *) chk_bad "下载目录 $cache 是 $(fs_type "$cache")" "NTFS/exFAT/vfat 存 rootfs 会丢权限与软链，必须换 ext4/xfs/btrfs" ;;
    esac
    case "$(fs_type "$WORK_DIR")" in
        ext2|ext3|ext4|xfs|btrfs|zfs|overlay) chk_ok "工作目录 $WORK_DIR：$(fs_type "$WORK_DIR")" ;;
        *) chk_bad "工作目录 $WORK_DIR 是 $(fs_type "$WORK_DIR")" "换成 ext4/xfs/btrfs 的分区（--dir）" ;;
    esac

    if [ "$cache" = "$WORK_DIR" ]; then
        local need_total=$(( total ))
        if [ "$fwork" -ge "$need_total" ]; then
            chk_ok "工作目录 $WORK_DIR 可用 $(mb2g "$fwork")（已用 ${pctw}%），本模式峰值约 $totalg，余量 $(mb2g $((fwork-need_total)))"
            [ "$pctw" -lt 85 ] || chk_warn "该分区已用 ${pctw}%，接近满盘：刷机中途写日志/镜像容易失败"
        else
            chk_bad "工作目录只剩 $(mb2g "$fwork")，本模式峰值需要 $totalg（下载$(mb2g $dl)+解压$(mb2g $ex)+临时）" \
                    "换盘：$(pick_hint "$total") ；或加 --auto-dir 让脚本自动选"
        fi
    else
        if [ "$fcache" -ge "$dl" ]; then chk_ok "下载目录 $cache 可用 $(mb2g "$fcache")（已用 ${pctc}%），需装下 $(mb2g $dl)"
        else chk_bad "下载目录只剩 $(mb2g "$fcache")，需要 $(mb2g $dl)" "换 --cache-dir 到大盘，或加 --auto-dir"; fi
        if [ "$fwork" -ge "$((ex+SPACE_FLASH_TMP+SPACE_LOG+SPACE_SLACK))" ]; then
            chk_ok "工作目录 $WORK_DIR 可用 $(mb2g "$fwork")，解压+临时约 $(mb2g $((ex+SPACE_FLASH_TMP+SPACE_LOG)))"
        else
            chk_bad "工作目录只剩 $(mb2g "$fwork")，解压+临时需要 $(mb2g $((ex+SPACE_FLASH_TMP+SPACE_LOG)))" \
                    "换盘：$(pick_hint "$total") ；或加 --auto-dir"
        fi
    fi
}

pick_hint() {
    local need_mb="$1" out
    out="$(hash_mounts "$need_mb")"
    if [ -n "$out" ]; then
        printf '可选挂载点 %s' "$(printf '%s' "$out" | awk '{print $3}' | tr '\n' ' ')"
    else
        printf '本机没有余量足够的其它分区，先清理或外接硬盘'
    fi
}

check_requirements() {
    local mode="$1" lt="$WORK_DIR/Linux_for_Tegra"
    FAILS=0
    echo
    printf '%s── 刷入前检查（%s 模式）──%s\n' "$C_B" "$mode" "$C_N"

    # 1 运行位置 / 主机架构
    local arch; arch="$(uname -m)"
    if [ "$DET_MODE" = "onboard" ]; then
        chk_ok "运行在 Jetson 本机（$arch），板内识别有效"
        [ "$mode" = "qspi" ] || [ "$mode" = "nvme" ] && \
            chk_bad "不能在板内自己刷自己（$arch）" "把板子短接 FC REC 接到 x86_64 主机上，在那台机器跑同一命令"
    elif [ "$mode" != "target" ]; then
        [ "$arch" = "x86_64" ] && chk_ok "主机架构 x86_64" || chk_bad "主机架构 $arch 不是 x86_64" "刷机要用 x86_64 主机；若这是 Jetson 本机请用 --mode target"
    fi

    # 2 系统版本（只提示，不拦）
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        case "${VERSION_ID:-}" in
            20.04|22.04) chk_ok "主机系统 ${PRETTY_NAME}（NVIDIA 官方支持）" ;;
            24.04|24.10|25.*) chk_warn "主机系统 ${PRETTY_NAME}：NVIDIA 官方只写 20.04/22.04，实测依赖可满足，按可用处理" ;;
            *) chk_warn "主机系统 ${PRETTY_NAME}：未验证，缺依赖时用 --no-deps 自行处理" ;;
        esac
    fi

    # 3 基础命令
    local miss=() p
    for p in curl tar bzip2 python3; do command -v "$p" >/dev/null 2>&1 || miss+=("$p"); done
    [ ${#miss[@]} -eq 0 ] && chk_ok "基础命令 curl/tar/bzip2/python3 齐全" || chk_bad "缺命令: ${miss[*]}" "sudo apt install ${miss[*]}"

    # 4 磁盘冗余（下载目录 + 工作目录分开算，含文件系统类型）
    check_disk "$mode"

    # 5 BSP 是否就位且版本对
    if [ -f "$lt/nv_tegra/bsp_version" ]; then
        local have; have="$(awk -F= '/^BSP_BRANCH=/{b=$2}/^BSP_MAJOR=/{m=$2}/^BSP_MINOR=/{n=$2}END{print b"."m"."n}' "$lt/nv_tegra/bsp_version")"
        if [ "$have" = "$L4T_VERSION" ]; then
            chk_ok "BSP 已解压且版本 ${have}"
        elif [ "$mode" = "detect" ]; then
            chk_warn "已有 BSP 是 ${have}，目标 ${L4T_VERSION}（体检不拦；真刷时会先备份旧目录再重解）"
        else
            chk_bad "已有 BSP 是 ${have}，目标 ${L4T_VERSION}" "去掉旧目录或换 --dir；脚本也会先备份再重解"
        fi
    else
        [ "$mode" = "detect" ] && chk_info "BSP 未解压（detect 模式不拦）" || chk_info "BSP 未解压，本次会下载解压"
    fi

    # 6 板型配置是否存在
    if [ -d "$lt" ]; then
        [ -f "$lt/${BOARD}.conf" ] && chk_ok "板型配置存在: ${BOARD}.conf" \
            || chk_bad "BSP 里没有 ${BOARD}.conf" "--list-boards 看可用板型，再用 --board 指定"
    fi

    # 7 rootfs（只有整机刷需要）
    if [ "$mode" = "nvme" ]; then
        if [ -f "$lt/rootfs/etc/nv_tegra_release" ]; then chk_ok "rootfs 已 apply_binaries"
        else chk_info "rootfs 未准备，本次会下 1.83G sample rootfs 并 apply_binaries"; fi
    fi

    # 8 recovery 设备 + USB 链路
    if [ "$mode" = "qspi" ] || [ "$mode" = "nvme" ]; then
        if lsusb 2>/dev/null | grep -qiE "0955:7(523|22)"; then
            chk_ok "检测到 recovery 设备（0955:$(lsusb | grep -oiE '0955:[0-9a-f]{4}' | head -1 | cut -d: -f2)）"
            local sp; sp="$(usb_speed || echo '')"
            case "$sp" in
                5000*|10000*) chk_ok "USB 链路 ${sp} Mbps" ;;
                "") chk_warn "读不到 USB 链路速率（不影响刷，但慢）" ;;
                *) chk_warn "USB 链路 ${sp} Mbps（USB2，刷写会慢很多，建议换 USB3 口/线）" ;;
            esac
        else
            chk_warn "当前没有 recovery 设备（不致命：刷写前会等你短接，按回车一直刷新到检测到为止）"
        fi
    fi

    # 9 提权
    if [ "$mode" = "qspi" ] || [ "$mode" = "nvme" ] || [ "$mode" = "target" ]; then
        if [ "$(id -u)" = 0 ] || sudo -n true 2>/dev/null; then chk_ok "sudo 可用（免密）"
        else chk_warn "sudo 需要输入密码，运行时会提示你输入"; fi
    fi

    # 10 板内专属检查
    if [ "$DET_MODE" = "onboard" ]; then
        chk_info "板内识别: TNSPEC=${DET_TNSPEC:-未知} L4T=${DET_L4T:-未知} Super=${DET_SUPER} 启动盘=${DET_STORAGE:-未知}"
        local fdt; fdt="$(grep -hiE '^[[:space:]]*(FDT|DEVICETREE)[[:space:]]' /boot/extlinux/extlinux.conf 2>/dev/null | awk '{print $NF}' | head -2 | tr '\n' ' ')"
        if [ -z "$fdt" ]; then
            chk_ok "extlinux 未指定自定义 FDT（用 UEFI 按 TNSPEC 自动选 dtb）"
        elif printf '%s' "$fdt" | grep -qE 'kernel_tegra234-p(3767|3768)' ; then
            chk_ok "extlinux 用的 dtb 属 NVIDIA 官方目录（$(basename "$fdt")）"
        else
            chk_warn "extlinux 指向非官方 dtb（$fdt）→ 刷 QSPI 前先备份 /boot 与厂商补丁"
        fi
        local uefi_target_major; uefi_target_major="$(printf '%s' "$L4T_VERSION" | cut -d. -f1-2)"
        if [ -n "$DET_UEFI" ]; then
            case "$DET_UEFI" in
                "$uefi_target_major".*) chk_ok "QSPI/UEFI 已是 ${DET_UEFI}（与目标 ${L4T_VERSION} 同代，无需再刷 QSPI）" ;;
                *) chk_warn "QSPI/UEFI 是 ${DET_UEFI}，目标 ${L4T_VERSION} → 需要刷 QSPI 才能拿到 Super/新 bootloader" ;;
            esac
        fi
        if [ "$mode" = "target" ]; then
            local f; f="$(free_gb /)"
            if [ "$f" -ge 8 ]; then chk_ok "系统盘可用 ${f}G"
            else chk_bad "系统盘只剩 ${f}G，apt dist-upgrade 需要 ≥8G" "先清 /var/cache/apt、旧内核"; fi
        fi
    fi

    echo
    if [ "$FAILS" -gt 0 ]; then
        die "有 ${FAILS} 项不满足，先按上面的“修法”处理再跑（体检不算改动）"
    fi
    ok "检查项全部通过"
    echo
}

# ================================================================ 参数/工具
usage() {
cat <<EOF
用法: bash $(basename "$0") [选项]

  --mode <detect|qspi|nvme|prep|target>  执行模式（不给则进交互菜单）
  --board <名字>                  强制板型配置（默认自动识别，--list-boards 看全部）
  --dir <路径>                    工作目录（默认脚本所在目录 / \$JETSON_DIR）
  --mirror <源[,源2...]>          下载源，支持 http/https/file:// 或本地目录
  --offline --src <目录>          完全离线：从本地目录取 tbz2
  --with-rootfs                   prep 模式顺带下 sample rootfs
  --rootdev <设备>                flash.sh 的 rootdev（默认按启动盘推断）
  --skip-recovery-check           不检查 recovery，强行进入刷写（失败自负）
  --no-deps                       不自动 apt 装主机依赖
  --accept                        跳过协议交互（等同已同意，自动化可用）
  --yes                           不再逐次确认
  --cache-dir <路径>              下载包存放/复用目录（= --resource，默认跟 --dir 同一个盘）
  --auto-dir                      自动挑余量最大的分区当工作目录（含下载缓存）
  --config <文件>                 读取配置（默认 ~/.config/jetson-jp62/config，KEY=VALUE）
  --l4t <版本|latest>             目标 L4T 版本，默认 auto=向上游探测最新有 BSP 的版本
  --doc                           打开使用说明页（index.html）
  --doc-url <url>                 在线文档地址（无本地 index.html 时用）
  --no-doc                        跑完不提示打开文档
  --matrix                        打印 QSPI/刷机支持矩阵（上游 apt 仓库 + 官方下载目录实时探测）
  --refresh                       强制重取上游矩阵缓存
  --manifest-url <url>            用外部 sha256 清单校验下载包（默认用本机 TOFU 清单）
  --self-update                   从 --update-from / JETSON_SCRIPT_URL 更新脚本自身
  --update-from <url|路径>        更新源
  --dry-run                       只体检、只打印，不下载不改动
  --list-boards                   列出 BSP 里可用的板型配置
  -h, --help                      显示本帮助

环境变量: JETSON_MIRROR  JETSON_DIR  JETSON_BOARD  L4T_VERSION
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
url_exists() { curl -sIL --max-time 12 "$1" 2>/dev/null | grep -q '^HTTP/2 200'; }

refresh_filenames() {
    [ -n "$L4T_TAG" ] || L4T_TAG="$(tag_for_version "$L4T_VERSION")"
    BSP_FILENAME="Jetson_Linux_R${L4T_VERSION}_aarch64.tbz2"
    ROOTFS_FILENAME="Tegra_Linux_Sample-Root-Filesystem_R${L4T_VERSION}_aarch64.tbz2"
    DEFAULT_MIRROR="$NV_DL_BASE/l4t/${L4T_TAG}/release"
    BSP_SIZE=""; ROOTFS_SIZE=""        # 不预判大小：bzip2 -t + TOFU 清单校验
}

load_config() {
    local f="${CONFIG_FILE:-$AGREE_DIR/config}"
    [ -n "$CONFIG_FILE" ] && [ ! -f "$f" ] && die "配置文件不存在: $f"
    [ -f "$f" ] || return 0
    log "读取配置: $f"
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
            *) warn "配置里忽略未知项: $k" ;;
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
        warn "没找到余量 ≥$(mb2g "$total") 的可写分区，继续用当前目录（体检会拦）"
        return 0
    fi
    local fm mnt; fm="${best%%|*}"; mnt="${best#*|}"
    local base="$mnt/jetson-jp62"
    [ "$mnt" = "/" ] && base="/var/tmp/jetson-jp62"
    log "自动选盘: $mnt（可用 $(mb2g "$fm")，本模式峰值约 $(mb2g "$total")）→ $base"
    [ "$WORK_DIR" = "$SCRIPT_DIR" ] || warn "已被 --dir/配置指定的工作目录 $WORK_DIR 将被覆盖为 $base"
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
            --l4t)      L4T_VERSION="${2:-}"; shift 2 ;;
            --matrix)   MODE="matrix"; shift ;;
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
            -h|--help)  usage ;;
            *) die "未知参数: $1（--help 看用法）" ;;
        esac
    done
    case "$MODE" in
        ""|detect|qspi|nvme|prep|target|matrix|update|doc) ;;
        *) die "--mode 只能是 detect / qspi / nvme / prep / target（另有 --matrix / --self-update / --doc 三个动作）" ;;
    esac
}

list_boards() {
    local d="$WORK_DIR/Linux_for_Tegra"
    [ -d "$d" ] || { warn "还没有解压 BSP，先跑：bash $(basename "$0") --mode prep"; return; }
    ( cd "$d" && ls jetson-*.conf 2>/dev/null | sed 's/\.conf$//' )
}

run_root() {
    if [ "$DRY_RUN" = 1 ]; then log "[dry-run] 会执行: $*"; return 0; fi
    if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi
}

install_deps() {
    [ "$SKIP_DEPS" = 1 ] && { warn "跳过依赖安装（--no-deps）"; return 0; }
    local d="$WORK_DIR/Linux_for_Tegra"
    if [ -x "$d/tools/l4t_flash_prerequisites.sh" ]; then
        log "安装 NVIDIA 官方列出的主机依赖"
        run_root "$d/tools/l4t_flash_prerequisites.sh" || die "依赖安装失败；可手工装好后加 --no-deps 重跑"
    else
        local miss=() p
        for p in curl bzip2 tar python3 file rsync; do command -v "$p" >/dev/null 2>&1 || miss+=("$p"); done
        [ ${#miss[@]} -eq 0 ] || { run_root apt-get update && run_root apt-get install -y "${miss[@]}" || die "基础依赖安装失败"; }
    fi
    ok "主机依赖就绪"
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

fetch() {
    local name="$1" size="$2" local_src="${3:-}" dst
    dst="$(pkg_dir)/$1"
    mkdir -p "$(pkg_dir)" 2>/dev/null || true
    if [ -s "$dst" ]; then
        local got; got="$(stat -c%s "$dst")"
        [ -n "$size" ] && [ "$got" = "$size" ] && { log "已存在且大小对得上，复用: $name"; return 0; }
        [ "$DRY_RUN" = 1 ] || warn "已存在但大小不符（$got/$size），续传"
    fi
    if [ -n "$local_src" ] && [ -f "$local_src/$name" ]; then
        log "离线拷贝: $local_src/$name"
        [ "$DRY_RUN" = 1 ] && { log "[dry-run] cp $local_src/$name $dst"; return 0; }
        cp -f "$local_src/$name" "$dst" && return 0
    fi
    local m
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        log "下载 $name ← $m"
        [ "$DRY_RUN" = 1 ] && { log "[dry-run] curl -fL -C - -o $dst ${m}/${name}"; return 0; }
        if curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -C - -o "$dst" "${m}/${name}"; then
            local got; got="$(stat -c%s "$dst")"
            [ -n "$size" ] && [ "$got" != "$size" ] && { warn "大小不符（$got/$size），换源"; rm -f "$dst"; continue; }
            return 0
        fi
        warn "该源失败，换下一个"
    done < <(mirror_list)
    die "全部源都下不动: $name；用 --mirror 指定内网/本地源（支持 file:// 与目录）"
}

verify_tbz2() {
    local f; f="$(pkg_dir)/$1"
    if [ "$DRY_RUN" = 1 ]; then log "[dry-run] bzip2 -t $f"; return 0; fi
    [ -s "$f" ] || die "缺文件: $f"
    log "校验压缩包: $1"
    bzip2 -t "$f" || die "压缩包损坏，删掉重下: rm '$f'"
}

# ============================================================ 解压 / 应用
extract_bsp() {
    local lt="$WORK_DIR/Linux_for_Tegra"
    if [ -d "$lt" ] && [ -f "$lt/nv_tegra/bsp_version" ]; then
        local have; have="$(awk -F= '/^BSP_BRANCH=/{b=$2}/^BSP_MAJOR=/{m=$2}/^BSP_MINOR=/{n=$2}END{print b"."m"."n}' "$lt/nv_tegra/bsp_version")"
        [ "$have" = "$L4T_VERSION" ] && { log "BSP 已解压且版本正确（$have）"; return 0; }
        warn "已有 Linux_for_Tegra 是 $have，与目标 $L4T_VERSION 不符 → 备份后重解"
        [ "$DRY_RUN" = 1 ] || run_root mv "$lt" "${lt}.bak.$(date +%s)"
    fi
    log "解压 $BSP_FILENAME"
    [ "$DRY_RUN" = 1 ] && { log "[dry-run] tar -xjf $(pkg_dir)/$BSP_FILENAME -C $WORK_DIR"; return 0; }
    tar -xjf "$(pkg_dir)/$BSP_FILENAME" -C "$WORK_DIR" || die "解压 BSP 失败"
    ok "BSP 解压完成: $lt"
}

extract_rootfs() {
    local lt="$WORK_DIR/Linux_for_Tegra"
    if [ -f "$lt/rootfs/etc/nv_tegra_release" ]; then
        log "rootfs 看起来已经 apply 过，跳过解压"
    else
        log "解压 sample rootfs"
        [ "$DRY_RUN" = 1 ] && log "[dry-run] tar -xjpf $(pkg_dir)/$ROOTFS_FILENAME -C $lt/rootfs" \
                          || run_root tar -xjpf "$(pkg_dir)/$ROOTFS_FILENAME" -C "$lt/rootfs" || die "解压 rootfs 失败"
    fi
    log "apply_binaries.sh"
    run_root bash -lc "cd '$lt' && ./apply_binaries.sh" || die "apply_binaries.sh 失败"
    ok "rootfs 准备完成"
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
    [ -n "$lines" ] || { printf '  当前 USB 上没有任何 NVIDIA 设备（0955:*）\n'; return 0; }
    printf '%s  当前看到的 NVIDIA USB 设备:%s\n' "$C_D" "$C_N"
    local pid
    while IFS= read -r l; do
        [ -n "$l" ] || continue
        pid="$(printf '%s' "$l" | grep -oiE '0955:[0-9a-f]{4}' | head -1 | cut -d: -f2 | tr 'A-F' 'a-f')"
        if printf '%s' "$l" | grep -qiE 'APX'; then
            printf '    %s · 0955:%s → recovery/APX，✓ 就是这个，按回车即可\n' "$C_G" "$pid"
            local prod
            prod="$(lsusb -v -d "0955:$pid" 2>/dev/null | grep -i 'iProduct' | head -1 | sed 's/.*iProduct *//; s/^ *[0-9]* *//')"
            case "$prod" in
                ""|APX) printf '      %s 产品串是 "%s"，APX 模式不会告诉你模组型号；板型以刷写日志里的 Board ID/sku 为准%s\n' "$C_D" "${prod:-空}" "$C_N" ;;
                *)      printf '      %s 产品串: %s（可据此核对模组/载板）%s\n' "$C_D" "$prod" "$C_N" ;;
            esac
            continue
        fi
        case "$pid" in
            7523|7522|7623) printf '    %s · 0955:%s → recovery/APX，✓ 就是这个，按回车即可\n' "$C_G" "$pid" ;;
            7020|7018|7418)
                printf '    %s · 0955:%s → L4T 已经正常启动（USB device/gadget 模式），不是 recovery\n' "$C_R" "$pid"
                printf '      %s 说明线是好的、板子有电，只是没进 recovery：断电 → 保持短接 → 上电 2 秒后再松开\n' "$C_D"
                printf '      %s 顺带：这种状态下主机通常有 usb0/192.168.55.x，可 ssh ubuntu@192.168.55.1 确认是哪块板\n' "$C_D" ;;
            *) printf '    %s · 0955:%s → 未知/其它模式\n' "$C_Y" "$pid" ;;
        esac
    done <<< "$lines"
}

print_recovery_howto() {
    cat <<EOF

  ${C_Y}板子现在不在 recovery 模式。${C_N}
    1) 断电，把 FC REC 与 GND 短接（Orin Nano DevKit：12 针排针第 9、10 脚）
    2) 保持短接上电，等 2 秒后松开
    3) USB-C（要能传数据的口/线）接回本机
    4) 本机确认：${C_B}lsusb | grep 0955${C_N}  应出现 0955:7523 NVIDIA Corp. APX
   提示：进 recovery 后板子不会显示为新磁盘，只在 lsusb 里出现，属正常。

EOF
}

# 刷写前的 recovery 闸门：没检测到就一直让用户手动按回车刷新（不自动轮询、不超时）
# 返回 0 = 可以继续刷；1 = 放弃（EOF/非交互时等不到人）
wait_recovery() {
    [ "$DRY_RUN" = 1 ] && { log "[dry-run] 跳过 recovery 检测"; return 0; }
    command -v lsusb >/dev/null 2>&1 || run_root apt-get install -y usbutils >/dev/null 2>&1

    if recovery_present; then ok "recovery 设备已就位"; return 0; fi
    if [ "$RECOVERY_SKIP" = 1 ]; then
        warn "按 --skip-recovery-check 跳过检测，直接刷（recovery 没进的话刷写必然失败）"
        return 0
    fi

    print_recovery_howto
    usb_state_hint
    local key n=0
    while :; do
        n=$((n + 1))
        if [ ! -t 0 ]; then
            warn "没有检测到 recovery 设备，且当前不是交互终端（无法按键刷新）"
            warn "请在终端里重跑本命令，或先在别的终端把板子切到 recovery 再回来"
            return 1
        fi
        printf '  %s→ 板子短接好并上电后，按 [回车] 刷新检测%s   [s] 跳过检测强行刷   [q] 退出   （第 %d 次）> ' \
               "$C_Y" "$C_N" "$n"
        if ! IFS= read -rsn1 key; then warn "输入结束，放弃"; return 1; fi   # 单键即生效，回车=刷新
        case "$key" in
            q|Q) die "已退出（板子没进 recovery）" ;;
            s|S) warn "跳过 recovery 检测，直接进入刷写（失败请回来重跑）"; return 0 ;;
        esac
        if recovery_present; then ok "检测到 recovery 设备（第 ${n} 次刷新）"; return 0; fi
        warn "还是没进 recovery。常见原因：没在断电状态下保持短接就上电 / 短错脚位 / USB 线只充电不传数据"
        usb_state_hint
        log "弄好后继续按 [回车] 刷新，我这边一直等着"
    done
}

confirm_flash() {
    [ "$YES" = 1 ] && return 0
    [ "$DRY_RUN" = 1 ] && return 0
    printf '%s即将执行：%s，继续？[y/N] %s' "$C_Y" "$1" "$C_N"
    local a; read -r a
    case "$a" in y|Y|yes|YES) ;; *) die "已取消" ;; esac
}

verify_flash_log() {
    # 刷写日志里 NVIDIA 会打印 EEPROM 读到的板子信息，与所选配置对不上就报警
    local logf="$1" got
    got="$(grep -m1 -oE 'Board ID\([^)]*\) version\([^)]*\) sku\([^)]*\) revision\([^)]*\)' "$logf" 2>/dev/null)"
    [ -n "$got" ] || { chk_warn "刷写日志里没找到 Board ID 行，无法二次核对板型"; return 0; }
    log "EEPROM 读到: $got"
    local sku; sku="$(printf '%s' "$got" | sed -n 's/.*sku(\([^)]*\)).*/\1/p')"
    case "$BOARD:$sku" in
        *-super*:0004|*-super*:0005) chk_ok "板型与 EEPROM sku 匹配（$sku）" ;;
        *devkit*:0004|*devkit*:0005) chk_ok "板型与 EEPROM sku 匹配（$sku）" ;;
        *) chk_warn "板型 $BOARD 与 EEPROM sku($sku) 可能不匹配，建议 --board 换成对应配置后重刷" ;;
    esac
}

# ==================================================================== 刷机
do_qspi() {
    local lt="$WORK_DIR/Linux_for_Tegra" logf="$WORK_DIR/flash-qspi.log"
    [ -x "$lt/flash.sh" ] || die "缺 flash.sh，先跑 --mode prep"
    confirm_flash "只刷 QSPI（UEFI/bootloader），板型 $BOARD，不动系统盘数据"
    wait_recovery || die "没有进入 recovery，已放弃本次刷写（板子就绪后重跑同一条命令即可）"
    local cmd=(./flash.sh --no-systemimg -c bootloader/generic/cfg/flash_t234_qspi.xml "$BOARD" "$ROOTDEV")
    log "命令: sudo ${cmd[*]}"
    if [ "$DRY_RUN" = 1 ]; then log "[dry-run] 到此为止，不执行"; return 0; fi
    ( cd "$lt" && run_root "${cmd[@]}" 2>&1 | tee "$logf" ) || die "flash.sh 失败（见 $logf）"
    verify_flash_log "$logf"
    ok "QSPI 刷写完成"
    cat <<EOF

板子重启后自检（在板内跑）：
  nvbootctrl dump-slots-info   # Current version 应为 36.4.x
  nvpmodel -q                  # 期望 MAXN_SUPER（需 super 板型 + 36.4 UEFI）
  head -3 /etc/nv_boot_control.conf   # TNSPEC 应带 -super

EOF
}

do_nvme() {
    local lt="$WORK_DIR/Linux_for_Tegra" logf="$WORK_DIR/flash-nvme.log"
    [ -x "$lt/tools/kernel_flash/l4t_initrd_flash.sh" ] || die "缺 l4t_initrd_flash.sh（先 --mode prep --with-rootfs）"
    [ -f "$lt/rootfs/etc/nv_tegra_release" ] || die "rootfs 未准备：先 --mode prep --with-rootfs"
    confirm_flash "整机刷到 NVMe（QSPI+系统全刷，目标盘数据会丢）"
    wait_recovery || die "没有进入 recovery，已放弃本次刷写（板子就绪后重跑同一条命令即可）"
    local cmd=(./tools/kernel_flash/l4t_initrd_flash.sh
               --external-device nvme0n1p1
               -p "-c ./bootloader/generic/cfg/flash_t234_qspi.xml"
               -c ./tools/kernel_flash/flash_l4t_t234_nvme.xml
               --showlogs --network usb0 "$BOARD" external)
    log "命令: sudo ${cmd[*]}"
    if [ "$DRY_RUN" = 1 ]; then log "[dry-run] 到此为止，不执行"; return 0; fi
    ( cd "$lt" && run_root "${cmd[@]}" 2>&1 | tee "$logf" ) || die "initrd flash 失败（见 $logf）"
    verify_flash_log "$logf"
    ok "整机刷写完成（用户名/密码在首启创建，可用 tools/l4t_create_default_user.sh 预置）"
}

do_prep() {
    local src=""
    if [ -n "$OFFLINE_SRC" ]; then
        src="$OFFLINE_SRC"; [ "$src" = "auto" ] && src="$WORK_DIR"
        [ -d "$src" ] || die "离线源目录不存在: $src"
        log "离线模式：从 $src 取包"
    fi
    fetch "$BSP_FILENAME" "$BSP_SIZE" "$src"
    verify_tbz2 "$BSP_FILENAME"
    verify_checksum "$BSP_FILENAME"
    extract_bsp
    install_deps
    if [ "$WITH_ROOTFS" = 1 ]; then
        fetch "$ROOTFS_FILENAME" "$ROOTFS_SIZE" "$src"
        verify_tbz2 "$ROOTFS_FILENAME"
        extract_rootfs
    fi
    ok "准备完成: $WORK_DIR/Linux_for_Tegra"
}

do_target() {
    local rel; rel="$(grep -m1 '^# R' /etc/nv_tegra_release 2>/dev/null)"
    log "当前 L4T: ${rel:-未知}"
    if [ "$DRY_RUN" = 1 ]; then
        log "[dry-run] 把 nvidia-l4t-apt-source.list 里的 r36.x 改成 r36.4 后 apt dist-upgrade"
        return 0
    fi
    warn "这条会升级板上 BSP 包：TensorRT 8.x→10.x、cuDNN 8.x→9.x，自编 engine 需重建"
    confirm_flash "在 Jetson 上把 L4T 包升到 36.4（官方 apt 升级路径）"
    local f=/etc/apt/sources.list.d/nvidia-l4t-apt-source.list
    [ -f "$f" ] || die "没有 $f，不是标准 L4T 系统"
    run_root cp "$f" "$f.bak.$(date +%s)"
    run_root sed -i -E 's#jetson/(common|t234|ffmpeg) r36\.[0-9]+#jetson/\1 r36.4#g' "$f"
    run_root apt-get update
    run_root apt-get -y dist-upgrade || warn "dist-upgrade 有报错，继续尝试修复"
    run_root apt-get install -y --fix-broken -o Dpkg::Options::="--force-overwrite" || true
    ok "完成，物理重启后 nvbootctrl dump-slots-info 应显示 36.4.x"
}

# ==================================================================== 菜单
menu() {
    banner
    echo "  请选择要做什么（输入序号）："
    echo "    1) 体检：自动识别板子 + 检查能不能刷（不改任何东西）"
    echo "    2) 只刷 QSPI（UEFI/bootloader 升 36.4.3，系统盘数据保留）"
    echo "    3) 整机刷到 NVMe（QSPI + 系统全刷，目标盘会格式化）"
    echo "    4) 只下载 + 解压（离线缓存，可带 sample rootfs）"
    echo "    5) 在 Jetson 本机：apt 升计算栈到 6.2（不重刷）"
    echo "    6) 打开使用说明页（支持矩阵 / 参数 / 免责声明）"
    echo "    0) 退出"
    printf '  输入: '
    local a; read -r a
    case "$a" in
        1) MODE=detect ;;
        2) MODE=qspi ;;
        3) MODE=nvme; WITH_ROOTFS=1 ;;
        4) MODE=prep; printf '  一并下载 sample rootfs（1.83G，整机刷才需要）？[y/N] '; local b; read -r b
           case "$b" in y|Y) WITH_ROOTFS=1 ;; esac ;;
        5) MODE=target ;;
        6) MODE=doc ;;
        *) log "退出"; exit 0 ;;
    esac
}

report_detect() {
    banner
    echo "  自动识别结果："
    case "$DET_MODE" in
        onboard)
            chk_ok "运行在 Jetson 本机（板内识别最准）"
            chk_info "TNSPEC      : ${DET_TNSPEC:-未读到}"
            chk_info "模块/机型   : ${DET_MODULE:-未知} → 建议板型 ${DET_BOARD_SUGGEST:-未知}"
            chk_info "L4T 版本    : ${DET_L4T:-未知}"
            chk_info "UEFI 版本   : ${DET_UEFI:-需要 sudo，未读到}"
            chk_info "Super 已启用: ${DET_SUPER}"
            chk_info "启动存储    : ${DET_STORAGE:-未知}（rootdev ${DET_ROOTDEV_SUGGEST:-未知}）"
            ;;
        recovery) chk_ok "主机端看到 recovery 设备（板子型号需刷写时由 EEPROM 读出）" ;;
        *) chk_warn "既不在板内，也没有 recovery 设备（板子没连、或没进 recovery）" ;;
    esac
    if [ -n "$DET_BOARD_SUGGEST" ]; then
        local want="jetson-orin-nano-devkit-super"
        case "$DET_TNSPEC" in
            *-super*) [ "$want" = "jetson-orin-nano-devkit-super" ] && chk_ok "板型可支持 Super（config 用 ${want}）" ;;
            *) chk_warn "当前板子不是 super 版；要 Super 必须先刷 QSPI 到 36.4，再 nvpmodel 切 MAXN_SUPER" ;;
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
#       turing-pi-2.5-jetson-eeprom-fix (先备份再只刷 QSPI，NVMe 数据不动)
matrix_age() {
    [ -f "$MATRIX_FILE" ] || { echo 999999; return; }
    echo $(( $(date +%s) - $(stat -c%Y "$MATRIX_FILE" 2>/dev/null || echo 0) ))
}

suite_core_version() {   # suite -> 该 suite 最新 nvidia-l4t-core 版本
    local s="$1" url="$NV_REPO/t234/dists/$s/main/binary-arm64/Packages.gz"
    curl -s --max-time 25 "$url" | gunzip -c 2>/dev/null | \
        awk '/^Package: nvidia-l4t-core$/{f=1;next} f&&/^Version:/{print $2; exit}'
}

suite_qspi_updater() {   # suite -> QSPI capsule 更新包版本（没有则空）
    local s="$1" url="$NV_REPO/t234/dists/$s/main/binary-arm64/Packages.gz"
    curl -s --max-time 25 "$url" | gunzip -c 2>/dev/null | \
        awk '/^Package: nvidia-l4t-jetson-orin-nano-qspi-updater$/{f=1;next} f&&/^Version:/{print $2; exit}'
}

build_matrix() {
    local force="${1:-0}"
    local age; age="$(matrix_age)"
    if [ "$force" != 1 ] && [ "$age" -ge 0 ] && [ "$age" -lt "$MATRIX_TTL" ]; then
        log "上游矩阵用缓存（$(( age / 3600 )) 小时前生成，--refresh 可强制重取）"
        return 0
    fi
    mkdir -p "$(dirname "$MATRIX_FILE")" 2>/dev/null
    : > "$MATRIX_FILE.tmp"
    local s core qspi maj min pat v best
    for s in $SUITES; do
        core="$(suite_core_version "$s")"
        [ -n "$core" ] || continue
        qspi="$(suite_qspi_updater "$s")"
        maj="${core%%.*}"; local rest="${core#*.}"; min="${rest%%.*}"; pat="${rest#*.}"; pat="${pat%%-*}"
        best=""
        for v in $(seq "$pat" -1 0); do
            if url_exists "$(bsp_url "$maj.$min.$v")"; then best="$maj.$min.$v"; break; fi
        done
        printf '%s|%s|%s|%s\n' "$s" "$core" "${qspi%%-*}" "$best" >> "$MATRIX_FILE.tmp"
        log "探测 $s: L4T=${core%%-*}, 有BSP=${best:-无}"
    done
    mv "$MATRIX_FILE.tmp" "$MATRIX_FILE"
}

matrix_print() {
    printf '\n%s── QSPI / 刷机支持矩阵（数据源：NVIDIA apt 仓库 + 官方下载目录，%s）──%s\n' "$C_B" "$(date +%F)" "$C_N"
    printf '%-8s %-10s %-12s %-12s %s\n' "suite" "L4T(apt)" "BSP可下" "QSPI胶囊包" "只刷QSPI"
    local s core qspi best
    while IFS='|' read -r s core qspi best; do
        [ -n "$s" ] || continue
        local ok="是"; [ -n "$best" ] || ok="否(只有apt)"
        local cap="无"; [ -n "$qspi" ] && cap="有 $qspi"
        printf '%-8s %-10s %-12s %-12s %s\n' "$s" "${core%%-*}" "${best:--}" "$cap" "$ok"
    done < "$MATRIX_FILE"
    local lt="$WORK_DIR/Linux_for_Tegra"
    if [ -d "$lt/bootloader/generic/cfg" ]; then
        printf '\n本机 BSP 里的 QSPI 分区配置（决定能刷哪些存储后端）：\n'
        ls "$lt/bootloader/generic/cfg/" 2>/dev/null | grep -E '^flash_t234_qspi.*\.xml$' | sed 's/^/  - /'
        printf '本机 BSP 可用板型（--board 的取值）：\n'
        ls "$lt"/jetson-*.conf 2>/dev/null | sed 's#.*/##; s/\.conf$//' | sed 's/^/  - /' | head -20
    fi
    printf '\n官方图形工具（可整机刷，无"只刷 QSPI"选项）: https://developer.nvidia.com/sdk-manager\n'
    printf '只刷 QSPI 的第三方实现参考: osrbot/mfi-qspi-forge（量产 MFI 包）、Hi5808/turing-pi-2.5-jetson-eeprom-fix（先备份载板 EEPROM 再只刷 QSPI）\n\n'
}

resolve_l4t() {
    # L4T_VERSION 支持 auto/latest/<x.y.z>
    case "$L4T_VERSION" in
        auto|latest|"")
            build_matrix 0
            L4T_VERSION="$(awk -F'|' '$4!=""{print $4}' "$MATRIX_FILE" 2>/dev/null | sort -V | tail -1)"
            [ -n "$L4T_VERSION" ] || die "从上游没解析出可用 BSP 版本（网络不通？矩阵缓存 $MATRIX_FILE）"
            log "自动选中最新可刷 BSP: L4T $L4T_VERSION"
            ;;
        *)  : ;;
    esac
    refresh_filenames
    if ! url_exists "$(bsp_url "$L4T_VERSION")"; then
        warn "L4T $L4T_VERSION 的 BSP 包在官方下载目录不存在（可能只有 apt/OTA 发布）"
        build_matrix 0
        printf '可选版本（有 BSP 包）: %s\n' "$(awk -F'|' '$4!=""{print $4}' "$MATRIX_FILE" 2>/dev/null | sort -V | tr '\n' ' ')"
        die "换个版本：--l4t <版本>，或 --l4t latest 自动挑最新的"
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
    [ "$DRY_RUN" = 1 ] && { log "[dry-run] sha256 校验 $f"; return 0; }
    [ -s "$f" ] || { warn "文件不在，跳过校验"; return 0; }
    local got want=""
    got="$(sha256sum "$f" | awk '{print $1}')"
    if [ -n "$MANIFEST_URL" ]; then
        want="$(curl -fsSL --max-time 20 "$MANIFEST_URL" 2>/dev/null | awk -v n="$name" '$2==n||$2=="*"n{print $1}' | head -1)"
        [ -n "$want" ] || warn "外部清单里没有 $name，退回本机 TOFU 记录"
    fi
    [ -n "$want" ] || want="$(manifest_get "$name")"
    if [ -z "$want" ]; then
        manifest_put "$name" "$got"
        ok "首次校验通过并记入本机清单: $name = $got"
        return 0
    fi
    if [ "$got" = "$want" ]; then ok "sha256 与清单一致: $name"
    else die "sha256 不符（本地 $got ≠ 清单 $want）；若上游确实换了包，删掉清单行重跑：rm $MANIFEST_FILE"; fi
}

# ================================================================ 自更新
self_update() {
    local src="${UPDATE_FROM:-${JETSON_SCRIPT_URL:-}}"
    [ -n "$src" ] || die "没给更新源：--update-from <url|路径>，或配 JETSON_SCRIPT_URL"
    local tmp; tmp="$(mktemp)"; local new_sha old_sha
    case "$src" in
        http://*|https://*) curl -fsSL --max-time 60 -o "$tmp" "$src" || die "下载新版本失败: $src" ;;
        *) [ -f "$src" ] || die "更新源不存在: $src"; cp -f "$src" "$tmp" ;;
    esac
    bash -n "$tmp" || { rm -f "$tmp"; die "新版本语法检查没过，放弃更新"; }
    new_sha="$(sha256sum "$tmp" | awk '{print $1}')"
    old_sha="$(sha256sum "$0" 2>/dev/null | awk '{print $1}')"
    if [ "$new_sha" = "$old_sha" ]; then rm -f "$tmp"; ok "已经是当前最新版（sha256 相同）"; return 0; fi
    warn "发现新版本，准备替换（旧版备份为 $(basename "$0").bak.$(date +%s)）"
    cp -f "$0" "$0.bak.$(date +%s)" 2>/dev/null || true
    chmod 755 "$tmp"
    if mv -f "$tmp" "$0" 2>/dev/null; then ok "已更新：$0"
    else warn "无法写入 $0（只读/权限），新版本留在 $tmp，可手工拷走"; fi
    log "新版本说明（头部 12 行）："; head -12 "$0" | sed 's/^/    /'
}

# =================================================== 说明文档（自动打开）
doc_target() {
    # 优先本仓库随附的 index.html（与脚本同目录 / 工作目录），其次配置的在线地址
    local c
    for c in "$SCRIPT_DIR/index.html" "$WORK_DIR/index.html" "$SCRIPT_DIR/docs/index.html"; do
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
        warn "没找到 index.html（应与脚本同目录），也没配 --doc-url；跳过"
        return 0
    fi
    local url="$t"
    case "$t" in http://*|https://*) ;; *) url="file://$t" ;; esac
    if ! has_display; then
        log "无图形环境（headless），文档在这里：$t"
        [ -n "$DOC_URL" ] && log "在线版：$DOC_URL"
        return 0
    fi
    if open_in_browser "$url"; then log "已在浏览器打开：$url"
    else warn "打不开浏览器，文档路径：$t"; fi
}

maybe_open_doc() {
    [ "$OPEN_DOC" = 0 ] && return 0
    [ "$DRY_RUN" = 1 ] && return 0
    local t; t="$(doc_target)" || return 0
    if ! has_display; then
        log "更多说明（矩阵/参数/坑）：$t"
        return 0
    fi
    if [ "$YES" = 1 ] || [ ! -t 0 ]; then
        open_doc
        return 0
    fi
    printf '  打开使用说明页（矩阵 / 参数 / 免责声明）？[Y/n] '
    local a; read -r a
    case "$a" in n|N|no|NO) log "文档路径：$t" ;; *) open_doc ;; esac
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
    esac

    case "$MODE" in nvme) WITH_ROOTFS=1 ;; esac   # nvme 必定要 rootfs，先定下来再算空间
    [ "$AUTO_DIR" = 1 ] && auto_select_dirs "$MODE"
    resolve_l4t                    # auto/latest → 向上游探测最新可刷 BSP（不写死版本）

    detect_onboard || detect_recovery || DET_MODE="none"
    pick_board
    [ -n "$CACHE_DIR" ] || CACHE_DIR="$WORK_DIR"

    case "$MODE" in
        detect)
            report_detect
            check_requirements detect
            if [ "$DET_MODE" = "onboard" ]; then
                log "板内体检通过。板内只能 --mode target（升计算栈）；要刷 QSPI/整机请接 x86_64 主机"
            else
                log "主机侧体检通过。板子进 recovery 后：--mode qspi（只升 UEFI，留数据）或 --mode nvme（整机重刷）"
            fi
            ;;
        target)
            report_detect; check_requirements target; do_target ;;
        prep)
            report_detect; check_requirements prep; do_prep ;;
        qspi)
            report_detect; check_requirements qspi
            do_prep; do_qspi ;;
        nvme)
            report_detect; WITH_ROOTFS=1; check_requirements nvme
            do_prep; do_nvme ;;
    esac
    ok "全部完成"
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
    ( main "$@" )        # source 调用：放子壳跑，中途 exit 不会关掉调用者终端
    return $?
fi
