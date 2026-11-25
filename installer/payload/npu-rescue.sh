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

# 这台 U-Boot 的 factory env 里**没有** loadaddr（`loady $loadaddr` 直接报
# "not defined"），另外 initramfs 不能原地解压 —— gzip 的输出涨得比输入消费得
# 快，`unzip $ramdisk_addr_r $ramdisk_addr_r` 会用输出踩掉还没读的输入。
# 所以三个地址写死，都是 2026-11-25 在真机上跑通的（DRAM 0x0–0x80000000，
# kernel_addr_r=0x07000000 / ramdisk_addr_r=0x0A000000 / fdt_addr_r=0x06F00000）：
#   Image.gz    0x02000000（13.7 MB）→ 解压到 kernel_addr_r（37.7 MB）
#   initramfs.gz ramdisk_addr_r（2.2 MB）→ 解压到 0x20000000（3.4 MB）
SCRATCH_KERNEL_GZ=0x02000000
INITRD_RAW=0x20000000

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
if ! serial_read_until "$UBOOT_PROMPT" 10 "$UBOOT_PROMPT_ALT"; then
	echo "   没停住（NPU 已经进系统了？）"
	return 1
fi

# 只有这三样要过串口；kernel 能用 p2 里现成的就不推（13.7 MB 是整个包的大头）。
# 包里的模块版本 = initramfs 里 /lib/modules 下那个目录名
KVER=$(zcat "$WORK/initramfs.gz" 2>/dev/null | cpio -t 2>/dev/null | sed -n 's#^lib/modules/\([^/]*\)/.*#\1#p' | head -1)

echo "== 4/6 先看 p2 里有没有能直接用的 kernel"
USE_P2_KERNEL=0
if [ -n "$KVER" ]; then
	p2kver=$(serial_uboot 'ext4ls mmc 0:2 /usr/lib/modules' 25 |
		grep -o "$KVER" | head -1)
	[ -n "$p2kver" ] || p2kver=$(serial_uboot 'ext4ls mmc 0:2 /lib/modules' 25 |
		grep -o "$KVER" | head -1)
	if [ -n "$p2kver" ]; then
		echo "   p2 里有 $KVER 的模块，可以少推 13.7 MB"
		if serial_uboot 'ext4load mmc 0:2 $kernel_addr_r /boot/Image' 120 | grep -q 'bytes read'; then
			USE_P2_KERNEL=1
		elif serial_uboot "ext4load mmc 0:2 $SCRATCH_KERNEL_GZ /boot/vmlinuz-$KVER" 60 | grep -q 'bytes read' &&
			serial_uboot "unzip $SCRATCH_KERNEL_GZ \$kernel_addr_r" 120 | grep -q 'Uncompressed size'; then
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
	# loady 由 ymodem.py 自己敲：它要先排空残留的 'C'，再核对 U-Boot 打出来的
	# "download to <addr>"。以前这里先敲 loady、只等 1 秒就去发文件头，串口里
	# 上一次 loady 留下的 'C' 会让数据落到旧地址（2026-11-25 实测踩过）。
	python3 "$PAYLOAD/ymodem.py" --addr "$_addr" "$TTY" "$WORK/$_n" || return 1
	serial_read_until "$UBOOT_PROMPT" 20 "$UBOOT_PROMPT_ALT" || true
}
d=$(ls "$WORK"/cn9130-*.dtb 2>/dev/null | head -1)
cp "$d" "$WORK/xgs87.dtb"
push xgs87.dtb '$fdt_addr_r' || { echo "   DTB 推失败"; return 1; }
# initramfs 放最后：booti 要的 $filesize 是它的大小
push initramfs.gz '$ramdisk_addr_r' || { echo "   initramfs.gz 推失败"; return 1; }
serial_uboot 'setenv rd_size ${filesize}' 3 >/dev/null || true
serial_uboot "unzip \$ramdisk_addr_r $INITRD_RAW; setenv rd_size \${filesize}" 90 >/dev/null ||
	{ echo "   unzip initramfs 失败"; return 1; }
# 把解压后的大小**读成字面量**再用。`booti ...:${rd_size}` 一旦在那里被别的东西
# 展开成空值，U-Boot 会把 initrd 放到 0x80000000（DRAM 之外），内核一个字符都
# 不打就死 —— 2026-11-25 踩过，排查了很久。
RD_SIZE=$(serial_uboot 'printenv filesize' 10 | sed -n 's/^filesize=//p' | tr -d '\r' | head -1)
case "$RD_SIZE" in
[0-9a-fA-F]*) ;;
*) echo "   读不出 unzip 之后的大小（filesize），不往下走"; return 1 ;;
esac
echo "   initramfs 解压后 $((0x$RD_SIZE)) 字节"
if [ "$USE_P2_KERNEL" != 1 ]; then
	# 内核在包里可能是 Image.gz 也可能是 Image.lzma（build-rescue.sh --kernel-fmt）
	KIMG=$(ls "$WORK"/Image.gz "$WORK"/Image.lzma 2>/dev/null | head -1)
	[ -n "$KIMG" ] || { echo "   包里没有 Image.gz / Image.lzma"; return 1; }
	push "${KIMG##*/}" "$SCRATCH_KERNEL_GZ" || { echo "   内核推失败"; return 1; }
	serial_uboot "unzip $SCRATCH_KERNEL_GZ \$kernel_addr_r" 120 >/dev/null || { echo "   unzip kernel 失败"; return 1; }
fi

echo "== 6/6 启动"
serial_uboot "setenv bootargs 'console=ttyS0,115200n8 earlycon=uart8250,mmio32,0xf0512000 rescue.url=http://10.234.56.2:$PORT/$IMG_NAME rescue.part=/dev/mmcblk0p2 rescue.ip=10.234.56.1/24'" 15 >/dev/null || true
serial_uboot "booti \$kernel_addr_r $INITRD_RAW:0x$RD_SIZE \$fdt_addr_r" 20 >/dev/null || true

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