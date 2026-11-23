#!/usr/bin/env python3
"""Redact serials, MACs and UUIDs from collected logs before publishing.

The values that point at one specific unit -- serial numbers, asset tags, the
local user name -- are deliberately NOT kept in this repository.  Put them in a
plain text file outside the tree (one literal per line, `#` comments allowed)
and pass it with --list:

    ./redact.py --list ~/xgs-private.txt COM5.log COM5.log.redacted

The patterns below are generic on purpose: they catch the two serial formats
these boards use, any MAC that is not part of the design, EUI-64 link-local
addresses, and UUIDs.
"""
import argparse
import re

# Addresses the repository itself assigns; they are not device identity.
KEEP_MACS = {
    "00:51:82:11:22:01", "00:51:82:11:22:02", "00:51:82:11:22:03",
    "00:51:82:11:22:04",          # stock U-Boot defaults
    "02:58:47:53:00:11", "02:58:47:53:00:31",  # xgs-ntb-up.sh VLAN MACs
    "02:00:00:00:00:01",          # documented netconsole listener
    "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff",
}


def load_literals(path):
    """One literal per line; blank lines and # comments are skipped."""
    if not path:
        return []
    with open(path, encoding="utf-8") as fh:
        return [line.strip() for line in fh
                if line.strip() and not line.lstrip().startswith("#")]


def redact(text: str, literals=()) -> str:
    for s in literals:
        text = text.replace(s, "<redacted>")
    text = re.sub(r"SEAAMDA0200-0001\d+", "SEAAMDA0200-<redacted>", text)
    text = re.sub(r"X01\d{10}", "X01<redacted>", text)

    def mac_sub(m):
        mac = m.group(0)
        return mac if mac.lower() in KEEP_MACS else "<redacted-mac>"

    text = re.sub(r"(?i)\b[0-9a-f]{2}(:[0-9a-f]{2}){5}\b", mac_sub, text)
    # EUI-64 link-local: the interface id of a MAC-derived address has ff:fe in it.
    text = re.sub(r"(?i)\bfe80:(:[0-9a-f]{0,4})*:[0-9a-f]{0,4}ff:fe[0-9a-f:]*\b",
                  "<redacted-ipv6>", text)
    # PCIe / DMI UUIDs and filesystem UUIDs
    text = re.sub(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b",
                  "<uuid>", text)
    text = re.sub(r"\b[0-9A-F]{4}-[0-9A-F]{4}\b(?=\s+/boot/efi)", "<efi-uuid>", text)
    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", help="file with extra literals to redact")
    ap.add_argument("src", help="input log ('-' for stdin)")
    ap.add_argument("dst", help="output file ('-' for stdout)")
    a = ap.parse_args()

    literals = load_literals(a.list)
    data = open(a.src, encoding="utf-8", errors="replace").read() \
        if a.src != "-" else __import__("sys").stdin.read()
    out = redact(data, literals)
    if a.dst == "-":
        print(out, end="")
    else:
        open(a.dst, "w", encoding="utf-8").write(out)
        print("redacted ->", a.dst)


if __name__ == "__main__":
    main()
