#!/bin/sh
# x86 side: bring the NTB link to the NPU up and put addresses on it.
#
# The NPU tags its WAN segment as VLAN 100 and its LAN segment as VLAN 200, so
# both live on this one link.  The raw netdev carries no address of its own.
#
#   eth0.100  WAN / 管理    DHCP（上游给什么用什么，默认路由也从这里来）
#   eth0.200  LAN           static 10.234.56.2/24（NPU 是 .1，LAN 上没人发 DHCP）
#
# Install as /usr/local/sbin/xgs-ntb-up.sh plus a oneshot unit, see
# xgs-ntb.service.  Debian does not build the NTB stack, so ntb.ko,
# ntb_hw_epf.ko, ntb_transport.ko and ntb_netdev.ko must be built against
# this kernel's headers and dropped in /lib/modules/$(uname -r)/extra/.
#
# PCIe policy: wait, do not poke.  A remove/rescan re-asserts PERST# and, in a
# loop, keeps resetting the NPU while it is still booting.  That is exactly the
# "self-resets every ~2 s" symptom chased on 2026-11-25.  Automatic rescan is
# therefore off; once the NPU is fully up, run this script with --force-rescan.
set -u

FORCE_RESCAN=0
case "${1:-}" in
--force-rescan) FORCE_RESCAN=1 ;;
"") ;;
-h | --help)
	echo "usage: $0 [--force-rescan]"
	echo "  --force-rescan  one remove/rescan after the wait; only when the NPU is up"
	exit 0
	;;
*)
	echo "usage: $0 [--force-rescan]" >&2
	exit 2
	;;
esac

WAN_VID=${WAN_VID:-100}
LAN_VID=${LAN_VID:-200}
WAIT=${WAIT:-180}
NTB_DEV=/sys/bus/ntb/devices/0000:03:00.0
PCI_DEV=/sys/bus/pci/devices/0000:03:00.0
BDF=0000:03:00.0

modprobe ntb_hw_epf 2>/dev/null
modprobe ntb_transport transport_mtu=2048 2>/dev/null
modprobe ntb_netdev 2>/dev/null

# 180 s of plain waiting.  The NPU's Debian boots in ~11 s, but a power cycle,
# fsck or a manual U-Boot stop can take much longer; none of that is a reason
# to touch the PCIe link.
i=0
while [ ! -e "$NTB_DEV" ] && [ "$i" -lt "$WAIT" ]; do
	i=$((i + 1))
	sleep 1
done

if [ "$FORCE_RESCAN" = 1 ] && [ -e "$PCI_DEV" ]; then
	echo "xgs-ntb: forcing one remove/rescan of $PCI_DEV" >&2
	echo 1 > "$PCI_DEV/remove" 2>/dev/null
	sleep 1
	echo 1 > /sys/bus/pci/rescan 2>/dev/null
	i=0
	while [ ! -e "$NTB_DEV" ] && [ "$i" -lt 30 ]; do
		i=$((i + 1))
		sleep 1
	done
fi

