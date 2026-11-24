#!/usr/bin/env python3
"""Hardware-free tests for mcp2210-nor.py.

The MCP2210 and the MX25L3205D are simulated in memory, so these tests exercise
the real command framing, SPI transaction state machine, NOR semantics, the
backup manifest and the env-only write policy without an appliance.

Run from the repository root:

    python -m unittest discover -s tools/on-x86 -p 'test_*.py' -v
"""

import gzip
import importlib.util
import os
import struct
import sys
import tempfile
import unittest
import zlib
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
TOOL_PATH = os.path.join(HERE, "mcp2210-nor.py")


def load_tool():
    spec = importlib.util.spec_from_file_location("mcp2210_nor", TOOL_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


m = load_tool()


def reference_uboot():
    with gzip.open(os.path.join(REPO, "reference", "mtd", "npu-mtd0-uboot.bin.gz"), "rb") as fh:
        data = fh.read()
    assert len(data) == m.UBOOT_SIZE
    return data


def reference_env_items():
    with gzip.open(os.path.join(REPO, "reference", "mtd", "npu-mtd1-env.bin.gz"), "rb") as fh:
        image = fh.read()
    items, _, _, _ = m.load_env_image(image)
    return items


def sim_env_image(mac=b"02:00:00:00:00:01"):
    items = reference_env_items()
    items[b"ethaddr"] = mac
    return m.build_env_image(items)


def flash_with_reference(mac=b"02:00:00:00:00:01"):
    flash = SimFlash()
    flash.mem[:m.UBOOT_SIZE] = reference_uboot()
    flash.mem[m.ENV_OFFSET:m.ENV_OFFSET + m.ENV_SIZE] = sim_env_image(mac)
    return flash


class SimFlash:
    """MX25L3205D subset: RDID/READ/RDSR/WREN/WRSR/PP/SE/BE."""

    JEDEC = b"\xc2\x20\x16"

    def __init__(self, size=m.FLASH_SIZE):
        self.mem = bytearray(b"\xff" * size)
        self.wel = False
        self.bp = 0
        self.srwd = 0
        self.busy_reads = 0
        self.writes = []

    def status(self):
        value = self.bp & 0x1C
        if self.wel:
            value |= 0x02
        if self.busy_reads:
            value |= 0x01
        if self.srwd:
            value |= 0x80
        return value

    def miso(self, stream):
        if not stream:
            return b""
        cmd = stream[0]
        out = bytearray(b"\xff" * len(stream))
        if cmd == 0x9F:
            out[1:4] = self.JEDEC
        elif cmd == 0x03:
            if len(stream) >= 4:
                addr = (stream[1] << 16) | (stream[2] << 8) | stream[3]
                for i in range(4, len(stream)):
                    pos = addr + i - 4
                    if pos < len(self.mem):
                        out[i] = self.mem[pos]
        elif cmd == 0x05:
            if len(stream) >= 2:
                out[1] = self.status()
        return bytes(out)

    def execute(self, stream):
        if not stream:
            return
        cmd = stream[0]
        if cmd == 0x06:  # WREN
            self.wel = True
        elif cmd == 0x01:  # WRSR
            if len(stream) >= 2:
                self.bp = stream[1] & 0x1C
                self.srwd = stream[1] & 0x80
                self.wel = False
                self.busy_reads = 2
        elif cmd == 0x05:  # RDSR
            if self.busy_reads:
                self.busy_reads -= 1
        elif cmd == 0x02:  # PP
            addr = (stream[1] << 16) | (stream[2] << 8) | stream[3]
            data = stream[4:]
            self.writes.append(("PP", addr, len(data)))
            if self.wel and not self.bp:
                for i, byte in enumerate(data):
                    self.mem[addr + i] &= byte
            self.wel = False
            self.busy_reads = 2
        elif cmd == 0x20:  # SE
            addr = (stream[1] << 16) | (stream[2] << 8) | stream[3]
            self.writes.append(("SE", addr, 0x1000))
            if self.wel and not self.bp:
                self.mem[addr:addr + 0x1000] = b"\xff" * 0x1000
            self.wel = False
            self.busy_reads = 2
        elif cmd == 0xD8:  # BE
            addr = (stream[1] << 16) | (stream[2] << 8) | stream[3]
            self.writes.append(("BE", addr, 0x10000))
            if self.wel and not self.bp:
                self.mem[addr:addr + 0x10000] = b"\xff" * 0x10000
            self.wel = False
            self.busy_reads = 1


class SimMcpTransport:
    """MCP2210 command engine + SPI engine, enough for the tool's usage."""

    def __init__(self, flash, inputs=0x029, busy_responses=0):
        self.flash = flash
        self.inputs = inputs
        self.busy_responses = busy_responses
        self.responses = deque()
        self.serial = "0000000001"
        self.path = "/dev/fake-hidraw"

        self.designations = [0] * 9
        self.chip_out = 0x0000
        self.chip_dir = 0x01FF
        self.other = 0x00
        self.live_dir = 0x01FF
        self.live_out = 0x0000
        self.access = 0x00

        self.spi = m.SpiSettings(1_000_000, 0x01FF, 0x01FE, 0, 0, 0, 4, 0)
        self.tx = None
        self.tx_done = True
        self.transactions = 0
        self.gpio_writes = []

    # -- transport ------------------------------------------------------

    def write(self, data):
        if len(data) == 65 and data[0] == 0:
            data = data[1:]
        if len(data) != 64:
            raise AssertionError("sim got a {}-byte report".format(len(data)))
        req = bytes(data)
        cmd = req[0]
        resp = bytearray(64)
        resp[0] = cmd
        resp[1] = 0x00

        if cmd == 0x10:  # get status
            pass
        elif cmd == 0x20:  # get GPIO settings
            resp[2] = 14
            resp[3] = 0
            resp[4:13] = bytes(self.designations)
            struct.pack_into("<H", resp, 13, self.chip_out)
            struct.pack_into("<H", resp, 15, self.chip_dir)
            resp[17] = self.other
            resp[18] = self.access
        elif cmd == 0x21:  # set GPIO settings
            self.designations = list(req[4:13])
            self.chip_out = struct.unpack_from("<H", req, 13)[0]
            self.chip_dir = struct.unpack_from("<H", req, 15)[0]
            self.other = req[17]
            self.live_dir = self.chip_dir
            self.gpio_writes.append(("chip", self.chip_out, self.chip_dir))
        elif cmd == 0x30:  # set live GPIO values
            self.live_out = struct.unpack_from("<H", req, 4)[0] & 0x1FF
            self.gpio_writes.append(("live", self.live_out, self.live_dir))
        elif cmd == 0x31:  # get live GPIO values
            value = (self.live_out & ~self.live_dir) | (self.inputs & self.live_dir)
            struct.pack_into("<H", resp, 4, value & 0x1FF)
        elif cmd == 0x32:  # set live direction
            self.live_dir = struct.unpack_from("<H", req, 4)[0] & 0x1FF
        elif cmd == 0x33:  # get live direction
            struct.pack_into("<H", resp, 4, self.live_dir & 0x1FF)
        elif cmd == 0x41:  # get SPI settings
            resp[2] = 17
            resp[4:21] = self.spi.pack()
        elif cmd == 0x40:  # set SPI settings
            self.spi = m.SpiSettings.unpack(req[4:21])
            resp[4:21] = req[4:21]
        elif cmd == 0x42:  # SPI transfer
            self._spi_xfer(req, resp)
        elif cmd in (0x11, 0x80):
            pass
        else:
            resp[1] = 0xF9
        self.responses.append(bytes(resp))

    def read(self, timeout):
        if self.responses:
            return self.responses.popleft()
        return b""

    def close(self):
        pass

    # -- SPI engine -----------------------------------------------------

    def _selected(self):
        cs_pins = [i for i, d in enumerate(self.designations) if d == 1]
        if not cs_pins:
            # manual GPIO CS: the first GPIO output that is low selects
            return any(not (self.live_dir & (1 << i)) and not (self.live_out & (1 << i))
                       for i in range(9))
        for pin in cs_pins:
            if (self.spi.idle_cs >> pin) & 1 != 1:
                return False
            if (self.spi.active_cs >> pin) & 1 != 0:
                return False
        return True

    def _new_miso(self, old_len):
        stream = self.tx
        out = bytearray(b"\xff" * (len(stream) - old_len))
        if not stream:
            return bytes(out)
        cmd = stream[0]
        if cmd == 0x03 and len(stream) >= 4:
            addr = (stream[1] << 16) | (stream[2] << 8) | stream[3]
            for i in range(max(4, old_len), len(stream)):
                pos = addr + i - 4
                if pos < len(self.flash.mem):
                    out[i - old_len] = self.flash.mem[pos]
        elif cmd == 0x9F:
            for i in range(old_len, len(stream)):
                if 1 <= i <= 3:
                    out[i - old_len] = self.flash.JEDEC[i - 1]
        elif cmd == 0x05:
            if old_len <= 1 < len(stream):
                out[1 - old_len] = self.flash.status()
        return bytes(out)

    def _spi_xfer(self, req, resp):
        count = req[1]
        data = req[4:4 + count]
        if self.busy_responses:
            self.busy_responses -= 1
            resp[1] = 0xF8
            return
        if self.tx is None or self.tx_done:
            self.tx = bytearray()
            self.tx_done = False
            self.transactions += 1
        if len(self.tx) + len(data) > self.spi.xfer_size:
            resp[1] = 0xF7
            return
        old_len = len(self.tx)
        self.tx += data
        if self._selected():
            new_miso = self._new_miso(old_len)
        else:
            new_miso = b"\xff" * len(data)
        if len(self.tx) == self.spi.xfer_size:
            if self._selected():
                self.flash.execute(self.tx)
            self.tx_done = True
            engine = m.SPI_ENGINE_FINISHED
        else:
            engine = m.SPI_ENGINE_DATA_AVAILABLE
        resp[2] = len(new_miso)
        resp[3] = engine
        resp[4:4 + len(new_miso)] = new_miso


class QuietLogger(m.Logger):
    def __init__(self):
        super().__init__(path=None, debug=False, quiet=True)


NPU = {"mode": "hold", "hold": 0xFFD7, "release": 0xFFFF, "mask": 0x0029}


def make_nor(flash=None, **kwargs):
    flash = flash or flash_with_reference()
    transport = SimMcpTransport(flash)
    log = QuietLogger()
    nor = m.SpiNor(transport and m.Mcp2210(transport, log), log,
                   cs_pin=kwargs.pop("cs_pin", 0),
                   cs_mode=kwargs.pop("cs_mode", "internal"),
                   speed=kwargs.pop("speed", 1_000_000),
                   npu=kwargs.pop("npu", NPU),
                   **kwargs)
    nor.open(require_chip=True)
    return nor, transport, flash


class EnvTests(unittest.TestCase):
    def test_reference_text_rebuilds_byte_exact_image(self):
        with gzip.open(os.path.join(REPO, "reference", "mtd", "npu-mtd1-env.bin.gz"), "rb") as fh:
            reference = fh.read()
        items = reference_env_items()
        self.assertEqual(m.build_env_image(items), reference)
        self.assertEqual(len(items), 26)

    def test_env_set_keeps_everything_else(self):
        items = reference_env_items()
        old = dict(items)
        items[b"bootcmd"] = b"run bootcmd_emmc2"
        image = m.build_env_image(items)
        parsed, stored, calc, _ = m.load_env_image(image)
        self.assertEqual(stored, calc)
        self.assertEqual(parsed[b"bootcmd"], b"run bootcmd_emmc2")
        for key, value in old.items():
            if key != b"bootcmd":
                self.assertEqual(parsed[key], value)

    def test_bad_crc_is_detected(self):
        image = bytearray(sim_env_image())
        image[0] ^= 0xFF
        with self.assertRaises(m.ToolError):
            m.load_env_image(bytes(image))
        items, stored, calc, _ = m.load_env_image(bytes(image), strict_crc=False)
        self.assertNotEqual(stored, calc)
        self.assertIn(b"bootcmd", items)

    def test_reference_env_is_redacted(self):
        self.assertTrue(m.mac_is_placeholder(reference_env_items()))

    def test_env_text_rejects_bad_lines(self):
        with self.assertRaises(m.ToolError):
            m.parse_env_text(b"bootcmd=x\nnonsense\n")
        with self.assertRaises(m.ToolError):
            m.parse_env_text(b"a=1\na=2\n")


class SimTests(unittest.TestCase):
    def test_read_id_and_status(self):
        nor, transport, flash = make_nor()
        try:
            self.assertEqual(nor.read_id(), flash.JEDEC)
            self.assertEqual(nor.read_status() & m.SR_WIP, 0)
            # the NPU hold was applied and GP0 is the CS
            self.assertEqual(transport.live_out & m.NPU_MASK, 0x01)
            self.assertEqual(transport.designations[0], 1)
        finally:
            nor.close()
        self.assertEqual(transport.live_out & m.NPU_MASK, 0x29)

    def test_dump_two_passes_and_verify(self):
        nor, transport, flash = make_nor()
        log = QuietLogger()
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "npu-nor.bin")
            session = m.NorSession(nor, log, reference_uboot(), None)
            backup = session.dump(out, passes=2, progress=False)
            self.assertEqual(backup.data, bytes(flash.mem))
            self.assertTrue(backup.manifest["verified"])
            self.assertEqual(backup.manifest["passes"], 2)
            self.assertEqual(backup.sha, m.sha256_hex(backup.data))
            self.assertTrue(os.path.exists(out + ".json"))
            self.assertTrue(os.path.exists(out + ".sha256"))
            loaded = m.Backup.load(out, require_manifest=True)
            self.assertEqual(loaded.sha, backup.sha)
            session.verify_backup(loaded, full=True, progress=False)
        nor.close()

    def test_dump_refuses_to_overwrite(self):
        nor, transport, flash = make_nor()
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "npu-nor.bin")
            session = m.NorSession(nor, QuietLogger(), reference_uboot(), None)
            session.dump(out, passes=1, progress=False)
            with self.assertRaises(m.ToolError):
                session.dump(out, passes=1, progress=False)
        nor.close()

    def test_flash_write_region_repairs_a_corrupt_env(self):
        # env 坏到连备份都解析不了时，env-write 会拒绝启动（先有鸡先有蛋）；
        # flash-write 是那条路的出口，它只认显式区间，所以必须自己守住 mtd0。
        nor, transport, flash = make_nor()
        oracle = bytes(flash.mem)
        image = m.build_env_image(reference_env_items())
        flash.mem[m.ENV_OFFSET:m.ENV_OFFSET + m.ENV_SIZE] = b"\xA5" * m.ENV_SIZE
        session = m.NorSession(nor, QuietLogger(), None, None)
        ok = session.write_region(image, m.ENV_OFFSET,
                                  commit=True, yes=True, progress=False)
        self.assertTrue(ok)
        self.assertEqual(bytes(flash.mem[m.ENV_OFFSET:m.ENV_OFFSET + m.ENV_SIZE]), image)
        self.assertEqual(bytes(flash.mem[:m.UBOOT_OFFSET + m.UBOOT_SIZE]),
                         oracle[:m.UBOOT_OFFSET + m.UBOOT_SIZE])
        nor.close()

    def test_flash_write_region_refuses_bad_ranges(self):
        nor, transport, flash = make_nor()
        oracle = bytes(flash.mem)
        session = m.NorSession(nor, QuietLogger(), None, None)
        image = m.build_env_image(reference_env_items())
        with self.assertRaises(m.SafetyError):          # 没有 64 KiB 对齐
            session.write_region(image, 0x3F0800, commit=True, yes=True, progress=False)
        with self.assertRaises(m.SafetyError):          # 压到 mtd0 上，且没 acknowledge
            session.write_region(image, 0x3E0000, commit=True, yes=True, progress=False)
        with self.assertRaises(m.SafetyError):          # 超出芯片末尾
            session.write_region(image, m.FLASH_SIZE, commit=True, yes=True, progress=False)
        with self.assertRaises(m.SafetyError):          # 长度必须是 64 KiB 的整数倍
            session.write_region(image[:-1], m.ENV_OFFSET,
                                 commit=True, yes=True, progress=False)
        self.assertEqual(bytes(flash.mem), oracle)
        self.assertFalse(session.write_region(image, m.ENV_OFFSET, commit=False, progress=False))
        self.assertEqual(bytes(flash.mem), oracle)
        nor.close()

    def test_env_write_only_touches_env(self):
        nor, transport, flash = make_nor()
        oracle = bytes(flash.mem)
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "npu-nor.bin")
            session = m.NorSession(nor, QuietLogger(), reference_uboot(), None)
            backup = session.dump(out, passes=2, progress=False)
            items = reference_env_items()
            items[b"ethaddr"] = b"02:00:00:00:00:01"
            items[b"bootcmd"] = b"run bootcmd_emmc2"
            image = m.build_env_image(items)
            flash.writes.clear()
            ok = session.write_env(backup, image, commit=True, yes=True, progress=False)
            self.assertTrue(ok)
            self.assertEqual(bytes(flash.mem[:m.UBOOT_OFFSET + m.UBOOT_SIZE]),
                             oracle[:m.UBOOT_OFFSET + m.UBOOT_SIZE])
            self.assertEqual(bytes(flash.mem[m.ENV_OFFSET:m.ENV_OFFSET + m.ENV_SIZE]), image)
            self.assertTrue(flash.writes)
            for op, addr, length in flash.writes:
                self.assertGreaterEqual(addr, m.ENV_OFFSET)
                self.assertLessEqual(addr + length, m.ENV_OFFSET + m.ENV_SIZE)
            parsed, stored, calc, _ = m.load_env_image(
                bytes(flash.mem[m.ENV_OFFSET:m.ENV_OFFSET + m.ENV_SIZE]))
            self.assertEqual(stored, calc)
            self.assertEqual(parsed[b"bootcmd"], b"run bootcmd_emmc2")
            self.assertEqual(parsed[b"ethaddr"], b"02:00:00:00:00:01")
        nor.close()

    def test_env_write_dry_run_writes_nothing(self):
        nor, transport, flash = make_nor()
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "npu-nor.bin")
            session = m.NorSession(nor, QuietLogger(), reference_uboot(), None)
            backup = session.dump(out, passes=2, progress=False)
            items = reference_env_items()
            items[b"ethaddr"] = b"02:00:00:00:00:01"
            items[b"bootcmd"] = b"run bootcmd_emmc2"
            image = m.build_env_image(items)
            flash.writes.clear()
            self.assertFalse(session.write_env(backup, image, commit=False, progress=False))
            self.assertEqual(flash.writes, [])
        nor.close()

    def test_env_write_refuses_without_manifest(self):
        nor, transport, flash = make_nor()
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "npu-nor.bin")
            session = m.NorSession(nor, QuietLogger(), reference_uboot(), None)
            session.dump(out, passes=2, progress=False)
            os.unlink(out + ".json")
            with self.assertRaises(m.SafetyError):
                m.Backup.load(out, require_manifest=True)
        nor.close()

    def test_env_write_refuses_unverified_backup(self):
        nor, transport, flash = make_nor()
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "npu-nor.bin")
            session = m.NorSession(nor, QuietLogger(), reference_uboot(), None)
            backup = session.dump(out, passes=1, progress=False)
            with self.assertRaises(m.SafetyError):
                backup.require_verified()
        nor.close()

    def test_env_write_refuses_stale_backup(self):
        nor, transport, flash = make_nor()
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "npu-nor.bin")
            session = m.NorSession(nor, QuietLogger(), reference_uboot(), None)
            backup = session.dump(out, passes=2, progress=False)
            items = reference_env_items()
            items[b"ethaddr"] = b"02:00:00:00:00:01"
            items[b"bootcmd"] = b"run bootcmd_emmc2"
            image = m.build_env_image(items)
            flash.mem[m.ENV_OFFSET] ^= 0xFF
            with self.assertRaises(m.SafetyError):
                session.write_env(backup, image, commit=True, yes=True, progress=False)
        nor.close()

    def test_env_write_refuses_uboot_mismatch(self):
        flash = flash_with_reference()
        flash.mem[0x100] ^= 0xFF
        nor, transport, flash = make_nor(flash)
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "npu-nor.bin")
            session = m.NorSession(nor, QuietLogger(), reference_uboot(), None)
            backup = session.dump(out, passes=2, progress=False)
            items = reference_env_items()
            items[b"ethaddr"] = b"02:00:00:00:00:01"
            items[b"bootcmd"] = b"run bootcmd_emmc2"
            image = m.build_env_image(items)
            with self.assertRaises(m.SafetyError):
                session.write_env(backup, image, commit=True, yes=True, progress=False)
            # explicit override allows the plan (still dry-run)
            self.assertFalse(session.write_env(backup, image, commit=False,
                                               allow_uboot_mismatch=True, progress=False))
        nor.close()

    def test_env_write_expected_uboot_sha(self):
        nor, transport, flash = make_nor()
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "npu-nor.bin")
            session = m.NorSession(nor, QuietLogger(), reference_uboot(), None)
            backup = session.dump(out, passes=2, progress=False)
            good = m.sha256_hex(backup.data[:m.UBOOT_SIZE])
            items = reference_env_items()
            items[b"ethaddr"] = b"02:00:00:00:00:01"
            items[b"bootcmd"] = b"run bootcmd_emmc2"
            image = m.build_env_image(items)
            # no reference file, but the expected SHA is enough for the plan
            plan_only = m.NorSession(nor, QuietLogger(), None, None)
            self.assertFalse(plan_only.write_env(
                backup, image, commit=False, expected_uboot_sha256=good, progress=False))
            with self.assertRaises(m.SafetyError):
                plan_only.write_env(backup, image, commit=False,
                                    expected_uboot_sha256="00" * 32, progress=False)
        nor.close()

    def test_env_write_refuses_placeholder_mac(self):
        nor, transport, flash = make_nor()
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "npu-nor.bin")
            session = m.NorSession(nor, QuietLogger(), reference_uboot(), None)
            backup = session.dump(out, passes=2, progress=False)
            items = reference_env_items()  # ethaddr is xx:xx:xx
            items[b"bootcmd"] = b"run bootcmd_emmc2"
            image = m.build_env_image(items)
            with self.assertRaises(m.SafetyError):
                session.write_env(backup, image, commit=False, progress=False)
        nor.close()

    def test_env_write_refuses_block_protect(self):
        flash = flash_with_reference()
        flash.bp = 0x04
        nor, transport, flash = make_nor(flash)
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "npu-nor.bin")
            session = m.NorSession(nor, QuietLogger(), reference_uboot(), None)
            backup = session.dump(out, passes=2, progress=False)
            items = reference_env_items()
            items[b"ethaddr"] = b"02:00:00:00:00:01"
            items[b"bootcmd"] = b"run bootcmd_emmc2"
            image = m.build_env_image(items)
            with self.assertRaises(m.SafetyError):
                session.write_env(backup, image, commit=True, yes=True, progress=False)
            flash.writes.clear()
            ok = session.write_env(backup, image, commit=True, yes=True,
                                   clear_bp=True, progress=False)
            self.assertTrue(ok)
            self.assertEqual(flash.bp, 0)
        nor.close()

    def test_env_write_noop_when_image_matches(self):
        nor, transport, flash = make_nor()
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "npu-nor.bin")
            session = m.NorSession(nor, QuietLogger(), reference_uboot(), None)
            backup = session.dump(out, passes=2, progress=False)
            flash.writes.clear()
            self.assertFalse(session.write_env(backup, backup.env_image(),
                                               commit=True, yes=True, progress=False))
            self.assertEqual(flash.writes, [])
        nor.close()

    def test_mtd0_restore_rewrites_only_damaged_blocks(self):
        flash = flash_with_reference()
        flash.mem[0:0x100] = b"\x5a" * 0x100          # damage block 0 only
        nor, transport, flash = make_nor(flash)
        env_before = bytes(flash.mem[m.ENV_OFFSET:m.ENV_OFFSET + m.ENV_SIZE])
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "npu-nor.bin")
            session = m.NorSession(nor, QuietLogger(), reference_uboot(), None)
            backup = session.dump(out, passes=2, progress=False)
            flash.writes.clear()
            ok = session.restore_mtd0(backup, reference_uboot(), commit=True, yes=True,
                                      acknowledge=True, progress=False)
            self.assertTrue(ok)
            self.assertEqual(bytes(flash.mem[:m.UBOOT_SIZE]), reference_uboot())
            self.assertEqual(
                bytes(flash.mem[m.ENV_OFFSET:m.ENV_OFFSET + m.ENV_SIZE]), env_before)
            self.assertTrue(flash.writes)
            for op, addr, length in flash.writes:
                self.assertLess(addr + length, m.ENV_OFFSET)
        nor.close()

    def test_mtd0_restore_needs_explicit_acknowledgement(self):
        flash = flash_with_reference()
        flash.mem[0x40] ^= 0xFF
        nor, transport, flash = make_nor(flash)
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "npu-nor.bin")
            session = m.NorSession(nor, QuietLogger(), reference_uboot(), None)
            backup = session.dump(out, passes=2, progress=False)
            flash.writes.clear()
            self.assertFalse(session.restore_mtd0(backup, reference_uboot(),
                                                 commit=True, yes=True, progress=False))
            self.assertEqual(flash.writes, [])
        nor.close()

    def test_mtd0_restore_rejects_wrong_image_size(self):
        nor, transport, flash = make_nor()
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "npu-nor.bin")
            session = m.NorSession(nor, QuietLogger(), reference_uboot(), None)
            backup = session.dump(out, passes=2, progress=False)
            with self.assertRaises(m.SafetyError):
                session.restore_mtd0(backup, b"\x00" * 0x1000, commit=True, yes=True,
                                     acknowledge=True, progress=False)
        nor.close()

    def test_mtd0_restore_refuses_stale_backup(self):
        flash = flash_with_reference()
        nor, transport, flash = make_nor(flash)
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "npu-nor.bin")
            session = m.NorSession(nor, QuietLogger(), reference_uboot(), None)
            backup = session.dump(out, passes=2, progress=False)
            flash.mem[0x200] ^= 0xFF                # chip moves after the backup
            flash.writes.clear()
            with self.assertRaises(m.SafetyError):
                session.restore_mtd0(backup, reference_uboot(), commit=True, yes=True,
                                     acknowledge=True, progress=False)
            self.assertEqual(flash.writes, [])
            ok = session.restore_mtd0(backup, reference_uboot(), commit=True, yes=True,
                                      acknowledge=True, allow_mismatch=True, progress=False)
            self.assertTrue(ok)
            self.assertEqual(bytes(flash.mem[:m.UBOOT_SIZE]), reference_uboot())
        nor.close()

    def test_busy_retries(self):
        nor, transport, flash = make_nor()
        transport.busy_responses = 3
        try:
            self.assertEqual(nor.read_status() & m.SR_WIP, 0)
        finally:
            nor.close()

    def test_manual_gpio_cs(self):
        nor, transport, flash = make_nor(cs_mode="gpio", cs_pin=0)
        try:
            self.assertEqual(nor.read_id(), flash.JEDEC)
            self.assertEqual(transport.designations[0], 0)
        finally:
            nor.close()

    def test_unexpected_chip_is_rejected(self):
        flash = flash_with_reference()
        flash.JEDEC = b"\xef\x40\x17"  # W25Q64
        transport = SimMcpTransport(flash)
        log = QuietLogger()
        nor = m.SpiNor(m.Mcp2210(transport, log), log, cs_pin=0, npu=NPU)
        with self.assertRaises(m.ToolError):
            nor.open(require_chip=True)
        nor.close()


