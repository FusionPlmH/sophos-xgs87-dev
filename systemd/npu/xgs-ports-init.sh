#!/bin/bash
# XGS 87 NPU: give every front port the MAC the vendor assigned it, then bring
# the ports up so their PHYs negotiate.  Runs at boot, before network.target,
# so it first waits for DSA to create the switch ports.
#
# The VPD says eth.macs=7 and U-Boot's ethaddr is the backplane address:
#
#   label / VPD base = ethaddr - 5
#   p1..p4           = base + 0..3   (the four RJ45 panel ports)
#   sfp              = base + 4
#   end0 / ethaddr   = base + 5
#   base + 6         = unused spare
#
# This board has four RJ45 jacks, not eight: p5..p8 exist in the switch but are
# not wired to the panel.  PANEL_PORTS can be overridden for an XGS 107, where
# the same switch exposes eight jacks.
set -u

PANEL_PORTS=${PANEL_PORTS:-"p1 p2 p3 p4"}
SFP_PORT=${SFP_PORT:-sfp}
WAIT_STEPS=${WAIT_STEPS:-150}   # 150 × 0.2 s = 30 s

int2mac() {
	printf '%02x:%02x:%02x:%02x:%02x:%02x' \
		$(( ($1 >> 40) & 255 )) $(( ($1 >> 32) & 255 )) $(( ($1 >> 24) & 255 )) \
		$(( ($1 >> 16) & 255 )) $(( ($1 >> 8) & 255 )) $(( $1 & 255 ))
}

# 1. wait for the DSA ports (mv88e6xxx probes after MDIO/SPI are up)
i=0
missing=
while [ "$i" -lt "$WAIT_STEPS" ]; do
	missing=
	for p in $PANEL_PORTS $SFP_PORT; do
		[ -e "/sys/class/net/$p" ] || missing=$p
	done
	[ -z "$missing" ] && break
	i=$((i + 1))
	sleep 0.2
done
if [ -n "$missing" ]; then
	echo "switch port $missing never appeared" >&2
	exit 1
fi

# 2. wait for the U-Boot environment partition (spi-orion is a module)
i=0
while [ ! -e /dev/mtd1 ] && [ "$i" -lt 50 ]; do
	i=$((i + 1))
	sleep 0.2
done

# 3. per-port MACs.  If the environment is unavailable, bring the ports up
#    anyway: a random MAC is worse than none for DHCP, but a dead port is worse
#    than both, and the operator can still set the address by hand.
base=$(fw_printenv -n ethaddr 2>/dev/null || true)
if [ -n "$base" ]; then
	IFS=':' read -r a b c d e f <<< "$base"
	backplane=$(( 0x$a$b$c$d$e$f ))
	label=$(( backplane - 5 ))
	if [ "$label" -lt 0 ] || [ $(( (label >> 40) & 1 )) -ne 0 ]; then
		echo "refusing to derive per-port MACs from invalid ethaddr $base" >&2
	else
		n=0
		for p in $PANEL_PORTS; do
			ip link set dev "$p" address "$(int2mac $(( label + n )))" 2>/dev/null || true
			n=$((n + 1))
		done
		ip link set dev "$SFP_PORT" address "$(int2mac $(( label + n )))" 2>/dev/null || true
	fi
else
	echo "no ethaddr in the U-Boot environment; leaving the port MACs to DSA" >&2
fi

# 4. bring the panel ports up so their PHYs negotiate
for p in $PANEL_PORTS $SFP_PORT; do
	ip link set dev "$p" up
done
exit 0
