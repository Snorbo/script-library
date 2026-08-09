#!/bin/bash
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

#定义快捷键z相关
SCRIPT_PATH="$(readlink -f "$0")"

#解绑z键
remove_z_shortcut() {
    local target="/usr/local/bin/z"

    if [ "$EUID" -ne 0 ]; then
        sudo rm -f "$target"
    else
        rm -f "$target"
    fi

    unalias z 2>/dev/null || true
    sed -i '/^[[:space:]]*alias z=/d' "$HOME/.bashrc" 2>/dev/null || true
    sed -i '/^[[:space:]]*alias z=/d' "$HOME/.zshrc" 2>/dev/null || true
    hash -r 2>/dev/null || true

    echo -e "${GREEN}已解绑快捷命令 z${NC}"
    read -p "按回车键继续..."
}

#绑定z键
install_z_shortcut() {
    local target="/usr/local/bin/z"
    if [ "$EUID" -ne 0 ]; then
        sudo ln -sf "$SCRIPT_PATH" "$target"
    else
        ln -sf "$SCRIPT_PATH" "$target"
    fi
    echo -e "${GREEN}已安装快捷命令：z${NC}"
    echo -e "${GREEN}现在可以直接输入 z 启动这个菜单${NC}"
    read -p "按回车键继续..."
}

# 打印 Logo
print_logo() {
    if command -v figlet >/dev/null 2>&1; then
        figlet -f standard "SNORBO"
    elif command -v toilet >/dev/null 2>&1; then
        toilet -f standard "SNORBO"
    else
        cat << 'EOF'
  SSS  N   N  OOO  RRRR  BBB   OOO 
 S     NN  N O   O R   R B   B O   O
  SSS  N N N O   O RRRR  BBBB  O   O
     S N  NN O   O R R   B   B O   O
  SSS  N   N  OOO  R  R  BBBB   OOO 
EOF
    fi
}

