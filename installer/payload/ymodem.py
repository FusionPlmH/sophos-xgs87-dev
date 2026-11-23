#!/usr/bin/env python3
"""YMODEM 批量发送（带 1k 块 + CRC16），给 U-Boot 的 `loady` 用。

    ./ymodem.py /dev/ttyS2 file1 file2 ...

为什么自己写：U 盘系统里不想为了一次急救再装 lrzsz，而且这条链路是
"串口 + 只有 3 秒窗口的 U-Boot"，需要能自己控制超时和重试。

协议要点（U-Boot 的 loady 就是标准 YMODEM）：
  接收方先发 'C' (0x43) → 发送方发 SOH/STX 帧，块号从 0 开始
  帧格式：SOH(128B)/STX(1024B) + blk + ~blk + data + CRC16(hi,lo)
  第 0 块是文件头："<name>\\0<size>\\0"，数据区补 0x1a
  文件发完发 EOT，等 ACK，再等下一个 'C' 开下一个文件
  最后发一个空的第 0 块（只有 name 位置是 0）表示批次结束，等 ACK
"""
import os
import sys

SOH, STX, EOT, ACK, NAK, CAN, CRC_C = 0x01, 0x02, 0x04, 0x06, 0x15, 0x18, 0x43


def crc16(data):
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


class Sender:
    def __init__(self, fd, verbose=True):
        self.fd = fd
        self.verbose = verbose
        self.retries = 10

    def read_byte(self, timeout):
        import select
        r, _, _ = select.select([self.fd], [], [], timeout)
        if not r:
            return None
        try:
            data = os.read(self.fd, 1)
        except OSError:
            return None
        return data[0] if data else None

    def wait_for(self, want, timeout):
        """等一个期望的字节，顺手吸收 CAN。"""
        while True:
            b = self.read_byte(timeout)
            if b is None:
                return False
            if b == want:
                return True
            if b == CAN:
                raise SystemExit("ymodem: 对端取消（收到 CAN）")
            # 其它字节（例如回显）忽略

    def send_packet(self, payload, blk):
        fill = 0x1A
        if len(payload) <= 128 and blk != 0:
            head, size = SOH, 128
        else:
            head, size = STX, 1024
        body = payload + bytes([fill]) * (size - len(payload))
        frame = bytes([head, blk & 0xFF, 0xFF - (blk & 0xFF)]) + body
        crc = crc16(body)
        frame += bytes([(crc >> 8) & 0xFF, crc & 0xFF])
        for attempt in range(self.retries):
            os.write(self.fd, frame)
            b = self.read_byte(3)
            if b == ACK:
                return True
            if b is not None and attempt == 0:
                pass
        return False

    def send_file(self, path):
        name = os.path.basename(path)
        size = os.path.getsize(path)
        if self.verbose:
            print("ymodem: %s (%d bytes)" % (name, size), file=sys.stderr)
        if not self.wait_for(CRC_C, 30):
            raise SystemExit("ymodem: 对端没有发 'C'（不在 loady 里？）")
        header = ("%s\x00%d\x00" % (name, size)).encode()
        if not self.send_packet(header, 0):
            raise SystemExit("ymodem: 文件头没被确认")
        if not self.wait_for(CRC_C, 10):
            raise SystemExit("ymodem: 文件头之后没等到 'C'")
        blk = 1
        sent = 0
        with open(path, "rb") as f:
            while sent < size:
                chunk = f.read(1024)
                if not chunk:
                    break
                for attempt in range(self.retries):
                    if self.send_packet(chunk, blk):
                        break
                else:
                    raise SystemExit("ymodem: 第 %d 块重试用尽" % blk)
                sent += len(chunk)
                blk = (blk + 1) & 0xFF
                if self.verbose and sent % (1024 * 256) == 0:
                    print("ymodem: %d/%d KiB" % (sent // 1024, size // 1024), file=sys.stderr)
        for attempt in range(self.retries):
            os.write(self.fd, bytes([EOT]))
            if self.wait_for(ACK, 3):
                break
        else:
            raise SystemExit("ymodem: EOT 没被确认")
        return True

    def finish(self):
        # 空文件名 = 批次结束
        os.write(self.fd, bytes([EOT]))
        self.wait_for(ACK, 3)
        if self.wait_for(CRC_C, 5):
            self.send_packet(b"", 0)
            return


def make_raw(path):
    """串口必须是 raw：默认的 canonical 模式会把单个 'C' 扣住不交给我们。"""
    import termios
    import tty
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
    try:
        attrs = termios.tcgetattr(fd)
        attrs[0] &= ~(termios.IGNBRK | termios.BRKINT | termios.PARMRK | termios.ISTRIP |
                      termios.INLCR | termios.IGNCR | termios.ICRNL)
        attrs[1] &= ~termios.OPOST
        attrs[2] &= ~(termios.CSIZE | termios.PARENB | termios.CSTOPB)
        attrs[2] |= termios.CS8
        attrs[3] &= ~(termios.ECHO | termios.ECHONL | termios.ICANON | termios.ISIG | termios.IEXTEN)
        attrs[6][termios.VMIN] = 1
        attrs[6][termios.VTIME] = 0
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
    except termios.error:
        pass
    return fd


def main():
    if len(sys.argv) < 3:
        raise SystemExit("用法: ymodem.py <tty> file...")
    fd = make_raw(sys.argv[1])
    s = Sender(fd)
    for path in sys.argv[2:]:
        s.send_file(path)
    s.finish()
    print("ymodem: done", file=sys.stderr)


if __name__ == "__main__":
    main()