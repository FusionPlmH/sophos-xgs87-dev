#!/bin/sh
# 把 debian-npu.tar.zst 装到 NPU 的 root 分区。
#
# 四级阶梯（NBD 目前禁用），按"前提最容易满足 + 破坏性从小到大"排，任一级失败
# 自动往下一级走：
#
#   1. ssh + tar：NPU 能 ssh 且有 tar/zstd（我们自己的镜像）→ x86 这边 mkfs，
#      190 MB 直接流进 NPU 的 tar（npu_ssh_stream 用 sudo -A，stdin 留给数据）
#   1b. ssh + dd：NPU 连 tar/zstd 都没有（原厂系统就是这样）→ x86 造一个等大的
#      ext4 镜像，ssh + dd 整块灌进去。只要 busybox 的 dd
#   2. U-Boot + tftp：NPU 起不来时唯一还能用的路，但 x86 得插 USB 网卡做物理
#      旁路（NPU 一进 U-Boot，vNTB 就断了）。会先停掉 xgs-ntb-watch，免得它
#      的 PCIe rescan 把刚停住的 U-Boot 打飞
#   3. 急救 initramfs：上面全不行时，串口推 15 MB（p2 里还有内核就只推 1.9 MB）
#
# NBD 这一级目前禁用（两个镜像都不带 nbd-client/nbd-server，也从未实测通过），
# 代码保留在 SKIP_NBD=0 后面，等它真的跑通再启用。
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
# NBD 这一级先禁用（两个镜像都不再带 nbd-client/nbd-server，也从未实测通过）
SKIP_NBD=${SKIP_NBD:-1}
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

	# 让 NPU 自己把答案打成一个带标记的单行，再从回显里把它抠出来。
	# 以前是解析 `ip -br a` 的第 3 列，实机（2026-11-25）上明明打出了
	# "br-lan UP 10.234.56.1/24" 却解析出空值，于是直接判"没得镜像"、
	# 整条串口兜底白跑一趟。带标记的单行不依赖列位置、不怕空格/回绕。
	lan=
	for dev in br-lan br0 br-wan; do
		raw=$(serial_run "echo XGS87LAN=\$(ip -4 -o addr show $dev 2>/dev/null | sed -n 's/.* inet \\([^ ]*\\).*/\\1/p' | head -1)" 20) || true
		lan=$(printf '%s\n' "$raw" | sed -n 's/.*XGS87LAN=\([0-9][0-9.]*\/[0-9][0-9]*\).*/\1/p' | head -1)
		[ -n "$lan" ] && break
	done
	[ -n "$lan" ] || {
		echo "   NPU 上没有可取用的 br-lan/br0/br-wan 地址；先看上面的输出"
		return 1
	}

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

	# eth0 是 vNTB。装 NPU 这一步最常见的失败原因就是它压根没出现（x86 开机时
	# NPU 的端点还没枚举到），所以先把这一侧的状态摊开，别让人猜。
	if [ ! -e /sys/class/net/eth0 ]; then
		echo "   x86 这边没有 eth0（vNTB 没建起来）"
		ip -br link 2>/dev/null | sed 's/^/     /'
		return 1
	fi

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
		ip -br a 2>/dev/null | sed 's/^/     /'
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
	# bootcmd_deb loads these two fixed names; tar unpacking does not run the
	# kernel postinst hooks that normally create them.
	npu_ssh 'kver=$(ls /mnt/lib/modules 2>/dev/null | sort -V | tail -1)
		if [ -n "$kver" ]; then
			[ -e /mnt/boot/Image ] || ln -f "/mnt/boot/vmlinuz-$kver" /mnt/boot/Image 2>/dev/null || cp -f "/mnt/boot/vmlinuz-$kver" /mnt/boot/Image
			[ -e /mnt/boot/initrd.img ] || ln -f "/mnt/boot/initrd.img-$kver" /mnt/boot/initrd.img 2>/dev/null || cp -f "/mnt/boot/initrd.img-$kver" /mnt/boot/initrd.img
		fi' || return 1
	npu_ssh "sync; umount /mnt; echo done" || return 1
	echo "== 写完了，让它重启"
	npu_ssh "pkill -f 'nbd-server' 2>/dev/null || true; (sleep 1; reboot) >/dev/null 2>&1 &" || true
	return 0
}

# 连 tar/zstd 都没有时的退路：x86 这边造一个等大的 ext4 镜像，ssh + dd 整块灌进去。
# 唯一的前提是 NPU 上有 dd —— busybox 自带，原厂系统也有。
sshdd_install() {
	echo "== ssh + dd 整块写 $PART（NPU 上只要 dd）"
	NPU=$NPU NPU_USER=${NPU_USER:-root} NPU_PASS=${NPU_PASS:-} PART=$PART \
		sh "$PAYLOAD/npu-sshdd.sh"
}

cleanup_nbd() {
	nbd-client -d "$NBD" 2>/dev/null || true
}

