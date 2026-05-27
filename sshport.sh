#!/bin/bash

# 颜色定义
gl_hong='\033[31m'
gl_lv='\033[32m'
gl_huang='\033[33m'
gl_bai='\033[0m'
gl_kjlan='\033[96m'

# 通用安装函数（精简版，仅支持主流包管理器）
install() {
    for package in "$@"; do
        if ! command -v "$package" &>/dev/null; then
            echo -e "${gl_kjlan}正在安装 $package...${gl_bai}"
            if command -v dnf &>/dev/null; then
                dnf install -y "$package"
            elif command -v yum &>/dev/null; then
                yum install -y "$package"
            elif command -v apt &>/dev/null; then
                apt update -y && apt install -y "$package"
            elif command -v apk &>/dev/null; then
                apk add "$package"
            elif command -v pacman &>/dev/null; then
                pacman -S --noconfirm "$package"
            elif command -v zypper &>/dev/null; then
                zypper install -y "$package"
            else
                echo "未知的包管理器，无法安装 $package"
                return 1
            fi
        fi
    done
}

# 通用重启函数
restart() {
    local SERVICE_NAME="$1"
    if command -v apk &>/dev/null; then
        service "$SERVICE_NAME" restart
    else
        systemctl restart "$SERVICE_NAME"
    fi
    if [ $? -eq 0 ]; then
        echo "$SERVICE_NAME 服务已重启。"
    else
        echo "错误：重启 $SERVICE_NAME 服务失败。"
    fi
}

# 重启 SSH 服务
restart_ssh() {
    restart sshd > /dev/null 2>&1
}

# 修正 SSH 配置（确保基本登录方式正确）
correct_ssh_config() {
    local sshd_config="/etc/ssh/sshd_config"
    # 防止因为某些配置导致无法登录，设置合理的默认值
    if grep -Eq "^\s*PasswordAuthentication\s+no" "$sshd_config"; then
        sed -i -e 's/^\s*#\?\s*PermitRootLogin .*/PermitRootLogin prohibit-password/' \
               -e 's/^\s*#\?\s*PasswordAuthentication .*/PasswordAuthentication no/' \
               -e 's/^\s*#\?\s*PubkeyAuthentication .*/PubkeyAuthentication yes/' \
               -e 's/^\s*#\?\s*ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' "$sshd_config"
    else
        sed -i -e 's/^\s*#\?\s*PermitRootLogin .*/PermitRootLogin yes/' \
               -e 's/^\s*#\?\s*PasswordAuthentication .*/PasswordAuthentication yes/' \
               -e 's/^\s*#\?\s*PubkeyAuthentication .*/PubkeyAuthentication yes/' "$sshd_config"
    fi
    rm -rf /etc/ssh/sshd_config.d/* /etc/ssh/ssh_config.d/* 2>/dev/null
}

# 保存 iptables 规则（持久化）
save_iptables_rules() {
    install iptables iptables-persistent 2>/dev/null
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    # 设置开机自动恢复
    if ! grep -q "iptables-restore" /etc/rc.local 2>/dev/null; then
        echo "iptables-restore < /etc/iptables/rules.v4" >> /etc/rc.local
        chmod +x /etc/rc.local
    fi
}

# 开放指定端口
open_port() {
    local ports=($@)
    if [ ${#ports[@]} -eq 0 ]; then
        echo "请提供至少一个端口号"
        return 1
    fi
    install iptables
    for port in "${ports[@]}"; do
        iptables -D INPUT -p tcp --dport $port -j DROP 2>/dev/null
        iptables -D INPUT -p udp --dport $port -j DROP 2>/dev/null
        if ! iptables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null; then
            iptables -I INPUT 1 -p tcp --dport $port -j ACCEPT
        fi
        if ! iptables -C INPUT -p udp --dport $port -j ACCEPT 2>/dev/null; then
            iptables -I INPUT 1 -p udp --dport $port -j ACCEPT
            echo -e "${gl_lv}已打开端口 $port${gl_bai}"
        fi
    done
    save_iptables_rules
}

# 修改 SSH 端口主函数
new_ssh_port() {
    local new_port=$1
    if [[ -z "$new_port" ]]; then
        echo "用法：$0 <新端口号>"
        exit 1
    fi
    # 备份原配置
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    # 删除已有 Port 行，添加新端口
    sed -i '/^\s*#\?\s*Port\s\+/d' /etc/ssh/sshd_config
    echo "Port $new_port" >> /etc/ssh/sshd_config
    # 确保其他基本配置正确
    correct_ssh_config
    # 重启 SSH 服务
    restart_ssh
    # 放行新端口（防火墙）
    open_port $new_port
    # 可选：关闭旧的 SSH 端口（原配置中的端口号，需要用户提前告知，这里省略）
    echo -e "${gl_lv}SSH 端口已修改为: $new_port${gl_bai}"
    echo -e "${gl_huang}请确保新端口 $new_port 已放行，并保持当前连接，测试新端口可用后再关闭旧会话。${gl_bai}"
}

# 主程序：交互式输入端口号或直接传参
if [ "$EUID" -ne 0 ]; then
    echo -e "${gl_hong}请使用 root 权限运行此脚本（例如：sudo $0）${gl_bai}"
    exit 1
fi

if [ $# -eq 1 ]; then
    # 通过参数传入端口号
    PORT="$1"
else
    # 交互式输入
    echo -e "${gl_kjlan}修改 SSH 连接端口${gl_bai}"
    echo "------------------------"
    # 读取当前端口（如果配置了多个 Port，只显示第一个）
    CURRENT_PORT=$(grep -E '^ *Port [0-9]+' /etc/ssh/sshd_config | awk '{print $2}')
    if [ -n "$CURRENT_PORT" ]; then
        echo -e "当前 SSH 端口号: ${gl_huang}$CURRENT_PORT${gl_bai}"
    else
        echo -e "当前 SSH 端口号: ${gl_huang}22（默认）${gl_bai}"
    fi
    echo "------------------------"
    echo "端口号范围 1-65535（输入 0 退出）"
    while true; do
        read -e -p "请输入新的 SSH 端口号: " PORT
        if [[ "$PORT" =~ ^[0-9]+$ ]]; then
            if [ "$PORT" -eq 0 ]; then
                echo "已取消修改。"
                exit 0
            elif [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
                break
            else
                echo -e "${gl_hong}端口号无效，请输入 1-65535 之间的数字。${gl_bai}"
            fi
        else
            echo -e "${gl_hong}输入无效，请输入数字。${gl_bai}"
        fi
    done
fi

# 执行修改
new_ssh_port "$PORT"
