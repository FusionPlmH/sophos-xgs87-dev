#!/bin/bash
# Run one command on the NPU console from the x86 host.
#
# The NPU's console is wired to the x86's second 16550.  On the current Debian
# kernel the host rate is 115200 and that is also the wire rate.  The old
# hand-installed image kernel reported a 2x divisor base (host 57600 = wire
# 115200); if you are still running that kernel, set BAUD=57600.  Only one
# process may read /dev/ttyS2 at a time; two readers split the byte stream into
# garbage, which is the single easiest way to waste an afternoon here.
#
#   sudo npu-console login          # log in (root / openwrt123 on p3)
#   sudo npu-console 'uname -r'     # run a command on an already logged shell
#   WAIT=8 sudo npu-console 'dmesg | tail'
set -u

DEV=${DEV:-/dev/ttyS2}
BAUD=${BAUD:-115200}
WAIT=${WAIT:-5}
USER_NAME=${USER_NAME:-root}
PASSWORD=${PASSWORD:-openwrt123}

stty -F "$DEV" "$BAUD" raw -echo -crtscts || exit 1

LOG=$(mktemp)
timeout $((WAIT + 6)) cat "$DEV" > "$LOG" &
reader=$!
sleep 0.3

case "${1:-}" in
login)
	printf '%s\r' "$USER_NAME" > "$DEV"
	sleep 1.5
	printf '%s\r' "$PASSWORD" > "$DEV"
	sleep 2.5
	;;
'')
	echo "usage: $0 login | <command>" >&2
	kill "$reader" 2>/dev/null
	rm -f "$LOG"
	exit 2
	;;
*)
	printf '%s; echo __RC=$?__\r' "$*" > "$DEV"
	sleep "$WAIT"
	;;
esac

kill "$reader" 2>/dev/null
wait "$reader" 2>/dev/null
cat -v "$LOG"
rm -f "$LOG"