echo "== 先把 vNTB 链路拉起来（watcher 默认不碰 PCIe，安装期间也别让它插手）"
systemctl stop xgs-ntb-watch 2>/dev/null || true
systemctl start xgs-ntb 2>/dev/null || true

# eth0 是 vNTB 的 netdev。它不在就什么网络办法都不用试了 —— 先把可能的原因
# 排掉：端点没枚举（BIOS 早于 NPU 启动）、枚举了但驱动没绑、或者单元没跑。
# 2026-11-25 实机：这一步之前直接进 find_npu，30 秒后报"网络到不了 NPU"，
# 没人知道到底是哪一环。
i=0
while [ ! -e /sys/class/net/eth0 ] && [ "$i" -lt 3 ]; do
	i=$((i + 1))
	if [ ! -e /sys/bus/pci/devices/0000:03:00.0 ] && [ -x /usr/local/sbin/xgs-ntb-up.sh ]; then
		echo "   eth0 没有，03:00.0 也没枚举到，做一次 rescan（第 $i 次）"
		/usr/local/sbin/xgs-ntb-up.sh --force-rescan || true
	elif [ -x /usr/local/sbin/xgs-ntb-up.sh ]; then
		echo "   eth0 没有但 03:00.0 在，重跑一次 xgs-ntb-up --force-rescan（第 $i 次）"
		/usr/local/sbin/xgs-ntb-up.sh --force-rescan || true
	else
		echo "   eth0 没有，也没有 /usr/local/sbin/xgs-ntb-up.sh（不是我们的镜像？）"
		break
	fi
	sleep 4
done
if [ -e /sys/class/net/eth0 ]; then
	echo "   eth0 就位：$(cat /sys/class/net/eth0/operstate)"
else
	echo "   ⚠️ eth0 还是没有；下面的网络办法会失败，会走串口/急救"
	# rescan 只有在 PCIe 链路本身已经训练起来时才有用。如果 03:00.0 在
	# rescan 之后仍然不出现，说明主机侧从来没有枚举过这个端点（典型是
	# x86 先开机、NPU 后部署，POST 时链路上什么都没有）。这种情况下唯一
	# 可靠的办法是重启 x86，让 BIOS 在 POST 里重新训练链路。
	if [ ! -e /sys/bus/pci/devices/0000:03:00.0 ]; then
		echo "      03:00.0 依然不存在 → 主机侧没枚举过这个端点。"
		echo "      重启一次 x86（NPU 保持开机），让 BIOS 在 POST 时训练 PCIe 链路，"
		echo "      再回来重跑本菜单的 2 就会走网络这条路。"
	fi
fi

# 维护盘是另一个系统（U 盘上的 root），它的 networkd 不一定给 eth0.200 配上
# LAN 地址；没有地址 find_npu 就 ping 不到 NPU 的 10.234.56.1。10.234.56.2/24
# 是文档里 x86 的固定 LAN 地址，这里幂等补上，让"网络"这条路自己就能走通。
_vlan=eth0.200
if [ -e "/sys/class/net/$_vlan" ] &&
	! ip -4 addr show dev "$_vlan" 2>/dev/null | grep -q 'inet '; then
	ip link set "$_vlan" up 2>/dev/null || true
	ip addr add 10.234.56.2/24 dev "$_vlan" 2>/dev/null &&
		echo "   补上 $_vlan = 10.234.56.2/24（原本没有地址）"
fi

# ---- 目标分区在 NPU 上，所以等找到 NPU 之后再问（见下面）----
# 以前这里先问、还用本机的 `lsblk` 显示大小：在维护盘上那会显示 x86 自己的
# 内置盘（/dev/mmcblk0p2 597M），看起来像要写本机，2026-11-25 实际吓到过人。
# 真正写入一直是通过 npu_ssh 在 NPU 上做的，但提示必须说清楚。

# U-Boot 放最后再试（见 try_uboot）：它会先把 NPU 停进 U-Boot，vNTB 一断就没
# 退路了，所以必须等 ssh/整块写这些"不动 NPU"的路都失败之后再考虑。

# U-Boot + tftp：NPU 起不来时唯一还能用的路，但得先把 NPU 停进 U-Boot（vNTB 会
# 断，x86 只能靠面板口的 USB 网卡）。所以它排在所有"不动 NPU"的路之后。
try_uboot() {
	[ "${NO_UBOOT:-0}" != 1 ] || return 1
	[ -x "$PAYLOAD/npu-uboot-install.sh" ] || return 1
	echo "== 试 U-Boot 方式（tftpboot + mmc write）"
	"$PAYLOAD/npu-uboot-install.sh"
}

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
== NPU 完全不可达（试过：$NPU_CANDIDATES）。NBD 那一级已禁用，自动流程只剩急救包。

   先确认串口还能看到它（菜单 4 → NPU 串口）：能停在 U-Boot 就还有 U-Boot+tftp
   这条路（需要 x86 插 USB 网卡）；连 U-Boot 都进不去就只能走急救 initramfs。
   如果 NPU 其实起来了、只是网络不对，先用菜单 4 登录，把 br-lan/VLAN 修好，
   再回来重新选本项。
