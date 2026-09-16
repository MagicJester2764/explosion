#!/bin/sh
# Check the root filesystem inside a disk image the way Linux would.
#
#     tools/check-rootfs.sh [hdimage.bin]
#
# The guest writes; e2fsck, off the host, says whether what it wrote is a
# filesystem. The root is the GPT's second partition.
set -e
IMG=${1:-hdimage.bin}
START=$(python3 - "$IMG" <<'PY'
import struct, sys
with open(sys.argv[1], 'rb') as f:
    f.seek(512)
    hdr = f.read(92)
    entries, count, size = struct.unpack_from('<QII', hdr, 72)
    f.seek(entries * 512 + size)          # the second entry
    first, last = struct.unpack_from('<QQ', f.read(size), 32)
    print(first, last - first + 1)
PY
)
set -- $START
PART=$(mktemp)
trap 'rm -f "$PART"' EXIT
dd if="$IMG" of="$PART" bs=512 skip="$1" count="$2" status=none
e2fsck -fn "$PART"
