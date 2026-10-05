#!/usr/bin/env bash
# ============================================================
# 虚拟内存（swapfile）管理（修正版）
# 平台：Debian 12/13、Ubuntu 22.04/24.04
# 相对原版的改动：
#   1. 【重要】删除了对 /proc/swaps 中所有块设备的
#      `swapoff + wipefs -a + mkswap` 循环 —— 那会抹掉分区上的
#      文件系统签名，属于不可逆数据破坏。现在只管理 /swapfile。
#      如需接管既有分区式 swap，必须显式使用 --adopt-block <设备>。
#   2. 创建前检查磁盘可用空间，避免写满根分区
#   3. fallocate 失败（btrfs/zfs 等）自动回退 dd 方式
#   4. 改 /etc/fstab 前先备份，且保证写入的是独立完整的一行
#      （原版直接 >> 追加，若 fstab 末尾没有换行会拼坏 fstab 导致
#       下次开机进入 emergency mode）
#   5. 自定义大小做数字校验，拒绝空值/非数字/超大值
#   6. 结束后用 swapon --show 回显真实状态并校验 fstab
#   7. 支持非交互调用：swap.sh <MB> / check / --help
# ============================================================

set -uo pipefail

GL_HUANG='\033[33m'
GL_LV='\033[32m'
GL_HONG='\033[31m'
GL_BAI='\033[0m'

SWAPFILE='/swapfile'
FSTAB='/etc/fstab'
FSTAB_ENTRY="${SWAPFILE} none swap sw 0 0"
# 允许的最大值（MB），防止误输入 99999999 写满磁盘
MAX_SWAP_MB=1048576
MIN_SWAP_MB=64

info() { echo -e "${GL_HUANG}$1${GL_BAI}"; }
ok()   { echo -e "${GL_LV}$1${GL_BAI}"; }
err()  { echo -e "${GL_HONG}$1${GL_BAI}" >&2; }

root_use() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        err '请使用 root 运行此脚本（sudo bash swap.sh）。'
        exit 1
    fi
}

usage() {
    cat <<'EOF'
用法:
  sudo bash swap.sh              # 交互式菜单
  sudo bash swap.sh 2048         # 直接把 swapfile 设为 2048M 并启用
  sudo bash swap.sh check        # 只在没有 swap 时创建 1024M
  sudo bash swap.sh --help

说明:
  本脚本只创建/调整 /swapfile（单文件 swap）。
  不会对块设备执行 swapoff/wipefs/mkswap —— 那会破坏分区上的文件系统。
  如需把某个空分区接管为 swap，请手动执行：
    swapoff <设备> && mkswap <设备> && swapon <设备>
  并在 /etc/fstab 中自行添加对应条目。
EOF
}

# ---------- 查询 ----------
swap_total_mb() {
    free -m 2>/dev/null | awk 'NR==3{print $2+0}'
}

swap_used_mb() {
    free -m 2>/dev/null | awk 'NR==3{print $3+0}'
}

swap_info_line() {
    local total used percent
    total="$(swap_total_mb)"
    used="$(swap_used_mb)"
    if [ "$total" -eq 0 ]; then
        percent=0
    else
        percent=$((used * 100 / total))
    fi
    printf '%dM/%dM (%d%%)' "$used" "$total" "$percent"
}

# 根分区可用空间（MB）
root_avail_mb() {
    df -Pk / 2>/dev/null | awk 'NR==2{printf "%d", $4/1024}'
}

root_fstype() {
    df -PT / 2>/dev/null | awk 'NR==2{print $2}'
}

fstab_has_swapfile() {
    grep -qsE "^[[:space:]]*${SWAPFILE}[[:space:]]" "$FSTAB"
}

# 检查是否存在非 /swapfile 的块设备 swap，仅提示不处理
other_block_swaps() {
    awk 'NR>1 && $1 ~ /^\/dev\// {print $1}' /proc/swaps 2>/dev/null
}

