#!/bin/sh
# Stop a machine in the middle of things, check the filesystem as the crash
# left it, boot it again, and check it after the server has recovered.
#
#     tools/crash-test.sh [<stops>]
#
# Runs on whatever image `make hd` or `make hd-ext4` last built (or `IMG`).
# Three things are on the disk when the machine is stopped:
#
#   - a file a program holds open and has removed. It is still allocated,
#     and the crash left it only on the orphan list.
#   - a file written and synced. It must be there, whole: a sync that has
#     answered has nothing left to lose.
#   - where there is a journal, a directory being changed for as long as the
#     machine runs — files written and cut short, renamed, removed,
#     directories made and taken away — so that it stops with a change half
#     recorded. Those may be anything; the filesystem may not.
#
# With a journal the machine is stopped <stops> times (24) before the last:
# held where it is, a moment apart, while a copy of its disk is recovered
# the way Linux would recover it — the journal replayed, the orphan cleared
# — and has to come out a clean filesystem with the synced file in it. The
# stop that matters is the one that finds a transaction committed to the
# journal and not yet written where it belongs, and many stops are how one
# is found: how many did is said, and the first such disk is kept and
# started, so that the file server's own replay is tried on it and not only
# e2fsck's.
#
# Then the machine is stopped for good, and the disk as that left it is
# recovered twice: by e2fsck, and — booting it — by the file server.
#
# And where there is a journal, one disk is not left to a stop to find: it is
# made, with debugfs, before the machine first starts. Its journal holds one
# committed transaction — a directory made, which moves the free counts and a
# group's descriptor — over the filesystem as it was before, with a removed
# file on the orphan list. The file server replays it and frees the orphan,
# and what it leaves has to be clean: a server that kept what it read before
# the replay wrote that back with the orphan, undid the transaction in the
# counts and left the new directory's inode and block free in the bitmaps.
#
# A machine started to recover a disk is quit at its login prompt, which can
# be between a transaction of the server's own — the system log writes as
# it starts — and that transaction's checkpoint: the bitmap in place, say,
# and the inode that owns the block it gives still only in the journal.
# That is a journal to replay, as a mount replays it, and not damage, and
# `e2fsck -n` cannot replay one. So what the server left in its journal is
# replayed first, with debugfs, which does nothing else — e2fsck would free
# the orphans the server should have — and only if it is the server's own:
# numbered past every transaction that was committed when it started, each
# of which was its to replay.
#
# Exits 1 if any recovery left damage or lost the synced file.
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
RUN=${RUNDIR:-${TMPDIR:-/tmp}/quark-boot-test}
IMG=${IMG:-$TOP/hdimage.bin}
export IMG

