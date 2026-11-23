#!/bin/sh
# 把 debian-npu.tar.zst 装到 NPU 的 root 分区。
#
#   A. NPU 还能启动到 Debian：通过 vNTB 链路直接推过去（最省事）
#   B. NPU 起不来：起一个 HTTP 服务，从 x86 的 ttyS2 控制台在 NPU 上手动拉
#
# 注意：x86 摸不到 NPU 的 eMMC，所有写入都是在 NPU 上执行的。
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
TAR=$HERE/../debian-npu.tar.zst
DTB=$(ls "$HERE"/../cn9130-sophos-xgs87w-sfp10g*.dtb 2>/dev/null | head -1)
[ -f "$TAR" ] || { echo "找不到 debian-npu.tar.zst"; exit 1; }

echo "== 先把 vNTB 链路拉起来（U 盘的 x86 系统里就有这些单元）"
systemctl start xgs-ntb xgs-ntb-watch 2>/dev/null || true
for i in $(seq 1 30); do
	ping -c1 -W1 192.168.100.1 >/dev/null 2>&1 && break
	sleep 1
done

if ping -c1 -W1 192.168.100.1 >/dev/null 2>&1; then
	echo "== NPU 在线，直接推过去（走 vNTB，约 1 Gbit/s）"
	read -r -p "目标分区 [/dev/mmcblk0p2]: " PART
	PART=${PART:-/dev/mmcblk0p2}
	echo "⚠️  会 mkfs.ext4 $PART 并解包，NPU 上原有的东西会没。"
	printf '输入 YES 继续：'
	read -r ok
	[ "$ok" = YES ] || exit 1

	cat "$TAR" | ssh admin@192.168.100.1 '
		set -e
		cat > /tmp/debian-npu.tar.zst
		sudo umount /mnt 2>/dev/null || true
		sudo mkfs.ext4 -q -L xgsroot '"$PART"'
		sudo mount '"$PART"' /mnt
		sudo tar -xpf /tmp/debian-npu.tar.zst -C /mnt
		sudo mkdir -p /mnt/boot
		sudo tee /mnt/boot/cn9130-sophos-xgs87w-sfp10g.dtb >/dev/null
		sync
		sudo umount /mnt
		echo done
	' < /dev/stdin
	echo "NPU 写完了，reboot 它即可。"
else
	echo "== NPU 不可达。起 HTTP 服务，从 NPU 的控制台手动装："
	ADDR=$(ip -4 -br a show eth0.100 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
	ADDR=${ADDR:-192.168.100.2}
	PORT=8080
	cd "$HERE/.."
	echo
	echo "  在 x86 上已经跑起：  python3 -m http.server $PORT --bind $ADDR"
	echo "  然后在 NPU 控制台（x86 的 /dev/ttyS2，57600）里执行："
	echo
	echo "    wget http://$ADDR:$PORT/debian-npu.tar.zst -O /tmp/x.tar.zst"
	echo "    mkfs.ext4 -L xgsroot /dev/mmcblk0p2"
	echo "    mount /dev/mmcblk0p2 /mnt && tar -xpf /tmp/x.tar.zst -C /mnt"
	echo "    cp /tmp/cn9130-*.dtb /mnt/boot/ && umount /mnt && reboot"
	echo
	echo "  DTB 也在同一个目录下。按 Ctrl-C 结束服务。"
	exec python3 -m http.server "$PORT" --bind "$ADDR"
fi