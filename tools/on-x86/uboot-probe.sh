#!/bin/sh
# Hold the NPU's U-Boot autoboot via the x86's ttyS2 and run one command.
#
# The U-Boot console is 115200 on the same wire as TF-A.  The x86's ttyS2 is
# bidirectional: spamming spaces during bootdelay=3 leaves the U-Boot at `=>`,
# then the command goes out the same tty and its answer comes back here.
set -u

DEV=${DEV:-/dev/ttyS2}
KEY_FOR=${KEY_FOR:-40}
WAIT=${WAIT:-3}
CMD=${CMD:-'mmc list'}
LOG=${LOG:-/tmp/uboot-probe.log}

stty -F "$DEV" 115200 raw -echo -crtscts || exit 1

( timeout "$KEY_FOR" sh -c "while true; do printf ' ' > $DEV; sleep 0.2; done" ) &
timeout -s KILL "$KEY_FOR" cat "$DEV" > "$LOG" 2>&1

printf '%s\n' "$CMD" > "$DEV"
sleep "$WAIT"
timeout -s KILL 3 cat "$DEV"

printf '\n===UBOOT_LOG===\n'
tail -40 "$LOG"
