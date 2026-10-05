#!/usr/bin/env bash
# ============================================================
# Nginx 配置交互式生成（修正版）
# 平台：Debian 12/13、Ubuntu 22.04/24.04
# 相对原版的改动：
#   1. nginx 可执行文件解析：优先 /usr/local/nginx/sbin/nginx（选项 13
#      的编译安装路径），不再依赖当前 shell 的 PATH（原版在非登录
#      shell 下会直接 die）
#   2. 生成的 http{} 里保留 include conf.d/*.conf 与 include
#      sites-enabled/*，并自动创建目录，不再丢掉用户已有站点
#   3. 端口、后端地址全部可配置（带默认值并做范围校验），不再硬编码
#      1551/1554/2999/3001/5244
#   4. HTTP/3(quic) 只在二进制确实编译了 http_v3 时启用，避免
#      nginx -t 直接失败
#   5. 覆写前写清「会影响什么」，备份文件名明确，覆写后自动 reload，
#      并在 reload 后确认 master 进程存活
#   6. 证书目录名与菜单选项 20 统一：填「去掉 *. 的域名」
# ============================================================

set -uo pipefail

TARGET_CONFIG='/usr/local/nginx/conf/nginx.conf'
TEMP_CONFIG=''
BACKUP_FILE=''
TEST_PREFIX=''

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info() { echo -e "${YELLOW}$1${NC}"; }
ok()   { echo -e "${GREEN}$1${NC}"; }
err()  { echo -e "${RED}$1${NC}" >&2; }

die() {
    err "错误：$1"
    exit 1
}

cleanup_temp() {
    if [ -n "$TEMP_CONFIG" ] && [ -e "$TEMP_CONFIG" ]; then
        rm -f -- "$TEMP_CONFIG"
    fi
    if [ -n "$TEST_PREFIX" ] && [ -d "$TEST_PREFIX" ]; then
        rm -rf -- "$TEST_PREFIX"
    fi
}
trap cleanup_temp EXIT

# ---------- nginx 可执行文件解析 ----------
NGINX_BIN=''
resolve_nginx() {
    local candidates=(
        /usr/local/nginx/sbin/nginx
        /usr/sbin/nginx
        /usr/bin/nginx
        /opt/nginx/sbin/nginx
    )
    local c
    for c in "${candidates[@]}"; do
        if [ -x "$c" ]; then
            NGINX_BIN="$c"
            return 0
        fi
    done
    if command -v nginx >/dev/null 2>&1; then
        NGINX_BIN="$(command -v nginx)"
        return 0
    fi
    return 1
}

# 二进制是否编译了某个模块
nginx_has_module() {
    "$NGINX_BIN" -V 2>&1 | grep -q -- "$1"
}

# ---------- 输入校验 ----------
is_valid_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

read_domain() {
    local prompt="$1" default_value="$2" value
    while true; do
        read -r -p "${prompt} [默认：${default_value}]：" value || die '标准输入已结束。'
        value="${value//[[:space:]]/}"
        value="${value:-$default_value}"
        if is_valid_domain "$value"; then
            printf '%s' "$value"
            return 0
        fi
        err '域名格式无效，请重新输入（不要带 *. 前缀）。'
    done
}

read_port() {
    local prompt="$1" default_value="$2" value
    while true; do
        read -r -p "${prompt} [默认：${default_value}]：" value || die '标准输入已结束。'
        value="${value:-$default_value}"
        case "$value" in
            ''|*[!0-9]*) err '端口必须是数字。'; continue ;;
        esac
        value="$((10#${value}))"
        if [ "$value" -ge 1 ] && [ "$value" -le 65535 ]; then
            printf '%s' "$value"
            return 0
        fi
        err '端口必须在 1-65535 之间。'
    done
}

# ---------- 前置检查 ----------
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die '此脚本必须使用 root 权限运行。'
fi

resolve_nginx || die '找不到 nginx 可执行文件。请先执行菜单选项 13 编译安装，或 apt install nginx'
info "使用 nginx：${NGINX_BIN}（版本：$("$NGINX_BIN" -v 2>&1 | sed 's/^nginx version: //')）"

