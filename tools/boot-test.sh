#!/bin/sh
# Boot the assembled image and drive it from a script of key presses.
#
#     ./tools/boot-test.sh <keys-file> <screenshot.ppm>
#
# `IMG` is the image to boot and `RUNDIR` where the emulator's sockets and log
# go, so that two boots — an ext2 one and an ext4 one — can run at once.
#
# Verification here is boot-in-QEMU: user-space `println!` goes to the
# framebuffer and not to serial, so a screendump is the output and serial only
# catches kernel faults.
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
IMG=${IMG:-hdimage.bin}
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
qemu-system-x86_64 $(test -w /dev/kvm && echo -enable-kvm) -cpu max -m 1G \
  -L ../bang/firmware-redist/ovmf/ \
  -pflash ../bang/firmware-redist/ovmf/OVMF_CODE.fd \
  -pflash "$RUN/OVMF_VARS.fd" \
  -hda "$IMG" -display none \
  -device rtl8139,netdev=n -netdev user,id=n \
  -qmp unix:"$RUN/qmp.sock",server,nowait \
  -serial file:"$RUN/serial.log" 2>/dev/null &
echo $! > "$RUN/qemu.pid"

python3 "$HERE/drive-qemu.py" "$RUN/qmp.sock" "$1" || true
kill "$(cat "$RUN/qemu.pid")" 2>/dev/null || true
kill "$(cat "$RUN/echo.pid")" 2>/dev/null || true
rm -f "$RUN/qemu.pid" "$RUN/echo.pid"

if grep -aq "KFAULT\|PANIC" "$RUN/serial.log" 2>/dev/null; then
    echo "KERNEL FAULT:"
    grep -a "KFAULT\|PANIC" "$RUN/serial.log"
fi
echo "serial: $RUN/serial.log"
