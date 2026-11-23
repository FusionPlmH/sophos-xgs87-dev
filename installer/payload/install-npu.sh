#!/bin/sh
# 把 debian-npu.tar.zst 装到 NPU 的 root 分区。
#
# 顺序是"由快到慢、由自动到手动"：
#
#   A. vNTB/网络能到 NPU：直接 ssh 推过去（约 1 Gbit/s）
#   B. 到不了：用 x86 的 ttyS2 串口登录 NPU，问出它的 br-lan 地址和 VLAN，
#      在 x86 这边镜像同样的 VLAN + 同网段地址 —— 顺便把 sshd 修一遍 ——
#      然后再走 A
#   C. 串口也进不去：起 HTTP 服务，把命令打到屏幕上让人在 NPU 控制台敲
#
# 数据永远走网络；串口只当控制通道（115200 的线搬 190 MB 要几个小时）。
#
# 注意：x86 摸不到 NPU 的 eMMC —— 两台机器只有 PCIe(vNTB) 和一路 UART，
# 所有写入都是在 NPU 上执行的。
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
PAYLOAD=${PAYLOAD:-$HERE}
TAR=$PAYLOAD/debian-npu.tar.zst
DTB=$(ls "$PAYLOAD"/cn9130-sophos-xgs87w-sfp10g*.dtb 2>/dev/null | head -1)
. "$PAYLOAD/lib.sh"
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"
SERIAL=${SERIAL:-/dev/ttyS2}

[ -f "$TAR" ] || { echo "找不到 debian-npu.tar.zst"; exit 1; }
[ -n "$DTB" ] || { echo "找不到 DTB"; exit 1; }

# 从串口把 NPU 的 br-lan 摸清楚，并在 x86 这边把同样的 VLAN + 地址建出来。
# 成功则 $NPU 可以被 ssh 到。
serial_repair() {
	TTY=$SERIAL . "$PAYLOAD/serial.sh" || return 1
	echo "== 串口登录 NPU（$SERIAL，只能是它自己一个读者）"
	serial_login || {
		echo "   登录不上（NPU 没起来？密码不是 $NPU_PASS？）"
		return 1
	}

	echo "== 问它现在的网络"
	info=$(serial_run 'ip -4 -br a' 25) || true
	printf '%s\n' "$info" | sed 's/^/   /'
	lan=$(printf '%s\n' "$info" |
		awk '$1 ~ /^(br-lan|br0|br-wan)/ && $3 ~ /^[0-9]/ { print $3; exit }')
	[ -n "$lan" ] || { echo "   br-lan 上没有 IPv4 地址，没得镜像" ; return 1; }

	vid=$(serial_run 'ip -d link show master br-lan' 25 2>/dev/null |
		sed -n 's/.*vlan protocol 802.1Q id \([0-9][0-9]*\).*/\1/p' | head -1) || vid=
	# 旧固件的桥可能没有 vlan 设备（直接桥 vNTB），那就按 untagged 处理。
	vid=${vid:-0}
	echo "== NPU 的 br-lan：$lan，VLAN ${vid:-无}"

	npu_ip=${lan%/*}
	case "$lan" in
	*/24) net=$(printf '%s' "$npu_ip" | cut -d. -f1-3) ;;
	*)
		echo "   只认得 /24 的 br-lan（现在是 $lan），先手工处理："
		echo "   ip addr add <同网段地址>/24 dev $SERIAL 这类命令在 x86 上跑"
		return 1
		;;
	esac
	mine=$net.200
	[ "$mine" = "$npu_ip" ] && mine=$net.201

	if [ "$vid" = 0 ]; then
		target=eth0
	else
		target=eth0.$vid
		ip link show "$target" >/dev/null 2>&1 ||
			ip link add link eth0 name "$target" type vlan id "$vid" || return 1
	fi
	ip link set "$target" up 2>/dev/null || true
	ip addr show dev "$target" | grep -q " $mine/" ||
		ip addr add "$mine/24" dev "$target" || return 1
	echo "== x86 这边补上 $target = $mine/24"

	if ping -c1 -W2 "$npu_ip" >/dev/null 2>&1; then
		echo "== 通了：$npu_ip"
	else
		echo "   还是 ping 不通 $npu_ip（链路/桥没通）"
		return 1
	fi

	# 镜像里刻意不带 ssh host key，Debian 13 的 ssh.service 自己也不会生成，
	# 于是"网络通但 ssh 连不上"。串口这边正好能补。
	echo "== 让 NPU 那边把 ssh 修好"
	serial_run 'sudo ssh-keygen -A >/dev/null 2>&1; sudo systemctl restart ssh' 60 |
		sed 's/^/   /' || true
	NPU=$npu_ip
	export NPU
	return 0
}

echo "== 先把 vNTB 链路拉起来（U 盘的 x86 系统里就有这些单元）"
systemctl start xgs-ntb xgs-ntb-watch 2>/dev/null || true
NPU=$(find_npu 30) || NPU=

if [ -z "$NPU" ] && [ -e "$SERIAL" ]; then
	echo "== 网络到不了 NPU，改从 $SERIAL 串口直接驱动它"
	serial_repair || true
	[ -n "${NPU:-}" ] || NPU=
fi

if [ -n "$NPU" ]; then
	echo "== NPU 在线（$NPU），直接推过去（走 vNTB，约 1 Gbit/s）"
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
	y | Y) NPU=$NPU "$HERE/backup-npu.sh" "$PART" || {
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
	echo "== NPU 不可达（试过：$NPU_CANDIDATES）。起 HTTP 服务，从 NPU 的控制台手动装："
	# 别假设地址：vNTB 链路没起来时 eth0.200 根本不存在，bind 会失败
	# （OSError: Cannot assign requested address）。所以绑 0.0.0.0，把所有
	# 现有地址都列出来 —— NPU 那边能用哪个就用哪个。
	PORT=${PORT:-8080}
	ADDRS=$(local_addrs)
	if [ -z "$ADDRS" ]; then
		echo
		echo "⚠️  x86 现在没有任何 IPv4 地址 —— vNTB 链路大概没起来。"
		echo "    ip -br a            看接口"
		echo "    systemctl status xgs-ntb xgs-ntb-watch"
		echo "    菜单选 7 可以直接开 NPU 串口看一眼。"
		exit 1
	fi
	cd "$PAYLOAD"
	echo
	echo "  x86 上已经跑起：  python3 -m http.server $PORT --bind 0.0.0.0"
	echo "  然后在 NPU 控制台（菜单选 7，或 x86 的 /dev/ttyS2，57600）里执行："
	echo
	for a in $ADDRS; do
		echo "    # NPU 在 $a 那个网段时："
		echo "    wget http://$a:$PORT/debian-npu.tar.zst -O /tmp/x.tar.zst"
	done
	echo
	echo "    mkfs.ext4 -L xgsroot /dev/mmcblk0p2"
	echo "    mount /dev/mmcblk0p2 /mnt && tar -xpf /tmp/x.tar.zst -C /mnt"
	echo "    cp /tmp/cn9130-*.dtb /mnt/boot/ && umount /mnt && reboot"
	echo
	echo "  NPU 上没有 wget 的话先用 apt 装，或者接了网线直接从上游拉："
	echo "    sudo apt-get install -y wget"
	echo
	echo "  DTB 也在同一个目录下。按 Ctrl-C 结束服务。"
	exec python3 -m http.server "$PORT" --bind 0.0.0.0
fi