#!/bin/bash
# 变量
CURRENT_SCRIPT_PATH=$(readlink -f "$0")
DEFAULT_ARG="-4"
RAW_SCRIPT=$(curl -Ls https://raw.githubusercontent.com/Snorbo/script-library/refs/heads/main/ip_clear.sh)

echo "=================================================="
echo "          IP Check 快捷运行脚本"
echo "=================================================="
echo "提示: 直接回车将默认使用参数: $DEFAULT_ARG(仅检查IPV4的IP质量)"
echo "其他参数备注："
echo "-6：仅检查IPV6的IP质量 |-y：自动安装依赖"
echo "-f：展示完整IP地址     |-p：禁用在线报告生成"
echo "--------------------------------------------------"

# 读取用户输入
read -p "请输入指令参数 (默认 $DEFAULT_ARG): " user_input

# 如果用户直接回车（输入为空），则使用默认参数
if [ -z "$user_input" ]; then
    FINAL_ARG="$DEFAULT_ARG"
else
    # 容错处理：如果用户输入了参数但忘了加 "-"，自动帮他加上
    if [[ ! "$user_input" =~ ^- ]]; then
        FINAL_ARG="-$user_input"
    else
        FINAL_ARG="$user_input"
    fi
fi

echo -e "\n[正在拉取脚本]... 请稍候...\n"

# 【优化核心】：判断网络请求是否成功，避免空变量引发错误
if [ -z "$RAW_SCRIPT" ]; then
    echo "错误：无法从 GitHub 拉取脚本，请检查网络连接！"
    exit 1
fi

# 【优化核心】：使用管道配合 -s 传参，完美避开路径解析 Bug
echo "$RAW_SCRIPT" | bash -s -- $FINAL_ARG