EOM
	trap - INT QUIT
	printf '按回车继续尝试急救包...'
	read -r _
	try_rescue
	exit 1
fi

echo "== NPU 在线（$NPU）"

# ---- 破坏性操作的确认：只问一次，所有层级（U-Boot / NBD(禁用) / 急救）共用 ----
# 分区路径是**NPU 上的**（写入通过 npu_ssh 在 NPU 上执行），大小也从 NPU 读，
# 不要用本机的 lsblk —— 维护盘上那会显示 x86 自己的 mmcblk0p2，看着像要写本机。
printf 'NPU 上要重写的分区 [/dev/mmcblk0p2]: '
read -r PART
PART=${PART:-/dev/mmcblk0p2}
case "$PART" in
/dev/*) ;;
*) echo "分区要写 /dev/... 的绝对路径"; exit 1 ;;
esac
# 裸文件系统镜像只能写分区：写成整盘会把 MBR/GPT 覆盖掉（2026-11-24 的砖机就是这么来的）
. "$PAYLOAD/lib.sh"
require_partition "$PART" "目标分区"
_remote_size=$(npu_ssh "lsblk -dno SIZE,MODEL $PART 2>/dev/null || echo '(NPU 上没有这个分区)'" 20 2>/dev/null | tr -s ' ')
echo "   目标：NPU 的 $PART  ${_remote_size:-（读不到大小）}"
echo "⚠️  接下来会把 NPU 的 $PART 整个重写（mkfs / dd），里面的东西会没。"
printf '输入 YES 继续：'
read -r ok
[ "$ok" = YES ] || exit 1
# 从这里开始不能被 Ctrl+C 打断：写到一半的 ext4 比没写更麻烦。
trap '' INT QUIT
echo "   已开始，Ctrl+C 不再中断（要重来就等它跑完）。"
export PART

# 顺序按"前提最容易满足"排：ssh + tar 只要 NPU 上有 tar/zstd（哪个镜像都有），
# NBD 还得多一个 nbd-server。所以先试 ssh，成不了再谈 nbd。
# `timeout` 只能执行外部命令，npu_ssh 是 shell 函数 —— 写成 `timeout 60 npu_ssh …`
# 会直接 "No such file or directory"。ssh 自己带 ConnectTimeout，够了。
echo "== 1/6 看 NPU 上能不能直接解包（tar + zstd）"
if npu_ssh 'command -v tar && command -v zstd' >/dev/null 2>&1; then
	echo "   能 —— 直接用 ssh 解包，不需要 nbd-server"
	if stream_install; then
		echo
		echo "NPU 写完了（ssh+tar 路径），它正在重启。"
		trap - INT QUIT
		printf '按回车返回菜单...'
		read -r _
		exit 0
	fi
	echo "== ssh+tar 没成，退到 ssh+dd"
else
	echo "   NPU 上没有 tar/zstd（它不是我们的镜像？）—— 退到 ssh+dd"
fi

echo "== 1/6 试 ssh + dd（整块 ext4 镜像；NPU 上只要 busybox 的 dd）"
if sshdd_install; then
	# 写完了：把 Ctrl+C 还回去，否则"按回车返回菜单"这里按 Ctrl+C 毫无反应。
	trap - INT QUIT
	echo
	echo "NPU 写完了（ssh+dd 路径），重启它。"
	printf '按回车返回菜单...'
	read -r _
	exit 0
fi
echo "== ssh+dd 也没成，退到 U-Boot（这一步会把 NPU 停进 U-Boot，vNTB 会断）"
if try_uboot; then
	trap - INT QUIT
	echo
	echo "NPU 写完了（U-Boot 路径），它正在重启。"
	printf '按回车返回菜单...'
	read -r _
	exit 0
fi
echo "== U-Boot 那条路没走通，看 NBD（默认禁用）"

if [ "${SKIP_NBD:-1}" = 1 ]; then
	echo "== NBD 已禁用（SKIP_NBD=1），跳过这一级"
	trap - INT QUIT
	try_rescue
	exit 1
fi

echo "== 1/6 确认 NPU 上有 nbd-server"
echo "   （在 NPU 上查一遍；没有就装，apt 走它自己的外网，最多等 3 分钟）"
if ! npu_ssh 'command -v nbd-server' >/dev/null 2>&1; then
	echo "   没有，试着装一下"
	npu_ssh 'apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq nbd-server' || {
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
materialize_boot_names "$MNT" || true
sync
echo "   rootfs: $(du -sh "$MNT" 2>/dev/null | cut -f1)"
umount "$MNT"

echo "== 6/6 断开、让它重启"
cleanup_nbd
npu_ssh "pkill -f 'nbd-server -C /etc/nbd-server/xgs87.conf' 2>/dev/null || true
	(sleep 1; reboot) >/dev/null 2>&1 &" || true

echo
echo "NPU 写完了，正在重启。等它起来后菜单选 3 看状态。"
trap - INT QUIT
printf '按回车返回菜单...'
read -r _
exit 0