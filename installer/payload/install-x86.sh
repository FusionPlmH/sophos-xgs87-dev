#!/bin/sh
# 把 U 盘里的 debian-x86.img 写进本机的内置盘。
#
# 关键点：认出"不是 U 盘的那块盘"。U 盘自己挂着 /（或 /run/live），
# 所以用 lsblk 找出承载当前根的盘，把它排除掉。
set -eu

PAYLOAD=${PAYLOAD:-$(cd "$(dirname "$0")" && pwd)}
. "$PAYLOAD/lib.sh"
IMG=$(ls "$PAYLOAD"/debian-x86.img.zst 2>/dev/null | head -1)
[ -n "$IMG" ] || { echo "找不到 $PAYLOAD/debian-x86.img.zst"; exit 1; }

# 当前根所在的盘
ROOTSRC=$(findmnt -n -o SOURCE /)
ROOTDISK=/dev/$(lsblk -no pkname "$ROOTSRC" | head -1)
case "$ROOTSRC" in
/dev/*) ;;
*) ROOTDISK=$(lsblk -no pkname "$(findmnt -n -o SOURCE /run 2>/dev/null || echo)" 2>/dev/null | head -1) ;;
esac

echo "本机磁盘："
lsblk -dno NAME,SIZE,MODEL | sed 's/^/  /'
echo
echo "U 盘所在的盘：$ROOTDISK"
echo
echo "要写入的目标盘（不能是 $ROOTDISK）："
TARGET=""
for d in /dev/sd? /dev/mmcblk? /dev/nvme?n?; do
	[ -e "$d" ] || continue
	[ "$d" = "$ROOTDISK" ] && continue
	TARGET=$d
done
[ -n "$TARGET" ] || { echo "找不到可写的目标盘"; exit 1; }
echo "  $TARGET  ($(lsblk -dno SIZE,MODEL "$TARGET" | tr -s ' '))"
echo
printf '要先把 %s 备份到 U 盘吗？[y/N] ' "$TARGET"
read -r bk
case "${bk:-n}" in
y | Y)
	if ! "$PAYLOAD/backup-x86.sh" "$TARGET"; then
		printf '\n备份没成功。仍然整盘覆盖 %s（原有系统会没）？输入 YES：' "$TARGET"
		read -r go2
		[ "$go2" = YES ] || { echo "取消"; exit 1; }
	fi
	;;
esac
echo
printf '确认把 %s 整盘覆盖成 debian-x86？输入 YES 继续：' "$TARGET"
read -r ok
[ "$ok" = YES ] || { echo "取消"; exit 1; }

echo "== 解压并写入（这一步不能断电）"
zstd -dc "$IMG" | dd of="$TARGET" bs=4M conv=fsync status=progress
sync
echo
echo "写完。拔掉 U 盘，重启即可。首次开机会自动把 root 分区扩到盘尾。"
echo "登录：admin / P@ssw0rd"
printf '按回车返回菜单...'
read -r _