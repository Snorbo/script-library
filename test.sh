# 打印 Logo
print_logo() {
    if command -v figlet >/dev/null 2>&1; then
        figlet -f standard "SNORBO"
    elif command -v toilet >/dev/null 2>&1; then
        toilet -f standard "SNORBO"
    else
        cat << 'EOF'
  SSS   N   N  OOO  RRRR  BBB   OOO 
 S     NN  N O   O R   R B   B O   O
  SSS  N N N O   O RRRR  BBBB  O   O
     S N  NN O   O R R   B   B O   O
  SSS  N   N  OOO  R  R  BBBB   OOO 
EOF
    fi
}

# 主程序
print_logo
echo "欢迎使用 Snorbo 脚本"
# 其他逻辑...