class CliTests(unittest.TestCase):
    def test_env_build_from_text_and_compare(self):
        with tempfile.TemporaryDirectory() as tmp:
            env_out = os.path.join(tmp, "env.bin")
            rc = m.main(["env-build",
                         "--from-text", os.path.join(REPO, "reference", "uboot-env.txt"),
                         "--out", env_out,
                         "--allow-redacted",
                         "--set", "bootcmd=run bootcmd_emmc2"])
            self.assertEqual(rc, 0)
            with open(env_out, "rb") as fh:
                items, stored, calc, _ = m.load_env_image(fh.read())
            self.assertEqual(stored, calc)
            self.assertEqual(items[b"bootcmd"], b"run bootcmd_emmc2")

            # A dump built from the reference images must compare clean.
            dump = os.path.join(tmp, "dump.bin")
            flash = flash_with_reference()
            transport = SimMcpTransport(flash)
            log = QuietLogger()
            nor = m.SpiNor(m.Mcp2210(transport, log), log, cs_pin=0, npu=NPU)
            nor.open(require_chip=True)
            try:
                m.NorSession(nor, log, reference_uboot(), None).dump(
                    dump, passes=1, progress=False)
            finally:
                nor.close()
            rc = m.main(["compare", "--dump", dump,
                         "--reference-uboot", os.path.join(REPO, "reference", "mtd",
                                                           "npu-mtd0-uboot.bin.gz"),
                         "--reference-env", os.path.join(REPO, "reference", "mtd",
                                                         "npu-mtd1-env.bin.gz")])
            self.assertEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
