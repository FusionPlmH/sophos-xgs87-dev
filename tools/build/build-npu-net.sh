#!/bin/bash
# Build the NPU's network modules: the 88E6193X switch driver and the PPv2 MAC
# driver.  Cross-compiled in the full kernel source tree.
#
# Do not try this against Debian's linux-headers package: its scripts/ are
# aarch64 binaries (fixdep, modpost), so on an x86 host nothing runs.  A full
# tree builds those for the host with the host compiler and cross-compiles
# only the module code, which turns a 20-minute qemu session into seconds.
#
# Prerequisites on the host:
#   apt-get install gcc-14-aarch64-linux-gnu flex bison bc libelf-dev libssl-dev
#   ln -sf aarch64-linux-gnu-gcc-14 /usr/bin/aarch64-linux-gnu-gcc
#
# Patches applied:
#   net/patches/000{1,2}-*.patch   the two TCAM policy checks missing from
#                                  6.12.y (a user port could read or delete
#                                  another port's policy rule)
#   MVPP2_AGGR_TXQ_SIZE 256 -> 512  the register field is 10 bits wide, so 512
#                                  still fits; 256 is thin for a 10G port
set -eu

SRC=${SRC:-/srv/lsrc-deb/usr/src/linux-source-6.12}
OBJ=${OBJ:-/srv/kbuild}
NPU_ROOT=${NPU_ROOT:-/srv/npu}
KVER=${KVER:-6.12.117+deb13-arm64}
ARCH=arm64
CROSS=aarch64-linux-gnu-
REPO=$(cd "$(dirname "$0")/.." && pwd)

mkdir -p "$OBJ"

if [ ! -f "$OBJ/.config" ]; then
	cp "$NPU_ROOT/boot/config-$KVER" "$OBJ/.config"
	# The Debian ABI suffix has to live in CONFIG_LOCALVERSION: a localversion
	# file would stack on top of it, and LOCALVERSION= on the command line is
	# dropped by olddefconfig.
	sed -i "s/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION=\"+deb13-arm64\"/" "$OBJ/.config"
fi

make -C "$SRC" O="$OBJ" ARCH=$ARCH CROSS_COMPILE=$CROSS olddefconfig
make -C "$SRC" O="$OBJ" ARCH=$ARCH CROSS_COMPILE=$CROSS -j"$(nproc)" modules_prepare

# modules_prepare does not produce Module.symvers; borrow the one shipped with
# the headers or modpost leaves ~120 symbols unresolved.
if [ ! -s "$OBJ/Module.symvers" ]; then
	cp "$NPU_ROOT/usr/src/linux-headers-$KVER/Module.symvers" "$OBJ/Module.symvers"
fi

grep UTS_RELEASE "$OBJ/include/generated/utsrelease.h"

cd "$SRC"
if ! grep -q 'policy->port != port' drivers/net/dsa/mv88e6xxx/chip.c; then
	patch -p1 -s < "$REPO/net/patches/0001-net-dsa-mv88e6xxx-check-port-on-read.patch"
	patch -p1 -s < "$REPO/net/patches/0002-net-dsa-mv88e6xxx-check-port-on-delete.patch"
fi
sed -i 's/^#define MVPP2_AGGR_TXQ_SIZE\t\t256$/#define MVPP2_AGGR_TXQ_SIZE\t\t512/' \
	drivers/net/ethernet/marvell/mvpp2/mvpp2.h
grep -n '^#define MVPP2_AGGR_TXQ_SIZE' drivers/net/ethernet/marvell/mvpp2/mvpp2.h

for d in drivers/net/dsa/mv88e6xxx drivers/net/ethernet/marvell/mvpp2; do
	rm -f "$SRC/$d"/*.o "$SRC/$d"/*.ko
	make -C "$SRC" O="$OBJ" ARCH=$ARCH CROSS_COMPILE=$CROSS M="$SRC/$d" modules
done

for k in "$SRC/drivers/net/dsa/mv88e6xxx/mv88e6xxx.ko" \
	 "$SRC/drivers/net/ethernet/marvell/mvpp2/mvpp2.ko"; do
	printf '%s\n  vermagic: %s\n' "$k" "$(modinfo -F vermagic "$k")"
done

cat <<'EOM'

Install them UNCOMPRESSED.  An xz -9 archive uses a 64 MiB dictionary, which
is outside what the kernel's xz decoder accepts; the module then silently
fails with "decompression failed with status 6" and never loads:

    strip --strip-debug mv88e6xxx.ko mvpp2.ko
    cp mv88e6xxx.ko /lib/modules/<kver>/kernel/drivers/net/dsa/mv88e6xxx/
    cp mvpp2.ko     /lib/modules/<kver>/kernel/drivers/net/ethernet/marvell/mvpp2/
    depmod -a && reboot
EOM
