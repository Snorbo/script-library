#!/bin/bash

# 默认参数
DEFAULT_ARG="-4"

echo "=================================================="
echo "          IP Check 快捷运行脚本"
echo "=================================================="
echo "提示: 直接回车将默认使用参数: $DEFAULT_ARG"
echo "你可以输入其他参数 (例如: -6, -all, --help 等)"
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

echo -e "\n[正在执行]: bash <(curl -Ls https://IP.Check.Place) $FINAL_ARG\n"

# 执行远程脚本并传递参数
bash <(curl -Ls https://IP.Check.Place) $FINAL_ARG
