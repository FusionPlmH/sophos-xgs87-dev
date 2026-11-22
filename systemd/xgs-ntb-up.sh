#!/bin/sh
# x86 side: bring the NTB link to the NPU up and put an address on it.
#
# Install as /usr/local/sbin/xgs-ntb-up.sh plus a oneshot unit, see
# x86-xgs-ntb.service.  Debian does not build the NTB stack, so ntb.ko,
# ntb_hw_epf.ko, ntb_transport.ko and ntb_netdev.ko must be built against
# this kernel's headers and dropped in /lib/modules/$(uname -r)/extra/.
set -u

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

ip addr add 192.168.100.2/24 dev eth0 2>/dev/null
ip link set eth0 up
echo "xgs-ntb: $(ip -br a show eth0)"
