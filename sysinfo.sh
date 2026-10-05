#!/bin/bash
# sysinfo.sh —— 系统信息查询面板
#
# 目标平台: Ubuntu 22.04 / 24.04, Debian 12 / 13(含最小化安装与容器环境)
#
# 维护约定(修改时请保持):
#   1. 不使用 set -e: 这是交互式查询脚本, 任何可选命令失败都不应中断整个面板。
#   2. 不解析脚本自身路径(不用 readlink 的 -f 形式), 也不依赖 $0 是真实文件路径
#      (常见运行方式: bash <(curl -fsSL .../sysinfo.sh))。
#   3. 真正可选的命令(curl/wget/lscpu/ss/ip/free/timedatectl 等)都先用 command -v
#      判断, 缺失或执行失败时显示 unknown, 不留空值。grep/sed/awk/tr/df/date/mktemp
#      属于 Debian "Essential" 基础工具, 按 POSIX 环境假定存在, 不再逐个判断。
#   4. 所有网络请求都带超时; ipinfo.io 只在 ip_address() 里请求一次, 结果缓存复用。
#   5. 除明确需要分词的地方外, 所有变量展开都加双引号。
#
# 用法:
#   bash sysinfo.sh          打印一次系统信息面板
#   bash sysinfo.sh --help   查看帮助

# 统一使用 C locale: 让 date / awk / df / uptime / timedatectl 的字段名与数字格式
# (小数点、AM/PM、英文列名)不随用户 locale 变化, 输出解析更稳定。
export LC_ALL=C

# ---------- 颜色定义(与原脚本一致) ----------
gl_hui='\e[37m'
gl_hong='\033[31m'
gl_lv='\033[32m'
gl_huang='\033[33m'
gl_lan='\033[34m'
gl_bai='\033[0m'
gl_zi='\033[35m'
gl_kjlan='\033[96m'

# ---------- 全局常量与缓存 ----------
UNKNOWN='unknown'
IPINFO_URL='https://ipinfo.io/json'
IPINFO_JSON=''
IPINFO_REQUESTED=0

# 中国大陆运营商/云厂商出口在 ipinfo org 字段里的特征串(仅在 country 字段取不到时兜底)。
# 原脚本(第 25 行)只用 'CHINANET|mobile|unicom|telecom' 判断:
#   * 漏判: CMNET / CERNET / 云厂商出口(阿里云、腾讯云等)都不含这些词;
#   * 误判: 境外任何名字里带 Telecom/Mobile 的运营商都会被当成中国出口。
# 现在的判定顺序见 is_china_isp(): country == CN 为主, org 特征串兜底。
CHINA_ORG_PATTERN='CHINANET|CHINA[[:space:]]?TELECOM|CHINA[[:space:]]?UNICOM|CHINA[[:space:]]?MOBILE|CHINA[[:space:]]?NETCOM|CHINA[[:space:]]?BROADNET|CHINA[[:space:]]?RAILWAY|CMNET|CNCGROUP|CERNET|CHINA[[:space:]]?EDU|ALIYUN|ALIBABA|TENCENT|HUAWEI[[:space:]]?CLOUD|UCLOUD|KINGSOFT|BAIDU|TIETONG'

# ---------- 通用小工具 ----------

# 命令是否存在(所有可选命令都必须先经过这里)
has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# 只在交互终端里清屏, 避免输出被重定向时写入控制字符
clear_screen() {
    if [ -t 1 ] && [ -n "${TERM:-}" ] && has_cmd clear; then
        clear 2>/dev/null
    fi
    return 0
}

# ---------- 网络信息: 单次请求 + 本地解析 ----------

fetch_ipinfo() {
    # (原脚本缺陷 a) 原脚本分别请求 ipinfo.io/ip、ipinfo.io/org、v6.ipinfo.io/ip,
    # 超时还各不相同(max-time 3 / 1 / 无超时)。现在只在这里请求一次并缓存,
    # 失败时 IPINFO_JSON 保持为空, 由 ip_address() 统一转成 unknown。
    if [ "$IPINFO_REQUESTED" = '1' ]; then
        return 0
    fi
    IPINFO_REQUESTED=1
    # curl 必须带 -f, 否则 HTTP 4xx/5xx 的错误页会被当成数据解析;
    # wget 作为 curl 缺失时的后备, -T 15 同时限制 DNS/连接/读取超时。
    if has_cmd curl; then
        IPINFO_JSON=$(curl -fsSL --connect-timeout 5 --max-time 15 "$IPINFO_URL" 2>/dev/null)
    elif has_cmd wget; then
        IPINFO_JSON=$(wget -q -T 15 --tries=2 -O - "$IPINFO_URL" 2>/dev/null)
    fi
    # 个别代理会返回 CRLF, 去掉 CR 以免影响解析
    IPINFO_JSON=$(printf '%s' "$IPINFO_JSON" | tr -d '\r')
    return 0
}

