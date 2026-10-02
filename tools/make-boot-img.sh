#!/bin/sh
# Make boot.img: a small FAT image of the services init starts before there
# is a root filesystem to read them from.
#
#     tools/make-boot-img.sh <stage-dir> <image> <size-kb>
#
# The bootloader hands it to the kernel as a module, and init reads the
# servers out of it. It is made while staging, because the root filesystem
# carries a copy: a system installs another by copying what it was started
# with.
set -e
STAGE=${1:?usage: make-boot-img.sh <stage-dir> <image> <size-kb>}
IMG=${2:?the image to make}
SIZE_KB=${3:?its size in KiB}
IMG=$(cd "$(dirname "$IMG")" && pwd)/$(basename "$IMG")
dd if=/dev/zero of="$IMG" bs=1k count="$SIZE_KB" status=none
mformat -i "$IMG" -F ::
cd "$STAGE/boot"
find . -type f | sort | while read -r f; do
    mcopy -i "$IMG" "$f" "::$f"
done
