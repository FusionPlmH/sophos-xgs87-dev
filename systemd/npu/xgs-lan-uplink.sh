#!/bin/sh
# Give the x86 host a real address on the house LAN.
#
# The only wire between the NPU and the x86 is the PCIe vNTB netdev, so the
# uplink port is bridged to a VLAN on that netdev: the NPU acts as a two-port
# switch between p4 and the x86.  The x86 runs a DHCP client on its own end of
# the VLAN and gets a lease straight from the house router.
#
# The management segment (br-mgmt, VLAN 100) is untouched by this script.
#
# Idempotent: safe to re-run.
set -u

BR=br-lan
PORT=${LAN_PORT:-p4}
VID=${LAN_VID:-31}

i=0
while [ $i -lt 60 ]; do
	[ -e "/sys/class/net/$PORT" ] && break
	i=$((i + 1))
	sleep 1
done
if [ ! -e "/sys/class/net/$PORT" ]; then
	echo "xgs-lan-uplink: $PORT did not appear" >&2
	exit 1
fi

NTB=
for n in /sys/class/net/*; do
	dev=${n##*/}
	[ -e "$n/device" ] || continue
	case "$(readlink -f "$n/device")" in
	*/0001:*) NTB=$dev;;
	esac
done
if [ -z "$NTB" ]; then
	echo "xgs-lan-uplink: no vNTB netdev yet" >&2
	exit 1
fi

ip link set "$NTB" mtu 2022 2>/dev/null || true
ip link set "$NTB" up
VL=$NTB.$VID
ip link show "$VL" >/dev/null 2>&1 || \
	ip link add link "$NTB" name "$VL" type vlan id "$VID" || exit 1
ip link set "$VL" up

ip link show "$BR" >/dev/null 2>&1 || ip link add name "$BR" type bridge
# Plain L2 passthrough: no STP (nothing to loop with) and no learning delay,
# so the x86's DHCP request is forwarded the moment it arrives.
#
# br-mgmt keeps the switch's default VLAN 1 on p8.  If this bridge also used
# VLAN 1 the two bridges would land in the same hardware VLAN ("hw VLAN 1
# already used by port 8 in br-mgmt") and the management segment would leak
# onto the panel port, so br-lan gets its own VID and filters in the bridge.
ip link set "$BR" type bridge stp_state 0 forward_delay 0 2>/dev/null || true
ip link set "$BR" type bridge vlan_default_pvid 0 2>/dev/null || true
ip link set "$BR" type bridge vlan_filtering 1 2>/dev/null || true

ip link set "$PORT" master "$BR"
ip link set "$PORT" up
ip link set "$VL" master "$BR"
ip link set "$BR" up

# p4 and the vNTB VLAN carry house-LAN frames; the bridge's own port needs the
# same VID too (`self`), otherwise the NPU's own address on br-lan stops
# passing traffic.
bridge vlan del dev "$PORT" vid 1 2>/dev/null || true
bridge vlan del dev "$VL" vid 1 2>/dev/null || true
bridge vlan add dev "$PORT" vid "$VID" pvid untagged 2>/dev/null || true
bridge vlan add dev "$VL" vid "$VID" pvid untagged 2>/dev/null || true
bridge vlan add dev "$BR" vid "$VID" pvid untagged self 2>/dev/null || true

echo "xgs-lan-uplink: $BR = $PORT + $VL ($(cat /sys/class/net/$PORT/carrier 2>/dev/null | sed 's/1/link up/;s/0/no link/'))"
