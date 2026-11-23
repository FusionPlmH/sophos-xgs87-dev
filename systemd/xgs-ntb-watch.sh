#!/bin/sh
# Keep the vNTB link to the NPU alive.  The NPU is the endpoint, so every time
# it reboots the host has to re-enumerate the device; nothing does that by
# itself, and worse, the link can sit at carrier 0 forever.
set -u

NTB_DEV=/sys/bus/ntb/devices/0000:03:00.0
PCI_DEV=/sys/bus/pci/devices/0000:03:00.0
last=0

while :; do
	carrier=0
	[ -r /sys/class/net/eth0/carrier ] && carrier=$(cat /sys/class/net/eth0/carrier 2>/dev/null || echo 0)

	if [ ! -e "$NTB_DEV" ] || [ "$carrier" != 1 ]; then
		now=$(date +%s)
		if [ -e "$PCI_DEV" ] && [ $((now - last)) -ge 60 ]; then
			last=$now
			logger -t xgs-ntb-watch "link down (carrier=$carrier), re-enumerating"
			/usr/local/sbin/xgs-ntb-up.sh >> /var/log/xgs-ntb-watch.log 2>&1
		fi
	else
		# Link is healthy: make sure our addresses survived.
		ip link set eth0 up 2>/dev/null
		for vid in 100 31; do
			vl=eth0.$vid
			[ -e "/sys/class/net/$vl" ] || \
				ip link add link eth0 name "$vl" type vlan id "$vid" 2>/dev/null
			ip link set "$vl" up 2>/dev/null
		done
		ip addr show dev eth0.100 2>/dev/null | grep -q '192.168.100.2/' || \
			ip addr add 192.168.100.2/24 dev eth0.100 2>/dev/null
	fi
	sleep 15
done
