#!/bin/sh
# 最后一级：急救 initramfs。串口推十几 MB 进 U-Boot，起来把 vNTB 拉通，
# 再让 x86 用 HTTP 把 p2 的整盘影像写进去。
#
# 只在前面所有路都走不通时用（NPU 起不来 + 没有 USB 网卡）。慢，但只需要
# U-Boot 活着 —— 这是唯一不依赖 NPU 任何用户态的路。
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
PAYLOAD=${PAYLOAD:-$HERE}
RESCUE=$PAYLOAD/xgs87-rescue.tar.zst
TAR=$PAYLOAD/debian-npu.tar.zst
. "$PAYLOAD/lib.sh"
TTY=${SERIAL:-/dev/ttyS2}
BAUD=${BAUD:-115200}
IMG_NAME=p2.img
PORT=${PORT:-8080}

[ -f "$RESCUE" ] || { echo "没有 $RESCUE（构建 U 盘时要带 --rescue）"; return 1; }
[ -f "$TAR" ] || { echo "找不到 debian-npu.tar.zst"; return 1; }

STORE=$(ensure_store) || { echo "备份区没挂上，整盘影像没地方放"; return 1; }
WORK=$STORE/rescue
mkdir -p "$WORK"

echo "== 1/6 解开急救包"
tar --zstd -xf "$RESCUE" -C "$WORK" || return 1
ls -lh "$WORK" | sed 's/^/   /'

echo "== 2/6 准备要写的整盘影像（和 p2 等大，含根文件系统）"
IMG=$WORK/$IMG_NAME
if [ ! -f "$IMG" ]; then
	# p2 的大小只有上机才知道；这里用一个稳妥的上限，写的时候按实际大小裁。
	truncate -s "${IMG_MB:-1536}M" "$IMG" || return 1
	mkfs.ext4 -q -F -L xgsroot "$IMG" || return 1
	mkdir -p /tmp/xgs87-rescuemnt
	mount -o loop "$IMG" /tmp/xgs87-rescuemnt || return 1
	zstd -dc "$TAR" | tar -xpf - -C /tmp/xgs87-rescuemnt || { umount /tmp/xgs87-rescuemnt; return 1; }
	d=$(ls "$WORK"/cn9130-*.dtb 2>/dev/null | head -1)
	[ -n "$d" ] && { mkdir -p /tmp/xgs87-rescuemnt/boot; cp "$d" /tmp/xgs87-rescuemnt/boot/cn9130-sophos-xgs87w-sfp10g.dtb; }
	materialize_boot_names /tmp/xgs87-rescuemnt || true
	sync; umount /tmp/xgs87-rescuemnt
fi
echo "   $(du -h "$IMG" | cut -f1)"

echo "== 3/6 让 NPU 停在 U-Boot"
stty -F "$TTY" "$BAUD" raw -echo 2>/dev/null || true
TTY=$TTY BAUD=$BAUD INTERACTIVE=0 sh "$PAYLOAD/npu-uboot.sh" || return 1
TTY=$TTY BAUD=$BAUD . "$PAYLOAD/serial.sh" || return 1
if ! serial_read_until "=> " 10; then
	echo "   没停住（NPU 已经进系统了？）"
	return 1
fi

# 只有这三样要过串口；kernel 能用 p2 里现成的就不推（13.7 MB 是整个包的大头）。
# 包里的模块版本 = initramfs 里 /lib/modules 下那个目录名
KVER=$(zcat "$WORK/initramfs.gz" 2>/dev/null | cpio -t 2>/dev/null | sed -n 's#^lib/modules/\([^/]*\)/.*#\1#p' | head -1)

