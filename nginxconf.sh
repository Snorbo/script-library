#!/usr/bin/env bash

# 交互式生成示范 nginx.conf，并在检查通过后覆写 Nginx 配置文件。
set -Eeuo pipefail

target_config='/usr/local/nginx/conf/nginx.conf'
temp_config=''

cleanup_temp() {
    if [[ -n "$temp_config" && -e "$temp_config" ]]; then
        rm -f -- "$temp_config"
    fi
}

trap cleanup_temp EXIT

die() {
    printf '错误：%s\n' "$1" >&2
    exit 1
}

[[ "$EUID" -eq 0 ]] || die '此脚本必须使用 root 权限运行。'
command -v nginx >/dev/null 2>&1 || die '找不到 nginx 命令，请先确认 Nginx 已安装。'

[[ -d "$(dirname -- "$target_config")" ]] || die "配置目录不存在：$(dirname -- "$target_config")"

# 只接受普通域名，避免把无效内容写入 Nginx 配置。
is_valid_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

read_domain() {
    local prompt="$1"
    local default_value="$2"
    local value

    while true; do
        read -r -p "${prompt} [默认：${default_value}]：" value
        value="${value:-$default_value}"

        if is_valid_domain "$value"; then
            printf '%s' "$value"
            return 0
        fi

        printf '错误：域名格式无效，请重新输入。\n' >&2
    done
}

printf '=== Nginx 配置交互式生成脚本 ===\n'
printf '配置生成后会先执行 nginx -t，检查通过才会覆写：%s\n\n' "$target_config"

domain_one="$(read_domain '请输入 AdGuard 面板域名' 'eg1.example.com')"
domain_two="$(read_domain '请输入 Web 或 Cloudreve 域名' 'eg2.example.com')"
certificate_domain="$(read_domain '请输入证书目录域名（用于 fullchain.pem 和 privkey.pem）' 'example.net')"

if [[ "$domain_one" == "$domain_two" ]]; then
    die 'AdGuard 面板域名和 Web/Cloudreve 域名不能相同。'
fi

