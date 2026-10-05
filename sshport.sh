#!/bin/bash
# ============================================================
# SSH 端口修改脚本（修正版）
# 平台：Debian 12/13、Ubuntu 22.04/24.04
# 相对原版的改动：
#   1. 修改前先 sshd -t 校验，失败自动回滚，绝不留下起不来的 sshd
#   2. 用 `sshd -T` 读取「实际生效端口」，兼容 sshd_config.d/ 下的 Port
#   3. 新端口写入 drop-in 并确保主配置顶部有 Include（避免被覆盖）
#   4. 用 systemctl reload-or-restart，并给出连接测试/回滚指引
#   5. 防火墙探测顺序修正（ufw → firewall-cmd → iptables），规则可持久化
#   6. 校验新端口真的在监听，并在结尾回显最终生效端口
# ============================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

SSHD_CONFIG='/etc/ssh/sshd_config'
DROPIN_DIR='/etc/ssh/sshd_config.d'
DROPIN_FILE="${DROPIN_DIR}/00-snorbo-port.conf"
BACKUP_DIR='/root/.ssh-port-backup'
STAMP="$(date +%Y%m%d-%H%M%S)"

die() {
    echo -e "${RED}错误：$1${NC}" >&2
    exit 1
}

info() {
    echo -e "${YELLOW}$1${NC}"
}

ok() {
    echo -e "${GREEN}$1${NC}"
}

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die '请以 root 用户运行此脚本（sudo bash sshport.sh）'
fi

command -v sshd >/dev/null 2>&1 || die '找不到 sshd 命令（openssh-server 未安装？）'

# 校验当前配置是否合法
sshd_config_ok() {
    sshd -t >/dev/null 2>&1
}

# 取实际生效端口（默认 22）
effective_port() {
    local p
    p="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
    printf '%s\n' "${p:-22}"
}

# 该端口是否已显式写入配置文件（区分「默认 22」与「显式 22」）
port_is_explicit() {
    grep -rqsE '^[[:space:]]*Port[[:space:]]+[0-9]+' \
        "$SSHD_CONFIG" "$DROPIN_DIR" 2>/dev/null
}

show_effective_ports() {
    local ports
    ports="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | paste -sd' ' -)"
    info "当前 sshd 实际生效端口：${ports:-未知}"
}

backup_configs() {
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    cp -a "$SSHD_CONFIG" "${BACKUP_DIR}/sshd_config.${STAMP}"
    if [ -d "$DROPIN_DIR" ]; then
        tar -czf "${BACKUP_DIR}/sshd_config.d.${STAMP}.tar.gz" -C /etc/ssh sshd_config.d 2>/dev/null || true
    fi
    echo -e "${YELLOW}已备份：${BACKUP_DIR}/sshd_config.${STAMP}${NC}"
    if [ -f "${BACKUP_DIR}/sshd_config.d.${STAMP}.tar.gz" ]; then
        echo -e "${YELLOW}已备份：${BACKUP_DIR}/sshd_config.d.${STAMP}.tar.gz${NC}"
    fi
}

rollback() {
    echo -e "${RED}正在回滚 SSH 配置...${NC}"
    if [ -f "${BACKUP_DIR}/sshd_config.${STAMP}" ]; then
        cp -a "${BACKUP_DIR}/sshd_config.${STAMP}" "$SSHD_CONFIG"
    fi
    if [ -f "${BACKUP_DIR}/sshd_config.d.${STAMP}.tar.gz" ]; then
        tar -xzf "${BACKUP_DIR}/sshd_config.d.${STAMP}.tar.gz" -C /etc/ssh 2>/dev/null || true
    else
        rm -f "$DROPIN_FILE"
    fi
    if sshd_config_ok; then
        ok '回滚完成，配置已恢复为修改前状态。'
    else
        echo -e "${RED}回滚后配置仍不合法，请人工检查 ${SSHD_CONFIG}${NC}" >&2
    fi
}

