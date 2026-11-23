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
set -u

WAN_VID=${WAN_VID:-100}
LAN_VID=${LAN_VID:-200}

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

for vid in "$WAN_VID" "$LAN_VID"; do
	vl=eth0.$vid
	ip link show "$vl" >/dev/null 2>&1 || \
		ip link add link eth0 name "$vl" type vlan id "$vid" || exit 1
done

# ntb_netdev invents a random MAC on every boot and has no
# ndo_set_mac_address, so pin the addresses on the VLAN devices instead.
# Without this the DHCP lease (and every ssh known_hosts entry) changes on
# each reboot.
ip link set "eth0.$WAN_VID" address 02:58:47:53:00:11 2>/dev/null || true
ip link set "eth0.$LAN_VID" address 02:58:47:53:00:21 2>/dev/null || true

for vid in "$WAN_VID" "$LAN_VID"; do
	ip link set "eth0.$vid" up
done

# Addresses and the default route are left to systemd-networkd (see
# 100-wan.network and 200-lan.network) so the lease is renewed by something
# that keeps running.
systemctl try-restart systemd-networkd 2>/dev/null || true

echo "xgs-ntb: $(ip -br a show eth0 | tr -s " ")"
for vid in "$WAN_VID" "$LAN_VID"; do
	echo "xgs-ntb: $(ip -br a show "eth0.$vid" | tr -s " ")"
done
