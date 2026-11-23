#!/bin/sh
# XGS 87 维护 U 盘的菜单。开机在串口控制台上跑，选完就执行，不做别的事。
set -u

PAYLOAD=${PAYLOAD:-$(cd "$(dirname "$0")" && pwd)}
STORE=${STORE:-/media/xgs87-bak}

if [ ! -f "$PAYLOAD/install-x86.sh" ]; then
	printf '\nXGS 87 维护盘：找不到 payload（%s 没有安装脚本？）\n' "$PAYLOAD"
	printf '先给你一个 shell，exit 之后会重新尝试菜单。\n\n'
	exec /bin/sh
fi
export PAYLOAD STORE

# 备份分区第一次开机才切，这里同步一下状态（挂上了就只是几次 stat）。
store_state() {
	if findmnt -n -o TARGET "$STORE" >/dev/null 2>&1; then
		printf '备份分区 %s：可用 %s' "$STORE" \
			"$(df -h --output=avail "$STORE" | tail -1 | tr -d ' ')"
	else
		printf '备份分区 %s：没准备好（U 盘没有剩余空间？）' "$STORE"
	fi
}

ask() {
	if command -v whiptail >/dev/null 2>&1; then
		whiptail --title "XGS 87 维护盘" --menu \
"payload: $PAYLOAD
$(store_state)

选择一个操作：" 22 78 11 \
			"1" "重装 x86：把 debian-x86.img 写进本机内置盘（整盘覆盖）" \
			"2" "重装 NPU：把 debian-npu.tar.zst 送到 NPU 的 root 分区（会先问要不要备份）" \
			"3" "查看状态：磁盘、vNTB 链路、NPU 是否在线" \
			"4" "备份 x86 内置盘到 U 盘的备份分区" \
			"6" "备份 NPU 分区到 U 盘的备份分区" \
			"7" "NPU 串口控制台（ttyS2，57600）—— NPU 起不来时从这里进" \
			"5" "shell（exit 返回菜单）" \
			"9" "关机" \
			"0" "重启" 3>&1 1>&2 2>&3
	else
		printf '\nXGS 87 维护盘  (payload: %s)\n' "$PAYLOAD" >&2
		printf '%s\n\n' "$(store_state)" >&2
		printf '  1 重装 x86    2 重装 NPU    3 状态\n' >&2
		printf '  4 备份 x86    6 备份 NPU    7 NPU 串口\n' >&2
		printf '  5 shell       9 关机       0 重启\n' >&2
		printf '选择: ' >&2
		read -r answer || return 1
		printf '%s\n' "$answer"
	fi
}
while :; do
	CHOICE=$(ask) || exit 0
	case "$CHOICE" in
	1) "$PAYLOAD/install-x86.sh" ;;
	2) "$PAYLOAD/install-npu.sh" ;;
	3) "$PAYLOAD/status.sh"; printf '\n按回车返回菜单...'; read -r _ ;;
	4) "$PAYLOAD/backup-x86.sh"; printf '\n按回车返回菜单...'; read -r _ ;;
	6) "$PAYLOAD/backup-npu.sh"; printf '\n按回车返回菜单...'; read -r _ ;;
	7) "$PAYLOAD/npu-console.sh" ;;
	5) /bin/sh ;;
	9) poweroff ;;
	0) reboot ;;
	esac
done