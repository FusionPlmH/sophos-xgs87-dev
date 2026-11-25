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
# PCIe policy: wait, do not reset.  A remove/rescan re-asserts PERST# and, in a
# loop, keeps resetting the NPU while it is still booting.  That is exactly the
# "self-resets every ~2 s" symptom chased on 2026-11-25.  Automatic
# remove/rescan is therefore off; once the NPU is fully up, run this script
# with --force-rescan.  A plain rescan (no remove) is safe and is used below,
# because it cannot reset anything the kernel does not already know.
set -u

FORCE_RESCAN=0
RETRAIN=0
case "${1:-}" in
--force-rescan) FORCE_RESCAN=1 ;;
--retrain) RETRAIN=1 ;;
"") ;;
-h | --help)
	echo "usage: $0 [--force-rescan|--retrain]"
	echo "  --force-rescan  one remove/rescan after the wait; only when the NPU is up"
	echo "  --retrain       toggle Link Disable on the root port so the link trains again"
	exit 0
	;;
*)
	echo "usage: $0 [--force-rescan|--retrain]" >&2
	exit 2
	;;
esac

WAN_VID=${WAN_VID:-100}
LAN_VID=${LAN_VID:-200}
WAIT=${WAIT:-180}
BDF=0000:03:00.0
NTB_DEV=/sys/bus/ntb/devices/$BDF
PCI_DEV=/sys/bus/pci/devices/$BDF

modprobe ntb_hw_epf 2>/dev/null
modprobe ntb_transport transport_mtu=2048 2>/dev/null
modprobe ntb_netdev 2>/dev/null

# The endpoint's bus number is assigned by the BIOS, and 03:00.0 was hardcoded
# everywhere.  A chassis power cycle is free to renumber it, and then every
# path below points at nothing while the device sits one bus over -- with the
# extra twist that `tee .../bind: No such device` reads like "the NPU is dead".
# Look the function up by its vendor/device IDs instead; 03:00.0 stays as the
# starting guess so the messages read the same as before on a normal boot.
find_epf() {
	for d in /sys/bus/pci/devices/*; do
		[ -r "$d/vendor" ] && [ -r "$d/device" ] || continue
		[ "$(cat "$d/vendor" 2>/dev/null)" = 0x1957 ] || continue
		[ "$(cat "$d/device" 2>/dev/null)" = 0x0809 ] || continue
		echo "${d##*/}"
		return 0
	done
	return 1
}

set_bdf() {
	BDF=$1
	NTB_DEV=/sys/bus/ntb/devices/$BDF
	PCI_DEV=/sys/bus/pci/devices/$BDF
}

# 180 s of plain waiting.  The NPU's Debian boots in ~11 s, but a power cycle,
# fsck or a manual U-Boot stop can take much longer; none of that is a reason
# to touch the PCIe link.
i=0
while [ ! -e "$NTB_DEV" ] && [ "$i" -lt "$WAIT" ]; do
	i=$((i + 1))
	if [ $((i % 5)) -eq 0 ] && found=$(find_epf); then
		[ "$found" = "$BDF" ] || echo "xgs-ntb: endpoint enumerated at $found (was $BDF)" >&2
		set_bdf "$found"
	fi
	sleep 1
done

# A plain rescan is not a reset.  It asks the kernel to walk the buses again
# and build pci_devs for functions it does not already know; devices it does
# know are not touched, nothing is removed, and therefore no PERST# is
# asserted.  That is what makes it safe here, unlike remove+rescan below.
#
# It is also necessary.  On a cold start the BIOS enumerates the root port
# before the NPU has armed its endpoint (U-Boot plus kernel plus
# xgs-vntb.service is ~10-20 s), so the function can appear after the kernel
# has already scanned the bus.  Without a rescan the host never notices, and
# from both ends it looks exactly like a dead link.
if [ ! -e "$NTB_DEV" ] && [ "$FORCE_RESCAN" != 1 ]; then
	i=0
	while [ ! -e "$NTB_DEV" ] && [ "$i" -lt 3 ]; do
		i=$((i + 1))
		echo "xgs-ntb: no ntb device yet; plain bus rescan $i/3" >&2
		echo 1 2>/dev/null > /sys/bus/pci/rescan || true
		j=0
		while [ ! -e "$NTB_DEV" ] && [ "$j" -lt 20 ]; do
			j=$((j + 1))
			sleep 1
		done
	done
fi

if [ "$FORCE_RESCAN" = 1 ] && [ -e "$PCI_DEV" ]; then
	echo "xgs-ntb: forcing one remove/rescan of $PCI_DEV" >&2
	echo 1 2>/dev/null > "$PCI_DEV/remove"
	sleep 1
	echo 1 2>/dev/null > /sys/bus/pci/rescan
	i=0
	while [ ! -e "$NTB_DEV" ] && [ "$i" -lt 30 ]; do
		i=$((i + 1))
		sleep 1
	done
fi

# Last resort: the link itself never trained (the endpoint armed its EPC
# long after POST finished training), so no amount of rescanning will find a
# function that is not electrically there.  Toggling Link Disable on the root
# port restarts the LTSSM and both sides train from scratch.
#
# Only the *root port* is written.  Reading or writing the endpoint's config
# space while it is unstable is what killed the host on 2026-11-25, and the
# check here is a sysfs existence test, which does not touch the device.
#
# The NPU generally reboots when the link drops, so allow it time to come back
# and arm its endpoint again before looking.
retrain_link() {
	port=$1
	[ -e "/sys/bus/pci/devices/$port" ] || return 1
	cur=$(setpci -s "$port" CAP_EXP+10.w 2>/dev/null) || return 1
	[ -n "$cur" ] || return 1
	off=$(printf '%04x' $(( 0x$cur | 0x10 )))
	on=$(printf '%04x' $(( 0x$cur & 0xffef )))
	echo "xgs-ntb: link down on $port (${cur} -> off ${off} -> on ${on})" >&2
	setpci -s "$port" CAP_EXP+10.w="$off" 2>/dev/null || return 1
	sleep 2
	setpci -s "$port" CAP_EXP+10.w="$on" 2>/dev/null || return 1
	return 0
}

if [ "$RETRAIN" = 1 ] && [ ! -e "$NTB_DEV" ]; then
	bus=${BDF#*:}
	bus=$((0x${bus%%:*}))
	port=
	for d in /sys/bus/pci/devices/*; do
		[ -r "$d/secondary_bus_number" ] || continue
		[ "$(cat "$d/secondary_bus_number" 2>/dev/null)" = "$bus" ] || continue
		port=${d##*/}
		break
	done
	if [ -z "$port" ]; then
		echo "xgs-ntb: no root port with secondary bus $bus; nothing to retrain" >&2
	elif retrain_link "$port"; then
		j=0
		while [ ! -e "$NTB_DEV" ] && [ "$j" -lt 45 ]; do
			j=$((j + 1))
			sleep 1
			[ $((j % 15)) -eq 0 ] && echo 1 2>/dev/null > /sys/bus/pci/rescan
		done
	fi
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
		if echo "$BDF" 2>/dev/null > /sys/bus/pci/drivers/ntb_hw_epf/bind; then
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
