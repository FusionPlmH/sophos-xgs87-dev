#!/bin/sh
# Put the front-panel port p8 into a bridge with a management address, so the
# NPU is reachable on a dedicated management port.  Idempotent: safe to re-run.
set -u

BR=br-mgmt
PORT=p8
ADDR=${MGMT_ADDR:-192.168.100.1/24}

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

ip link show "$BR" >/dev/null 2>&1 || ip link add name "$BR" type bridge
ip link set "$BR" type bridge forward_delay 0 2>/dev/null || true
ip link set "$PORT" master "$BR"
ip link set "$PORT" up
# Stable MAC: adopt the port's own address instead of the random one the
# kernel picks while the port has no carrier.
ip link set "$BR" address "$(cat "/sys/class/net/$PORT/address")" 2>/dev/null || true
ip addr show dev "$BR" | grep -q "${ADDR%/*}/" || ip addr add "$ADDR" dev "$BR"
ip link set "$BR" up

echo "xgs-mgmt-bridge: $(ip -br addr show "$BR")"