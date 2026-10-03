#!/usr/bin/env python3
"""Where an image's EFI system partition begins, and which partition its root is.

    tools/gpt-root.py <image>

Prints two words: the byte the EFI system partition starts at, and the root
partition's own GUID — the first Linux filesystem partition's — the usual way,
as `root.cfg` names it (`root partuuid GUID`). The image's build writes that
into the EFI system partition inside the image, so that the root is found on
whichever disk has it.
"""
import struct
import sys
import uuid

ESP = uuid.UUID("c12a7328-f81f-11d2-ba4b-00a0c93ec93b")
LINUX = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4")

with open(sys.argv[1], "rb") as image:
    image.seek(512)
    header = image.read(92)
    if header[:8] != b"EFI PART":
        sys.exit("gpt-root: no GPT on " + sys.argv[1])
    entries, count, size = struct.unpack_from("<QII", header, 72)
    image.seek(entries * 512)
    table = image.read(count * size)
esp = root = None
for n in range(count):
    entry = table[n * size:(n + 1) * size]
    kind = uuid.UUID(bytes_le=entry[:16])
    first = struct.unpack_from("<Q", entry, 32)[0]
    if kind == ESP and esp is None:
        esp = first * 512
    elif kind == LINUX and root is None:
        root = uuid.UUID(bytes_le=entry[16:32])
if esp is None or root is None:
    sys.exit("gpt-root: no EFI system partition, or no root, on " + sys.argv[1])
print(esp, root)
