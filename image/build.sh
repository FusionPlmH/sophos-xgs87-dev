#!/bin/bash
# Build a Debian root filesystem for the XGS 87.
#
#   ./image/build.sh --arch arm64                 # NPU, DKMS modules + toolchain
#   ./image/build.sh --arch amd64                 # x86, same
#   ./image/build.sh --arch amd64 --variant lean  # modules built, no compiler
#   ./image/build.sh --arch arm64 --variant base  # skeleton only, no modules
#
# Needs root (mmdebstrap).  Cross-arch builds need qemu-user-static with binfmt
# registered on the host; the CI workflows avoid that by running each rootfs on
# a native runner instead.
#
# variants
#   full (default) : + dkms + build-essential + headers, the modules are built
#                    and installed during the build, and a later kernel upgrade
#                    rebuilds them automatically.  ~350 MB compressed, ~900 MB
#                    unpacked.
#   lean           : the same modules, built once with plain make, then the
#                    compiler and headers are purged again.  ~380 MiB smaller
#                    unpacked; the price is that the image cannot rebuild the
#                    modules itself, so the kernel is held.
#   base           : minbase + the packages below, no compiler, no modules.
#                    Use it when the root partition is small; then run
#                    kernel/<side>/install.sh once on the device.
set -eu

ARCH=arm64
VARIANT=full
SUITE=trixie
MIRROR=http://deb.debian.org/debian
OUT=
BOARD_DTB=
REPO=$(cd "$(dirname "$0")/.." && pwd)

while [ $# -gt 0 ]; do
	case "$1" in
	--arch)    ARCH=$2; shift 2 ;;
	--variant) VARIANT=$2; shift 2 ;;
	--suite)   SUITE=$2; shift 2 ;;
	--mirror)  MIRROR=$2; shift 2 ;;
	--out)     OUT=$2; shift 2 ;;
	--dtb)     BOARD_DTB=$2; shift 2 ;;
	-h|--help) sed -n '2,24p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done

case "$ARCH" in
amd64) SIDE=x86 ;;
arm64) SIDE=npu ;;
*) echo "--arch must be amd64 or arm64" >&2; exit 1 ;;
esac
case "$VARIANT" in
full|lean|base) ;;
*) echo "--variant must be full, lean or base" >&2; exit 1 ;;
esac

OUT=${OUT:-$REPO/out/xgs87-$SIDE-$VARIANT.tar.zst}
case "$OUT" in
*.zst) ;;
*) OUT=$OUT.zst ;;   # 后面固定做 zstd，不带扩展名会让 TAR 和 OUT 撞成同一个文件
esac
mkdir -p "$(dirname "$OUT")"
[ "$(id -u)" = 0 ] || { echo "run as root (mmdebstrap)" >&2; exit 1; }

PKGS=$({ cat "$REPO/image/packages-common.list"; echo; cat "$REPO/image/packages-$SIDE.list"; } |
	grep -v '^#' | grep -v '^$' | paste -sd, -)
if [ "$VARIANT" = full ]; then
	PKGS="$PKGS,dkms,build-essential,linux-headers-$ARCH"
fi
# lean installs the compiler inside the chroot (image/setup.sh) so it can purge
# exactly the packages it added; only full keeps the toolchain in the image.

echo "== $ARCH / $VARIANT -> $OUT"
TAR=${OUT%.zst}
rm -f "$OUT" "$TAR"

# The board tree that lands in the image.  A prebuilt DTB (--dtb) is added on
# top: the NPU's bootcmd_deb loads /boot/cn9130-sophos-xgs87w-sfp10g.dtb by
# fixed name, so an image without it cannot boot, and until now only the
# installer copied it in -- a bare `tar -x` (or any other install path) left the
# machine unbootable.  copy-in needs a real file, so stage a directory.
STAGE_BOARD=$(mktemp -d)
cp -f "$REPO"/board/* "$STAGE_BOARD"/ 2>/dev/null || true
if [ -n "$BOARD_DTB" ]; then
	[ -f "$BOARD_DTB" ] || { echo "--dtb: no such file: $BOARD_DTB" >&2; exit 1; }
	cp -f "$BOARD_DTB" "$STAGE_BOARD/cn9130-sophos-xgs87w-sfp10g.dtb"
	echo "== board dtb: $BOARD_DTB"
fi

# These machines have no screen, no keyboard and no translator: drop the doc
# tree (keeping the copyright files dpkg policy asks for), the man pages, the
# gettext catalogs and the locale sources.  ~100 MB that never gets read, and
# excluding them at unpack time is free -- deleting them afterwards is not.
mmdebstrap \
	--architectures="$ARCH" \
	--variant=minbase \
	--components="main contrib non-free-firmware" \
	--include="$PKGS" \
	--dpkgopt='path-exclude=/usr/share/doc/*' \
	--dpkgopt='path-include=/usr/share/doc/*/copyright' \
	--dpkgopt='path-exclude=/usr/share/man/*' \
	--dpkgopt='path-exclude=/usr/share/locale/*' \
	--dpkgopt='path-exclude=/usr/share/i18n/*' \
	--customize-hook='mkdir -p "$1/opt/xgs87/systemd" "$1/opt/xgs87/kernel" "$1/opt/xgs87/board"' \
	--customize-hook="sync-in $REPO/image/overlay/common /" \
	--customize-hook="sync-in $REPO/image/overlay/$SIDE /" \
	--customize-hook="sync-in $REPO/systemd /opt/xgs87/systemd" \
	--customize-hook="sync-in $REPO/kernel /opt/xgs87/kernel" \
	--customize-hook="sync-in $STAGE_BOARD /opt/xgs87/board" \
	--customize-hook="copy-in $REPO/image/setup.sh /tmp" \
	--customize-hook="chroot \$1 /bin/sh /tmp/setup.sh $SIDE $VARIANT" \
	"$SUITE" "$TAR" "$MIRROR"

echo "== compress"
zstd -T0 -10 --rm -f "$TAR" -o "$OUT"
ls -lh "$OUT"
echo
echo "x86: ./image/mkdisk.sh --rootfs $OUT --out out/xgs87-x86.img"
echo "NPU: on the running NPU, unpack into a spare partition and point bootcmd at it"