json_value() {
    # 从缓存的 JSON 中取出键 $1 的值。只用 sed/awk 家族, 因为 jq 在很多
    # 最小化系统上并不存在。
    #   * 取“第一个”出现的键(即顶层字段), 避免付费版 JSON 里 asn/company/abuse
    #     等嵌套对象中的同名字段覆盖顶层值;
    #   * 输出去掉两侧引号、空白和结尾逗号; 键不存在时输出空字符串。
    printf '%s' "$IPINFO_JSON" | tr -d '\n\r' | awk -v key="$1" '
        {
            needle = "\"" key "\""
            pos = index($0, needle)
            if (pos == 0) exit
            rest = substr($0, pos + length(needle))
            if (rest !~ /^[[:space:]]*:/) exit
            sub(/^[[:space:]]*:[[:space:]]*/, "", rest)
            if (substr(rest, 1, 1) == "\"") {
                rest = substr(rest, 2)
                q = index(rest, "\"")
                if (q > 0) rest = substr(rest, 1, q - 1)
                print rest
                exit
            }
            # 值不是字符串(数字/布尔/null, 或嵌套对象/数组):
            # 数字等按原样返回, 对象/数组视为取不到, 避免返回残缺的 JSON 片段。
            if (substr(rest, 1, 1) == "{" || substr(rest, 1, 1) == "[") exit
            sub(/[,}].*$/, "", rest)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", rest)
            if (rest != "" && rest != "null") print rest
            exit
        }'
}

is_china_isp() {
    # 判断“是否中国大陆出口”(决定 IPv4 显示公网地址还是本机地址)。
    # $1 = ipinfo country 字段, $2 = ipinfo org 字段(sed/awk 解析后的纯文本)。
    # 返回 0 表示是中国大陆出口, 1 表示不是。
    # 判定顺序:
    #   1) country == CN: 最可靠, 来自同一次 ipinfo 请求, 云厂商/机房出口也覆盖;
    #   2) country 缺失时, 用 org 里的中国大陆运营商/云厂商特征串兜底
    #      (CHINA_ORG_PATTERN, 见文件顶部注释)。
    local country="$1"
    local org="$2"
    if [ "$country" = 'CN' ]; then
        return 0
    fi
    if [ -n "$org" ] && printf '%s' "$org" | grep -Eqi "$CHINA_ORG_PATTERN"; then
        return 0
    fi
    return 1
}

get_local_ip() {
    # 本机 IPv4(纯本地查询, 不联网): iproute2 -> hostname -I -> ifconfig;
    # 全部拿不到时返回 unknown, 保证调用方永远有值可显示。
    # (原脚本用 grep -oP 'src \K...', 依赖 GNU grep 的 PCRE, 这里改用 awk。)
    local addr=''
    if has_cmd ip; then
        addr=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }')
        if [ -z "$addr" ]; then
            addr=$(ip -4 -o addr show scope global 2>/dev/null | awk '{ split($4, a, "/"); print a[1]; exit }')
        fi
    fi
    if [ -z "$addr" ] && has_cmd hostname; then
        addr=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^[0-9.]+$/ { print; exit }')
    fi
    if [ -z "$addr" ] && has_cmd ifconfig; then
        addr=$(ifconfig 2>/dev/null | awk '/inet / { if ($2 != "127.0.0.1" && $2 !~ /^127\./) { print $2; exit } }')
    fi
    if [ -z "$addr" ]; then
        addr=$UNKNOWN
    fi
    printf '%s' "$addr"
}

get_local_ipv6() {
    # 本机全局 IPv6(纯本地查询); 没有则返回 unknown
    local addr=''
    if has_cmd ip; then
        addr=$(ip -6 -o addr show scope global 2>/dev/null | awk '{ split($4, a, "/"); if (a[1] !~ /^fe80/) { print a[1]; exit } }')
    fi
    if [ -z "$addr" ] && has_cmd ifconfig; then
        addr=$(ifconfig 2>/dev/null | awk '/inet6/ && $2 !~ /^fe80/ && $2 != "::1" { print $2; exit }')
    fi
    if [ -z "$addr" ]; then
        addr=$UNKNOWN
    fi
    printf '%s' "$addr"
}

