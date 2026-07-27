#!/bin/bash
# SSH密钥登录配置脚本（基于科技lion脚本提取）
# 功能：开启SSH密钥认证，禁用密码登录，支持生成新密钥或导入公钥
# 使用方法：以root身份运行，按提示操作

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 检查root权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误：请以 root 用户运行此脚本${NC}"
  exit 1
fi

# 备份sshd_config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)
echo -e "${GREEN}已备份配置文件${NC}"

# 清理可能干扰的drop-in配置（原脚本做法）
rm -rf /etc/ssh/sshd_config.d/* /etc/ssh/ssh_config.d/* 2>/dev/null || true

# 配置sshd：强制密钥登录，禁用密码
configure_sshd() {
  cat > /etc/ssh/sshd_config <<EOF
# 由SSH密钥登录配置脚本生成
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
UsePrivilegeSeparation yes
KeyRegenerationInterval 3600
ServerKeyBits 1024
SyslogFacility AUTH
LogLevel INFO
LoginGraceTime 120
PermitRootLogin prohibit-password
StrictModes yes
RSAAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile	.ssh/authorized_keys
PasswordAuthentication no
ChallengeResponseAuthentication no
X11Forwarding yes
X11DisplayOffset 10
PrintMotd no
PrintLastLog yes
TCPKeepAlive yes
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
UsePAM yes
EOF
  echo -e "${GREEN}sshd_config 已更新为密钥登录模式${NC}"
}

# 重启SSH服务
restart_ssh() {
  echo "正在重启SSH服务..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart sshd || systemctl restart ssh
  elif command -v service >/dev/null 2>&1; then
    service sshd restart || service ssh restart
  else
    /etc/init.d/sshd restart || /etc/init.d/ssh restart
  fi
  echo -e "${GREEN}SSH服务已重启${NC}"
}

# 生成新密钥对并添加到authorized_keys
generate_and_add_key() {
  mkdir -p ~/.ssh
  chmod 700 ~/.ssh
  echo -e "${YELLOW}正在生成 ed25519 密钥对（默认无密码）...${NC}"
  ssh-keygen -t ed25519 -f ~/.ssh/sshkey -N "" -C "ssh-key-$(hostname)"
  cat ~/.ssh/sshkey.pub >> ~/.ssh/authorized_keys
  chmod 600 ~/.ssh/authorized_keys
  echo -e "${GREEN}密钥已生成并添加到 authorized_keys${NC}"
  echo -e "${YELLOW}私钥内容（请立即保存到本地文件）：${NC}"
  echo "----------------------------------------"
  cat ~/.ssh/sshkey
  echo "----------------------------------------"
  echo -e "${RED}请将上述私钥保存为文件，用于后续SSH登录${NC}"
}

# 导入已有公钥（支持直接粘贴或从文件读取）
import_public_key() {
  local pubkey="$1"
  if [ -z "$pubkey" ]; then
    read -p "请粘贴您的SSH公钥内容（以 ssh-rsa/ssh-ed25519 开头）: " pubkey
  fi
  if [[ ! "$pubkey" =~ ^ssh-(rsa|ed25519|ecdsa) ]]; then
    echo -e "${RED}无效的公钥格式${NC}"
    return 1
  fi
  mkdir -p ~/.ssh
  chmod 700 ~/.ssh
  touch ~/.ssh/authorized_keys
  chmod 600 ~/.ssh/authorized_keys
  if grep -Fxq "$pubkey" ~/.ssh/authorized_keys 2>/dev/null; then
    echo -e "${YELLOW}该公钥已存在，无需重复添加${NC}"
  else
    echo "$pubkey" >> ~/.ssh/authorized_keys
    echo -e "${GREEN}公钥已添加到 authorized_keys${NC}"
  fi
}

# 主菜单
echo "================ SSH密钥登录配置 ================"
echo "1. 生成新的密钥对并启用（私钥将显示在屏幕上）"
echo "2. 导入已有公钥（粘贴或从文件）"
echo "3. 从GitHub导入公钥（输入用户名）"
echo "0. 退出"
read -p "请选择 (0-3): " choice

case $choice in
  1)
    configure_sshd
    generate_and_add_key
    restart_ssh
    echo -e "${GREEN}✅ SSH密钥登录已启用，密码登录已禁用${NC}"
    ;;
  2)
    read -p "请输入公钥内容（直接粘贴，或输入文件路径如 /root/mykey.pub）: " input
    if [ -f "$input" ]; then
      pubkey=$(cat "$input" | tr -d '\n')
    else
      pubkey="$input"
    fi
    if import_public_key "$pubkey"; then
      configure_sshd
      restart_ssh
      echo -e "${GREEN}✅ SSH密钥登录已启用，密码登录已禁用${NC}"
    else
      echo -e "${RED}导入失败，未修改配置${NC}"
      exit 1
    fi
    ;;
  3)
    read -p "请输入GitHub用户名: " gh_user
    if [ -z "$gh_user" ]; then
      echo -e "${RED}用户名不能为空${NC}"
      exit 1
    fi
    echo "正在从 https://github.com/${gh_user}.keys 获取公钥..."
    keys_url="https://github.com/${gh_user}.keys"
    if curl -fsSL --connect-timeout 10 "$keys_url" -o /tmp/gh_keys.txt; then
      if [ -s /tmp/gh_keys.txt ]; then
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          import_public_key "$line"
        done < /tmp/gh_keys.txt
        configure_sshd
        restart_ssh
        echo -e "${GREEN}✅ 已导入GitHub公钥，SSH密钥登录已启用，密码登录已禁用${NC}"
      else
        echo -e "${RED}下载的公钥文件为空${NC}"
        exit 1
      fi
    else
      echo -e "${RED}无法从GitHub获取公钥，请检查用户名或网络${NC}"
      exit 1
    fi
    ;;
  0)
    echo "退出"
    exit 0
    ;;
  *)
    echo -e "${RED}无效选择${NC}"
    exit 1
    ;;
esac

echo -e "${YELLOW}重要提示：${NC}"
echo "1. 请保持当前SSH会话开启，另开终端使用密钥测试连接。"
echo "2. 确认密钥登录正常后再关闭当前会话。"
echo "3. 若密钥登录失败，可恢复备份配置文件："
echo "   cp /etc/ssh/sshd_config.bak.* /etc/ssh/sshd_config && systemctl restart sshd"
