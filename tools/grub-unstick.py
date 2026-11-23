import serial
import sys
import time

port = sys.argv[1] if len(sys.argv) > 1 else "COM5"
s = serial.Serial(port, 115200, timeout=0.5)
time.sleep(0.3)


def send(payload, wait=0.8, label=""):
    s.reset_input_buffer()
    s.write(payload)
    time.sleep(wait)
    got = s.read(2000)
    print(label, "->", repr(got[-160:]))
    return got


# GRUB is sitting on its continuation prompt; ESC and Ctrl-C both abort.
send(b"\x1b", 0.5, "ESC")
send(b"\x03", 0.5, "CTRL-C")
send(b"\r", 0.8, "CR")
send(b"normal\r", 1.5, "normal")
s.close()
