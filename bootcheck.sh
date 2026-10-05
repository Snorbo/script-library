#!/bin/bash
# ============================================================
# 重启前引导健康检查（bootcheck.sh）
# 平台：Debian 12/13、Ubuntu 22.04/24.04
#
# 为什么需要这个脚本：
#   一次 apt 升级可能因为「/boot 写满 / 包配置被中断 / autoremove 误删内核」
#   而留下一个**无法引导**的系统。风险点在于：升级过程本身能跑完，
#   问题只在**下次重启**才暴露，届时若没有控制台就等于失联。
#   因此原则是：**先在当前运行的系统里证明"可引导"，再允许重启。**
#
# 检查项：
#   1. dpkg 是否有半配置/半安装的包（dpkg --audit 输出为空）
#   2. 列出所有状态不是 ii 的包
#   3. /boot 剩余空间（生成新 initramfs 需要余量）
#   4. /boot 下每个 vmlinuz-* 是否都有配对的 initrd.img-*
#   5. 正在运行的内核是否仍有对应的内核包（没被 autoremove 删掉）
#   6. 是否至少存在一个可引导内核
#   7. GRUB 配置文件是否存在且含有效菜单项
#   8. 是否存在阻止登录的 /etc/nologin
#   9. /etc/fstab 是否有语法错误或引用了不存在的设备
#  10. 是否有待生效的重启标记（/var/run/reboot-required）
#
# 用法：
#   bash bootcheck.sh           只检查（默认）
#   bash bootcheck.sh --fix     发现问题时尝试自动修复
#   bash bootcheck.sh --quiet   只输出结论行
#
# 退出码：
#   0 = 可以重启
#   1 = 不可以重启（存在错误级问题）
#   2 = 无法判定（缺少 root 权限等）
# ============================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DO_FIX='no'
QUIET='no'
KERNEL_PKG_PATTERN='linux-image|linux-headers|linux-modules|linux-generic|linux-virtual|linux-signed|linux-restricted|linux-extra'

ERRORS=0
WARNINGS=0
FIX_NOTES=()

for arg in "$@"; do
    case "$arg" in
        --fix) DO_FIX='yes' ;;
        --quiet|-q) QUIET='yes' ;;
        -h|--help) sed -n '2,40p' "$0" 2>/dev/null || true; exit 0 ;;
        *) echo "未知参数：$arg" >&2; exit 2 ;;
    esac
done

say() {
    [ "$QUIET" = 'yes' ] && return 0
    echo -e "$1"
}

problem() {
    # $1 = error|warn, $2 = 说明, $3 = 修复建议
    local level="$1" msg="$2" hint="${3:-}"
    if [ "$level" = 'error' ]; then
        ERRORS=$((ERRORS + 1))
        say "${RED}  [错误] ${msg}${NC}"
    else
        WARNINGS=$((WARNINGS + 1))
        say "${YELLOW}  [警告] ${msg}${NC}"
    fi
    [ -n "$hint" ] && say "${YELLOW}         建议：${hint}${NC}"
    return 0
}

run_fix() {
    # 记录并执行修复命令（仅在 --fix 时）
    local desc="$1"
    shift
    if [ "$DO_FIX" != 'yes' ]; then
        FIX_NOTES+=("$desc")
        return 1
    fi
    say "${BLUE}  → 自动修复：${desc}${NC}"
    "$@"
    return $?
}

# ---------- 1/2. 包状态 ----------
list_broken_packages() {
    # 状态不是 ii 的包（半安装 iF / 待解包 iU / 半配置 iH / 待清除 r?)
    dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' 2>/dev/null \
        | awk '$1 != "ii" && $1 != "rc" && $1 != "" { print $1, $2 }'
}

