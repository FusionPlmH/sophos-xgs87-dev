#!/bin/sh
# 用 NPU 自己的 U-Boot 把 rootfs 写进 p2：ext4 影像 → tftpboot → mmc write。
#
# 关键前提（也是这条路的要害）：**NPU 停在 U-Boot 时，vNTB 是断的** —— 也就是
# 说 x86 自己那两条 VLAN 全没了。数据只能走"物理旁路"：
#
#     x86 的 USB 网卡 ── 网线 ── 面板口 ── 交换机 ── NPU 的 end0
#
# 所以脚本**先确认有网卡、有影像空间，才去停 NPU**；没有网卡就直接退出，免得
# 把机器停在"NPU 在 U-Boot、x86 又没网"的死角里（那就只剩串口几小时一条路）。
#
# 参数：--keep-image 复用 /media/xgs87-bak/xgs87-p2.img
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
PAYLOAD=${PAYLOAD:-$HERE}
TAR=$PAYLOAD/debian-npu.tar.zst
DTB=$(ls "$PAYLOAD"/cn9130-sophos-xgs87w-sfp10g*.dtb 2>/dev/null | head -1)
. "$PAYLOAD/lib.sh"
TTY=${SERIAL:-/dev/ttyS2}
IMG_NAME=xgs87-p2.img
NET_PREFIX=${NET_PREFIX:-192.168.77}
KEEP=0
[ "${1:-}" = "--keep-image" ] && KEEP=1

[ -f "$TAR" ] || { echo "找不到 debian-npu.tar.zst"; return 1; }
[ -n "$DTB" ] || { echo "找不到 DTB"; return 1; }

# ---------------------------------------------------------------- 预检 ---
# 1) 物理网口：x86 自己没有网口，得有一条"有载波、又不是 vNTB"的链路
NIC=${NIC:-}
if [ -z "$NIC" ]; then
	for i in /sys/class/net/*; do
		i=${i##*/}
		case "$i" in lo|eth0|eth0.*|br-*|dummy*) continue ;; esac
		[ "$(cat "/sys/class/net/$i/carrier" 2>/dev/null)" = 1 ] && { NIC=$i; break; }
	done
fi
if [ -z "${NIC:-}" ]; then
	echo "没有可用的物理网口 —— U-Boot 那条路走不了。"
	echo "  NPU 停在 U-Boot 时 vNTB 是断的，x86 只能靠 USB 网卡插面板口才有网。"
	echo "  现在的接口：$(ls /sys/class/net | tr '\n' ' ')"
	echo "  插好 USB 网卡（面板口 1/2/3/4 任意一个）再重试；否则只能走急救 initramfs。"
	return 1
fi
x86_ip=$NET_PREFIX.1
echo "== 0/6 预检通过：数据走 $NIC（$x86_ip）→ 面板口 → NPU end0"

# 2) 影像要有地方放
STORE=$(ensure_store) || {
	echo "   备份区没挂上 —— 影像（约 1.5 GiB）没地方放，先解决 U 盘空间再试。"
	return 1
}

echo "== 1/6 让 NPU 停在 U-Boot（这期间 x86 的 vNTB 会断，串口不受影响）"
TTY=$TTY INTERACTIVE=0 sh "$PAYLOAD/npu-uboot.sh" || return 1

echo "== 2/6 连上串口，等 '=> '"
TTY=$TTY . "$PAYLOAD/serial.sh" || return 1
if ! serial_read_until "=> " 10; then
	echo "   没看到 U-Boot 提示符（NPU 已经启动进系统了？先回到 ssh 那条路）"
	return 1
fi

# 停在 U-Boot 上失败时要让它自己启动回去：ssh/急救那条路需要 NPU 跑到用户态。
leave_uboot() {
	serial_run 'reset' 10 >/dev/null 2>&1 || true
}

echo "== 3/6 探能力"
help_out=$(serial_run 'help' 30) || { leave_uboot; return 1; }
case "$help_out" in
*'tftpboot'*) ;;
*)
	echo "   这个 U-Boot 里没有 tftpboot —— 只能走急救 initramfs。"
	leave_uboot
	return 1
	;;
esac

