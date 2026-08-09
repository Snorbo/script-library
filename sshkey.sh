#!/bin/bash
# ============================================================
# 文件名: enable_ssh_key.sh
# 描述: 一键启用 SSH 密钥登录（禁用密码），支持多种公钥导入方式
# 原脚本: kejilion.sh
# ============================================================

# ---------- 颜色定义 ----------
gl_hong='\033[31m'
gl_lv='\033[32m'
gl_huang='\033[33m'
gl_bai='\033[0m'

# ---------- 工具函数 ----------
# 检查 root 权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${gl_huang}错误: 该操作需要 root 权限，请使用 sudo 或切换为 root 用户。${gl_bai}"
        exit 1
    fi
}

# 重启 SSH 服务（兼容各种发行版）
restart_ssh() {
    if command -v systemctl &>/dev/null; then
        systemctl restart sshd ssh 2>/dev/null || systemctl restart ssh 2>/dev/null
    else
        service sshd restart 2>/dev/null || service ssh restart 2>/dev/null
    fi
    echo -e "${gl_lv}SSH 服务已重启。${gl_bai}"
}

# ---------- 核心函数 ----------
# 启用密钥登录模式（关闭密码登录）
sshkey_on() {
    local sshd_config="/etc/ssh/sshd_config"
    # 修改配置
    sed -i -e 's/^\s*#\?\s*PermitRootLogin .*/PermitRootLogin prohibit-password/' \
           -e 's/^\s*#\?\s*PasswordAuthentication .*/PasswordAuthentication no/' \
           -e 's/^\s*#\?\s*PubkeyAuthentication .*/PubkeyAuthentication yes/' \
           -e 's/^\s*#\?\s*ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' \
           "$sshd_config"
    # 清除可能冲突的 drop-in 配置
    rm -rf /etc/ssh/sshd_config.d/* /etc/ssh/ssh_config.d/* 2>/dev/null
    restart_ssh
    echo -e "${gl_lv}已启用密钥登录模式，密码登录已禁用。${gl_bai}"
}

# 导入公钥（公钥内容作为参数）
import_sshkey() {
    local public_key="$1"
    local base_dir="${2:-$HOME}"
    local ssh_dir="${base_dir}/.ssh"
    local auth_keys="${ssh_dir}/authorized_keys"

    if [[ -z "$public_key" ]]; then
        echo -e "${gl_hong}错误：未提供公钥内容。${gl_bai}"
        return 1
    fi

    # 简单校验公钥格式
    if [[ ! "$public_key" =~ ^ssh-(rsa|ed25519|ecdsa) ]]; then
        echo -e "${gl_hong}错误：公钥格式不正确，应以 ssh-rsa、ssh-ed25519 等开头。${gl_bai}"
        return 1
    fi

    # 检查是否已存在，避免重复添加
    if grep -Fxq "$public_key" "$auth_keys" 2>/dev/null; then
        echo "该公钥已存在，无需重复添加。"
        return 0
    fi

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    touch "$auth_keys"
    echo "$public_key" >> "$auth_keys"
    chmod 600 "$auth_keys"

    echo -e "${gl_lv}公钥已成功添加。${gl_bai}"
    sshkey_on
}

# 生成新的密钥对（ed25519）并自动启用
add_sshkey() {
    local key_dir="${HOME}/.ssh"
    mkdir -p "$key_dir"
    chmod 700 "$key_dir"

    # 生成密钥对（覆盖已存在的文件需提示）
    if [ -f "${key_dir}/sshkey" ]; then
        echo -e "${gl_huang}已存在 ${key_dir}/sshkey，是否覆盖？(y/N)${gl_bai}"
        read -r ans
        if [[ ! "$ans" =~ ^[Yy]$ ]]; then
            echo "已取消生成。"
            return 0
        fi
    fi

    ssh-keygen -t ed25519 -C "sshkey_$(hostname)" -f "${key_dir}/sshkey" -N ""
    cat "${key_dir}/sshkey.pub" >> "${key_dir}/authorized_keys"
    chmod 600 "${key_dir}/authorized_keys"

    echo -e "${gl_lv}新密钥对已生成：${gl_bai}"
    echo "私钥: ${key_dir}/sshkey"
    echo "公钥: ${key_dir}/sshkey.pub"
    echo -e "${gl_huang}请务必将私钥内容保存到本地！${gl_bai}"
    echo "----------------------------------------"
    cat "${key_dir}/sshkey"
    echo "----------------------------------------"

    sshkey_on
}

# 从远程 URL 导入公钥
fetch_remote_ssh_keys() {
    local keys_url="$1"
    local base_dir="${2:-$HOME}"
    local ssh_dir="${base_dir}/.ssh"
    local authorized_keys="${ssh_dir}/authorized_keys"
    local temp_file

    if [[ -z "${keys_url}" ]]; then
        read -e -p "请输入公钥的 URL 地址: " keys_url
    fi

    if [[ -z "${keys_url}" ]]; then
        echo -e "${gl_hong}错误：URL 不能为空。${gl_bai}"
        return 1
    fi

    echo "正在从 $keys_url 下载公钥..."
    temp_file=$(mktemp)
    if command -v curl &>/dev/null; then
        curl -fsSL --connect-timeout 10 "${keys_url}" -o "${temp_file}" || {
            echo -e "${gl_hong}下载失败。${gl_bai}"
            rm -f "$temp_file"
            return 1
        }
    elif command -v wget &>/dev/null; then
        wget -q --timeout=10 -O "${temp_file}" "${keys_url}" || {
            echo -e "${gl_hong}下载失败。${gl_bai}"
            rm -f "$temp_file"
            return 1
        }
    else
        echo -e "${gl_hong}错误：未找到 curl 或 wget，无法下载。${gl_bai}"
        rm -f "$temp_file"
        return 1
    fi

    if [ ! -s "$temp_file" ]; then
        echo -e "${gl_hong}错误：下载的文件为空。${gl_bai}"
        rm -f "$temp_file"
        return 1
    fi

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    touch "$authorized_keys"
    chmod 600 "$authorized_keys"

    local added=0
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        if ! grep -Fxq "$line" "$authorized_keys" 2>/dev/null; then
            echo "$line" >> "$authorized_keys"
            ((added++))
        fi
    done < "$temp_file"
    rm -f "$temp_file"

    if [ $added -eq 0 ]; then
        echo "没有新公钥被添加（可能已存在或文件无效）。"
    else
        echo -e "${gl_lv}成功添加 ${added} 条公钥。${gl_bai}"
        sshkey_on
    fi
}

# 从 GitHub 用户导入公钥
fetch_github_ssh_keys() {
    local username="$1"
    if [[ -z "$username" ]]; then
        read -e -p "请输入 GitHub 用户名: (Snorbo)" username
    fi
    if [[ -z "$username" ]]; then
        echo -e "${gl_hong}用户名不能为空。${gl_bai}"
        return 1
    fi
    local url="https://github.com/${username}.keys"
    fetch_remote_ssh_keys "$url"
}

# ---------- 交互菜单 ----------
show_menu() {
    clear
    echo "=========================================="
    echo "      SSH 密钥登录管理工具"
    echo "=========================================="
    echo "1. 启用密钥登录（不导入公钥）"
    echo "2. 手动粘贴公钥并启用"
    echo "3. 从本地文件导入公钥"
    echo "4. 从 URL 导入公钥"
    echo "5. 从 GitHub 导入公钥"
    echo "6. 生成新密钥对并启用"
    echo "0. 退出"
    echo "=========================================="
    read -e -p "请输入选项 (0-6): " choice
    case "$choice" in
        1)
            sshkey_on
            ;;
        2)
            echo "请粘贴您的 SSH 公钥（以 ssh-rsa、ssh-ed25519 等开头）:"
            read -r pubkey
            if [ -n "$pubkey" ]; then
                import_sshkey "$pubkey"
            else
                echo -e "${gl_hong}未输入内容。${gl_bai}"
            fi
            ;;
        3)
            read -e -p "请输入公钥文件的路径: " keyfile
            if [ -f "$keyfile" ]; then
                pubkey=$(< "$keyfile")
                import_sshkey "$pubkey"
            else
                echo -e "${gl_hong}文件不存在。${gl_bai}"
            fi
            ;;
        4)
            fetch_remote_ssh_keys
            ;;
        5)
            fetch_github_ssh_keys
            ;;
        6)
            add_sshkey
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${gl_hong}无效选项。${gl_bai}"
            sleep 1
            ;;
    esac
}

# ---------- 主程序 ----------
check_root
while true; do
    show_menu
    echo -e "\n按回车继续..."
    read -r
done
