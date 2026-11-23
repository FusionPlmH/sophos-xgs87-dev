import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(('0.0.0.0', 6666))
s.settimeout(1.0)
f = open(r'logs\npu-netcon.log', 'wb', buffering=0)
f.write(b"\n===== start %s =====\n" % time.strftime('%H:%M:%S').encode())
while True:
    try:
        d, a = s.recvfrom(65535)
        f.write(d)
    except socket.timeout:
        pass
