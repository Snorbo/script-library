#!/bin/bash
# ============================================================
# 系统更新（修正版）
# 平台：Debian 12/13、Ubuntu 22.04/24.04（apt 系已加固）
# 相对原版的改动：
#   1. 【重要】删除 `pkill -9 -f 'apt|dpkg'` —— 该 ERE 子串匹配会误杀
#      任何命令行含 apt/dpkg 的进程，也可能打断正在进行的升级
#   2. 【重要】不再无条件删除 dpkg/apt 锁文件。先确认没有 apt/dpkg
#      进程持有锁，才清理残留锁，避免并发 dpkg 损坏包数据库
#   3. apt 分支改用 apt-get 并检查每一步退出码
#   4. opkg 分支补齐 upgrade（原来只 update 不升级，与其它分支语义不一致）
#   5. 内核有更新时给出「需要重启」的明确提示
#   6. 支持 --yes 非交互与 --help
# ============================================================

set -uo pipefail

GL_KJLAN='\033[96m'
GL_BAI='\033[0m'
GL_HONG='\033[31m'
GL_LV='\033[32m'
GL_HUANG='\033[33m'

info() { echo -e "${GL_KJLAN}$1${GL_BAI}"; }
ok()   { echo -e "${GL_LV}$1${GL_BAI}"; }
warn() { echo -e "${GL_HUANG}$1${GL_BAI}"; }
err()  { echo -e "${GL_HONG}$1${GL_BAI}" >&2; }

usage() {
    cat <<'EOF'
用法:
  sudo bash sysupdate.sh            # 交互式系统更新
  sudo bash sysupdate.sh --yes      # 非交互
  sudo bash sysupdate.sh --help
EOF
}

# ---------- apt/dpkg 占用检查（替代原来的 pkill + 删锁） ----------
apt_is_idle() {
    local busy=''
    if command -v pgrep >/dev/null 2>&1; then
        busy="$(pgrep -x -a 'apt|apt-get|aptitude|dpkg|unattended-upgr|packagekitd' 2>/dev/null || true)"
    fi
    if [ -z "$busy" ] && command -v fuser >/dev/null 2>&1; then
        local f
        for f in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock /var/lib/apt/lists/lock; do
            [ -e "$f" ] || continue
            if fuser "$f" >/dev/null 2>&1; then
                busy="锁被占用：$f"
                break
            fi
        done
    fi
    if [ -n "$busy" ]; then
        err '检测到 apt/dpkg 正在运行，已中止本次更新（避免并发损坏包数据库）：'
        printf '  %s\n' "$busy"
        echo '  请等待其结束后重试（自动更新任务：systemctl status apt-daily.service）。'
        return 1
    fi
    return 0
}

clean_stale_locks() {
    local locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock /var/lib/apt/lists/lock)
    local f
    for f in "${locks[@]}"; do
        [ -e "$f" ] || continue
        if command -v fuser >/dev/null 2>&1 && fuser "$f" >/dev/null 2>&1; then
            warn "跳过仍被占用的锁：$f"
            continue
        fi
        rm -f -- "$f" 2>/dev/null || true
    done
}

fix_dpkg() {
    if ! apt_is_idle; then
        return 1
    fi
    clean_stale_locks
    info '正在修复可能中断的 dpkg 状态（dpkg --configure -a）...'
    if DEBIAN_FRONTEND=noninteractive dpkg --configure -a; then
        return 0
    fi
    warn 'dpkg --configure -a 返回非零，请手动检查。'
    return 1
}

kernel_update_pending() {
    local running newest
    running="$(uname -r)"
    newest="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V | tail -n1)"
    [ -n "$newest" ] && [ "$newest" != "$running" ]
}

linux_update() {
    info '正在系统更新...'

    if command -v apt-get >/dev/null 2>&1; then
        fix_dpkg || { err 'apt/dpkg 未处于空闲状态，已中止。'; return 1; }
        info '→ apt-get update'
        if ! DEBIAN_FRONTEND=noninteractive apt-get update; then
            err 'apt-get update 失败，已中止（请检查软件源/网络）。'
            return 1
        fi
        info '→ apt-get full-upgrade -y'
        if ! DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y; then
            err 'apt-get full-upgrade 失败，请查看上方输出。'
            return 1
        fi
        info '→ apt-get autoremove -y'
        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || warn 'autoremove 返回非零（可忽略）。'

    elif command -v dnf >/dev/null 2>&1; then
        dnf -y upgrade || { err 'dnf upgrade 失败。'; return 1; }
    elif command -v yum >/dev/null 2>&1; then
        yum -y update || { err 'yum update 失败。'; return 1; }
    elif command -v apk >/dev/null 2>&1; then
        apk update && apk upgrade || { err 'apk upgrade 失败。'; return 1; }
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Syu --noconfirm || { err 'pacman -Syu 失败。'; return 1; }
    elif command -v zypper >/dev/null 2>&1; then
        zypper refresh && zypper update || { err 'zypper update 失败。'; return 1; }
    elif command -v opkg >/dev/null 2>&1; then
        opkg update && opkg upgrade || { err 'opkg upgrade 失败。'; return 1; }
    else
        err '未知的包管理器！'
        return 1
    fi

    ok '系统更新完成。'
    if kernel_update_pending; then
        warn "检测到新内核（当前运行：$(uname -r)），建议尽快重启以生效：reboot"
    fi
    return 0
}

ASSUME_YES='no'
while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y) ASSUME_YES='yes' ;;
        -h|--help|help) usage; exit 0 ;;
        *) err "未知参数：$1"; usage; exit 1 ;;
    esac
    shift
done

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "请使用 root 权限运行此脚本（例如：sudo bash $0）"
    exit 1
fi

if [ "$ASSUME_YES" != 'yes' ] && [ -t 0 ]; then
    warn '即将执行系统更新（可能升级内核并需要重启）。'
    read -r -p '是否继续？(y/N): ' a || a='n'
    if [[ ! "$a" =~ ^[Yy]$ ]]; then
        echo '已取消。'
        exit 0
    fi
fi

linux_update