ip_address() {
    # 集中设置面板所有网络字段(isp_info / geo_info / ipv4_address / ipv6_address),
    # 保证它们都不会是空字符串。
    fetch_ipinfo

    local public_ip='' country='' city='' org='' local4='' local6=''
    public_ip=$(json_value ip)
    country=$(json_value country)
    city=$(json_value city)
    org=$(json_value org)

    # 运营商(原脚本的 isp_info 在请求失败时是空的)
    if [ -n "$org" ]; then
        isp_info=$org
    else
        isp_info=$UNKNOWN
    fi

    # 地理位置
    if [ -z "$country" ] && [ -z "$city" ]; then
        geo_info=$UNKNOWN
    elif [ -z "$city" ]; then
        geo_info=$country
    elif [ -z "$country" ]; then
        geo_info=$city
    else
        geo_info="$country $city"
    fi

    local4=$(get_local_ip)
    local6=$(get_local_ipv6)

    if is_china_isp "$country" "$org"; then
        # 中国大陆出口通常是运营商 NAT/共享地址, 对本机排障意义不大, 因此和原脚本
        # 一样直接显示本机地址(保持熟悉的输出); 与原来不同的是: country/org 都取不到
        # 时原脚本会输出空值, 这里始终会回落到本机地址或 unknown。
        ipv4_address=$local4
    else
        # 拿不到公网 IPv4 时回落到本机地址, 但必须标注清楚, 否则内网地址会被误读成
        # 公网地址(ipinfo 请求失败时"运营商"一行同时会显示 unknown)。
        local ipv4_note=''
        case "$public_ip" in
            '')
                ipv4_note='本机地址, 公网 IP 未获取'
                ;;
            *:*)
                ipv4_note='本机地址, 公网出口为 IPv6'
                ;;
            *)
                ipv4_note=''
                ;;
        esac
        if [ -z "$ipv4_note" ]; then
            ipv4_address=$public_ip
        elif [ "$local4" = "$UNKNOWN" ]; then
            ipv4_address=$UNKNOWN
        else
            ipv4_address="$local4 ($ipv4_note)"
        fi
    fi

    # IPv6: 优先用本次请求返回的公网 IPv6, 否则看本机是否有全局 IPv6 地址。
    # 原脚本在这里用 --max-time 1 请求 v6.ipinfo.io, 基本必然失败并导致整行消失;
    # 现在改为明确显示 unknown(不再出现空值或整行消失)。
    case "$public_ip" in
        *:*)
            ipv6_address=$public_ip
            ;;
        *)
            if [ "$local6" != "$UNKNOWN" ]; then
                ipv6_address=$local6
            else
                ipv6_address=$UNKNOWN
            fi
            ;;
    esac
    return 0
}

# ---------- 各项系统信息 ----------

get_hostname() {
    # (原脚本缺陷 f) uname -n 可能不存在: 逐级回退
    local value=''
    if has_cmd uname; then
        value=$(uname -n 2>/dev/null)
    fi
    if [ -z "$value" ] && has_cmd hostname; then
        value=$(hostname 2>/dev/null)
    fi
    if [ -z "$value" ] && [ -r /proc/sys/kernel/hostname ]; then
        read -r value < /proc/sys/kernel/hostname
    fi
    if [ -z "$value" ] && [ -r /etc/hostname ]; then
        read -r value < /etc/hostname
    fi
    if [ -z "$value" ]; then
        value=$UNKNOWN
    fi
    printf '%s' "$value"
}

get_kernel() {
    local value=''
    if has_cmd uname; then
        value=$(uname -r 2>/dev/null)
    fi
    if [ -z "$value" ] && [ -r /proc/version ]; then
        value=$(awk '{ print $3; exit }' /proc/version 2>/dev/null)
    fi
    if [ -z "$value" ]; then
        value=$UNKNOWN
    fi
    printf '%s' "$value"
}

get_arch() {
    local value=''
    if has_cmd uname; then
        value=$(uname -m 2>/dev/null)
    fi
    if [ -z "$value" ]; then
        value=$UNKNOWN
    fi
    printf '%s' "$value"
}