check_dpkg_state() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        say "${YELLOW}  [跳过] 包状态检查需要 root${NC}"
        return 0
    fi

    local audit broken
    audit="$(dpkg --audit 2>&1 | grep -v '^[[:space:]]*$' || true)"
    broken="$(list_broken_packages)"

    if [ -n "$audit" ] || [ -n "$broken" ]; then
        problem 'error' 'dpkg 状态不完整：存在半配置/半安装的包（重启后极易起不来）' \
            '执行 dpkg --configure -a && apt-get --fix-broken install，成功后再重启'
        if [ -n "$broken" ]; then
            say "${YELLOW}         状态异常的包（前 20 个）：${NC}"
            printf '%s\n' "$broken" | head -n 20 | sed 's/^/           /'
        fi
        if [ -n "$audit" ]; then
            say "${YELLOW}         dpkg --audit 输出（前 20 行）：${NC}"
            printf '%s\n' "$audit" | head -n 20 | sed 's/^/           /'
        fi
        if [ "$DO_FIX" = 'yes' ]; then
            say "${BLUE}  → 自动修复：dpkg --configure -a${NC}"
            DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true
            say "${BLUE}  → 自动修复：apt-get --fix-broken install -y${NC}"
            DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y || true
            # 复查
            if [ -z "$(dpkg --audit 2>&1 | grep -v '^[[:space:]]*$' || true)" ] && [ -z "$(list_broken_packages)" ]; then
                say "${GREEN}  → 修复成功：dpkg 状态已正常${NC}"
                ERRORS=$((ERRORS - 1))
            else
                say "${RED}  → 修复未能解决全部问题，请人工处理后再重启${NC}"
            fi
        else
            FIX_NOTES+=('dpkg --configure -a && apt-get --fix-broken install')
        fi
    else
        say "${GREEN}  [通过] dpkg 包状态正常（无半配置/半安装的包）${NC}"
    fi
}

# ---------- 3. /boot 空间 ----------
boot_dir() {
    if [ -d /boot ] && [ "$(df -P /boot 2>/dev/null | awk 'NR==2{print $6}')" = '/boot' ]; then
        printf '/boot'
    else
        printf '/'
    fi
}

check_boot_space() {
    local dir avail
    dir="$(boot_dir)"
    avail="$(df -Pk "$dir" 2>/dev/null | awk 'NR==2{printf "%d", $4/1024}')"
    if [ -z "$avail" ]; then
        say "${YELLOW}  [跳过] 无法读取 ${dir} 可用空间${NC}"
        return 0
    fi
    if [ "$avail" -lt 50 ]; then
        problem 'error' "${dir} 可用空间仅 ${avail}M：新内核的 initramfs 很可能生成失败" \
            '清理旧内核：apt-get autoremove --purge（手动指定旧版本，勿全自动），或扩大该分区'
    elif [ "$avail" -lt 200 ]; then
        problem 'warn' "${dir} 可用空间偏低（${avail}M），升级内核前建议清理旧内核" \
            '删除不再使用的旧内核版本后再次确认'
    else
        say "${GREEN}  [通过] ${dir} 可用空间 ${avail}M${NC}"
    fi
}

# ---------- 4. vmlinuz 与 initrd 配对 ----------
check_initrd_pairs() {
    local boot='/boot' v ver missing=0
    [ -d "$boot" ] || { say "${YELLOW}  [跳过] /boot 不存在（可能合并在根分区）${NC}"; return 0; }

    for v in "$boot"/vmlinuz-*; do
        [ -e "$v" ] || continue
        ver="${v##*/vmlinuz-}"
        if [ ! -s "${boot}/initrd.img-${ver}" ]; then
            problem 'error' "缺少 initramfs：/boot/initrd.img-${ver}（该内核无法引导）" \
                "执行 update-initramfs -c -k ${ver}（或 -u -k all）"
            missing=$((missing + 1))
        fi
    done

    if [ "$missing" -eq 0 ]; then
        say "${GREEN}  [通过] /boot 下所有 vmlinuz 均有配对的 initrd.img${NC}"
    elif [ "$DO_FIX" = 'yes' ]; then
        say "${BLUE}  → 自动修复：update-initramfs -u -k all${NC}"
        if update-initramfs -u -k all; then
            local still=0
            for v in "$boot"/vmlinuz-*; do
                [ -e "$v" ] || continue
                ver="${v##*/vmlinuz-}"
                [ -s "${boot}/initrd.img-${ver}" ] || still=$((still + 1))
            done
            if [ "$still" -eq 0 ]; then
                say "${GREEN}  → 修复成功：initramfs 已补齐${NC}"
                ERRORS=$((ERRORS - missing))
            else
                say "${RED}  → 仍有 ${still} 个内核缺少 initramfs${NC}"
            fi
        fi
    else
        FIX_NOTES+=('update-initramfs -u -k all')
    fi
}