echo "== 4/6 先看 p2 里有没有能直接用的 kernel"
USE_P2_KERNEL=0
if [ -n "$KVER" ]; then
	p2kver=$(serial_run 'ext4ls mmc 0:2 /usr/lib/modules' 20 2>/dev/null |
		grep -o "$KVER" | head -1)
	[ -n "$p2kver" ] || p2kver=$(serial_run 'ext4ls mmc 0:2 /lib/modules' 20 2>/dev/null |
		grep -o "$KVER" | head -1)
	if [ -n "$p2kver" ]; then
		echo "   p2 里有 $KVER 的模块，可以少推 13.7 MB"
		if serial_run 'ext4load mmc 0:2 $kernel_addr_r /boot/Image' 120 >/dev/null 2>&1 ||
			{ serial_run 'ext4load mmc 0:2 $loadaddr /boot/vmlinuz-'$KVER 60 >/dev/null 2>&1 &&
			  serial_run 'unzip $loadaddr $kernel_addr_r' 120 >/dev/null 2>&1; }; then
			USE_P2_KERNEL=1
		fi
	fi
fi
[ "$USE_P2_KERNEL" = 1 ] || echo "   p2 里没有，得自己推 Image.gz（13.7 MB，慢的就是这段）"

echo "== 5/6 串口推 DTB + initramfs$([ "$USE_P2_KERNEL" = 1 ] || echo ' + Image.gz')（$BAUD）"
stty -F "$TTY" "$BAUD" raw -echo -crtscts 2>/dev/null || true
push() {
	_n=$1; _addr=$2
	echo "   loady $_addr  ← $_n"
	serial_run "loady $_addr" 3 >/dev/null 2>&1 || true   # 让 U-Boot 打出 "Ready for binary (ymodem) ..."
	python3 "$PAYLOAD/ymodem.py" "$TTY" "$WORK/$_n" || return 1
	serial_read_until "=> " 20 || true
}
d=$(ls "$WORK"/cn9130-*.dtb 2>/dev/null | head -1)
cp "$d" "$WORK/xgs87.dtb"
push xgs87.dtb '$fdt_addr_r' || { echo "   DTB 推失败"; return 1; }
# initramfs 放最后：booti 要的 $filesize 是它的大小
push initramfs.gz '$ramdisk_addr_r' || { echo "   initramfs.gz 推失败"; return 1; }
serial_run 'setenv rd_size ${filesize}' 10 >/dev/null || true
serial_run 'unzip $ramdisk_addr_r $ramdisk_addr_r; setenv rd_size ${filesize}' 90 >/dev/null ||
	{ echo "   unzip initramfs 失败"; return 1; }
if [ "$USE_P2_KERNEL" != 1 ]; then
	push Image.gz '$loadaddr' || { echo "   Image.gz 推失败"; return 1; }
	serial_run 'unzip $loadaddr $kernel_addr_r' 120 >/dev/null || { echo "   unzip kernel 失败"; return 1; }
fi

echo "== 6/6 启动"
serial_run "setenv bootargs 'console=ttyS0,115200n8 earlycon=uart8250,mmio32,0xf0512000 rescue.url=http://10.234.56.2:$PORT/$IMG_NAME rescue.part=/dev/mmcblk0p2 rescue.ip=10.234.56.1/24'" 15 >/dev/null || true
serial_run "booti \$kernel_addr_r \$ramdisk_addr_r:\${rd_size} \$fdt_addr_r" 20 >/dev/null || true

echo "== 等急救系统把 eth0 拉起来，然后喂它整盘影像"
# vNTB 起来之前 x86 是没有地址的；先等 NTB netdev 出现，再给裸 eth0 配一个。
i=0
while [ ! -e /sys/class/net/eth0 ] && [ "$i" -lt 60 ]; do
	i=$((i + 1))
	sleep 1
done
[ -e /sys/class/net/eth0 ] || { echo "   60 s 内 eth0 没出现（vNTB 没起来）"; return 1; }
ip link set eth0 up 2>/dev/null || true
ip addr show dev eth0 | grep -q ' 10.234.56.2/' || ip addr add 10.234.56.2/24 dev eth0
cd "$WORK" || return 1
echo "   HTTP 服务：http://10.234.56.2:$PORT/$IMG_NAME"
echo "   串口日志会显示 rescue: 开头的进度（下载 + dd 大约 1-2 分钟）"
echo "   Ctrl-C 可以中断（中断后 NPU 停在急救 shell 里，还能手动 wget/dd）"
exec python3 -m http.server "$PORT" --bind 10.234.56.2