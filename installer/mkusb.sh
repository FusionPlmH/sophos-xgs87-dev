#!/bin/bash
# 用 debian-x86.img + debian-npu.tar.zst 拼一条自用维护 U 盘（diagnostic USB）。
#
#   ./installer/mkusb.sh \
#       --x86 out/debian-x86.img.zst \
#       --npu out/debian-npu.tar.zst \
#       --dtb out/cn9130-sophos-xgs87w-sfp10g.dtb \
#       --out out/debian-usb.img
#
# 做法：先把 x86 的整盘镜像解开，追加一个带标签 XGS87 的 ext4 分区放 payload，
# 再往镜像里的 root 分区塞入 installer 单元，开机后在串口控制台上出菜单。
#
# 这台机器没有显示接口，菜单跑在 /dev/ttyS0（RJ45 / micro-USB 那个 115200 控制台）。
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
X86=
NPU=
DTB=
OUT=$REPO/out/debian-usb.img
EXTRA_MB=512
MENU_TTY=/dev/ttyS0

while [ $# -gt 0 ]; do
	case "$1" in
	--x86)   X86=$2; shift 2 ;;
	--npu)   NPU=$2; shift 2 ;;
	--dtb)   DTB=$2; shift 2 ;;
	--out)   OUT=$2; shift 2 ;;
	--extra) EXTRA_MB=$2; shift 2 ;;
	--tty)   MENU_TTY=$2; shift 2 ;;
	-h|--help) sed -n '2,13p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done