get_os_info() {
    # /etc/os-release 可能缺失(极简容器), 依次回退 /usr/lib/os-release -> /etc/issue
    local info='' file=''
    for file in /etc/os-release /usr/lib/os-release; do
        if [ -r "$file" ]; then
            info=$(awk '/^PRETTY_NAME=/ { sub(/^PRETTY_NAME=/, ""); gsub(/^"|"$/, ""); print; exit }' "$file" 2>/dev/null)
        fi
        if [ -n "$info" ]; then
            break
        fi
    done
    if [ -z "$info" ] && [ -r /etc/issue ]; then
        # (原脚本缺陷 g) /etc/issue 可能根本不存在, 所以这里必须先判 -r;
        # 同时去掉 \\n \\l 之类的转义序列
        info=$(awk 'NR == 1 { sub(/\\[a-zA-Z].*$/, ""); sub(/[[:space:]]+$/, ""); print; exit }' /etc/issue 2>/dev/null)
    fi
    if [ -z "$info" ]; then
        info=$UNKNOWN
    fi
    printf '%s' "$info"
}

get_cpu_model() {
    # (原脚本缺陷 f) lscpu 可能不存在: 回退 /proc/cpuinfo(x86 用 model name,
    # ARM 用 Hardware/Model/cpu model)
    local model=''
    if has_cmd lscpu; then
        model=$(lscpu 2>/dev/null | awk -F':[[:space:]]*' '/^Model name:/ { print $2; exit }')
    fi
    if [ -z "$model" ] && [ -r /proc/cpuinfo ]; then
        model=$(awk -F':[[:space:]]*' '/^model name|^Model|^Hardware|^cpu model/ { print $2; exit }' /proc/cpuinfo 2>/dev/null)
    fi
    if [ -z "$model" ]; then
        model=$UNKNOWN
    fi
    printf '%s' "$model"
}

get_cpu_cores() {
    local value=''
    if has_cmd nproc; then
        value=$(nproc 2>/dev/null)
    fi
    if [ -z "$value" ] && has_cmd getconf; then
        value=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
    fi
    if [ -z "$value" ] && [ -r /proc/cpuinfo ]; then
        value=$(awk '/^processor[[:space:]]*:/ { n++ } END { if (n > 0) print n }' /proc/cpuinfo 2>/dev/null)
    fi
    if [ -z "$value" ]; then
        value=$UNKNOWN
    fi
    printf '%s' "$value"
}

get_cpu_freq() {
    # (原脚本缺陷 e) 原脚本假设 MHz 一定在第 4 个字段, 且 ARM 上 /proc/cpuinfo
    # 往往没有 cpu MHz 行, 于是整行显示为空。现在:
    #   1) 在 /proc/cpuinfo 的 cpu MHz 行里取第一个数值(不依赖字段位置);
    #   2) 取不到再用 lscpu 的 CPU MHz / CPU max MHz;
    #   3) 仍然取不到(ARM 常见)显示 unknown。
    local mhz=''
    if [ -r /proc/cpuinfo ]; then
        mhz=$(awk -F':[[:space:]]*' '
            tolower($1) ~ /^cpu[[:space:]]*mhz/ {
                line = $2
                gsub(/[^0-9.]/, " ", line)
                n = split(line, parts, " ")
                for (i = 1; i <= n; i++) {
                    if (parts[i] ~ /^[0-9]/ && parts[i] + 0 > 0) {
                        print parts[i]
                        exit
                    }
                }
            }' /proc/cpuinfo 2>/dev/null)
    fi
    if [ -z "$mhz" ] && has_cmd lscpu; then
        mhz=$(lscpu 2>/dev/null | awk -F':[[:space:]]*' '/CPU max MHz|CPU MHz/ { print $2; exit }')
    fi
    if [ -z "$mhz" ]; then
        printf '%s' "$UNKNOWN"
        return 0
    fi
    # >= 1000 MHz 用 GHz 显示(与原脚本一致的 1 位小数), 否则用 MHz
    awk -v m="$mhz" 'BEGIN {
        if (m + 0 <= 0) {
            print "unknown"
            exit
        }
        if (m + 0 >= 1000) {
            printf "%.1f GHz", (m + 0) / 1000
        } else {
            printf "%.0f MHz", m + 0
        }
    }'
}

