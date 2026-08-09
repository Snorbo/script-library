#!/usr/bin/env bash

# UFW 管理脚本（Ubuntu 优先）
# 说明：脚本需要 root 权限，请使用 sudo 执行。

set -o pipefail
umask 077

readonly LOG_FILE="${UFW_MANAGER_LOG:-/var/log/ufw-manager.log}"
readonly BACKUP_DIR="${UFW_MANAGER_BACKUP_DIR:-/var/backups/ufw-manager}"
readonly LOCK_FILE="/run/lock/ufw-manager.lock"
UFW_BIN=""

log_msg() {
    local message="$1"
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$message" >> "$LOG_FILE" 2>/dev/null || true
}

pause_screen() {
    read -r -p "按回车键继续..." _ || true
}

die() {
    echo "错误：$1" >&2
    exit 1
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "请使用 root 权限执行，例如：sudo bash $0"
fi

# 防止同一台主机同时修改规则，避免规则编号和状态互相覆盖。
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE" || die "无法创建锁文件：$LOCK_FILE"
    flock -n 9 || die "已有另一个 UFW 管理脚本正在运行"
fi

detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        printf '%s\n' apt
    elif command -v dnf >/dev/null 2>&1; then
        printf '%s\n' dnf
    elif command -v yum >/dev/null 2>&1; then
        printf '%s\n' yum
    elif command -v pacman >/dev/null 2>&1; then
        printf '%s\n' pacman
    elif command -v zypper >/dev/null 2>&1; then
        printf '%s\n' zypper
    else
        printf '%s\n' unknown
    fi
}

refresh_ufw_path() {
    UFW_BIN="$(command -v ufw 2>/dev/null || true)"
}

check_ufw_installed() {
    refresh_ufw_path
    if [[ -z "$UFW_BIN" ]]; then
        echo "UFW 尚未安装，请先选择“安装 UFW”。"
        pause_screen
        return 1
    fi
    return 0
}

# 统一执行 UFW 命令并记录修改操作；所有参数通过数组传递，避免 Shell 重新解析。
ufw_change() {
    local rendered
    printf -v rendered '%q ' "$@"
    if "$UFW_BIN" "$@"; then
        log_msg "SUCCESS ufw $rendered"
        return 0
    fi
    log_msg "FAILED ufw $rendered"
    echo "操作失败，请检查上面的 UFW 错误信息。" >&2
    return 1
}

backup_ufw() {
    local stamp archive
    [[ -d /etc/ufw ]] || { echo "未找到 /etc/ufw，无法备份。" >&2; return 1; }
    mkdir -p "$BACKUP_DIR" || { echo "无法创建备份目录：$BACKUP_DIR" >&2; return 1; }
    chmod 700 "$BACKUP_DIR" || true
    stamp="$(date '+%Y%m%d-%H%M%S-%N')"
    archive="$BACKUP_DIR/ufw-$stamp.tar.gz"
    if tar -czf "$archive" -C /etc ufw; then
        chmod 600 "$archive" || true
        log_msg "BACKUP $archive"
        echo "规则已备份到：$archive"
        return 0
    fi
    echo "备份失败，已取消后续操作。" >&2
    return 1
}

