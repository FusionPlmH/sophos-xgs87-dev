#!/bin/sh
# 把 NPU 的一个分区整块备份到 U 盘的 exfat 备份分区。
#
#   ./backup-npu.sh [/dev/mmcblk0p2]
#
# 数据流是 NPU → ssh → x86 → U 盘，NPU 上不需要额外空间，也不需要装 zstd。
# 目标分区正在使用（root 挂在上面）时读到的是崩溃一致（crash-consistent）的
# 镜像：文件系统会像断电一样需要 fsck，但用来回滚足够了。
set -eu

PAYLOAD=${PAYLOAD:-$(cd "$(dirname "$0")" && pwd)}
. "$PAYLOAD/lib.sh"
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"

STORE=$(ensure_store) || {
	echo "U 盘上没有可用的备份分区（/media/xgs87-bak 没挂上）。" >&2
	echo "它由 xgs87-usbstore.service 在首次开机时切出来；" >&2
	echo "手动跑一次： sudo /usr/local/sbin/xgs87-usbstore.sh" >&2
	exit 1
}

NPU=$(find_npu 10) || {
	echo "NPU 不可达（试过：$NPU_CANDIDATES）。vNTB 链路起来了吗？" >&2
	exit 1
}

PART=${1:-}
[ -n "$PART" ] || {
	printf '要备份的 NPU 分区 [/dev/mmcblk0p2]: '
	read -r PART
	PART=${PART:-/dev/mmcblk0p2}
}
case "$PART" in
/dev/*) ;;
*) echo "分区要写 /dev/... 的绝对路径" >&2; exit 1 ;;
esac

DEST=$STORE/npu-$(basename "$PART")-$(date +%Y%m%d-%H%M).img.gz

SZ=$($SSH "admin@$NPU" "sudo blockdev --getsize64 $PART") || {
	echo "读不到 $PART 的大小（NPU 上的 ssh/sudo 有问题？）" >&2
	exit 1
}
AVAIL=$(df --output=avail -B1 "$STORE" | tail -1)
echo "分区 $PART = $((SZ / 1024 / 1024)) MiB，备份分区剩余 $((AVAIL / 1024 / 1024)) MiB"
[ "$AVAIL" -gt "$SZ" ] || {
	echo "空间不够：至少要 $((SZ / 1024 / 1024)) MiB 空闲，现在只有 $((AVAIL / 1024 / 1024)) MiB。" >&2
	echo "换一条更大的 U 盘（剩余空间 = U 盘容量 - 镜像大小）。" >&2
	exit 1
}

echo "== 开始备份到 $DEST"
$SSH "admin@$NPU" "sudo dd if=$PART bs=4M" | gzip -1 > "$DEST"
sync
gzip -t "$DEST" || { echo "⚠️  备份文件 gzip 校验失败，不要依赖它" >&2; exit 1; }
ls -lh "$DEST"
echo "备份完成（$(( $(stat -c %s "$DEST") / 1024 / 1024 )) MiB 压缩后）"