"""Dump the raw byte stream of a COM port into a log file."""
import argparse
import os
import time

import serial


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM5")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--out", default=os.path.join("logs", "x86-console.log"))
    a = ap.parse_args()

    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    s = serial.Serial(a.port, a.baud, timeout=1)
    with open(a.out, "ab", buffering=0) as f:
        f.write(b"\n\n===== capture start %s =====\n" % time.strftime('%H:%M:%S').encode())
        while True:
            try:
                d = s.read(4096)
                if d:
                    f.write(d)
            except Exception as e:
                f.write(b"\n[read error %s]\n" % str(e).encode())
                time.sleep(1)


if __name__ == "__main__":
    main()