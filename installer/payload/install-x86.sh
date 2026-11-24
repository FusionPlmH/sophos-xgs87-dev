#!/bin/sh
# 把 U 盘里的 debian-x86.img 写进本机的内置盘。
#
# 关键点：认出"不是 U 盘的那块盘"。U 盘自己挂着 /（或 /run/live），
# 所以用 lsblk 找出承载当前根的盘，把它排除掉。
set -eu

PAYLOAD=${PAYLOAD:-$(cd "$(dirname "$0")" && pwd)}
. "$PAYLOAD/lib.sh"
IMG=$(ls "$PAYLOAD"/debian-x86.img.zst "$PAYLOAD"/debian-x86.img 2>/dev/null | head -1)
[ -n "$IMG" ] || { echo "找不到 $PAYLOAD/debian-x86.img（或 .img.zst）"; exit 1; }

# 镜像可能是压缩过的，也可能已经解开
xgs87_image_stream() {
	case "$IMG" in
	*.zst) zstd -dc "$IMG" ;;
	*) cat "$IMG" ;;
	esac
}

# 当前根所在的盘。名字必须统一成 /dev/xxx —— 否则下面"目标盘不能是系统盘"
# 的比较会永远为假，U 盘自己就会被当成目标盘写掉。
ROOTSRC=$(findmnt -n -o SOURCE /)
_rootdev=$(lsblk -no pkname "$ROOTSRC" 2>/dev/null | head -1)
case "$ROOTSRC" in
/dev/*) ;;
*) _rootdev=$(lsblk -no pkname "$(findmnt -n -o SOURCE /run 2>/dev/null || echo)" 2>/dev/null | head -1) ;;
esac
case "${_rootdev:-}" in
"") ROOTDISK="" ;;
/dev/*) ROOTDISK=$_rootdev ;;
*) ROOTDISK=/dev/$_rootdev ;;
esac
if [ -z "$ROOTDISK" ]; then
	echo "认不出当前系统所在的盘（/ 在 $ROOTSRC 上）—— 无法排除它，拒绝继续。" >&2
	echo "换一种方式启动维护系统，或用 TARGET=/dev/sdX 显式指定（风险自负）。" >&2
	exit 1
fi

echo "本机磁盘："
lsblk -dno NAME,SIZE,MODEL | sed 's/^/  /'
echo
echo "U 盘所在的盘：$ROOTDISK"
echo
echo "要写入的目标盘（不能是 $ROOTDISK）："
# 允许显式指定：TARGET=/dev/sda ./install-x86.sh   或   ./install-x86.sh /dev/sda
TARGET=${TARGET:-${1:-}}
if [ -z "$TARGET" ]; then
	_cands=""
	for d in /dev/sd? /dev/mmcblk? /dev/nvme?n?; do
		[ -e "$d" ] || continue
		[ "$d" = "$ROOTDISK" ] && continue
		_cands="$_cands $d"
	done
	# shellcheck disable=SC2086
	set -- $_cands
	if [ $# -eq 0 ]; then
		echo "找不到可写的目标盘"; exit 1
	elif [ $# -gt 1 ]; then
		echo "有多块候选盘，请显式指定：TARGET=/dev/sdX $0"
		for d in "$@"; do echo "  $d  ($(lsblk -dno SIZE,MODEL "$d" | tr -s ' '))"; done
		exit 1
	fi
	TARGET=$1
fi
[ "$TARGET" = "$ROOTDISK" ] && { echo "目标盘就是当前系统盘（$ROOTDISK），拒绝"; exit 1; }
# 整盘镜像只能写整盘：写到分区上会毁掉该分区却保留旧分区表
require_whole_disk "$TARGET"
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
# 先确认这是"整盘镜像"：LBA 0 末尾必须有 0x55AA。裸文件系统镜像（mkfs 出来的）
# 没有它 —— 那种镜像写到整盘会把分区表冲掉（2026-11-24 的砖机教训）。
_xgs87_mbr=$(xgs87_image_stream | dd bs=512 count=1 2>/dev/null | tail -c 2 | od -An -tx1 | tr -d ' \n')
[ "$_xgs87_mbr" = "55aa" ] || {
	echo "这份镜像的 LBA 0 没有 MBR 签名（读到 '${_xgs87_mbr:-空}'）——它不是整盘镜像，拒绝写整盘" >&2
	exit 1
}
xgs87_image_stream | dd of="$TARGET" bs=4M conv=fsync status=progress
sync
echo
if command -v sfdisk >/dev/null 2>&1; then
	if sfdisk -d "$TARGET" >/dev/null 2>&1; then
		echo "== 分区表回读正常"
	else
		echo "⚠️  分区表回读失败 —— 别急着重启，先检查这块盘" >&2
	fi
fi
echo "写完。拔掉 U 盘，重启即可。首次开机会自动把 root 分区扩到盘尾。"
echo "登录：admin / P@ssw0rd"
printf '按回车返回菜单...'
read -r _