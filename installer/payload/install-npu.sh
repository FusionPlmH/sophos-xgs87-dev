#!/bin/sh
# 把 debian-npu.tar.zst 装到 NPU 的 root 分区。
#
#   A. NPU 还能启动到 Debian：通过 vNTB 链路直接推过去（最省事）
#   B. NPU 起不来：起一个 HTTP 服务，从 x86 的 ttyS2 控制台在 NPU 上手动拉
#
# 注意：x86 摸不到 NPU 的 eMMC，所有写入都是在 NPU 上执行的。
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
PAYLOAD=${PAYLOAD:-$HERE}
TAR=$PAYLOAD/debian-npu.tar.zst
DTB=$(ls "$PAYLOAD"/cn9130-sophos-xgs87w-sfp10g*.dtb 2>/dev/null | head -1)
NPU=${NPU:-192.168.100.1}
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"

[ -f "$TAR" ] || { echo "找不到 debian-npu.tar.zst"; exit 1; }
[ -n "$DTB" ] || { echo "找不到 DTB"; exit 1; }

echo "== 先把 vNTB 链路拉起来（U 盘的 x86 系统里就有这些单元）"
systemctl start xgs-ntb xgs-ntb-watch 2>/dev/null || true
for _ in $(seq 1 30); do
	ping -c1 -W1 "$NPU" >/dev/null 2>&1 && break
	sleep 1
done

if ping -c1 -W1 "$NPU" >/dev/null 2>&1; then
	echo "== NPU 在线，直接推过去（走 vNTB，约 1 Gbit/s）"
	printf '目标分区 [/dev/mmcblk0p2]: '
	read -r PART
	PART=${PART:-/dev/mmcblk0p2}
	case "$PART" in
	/dev/*) ;;
	*) echo "分区要写 /dev/... 的绝对路径"; exit 1 ;;
	esac
	echo "⚠️  会 mkfs.ext4 $PART 并解包，NPU 上原有的东西会没。"
	printf '先在 U 盘上备份 %s 吗？[Y/n] ' "$PART"
	read -r bk
	case "${bk:-y}" in
	y | Y) "$HERE/backup-npu.sh" "$PART" || {
		echo "备份没成功，已中止 —— 没有格式化任何东西。"
		exit 1
	} ;;
	esac
	printf '输入 YES 继续：'
	read -r ok
	[ "$ok" = YES ] || exit 1

	echo "== 1/3 建文件系统并挂到 /mnt"
	$SSH "admin@$NPU" "sudo umount /mnt 2>/dev/null || true
		sudo mkfs.ext4 -q -L xgsroot $PART
		sudo mount $PART /mnt
		echo mounted"

	echo "== 2/3 解包（在 x86 上解压，NPU 不需要装 zstd）"
	zstd -dc "$TAR" | $SSH "admin@$NPU" 'sudo tar -xpf - -C /mnt'

	echo "== 3/3 放 DTB、收尾"
	cat "$DTB" | $SSH "admin@$NPU" \
		'sudo mkdir -p /mnt/boot
		 sudo tee /mnt/boot/cn9130-sophos-xgs87w-sfp10g.dtb >/dev/null
		 sync
		 sudo umount /mnt
		 echo done'

	echo
	echo "NPU 写完了，reboot 它即可（或者选 0 重启整机）。"
	printf '按回车返回菜单...'
	read -r _
else
	echo "== NPU 不可达。起 HTTP 服务，从 NPU 的控制台手动装："
	# 别假设地址：vNTB 链路没起来时 eth0.100 根本不存在，bind 会失败
	# （OSError: Cannot assign requested address）。
	ADDR=$(ip -4 -br a show up 2>/dev/null |
		awk '$1 != "lo" && $3 ~ /^[0-9]/ { print $3 }' | cut -d/ -f1 | head -1)
	PORT=${PORT:-8080}
	if [ -z "$ADDR" ]; then
		echo
		echo "⚠️  x86 现在没有任何 IPv4 地址 —— vNTB 链路大概没起来。"
		echo "    ip -br a            看接口"
		echo "    systemctl status xgs-ntb xgs-ntb-watch"
		echo "    链路起来后重选本项即可；实在不行可以："
		echo "      cd $PAYLOAD && python3 -m http.server $PORT --bind 0.0.0.0"
		exit 1
	fi
	cd "$PAYLOAD"
	echo
	echo "  x86 上已经跑起：  python3 -m http.server $PORT --bind $ADDR"
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