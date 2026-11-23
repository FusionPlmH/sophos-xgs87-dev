#!/bin/sh
# 把 debian-npu.tar.zst 装到 NPU 的 root 分区。
#
# 四级阶梯，按"前提最容易满足"排，任一级失败自动往下一级走：
#
#   1. ssh + tar：NPU 能 ssh 且有 tar/zstd（哪个镜像都有）→ x86 这边 mkfs，
#      190 MB 直接流进 NPU 的 tar（npu_ssh_stream 用 sudo -A，stdin 留给数据）
#   2. NBD：NPU 上有 nbd-server（或能装上）→ 块设备，x86 本地 mkfs/解包/fsck
#   3. U-Boot + tftp：NPU 起不来时唯一还能用的路，但 x86 得插 USB 网卡做物理
#      旁路（NPU 一进 U-Boot，vNTB 就断了）。会先停掉 xgs-ntb-watch，免得它
#      的 PCIe rescan 把刚停住的 U-Boot 打飞
#   4. 急救 initramfs：上面全不行时，串口推 15 MB（p2 里还有内核就只推 1.9 MB）
#
# 网不到 NPU 时先走串口（ttyS2）登录一遍：问出 br-lan 地址和 VLAN、在 x86 上
# 镜像同样的 VLAN、顺手把 sshd 的 host key 修好，再回到第 1 级。
#
# ⚠️ 写的是块设备：NPU 如果正跑着这个分区，边写边用会把文件系统写坏。真机上
# 就是"装系统"这个语义，装完要重启。
set -u
# shellcheck disable=SC2154
trap 'rc=$?; [ "$rc" = 0 ] || echo "$0: 退出码 $rc" >&2' EXIT

HERE=$(cd "$(dirname "$0")" && pwd)
PAYLOAD=${PAYLOAD:-$HERE}
TAR=$PAYLOAD/debian-npu.tar.zst
DTB=$(ls "$PAYLOAD"/cn9130-sophos-xgs87w-sfp10g*.dtb 2>/dev/null | head -1)
. "$PAYLOAD/lib.sh"
SERIAL=${SERIAL:-/dev/ttyS2}
PORT=${PORT:-10809}
NBD=${NBD:-/dev/nbd0}
MNT=${MNT:-/mnt}

[ -f "$TAR" ] || { echo "找不到 debian-npu.tar.zst"; exit 1; }
[ -n "$DTB" ] || { echo "找不到 DTB"; exit 1; }
chmod 755 "$PAYLOAD"/*.sh 2>/dev/null || true

# 登录 NPU 并跑一段脚本：实现搬到 lib.sh 的 npu_ssh（askpass 登录 + sudo -S）。

# 串口那条路：登录进去，问清楚 br-lan 的地址和 VLAN，在 x86 这边镜像出来。
serial_repair() {
	TTY=$SERIAL . "$PAYLOAD/serial.sh" || return 1
	echo "== 串口登录 NPU（$SERIAL）"
	serial_login || { echo "   登录不上（NPU 没起来？密码不是 $NPU_PASS？）"; return 1; }

	echo "== 问它现在的网络"
	info=$(serial_run 'ip -4 -br a' 25) || true
	printf '%s\n' "$info" | sed 's/^/   /'
	lan=$(printf '%s\n' "$info" |
		awk '$1 ~ /^(br-lan|br0|br-wan)/ && $3 ~ /^[0-9]/ { print $3; exit }')
	[ -n "$lan" ] || { echo "   br-lan 上没有 IPv4 地址，没得镜像"; return 1; }

	vid=$(serial_run 'ip -d link show master br-lan' 25 2>/dev/null |
		sed -n 's/.*vlan protocol 802.1Q id \([0-9][0-9]*\).*/\1/p' | head -1) || vid=
	vid=${vid:-0}
	echo "== NPU 的 br-lan：$lan，VLAN $vid"

	npu_ip=${lan%/*}
	case "$lan" in
	*/24) net=$(printf '%s' "$npu_ip" | cut -d. -f1-3) ;;
	*) echo "   只认得 /24 的 br-lan（现在是 $lan），先手工处理"; return 1 ;;
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

	ping -c1 -W2 "$npu_ip" >/dev/null 2>&1 || {
		echo "   还是 ping 不通 $npu_ip（链路/桥没通）"
		return 1
	}
	echo "== 通了：$npu_ip"

	# 镜像里刻意不带 ssh host key，Debian 13 的 ssh.service 自己也不会生成，
	# 于是"网络通但 ssh 连不上"。串口这边正好能补。
	echo "== 让 NPU 那边把 ssh 修好"
	serial_run 'sudo ssh-keygen -A >/dev/null 2>&1; sudo systemctl restart ssh' 60 |
		sed 's/^/   /' || true
	NPU=$npu_ip
	export NPU
	return 0
}

