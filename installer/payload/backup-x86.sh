#!/bin/sh
# 把 x86 的内置盘整盘备份到 U 盘的 exfat 备份分区。
#
#   ./backup-x86.sh [/dev/mmcblk0]
#
# 不带参数时自动挑"不是当前根所在"的那块盘。整盘 16 GB 的 eMMC 要备份分区装得下
# 才做得了，装不下就明说差多少，别假装能备份。
set -eu

PAYLOAD=${PAYLOAD:-$(cd "$(dirname "$0")" && pwd)}
. "$PAYLOAD/lib.sh"
SRC=${1:-}

STORE=$(ensure_store) || {
	echo "U 盘上没有可用的备份分区（/media/xgs87-bak 没挂上）。" >&2
	echo "它由 xgs87-usbstore.service 在首次开机时切出来；" >&2
	echo "手动跑一次： sudo /usr/local/sbin/xgs87-usbstore.sh" >&2
	exit 1
}

if [ -z "$SRC" ]; then
	ROOTSRC=$(findmnt -n -o SOURCE /)
	ROOTDISK=/dev/$(lsblk -no pkname "$ROOTSRC" | head -1)
	for d in /dev/sd? /dev/mmcblk? /dev/nvme?n?; do
		[ -e "$d" ] || continue
		[ "$d" = "$ROOTDISK" ] && continue
		SRC=$d
	done
fi
[ -n "$SRC" ] || { echo "找不到内置盘" >&2; exit 1; }
case "$SRC" in
/dev/*) ;;
*) echo "盘要写 /dev/... 的绝对路径" >&2; exit 1 ;;
esac

SZ=$(blockdev --getsize64 "$SRC")
AVAIL=$(df --output=avail -B1 "$STORE" | tail -1)
echo "内置盘 $SRC = $((SZ / 1024 / 1024)) MiB，备份分区剩余 $((AVAIL / 1024 / 1024)) MiB"
[ "$AVAIL" -gt "$SZ" ] || {
	echo "空间不够：整盘要 $((SZ / 1024 / 1024)) MiB，现在只有 $((AVAIL / 1024 / 1024)) MiB。" >&2
	echo "换一条更大的 U 盘（剩余空间 = U 盘容量 - 镜像大小），或者把这块盘接到别的机器上 dd。" >&2
	exit 1
}

DEST=$STORE/x86-$(basename "$SRC")-$(date +%Y%m%d-%H%M).img.gz
echo "== 备份到 $DEST"
dd if="$SRC" bs=4M status=progress | gzip -1 > "$DEST"
sync
gzip -t "$DEST" || { echo "⚠️  备份文件校验失败，不要依赖它" >&2; exit 1; }
ls -lh "$DEST"