restore_ufw_backup() {
    check_ufw_installed || return
    [[ -d "$BACKUP_DIR" ]] || { echo "没有找到备份目录：$BACKUP_DIR"; pause_screen; return; }

    local -a backups=()
    mapfile -t backups < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'ufw-*.tar.gz' -printf '%f\n' | sort -r)
    if (( ${#backups[@]} == 0 )); then
        echo "没有找到 UFW 备份。"
        pause_screen
        return
    fi
    echo "可用备份："
    local i=1
    local item
    for item in "${backups[@]}"; do
        printf '  %d. %s\n' "$i" "$item"
        ((i++))
    done

    local choice selected archive_entries
    read -r -p "请选择备份编号：" choice
    [[ "$choice" =~ ^[0-9]{1,5}$ && 10#$choice -ge 1 && 10#$choice -le ${#backups[@]} ]] || {
        echo "备份编号无效。"
        pause_screen
        return
    }
    selected="${backups[$((10#$choice - 1))]}"
    local archive="$BACKUP_DIR/$selected"

    # 只允许恢复本脚本生成的 /etc/ufw 相对路径，拒绝绝对路径和目录穿越条目。
    archive_entries="$(tar -tzf "$archive" 2>/dev/null)" || {
        echo "备份文件损坏或不是有效的 tar.gz。" >&2
        pause_screen
        return
    }
    while IFS= read -r item; do
        [[ "$item" == ufw/* && "$item" != *..* ]] || {
            echo "备份包含不安全路径，已拒绝恢复。" >&2
            pause_screen
            return
        }
    done <<< "$archive_entries"

    read -r -p "恢复前会先备份当前配置，确认恢复？请输入 RESTORE：" choice
    [[ "$choice" == RESTORE ]] || { echo "操作已取消。"; pause_screen; return; }
    backup_ufw || { pause_screen; return; }
    if tar -xzf "$archive" -C /etc --no-same-owner --no-same-permissions && ufw_change reload; then
        log_msg "RESTORE $archive"
        echo "备份已恢复，UFW 规则已重载。"
    else
        echo "恢复或重载失败，请检查当前配置。" >&2
    fi
    pause_screen
}

delete_ufw_backup() {
    check_ufw_installed || return
    [[ -d "$BACKUP_DIR" ]] || { echo "没有找到备份目录：$BACKUP_DIR"; pause_screen; return; }

    local -a backups=()
    mapfile -t backups < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'ufw-*.tar.gz' -printf '%f\n' | sort -r)
    if (( ${#backups[@]} == 0 )); then
        echo "没有找到 UFW 备份。"
        pause_screen
        return
    fi

    echo "可删除的备份："
    local i=1 item
    for item in "${backups[@]}"; do
        printf '  %d. %s\n' "$i" "$item"
        ((i++))
    done

    local choice selected archive
    read -r -p "请选择要删除的备份编号：" choice
    [[ "$choice" =~ ^[0-9]{1,5}$ && 10#$choice -ge 1 && 10#$choice -le ${#backups[@]} ]] || {
        echo "备份编号无效。"
        pause_screen
        return
    }
    selected="${backups[$((10#$choice - 1))]}"
    archive="$BACKUP_DIR/$selected"
    read -r -p "将永久删除 $selected，请输入 DELETE 确认：" choice
    [[ "$choice" == DELETE ]] || { echo "操作已取消。"; pause_screen; return; }

    if rm -f -- "$archive" && [[ ! -e "$archive" ]]; then
        log_msg "DELETE_BACKUP $archive"
        echo "备份已删除：$selected"
    else
        echo "备份删除失败：$selected" >&2
    fi
    pause_screen
}

install_ufw() {
    refresh_ufw_path
    if [[ -n "$UFW_BIN" ]]; then
        echo "UFW 已安装：$UFW_BIN"
        pause_screen
        return 0
    fi

    local package_manager
    package_manager="$(detect_package_manager)"
    echo "检测到包管理器：$package_manager"
    case "$package_manager" in
        apt)
            apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
            ;;
        dnf)
            dnf install -y ufw
            ;;
        yum)
            yum install -y ufw
            ;;
        pacman)
            pacman -S --noconfirm ufw
            ;;
        zypper)
            zypper --non-interactive install ufw
            ;;
        *)
            echo "无法识别包管理器，请手动安装 ufw。" >&2
            pause_screen
            return 1
            ;;
    esac

    refresh_ufw_path
    if [[ -n "$UFW_BIN" ]]; then
        echo "UFW 安装成功。"
        log_msg "INSTALL package_manager=$package_manager"
    else
        echo "安装命令执行后仍未找到 ufw，请检查安装结果。" >&2
        pause_screen
        return 1
    fi
    pause_screen
}

uninstall_firewall() {
    check_ufw_installed || return
    echo "警告：这会禁用 UFW、删除软件包，并清除防火墙配置。"
    read -r -p "请输入 UNINSTALL 确认：" confirm
    [[ "$confirm" == "UNINSTALL" ]] || { echo "操作已取消。"; pause_screen; return; }
    backup_ufw || { pause_screen; return; }

    if ! ufw_change --force disable; then
        echo "无法确认 UFW 已禁用，已停止卸载。" >&2
        pause_screen
        return
    fi

    local package_manager
    package_manager="$(detect_package_manager)"
    case "$package_manager" in
        apt) apt-get purge -y ufw ;;
        dnf) dnf remove -y ufw ;;
        yum) yum remove -y ufw ;;
        pacman) pacman -Rns --noconfirm ufw ;;
        zypper) zypper --non-interactive remove ufw ;;
        *) echo "无法识别包管理器，未删除软件包。" >&2; pause_screen; return 1 ;;
    esac
    refresh_ufw_path
    if [[ -z "$UFW_BIN" ]]; then
        log_msg "UNINSTALL package_manager=$package_manager"
        echo "UFW 已卸载。"
    else
        echo "卸载命令完成，但仍能找到 ufw，请检查包管理器状态。" >&2
    fi
    pause_screen
}

valid_port_number() {
    local number="$1"
    [[ "$number" =~ ^[0-9]{1,5}$ ]] || return 1
    (( 10#$number >= 1 && 10#$number <= 65535 ))
}

valid_port_spec() {
    local port_spec="$1" first last
    if [[ "$port_spec" =~ ^[0-9]{1,5}$ ]]; then
        valid_port_number "$port_spec"
        return
    fi
    if [[ "$port_spec" =~ ^([0-9]{1,5}):([0-9]{1,5})$ ]]; then
        first="${BASH_REMATCH[1]}"
        last="${BASH_REMATCH[2]}"
        valid_port_number "$first" && valid_port_number "$last" && (( 10#$first <= 10#$last ))
        return
    fi
    return 1
}

valid_source() {
    local source="$1"
    [[ "$source" == "any" ]] && return 0
    # 先限制字符集，UFW 负责进一步验证地址和掩码是否合法。
    [[ "$source" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]]
}

valid_comment() {
    local comment="$1"
    [[ ${#comment} -le 120 ]] || return 1
    [[ "$comment" != *$'\r'* && "$comment" != *$'\n'* ]]
}

list_ports() {
    check_ufw_installed || return
    echo "当前 UFW 规则："
    "$UFW_BIN" status numbered
    pause_screen
}

open_port() {
    check_ufw_installed || return
    local port_spec proto_choice proto source comment
    read -r -p "请输入端口或范围（例如 22 或 8000:8080）：" port_spec
    if ! valid_port_spec "$port_spec"; then
        echo "端口必须是 1-65535，范围格式为 起始:结束。"
        pause_screen
        return
    fi

    echo "1. TCP"
    echo "2. UDP"
    echo "3. TCP 和 UDP"
    read -r -p "请选择协议 [1-3]（默认 1）：" proto_choice
    case "${proto_choice:-1}" in
        1) proto=tcp ;;
        2) proto=udp ;;
        3) proto=both ;;
        *) echo "无效协议选择。"; pause_screen; return ;;
    esac

    read -r -p "来源地址（留空表示任意来源，或输入 IPv4/IPv6/CIDR）：" source
    source="${source:-any}"
    if ! valid_source "$source"; then
        echo "来源地址格式不受支持。" >&2
        pause_screen
        return
    fi
    read -r -p "规则备注（可选，最多 120 字符）：" comment
    if ! valid_comment "$comment"; then
        echo "备注过长或包含控制字符。" >&2
        pause_screen
        return
    fi

    local args=()
    if [[ "$source" == "any" ]]; then
        if [[ "$proto" == both ]]; then
            args=(allow "$port_spec")
        else
            args=(allow "$port_spec/$proto")
        fi
    else
        args=(allow from "$source" to any port "$port_spec")
        [[ "$proto" == both ]] || args+=(proto "$proto")
    fi
    [[ -n "$comment" ]] && args+=(comment "$comment")

    if ufw_change "${args[@]}"; then
        echo "规则已添加。"
    fi
    pause_screen
}

allow_application() {
    check_ufw_installed || return
    echo "可用应用配置："
    "$UFW_BIN" app list
    local app
    read -r -p "请输入应用配置名称（例如 OpenSSH）：" app
    [[ -n "$app" && ${#app} -le 100 ]] || { echo "应用名称无效。"; pause_screen; return; }
    if "$UFW_BIN" app info "$app" >/dev/null 2>&1; then
        ufw_change allow "$app" && echo "应用规则已添加。"
    else
        echo "未找到应用配置：$app" >&2
    fi
    pause_screen
}

allow_from_source() {
    check_ufw_installed || return
    local source port_spec proto_choice proto comment

    read -r -p "请输入来源地址（IPv4/IPv6/CIDR）：" source
    if ! valid_source "$source" || [[ "$source" == "any" ]]; then
        echo "来源地址无效；此功能要求指定具体来源地址。" >&2
        pause_screen
        return
    fi

    read -r -p "请输入目标端口或端口范围（例如 22 或 8000:8080）：" port_spec
    if ! valid_port_spec "$port_spec"; then
        echo "端口必须是 1-65535，范围格式为 起始:结束。" >&2
        pause_screen
        return
    fi

    echo "1. TCP"
    echo "2. UDP"
    echo "3. TCP 和 UDP"
    read -r -p "请选择协议 [1-3]（默认 1）：" proto_choice
    case "${proto_choice:-1}" in
        1) proto=tcp ;;
        2) proto=udp ;;
        3) proto=both ;;
        *) echo "无效协议选择。"; pause_screen; return ;;
    esac

    read -r -p "规则备注（可选，最多 120 字符）：" comment
    if ! valid_comment "$comment"; then
        echo "备注过长或包含控制字符。" >&2
        pause_screen
        return
    fi

    local args=(allow from "$source" to any port "$port_spec")
    [[ "$proto" == both ]] || args+=(proto "$proto")
    [[ -n "$comment" ]] && args+=(comment "$comment")
    if ufw_change "${args[@]}"; then
        echo "已添加来源 $source 到端口 $port_spec 的允许规则。"
    fi
    pause_screen
}

delete_rule_by_number() {
    check_ufw_installed || return
    echo "当前规则列表："
    "$UFW_BIN" status numbered
    local number
    read -r -p "请输入要删除的规则编号：" number
    [[ "$number" =~ ^[0-9]{1,5}$ && 10#$number -gt 0 ]] || { echo "规则编号无效。"; pause_screen; return; }
    read -r -p "确认删除规则 $number？（y/N）：" confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "操作已取消。"; pause_screen; return; }
    if ufw_change --force delete "$number"; then
        echo "规则 $number 已删除。"
    fi
    pause_screen
}

enable_firewall() {
    check_ufw_installed || return
    read -r -p "确认启用 UFW？（y/N）：" confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "操作已取消。"; pause_screen; return; }
    if ufw_change --force enable; then
        echo "防火墙已启用。"
    fi
    pause_screen
}

disable_firewall() {
    check_ufw_installed || return
    read -r -p "禁用后主机将暂时失去 UFW 保护，确认？（y/N）：" confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "操作已取消。"; pause_screen; return; }
    if ufw_change --force disable; then
        echo "防火墙已禁用。"
    fi
    pause_screen
}

show_status() {
    check_ufw_installed || return
    "$UFW_BIN" status verbose
    pause_screen
}

set_default_policy() {
    check_ufw_installed || return
    echo "1. 拒绝进入（推荐）"
    echo "2. 允许进入"
    read -r -p "进入策略 [1-2]（默认 1）：" incoming_choice
    echo "1. 允许出去（推荐）"
    echo "2. 拒绝出去"
    read -r -p "出去策略 [1-2]（默认 1）：" outgoing_choice
    local incoming=deny outgoing=allow
    [[ "${incoming_choice:-1}" == 2 ]] && incoming=allow
    [[ "${outgoing_choice:-1}" == 2 ]] && outgoing=deny
    read -r -p "将设置 incoming=$incoming、outgoing=$outgoing，确认？（y/N）：" confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "操作已取消。"; pause_screen; return; }
    ufw_change default "$incoming" incoming || { pause_screen; return; }
    if ufw_change default "$outgoing" outgoing; then
        echo "默认策略已更新。"
    fi
    pause_screen
}

set_logging() {
    check_ufw_installed || return
    echo "可选级别：off、low、medium、high、full"
    local level
    read -r -p "请输入日志级别：" level
    case "$level" in
        off|low|medium|high|full) ;;
        *) echo "无效日志级别。"; pause_screen; return ;;
    esac
    if ufw_change logging "$level"; then
        echo "UFW 日志级别已设为：$level"
    fi
    pause_screen
}

reload_firewall() {
    check_ufw_installed || return
    if ufw_change reload; then
        echo "UFW 规则已重载。"
    fi
    pause_screen
}

reset_firewall() {
    check_ufw_installed || return
    echo "警告：重置会删除所有 UFW 规则并恢复默认配置。"
    read -r -p "请输入 RESET 确认：" confirm
    [[ "$confirm" == RESET ]] || { echo "操作已取消。"; pause_screen; return; }
    backup_ufw || { pause_screen; return; }
    if ufw_change --force reset; then
        echo "UFW 已重置并保持禁用状态。"
    fi
    pause_screen
}

show_menu() {
    clear 2>/dev/null || true
    echo "=============================================="
    echo "              UFW 防火墙管理脚本"
    echo "=============================================="
    echo "  1. 查看规则（带编号）"
    echo "  2. 开放端口/端口范围"
    echo "  3. 允许应用配置"
    echo "  4. 自定义来源放行端口"
    echo "  5. 删除规则"
    echo "  6. 启用防火墙"
    echo "  7. 禁用防火墙"
    echo "  8. 查看状态"
    echo "  9. 设置默认策略"
    echo " 10. 设置日志级别"
    echo " 11. 备份当前规则"
    echo " 12. 恢复规则备份"
    echo " 13. 删除规则备份"
    echo " 14. 重载规则"
    echo " 15. 重置 UFW"
    echo " 16. 安装 UFW"
    echo " 17. 卸载 UFW"
    echo "  0. 退出"
    echo "=============================================="
    printf '请选择操作 [0-17]: '
}

while true; do
    show_menu
    read -r choice || exit 0
    case "$choice" in
        1) list_ports ;;
        2) open_port ;;
        3) allow_application ;;
        4) allow_from_source ;;
        5) delete_rule_by_number ;;
        6) enable_firewall ;;
        7) disable_firewall ;;
        8) show_status ;;
        9) set_default_policy ;;
        10) set_logging ;;
        11) check_ufw_installed && backup_ufw; pause_screen ;;
        12) restore_ufw_backup ;;
        13) delete_ufw_backup ;;
        14) reload_firewall ;;
        15) reset_firewall ;;
        16) install_ufw ;;
        17) uninstall_firewall ;;
        0) echo "退出脚本。"; exit 0 ;;
        *) echo "无效选项，请重新选择。"; sleep 1 ;;
    esac
done
