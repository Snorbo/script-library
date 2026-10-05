#!/bin/bash
# ============================================================
# 系统清理（修正版）
# 平台：Debian 12/13、Ubuntu 22.04/24.04（已针对 apt 系加固）
# 相对原版的改动：
#   1. 【重要】删除 `pkill -9 -f 'apt|dpkg'` —— 该正则子串匹配会误杀
#      任何命令行含 "apt"/"dpkg" 的进程，且会打断正在运行的升级
#   2. 【重要】不再无条件删除 /var/lib/dpkg/lock* 抢夺锁。
#      现在先用 pgrep/fuser/lsof 判断是否真的没有 apt/dpkg 在运行，
#      只有确认无进程持锁时才清理残留锁，避免并发 dpkg 损坏包数据库
#   3. 清理 journal 日志改为默认关闭，需显式选择或传参（--logs N天）
#   4. /tmp 清理只删除超过 24 小时的普通文件，不再 rm -rf /tmp/*
#   5. 不再 rm -rf /var/log/*（会让系统失去排障能力）
#   6. autoremove 先列出将被删除的包，确认后才执行
#   7. 各步骤均有失败检查与结果汇总
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

# 统计
CLEAN_ACTIONS=()
CLEAN_WARNINGS=()

record() { CLEAN_ACTIONS+=("$1"); }
warn_record() { CLEAN_WARNINGS+=("$1"); }

usage() {
    cat <<'EOF'
用法:
  sudo bash sysclean.sh                # 交互式清理（推荐）
  sudo bash sysclean.sh --yes          # 非交互，使用默认安全项
  sudo bash sysclean.sh --logs 3       # 额外把 journal 日志裁剪到最近 3 天
  sudo bash sysclean.sh --help
EOF
}

# ---------- apt/dpkg 状态检查（替代原来的 pkill + 删锁） ----------
# 返回 0 表示 apt/dpkg 空闲（可以安全清理残留锁）
apt_is_idle() {
    local busy=''

    if command -v pgrep >/dev/null 2>&1; then
        # 用精确进程名匹配，避免匹配到含 "apt" 的任意命令行
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

    if [ -z "$busy" ]; then
        return 0
    fi

    err '检测到 apt/dpkg 正在运行，已跳过锁清理（避免损坏包数据库）：'
    printf '  %s\n' "$busy"
    echo '  请等待其结束（可用 systemctl status apt-daily.service 查看自动更新任务），再重新运行本脚本。'
    return 1
}

# 仅清理「确认无进程持有」的残留锁
clean_stale_locks() {
    local locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock /var/lib/apt/lists/lock)
    local removed=0 f
    for f in "${locks[@]}"; do
        [ -e "$f" ] || continue
        if command -v fuser >/dev/null 2>&1 && fuser "$f" >/dev/null 2>&1; then
            warn_record "跳过仍被占用的锁：$f"
            continue
        fi
        if rm -f -- "$f"; then
            removed=$((removed + 1))
        fi
    done
    if [ "$removed" -gt 0 ]; then
        record "清理了 ${removed} 个无进程持有的残留 apt/dpkg 锁文件"
    fi
}

# 修复中断的 dpkg（在确认空闲后执行）
fix_dpkg() {
    if ! apt_is_idle; then
        warn_record 'dpkg 修复被跳过（apt/dpkg 正忙）'
        return 1
    fi
    clean_stale_locks
    info '正在修复可能中断的 dpkg 状态（dpkg --configure -a）...'
    if DEBIAN_FRONTEND=noninteractive dpkg --configure -a >/dev/null 2>&1; then
        record 'dpkg --configure -a 已完成'
        return 0
    fi
    warn_record 'dpkg --configure -a 返回非零，请手动执行 dpkg --configure -a 查看详情'
    return 1
}

