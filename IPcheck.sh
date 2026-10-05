#!/bin/bash
# IPcheck.sh —— IP 质量检测快捷启动脚本(ip_clear.sh 的下载启动器)
#
# 作用不变: 从 GitHub 拉取官方 ip_clear.sh 并执行, 转发一个用户输入的参数。
#
# 相对原脚本的改动(每条都对应一个真实缺陷):
#   1. 原脚本用 `echo "$RAW_SCRIPT" | bash -s -- $FINAL_ARG` 执行, 子进程的 stdin
#      变成了那段脚本文本, 子脚本里的 read / 交互提示读不到用户输入(会读到脚本文本
#      或立刻 EOF)。现在改为: mktemp 落地成真实文件 -> 校验非空 -> bash -n 语法预检
#      -> `bash "$tmp" ...` 执行, stdin 始终是当前终端。
#   2. 原脚本先联网下载再询问参数, 用户要先干等网络。现在先询问, 再下载。
#   3. 原脚本的 CURRENT_SCRIPT_PATH(用 readlink 的 -f 形式解析 $0 得到)是死代码,
#      而且这种方式与 $0 在 `bash <(curl ...)` 场景下都不可靠, 已整体删除。
#   4. 参数白名单校验(只允许 4/6/y/f/p 与空格分隔), 空输入用默认值 -4,
#      无效输入最多重问 MAX_ATTEMPTS 次。
#   5. curl / wget 都缺失或下载失败时给出明确错误和非零退出码, 并提示
#      raw.githubusercontent.com 在部分网络下会被阻断。
#
# 用法:
#   bash IPcheck.sh        (交互式询问参数后拉取并执行 ip_clear.sh)
# 说明: 命令行参数与旧版一样被忽略, 参数一律通过交互输入。

SCRIPT_URL='https://raw.githubusercontent.com/Snorbo/script-library/refs/heads/main/ip_clear.sh'
DEFAULT_ARG='-4'
MAX_ATTEMPTS=3

TMP_SCRIPT=''
FINAL_ARG=''

# ---------- 基础工具 ----------

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

error() {
    printf '错误: %s\n' "$1" >&2
}

cleanup() {
    # 退出时清理临时文件(正常退出、exit、Ctrl-C/Ctrl-\ 以及 kill 都会触发 EXIT trap)
    if [ -n "$TMP_SCRIPT" ] && [ -f "$TMP_SCRIPT" ]; then
        rm -f -- "$TMP_SCRIPT"
    fi
    return 0
}

print_banner() {
    printf '%s\n' '=================================================='
    printf '%s\n' '          IP Check 快捷运行脚本'
    printf '%s\n' '=================================================='
    printf '%s\n' "提示: 直接回车将默认使用参数: $DEFAULT_ARG(仅检查IPV4的IP质量)"
    printf '%s\n' '其他参数备注：'
    printf '%s\n' '-6：仅检查IPV6的IP质量 |-y：自动安装依赖'
    printf '%s\n' '-f：展示完整IP地址     |-p：禁用在线报告生成'
    printf '%s\n' '--------------------------------------------------'
}

# ---------- 参数处理 ----------

normalize_arg() {
    # 规范化用户输入:
    #   * 所有空白(含制表符)压缩成一个空格, 并去掉首尾空白;
    #   * 空输入 -> 默认参数 -4;
    #   * 忘记写 "-" 时自动补上(保留原脚本的容错行为);
    #   * 只有单独一个 "-"(没有任何选项)时按空输入处理, 避免把无意义参数传给子脚本。
    local value=''
    value=$(printf '%s' "$1" | tr -s '[:space:]' ' ')
    value=${value# }
    value=${value% }
    if [ -z "$value" ]; then
        printf '%s' "$DEFAULT_ARG"
        return 0
    fi
    case "$value" in
        -*) ;;
        *) value="-${value}" ;;
    esac
    if [ "$value" = '-' ]; then
        printf '%s' "$DEFAULT_ARG"
        return 0
    fi
    printf '%s' "$value"
}

is_valid_arg() {
    # 白名单校验: 只允许一个前导 '-' 加上 4/6/y/f/p, 以及作为分隔的空格,
    # 也就是正则 ^-[46yfp ]*$。
    # 说明: 正则放进变量再匹配, 是因为 [[ ]] 的匹配式里不能出现裸空格
    # (会被 shell 当成词分隔); 用变量既能写出真实的空格, 匹配语义也不变。
    local pattern='^-[46yfp ]*$'
    [[ "$1" =~ $pattern ]]
}

