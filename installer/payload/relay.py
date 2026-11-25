#!/usr/bin/env python3
"""把一台机器变成"串口透传"：本机 console ⇄ /dev/ttyS2（NPU 的 UART）。

为什么需要它：NPU 的 UART 只接到 x86 的 ttyS2，PC 只能通过 COM5 摸到 x86 的控制台。
如果让 x86 自己收文件再转给 NPU，同一个 115200 要走**两遍**（PC→x86 31 min，
x86→NPU 再 23 min）。跑这个透传以后 PC 的 COM5 就等于插在 NPU 上，一遍走完。

    sudo -n python3 relay.py [设备] [最长秒数]

- 必须 root（/dev/ttyS2 是 root:dialout 660）。
- 前台跑：它要接管控制台 tty，让 shell 不再抢输入。
- PC 侧发 `\\x18\\x18XGS87QUIT\\r` 退出，退出时会恢复 tty 设置，shell 立刻能用。
- 实测 2026-11-25：15.9 MB 走 YMODEM，稳定 9.9 KiB/s，2298 块里 112 块重传。
"""
import os
import sys
import termios
import tty
import select
import time

MAGIC = b'\x18\x18XGS87QUIT\r'
DEV = sys.argv[1] if len(sys.argv) > 1 else '/dev/ttyS2'
LIMIT = float(sys.argv[2]) if len(sys.argv) > 2 else 10800.0


def write_all(fd, data):
    while data:
        try:
            n = os.write(fd, data)
        except BlockingIOError:
            select.select([], [fd], [], 1.0)
            continue
        data = data[n:]


fd = os.open(DEV, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
saved = termios.tcgetattr(0)
started = time.time()
try:
    tty.setraw(0)
    sys.stderr.write('RELAY-READY\r\n')
    sys.stderr.flush()
    tail = b''
    while time.time() - started < LIMIT:
        r, _, _ = select.select([0, fd], [], [], 5.0)
        if 0 in r:
            d = os.read(0, 4096)
            if not d:
                break
            write_all(fd, d)
        if fd in r:
            try:
                d = os.read(fd, 4096)
            except BlockingIOError:
                d = b''
            if d:
                write_all(1, d)
                tail = (tail + d)[-64:]
                if MAGIC in tail:
                    break
finally:
    termios.tcsetattr(0, termios.TCSADRAIN, saved)
    os.close(fd)
sys.stderr.write('\r\nRELAY-DONE\r\n')