get_cpu_usage() {
    # 采样 /proc/stat 两次(间隔 1 秒)计算整体 CPU 占用。
    # 原脚本用进程替换 + grep, 且没有处理除零; 这里直接 read 第一行(聚合 cpu 行),
    # 并对空值/全 0 做保护, 失败时输出 unknown。
    if [ ! -r /proc/stat ]; then
        printf '%s' "$UNKNOWN"
        return 0
    fi
    local cpu_label='' u1='' n1='' s1='' i1='' w1='' q1='' sq1='' st1=''
    local u2='' n2='' s2='' i2='' w2='' q2='' sq2='' st2=''
    local busy1='' idle1='' busy2='' idle2='' total='' delta_busy=''
    read -r cpu_label u1 n1 s1 i1 w1 q1 sq1 st1 guest guest_nice < /proc/stat
    sleep 1
    read -r cpu_label u2 n2 s2 i2 w2 q2 sq2 st2 guest guest_nice < /proc/stat
    # busy = user + nice + system + irq + softirq + steal; idle = idle + iowait
    busy1=$((u1 + n1 + s1 + q1 + sq1 + st1))
    idle1=$((i1 + w1))
    busy2=$((u2 + n2 + s2 + q2 + sq2 + st2))
    idle2=$((i2 + w2))
    delta_busy=$((busy2 - busy1))
    total=$((busy2 + idle2 - busy1 - idle1))
    case "$delta_busy" in
        ''|*[!0-9]*)
            printf '%s' "$UNKNOWN"
            return 0
            ;;
    esac
    case "$total" in
        ''|*[!0-9]*|0)
            printf '%s' "$UNKNOWN"
            return 0
            ;;
    esac
    awk -v b="$delta_busy" -v t="$total" 'BEGIN { printf "%.0f", b * 100 / t }'
    return 0
}

get_load() {
    # 优先沿用原脚本的 uptime 输出; uptime 缺失或输出无法解析时用 /proc/loadavg
    local value=''
    if has_cmd uptime; then
        # 不依赖字段位置与语言之外的差异, 只取 "load average:" 之后的内容
        value=$(uptime 2>/dev/null | sed -n 's/.*load average[s]*:[[:space:]]*//p')
    fi
    if [ -z "$value" ] && [ -r /proc/loadavg ]; then
        value=$(awk '{ print $1, $2, $3; exit }' /proc/loadavg 2>/dev/null)
    fi
    if [ -z "$value" ]; then
        value=$UNKNOWN
    fi
    printf '%s' "$value"
}

