#!/usr/bin/env python3
"""极简 TFTP 服务器（RFC 1350 + blksize），只做 RRQ —— 给 NPU 的 U-Boot 用。

    ./tftp.py <dir> [port]

只有一条连接在工作，而且所有包都从同一个 socket 发出去（不另开 TID）：
U-Boot 的 tftp 用"回包的源地址"当后续目标，客户端（curl/atftp）则把 ACK
发回它连的那个端口 —— 同端口收发对两边都成立，也省掉一堆状态。
"""
import os
import socket
import struct
import sys

RRQ, DATA, ACK, ERROR, OACK = 1, 3, 4, 5, 6


def send_file(sock, path, peer, blksize):
    with open(path, "rb") as f:
        block = 1
        while True:
            chunk = f.read(blksize)
            pkt = struct.pack("!HH", DATA, block & 0xFFFF) + chunk
            for _ in range(6):
                sock.sendto(pkt, peer)
                sock.settimeout(2)
                try:
                    ack, apeer = sock.recvfrom(blksize + 4)
                except socket.timeout:
                    continue
                if len(ack) >= 4 and ack[:2] == struct.pack("!H", ACK) \
                        and struct.unpack("!H", ack[2:4])[0] == (block & 0xFFFF):
                    peer = apeer
                    break
            else:
                print("tftp: giving up on block %d" % block, flush=True)
                return
            if len(chunk) < blksize:
                return
            block += 1


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 69
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", port))
    print("tftp: serving %s on udp/%d" % (root, port), flush=True)
    while True:
        try:
            data, peer = sock.recvfrom(2048)
        except OSError:
            continue
        if len(data) < 4 or struct.unpack("!H", data[:2])[0] != RRQ:
            # ACK 之类的东西落到这里说明有客户端在跟我们说话，忽略即可
            continue
        parts = data[2:].split(b"\x00")
        name = parts[0].decode()
        opts = {}
        for i in range(2, len(parts) - 1, 2):   # filename \0 mode \0 opt \0 val \0
            if parts[i]:
                opts[parts[i].decode().lower()] = parts[i + 1].decode()
        path = os.path.join(root, os.path.basename(name))
        if not os.path.isfile(path):
            print("tftp: %s: not found" % name, flush=True)
            sock.sendto(struct.pack("!HH", ERROR, 1) + b"not found\x00", peer)
            continue
        blksize = max(8, min(int(opts.get("blksize", 512)), 8192)) if "blksize" in opts else 512
        print("tftp: %s -> %s:%d blksize=%d size=%d" %
              (name, peer[0], peer[1], blksize, os.path.getsize(path)), flush=True)
        if "blksize" in opts:
            sock.sendto(struct.pack("!HH", OACK, 0) + ("blksize\x00%d\x00" % blksize).encode(), peer)
            sock.settimeout(3)
            try:
                ack, apeer = sock.recvfrom(64)
                if len(ack) >= 4 and ack[:2] == struct.pack("!H", ACK):
                    peer = apeer
            except socket.timeout:
                continue
        send_file(sock, path, peer, blksize)
        print("tftp: %s done" % name, flush=True)


if __name__ == "__main__":
    main()