#!/bin/sh
# Build e2fsprogs for Quark: the programs that make and check ext2 and ext4
# filesystems.
#
#     ./build-e2fsprogs.sh /path/to/e2fsprogs-1.47.3 [outdir]
#
# Needs x86_64-quark-musl-gcc on PATH, which quark-toolchain installs.
#
# Puts `mke2fs` and `e2fsck` in <outdir>/usr/bin (default ./fstools, which is
# laid out like a root and staged as one), and beside `mke2fs` the two names
# it is asked for by: `mkfs.ext2` and `mkfs.ext4` are links to it, and it
# makes the filesystem its name says.
#
# Nothing in e2fsprogs is patched. Its config.sub is taught the word quark,
# as every autoconf package's is. What it needed was already Quark's to have:
#
# - **A disk as a file.** It opens the device, asks how long it is and reads
#   and writes at the offsets it likes. It finds the length the slow way
#   here — reading at an offset to see whether there is anything there, and
#   halving — because the question it would rather ask is behind
#   `#ifdef __linux__`. That works, and is a dozen reads.
# - **`-rdynamic`.** It links e2fsck with it without asking whether the
#   compiler has it, and the compiler's driver had not. It has now
#   (quark-toolchain), and the flag changes nothing in a static program.
#
# Its own uuid and blkid libraries are built in, since there is no
# util-linux here to have them. Left out, by configure: the debugger, the
# resizer, the image and defragmenting tools, the FUSE driver and the uuid
# daemon — none of them is needed to install a system, and each is one more
# program to keep honest.
set -e

SRC=${1:?usage: build-e2fsprogs.sh <e2fsprogs-src> [outdir]}
OUT=${2:-$PWD/fstools}
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$SRC" && pwd)
mkdir -p "$OUT/usr/bin"
OUT=$(cd "$OUT" && pwd)

sh "$HERE/teach-config-sub.sh" "$SRC/config/config.sub"

mkdir -p "$SRC/build-quark" && cd "$SRC/build-quark"
"$SRC/configure" \
    --host=x86_64-quark \
    CC=x86_64-quark-musl-gcc \
    --prefix=/usr --sysconfdir=/etc \
    --enable-libuuid --enable-libblkid \
    --disable-nls --disable-rpath --disable-backtrace --disable-testio-debug \
    --disable-debugfs --disable-imager --disable-resizer --disable-defrag \
    --disable-fuse2fs --disable-uuidd --disable-tdb --disable-mmp \
    --without-libarchive --without-udev-rules-dir --without-crond-dir \
    --without-systemd-unit-dir
make -j"$(nproc)"

# --strip-debug and not -s: the symbol table is what turns a faulting rip
# into a function name.
x86_64-quark-strip --strip-debug -o "$OUT/usr/bin/mke2fs" misc/mke2fs
x86_64-quark-strip --strip-debug -o "$OUT/usr/bin/e2fsck" e2fsck/e2fsck
ln -sf mke2fs "$OUT/usr/bin/mkfs.ext2"
ln -sf mke2fs "$OUT/usr/bin/mkfs.ext4"

echo
echo "mke2fs, mkfs.ext2, mkfs.ext4 and e2fsck are in $OUT/usr/bin"
