#!/bin/sh
# Keep the vNTB link to the NPU alive.
#
# It fails in two different ways and only one of them is obvious:
#
#   * the endpoint vanishes (NPU reboots) and eth0 sits at carrier 0, which a
#     re-enumeration fixes;
#   * the two sides disagree -- the host still reads carrier 1 while the NPU
#     has dropped the link, so nothing ever notices and the link stays dead
#     until someone pokes it.
#
# So both the carrier and actual reachability are watched, and either one
# failing for a minute triggers the up script.
set -u

NTB_DEV=/sys/bus/ntb/devices/0000:03:00.0
PCI_DEV=/sys/bus/pci/devices/0000:03:00.0
PEER=192.168.100.1
INTERVAL=15
LIMIT=4			# ~60 s of trouble before acting

miss=0

while :; do
	healthy=1

	if [ ! -e "$NTB_DEV" ]; then
		healthy=0
	else
		carrier=$(cat /sys/class/net/eth0/carrier 2>/dev/null || echo 0)
		[ "$carrier" = 1 ] || healthy=0
	fi

	if [ "$healthy" = 1 ]; then
		ping -c 1 -W 2 "$PEER" >/dev/null 2>&1 || healthy=0
	fi

	if [ "$healthy" = 1 ]; then
		miss=0
		# make sure the plumbing survived whatever happened last time
		ip link set eth0 up 2>/dev/null
		for vid in 100 31; do
			vl=eth0.$vid
			[ -e "/sys/class/net/$vl" ] || \
				ip link add link eth0 name "$vl" type vlan id "$vid" 2>/dev/null
			ip link set "$vl" up 2>/dev/null
		done
		ip addr show dev eth0.100 2>/dev/null | grep -q '192.168.100.2/' || \
			ip addr add 192.168.100.2/24 dev eth0.100 2>/dev/null
	else
		miss=$((miss + 1))
		if [ "$miss" -ge "$LIMIT" ] && [ -e "$PCI_DEV" ]; then
			miss=0
			logger -t xgs-ntb-watch "link unhealthy, re-enumerating"
			/usr/local/sbin/xgs-ntb-up.sh >> /var/log/xgs-ntb-watch.log 2>&1
		fi
	fi

	sleep "$INTERVAL"
done
