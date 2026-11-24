#!/usr/bin/env python3
"""Send U-Boot commands to the NPU through the x86 and read the reply via COM7.

The NPU console is wired twice:

  * x86 /dev/ttyS2  - TX+RX, driven over the x86 console (COM6)
  * CH340 on COM7   - RX only (the TX line is not connected)

So commands go out through the x86 and the output is captured locally on COM7.
Nothing here writes to flash; it is just the console plumbing.
"""
import argparse
import subprocess
import sys
import time

import serial


def send_via_x86(x86_port, text, x86_timeout=30):
    payload = text.replace("\\", "\\\\").replace('"', '\\"')
    remote = 'sudo sh -c "printf \'%s\\r\' > /dev/ttyS2"' % payload
    cmd = [sys.executable, "tools/on-pc/x86-console.py", "--port", x86_port,
           "--timeout", str(x86_timeout), remote]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=x86_timeout + 30)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--x86-port", default="COM6")
    ap.add_argument("--npu-port", default="COM7")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--wait", type=float, default=1.5, help="seconds to read after each command")
    ap.add_argument("commands", nargs="+")
    a = ap.parse_args()

    ser = serial.Serial(a.npu_port, a.baud, timeout=0.1)
    time.sleep(0.2)
    ser.reset_input_buffer()
    try:
        for cmd in a.commands:
            res = send_via_x86(a.x86_port, cmd)
            if res.returncode != 0:
                print("[x86 send failed] %s" % (res.stderr or res.stdout)[-300:])
            end = time.monotonic() + a.wait
            buf = b""
            while time.monotonic() < end:
                chunk = ser.read(4096)
                if chunk:
                    buf += chunk
                else:
                    time.sleep(0.05)
            text = buf.decode("utf-8", "replace")
            print("$ %s" % cmd)
            print(text.strip("\r\n"))
            print("-" * 60)
    finally:
        ser.close()


if __name__ == "__main__":
    main()
