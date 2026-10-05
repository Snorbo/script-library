#!/bin/bash
# ============================================================
# 综合维护菜单（修正版）
# 目标平台：Debian 12/13、Ubuntu 22.04/24.04（apt 系）
# 支持两种启动方式：
#   sudo ./menu.sh
#   sudo bash <(curl -fsSL https://raw.githubusercontent.com/Snorbo/script-library/refs/heads/main/menu.sh)
# ============================================================

# 不使用 set -e：菜单类脚本需要容错，失败要提示而不是整体退出。
set -uo pipefail

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 远端脚本基地址
RAW_BASE='https://raw.githubusercontent.com/Snorbo/script-library/refs/heads/main'
BBR_URL='https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/2026newconfig/bbr.sh'

# 自身路径：$0 在 `bash <(curl ...)` 下是 /dev/fd/63，不可直接当文件使用。
resolve_self_path() {
    local p="${BASH_SOURCE[0]:-$0}"
    if [ -f "$p" ] && [[ "$p" != /dev/fd/* ]] && [[ "$p" != /proc/self/fd/* ]]; then
        printf '%s\n' "$p"
        return 0
    fi
    printf '%s\n' ''
}
SCRIPT_PATH="$(resolve_self_path)"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${YELLOW}警告：建议以 root 用户执行此脚本（sudo ./menu.sh），否则多数操作会因权限不足而失败。${NC}"
    echo -e "        子脚本自身也会再次校验 root，非 root 会在那里退出。\n"
fi

pause() {
    read -r -p "按回车键继续..." _ || true
}

# 检查命令是否存在
need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# 运行远端脚本：先下载到临时文件校验，再执行；返回子脚本的真实退出码。
run_remote() {
    local url="$1"
    shift
    local tmp rc
    if ! need_cmd curl; then
        echo -e "${RED}缺少 curl，无法拉取脚本。请先执行选项 23 安装基础包。${NC}"
        return 1
    fi
    tmp="$(mktemp)" || { echo -e "${RED}无法创建临时文件。${NC}"; return 1; }
    if ! curl -fsSL --connect-timeout 10 --max-time 120 --retry 2 -o "$tmp" "$url"; then
        echo -e "${RED}下载失败：${url}${NC}"
        echo -e "${YELLOW}请检查网络/代理，或稍后重试。${NC}"
        rm -f "$tmp"
        return 1
    fi
    if [ ! -s "$tmp" ]; then
        echo -e "${RED}下载内容为空：${url}${NC}"
        rm -f "$tmp"
        return 1
    fi
    if ! bash -n "$tmp" 2>/dev/null; then
        echo -e "${RED}远端脚本语法检查未通过，已中止执行：${url}${NC}"
        rm -f "$tmp"
        return 1
    fi
    bash "$tmp" "$@"
    rc=$?
    rm -f "$tmp"
    return "$rc"
}

# 统一的「执行远端脚本并反馈结果」包装
run_remote_reported() {
    local desc="$1"
    local url="$2"
    shift 2
    if run_remote "$url" "$@"; then
        echo -e "${GREEN}${desc} 完成。${NC}"
    else
        echo -e "${RED}${desc} 失败或已中止，请查看上方输出确认当前状态。${NC}"
    fi
    pause
}

confirm() {
    local prompt="$1" answer
    read -r -p "${prompt}（y/N）：" answer || return 1
    [[ "$answer" =~ ^[Yy]$ ]]
}

# 确认后执行远端脚本；用户拒绝则不发请求
confirm_remote_reported() {
    local desc="$1"
    local url="$2"
    shift 2
    confirm "即将执行：${desc}，是否继续" || { echo '已取消。'; pause; return; }
    run_remote_reported "$desc" "$url" "$@"
}

print_logo() {
    if command -v figlet >/dev/null 2>&1; then
        figlet -f standard "SNORBO"
    elif command -v toilet >/dev/null 2>&1; then
        toilet -f standard "SNORBO"
    else
        cat <<'EOF'
  SSS  N   N  OOO  RRRR  BBB   OOO
 S     NN  N O   O R   R B   B O   O
  SSS  N N N O   O RRRR  BBBB  O   O
     S N  NN O   O R R   B   B O   O
  SSS  N   N  OOO  R  R  BBBB   OOO
EOF
    fi
}

# ---------------- z 快捷命令 ----------------
Z_TARGET='/usr/local/bin/z'

write_z_wrapper() {
    # 写成 wrapper 而不是软链：脚本常以 `bash <(curl ...)` 方式运行，
    # 此时 $0 是 /dev/fd/63，软链会变成死链接。
    tee "$Z_TARGET" >/dev/null <<EOF
#!/bin/bash
exec bash <(curl -fsSL --connect-timeout 10 --max-time 120 '${RAW_BASE}/menu.sh')
EOF
    chmod 755 "$Z_TARGET"
}

install_z_shortcut() {
    echo -e "${YELLOW}安装快捷命令 z ...${NC}"
    if [ -n "$SCRIPT_PATH" ]; then
        local self_abs
        self_abs="$(cd "$(dirname -- "$SCRIPT_PATH")" && pwd)/$(basename -- "$SCRIPT_PATH")"
        tee "$Z_TARGET" >/dev/null <<EOF
#!/bin/bash
exec bash '${self_abs}'
EOF
        chmod 755 "$Z_TARGET"
    else
        write_z_wrapper
    fi
    if [ -x "$Z_TARGET" ]; then
        echo -e "${GREEN}已安装快捷命令：z（$Z_TARGET）${NC}"
        echo -e "${GREEN}现在可以直接输入 z 启动这个菜单${NC}"
    else
        echo -e "${RED}安装失败，请检查 $Z_TARGET 的写入权限。${NC}"
    fi
    pause
}

remove_z_shortcut() {
    rm -f "$Z_TARGET"
    unalias z 2>/dev/null || true
    # 只处理在行的 alias z，两种写法都覆盖
    sed -i -E '/^[[:space:]]*alias[[:space:]]+z=/d' "$HOME/.bashrc" 2>/dev/null || true
    sed -i -E '/^[[:space:]]*alias[[:space:]]+z=/d' "$HOME/.zshrc" 2>/dev/null || true
    hash -r 2>/dev/null || true
    echo -e "${GREEN}已解绑快捷命令 z（已删除 $Z_TARGET 及 ~/.bashrc、~/.zshrc 中的 alias z）${NC}"
    pause
}

# ---------------- 菜单 ----------------
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
    echo "13. 编译安装 nginx"
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
    echo "23. 安装基础包"
    echo "24. 配置ufw防火墙"
    echo "99. 端口备忘"
    echo "0. 退出脚本"
    echo -e "${BLUE}========================================${NC}"
    echo -n "请输入选项 [0-24 或 99]: "
}

# 1. 修改 SSH 端口
option1() {
    echo -e "${YELLOW}执行：修改 SSH 连接端口...${NC}"
    run_remote_reported '修改 SSH 端口' "${RAW_BASE}/sshport.sh"
}

# 2. 启用 SSH 密钥
option2() {
    echo -e "${YELLOW}执行：启用 SSH 密钥连接...${NC}"
    run_remote_reported '配置 SSH 密钥登录' "${RAW_BASE}/sshkey.sh"
}

# 3. 禁用 IPQS
option3() {
    echo -e "${YELLOW}执行：禁用 IPQS（修改 /etc/hosts）...${NC}"
    local hosts='/etc/hosts'
    if [ ! -w "$hosts" ]; then
        echo -e "${RED}无法写入 $hosts（请以 root 运行）。${NC}"
        pause
        return 1
    fi
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    if ! grep -q 'ipqualityscore\.com' "$hosts"; then
        if cp -a "$hosts" "${hosts}.bak.${stamp}" 2>/dev/null; then
            echo -e "${YELLOW}已备份到 ${hosts}.bak.${stamp}${NC}"
        else
            echo -e "${RED}备份 ${hosts} 失败，已中止以防误改。${NC}"
            pause
            return 1
        fi
    fi
    sed -i '/ipqualityscore\.com/d' "$hosts"
    {
        echo '127.0.0.1 ipqualityscore.com'
        echo '127.0.0.1 www.ipqualityscore.com'
        echo '127.0.0.1 api.ipqualityscore.com'
    } >> "$hosts"
    if grep -q 'api\.ipqualityscore\.com' "$hosts"; then
        echo -e "${GREEN}完成：已写入 3 条 ipqualityscore.com 记录。${NC}"
        echo -e "${YELLOW}注意：这会影响任何依赖该域名解析的程序（含本机的 IP 质量检测）。${NC}"
    else
        echo -e "${RED}写入失败，请检查 /etc/hosts 状态。${NC}"
    fi
    pause
}

# 4. 空出 53 端口
option4() {
    echo -e "${YELLOW}执行：空出 53 端口（调整 systemd-resolved）...${NC}"

    if ! command -v systemctl >/dev/null 2>&1; then
        echo -e "${RED}未检测到 systemd，此选项不适用。${NC}"
        pause
        return 1
    fi
    if ! systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved\.service'; then
        echo -e "${YELLOW}未安装 systemd-resolved（可能使用 resolvconf/NetworkManager 管理 DNS）。${NC}"
        echo -e "${YELLOW}请手动确认 53 端口占用：ss -lunp | grep :53${NC}"
        pause
        return 0
    fi

    local up_dns down_dns
    read -r -p "上游 DNS1 [默认 1.1.1.1]: " up_dns
    up_dns="${up_dns:-1.1.1.1}"
    read -r -p "上游 DNS2 [默认 8.8.8.8，留空则只用一个]: " down_dns
    local dns_line="$up_dns"
    [ -n "$down_dns" ] && dns_line="$up_dns $down_dns"

    local conf='/etc/systemd/resolved.conf'
    local stamp bak
    stamp="$(date +%Y%m%d-%H%M%S)"
    bak="${conf}.bak.${stamp}"
    if [ -f "$conf" ]; then
        cp -a "$conf" "$bak" && echo -e "${YELLOW}原配置已备份：${bak}${NC}"
    fi

    # 用 drop-in 覆盖，避免直接重写 resolved.conf 丢掉用户其它设置
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/99-snorbo-dns.conf <<EOF
[Resolve]
DNS=${dns_line}
DNSStubListener=no
EOF
    echo -e "${YELLOW}已写入 /etc/systemd/resolved.conf.d/99-snorbo-dns.conf（不覆盖 $conf）${NC}"

    if ! systemctl restart systemd-resolved; then
        echo -e "${RED}systemd-resolved 重启失败，正在回滚...${NC}"
        rm -f /etc/systemd/resolved.conf.d/99-snorbo-dns.conf
        [ -f "$bak" ] && cp -a "$bak" "$conf"
        systemctl restart systemd-resolved 2>/dev/null || true
        pause
        return 1
    fi

    if [ -e /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
        cp -a /etc/resolv.conf "/etc/resolv.conf.bak.${stamp}" 2>/dev/null || true
    fi
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

    echo -e "${YELLOW}当前 DNS 解析状态：${NC}"
    resolvectl status 2>/dev/null | sed -n '1,20p' || true
    echo -e "${YELLOW}53 端口监听情况（应无 systemd-resolve 占用）：${NC}"
    ss -lunp 2>/dev/null | grep ':53 ' || echo '（未检测到 53 端口监听）'
    echo -e "${GREEN}完成。若 DNS 异常，可执行：rm -f /etc/systemd/resolved.conf.d/99-snorbo-dns.conf && cp -a ${bak} ${conf} && systemctl restart systemd-resolved${NC}"
    pause
}

# 5. IP 质量检测
option5() {
    echo -e "${YELLOW}执行：IP 质量检测...${NC}"
    echo -e "${YELLOW}提示：该功能会执行第三方站点 Check.Place 返回的脚本（以当前用户身份）。${NC}"
    confirm '是否继续' || { echo '已取消。'; pause; return 0; }
    if run_remote 'https://Check.Place' -I; then
        echo -e "${GREEN}完成。${NC}"
    else
        echo -e "${RED}检测脚本执行失败。${NC}"
    fi
    pause
}

# 6. 流媒体解锁检测
option6() {
    echo -e "${YELLOW}执行：流媒体解锁检测...${NC}"
    echo -e "${YELLOW}提示：该功能会执行第三方仓库 RegionRestrictionCheck 的脚本。${NC}"
    confirm '是否继续' || { echo '已取消。'; pause; return 0; }
    if run_remote 'https://raw.githubusercontent.com/1-stream/RegionRestrictionCheck/main/check.sh'; then
        echo -e "${GREEN}完成。${NC}"
    else
        echo -e "${RED}检测脚本执行失败。${NC}"
    fi
    pause
}

# 7. NodeQuality 检测
option7() {
    echo -e "${YELLOW}执行：NodeQuality 检测...${NC}"
    echo -e "${YELLOW}提示：该功能会执行第三方站点 run.NodeQuality.com 返回的脚本。${NC}"
    confirm '是否继续' || { echo '已取消。'; pause; return 0; }
    if run_remote 'https://run.NodeQuality.com'; then
        echo -e "${GREEN}完成。${NC}"
    else
        echo -e "${RED}检测脚本执行失败。${NC}"
    fi
    pause
}

# 8. 安装 nexttrace
option8() {
    echo -e "${YELLOW}执行：安装 nexttrace...${NC}"
    echo -e "${YELLOW}提示：将执行 nxtrace.org 官方安装脚本。${NC}"
    confirm '是否继续' || { echo '已取消。'; pause; return 0; }
    if run_remote 'https://nxtrace.org/nt'; then
        echo -e "${GREEN}完成。${NC}"
    else
        echo -e "${RED}安装脚本执行失败，若因官方地址不可达可尝试：bash <(curl -fsSL https://raw.githubusercontent.com/nxtrace/NTrace-core/main/install.sh)${NC}"
    fi
    pause
}

# 9. 安装 BBR 内核
option9() {
    echo -e "${YELLOW}执行：安装支持 BBR 的内核（参数 1）...${NC}"
    echo -e "${RED}注意：该操作会安装第三方内核并在完成后重启系统！${NC}"
    echo -e "${YELLOW}请先确认没有未保存的工作，并确保云厂商控制台/VNC 可用。${NC}"
    confirm '确认继续（安装后 60 秒重启）' || { echo '已取消。'; pause; return 0; }
    if run_remote "$BBR_URL" 1; then
        echo -e "${GREEN}内核安装流程结束。${NC}"
    else
        echo -e "${RED}安装失败或已中止，未执行重启。${NC}"
    fi
    pause
}

# 10. 安装 3x-ui 面板
option10() {
    echo -e "${YELLOW}执行：安装 3x-ui 面板...${NC}"
    confirm '是否继续' || { echo '已取消。'; pause; return 0; }
    if run_remote 'https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh'; then
        echo -e "${GREEN}完成。首次安装请记录脚本输出的面板端口/路径/用户名/密码。${NC}"
        echo -e "${YELLOW}提示：安装后 x-ui 默认端口是随机生成的，配置 nginx 前请用 x-ui 菜单确认实际端口。${NC}"
    else
        echo -e "${RED}安装失败。${NC}"
    fi
    pause
}

# 11. 安装 AdGuard Home
option11() {
    echo -e "${YELLOW}====== 安装 AdGuard Home ======${NC}"
    echo -e "${BLUE}→ 拉取并执行 AdGuardHome 官方安装脚本 ...${NC}"
    confirm '是否继续' || { echo '已取消。'; pause; return 0; }
    # 官方 install.sh 的 -v 是 verbose（不是版本号），默认已装 release 最新版；-r 表示已存在时重装。
    if run_remote 'https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh' -r -v; then
        echo -e "${GREEN}AdGuard Home 安装完成，管理面板默认 http://<IP>:3000${NC}"
        echo -e "${GREEN}卸载命令：curl -fsSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sudo sh -s -- -u${NC}"
    else
        echo -e "${RED}安装失败。若提示需要 tar/unzip，请先执行选项 23 安装基础包。${NC}"
    fi
    pause
}

# 12. 安装 OpenList
option12() {
    echo -e "${YELLOW}====== 安装 OpenList ======${NC}"
    echo -e "${BLUE}→ 拉取并执行 OpenList 官方安装脚本 ...${NC}"
    confirm '是否继续' || { echo '已取消。'; pause; return 0; }
    local tmp rc
    tmp="$(mktemp)"
    if ! curl -fsSL --connect-timeout 10 --max-time 120 -o "$tmp" 'https://res.oplist.org/script/v4.sh'; then
        echo -e "${RED}下载 OpenList 安装脚本失败（res.oplist.org 可能不可达）。${NC}"
        rm -f "$tmp"
        pause
        return 1
    fi
    bash -n "$tmp" 2>/dev/null || { echo -e "${RED}脚本语法检查失败，已中止。${NC}"; rm -f "$tmp"; pause; return 1; }
    bash "$tmp"
    rc=$?
    rm -f "$tmp"
    if [ "$rc" -eq 0 ]; then
        echo -e "${GREEN}OpenList 安装完成（默认端口 5244）。${NC}"
    else
        echo -e "${RED}OpenList 安装脚本返回非零退出码：${rc}${NC}"
    fi
    pause
}

# 13. 编译安装 Nginx（动态取最新 mainline 版本）
option13() {
    echo -e "${YELLOW}====== 编译安装 Nginx ======${NC}"

    if ! command -v apt-get >/dev/null 2>&1; then
        echo -e "${RED}此选项仅支持 Debian/Ubuntu（需要 apt-get）。${NC}"
        pause
        return 1
    fi

    local nginx_version=''
    echo -e "${BLUE}→ 获取 nginx 最新 mainline 版本号...${NC}"
    nginx_version="$(curl -fsSL --connect-timeout 10 --max-time 30 https://nginx.org/en/download.html 2>/dev/null \
        | grep -oE 'nginx-1\.[0-9]+\.[0-9]+\.tar\.gz' \
        | sed -E 's/^nginx-//; s/\.tar\.gz$//' \
        | sort -uV \
        | tail -n1)"
    if [ -z "$nginx_version" ]; then
        nginx_version='1.31.6'
        echo -e "${YELLOW}无法联网获取版本号，回退到内置版本：${nginx_version}${NC}"
    else
        echo -e "${GREEN}最新 mainline 版本：${nginx_version}${NC}"
    fi
    if [ -n "${NGINX_VERSION_OVERRIDE:-}" ]; then
        nginx_version="$NGINX_VERSION_OVERRIDE"
        echo -e "${YELLOW}使用环境变量指定的版本：${nginx_version}${NC}"
    fi

    local nginx_tar="nginx-${nginx_version}.tar.gz"
    local nginx_dir="nginx-${nginx_version}"
    local build_root='/usr/local/src'
    local src_dir="${build_root}/${nginx_dir}"

    echo -e "${BLUE}→ 安装编译依赖...${NC}"
    apt-get update || { echo -e "${RED}apt update 失败。${NC}"; pause; return 1; }
    # PCRE2 优先；PCRE2 不可用时回退 PCRE1（旧发行版）
    local pcre_pkgs='libpcre2-dev'
    if ! apt-get install -y --no-install-recommends build-essential libpcre2-dev zlib1g-dev libssl-dev wget ca-certificates >/dev/null 2>&1; then
        echo -e "${YELLOW}使用 PCRE2 的依赖集安装失败，回退到 libpcre3-dev...${NC}"
        pcre_pkgs='libpcre3-dev'
        apt-get install -y --no-install-recommends build-essential libpcre3-dev zlib1g-dev libssl-dev wget ca-certificates \
            || { echo -e "${RED}依赖安装失败，请检查 apt 源。${NC}"; pause; return 1; }
    fi
    echo -e "${GREEN}依赖就绪（PCRE: ${pcre_pkgs}）。${NC}"

    # 判断 OpenSSL 是否具备 QUIC 能力，决定是否启用 http_v3
    local with_v3='no'
    local ossl_version=''
    if [ -f /usr/include/openssl/opensslv.h ]; then
        ossl_version="$(awk -F'"' '/OPENSSL_VERSION_TEXT/{print $2; exit}' /usr/include/openssl/opensslv.h)"
    fi
    if grep -qs 'SSL_CTX_set_quic_method' /usr/include/openssl/ssl.h 2>/dev/null; then
        with_v3='yes'
    elif [ -n "$ossl_version" ]; then
        local ver_num
        ver_num="$(printf '%s' "$ossl_version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
        if [ -n "$ver_num" ]; then
            local major minor
            major="${ver_num%%.*}"
            minor="$(printf '%s' "$ver_num" | cut -d. -f2)"
            if [ "$major" -gt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -ge 5 ]; }; then
                with_v3='yes'
            fi
        fi
    fi
    if [ "$with_v3" = 'yes' ]; then
        echo -e "${GREEN}检测到支持 QUIC 的 OpenSSL（${ossl_version:-未知版本}），将启用 HTTP/3。${NC}"
    else
        echo -e "${YELLOW}系统 OpenSSL（${ossl_version:-未检测到}）不支持 QUIC，本次不编译 HTTP/3 模块。${NC}"
        echo -e "${YELLOW}如需 HTTP/3，请另装 quictls/BoringSSL 后用 --with-openssl= 指定。${NC}"
    fi

    echo -e "${BLUE}→ 下载 nginx ${nginx_version}...${NC}"
    mkdir -p "$build_root"
    cd "$build_root" || { echo -e "${RED}无法进入 ${build_root}。${NC}"; pause; return 1; }
    rm -rf "$src_dir" "$nginx_tar"
    if ! wget -q --timeout=30 --tries=3 -O "$nginx_tar" "https://nginx.org/download/${nginx_tar}"; then
        echo -e "${RED}下载 nginx 源码失败：https://nginx.org/download/${nginx_tar}${NC}"
        pause
        return 1
    fi
    tar -zxf "$nginx_tar" || { echo -e "${RED}解压失败。${NC}"; pause; return 1; }
    cd "$src_dir" || { echo -e "${RED}无法进入源码目录。${NC}"; pause; return 1; }

    local -a conf_args=(
        --prefix=/usr/local/nginx
        --user=www-data
        --group=www-data
        --with-http_ssl_module
        --with-http_v2_module
        --with-http_realip_module
        --with-http_stub_status_module
        --with-http_gzip_static_module
        --with-stream
        --with-stream_ssl_module
        --with-stream_ssl_preread_module
        --with-threads
    )
    if [ "$with_v3" = 'yes' ]; then
        conf_args+=(--with-http_v3_module)
    fi

    echo -e "${BLUE}→ 配置编译参数...${NC}"
    if ! ./configure "${conf_args[@]}" > /tmp/nginx-configure.log 2>&1; then
        echo -e "${RED}configure 失败，日志末尾：${NC}"
        tail -n 30 /tmp/nginx-configure.log
        pause
        return 1
    fi

    echo -e "${BLUE}→ 编译（make -j$(nproc)）...${NC}"
    if ! make -j"$(nproc)" > /tmp/nginx-make.log 2>&1; then
        echo -e "${RED}编译失败，日志末尾：${NC}"
        tail -n 30 /tmp/nginx-make.log
        pause
        return 1
    fi
    if ! make install > /tmp/nginx-install.log 2>&1; then
        echo -e "${RED}make install 失败，日志末尾：${NC}"
        tail -n 30 /tmp/nginx-install.log
        pause
        return 1
    fi

    echo -e "${BLUE}→ 创建运行用户与目录...${NC}"
    if ! id -u www-data >/dev/null 2>&1; then
        useradd -r -s /usr/sbin/nologin -d /nonexistent www-data 2>/dev/null || true
    fi
    mkdir -p /usr/local/nginx/conf/conf.d /usr/local/nginx/logs /var/cache/nginx
    chown -R www-data:www-data /var/cache/nginx 2>/dev/null || true
    # 主配置如已存在则不覆盖
    if [ ! -f /usr/local/nginx/conf/nginx.conf ]; then
        cp -a /usr/local/nginx/conf/nginx.conf.default /usr/local/nginx/conf/nginx.conf 2>/dev/null || true
    fi

    echo -e "${BLUE}→ 配置 Nginx systemd 服务...${NC}"
    tee /etc/systemd/system/nginx.service >/dev/null <<'EOF'
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=syslog.target network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/usr/local/nginx/logs/nginx.pid
ExecStartPre=/usr/local/nginx/sbin/nginx -t -q
ExecStart=/usr/local/nginx/sbin/nginx
ExecReload=/usr/local/nginx/sbin/nginx -s reload
ExecStop=/bin/kill -s QUIT $MAINPID
TimeoutStopSec=5
KillMode=mixed
LimitNOFILE=65535
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${BLUE}→ 添加 Nginx 到 PATH...${NC}"
    echo 'export PATH=$PATH:/usr/local/nginx/sbin' > /etc/profile.d/nginx-path.sh
    chmod 644 /etc/profile.d/nginx-path.sh

    echo -e "${BLUE}→ 启用并启动 Nginx...${NC}"
    systemctl daemon-reload
    if ! /usr/local/nginx/sbin/nginx -t >/dev/null 2>&1; then
        echo -e "${RED}nginx -t 未通过，服务未启用。请检查 /usr/local/nginx/conf/nginx.conf。${NC}"
        pause
        return 1
    fi
    systemctl enable --now nginx >/dev/null 2>&1
    systemctl --no-pager --full status nginx | sed -n '1,12p' || true

    if systemctl is-active --quiet nginx; then
        echo -e "${GREEN}Nginx 编译安装完成（版本 ${nginx_version}，HTTP/3: ${with_v3}）。${NC}"
        echo -e "${GREEN}二进制：/usr/local/nginx/sbin/nginx${NC}"
    else
        echo -e "${RED}Nginx 服务未能启动，请查看：journalctl -u nginx -n 50 --no-pager${NC}"
    fi
    pause
}

# 14. 修改 nginx.conf
option14() {
    echo -e "${YELLOW}执行：nginx.conf 配置脚本...${NC}"
    run_remote_reported '配置 nginx.conf' "${RAW_BASE}/nginxconf.sh"
}

# 15. 配置系统更新
option15() {
    echo -e "${YELLOW}====== 系统更新 ======${NC}"
    if ! command -v apt-get >/dev/null 2>&1; then
        echo -e "${RED}此选项仅支持 Debian/Ubuntu（需要 apt-get）。${NC}"
        pause
        return 1
    fi
    confirm '将执行 apt update / full-upgrade / autoremove，是否继续' || { echo '已取消。'; pause; return 0; }

    echo -e "${BLUE}→ apt update ...${NC}"
    apt-get update || { echo -e "${RED}apt update 失败。${NC}"; pause; return 1; }
    echo -e "${BLUE}→ apt full-upgrade -y ...${NC}"
    DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y || { echo -e "${RED}升级过程出错，请查看上方输出。${NC}"; pause; return 1; }
    echo -e "${BLUE}→ apt autoremove -y ...${NC}"
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
    echo -e "${GREEN}系统更新完成。如内核有更新，建议稍后重启。${NC}"
    pause
}

# 16. Ubuntu 系统升级
option16() {
    echo -e "${YELLOW}====== 系统升级（do-release-upgrade） ======${NC}"
    if ! grep -qi '^ID=ubuntu' /etc/os-release 2>/dev/null; then
        echo -e "${RED}当前系统不是 Ubuntu，此选项不适用（Debian 请使用 apt full-upgrade 或编辑 sources.list 手动升级）。${NC}"
        pause
        return 1
    fi
    if ! command -v do-release-upgrade >/dev/null 2>&1; then
        echo -e "${YELLOW}未安装 do-release-upgrade，正在安装 update-manager-core...${NC}"
        apt-get update && apt-get install -y update-manager-core || { echo -e "${RED}安装失败。${NC}"; pause; return 1; }
    fi
    echo -e "${RED}注意：跨版本升级耗时长（可能 30-90 分钟），会用新 sshd 配置覆盖当前会话设置。${NC}"
    echo -e "${YELLOW}建议先在 tmux/screen 中运行，并确保有 VNC/控制台兜底。${NC}"
    confirm '确认继续跨版本升级' || { echo '已取消。'; pause; return 0; }
    do-release-upgrade
    echo -e "${GREEN}升级流程结束（如提示重启请执行 reboot）。${NC}"
    pause
}

# 17. 查看系统信息
option17() {
    echo -e "${YELLOW}执行：拉取信息获取脚本...${NC}"
    run_remote_reported '查看系统信息' "${RAW_BASE}/sysinfo.sh"
}

# 18. 系统清理
option18() {
    echo -e "${YELLOW}执行：拉取清理脚本...${NC}"
    run_remote_reported '系统清理' "${RAW_BASE}/sysclean.sh"
}

# 19. 设置虚拟内存
option19() {
    echo -e "${YELLOW}执行：设置虚拟内存...${NC}"
    run_remote_reported '设置虚拟内存' "${RAW_BASE}/swap.sh"
}

# 20. 配置通配符证书（Certbot + Cloudflare DNS）
option20() {
    echo -e "${YELLOW}====== 配置通配符证书（Certbot + Cloudflare DNS） ======${NC}"

    # 1. 安装 certbot：优先 apt（Debian/Ubuntu 官方源都带 cloudflare 插件），失败再退 snap
    local cf_plugin=''
    if command -v certbot >/dev/null 2>&1 && certbot plugins 2>/dev/null | grep -q 'dns-cloudflare'; then
        echo -e "${GREEN}已安装 certbot 且包含 dns-cloudflare 插件，跳过安装。${NC}"
        cf_plugin='ok'
    else
        echo -e "${BLUE}→ 通过 apt 安装 certbot 与 dns-cloudflare 插件...${NC}"
        apt-get update >/dev/null 2>&1 || true
        if DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-dns-cloudflare >/dev/null 2>&1; then
            cf_plugin='ok'
            echo -e "${GREEN}apt 安装成功。${NC}"
        else
            echo -e "${YELLOW}apt 安装失败（可能是 Ubuntu 的 certbot 在 universe 源未启用），尝试 snap...${NC}"
            if command -v snap >/dev/null 2>&1 && snap install certbot --classic && snap set certbot trust-plugin-with-root=ok && snap install certbot-dns-cloudflare; then
                ln -sf /snap/bin/certbot /usr/bin/certbot
                cf_plugin='ok'
                echo -e "${GREEN}snap 安装成功。${NC}"
            else
                echo -e "${RED}certbot 安装失败。可手动执行：apt install certbot python3-certbot-dns-cloudflare${NC}"
                pause
                return 1
            fi
        fi
    fi
    [ "$cf_plugin" = 'ok' ] || { pause; return 1; }

    # 2. 收集参数
    local cf_email
    read -r -p "请输入用于 ACME 注册的邮箱: " cf_email
    cf_email="${cf_email//[[:space:]]/}"
    if ! printf '%s' "$cf_email" | grep -Eq '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'; then
        echo -e "${RED}邮箱格式无效，已取消。${NC}"
        pause
        return 1
    fi

    local cf_token
    echo -e "${BLUE}→ 请输入 Cloudflare API Token（需 Zone:DNS:Edit 权限，输入时不回显）：${NC}"
    read -rs cf_token
    printf '\n'
    # 去掉粘贴常见的 CR/空白
    cf_token="${cf_token//$'\r'/}"
    cf_token="${cf_token//[[:space:]]/}"
    if [ -z "$cf_token" ]; then
        echo -e "${RED}API Token 不能为空，已取消。${NC}"
        pause
        return 1
    fi

    local wildcard_domain cert_name
    read -r -p "请输入通配符域名（例如 *.example.com）: " wildcard_domain
    wildcard_domain="${wildcard_domain//[[:space:]]/}"
    case "$wildcard_domain" in
        '*.'*) cert_name="${wildcard_domain#\*.}" ;;
        *'*'*) echo -e "${RED}域名格式无效（* 只能出现在最前面的 *.）。${NC}"; pause; return 1 ;;
        *.*)  cert_name="$wildcard_domain"
              echo -e "${YELLOW}未输入 *. 前缀，将按单域名 ${cert_name} 申请。${NC}" ;;
        *)    echo -e "${RED}域名格式无效。${NC}"; pause; return 1 ;;
    esac
    if ! printf '%s' "$cert_name" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$'; then
        echo -e "${RED}域名格式无效：${cert_name}${NC}"
        pause
        return 1
    fi

    # 3. 凭证文件：使用 API Token（全局 API Key 已被 Cloudflare 弃用）
    local cred_file='/etc/letsencrypt/cloudflare.ini'
    mkdir -p /etc/letsencrypt
    umask 077
    cat > "$cred_file" <<EOF
# Cloudflare API Token used by Certbot (dns-cloudflare plugin)
dns_cloudflare_api_token = ${cf_token}
EOF
    chmod 0400 "$cred_file"
    chown root:root "$cred_file" 2>/dev/null || true
    echo -e "${GREEN}凭证已写入 ${cred_file}（权限 0400）。${NC}"

    # 4. 申请证书（带 --agree-tos，避免非交互失败）
    # 说明：-d 传入域名后证书目录名会自动去掉 *. （live/example.com/），
    # 不要再额外传 -d example.com，否则会生成 example.com-0001 分叉目录。
    local -a cert_args=(
        certonly --dns-cloudflare
        --dns-cloudflare-credentials "$cred_file"
        --dns-cloudflare-propagation-seconds 60
        --key-type ecdsa
        --agree-tos -n
        -m "$cf_email"
        -d "$wildcard_domain"
    )

    echo -e "${BLUE}→ 开始申请证书：${wildcard_domain}${NC}"
    if certbot "${cert_args[@]}"; then
        local live_dir="/etc/letsencrypt/live/${cert_name}"
        if [ -s "${live_dir}/fullchain.pem" ] && [ -s "${live_dir}/privkey.pem" ]; then
            echo -e "${GREEN}证书申请成功。${NC}"
            echo -e "${GREEN}证书：${live_dir}/fullchain.pem${NC}"
            echo -e "${GREEN}私钥：${live_dir}/privkey.pem${NC}"
            echo -e "${YELLOW}提示：nginx 配置里的证书目录请填写「去掉 *. 的域名」，即 ${cert_name}。${NC}"
        else
            echo -e "${RED}certbot 返回 0，但未找到 ${live_dir}/fullchain.pem，请检查输出。${NC}"
        fi
        echo -e "${GREEN}查看证书：certbot certificates；吊销：certbot revoke；删除：certbot delete${NC}"
        echo -e "${GREEN}续期由 systemd timer（certbot.timer）或 cron 自动完成，可用 systemctl list-timers | grep certbot 查看。${NC}"
    else
        echo -e "${RED}证书申请失败，请检查：域名是否已托管到该 Cloudflare 账户、Token 权限是否为 Zone:DNS:Edit、Token 是否包含该 Zone。${NC}"
    fi
    pause
}

# 23. 安装基础包
option23() {
    echo -e "${YELLOW}执行：安装基础工具...${NC}"
    if ! command -v apt-get >/dev/null 2>&1; then
        echo -e "${RED}此选项仅支持 Debian/Ubuntu（需要 apt-get）。${NC}"
        pause
        return 1
    fi
    apt-get update || { echo -e "${RED}apt update 失败。${NC}"; pause; return 1; }
    if DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl wget sudo socat htop unzip tar tmux vim nano git jq ca-certificates lsof psmisc; then
        echo -e "${GREEN}基础工具安装完成（含 jq、lsof、psmisc/fuser）。${NC}"
    else
        echo -e "${RED}部分软件包安装失败，请查看上方输出。${NC}"
        pause
        return 1
    fi
    pause
}

# 24. 配置 ufw 防火墙
option24() {
    echo -e "${YELLOW}正在拉取 ufw 管理脚本...${NC}"
    run_remote_reported '配置 ufw 防火墙' "${RAW_BASE}/ufw.sh"
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
    echo -e "${YELLOW}注：1551/1554 是历史约定值，3x-ui 安装后实际端口以面板显示为准，"
    echo -e "    配置 nginx.conf 时请填入实际端口。${NC}"
    pause
}

# ---------------- 主循环 ----------------
while true; do
    show_menu
    # stdin 结束（管道/cron/EOF）时直接退出，避免 read 失败造成死循环
    if ! read -r choice; then
        echo
        echo -e "${YELLOW}标准输入已结束，退出脚本。${NC}"
        exit 0
    fi
    case "$choice" in
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
        '') ;; # 空输入（直接回车）：静默重绘
        *) echo -e "${RED}无效选项，请重新输入。${NC}"; sleep 1 ;;
    esac
done
