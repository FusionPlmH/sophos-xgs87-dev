#!/bin/sh
# Management bridge on the front panel port p8.
#
# Both machines share one front-panel port, and the PCIe vNTB netdev is the
# only link between them -- but that same link also has to carry real LAN
# traffic for the x86.  So the management segment rides on 802.1Q VLAN 100
# instead of being untagged on the raw netdev: p8 stays an access port (a
# laptop plugged in sees 192.168.100.0/24 untagged), while the vNTB side is
# tagged.  The tag also keeps management frames from leaking onto p8.
#
# Idempotent: safe to re-run.
set -u

BR=br-mgmt
PORT=p8
ADDR=${MGMT_ADDR:-192.168.100.1/24}
VID=${MGMT_VID:-100}

i=0
while [ $i -lt 60 ]; do
	[ -e "/sys/class/net/$PORT" ] && break
	i=$((i + 1))
	sleep 1
done
if [ ! -e "/sys/class/net/$PORT" ]; then
	echo "xgs-mgmt-bridge: $PORT did not appear" >&2
	exit 1
fi

# Find the vNTB netdev by its bus, so a stray "eth0" can never be picked up.
NTB=
for n in /sys/class/net/*; do
	dev=${n##*/}
	[ -e "$n/device" ] || continue
	case "$(readlink -f "$n/device")" in
	*/0001:*) NTB=$dev;;
	esac
done
if [ -z "$NTB" ]; then
	echo "xgs-mgmt-bridge: no vNTB netdev yet" >&2
	exit 1
fi

modprobe 8021q 2>/dev/null

# An older revision of this script enslaved the raw netdev; undo that before
# putting a VLAN on top of it.
ip link set "$NTB" nomaster 2>/dev/null || true
ip link set "$NTB" mtu 2022 2>/dev/null || true
# The VLANs inherit their carrier from this device, so it has to be up even
# though it carries no addresses itself.
ip link set "$NTB" up

VL=$NTB.$VID
ip link show "$VL" >/dev/null 2>&1 || \
	ip link add link "$NTB" name "$VL" type vlan id "$VID" || exit 1
ip link set "$VL" up

ip link show "$BR" >/dev/null 2>&1 || ip link add name "$BR" type bridge
ip link set "$BR" type bridge forward_delay 0 2>/dev/null || true
# Stable MAC: adopt the port's own address instead of the random one the
# kernel picks while the port has no carrier.
ip link set "$BR" address "$(cat "/sys/class/net/$PORT/address")" 2>/dev/null || true

ip link set "$PORT" master "$BR"
ip link set "$PORT" up
ip link set "$VL" master "$BR"

ip addr show dev "$BR" | grep -q "${ADDR%/*}/" || ip addr add "$ADDR" dev "$BR"
ip link set "$BR" up

echo "xgs-mgmt-bridge: $BR=$(ip -br addr show "$BR" | tr -s ' ' | cut -d' ' -f3-) via $VL"