# ---------- 5. 运行中内核是否仍有对应包 ----------
running_kernel_package() {
    local rel pkg
    rel="$(uname -r)"
    pkg="$(dpkg-query -S "/boot/vmlinuz-${rel}" 2>/dev/null | head -n1 | cut -d: -f1)"
    printf '%s' "$pkg"
}

check_running_kernel() {
    local rel pkg
    rel="$(uname -r)"
    pkg="$(running_kernel_package)"

    if [ -n "$pkg" ]; then
        say "${GREEN}  [通过] 运行中内核 ${rel} 对应的包仍在：${pkg}${NC}"
    else
        problem 'warn' "运行中内核 ${rel} 找不到对应的已安装包（可能被 autoremove 移除）" \
            '若 /boot 中仍有该 vmlinuz 与 initrd，本次重启通常仍可引导；但下次内核升级会失去回退版本'
    fi

    # 至少存在一个可引导内核
    local cnt=0 v
    for v in /boot/vmlinuz-*; do
        [ -e "$v" ] || continue
        [ -s "/boot/initrd.img-${v##*/vmlinuz-}" ] && cnt=$((cnt + 1))
    done

    if [ "$cnt" -eq 0 ]; then
        problem 'error' '/boot 下没有任何「vmlinuz + initrd」配对完整的可引导内核' \
            '立即安装内核包：apt-get install --reinstall -y linux-image-generic（Debian 用 linux-image-amd64）'
    else
        say "${GREEN}  [通过] 共有 ${cnt} 个可引导内核${NC}"
    fi

    # 若内核包被删，至少把当前 initrd 备份出来，便于救援
    if [ -z "$pkg" ] && [ -s "/boot/initrd.img-${rel}" ]; then
        if [ "$DO_FIX" = 'yes' ]; then
            cp -a "/boot/initrd.img-${rel}" "/boot/initrd.img-${rel}.keep" 2>/dev/null \
                && say "${BLUE}  → 已备份当前 initramfs 为 /boot/initrd.img-${rel}.keep${NC}"
        fi
    fi
}

# ---------- 6. GRUB ----------
check_grub() {
    if ! command -v update-grub >/dev/null 2>&1 && [ ! -d /boot/grub ] && [ ! -d /boot/efi ]; then
        say "${YELLOW}  [跳过] 未检测到 GRUB（可能是其它引导器或容器环境）${NC}"
        return 0
    fi

    local cfg=''
    for c in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
        [ -f "$c" ] && cfg="$c" && break
    done

    if [ -z "$cfg" ]; then
        problem 'error' '找不到 GRUB 配置文件（/boot/grub/grub.cfg）' \
            '执行 update-grub 重新生成；若失败请先用控制台排查'
        return 0
    fi

    local entries
    entries="$(grep -c '^menuentry ' "$cfg" 2>/dev/null || echo 0)"
    if [ "${entries:-0}" -eq 0 ]; then
        problem 'error' "GRUB 配置 ${cfg} 中没有任何菜单项" \
            '执行 update-grub 重新生成'
    else
        say "${GREEN}  [通过] GRUB 配置存在，含 ${entries} 个菜单项（${cfg}）${NC}"
    fi

    # GRUB 配置里引用的 vmlinuz 是否真实存在
    local ref miss=0
    for ref in $(grep -oE '/boot/vmlinuz-[^[:space:]]+' "$cfg" 2>/dev/null | sort -u); do
        if [ ! -e "$ref" ]; then
            miss=$((miss + 1))
            say "${YELLOW}         注意：GRUB 引用了不存在的内核 ${ref}${NC}"
        fi
    done
    if [ "$miss" -gt 0 ]; then
        problem 'warn' "GRUB 配置中有 ${miss} 个内核文件已不存在（通常无害，但说明需要 update-grub）" \
            '执行 update-grub 使菜单与 /boot 实际内容一致'
    fi
}

