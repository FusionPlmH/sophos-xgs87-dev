#!/bin/sh
# Fail if device-identifying data leaked back into the tracked tree.
#
# Everything this repository assigns itself is allowed:
#   00:51:82:11:22:01..04   stock U-Boot defaults
#   02:58:47:53:00:11/.31   VLAN MACs set by systemd/x86/xgs-ntb-up.sh
#   02:00:00:00:00:01       documented netconsole listener
# Anything else -- a real NIC, a real serial, a home-LAN address, a Windows
# user path -- is a regression: put it in a file outside the tree instead.
set -eu
cd "$(dirname "$0")/.."

fail=0
report() {
	printf '\n== %s\n%s\n' "$1" "$2"
	fail=1
}

macs=$(git grep -n -i -E '\b([0-9a-f]{2}:){5}[0-9a-f]{2}\b' |
	grep -viE '00:51:82:11:22:0[1-4]|02:58:47:53:00:(11|31)|02:00:00:00:00:01|00:00:00:00:00:00|ff:ff:ff:ff:ff:ff' || true)
[ -z "$macs" ] || report "MAC addresses that are not part of the design" "$macs"

ipv6=$(git grep -n -i -E '\bfe80:[0-9a-f:]*ff:fe[0-9a-f:]*' || true)
[ -z "$ipv6" ] || report "EUI-64 link-local addresses (they embed a MAC)" "$ipv6"

# 192.168.0/24 and 192.168.1/24 are the documentation examples, 192.168.100/24
# is the appliance's own management segment.
ips=$(git grep -n -E '\b192\.168\.[0-9]{1,3}\.[0-9]{1,3}\b' |
	grep -vE '\b192\.168\.(0|1|100)\.[0-9]{1,3}\b' || true)
[ -z "$ips" ] || report "addresses outside the documented example subnets" "$ips"

serials=$(git grep -n -E 'X01[0-9]{10}|SEAAMDA0200-0001[0-9]' || true)
[ -z "$serials" ] || report "serial numbers" "$serials"

paths=$(git grep -n -i -E '[A-Za-z]:\\Users\\' || true)
[ -z "$paths" ] || report "Windows user paths" "$paths"

if [ "$fail" = 0 ]; then
	echo "hygiene: tracked tree is clean"
fi
exit "$fail"