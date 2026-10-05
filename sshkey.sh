#!/bin/bash
# ============================================================
# SSH 密钥登录管理（修正版）
# 平台：Debian 12/13、Ubuntu 22.04/24.04
# 相对原版的改动（核心是「不会再把自己锁在门外」）：
#   1. 启用「仅密钥登录」前强制检查 authorized_keys 非空且可用
#   2. 不再 rm -rf /etc/ssh/sshd_config.d/*（保留云厂商 drop-in）
#      改为写入 00-snorbo-keyauth.conf，靠 Include 在顶部优先生效
#   3. 修改后 sshd -t 校验 + sshd -T 复核生效值，失败即回滚
#   4. 旧的 ChallengeResponseAuthentication 已废弃：改为写入 KbdInteractiveAuthentication no
#      （状态展示时仍会一并读取两个字段，仅为兼容旧配置的可见性）
#   5. 及时创建/修正 .ssh 与 authorized_keys 权限（0600/0700）
#   6. 生成新密钥时不再把私钥明文打印到终端（改为一句话提示）
#   7. 所有 read 都做 EOF 保护，重启有二次确认与倒计时
# ============================================================

set -uo pipefail

GL_HONG='\033[31m'
GL_LV='\033[32m'
GL_HUANG='\033[33m'
GL_BAI='\033[0m'

SSHD_CONFIG='/etc/ssh/sshd_config'
DROPIN_DIR='/etc/ssh/sshd_config.d'
KEYAUTH_DROPIN="${DROPIN_DIR}/00-snorbo-keyauth.conf"
BACKUP_DIR='/root/.ssh-key-backup'
STAMP="$(date +%Y%m%d-%H%M%S)"

info() { echo -e "${GL_HUANG}$1${GL_BAI}"; }
ok()   { echo -e "${GL_LV}$1${GL_BAI}"; }
err()  { echo -e "${GL_HONG}$1${GL_BAI}"; }

die() {
    err "错误：$1"
    exit 1
}

pause() {
    read -r -p "按回车键继续..." _ || true
}

check_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        die '该操作需要 root 权限，请使用 sudo 或切换为 root 用户。'
    fi
}

sshd_ok() {
    sshd -t >/dev/null 2>&1
}

restart_ssh() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl reload-or-restart ssh 2>/dev/null || systemctl reload-or-restart sshd 2>/dev/null
        return $?
    fi
    if command -v service >/dev/null 2>&1; then
        service ssh reload 2>/dev/null || service sshd reload 2>/dev/null
        return $?
    fi
    /etc/init.d/ssh reload 2>/dev/null || /etc/init.d/sshd reload 2>/dev/null
}

backup_sshd() {
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    cp -a "$SSHD_CONFIG" "${BACKUP_DIR}/sshd_config.${STAMP}" 2>/dev/null || true
    if [ -d "$DROPIN_DIR" ]; then
        tar -czf "${BACKUP_DIR}/sshd_config.d.${STAMP}.tar.gz" -C /etc/ssh sshd_config.d 2>/dev/null || true
    fi
}

rollback_sshd() {
    err '正在回滚 SSH 配置...'
    rm -f "$KEYAUTH_DROPIN"
    if [ -f "${BACKUP_DIR}/sshd_config.${STAMP}" ]; then
        cp -a "${BACKUP_DIR}/sshd_config.${STAMP}" "$SSHD_CONFIG"
    fi
    if [ -f "${BACKUP_DIR}/sshd_config.d.${STAMP}.tar.gz" ]; then
        tar -xzf "${BACKUP_DIR}/sshd_config.d.${STAMP}.tar.gz" -C /etc/ssh 2>/dev/null || true
    fi
    if sshd_ok; then
        restart_ssh >/dev/null 2>&1 || true
        ok '已回滚到修改前状态。'
    else
        err '回滚后配置仍不合法，请人工检查 /etc/ssh/。'
    fi
}

