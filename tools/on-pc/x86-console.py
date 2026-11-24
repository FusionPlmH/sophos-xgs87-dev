#!/usr/bin/env python3
"""Talk to the XGS 87's x86 console over the front-panel micro-USB (COM6).

The adapter is a PL2303GL wired to the x86's ttyS0; the RJ45 service port
(COM5) is the same UART, so only one of the two can be used at a time.
"""
import argparse
import re
import sys
import time

import serial

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

SENT = "__XGS_RC__"


class Console:
    def __init__(self, port, baud):
        self.ser = serial.Serial(port, baud, timeout=0.2)
        time.sleep(0.2)
        self.ser.reset_input_buffer()

    def drain(self, quiet=0.6, limit=3.0):
        buf = b""
        deadline = time.time() + limit
        last = time.time()
        while time.time() < deadline:
            chunk = self.ser.read(8192)
            if chunk:
                buf += chunk
                last = time.time()
            elif time.time() - last > quiet:
                break
        return buf.decode("utf-8", "replace")

    def write(self, text):
        self.ser.write(text.encode())
        self.ser.flush()

    def run(self, cmd, timeout=30.0):
        # 多行命令必须压成一行再发。以前是直接拼 "\n" + "; echo 哨兵"，
        # 那会在最后一行前面留下一个以 `;` 开头的独立语句 —— bash 直接
        # 语法错误，哨兵永远不出现，于是每次都等到超时（表现就是"命令没
        # 输出 / 工具卡住"）。用 `; ` 连接既保持单行，又保留语句顺序。
        flat = " ; ".join(ln.strip() for ln in cmd.splitlines() if ln.strip())
        if not flat:
            return ""
        self.write(flat + "; echo " + SENT + "$?\n")
        buf = ""
        deadline = time.time() + timeout
        done = re.compile(SENT + r"\d")
        while time.time() < deadline:
            chunk = self.ser.read(8192)
            if chunk:
                buf += chunk.decode("utf-8", "replace")
                if done.search(buf):
                    time.sleep(0.3)
                    buf += self.ser.read(65536).decode("utf-8", "replace")
                    return buf
            else:
                time.sleep(0.05)
        return buf + "\n[[timeout: no sentinel]]"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM6")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password", default="P@ssw0rd")
    ap.add_argument("--timeout", type=float, default=40.0)
    ap.add_argument("--peek", action="store_true", help="just dump what the console prints")
    ap.add_argument("--script", metavar="FILE",
                    help="send every line of FILE as its own command first "
                         "(for pushing a file over the console in chunks)")
    ap.add_argument("commands", nargs="*")
    a = ap.parse_args()

    script = []
    if a.script:
        with open(a.script, "r", encoding="utf-8") as fh:
            script = [ln.rstrip("\n") for ln in fh if ln.strip()]

    c = Console(a.port, a.baud)
    if a.peek:
        c.write("\n")
        sys.stdout.write(c.drain(quiet=1.0, limit=4.0))
        return

    if not a.commands and not script:
        ap.error("no commands")

    c.write("\n")
    time.sleep(0.4)
    banner = c.drain(quiet=0.5, limit=2.0)
    if "login:" in banner:
        c.write(a.user + "\n")
        time.sleep(1.0)
        c.drain(quiet=0.4, limit=1.5)
        c.write(a.password + "\n")
        time.sleep(2.5)
        c.drain(quiet=0.5, limit=2.0)
    c.write("\x03")
    time.sleep(0.3)
    c.drain(quiet=0.4, limit=1.5)
    for index, cmd in enumerate(script, 1):
        c.run(cmd, a.timeout)
        if index % 10 == 0 or index == len(script):
            print("sent %d/%d" % (index, len(script)))
    for cmd in a.commands:
        out = c.run(cmd, a.timeout)
        # strip the echoed command and the sentinel
        flat = " ; ".join(ln.strip() for ln in cmd.splitlines() if ln.strip())
        lines = out.replace("\r", "").split("\n")
        keep = []
        for ln in lines:
            if SENT in ln:
                continue
            if ln.strip() == flat:
                continue
            keep.append(ln)
        print("\n".join(keep).strip("\n"))


if __name__ == "__main__":
    main()