# The ntb device node only exists once ntb_hw_epf has *bound* the PCI
# function, and a driver that was already loaded binds as soon as the device
# is added -- so this normally does nothing.  It matters when the module was
# not loaded at the moment the function appeared (module index stale, service
# restarted after the fact, DKMS module installed later): the device sits
# there with no driver and nothing ever picks it up.  Meanwhile a user looking
# at `lspci` sees a perfectly normal endpoint, which is exactly the confusing
# "03:00.0 在，eth0 没有" state.
if [ ! -e "$NTB_DEV" ] && [ -e "$PCI_DEV" ]; then
	bound=$(readlink -f "$PCI_DEV/driver" 2>/dev/null || true)
	bound=${bound##*/}
	if [ -n "$bound" ] && [ -e "$PCI_DEV/driver" ]; then
		echo "xgs-ntb: $PCI_DEV is bound to $bound, not to ntb_hw_epf" >&2
	else
		echo "xgs-ntb: $PCI_DEV is enumerated with no driver; binding ntb_hw_epf" >&2
		if echo "$BDF" > /sys/bus/pci/drivers/ntb_hw_epf/bind 2>/dev/null; then
			i=0
			while [ ! -e "$NTB_DEV" ] && [ "$i" -lt 15 ]; do
				i=$((i + 1))
				sleep 1
			done
		else
			echo "xgs-ntb: bind failed; the driver said:" >&2
			dmesg | grep -iE 'ntb|0000:03:00' | tail -10 >&2 || true
		fi
	fi
fi

if [ ! -e "$NTB_DEV" ]; then
	if [ -e "$PCI_DEV" ]; then
		bound=$(readlink -f "$PCI_DEV/driver" 2>/dev/null || true)
		pci_state="present, driver: ${bound##*/}"
	else
		pci_state="absent -- the host never enumerated the endpoint"
	fi
	cat >&2 <<EOF
xgs-ntb: the vNTB device did not appear within ${WAIT}s.
  $PCI_DEV: $pci_state
  - If the NPU is still booting (or stopped in U-Boot), leave it alone.
  - Once the NPU is fully up, run:
        sudo $0 --force-rescan
  - If rescan does not bring the device back either, the link was never
    trained: reboot this machine with the NPU left running.
  - Do NOT run remove/rescan in a loop: it resets the NPU's PCIe link and
    prevents it from ever finishing its own boot.
EOF
	exit 1
fi

# Find the netdev owned by ntb_netdev.  Never fall back to "whatever is called
# eth0": a USB Ethernet adapter used for the U-Boot rescue path is also eth0
# on this machine, and putting the WAN VLAN on it would be very confusing.
NTB=
for n in /sys/class/net/*; do
	dev=${n##*/}
	drv=$(ethtool -i "$dev" 2>/dev/null | sed -n 's/^driver: //p')
	if [ "$drv" = ntb_netdev ]; then
		NTB=$dev
		break
	fi
done
if [ -z "$NTB" ]; then
	for n in /sys/class/net/*; do
		dev=${n##*/}
		case "$(readlink -f "$n/device" 2>/dev/null)" in
		*/0001:*) NTB=$dev ;;
		esac
	done
fi
if [ -z "$NTB" ]; then
	echo "xgs-ntb: no ntb_netdev interface found" >&2
	exit 1
fi

if [ "$NTB" != eth0 ]; then
	if [ -e /sys/class/net/eth0 ]; then
		echo "xgs-ntb: the NTB link is $NTB, but eth0 is another NIC." >&2
		echo "         Unplug it (or rename it) so the VLANs keep their eth0.* names." >&2
		exit 1
	fi
	ip link set "$NTB" down 2>/dev/null
	ip link set "$NTB" name eth0 || exit 1
	NTB=eth0
fi

modprobe 8021q 2>/dev/null
ip link set "$NTB" mtu 2022 2>/dev/null || true

# Earlier revisions carried the management address untagged; drop it.  The
# raw link keeps no address of its own but must be up: the VLANs above it
# inherit their carrier from here.
ip addr flush dev "$NTB" 2>/dev/null
ip link set "$NTB" up

for vid in "$WAN_VID" "$LAN_VID"; do
	vl=$NTB.$vid
	ip link show "$vl" >/dev/null 2>&1 || \
		ip link add link "$NTB" name "$vl" type vlan id "$vid" || exit 1
done

# ntb_netdev invents a random MAC on every boot and has no
# ndo_set_mac_address, so pin the addresses on the VLAN devices instead.
# Without this the DHCP lease (and every ssh known_hosts entry) changes on
# each reboot.
ip link set "$NTB.$WAN_VID" address 02:58:47:53:00:11 2>/dev/null || true
ip link set "$NTB.$LAN_VID" address 02:58:47:53:00:21 2>/dev/null || true

for vid in "$WAN_VID" "$LAN_VID"; do
	ip link set "$NTB.$vid" up
done

# Addresses and the default route are left to systemd-networkd (see
# 100-wan.network and 200-lan.network) so the lease is renewed by something
# that keeps running.
systemctl try-restart systemd-networkd 2>/dev/null || true

echo "xgs-ntb: $(ip -br a show "$NTB" | tr -s " ")"
for vid in "$WAN_VID" "$LAN_VID"; do
	echo "xgs-ntb: $(ip -br a show "$NTB.$vid" | tr -s " ")"
done
