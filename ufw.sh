#!/bin/bash

# ============================================
# UFW 管理脚本（中文菜单）
# 功能：安装/卸载/端口管理/启用/禁用/状态
# 需要 root 权限运行
# 自动适配多种包管理器
# ============================================

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
    echo "错误：请使用 root 用户执行此脚本（sudo ./script.sh）"
    exit 1
fi

# 检测包管理器
detect_package_manager() {
    if command -v apt &> /dev/null; then
        echo "apt"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    elif command -v yum &> /dev/null; then
        echo "yum"
    elif command -v pacman &> /dev/null; then
        echo "pacman"
    elif command -v zypper &> /dev/null; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

# 安装 UFW（根据包管理器）
install_ufw() {
    local pkg_manager=$(detect_package_manager)
    echo "检测到包管理器: $pkg_manager"
    case $pkg_manager in
        apt)
            apt update && apt install ufw -y
            ;;
        dnf)
            dnf install ufw -y
            ;;
        yum)
            yum install ufw -y
            ;;
        pacman)
            pacman -S ufw --noconfirm
            ;;
        zypper)
            zypper install -y ufw
            ;;
        *)
            echo "错误：无法识别的包管理器，请手动安装 ufw。"
            return 1
            ;;
    esac

    if command -v ufw &> /dev/null; then
        echo "UFW 安装成功！"
    else
        echo "安装失败，请检查网络或手动安装。"
        return 1
    fi
}

# 检查 UFW 是否已安装（用于其他功能前）
check_ufw_installed() {
    if ! command -v ufw &> /dev/null; then
        echo "错误：UFW 尚未安装。请先选择菜单选项中的“8. 安装 UFW”。"
        read -p "按回车键返回菜单..." dummy
        return 1
    fi
    return 0
}

# 显示菜单
show_menu() {
    clear
    echo "====================================="
    echo "        UFW 防火墙管理脚本          "
    echo "====================================="
    echo "  1. 卸载防火墙 (Uninstall)"
    echo "  2. 查看端口列表 (带编号)"
    echo "  3. 开放端口"
    echo "  4. 根据编号删除端口"
    echo "  5. 启用防火墙"
    echo "  6. 禁用防火墙"
    echo "  7. 查看防火墙状态"
    echo "  8. 安装 UFW"
    echo "  0. 退出脚本"
    echo "====================================="
    echo -n "请选择操作 [0-8]: "
}

# 卸载防火墙
uninstall_firewall() {
    check_ufw_installed || return
    read -p "警告：此操作将完全移除 UFW 并清除所有规则，是否继续？(y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        ufw --force disable 2>/dev/null
        apt remove --purge ufw -y
        # 如果是其他包管理器安装的，需要对应卸载（简化处理，因为卸载主要由 apt 完成，其他管理器同理但此处调用通用）
        # 实际上 ufw 主要通过 apt 安装，若为其它管理器，也可用对应命令，这里简单处理
        local pkg_manager=$(detect_package_manager)
        case $pkg_manager in
            dnf|yum) $pkg_manager remove -y ufw ;;
            pacman) pacman -Rns ufw --noconfirm ;;
            zypper) zypper remove -y ufw ;;
        esac
        echo "UFW 已卸载。"
    else
        echo "操作已取消。"
    fi
    read -p "按回车键继续..." dummy
}

# 查看端口列表（编号）
list_ports() {
    check_ufw_installed || return
    echo "当前 UFW 状态："
    ufw status numbered
    read -p "按回车键继续..." dummy
}

# 开放端口
open_ports() {
    check_ufw_installed || return
    read -p "请输入要开放的端口号: " port
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        echo "无效端口号，请输入 1-65535 之间的数字。"
        read -p "按回车键继续..." dummy
        return
    fi
    echo "选择协议："
    echo "1. TCP"
    echo "2. UDP"
    echo "3. 两者（TCP+UDP）"
    read -p "请选择 [1-3] (默认 1): " proto_choice
    case $proto_choice in
        2) proto="udp" ;;
        3) proto="" ;;
        *) proto="tcp" ;;
    esac
    if [[ -z "$proto" ]]; then
        ufw allow "$port"
        echo "已允许端口 $port (TCP+UDP)"
    else
        ufw allow "$port"/"$proto"
        echo "已允许端口 $port/$proto"
    fi
    read -p "按回车键继续..." dummy
}

# 根据编号删除端口
delete_port_by_number() {
    check_ufw_installed || return
    echo "当前规则列表（带编号）："
    ufw status numbered
    read -p "请输入要删除的规则编号: " num
    if [[ ! "$num" =~ ^[0-9]+$ ]]; then
        echo "无效编号。"
        read -p "按回车键继续..." dummy
        return
    fi
    echo "y" | ufw delete "$num" 2>/dev/null
    if [[ $? -eq 0 ]]; then
        echo "规则 $num 已删除。"
    else
        echo "删除失败，请检查编号是否正确。"
    fi
    read -p "按回车键继续..." dummy
}

# 启用防火墙
enable_firewall() {
    check_ufw_installed || return
    ufw enable
    echo "防火墙已启用。"
    read -p "按回车键继续..." dummy
}

# 禁用防火墙
disable_firewall() {
    check_ufw_installed || return
    ufw disable
    echo "防火墙已禁用。"
    read -p "按回车键继续..." dummy
}

# 查看防火墙状态
show_status() {
    check_ufw_installed || return
    ufw status verbose
    read -p "按回车键继续..." dummy
}

# ========== 主程序 ==========
while true; do
    show_menu
    read choice
    case $choice in
        1) uninstall_firewall ;;
        2) list_ports ;;
        3) open_ports ;;
        4) delete_port_by_number ;;
        5) enable_firewall ;;
        6) disable_firewall ;;
        7) show_status ;;
        8) install_ufw ;;
        0) echo "退出脚本。"; exit 0 ;;
        *) echo "无效选项，请重新选择。" ; sleep 1 ;;
    esac
done