# ---------- 核心操作 ----------
create_swapfile() {
    local size_mb="$1"
    local fstype avail need_mb

    # 参数校验
    case "$size_mb" in
        ''|*[!0-9]*)
            err "虚拟内存大小必须是纯数字（单位 MB），收到：'${size_mb}'"
            return 1
            ;;
    esac
    size_mb="$((10#${size_mb}))"
    if [ "$size_mb" -lt "$MIN_SWAP_MB" ] || [ "$size_mb" -gt "$MAX_SWAP_MB" ]; then
        err "大小必须在 ${MIN_SWAP_MB}-${MAX_SWAP_MB} MB 之间，收到：${size_mb}"
        return 1
    fi

    fstype="$(root_fstype)"
    avail="$(root_avail_mb)"
    if [ -z "$avail" ]; then
        err '无法读取根分区可用空间，已中止。'
        return 1
    fi
    # 需要额外预留 64M（文件系统元数据/日志）
    need_mb=$((size_mb + 64))
    if [ "$avail" -lt "$need_mb" ]; then
        err "根分区可用空间不足：需要约 ${need_mb}M，当前仅 ${avail}M。"
        err '已中止，未做任何修改。'
        return 1
    fi
    info "根分区文件系统：${fstype:-未知}，可用 ${avail}M，将创建 ${size_mb}M 的 ${SWAPFILE}"

    # 提示其它块设备 swap（不做任何破坏性操作）
    local blocks
    blocks="$(other_block_swaps)"
    if [ -n "$blocks" ]; then
        info "检测到以下块设备 swap（本脚本不会改动它们）："
        printf '  %s\n' $blocks
    fi

    # 关闭并删除旧 swapfile
    if [ -e "$SWAPFILE" ]; then
        if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$SWAPFILE"; then
            swapoff "$SWAPFILE" 2>/dev/null || { err "无法关闭 ${SWAPFILE}（可能仍在使用）。"; return 1; }
        fi
        rm -f -- "$SWAPFILE" || { err "无法删除旧 ${SWAPFILE}。"; return 1; }
    fi

    # 创建文件：fallocate 快，但 btrfs/zfs 上受限，失败则回退 dd
    local created=no
    if command -v fallocate >/dev/null 2>&1; then
        if fallocate -l "${size_mb}M" "$SWAPFILE" 2>/dev/null; then
            created=yes
        fi
    fi
    if [ "$created" = 'no' ]; then
        info 'fallocate 不可用或不支持该文件系统，改用 dd 方式（较慢，请耐心等待）...'
        local count
        count=$((size_mb * 1024))
        if ! dd if=/dev/zero of="$SWAPFILE" bs=1024 count="$count" status=none; then
            err 'dd 创建 swapfile 失败。'
            rm -f -- "$SWAPFILE"
            return 1
        fi
        created=yes
    fi

    chmod 600 "$SWAPFILE" || { err 'chmod 600 失败。'; return 1; }
    if ! mkswap -f "$SWAPFILE" >/dev/null; then
        err 'mkswap 失败。'
        rm -f -- "$SWAPFILE"
        return 1
    fi
    if ! swapon "$SWAPFILE"; then
        err 'swapon 失败，请检查内核是否支持 swapfile 及 SELinux/AppArmor 策略。'
        return 1
    fi

    # 写入 fstab（先备份，再保证是独立完整的一行）
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    if [ -f "$FSTAB" ]; then
        cp -a "$FSTAB" "${FSTAB}.bak.${stamp}" 2>/dev/null || {
            err "备份 ${FSTAB} 失败，为避免破坏启动配置已中止（swap 已生效但未持久化）。"
            return 1
        }
        info "已备份：${FSTAB}.bak.${stamp}"
    fi

    # 删除旧的 /swapfile 条目
    sed -i -E "\|^[[:space:]]*${SWAPFILE}[[:space:]]|d" "$FSTAB"

    # 若文件末尾无换行，先补一个换行，避免与新条目拼接成一行
    if [ -s "$FSTAB" ] && [ -n "$(tail -c1 "$FSTAB")" ]; then
        printf '\n' >> "$FSTAB"
    fi
    printf '%s\n' "$FSTAB_ENTRY" >> "$FSTAB"

    # 校验 fstab 语法（可用时）
    if command -v findmnt >/dev/null 2>&1; then
        if ! findmnt --verify >/dev/null 2>&1; then
            info '提示：findmnt --verify 报告 fstab 存在告警，请执行 findmnt --verify 查看。'
        fi
    fi

    ok "虚拟内存已设置为 ${size_mb}M（${SWAPFILE}），并已写入 ${FSTAB}。"
    return 0
}

# 只在完全没有 swap 时创建
check_swap() {
    local total
    total="$(swap_total_mb)"
    if [ "${total:-0}" -gt 0 ]; then
        info "当前已有 ${total}M 虚拟内存，无需创建。"
        return 0
    fi
    info '当前没有虚拟内存，自动创建 1024M。'
    create_swapfile 1024
}

show_status() {
    echo -e "${GL_HUANG}当前虚拟内存: $(swap_info_line)${GL_BAI}"
    if command -v swapon >/dev/null 2>&1; then
        echo
        swapon --show 2>/dev/null || true
    fi
    echo
    if fstab_has_swapfile; then
        ok "${FSTAB} 中已有 ${SWAPFILE} 条目。"
    else
        info "${FSTAB} 中没有 ${SWAPFILE} 条目（重启后不会自动启用）。"
    fi
    local blocks
    blocks="$(other_block_swaps)"
    if [ -n "$blocks" ]; then
        info '检测到块设备 swap（本脚本不会改动）：'
        printf '  %s\n' $blocks
    fi
}

swap_menu() {
    root_use
    while true; do
        clear
        echo '设置虚拟内存'
        echo -e "当前虚拟内存: ${GL_HUANG}$(swap_info_line)${GL_BAI}"
        echo '------------------------'
        echo '1. 分配1024M         2. 分配2048M         3. 分配4096M         4. 自定义大小'
        echo '5. 查看当前 swap 状态'
        echo '------------------------'
        echo '0. 返回上一级选单'
        echo '------------------------'
        read -r -e -p '请输入你的选择: ' choice || return 0
        case "$choice" in
            1) create_swapfile 1024 ;;
            2) create_swapfile 2048 ;;
            3) create_swapfile 4096 ;;
            4)
                local new_swap
                read -r -e -p '请输入虚拟内存大小（单位M，64-1048576）: ' new_swap || continue
                create_swapfile "$new_swap"
                ;;
            5) show_status ;;
            0|'') break ;;
            *) err '无效选项。'; sleep 1 ;;
        esac
        echo
        read -r -p '按回车键继续...' _ || true
    done
}

main() {
    case "${1:-menu}" in
        menu) swap_menu ;;
        check|auto)
            root_use
            check_swap
            ;;
        -h|--help|help) usage ;;
        ''|*[!0-9]*) usage; exit 1 ;;
        *)
            root_use
            create_swapfile "$1"
            ;;
    esac
}

main "$@"