ask_arg() {
    # 询问参数并写入全局 FINAL_ARG; 校验失败最多重问 MAX_ATTEMPTS 次。
    # 全部失败返回 1。读取到 EOF(例如 stdin 被关闭或按了 Ctrl-D)时直接用默认值,
    # 不让脚本卡住。
    local attempt=1
    local input=''
    local candidate=''
    local prompt="请输入指令参数 (默认 ${DEFAULT_ARG}): "
    while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
        if ! read -r -p "$prompt" input; then
            printf '\n'
            printf '%s\n' '未读取到输入(EOF), 使用默认参数。'
            FINAL_ARG=$DEFAULT_ARG
            return 0
        fi
        candidate=$(normalize_arg "$input")
        if is_valid_arg "$candidate"; then
            FINAL_ARG=$candidate
            return 0
        fi
        printf '%s\n' "参数无效: $input"
        printf '%s\n' '只允许 4、6、y、f、p 这几个选项(可用空格分隔多个, 例如: -4 -y)。'
        attempt=$((attempt + 1))
        prompt="请重新输入 (默认 ${DEFAULT_ARG}): "
    done
    return 1
}

# ---------- 下载与执行 ----------

fetch_script() {
    # 下载 ip_clear.sh 到 $TMP_SCRIPT(调用前必须已由 mktemp 创建)。
    # 返回 0 成功; 1 下载失败; 2 既没有 curl 也没有 wget。
    # 网络请求全部带超时: curl 连接 5s / 整体 15s; wget -T 15 同时限制
    # DNS、连接和读取超时, --tries=2 避免默认 20 次重试长时间卡住。
    if has_cmd curl; then
        # -f 必须有: HTTP 4xx/5xx 时直接失败, 不会把错误页当脚本保存
        if curl -fsSL --connect-timeout 5 --max-time 15 -o "$TMP_SCRIPT" "$SCRIPT_URL"; then
            return 0
        fi
        return 1
    fi
    if has_cmd wget; then
        if wget -q -T 15 --tries=2 -O - "$SCRIPT_URL" > "$TMP_SCRIPT"; then
            return 0
        fi
        return 1
    fi
    return 2
}

check_script() {
    # 下载结果三连检: 非空 -> 不是 HTML/404 之类的错误页 -> bash 语法预检通过。
    local syntax_error=''
    if [ ! -s "$TMP_SCRIPT" ]; then
        error '下载到的内容为空(网络被中断或响应为空)。'
        return 1
    fi
    if head -c 256 "$TMP_SCRIPT" | grep -Eqi '<html|404: not found|^404$|rate limit|access denied'; then
        error '下载到的不是脚本内容(可能是 GitHub 限流或中间设备返回的拦截页面)。'
        return 1
    fi
    syntax_error=$(bash -n "$TMP_SCRIPT" 2>&1)
    if [ -n "$syntax_error" ]; then
        error '下载到的脚本没有通过 bash -n 语法预检, 已中止执行。'
        printf '%s\n' "$syntax_error" >&2
        return 1
    fi
    return 0
}

run_script() {
    # 参数转发: FINAL_ARG 可能包含多个以空格分隔的选项(例如 "-4 -y"),
    # 这里的 read -a 是“有意的分词”: 每个选项各自成为一个独立参数传给子脚本,
    # 既保持了原脚本 $FINAL_ARG 直接展开的分词效果, 又不留下未加引号的变量展开
    # (输入已通过白名单校验, 不含通配符或命令替换字符)。
    #
    # 关键: 直接把真实临时文件交给 bash 执行, 不做管道、不做 < 重定向,
    # 这样子脚本的 stdin 仍然是当前终端, 它的交互提示才能正常工作。
    local -a script_args=()
    local status=0
    read -r -a script_args <<< "$FINAL_ARG"
    bash "$TMP_SCRIPT" "${script_args[@]}"
    status=$?
    return "$status"
}

# ---------- 主流程 ----------

main() {
    print_banner

    # (b) 先问参数, 再去联网, 避免用户在下载上干等
    if ! ask_arg; then
        error "参数连续 ${MAX_ATTEMPTS} 次校验失败, 已退出。"
        return 1
    fi

    printf '\n%s\n\n' '[正在拉取脚本]... 请稍候...'

    if ! has_cmd curl && ! has_cmd wget; then
        error '系统里没有 curl 也没有 wget, 无法下载脚本。'
        printf '%s\n' '      请先安装一个, 例如: apt-get update && apt-get install -y curl' >&2
        return 1
    fi

    if ! has_cmd mktemp; then
        error '找不到 mktemp, 无法创建临时文件。'
        return 1
    fi
    TMP_SCRIPT=$(mktemp 2>/dev/null)
    if [ -z "$TMP_SCRIPT" ] || [ ! -f "$TMP_SCRIPT" ]; then
        error '创建临时文件失败(mktemp)。'
        return 1
    fi

    if ! fetch_script; then
        error '无法从 GitHub 拉取 ip_clear.sh, 请检查网络连接。'
        printf '%s\n' '      注意: raw.githubusercontent.com 在部分网络环境下会被阻断或返回错误页,' >&2
        printf '%s\n' '            可先配置代理后重试, 或手动下载该文件后本地执行:' >&2
        printf '%s\n' "            $SCRIPT_URL" >&2
        return 1
    fi

    if ! check_script; then
        return 1
    fi

    printf '%s\n' '脚本已就绪, 开始执行...'
    run_script
    return $?
}

# 临时文件清理(含异常退出)
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 131' QUIT
trap 'exit 143' TERM

main
exit $?
