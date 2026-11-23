#!/bin/sh
# Runs inside the chroot at the end of image/build.sh.
#
#   setup.sh <x86|npu> <full|base>
set -eu

SIDE=$1
VARIANT=$2

echo "== setup.sh: side=$SIDE variant=$VARIANT"

case "$SIDE" in
npu) HOSTNAME=xgs87-npu ;;
x86) HOSTNAME=debian ;;
esac
echo "$HOSTNAME" > /etc/hostname
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "$HOSTNAME" > /etc/hosts

# --- units and scripts, straight from the repository ------------------------
install -m755 /opt/xgs87/systemd/"$SIDE"/*.sh /usr/local/sbin/
install -m644 /opt/xgs87/systemd/"$SIDE"/*.service /etc/systemd/system/
mkdir -p /etc/systemd/network
for f in /opt/xgs87/systemd/"$SIDE"/*.network; do
	[ -e "$f" ] && install -m644 "$f" /etc/systemd/network/
done

if [ "$SIDE" = npu ]; then
	# Everything the x86 and the switch need is in the units; the modules are
	# what needs building.
	cat > /etc/modules-load.d/xgs87-hardware.conf <<'EOF'
spi-orion
clkfix
EOF
	# The two boot hooks arrive with image/overlay/npu (they land in
	# /etc/kernel/postinst.d and /etc/initramfs/post-update.d, already
	# executable); just make sure the directories exist.
	chmod 755 /etc/kernel/postinst.d/zz-xgs87-image \
		  /etc/initramfs/post-update.d/zz-xgs87-initrd
	systemctl enable xgs-ports-up xgs-vntb xgs-mgmt-bridge xgs-lan-uplink \
		xgs-lan-dhcp xgs-netconsole
else
	systemctl enable systemd-networkd xgs-ntb xgs-ntb-watch xgs-ntb-stop xgs-netconsole
fi

# --- out-of-tree modules ----------------------------------------------------
if [ "$VARIANT" = full ]; then
	PKG=xgs87-$SIDE
	VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' /opt/xgs87/kernel/"$SIDE"/dkms.conf)
	# Inside the chroot uname -r is the *host* kernel, so ask the tree which
	# kernel is actually installed here.
	KVER=$(ls /lib/modules | sort -V | tail -1)
	if [ ! -d "/lib/modules/$KVER/build" ]; then
		echo "== no headers for $KVER, skipping the DKMS build" >&2
	else
		mkdir -p /usr/src/$PKG-$VER
		cp /opt/xgs87/kernel/"$SIDE"/*.c /opt/xgs87/kernel/"$SIDE"/Makefile \
		   /opt/xgs87/kernel/"$SIDE"/dkms.conf /usr/src/$PKG-$VER/ 2>/dev/null || true
		cp /opt/xgs87/kernel/"$SIDE"/*.h /usr/src/$PKG-$VER/ 2>/dev/null || true
		dkms add "$PKG/$VER"
		dkms build "$PKG/$VER" -k "$KVER"
		dkms install "$PKG/$VER" -k "$KVER" --force
		echo "== dkms: $(dkms status "$PKG")"
	fi
fi

# --- housekeeping -----------------------------------------------------------
systemctl enable systemd-timesyncd ssh
: > /etc/machine-id
rm -f /etc/ssh/ssh_host_*
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "== setup.sh done"
