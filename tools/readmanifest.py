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

# Mirrors CAP_TYPE_* in quark-rt.
TYPES = {
    1: "ioport",
    2: "phys_range",
    3: "irq",
    4: "task_mgmt",
    5: "phys_alloc",
    6: "set_uid",
    7: "endpoint",
}


def describe(cap_type, p0, p1):
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
