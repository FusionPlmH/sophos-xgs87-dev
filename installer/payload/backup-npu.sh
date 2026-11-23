#!/bin/sh
# 把 NPU 的一个分区整块备份到 U 盘的 payload 分区。
#
#   ./backup-npu.sh [/dev/mmcblk0p2]
#
# 数据流是 NPU → ssh → x86 → U 盘，NPU 上不需要额外空间，也不需要装 zstd。
# 目标分区正在使用（root 挂在上面）时读到的是崩溃一致（crash-consistent）的
# 镜像：文件系统会像断电一样需要 fsck，但用来回滚足够了。
set -eu

PAYLOAD=${PAYLOAD:-$(cd "$(dirname "$0")" && pwd)}
NPU=${NPU:-192.168.100.1}
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"

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

DEST=$PAYLOAD/npu-$(basename "$PART")-$(date +%Y%m%d-%H%M).img.gz

SZ=$($SSH "admin@$NPU" "sudo blockdev --getsize64 $PART") || {
	echo "读不到 $PART 的大小（NPU 上的 ssh/sudo 有问题？）" >&2
	exit 1
}
AVAIL=$(df --output=avail -B1 "$PAYLOAD" | tail -1)
echo "分区 $PART = $((SZ / 1024 / 1024)) MiB，U 盘剩余 $((AVAIL / 1024 / 1024)) MiB"
[ "$AVAIL" -gt "$SZ" ] || {
	echo "空间不够：至少要 $((SZ / 1024 / 1024)) MiB 空闲，现在只有 $((AVAIL / 1024 / 1024)) MiB。" >&2
	echo "重做 U 盘时把这个分区做大，例如 ./installer/mkusb.sh ... --extra 2048" >&2
	exit 1
}

echo "== 开始备份到 $DEST"
$SSH "admin@$NPU" "sudo dd if=$PART bs=4M" | gzip -1 > "$DEST"
sync
gzip -t "$DEST" || { echo "⚠️  备份文件 gzip 校验失败，不要依赖它" >&2; exit 1; }
ls -lh "$DEST"
echo "备份完成（$(( $(stat -c %s "$DEST") / 1024 / 1024 )) MiB 压缩后）"
