#!/bin/sh
# XGS 87 维护 U 盘的菜单。开机在 tty1 上跑，选完就执行，不做别的事。
set -u
PAYLOAD=$(dirname "$0")
PAYLOAD=$(cd "$PAYLOAD/.." && pwd)
export PAYLOAD

while :; do
	CHOICE=$(whiptail --title "XGS 87 维护盘" --menu \
"这条 U 盘里带着 debian-x86.img 和 debian-npu.tar.zst。

选择一个操作：" 20 74 8 \
		"1" "重装 x86（把镜像写进这台机器的内置 eMMC）" \
		"2" "重装 NPU（把根文件系统送到 NPU，需要它能启动）" \
		"3" "查看状态（磁盘、vNTB 链路、NPU 是否在线）" \
		"4" "备份 x86 内置盘到 U 盘" \
		"5" "shell（Ctrl-D 返回菜单）" \
		"0" "重新启动" 3>&1 1>&2 2>&3) || exit 0

	case "$CHOICE" in
	1) "$PAYLOAD/install-x86.sh" ;;
	2) "$PAYLOAD/install-npu.sh" ;;
	3) "$PAYLOAD/status.sh"; read -r _ ;;
	4) "$PAYLOAD/backup-x86.sh" ;;
	5) /bin/sh ;;
	0) reboot ;;
	esac
done