# 目标配置目录：以 nginx -V 的 --prefix 为准，回退到约定路径
NGINX_PREFIX="$("$NGINX_BIN" -V 2>&1 | tr ' ' '\n' | awk -F= '/^--prefix=/{print $2; exit}')"
NGINX_PREFIX="${NGINX_PREFIX:-/usr/local/nginx}"
TARGET_CONFIG="${NGINX_PREFIX}/conf/nginx.conf"
info "目标配置文件：${TARGET_CONFIG}"

[ -d "$(dirname -- "$TARGET_CONFIG")" ] || die "配置目录不存在：$(dirname -- "$TARGET_CONFIG")"

WITH_HTTP3='no'
if nginx_has_module --with-http_v3_module; then
    WITH_HTTP3='yes'
fi
WITH_STREAM='no'
if nginx_has_module --with-stream; then
    WITH_STREAM='yes'
fi
if [ "$WITH_STREAM" != 'yes' ]; then
    die '当前 nginx 未编译 stream 模块（--with-stream），无法生成 SNI 分流配置。请重新编译。'
fi

# ---------- 收集参数 ----------
printf '\n=== Nginx 配置交互式生成脚本（修正版）===\n'
info "配置生成后会先执行 ${NGINX_BIN} -t，检查通过才会覆写：${TARGET_CONFIG}"
err '注意：本操作会用模板整体覆写该文件（原文件会先备份）。'
echo

domain_one="$(read_domain '请输入 AdGuard 面板域名' 'eg1.example.com')"
domain_two="$(read_domain '请输入 Web 或 Cloudreve 域名' 'eg2.example.com')"
certificate_domain="$(read_domain '请输入证书目录域名（fullchain.pem 所在目录，去掉 *. ）' 'example.com')"

if [ "$domain_one" = "$domain_two" ]; then
    die 'AdGuard 面板域名和 Web/Cloudreve 域名不能相同。'
fi

# 证书必须能覆盖两个域名：检查是否为共同父域
cert_ok=yes
case "$domain_one" in
    "$certificate_domain"|*".${certificate_domain}") ;;
    *) cert_ok=no ;;
esac
case "$domain_two" in
    "$certificate_domain"|*".${certificate_domain}") ;;
    *) cert_ok=no ;;
esac
if [ "$cert_ok" = 'no' ]; then
    err "警告：证书域名 ${certificate_domain} 无法覆盖 ${domain_one} / ${domain_two}。"
    err '请确认已用选项 20 申请 *.${certificate_domain} 通配符证书，否则浏览器会报证书错误。'
    read -r -p '仍要继续？(y/N): ' cont || cont='n'
    [[ "$cont" =~ ^[Yy]$ ]] || die '已取消。'
fi

echo
info '--- 后端端口（回车使用默认值）---'
port_adguard_panel="$(read_port 'AdGuard 面板端口 (/ 反代目标)' 3001)"
port_dns="$(read_port 'DNS 后端端口 (dns_backend)' 2999)"
port_xui_grpc="$(read_port 'x-ui gRPC 端口 (grpc_pass)' 1551)"
port_xui_reality="$(read_port 'x-ui Reality 回退端口 (默认后端)' 1554)"
port_web="$(read_port 'Web/OpenList 端口 (默认站点)' 5244)"
port_entry="$(read_port '本地 HTTPS 入口端口 (stream 分流目标)' 8443)"

echo
info '--- 后端可达性检查 ---'
check_backend() {
    local name="$1" port="$2"
    if command -v ss >/dev/null 2>&1; then
        if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"; then
            ok "  ${name} (127.0.0.1:${port}) 正在监听"
        else
            err "  ${name} (127.0.0.1:${port}) 未检测到监听 —— 请确认对应服务已启动、端口正确"
        fi
    fi
}
check_backend 'AdGuard 面板' "$port_adguard_panel"
check_backend 'DNS 后端' "$port_dns"
check_backend 'x-ui gRPC' "$port_xui_grpc"
check_backend 'x-ui Reality' "$port_xui_reality"
check_backend 'Web/OpenList' "$port_web"

if [ "$WITH_HTTP3" = 'yes' ]; then
    ok '检测到二进制已编译 http_v3 模块，将启用 QUIC (HTTP/3)。'
