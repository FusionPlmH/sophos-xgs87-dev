#!/bin/bash
# Build a Debian root filesystem for the XGS 87.
#
#   ./image/build.sh --arch arm64                 # NPU, everything included
#   ./image/build.sh --arch amd64                 # x86, everything included
#   ./image/build.sh --arch arm64 --variant base  # skeleton only, no toolchain
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
#   base           : minbase + the packages below, no compiler, no modules.
#                    Use it when the root partition is small; then run
#                    kernel/<side>/install.sh once on the device.
set -eu

ARCH=arm64
VARIANT=full
SUITE=trixie
MIRROR=http://deb.debian.org/debian
OUT=
REPO=$(cd "$(dirname "$0")/.." && pwd)

while [ $# -gt 0 ]; do
	case "$1" in
	--arch)    ARCH=$2; shift 2 ;;
	--variant) VARIANT=$2; shift 2 ;;
	--suite)   SUITE=$2; shift 2 ;;
	--mirror)  MIRROR=$2; shift 2 ;;
	--out)     OUT=$2; shift 2 ;;
	-h|--help) sed -n '2,19p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done

case "$ARCH" in
amd64) SIDE=x86 ;;
arm64) SIDE=npu ;;
*) echo "--arch must be amd64 or arm64" >&2; exit 1 ;;
esac
case "$VARIANT" in
full|base) ;;
*) echo "--variant must be full or base" >&2; exit 1 ;;
esac

OUT=${OUT:-$REPO/out/xgs87-$SIDE-$VARIANT.tar.zst}
mkdir -p "$(dirname "$OUT")"
[ "$(id -u)" = 0 ] || { echo "run as root (mmdebstrap)" >&2; exit 1; }

PKGS=$({ cat "$REPO/image/packages-common.list"; echo; cat "$REPO/image/packages-$SIDE.list"; } |
	grep -v '^#' | grep -v '^$' | paste -sd, -)
if [ "$VARIANT" = full ]; then
	PKGS="$PKGS,dkms,build-essential,linux-headers-$ARCH"
fi

echo "== $ARCH / $VARIANT -> $OUT"
TAR=${OUT%.zst}
rm -f "$OUT" "$TAR"

mmdebstrap \
	--architectures="$ARCH" \
	--variant=minbase \
	--components="main contrib non-free-firmware" \
	--include="$PKGS" \
	--customize-hook='mkdir -p "$1/opt/xgs87/systemd" "$1/opt/xgs87/kernel" "$1/opt/xgs87/board"' \
	--customize-hook="sync-in $REPO/image/overlay/common /" \
	--customize-hook="sync-in $REPO/image/overlay/$SIDE /" \
	--customize-hook="sync-in $REPO/systemd /opt/xgs87/systemd" \
	--customize-hook="sync-in $REPO/kernel /opt/xgs87/kernel" \
	--customize-hook="sync-in $REPO/board /opt/xgs87/board" \
	--customize-hook="copy-in $REPO/image/setup.sh /tmp" \
	--customize-hook="chroot \$1 /bin/sh /tmp/setup.sh $SIDE $VARIANT" \
	"$SUITE" "$TAR" "$MIRROR"

echo "== compress"
zstd -T0 -10 --rm -f "$TAR" -o "$OUT"
ls -lh "$OUT"
echo
echo "x86: ./image/mkdisk.sh --rootfs $OUT --out out/xgs87-x86.img"
echo "NPU: on the running NPU, unpack into a spare partition and point bootcmd at it"