ensure_include() {
    [ -d "$DROPIN_DIR" ] || mkdir -p "$DROPIN_DIR"
    local first_directive include_line
    first_directive="$(grep -nvE '^[[:space:]]*(#|$)' "$SSHD_CONFIG" 2>/dev/null | head -n1 | cut -d: -f1)"
    include_line="$(grep -nE '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d' "$SSHD_CONFIG" 2>/dev/null | head -n1 | cut -d: -f1)"
    if [ -z "$include_line" ]; then
        sed -i "1i Include ${DROPIN_DIR}/*.conf" "$SSHD_CONFIG"
        info "已在 ${SSHD_CONFIG} 顶部插入 Include ${DROPIN_DIR}/*.conf"
        return 0
    fi
    if [ -n "$first_directive" ] && [ "$include_line" -gt "$first_directive" ]; then
        sed -i "${include_line}d" "$SSHD_CONFIG"
        sed -i "1i Include ${DROPIN_DIR}/*.conf" "$SSHD_CONFIG"
        info "已将 Include 语句移动到 ${SSHD_CONFIG} 顶部"
    fi
}

# 取生效的 AuthorizedKeysFile（可能是多值，取第一个）
effective_akf() {
    local f
    f="$(sshd -T 2>/dev/null | awk '$1=="authorizedkeysfile"{print $2; exit}')"
    printf '%s\n' "${f:-.ssh/authorized_keys}"
}

# 解析 AuthorizedKeysFile 为绝对路径
akf_path_for_home() {
    local home="$1" raw="$2" p
    p="${raw%%.ssh/authorized_keys*}"
    if [ -z "$p" ]; then
        printf '%s/.ssh/authorized_keys\n' "$home"
    elif [ "${p#/}" != "$p" ]; then
        printf '%s/.ssh/authorized_keys\n' "${p%/}"
    else
        printf '%s/%s/.ssh/authorized_keys\n' "$home" "${p%/}"
    fi
}

# 从 sshd -T 的 authorizedkeyscommand 取命令名（rss 表示未启用）
authorized_keys_command() {
    sshd -T 2>/dev/null | awk '$1=="authorizedkeyscommand"{print $2; exit}'
}

# 查看某个账户当前可用于登录的公钥数量
count_keys_for_user() {
    local user="$1" home raw akf n=0
    home="$(getent passwd "$user" | cut -d: -f6)"
    [ -n "$home" ] || { printf '0\n'; return; }
    raw="$(effective_akf)"
    akf="$(akf_path_for_home "$home" "$raw")"
    if [ -f "$akf" ]; then
        n="$(grep -cvE '^[[:space:]]*(#|$)' "$akf" 2>/dev/null || echo 0)"
    fi
    printf '%s\n' "${n:-0}"
}

list_key_users() {
    local u
    for u in root "$(logname 2>/dev/null || true)" "${SUDO_USER:-}"; do
        [ -n "$u" ] || continue
        getent passwd "$u" >/dev/null 2>&1 || continue
        printf '%s (%s 条公钥)\n' "$u" "$(count_keys_for_user "$u")"
    done | sort -u
}

