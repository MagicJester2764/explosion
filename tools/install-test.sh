#!/bin/sh
# Install ExplOSion the way docs/install.md says to, and start what was
# installed.
#
#     tools/install-test.sh [<megabytes>]
#
# Needs explosion.iso (`make iso`). A blank disk of <megabytes> (1024) is
# made, the ISO is booted with it attached, and every command the guide sets
# apart is typed, in order — the guide is the script, so a guide that has
# gone stale fails here rather than in front of somebody. Its last command
# restarts the machine; the disc is taken out, as the guide says to, and it
# comes up from the disk.
#
# Then the disk is booted with no ISO, and the system on it is asked what it
# is: its root, its packages, each file's checksum against what was built.
# And this machine's own tools look at what the guest's tools made — the
# partition table, the FAT filesystem and the ext4 one.
#
# RUNDIR is where the disk, the logs and the transcripts go; they are kept.
# (Keep it short: the emulator's control socket is in it, and a socket's
# path has a hundred characters to fit in.)
# Exits 1 if anything did not happen as the guide says.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
SIZE=${1:-1024}
RUN=${RUNDIR:-${TMPDIR:-/tmp}/explosion-install-test}
ISO_PATH=${ISO:-$TOP/explosion.iso}
DISK=$RUN/disk.img

[ -f "$ISO_PATH" ] || { echo "install-test: no $ISO_PATH; make iso" >&2; exit 1; }
mkdir -p "$RUN"
rm -f "$DISK"
truncate -s "${SIZE}M" "$DISK"

# The guide's commands: every line of every fenced block, in order.
python3 - "$TOP/docs/install.md" "$RUN" <<'PY'
import sys

guide, run = sys.argv[1:]
commands = []
fenced = False
for line in open(guide):
    line = line.rstrip("\n")
    if line.startswith("```"):
        fenced = not fenced
    elif fenced and line.strip():
        commands.append(line)

prompt = r"\$$"
# How long each is given: formatting and copying write a disk a sector at a
# time on a machine that is emulated.
slow = ("mkfs.", "qpkg strap", "bang-install")
keys = ["expect 240 ^login:$", r"type root\n", f"expect 60 {prompt}"]
for c in commands:
    keys.append(f"type {c}\\n")
    if c.startswith("shutdown -r"):
        # "Remove the installation disc when the machine restarts": it comes
        # up from the disk.
        keys += ["hmp eject -f ide1-cd0", "expect 300 ^login:$", r"type root\n", f"expect 60 {prompt}"]
    else:
        keys.append(f"expect {1800 if c.startswith(slow) else 120} {prompt}")
keys += [
    # What it restarted into is what was installed.
    r"type mount\n", f"expect 60 {prompt}",
    "saw ^/dev/disk0p2 on / type ext4",
    f"transcript {run}/install.txt",
    r"type shutdown\n", "off 120",
]
open(f"{run}/install.keys", "w").write("\n".join(keys) + "\n")

first = [
    "expect 240 ^login:$", r"type root\n", f"expect 60 {prompt}",
    r"type mount\n", f"expect 60 {prompt}",
    "saw ^/dev/disk0p2 on / type ext4",
    r"type disks\n", f"expect 60 {prompt}",
    r"type qpkg\n", f"expect 60 {prompt}",
    r"type qpkg verify\n", f"expect 600 {prompt}",
    "saw ^system: [0-9]+ files, as built$",
    "saw ^boot: [0-9]+ files, as built$",
    # And is somewhere to work: the first things anybody types. (A package
    # list once gave `ls` to the tests, and an installed system had none.)
    r"type ls /\n", f"expect 60 {prompt}",
    "saw ^usr/$",
    r"type echo it is installed\n", f"expect 60 {prompt}",
    "saw ^it is installed$",
    r"type qpkg owner /usr/bin/ls\n", f"expect 60 {prompt}",
    "saw ^/usr/bin/ls is from system$",
    f"transcript {run}/first-boot.txt",
    r"type shutdown\n", "off 120",
]
open(f"{run}/first-boot.keys", "w").write("\n".join(first) + "\n")
print(f"install-test: {len(commands)} commands from the guide")
PY

failed=0
echo "install-test: installing from the ISO onto a blank ${SIZE} MiB disk"
ISO=$ISO_PATH IMG=$DISK RUNDIR=$RUN/install sh "$HERE/boot-test.sh" "$RUN/install.keys" "$RUN/install.ppm" \
    > "$RUN/install.out" 2>&1 || failed=1
grep -E 'gave up|^saw:|^off:|FAULT' "$RUN/install.out" || true

echo "install-test: starting the installed disk, with no ISO"
IMG=$DISK RUNDIR=$RUN/first-boot sh "$HERE/boot-test.sh" "$RUN/first-boot.keys" "$RUN/first-boot.ppm" \
    > "$RUN/first-boot.out" 2>&1 || failed=1
grep -E 'gave up|^saw:|^off:|FAULT' "$RUN/first-boot.out" || true

# What the guest's tools made, as this machine's tools see it.
echo "install-test: checking the disk from here"
sfdisk --verify "$DISK" > "$RUN/sfdisk.out" 2>&1 || failed=1
grep -q 'No errors detected' "$RUN/sfdisk.out" || { cat "$RUN/sfdisk.out"; failed=1; }
python3 - "$DISK" "$RUN" <<'PY' || failed=1
import json
import subprocess
import sys

disk, run = sys.argv[1:]
table = json.loads(subprocess.check_output(["sfdisk", "-J", disk]))["partitiontable"]["partitions"]
ok = True
for i, part in enumerate(table):
    out = f"{run}/part{i + 1}.img"
    subprocess.check_call(["dd", f"if={disk}", f"of={out}", "bs=512", f"skip={part['start']}",
                           f"count={part['size']}", "status=none"])
    check = ["fsck.fat", "-n", out] if i == 0 else ["e2fsck", "-fn", out]
    done = subprocess.run(check, capture_output=True, text=True)
    print(f"  {' '.join(check[:2])} on partition {i + 1}: exit {done.returncode}")
    if done.returncode != 0:
        print(done.stdout + done.stderr)
        ok = False
sys.exit(0 if ok else 1)
PY

if [ "$failed" = 0 ]; then
    echo "install-test: passed; transcripts in $RUN"
else
    echo "install-test: FAILED; see $RUN"
fi
exit $failed
