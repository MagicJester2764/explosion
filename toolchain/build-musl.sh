#!/bin/sh
# Build musl for Quark.
#
#     ./build-musl.sh /path/to/musl-1.2.5
#
# Needs the x86_64-quark toolchain on PATH (build.sh) and the translation
# layer built (`make -C ../../quarkutils/linux-abi`).
#
# musl is written against Linux — not against "a kernel", but against Linux's
# numbers, argument order, error convention and idea of what a process is.
# Quark's calls are a different set with different semantics, so this is a
# translation layer rather than a port, and the layer lives in Quark's tree
# where it can talk to the servers that actually answer most of it.
#
# The patch is five files and no more, which is the interesting part: musl's
# system call interface really is that narrow. Four of them are about issuing a
# system call at all; the fifth is `clone`, which is the one place musl asks
# the kernel for something Quark does not have the shape of — Linux has the
# child *return from the same call* on a new stack, and Quark starts a task at
# an entry point. That file becomes a tail call into the translation layer.
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

# Make musl a choice the compiler knows how to make, rather than a pile of
# flags every build system would have to be told: a specs file and two
# wrappers, written by a script of its own because they name the userland's
# checkout and have to be rewritten when that moves.
sh "$HERE/musl-wrappers.sh"

echo
echo "Done. Programs build with no flags at all:"
echo "    x86_64-quark-musl-gcc hello.c -o hello"
