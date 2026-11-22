#!/bin/bash
#
# Build the out-of-tree modules the Debian arm64 kernel does not ship
# for the Sophos XGS 87 NPU (Marvell CN9130 / CP115).
#
#   clkfix.ko      keeps the EIP197 crypto clocks enabled (they are gated
#                  by clk_disable_unused() because no driver claims them)
#   spi-orion.ko   CP115 SPI controller (CONFIG_SPI_ORION is not built by
#                  Debian arm64), needed for /proc/mtd and fw_printenv
#
# Run inside a Debian 13 arm64 rootfs that has
#   linux-headers-$(uname -r)  (or the matching version) + build-essential.
#
# Usage: ./build.sh <linux-source-dir> [kdir]
set -e

SRC=${1:?usage: $0 <linux-source-dir> [kdir]}
KDIR=${2:-/usr/src/linux-headers-$(uname -r)}
OUT=$(cd "$(dirname "$0")" && pwd)/out

echo "kernel build dir : $KDIR"
echo "kernel source    : $SRC"
echo "output           : $OUT"

[ -e "$KDIR/Makefile" ] || { echo "missing $KDIR (install linux-headers-*)"; exit 1; }
[ -e "$SRC/drivers/spi/spi-orion.c" ] || { echo "missing spi-orion.c in $SRC"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/clkfix" "$OUT/spi-orion"

cp "$(dirname "$0")/clkfix/clkfix.c" "$OUT/clkfix/"
printf 'obj-m := clkfix.o\n' > "$OUT/clkfix/Makefile"
make -C "$KDIR" M="$OUT/clkfix" modules

cp "$SRC/drivers/spi/spi-orion.c" "$OUT/spi-orion/"
printf 'obj-m := spi-orion.o\n' > "$OUT/spi-orion/Makefile"
make -C "$KDIR" M="$OUT/spi-orion" modules

echo
echo "built:"
find "$OUT" -name '*.ko' -exec ls -l {} \;
echo
echo "install:"
echo "  cp $OUT/*/*.ko /lib/modules/\$(uname -r)/extra/ && depmod -a"
echo "  echo -e 'spi-orion\\nclkfix' > /etc/modules-load.d/xgs87-hardware.conf"
