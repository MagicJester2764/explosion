#!/usr/bin/env python3
"""Read a Quark capability manifest out of a program image.

The manifest is a `.quark.manifest` section compiled into the binary. It is
found here the same way the spawner finds it at runtime — by scanning for the
magic — so this reports exactly what the system will grant, rather than a
description that could drift from it.

Exits 0 if a manifest was found and printed, 1 if the image has none.
"""

import struct
import sys

MAGIC = (0x46494E414D4B5251).to_bytes(8, "little")
VERSION = 1
HDR = 24
REQ = 24

# Mirrors CAP_TYPE_* in quark-rt. 7 was a set of task ids and was withdrawn;
# an endpoint is 8.
TYPES = {
    1: "ioport",
    2: "phys_range",
    3: "irq",
    4: "task_mgmt",
    5: "phys_alloc",
    6: "set_uid",
    8: "endpoint",
    9: "memobject",
    10: "device_memory",
    11: "clock",
    12: "power",
    13: "swap",
    14: "pci_device",
}

# Not a capability: a request to be scheduled in a band (PRIORITY_REQ in
# quark-rt's manifest module). A spawner applies it under the same narrowing
# rule, so it can give no better a band than it is in itself.
PRIORITY_REQ = 0x100
BANDS = {0: "driver", 1: "server", 2: "normal", 3: "idle"}

# Not a capability either: a device the program drives (MATCH_REQ), which
# the device manager starts it for, holding that device. Matched as
# `key & mask == value` over vendor << 48 | device << 32 | class code << 8.
MATCH_REQ = 0x101


def describe(cap_type, p0, p1):
    if cap_type == PRIORITY_REQ:
        return f"band {BANDS.get(p0, p0)}"
    if cap_type == MATCH_REQ:
        if p1 == 0xFFFFFFFF << 32:
            return f"drives {p0 >> 48:04x}:{(p0 >> 32) & 0xFFFF:04x}"
        width = 6 if p1 == 0xFFFFFF << 8 else 4
        return f"drives class {(p0 >> 8) >> (24 - width * 4):0{width}x}"
    name = TYPES.get(cap_type, f"type{cap_type}")
    if name == "ioport":
        return f"ioport 0x{p0:X}-0x{p1:X}"
    if name == "irq":
        return "irq any" if p0 == 0xFF else f"irq {p0}"
    if name == "phys_range":
        return f"phys_range 0x{p0:X}-0x{p1:X}"
    if name == "phys_alloc":
        return "phys_alloc unlimited" if p0 == 0 else f"phys_alloc {p0} pages"
    if name == "task_mgmt":
        return "task_mgmt any" if p0 == 0 else f"task_mgmt tid {p0}"
    if name == "pci_device":
        return "pci_device any" if p0 == 0xFFFFFFFF else f"pci_device {p0 >> 8:02x}:{(p0 >> 3) & 0x1F:02x}.{p0 & 7}"
    return name


def find(data):
    off = 0
    while off + HDR <= len(data):
        if data[off:off + 8] == MAGIC:
            version, count = struct.unpack_from("<QQ", data, off + 8)
            if version == VERSION and off + HDR + count * REQ <= len(data):
                return [
                    struct.unpack_from("<QQQ", data, off + HDR + i * REQ)
                    for i in range(count)
                ]
        off += 8
    return None


def find_all(data):
    """Every request in every manifest block of an image.

    An image is linked from several objects and any of them may declare
    what it needs — a C library does — so what a program is granted is the
    sum of its blocks, which is how a spawner reads it.
    """
    reqs = []
    off = 0
    while off + HDR <= len(data):
        if data[off:off + 8] == MAGIC:
            version, count = struct.unpack_from("<QQ", data, off + 8)
            if version == VERSION and off + HDR + count * REQ <= len(data):
                reqs += [
                    struct.unpack_from("<QQQ", data, off + HDR + i * REQ)
                    for i in range(count)
                ]
                off += HDR + count * REQ
                continue
        off += 8
    return reqs


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = sys.argv[1]
    label = sys.argv[2] if len(sys.argv) > 2 else path

    with open(path, "rb") as f:
        reqs = find(f.read())
    if not reqs:
        return 1

    print(f"  {label.lstrip('./')}:")
    for cap_type, p0, p1 in reqs:
        if cap_type == 0:
            continue
        print(f"    {describe(cap_type, p0, p1)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
