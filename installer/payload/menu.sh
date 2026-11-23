#!/bin/sh
# XGS 87 维护 U 盘的菜单。开机在串口控制台上跑，选完就执行，不做别的事。
#
# 顶层只有 6 项：装、看、串口、shell、关机/重启。备份和"看 NPU 硬盘"放进
# "看 / 备份"子菜单 —— 它们平时用不到，不该占顶层。
set -u

PAYLOAD=${PAYLOAD:-$(cd "$(dirname "$0")" && pwd)}
STORE=${STORE:-/media/xgs87-bak}

if [ ! -f "$PAYLOAD/install-x86.sh" ]; then
	printf '\nXGS 87 维护盘：找不到 payload（%s 没有安装脚本？）\n' "$PAYLOAD"
	printf '先给你一个 shell，exit 之后会重新尝试菜单。\n\n'
	exec /bin/sh
fi
export PAYLOAD STORE

whiptail_menu() {
	# $1 标题  $2 提示文字  $3 高度  $4 宽度  $5 列表高度  $6.. "tag" "描述"
	_t=$1; _p=$2; _h=$3; _w=$4; _l=$5; shift 5
	if command -v whiptail >/dev/null 2>&1; then
		whiptail --title "$_t" --menu "$_p" "$_h" "$_w" "$_l" "$@" 3>&1 1>&2 2>&3
	else
		printf '\n%s\n%s\n\n' "$_t" "$_p" >&2
		while [ $# -gt 0 ]; do
			printf '  %-2s %s\n' "$1" "$2" >&2
			shift 2
		done
		printf '选择: ' >&2
		read -r _a || return 1
		printf '%s\n' "$_a"
	fi
}

store_state() {
	if findmnt -n -o TARGET "$STORE" >/dev/null 2>&1; then
		printf '备份区 %s：可用 %s' "$STORE" "$(df -h --output=avail "$STORE" | tail -1 | tr -d ' ')"
	else
		printf '备份区 %s：没准备好（U 盘没有剩余空间？）' "$STORE"
	fi
}

pause() {
	printf '\n按回车返回菜单...'
	read -r _
}

# ---- 子菜单：看 / 备份 ----
sub_peek() {
	while :; do
		c=$(whiptail_menu "看 / 备份" \
"$(store_state)

只读操作，随便点：" 20 78 8 \
			"1" "看状态：磁盘、vNTB 链路、NPU 在线、SSH" \
			"2" "备份 x86 内置盘 → 备份区" \
			"3" "备份 NPU 分区 → 备份区" \
			"4" "把 NPU 的 p2 挂成本机 /dev/nbd0（只读，可 fsck/mount/dd）" \
			"0" "返回") || return 0
		case "$c" in
		1) "$PAYLOAD/status.sh"; pause ;;
		2) "$PAYLOAD/backup-x86.sh"; pause ;;
		3) "$PAYLOAD/backup-npu.sh"; pause ;;
		4) "$PAYLOAD/npu-disk.sh"; pause ;;
		0 | "") return 0 ;;
		esac
	done
}

# ---- 顶层 ----
while :; do
	CHOICE=$(whiptail_menu "XGS 87 维护盘" \
"payload: $PAYLOAD
$(store_state)

选一个：" 20 78 6 \
		"1" "装 x86（写本机内置盘，会先问要不要备份）" \
		"2" "装 NPU（U-Boot → NBD → 急救，自动逐级尝试）" \
		"3" "看状态 / 备份 / 挂 NPU 硬盘" \
		"4" "NPU 串口控制台（含进 U-Boot）" \
		"5" "shell" \
		"0" "重启" \
		"9" "关机") || exit 0
	case "$CHOICE" in
	1) "$PAYLOAD/install-x86.sh" ;;
	2) "$PAYLOAD/install-npu.sh" ;;
	3) sub_peek ;;
	4) "$PAYLOAD/npu-console.sh" ;;
	5) /bin/sh ;;
	0) reboot ;;
	9) poweroff ;;
	esac
done