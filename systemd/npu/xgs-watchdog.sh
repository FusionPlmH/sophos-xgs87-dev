#!/bin/sh
# Feed the CN9130 SBSA hardware watchdog.
#
# Why not systemd's RuntimeWatchdogSec: sbsa_gwdt is a module, so /dev/watchdog0
# only exists after udev has bound it -- long after PID1 decides whether it can
# use a watchdog.  Measured 2026-11-25: with no process petting the device the
# SoC really does reset, so this loop is the difference between "hang forever"
# and "reboot and come back".
#
# 超时由 /etc/modprobe.d/xgs-watchdog.conf 设成 60 秒（驱动默认 10 秒）。10 秒
# 太紧：`modprobe -r` 卸 vNTB 协议栈、大的 ext4 写入、卡住的 PCIe 访问都能让用户
# 态停顿超过 10 秒，然后 SoC 就在恢复过程中被硬复位 —— 2026-11-26 实测变成
# "重启风暴"。这里每 4 秒喂一次，60 秒的余量足够。
#
# Opening /dev/watchdog0 starts the timer; a write of any byte pets it.
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
echo "xgs-watchdog: feeding /dev/watchdog0 every 4 s (timeout $(cat /sys/class/watchdog/watchdog0/timeout 2>/dev/null || echo '?')s)"
while :; do
	printf '1' >&3 || exit 1
	sleep 4
done
