#!/bin/bash
# 用 debian-x86.img + debian-npu.tar.zst 拼一条自用维护 U 盘（diagnostic USB）。
#
#   ./installer/mkusb.sh \
#       --x86 out/debian-x86.img.zst \
#       --npu out/debian-npu.tar.zst \
#       --dtb out/cn9130-sophos-xgs87w-sfp10g.dtb \
#       --out out/debian-usb.img
#
# 镜像里只有 ESP + root 两个分区：安装用的 payload（x86 整盘镜像、NPU 的 tar、
# DTB、菜单脚本）直接放进 root 的 /opt/xgs87/payload，所以不用另切一个分区，
# 也不会因为预留大小估错而浪费。
#
# U 盘上剩下的空间不预先切出来：第一次开机由 xgs87-usbstore.service
# （installer/payload/usbstore.sh）把盘尾做成一个 exfat 分区（标签 XGS87BAK），
# 挂到 /media/xgs87-bak，用来放原厂/整盘备份。
#
# 这台机器没有显示接口，菜单跑在 /dev/ttyS0（RJ45 / micro-USB 那个 115200 控制台）。
#
# --rescue 可选：tools/build/build-rescue.sh 产出的小急救包（Image.lzma +
# initramfs.xz，约 2.1 MB）。NPU 起不来、也没有 USB 网卡做物理旁路时，菜单 2 的
# 最后一级会把这段走串口推进 U-Boot，起来后由 x86 喂整盘影像。
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
X86=
NPU=
DTB=
RESCUE=
OUT=$REPO/out/debian-usb.img
MENU_TTY=/dev/ttyS0
PAYLOAD_DIR=/opt/xgs87/payload

while [ $# -gt 0 ]; do
	case "$1" in
	--x86)   X86=$2; shift 2 ;;
	--npu)   NPU=$2; shift 2 ;;
	--dtb)   DTB=$2; shift 2 ;;
	--rescue) RESCUE=$2; shift 2 ;;
	--out)   OUT=$2; shift 2 ;;
	--tty)   MENU_TTY=$2; shift 2 ;;
	-h|--help) sed -n '2,19p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done
