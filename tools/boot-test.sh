#!/bin/sh
# Boot the assembled image and drive it from a script of key presses.
#
#     ./tools/boot-test.sh <keys-file> <screenshot.ppm>
#
# `IMG` is the image to boot and `RUNDIR` where the emulator's sockets and log
# go, so that two boots — an ext2 one and an ext4 one — can run at once.
# `ISO` is a disc to boot from instead: with it, `IMG` is a disk to have
# attached as well — the one an installer installs onto — and there is no
# disk at all if `IMG` is not said.
# `CPU` is the processor to emulate: `max` unless said otherwise, which has SMEP
# and SMAP. `CPU=qemu64` has neither, and is how the kernel is tried on a
# machine where it cannot turn them on.
# `SMP` is how many processors the machine has: one unless said otherwise.
# `IOMMU=1` gives it Intel's IOMMU (`-device intel-iommu`), which wants QEMU's
# q35 chipset — a machine with no disk on the old IDE ports, so it is for a
# system that runs from memory: the live ISO.
# `VIRTIO=1` puts the disk on virtio (`virtio-blk-pci`) where it would be on
# the IDE ports, and the network card with it (`virtio-net-pci`) where the
# RTL8139 would be: the devices a virtual machine is usually given, each
# with a driver the device manager starts for it.
# `MEM` is how much memory: a gigabyte unless said otherwise. `MEM=6G` is a
# machine with memory above four gigabytes, which is a different machine to
# start on: the firmware loads the bootloader up there, the kernel has more
# to map than its first map holds, and a device that is told an address in
# thirty-two bits has to be given memory it can reach.
#
# The machine also has QEMU's `edu` device in it: a device with nothing to
# do but be driven, whose registers are memory at an address the firmware
# chose and whose interrupt is a message of its own. The device manager
# starts its driver where the image has it (`/usr/lib/drivers`, in the
# `tests` package), and then `dtest msi` has a device to ask about.
# `dtest pressure` wants the image to have started something too: `swapd`,
# with a file to write memory out to (`start /usr/bin/swapd /var/swap 16`).
#
# Verification here is boot-in-QEMU: user-space `println!` goes to the
# framebuffer and not to serial, so a screendump is the output and serial only
# catches kernel faults. The text console's screen can be read back as text
# (`tools/screentext.py`), which is what a script's `expect`, `text` and
# `transcript` lines do: wait for a prompt, and keep what was printed.
#
# Exits 1 if an `expect` gave up or the kernel faulted.
#
# Two things worth not rediscovering:
#
#  - Never kill the emulator by matching its name. Any shell whose command line
#    mentions it matches too, including the one running this, and `[q]emu` does
#    not help when the literal name appears in the file. Kill by pid.
#  - The timing lives inside the Python driver rather than in this shell,
#    because a foreground `sleep` in an agent's tool call can be blocked.
#  - No `set -e`. Half of what this does is tidying up after a previous run
#    that may not have happened, and a `[ -f pidfile ] && kill` whose test
#    fails is enough to end the script before it starts the emulator.
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
RUN=${RUNDIR:-${TMPDIR:-/tmp}/quark-boot-test}
# A disk on the IDE ports, or on virtio.
disk() {
    if [ -n "$VIRTIO" ]; then
        echo "-drive file=$1,if=none,id=disk0,format=raw -device virtio-blk-pci,drive=disk0"
    else
        echo "-hda $1"
    fi
}
if [ -n "$ISO" ]; then
    DRIVES="-cdrom $ISO"
    [ -n "$IMG" ] && DRIVES="$DRIVES $(disk "$IMG")"
else
    DRIVES=$(disk "${IMG:-hdimage.bin}")
fi
NIC=rtl8139
[ -n "$VIRTIO" ] && NIC=virtio-net-pci
mkdir -p "$RUN"
CHIPSET=${CHIPSET:-}
if [ -n "$IOMMU" ]; then
    # The IOMMU first: the devices after it are behind it.
    CHIPSET="-machine q35 -device intel-iommu"
fi

[ -f "$RUN/qemu.pid" ] && kill "$(cat "$RUN/qemu.pid")" 2>/dev/null
rm -f "$RUN/qmp.sock" "$RUN/serial.log" "$2"

cd "$TOP"
# The firmware writes its variable store, and the one in bang is tracked. Boot
# from a copy, so a test run does not leave the bootloader repository dirty.
cp ../bang/firmware-redist/ovmf/OVMF_VARS.fd "$RUN/OVMF_VARS.fd"
# Something on the network to talk to: an echo server on this machine's
# loopback, which the guest's user-mode network shows as 10.0.2.2:7007.
# One, for every run there is at once: started if nothing is listening —
# one that finds the port taken ends by itself — and left running, in a
# session of its own. A run that started one and stopped it when it ended
# was stopping the one the run beside it was using: the port is one port.
(setsid python3 "$HERE/echo-server.py" 7007 >/dev/null 2>&1 &)
# -m 1G for the reason the Makefile gives: a toolkit-linked program is tens of
# megabytes and is in memory twice while it is being started.
qemu-system-x86_64 $(test -w /dev/kvm && echo -enable-kvm) -cpu "${CPU:-max}" -smp "${SMP:-1}" -m "${MEM:-1G}" $CHIPSET \
  -L ../bang/firmware-redist/ovmf/ \
  -pflash ../bang/firmware-redist/ovmf/OVMF_CODE.fd \
  -pflash "$RUN/OVMF_VARS.fd" \
  $DRIVES -display none \
  -device $NIC,netdev=n -netdev user,id=n \
  -device edu \
  -qmp unix:"$RUN/qmp.sock",server,nowait \
  -serial file:"$RUN/serial.log" 2>/dev/null &
echo $! > "$RUN/qemu.pid"

# The script's `expect` lines are the test: one that gave up is a failure, and
# so is a fault in the kernel. Both are reported after the tidying up.
status=0
python3 "$HERE/drive-qemu.py" "$RUN/qmp.sock" "$1" || status=1
kill "$(cat "$RUN/qemu.pid")" 2>/dev/null || true
rm -f "$RUN/qemu.pid"

if grep -aq "KFAULT\|PANIC" "$RUN/serial.log" 2>/dev/null; then
    echo "KERNEL FAULT:"
    grep -a "KFAULT\|PANIC" "$RUN/serial.log"
    status=1
fi
echo "serial: $RUN/serial.log"
exit $status
