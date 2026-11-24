#!/bin/sh
# 在 x86 上把 NPU 的硬盘挂成块设备（NBD），然后就能像本地盘一样 mount/fsck/dd。
#
#   ./npu-disk.sh            # 只读导出 /dev/mmcblk0p2 → x86 的 /dev/nbd0
#   ./npu-disk.sh --rw       # 读写导出（NPU 必须已经从别的系统启动，否则写坏）
#   ./npu-disk.sh /dev/mmcblk0p1
#
# 两台机器之间只有 PCIe(vNTB)，x86 没有任何办法直接摸到 eMMC 的控制器，
# 所以"直接读写"只能是 NPU 自己把块设备导出来（nbd-server），x86 这端接上
# （nbd-client）。走 vNTB 大约 1 Gbit/s，比 dd | ssh 稳，而且可以 fsck。
#
# 需要：NPU 上装了 nbd-server，x86 上装了 nbd-client、内核有 nbd 模块。
set -u
# shellcheck disable=SC2154
trap 'rc=$?; [ "$rc" = 0 ] || echo "$0: 退出码 $rc" >&2' EXIT

HERE=$(cd "$(dirname "$0")" && pwd)
PAYLOAD=${PAYLOAD:-$HERE}
. "$PAYLOAD/lib.sh"

# NBD 已在两个镜像里禁用（x86 不带 nbd-client、NPU 不带 nbd-server），
# 这一项现在跑不起来 —— 直接说清楚，别让它走一半再报 Permission denied。
if ! command -v nbd-client >/dev/null 2>&1; then
	echo "NBD 已禁用：这个镜像没有 nbd-client，NPU 镜像也没有 nbd-server。"
	echo "要用这一项，两个镜像都要把 NBD 装回来（详见图纸里的 NBD 一节）。"
	exit 1
fi

PORT=${PORT:-10809}
NBD=${NBD:-/dev/nbd0}

RW=0
PART=
for a in "$@"; do
	case "$a" in
	--rw) RW=1 ;;
	/dev/*) PART=$a ;;
	*) echo "用法：$0 [--rw] [/dev/mmcblk0p2]" >&2; exit 1 ;;
	esac
done
[ -n "$PART" ] || PART=/dev/mmcblk0p2

NPU=$(find_npu 10) || {
	echo "NPU 不可达（试过：$NPU_CANDIDATES）。先修链路，或者菜单选 2 / 7。" >&2
	exit 1
}

if [ "$RW" = 1 ]; then
	echo "⚠️  读写导出 $PART：NPU 现在如果正跑着它，文件系统会被写坏。"
	printf '确认 NPU 没有在使用 %s？（输入 RW）' "$PART"
	read -r ok
	[ "$ok" = RW ] || { echo "取消"; exit 1; }
fi

echo "== NPU（$NPU）上起 nbd-server 导出 $PART（$([ "$RW" = 1 ] && echo 读写 || echo 只读)）"
# 配置文件形式：命令行形式（nbd-server PORT FILE）在 3.2x 里固定是只读导出。
RO=$([ "$RW" = 1 ] && echo false || echo true)
npu_ssh "mkdir -p /etc/nbd-server
	cat > /etc/nbd-server/xgs87.conf <<INNER
[generic]
[xgs87]
exportname = $PART
readonly = $RO
port = $PORT
INNER
	pkill -f 'nbd-server -C /etc/nbd-server/xgs87.conf' 2>/dev/null || true
	setsid nbd-server -C /etc/nbd-server/xgs87.conf >/var/log/xgs87-nbd.log 2>&1 &
	sleep 2
	ss -ltn 2>/dev/null | grep -q ':$PORT ' && echo listening || { echo 没起来; cat /var/log/xgs87-nbd.log; }"
echo "== x86 这端接上"
modprobe nbd max_part=8 2>/dev/null || true
nbd-client -d "$NBD" 2>/dev/null || true
if [ "$RW" = 1 ]; then
	nbd-client -N xgs87 -p "$NPU" "$PORT" "$NBD" >/dev/null
else
	nbd-client -N xgs87 -r -p "$NPU" "$PORT" "$NBD" >/dev/null
fi

echo
echo "/dev/nbd0 = NPU 的 $PART（$([ "$RW" = 1 ] && echo 读写 || echo 只读)）"
echo
echo "  sudo mount -o ro $NBD /mnt      # 看看里面"
echo "  sudo fsck -n $NBD               # 检查文件系统"
echo "  sudo dd if=$NBD bs=4M | zstd > /media/xgs87-bak/npu-p2.img.zst"
echo
echo "用完断开："
echo "  sudo umount /mnt; sudo nbd-client -d $NBD"
echo "  ssh admin@$NPU 'sudo pkill -f nbd-server'"