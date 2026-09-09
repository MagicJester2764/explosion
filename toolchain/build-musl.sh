#!/bin/sh
# Build musl for Quark.
#
#     ./build-musl.sh /path/to/musl-1.2.5
#
# Needs the x86_64-quark toolchain on PATH (build.sh) and the translation
# layer built (`make -C ../../quark/user/linux-abi`).
#
# musl is written against Linux — not against "a kernel", but against Linux's
# numbers, argument order, error convention and idea of what a process is.
# Quark's calls are a different set with different semantics, so this is a
# translation layer rather than a port, and the layer lives in Quark's tree
# where it can talk to the servers that actually answer most of it.
#
# The patch is four files and no more, which is the interesting part: musl's
# system call interface really is that narrow.
set -e

MUSL_SRC=${1:?usage: build-musl.sh <musl-src>}
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}
HERE=$(cd "$(dirname "$0")" && pwd)

echo "==> patching $MUSL_SRC"
( cd "$MUSL_SRC" && patch -p1 -N -r - < "$HERE/patches/musl-1.2.5-quark.patch" || true )

cd "$MUSL_SRC"
./configure --target=x86_64-quark --prefix="$PREFIX" \
    CC=x86_64-quark-gcc --disable-shared
make
make install

echo
echo "Done. A program against it links as:"
echo "    x86_64-quark-gcc -nostdlib -nostdinc -isystem $PREFIX/include \\"
echo "        -o prog prog.c $PREFIX/lib/crt1.o $PREFIX/lib/libc.a \\"
echo "        <quark>/user/linux-abi/liblinux-abi.a"
