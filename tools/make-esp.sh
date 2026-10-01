#!/bin/sh
# Make an EFI system partition: the loader, the kernel it loads, and the
# modules it hands the kernel.
#
#     tools/make-esp.sh <image> <size-kb> <stage> <boot.img> [<file>:<NAME>...]
#
# <stage> has BOOTX64.EFI, kernel.bin and drivers/. <boot.img> goes in as a
# module beside them, and so does each <file>, under the 8.3 name after its
# colon: a module is whatever the bootloader finds in \drivers, and the name
# is how init tells one from another.
#
# The boot menu is written to match what goes into the image, so it never
# offers something that is not there. Anything beyond Quark is whatever this
# build host happened to have lying around, named in the environment:
# SHELL_EFI, a UEFI shell, to show that Bang can hand off to another EFI
# application at all — which is how it would reach a Windows boot manager —
# and LINUX_KERNEL (with INITRD beside it), to show the handover protocol
# working.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
IMG=${1:?usage: make-esp.sh <image> <size-kb> <stage> <boot.img> [<file>:<NAME>...]}
SIZE_KB=${2:?size in KiB}
STAGE=${3:?the stage directory}
BOOT_IMG=${4:?boot.img}
shift 4

dd if=/dev/zero of="$IMG" bs=1k count="$SIZE_KB" status=none
mformat -i "$IMG" ::
mmd -i "$IMG" ::/EFI
mmd -i "$IMG" ::/EFI/BOOT
mcopy -i "$IMG" "$STAGE/BOOTX64.EFI" ::/EFI/BOOT
mcopy -i "$IMG" "$STAGE/kernel.bin" ::/kernel.bin

cp "$HERE/../bang.cfg" "$STAGE/bang.cfg"
if [ -n "$SHELL_EFI" ] && [ -f "$SHELL_EFI" ]; then
    mmd -i "$IMG" ::/EFI/tools
    mcopy -i "$IMG" "$SHELL_EFI" ::/EFI/tools/Shell.efi
    printf '\nentry UEFI Shell\n    chainload \\EFI\\tools\\Shell.efi\n' >> "$STAGE/bang.cfg"
fi
if [ -n "$LINUX_KERNEL" ] && [ -f "$LINUX_KERNEL" ]; then
    mcopy -i "$IMG" "$LINUX_KERNEL" ::/vmlinuz
    printf '\nentry Linux\n    linux   \\vmlinuz\n' >> "$STAGE/bang.cfg"
    if [ -n "$INITRD" ] && [ -f "$INITRD" ]; then
        mcopy -i "$IMG" "$INITRD" ::/initrd.img
        printf '    initrd  \\initrd.img\n' >> "$STAGE/bang.cfg"
    fi
    printf '    options console=ttyS0 earlyprintk=serial,ttyS0 panic=5\n' >> "$STAGE/bang.cfg"
fi
mcopy -i "$IMG" "$STAGE/bang.cfg" ::/bang.cfg

mmd -i "$IMG" ::/drivers
for f in "$STAGE"/drivers/*; do
    mcopy -i "$IMG" "$f" ::/drivers/
done
mcopy -i "$IMG" "$BOOT_IMG" ::/drivers/boot.img
for extra in "$@"; do
    mcopy -i "$IMG" "${extra%%:*}" "::/drivers/${extra##*:}"
done
