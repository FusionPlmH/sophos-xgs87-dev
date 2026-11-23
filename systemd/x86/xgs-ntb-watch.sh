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
# So both the carrier and actual reachability are watched.
#
# Recovery has to be a *full* reset, not just a re-enumeration: when the NPU
# reboots it reprograms its own BAR size registers and its inbound iATU, so
# every read of the old BAR address returns 0xffffffff ("endpoint
# unreachable").  Pulling the PCI device out from under the still-loaded
# transport is what turns that into a hang, so the order below matters:
# netdev -> transport -> hw driver -> remove/rescan -> rebuild.
set -u

NTB_DEV=/sys/bus/ntb/devices/0000:03:00.0
PCI_DEV=/sys/bus/pci/devices/0000:03:00.0
PEER=${PEER:-10.234.56.1}	# NPU 的 br-lan：它永远存在，不像 WAN 那样看上游
INTERVAL=15
LIMIT=4			# ~60 s of trouble before acting
COOLDOWN=30		# s to let the other side settle after a reset

miss=0

recover() {
	logger -t xgs-ntb-watch "link unhealthy, full reset"

	ip link set eth0.200 down 2>/dev/null
	ip link set eth0.100 down 2>/dev/null
	ip link set eth0 down 2>/dev/null

	for m in ntb_netdev ntb_transport ntb_hw_epf; do
		timeout 5 rmmod "$m" 2>/dev/null
	done

	# Re-read the endpoint: the NPU's BAR registers were reset with it.
	[ -e "$PCI_DEV" ] && echo 1 > "$PCI_DEV/remove" 2>/dev/null
	sleep 1
	echo 1 > /sys/bus/pci/rescan

	/usr/local/sbin/xgs-ntb-up.sh >> /var/log/xgs-ntb-watch.log 2>&1

	sleep "$COOLDOWN"
}

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
		for vid in 100 200; do
			vl=eth0.$vid
			[ -e "/sys/class/net/$vl" ] || \
				ip link add link eth0 name "$vl" type vlan id "$vid" 2>/dev/null
			ip link set "$vl" up 2>/dev/null
		done
		ip addr show dev eth0.200 2>/dev/null | grep -q '10.234.56.2/' || \
			ip addr add 10.234.56.2/24 dev eth0.200 2>/dev/null
	else
		miss=$((miss + 1))
		if [ "$miss" -ge "$LIMIT" ]; then
			miss=0
			recover
		fi
	fi

	sleep "$INTERVAL"
done
