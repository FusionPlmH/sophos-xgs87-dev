#!/bin/sh
# 把维护 U 盘上"镜像以外"的剩余空间做成一个 exfat 分区，挂到 /media/xgs87-bak。
#
#   /usr/local/sbin/xgs87-usbstore.sh          # 开机由 xgs87-usbstore.service 跑
#   STORE=/mnt/x ./xgs87-usbstore.sh           # 改挂载点（测试用）
#
# 为什么分区要等开机才切：U 盘多大只有插上才知道。镜像写到 32 GB 的盘上，
# 装完系统只占不到 2 GB，剩下的 30 GB 与其在构建时估一个 --extra，不如开机
# 再按实际大小切出来。
#
# 已经挂好就直接退出，所以备份脚本可以放心地先调它一下。
set -u

STORE=${STORE:-/media/xgs87-bak}
LABEL=${LABEL:-XGS87BAK}

if findmnt -n -o TARGET "$STORE" >/dev/null 2>&1; then
	exit 0
fi

ROOTSRC=$(findmnt -n -o SOURCE /)
DISK=${DISK:-/dev/$(lsblk -no pkname "$ROOTSRC" | head -1)}
if [ ! -b "$DISK" ]; then
	echo "xgs87-usbstore: 找不到 U 盘设备（/ 在 $ROOTSRC 上，不是块设备？）" >&2
	exit 0
fi

# 备份分区只切"维护 U 盘"。这个单元跟着镜像装进了内置盘，如果没有这道检查，
# 装好之后的系统每次开机都会在自己的 eMMC 尾部硬切一块出来当备份区 ——
# 空间白白丢掉，而且备份会写进自己盘里（2026-11 审查时发现）。
REMOVABLE=$(cat "/sys/block/$(basename "$DISK")/removable" 2>/dev/null || echo 0)
if [ "$REMOVABLE" != 1 ] && [ "${ALLOW_FIXED:-0}" != 1 ]; then
	echo "xgs87-usbstore: $DISK 不是可移动盘，跳过（备份分区只切 U 盘）" >&2
	exit 0
fi

case "$DISK" in
/dev/*[0-9]) PART="${DISK}p3" ;;
*)           PART="${DISK}3" ;;
esac

# dd 到更大的盘之后，GPT 的备份头还在镜像原来的末尾。先把它搬到盘尾，
# 否则内核认为"盘就只有镜像那么大"，后面那段空间切不出分区。
sgdisk -e "$DISK" >/dev/null 2>&1 || true

if [ ! -b "$PART" ]; then
	LAST=$(sfdisk -d "$DISK" |
		sed -n 's/.*start=[[:space:]]*\([0-9]*\), size=[[:space:]]*\([0-9]*\).*/\1 \2/p' |
		awk '{ if ($1 + $2 > m) m = $1 + $2 } END { print m + 0 }')
	TOTAL=$(blockdev --getsz "$DISK")
	START=$(( (LAST + 2047) / 2048 * 2048 ))
	# 盘尾留 2048 扇区（1 MiB）给 GPT 备份头
	SIZE=$(( TOTAL - 2048 - START ))

	if [ "$LAST" -le 0 ] || [ "$SIZE" -lt 131072 ]; then
		echo "xgs87-usbstore: U 盘没有剩余空间做备份分区（至少要 64 MiB）。"
		echo "xgs87-usbstore: 换一条比镜像更大的 U 盘就有空间了。"
		exit 0
	fi

	echo "xgs87-usbstore: 在 $DISK 上切出 $((SIZE / 2048)) MiB 给备份用"
	printf 'start=%s, size=%s, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="XGS87BAK"\n' \
		"$START" "$SIZE" | sfdisk --append --force "$DISK" >/dev/null || {
		echo "xgs87-usbstore: sfdisk 失败，备份功能不可用" >&2
		exit 0
	}
	partx -u "$DISK" 2>/dev/null || true
	udevadm settle --timeout=10 2>/dev/null || true
	i=0
	while [ ! -b "$PART" ] && [ "$i" -lt 50 ]; do
		i=$((i + 1))
		sleep 0.1
	done
fi

# 分区已经在但没文件系统（比如上次 mkfs 前掉电）：补一个。
if ! blkid -o value -s TYPE "$PART" 2>/dev/null | grep -q .; then
	mkfs.exfat -n "$LABEL" "$PART" >/dev/null || {
		echo "xgs87-usbstore: mkfs.exfat 失败（装了 exfatprogs 吗？）" >&2
		exit 0
	}
fi

mkdir -p "$STORE"
mount -o rw "$PART" "$STORE" || {
	echo "xgs87-usbstore: 挂不上 $PART" >&2
	exit 0
}
echo "xgs87-usbstore: $PART → $STORE（$(df -h --output=avail "$STORE" | tail -1 | tr -d " ") 可用）"