[ -n "$X86" ] && [ -n "$NPU" ] || { echo "--x86 and --npu are required" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

WORK=$(mktemp -d)
LOOP=
cleanup() {
	umount "$WORK/root" 2>/dev/null || true
	[ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
	rm -rf "$WORK"
}
trap cleanup EXIT

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

echo "== 解开 x86 镜像"
zstd -dc "$X86" > "$WORK/base.img"

# root 分区要额外装下：x86 的整盘镜像（装回内置盘用）、NPU 的 tar、DTB。
NEED=$(( $(stat -c %s "$X86") + $(stat -c %s "$NPU") ))
[ -n "$DTB" ] && NEED=$(( NEED + $(stat -c %s "$DTB") ))
GROW_MB=$(( NEED / 1048576 + 64 ))

echo "== root 分区扩 ${GROW_MB} MiB 装 payload"
cp --sparse=always "$WORK/base.img" "$OUT"
truncate -s "+${GROW_MB}M" "$OUT"

# p2 是最后一个分区，直接把它撑到新盘尾（末尾 34 扇区留给 GPT 备份头）。
read -r P2_START P2_SIZE <<EOP
$(sfdisk -d "$OUT" |
	sed -n 's/.*start=[[:space:]]*\([0-9]*\), size=[[:space:]]*\([0-9]*\).*/\1 \2/p' |
	sed -n 2p)
EOP
[ -n "${P2_START:-}" ] || { echo "读不出 $OUT 的分区表" >&2; exit 1; }
TOTAL_SECT=$(( $(stat -c %s "$OUT") / 512 ))
P2_NEW=$(( TOTAL_SECT - 34 - P2_START ))
[ "$P2_NEW" -gt "$P2_SIZE" ] || { echo "p2 撑不开：$P2_SIZE -> $P2_NEW" >&2; exit 1; }
printf 'start=%s, size=%s\n' "$P2_START" "$P2_NEW" |
	sfdisk --force --no-reread -N 2 "$OUT" >/dev/null

LOOP=$(losetup -f --show -P "$OUT")
ROOT_DEV=$(part_dev 2) || exit 1
e2fsck -f -y "$ROOT_DEV" >/dev/null 2>&1 || true
resize2fs "$ROOT_DEV" >/dev/null

mkdir -p "$WORK/root"
mount "$ROOT_DEV" "$WORK/root"

# The USB image starts life as a copy of debian-x86.img, so its root filesystem
# UUID and its partition GUIDs are *identical* to the installed system's.  Two
# consequences, both seen on real hardware on 2026-11-25:
#   - `search.fs_uuid <root>` and `root=UUID=<root>` match whichever disk the
#     firmware enumerated first, so the stick happily boots the internal system
#     (and vice versa);
#   - the UEFI boot entry "…HD(1,GPT,<guid>)" matches the internal ESP too, so
#     "boot from USB" can load the internal GRUB.
# Give the stick its own identity before anything else is written into it.
echo "== 给 U 盘换一套自己的 UUID/GUID"
OLD_ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
umount "$WORK/root"
e2fsck -f -y "$ROOT_DEV" >/dev/null 2>&1 || true
NEW_ROOT_UUID=$(cat /proc/sys/kernel/random/uuid)
tune2fs -U "$NEW_ROOT_UUID" "$ROOT_DEV" >/dev/null
sgdisk -G "$OUT" >/dev/null 2>&1 || echo "   （sgdisk -G 失败，分区 GUID 仍然是旧的）" >&2
LOOP=$(losetup -d "$LOOP" 2>/dev/null; losetup -f --show -P "$OUT")
ROOT_DEV=$(part_dev 2) || exit 1
ESP_DEV=$(part_dev 1) || exit 1
mount "$ROOT_DEV" "$WORK/root"
echo "   root UUID $OLD_ROOT_UUID -> $NEW_ROOT_UUID"

# Everything inside the image that resolves the root by UUID has to follow.
sed -i "s/$OLD_ROOT_UUID/$NEW_ROOT_UUID/g" \
	"$WORK/root/etc/fstab" "$WORK/root/boot/grub/grub.cfg"

echo "== 放 payload 到 $PAYLOAD_DIR"
mkdir -p "$WORK/root$PAYLOAD_DIR"
cp "$X86" "$WORK/root$PAYLOAD_DIR/debian-x86.img.zst"
cp "$NPU" "$WORK/root$PAYLOAD_DIR/debian-npu.tar.zst"
[ -n "$DTB" ] && cp "$DTB" "$WORK/root$PAYLOAD_DIR/"
if [ -n "$RESCUE" ] && [ -f "$RESCUE" ]; then
	cp "$RESCUE" "$WORK/root$PAYLOAD_DIR/xgs87-rescue.tar.zst"
fi
cp -a "$REPO"/installer/payload/. "$WORK/root$PAYLOAD_DIR/"
chown -R 0:0 "$WORK/root$PAYLOAD_DIR"
chmod 755 "$WORK/root$PAYLOAD_DIR"/*.sh

echo "== 往 U 盘系统的 root 里塞菜单"
install -m755 "$REPO/installer/payload/menu.sh" "$WORK/root/usr/local/sbin/xgs87-menu.sh"
install -m755 "$REPO/installer/payload/usbstore.sh" "$WORK/root/usr/local/sbin/xgs87-usbstore.sh"

# 维护盘：控制台直接给 root（密码同 admin）。插上 U 盘的人已经有物理访问权，
# 而 sudo 的密码提示会和串口输出/内核刷屏交错，实机上就是这么把密码敲成命令的。
# 只改这一份 U 盘 rootfs，装进内置盘的系统仍然 root 锁定 + admin/sudo。
if [ "${USB_ROOT_LOGIN:-1}" = 1 ]; then
	chroot "$WORK/root" sh -c "echo 'root:P@ssw0rd' | chpasswd && usermod -s /bin/bash root" ||
		echo "   （U 盘 root 解锁失败，仍然可以用 admin + sudo）" >&2
fi

cat > "$WORK/root/etc/systemd/system/xgs87-usbstore.service" <<'EOF'
[Unit]
Description=XGS 87 维护盘：把 U 盘剩下的空间做成 exfat 备份分区
After=local-fs.target
Before=xgs87-installer.service
ConditionPathExists=/usr/local/sbin/xgs87-usbstore.sh

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/xgs87-usbstore.sh

[Install]
WantedBy=multi-user.target
EOF

cat > "$WORK/root/etc/systemd/system/xgs87-installer.service" <<EOF
[Unit]
Description=XGS 87 维护菜单（串口）
After=multi-user.target xgs87-usbstore.service
Wants=xgs87-usbstore.service
ConditionPathExists=/usr/local/sbin/xgs87-menu.sh
Restart=on-failure
RestartSec=2

[Service]
Type=simple
Environment=TERM=linux
Environment=PAYLOAD=$PAYLOAD_DIR
Environment=STORE=/media/xgs87-bak
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

mkdir -p "$WORK/root/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/xgs87-installer.service \
	"$WORK/root/etc/systemd/system/multi-user.target.wants/xgs87-installer.service"

# 串口和 tty1 交给菜单，别再起 getty。
ln -sf /dev/null "$WORK/root/etc/systemd/system/serial-getty@ttyS0.service"
ln -sf /dev/null "$WORK/root/etc/systemd/system/getty@tty1.service"

# 千万别让 growroot 把 p2 扩到盘尾：那块空间要留给 exfat 备份分区。
rm -f "$WORK/root/etc/systemd/system/multi-user.target.wants/xgs87-growroot.service"

# 但 vNTB 那套要留着：U 盘系统自己也要能上网 —— xgs-ntb 把 eth0 和两条 VLAN
# （eth0.100 WAN、eth0.200 LAN）建起来，systemd-networkd 在 eth0.100 上跑 DHCP，
# 于是从面板 2/WAN 那条上游就能 ssh 进 U 盘系统（或者让它替 NPU 干活）。
# 原来的做法是把这些单元全关掉，结果只能靠串口。

# 串口上的内核 printk 会和 whiptail 抢同一行，U 盘启动时安静点。
if [ -f "$WORK/root/boot/grub/grub.cfg" ]; then
	sed -i -E '/^[[:space:]]*linux[[:space:]]/ s/$/ quiet loglevel=3/' \
		"$WORK/root/boot/grub/grub.cfg"
fi

# The ESP's shim is just `set prefix=($root)/boot/grub; configfile ...`, and
# $root at that point is the ESP itself -- which has no /boot/grub.  Put a copy
# of the menu there, with a search line in front of it so the kernel and initrd
# paths resolve on the stick's own root.  Without this the boot attempt dies and
# the firmware silently falls through to the internal disk.
echo "== 让 U 盘的 ESP 能自己启动"
mkdir -p "$WORK/esp"
mount "$ESP_DEV" "$WORK/esp"
# 兜底启动器必须在盘上。这块板子的 BIOS 执行的是 ESP 的 \EFI\BOOT\BOOTX64.EFI；
# 少了它，机器上是"BIOS 认得出 U 盘、但一个字符都不打就 reset"，而且没法从机器本身修
# （2026-11-26 卡了半天）。CI 里没有真机，只能在这里拦。
[ -s "$WORK/esp/EFI/BOOT/BOOTX64.EFI" ] || {
	echo "== ERROR: U 盘 ESP 里没有 /EFI/BOOT/BOOTX64.EFI —— 这块板子起不来" >&2
	echo "   （x86 镜像里的 grub-install --removable 没生效？看 image/mkdisk.sh）" >&2
	umount "$WORK/esp"; exit 1
}
ls -l "$WORK/esp/EFI/BOOT" | sed 's/^/   /'
mkdir -p "$WORK/esp/boot/grub"
{
	echo "search --no-floppy --fs-uuid --set=root $NEW_ROOT_UUID"
	cat "$WORK/root/boot/grub/grub.cfg"
} > "$WORK/esp/boot/grub/grub.cfg"
sync
umount "$WORK/esp"

sync
umount "$WORK/root"
losetup -d "$LOOP"; LOOP=

echo "== 压缩"
zstd -T0 -10 -f --rm "$OUT" -o "$OUT.zst"
ls -lh "$OUT.zst"
cat <<EOM

写到 U 盘（整条盘都会被覆盖）：
    zstd -d $OUT.zst
    sudo dd if=${OUT%.zst} of=/dev/sdX bs=4M conv=fsync status=progress

U 盘比镜像大多少，第一次开机就能拿到多少 exfat 备份空间（/media/xgs87-bak）。
插到 XGS 87 上，开机选 USB 启动，串口 115200 上就是菜单（$MENU_TTY）。
EOM