else
    info '未检测到 http_v3 模块，本次不写 quic 监听（避免 nginx -t 失败）。'
fi

# 已有站点配置时不能抢占 default_server，否则 nginx -t 会直接报端口冲突
EXISTING_SITES='no'
conf_dir_pre="$(dirname -- "$TARGET_CONFIG")"
if [ -n "$(ls -A "${conf_dir_pre}/conf.d" 2>/dev/null)" ] || [ -n "$(ls -A "${conf_dir_pre}/sites-enabled" 2>/dev/null)" ]; then
    EXISTING_SITES='yes'
    err "检测到 ${conf_dir_pre}/conf.d 或 sites-enabled 下已有站点配置。"
    info '为避免与已有 server 冲突，本次生成的 80 端口监听不会加 default_server 标记。'
fi
DEFAULT_SERVER_FLAG='default_server'
if [ "$EXISTING_SITES" = 'yes' ]; then
    DEFAULT_SERVER_FLAG=''
fi

# ---------- 生成配置 ----------
NGINX_CONF_TEMPLATE=$(cat <<'NGINX_CONF'
# 由 nginxconf.sh 生成
worker_processes auto;
worker_cpu_affinity auto;
worker_rlimit_nofile 35535;
pcre_jit on;

error_log logs/error.log warn;
pid logs/nginx.pid;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
    accept_mutex off;
}

stream {
    map_hash_bucket_size 128;
    map_hash_max_size 4096;

    # 根据 TLS ClientHello 中的 SNI 选择后端
    map $ssl_preread_server_name $backend_name {
        __DOMAIN_ONE__ dns_backend;
        default xray_reality_backend;
    }

    upstream none_backend { server 127.0.0.1:__PORT_ENTRY__; }
    upstream xray_reality_backend { server 127.0.0.1:__PORT_XUI_REALITY__; }
    upstream dns_backend { server 127.0.0.1:__PORT_DNS__; }

    # TCP 443 按 SNI 分流，并向后端传递 Proxy Protocol
    server {
        listen 443;
        listen [::]:443;
        ssl_preread on;
        proxy_pass $backend_name;
        proxy_protocol on;
    }

    # UDP 443 转发到默认后端
    server {
        listen 443 udp reuseport;
        listen [::]:443 udp reuseport;
        proxy_pass none_backend;
    }
}

