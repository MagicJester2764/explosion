#!/bin/sh
# Fill an ext2 or ext4 image from the staged root, with one debugfs run.
#
#     tools/populate-ext.sh <image> <stage-dir>
#
# Every staged directory under usr, etc and var is made, and every file in
# them written. Quark's own install names its files the way FAT wants them,
# HELLO.ELF and PASSWD, in usr/bin and etc; there the image gets the names the
# shell and init look for, hello and passwd. Everywhere else, and for any name
# with a lowercase letter in it, the staged name was chosen on purpose and is
# kept: DejaVuSans.ttf, and the LICENSE beside it.
#
# debugfs exits 0 whatever happened, so its complaints are read instead, and
# every file is looked for afterwards. Neither is enough alone: a write that
# runs out of room leaves the file's name and size behind with no blocks, so
# it is found, reads as zeros, and e2fsck calls the image clean.
set -e
if [ $# -ne 2 ]; then
    echo "usage: populate-ext.sh <image> <stage-dir>" >&2
    exit 2
fi
IMG=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
cd "$2"

target() {
    dir=$(dirname "$1")
    base=$(basename "$1")
    case "$dir:$base" in
    usr/bin:*[a-z]* | etc:*[a-z]*) ;;
    usr/bin:* | etc:*)
        base=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed 's/\.elf$//') ;;
    esac
    printf '%s/%s\n' "$dir" "$base"
}

CMDS=$(mktemp)
OUT=$(mktemp)
ERR=$(mktemp)
trap 'rm -f "$CMDS" "$OUT" "$ERR"' EXIT
{
    # /dev is the VFS's, but listing / should show it.
    printf 'mkdir dev\nmkdir home\nmkdir home/root\nmkdir tmp\n'
    find usr etc var -type d 2>/dev/null | sort | sed 's/^/mkdir /'
    find usr etc var -type f 2>/dev/null | sort | while read -r f; do
        printf 'write %s %s\n' "$f" "$(target "$f")"
    done
} > "$CMDS"
debugfs -w -f "$CMDS" "$IMG" >/dev/null 2>"$ERR"
# After its banner, a run where everything worked says nothing on stderr.
if grep -v '^debugfs [0-9]' "$ERR" >&2; then
    echo "$IMG: debugfs could not write everything" >&2
    exit 1
fi

find usr etc var -type f 2>/dev/null | sort | while read -r f; do
    printf 'stat %s\n' "$(target "$f")"
done > "$CMDS"
debugfs -f "$CMDS" "$IMG" > "$OUT" 2>&1 || true
# The error names the path. The command echo that precedes it on stdout is
# buffered, so the two do not reliably arrive in order.
if grep -q 'File not found' "$OUT"; then
    grep 'File not found' "$OUT" | sed 's/: File not found.*//; s/^/  MISSING from the image: /' >&2
    echo "$IMG is incomplete" >&2
    exit 1
fi
