#!/bin/bash
# Build the x86 side of the vNTB link (ntb.ko, ntb_hw_epf.ko,
# ntb_transport.ko, ntb_netdev.ko) against the running Debian kernel.
#
# Debian does not ship the NTB stack, so the modules are built out of tree
# from the matching upstream source.  The source version must be compatible
# with the running kernel: 6.12.117 sources call ntb_get_dma_dev(), which does
# not exist in 6.12.94, so 6.12.94 headers cannot build those sources.
set -eu

SRC=${SRC:-/srv/lsrc-deb/usr/src/linux-source-6.12}
B=${B:-/srv/x86build}
# Take the headers from whatever the image actually ships instead of pinning a
# version here -- the pin was still 6.12.94 while the images moved to 6.12.117.
KD=${KD:-$(ls -d /usr/src/linux-headers-* 2>/dev/null | sort -V | tail -1)}
REPO=$(cd "$(dirname "$0")/../.." && pwd)

rm -rf "$B"
mkdir -p "$B/src/drivers/ntb/hw/epf"

for f in core.c ntb_transport.c; do
	cp "$SRC/drivers/ntb/$f" "$B/${f/core/ntb_core}"
done
cp "$SRC/drivers/net/ntb_netdev.c" "$B/ntb_netdev.c"

cp "$SRC/drivers/ntb/hw/epf/ntb_hw_epf.c" "$B/src/drivers/ntb/hw/epf/"
(cd "$B/src" && patch -p1 -s < "$REPO/ntb/0101-ntb_hw_epf.patch")
cp "$B/src/drivers/ntb/hw/epf/ntb_hw_epf.c" "$B/ntb_hw_epf.c"

cat > "$B/Makefile" <<'EOF'
obj-m := ntb_core.o ntb_transport.o ntb_netdev.o ntb_hw_epf.o
EOF

# pahole older than 1.26 cannot do BTF, so turn module BTF off.
make -C "$KD" M="$B" modules CONFIG_DEBUG_INFO_BTF_MODULES=

ls -l "$B"/*.ko
for k in "$B"/*.ko; do echo "$(basename "$k"): $(modinfo -F vermagic "$k")"; done
