#!/usr/bin/env python3
"""MCP2210 USB-SPI tool for the NPU's 4 MiB SPI NOR (XGS 87 rescue path).

Runs on the x86 side (Debian) against /dev/hidraw0 (04d8:00de).  It speaks the
MCP2210 HID command set from DS22288A directly through hidraw, so there is no
libusb/hidapi dependency:

    0x10 get status                 0x11 cancel SPI transfer
    0x20/0x21 get/set GPIO          0x30/0x31 set/get GPIO value
    0x32/0x33 set/get GPIO dir      0x40/0x41 set/get SPI settings
    0x42 SPI transfer               0x80 request SPI bus release

The flash is a Macronix MX25L3205D (4 MiB, 64 KiB blocks, JEDEC C2 20 16):

    0x000000..0x3F0000   U-Boot + TF-A (mtd0, only `mtd0-restore` writes it)
    0x3F0000..0x400000   U-Boot env (mtd1, the normal writable region)

Safety model (enforced, not just documented):

  * `dump` reads the whole chip twice and only then writes the backup + manifest.
  * `env-write` refuses to run without a two-pass verified backup, re-reads the
    chip to prove the backup is still current, checks mtd0 against the known-good
    reference, and never touches a byte outside the env block.
  * A failed env write automatically rolls the original env back from the backup.
  * `env-write` is a dry-run plan unless --commit is given; --commit also asks
    for an interactive confirmation unless --yes is used.
  * `mtd0-restore` is the repair path for a damaged U-Boot/TF-A region.  It needs
    a verified backup, an exactly 0x3F0000-byte image with a known SHA-256, and
    *both* --unsafe-mtd0 and --commit; it then rewrites only the 64 KiB blocks
    that differ, verifies each one, and never touches the env block.

Examples (on the x86):

    sudo ./mcp2210-nor.py info --read-env
    sudo ./mcp2210-nor.py dump --out /var/tmp/npu-nor.bin
    sudo ./mcp2210-nor.py verify --backup /var/tmp/npu-nor.bin
    ./mcp2210-nor.py compare --dump /var/tmp/npu-nor.bin
    ./mcp2210-nor.py env-build --from-backup /var/tmp/npu-nor.bin \
        --out /var/tmp/env-p2.bin --set 'bootcmd=run bootcmd_emmc2'
    sudo ./mcp2210-nor.py env-write --backup /var/tmp/npu-nor.bin \
        --image /var/tmp/env-p2.bin            # plan only
    sudo ./mcp2210-nor.py env-write --backup /var/tmp/npu-nor.bin \
        --image /var/tmp/env-p2.bin --commit --yes
"""

from __future__ import annotations

import argparse
import binascii
import errno
import glob
import gzip
import hashlib
import json
import os
import re
import select
import struct
import subprocess
import sys
import time
import zlib
from collections import OrderedDict

TOOL_VERSION = "1.0"

VID = 0x04D8
PID = 0x00DE
VID_PID_TEXT = "04d8:00de"

FLASH_SIZE = 0x400000
UBOOT_OFFSET = 0x000000
UBOOT_SIZE = 0x3F0000
ENV_OFFSET = 0x3F0000
ENV_SIZE = 0x10000
ENV_DATA_SIZE = ENV_SIZE - 4  # U-Boot's env_t.data[] covers the whole sector

JEDEC_ID = b"\xc2\x20\x16"
CHIP_NAME = "MX25L3205D"

# MCP2210 commands (DS22288A section 3)
CMD_GET_STATUS = 0x10
CMD_CANCEL = 0x11
CMD_GET_GPIO = 0x20
CMD_SET_GPIO = 0x21
CMD_SET_GPIO_VALUE = 0x30
CMD_GET_GPIO_VALUE = 0x31
CMD_SET_GPIO_DIR = 0x32
CMD_GET_GPIO_DIR = 0x33
CMD_SET_SPI = 0x40
CMD_GET_SPI = 0x41
CMD_SPI_XFER = 0x42
CMD_RELEASE = 0x80

GPIO_DESIGNATION_GPIO = 0x00
GPIO_DESIGNATION_CS = 0x01
GPIO_DESIGNATION_FUNC = 0x02
GPIO_DESIGNATION_NAMES = {
    GPIO_DESIGNATION_GPIO: "GPIO",
    GPIO_DESIGNATION_CS: "CS",
    GPIO_DESIGNATION_FUNC: "FUNC",
}
GPIO_COUNT = 9
GPIO_MASK = (1 << GPIO_COUNT) - 1

# MCP2210 status/return codes
MCP_OK = 0x00
MCP_SPI_BUS_LOCKED = 0xF7
MCP_BUSY = 0xF8
MCP_UNKNOWN_COMMAND = 0xF9

# SPI transfer-engine status byte (response byte 3 of 0x42)
SPI_ENGINE_STARTED = 0x20
SPI_ENGINE_DATA_AVAILABLE = 0x30
SPI_ENGINE_FINISHED = 0x10

# MX25L3205D commands
NOR_RDID = 0x9F
NOR_READ = 0x03
NOR_RDSR = 0x05
NOR_WREN = 0x06
NOR_WRDI = 0x04
NOR_WRSR = 0x01
NOR_PP = 0x02
NOR_SE = 0x20
NOR_BE = 0xD8
NOR_CE = 0x60
NOR_DP = 0xB9
NOR_RDP = 0xAB

SR_WIP = 0x01
SR_WEL = 0x02
SR_BP_MASK = 0x1C  # BP0..BP2
SR_SRWD = 0x80

# MCP2210 packet layout: 0x42 carries at most 60 payload bytes (bytes 4..63)
MCP_MAX_XFER_CHUNK = 60
# A programmable page is 256 bytes; the 4-byte PP header leaves 56 bytes.
NOR_MAX_PP_DATA = MCP_MAX_XFER_CHUNK - 4

DEFAULT_SPEEDS = [1_000_000, 500_000, 250_000, 100_000, 50_000, 10_000]
DEFAULT_READ_CHUNK = 4096

# The NPU's reset / SPI-bus-mux lines are GP0, GP3 and GP5 on every ARMADA XGS
# board.  Sophos's xgs-usb-spi-flash drives all three together; the per-board
# values were recovered from that binary (see the os-xgs-npu reference repo,
# docs/npuep/npu-bring-up.md).  AMDA0200 (XGS 87/107) is the inverse of AMDA0201.
NPU_MASK = 0x0029
NPU_VALUES = {
    200: {"hold": 0xFFD7, "release": 0xFFFF},  # XGS 87 / 107 (AMDA0200)
    201: {"hold": 0xFFFF, "release": 0xFFD7},  # XGS 126 / 136
    202: {"hold": 0xFFDF, "release": 0xFFF7},
    203: {"hold": 0xFFDF, "release": 0xFFF7},
    204: {"hold": 0xFFDF, "release": 0xFFF7},
    205: {"hold": 0xFFDF, "release": 0xFFF7},
    208: {"hold": 0xFFFF, "release": 0xFFD7},  # XGS 116
    224: {"hold": 0xFFFF, "release": 0xFFD7},  # XGS 138
}

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


# --------------------------------------------------------------------------
# errors / logging / small helpers
# --------------------------------------------------------------------------

class ToolError(Exception):
    exit_code = 1


class SafetyError(ToolError):
    exit_code = 3


class ProtocolError(ToolError):
    exit_code = 1


class TransferTimeout(ToolError):
    exit_code = 1


def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def hexs(data):
    return binascii.hexlify(data).decode("ascii")


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def crc32_uboot(data):
    return zlib.crc32(data) & 0xFFFFFFFF


class Logger:
    """Console output plus an optional append-only log file."""

    def __init__(self, path=None, debug=False, quiet=False):
        self.path = path
        self.debug_enabled = debug
        self.quiet = quiet
        self.fh = None
        if path:
            parent = os.path.dirname(os.path.abspath(path))
            if parent:
                os.makedirs(parent, exist_ok=True)
            self.fh = open(path, "a", encoding="utf-8", errors="replace")

    def _line(self, level, msg):
        line = "{} [{}] {}".format(utc_now(), level, msg)
        if self.fh:
            self.fh.write(line + "\n")
            self.fh.flush()
        if level == "DEBUG" and not self.debug_enabled:
            return
        if level in ("INFO", "DEBUG") and self.quiet:
            return
        if self.fh:
            print(line, file=sys.stderr)
        elif level == "ERROR":
            print("ERROR: " + msg, file=sys.stderr)
        elif level == "WARN":
            print("WARNING: " + msg, file=sys.stderr)
        elif level == "DEBUG":
            print("DBG: " + msg, file=sys.stderr)
        else:
            print(msg, file=sys.stderr)

    def info(self, msg):
        self._line("INFO", msg)

    def warn(self, msg):
        self._line("WARN", msg)

    def error(self, msg):
        self._line("ERROR", msg)

    def debug(self, msg):
        self._line("DEBUG", msg)

    def trace(self, prefix, data):
        if self.debug_enabled:
            self.debug("{} {}".format(prefix, hexs(data)))

    def close(self):
        if self.fh:
            try:
                self.fh.close()
            finally:
                self.fh = None


