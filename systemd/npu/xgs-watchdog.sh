#!/bin/sh
# Feed the CN9130 SBSA hardware watchdog.
#
# Why not systemd's RuntimeWatchdogSec: sbsa_gwdt is a module, so /dev/watchdog0
# only exists after udev has bound it -- long after PID1 decides whether it can
# use a watchdog.  Measured 2026-11-25: with no process petting the device the
# SoC really does reset (about 10-20 s), so this loop is the difference between
# "hang forever" and "reboot and come back".
#
# Opening /dev/watchdog0 starts the 10 s timer; a write of any byte pets it.
# Closing the fd without the magic 'V' leaves it running (nowayout=0 would stop
# it, but we never want that), so a killed pinger is followed by a reset.
set -u

i=0
while [ ! -e /dev/watchdog0 ] && [ "$i" -lt 50 ]; do
	i=$((i + 1))
	sleep 0.2
done
[ -e /dev/watchdog0 ] || { echo "xgs-watchdog: no /dev/watchdog0" >&2; exit 1; }

exec 3>/dev/watchdog0
echo "xgs-watchdog: feeding /dev/watchdog0 every 4 s (hardware timeout 10 s)"
while :; do
	printf '1' >&3 || exit 1
	sleep 4
done