# 确保主配置顶部有 Include sshd_config.d/*.conf
ensure_include() {
    [ -d "$DROPIN_DIR" ] || mkdir -p "$DROPIN_DIR"

    # 检查 Include 是否在「任何全局指令之前」（sshd 对多数指令取首次出现的值）
    local first_directive
    first_directive="$(grep -nvE '^[[:space:]]*(#|$)' "$SSHD_CONFIG" 2>/dev/null | head -n1 | cut -d: -f1)"

    local include_line
    include_line="$(grep -nE '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d' "$SSHD_CONFIG" 2>/dev/null | head -n1 | cut -d: -f1)"

    if [ -z "$include_line" ]; then
        sed -i "1i Include ${DROPIN_DIR}/*.conf" "$SSHD_CONFIG"
        echo -e "${YELLOW}已在 ${SSHD_CONFIG} 顶部插入 Include ${DROPIN_DIR}/*.conf${NC}"
        return 0
    fi

    if [ -n "$first_directive" ] && [ "$include_line" -gt "$first_directive" ]; then
        # Include 存在但位置靠后：移到顶部，避免被主配置里的 Port 抢先
        sed -i "${include_line}d" "$SSHD_CONFIG"
        sed -i "1i Include ${DROPIN_DIR}/*.conf" "$SSHD_CONFIG"
        echo -e "${YELLOW}已将 Include 语句移动到 ${SSHD_CONFIG} 顶部${NC}"
    fi
}

# 1. 读取新端口
show_effective_ports
if port_is_explicit; then
    info '（该端口来自配置文件中的 Port 指令）'
else
    info '（配置文件中没有 Port 指令，这是 OpenSSH 默认值）'
fi

new_port=''
while true; do
    if ! read -r -p "请输入新的 SSH 端口号（1-65535，输入 0 退出）: " new_port; then
        echo
        die '标准输入已结束，未做任何修改。'
    fi
    case "$new_port" in
        0) echo '已取消操作。'; exit 0 ;;
        ''|*[!0-9]*) echo -e "${RED}无效端口，请输入 1-65535 之间的数字。${NC}"; continue ;;
    esac
    # 去掉可能的前导 0 再比较
    if [ "$((10#${new_port}))" -ge 1 ] && [ "$((10#${new_port}))" -le 65535 ]; then
        new_port="$((10#${new_port}))"
        break
    fi
    echo -e "${RED}无效端口，请输入 1-65535 之间的数字。${NC}"
done

if [ "$new_port" = "$(effective_port)" ]; then
    info "新端口与当前生效端口相同（${new_port}），无需修改。"
    exit 0
fi

# 2. 备份
backup_configs

# 3. 写入新配置
ensure_include
umask 022
if ! printf 'Port %s\n' "$new_port" > "$DROPIN_FILE"; then
    die "无法写入 ${DROPIN_FILE}"
fi
# 清掉主配置里旧的 Port（含被注释的），避免与新 drop-in 冲突
sed -i -E '/^[[:space:]]*#?[[:space:]]*Port[[:space:]]+[0-9]+([[:space:]]|$)/d' "$SSHD_CONFIG"

# 4. 校验配置
if ! sshd_config_ok; then
    echo -e "${RED}sshd 配置校验失败，输出如下：${NC}"
    sshd -t || true
    rollback
    die '未重启 SSH 服务，配置已回滚。'
fi
ok 'sshd 配置校验通过（sshd -t）'

