#!/bin/bash
# Install the NPU side of the XGS 87: PCIe endpoint + vNTB modules (via DKMS),
# the SPI NOR / clock helper modules, and the units that bring the switch and
# the link to the x86 up.
#
# Run as root on the NPU (Debian 13 arm64), from a clone of this repository.
#
#   ./kernel/npu/install.sh
set -eu

REPO=$(cd "$(dirname "$0")/../.." && pwd)
PKG=xgs87-npu
VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$REPO/kernel/npu/dkms.conf")

die() { echo "error: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"

echo "== packages"
apt-get install -y dkms build-essential "linux-headers-$(uname -r)" >/dev/null || \
	die "cannot install dkms / build-essential / linux-headers-$(uname -r)"

echo "== dkms $PKG/$VER"
dkms remove "$PKG/$VER" --all >/dev/null 2>&1 || true
rm -rf "/usr/src/$PKG-$VER"
mkdir -p "/usr/src/$PKG-$VER"
cp "$REPO"/kernel/npu/*.c "$REPO"/kernel/npu/*.h \
   "$REPO"/kernel/npu/Makefile "$REPO"/kernel/npu/dkms.conf "/usr/src/$PKG-$VER/"
dkms add "$PKG/$VER" >/dev/null
dkms build "$PKG/$VER" >/dev/null
dkms install "$PKG/$VER" --force >/dev/null
echo "   installed for $(dkms status "$PKG" | sed 's/.*: //' | tr '\n' ' ')"

echo "== module autoload"
cat > /etc/modules-load.d/xgs87-hardware.conf <<'EOF'
# XGS 87 NPU: drivers the Debian arm64 kernel does not build
spi-orion
clkfix
EOF

echo "== systemd units"
install -m755 "$REPO"/systemd/npu/*.sh /usr/local/sbin/
install -m644 "$REPO"/systemd/npu/*.service /etc/systemd/system/
# Do not clobber a WAN/LAN layout the operator already tuned.
install -d /etc/xgs87
[ -e /etc/xgs87/net.conf ] ||
	install -m644 "$REPO"/image/overlay/npu/etc/xgs87/net.conf /etc/xgs87/net.conf
systemctl daemon-reload
systemctl enable xgs-ports-up xgs-vntb xgs-net-up \
	xgs-dhcp xgs-netconsole >/dev/null

cat <<EOM

Done.  Next:
  systemctl start xgs-ports-up xgs-vntb xgs-net-up xgs-dhcp xgs-netconsole
  ip -br link            # p1..p8 + sfp must exist

Boot files (/boot/Image, /boot/initrd.img, the DTB) are handled by
/etc/kernel/postinst.d/zz-xgs87-image, installed by the image build or by
hand from image/overlay/npu/.
EOM
