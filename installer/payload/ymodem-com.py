#!/usr/bin/env python3
"""YMODEM 发送（pyserial 版），给 U-Boot 的 `loady` 用 —— 在 Windows/任何有 COM 口的地方跑。

和 `ymodem.py` 的区别：那个跑在 Linux 上、直接开 tty 设备；这个只认 `COM5` 这种
端口名，用 pyserial。PC 通过 `relay.py` 透传到 NPU 的 UART 时用它。

    ymodem-com.py COM5 send 0x06f00000 xgs87.dtb      # 打 loady，再推文件
    ymodem-com.py COM5 cmd  "printenv filesize"       # 只打一行、回显 8 s
    ymodem-com.py COM5 hear 5                         # 只看 5 s 串口输出

注意三件事（都是实测踩过的）：
  * U-Boot 的 loady 在收块之间会补发 'C' 当"重传请求"，所以每帧前先把残留字节排空，
    否则会读到上一个 'C' 而误判成失败。
  * 一定要看 U-Boot 最后打的 `## Total Size`，它才是"真的收全了"的唯一证据。
  * 只支持 SOH(128)/STX(1024)，不能加大块 —— U-Boot 就这个规格。
"""
import os
import sys
import time

import serial

SOH, STX, EOT, ACK, NAK, CAN, CRC_C = 0x01, 0x02, 0x04, 0x06, 0x15, 0x18, 0x43


def crc16(data):
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


class Tx:
    def __init__(self, port):
        self.p = port
        self.retries = 10
        self.log = b''

    def _keep(self, d):
        if d:
            self.log = (self.log + d)[-4000:]

    def drain(self, seconds=0.0):
        end = time.time() + seconds
        got = b''
        while True:
            n = self.p.in_waiting
            if n:
                d = self.p.read(n)
                got += d
                self._keep(d)
                continue
            if time.time() >= end:
                return got
            time.sleep(0.002)

    def read1(self, timeout):
        self.p.timeout = max(0.02, timeout)
        d = self.p.read(1)
        if d:
            self._keep(d)
            return d[0]
        return None

    def wait_for(self, want, timeout):
        end = time.time() + timeout
        while time.time() < end:
            b = self.read1(end - time.time())
            if b is None:
                continue
            if b == want:
                return True
            if b == CAN:
                raise SystemExit('ymodem: 收到 CAN -> %r' % self.log[-200:])
        return False

    def send_packet(self, payload, blk, what='data'):
        fill = 0x1A
        if len(payload) <= 128 and blk != 0:
            head, size = SOH, 128
        else:
            head, size = STX, 1024
        body = payload + bytes([fill]) * (size - len(payload))
        frame = bytes([head, blk & 0xFF, 0xFF - (blk & 0xFF)]) + body
        c = crc16(body)
        frame += bytes([(c >> 8) & 0xFF, c & 0xFF])
        for attempt in range(self.retries):
            self.drain(0)          # 残留的 'C' 不能当 ACK 用
            self.p.write(frame)
            self.p.flush()
            b = self.read1(4)
            if b == ACK:
                return True
            if attempt == 0:
                sys.stderr.write('  [%s blk %d: 收到 %r，重传]\n' % (what, blk, b))
        return False

    def send_file(self, path, chunk=1024):
        name = os.path.basename(path)
        size = os.path.getsize(path)
        sys.stderr.write('ymodem: %s (%d bytes)\n' % (name, size))
        if not self.wait_for(CRC_C, 30):
            raise SystemExit("ymodem: 没等到 'C'（U-Boot 没在 loady 里？）")
        header = ('%s\x00%d\x00' % (name, size)).encode()
        if not self.send_packet(header, 0, 'hdr'):
            raise SystemExit('ymodem: 文件头没被确认')
        if not self.wait_for(CRC_C, 10):
            raise SystemExit("ymodem: 文件头之后没等到 'C'")
        blk = 1
        sent = 0
        t0 = time.time()
        with open(path, 'rb') as f:
            while sent < size:
                data = f.read(chunk)
                if not data:
                    break
                if not self.send_packet(data, blk):
                    raise SystemExit('ymodem: 第 %d 块重试用尽' % blk)
                sent += len(data)
                blk = (blk + 1) & 0xFF
                if sent % (chunk * 256) == 0 or sent >= size:
                    el = time.time() - t0
                    kbs = sent / 1024.0 / el if el else 0
                    eta = (size - sent) / (kbs * 1024) if kbs else 0
                    sys.stderr.write('  %6.2f/%6.2f MiB  %5.1f KiB/s  eta %4.0fs\n'
                                     % (sent / 1048576.0, size / 1048576.0, kbs, eta))
        for _ in range(self.retries):
            self.p.write(bytes([EOT]))
            self.p.flush()
            if self.wait_for(ACK, 3):
                break
        else:
            raise SystemExit('ymodem: EOT 没被确认')
        sys.stderr.write('ymodem: %s 传完，%.1fs（%.1f KiB/s）\n'
                         % (name, time.time() - t0, size / 1024.0 / (time.time() - t0)))
        return True


def open_port(name):
    p = serial.Serial()
    p.port = name
    p.baudrate = 115200
    p.bytesize = serial.EIGHTBITS
    p.parity = serial.PARITY_NONE
    p.stopbits = serial.STOPBITS_ONE
    p.timeout = 0.05
    p.write_timeout = 10
    p.dtr = False          # 别拉 DTR：对面是登录着的 console，掉 DTR 可能 SIGHUP 掉 shell
    p.rts = False
    p.open()
    return p


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    port = sys.argv[1]
    verb = sys.argv[2]
    p = open_port(port)
    tx = Tx(p)
    try:
        tx.drain(0.3)
        if verb == 'send':
            addr, path = sys.argv[3], sys.argv[4]
            p.write(('loady %s\r' % addr).encode())
            p.flush()
            sys.stderr.write('== 已输入: loady %s\n' % addr)
            tx.send_file(path)
            got = tx.drain(6.0)
            sys.stderr.write('== 回复: %r\n' % got[-300:])
        elif verb == 'cmd':
            p.write((sys.argv[3] + '\r').encode())
            p.flush()
            got = tx.drain(8.0)
            sys.stderr.write(got.decode('utf-8', 'replace'))
        elif verb == 'hear':
            got = tx.drain(float(sys.argv[3]))
            sys.stderr.write(got.decode('utf-8', 'replace'))
        else:
            raise SystemExit('不认识的动词 %s' % verb)
    finally:
        p.close()


if __name__ == '__main__':
    main()
