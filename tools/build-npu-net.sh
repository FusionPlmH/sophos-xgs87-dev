#!/bin/bash
# Build the network-side modules for the NPU: the 88E6193X switch driver and
# the PPv2 MAC driver.
#
# Both are patched copies of the distribution source:
#   net/patches/000{1,2}-*.patch  the two TCAM policy checks that are not in
#                                 6.12.y (a user port could read or delete
#                                 another port's policy rule)
#   MVPP2_AGGR_TXQ_SIZE 256 -> 512
#                                 256 aggregated TX descriptors is thin for a
#                                 10G port; the register field is 10 bits wide
#                                 so 512 still fits
#
# The switch driver must be built with exactly the same object list the
# kernel's own Kbuild uses, otherwise the module loads but DSA never probes
# and all nine front-panel ports simply do not appear.
set -eu

SRC=${SRC:-/srv/lsrc-deb/usr/src/linux-source-6.12}
B=${B:-/srv/npu/build/net}
KDIR=${KDIR:-/usr/src/linux-headers-6.12.117+deb13-arm64}
REPO=$(cd "$(dirname "$0")/.." && pwd)

rm -rf "$B"
mkdir -p "$B/mv88e6xxx" "$B/mvpp2"

cp "$SRC"/drivers/net/dsa/mv88e6xxx/*.c "$SRC"/drivers/net/dsa/mv88e6xxx/*.h "$B/mv88e6xxx/"
cp "$SRC"/drivers/net/ethernet/marvell/mvpp2/*.c \
   "$SRC"/drivers/net/ethernet/marvell/mvpp2/*.h "$B/mvpp2/"

for p in 0001-net-dsa-mv88e6xxx-check-port-on-read.patch \
	 0002-net-dsa-mv88e6xxx-check-port-on-delete.patch; do
	patch -p5 -s -d "$B/mv88e6xxx" < "$REPO/net/patches/$p"
done

sed -i 's/^#define MVPP2_AGGR_TXQ_SIZE\t\t256$/#define MVPP2_AGGR_TXQ_SIZE\t\t512/' \
	"$B/mvpp2/mvpp2.h"
grep -n '^#define MVPP2_AGGR_TXQ_SIZE' "$B/mvpp2/mvpp2.h"

# CONFIG_NET_DSA_MV88E6XXX_PTP and CONFIG_MVPP2_PTP are both off on this
# kernel, so hwtstamp.o/ptp.o and mvpp2_tai.o are deliberately absent.
cat > "$B/mv88e6xxx/Makefile" <<'EOF'
obj-m := mv88e6xxx.o
mv88e6xxx-y := chip.o devlink.o global1.o global1_atu.o global1_vtu.o \
	global2.o global2_avb.o global2_scratch.o pcs-6185.o pcs-6352.o \
	pcs-639x.o phy.o port.o port_hidden.o serdes.o smi.o switchdev.o trace.o
CFLAGS_trace.o := -I$(src)
EOF

cat > "$B/mvpp2/Makefile" <<'EOF'
obj-m := mvpp2.o
mvpp2-y := mvpp2_main.o mvpp2_prs.o mvpp2_cls.o mvpp2_debugfs.o
EOF

chroot /srv/npu make -C "$KDIR" M=/build/net/mv88e6xxx modules
chroot /srv/npu make -C "$KDIR" M=/build/net/mvpp2 modules

echo
echo "WARNING: as of 2026-11-23 the mv88e6xxx built this way loads but DSA"
echo "does not probe (no p1..p8/sfp appears), so the shipped module is still"
echo "the distribution one.  mvpp2 builds and runs fine."
ls -l "$B"/mv88e6xxx/mv88e6xxx.ko "$B"/mvpp2/mvpp2.ko