# ---------- 启用密钥登录（可选同时关闭密码） ----------
apply_keyauth() {
    local disable_password="$1"
    local -a targets=()
    local u n
    for u in root "${SUDO_USER:-}"; do
        [ -n "$u" ] || continue
        getent passwd "$u" >/dev/null 2>&1 || continue
        targets+=("$u")
    done

    local total=0
    for u in "${targets[@]}"; do
        n="$(count_keys_for_user "$u")"
        total=$((total + n))
        info "账户 ${u} 当前有效公钥：${n} 条"
    done

    if [ "$total" -eq 0 ]; then
        err '未在任何账户下发现可用的公钥，拒绝修改 SSH 配置（否则可能无法再登录）。'
        echo '请先用「2/3/4/5/6」导入公钥，再启用密钥登录。'
        return 1
    fi

    local akc
    akc="$(authorized_keys_command)"
    if [ -n "$akc" ] && [ "$akc" != 'rss' ] && [ "$akc" != 'none' ]; then
        info "注意：sshd 配置了 AuthorizedKeysCommand=${akc}，密钥可能来自外部来源（云厂商/SSSD）。"
        info "如使用该机制，禁用密码登录前请先用新会话验证密钥登录确实可用。"
    fi

    ensure_include
    backup_sshd

    umask 022
    {
        echo 'PermitRootLogin prohibit-password'
        echo 'PubkeyAuthentication yes'
        echo 'KbdInteractiveAuthentication no'
        if [ "$disable_password" = 'yes' ]; then
            echo 'PasswordAuthentication no'
        else
            echo 'PasswordAuthentication yes'
        fi
    } > "$KEYAUTH_DROPIN"

    if ! sshd_ok; then
        err 'sshd 配置校验失败：'
        sshd -t || true
        rollback_sshd
        return 1
    fi

    if ! restart_ssh; then
        err 'SSH 服务重载失败。'
        rollback_sshd
        return 1
    fi

    # 复核生效值
    local eff_pw eff_pk
    eff_pw="$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2; exit}')"
    eff_pk="$(sshd -T 2>/dev/null | awk '$1=="pubkeyauthentication"{print $2; exit}')"
    info "生效值：PasswordAuthentication=${eff_pw:-未知}  PubkeyAuthentication=${eff_pk:-未知}"

    if [ "$eff_pk" != 'yes' ]; then
        err '公钥认证未生效，正在回滚。'
        rollback_sshd
        return 1
    fi
    if [ "$disable_password" = 'yes' ] && [ "$eff_pw" != 'no' ]; then
        err "密码登录未被关闭（生效值 ${eff_pw:-未知}），可能被其它 drop-in 覆盖，正在回滚。"
        rollback_sshd
        return 1
    fi

    ok 'SSH 配置已更新并生效。'
    echo
    err '★ 请保持当前会话不要关闭，另开一个新终端验证密钥登录成功后再退出。'
    echo "  回滚命令：rm -f ${KEYAUTH_DROPIN} && systemctl reload-or-restart ssh"
    echo "  备份位置：${BACKUP_DIR}（时间戳 ${STAMP}）"
    return 0
}

# ---------- 公钥校验与写入 ----------
is_valid_pubkey() {
    local key="$1"
    printf '%s' "$key" | grep -Eq '^(ssh-(rsa|ed25519|ecdsa|dss)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com|ecdsa-sha2-nistp(256|384|521)|ssh-ed25519|rsa-sha2-256|rsa-sha2-512)[[:space:]]+[A-Za-z0-9+/=]+'
}

write_pubkey_for_user() {
    local user="$1" key="$2" home raw akf
    home="$(getent passwd "$user" | cut -d: -f6)"
    [ -n "$home" ] || { err "找不到用户 ${user}。"; return 1; }
    raw="$(effective_akf)"
    akf="$(akf_path_for_home "$home" "$raw")"

    mkdir -p "$(dirname -- "$akf")"
    chmod 700 "$(dirname -- "$akf")"
    touch "$akf"
    chmod 600 "$akf"
    chown -R "${user}:${user}" "$(dirname -- "$akf")" 2>/dev/null || \
        chown -R "${user}" "$(dirname -- "$akf")" 2>/dev/null || true

    # 命令型公钥以 command= 开头，也允许导入
    local norm="$key"
    if printf '%s' "$norm" | grep -qE '^[[:space:]]*command='; then
        :
    elif ! is_valid_pubkey "$norm"; then
        err "公钥格式不正确（应以 ssh-ed25519 / ssh-rsa / ecdsa-sha2-* 开头）。"
        return 1
    fi

    if grep -Fxq -- "$norm" "$akf" 2>/dev/null; then
        info "该公钥已存在于 ${akf}，无需重复添加。"
        return 0
    fi
    printf '%s\n' "$norm" >> "$akf"
    ok "已写入 ${akf}（${user}）"
    return 0
}

choose_user_for_import() {
    local user=''
    read -r -p "要导入到哪个账户？[默认 root]: " user || return 1
    user="${user:-root}"
    if ! getent passwd "$user" >/dev/null 2>&1; then
        err "用户 ${user} 不存在。"
        return 1
    fi
    printf '%s\n' "$user"
}

import_then_maybe_enable() {
    local user="$1" key="$2"
    write_pubkey_for_user "$user" "$key" || return 1
    echo
    if [ "$(count_keys_for_user "$user")" -gt 0 ]; then
        info "是否同时应用密钥登录策略（关闭密码登录）？"
        info "建议先另开终端验证密钥登录可用，再关闭密码。"
        local a
        read -r -p "现在应用配置？(y/N): " a || return 0
        if [[ "$a" =~ ^[Yy]$ ]]; then
            apply_keyauth 'yes'
        else
            info '已跳过配置修改（公钥已导入）。可稍后用菜单项 1 应用。'
        fi
    fi
}

