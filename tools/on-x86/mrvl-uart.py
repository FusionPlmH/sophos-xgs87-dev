#!/usr/bin/env python3
"""Marvell BootROM UART 恢复通道：pattern 锁定 + XMODEM-128 送载荷。

为什么要这个：这条路**完全不经过 TF-A / BL31 / CP0 MSS**，是唯一能在 NPU 的
CPU 还没跑完固件时把代码塞进 RAM 并执行的手段。判据极简单——送一个只往串口
死循环打 `X` 的桩（见 mk-hb.py），看得到 `X` 就说明通道可用。

协议（与 u-boot/tools/mrvl_uart.sh 一致，见 docs/23 §23.10）：

  1. 主机连续发 pattern `BB 11 22 33 44 55 66 77`。BootROM 只在启动窗口
     内认这个（2026-11-24 的 rescan 风暴里约 3.2 s 一轮；正常启动窗口更短），
     一旦认出来就锁定 UART 恢复模式并回 `0x15`（XMODEM-128 checksum 模式）。
     **必须先 pattern 再传**，否则窗口极短。
  2. 之后按 XMODEM-128 传：每个包 `STX seq ~seq data[128] checksum(1)`，
     等 `ACK(0x06)`，`NAK(0x15)` 或超时就重发同一包。
  3. 全部发完发 `EOT(0x04)`，收到 `ACK` 说明 BootROM 收下了，会把载荷拷到 RAM
     并跳过去执行。

用法：

    sudo python3 mrvl-uart.py --file /tmp/hb.bin                    # 默认 /dev/ttyS2 115200
    sudo python3 mrvl-uart.py --file /tmp/hb.bin --lock-timeout 30
    sudo python3 mrvl-uart.py --file x.bin --baud 230400 --speedup F2

注意：串口要用 raw；`stty raw` **不会**清 `crtscts`，所以这里直接设 termios，
不接受"先 stty 再跑"的半吊子做法。
"""
import argparse
import os
import sys
import time

try:
    import termios
except ImportError:          # Windows 上只能看 --help，收发必须在 Linux（x86）上跑
    termios = None

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

PATTERN = bytes([0xBB, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77])
SOH, STX, EOT, ACK, NAK, CAN = 0x01, 0x02, 0x04, 0x06, 0x15, 0x18
BAUDS = {
    115200: "B115200",
    230400: "B230400",
    460800: "B460800",
    921600: "B921600",
}
SPEEDUP = {"F2": b"F2", "F4": b"F4", "F8": b"F8"}


def _baud_const(name):
    value = getattr(termios, name, None)
    if value is None:
        raise SystemExit("这个 termios 没有 {}（不是 Linux？）".format(name))
    return value


class Port:
    def __init__(self, path, baud):
        if termios is None:
            raise SystemExit("termios 不可用：这个脚本只能在 Linux（x86 上）跑")
        if baud not in BAUDS:
            raise SystemExit("不支持的波特率 {}，只支持 {}".format(
                baud, ", ".join(str(b) for b in sorted(BAUDS))))
        speed = _baud_const(BAUDS[baud])
        self.fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        a = termios.tcgetattr(self.fd)
        a[0] = 0                                  # iflag: 关掉 IXON/IXOFF/CR 转换
        a[1] = 0                                  # oflag: 关掉 OPOST
        a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL   # 无 CRTSCTS
        a[3] = 0                                  # lflag: raw
        a[4] = speed
        a[5] = speed
        a[6][termios.VMIN] = 0
        a[6][termios.VTIME] = 1                   # 读超时 100 ms
        termios.tcsetattr(self.fd, termios.TCSANOW, a)
        termios.tcflush(self.fd, termios.TCIOFLUSH)

    def write(self, data):
        view = memoryview(data)
        while view:
            try:
                n = os.write(self.fd, view)
            except BlockingIOError:
                time.sleep(0.01)
                continue
            view = view[n:]

    def read(self, n=1, timeout=1.0):
        end = time.time() + timeout
        buf = b""
        while time.time() < end and len(buf) < n:
            try:
                chunk = os.read(self.fd, max(1, n - len(buf)))
            except OSError:
                chunk = b""
            if chunk:
                buf += chunk
            else:
                time.sleep(0.01)
        return buf

    def drain(self):
        try:
            os.read(self.fd, 65536)
        except OSError:
            pass

    def close(self):
        os.close(self.fd)


