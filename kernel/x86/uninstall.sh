#!/bin/bash
# Remove everything kernel/x86/install.sh put in place.
set -eu

PKG=xgs87-x86
VER=1.0.0

systemctl disable --now xgs-ntb-watch xgs-ntb xgs-netconsole 2>/dev/null || true
systemctl stop xgs-ntb-stop 2>/dev/null || true

dkms remove "$PKG/$VER" --all || true
rm -rf "/usr/src/$PKG-$VER"

echo "modules removed; the systemd units and scripts were left in place"