# 函数：显示菜单
show_menu() {
    clear
    echo -e "${BLUE}========================================${NC}"
    print_logo
    echo -e "${GREEN}             综合面板${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "------配置SSH"
    echo "1. 修改 SSH 连接端口"
    echo "2. 启用 SSH 密钥连接"
    echo "------检测脚本与相关配置"
    echo "3. 禁用 IPQS（写入 hosts）"
    echo "4. 空出 53 端口"
    echo "5. 调用 IP 质量检测脚本"
    echo "6. 调用流媒体解锁检测脚本"
    echo "7. 调用 NodeQuality 检测脚本"
    echo "------安装应用"
    echo "8. 安装 nexttrace"
    echo "9. 安装支持 BBR3 的内核"
    echo "10. 安装 3x-ui 面板"
    echo "11. 安装 Adguardhome"
    echo "12. 安装 Openlist"
    echo "13. 安装 nginx"
    echo "14. 配置 nginx.conf"
    echo "------系统相关"
    echo "15. 配置系统更新"
    echo "16. Ubuntu24升级Ubuntu26"
    echo "17. 查看系统信息"
    echo "18. 系统清理"
    echo "19. 设置虚拟内存"
    echo "------证书"
    echo "20. 配置通配符证书"
    echo "------额外选项"
    echo "21. 安装快捷命令 z（可直接输入 z 启动菜单）"
    echo "22. 解除快捷命令 z"
    echo "23. 安装基础包"3
    echo "24. 配置ufw防火墙"
    echo "99. 端口备忘"
    echo "0. 退出脚本"
    echo -e "${BLUE}========================================${NC}"
    echo -n "请输入选项 [0-24]: "
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
    echo -e "${GREEN}完成，服务器即将重启${NC}"
    reboot
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
    sudo bash -c 'echo -e "[Resolve]\nDNS=1.1.1.1 8.8.8.8\nDNSStubListener=no" > /etc/systemd/resolved.conf && \
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

# 7. NodeQuality 检测
option7() {
    echo -e "${YELLOW}执行：NodeQuality 检测...${NC}"
    bash <(curl -sL https://run.NodeQuality.com)
    echo -e "${GREEN}完成。${NC}"
    read -p "按回车键继续..."
}

# 8. 安装 nexttrace
option8() {
    echo -e "${YELLOW}执行：安装 nexttrace...${NC}"
    curl -sL nxtrace.org/nt | bash
    echo -e "${GREEN}完成。${NC}"
    read -p "按回车键继续..."
}

# 9. 安装 BBR 内核（带参数 1）
option9() {
    echo -e "${YELLOW}执行：安装支持 BBR 的内核（参数 1）...${NC}"
    # 使用 bash <(curl) 传递参数 1
    bash <(curl -s https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/2026newconfig/bbr.sh) 1
    echo -e "${GREEN}完成。${NC}"
    read -p "按回车键继续..."
}

# 10. 安装 3x-ui 面板
option10() {
    echo -e "${YELLOW}执行：安装 3x-ui 面板...${NC}"
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
    echo -e "${GREEN}完成。${NC}"
    read -p "按回车键继续..."
}

# 11. 安装Adguardhome
option11() {
    echo -e "${YELLOW}====== 系统升级 ======${NC}"
    echo -e "${BLUE}→ 执行 Adguardhome 安装脚本 ...${NC}"
    curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
    echo -e "${GREEN}Adguardhome安装完成。${NC}"
    echo -e "${GREEN}若需卸载可执行：wget --no-verbose -O - https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -u${NC}"
    read -p "按回车键继续..."
}

# 12. 安装Openlist
option12() {
    echo -e "${YELLOW}====== 系统升级 ======${NC}"
    echo -e "${BLUE}→ 执行 Openlist 安装脚本 ...${NC}"
    curl -fsSL https://res.oplist.org/script/v4.sh > install-openlist-v4.sh && sudo bash install-openlist-v4.sh
    echo -e "${GREEN}Openlist安装完成。${NC}"
    read -p "按回车键继续..."
}

# 13. 编译安装 Nginx
option13() {
    echo -e "${YELLOW}====== 编译安装 Nginx ======${NC}"

    local nginx_version="1.31.3"
    local nginx_tar="nginx-${nginx_version}.tar.gz"
    local nginx_dir="nginx-${nginx_version}"

    echo -e "${BLUE}→ 安装编译依赖...${NC}"
    sudo apt update
    sudo apt install -y wget gcc make libpcre3 libpcre3-dev zlib1g zlib1g-dev libssl-dev

    echo -e "${BLUE}→ 下载 Nginx ${nginx_version}...${NC}"
    cd /usr/local/src || exit 1
    sudo wget -O "$nginx_tar" "https://nginx.org/download/${nginx_tar}"

    echo -e "${BLUE}→ 解压源码...${NC}"
    sudo tar -zxvf "$nginx_tar"
    cd "$nginx_dir" || exit 1

    echo -e "${BLUE}→ 配置编译参数...${NC}"
    sudo ./configure \
        --prefix=/usr/local/nginx \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_v3_module \
        --with-stream \
        --with-stream_ssl_module \
        --with-http_realip_module \
        --with-stream_ssl_preread_module

    echo -e "${BLUE}→ 编译并安装...${NC}"
    sudo make
    sudo make install

    echo -e "${BLUE}→ 配置 Nginx systemd 服务...${NC}"
    sudo tee /etc/systemd/system/nginx.service >/dev/null <<'EOF'
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=syslog.target network-online.target remote-fs.target nss-lookup.target
After=xray.service

[Service]
Type=forking
ExecStartPre=/usr/local/nginx/sbin/nginx -t
ExecStart=/usr/local/nginx/sbin/nginx
ExecReload=/usr/local/nginx/sbin/nginx -s reload
ExecStop=/bin/kill -s QUIT $MAINPID
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${BLUE}→ 添加 Nginx 到 PATH...${NC}"
    echo 'export PATH=$PATH:/usr/local/nginx/sbin' | sudo tee /etc/profile.d/nginx-path.sh >/dev/null

    echo -e "${BLUE}→ 启用并启动 Nginx...${NC}"
    sudo systemctl daemon-reload
    sudo systemctl enable --now nginx

    echo -e "${GREEN}Nginx 编译安装完成。${NC}"
    sudo systemctl status nginx --no-pager

    read -p "按回车键继续..."
}

# 14. 修改 nginx.conf
option14() {
    echo -e "${YELLOW}执行nginx.conf修改脚本...${NC}"
    bash <(curl -s https://raw.githubusercontent.com/Snorbo/script-library/refs/heads/main/nginxconf.sh)
    echo -e "${GREEN}完成。${NC}"
    read -p "按回车键继续..."
}

# 15. 配置系统更新（update & full-upgrade & autoremove）
option15() {
    echo -e "${YELLOW}====== 配置系统更新 ======${NC}"
    echo -e "${BLUE}→ 执行 sudo apt update ...${NC}"
    sudo apt update
    echo -e "${BLUE}→ 执行 sudo apt full-upgrade -y ...${NC}"
    sudo apt full-upgrade -y
    echo -e "${BLUE}→ 执行 sudo apt autoremove -y ...${NC}"
    sudo apt autoremove -y
    echo -e "${GREEN}系统更新完成。${NC}"
    read -p "按回车键继续..."
}

# 16. Ubuntu系统升级
option16() {
    echo -e "${YELLOW}====== 系统升级 ======${NC}"
    echo -e "${BLUE}→ 执行 sudo do-release-upgrade ...${NC}"
    sudo do-release-upgrade
    echo -e "${GREEN}系统升级完成。${NC}"
    read -p "按回车键继续..."
}

# 17. 查看系统信息
option17() {
    echo -e "${YELLOW}执行：拉取信息获取脚本...${NC}"
    bash <(curl -s https://raw.githubusercontent.com/Snorbo/script-library/refs/heads/main/sysinfo.sh)
    echo -e "${GREEN}完成。${NC}"
    read -p "按回车键继续..."
}

# 18. 系统清理
option18() {
    echo -e "${YELLOW}执行：拉取清理脚本...${NC}"
    bash <(curl -s https://raw.githubusercontent.com/Snorbo/script-library/refs/heads/main/sysclean.sh)
    echo -e "${GREEN}完成。${NC}"
    read -p "按回车键继续..."
}

# 19. 设置虚拟内存
option19() {
    echo -e "${YELLOW}执行：设置虚拟内存...${NC}"
    bash <(curl -L -s https://raw.githubusercontent.com/Snorbo/script-library/refs/heads/main/swap.sh)
    echo -e "${GREEN}完成。${NC}"
    read -p "按回车键继续..."
}

# 20. 配置通配符证书（Certbot + Cloudflare DNS）
option20() {
    echo -e "${YELLOW}====== 配置通配符证书（Certbot + Cloudflare DNS） ======${NC}"
    
    # 1. 移除旧版 certbot（如有）
    echo -e "${BLUE}→ 移除旧版 certbot...${NC}"
    sudo apt-get remove -y certbot 2>/dev/null || true

    # 2. 通过 snap 安装 certbot
    echo -e "${BLUE}→ 安装 certbot（snap）...${NC}"
    sudo snap install certbot --classic

    # 3. 创建软链接
    echo -e "${BLUE}→ 创建 /usr/bin/certbot 软链接...${NC}"
    sudo ln -sf /snap/bin/certbot /usr/bin/certbot

    # 4. 允许 snap 插件以 root 运行
    echo -e "${BLUE}→ 设置 trust-plugin-with-root...${NC}"
    sudo snap set certbot trust-plugin-with-root=ok

    # 5. 安装 Cloudflare DNS 插件
    echo -e "${BLUE}→ 安装 certbot-dns-cloudflare 插件...${NC}"
    sudo snap install certbot-dns-cloudflare

    # 6. 创建 Cloudflare 凭证文件（由用户输入 API Key）
    echo -e "${BLUE}→ 请输入你的 Cloudflare API Key（输入时不显示，请直接粘贴后回车）：${NC}"
    read -s api_key
    if [ -z "$api_key" ]; then
        echo -e "${RED}API Key 不能为空，取消操作。${NC}"
        read -p "按回车键继续..."
        return
    fi
    echo -e "${BLUE}→ 创建 /etc/letsencrypt/cloudflare.int 并设置权限...${NC}"
    sudo mkdir -p /etc/letsencrypt
    # 注意：邮箱固定为 email.snorbo@gmail.com，若需修改可自行调整
    sudo tee /etc/letsencrypt/cloudflare.int > /dev/null <<EOF
# Cloudflare API credentials used by Certbot
dns_cloudflare_email = email.snorbo@gmail.com
dns_cloudflare_api_key = ${api_key}
EOF
    sudo chmod 0400 /etc/letsencrypt/cloudflare.int

    # 7. 询问通配符域名
    echo -e "${BLUE}→ 请输入你要申请的通配符域名（例如 *.example.com）：${NC}"
    read -p "域名: " wildcard_domain
    if [ -z "$wildcard_domain" ]; then
        echo -e "${RED}域名不能为空，取消操作。${NC}"
        read -p "按回车键继续..."
        return
    fi

    # 8. 执行 certbot 申请证书
    echo -e "${BLUE}→ 开始申请证书，请稍候...${NC}"
    sudo certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.int \
        --dns-cloudflare-propagation-seconds 60 \
        --key-type ecdsa \
        -d "$wildcard_domain"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}证书申请成功！证书位置：/etc/letsencrypt/live/${wildcard_domain}/${NC}"
        echo -e "${GREEN}证书位置：/etc/letsencrypt/live/${wildcard_domain}/fullchain.pem${NC}"
        echo -e "${GREEN}私钥位置：/etc/letsencrypt/live/${wildcard_domain}/privkey.pem${NC}"
        echo -e "${GREEN}子命令certificates显示所有证书的信息；revoke吊销证书；delete删除证书${NC}"
        echo -e "${GREEN}示例：sudo certbot certificates ${NC}"
    else
        echo -e "${RED}证书申请失败，请检查域名、API 凭证及网络。${NC}"
    fi

    read -p "按回车键继续..."
}

# 23. 安装基础包
option23() {
    echo -e "${YELLOW}执行：安装基础工具...${NC}"
    sudo apt update && sudo apt install -y curl wget sudo socat htop unzip tar tmux vim nano git
    echo -e "${GREEN}基础工具安装完成。${NC}"
    read -p "按回车键继续..."
}

# 24. 配置ufw防火墙
option24() {
    echo -e "${YELLOW}正在拉取脚本...${NC}"
    bash <(curl -s https://raw.githubusercontent.com/Snorbo/script-library/refs/heads/main/ufw.sh)
    echo -e "${GREEN}完成。${NC}"
    read -p "按回车键继续..."
}

option99() {
    clear
    echo -e "${YELLOW}====== 端口备忘 ======${NC}"
    echo "53：DNS"
    echo ""
    echo "80：nginx"
    echo "443：nginx"
    echo ""
    echo "8443：nginx"
    echo "1553：hysteria2"
    echo "1551：x-ui"
    echo "1554：x-ui"
    echo "1556：SSH"
    echo "1552/5244：openlist"
    echo "1555：x-uiweb"
    echo "3000：adguard"
    echo ""
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
        10) option10 ;;
        11) option11 ;;
        12) option12 ;;
        13) option13 ;;
        14) option14 ;;
        15) option15 ;;
        16) option16 ;;
        17) option17 ;;
        18) option18 ;;
        19) option19 ;;
        20) option20 ;;
        21) install_z_shortcut ;;
        22) remove_z_shortcut ;;
        23) option23 ;;
        24) option24 ;;
        99) option99 ;;
        0) echo -e "${GREEN}退出脚本。${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入。${NC}"; sleep 1 ;;
    esac
done
