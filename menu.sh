#!/bin/bash
# ==================================================
# 系统初始化 & 工具箱菜单
# 用法：sudo ./menu.sh
# ==================================================

# 检查是否以 root 运行（多数操作需要提权）
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[33m警告：建议以 root 用户执行此脚本，否则部分命令可能因权限不足而失败。\033[0m"
    echo -e "你可以使用 \033[36msudo ./menu.sh\033[0m 重新运行。\n"
fi

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 函数：显示菜单
show_menu() {
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}         面板@By Snorbo${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "1. 修改 SSH 连接端口"
    echo "2. 启用 SSH 密钥连接"
    echo "3. 禁用 IPQS（写入 hosts）"
    echo "4. 空出 53 端口（调整 systemd-resolved）"
    echo "5. 调用 IP 质量检测脚本"
    echo "6. 调用流媒体解锁检测脚本"
    echo "7. 安装 nexttrace"
    echo "8. 安装支持 BBR 的内核（带参数 1）"
    echo "9. 安装 3x-ui 面板"
    echo "0. 退出脚本"
    echo -e "${BLUE}========================================${NC}"
    echo -n "请输入选项 [0-9]: "
}

# 1. 修改 SSH 端口
option1() {
    echo -e "${YELLOW}执行：修改 SSH 连接端口...${NC}"
    bash <(curl -s https://raw.githubusercontent.com/Snorbo/script-library/refs/heads/main/sshport.sh)
    echo -e "${GREEN}完成。${NC}"
    read -p "按回车键继续..."
}

# 2. 启用 SSH 密钥
option2() {
    echo -e "${YELLOW}执行：启用 SSH 密钥连接...${NC}"
    bash <(curl -s https://raw.githubusercontent.com/Snorbo/script-library/refs/heads/main/sshkey.sh)
    echo -e "${GREEN}完成。${NC}"
    read -p "按回车键继续..."
}

# 3. 禁用 IPQS
option3() {
    echo -e "${YELLOW}执行：禁用 IPQS（修改 /etc/hosts）...${NC}"
    sudo sed -i '/ipqualityscore.com/d' /etc/hosts && \
    sudo sh -c 'echo "127.0.0.1 ipqualityscore.com\n127.0.0.1 www.ipqualityscore.com\n127.0.0.1 api.ipqualityscore.com" >> /etc/hosts'
    echo -e "${GREEN}完成。${NC}"
    read -p "按回车键继续..."
}

# 4. 空出 53 端口
option4() {
    echo -e "${YELLOW}执行：空出 53 端口（调整 systemd-resolved）...${NC}"
    sudo bash -c 'echo -e "[Resolve]\nDNS=8.8.8.8 1.1.1.1\nDNSStubListener=no" > /etc/systemd/resolved.conf && \
                   ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf && \
                   systemctl restart systemd-resolved'
    echo -e "${GREEN}完成。${NC}"
    read -p "按回车键继续..."
}

# 5. IP 质量检测
option5() {
    echo -e "${YELLOW}执行：IP 质量检测...${NC}"
    bash <(curl -s https://raw.githubusercontent.com/Snorbo/script-library/refs/heads/main/IPcheck.sh)
    echo -e "${GREEN}完成。${NC}"
    read -p "按回车键继续..."
}

# 6. 流媒体解锁检测
option6() {
    echo -e "${YELLOW}执行：流媒体解锁检测...${NC}"
    bash <(curl -L -s https://github.com/1-stream/RegionRestrictionCheck/raw/main/check.sh)
    echo -e "${GREEN}完成。${NC}"
    read -p "按回车键继续..."
}

# 7. 安装 nexttrace
option7() {
    echo -e "${YELLOW}执行：安装 nexttrace...${NC}"
    curl -sL nxtrace.org/nt | bash
    echo -e "${GREEN}完成。${NC}"
    read -p "按回车键继续..."
}

# 8. 安装 BBR 内核（带参数 1）
option8() {
    echo -e "${YELLOW}执行：安装支持 BBR 的内核（参数 1）...${NC}"
    # 使用 bash <(curl) 传递参数 1
    bash <(curl -s https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/2026newconfig/bbr.sh) 1
    echo -e "${GREEN}完成。${NC}"
    read -p "按回车键继续..."
}

# 9. 安装 3x-ui 面板
option9() {
    echo -e "${YELLOW}执行：安装 3x-ui 面板...${NC}"
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
    echo -e "${GREEN}完成。${NC}"
    read -p "按回车键继续..."
}

# 主循环
while true; do
    show_menu
    read choice
    case $choice in
        1) option1 ;;
        2) option2 ;;
        3) option3 ;;
        4) option4 ;;
        5) option5 ;;
        6) option6 ;;
        7) option7 ;;
        8) option8 ;;
        9) option9 ;;
        0) echo -e "${GREEN}退出脚本。${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入。${NC}"; sleep 1 ;;
    esac
done
