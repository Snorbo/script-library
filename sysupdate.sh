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

# 系统更新主函数
linux_update() {
    echo -e "${gl_kjlan}正在系统更新...${gl_bai}"
    
    if command -v dnf &>/dev/null; then
        dnf -y update
    elif command -v yum &>/dev/null; then
        yum -y update
    elif command -v apt &>/dev/null; then
        fix_dpkg
        DEBIAN_FRONTEND=noninteractive apt update -y
        DEBIAN_FRONTEND=noninteractive apt full-upgrade -y
    elif command -v apk &>/dev/null; then
        apk update && apk upgrade
    elif command -v pacman &>/dev/null; then
        pacman -Syu --noconfirm
    elif command -v zypper &>/dev/null; then
        zypper refresh
        zypper update
    elif command -v opkg &>/dev/null; then
        opkg update
    else
        echo -e "${gl_hong}未知的包管理器！${gl_bai}"
        return 1
    fi
    
    echo -e "${gl_kjlan}系统更新完成。${gl_bai}"
}

# 检查是否需要 root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${gl_hong}请使用 root 权限运行此脚本（例如：sudo $0）${gl_bai}"
    exit 1
fi

# 执行更新
linux_update
