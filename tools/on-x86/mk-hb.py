#!/usr/bin/env python3
"""生成一个"心跳桩"：往 TF-A 已配好的 UART 死循环打一个字符。

用途：验证 Marvell BootROM 的 UART 注入通道到底通不通。

    python3 mk-hb.py --out /tmp/hb.bin           # 20 字节桩放在 0x0
    python3 mk-hb.py --out /tmp/hb.bin --at 0x48 # 放在 0x48（BL1 代码起点后面）
    python3 mk-hb.py --out /tmp/hb.bin --char Z

判据：BootROM 跳进载荷后串口应该开始刷这个字符。**看得到 ⇒ 我们能在 NPU 的
RAM 里执行任意代码**（完全绕开坏掉的 BL31）；看不到 ⇒ 这条路也堵死。

指令序列（AArch64，小端）：

    movz x0, #0x2000          ; 0xD2840000
    movk x0, #0xf051, lsl 16  ; 0xF2BE0A20   → x0 = 0xF0512000 (UART THR)
  loop:
    mov  w1, #'X'             ; 0x52800B01
    str  w1, [x0]             ; 0xB9000001
    b    loop                 ; 0x17FFFFFE

0xF0512000 是 Marvell CN9130 (AP806) 的 UART0 数据寄存器；TF-A 在打印 NOTICE 时
已经把它配好了，所以桩不需要自己初始化串口。**但如果 BootROM 的 UART 恢复模式
不跑 binary extension（即不初始化 UART），这个地址可能还没被配好** —— 看不到
字符时先换 `--at`/`--char` 重试，再考虑加"自己初始化 UART"的版本。
"""
import argparse
import struct
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

STUB_WORDS = [
    0xD2840000,   # movz x0, #0x2000
    0xF2BE0A20,   # movk x0, #0xf051, lsl #16
]


def build(char):
    if not (0x20 <= ord(char) < 0x7F):
        raise SystemExit("--char 要一个可打印 ASCII 字符")
    words = STUB_WORDS + [
        0x52800000 | (ord(char) << 5) | 1,   # mov w1, #char
        0xB9000001,                          # str w1, [x0]
        0x17FFFFFE,                          # b .-8
    ]
    return b"".join(struct.pack("<I", w) for w in words)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--at", type=lambda s: int(s, 0), default=0,
                    help="桩在载荷文件里的偏移（默认 0）")
    ap.add_argument("--size", type=int, default=512,
                    help="输出文件大小，至少一个 XMODEM 块（默认 512）")
    ap.add_argument("--char", default="X")
    a = ap.parse_args()

    stub = build(a.char)
    if a.at + len(stub) > a.size:
        raise SystemExit("--at {} + {} 字节超出了 --size {}".format(a.at, len(stub), a.size))
    blob = bytearray(b"\x00" * a.size)
    blob[a.at:a.at + len(stub)] = stub
    with open(a.out, "wb") as fh:
        fh.write(blob)
    print("{}: {} 字节，桩 {} 字节放在 +0x{:X}，心跳字符 '{}'".format(
        a.out, len(blob), len(stub), a.at, a.char))
    print("  前 32 字节: " + blob[:32].hex())


if __name__ == "__main__":
    main()
