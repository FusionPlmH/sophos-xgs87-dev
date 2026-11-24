#!/bin/sh
# Grow the root partition to fill the disk on first boot.
#
# The images are built at the smallest size that holds the root filesystem, so
# the download stays small and the same image can be written to the 16 GB eMMC
# or to a bigger card.  This runs once and leaves a marker behind.
set -eu

MARKER=/var/lib/xgs87/grown
[ -e "$MARKER" ] && exit 0

ROOT=$(findmnt -n -o SOURCE /)
case "$ROOT" in
/dev/*) ;;
*)
	echo "xgs87-growroot: root is not on a block device ($ROOT), skipping"
	mkdir -p /var/lib/xgs87; : > "$MARKER"
	exit 0
	;;
esac

DISK=/dev/$(lsblk -no pkname "$ROOT")
PART=$(cat "/sys/class/block/$(basename "$ROOT")/partition")

# Only grow the last partition.  On the NPU, p2 is followed by p3 (factory
# rollback) and p4 (VPD); growing p2 to the end of the disk would try to eat
# them.  growpart normally refuses, but do not even ask.
LAST=$(lsblk -ln -o PARTN "$DISK" 2>/dev/null | sed '/^$/d' | sort -n | tail -1)
if [ -n "$LAST" ] && [ "$PART" != "$LAST" ]; then
	echo "xgs87-growroot: $ROOT is partition $PART of $DISK, not the last ($LAST); not growing"
	mkdir -p /var/lib/xgs87; : > "$MARKER"
	exit 0
fi

echo "xgs87-growroot: growing $DISK partition $PART ($ROOT)"
# The image is written with dd, so the GPT still says "the disk ends where the
# image ended" and the backup header sits in the middle of the real device.
# growpart refuses to touch a table in that state, so move the header first
# (this is what xgs87-usbstore.sh already did for the maintenance stick).
if command -v sgdisk >/dev/null 2>&1; then
	sgdisk -e "$DISK" >/dev/null 2>&1 ||
		echo "xgs87-growroot: sgdisk -e failed (table may still be short)" >&2
fi
# growpart rewrites the partition entry and nudges the kernel; the kernel
# refuses a full table re-read for a mounted disk, which growpart knows about.
grown=1
growpart "$DISK" "$PART" || {
	echo "xgs87-growroot: growpart refused; leaving root at its current size" >&2
	grown=0
}
if [ "$grown" = 1 ]; then
	resize2fs "$ROOT" || {
		echo "xgs87-growroot: resize2fs failed, will retry on next boot" >&2
		grown=0
	}
fi

if [ "$grown" = 1 ]; then
	mkdir -p /var/lib/xgs87
	: > "$MARKER"
fi
df -h / || true