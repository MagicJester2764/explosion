#!/bin/sh
# Put the Linux userspace API headers in the Quark musl sysroot.
#
#     ./install-linux-headers.sh [source-include-dir]
#
# Quark answers Linux system calls -- that is what user/linux-abi is -- so a
# program built for it is a Linux program, and Linux programs include
# <linux/input.h> for the key codes, <linux/dma-buf.h> for the ioctls, and so
# on. These are the kernel's uapi headers: constants and structure layouts,
# installed by every distribution as a package of its own precisely because
# they are not part of any C library.
#
# Taken from the host rather than from a kernel tree, because they are the same
# headers -- `make headers_install` is what put them there -- and requiring a
# kernel checkout to build a Wayland client would be a strange thing to ask.
#
# Nothing here is Quark's. If one of these headers describes something Quark
# does not implement, a program using it gets ENOSYS at run time, which is the
# honest answer and the one it would get from an old Linux.
set -e

SRC=${1:-/usr/include}
SYSROOT=${SYSROOT:-$HOME/opt/cross/x86_64-quark/musl}

for dir in linux asm asm-generic; do
    if [ ! -d "$SRC/$dir" ]; then
        echo "no $SRC/$dir -- install your distribution's kernel-headers" >&2
        exit 1
    fi
done

mkdir -p "$SYSROOT/include"
for dir in linux asm asm-generic; do
    echo "==> $dir"
    rm -rf "$SYSROOT/include/$dir"
    cp -r "$SRC/$dir" "$SYSROOT/include/$dir"
done

echo "installed into $SYSROOT/include"
