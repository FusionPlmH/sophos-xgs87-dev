#!/bin/bash
# Build the NPU's out-of-tree vNTB module set.
#
# The NPU has no compiler, so this runs the Debian arm64 build inside the
# NPU's own rootfs (mounted at /srv/npu, qemu user-mode) against the identical
# kernel headers it runs.  Every source change lives in ntb/*.patch; to add
# one, edit the patched tree, then regenerate the patch with diff -u.
#
#   ./tools/build/build-npu-vntb.sh            # build
#   B=/tmp/ntb ./tools/build/build-npu-vntb.sh # build somewhere else
set -eu

SRC=${SRC:-/srv/lsrc-deb/usr/src/linux-source-6.12}
B=${B:-/srv/npu/build/ntb}
KDIR=${KDIR:-/usr/src/linux-headers-6.12.117+deb13-arm64}
REPO=$(cd "$(dirname "$0")/.." && pwd)

rm -rf "$B"
mkdir -p "$B/src"

apply() {	# apply <patch-name> <path-relative-to-kernel> <output-name>
	patchname=$1
	rel=$2
	out=$3
	mkdir -p "$B/src/$(dirname "$rel")"
	cp "$SRC/$rel" "$B/src/$rel"
	(cd "$B/src" && patch -p1 -s < "$REPO/ntb/$patchname")
	cp "$B/src/$rel" "$B/$out"
}

apply 0001-pci-epf-vntb.patch		drivers/pci/endpoint/functions/pci-epf-vntb.c	pci_epf_vntb.c
apply 0002-pcie-designware-plat.patch	drivers/pci/controller/dwc/pcie-designware-plat.c	pcie_dw_plat.c
apply 0003-pci-ep-cfs.patch		drivers/pci/endpoint/pci-ep-cfs.c		pci_ep_cfs.c

cp "$SRC/drivers/ntb/core.c"				"$B/ntb_core.c"
cp "$SRC/drivers/ntb/ntb_transport.c"			"$B/ntb_transport.c"
cp "$SRC/drivers/net/ntb_netdev.c"			"$B/ntb_netdev.c"
cp "$SRC/drivers/pci/controller/dwc/pcie-designware.h"	"$B/pcie-designware.h"

cat > "$B/Makefile" <<'EOF'
obj-m := ntb_core.o ntb_transport.o ntb_netdev.o pci_ep_cfs.o pci_epf_vntb.o pcie_dw_plat.o
ccflags-y := -DCONFIG_PCIE_DW_PLAT_EP=1 -DCONFIG_PCI_ENDPOINT_CONFIGFS=1
EOF

# The chroot sees the build dir as /build/ntb.
chroot /srv/npu make -C "$KDIR" M=/build/ntb modules

ls -l "$B"/*.ko
echo "install with: xz -9 -k -f <mod>.ko && cp <mod>.ko.xz /lib/modules/$(uname -r)/extra/"
