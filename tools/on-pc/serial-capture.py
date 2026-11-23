import serial, time, sys
port = 'COM5'
out = r'logs\x86-console.log'
s = serial.Serial(port, 115200, timeout=1)
f = open(out, 'ab', buffering=0)
f.write(b"\n\n===== capture start %s =====\n" % time.strftime('%H:%M:%S').encode())
while True:
    try:
        d = s.read(4096)
        if d:
            f.write(d)
    except Exception as e:
        f.write(b"\n[read error %s]\n" % str(e).encode())
        time.sleep(1)