http {
    server_tokens off;
    include mime.types;
    default_type application/octet-stream;
    client_max_body_size 10000m;
    msie_padding off;

    # 站点级配置目录（保留用户已有配置，请勿删除本行）
    include conf.d/*.conf;
    include sites-enabled/*;

    map $http_x_forwarded_for $clientRealIp {
        "" $remote_addr;
        "~*(?P<firstAddr>([0-9a-f]{0,4}:){1,7}[0-9a-f]{1,4}|([0-9]{1,3}\.){3}[0-9]{1,3})$" $firstAddr;
    }

    map $http_upgrade $connection_upgrade {
        default upgrade;
        '' close;
    }

    log_format main '$clientRealIp $remote_addr $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" $http_x_forwarded_for '
                    '"$upstream_addr" "$upstream_status" "$upstream_response_time" "$request_time"';
    access_log logs/access.log main buffer=32k flush=5s;

    sendfile on;
    tcp_nopush on;
    keepalive_timeout 60;
    keepalive_requests 10000;
    gzip on;
    gzip_min_length 2k;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml;
    gzip_comp_level 5;

    # HTTP 跳转 HTTPS
    server {
        listen 80 __DEFAULT_SERVER_FLAG__;
        listen [::]:80 __DEFAULT_SERVER_FLAG__;
        return 301 https://$host$request_uri;
    }

    # AdGuard 面板（stream 层已按 SNI 分流到此端口）
    server {
        listen 127.0.0.1:__PORT_DNS__ ssl proxy_protocol;
        server_name __DOMAIN_ONE__;
        set_real_ip_from 127.0.0.1;
        real_ip_header proxy_protocol;

        ssl_session_tickets on;
        ssl_stapling on;
        ssl_stapling_verify on;
        resolver 223.5.5.5 119.29.29.29 valid=300s;
        resolver_timeout 5s;

        ssl_certificate /etc/letsencrypt/live/__CERTIFICATE_DOMAIN__/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/__CERTIFICATE_DOMAIN__/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;

        location / {
            proxy_pass http://127.0.0.1:__PORT_ADGUARD_PANEL__;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }

        location /snorbo {
            proxy_pass https://127.0.0.1:__PORT_ADGUARD_PANEL__/dns-query;
            proxy_set_header Host $host;
        }

        location /dns-query { return 404; }
    }

    # 默认站点：拒绝未指定域名的访问
    server {
        listen 127.0.0.1:__PORT_ENTRY__ ssl proxy_protocol default_server;
        __LISTEN_QUIC__
        server_name _;

        ssl_certificate /etc/letsencrypt/live/__CERTIFICATE_DOMAIN__/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/__CERTIFICATE_DOMAIN__/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;

        return 444;
    }

    # Web / Cloudreve / OpenList
    server {
        listen 127.0.0.1:__PORT_ENTRY__ ssl proxy_protocol reuseport;
        __LISTEN_QUIC_REUSEPORT__
        http2 on;

        server_name __DOMAIN_ONE__ __DOMAIN_TWO__;
        set_real_ip_from 127.0.0.1;
        real_ip_header proxy_protocol;

        ssl_session_tickets on;
        ssl_stapling on;
        ssl_stapling_verify on;
        resolver 223.5.5.5 119.29.29.29 valid=300s;
        resolver_timeout 5s;

        ssl_certificate /etc/letsencrypt/live/__CERTIFICATE_DOMAIN__/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/__CERTIFICATE_DOMAIN__/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;

        location /-/zh/gp/goldbox {
            grpc_pass grpc://127.0.0.1:__PORT_XUI_GRPC__;
        }

        location / {
            add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
            add_header Alt-Svc 'h3=":443"; ma=86400';
            proxy_pass http://127.0.0.1:__PORT_WEB__;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }
    }
}
NGINX_CONF
)

listen_quic=''
listen_quic_reuseport=''
if [ "$WITH_HTTP3" = 'yes' ]; then
    # quic reuseport 只能出现一次（交给 web server），默认 server 只加 quic
    listen_quic="listen 127.0.0.1:__PORT_ENTRY__ quic;"
    listen_quic_reuseport="listen 127.0.0.1:__PORT_ENTRY__ quic reuseport;"
fi

nginx_conf="${NGINX_CONF_TEMPLATE//__DOMAIN_ONE__/$domain_one}"
nginx_conf="${nginx_conf//__DOMAIN_TWO__/$domain_two}"
nginx_conf="${nginx_conf//__CERTIFICATE_DOMAIN__/$certificate_domain}"
nginx_conf="${nginx_conf//__PORT_ADGUARD_PANEL__/$port_adguard_panel}"
nginx_conf="${nginx_conf//__PORT_DNS__/$port_dns}"
nginx_conf="${nginx_conf//__PORT_XUI_GRPC__/$port_xui_grpc}"
nginx_conf="${nginx_conf//__PORT_XUI_REALITY__/$port_xui_reality}"
nginx_conf="${nginx_conf//__PORT_WEB__/$port_web}"
nginx_conf="${nginx_conf//__PORT_ENTRY__/$port_entry}"
nginx_conf="${nginx_conf//__LISTEN_QUIC__/$listen_quic}"
nginx_conf="${nginx_conf//__LISTEN_QUIC_REUSEPORT__/$listen_quic_reuseport}"
nginx_conf="${nginx_conf//__DEFAULT_SERVER_FLAG__/$DEFAULT_SERVER_FLAG}"

# 证书文件存在性检查
cert_pem="/etc/letsencrypt/live/${certificate_domain}/fullchain.pem"
key_pem="/etc/letsencrypt/live/${certificate_domain}/privkey.pem"
if [ ! -s "$cert_pem" ] || [ ! -s "$key_pem" ]; then
    err "未找到证书文件：${cert_pem} 或 ${key_pem}"
    err '请先用菜单选项 20 申请证书，或确认「证书目录域名」填写正确（应为去掉 *. 的域名）。'
    read -r -p '仍要继续（nginx -t 可能失败）？(y/N): ' cont2 || cont2='n'
    [[ "$cont2" =~ ^[Yy]$ ]] || die '已取消。'
fi

# ---------- 写入候选配置 ----------
conf_dir="$(dirname -- "$TARGET_CONFIG")"
mkdir -p "${conf_dir}/conf.d" "${conf_dir}/sites-enabled" || true

# 校验用的临时 prefix：避免 `nginx -t -c 临时文件` 因 pid/socket 冲突而误报，
# 同时把 mime.types 复制进去（配置里用的是相对路径 include mime.types）。
TEST_PREFIX="$(mktemp -d /tmp/nginxtest.XXXXXX)" || die '无法创建校验用临时目录。'
mkdir -p "${TEST_PREFIX}/conf" "${TEST_PREFIX}/logs"
if [ -f "${conf_dir}/mime.types" ]; then
    cp -p -- "${conf_dir}/mime.types" "${TEST_PREFIX}/conf/mime.types"
else
    printf 'types { }\n' > "${TEST_PREFIX}/conf/mime.types"
fi
# 让校验也能看到用户已有的站点配置（内容与真实环境一致）
if [ -d "${conf_dir}/conf.d" ]; then
    ln -sfn "${conf_dir}/conf.d" "${TEST_PREFIX}/conf/conf.d"
fi
if [ -d "${conf_dir}/sites-enabled" ]; then
    ln -sfn "${conf_dir}/sites-enabled" "${TEST_PREFIX}/conf/sites-enabled"
fi

TEMP_CONFIG="${TEST_PREFIX}/conf/nginx.conf"
printf '%s\n' "$nginx_conf" > "$TEMP_CONFIG"
chmod 644 "$TEMP_CONFIG"

printf '\n正在检查生成的 Nginx 配置……\n'
if ! "$NGINX_BIN" -t -p "$TEST_PREFIX" -c "$TEMP_CONFIG"; then
    die 'Nginx 配置检查失败，原配置未被修改。'
fi
ok '配置检查通过（nginx -t）。'

# ---------- 备份并覆写 ----------
if [ -f "$TARGET_CONFIG" ]; then
    BACKUP_FILE="${TARGET_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
    if ! cp -p -- "$TARGET_CONFIG" "$BACKUP_FILE"; then
        die "备份原配置失败：${TARGET_CONFIG}"
    fi
    info "原配置已备份到：${BACKUP_FILE}"
fi

if ! cp -- "$TEMP_CONFIG" "$TARGET_CONFIG"; then
    die '覆写配置文件失败。'
fi
chmod 644 "$TARGET_CONFIG" 2>/dev/null || true
ok "配置已成功覆写：${TARGET_CONFIG}"

# ---------- reload 并确认存活 ----------
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
    if systemctl reload nginx 2>/dev/null || "$NGINX_BIN" -s reload 2>/dev/null; then
        sleep 1
        if systemctl is-active --quiet nginx; then
            ok 'Nginx 已 reload，服务运行正常。'
        else
            err 'reload 后 Nginx 未处于 active 状态，请检查：journalctl -u nginx -n 50 --no-pager'
            err "回滚：cp -a ${BACKUP_FILE} ${TARGET_CONFIG} && systemctl restart nginx"
        fi
    else
        err "reload 失败，请手动执行：${NGINX_BIN} -s reload"
    fi
else
    info 'Nginx 当前未以 systemd 服务运行（未启动）。'
    echo "  校验配置：${NGINX_BIN} -t"
    echo "  启动服务：systemctl start nginx  或  ${NGINX_BIN}"
fi

echo
echo -e "${YELLOW}后续提示：${NC}"
if [ -n "$BACKUP_FILE" ]; then
    echo "  1. 回滚配置：cp -a ${BACKUP_FILE} ${TARGET_CONFIG} && ${NGINX_BIN} -s reload"
else
    echo "  1. 本次为新建配置，无旧文件可回滚。"
fi
echo "  2. 站点级配置可放在 ${conf_dir}/conf.d/ 下，已通过 include 引入。"
echo "  3. stream 层已占用 443，请在云安全组放行 443/tcp 与 443/udp。"
exit 0
