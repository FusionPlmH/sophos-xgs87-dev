#!/bin/sh
# Watch the vNTB link to the NPU.
#
# It fails in two different ways and only one of them is obvious:
#
#   * the endpoint vanishes (NPU reboots) and eth0 sits at carrier 0;
#   * the two sides disagree -- the host still reads carrier 1 while the NPU
#     has dropped the link, so nothing ever notices.
#
# So both the carrier and actual reachability are watched.
#
# IMPORTANT: this service does NOT remove/rescan PCIe by default.  A rescan
# re-asserts PERST#; doing that while the NPU is booting is what produced the
# "NPU resets every 3.2 s" loop on 2026-11-25.  The watcher now only keeps the
# local VLAN plumbing alive and logs.  If you want one automatic recovery
# attempt, set AUTO_RECOVER=1 in /etc/default/xgs-ntb-watch (or the unit
# environment); it waits LIMIT*INTERVAL (5 min) and then runs
# `xgs-ntb-up.sh --force-rescan` once.
set -u

# Optional: AUTO_RECOVER=1 and/or MAX_RECOVER=N
# shellcheck disable=SC1091
[ -r /etc/default/xgs-ntb-watch ] && . /etc/default/xgs-ntb-watch

NTB_DEV=/sys/bus/ntb/devices/0000:03:00.0
PEER=${PEER:-10.234.56.1}	# NPU 的 br-lan：它永远存在，不像 WAN 那样看上游
INTERVAL=${INTERVAL:-15}
LIMIT=${LIMIT:-20}		# 20 × 15 s = 5 min of continuous trouble
COOLDOWN=${COOLDOWN:-600}	# 10 min between automatic attempts
AUTO_RECOVER=${AUTO_RECOVER:-0}
MAX_RECOVER=${MAX_RECOVER:-1}

miss=0
recover_count=0
warned=0

log() {
	echo "xgs-ntb-watch: $*" >&2
	if command -v logger >/dev/null 2>&1; then
		logger -t xgs-ntb-watch "$*"
	fi
}

is_ntb_eth0() {
	[ -e /sys/class/net/eth0 ] || return 1
	drv=$(ethtool -i eth0 2>/dev/null | sed -n 's/^driver: //p')
	[ "$drv" = ntb_netdev ]
}

keep_local_plumbing() {
	# Do not touch anything if eth0 is not the vNTB netdev (e.g. a USB NIC
	# plugged in for the U-Boot rescue path).
	is_ntb_eth0 || return 0
	ip link set eth0 up 2>/dev/null
	for vid in 100 200; do
		vl=eth0.$vid
		[ -e "/sys/class/net/$vl" ] || \
			ip link add link eth0 name "$vl" type vlan id "$vid" 2>/dev/null
		ip link set "$vl" up 2>/dev/null
	done
	ip addr show dev eth0.200 2>/dev/null | grep -q '10.234.56.2/' || \
		ip addr add 10.234.56.2/24 dev eth0.200 2>/dev/null
}

while :; do
	healthy=1

	if [ ! -e "$NTB_DEV" ]; then
		healthy=0
	elif ! is_ntb_eth0; then
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
		warned=0
		keep_local_plumbing
	else
		miss=$((miss + 1))
		if [ "$miss" -ge "$LIMIT" ]; then
			miss=0
			if [ "$AUTO_RECOVER" = 1 ] && [ "$recover_count" -lt "$MAX_RECOVER" ]; then
				recover_count=$((recover_count + 1))
				log "link unhealthy for $((LIMIT * INTERVAL))s; one forced rescan (attempt $recover_count/$MAX_RECOVER)"
				/usr/local/sbin/xgs-ntb-up.sh --force-rescan >>/var/log/xgs-ntb-watch.log 2>&1 || true
				sleep "$COOLDOWN"
			elif [ "$warned" = 0 ]; then
				log "link unhealthy; no automatic PCIe rescan (AUTO_RECOVER=$AUTO_RECOVER, attempts=$recover_count/$MAX_RECOVER). Run: sudo xgs-ntb-up.sh --force-rescan"
				warned=1
			fi
		fi
	fi

	sleep "$INTERVAL"
done
