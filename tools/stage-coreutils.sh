#!/bin/sh
# Put a coreutils build into the staged /usr/bin.
#
#     tools/stage-coreutils.sh <stage-dir> [<coreutils-build>/src]
#
# coreutils is not built here. Building it needs the cross toolchain, which is
# an install rather than a checkout, so this takes a directory somebody else
# built and copies the programs out of it — the same arrangement as
# LINUX_KERNEL. `toolchain/build-coreutils.sh` leaves them in its build
# directory's `src/`.
#
# Three rules, each one a thing that went wrong first:
#
#   - A program is one that starts at Quark's load address. A build tree also
#     holds helpers built for the *host* — same architecture, same file type,
#     and no business in an image.
#   - Quark's own userland keeps its names. coreutils `ls` wants `getdents64`
#     and Quark has none; the in-tree one lists a directory over the VFS
#     protocol and works. Rather than decide that case by case, whatever is
#     already staged stays.
#   - Strip. Debug info is three quarters of 54 MB and the root filesystem is
#     33.
#
# What was staged is recorded, so a later stage with no coreutils takes them
# back out instead of leaving an image half-built from something removed.
set -e

STAGE=${1:?usage: stage-coreutils.sh <stage-dir> [<coreutils-build>/src]}
SRC=${2:-}
BIN=$STAGE/usr/bin
LIST=$STAGE/.coreutils
# Outside usr/ and etc/, so the image rules do not find it and try to install
# the bookkeeping alongside the programs.

if [ -f "$LIST" ]; then
    while read -r name; do
        [ -n "$name" ] && rm -f "$BIN/$name"
    done < "$LIST"
    rm -f "$LIST"
fi

[ -n "$SRC" ] || exit 0
if [ ! -d "$SRC" ]; then
    echo "coreutils: $SRC is not a directory" >&2
    exit 1
fi

STRIP=${STRIP:-x86_64-quark-strip}
command -v "$STRIP" >/dev/null 2>&1 || STRIP=strip

mkdir -p "$BIN"
staged=0
kept=

for f in "$SRC"/*; do
    [ -f "$f" ] && [ -x "$f" ] || continue
    readelf -h "$f" 2>/dev/null | grep -q 'Entry point address: *0x80' || continue

    name=$(basename "$f")
    upper=$(echo "$name" | tr '[:lower:]' '[:upper:]')
    # The ext2 image lowercases every name it is given, so a program staged as
    # FOO.ELF and one called foo are the same file there.
    if [ -e "$BIN/$name" ] || [ -e "$BIN/$upper.ELF" ]; then
        kept="$kept $name"
        continue
    fi

    cp "$f" "$BIN/$name"
    "$STRIP" "$BIN/$name" 2>/dev/null || true
    echo "$name" >> "$LIST"
    staged=$((staged + 1))
done

echo "coreutils: staged $staged programs${kept:+, kept Quark's$kept}"
