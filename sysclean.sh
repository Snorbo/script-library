#!/bin/bash

# 颜色定义
gl_kjlan='\033[96m'
gl_bai='\033[0m'
gl_hong='\033[31m'

# 修复 dpkg 中断问题（仅 Debian/Ubuntu）
fix_dpkg() {
    pkill -9 -f 'apt|dpkg' 2>/dev/null
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>/dev/null
}

# 系统清理主函数
linux_clean() {
    echo -e "${gl_kjlan}正在系统清理...${gl_bai}"
    
    if command -v dnf &>/dev/null; then
        rpm --rebuilddb
        dnf autoremove -y
        dnf clean all
        dnf makecache
        journalctl --rotate
        journalctl --vacuum-time=1s
        journalctl --vacuum-size=500M
    elif command -v yum &>/dev/null; then
        rpm --rebuilddb
        yum autoremove -y
        yum clean all
        yum makecache
        journalctl --rotate
        journalctl --vacuum-time=1s
        journalctl --vacuum-size=500M
    elif command -v apt &>/dev/null; then
        fix_dpkg
        apt autoremove --purge -y
        apt clean -y
        apt autoclean -y
        journalctl --rotate
        journalctl --vacuum-time=1s
        journalctl --vacuum-size=500M
    elif command -v apk &>/dev/null; then
        echo "清理包管理器缓存..."
        apk cache clean
        echo "删除系统日志..."
        rm -rf /var/log/*
        echo "删除APK缓存..."
        rm -rf /var/cache/apk/*
        echo "删除临时文件..."
        rm -rf /tmp/*
    elif command -v pacman &>/dev/null; then
        pacman -Rns $(pacman -Qdtq) --noconfirm 2>/dev/null
        pacman -Scc --noconfirm
        journalctl --rotate
        journalctl --vacuum-time=1s
        journalctl --vacuum-size=500M
    elif command -v zypper &>/dev/null; then
        zypper clean --all
        zypper refresh
        journalctl --rotate
        journalctl --vacuum-time=1s
        journalctl --vacuum-size=500M
    elif command -v opkg &>/dev/null; then
        echo "删除系统日志..."
        rm -rf /var/log/*
        echo "删除临时文件..."
        rm -rf /tmp/*
    elif command -v pkg &>/dev/null; then
        echo "清理未使用的依赖..."
        pkg autoremove -y
        echo "清理包管理器缓存..."
        pkg clean -y
        echo "删除系统日志..."
        rm -rf /var/log/*
        echo "删除临时文件..."
        rm -rf /tmp/*
    else
        echo -e "${gl_hong}未知的包管理器！${gl_bai}"
        return 1
    fi
    
    echo -e "${gl_kjlan}系统清理完成。${gl_bai}"
}

# 检查是否需要 root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${gl_hong}请使用 root 权限运行此脚本（例如：sudo $0）${gl_bai}"
    exit 1
fi

# 执行清理
linux_clean
