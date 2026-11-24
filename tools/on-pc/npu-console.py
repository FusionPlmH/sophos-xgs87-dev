#!/usr/bin/env python3
"""Read/interact with the NPU console over the CH340 (COM7).

All three stages put 115200 8N1 on the same wire:

  TF-A         115200 8N1
  U-Boot       115200 8N1
  p3 Linux     115200 8N1

(230400 was a misread: sampling 115200 data at 2x looks like garbage.)
`--interrupt` holds the U-Boot autoboot (bootdelay=3) by sending spaces,
leaving the `=>` prompt for `--send`.
"""
import argparse
import sys
import time

import serial

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

PROMPT = "=>"


def drain(ser, seconds, interrupt=False, interrupt_for=8.0):
    """Read for `seconds`, optionally holding the U-Boot prompt."""
    end = time.time() + seconds
    key_until = time.time() + interrupt_for if interrupt else 0.0
    next_key = time.time()
    while time.time() < end:
        if interrupt and time.time() < key_until and time.time() >= next_key:
            ser.write(b" ")
            ser.flush()
            next_key = time.time() + 0.2
        chunk = ser.read(4096)
        if chunk:
            sys.stdout.write(chunk.decode("utf-8", "replace"))
            sys.stdout.flush()
        else:
            time.sleep(0.02)


def send(ser, cmd, seconds=3.0):
    ser.write((cmd + "\n").encode())
    ser.flush()
    drain(ser, seconds)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--port", default="COM7")
    ap.add_argument("--baud", type=int, default=115200,
                    help="console rate; all NPU stages are 115200")
    ap.add_argument("--seconds", type=float, default=20.0,
                    help="initial read window")
    ap.add_argument("--interrupt", action="store_true",
                    help="send spaces to stop U-Boot autoboot (bootdelay=3)")
    ap.add_argument("--send", action="append", default=[], metavar="CMD",
                    help="U-Boot command to send after the initial read")
    ap.add_argument("--after", type=float, default=10.0,
                    help="read window after the last --send (kernel boot)")
    a = ap.parse_args()

    ser = serial.Serial(a.port, a.baud, timeout=0.1)
    time.sleep(0.2)
    ser.reset_input_buffer()

    drain(ser, a.seconds, interrupt=a.interrupt)
    for cmd in a.send:
        send(ser, cmd)
    if a.send:
        drain(ser, a.after)


if __name__ == "__main__":
    main()
