#!/usr/bin/env bash

gl_huang='\033[33m'
gl_bai='\033[0m'

root_use() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请使用 root 运行此脚本。"
    exit 1
  fi
}

send_stats() {
  :
}

add_swap() {
	local new_swap=$1  # 获取传入的参数

	# 获取当前系统中所有的 swap 分区
	local swap_partitions=$(grep -E '^/dev/' /proc/swaps | awk '{print $1}')

	# 遍历并删除所有的 swap 分区
	for partition in $swap_partitions; do
		swapoff "$partition"
		wipefs -a "$partition"
		mkswap -f "$partition"
	done

	# 确保 /swapfile 不再被使用
	swapoff /swapfile

	# 删除旧的 /swapfile
	rm -f /swapfile

	# 创建新的 swap 分区
	fallocate -l ${new_swap}M /swapfile
	chmod 600 /swapfile
	mkswap /swapfile
	swapon /swapfile

	sed -i '/\/swapfile/d' /etc/fstab
	echo "/swapfile swap swap defaults 0 0" >> /etc/fstab

	if [ -f /etc/alpine-release ]; then
		echo "nohup swapon /swapfile" > /etc/local.d/swap.start
		chmod +x /etc/local.d/swap.start
		rc-update add local
	fi

	echo -e "虚拟内存大小已调整为${gl_huang}${new_swap}${gl_bai}M"
}

check_swap() {
	local swap_total=$(free -m | awk 'NR==3{print $2}')

	# 判断是否需要创建虚拟内存
	[ "$swap_total" -gt 0 ] || add_swap 1024
}

swap_menu() {
	root_use
	send_stats "设置虚拟内存"
	while true; do
		clear
		echo "设置虚拟内存"
		local swap_used=$(free -m | awk 'NR==3{print $3}')
		local swap_total=$(free -m | awk 'NR==3{print $2}')
		local swap_info=$(free -m | awk 'NR==3{used=$3; total=$2; if (total == 0) {percentage=0} else {percentage=used*100/total}; printf "%dM/%dM (%d%%)", used, total, percentage}')

		echo -e "当前虚拟内存: ${gl_huang}$swap_info${gl_bai}"
		echo "------------------------"
		echo "1. 分配1024M         2. 分配2048M         3. 分配4096M         4. 自定义大小"
		echo "------------------------"
		echo "0. 返回上一级选单"
		echo "------------------------"
		read -e -p "请输入你的选择: " choice

		case "$choice" in
		  1)
			send_stats "已设置1G虚拟内存"
			add_swap 1024

			;;
		  2)
			send_stats "已设置2G虚拟内存"
			add_swap 2048

			;;
		  3)
			send_stats "已设置4G虚拟内存"
			add_swap 4096

			;;

		  4)
			read -e -p "请输入虚拟内存大小（单位M）: " new_swap
			add_swap "$new_swap"
			send_stats "已设置自定义虚拟内存"
			;;

		  *)
			break
			;;
		esac
	done
}

usage() {
  cat <<'EOF'
用法:
  sudo bash virtual_memory_swap.sh
  sudo bash virtual_memory_swap.sh menu
  sudo bash virtual_memory_swap.sh swap 2048
  sudo bash virtual_memory_swap.sh check
  sudo bash virtual_memory_swap.sh 1024
  sudo bash virtual_memory_swap.sh 2048
  sudo bash virtual_memory_swap.sh 4096
  sudo bash virtual_memory_swap.sh custom
EOF
}

main() {
  case "${1:-menu}" in
    menu)
      swap_menu
      ;;
    swap)
      shift
      root_use
      if [ "${1:-}" ]; then
        add_swap "$1"
      else
        usage
        exit 1
      fi
      ;;
    check|auto)
      root_use
      check_swap
      ;;
    1024|2048|4096)
      root_use
      add_swap "$1"
      ;;
    custom)
      root_use
      read -r -e -p "请输入虚拟内存大小（单位M）: " new_swap
      add_swap "$new_swap"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