# 使用单引号 heredoc，保留 Nginx 配置中的 $host、$request_uri 等变量。
nginx_conf_template=$(cat <<'NGINX_CONF'
# user nginx;
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

    # 根据 TLS ClientHello 中的域名选择后端。
    map $ssl_preread_server_name $backend_name {
        __DOMAIN_ONE__ dns_backend;
        default xray_reality_backend;
    }

    upstream none_backend { server 127.0.0.1:8443; }
    upstream xray_reality_backend { server 127.0.0.1:1554; }
    upstream dns_backend { server 127.0.0.1:2999; }
    upstream web_backend {
        server 127.0.0.1:8443 max_fails=3 fail_timeout=10s;
        zone backend 64k;
    }

    # TCP 443 端口根据 SNI 转发，并向后端传递 Proxy Protocol。
    server {
        listen 443;
        listen [::]:443;
        ssl_preread on;
        proxy_pass $backend_name;
        proxy_protocol on;
    }

    # UDP 443 端口转发到默认后端。
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

    # 获取经过反向代理传递的真实客户端 IP。
    map $http_x_forwarded_for $clientRealIp {
        "" $remote_addr;
        "~*(?P<firstAddr>([0-9a-f]{0,4}:){1,7}[0-9a-f]{1,4}|([0-9]{1,3}\.){3}[0-9]{1,3})$" $firstAddr;
    }

    # 根据 Upgrade 请求头设置连接类型。
    map $http_upgrade $connection_upgrade {
        default upgrade;
        '' close;
    }

    log_format main '$clientRealIp $remote_addr $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" $http_x_forwarded_for '
                    '"$upstream_addr" "$upstream_status" "$upstream_response_time" "$request_time" ';
    access_log logs/access.log main buffer=32k flush=5s;

    sendfile on;
    tcp_nopush on;
    keepalive_timeout 60;
    keepalive_requests 10000;
    gzip on;
    gzip_min_length 2k;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml;
    gzip_comp_level 5;

    # 将 HTTP 请求重定向到 HTTPS。
    server {
        listen 80;
        listen [::]:80;
        return 301 https://$host$request_uri;
    }

    # AdGuard 面板。
    server {
        listen 127.0.0.1:2999 ssl proxy_protocol;
        server_name __DOMAIN_ONE__;
        set_real_ip_from 127.0.0.1;
        real_ip_header proxy_protocol;

        ssl_session_tickets on;
        ssl_stapling on;
        ssl_stapling_verify on;
        resolver 8.8.8.8 1.1.1.1 valid=300s;
        resolver_timeout 5s;

        ssl_certificate /etc/letsencrypt/live/__CERTIFICATE_DOMAIN__/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/__CERTIFICATE_DOMAIN__/privkey.pem;
        ssl_protocols TLSv1.3;

        location / {
            proxy_pass http://127.0.0.1:3001;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }

        location /snorbo {
            rewrite ^/snorbo$ /dns-query break;
            proxy_pass https://127.0.0.1:3000/dns-query;
            proxy_set_header Host $host;
        }

        location /dns-query { return 404; }
    }

    # 针对泛域名证书的补丁：拒绝未指定的域名。
    server {
        listen 127.0.0.1:8443 quic default_server;
        listen 127.0.0.1:8443 ssl proxy_protocol default_server;
        server_name _;

        ssl_certificate /etc/letsencrypt/live/__CERTIFICATE_DOMAIN__/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/__CERTIFICATE_DOMAIN__/privkey.pem;
        ssl_protocols TLSv1.3;

        # 直接断开连接，不返回任何数据。
        return 444;
    }

    # Web 和 Cloudreve。
    server {
        listen 127.0.0.1:8443 quic reuseport;
        listen 127.0.0.1:8443 ssl proxy_protocol reuseport;
        http2 on;

        # 允许访问的域名。
        server_name __DOMAIN_ONE__ __DOMAIN_TWO__;
        set_real_ip_from 127.0.0.1;
        real_ip_header proxy_protocol;

        ssl_session_tickets on;
        ssl_stapling on;
        ssl_stapling_verify on;
        resolver 8.8.8.8 1.1.1.1 valid=300s;
        resolver_timeout 5s;

        ssl_certificate /etc/letsencrypt/live/__CERTIFICATE_DOMAIN__/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/__CERTIFICATE_DOMAIN__/privkey.pem;
        ssl_protocols TLSv1.3;

        location /-/zh/gp/goldbox?ref_=nav_cs_gb {
            grpc_pass grpc://127.0.0.1:1551;
        }

        location / {
            add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
            add_header Alt-Svc 'h3=":443"; ma=86400';
            proxy_pass http://127.0.0.1:5244;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }
    }
}
NGINX_CONF
)

# 仅替换脚本定义的占位符，不使用 sed，避免 Nginx 变量被 shell 展开。
nginx_conf="${nginx_conf_template//__DOMAIN_ONE__/$domain_one}"
nginx_conf="${nginx_conf//__DOMAIN_TWO__/$domain_two}"
nginx_conf="${nginx_conf//__CERTIFICATE_DOMAIN__/$certificate_domain}"

# 临时文件和目标文件位于同一目录，便于执行原子替换。
temp_config="$(mktemp "${target_config}.tmp.XXXXXX")"
printf '%s\n' "$nginx_conf" > "$temp_config"
chmod 644 "$temp_config"

printf '\n正在检查生成的 Nginx 配置……\n'
if ! nginx -t -c "$temp_config"; then
    die 'Nginx 配置检查失败，原配置未被修改。'
fi

if [[ -f "$target_config" ]]; then
    backup_file="${target_config}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p -- "$target_config" "$backup_file"
    printf '原配置已备份到：%s\n' "$backup_file"
fi

mv -f -- "$temp_config" "$target_config"
temp_config=''

printf '配置已成功覆写：%s\n' "$target_config"
printf '如需使 Nginx 载入新配置，请执行：nginx -s reload\n'