part_out=$(serial_run 'mmc part' 20) || { leave_uboot; return 1; }
p2_start=$(printf '%s\n' "$part_out" | awk '$1 == 2 && $2 ~ /^[0-9]+$/ { print $2; exit }')
p2_size=$(printf '%s\n' "$part_out" | awk '$1 == 2 && $2 ~ /^[0-9]+$/ { print $3; exit }')
[ -n "${p2_start:-}" ] || {
	echo "   读不出 p2 的起始扇区："
	printf '%s\n' "$part_out" | sed 's/^/     /'
	leave_uboot
	return 1
}
echo "   p2: start=$p2_start size=$p2_size sectors（$((p2_size / 2048)) MiB）"

echo "== 4/6 准备影像"
IMG=$STORE/$IMG_NAME
if [ "$KEEP" = 1 ] && [ -f "$IMG" ] && [ "$(stat -c %s "$IMG")" = "$((p2_size * 512))" ]; then
	echo "   复用 $IMG"
else
	rm -f "$IMG"
	truncate -s "$((p2_size * 512))" "$IMG" || { leave_uboot; return 1; }
	mkfs.ext4 -q -F -L xgsroot "$IMG" || { leave_uboot; return 1; }
	mkdir -p /tmp/xgs87-imgmnt
	mount -o loop "$IMG" /tmp/xgs87-imgmnt || { leave_uboot; return 1; }
	if ! zstd -dc "$TAR" | tar -xpf - -C /tmp/xgs87-imgmnt; then
		umount /tmp/xgs87-imgmnt; leave_uboot; return 1
	fi
	mkdir -p /tmp/xgs87-imgmnt/boot
	cp "$DTB" /tmp/xgs87-imgmnt/boot/cn9130-sophos-xgs87w-sfp10g.dtb
	materialize_boot_names /tmp/xgs87-imgmnt || true
	sync
	echo "   rootfs $(du -sh /tmp/xgs87-imgmnt | cut -f1) / 影像 $((p2_size / 2048)) MiB"
	umount /tmp/xgs87-imgmnt
fi

echo "== 5/6 起 TFTP 服务（$NIC）"
ip addr show dev "$NIC" | grep -q " $x86_ip/" || ip addr add "$x86_ip/24" dev "$NIC"
ip link set "$NIC" up
python3 "$PAYLOAD/tftp.py" "$STORE" 69 >/var/log/xgs87-tftp.log 2>&1 &
tftp_pid=$!
sleep 1
echo "   $x86_ip:69 服务 $STORE"

echo "== 6/6 在 U-Boot 里拉影像并写 p2"
rc=0
serial_run "setenv ipaddr $NET_PREFIX.2; setenv serverip $x86_ip; setenv netmask 255.255.255.0" 20 >/dev/null ||
	rc=1
if [ "$rc" = 0 ]; then
	serial_run 'ping $serverip' 20 >/dev/null || {
		echo "   U-Boot ping 不到 $x86_ip：网线插的是不是面板口？交换机默认转发被改过？"
		rc=1
	}
fi
if [ "$rc" = 0 ]; then
	echo "   tftpboot $((p2_size * 512 / 1024 / 1024)) MiB（1 Gbit/s 大约 15-20 秒）"
	serial_run "tftpboot \$loadaddr $IMG_NAME" 900 >/dev/null || { echo "   tftpboot 失败"; rc=1; }
fi
if [ "$rc" = 0 ]; then
	echo "   mmc write"
	serial_run "mmc dev 0; mmc write \$loadaddr $p2_start $p2_size" 900 >/dev/null || { echo "   mmc write 失败"; rc=1; }
fi
if [ "$rc" = 0 ]; then
	echo "   验证：ext4load mmc 0:2 /boot/Image"
	if serial_run "ext4load mmc 0:2 \$kernel_addr_r /boot/Image" 90 >/dev/null; then
		echo "   ✓ 读到了"
		serial_run "setenv bootcmd 'run bootcmd_deb10g'; saveenv" 30 >/dev/null || true
		serial_run 'reset' 10 >/dev/null || true
		echo "   NPU 正在重启（vNTB 会自己回来）"
	else
		echo "   ✗ 写进去的东西 ext4load 读不出来"
		rc=1
	fi
fi
kill "$tftp_pid" 2>/dev/null
tail -3 /var/log/xgs87-tftp.log 2>/dev/null | sed 's/^/   /'
if [ "$rc" != 0 ]; then
	echo "   让 NPU 正常启动回去"
	leave_uboot
	echo "   U-Boot 这条路没成功，转急救 initramfs"
	return 1
fi
return 0