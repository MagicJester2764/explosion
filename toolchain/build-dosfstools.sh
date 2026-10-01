#!/bin/sh
# Build dosfstools for Quark: the programs that make and check FAT
# filesystems, which is what an EFI system partition is.
#
#     ./build-dosfstools.sh /path/to/dosfstools-4.2 [outdir]
#
# Needs x86_64-quark-musl-gcc on PATH, which quark-toolchain installs.
#
# Puts `mkfs.fat` and `fsck.fat` in <outdir>/usr/bin (default ./fstools, laid
# out like a root and staged as one).
#
# Nothing in dosfstools is patched. Its config.sub is from 2018, when the
# list of operating systems was written with a dash before each, and
# teach-config-sub.sh learned that shape for it. Like e2fsprogs it finds how
# long a disk is by reading at offsets until there is nothing there, the
# direct question being Linux's.
set -e

SRC=${1:?usage: build-dosfstools.sh <dosfstools-src> [outdir]}
OUT=${2:-$PWD/fstools}
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$SRC" && pwd)
mkdir -p "$OUT/usr/bin"
OUT=$(cd "$OUT" && pwd)

sh "$HERE/teach-config-sub.sh" "$SRC/config.sub"

mkdir -p "$SRC/build-quark" && cd "$SRC/build-quark"
"$SRC/configure" \
    --host=x86_64-quark \
    CC=x86_64-quark-musl-gcc \
    --prefix=/usr
make -j"$(nproc)"

x86_64-quark-strip --strip-debug -o "$OUT/usr/bin/mkfs.fat" src/mkfs.fat
x86_64-quark-strip --strip-debug -o "$OUT/usr/bin/fsck.fat" src/fsck.fat

echo
echo "mkfs.fat and fsck.fat are in $OUT/usr/bin"
