#!/usr/bin/env python3
"""Timestamped NPU console listener over the CH340 (default COM7).

Listen-only: it never writes to the port, so it cannot fight the x86's
/dev/ttyS2 for the NPU's RX line.  Use it to time cold boots (press power,
watch the first BootROM line and the delta to the next one).
"""
import argparse
import re
import sys
import time

import serial

MARKERS = (b"BootROM - 2.03", b"Cold boot", b"Booting BL31", b"NOTICE:  BL1",
           b"Trying Uart", b"Found valid image", b"error = 0x")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM7")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--seconds", type=float, default=60.0)
    ap.add_argument("--raw", action="store_true", help="dump every chunk as text")
    ap.add_argument("--out", help="also write the raw bytes to this file")
    a = ap.parse_args()

    ser = serial.Serial(a.port, a.baud, timeout=0.1)
    t0 = time.monotonic()
    pending = b""
    events = []
    raw = open(a.out, "wb") if a.out else None
    print("listening on %s @ %d for %.0f s (no writes)" % (a.port, a.baud, a.seconds))
    try:
        while time.monotonic() - t0 < a.seconds:
            chunk = ser.read(4096)
            if not chunk:
                continue
            if raw:
                raw.write(chunk)
            if a.raw:
                sys.stdout.write(chunk.decode("latin1"))
                sys.stdout.flush()
            pending += chunk
            for marker in MARKERS:
                while marker in pending:
                    stamp = time.monotonic() - t0
                    print("%8.3f  %s" % (stamp, marker.decode()))
                    events.append((stamp, marker.decode()))
                    pending = pending.split(marker, 1)[1]
            pending = pending[-64:]
    except KeyboardInterrupt:
        pass
    finally:
        if raw:
            raw.close()
        ser.close()

    boots = [t for t, name in events if name == "BootROM - 2.03"]
    if len(boots) >= 2:
        deltas = [b - a_ for a_, b in zip(boots, boots[1:])]
        print("\nBootROM resets: %d, period: %s s" % (
            len(boots), ", ".join("%.3f" % d for d in deltas)))
    elif boots:
        print("\nBootROM resets: 1 (no period yet)")


if __name__ == "__main__":
    main()