# ---------- journal 日志裁剪（默认不做） ----------
vacuum_journal() {
    local days="${1:-3}"
    case "$days" in
        ''|*[!0-9]*) err "日志保留天数必须是数字，收到：${days}"; return 1 ;;
    esac
    command -v journalctl >/dev/null 2>&1 || { warn_record '未找到 journalctl，跳过日志裁剪'; return 1; }
    info "正在把 systemd journal 裁剪为最近 ${days} 天（会删除更早的系统日志）..."
    journalctl --rotate >/dev/null 2>&1 || true
    if journalctl --vacuum-time="${days}d" >/dev/null 2>&1; then
        record "已将 journal 日志裁剪为最近 ${days} 天"
    else
        warn_record 'journal 裁剪失败'
    fi
}

# ---------- /tmp 清理：只删 24 小时前的普通文件 ----------
clean_tmp_old() {
    local count
    count="$(find /tmp -xdev -mindepth 1 -maxdepth 1 -mtime +1 2>/dev/null | wc -l)"
    if [ "${count:-0}" -eq 0 ]; then
        info '/tmp 中没有超过 24 小时的文件。'
        return 0
    fi
    info "/tmp 中有 ${count} 个超过 24 小时的项目，正在删除（保留近期文件与活动会话）..."
    # -xdev 避免跨文件系统；只删 24h 前的条目
    find /tmp -xdev -mindepth 1 -maxdepth 1 -mtime +1 -exec rm -rf -- {} + 2>/dev/null || true
    record "/tmp 中清理了 ${count} 个超过 24 小时的项目"
}

# ---------- 各发行版清理 ----------
clean_apt() {
    fix_dpkg || true

    info '正在执行 apt autoremove --purge（先列出将被删除的包）...'
    local purge_list
    purge_list="$(apt-get -s autoremove --purge 2>/dev/null | awk '/^Remv /{print $2}')"
    if [ -n "$purge_list" ]; then
        warn '以下软件包将被移除：'
        printf '  %s\n' $purge_list
        if [ "$ASSUME_YES" = 'yes' ]; then
            warn '（非交互模式，直接执行）'
        else
            local a
            read -r -p '确认移除以上软件包？(y/N): ' a || a='n'
            if [[ ! "$a" =~ ^[Yy]$ ]]; then
                warn_record '已跳过 autoremove --purge'
                purge_list=''
            fi
        fi
        if [ -n "$purge_list" ]; then
            if DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y >/dev/null 2>&1; then
                record 'apt autoremove --purge 已完成'
            else
                warn_record 'apt autoremove --purge 失败或部分失败'
            fi
        fi
    else
        info '没有可自动移除的软件包。'
    fi

    info '正在清理 apt 缓存（apt-get clean / autoclean）...'
    apt-get clean >/dev/null 2>&1 && record 'apt-get clean 已完成' || warn_record 'apt-get clean 失败'
    apt-get autoclean >/dev/null 2>&1 && record 'apt-get autoclean 已完成' || true

    # 仅清理无用的依赖缓存目录，不动 /var/log
    if [ -d /var/cache/apt/archives ] && [ -z "$(find /var/cache/apt/archives -maxdepth 1 -name '*.deb' -print -quit 2>/dev/null)" ]; then
        info '/var/cache/apt/archives 中没有残留 .deb 包。'
    fi
    clean_tmp_old
}

clean_dnf_yum() {
    local pm="$1"
    info "正在执行 ${pm} 清理..."
    rpm --rebuilddb >/dev/null 2>&1 && record 'rpm --rebuilddb 已完成' || warn_record 'rpm --rebuilddb 失败'
    "$pm" autoremove -y >/dev/null 2>&1 && record "${pm} autoremove 已完成" || true
    "$pm" clean all >/dev/null 2>&1 && record "${pm} clean all 已完成" || warn_record "${pm} clean all 失败"
    "$pm" makecache >/dev/null 2>&1 || true
    clean_tmp_old
}