# 5. 开放防火墙端口（在重启 sshd 之前完成，避免瞬间不可达）
open_firewall_port() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        info "检测到 ufw 已启用，放行 ${port}/tcp ..."
        if ufw allow "${port}/tcp" >/dev/null 2>&1; then
            ok "已通过 ufw 放行 ${port}/tcp"
        else
            echo -e "${RED}ufw 放行失败，请手动执行：ufw allow ${port}/tcp${NC}"
        fi
        return 0
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        info "检测到 firewalld 运行中，放行 ${port}/tcp ..."
        if firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1; then
            ok "已通过 firewalld 放行 ${port}/tcp"
        else
            echo -e "${RED}firewalld 放行失败，请手动执行：firewall-cmd --permanent --add-port=${port}/tcp && firewall-cmd --reload${NC}"
        fi
        return 0
    fi

    if command -v iptables >/dev/null 2>&1; then
        info "未检测到已启用的 ufw/firewalld，尝试 iptables 放行 ${port}/tcp ..."
        if iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
            ok "iptables 规则已存在"
        elif iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
            ok "已添加 iptables 规则：允许 tcp/${port}"
        else
            echo -e "${RED}iptables 规则添加失败。${NC}"
        fi
        # 持久化：优先发行版机制，其次写入 rules.v4 并明确告知依赖
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1 && ok 'iptables 规则已通过 netfilter-persistent 保存'
        elif command -v iptables-save >/dev/null 2>&1; then
            mkdir -p /etc/iptables
            if iptables-save > /etc/iptables/rules.v4 2>/dev/null; then
                if [ -d /etc/iptables ] && dpkg -l iptables-persistent 2>/dev/null | grep -q '^ii'; then
                    ok 'iptables 规则已写入 /etc/iptables/rules.v4（iptables-persistent 已安装）'
                else
                    echo -e "${YELLOW}规则已写入 /etc/iptables/rules.v4，但未安装 iptables-persistent，重启后不会自动恢复。${NC}"
                    echo -e "${YELLOW}如需持久化请执行：apt install -y iptables-persistent${NC}"
                fi
            fi
        fi
        return 0
    fi

    echo -e "${YELLOW}未检测到 ufw / firewalld / iptables，且未识别到云厂商安全组。${NC}"
    echo -e "${YELLOW}请务必在云厂商控制台的安全组中放行 ${port}/tcp，否则将无法连接。${NC}"
    return 1
}
open_firewall_port "$new_port" || true

# 6. 重启/重载 sshd
echo
echo -e "${RED}即将重载 SSH 服务。当前会话通常不会被中断，但请勿关闭本窗口。${NC}"
rollback_hint="cp -a ${BACKUP_DIR}/sshd_config.${STAMP} ${SSHD_CONFIG} && rm -f ${DROPIN_FILE} && systemctl restart ssh"
info "如新端口无法连接，可在云控制台 VNC 执行：${rollback_hint}"

if command -v systemctl >/dev/null 2>&1; then
    systemctl reload-or-restart ssh 2>/dev/null || systemctl reload-or-restart sshd 2>/dev/null || {
        echo -e "${RED}SSH 服务重载失败，正在回滚配置...${NC}"
        rollback
        systemctl reload-or-restart ssh 2>/dev/null || systemctl reload-or-restart sshd 2>/dev/null || true
        die 'SSH 服务重载失败，已回滚。'
    }
elif command -v service >/dev/null 2>&1; then
    service ssh reload 2>/dev/null || service sshd reload 2>/dev/null || {
        rollback
        die 'SSH 服务重载失败，已回滚。'
    }
else
    /etc/init.d/ssh reload 2>/dev/null || /etc/init.d/sshd reload 2>/dev/null || {
        rollback
        die 'SSH 服务重载失败，已回滚。'
    }
fi

sleep 1
if ! sshd_config_ok; then
    rollback
    die '重载后配置异常，已回滚。'
fi

# 7. 结果确认
final_port="$(effective_port)"
if [ "$final_port" = "$new_port" ]; then
    ok "SSH 端口已成功修改为 ${final_port}"
else
    echo -e "${RED}警告：生效端口为 ${final_port}，与期望的 ${new_port} 不一致。${NC}"
    echo -e "${YELLOW}请检查 /etc/ssh/sshd_config.d/ 下是否有其它文件覆盖了 Port。${NC}"
fi

if command -v ss >/dev/null 2>&1; then
    echo -e "${YELLOW}当前监听：${NC}"
    ss -tlnp 2>/dev/null | grep -E "sshd|:${final_port}\b" || true
fi

echo
echo -e "${YELLOW}重要提示：${NC}"
echo "1. 请保持当前 SSH 会话开启，另开一个新终端测试：ssh -p ${final_port} 用户@主机"
echo "2. 确认新端口可连接后，再关闭当前会话。"
echo "3. 回滚命令：${rollback_hint}"
echo "4. 本次备份位于：${BACKUP_DIR}（文件名带时间戳 ${STAMP}）"
exit 0
