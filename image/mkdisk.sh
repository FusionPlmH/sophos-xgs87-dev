#!/bin/bash
# Turn an x86 rootfs tarball into a bootable GPT image for the XGS 87's x86
# side (16 GB eMMC, UEFI only, no CSM).
#
#   sudo ./image/mkdisk.sh --rootfs out/xgs87-x86-full.tar.zst \
#                          --out out/xgs87-x86.img [--size 8G]
#
# Writes ESP (476 MiB, FAT32) + root (ext4, rest), installs GRUB EFI and
# shortens the boot menu the same way the running machine has it (a failed
# boot otherwise waits 30 s on recordfail).
set -eu

ROOTFS=
OUT=out/xgs87-x86.img
SIZE=auto
ESP_MIB=476

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
# first boot grows the partition to fill whatever disk it was written to, so
# there is no reason to ship a 4 GB image for 700 MB of data.  The ESP is part
# of the same image, so its 476 MiB has to be added on top of the root size --
# and ext4 needs room for its inode table, bitmaps, journal and 5% reserved
# blocks, hence the 15% + 256 MiB on the data.
if [ "$SIZE" = auto ]; then
	BYTES=$(zstd -dc "$ROOTFS" | wc -c)
	SIZE=$(( ((BYTES + BYTES * 15 / 100 + 256 * 1024 * 1024
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

# Short boot menu: 26 s instead of 70 s (see docs/20 20.8).
cat > "$TMP/root/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=2
GRUB_RECORDFAIL_TIMEOUT=2
GRUB_DISTRIBUTOR="XGS87"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX=""
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
EOF

chroot "$TMP/root" grub-install --target=x86_64-efi --efi-directory=/boot/efi \
	--bootloader-id=debian --removable --no-nvram
chroot "$TMP/root" update-grub

for d in dev proc sys; do umount "$TMP/root/$d"; done
umount "$TMP/root/boot/efi"

echo "== done"
ls -lh "$OUT"
echo
echo "Write it with:  dd if=$OUT of=/dev/sdX bs=4M conv=fsync status=progress"
echo "The XGS 87 BIOS boots \\EFI\\BOOT\\BOOTX64.EFI from the ESP, so --removable matters."