# 没有 nbd-server 时的退路：ssh + tar 流式解包（NPU 只要 tar 和 zstd）
stream_install() {
	echo "== ssh 直接解包到 $PART（不需要 nbd）"
	npu_ssh "umount /mnt 2>/dev/null || true
		mkfs.ext4 -q -F -L xgsroot $PART
		mkdir -p /mnt
		mount $PART /mnt
		echo mounted" || return 1
	echo "   解包（190 MB 走 vNTB，1-2 分钟）"
	zstd -dc "$TAR" | npu_ssh_stream 'tar -xpf - -C /mnt' || return 1
	cat "$DTB" | npu_ssh_stream \
		'mkdir -p /mnt/boot && tee /mnt/boot/cn9130-sophos-xgs87w-sfp10g.dtb >/dev/null' || return 1
	npu_ssh "sync; umount /mnt; echo done" || return 1
	echo "== 写完了，让它重启"
	npu_ssh "pkill -f 'nbd-server' 2>/dev/null || true; (sleep 1; reboot) >/dev/null 2>&1 &" || true
	return 0
}

cleanup_nbd() {
	nbd-client -d "$NBD" 2>/dev/null || true
}

echo "== 先把 vNTB 链路拉起来"
systemctl start xgs-ntb xgs-ntb-watch 2>/dev/null || true

