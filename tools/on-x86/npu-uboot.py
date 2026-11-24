#!/usr/bin/env python3
"""Drive the NPU U-Boot / p3 console through the x86's /dev/ttyS2.

The U-Boot console is 115200 on the same wire as TF-A and the p3 kernel.
During bootdelay=3 the x86 sends spaces until `=>` shows up, then commands
are written to the same tty and their output is captured here.

Examples (on the x86, as root):
    npu-uboot.py --cmd 'mmc list' --cmd 'ext4ls mmc 0:3 /boot'
    npu-uboot.py --pre 'wdt stop' --p3 --login
"""
import argparse
import os
import select
import sys
import termios
import time


def open_tty(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = 0
    a[1] = 0
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[3] = 0
    a[4] = termios.B115200
    a[5] = termios.B115200
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def read_some(fd, buf, quiet, limit):
    end = time.time() + limit
    last = time.time()
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if chunk:
                buf.extend(chunk)
                sys.stdout.write(chunk.decode("utf-8", "replace"))
                sys.stdout.flush()
                last = time.time()
                continue
        if time.time() - last > quiet:
            break
    return buf


def tail_text(buf, n=4096):
    return bytes(buf[-n:]).decode("utf-8", "replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="/dev/ttyS2")
    ap.add_argument("--wait", type=float, default=90.0,
                    help="how long to keep sending spaces waiting for U-Boot")
    ap.add_argument("--settle", type=float, default=2.5,
                    help="quiet time after a command")
    ap.add_argument("--max", type=float, default=12.0,
                    help="max time to collect one command's output")
    ap.add_argument("--pre", action="append", default=[], metavar="CMD",
                    help="U-Boot command before --p3/--cmd")
    ap.add_argument("--cmd", action="append", default=[], metavar="CMD")
    ap.add_argument("--p3", action="store_true", help="run bootcmd_emmc3")
    ap.add_argument("--login", action="store_true",
                    help="log in to the p3 Linux after --p3/boot")
    ap.add_argument("--login-user", default="root")
    ap.add_argument("--login-pass", default="openwrt123")
    ap.add_argument("--full", action="store_true", help="print the whole buffer")
    ap.add_argument("--log", default="/tmp/npu-uboot.log")
    a = ap.parse_args()

    fd = open_tty(a.device)
    buf = bytearray()
    key_until = time.time() + a.wait
    next_key = 0.0
    prompt_at = None

    while time.time() < key_until:
        if time.time() >= next_key:
            os.write(fd, b" ")
            next_key = time.time() + 0.2
        read_some(fd, buf, quiet=0.05, limit=0.2)
        t = tail_text(buf)
        if "=>" in t or "U-Boot 20" in t or "Hit any key" in t:
            prompt_at = len(buf)
            break

    # a little more output after the banner/prompt
    read_some(fd, buf, quiet=0.5, limit=3.0)

    if prompt_at is None:
        sys.stderr.write("\n[npu-uboot] no U-Boot prompt within %.0fs\n" % a.wait)
        sys.stderr.write(tail_text(buf, 4000))
        with open(a.log, "wb") as f:
            f.write(buf)
        return 2

    with open(a.log, "wb") as f:
        f.write(buf)

    cmds = list(a.pre)
    if a.p3 or a.login:
        cmds.append("run bootcmd_emmc3")
    cmds.extend(a.cmd)

    for cmd in cmds:
        os.write(fd, cmd.encode() + b"\r")
        read_some(fd, buf, quiet=a.settle, limit=a.max)
        with open(a.log, "wb") as f:
            f.write(buf)

    if a.login:
        t = tail_text(buf)
        if "login:" in t:
            os.write(fd, a.login_user.encode() + b"\r")
            read_some(fd, buf, quiet=1.0, limit=4.0)
        if "Password:" in tail_text(buf):
            os.write(fd, a.login_pass.encode() + b"\r")
            read_some(fd, buf, quiet=1.0, limit=5.0)

    if a.full:
        sys.stdout.write("\n--- full buffer ---\n" + bytes(buf).decode("utf-8", "replace"))
    else:
        idx = bytes(buf).rfind(b"U-Boot 20")
        if idx > 0:
            sys.stdout.write("\n--- U-Boot onwards ---\n" + bytes(buf[idx:]).decode("utf-8", "replace"))
    sys.stdout.write("\n[npu-uboot] log: %s\n" % a.log)
    return 0


if __name__ == "__main__":
    sys.exit(main())
