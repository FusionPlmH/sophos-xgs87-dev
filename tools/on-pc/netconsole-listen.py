"""Receive netconsole on UDP 6666 and append it to a log file."""
import argparse
import os
import socket
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=6666)
    ap.add_argument("--out", default=os.path.join("logs", "npu-netcon.log"))
    a = ap.parse_args()

    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((a.bind, a.port))
    s.settimeout(1.0)
    with open(a.out, "wb", buffering=0) as f:
        f.write(b"\n===== start %s =====\n" % time.strftime('%H:%M:%S').encode())
        while True:
            try:
                d, _ = s.recvfrom(65535)
                f.write(d)
            except socket.timeout:
                pass


if __name__ == "__main__":
    main()
