#!/bin/sh
# 把 x86 的内置盘整盘读到 U 盘（空间不够就什么都不做）。
set -eu
PAYLOAD=${PAYLOAD:-$(cd "$(dirname "$0")" && pwd)}
DEST=$PAYLOAD/backup-$(date +%Y%m%d-%H%M).img.gz
ROOTSRC=$(findmnt -n -o SOURCE /)
ROOTDISK=/dev/$(lsblk -no pkname "$ROOTSRC" | head -1)
SRC=""
for d in /dev/sd? /dev/mmcblk? /dev/nvme?n?; do
	[ -e "$d" ] || continue
	[ "$d" = "$ROOTDISK" ] && continue
	SRC=$d
done
[ -n "$SRC" ] || { echo "找不到内置盘"; exit 1; }
SZ=$(blockdev --getsize64 "$SRC")
AVAIL=$(df --output=avail -B1 "$PAYLOAD" | tail -1)
echo "内置盘 $SRC = $((SZ/1024/1024)) MiB，U 盘剩余 $((AVAIL/1024/1024)) MiB"
[ "$AVAIL" -gt "$SZ" ] || { echo "空间不够，退出"; exit 1; }
dd if="$SRC" bs=4M status=progress | gzip -1 > "$DEST"
sync
ls -lh "$DEST"
printf '按回车返回菜单...'
read -r _