def lock_bootrom(port, timeout, speedup):
    """狂发 pattern 直到 BootROM 回 NAK，说明它进了恢复模式。"""
    start = time.time()
    sent = 0
    while time.time() - start < timeout:
        port.write(PATTERN)
        sent += len(PATTERN)
        data = port.read(16, timeout=0.02)
        if NAK in data:
            print("NAK seen after {:.2f} s ({} bytes of pattern)".format(
                time.time() - start, sent))
            if speedup:
                port.write(SPEEDUP[speedup])
                ack = port.read(1, timeout=2.0)
                print("speed-up {} -> {}".format(
                    speedup, hex(ack[0]) if ack else "no reply"))
            return True
        if ACK in data:
            print("注意：收到 ACK 而不是 NAK（{}）".format(data.hex()))
            return True
    return False


def send_xmodem(port, payload, retries=10):
    total = len(payload)
    sent = 0
    seq = 1
    start = time.time()
    for off in range(0, total, 128):
        chunk = payload[off:off + 128]
        if len(chunk) < 128:
            chunk = chunk + b"\x1A" * (128 - len(chunk))   # XMODEM 填空
        packet = bytes([STX, seq & 0xFF, (~seq) & 0xFF]) + chunk + bytes([sum(chunk) & 0xFF])
        for attempt in range(1, retries + 1):
            port.write(packet)
            reply = port.read(1, timeout=3.0)
            if reply and reply[0] == ACK:
                seq += 1
                sent += len(chunk) if off + 128 <= total else total - off
                pct = 100.0 * sent / total if total else 100.0
                rate = sent / max(1e-6, time.time() - start) / 1024.0
                sys.stdout.write("\r{:5.1f}% {}/{} {:.1f} KiB/s".format(
                    pct, sent, total, rate))
                sys.stdout.flush()
                break
            if reply and reply[0] == CAN:
                print("\n对端发了 CAN，传输中止")
                return False
        else:
            print("\n包 #{} 重试 {} 次都没 ACK".format(seq, retries))
            return False
    print()
    return True


def main():
    ap = argparse.ArgumentParser(description="Marvell BootROM UART 恢复（pattern + XMODEM-128）")
    ap.add_argument("--port", default="/dev/ttyS2")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--file", required=True, help="要送进 RAM 的载荷")
    ap.add_argument("--lock-timeout", type=float, default=20.0,
                    help="最多花多久狂发 pattern 等 BootROM 锁定（默认 20 s）")
    ap.add_argument("--speedup", choices=sorted(SPEEDUP),
                    help="锁定后先协商更高波特率（F2=230400 F4=460800 F8=921600）")
    ap.add_argument("--no-eot", action="store_true", help="不发送 EOT（调试用）")
    a = ap.parse_args()

    with open(a.file, "rb") as fh:
        payload = fh.read()
    if not payload:
        raise SystemExit("载荷是空的")
    print("载荷 {} 字节，端口 {} @ {}".format(len(payload), a.port, a.baud))

    port = Port(a.port, a.baud)
    try:
        port.drain()
        print("狂发 pattern 等 BootROM 锁定（最多 {:.0f} s；复位循环时约 3.2 s 一轮）...".format(
            a.lock_timeout))
        if not lock_bootrom(port, a.lock_timeout, a.speedup):
            print("没能锁定 BootROM：{} 秒内没等到 NAK。".format(a.lock_timeout))
            print("  - NPU 完全没电/没在启动？先看 ttyS2 上有没有 BootROM 循环；")
            print("  - 或者这个端口收不到（TX 没接）？")
            return 1
        if not send_xmodem(port, payload):
            return 1
        if not a.no_eot:
            port.write(bytes([EOT]))
            reply = port.read(1, timeout=5.0)
            if reply and reply[0] == ACK:
                print("EOT -> 0x06 transfer ok（BootROM 收下了，正在跳过去执行）")
            else:
                print("EOT 没收到 ACK（收到 {}）".format(
                    hex(reply[0]) if reply else "无回复"))
                return 1
        return 0
    finally:
        port.close()


if __name__ == "__main__":
    sys.exit(main())
