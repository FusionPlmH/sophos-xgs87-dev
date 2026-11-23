#!/bin/sh
# Say goodbye to the endpoint before this machine goes away.
#
# Unloading ntb_hw_epf makes it write COMMAND_LINK_DOWN into the endpoint's
# control area, so the NPU tears its transport down while the shared region is
# still mapped.  Skip this and the NPU is left holding a pointer into a machine
# that just vanished: it takes an external abort and, with panic_on_oops set,
# reboots itself for no reason -- which is exactly the chain reboot we kept
# seeing.
set -u

systemctl stop xgs-ntb-watch.service 2>/dev/null

ip link set eth0.31 down 2>/dev/null
ip link set eth0.100 down 2>/dev/null

for m in ntb_netdev ntb_transport ntb_hw_epf; do
	timeout 5 rmmod "$m" 2>/dev/null
done

echo "xgs-ntb-stop: endpoint told to drop the link"
