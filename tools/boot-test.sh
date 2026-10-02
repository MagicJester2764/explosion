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
# `MEM` is how much memory: a gigabyte unless said otherwise. `MEM=6G` is a
# machine with memory above four gigabytes, which is a different machine to
# start on: the firmware loads the bootloader up there, the kernel has more
# to map than its first map holds, and a device that is told an address in
# thirty-two bits has to be given memory it can reach.
#
# The machine also has QEMU's `edu` device in it: a device with nothing to
# do but be driven, whose registers are memory at an address the firmware
# chose and whose interrupt is a message of its own. Nothing notices it
# unless the image starts its driver (`start /usr/bin/edu` in
# `/etc/init.conf`), and then `dtest msi` has a device to ask about.
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
if [ -n "$ISO" ]; then
    DRIVES="-cdrom $ISO"
    [ -n "$IMG" ] && DRIVES="$DRIVES -hda $IMG"
else
    DRIVES="-hda ${IMG:-hdimage.bin}"
fi
mkdir -p "$RUN"

[ -f "$RUN/qemu.pid" ] && kill "$(cat "$RUN/qemu.pid")" 2>/dev/null
rm -f "$RUN/qmp.sock" "$RUN/serial.log" "$2"

cd "$TOP"
# The firmware writes its variable store, and the one in bang is tracked. Boot
# from a copy, so a test run does not leave the bootloader repository dirty.
cp ../bang/firmware-redist/ovmf/OVMF_VARS.fd "$RUN/OVMF_VARS.fd"
# Something on the network to talk to: an echo server on this machine's
# loopback, which the guest's user-mode network shows as 10.0.2.2:7007.
[ -f "$RUN/echo.pid" ] && kill "$(cat "$RUN/echo.pid")" 2>/dev/null
python3 "$HERE/echo-server.py" 7007 >/dev/null 2>&1 &
echo $! > "$RUN/echo.pid"
# -m 1G for the reason the Makefile gives: a toolkit-linked program is tens of
# megabytes and is in memory twice while it is being started.
qemu-system-x86_64 $(test -w /dev/kvm && echo -enable-kvm) -cpu "${CPU:-max}" -smp "${SMP:-1}" -m "${MEM:-1G}" \
  -L ../bang/firmware-redist/ovmf/ \
  -pflash ../bang/firmware-redist/ovmf/OVMF_CODE.fd \
  -pflash "$RUN/OVMF_VARS.fd" \
  $DRIVES -display none \
  -device rtl8139,netdev=n -netdev user,id=n \
  -device edu \
  -qmp unix:"$RUN/qmp.sock",server,nowait \
  -serial file:"$RUN/serial.log" 2>/dev/null &
echo $! > "$RUN/qemu.pid"

# The script's `expect` lines are the test: one that gave up is a failure, and
# so is a fault in the kernel. Both are reported after the tidying up.
status=0
python3 "$HERE/drive-qemu.py" "$RUN/qmp.sock" "$1" || status=1
kill "$(cat "$RUN/qemu.pid")" 2>/dev/null || true
kill "$(cat "$RUN/echo.pid")" 2>/dev/null || true
rm -f "$RUN/qemu.pid" "$RUN/echo.pid"

if grep -aq "KFAULT\|PANIC" "$RUN/serial.log" 2>/dev/null; then
    echo "KERNEL FAULT:"
    grep -a "KFAULT\|PANIC" "$RUN/serial.log"
    status=1
fi
echo "serial: $RUN/serial.log"
exit $status