# ---- 破坏性操作的确认：只问一次，三个层级（U-Boot / NBD / 急救）共用 ----
printf '目标分区 [/dev/mmcblk0p2]: '
read -r PART
PART=${PART:-/dev/mmcblk0p2}
case "$PART" in
/dev/*) ;;
*) echo "分区要写 /dev/... 的绝对路径"; exit 1 ;;
esac
echo "⚠️  接下来会把 $PART 整个重写（mmc write / mkfs / dd），NPU 上原有的东西会没。"
printf '输入 YES 继续：'
read -r ok
[ "$ok" = YES ] || exit 1
# 从这里开始不能被 Ctrl+C 打断：写到一半的 ext4 比没写更麻烦。
trap '' INT QUIT
echo "   已开始，Ctrl+C 不再中断（要重来就等它跑完）。"
export PART

# 默认先走 U-Boot（ext4 影像 → tftpboot → mmc write）：这条路不依赖 NPU 上的任何
# 用户态程序，也不依赖它的 sshd。走不通（没有 tftpboot、没插网线、交换机没转发）
# 才退到 NBD，那时脚本会先让 NPU 正常启动回去。
if [ "${NO_UBOOT:-0}" != 1 ] && [ -x "$PAYLOAD/npu-uboot-install.sh" ]; then
	echo "== 先试 U-Boot 方式（tftpboot + mmc write）"
	if "$PAYLOAD/npu-uboot-install.sh"; then
		echo
		echo "NPU 写完了（U-Boot 路径），它正在重启。"
		printf '按回车返回菜单...'
		read -r _
		exit 0
	fi
	echo "== U-Boot 那条路没走通，改用 NBD"
fi

# 最后一招：串口推 15 MB 急救包进去，让它把 vNTB 拉起来再写整盘。
try_rescue() {
	[ -f "$PAYLOAD/xgs87-rescue.tar.zst" ] || { echo "   （没有急救包，跳过）"; return 1; }
	[ -x "$PAYLOAD/npu-rescue.sh" ] || return 1
	echo "== 试最后一招：急救 initramfs（串口推 Image.gz + initramfs.gz，约 15 MB）"
	echo "   115200 大约 24 分钟；BAUD=460800 sh 这个脚本就只要 6 分钟"
	printf '现在试吗？[Y/n] '
	read -r r
	case "${r:-y}" in
	n | N) return 1 ;;
	esac
	"$PAYLOAD/npu-rescue.sh"
}

# ---- 破坏性操作的确认见上面的 tty 那段（只问一次）----

NPU=$(find_npu 30) || NPU=

if [ -z "$NPU" ] && [ -e "$SERIAL" ]; then
	echo "== 网络到不了 NPU，改从 $SERIAL 串口直接驱动它"
	serial_repair || true
	[ -n "${NPU:-}" ] || NPU=
fi

if [ -z "$NPU" ]; then
	cat <<EOM
== NPU 完全不可达（试过：$NPU_CANDIDATES），NBD 也就没处可连。

   先在 NPU 上把导出开起来（菜单选 7，在它的控制台上敲）：
     sudo apt-get install -y nbd-server        # 老镜像没带的话
     sudo mkdir -p /etc/nbd-server
     printf '[generic]\n[xgs87]\nexportname = /dev/mmcblk0p2\nreadonly = false\nport = $PORT\n' |
       sudo tee /etc/nbd-server/xgs87.conf
     sudo nbd-server -C /etc/nbd-server/xgs87.conf
   然后回来重新选本项。
EOM
	printf '按回车返回菜单...'
	read -r _
	try_rescue
	exit 1
fi

echo "== NPU 在线（$NPU），目标分区 $PART"

# 顺序按"前提最容易满足"排：ssh + tar 只要 NPU 上有 tar/zstd（哪个镜像都有），
# NBD 还得多一个 nbd-server。所以先试 ssh，成不了再谈 nbd。
echo "== 1/6 看 NPU 上能不能直接解包（tar + zstd）"
if timeout 60 npu_ssh 'command -v tar && command -v zstd' >/dev/null 2>&1; then
	echo "   能 —— 直接用 ssh 解包，不需要 nbd-server"
	if stream_install; then
		echo
		echo "NPU 写完了（ssh+tar 路径），它正在重启。"
		printf '按回车返回菜单...'
		read -r _
		exit 0
	fi
	echo "== ssh+tar 没成，退到 NBD"
else
	echo "   NPU 上没有 tar/zstd（它不是我们的镜像？）—— 退到 NBD"
fi

echo "== 1/6 确认 NPU 上有 nbd-server"
echo "   （在 NPU 上查一遍；没有就装，apt 走它自己的外网，最多等 3 分钟）"
if ! timeout 60 npu_ssh 'command -v nbd-server' >/dev/null 2>&1; then
	echo "   没有，试着装一下"
	timeout 180 npu_ssh 'apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq nbd-server' || {
		echo
		echo "   没有 nbd-server，也装不上（NPU 没外网？）—— 改用 ssh 直接解包，"
		echo "   这条路只要 NPU 上有 tar 和 zstd，不需要 nbd。"
		stream_install && exit 0
		echo "== ssh 直接解包也没成"
		try_rescue
		exit 1
	}
fi

echo "== 2/6 让 NPU 导出 $PART"
# 必须用配置文件：命令行形式（nbd-server PORT FILE）在新版里是只读导出，
# mkfs 会直接 "Operation not permitted while setting up superblock"。
npu_ssh "mkdir -p /etc/nbd-server
	cat > /etc/nbd-server/xgs87.conf <<CONF
[generic]
[xgs87]
exportname = $PART
readonly = false
port = $PORT
CONF
	pkill -f 'nbd-server -C /etc/nbd-server/xgs87.conf' 2>/dev/null || true
	: > /var/log/xgs87-nbd.log
	setsid nbd-server -C /etc/nbd-server/xgs87.conf >/var/log/xgs87-nbd.log 2>&1 &
	sleep 2
	ss -ltn 2>/dev/null | grep -q ':$PORT ' && echo NBD_LISTENING || { echo NBD_FAILED; cat /var/log/xgs87-nbd.log; }"

echo "== 3/6 x86 这边接上 $NBD"
modprobe nbd max_part=8 2>/dev/null || true
cleanup_nbd
nbd-client -N xgs87 -p "$NPU" "$PORT" "$NBD" >/dev/null || {
	echo "nbd-client 连不上（$NPU:$PORT）"
	exit 1
}
if [ ! -b "$NBD" ]; then
	echo "$NBD 没出现（内核没 nbd 模块？）"
	exit 1
fi

echo "== 4/6 备份？"
printf '先把 %s 备份到 U 盘再动手吗？[Y/n] ' "$PART"
read -r bk
case "${bk:-y}" in
y | Y)
	STORE=$(ensure_store) || STORE=
	if [ -z "$STORE" ]; then
		echo "   备份分区不可用，跳过备份"
	else
		DEST=$STORE/npu-$(basename "$PART")-$(date +%Y%m%d-%H%M).img.zst
		echo "   写到 $DEST"
		dd if="$NBD" bs=4M status=progress | zstd -1 -T0 >"$DEST" || {
			echo "   备份失败，已中止 —— 没有格式化任何东西。"; cleanup_nbd; exit 1
		}
		zstd -t "$DEST" >/dev/null 2>&1 || { echo "   备份校验失败，已中止。"; cleanup_nbd; exit 1; }
		ls -lh "$DEST"
	fi
	;;
esac

echo "== 5/6 格式化 + 解包（都在 x86 这边做）"
mkfs.ext4 -q -F -L xgsroot "$NBD"
mkdir -p "$MNT"
mount "$NBD" "$MNT"
zstd -dc "$TAR" | tar -xpf - -C "$MNT"
mkdir -p "$MNT/boot"
cp "$DTB" "$MNT/boot/cn9130-sophos-xgs87w-sfp10g.dtb"
sync
echo "   rootfs: $(du -sh "$MNT" 2>/dev/null | cut -f1)"
umount "$MNT"

echo "== 6/6 断开、让它重启"
cleanup_nbd
npu_ssh "pkill -f 'nbd-server -C /etc/nbd-server/xgs87.conf' 2>/dev/null || true
	(sleep 1; reboot) >/dev/null 2>&1 &" || true

echo
echo "NPU 写完了，正在重启。等它起来后菜单选 3 看状态。"
printf '按回车返回菜单...'
read -r _
exit 0