#!/bin/bash
# Install the x86 side of the XGS 87: NTB modules (via DKMS) and the units
# that keep the link to the NPU alive.
#
# Run as root on the x86 (Debian 13), from a clone of this repository.
#
#   ./kernel/x86/install.sh
set -eu

REPO=$(cd "$(dirname "$0")/../.." && pwd)
PKG=xgs87-x86
VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$REPO/kernel/x86/dkms.conf")

die() { echo "error: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"

echo "== packages"
apt-get install -y dkms "linux-headers-$(uname -r)" >/dev/null || \
	die "cannot install dkms / linux-headers-$(uname -r)"

echo "== dkms $PKG/$VER"
dkms remove "$PKG/$VER" --all >/dev/null 2>&1 || true
rm -rf "/usr/src/$PKG-$VER"
mkdir -p "/usr/src/$PKG-$VER"
cp "$REPO"/kernel/x86/*.c "$REPO"/kernel/x86/Makefile "$REPO"/kernel/x86/dkms.conf \
	"/usr/src/$PKG-$VER/"
dkms add "$PKG/$VER" >/dev/null
dkms build "$PKG/$VER" >/dev/null
dkms install "$PKG/$VER" --force >/dev/null
echo "   installed for $(dkms status "$PKG" | sed 's/.*: //' | tr '\n' ' ')"

echo "== systemd units"
install -m755 "$REPO"/systemd/x86/*.sh /usr/local/sbin/
install -m644 "$REPO"/systemd/x86/*.service /etc/systemd/system/
install -m644 "$REPO"/systemd/x86/31-house-lan.network /etc/systemd/network/ 2>/dev/null || true
systemctl daemon-reload
systemctl enable xgs-ntb xgs-ntb-watch xgs-ntb-stop xgs-netconsole >/dev/null
systemctl enable systemd-networkd >/dev/null 2>&1 || true

cat <<EOM

Done.  Next:
  systemctl start xgs-ntb xgs-ntb-watch xgs-netconsole
  journalctl -u xgs-ntb -n 20

The link is only useful if the NPU end is up (kernel/npu/install.sh there).
EOM
