#!/bin/sh
# Boot the assembled image and drive it from a script of key presses.
#
#     ./tools/boot-test.sh <keys-file> <screenshot.ppm>
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
mkdir -p "$RUN"

[ -f "$RUN/qemu.pid" ] && kill "$(cat "$RUN/qemu.pid")" 2>/dev/null
rm -f "$RUN/qmp.sock" "$RUN/serial.log" "$2"

cd "$TOP"
qemu-system-x86_64 $(test -w /dev/kvm && echo -enable-kvm) -cpu max \
  -L ../bang/firmware-redist/ovmf/ \
  -pflash ../bang/firmware-redist/ovmf/OVMF_CODE.fd \
  -pflash ../bang/firmware-redist/ovmf/OVMF_VARS.fd \
  -hda hdimage.bin -display none \
  -qmp unix:"$RUN/qmp.sock",server,nowait \
  -serial file:"$RUN/serial.log" 2>/dev/null &
echo $! > "$RUN/qemu.pid"

python3 "$HERE/drive-qemu.py" "$RUN/qmp.sock" "$1" || true
kill "$(cat "$RUN/qemu.pid")" 2>/dev/null || true
rm -f "$RUN/qemu.pid"

if grep -aq "KFAULT\|PANIC" "$RUN/serial.log" 2>/dev/null; then
    echo "KERNEL FAULT:"
    grep -a "KFAULT\|PANIC" "$RUN/serial.log"
fi
echo "serial: $RUN/serial.log"