# The root, out of the image, into $PART: the GPT's second partition.
root_of() {
    python3 - "$IMG" "$PART" <<'PY'
import struct, sys
with open(sys.argv[1], 'rb') as f:
    f.seek(512)
    hdr = f.read(92)
    entries, count, size = struct.unpack_from('<QII', hdr, 72)
    f.seek(entries * 512 + size)
    first, last = struct.unpack_from('<QQ', f.read(size), 32)
    f.seek(first * 512)
    open(sys.argv[2], 'wb').write(f.read((last - first + 1) * 512))
PY
}
# Whether the synced file in it is what was written.
synced_file() {
    rm -f "$PART.got"
    debugfs -R "dump /tmp/crash-synced $PART.got" "$PART" >/dev/null 2>&1
    if cmp -s "$PART.got" "$PART.want"; then
        echo "   the synced file is whole: $(wc -c < "$PART.got") bytes, as written"
    else
        echo "   THE SYNCED FILE IS NOT WHAT WAS WRITTEN: $(wc -c < "$PART.got" 2>/dev/null || echo 0) bytes of $(wc -c < "$PART.want")"
        return 1
    fi
}
# The root of $IMG, from $PART, back where it came from.
root_to() {
    python3 - "$PART" "$1" <<'PY'
import struct, sys
with open(sys.argv[2], 'r+b') as f:
    f.seek(512)
    hdr = f.read(92)
    entries, count, size = struct.unpack_from('<QII', hdr, 72)
    f.seek(entries * 512 + size)
    first, last = struct.unpack_from('<QQ', f.read(size), 32)
    f.seek(first * 512)
    f.write(open(sys.argv[1], 'rb').read())
PY
}
# The number of the first transaction a file server that mounts the disk in
# $PART can write of its own: one past the last committed to its journal,
# which the server has to replay first, or where the journal stands when
# nothing is. 0 where there is no journal.
journal_next() {
    dumpe2fs -h "$PART" 2>/dev/null | grep -q has_journal || { echo 0; return; }
    last=
    if [ "$(dumpe2fs -h "$PART" 2>/dev/null | sed -n 's/^Journal start: *//p')" != 0 ]; then
        last=$(debugfs -R logdump "$PART" 2>/dev/null \
            | sed -n 's/^Found expected sequence \([0-9]*\), type 2 (commit block).*/\1/p' | tail -1)
    fi
    if [ -n "$last" ]; then
        echo $((last + 1))
    else
        echo $(($(dumpe2fs -h "$PART" 2>/dev/null | sed -n 's/^Journal sequence: *//p')))
    fi
}
# What a file server stopped as it ran left in the journal of $PART:
# nothing, or transactions of its own — numbered from $1 on — committed and
# not yet where they belong, which are replayed as a mount would replay
# them. One numbered before $1 was on the disk when the server started.
journal_left() {
    dumpe2fs -h "$PART" 2>/dev/null | grep -q needs_recovery || return 0
    [ "$(dumpe2fs -h "$PART" 2>/dev/null | sed -n 's/^Journal start: *//p')" != 0 ] || return 0
    seq=$(($(dumpe2fs -h "$PART" 2>/dev/null | sed -n 's/^Journal sequence: *//p')))
    if [ "$seq" -lt "$1" ]; then
        echo "   THE FILE SERVER DID NOT REPLAY ITS JOURNAL: transaction $seq is in it still"
        return 1
    fi
    debugfs -w -R jr "$PART" >/dev/null 2>&1
    if dumpe2fs -h "$PART" 2>/dev/null | grep -q needs_recovery; then
        echo "   WHAT THE FILE SERVER LEFT IN ITS JOURNAL COULD NOT BE REPLAYED"
        return 1
    fi
    echo "   stopped with a transaction of its own committed and not yet in place (from $seq): replayed, as a mount would"
}
# $RUN/crash-built.img: $IMG's filesystem with a removed file on the orphan
# list, under a committed transaction that makes a directory.
built() {
    cp "$IMG" "$RUN/crash-built.img"
    root_of
    python3 -c "
import sys
sys.stdout.buffer.write(bytes(range(256)) * 20)" > "$RUN/crash-built.orphan"
    debugfs -w -R "write $RUN/crash-built.orphan /crash-orphan" "$PART" >/dev/null 2>&1
    ino=$(debugfs -R "stat /crash-orphan" "$PART" 2>/dev/null | sed -n 's/^Inode: \([0-9]*\).*/\1/p')
    [ -n "$ino" ] || return 1
    printf 'unlink /crash-orphan\nsif <%s> links_count 0\nsif <%s> dtime 0\nssv last_orphan %s\n' \
        "$ino" "$ino" "$ino" | debugfs -w -f - "$PART" >/dev/null 2>&1
    # What the transaction makes of that, and the blocks it changes.
    cp "$PART" "$RUN/crash-built.ext"
    debugfs -w -R "mkdir /crash-replayed" "$RUN/crash-built.ext" >/dev/null 2>&1
    bs=$(dumpe2fs -h "$PART" 2>/dev/null | sed -n 's/^Block size: *//p')
    blocks=$(python3 - "$PART" "$RUN/crash-built.ext" "$RUN/crash-built.blocks" "$bs" <<'PY'
import sys
a = open(sys.argv[1], 'rb').read()
b = open(sys.argv[2], 'rb').read()
bs = int(sys.argv[4])
out = open(sys.argv[3], 'wb')
changed = []
for n in range(len(a) // bs):
    if a[n * bs:(n + 1) * bs] != b[n * bs:(n + 1) * bs]:
        changed.append(n)
        out.write(b[n * bs:(n + 1) * bs])
print(','.join(map(str, changed)))
PY
)
    : > "$RUN/crash-built.ext"
    [ -n "$blocks" ] || return 1
    printf 'jo\njw -b %s %s\njc\n' "$blocks" "$RUN/crash-built.blocks" \
        | debugfs -w -f - "$PART" >/dev/null 2>&1
    dumpe2fs -h "$PART" 2>/dev/null | grep -q needs_recovery || return 1
    root_to "$RUN/crash-built.img"
}

# The disk as it stands, recovered by e2fsck: 0 if that left a clean
# filesystem with the synced file in it, having found nothing to repair but
# a journal to replay and an orphan to clear.
recovered() {
    root_of
    # What the journal holds, before anything replays it.
    debugfs -R logdump "$PART" > "$PART.journal" 2>/dev/null
    e2fsck -fy "$PART" > "$PART.log" 2>&1
    # Anything it had to be asked about is damage.
    if grep -q "? yes\|<y>" "$PART.log"; then
        echo "   E2FSCK FOUND MORE THAN A JOURNAL AND AN ORPHAN TO DEAL WITH:"
        grep -v "^Pass [1-5]\|^e2fsck " "$PART.log" | sed 's/^/   /'
        return 1
    fi
    e2fsck -fn "$PART" >/dev/null 2>&1 || { echo "   NOT CLEAN AFTER e2fsck"; return 1; }
    synced_file
}

# One stop, while the guest is held: what the driver runs between `hmp stop`
# and `hmp cont`, with the files the run below is keeping.
if [ "$1" = --stop ]; then
    PART=$2
    if recovered > "$PART.out" 2>&1; then
        if grep -q "commit block" "$PART.journal"; then
            # The first of these is kept whole, to be started.
            grep -q committed "$PART.stops" || cp "$IMG" "$RUN/crash-journal.img"
            echo committed >> "$PART.stops"
        elif grep -q "recovering journal" "$PART.log"; then
            echo opening >> "$PART.stops"
        else
            echo between >> "$PART.stops"
        fi
        exit 0
    fi
    echo damage >> "$PART.stops"
    cp "$PART.log" "$RUN/crash-damage.log" 2>/dev/null
    cat "$PART.out"
    exit 1
fi

STOPS=${1:-24}
SCRIPT=$(mktemp) || exit 1
PART=$(mktemp) || exit 1
trap 'rm -f "$SCRIPT" "$PART" "$PART.got" "$PART.want" "$PART.log" "$PART.out" "$PART.stops" "$PART.journal"' EXIT
STATUS=0
mkdir -p "$RUN"
python3 -c "
import sys
sys.stdout.buffer.write(bytes((n * 131 + i * 7 + 3) & 255 for n in range(75) for i in range(4096)))" > "$PART.want"

root_of
: > "$PART.stops"
BUILT=0
if dumpe2fs -h "$PART" 2>/dev/null | grep -q has_journal; then
    COMMAND="dchild crashed /tmp writing"
    LAST="^writing /tmp\$"
    if built; then
        BUILT=1
    else
        echo "== a disk with a transaction to replay could not be made"
        STATUS=1
    fi
    root_of
else
    COMMAND="dchild crashed /tmp"
    LAST="^left /tmp\$"
    STOPS=0
fi
{
    cat <<KEYS
expect 120 ^login:\$
type root\\n
expect 60 \\\$\$
type $COMMAND\\n
expect 120 $LAST
KEYS
    n=0
    while [ "$n" -lt "$STOPS" ]; do
        # A moment apart, and not the same moment each time: the writes
        # come in a rhythm, and a stop in step with it sees one thing.
        echo "sleep 0.$((13 + (n * 7) % 31))"
        echo "hmp stop"
        echo "run RUNDIR=$RUN IMG=$IMG sh $HERE/crash-test.sh --stop $PART"
        echo "hmp cont"
        n=$((n + 1))
    done
    cat <<KEYS
sleep 0.4
shot $RUN/crash-1.ppm
quit
KEYS
} > "$SCRIPT"
sh "$HERE/boot-test.sh" "$SCRIPT" "$RUN/crash-1.ppm" > "$RUN/crash-1.out" 2>&1 || {
    echo "== the first boot did not go as scripted; see $RUN/crash-1.out and $RUN/crash-1.ppm"
    grep "gave up\|^run:\|FOUND\|NOT " "$RUN/crash-1.out" | sed 's/^/   /'
    STATUS=1
}
if [ "$STOPS" -gt 0 ]; then
    echo "== stopped $(grep -c . "$PART.stops") times while it wrote: $(grep -c committed "$PART.stops") with a transaction committed and not yet in place, $(grep -c opening "$PART.stops") with one being written, $(grep -c between "$PART.stops") between two, $(grep -c damage "$PART.stops") damaged"
    if grep -q damage "$PART.stops"; then
        STATUS=1
    fi
fi

echo "== the disk as the crash left it, recovered by e2fsck:"
if recovered; then
    grep "recovering journal\|orphaned" "$PART.log" | sed 's/^/   /'
else
    STATUS=1
fi

# The disk $IMG, started: the file server recovers it as it mounts it, and
# what it leaves has to be a clean filesystem with the synced file in it —
# unless the second argument says it has none. What the server says about
# the orphans it frees goes to the screen, which is kept: user space never
# reaches the serial line.
served() {
    root_of
    next=$(journal_next)
    cat > "$SCRIPT" <<KEYS
expect 120 ^login:\$
shot $1
quit
KEYS
    sh "$HERE/boot-test.sh" "$SCRIPT" "$1" >/dev/null || {
        echo "   IT DID NOT REACH A LOGIN PROMPT; its screen: $1"
        STATUS=1
    }
    # Checked as check-rootfs.sh checks, on the root the server left with
    # what it left in its journal replayed. The image keeps it unreplayed.
    root_of
    journal_left "$next" || STATUS=1
    if e2fsck -fn "$PART" > "$PART.log" 2>&1; then
        tail -1 "$PART.log" | sed 's/^/   /'
    else
        sed 's/^/   /' "$PART.log"
        echo "   NOT CLEAN AFTER THE FILE SERVER'S RECOVERY"
        STATUS=1
    fi
    if [ "$2" != made ]; then
        synced_file || STATUS=1
    fi
}
echo "== the same disk, recovered by the file server instead:"
served "$RUN/crash-2.ppm"
if grep -q committed "$PART.stops"; then
    echo "== a disk stopped with a transaction committed and not yet in place, recovered by the file server:"
    IMG=$RUN/crash-journal.img
    served "$RUN/crash-3.ppm"
elif [ "$STOPS" -gt 0 ]; then
    echo "== no stop found a transaction committed and not yet in place: the file server's replay was not tried by a stop. Run it again, or with more stops."
fi
if [ "$BUILT" = 1 ]; then
    echo "== a disk made with a transaction to replay over an orphan, recovered by the file server:"
    IMG=$RUN/crash-built.img
    served "$RUN/crash-4.ppm" made
fi
echo "== screens: $RUN/crash-1.ppm (before), $RUN/crash-2.ppm (after)"
exit $STATUS