# ---------- 导入方式 ----------
import_from_paste() {
    local user key
    echo '请粘贴公钥内容（一行，以 ssh-ed25519 / ssh-rsa / ecdsa-sha2-* 开头）：'
    read -r key || { err '未输入内容。'; return 1; }
    key="${key%$'\r'}"
    if [ -z "$key" ]; then
        err '未输入内容。'
        return 1
    fi
    user="$(choose_user_for_import)" || return 1
    import_then_maybe_enable "$user" "$key"
}

import_from_file() {
    local path user key
    read -r -p '请输入公钥文件路径（如 /root/id_ed25519.pub）：' path || return 1
    path="${path%$'\r'}"
    if [ ! -f "$path" ]; then
        err "文件不存在：${path}"
        return 1
    fi
    key="$(head -n1 -- "$path")"
    if [ -z "$key" ]; then
        err '文件内容为空。'
        return 1
    fi
    user="$(choose_user_for_import)" || return 1
    import_then_maybe_enable "$user" "$key"
}

import_from_url() {
    local url user
    read -r -p '请输入公钥的 URL（如 https://github.com/用户名.keys）：' url || return 1
    url="${url%$'\r'}"
    [ -n "$url" ] || { err 'URL 不能为空。'; return 1; }
    case "$url" in
        https://*|http://*) ;;
        *) err 'URL 必须以 http:// 或 https:// 开头。'; return 1 ;;
    esac
    user="$(choose_user_for_import)" || return 1
    import_url_for_user "$url" "$user"
}

import_url_for_user() {
    local url="$1" user="$2" tmp line added=0
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || {
        err '未找到 curl 或 wget，无法下载。'
        return 1
    }
    tmp="$(mktemp)" || return 1
    info "正在下载：${url}"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 30 -o "$tmp" "$url" || {
            err '下载失败。'
            rm -f "$tmp"
            return 1
        }
    else
        wget -q -T 30 -O "$tmp" "$url" || {
            err '下载失败。'
            rm -f "$tmp"
            return 1
        }
    fi
    if [ ! -s "$tmp" ]; then
        err '下载内容为空。'
        rm -f "$tmp"
        return 1
    fi
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [ -n "$line" ] || continue
        case "$line" in \#*) continue ;; esac
        if write_pubkey_for_user "$user" "$line" >/dev/null 2>&1; then
            added=$((added + 1))
        fi
    done < "$tmp"
    rm -f "$tmp"
    if [ "$added" -eq 0 ]; then
        info '没有新增公钥（可能已存在或文件无效）。'
        return 1
    fi
    ok "成功添加 ${added} 条公钥到 ${user}。"
    echo
    local a
    read -r -p '现在应用密钥登录策略（关闭密码登录）？(y/N): ' a || return 0
    if [[ "$a" =~ ^[Yy]$ ]]; then
        apply_keyauth 'yes'
    fi
    return 0
}

import_from_github() {
    local username user
    read -r -p '请输入 GitHub 用户名: ' username || return 1
    username="${username%$'\r'}"
    username="${username//[[:space:]]/}"
    [ -n "$username" ] || { err '用户名不能为空。'; return 1; }
    if ! printf '%s' "$username" | grep -Eq '^[A-Za-z0-9-]{1,39}$'; then
        err 'GitHub 用户名格式无效。'
        return 1
    fi
    user="$(choose_user_for_import)" || return 1
    import_url_for_user "https://github.com/${username}.keys" "$user"
}