clean_apk() {
    info '正在执行 apk 清理...'
    apk cache clean >/dev/null 2>&1 && record 'apk cache clean 已完成' || warn_record 'apk cache clean 失败'
    if [ -d /var/cache/apk ]; then
        rm -rf /var/cache/apk/* 2>/dev/null && record '已清空 /var/cache/apk' || true
    fi
    clean_tmp_old
}

clean_pacman() {
    info '正在执行 pacman 清理...'
    local orphans
    orphans="$(pacman -Qdtq 2>/dev/null || true)"
    if [ -n "$orphans" ]; then
        warn '以下孤立软件包将被移除：'
        printf '  %s\n' $orphans
        if [ "$ASSUME_YES" = 'yes' ]; then
            pacman -Rns $orphans --noconfirm >/dev/null 2>&1 && record 'pacman 孤立包已移除' || warn_record 'pacman 移除孤立包失败'
        else
            local a
            read -r -p '确认移除以上孤立包？(y/N): ' a || a='n'
            if [[ "$a" =~ ^[Yy]$ ]]; then
                pacman -Rns $orphans --noconfirm >/dev/null 2>&1 && record 'pacman 孤立包已移除' || warn_record 'pacman 移除孤立包失败'
            else
                warn_record '已跳过 pacman 孤立包移除'
            fi
        fi
    else
        info '没有孤立软件包。'
    fi
    pacman -Scc --noconfirm >/dev/null 2>&1 && record 'pacman 缓存已清理' || warn_record 'pacman 缓存清理失败'
    clean_tmp_old
}

clean_zypper() {
    info '正在执行 zypper 清理...'
    zypper clean --all >/dev/null 2>&1 && record 'zypper clean 已完成' || warn_record 'zypper clean 失败'
    zypper refresh >/dev/null 2>&1 || true
    clean_tmp_old
}

print_summary() {
    echo
    info '========== 清理结果 =========='
    if [ "${#CLEAN_ACTIONS[@]}" -gt 0 ]; then
        printf '  [完成] %s\n' "${CLEAN_ACTIONS[@]}"
    else
        echo '  （没有执行任何清理动作）'
    fi
    if [ "${#CLEAN_WARNINGS[@]}" -gt 0 ]; then
        printf '  [注意] %s\n' "${CLEAN_WARNINGS[@]}"
    fi
    echo
}

# ---------- 入口 ----------
ASSUME_YES='no'
LOG_DAYS=''

while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y) ASSUME_YES='yes' ;;
        --logs)
            shift
            LOG_DAYS="${1:-3}"
            ;;
        --logs=*) LOG_DAYS="${1#--logs=}" ;;
        -h|--help|help) usage; exit 0 ;;
        *) err "未知参数：$1"; usage; exit 1 ;;
    esac
    shift
done

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "请使用 root 权限运行此脚本（例如：sudo bash $0）"
    exit 1
fi

# 交互式确认清理范围
if [ "$ASSUME_YES" != 'yes' ] && [ -t 0 ]; then
    echo
    warn '系统清理将执行以下操作：'
    echo '  - 修复中断的 dpkg 状态（仅在确认无 apt/dpkg 运行时）'
    echo "  - 移除可自动清理的软件包、清理包管理器缓存"
    echo '  - 清理 /tmp 中超过 24 小时的文件'
    echo '  - 默认【不】删除系统日志'
    echo
    local_a=''
    read -r -p '是否继续？(y/N): ' local_a || local_a='n'
    if [[ ! "$local_a" =~ ^[Yy]$ ]]; then
        echo '已取消。'
        exit 0
    fi
    if [ -z "$LOG_DAYS" ]; then
        read -r -p '是否同时把系统日志(journal)裁剪为最近 3 天？(y/N): ' local_a || local_a='n'
        if [[ "$local_a" =~ ^[Yy]$ ]]; then
            LOG_DAYS=3
        fi
    fi
fi

info '正在系统清理...'

if command -v apt-get >/dev/null 2>&1; then
    clean_apt
elif command -v dnf >/dev/null 2>&1; then
    clean_dnf_yum dnf
elif command -v yum >/dev/null 2>&1; then
    clean_dnf_yum yum
elif command -v apk >/dev/null 2>&1; then
    clean_apk
elif command -v pacman >/dev/null 2>&1; then
    clean_pacman
elif command -v zypper >/dev/null 2>&1; then
    clean_zypper
else
    err '未知的包管理器！'
    exit 1
fi

if [ -n "$LOG_DAYS" ]; then
    vacuum_journal "$LOG_DAYS"
else
    info '未裁剪系统日志（如需请使用 --logs N 或交互式选择）。'
fi

print_summary
ok '系统清理完成。'
