#!/bin/sh
# x86 side: bring the NTB link to the NPU up and put addresses on it.
#
# The NPU tags its management segment as VLAN 100 and passes the house LAN
# through as VLAN 31, so both live on this one link.  The raw netdev carries
# no address of its own.
#
# Install as /usr/local/sbin/xgs-ntb-up.sh plus a oneshot unit, see
# x86-xgs-ntb.service.  Debian does not build the NTB stack, so ntb.ko,
# ntb_hw_epf.ko, ntb_transport.ko and ntb_netdev.ko must be built against
# this kernel's headers and dropped in /lib/modules/$(uname -r)/extra/.
set -u

MGMT_VID=${MGMT_VID:-100}
LAN_VID=${LAN_VID:-31}
MGMT_ADDR=${MGMT_ADDR:-192.168.100.2/24}

modprobe ntb_hw_epf 2>/dev/null
modprobe ntb_transport transport_mtu=2048 2>/dev/null
modprobe ntb_netdev 2>/dev/null

# The NPU rewrites the endpoint header when its vNTB function starts, which
# may happen after we booted, so re-enumerate until the NTB device appears.
i=0
while [ ! -e /sys/bus/ntb/devices/0000:03:00.0 ] && [ $i -lt 30 ]; do
	i=$((i + 1))
	if [ -e /sys/bus/pci/devices/0000:03:00.0 ]; then
		echo 1 > /sys/bus/pci/devices/0000:03:00.0/remove 2>/dev/null
		echo 1 > /sys/bus/pci/rescan
	fi
	sleep 2
done

i=0
while [ ! -e /sys/class/net/eth0 ] && [ $i -lt 20 ]; do
	i=$((i + 1))
	sleep 1
done
[ -e /sys/class/net/eth0 ] || exit 1

modprobe 8021q 2>/dev/null
ip link set eth0 mtu 2022 2>/dev/null || true

# Earlier revisions carried the management address untagged; drop it.  The
# raw link keeps no address of its own but must be up: the VLANs above it
# inherit their carrier from here.
ip addr flush dev eth0 2>/dev/null
ip link set eth0 up

for vid in "$MGMT_VID" "$LAN_VID"; do
	vl=eth0.$vid
	ip link show "$vl" >/dev/null 2>&1 || \
		ip link add link eth0 name "$vl" type vlan id "$vid" || exit 1
done

# ntb_netdev invents a random MAC on every boot and has no
# ndo_set_mac_address, so pin the addresses on the VLAN devices instead.
# Without this the DHCP lease (and every ssh known_hosts entry) changes on
# each reboot.
ip link set "eth0.$MGMT_VID" address 02:58:47:53:00:11 2>/dev/null || true
ip link set "eth0.$LAN_VID" address 02:58:47:53:00:31 2>/dev/null || true

for vid in "$MGMT_VID" "$LAN_VID"; do
	ip link set "eth0.$vid" up
done

ip addr show dev "eth0.$MGMT_VID" | grep -q "${MGMT_ADDR%/*}/" || \
	ip addr add "$MGMT_ADDR" dev "eth0.$MGMT_VID"

# eth0.$LAN_VID is left to systemd-networkd (see 31-house-lan.network) so the
# lease is renewed by something that keeps running.
systemctl try-restart systemd-networkd 2>/dev/null || true

echo "xgs-ntb: $(ip -br a show eth0 | tr -s ' ')"
for vid in "$MGMT_VID" "$LAN_VID"; do
	echo "xgs-ntb: $(ip -br a show "eth0.$vid" | tr -s ' ')"
done