# ---------- 生成密钥对 ----------
generate_keypair() {
    local user keydir keyfile
    user="$(choose_user_for_import)" || return 1
    keydir="$(getent passwd "$user" | cut -d: -f6)/.ssh"
    keyfile="${keydir}/id_ed25519"
    mkdir -p "$keydir"
    chmod 700 "$keydir"
    chown -R "$user" "$keydir" 2>/dev/null || true

    if [ -f "$keyfile" ]; then
        local a
        read -r -p "${keyfile} 已存在，是否覆盖？(y/N): " a || return 1
        [[ "$a" =~ ^[Yy]$ ]] || { info '已取消。'; return 0; }
        rm -f "$keyfile" "${keyfile}.pub"
    fi

    if ! ssh-keygen -t ed25519 -C "${user}@$(hostname 2>/dev/null || echo host)-$(date +%Y%m%d)" -f "$keyfile" -N '' >/dev/null; then
        err 'ssh-keygen 执行失败。'
        return 1
    fi
    chmod 600 "$keyfile"
    chmod 644 "${keyfile}.pub"
    chown "$user" "$keyfile" "${keyfile}.pub" 2>/dev/null || true

    ok "密钥对已生成：${keyfile} / ${keyfile}.pub"
    if [ "$user" = 'root' ]; then
        write_pubkey_for_user 'root' "$(cat "${keyfile}.pub")" >/dev/null
    fi
    echo
    err '★ 私钥未在屏幕上显示（避免进入终端回滚缓冲与日志）。'
    echo "  请用以下方式之一安全取回私钥："
    echo "    scp root@<主机>:${keyfile} ./id_ed25519"
    echo "    或执行 cat ${keyfile} 后自行妥善保存，并尽快清理终端记录"
    echo
    local a
    read -r -p '现在应用密钥登录策略（关闭密码登录）？(y/N): ' a || return 0
    if [[ "$a" =~ ^[Yy]$ ]]; then
        apply_keyauth 'yes'
    fi
}

# ---------- 菜单 ----------
do_reboot() {
    err '即将重启服务器！'
    local a
    read -r -p '确认重启？(输入 yes 确认): ' a || return 0
    if [ "$a" != 'yes' ]; then
        info '已取消重启。'
        return 0
    fi
    if command -v shutdown >/dev/null 2>&1; then
        info '服务器将在 10 秒后重启（Ctrl+C 可取消）...'
        shutdown -r +0.2 2>/dev/null || reboot
    else
        reboot
    fi
}

show_menu() {
    clear
    echo '=========================================='
    echo '      SSH 密钥登录管理工具'
    echo '=========================================='
    echo '1. 应用密钥登录策略（要求已存在公钥）'
    echo '2. 仅启用密钥认证、保留密码登录'
    echo '3. 手动粘贴公钥并导入'
    echo '4. 从本地文件导入公钥'
    echo '5. 从 URL 导入公钥'
    echo '6. 从 GitHub 导入公钥'
    echo '7. 生成新密钥对（ed25519）'
    echo '8. 查看当前 SSH 认证相关生效配置'
    echo '9. 重启服务器'
    echo '0. 退出'
    echo '=========================================='
    echo -n '请输入选项 [0-9]: '
}

show_status() {
    echo
    info '当前 sshd 生效的关键配置：'
    if command -v sshd >/dev/null 2>&1; then
        sshd -T 2>/dev/null | grep -iE '^(port|passwordauthentication|pubkeyauthentication|permitrootlogin|kbdinteractiveauthentication|authorizedkeysfile|authorizedkeyscommand|challengeresponseauthentication) ' || err '无法读取 sshd -T 输出。'
    else
        err '未安装 openssh-server。'
    fi
    echo
    info '各账户可用公钥数量：'
    list_key_users
    echo
    if [ -f "$KEYAUTH_DROPIN" ]; then
        info "本脚本写入的配置文件 ${KEYAUTH_DROPIN}："
        cat "$KEYAUTH_DROPIN"
    else
        info '本脚本尚未写入任何配置。'
    fi
}

check_root
command -v sshd >/dev/null 2>&1 || die '未找到 sshd，请先安装 openssh-server。'
[ -d /etc/ssh ] || die '目录 /etc/ssh 不存在。'

while true; do
    show_menu
    if ! read -r choice; then
        echo
        info '标准输入已结束，退出。'
        exit 0
    fi
    case "$choice" in
        1) apply_keyauth 'yes'; pause ;;
        2) apply_keyauth 'no'; pause ;;
        3) import_from_paste; pause ;;
        4) import_from_file; pause ;;
        5) import_from_url; pause ;;
        6) import_from_github; pause ;;
        7) generate_keypair; pause ;;
        8) show_status; pause ;;
        9) do_reboot ;;
        0) echo '退出。'; exit 0 ;;
        '') ;;
        *) err '无效选项。'; sleep 1 ;;
    esac
done
