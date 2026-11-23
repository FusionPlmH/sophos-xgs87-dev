#!/usr/bin/env python3
"""Redact serials, real MACs and UUIDs from collected logs before publishing."""
import re
import sys

SERIALS = [
    "<redacted-serial>",
    "<redacted-serial>",
    "<redacted-serial>",
]
KEEP_MACS = {"00:51:82:11:22:01", "00:51:82:11:22:02", "00:51:82:11:22:03",
             "00:51:82:11:22:04", "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff"}


def redact(text: str) -> str:
    for s in SERIALS:
        text = text.replace(s, "<redacted-serial>")
    text = re.sub(r"SEAAMDA0200-0001\d+", "SEAAMDA0200-<redacted>", text)
    text = re.sub(r"X01\d{10}", "X01<redacted>", text)

    def mac_sub(m):
        mac = m.group(0)
        if mac.lower() in KEEP_MACS:
            return mac
        parts = mac.split(":")
        return ":".join(parts[:3] + ["xx", "xx", "xx"])

    text = re.sub(r"(?i)\b[0-9a-f]{2}(:[0-9a-f]{2}){5}\b", mac_sub, text)
    # PCIe / DMI UUIDs and filesystem UUIDs
    text = re.sub(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b",
                  "<uuid>", text)
    text = re.sub(r"\b[0-9A-F]{4}-[0-9A-F]{4}\b(?=\s+/boot/efi)", "<efi-uuid>", text)
    text = text.replace("user@debian", "user@debian")
    return text


if __name__ == "__main__":
    src, dst = sys.argv[1], sys.argv[2]
    data = open(src, encoding="utf-8", errors="replace").read()
    open(dst, "w", encoding="utf-8").write(redact(data))
    print("redacted ->", dst)
