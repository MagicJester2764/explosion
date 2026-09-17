#!/bin/sh
# Stop a machine while a program holds a removed file open, check the
# filesystem as the crash left it, boot it again, and check it after the
# server has recovered.
#
#     tools/crash-test.sh
#
# Runs on whatever image `make hd` or `make hd-ext4` last built. The first
# check is expected to find the removed file: it is still allocated, and the
# crash left it only on the orphan list. The last must be clean.
HERE=$(cd "$(dirname "$0")" && pwd)
RUN=${RUNDIR:-${TMPDIR:-/tmp}/quark-boot-test}
SCRIPT=$(mktemp)
trap 'rm -f "$SCRIPT"' EXIT
cat > "$SCRIPT" <<KEYS
sleep 16
type \\n
sleep 1
type root\\n
sleep 3
type dchild unlinked /tmp/crash-orphan\\n
sleep 4
shot $RUN/crash-1.ppm
quit
KEYS
sh "$HERE/boot-test.sh" "$SCRIPT" "$RUN/crash-1.ppm" >/dev/null
echo "== after the crash (the orphan is expected here):"
sh "$HERE/check-rootfs.sh" 2>&1 | tail -8
# What the server says about the orphans it frees goes to the screen, which
# is kept: user space never reaches the serial line.
cat > "$SCRIPT" <<KEYS
sleep 20
shot $RUN/crash-2.ppm
quit
KEYS
sh "$HERE/boot-test.sh" "$SCRIPT" "$RUN/crash-2.ppm" >/dev/null
echo "== the first boot's screen: $RUN/crash-1.ppm"
echo "== the second boot's screen: $RUN/crash-2.ppm"
echo "== after recovery:"
sh "$HERE/check-rootfs.sh"