class Progress:
    def __init__(self, logger, label, total):
        self.logger = logger
        self.label = label
        self.total = total
        self.done = 0
        self.t0 = time.monotonic()
        self.last = 0.0
        self.last_log = 0.0
        self.tty = sys.stderr.isatty()

    def _format(self, now):
        elapsed = max(1e-6, now - self.t0)
        rate = self.done / elapsed
        remain = max(0, self.total - self.done)
        eta = remain / rate if rate > 0 else 0
        pct = 100.0 * self.done / self.total if self.total else 100.0
        return "{} {:>6.1f}% ({}/{} KiB) {:.1f} KiB/s ETA {:02d}:{:02d}".format(
            self.label, pct, self.done // 1024, self.total // 1024,
            rate / 1024.0, int(eta // 60), int(eta % 60))

    def __call__(self, done, total=None):
        self.done = int(done)
        if total is not None:
            self.total = int(total)
        now = time.monotonic()
        if not self.tty:
            if self.done >= self.total or now - self.last_log >= 10.0:
                self.last_log = now
                self.logger.info(self._format(now))
            return
        if now - self.last < 1.0 and self.done < self.total:
            return
        self.last = now
        sys.stderr.write("\r" + self._format(now))
        if self.done >= self.total:
            sys.stderr.write("\n")
        sys.stderr.flush()

    def finish(self):
        if self.tty and self.done < self.total:
            sys.stderr.write("\n")
        self.last = 0.0
        self(done=self.total)


def write_atomic(path, data):
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    tmp = path + ".part"
    with open(tmp, "wb") as fh:
        fh.write(data)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def read_file(path):
    with open(path, "rb") as fh:
        return fh.read()


def read_optional(path):
    try:
        return read_file(path)
    except OSError as exc:
        if exc.errno == errno.ENOENT:
            return None
        raise


def load_maybe_gzip(path):
    data = read_file(path)
    if data[:2] == b"\x1f\x8b" or path.endswith(".gz"):
        data = gzip.decompress(data)
    return data


def diff_ranges(a, b, limit=16):
    """Return (offset, length) runs where two equal-length buffers differ."""
    if len(a) != len(b):
        return [(0, max(len(a), len(b)))]
    out = []
    start = None
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            if start is None:
                start = i
        elif start is not None:
            out.append((start, i - start))
            start = None
            if len(out) >= limit:
                return out
    if start is not None:
        out.append((start, len(a) - start))
    return out


def format_ranges(ranges):
    return ", ".join("0x{:06X}+0x{:X}".format(o, n) for o, n in ranges)


# --------------------------------------------------------------------------
# U-Boot environment image
# --------------------------------------------------------------------------

def _check_env_key_value(key, value, where):
    if not key:
        raise ToolError("{}: empty variable name".format(where))
    if b"=" in key:
        raise ToolError("{}: '=' in variable name {!r}".format(where, key))
    for what, blob in (("key", key), ("value", value)):
        for c in (0x00, 0x0A, 0x0D):
            if bytes([c]) in blob:
                raise ToolError("{}: NUL/LF/CR in {} {!r}".format(where, what, blob))


def parse_env_data(data_area, where="env"):
    """Parse U-Boot's NUL-separated env data area (without the 4-byte CRC)."""
    items = OrderedDict()
    pos = 0
    end = None
    size = len(data_area)
    while pos < size:
        z = data_area.find(b"\x00", pos)
        if z < 0:
            raise ToolError("{}: missing NUL terminator at offset {}".format(where, pos))
        entry = data_area[pos:z]
        pos = z + 1
        if not entry:
            end = pos
            break
        if b"=" not in entry:
            raise ToolError("{}: entry without '=' at offset {}".format(where, pos - len(entry) - 1))
        key, value = entry.split(b"=", 1)
        _check_env_key_value(key, value, where)
        if key in items:
            raise ToolError("{}: duplicate variable {!r}".format(where, key))
        items[key] = value
    if end is None:
        raise ToolError("{}: no empty entry (double NUL) terminating the env".format(where))
    tail = data_area[end:]
    fill = 0xFF
    if tail and any(c != 0xFF for c in tail):
        if any(c != 0x00 for c in tail):
            raise ToolError("{}: garbage after the terminator at offset {}".format(where, end))
        fill = 0x00
    return items, fill


def load_env_image(image, strict_crc=True, where="env image"):
    if len(image) != ENV_SIZE:
        raise ToolError("{}: expected {} bytes, got {}".format(where, ENV_SIZE, len(image)))
    stored = struct.unpack_from("<I", image, 0)[0]
    calc = crc32_uboot(image[4:])
    if strict_crc and stored != calc:
        raise ToolError(
            "{}: bad U-Boot CRC (stored 0x{:08X}, calculated 0x{:08X})".format(
                where, stored, calc))
    items, fill = parse_env_data(image[4:], where=where)
    return items, stored, calc, fill


def build_env_image(items, fill=0xFF):
    out = bytearray()
    for key, value in items.items():
        key = bytes(key)
        value = bytes(value)
        _check_env_key_value(key, value, "env build")
        out += key + b"=" + value + b"\x00"
    out += b"\x00"
    if len(out) > ENV_DATA_SIZE:
        raise ToolError("env text is {} bytes, maximum is {}".format(len(out), ENV_DATA_SIZE))
    out += bytes([fill]) * (ENV_DATA_SIZE - len(out))
    crc = crc32_uboot(bytes(out))
    return struct.pack("<I", crc) + bytes(out)


def parse_env_text(data, where="env text"):
    items = OrderedDict()
    for lineno, raw in enumerate(data.split(b"\n"), 1):
        line = raw.rstrip(b"\r")
        if not line:
            continue
        if line.lstrip().startswith(b"#"):
            continue
        if b"=" not in line:
            raise ToolError("{}:{}: expected key=value".format(where, lineno))
        key, value = line.split(b"=", 1)
        _check_env_key_value(key, value, "{}:{}".format(where, lineno))
        if key in items:
            raise ToolError("{}:{}: duplicate variable {!r}".format(where, lineno, key))
        items[key] = value
    return items


def env_diff(old, new):
    added = [k for k in new if k not in old]
    removed = [k for k in old if k not in new]
    changed = [k for k in old if k in new and old[k] != new[k]]
    return added, removed, changed


def mac_is_placeholder(items):
    value = items.get(b"ethaddr")
    return value is not None and b"xx" in value.lower()


def _printable(value):
    try:
        return value.decode("utf-8")
    except UnicodeDecodeError:
        return value.decode("latin-1")


# --------------------------------------------------------------------------
# MCP2210 protocol
# --------------------------------------------------------------------------

class SpiSettings:
    """The 17-byte RAM SPI transfer settings structure (DS22288A 3.2.1/3.2.2)."""

    __slots__ = ("bit_rate", "idle_cs", "active_cs", "cs_to_data",
                 "data_to_cs", "interbyte", "xfer_size", "mode")

    def __init__(self, bit_rate=1_000_000, idle_cs=0x01FF, active_cs=0x01FE,
                 cs_to_data=0, data_to_cs=0, interbyte=0, xfer_size=4, mode=0):
        self.bit_rate = int(bit_rate)
        self.idle_cs = int(idle_cs) & 0xFFFF
        self.active_cs = int(active_cs) & 0xFFFF
        self.cs_to_data = int(cs_to_data) & 0xFFFF
        self.data_to_cs = int(data_to_cs) & 0xFFFF
        self.interbyte = int(interbyte) & 0xFFFF
        self.xfer_size = int(xfer_size) & 0xFFFF
        self.mode = int(mode) & 0x03

    @classmethod
    def unpack(cls, data):
        if len(data) != 17:
            raise ProtocolError("SPI settings structure is {} bytes, expected 17".format(len(data)))
        return cls(
            bit_rate=struct.unpack_from("<I", data, 0)[0],
            idle_cs=struct.unpack_from("<H", data, 4)[0],
            active_cs=struct.unpack_from("<H", data, 6)[0],
            cs_to_data=struct.unpack_from("<H", data, 8)[0],
            data_to_cs=struct.unpack_from("<H", data, 10)[0],
            interbyte=struct.unpack_from("<H", data, 12)[0],
            xfer_size=struct.unpack_from("<H", data, 14)[0],
            mode=data[16],
        )

    def pack(self):
        return struct.pack("<IHHHHHHB", self.bit_rate, self.idle_cs, self.active_cs,
                           self.cs_to_data, self.data_to_cs, self.interbyte,
                           self.xfer_size, self.mode)

    def validate(self):
        if not 1_500 <= self.bit_rate <= 12_000_000:
            raise ProtocolError("SPI bit rate {} is outside 1.5 kHz .. 12 MHz".format(self.bit_rate))
        if not 0 <= self.mode <= 3:
            raise ProtocolError("SPI mode {} is invalid".format(self.mode))
        if not 0 <= self.xfer_size <= 0xFFFF:
            raise ProtocolError("SPI transaction size is invalid")

    def describe(self):
        return ("{} Hz, mode {}, idle_cs=0x{:03X}, active_cs=0x{:03X}, "
                "cs2data={}x100us, data2cs={}x100us, interbyte={}x100us, xfer={}".format(
                    self.bit_rate, self.mode, self.idle_cs, self.active_cs,
                    self.cs_to_data, self.data_to_cs, self.interbyte, self.xfer_size))


class GpioSettings:
    """The 14-byte RAM GPIO chip settings structure (DS22288A 3.2.3/3.2.4)."""

    __slots__ = ("designations", "output", "direction", "other")

    def __init__(self, designations=None, output=0x01FF, direction=0x0000, other=0x00):
        self.designations = list(designations if designations is not None else [0] * GPIO_COUNT)
        if len(self.designations) != GPIO_COUNT:
            raise ProtocolError("GPIO designation list must have 9 entries")
        self.output = int(output) & 0xFFFF
        self.direction = int(direction) & 0xFFFF
        self.other = int(other) & 0xFF

    @classmethod
    def unpack(cls, data):
        if len(data) != 14:
            raise ProtocolError("GPIO settings structure is {} bytes, expected 14".format(len(data)))
        return cls(
            designations=list(data[0:9]),
            output=struct.unpack_from("<H", data, 9)[0],
            direction=struct.unpack_from("<H", data, 11)[0],
            other=data[13],
        )

    def pack(self):
        return bytes(self.designations) + struct.pack("<HHB", self.output, self.direction, self.other)

    def describe(self):
        pins = []
        for i, d in enumerate(self.designations):
            pins.append("GP{}={}".format(i, GPIO_DESIGNATION_NAMES.get(d, "0x{:02X}".format(d))))
        return ("{}  out=0x{:03X} dir=0x{:03X} other=0x{:02X} "
                "(bus_release={})".format(
                    " ".join(pins), self.output, self.direction, self.other,
                    "hold" if (self.other & 0x01) else "release"))


def read_board_number(log, override=None):
    """Return (AMDA number, source text).  200 = AMDA0200 = XGS 87/107."""
    if override is not None:
        return int(override), "override"
    text = ""
    for path in ("/sys/class/dmi/id/board_serial",
                 "/sys/devices/virtual/dmi/id/board_serial"):
        try:
            text = read_file(path).decode("utf-8", "replace").strip()
        except OSError:
            text = ""
        if text:
            break
    if not text:
        try:
            text = subprocess.run(
                ["dmidecode", "-s", "baseboard-serial"],
                capture_output=True, text=True, errors="replace", timeout=5).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            text = ""
    match = re.search(r"AMDA0*(\d+)", text)
    if match:
        return int(match.group(1)), text
    return None, text


def npu_gpio_write(mcp, value, mask, log=None):
    """Sophos's gpio_write(): make every masked pin a GPIO output and drive value.

    This is the exact sequence from xgs-usb-spi-flash: modify the chip settings
    (designation 0, direction output, output bit) then write the live values.
    0x21 is what makes the direction take effect; 0x32 is not involved.
    """
    gpio, access = mcp.get_gpio()
    for pin in range(GPIO_COUNT):
        if mask & (1 << pin):
            gpio.designations[pin] = GPIO_DESIGNATION_GPIO
            gpio.direction &= ~(1 << pin)
            gpio.output = (gpio.output & ~(1 << pin)) | (value & (1 << pin))
    mcp.set_gpio(gpio)
    mcp.set_gpio_value(value & 0xFFFF)
    if log:
        log.debug("NPU GPIO write: value 0x{:04X} mask 0x{:04X}".format(value, mask))


def npu_live_state(mcp):
    gpio, access = mcp.get_gpio()
    return {
        "designations": list(gpio.designations),
        "chip_value": gpio.output,
        "chip_dir": gpio.direction,
        "other": gpio.other,
        "access": access,
        "live_value": mcp.get_gpio_value(),
        "live_dir": mcp.get_gpio_dir(),
    }


def resolve_npu(args, log, need_spi):
    """Decide whether this run must hold the NPU in reset to own the SPI bus."""
    mode = getattr(args, "npu", "auto")
    if not need_spi or mode == "none":
        return {"mode": "none"}
    board, source = read_board_number(log, getattr(args, "board", None))
    if board is None:
        raise SafetyError(
            "cannot determine the board assembly number (read {!r}); "
            "pass --board 200 for an XGS 87/107, or --npu none if the NPU "
            "is powered off and the bus is already isolated".format(source))
    if board not in NPU_VALUES:
        raise SafetyError(
            "no NPU hold/release values for AMDA{:04d}; this tool knows {}; "
            "pass --npu none if the bus is already isolated".format(
                board, ", ".join("AMDA{:04d}".format(b) for b in sorted(NPU_VALUES))))
    values = NPU_VALUES[board]
    log.info("board AMDA{:04d}: NPU hold=0x{:04X} release=0x{:04X} mask=0x{:04X}".format(
        board, values["hold"], values["release"], NPU_MASK))
    return {"mode": "hold", "board": board, "mask": NPU_MASK,
            "hold": values["hold"], "release": values["release"]}


class Mcp2210:
    """Minimal MCP2210 HID command engine."""

    def __init__(self, transport, log):
        self.transport = transport
        self.log = log
        self.report_prefix = b""
        self._probe_report_mode()

    def _read_report(self, timeout):
        data = self.transport.read(timeout)
        if not data:
            return b""
        if len(data) == 65 and data[0] == 0x00:
            data = data[1:]
        return data

    def _drain(self):
        dropped = 0
        while dropped < 64:
            try:
                data = self.transport.read(0.0)
            except (OSError, ToolError):
                return
            if not data:
                return
            dropped += 1
            self.log.debug("drained stale report: " + hexs(data))
        self.log.warn("drained 64 stale MCP2210 reports; the HID queue was flooded")

    def _probe_report_mode(self):
        request = bytes([CMD_GET_STATUS]).ljust(64, b"\x00")
        for label, prefix in (("plain 64-byte report", b""),
                              ("report-id-0 + 64 bytes", b"\x00")):
            try:
                self.transport.write(prefix + request)
            except (OSError, ToolError) as exc:
                self.log.debug("{} write failed: {}".format(label, exc))
                continue
            response = self._read_report(0.5)
            if response:
                if len(response) == 64 and response[0] == CMD_GET_STATUS:
                    self.report_prefix = prefix
                    self.log.debug("MCP2210 HID transport: " + label)
                    return
                self.log.debug("unexpected probe response ({}): {}".format(label, hexs(response)))
            self._drain()
        raise ProtocolError(
            "MCP2210 at {} did not answer GET_STATUS; check the hidraw device, "
            "permissions (root) and that no other process is reading it".format(
                getattr(self.transport, "path", "?")))

    def cmd(self, payload, timeout=1.0, retries=3, check=True):
        if not payload:
            raise ValueError("empty MCP2210 command")
        command = payload[0]
        request = bytes(payload).ljust(64, b"\x00")
        last_error = "no response"
        for attempt in range(retries):
            # A stale 0x42 reply is indistinguishable from the one we are about to
            # ask for (same command byte), so drain before every command.  This is
            # what xgs-usb-spi-flash and the os-xgs-npu implementation do.
            self._drain()
            self.transport.write(self.report_prefix + request)
            self.log.trace("->", request)
            deadline = time.monotonic() + max(0.05, timeout)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    last_error = "timeout"
                    break
                response = self._read_report(remaining)
                if not response:
                    last_error = "timeout"
                    break
                self.log.trace("<-", response)
                if len(response) != 64:
                    last_error = "short report ({} bytes)".format(len(response))
                    continue
                if response[0] != command:
                    last_error = "response for command 0x{:02X}, wanted 0x{:02X}".format(
                        response[0], command)
                    self.log.debug("stale MCP2210 response: " + last_error)
                    continue
                if not check:
                    return response
                code = response[1]
                if code == MCP_OK:
                    return response
                if code == MCP_BUSY:
                    last_error = "device busy (0xF8)"
                    break
                if code == MCP_UNKNOWN_COMMAND:
                    raise ProtocolError("MCP2210 does not support command 0x{:02X}".format(command))
                raise ProtocolError("MCP2210 command 0x{:02X} failed: status 0x{:02X}".format(
                    command, code))
            if attempt + 1 < retries:
                time.sleep(0.01)
        raise ProtocolError("MCP2210 command 0x{:02X} failed: {}".format(command, last_error))

    def get_status(self):
        r = self.cmd([CMD_GET_STATUS])
        return {
            "bus_release_external_request": r[2],
            "bus_owner": r[3],
            "password_attempts": r[4],
            "password_guessed": r[5],
        }

    def get_gpio(self):
        r = self.cmd([CMD_GET_GPIO])
        return GpioSettings.unpack(r[4:18]), r[18]

    def set_gpio(self, settings):
        payload = bytes([CMD_SET_GPIO, 0, 0, 0]) + settings.pack()
        self.cmd(payload)

    def get_gpio_dir(self):
        r = self.cmd([CMD_GET_GPIO_DIR])
        return struct.unpack_from("<H", r, 4)[0] & GPIO_MASK

    def set_gpio_dir(self, value):
        self.cmd(bytes([CMD_SET_GPIO_DIR, 0, 0, 0]) + struct.pack("<H", value & GPIO_MASK))

    def get_gpio_value(self):
        r = self.cmd([CMD_GET_GPIO_VALUE])
        return struct.unpack_from("<H", r, 4)[0] & GPIO_MASK

    def set_gpio_value(self, value):
        self.cmd(bytes([CMD_SET_GPIO_VALUE, 0, 0, 0]) + struct.pack("<H", value & GPIO_MASK))

    def get_spi(self):
        r = self.cmd([CMD_GET_SPI])
        size = r[2]
        if size != 17:
            raise ProtocolError("MCP2210 returned SPI settings size {}, expected 17".format(size))
        return SpiSettings.unpack(r[4:21])

    def set_spi(self, settings):
        settings.validate()
        packed = settings.pack()
        r = self.cmd(bytes([CMD_SET_SPI, 0, 0, 0]) + packed)
        if bytes(r[4:21]) != packed:
            raise ProtocolError("MCP2210 SPI settings echo mismatch")
        return settings

    def spi_xfer(self, data):
        if len(data) > MCP_MAX_XFER_CHUNK:
            raise ValueError("0x42 payload is limited to 60 bytes")
        payload = bytes([CMD_SPI_XFER, len(data), 0, 0]) + bytes(data)
        # Do not retry 0x42: if the device accepted the chunk but the response was
        # lost, resending it would duplicate bytes inside the same SPI transaction.
        return self.cmd(payload, check=False, timeout=2.0, retries=1)

    def cancel(self):
        try:
            self.cmd([CMD_CANCEL], check=False, timeout=0.5, retries=1)
        except ToolError:
            pass

    def release(self):
        try:
            self.cmd([CMD_RELEASE], check=False, timeout=0.5, retries=1)
        except ToolError:
            pass

    def close(self):
        self.transport.close()


class HidRawTransport:
    """Linux hidraw transport; 64-byte reports, no external dependencies."""

    def __init__(self, path, log):
        self.path = path
        self.log = log
        flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0)
        try:
            self.fd = os.open(path, flags)
        except OSError as exc:
            if exc.errno in (errno.EACCES, errno.EPERM):
                raise ToolError(
                    "cannot open {}: permission denied; run as root "
                    "(sudo) or install a udev rule for {}").format(path, VID_PID_TEXT)
            raise ToolError("cannot open {}: {}".format(path, exc))

    def write(self, data):
        view = memoryview(data)
        while view:
            try:
                written = os.write(self.fd, view)
            except InterruptedError:
                continue
            except OSError as exc:
                raise ProtocolError("hidraw write to {} failed: {}".format(self.path, exc))
            if written <= 0:
                raise ProtocolError("hidraw write to {} returned {}".format(self.path, written))
            view = view[written:]

    def read(self, timeout):
        if timeout is None:
            timeout = 1.0
        try:
            ready, _, _ = select.select([self.fd], [], [], max(0.0, timeout))
        except InterruptedError:
            return b""
        if not ready:
            return b""
        try:
            return os.read(self.fd, 65)
        except InterruptedError:
            return b""
        except OSError as exc:
            raise ProtocolError("hidraw read from {} failed: {}".format(self.path, exc))

    def close(self):
        if getattr(self, "fd", None) is not None:
            try:
                os.close(self.fd)
            finally:
                self.fd = None


def discover_hidraw(log, override=None):
    if override:
        return {"path": override, "name": "override", "serial": ""}
    if not sys.platform.startswith("linux"):
        raise ToolError("hidraw discovery only works on Linux; pass --device")
    wanted = "HID_ID=0003:{:08X}:{:08X}".format(VID, PID)
    found = []
    for sysdir in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        uevent = os.path.join(sysdir, "device", "uevent")
        try:
            text = read_file(uevent).decode("utf-8", "replace")
        except OSError:
            continue
        if wanted not in text:
            continue
        name = ""
        serial = ""
        for line in text.splitlines():
            if line.startswith("HID_NAME="):
                name = line.split("=", 1)[1]
            elif line.startswith("HID_UNIQ="):
                serial = line.split("=", 1)[1]
        found.append({"path": "/dev/" + os.path.basename(sysdir),
                      "name": name, "serial": serial, "uevent": text})
    if not found:
        raise ToolError(
            "no hidraw node for {} found in /sys/class/hidraw; "
            "check lsusb and that usbhid created /dev/hidraw*".format(VID_PID_TEXT))
    if len(found) > 1:
        for item in found:
            log.warn("found {} ({})".format(item["path"], item["name"]))
        raise ToolError("more than one {} device; select one with --device".format(VID_PID_TEXT))
    item = found[0]
    log.info("MCP2210: {}  serial={}  ({})".format(item["path"], item["serial"] or "?", item["name"]))
    return item


# --------------------------------------------------------------------------
# SPI NOR
# --------------------------------------------------------------------------

class SpiNor:
    """MX25L3205D on the MCP2210, with CS handling and settings restore."""

    def __init__(self, mcp, log, cs_pin=None, cs_mode="auto", speed=1_000_000,
                 mode=0, active_high=False, gpio_overrides=None, force_chip=False,
                 read_chunk=DEFAULT_READ_CHUNK, npu=None):
        self.mcp = mcp
        self.log = log
        self.requested_speed = speed
        self.speed = speed or DEFAULT_SPEEDS[0]
        self.mode = mode
        self.active_high = active_high
        self.gpio_overrides = list(gpio_overrides or [])
        self.force_chip = force_chip
        self.read_chunk = max(1, min(int(read_chunk), 0xFFFF - 4))
        self.npu = dict(npu or {"mode": "none"})
        self.npu_hold_applied = False

        self.cs_pin = cs_pin
        self.cs_mode = cs_mode
        self.jedec = b""
        self.orig_gpio = None
        self.orig_dir = None
        self.orig_val = None
        self.orig_spi = None
        self.cur_gpio = None
        self.cur_dir = 0
        self.cur_val = 0
        self._transaction_active = False

    # -- setup / restore ---------------------------------------------------

    def open(self, require_chip=True):
        self.orig_gpio, self.orig_access = self.mcp.get_gpio()
        self.orig_dir = self.mcp.get_gpio_dir()
        self.orig_val = self.mcp.get_gpio_value()
        self.orig_spi = self.mcp.get_spi()

        if self.npu.get("mode") == "hold":
            self.log.info(
                "holding the NPU in reset and taking the SPI bus "
                "(write 0x{:04X} mask 0x{:04X})".format(self.npu["hold"], self.npu["mask"]))
            npu_gpio_write(self.mcp, self.npu["hold"], self.npu["mask"], self.log)
            self.npu_hold_applied = True

        # Read the working state *after* the hold: the CS/GPIO code must not
        # write back the pre-hold settings and accidentally release the bus.
        self.cur_gpio, _ = self.mcp.get_gpio()
        self.cur_dir = self.mcp.get_gpio_dir()
        self.cur_val = self.mcp.get_gpio_value()

        self._resolve_cs()
        self._apply_gpio_overrides()
        self._configure_spi(4)

        speeds = [self.speed]
        if self.requested_speed is None:
            speeds = list(DEFAULT_SPEEDS)
        elif self.requested_speed > DEFAULT_SPEEDS[-1]:
            speeds += [s for s in DEFAULT_SPEEDS if s < self.requested_speed]

        seen = set()
        last_jedec = b""
        for speed in speeds:
            if speed in seen:
                continue
            seen.add(speed)
            self.speed = speed
            self._configure_spi(4)
            last_jedec = self.read_id()
            if last_jedec[:3] == JEDEC_ID[:3]:
                break
            self.log.debug("JEDEC {:s} at {} Hz".format(hexs(last_jedec), speed))
        self.jedec = last_jedec

        if require_chip:
            if self.jedec[:3] != JEDEC_ID[:3] and not self.force_chip:
                raise ToolError(
                    "unexpected JEDEC ID {} (wanted {} for {}); check CS pin/wiring, "
                    "or use --force-chip".format(hexs(self.jedec), hexs(JEDEC_ID), CHIP_NAME))
            if self.jedec[2] != JEDEC_ID[2] and not self.force_chip:
                raise ToolError(
                    "flash capacity byte 0x{:02X} is not 0x{:02X} (4 MiB); "
                    "this tool's layout only supports {}".format(
                        self.jedec[2], JEDEC_ID[2], CHIP_NAME))
        self.log.info("SPI NOR: {}  JEDEC {}  at {} Hz, CS {} ({})".format(
            CHIP_NAME, hexs(self.jedec), self.speed, self.cs_pin, self.cs_mode))
        return self

    def _apply_gpio_overrides(self):
        for pin, level in self.gpio_overrides:
            if pin == self.cs_pin:
                raise SafetyError("--gpio GP{} conflicts with the selected CS pin".format(pin))
            self.cur_dir &= ~(1 << pin)
            if level:
                self.cur_val |= (1 << pin)
            else:
                self.cur_val &= ~(1 << pin)
            self.mcp.set_gpio_dir(self.cur_dir)
            self.mcp.set_gpio_value(self.cur_val)
            self.log.info("GPIO override: GP{} = {} (output)".format(pin, level))

    def _resolve_cs(self):
        cs_pins = [i for i, d in enumerate(self.cur_gpio.designations)
                   if d == GPIO_DESIGNATION_CS]
        if self.cs_mode == "auto":
            if self.cs_pin is not None:
                self.cs_mode = "internal"
            elif len(cs_pins) == 1:
                self.cs_pin = cs_pins[0]
                self.cs_mode = "internal"
            else:
                raise ToolError(
                    "cannot auto-select the flash chip-select: designations are [{}]; "
                    "pass --cs-pin N (or --cs-mode gpio --cs-pin N)".format(
                        " ".join("GP{}=0x{:02X}".format(i, d)
                                 for i, d in enumerate(self.cur_gpio.designations))))
        if self.cs_pin is None:
            raise ToolError("--cs-pin is required with --cs-mode {}".format(self.cs_mode))
        if not 0 <= self.cs_pin <= 8:
            raise ToolError("CS pin must be 0..8")

        current = self.cur_gpio.designations[self.cs_pin]
        if self.cs_mode == "internal":
            if current != GPIO_DESIGNATION_CS:
                self.cur_gpio.designations[self.cs_pin] = GPIO_DESIGNATION_CS
                self.mcp.set_gpio(self.cur_gpio)
                self.log.info("GP{} temporarily designated as chip-select".format(self.cs_pin))
        elif self.cs_mode == "gpio":
            if current != GPIO_DESIGNATION_GPIO:
                self.cur_gpio.designations[self.cs_pin] = GPIO_DESIGNATION_GPIO
                self.mcp.set_gpio(self.cur_gpio)
                self.log.info("GP{} temporarily changed from CS to GPIO".format(self.cs_pin))
            self.cur_dir &= ~(1 << self.cs_pin)
            self.cur_val = self._set_bit(self.cur_val, self.cs_pin, self._idle_level())
            self.mcp.set_gpio_dir(self.cur_dir)
            self.mcp.set_gpio_value(self.cur_val)
        else:
            raise ToolError("unknown CS mode {!r}".format(self.cs_mode))

    def _idle_level(self):
        return 0 if self.active_high else 1

    def _active_level(self):
        return 1 if self.active_high else 0

    @staticmethod
    def _set_bit(value, pin, level):
        if level:
            return value | (1 << pin)
        return value & ~(1 << pin)

    def _configure_spi(self, xfer_size):
        idle = 0x01FF
        if self.cs_mode == "internal":
            active = idle & ~(1 << self.cs_pin)
        else:
            active = idle
        settings = SpiSettings(self.speed, idle, active, 0, 0, 0, xfer_size, self.mode)
        self.mcp.set_spi(settings)
        self.cur_spi = settings

    def close(self):
        if self.mcp is None:
            return
        try:
            if self._transaction_active:
                self.mcp.cancel()
        except ToolError:
            pass
        try:
            if self.orig_spi is not None:
                self.mcp.set_spi(self.orig_spi)
        except ToolError as exc:
            self.log.warn("could not restore MCP2210 SPI settings: {}".format(exc))
        try:
            try:
                if self.orig_gpio is not None:
                    self.mcp.set_gpio(self.orig_gpio)
                if self.orig_dir is not None:
                    self.mcp.set_gpio_dir(self.orig_dir)
                if self.orig_val is not None:
                    self.mcp.set_gpio_value(self.orig_val)
            except ToolError as exc:
                self.log.warn("could not restore MCP2210 GPIO settings: {}".format(exc))
            if self.npu_hold_applied:
                # Always give the bus back, even if the restore above failed:
                # leaving the NPU held is worse than a wrong GPIO setting.
                try:
                    self.log.info("releasing the NPU (write 0x{:04X} mask 0x{:04X})".format(
                        self.npu["release"], self.npu["mask"]))
                    npu_gpio_write(self.mcp, self.npu["release"], self.npu["mask"], self.log)
                except ToolError as exc:
                    self.log.error(
                        "could not release the NPU control lines: {}; run "
                        "`mcp2210-nor.py npu release` (or power-cycle) to let the NPU boot".format(
                            exc))
                finally:
                    self.npu_hold_applied = False
        finally:
            try:
                self.mcp.close()
            except Exception:
                pass

    # -- low-level SPI -----------------------------------------------------

    def _gpio_cs(self, asserted):
        level = self._active_level() if asserted else self._idle_level()
        self.cur_val = self._set_bit(self.cur_val, self.cs_pin, level)
        self.mcp.set_gpio_value(self.cur_val)

    def transaction(self, tx):
        tx = bytes(tx)
        if not 1 <= len(tx) <= 0xFFFF:
            raise ValueError("SPI transaction must be 1..65535 bytes")
        if self.cs_mode == "gpio":
            self._gpio_cs(True)
            try:
                return self._engine_transfer(tx)
            finally:
                self._gpio_cs(False)
        return self._engine_transfer(tx)

    def _xfer_timeout(self, chunk_bytes):
        # The 0x42 response acknowledges a chunk; at the slowest rate one chunk
        # takes ~320 ms on the wire, so do not be too aggressive.
        return max(1.0, 0.5 + chunk_bytes * 8.0 / max(1_500, self.speed))

    def _engine_transfer(self, tx):
        self._configure_spi(len(tx))
        chunks = [tx[i:i + MCP_MAX_XFER_CHUNK]
                  for i in range(0, len(tx), MCP_MAX_XFER_CHUNK)]
        index = 0
        rx = bytearray()
        polls = 0
        max_polls = 100 + len(chunks) * 10
        self._transaction_active = True
        try:
            while True:
                chunk = chunks[index] if index < len(chunks) else b""
                response = self.mcp.spi_xfer(chunk)
                code = response[1]
                if code == MCP_SPI_BUS_LOCKED:
                    raise ProtocolError(
                        "SPI bus is owned by an external master (0xF7); "
                        "check the NPU/SoC is not driving the flash bus")
                if code == MCP_BUSY:
                    time.sleep(0.002)
                    polls += 1
                    continue
                if code != MCP_OK:
                    raise ProtocolError("SPI transfer failed: status 0x{:02X}".format(code))
                if index < len(chunks):
                    index += 1
                count = response[2]
                engine = response[3]
                if count:
                    if len(rx) + count > len(tx):
                        raise ProtocolError("SPI engine returned too many bytes")
                    rx += response[4:4 + count]
                if engine == SPI_ENGINE_FINISHED:
                    break
                if engine not in (SPI_ENGINE_STARTED, SPI_ENGINE_DATA_AVAILABLE):
                    raise ProtocolError("unknown SPI engine status 0x{:02X}".format(engine))
                polls += 1
                if polls > max_polls:
                    self.mcp.cancel()
                    raise TransferTimeout("SPI transfer did not finish in time")
            if len(rx) != len(tx):
                raise ProtocolError(
                    "SPI received {} bytes, transmitted {}".format(len(rx), len(tx)))
            return bytes(rx)
        finally:
            self._transaction_active = False

    # -- NOR commands ------------------------------------------------------

    def read_id(self):
        rx = self.transaction(bytes([NOR_RDID, 0, 0, 0]))
        return rx[1:4]

    def read_status(self):
        rx = self.transaction(bytes([NOR_RDSR, 0]))
        return rx[1]

    def write_enable(self):
        self.transaction(bytes([NOR_WREN]))
        status = self.read_status()
        if not status & SR_WEL:
            raise ProtocolError("flash did not set WEL (status 0x{:02X})".format(status))

    def wait_ready(self, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            status = self.read_status()
            if not status & SR_WIP:
                return status
            time.sleep(0.002)
        raise TransferTimeout("flash stayed busy (WIP=1) for {:.1f}s".format(timeout))

    def read(self, addr, length):
        addr = int(addr)
        length = int(length)
        if addr < 0 or length < 0 or addr + length > FLASH_SIZE:
            raise ValueError("read 0x{:X}+0x{:X} is outside the 4 MiB flash".format(addr, length))
        out = bytearray()
        pos = 0
        while pos < length:
            n = min(self.read_chunk, length - pos)
            a = addr + pos
            tx = bytes([NOR_READ, (a >> 16) & 0xFF, (a >> 8) & 0xFF, a & 0xFF]) + b"\xFF" * n
            rx = self.transaction(tx)
            out += rx[4:4 + n]
            pos += n
        self.log.debug("read 0x{:06X}+0x{:X}".format(addr, length))
        return bytes(out)

    def read_range_progress(self, addr, length, progress=None):
        addr = int(addr)
        length = int(length)
        if addr < 0 or length < 0 or addr + length > FLASH_SIZE:
            raise ValueError("read 0x{:X}+0x{:X} is outside the 4 MiB flash".format(addr, length))
        out = bytearray()
        pos = 0
        while pos < length:
            n = min(self.read_chunk, length - pos)
            out += self.read(addr + pos, n)
            pos += n
            if progress is not None:
                progress(pos, length)
        return bytes(out)

    def program(self, addr, data):
        addr = int(addr)
        data = bytes(data)
        if addr < 0 or addr + len(data) > FLASH_SIZE:
            raise ValueError("program 0x{:X}+0x{:X} is outside the flash".format(addr, len(data)))
        pos = 0
        while pos < len(data):
            a = addr + pos
            page_left = 256 - (a & 0xFF)
            n = min(NOR_MAX_PP_DATA, page_left, len(data) - pos)
            chunk = data[pos:pos + n]
            if any(b != 0xFF for b in chunk):
                self.write_enable()
                self.transaction(bytes([NOR_PP, (a >> 16) & 0xFF, (a >> 8) & 0xFF, a & 0xFF]) + chunk)
                self.wait_ready(5.0)
            pos += n

    def erase_block(self, addr):
        addr = int(addr)
        if addr & 0xFFFF:
            raise ValueError("64 KiB block erase requires a 64 KiB-aligned address")
        if addr < 0 or addr + 0x10000 > FLASH_SIZE:
            raise ValueError("block erase outside the flash")
        self.write_enable()
        self.transaction(bytes([NOR_BE, (addr >> 16) & 0xFF, (addr >> 8) & 0xFF, addr & 0xFF]))
        self.wait_ready(15.0)

    def erase_sector(self, addr):
        addr = int(addr)
        if addr & 0xFFF:
            raise ValueError("4 KiB sector erase requires a 4 KiB-aligned address")
        self.write_enable()
        self.transaction(bytes([NOR_SE, (addr >> 16) & 0xFF, (addr >> 8) & 0xFF, addr & 0xFF]))
        self.wait_ready(5.0)

    def clear_block_protect(self):
        self.write_enable()
        self.transaction(bytes([NOR_WRSR, 0x00]))
        self.wait_ready(2.0)
        status = self.read_status()
        if status & SR_BP_MASK:
            raise ProtocolError(
                "block-protect bits are still set after WRSR (status 0x{:02X}); "
                "WP#/SRWD may be preventing the write".format(status))


# --------------------------------------------------------------------------
# backups / policy
# --------------------------------------------------------------------------

class Backup:
    def __init__(self, path, data, manifest, sha):
        self.path = path
        self.data = data
        self.manifest = manifest
        self.sha = sha

    @classmethod
    def load(cls, path, require_manifest=False):
        data = read_file(path)
        if len(data) != FLASH_SIZE:
            raise SafetyError(
                "backup {} is {} bytes, expected {} (4 MiB); "
                "use a full-chip dump from this tool".format(path, len(data), FLASH_SIZE))
        sha = sha256_hex(data)
        manifest = None
        manifest_path = path + ".json"
        raw_manifest = read_optional(manifest_path)
        if raw_manifest is not None:
            try:
                manifest = json.loads(raw_manifest.decode("utf-8"))
            except ValueError as exc:
                raise SafetyError("backup manifest {} is not valid JSON: {}".format(
                    manifest_path, exc))
        checksum_path = path + ".sha256"
        raw_checksum = read_optional(checksum_path)
        if raw_checksum is not None:
            first = raw_checksum.decode("ascii", "replace").split()[0] if raw_checksum.strip() else ""
            if first and first.lower() != sha:
                raise SafetyError(
                    "backup {} hash {} does not match {} ({})".format(
                        path, sha, checksum_path, first))
        if manifest is not None:
            if manifest.get("sha256") and manifest["sha256"].lower() != sha:
                raise SafetyError("backup manifest sha256 does not match the file")
            if manifest.get("size") and int(manifest["size"]) != len(data):
                raise SafetyError("backup manifest size does not match the file")
            if manifest.get("chip", {}).get("jedec"):
                if manifest["chip"]["jedec"].lower() != hexs(JEDEC_ID):
                    raise SafetyError(
                        "backup was made from a different chip ({}), this tool expects {}".format(
                            manifest["chip"]["jedec"], hexs(JEDEC_ID)))
        if require_manifest and manifest is None:
            raise SafetyError(
                "{} has no .json manifest; run `dump` with this tool so the backup "
                "is bound to a chip and a verification pass".format(path))
        return cls(path, data, manifest, sha)

    def env_image(self):
        return self.data[ENV_OFFSET:ENV_OFFSET + ENV_SIZE]

    def require_verified(self, allow_unverified=False):
        if allow_unverified:
            return
        if self.manifest is None:
            raise SafetyError("backup has no manifest; refusing to write")
        if not self.manifest.get("verified"):
            raise SafetyError("backup manifest says it is not verified (passes < 2)")
        if int(self.manifest.get("passes", 1)) < 2:
            raise SafetyError("backup was made with only {} pass(es); need 2".format(
                self.manifest.get("passes", 1)))

    def validate_against_reference(self, reference, allow_mismatch=False, allow_missing=False,
                                   expected_sha256=None):
        uboot = self.data[:UBOOT_SIZE]
        if expected_sha256:
            actual = sha256_hex(uboot)
            if actual.lower() != expected_sha256.lower():
                raise SafetyError(
                    "the backup's U-Boot partition SHA-256 is {}, expected {}; "
                    "refusing an env-only write".format(actual, expected_sha256))
        if reference is None:
            if allow_missing or expected_sha256:
                return
            raise SafetyError(
                "no known-good U-Boot reference available; pass --reference PATH "
                "or --reference-uboot-sha256 HEX (or --allow-missing-reference, "
                "not recommended)")
        if len(reference) != UBOOT_SIZE:
            raise SafetyError(
                "reference U-Boot is {} bytes, expected {}".format(len(reference), UBOOT_SIZE))
        if uboot != reference:
            ranges = diff_ranges(self.data[:UBOOT_SIZE], reference)
            if allow_mismatch:
                return
            raise SafetyError(
                "the backup's U-Boot partition (mtd0) differs from the known-good "
                "reference at {}; an env-only write cannot fix that. Refusing. "
                "Pass --allow-uboot-mismatch only if you are certain.".format(
                    format_ranges(ranges)))


class NorSession:
    def __init__(self, nor, log, reference_uboot=None, reference_env=None):
        self.nor = nor
        self.log = log
        self.reference_uboot = reference_uboot
        self.reference_env = reference_env

    def read_env(self):
        image = self.nor.read(ENV_OFFSET, ENV_SIZE)
        return image

    def dump(self, out_path, passes=2, force=False, progress=True):
        if os.path.exists(out_path) and not force:
            raise ToolError("{} already exists; use --force to overwrite".format(out_path))
        label = "read pass 1/{}".format(passes)
        p = Progress(self.log, label, FLASH_SIZE) if progress else None
        first = self.nor.read_range_progress(0, FLASH_SIZE, p)
        if p:
            p.finish()
        first_sha = sha256_hex(first)
        verified = False
        if passes >= 2:
            label = "verify pass 2/{}".format(passes)
            p = Progress(self.log, label, FLASH_SIZE) if progress else None
            second = self.nor.read_range_progress(0, FLASH_SIZE, p)
            if p:
                p.finish()
            second_sha = sha256_hex(second)
            if first != second:
                # Keep both passes: without them the mismatch is unactionable.
                write_atomic(out_path + ".pass1", first)
                write_atomic(out_path + ".pass2", second)
                ranges = diff_ranges(first, second)
                raise SafetyError(
                    "the two full-chip reads differ at {}; the SPI bus is unstable, "
                    "do NOT use this as a backup (passes saved as {}.pass1/.pass2)".format(
                        format_ranges(ranges), out_path))
            verified = first_sha == second_sha

        write_atomic(out_path, first)
        manifest = {
            "format": "mcp2210-nor-backup",
            "version": 1,
            "tool": "mcp2210-nor.py",
            "tool_version": TOOL_VERSION,
            "created_utc": utc_now(),
            "device": self._device_info(),
            "chip": {"jedec": hexs(self.nor.jedec), "name": CHIP_NAME, "size": FLASH_SIZE},
            "spi": {"speed_hz": self.nor.speed, "mode": self.nor.mode,
                    "cs_pin": self.nor.cs_pin, "cs_mode": self.nor.cs_mode},
            "passes": passes,
            "verified": verified,
            "size": len(first),
            "sha256": first_sha,
            "chunk_size": 0x10000,
            "chunk_sha256": [sha256_hex(first[i:i + 0x10000])
                             for i in range(0, len(first), 0x10000)],
        }
        write_atomic(out_path + ".json", json.dumps(manifest, indent=2, sort_keys=True).encode("utf-8") + b"\n")
        write_atomic(out_path + ".sha256",
                     "{}  {}\n".format(first_sha, os.path.basename(out_path)).encode("ascii"))
        self.log.info("backup written: {} ({} bytes, sha256 {})".format(out_path, len(first), first_sha))
        if not verified:
            self.log.warn("backup is NOT verified (passes={})".format(passes))
        return Backup(out_path, first, manifest, first_sha)

    def _device_info(self):
        transport = getattr(self.nor.mcp, "transport", None)
        return {"path": getattr(transport, "path", ""), "vid": VID_PID_TEXT,
                "serial": getattr(transport, "serial", "")}

    def verify_backup(self, backup, full=True, progress=True):
        self.log.info("re-reading {} to verify {}".format(
            "the whole 4 MiB chip" if full else "the 64 KiB env region", backup.path))
        if full:
            p = Progress(self.log, "verify", FLASH_SIZE) if progress else None
            current = self.nor.read_range_progress(0, FLASH_SIZE, p)
            if p:
                p.finish()
            if current != backup.data:
                ranges = diff_ranges(current, backup.data)
                raise SafetyError(
                    "chip no longer matches the backup at {}; refusing to continue".format(
                        format_ranges(ranges)))
        else:
            current = self.nor.read(ENV_OFFSET, ENV_SIZE)
            if current != backup.env_image():
                ranges = diff_ranges(current, backup.env_image())
                raise SafetyError(
                    "current env region differs from the backup at {}; refusing to continue".format(
                        format_ranges(ranges)))
        self.log.info("backup matches the chip")

    def write_env(self, backup, image, commit=False, yes=False, quick=False,
                  allow_uboot_mismatch=False, allow_missing_reference=False,
                  allow_unverified=False, clear_bp=False, confirm=None,
                  progress=True, expected_uboot_sha256=None):
        backup.require_verified(allow_unverified)
        if backup.manifest:
            expected_serial = backup.manifest.get("device", {}).get("serial")
            actual_serial = getattr(self.nor.mcp.transport, "serial", "")
            if expected_serial and actual_serial and expected_serial != actual_serial:
                raise SafetyError(
                    "backup was made with MCP2210 serial {} but this device is {}; "
                    "refusing to write".format(expected_serial, actual_serial))
        new_items, new_crc, new_calc, new_fill = load_env_image(image, where="new env image")
        old_items, old_stored, old_crc, old_fill = load_env_image(
            backup.env_image(), strict_crc=False, where="backup env")
        if old_stored != old_crc:
            self.log.warn(
                "backup env CRC is bad (stored 0x{:08X}, calculated 0x{:08X}); "
                "that is the image we are replacing".format(old_stored, old_crc))
        if backup.manifest and backup.manifest.get("sha256") != backup.sha:
            raise SafetyError("backup manifest hash mismatch")

        if mac_is_placeholder(new_items) and not mac_is_placeholder(old_items):
            raise SafetyError(
                "new env contains a redacted ethaddr (xx:xx), but the backup has a real "
                "one; refusing to overwrite the MAC. Build from the backup, not from "
                "reference/uboot-env.txt.")
        if new_items.get(b"ethaddr") is None and old_items.get(b"ethaddr") is not None:
            self.log.warn("new env drops ethaddr; the board will fall back to the "
                          "U-Boot default MAC")

        backup.validate_against_reference(self.reference_uboot,
                                          allow_mismatch=allow_uboot_mismatch,
                                          allow_missing=allow_missing_reference,
                                          expected_sha256=expected_uboot_sha256)

        old_image = backup.env_image()
        if image == old_image:
            self.log.info("new env image is identical to the backup; nothing to do")
            return False

        added, removed, changed = env_diff(old_items, new_items)
        self.log.info("env changes: {} added, {} removed, {} changed".format(
            len(added), len(removed), len(changed)))
        for key in added:
            self.log.info("  + {}={}".format(_printable(key), _printable(new_items[key])))
        for key in removed:
            self.log.info("  - {}={}".format(_printable(key), _printable(old_items[key])))
        for key in changed:
            self.log.info("  ~ {}: {!r} -> {!r}".format(
                _printable(key), _printable(old_items[key]), _printable(new_items[key])))
        if new_fill != 0xFF:
            self.log.warn("new env image fills the unused area with 0x{:02X}".format(new_fill))

        self.log.info("plan:")
        self.log.info("  erase  0x{:06X}..0x{:06X} (64 KiB env block only)".format(
            ENV_OFFSET, ENV_OFFSET + ENV_SIZE))
        self.log.info("  program the 64 KiB env image (only non-0xFF pages)")
        self.log.info("  leave  0x{:06X}..0x{:06X} (U-Boot, {} KiB) untouched".format(
            UBOOT_OFFSET, UBOOT_OFFSET + UBOOT_SIZE, UBOOT_SIZE // 1024))
        self.log.info("  new env CRC 0x{:08X}, image sha256 {}".format(new_crc, sha256_hex(image)))

        if not commit:
            self.log.info("dry run only; re-run with --commit to write")
            return False

        self.verify_backup(backup, full=not quick, progress=progress)

        status = self.nor.read_status()
        self.log.info("status register before write: 0x{:02X} (WIP={} WEL={} BP={})".format(
            status, status & SR_WIP, (status & SR_WEL) >> 1, (status & SR_BP_MASK) >> 2))
        if status & SR_BP_MASK:
            if not clear_bp:
                raise SafetyError(
                    "flash block-protect bits are set (status 0x{:02X}); "
                    "refusing to erase. Pass --clear-bp if you know WP# is high.".format(status))
            self.log.warn("clearing block-protect bits")
            self.nor.clear_block_protect()
            status = self.nor.read_status()
            if status & SR_BP_MASK:
                raise SafetyError("could not clear block protect (status 0x{:02X})".format(status))

        if confirm is not None:
            if not confirm():
                self.log.info("aborted by user")
                return False
        elif not yes:
            if not sys.stdin.isatty():
                raise SafetyError("refusing to write without --yes on a non-interactive stdin")
            sys.stderr.write("Type WRITE-ENV to erase and program the 64 KiB env block: ")
            sys.stderr.flush()
            answer = sys.stdin.readline().strip()
            if answer != "WRITE-ENV":
                self.log.info("aborted by user")
                return False

        self.log.info("erasing 64 KiB env block at 0x{:06X}".format(ENV_OFFSET))
        self.nor.erase_block(ENV_OFFSET)
        erased = self.nor.read(ENV_OFFSET, ENV_SIZE)
        if any(b != 0xFF for b in erased):
            raise SafetyError("env block did not read back as erased (all 0xFF)")

        self.log.info("programming {} bytes of env data".format(ENV_SIZE))
        try:
            self.nor.program(ENV_OFFSET, image)
            got = self.nor.read(ENV_OFFSET, ENV_SIZE)
            if got != image:
                ranges = diff_ranges(got, image)
                raise SafetyError(
                    "env verify failed at {}; rolling back".format(format_ranges(ranges)))
        except Exception:
            self.log.error("env write/verify failed; restoring the original env from the backup")
            try:
                self.nor.erase_block(ENV_OFFSET)
                self.nor.program(ENV_OFFSET, old_image)
                restored = self.nor.read(ENV_OFFSET, ENV_SIZE)
                if restored == old_image:
                    self.log.info("rollback succeeded; env is back to the backup image")
                else:
                    self.log.error("ROLLBACK VERIFY FAILED; env is damaged, backup is {}".format(
                        backup.path))
            except Exception as rollback_exc:
                self.log.error("ROLLBACK FAILED: {}; env is damaged, backup is {}".format(
                    rollback_exc, backup.path))
            raise

        self.log.info("env written and verified (sha256 {})".format(sha256_hex(image)))
        self.log.info("power-cycle the NPU and watch the console; if it still fails, "
                      "the problem is not the env")
        return True

    def write_region(self, image, offset, commit=False, yes=False,
                     acknowledge_mtd0=False, clear_bp=False, confirm=None, progress=True):
        """Erase+program one explicitly addressed region. No env parsing anywhere.

        This exists because a corrupt env makes the guarded writers refuse to run
        (they insist on a backup whose env parses) — which is a chicken-and-egg
        deadlock when the env is exactly what needs repairing. Everything here is
        therefore positional and checked by hand: 64 KiB alignment, inside the
        flash, and mtd0 is off limits unless --unsafe-mtd0 is given.
        """
        length = len(image)
        if length == 0 or length % ENV_SIZE:
            raise SafetyError(
                "region length {} is not a non-zero multiple of 0x{:X}".format(length, ENV_SIZE))
        if offset % ENV_SIZE:
            raise SafetyError(
                "offset 0x{:X} is not 0x{:X}-aligned".format(offset, ENV_SIZE))
        if offset < 0 or offset + length > FLASH_SIZE:
            raise SafetyError("region 0x{:X}..0x{:X} is outside the {} KiB flash".format(
                offset, offset + length, FLASH_SIZE // 1024))
        if offset < UBOOT_OFFSET + UBOOT_SIZE and not acknowledge_mtd0:
            raise SafetyError(
                "region 0x{:X}..0x{:X} overlaps mtd0 (0x{:06X}..0x{:06X}) — that is the "
                "U-Boot/TF-A area. Pass --unsafe-mtd0 if you really mean it.".format(
                    offset, offset + length, UBOOT_OFFSET, UBOOT_OFFSET + UBOOT_SIZE))

        self.log.info("plan:")
        self.log.info("  erase  0x{:06X}..0x{:06X} ({} KiB, no env parsing)".format(
            offset, offset + length, length // 1024))
        self.log.info("  program {} bytes, image sha256 {}".format(length, sha256_hex(image)))
        if not commit:
            self.log.info("dry run only; re-run with --commit to write")
            return False

        status = self.nor.read_status()
        self.log.info("status register before write: 0x{:02X} (WIP={} WEL={} BP={})".format(
            status, status & SR_WIP, (status & SR_WEL) >> 1, (status & SR_BP_MASK) >> 2))
        if status & SR_BP_MASK:
            if not clear_bp:
                raise SafetyError(
                    "flash block-protect bits are set (status 0x{:02X}); "
                    "refusing to erase. Pass --clear-bp if you know WP# is high.".format(status))
            self.log.warn("clearing block-protect bits")
            self.nor.clear_block_protect()
            status = self.nor.read_status()
            if status & SR_BP_MASK:
                raise SafetyError("could not clear block protect (status 0x{:02X})".format(status))

        if confirm is not None:
            if not confirm():
                self.log.info("aborted by user")
                return False
        elif not yes:
            if not sys.stdin.isatty():
                raise SafetyError("refusing to write without --yes on a non-interactive stdin")
            sys.stderr.write("Type WRITE-REGION to erase and program 0x{:06X}..0x{:06X}: ".format(
                offset, offset + length))
            sys.stderr.flush()
            if sys.stdin.readline().strip() != "WRITE-REGION":
                self.log.info("aborted by user")
                return False

        old = self.nor.read(offset, length)
        self.log.info("erasing 0x{:06X}..0x{:06X}".format(offset, offset + length))
        for addr in range(offset, offset + length, ENV_SIZE):
            self.nor.erase_block(addr)
        if any(b != 0xFF for b in self.nor.read(offset, length)):
            raise SafetyError("region did not read back as erased (all 0xFF)")

        self.log.info("programming {} bytes".format(length))
        try:
            self.nor.program(offset, image)
            got = self.nor.read(offset, length)
            if got != image:
                raise SafetyError("verify failed at {}".format(
                    format_ranges(diff_ranges(got, image))))
        except Exception:
            self.log.error("write/verify failed; restoring the previous content")
            try:
                for addr in range(offset, offset + length, ENV_SIZE):
                    self.nor.erase_block(addr)
                self.nor.program(offset, old)
                if self.nor.read(offset, length) == old:
                    self.log.info("rollback succeeded")
                else:
                    self.log.error("ROLLBACK VERIFY FAILED; region 0x{:06X} is damaged".format(offset))
            except Exception as rollback_exc:
                self.log.error("ROLLBACK FAILED: {}; region 0x{:06X} is damaged".format(
                    rollback_exc, offset))
            raise

        self.log.info("region written and verified (sha256 {})".format(sha256_hex(image)))
        return True

    def restore_mtd0(self, backup, image, commit=False, yes=False, acknowledge=False,
                     allow_unverified=False, allow_mismatch=False, clear_bp=False,
                     confirm=None, progress=True, expected_sha256=None):
        """Rewrite the 0x3F0000-byte U-Boot/TF-A region, block by block.

        This is the rollback/repair path that the tool otherwise refuses to touch.
        It exists so a bad flash write is recoverable, not as a routine operation:
        nothing is erased until the whole chip matches the backup, the image hash
        is known, and the caller passes both `acknowledge` and `commit`.
        """
        backup.require_verified(allow_unverified)
        image = bytes(image)
        if len(image) != UBOOT_SIZE:
            raise SafetyError(
                "mtd0 image must be exactly {} bytes (0x{:X}), got {}".format(
                    UBOOT_SIZE, UBOOT_SIZE, len(image)))
        image_sha = sha256_hex(image)
        if expected_sha256 and image_sha != expected_sha256.lower():
            raise SafetyError(
                "mtd0 image sha256 {} does not match --expect-image-sha256 {}".format(
                    image_sha, expected_sha256))
        if backup.manifest:
            expected_serial = backup.manifest.get("device", {}).get("serial")
            actual_serial = getattr(self.nor.mcp.transport, "serial", "")
            if expected_serial and actual_serial and expected_serial != actual_serial:
                raise SafetyError(
                    "backup was made with MCP2210 serial {} but this device is {}; "
                    "refusing to write".format(expected_serial, actual_serial))

        self.log.info("re-reading the 0x{:06X}-byte mtd0 region".format(UBOOT_SIZE))
        p = Progress(self.log, "read", UBOOT_SIZE) if progress else None
        current = self.nor.read_range_progress(0, UBOOT_SIZE, p)
        if p:
            p.finish()
        if current == image:
            self.log.info("mtd0 already matches the image (sha256 {}); nothing to do".format(
                image_sha))
            return False

        ranges = diff_ranges(current, image)
        self.log.info("mtd0 differs from the image at {}".format(format_ranges(ranges)))
        self.log.info("plan:")
        self.log.info("  verify the whole 4 MiB chip against the backup first")
        self.log.info("  erase+program only the 64 KiB blocks that differ")
        self.log.info("  verify each block right after programming; abort on a mismatch")
        self.log.info("  leave 0x{:06X}..0x{:06X} (env) untouched".format(
            ENV_OFFSET, ENV_OFFSET + ENV_SIZE))
        self.log.info("  image sha256 {}".format(image_sha))

        if not acknowledge:
            self.log.info("refusing to touch mtd0: pass --unsafe-mtd0 to confirm you "
                          "accept that a failure here needs the MCP2210 or JTAG")
            return False
        if not commit:
            self.log.info("dry run only; re-run with --commit to write")
            return False

        expected_mtd0 = backup.data[:UBOOT_SIZE]
        if current != expected_mtd0:
            ranges = format_ranges(diff_ranges(current, expected_mtd0))
            if not allow_mismatch:
                raise SafetyError(
                    "the chip's mtd0 no longer matches the backup at {}; refusing to "
                    "rewrite it (pass --allow-mtd0-mismatch if this is a rollback)".format(ranges))
            self.log.warn("chip mtd0 differs from the backup at {}; rewriting anyway "
                          "(--allow-mtd0-mismatch)".format(ranges))
        else:
            self.log.info("chip mtd0 matches the backup (the env region is never written "
                          "by this command, so a stale env in the backup does not matter)")

        status = self.nor.read_status()
        if status & SR_BP_MASK:
            if not clear_bp:
                raise SafetyError(
                    "flash block-protect bits are set (status 0x{:02X}); "
                    "refusing to erase. Pass --clear-bp if you know WP# is high.".format(status))
            self.log.warn("clearing block-protect bits")
            self.nor.clear_block_protect()

        if confirm is not None:
            if not confirm():
                self.log.info("aborted by user")
                return False
        elif not yes:
            if not sys.stdin.isatty():
                raise SafetyError("refusing to write without --yes on a non-interactive stdin")
            sys.stderr.write(
                "Type RESTORE-MTD0 to erase and program the U-Boot/TF-A region: ")
            sys.stderr.flush()
            if sys.stdin.readline().strip() != "RESTORE-MTD0":
                self.log.info("aborted by user")
                return False

        blocks = [addr for addr in range(0, UBOOT_SIZE, 0x10000)
                  if current[addr:addr + 0x10000] != image[addr:addr + 0x10000]]
        self.log.info("rewriting {} of {} 64 KiB blocks".format(
            len(blocks), UBOOT_SIZE // 0x10000))
        for index, addr in enumerate(blocks, 1):
            want = image[addr:addr + 0x10000]
            self.log.info("[{}/{}] block 0x{:06X}".format(index, len(blocks), addr))
            self.nor.erase_block(addr)
            self.nor.program(addr, want)
            got = self.nor.read(addr, 0x10000)
            if got != want:
                bad = diff_ranges(got, want)
                raise SafetyError(
                    "verify failed in block 0x{:06X} at {}; blocks from 0x{:06X} on were "
                    "not written. The env region is untouched.".format(
                        addr, format_ranges(bad), addr + 0x10000))

        final = self.nor.read_range_progress(0, UBOOT_SIZE,
                                             Progress(self.log, "verify", UBOOT_SIZE)
                                             if progress else None)
        if final != image:
            raise SafetyError("final mtd0 verify failed at {}".format(
                format_ranges(diff_ranges(final, image))))
        self.log.info("mtd0 restored and verified (sha256 {})".format(image_sha))
        return True


# --------------------------------------------------------------------------
# offline comparison / env building
# --------------------------------------------------------------------------

def default_reference_uboot():
    return os.path.join(REPO_ROOT, "reference", "mtd", "npu-mtd0-uboot.bin.gz")


def default_reference_env():
    return os.path.join(REPO_ROOT, "reference", "mtd", "npu-mtd1-env.bin.gz")


def load_reference_uboot(path):
    if path is None:
        return None
    try:
        data = load_maybe_gzip(path)
    except OSError:
        return None
    return data


def compare_dump(dump, reference_uboot, reference_env, log, json_out=False):
    if len(dump) != FLASH_SIZE:
        raise ToolError("dump is {} bytes, expected {}".format(len(dump), FLASH_SIZE))
    result = {"dump_size": len(dump), "dump_sha256": sha256_hex(dump)}
    uboot = dump[:UBOOT_SIZE]
    uboot_ref = reference_uboot
    if uboot_ref is not None and len(uboot_ref) == UBOOT_SIZE:
        same = uboot == uboot_ref
        result["uboot"] = {"reference": "match" if same else "diff",
                           "first_diff": [] if same else
                           [[o, n] for o, n in diff_ranges(uboot, uboot_ref)]}
    else:
        result["uboot"] = {"reference": "unavailable"}

    try:
        env_items, stored, calc, fill = load_env_image(
            dump[ENV_OFFSET:ENV_OFFSET + ENV_SIZE], strict_crc=False, where="dump env")
        result["env"] = {"crc_stored": stored, "crc_calculated": calc,
                         "crc_ok": stored == calc, "keys": len(env_items)}
        if stored != calc:
            log.warn("env CRC is BAD (stored 0x{:08X}, calculated 0x{:08X}); "
                     "the key/value text was still parsed".format(stored, calc))
        env_ref = None
        if reference_env is not None:
            try:
                env_ref, _, _, _ = load_env_image(reference_env, where="reference env")
            except ToolError as exc:
                log.warn("cannot parse the reference env: {}".format(exc))
        if env_ref is not None:
            added, removed, changed = env_diff(env_ref, env_items)
            redacted = []
            if mac_is_placeholder(env_ref) or mac_is_placeholder(env_items):
                if b"ethaddr" in changed:
                    redacted.append(b"ethaddr")
                    changed.remove(b"ethaddr")
            result["env"]["reference"] = {
                "added": [_printable(k) for k in added],
                "removed": [_printable(k) for k in removed],
                "changed": [_printable(k) for k in changed],
                "redacted_only": [_printable(k) for k in redacted],
            }
    except ToolError as exc:
        result["env"] = {"error": str(exc)}

    if json_out:
        print(json.dumps(result, indent=2, sort_keys=True))
        return result
    log.info("dump: {} bytes, sha256 {}".format(len(dump), result["dump_sha256"]))
    if result["uboot"]["reference"] == "match":
        log.info("U-Boot (mtd0, 0x000000..0x{:06X}): identical to the reference".format(UBOOT_SIZE))
    elif result["uboot"]["reference"] == "diff":
        log.warn("U-Boot (mtd0) DIFFERS from the reference at {}".format(
            format_ranges([tuple(x) for x in result["uboot"]["first_diff"]])))
        log.warn("an env-only write cannot fix a changed U-Boot image")
    else:
        log.warn("no U-Boot reference loaded")
    if "error" in result["env"]:
        log.warn("env: {}".format(result["env"]["error"]))
    else:
        log.info("env (mtd1): CRC 0x{:08X} {}, {} variables".format(
            result["env"]["crc_stored"], "OK" if result["env"]["crc_ok"] else "BAD",
            result["env"]["keys"]))
        if "reference" in result["env"]:
            ref = result["env"]["reference"]
            if ref["added"] or ref["removed"] or ref["changed"]:
                log.info("env vs reference: {} added, {} removed, {} changed".format(
                    len(ref["added"]), len(ref["removed"]), len(ref["changed"])))
                if ref["added"]:
                    log.info("  added: " + ", ".join(ref["added"]))
                if ref["removed"]:
                    log.info("  removed: " + ", ".join(ref["removed"]))
                if ref["changed"]:
                    log.info("  changed: " + ", ".join(ref["changed"]))
            else:
                log.info("env vs reference: identical (apart from redacted fields)")
            if ref["redacted_only"]:
                log.info("  redacted-only difference: " + ", ".join(ref["redacted_only"]))
    if result["uboot"]["reference"] == "match" and result.get("env", {}).get("crc_ok"):
        log.info("conclusion: the SPI NOR matches the known-good images; a boot failure "
                 "is probably not caused by these flash contents")
    elif result["uboot"]["reference"] == "match" and "error" not in result.get("env", {}):
        log.info("conclusion: U-Boot is intact but the env CRC is bad; rewriting only "
                 "the env block is the appropriate fix")
    return result


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def parse_speed(text):
    if text is None:
        return None
    text = text.strip()
    if text.lower() == "auto":
        return None
    match = re.fullmatch(r"(\d+(?:\.\d+)?)([kKmM]?)", text)
    if not match:
        raise argparse.ArgumentTypeError("speed must be a number like 1M, 500k or auto")
    value = float(match.group(1))
    unit = match.group(2).lower()
    value *= {"": 1, "k": 1000, "m": 1_000_000}[unit]
    value = int(value)
    if not 1_500 <= value <= 12_000_000:
        raise argparse.ArgumentTypeError("speed must be between 1500 and 12000000")
    return value


def parse_pin(text):
    match = re.fullmatch(r"(?i)(?:gp)?([0-8])", text.strip())
    if not match:
        raise argparse.ArgumentTypeError("pin must be 0..8 or GP0..GP8")
    return int(match.group(1))


def parse_gpio(text):
    if "=" not in text:
        raise argparse.ArgumentTypeError("--gpio expects PIN=LEVEL (e.g. GP3=0)")
    pin_text, level_text = text.split("=", 1)
    pin = parse_pin(pin_text)
    if level_text.strip() not in ("0", "1"):
        raise argparse.ArgumentTypeError("GPIO level must be 0 or 1")
    return pin, int(level_text)


def parse_set(text):
    if "=" not in text:
        raise argparse.ArgumentTypeError("--set expects KEY=VALUE")
    key, value = text.split("=", 1)
    if not key:
        raise argparse.ArgumentTypeError("--set key is empty")
    return key.encode("utf-8"), value.encode("utf-8")


def parse_int_hex(text):
    try:
        return int(text, 0)
    except ValueError:
        raise argparse.ArgumentTypeError("expected a number (decimal or 0x...)")


def make_logger(args):
    if getattr(args, "no_log", False):
        path = None
    elif getattr(args, "log", None):
        path = args.log
    else:
        stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
        path = os.path.join("logs", "mcp2210-{}.log".format(stamp))
    logger = Logger(path, debug=getattr(args, "debug", False))
    if path:
        logger.info("log: {}".format(os.path.abspath(path)))
    return logger


def open_hardware(args, logger, require_chip=True, need_spi=True):
    device = discover_hidraw(logger, args.device)
    transport = HidRawTransport(device["path"], logger)
    transport.serial = device.get("serial", "")
    try:
        mcp = Mcp2210(transport, logger)
    except Exception:
        transport.close()
        raise
    npu = resolve_npu(args, logger, need_spi)
    nor = SpiNor(
        mcp, logger,
        cs_pin=args.cs_pin,
        cs_mode=args.cs_mode,
        speed=args.speed,
        mode=args.mode,
        active_high=args.cs_active_high,
        gpio_overrides=args.gpio,
        force_chip=args.force_chip,
        read_chunk=args.read_chunk,
        npu=npu,
    )
    try:
        nor.open(require_chip=require_chip)
    except Exception:
        nor.close()
        raise
    return nor, device


def cmd_info(args, logger):
    device = discover_hidraw(logger, args.device)
    transport = HidRawTransport(device["path"], logger)
    transport.serial = device.get("serial", "")
    try:
        mcp = Mcp2210(transport, logger)
    except Exception:
        transport.close()
        raise
    info = {"device": device, "status": mcp.get_status()}
    gpio, access = mcp.get_gpio()
    direction = mcp.get_gpio_dir()
    value = mcp.get_gpio_value()
    spi = mcp.get_spi()
    info.update({
        "gpio": {"designations": list(gpio.designations), "output": gpio.output,
                 "direction": direction, "value": value, "other": gpio.other,
                 "access": access},
        "spi": {"bit_rate": spi.bit_rate, "mode": spi.mode, "idle_cs": spi.idle_cs,
                "active_cs": spi.active_cs, "cs_to_data": spi.cs_to_data,
                "data_to_cs": spi.data_to_cs, "interbyte": spi.interbyte,
                "xfer_size": spi.xfer_size},
    })
    if not args.no_probe:
        npu = resolve_npu(args, logger, need_spi=True)
        nor = SpiNor(mcp, logger, cs_pin=args.cs_pin, cs_mode=args.cs_mode,
                     speed=args.speed, mode=args.mode,
                     active_high=args.cs_active_high, gpio_overrides=args.gpio,
                     force_chip=True, read_chunk=args.read_chunk, npu=npu)
        try:
            nor.open(require_chip=False)
            info["chip"] = {"jedec": hexs(nor.jedec), "name": CHIP_NAME,
                            "speed": nor.speed, "cs_pin": nor.cs_pin, "cs_mode": nor.cs_mode}
            status = nor.read_status()
            info["chip"]["status"] = status
            if args.read_env:
                env_image = nor.read(ENV_OFFSET, ENV_SIZE)
                info["env_image_sha256"] = sha256_hex(env_image)
                try:
                    items, stored, calc, fill = load_env_image(
                        env_image, strict_crc=False, where="chip env")
                    info["env"] = {"crc_stored": stored, "crc_calculated": calc,
                                   "crc_ok": stored == calc,
                                   "keys": {_printable(k): _printable(v) for k, v in items.items()}}
                    if stored != calc:
                        logger.warn("env CRC is BAD (stored 0x{:08X}, calculated 0x{:08X})".format(
                            stored, calc))
                except ToolError as exc:
                    info["env"] = {"error": str(exc)}
                if args.env_out:
                    write_atomic(args.env_out, env_image)
                    logger.info("env image saved to {}".format(args.env_out))
        except ToolError as exc:
            info["probe_error"] = str(exc)
            logger.warn(str(exc))
        finally:
            nor.close()
    else:
        mcp.close()
    if args.json:
        print(json.dumps(info, indent=2, sort_keys=True))
        return 0
    print("device: {}  serial={}  ({})".format(device["path"], device.get("serial") or "?", device.get("name")))
    st = info["status"]
    print("status: bus_owner={} bus_release_request={} password_attempts={} guessed={}".format(
        st["bus_owner"], st["bus_release_external_request"],
        st["password_attempts"], st["password_guessed"]))
    print("GPIO:  " + gpio.describe())
    print("       current direction=0x{:03X} value=0x{:03X} access=0x{:02X}".format(
        direction, value, access))
    print("SPI:   " + spi.describe())
    if "chip" in info:
        print("chip:  {} JEDEC {} at {} Hz (CS {} via {})".format(
            CHIP_NAME, info["chip"]["jedec"], info["chip"]["speed"],
            info["chip"]["cs_pin"], info["chip"]["cs_mode"]))
        sr = info["chip"]["status"]
        print("SR:    0x{:02X} (WIP={} WEL={} BP={:03b} SRWD={})".format(
            sr, sr & SR_WIP, (sr & SR_WEL) >> 1, (sr & SR_BP_MASK) >> 2, (sr >> 7) & 1))
    if "env" in info:
        if "error" in info["env"]:
            print("env:   " + info["env"]["error"])
        else:
            print("env:   CRC 0x{:08X} {} ({} keys)".format(
                info["env"]["crc_stored"], "OK" if info["env"]["crc_ok"] else "BAD",
                len(info["env"]["keys"])))
            for key, value in info["env"]["keys"].items():
                print("       {}={}".format(key, value))
    if "probe_error" in info:
        print("probe: " + info["probe_error"])
    return 0


def cmd_dump(args, logger):
    nor, device = open_hardware(args, logger, require_chip=True)
    try:
        session = NorSession(nor, logger, load_reference_uboot(args.reference_uboot),
                             load_maybe_gzip(default_reference_env())
                             if os.path.exists(default_reference_env()) else None)
        backup = session.dump(args.out, passes=args.passes, force=args.force,
                              progress=not args.quiet)
        if args.compare:
            compare_dump(backup.data, session.reference_uboot, session.reference_env,
                         logger, json_out=False)
        return 0
    finally:
        nor.close()


def cmd_verify(args, logger):
    backup = Backup.load(args.backup, require_manifest=False)
    backup.require_verified(allow_unverified=True)
    nor, device = open_hardware(args, logger, require_chip=True)
    try:
        session = NorSession(nor, logger, load_reference_uboot(args.reference_uboot), None)
        session.verify_backup(backup, full=True, progress=not args.quiet)
        return 0
    finally:
        nor.close()


def cmd_compare(args, logger):
    dump = load_maybe_gzip(args.dump)
    reference_uboot = load_reference_uboot(args.reference_uboot)
    reference_env = None
    if args.reference_env:
        try:
            reference_env = load_maybe_gzip(args.reference_env)
        except OSError:
            reference_env = None
    result = compare_dump(dump, reference_uboot, reference_env, logger, json_out=args.json)
    if args.strict:
        bad = result["uboot"]["reference"] == "diff" or result.get("env", {}).get("crc_ok") is False
        if bad:
            return 1
    return 0


def cmd_env_get(args, logger):
    nor, device = open_hardware(args, logger, require_chip=True)
    try:
        image = nor.read(ENV_OFFSET, ENV_SIZE)
        if args.out:
            write_atomic(args.out, image)
            logger.info("env image saved to {}".format(args.out))
        items, stored, calc, fill = load_env_image(image, strict_crc=False, where="chip env")
        if stored == calc:
            logger.info("env CRC 0x{:08X} OK, {} keys".format(stored, len(items)))
        else:
            logger.warn("env CRC is BAD (stored 0x{:08X}, calculated 0x{:08X}), "
                        "but the key/value text parsed as {} keys".format(
                            stored, calc, len(items)))
        if args.json:
            print(json.dumps({"crc": stored, "crc_calculated": calc,
                              "crc_ok": stored == calc,
                              "keys": {_printable(k): _printable(v)
                                       for k, v in items.items()}},
                             indent=2, sort_keys=True))
        else:
            for key, value in items.items():
                print("{}={}".format(_printable(key), _printable(value)))
        return 0
    finally:
        nor.close()


def cmd_read(args, logger):
    nor, device = open_hardware(args, logger, require_chip=True)
    try:
        hashes = []
        last = None
        for index in range(max(1, args.repeat)):
            data = nor.read(args.addr, args.length)
            last = data
            digest = sha256_hex(data)
            hashes.append(digest)
            logger.info("read {}: 0x{:06X}+0x{:X} sha256 {}".format(
                index + 1, args.addr, args.length, digest))
            if args.json:
                print(json.dumps({"index": index + 1, "addr": args.addr,
                                  "length": args.length, "sha256": digest,
                                  "first32": hexs(data[:32])}))
            else:
                print("#{} {}  {}".format(index + 1, digest, hexs(data[:32])))
        if args.out:
            write_atomic(args.out, last)
            logger.info("saved the last read to {}".format(args.out))
        if len(set(hashes)) != 1:
            logger.error("reads are NOT stable: {} distinct hashes".format(len(set(hashes))))
            return 1
        return 0
    finally:
        nor.close()


def cmd_env_build(args, logger):
    if bool(args.from_backup) == bool(args.from_text):
        raise ToolError("use exactly one of --from-backup or --from-text")
    if args.from_backup:
        backup = Backup.load(args.from_backup, require_manifest=False)
        items, stored, calc, _ = load_env_image(
            backup.env_image(), strict_crc=False, where="backup env")
        if stored != calc:
            logger.warn("backup env CRC is BAD (stored 0x{:08X}, calculated 0x{:08X}); "
                        "building a fresh image with a correct CRC".format(stored, calc))
        source = "backup {}".format(args.from_backup)
    else:
        items = parse_env_text(read_file(args.from_text), where=args.from_text)
        source = "text {}".format(args.from_text)
        if mac_is_placeholder(items) and not args.allow_redacted:
            raise SafetyError(
                "{} has a redacted ethaddr (xx:xx); build from the chip backup "
                "instead, or pass --allow-redacted".format(args.from_text))
    for key, value in args.set:
        items[key] = value
    for key in args.unset:
        items.pop(key.encode("utf-8"), None)
    image = build_env_image(items)
    load_env_image(image, where="built env")
    write_atomic(args.out, image)
    logger.info("built {} -> {} ({} keys, {} bytes, sha256 {})".format(
        source, args.out, len(items), len(image), sha256_hex(image)))
    return 0


def cmd_env_write(args, logger):
    backup = Backup.load(args.backup, require_manifest=True)
    image = read_file(args.image)
    if args.expect_image_sha256:
        actual = sha256_hex(image)
        if actual.lower() != args.expect_image_sha256.lower():
            raise SafetyError("env image sha256 {} does not match --expect-image-sha256 {}".format(
                actual, args.expect_image_sha256))
    load_env_image(image, where="new env image")
    nor, device = open_hardware(args, logger, require_chip=True)
    try:
        session = NorSession(nor, logger, load_reference_uboot(args.reference_uboot), None)
        confirm = None
        if args.commit and not args.yes:
            confirm = lambda: _interactive_confirm()
        session.write_env(
            backup, image,
            commit=args.commit,
            yes=args.yes,
            quick=args.quick,
            allow_uboot_mismatch=args.allow_uboot_mismatch,
            allow_missing_reference=args.allow_missing_reference,
            allow_unverified=args.allow_unverified_backup,
            clear_bp=args.clear_bp,
            confirm=confirm,
            progress=not args.quiet,
            expected_uboot_sha256=args.reference_uboot_sha256,
        )
        return 0
    finally:
        nor.close()


def cmd_flash_write(args, logger):
    image = read_file(args.image)
    if args.expect_image_sha256:
        actual = sha256_hex(image)
        if actual.lower() != args.expect_image_sha256.lower():
            raise SafetyError("image sha256 {} does not match --expect-image-sha256 {}".format(
                actual, args.expect_image_sha256))
    nor, device = open_hardware(args, logger, require_chip=True)
    try:
        session = NorSession(nor, logger, None, None)
        confirm = None
        if args.commit and not args.yes:
            confirm = lambda: _interactive_confirm()
        session.write_region(
            image, args.offset,
            commit=args.commit,
            yes=args.yes,
            acknowledge_mtd0=args.unsafe_mtd0,
            clear_bp=args.clear_bp,
            confirm=confirm,
            progress=not args.quiet,
        )
        return 0
    finally:
        nor.close()


def cmd_mtd0_restore(args, logger):
    backup = Backup.load(args.backup, require_manifest=True)
    image = load_maybe_gzip(args.image)
    nor, device = open_hardware(args, logger, require_chip=True)
    try:
        session = NorSession(nor, logger, load_reference_uboot(args.reference_uboot), None)
        confirm = None
        if args.commit and args.unsafe_mtd0 and not args.yes:
            confirm = lambda: _interactive_confirm()
        session.restore_mtd0(
            backup, image,
            commit=args.commit,
            yes=args.yes,
            acknowledge=args.unsafe_mtd0,
            allow_unverified=args.allow_unverified_backup,
            allow_mismatch=args.allow_mtd0_mismatch,
            clear_bp=args.clear_bp,
            confirm=confirm,
            progress=not args.quiet,
            expected_sha256=args.expect_image_sha256,
        )
        return 0
    finally:
        nor.close()


def cmd_npu(args, logger):
    device = discover_hidraw(logger, args.device)
    transport = HidRawTransport(device["path"], logger)
    transport.serial = device.get("serial", "")
    try:
        mcp = Mcp2210(transport, logger)
    except Exception:
        transport.close()
        raise
    try:
        board, source = read_board_number(logger, args.board)
        if board is None:
            raise SafetyError("cannot determine the board assembly number (read {!r}); "
                              "pass --board 200".format(source))
        if board not in NPU_VALUES:
            raise SafetyError("no NPU values for AMDA{:04d}; known: {}".format(
                board, ", ".join("AMDA{:04d}".format(b) for b in sorted(NPU_VALUES))))
        values = NPU_VALUES[board]
        before = npu_live_state(mcp)
        result = {"board": board, "serial": source,
                  "mask": NPU_MASK, "hold": values["hold"], "release": values["release"],
                  "before": before}
        if args.action in ("hold", "pulse"):
            npu_gpio_write(mcp, values["hold"], NPU_MASK, logger)
            logger.info("NPU held: wrote 0x{:04X} mask 0x{:04X}".format(
                values["hold"], NPU_MASK))
            if args.action == "pulse":
                time.sleep(0.5)
                npu_gpio_write(mcp, values["release"], NPU_MASK, logger)
                logger.info("NPU released: wrote 0x{:04X} mask 0x{:04X}".format(
                    values["release"], NPU_MASK))
        elif args.action == "release":
            npu_gpio_write(mcp, values["release"], NPU_MASK, logger)
            logger.info("NPU released: wrote 0x{:04X} mask 0x{:04X}".format(
                values["release"], NPU_MASK))
        after = npu_live_state(mcp)
        result["after"] = after
        want = values["hold"] if args.action == "hold" else values["release"]
        result["matches"] = (after["live_value"] & NPU_MASK) == (want & NPU_MASK)
        if args.json:
            print(json.dumps(result, indent=2, sort_keys=True))
        else:
            print("board: AMDA{:04d}  ({})".format(board, source))
            print("mask:  0x{:04X}  hold=0x{:04X}  release=0x{:04X}".format(
                NPU_MASK, values["hold"], values["release"]))
            print("live:  before 0x{:04X} (dir 0x{:04X}) -> after 0x{:04X} (dir 0x{:04X})".format(
                before["live_value"], before["live_dir"],
                after["live_value"], after["live_dir"]))
            if args.action == "status":
                held = (before["live_value"] & NPU_MASK) == (values["hold"] & NPU_MASK)
                released = (before["live_value"] & NPU_MASK) == (values["release"] & NPU_MASK)
                print("state: " + ("HOLD" if held else "RELEASE" if released else "unknown/mixed"))
            else:
                print("result: " + ("OK" if result["matches"] else
                                    "MISMATCH (check the board table / wiring)"))
        return 0 if args.action == "status" or result["matches"] else 1
    finally:
        mcp.close()


def _interactive_confirm():
    if not sys.stdin.isatty():
        raise SafetyError("refusing to write without --yes on a non-interactive stdin")
    sys.stderr.write("Type WRITE-ENV to erase and program the 64 KiB env block: ")
    sys.stderr.flush()
    return sys.stdin.readline().strip() == "WRITE-ENV"


def build_parser():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--device", help="hidraw path (default: auto-detect 04d8:00de)")
    common.add_argument("--speed", type=parse_speed, default=parse_speed("1M"),
                        help="SPI clock (e.g. 1M, 500k) or auto (default 1M)")
    common.add_argument("--mode", type=int, choices=(0, 1, 2, 3), default=0,
                        help="SPI mode (default 0)")
    common.add_argument("--cs-pin", type=parse_pin, default=None,
                        help="GP pin wired to flash CS (default: auto-detect designation)")
    common.add_argument("--cs-mode", choices=("auto", "internal", "gpio"), default="auto",
                        help="internal = MCP2210 CS engine, gpio = manual GPIO toggling")
    common.add_argument("--cs-active-high", action="store_true",
                        help="CS is active high (only meaningful with --cs-mode gpio)")
    common.add_argument("--gpio", type=parse_gpio, action="append", default=[],
                        metavar="PIN=LEVEL", help="drive a GPIO output before probing (repeatable)")
    common.add_argument("--read-chunk", type=int, default=DEFAULT_READ_CHUNK,
                        help="bytes per SPI read transaction (default 4096)")
    common.add_argument("--npu", choices=("auto", "hold", "none"), default="auto",
                        help="hold the NPU in reset while using the SPI bus (default auto)")
    common.add_argument("--board", type=int, default=None,
                        help="AMDA board number (e.g. 200) if DMI cannot be read")
    common.add_argument("--force-chip", action="store_true",
                        help="proceed even if the JEDEC ID is not MX25L3205D")
    common.add_argument("--log", help="log file (default logs/mcp2210-<time>.log)")
    common.add_argument("--no-log", action="store_true", help="disable the log file")
    common.add_argument("--debug", action="store_true", help="verbose protocol logging")
    common.add_argument("--quiet", action="store_true", help="suppress progress output")
    common.add_argument("--json", action="store_true", help="machine-readable output where supported")
    common.add_argument("--yes", action="store_true", help="skip the interactive confirmation")

    ap = argparse.ArgumentParser(
        description="MCP2210 SPI NOR rescue tool for the XGS 87 NPU (mx25l3205d, 4 MiB)")
    sub = ap.add_subparsers(dest="command", required=True)

    p = sub.add_parser("info", parents=[common], help="read MCP2210 settings and chip status")
    p.add_argument("--no-probe", action="store_true", help="do not touch the SPI bus")
    p.add_argument("--read-env", action="store_true", help="also read and print the 64 KiB env")
    p.add_argument("--env-out", help="save the env image read by --read-env")
    p.set_defaults(func=cmd_info)

    p = sub.add_parser("npu", parents=[common],
                       help="inspect/hold/release/pulse the NPU reset lines")
    p.add_argument("action", choices=("status", "hold", "release", "pulse"))
    p.set_defaults(func=cmd_npu)

    p = sub.add_parser("dump", parents=[common], help="full 4 MiB read + verification + manifest")
    p.add_argument("--out", required=True, help="backup path (.bin; .json and .sha256 are written)")
    p.add_argument("--passes", type=int, choices=(1, 2), default=2,
                   help="1 = read once (not safe), 2 = read twice and compare (default)")
    p.add_argument("--force", action="store_true", help="overwrite an existing backup")
    p.add_argument("--no-compare", dest="compare", action="store_false", default=True,
                   help="do not compare the dump with the reference images")
    p.add_argument("--reference-uboot", default=default_reference_uboot(),
                   help="known-good mtd0 image (default: repository reference)")
    p.set_defaults(func=cmd_dump)

    p = sub.add_parser("verify", parents=[common], help="re-read the chip and verify a backup")
    p.add_argument("--backup", required=True)
    p.add_argument("--reference-uboot", default=default_reference_uboot())
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser("read", parents=[common],
                       help="read a range (repeatable; read-only stability check)")
    p.add_argument("--addr", type=parse_int_hex, default=0)
    p.add_argument("--length", type=parse_int_hex, default=4096)
    p.add_argument("--repeat", type=int, default=1)
    p.add_argument("--out", help="save the last read to this file")
    p.set_defaults(func=cmd_read)

    p = sub.add_parser("compare", help="offline compare a dump with the reference images")
    p.add_argument("--dump", required=True)
    p.add_argument("--reference-uboot", default=default_reference_uboot())
    p.add_argument("--reference-env", default=default_reference_env())
    p.add_argument("--json", action="store_true")
    p.add_argument("--strict", action="store_true", help="exit 1 on a U-Boot diff or bad env CRC")
    p.set_defaults(func=cmd_compare, no_log=True, debug=False, quiet=False)

    p = sub.add_parser("env-get", parents=[common], help="read the env region (read-only)")
    p.add_argument("--out", help="also save the 64 KiB env image")
    p.set_defaults(func=cmd_env_get)

    p = sub.add_parser("env-build", help="build a 64 KiB env image offline")
    p.add_argument("--from-backup", help="full 4 MiB backup to take the env from")
    p.add_argument("--from-text", help="text env (fw_printenv style, one key=value per line)")
    p.add_argument("--out", required=True, help="output 64 KiB env image")
    p.add_argument("--set", type=parse_set, action="append", default=[], metavar="KEY=VALUE")
    p.add_argument("--unset", action="append", default=[], metavar="KEY")
    p.add_argument("--allow-redacted", action="store_true",
                   help="allow a redacted ethaddr from --from-text")
    p.set_defaults(func=cmd_env_build, no_log=True, debug=False, quiet=False)

    p = sub.add_parser("env-write", parents=[common],
                       help="guarded erase/program of the 64 KiB env block only")
    p.add_argument("--backup", required=True, help="two-pass verified full 4 MiB backup")
    p.add_argument("--image", required=True, help="64 KiB env image from env-build")
    p.add_argument("--expect-image-sha256")
    p.add_argument("--commit", action="store_true", help="actually erase/program (default: plan)")
    p.add_argument("--quick", action="store_true",
                   help="verify only the env region before writing (default: whole chip)")
    p.add_argument("--clear-bp", action="store_true", help="clear flash block-protect bits")
    p.add_argument("--allow-uboot-mismatch", action="store_true")
    p.add_argument("--allow-missing-reference", action="store_true")
    p.add_argument("--allow-unverified-backup", action="store_true")
    p.add_argument("--reference-uboot", default=default_reference_uboot())
    p.add_argument("--reference-uboot-sha256",
                   help="known-good SHA-256 of the 0x3F0000-byte mtd0, "
                        "instead of (or in addition to) a reference file")
    p.set_defaults(func=cmd_env_write)

    p = sub.add_parser("flash-write", parents=[common],
                       help="erase+program one explicit 64 KiB-aligned region "
                            "(no env parsing — for repairing a corrupt env)")
    p.add_argument("--image", required=True, help="exactly the bytes for the region")
    p.add_argument("--offset", type=lambda s: int(s, 0), required=True,
                   help="region start, e.g. 0x3F0000 (must be 64 KiB aligned)")
    p.add_argument("--expect-image-sha256")
    p.add_argument("--commit", action="store_true", help="actually erase/program (default: plan)")
    p.add_argument("--unsafe-mtd0", action="store_true",
                   help="allow the region to overlap mtd0 (U-Boot/TF-A)")
    p.add_argument("--clear-bp", action="store_true", help="clear flash block-protect bits")
    p.set_defaults(func=cmd_flash_write)

    p = sub.add_parser("mtd0-restore", parents=[common],
                       help="restore the 0x3F0000-byte U-Boot/TF-A region "
                            "(needs --unsafe-mtd0, plans without --commit)")
    p.add_argument("--backup", required=True, help="two-pass verified full 4 MiB backup")
    p.add_argument("--image", required=True, help="0x3F0000-byte mtd0 image (.bin or .gz)")
    p.add_argument("--expect-image-sha256")
    p.add_argument("--unsafe-mtd0", action="store_true",
                   help="acknowledge that this erases the U-Boot/TF-A region")
    p.add_argument("--commit", action="store_true",
                   help="actually erase/program (default: plan)")
    p.add_argument("--clear-bp", action="store_true")
    p.add_argument("--allow-unverified-backup", action="store_true")
    p.add_argument("--allow-mtd0-mismatch", action="store_true",
                   help="proceed even if the chip's mtd0 differs from the backup "
                        "(needed when rolling back a previous write)")
    p.add_argument("--reference-uboot", default=default_reference_uboot())
    p.set_defaults(func=cmd_mtd0_restore)

    return ap


def main(argv=None):
    ap = build_parser()
    args = ap.parse_args(argv)
    logger = make_logger(args)
    try:
        return args.func(args, logger)
    except SafetyError as exc:
        logger.error(str(exc))
        return SafetyError.exit_code
    except ToolError as exc:
        logger.error(str(exc))
        return exc.exit_code
    except KeyboardInterrupt:
        logger.error("interrupted")
        return 130
    finally:
        logger.close()


if __name__ == "__main__":
    sys.exit(main())