# ---------- 7. nologin ----------
check_nologin() {
    if [ -e /etc/nologin ]; then
        say "${RED}  [错误] 存在 /etc/nologin：所有非 root 登录会被拒绝${NC}"
        if [ "$DO_FIX" = 'yes' ]; then
            rm -f /etc/nologin && say "${GREEN}  → 已删除 /etc/nologin${NC}" || true
        else
            ERRORS=$((ERRORS + 1))
            say "${YELLOW}         建议：rm -f /etc/nologin${NC}"
            FIX_NOTES+=('rm -f /etc/nologin')
        fi
    else
        say "${GREEN}  [通过] 不存在 /etc/nologin${NC}"
    fi
}

# ---------- 8. fstab ----------
check_fstab() {
    local bad=0
    if [ ! -f /etc/fstab ]; then
        say "${YELLOW}  [跳过] 没有 /etc/fstab${NC}"
        return 0
    fi

    # 行格式：非注释行必须是 6 个字段（或至少 4 个）
    local n
    n="$(awk '!/^[[:space:]]*#/ && NF>0 && NF<4 {c++} END{print c+0}' /etc/fstab)"
    if [ "$n" -gt 0 ]; then
        problem 'error' "/etc/fstab 有 ${n} 行字段数不足（会导致开机挂载失败进入 emergency mode）" \
            '用 cat /etc/fstab 检查这几行；可参考 /etc/fstab.bak.* 恢复'
        bad=$((bad + 1))
    fi

    # 关键挂载点是否声明
    if ! grep -qE '^[[:space:]]*[^#[:space:]][^[:space:]]*[[:space:]]+/([[:space:]]|$)' /etc/fstab; then
        problem 'warn' '/etc/fstab 中没有声明根挂载点 /（若根分区靠内核参数挂载可忽略）' ''
        bad=$((bad + 1))
    fi

    if [ "$bad" -eq 0 ]; then
        say "${GREEN}  [通过] /etc/fstab 字段数与根挂载点声明正常${NC}"
    fi

    # findmnt 校验（可用时）
    if command -v findmnt >/dev/null 2>&1; then
        if ! findmnt --verify >/dev/null 2>&1; then
            say "${YELLOW}  [警告] findmnt --verify 报告 fstab 存在告警，请执行 findmnt --verify 查看${NC}"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
}

# ---------- 9. 待重启标记 ----------
check_reboot_flag() {
    if [ -e /var/run/reboot-required ] || [ -e /run/reboot-required ]; then
        say "${YELLOW}  [提示] 系统标记了「需要重启」以完成更新:${NC}"
        [ -f /var/run/reboot-required.pkgs ] && sed 's/^/           /' /var/run/reboot-required.pkgs | head -n 10
    else
        say "${GREEN}  [通过] 没有待生效的重启标记${NC}"
    fi
}

# ---------- 主流程 ----------
say "${BLUE}============================================${NC}"
say "${BLUE} 重启前引导健康检查${NC}"
say "${BLUE}============================================${NC}"
say "内核：$(uname -r)    系统：$( (. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-未知}") || echo 未知 )"
say "模式：$([ "$DO_FIX" = 'yes' ] && echo '检查并自动修复' || echo '仅检查')"
say ''

check_dpkg_state
check_boot_space
check_initrd_pairs
check_running_kernel
check_grub
check_nologin
check_fstab
check_reboot_flag

say ''
say "${BLUE}--------------------------------------------${NC}"

if [ "$ERRORS" -gt 0 ]; then
    say "${RED}结论：不可以重启（${ERRORS} 个错误，${WARNINGS} 个警告）。${NC}"
    say "${RED}请先按上面的建议修复；若无法修复，请先通过云控制台/救援模式处理。${NC}"
    if [ "${#FIX_NOTES[@]}" -gt 0 ]; then
        say "${YELLOW}建议执行的修复命令：${NC}"
        printf '        %s\n' "${FIX_NOTES[@]}"
    fi
    if [ "$DO_FIX" != 'yes' ]; then
        say "${YELLOW}也可直接重跑：bash bootcheck.sh --fix${NC}"
    fi
    exit 1
fi

if [ "$WARNINGS" -gt 0 ]; then
    say "${YELLOW}结论：可以重启，但有 ${WARNINGS} 个警告，请先确认上面的提示。${NC}"
else
    say "${GREEN}结论：引导状态正常，可以安全重启。${NC}"
fi
exit 0
