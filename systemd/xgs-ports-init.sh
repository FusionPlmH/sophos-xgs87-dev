#!/bin/bash
# XGS 87 NPU: give every front port the MAC the vendor assigned it, then bring
# the ports up so their PHYs negotiate.  Runs at boot, before network.target,
# so it first waits for DSA to create the switch ports.
#
# Vendor scheme: 19 consecutive addresses from the label MAC.
#   p1..p8 = label+0..7   sfp = label+8   backplane(end0) = label+9 (= U-Boot ethaddr)

int2mac() {
	printf '%02x:%02x:%02x:%02x:%02x:%02x' \
		$(( ($1 >> 40) & 255 )) $(( ($1 >> 32) & 255 )) $(( ($1 >> 24) & 255 )) \
		$(( ($1 >> 16) & 255 )) $(( ($1 >> 8) & 255 )) $(( $1 & 255 ))
}

# 1. wait for the DSA ports (mv88e6xxx probes after MDIO/SPI are up)
for _ in $(seq 1 150); do
	[ -e /sys/class/net/p8 ] && [ -e /sys/class/net/sfp ] && break
	sleep 0.2
done
if [ ! -e /sys/class/net/p8 ] || [ ! -e /sys/class/net/sfp ]; then
	echo "switch ports never appeared" >&2
	exit 1
fi

# 2. wait for the U-Boot environment partition (spi-orion is a module)
for _ in $(seq 1 50); do
	[ -e /dev/mtd1 ] && break
	sleep 0.2
done

# 3. per-port MACs
base=$(fw_printenv -n ethaddr 2>/dev/null)
if [ -n "$base" ]; then
	IFS=':' read -r a b c d e f <<< "$base"
	backplane=$(( 0x$a$b$c$d$e$f ))
	label=$(( backplane - 9 ))
	for i in 1 2 3 4 5 6 7 8; do
		ip link set dev p$i address "$(int2mac $(( label + i - 1 )))" 2>/dev/null
	done
	ip link set dev sfp address "$(int2mac $(( label + 8 )))" 2>/dev/null
fi

# 4. bring everything up so the PHYs negotiate
for i in 1 2 3 4 5 6 7 8; do
	ip link set dev p$i up
done
ip link set dev sfp up
exit 0
