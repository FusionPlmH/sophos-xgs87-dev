#!/bin/bash
# Remove everything kernel/npu/install.sh put in place.
set -eu

PKG=xgs87-npu
VER=1.0.0

systemctl disable --now xgs-dhcp xgs-net-up xgs-mgmt-bridge xgs-vntb \
	xgs-ports-up xgs-netconsole 2>/dev/null || true

dkms remove "$PKG/$VER" --all || true
rm -rf "/usr/src/$PKG-$VER"
rm -f /etc/modules-load.d/xgs87-hardware.conf

echo "modules removed; the systemd units and scripts were left in place"
