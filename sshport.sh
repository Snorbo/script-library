#!/bin/bash
# 更换SSH端口脚本（基于科技lion脚本提取）
# 使用方法：以root身份运行，按提示输入新端口号

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 检查root权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误：请以 root 用户运行此脚本${NC}"
  exit 1
fi

# 获取当前SSH端口（若未设置则默认22）
current_port=$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config | awk '{print $2}')
if [ -z "$current_port" ]; then
  current_port=22
fi
echo -e "当前SSH端口号：${YELLOW}${current_port}${NC}"

# 输入新端口
while true; do
  read -p "请输入新的SSH端口号（1-65535，输入0退出）: " new_port
  if [[ "$new_port" =~ ^[0-9]+$ ]]; then
    if [ "$new_port" -eq 0 ]; then
      echo "已取消操作。"
      exit 0
    elif [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
      break
    fi
  fi
  echo -e "${RED}无效端口，请输入1-65535之间的数字。${NC}"
done

# 备份配置文件
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
echo "已备份配置文件到 /etc/ssh/sshd_config.bak"

# 修改端口（删除原有Port行，在文件首行插入新Port）
sed -i '/^[[:space:]]*#\?[[:space:]]*Port[[:space:]]\+/d' /etc/ssh/sshd_config
sed -i "1i Port $new_port" /etc/ssh/sshd_config

# 重启SSH服务
echo "正在重启SSH服务..."
if command -v systemctl >/dev/null 2>&1; then
  systemctl restart sshd || systemctl restart ssh
elif command -v service >/dev/null 2>&1; then
  service sshd restart || service ssh restart
else
  /etc/init.d/sshd restart || /etc/init.d/ssh restart
fi

# 尝试自动开放防火墙端口（支持iptables/firewalld/ufw）
echo "尝试自动开放新端口..."
if command -v iptables >/dev/null 2>&1; then
  # 检查并添加iptables规则
  if ! iptables -C INPUT -p tcp --dport "$new_port" -j ACCEPT 2>/dev/null; then
    iptables -I INPUT 1 -p tcp --dport "$new_port" -j ACCEPT
    echo "已添加iptables规则允许TCP端口 $new_port"
  else
    echo "iptables规则已存在"
  fi
  # 保存规则（兼容常见保存方式）
  if command -v iptables-save >/dev/null 2>&1; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  fi
elif command -v firewalld >/dev/null 2>&1; then
  if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="$new_port"/tcp && firewall-cmd --reload
    echo "已通过firewalld开放端口 $new_port"
  else
    echo "firewalld未运行，请手动开放端口"
  fi
elif command -v ufw >/dev/null 2>&1; then
  ufw allow "$new_port"/tcp && echo "已通过ufw开放端口 $new_port"
else
  echo -e "${YELLOW}未检测到常见防火墙管理工具，请手动开放端口 $new_port${NC}"
fi

echo -e "${GREEN}SSH端口已成功修改为 ${new_port}${NC}"
echo -e "${YELLOW}重要提示：${NC}"
echo "1. 请保持当前SSH会话开启，另开一个新终端测试新端口连接是否正常。"
echo "2. 确认新端口可连接后，再关闭当前会话。"
echo "3. 如果无法连接，可恢复备份：cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config && systemctl restart sshd"
