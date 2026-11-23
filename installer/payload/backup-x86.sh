#!/bin/sh
# 把 x86 的内置盘整盘备份到 U 盘。
#
#   ./backup-x86.sh [/dev/mmcblk0]
#
# 不带参数时自动挑"不是当前根所在"的那块盘。整盘 16 GB 的 eMMC 要 U 盘的
# payload 分区装得下才做得了，装不下就明说差多少，别假装能备份。
set -eu

PAYLOAD=${PAYLOAD:-$(cd "$(dirname "$0")" && pwd)}
SRC=${1:-}

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
AVAIL=$(df --output=avail -B1 "$PAYLOAD" | tail -1)
echo "内置盘 $SRC = $((SZ / 1024 / 1024)) MiB，U 盘剩余 $((AVAIL / 1024 / 1024)) MiB"
[ "$AVAIL" -gt "$SZ" ] || {
	echo "空间不够：整盘要 $((SZ / 1024 / 1024)) MiB，现在只有 $((AVAIL / 1024 / 1024)) MiB。" >&2
	echo "要整盘备份就用 ./installer/mkusb.sh ... --extra 16384 重做 U 盘，" >&2
	echo "或者把这块盘接到别的机器上 dd。" >&2
	exit 1
}

DEST=$PAYLOAD/backup-$(basename "$SRC")-$(date +%Y%m%d-%H%M).img.gz
echo "== 备份到 $DEST"
dd if="$SRC" bs=4M status=progress | gzip -1 > "$DEST"
sync
gzip -t "$DEST" || { echo "⚠️  备份文件校验失败，不要依赖它" >&2; exit 1; }
ls -lh "$DEST"
