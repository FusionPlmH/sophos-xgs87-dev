#!/bin/bash
# Turn an x86 rootfs tarball into a bootable GPT image for the XGS 87's x86
# side (16 GB eMMC, UEFI only, no CSM).
#
#   sudo ./image/mkdisk.sh --rootfs out/xgs87-x86-full.tar.zst \
#                          --out out/xgs87-x86.img [--size 8G]
#
# Writes ESP (128 MiB, FAT32) + root (ext4, rest), installs GRUB EFI and
# shortens the boot menu the same way the running machine has it (a failed
# boot otherwise waits 30 s on recordfail).
set -eu

ROOTFS=
OUT=out/xgs87-x86.img
SIZE=auto
ESP_MIB=128

while [ $# -gt 0 ]; do
	case "$1" in
	--rootfs) ROOTFS=$2; shift 2 ;;
	--out)    OUT=$2; shift 2 ;;
	--size)   SIZE=$2; shift 2 ;;
	-h|--help) sed -n '2,10p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done

[ -n "$ROOTFS" ] || { echo "--rootfs is required" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

TMP=$(mktemp -d)

cleanup() {
	umount -R "$TMP/root" 2>/dev/null || true
	umount "$TMP/esp" 2>/dev/null || true
	[ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null || true
	rm -rf "$TMP"
}
trap cleanup EXIT

# Smallest image that still holds the root filesystem plus a little slack; the
# first boot grows the root partition to fill whatever disk it was written to,
# so there is no reason to ship a 4 GB image for 700 MB of data.  The ESP is
# part of the same image and CANNOT grow afterwards without moving root, so its
# size is a permanent, build-time decision -- but ext4 needs room for its inode
# table, bitmaps, journal and 5% reserved blocks, so the two are not symmetric.
#
# 128 MiB for the ESP: shim + grub use ~4.4 MiB (measured), so this is ~29x
# headroom.  That covers shim/grub updates (they write the new files before
# dpkg removes the old ones, and --removable keeps a second copy in /EFI/BOOT)
# and one fwupd firmware capsule.  It used to be 476 MiB, which was 40% of the
# uncompressed image for nothing.
if [ "$SIZE" = auto ]; then
	BYTES=$(zstd -dc "$ROOTFS" | wc -c)
	SIZE=$(( ((BYTES + BYTES * 5 / 100 + 192 * 1024 * 1024
		+ ESP_MIB * 1048576) / 1048576 + 1) * 1048576 ))
fi

echo "== create $OUT ($SIZE bytes)"
rm -f "$OUT"
truncate -s "$SIZE" "$OUT"
sfdisk "$OUT" <<EOF
label: gpt
start=2048, size=$((ESP_MIB * 2048)), type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI"
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="root"
EOF

LOOP=$(losetup -f --show -P "$OUT")
mkfs.vfat -F32 -n EFI "${LOOP}p1" >/dev/null
mkfs.ext4 -q -L root "${LOOP}p2"

mkdir -p "$TMP/root" "$TMP/esp"
mount "${LOOP}p2" "$TMP/root"
mount "${LOOP}p1" "$TMP/esp"

echo "== unpack rootfs"
tar --use-compress-program=unzstd -xpf "$ROOTFS" -C "$TMP/root"

ROOT_UUID=$(blkid -s UUID -o value "${LOOP}p2")
ESP_UUID=$(blkid -s UUID -o value "${LOOP}p1")
cat > "$TMP/root/etc/fstab" <<EOF
UUID=$ROOT_UUID  /           ext4  defaults,noatime,errors=remount-ro  0 1
UUID=$ESP_UUID   /boot/efi   vfat  umask=0077                          0 1
EOF

echo "== grub + shim"
mkdir -p "$TMP/root/boot/efi"
mount --bind "$TMP/esp" "$TMP/root/boot/efi"
for d in dev proc sys; do mount --bind /$d "$TMP/root/$d"; done

# Short boot menu: 26 s instead of 70 s.  RECORDEFAIL_TIMEOUT keeps it short
# even after a bad shutdown, which would otherwise hide the menu for 30 s.
cat > "$TMP/root/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=2
GRUB_RECORDFAIL_TIMEOUT=2
GRUB_DISTRIBUTOR="XGS87"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="console=ttyS0,115200n8"
GRUB_TERMINAL="serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
EOF

chroot "$TMP/root" grub-install --target=x86_64-efi --efi-directory=/boot/efi \
	--bootloader-id=debian --removable --no-nvram
chroot "$TMP/root" update-grub

# 这块板子的 BIOS 执行的是 ESP 上的**兜底路径** \EFI\BOOT\BOOTX64.EFI（--removable 产
# 的那个），NVRAM 里那条 debian 项丢了也还能起。所以兜底文件必须真的在盘上：缺了它
# 镜像看起来完全正常，但机器上"BIOS 认得出 U 盘、却一个字符都不打就 reset"，
# 而且从机器本身没有任何办法修（2026-11-26 就是这么卡了半天）。
ls -l "$TMP/esp/EFI/BOOT" | sed 's/^/   /'
[ -s "$TMP/esp/EFI/BOOT/BOOTX64.EFI" ] ||
	{ echo "== ERROR: ESP 里没有 /EFI/BOOT/BOOTX64.EFI —— 这块板子起不来" >&2; exit 1; }
[ -s "$TMP/esp/EFI/debian/shimx64.efi" ] || [ -s "$TMP/esp/EFI/debian/grubx64.efi" ] ||
	echo "== warning: /EFI/debian 里既没有 shimx64.efi 也没有 grubx64.efi（只靠兜底路径也能起，但 NVRAM 项会指空）" >&2

# Prove the ESP sizing in the build log instead of finding out on a machine that
# will not boot: a full ESP means grub-install fails and the next update bricks it.
df -h "$TMP/esp" | sed -n '1,2p'
ESP_USE=$(df --output=pcent "$TMP/esp" | tail -1 | tr -dc '0-9')
[ "${ESP_USE:-0}" -lt 80 ] ||
	echo "== warning: ESP is ${ESP_USE}% full; raise ESP_MIB in $0" >&2

for d in dev proc sys; do umount "$TMP/root/$d"; done
umount "$TMP/root/boot/efi"

echo "== done"
ls -lh "$OUT"
echo
echo "Write it with:  dd if=$OUT of=/dev/sdX bs=4M conv=fsync status=progress"
echo "  ^ whole DISK (/dev/sdX), never a partition (/dev/sdX1) - and this artifact IS"
echo "    a full-disk image (it has a partition table), so writing it to a partition"
echo "    destroys that partition while leaving the old table in place."
echo "  ^ after writing: sfdisk -d /dev/sdX   (the table must read back)"
echo "The XGS 87 BIOS boots \\EFI\\BOOT\\BOOTX64.EFI from the ESP, so --removable matters."