[ -n "$X86" ] && [ -n "$NPU" ] || { echo "--x86 and --npu are required" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

WORK=$(mktemp -d)
LOOP=
cleanup() {
	umount "$WORK/root" 2>/dev/null || true
	umount "$WORK/data" 2>/dev/null || true
	[ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
	rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 解开 x86 镜像"
zstd -dc "$X86" > "$WORK/base.img"

# payload 分区要装下 NPU 的 tar + DTB，再留 EXTRA_MB 给备份。
PAYLOAD_MB=$(( ($(stat -c %s "$NPU") + ${DTB:+$(stat -c %s "$DTB")} + 1048575) / 1048576 + EXTRA_MB ))
echo "== 追加 payload 分区（${PAYLOAD_MB} MiB）"
cp --sparse=always "$WORK/base.img" "$OUT"
# 多给 4 MiB：新分区按 1 MiB 对齐，起点不一定正好落在原来的末尾。
truncate -s "+$((PAYLOAD_MB + 4))M" "$OUT"

LAST_END=$(sfdisk -d "$OUT" |
	sed -n 's/.*start=[[:space:]]*\([0-9]*\), size=[[:space:]]*\([0-9]*\).*/\1 \2/p' |
	awk '{ if ($1 + $2 > m) m = $1 + $2 } END { print m + 0 }')
[ "$LAST_END" -gt 0 ] || { echo "读不出 $OUT 的分区表" >&2; exit 1; }
START=$(( (LAST_END + 2047) / 2048 * 2048 ))
SIZE_SECT=$(( PAYLOAD_MB * 2048 ))
TOTAL_SECT=$(( $(stat -c %s "$OUT") / 512 ))
[ $((START + SIZE_SECT)) -le "$TOTAL_SECT" ] ||
	{ echo "payload 分区放不下：start=$START size=$SIZE_SECT total=$TOTAL_SECT" >&2; exit 1; }
echo "start=$START, size=$SIZE_SECT, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=\"XGS87\"" |
	sfdisk --append "$OUT"

LOOP=$(losetup -f --show -P "$OUT")

# udev normally creates /dev/loopNpM.  Without it (WSL, minimal containers) the
# kernel still registers the partitions in sysfs, so make the node ourselves
# instead of failing on a missing device file.
part_dev() {
	dev=${LOOP}p$1
	node="/sys/class/block/$(basename "$LOOP")p$1/dev"
	i=0
	while [ ! -b "$dev" ] && [ "$i" -lt 50 ]; do
		i=$((i + 1))
		if [ -r "$node" ]; then
			mknod "$dev" b "$(cut -d: -f1 "$node")" "$(cut -d: -f2 "$node")" 2>/dev/null || true
		fi
		sleep 0.1
	done
	[ -b "$dev" ] || { echo "分区设备 $dev 没出现" >&2; return 1; }
	echo "$dev"
}

DATA_DEV=$(part_dev 3) || exit 1
ROOT_DEV=$(part_dev 2) || exit 1
mkfs.ext4 -q -L XGS87 "$DATA_DEV"
mkdir -p "$WORK/data" "$WORK/root"
mount "$DATA_DEV" "$WORK/data"
mount "$ROOT_DEV" "$WORK/root"

echo "== 放 payload"
cp "$X86" "$WORK/data/debian-x86.img.zst"
cp "$NPU" "$WORK/data/debian-npu.tar.zst"
[ -n "$DTB" ] && cp "$DTB" "$WORK/data/"
cp -a "$REPO"/installer/payload/. "$WORK/data/"
chmod 755 "$WORK/data"/*.sh
sync

echo "== 往 U 盘系统的 root 里塞菜单"
cat > "$WORK/root/etc/systemd/system/xgs87-installer.service" <<EOF
[Unit]
Description=XGS 87 维护菜单（串口）
After=multi-user.target run-media-xgs87.mount
Wants=run-media-xgs87.mount
ConditionPathExists=/usr/local/sbin/xgs87-menu.sh
Restart=on-failure
RestartSec=2

[Service]
Type=simple
Environment=TERM=linux
Environment=PAYLOAD=/run/media/xgs87
ExecStart=/usr/local/sbin/xgs87-menu.sh
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=$MENU_TTY
TTYReset=yes
TTYVHangup=yes

[Install]
WantedBy=multi-user.target
EOF
install -m755 "$REPO/installer/payload/menu.sh" "$WORK/root/usr/local/sbin/xgs87-menu.sh"
mkdir -p "$WORK/root/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/xgs87-installer.service \
	"$WORK/root/etc/systemd/system/multi-user.target.wants/xgs87-installer.service"

# 让菜单能找到 payload：把 XGS87 分区挂到固定位置（rw，备份要往里写）。
cat > "$WORK/root/etc/systemd/system/run-media-xgs87.mount" <<'EOF'
[Unit]
Description=XGS87 payload partition
Before=local-fs.target

[Mount]
What=/dev/disk/by-label/XGS87
Where=/run/media/xgs87
Type=ext4
Options=rw,nofail

[Install]
WantedBy=local-fs.target
EOF
mkdir -p "$WORK/root/etc/systemd/system/local-fs.target.wants"
ln -sf /etc/systemd/system/run-media-xgs87.mount \
	"$WORK/root/etc/systemd/system/local-fs.target.wants/run-media-xgs87.mount"

# 串口和 tty1 交给菜单，别再起 getty；U 盘系统也不扩分区、不跑链路单元。
ln -sf /dev/null "$WORK/root/etc/systemd/system/serial-getty@ttyS0.service"
ln -sf /dev/null "$WORK/root/etc/systemd/system/getty@tty1.service"
rm -f "$WORK/root/etc/systemd/system/multi-user.target.wants/xgs87-growroot.service"
for u in xgs-ntb xgs-ntb-watch xgs-ntb-stop xgs-netconsole xgs-npu-console; do
	rm -f "$WORK/root/etc/systemd/system/multi-user.target.wants/$u.service"
done

# 串口上的内核 printk 会和 whiptail 抢同一行，U 盘启动时安静点。
if [ -f "$WORK/root/boot/grub/grub.cfg" ]; then
	sed -i -E '/^[[:space:]]*linux[[:space:]]/ s/$/ quiet loglevel=3/' \
		"$WORK/root/boot/grub/grub.cfg"
fi

sync
umount "$WORK/root" "$WORK/data"
losetup -d "$LOOP"; LOOP=

echo "== 压缩"
zstd -T0 -10 -f --rm "$OUT" -o "$OUT.zst"
ls -lh "$OUT.zst"
cat <<EOM

写到 U 盘（整条盘都会被覆盖）：
    zstd -d $OUT.zst
    sudo dd if=${OUT%.zst} of=/dev/sdX bs=4M conv=fsync status=progress

插到 XGS 87 上，开机选 USB 启动，串口 115200 上就是菜单（$MENU_TTY）。
EOM