get_mem_info() {
    # 物理内存: free 缺失时回退 /proc/meminfo(单位 kB -> MB)
    local info=''
    if has_cmd free; then
        info=$(free -b 2>/dev/null | awk 'NR == 2 { printf "%.2f/%.2fM (%.2f%%)", $3 / 1024 / 1024, $2 / 1024 / 1024, ($2 > 0 ? $3 * 100 / $2 : 0) }')
    fi
    if [ -z "$info" ] && [ -r /proc/meminfo ]; then
        info=$(awk '
            /^MemTotal:/ { total = $2 }
            /^MemAvailable:/ { avail = $2; have_avail = 1 }
            /^MemFree:/ { free_mem = $2 }
            /^Buffers:/ { buffers = $2 }
            /^Cached:/ { cached = $2 }
            END {
                if (total > 0) {
                    if (have_avail == 1) {
                        used = total - avail
                    } else {
                        used = total - free_mem - buffers - cached
                    }
                    printf "%.2f/%.2fM (%.2f%%)", used / 1024, total / 1024, used * 100 / total
                }
            }' /proc/meminfo 2>/dev/null)
    fi
    if [ -z "$info" ]; then
        info=$UNKNOWN
    fi
    printf '%s' "$info"
}

get_swap_info() {
    # 虚拟内存: 除法前必须判 total, 否则交换分区为 0 时会除零
    local info=''
    if has_cmd free; then
        info=$(free -m 2>/dev/null | awk 'NR == 3 { used = $3; total = $2; pct = (total > 0) ? used * 100 / total : 0; printf "%dM/%dM (%d%%)", used, total, pct }')
    fi
    if [ -z "$info" ] && [ -r /proc/meminfo ]; then
        info=$(awk '
            /^SwapTotal:/ { total = $2 }
            /^SwapFree:/ { swap_free = $2 }
            END {
                if (total > 0) {
                    used = total - swap_free
                    printf "%dM/%dM (%d%%)", used / 1024, total / 1024, used * 100 / total
                } else {
                    printf "0M/0M (0%%)"
                }
            }' /proc/meminfo 2>/dev/null)
    fi
    if [ -z "$info" ]; then
        info=$UNKNOWN
    fi
    printf '%s' "$info"
}

read_fs_record() {
    # (原脚本缺陷 d) 原脚本用 `df -h | awk '$NF=="/"'`: 设备名较长时 df 会折行,
    # 挂载点落到下一行, 于是匹配不到任何东西(整行空白)。
    # 现在直接 `df -P -h <路径>`: 由 df 自己解析该路径所在的文件系统, 因此对
    # btrfs 子卷、overlayfs(容器)、LVM、bind mount 都成立, 且 -P 保证不折行。
    # 结果写入全局变量: FS_USAGE / FS_MOUNT / FS_DEVICE, 失败返回 1。
    FS_USAGE=''
    FS_MOUNT=''
    FS_DEVICE=''
    local line='' rest=''
    line=$(df -P -h "$1" 2>/dev/null | awk '$5 ~ /%$/ {
        mount = $6
        for (i = 7; i <= NF; i++) {
            mount = mount " " $i
        }
        printf "%s/%s (%s)|%s|%s", $3, $2, $5, mount, $1
        exit
    }')
    if [ -z "$line" ]; then
        return 1
    fi
    FS_USAGE=${line%%|*}
    rest=${line#*|}
    FS_DEVICE=${rest##*|}
    FS_MOUNT=${rest%%|*}
    return 0
}

get_disk_info() {
    local result='' root_mount='' root_device='' var_mount='' var_device=''
    if ! read_fs_record /; then
        printf '%s' "$UNKNOWN"
        return 0
    fi
    result=$FS_USAGE
    root_mount=$FS_MOUNT
    root_device=$FS_DEVICE
    # /var 常常单独分区。只在它确实是“另一个文件系统”时才追加, 避免重复显示:
    #   * 挂载点与 / 相同 -> 同一个文件系统;
    #   * 设备名相同且是真实块设备(/dev/...) -> 同一文件系统的 bind mount;
    #   * overlay/none/tmpfs 这类伪设备名不参与比较(不同挂载点可能同名)。
    if [ -d /var ] && read_fs_record /var; then
        var_mount=$FS_MOUNT
        var_device=$FS_DEVICE
        if [ "$var_mount" != "$root_mount" ]; then
            case "$root_device" in
                /dev/*)
                    if [ "$var_device" = "$root_device" ]; then
                        printf '%s' "$result"
                        return 0
                    fi
                    ;;
            esac
            result="$result | /var: $FS_USAGE"
        fi
    fi
    printf '%s' "$result"
}

get_dns_info() {
    # /etc/resolv.conf 可能不存在(或指向 systemd-resolved 的本地存根)
    local value='' upstream=''
    if [ -r /etc/resolv.conf ]; then
        value=$(awk '/^[[:space:]]*nameserver[[:space:]]+/ { printf "%s ", $2 }' /etc/resolv.conf 2>/dev/null)
        value=${value% }
    fi
    if [ -z "$value" ]; then
        value=$UNKNOWN
    elif [ "$value" = '127.0.0.53' ] && has_cmd resolvectl; then
        # Ubuntu 22.04+ 默认用 systemd-resolved, 存根地址本身没有信息量,
        # 顺带把真实上游 DNS 也显示出来(取不到就保持原样)。
        upstream=$(resolvectl status 2>/dev/null | awk '/DNS Servers:/ { sub(/^[^:]*:[[:space:]]*/, ""); printf "%s ", $0 }')
        upstream=${upstream% }
        if [ -n "$upstream" ]; then
            value="$value (systemd-resolved 上游: $upstream)"
        fi
    fi
    printf '%s' "$value"
}

get_sysctl() {
    # sysctl 缺失时直接读 /proc/sys 下的同名文件(net.ipv4.x -> /proc/sys/net/ipv4/x)
    local value='' path=''
    if has_cmd sysctl; then
        value=$(sysctl -n "$1" 2>/dev/null)
    fi
    if [ -z "$value" ]; then
        path="/proc/sys/$(printf '%s' "$1" | tr '.' '/')"
        if [ -r "$path" ]; then
            read -r value < "$path"
        fi
    fi
    if [ -z "$value" ]; then
        value=$UNKNOWN
    fi
    printf '%s' "$value"
}

output_status() {
    # 网卡累计收发流量(全局变量 rx / tx)。
    # 只统计物理网卡命名(eth/ens/enp/eno+数字), 与原脚本保持一致: 网桥、bond、
    # docker0/veth 等虚拟接口的流量与会话重复, 计入会翻倍。
    rx=$UNKNOWN
    tx=$UNKNOWN
    if [ ! -r /proc/net/dev ]; then
        return 0
    fi
    local output=''
    output=$(awk 'BEGIN { rx_total = 0; tx_total = 0 }
        $1 ~ /^(eth|ens|enp|eno)[0-9]+/ {
            rx_total += $2
            tx_total += $10
        }
        END {
            rx_units = "Bytes";
            tx_units = "Bytes";
            if (rx_total >= 1024) { rx_total /= 1024; rx_units = "K"; }
            if (rx_total >= 1024) { rx_total /= 1024; rx_units = "M"; }
            if (rx_total >= 1024) { rx_total /= 1024; rx_units = "G"; }
            if (tx_total >= 1024) { tx_total /= 1024; tx_units = "K"; }
            if (tx_total >= 1024) { tx_total /= 1024; tx_units = "M"; }
            if (tx_total >= 1024) { tx_total /= 1024; tx_units = "G"; }
            printf "%.2f%s %.2f%s", rx_total, rx_units, tx_total, tx_units;
        }' /proc/net/dev 2>/dev/null)
    if [ -n "$output" ]; then
        read -r rx tx <<< "$output"
    fi
    if [ -z "$rx" ]; then
        rx=$UNKNOWN
    fi
    if [ -z "$tx" ]; then
        tx=$UNKNOWN
    fi
    return 0
}

count_connections() {
    # (原脚本缺陷 c) 原脚本 `ss -t | wc -l` 把表头行也算进去了, 所以永远多 1。
    # 现在用 NR > 1 明确去掉表头(不依赖 ss 的 -H 选项, 老版本 iproute2 没有);
    # ss 不存在时退回 netstat, 两者都没有(或执行失败)显示 unknown。
    local type="$1" count='' raw=''
    if [ "$type" != 't' ] && [ "$type" != 'u' ]; then
        printf '%s' "$UNKNOWN"
        return 0
    fi
    if has_cmd ss; then
        raw=$(ss "-$type" 2>/dev/null)
        if [ $? -eq 0 ]; then
            count=$(printf '%s\n' "$raw" | awk 'NR > 1 { n++ } END { print n + 0 }')
        fi
    elif has_cmd netstat; then
        # netstat 的表头不以 tcp/udp 开头, 按行首协议名过滤即可
        raw=$(netstat "-${type}n" 2>/dev/null)
        if [ $? -eq 0 ]; then
            count=$(printf '%s\n' "$raw" | awk '/^tcp|^udp/ { n++ } END { print n + 0 }')
        fi
    fi
    if [ -z "$count" ]; then
        count=$UNKNOWN
    fi
    printf '%s' "$count"
}

get_uptime() {
    local value=''
    if [ -r /proc/uptime ]; then
        value=$(awk -F. '{
            run_days = int($1 / 86400);
            run_hours = int(($1 % 86400) / 3600);
            run_minutes = int(($1 % 3600) / 60);
            if (run_days > 0) printf "%d天 ", run_days;
            if (run_hours > 0) printf "%d时 ", run_hours;
            printf "%d分", run_minutes;
        }' /proc/uptime 2>/dev/null)
    fi
    if [ -z "$value" ] && has_cmd uptime; then
        value=$(uptime -p 2>/dev/null)
    fi
    if [ -z "$value" ]; then
        value=$UNKNOWN
    fi
    printf '%s' "$value"
}

get_current_time() {
    local value=''
    if has_cmd date; then
        value=$(date '+%Y-%m-%d %I:%M %p' 2>/dev/null)
    fi
    if [ -z "$value" ]; then
        value=$UNKNOWN
    fi
    printf '%s' "$value"
}

current_timezone() {
    # (原脚本缺陷 g) 原脚本无条件 `grep -q 'Alpine' /etc/issue`, 文件不存在时会报错;
    # 且 timedatectl 在容器/最小化系统里可能缺失或没有输出。这里逐级回退:
    #   Alpine(/etc/issue, 先判 -r) -> timedatectl -> date -> /etc/timezone。
    local tz=''
    if [ -r /etc/issue ] && grep -qi 'alpine' /etc/issue 2>/dev/null; then
        tz=$(date '+%Z %z' 2>/dev/null)
    elif has_cmd timedatectl; then
        tz=$(timedatectl 2>/dev/null | awk -F':[[:space:]]*' '/Time zone/ { print $2; exit }')
        if [ -z "$tz" ]; then
            tz=$(date '+%Z %z' 2>/dev/null)
        fi
    else
        tz=$(date '+%Z %z' 2>/dev/null)
    fi
    if [ -z "$tz" ] && [ -r /etc/timezone ]; then
        read -r tz < /etc/timezone
    fi
    if [ -z "$tz" ]; then
        tz=$UNKNOWN
    fi
    printf '%s' "$tz"
}

# ---------- 面板 ----------

linux_info() {
    local cpu_info='' cpu_usage_percent='' cpu_usage_display='' cpu_cores='' cpu_freq=''
    local mem_info='' swap_info='' disk_info='' load='' dns_addresses=''
    local cpu_arch='' host_name='' kernel_version='' congestion_algorithm='' queue_algorithm=''
    local os_info='' current_time='' timezone='' runtime='' tcp_count='' udp_count=''

    clear_screen
    echo -e "${gl_kjlan}正在查询系统信息……${gl_bai}"

    # 网络信息(单次请求)最先执行, 让用户在等待网络时就先看到提示。
    ip_address

    cpu_info=$(get_cpu_model)
    cpu_usage_percent=$(get_cpu_usage)
    cpu_cores=$(get_cpu_cores)
    cpu_freq=$(get_cpu_freq)
    mem_info=$(get_mem_info)
    swap_info=$(get_swap_info)
    disk_info=$(get_disk_info)
    load=$(get_load)
    dns_addresses=$(get_dns_info)
    cpu_arch=$(get_arch)
    host_name=$(get_hostname)
    kernel_version=$(get_kernel)
    congestion_algorithm=$(get_sysctl net.ipv4.tcp_congestion_control)
    queue_algorithm=$(get_sysctl net.core.default_qdisc)
    os_info=$(get_os_info)
    output_status
    current_time=$(get_current_time)
    runtime=$(get_uptime)
    timezone=$(current_timezone)
    tcp_count=$(count_connections t)
    udp_count=$(count_connections u)

    # 取不到 CPU 占用率时不显示 "unknown%"
    case "$cpu_usage_percent" in
        ''|"$UNKNOWN")
            cpu_usage_display=$UNKNOWN
            ;;
        *)
            cpu_usage_display="${cpu_usage_percent}%"
            ;;
    esac

    clear_screen
    echo -e "系统信息查询"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}主机名:         ${gl_bai}$host_name"
    echo -e "${gl_kjlan}系统版本:       ${gl_bai}$os_info"
    echo -e "${gl_kjlan}Linux版本:      ${gl_bai}$kernel_version"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}CPU架构:        ${gl_bai}$cpu_arch"
    echo -e "${gl_kjlan}CPU型号:        ${gl_bai}$cpu_info"
    echo -e "${gl_kjlan}CPU核心数:      ${gl_bai}$cpu_cores"
    echo -e "${gl_kjlan}CPU频率:        ${gl_bai}$cpu_freq"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}CPU占用:        ${gl_bai}$cpu_usage_display"
    echo -e "${gl_kjlan}系统负载:       ${gl_bai}$load"
    echo -e "${gl_kjlan}TCP|UDP连接数:  ${gl_bai}$tcp_count|$udp_count"
    echo -e "${gl_kjlan}物理内存:       ${gl_bai}$mem_info"
    echo -e "${gl_kjlan}虚拟内存:       ${gl_bai}$swap_info"
    echo -e "${gl_kjlan}硬盘占用:       ${gl_bai}$disk_info"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}总接收:         ${gl_bai}$rx"
    echo -e "${gl_kjlan}总发送:         ${gl_bai}$tx"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}网络算法:       ${gl_bai}$congestion_algorithm $queue_algorithm"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}运营商:         ${gl_bai}$isp_info"
    echo -e "${gl_kjlan}IPv4地址:       ${gl_bai}$ipv4_address"
    echo -e "${gl_kjlan}IPv6地址:       ${gl_bai}$ipv6_address"
    echo -e "${gl_kjlan}DNS地址:        ${gl_bai}$dns_addresses"
    echo -e "${gl_kjlan}地理位置:       ${gl_bai}$geo_info"
    echo -e "${gl_kjlan}系统时间:       ${gl_bai}$timezone $current_time"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}运行时长:       ${gl_bai}$runtime"
    echo
}

usage() {
    cat <<'EOF'
用法: bash sysinfo.sh [选项]

不带任何参数运行时打印一次系统信息面板(主机名/系统/CPU/内存/磁盘/流量/网络/时间等)。

选项:
  -h, --help    显示本帮助并退出

说明:
  * 可选命令缺失或查询失败时对应字段显示 unknown, 不会中断整个面板。
  * 网络信息(运营商/公网 IP/地理位置)来自对 ipinfo.io 的单次请求, 连接超时 5 秒、
    整体超时 15 秒; 请求失败时相关字段显示 unknown。
EOF
}

# ---------- 入口 ----------

case "${1:-}" in
    '')
        linux_info
        exit 0
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        printf '%s\n' "未知参数: $1" >&2
        usage >&2
        exit 2
        ;;
esac
