#!/bin/bash
#变量
CURRENT_SCRIPT_PATH=$(readlink -f "$0")
DEFAULT_ARG="-4"
RAW_SCRIPT=$(curl -Ls https://raw.githubusercontent.com/Snorbo/script-library/refs/heads/main/ip_clear.sh)
# 自动检测并配置快捷键 'z'
## 检测当前 Shell 配置文件
if [ -n "$ZSH_VERSION" ]; then
    CONF_FILE="$HOME/.zshrc"
else
    CONF_FILE="$HOME/.bashrc"
fi

## 检查是否已经配置过别名
if ! grep -q "alias z=" "$CONF_FILE"; then
    echo "提示: 检测到首次运行，正在为你配置快捷键 'z'..."
    echo "alias z='$CURRENT_SCRIPT_PATH'" >> "$CONF_FILE"
    echo "--------------------------------------------------"
    echo "配置成功！由于系统限制，当前窗口需要手动输入: source $CONF_FILE"
    echo "或者直接重新打开一个终端窗口，之后就可以随时使用快捷键 [ z ] 了！"
    echo "=================================================="
    echo ""
fi

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

# 执行远程脚本并传递参数
bash <(echo "$RAW_SCRIPT") $FINAL_ARG
