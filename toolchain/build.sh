#!/bin/sh
# Build the x86_64-quark cross toolchain.
#
# Quark is x86-64 and so is the machine this runs on, so `-ffreestanding
# -nostdlib` with our own headers already produces working binaries — which is
# how the C library was built before this existed. What a target triple buys is
# everything a build system asks the compiler rather than being told: where a
# program loads, which code model it needs, what its C library is called and
# what to link it with. `./configure` cannot be handed those in CFLAGS by
# somebody who already knows the answer; that is the whole problem with porting
# software that was not written for you.
#
#     ./build.sh /path/to/binutils-gdb /path/to/gcc
#
# Needs the sysroot populated first, which is `make -C ../../quark/user/libc
# install-sysroot`. gcc's own support library is compiled against those
# headers, so they have to be there before this runs.
set -e

BINUTILS_SRC=${1:?usage: build.sh <binutils-src> <gcc-src>}
GCC_SRC=${2:?usage: build.sh <binutils-src> <gcc-src>}
PREFIX=${PREFIX:-$HOME/opt/cross}
SYSROOT=${SYSROOT:-$PREFIX/x86_64-quark/sys-root}
TARGET=x86_64-quark
JOBS=${JOBS:-$(nproc)}
HERE=$(cd "$(dirname "$0")" && pwd)

echo "==> patching $BINUTILS_SRC"
( cd "$BINUTILS_SRC" && patch -p1 -N -r - < "$HERE/patches/binutils-x86_64-quark.patch" || true )

echo "==> patching $GCC_SRC"
( cd "$GCC_SRC" && patch -p1 -N -r - < "$HERE/patches/gcc-x86_64-quark.patch" || true )
cp "$HERE/patches/gcc-config-quark.h" "$GCC_SRC/gcc/config/quark.h"

echo "==> binutils"
mkdir -p build-binutils-quark && cd build-binutils-quark
"$BINUTILS_SRC/configure" --target=$TARGET --prefix="$PREFIX" \
    --with-sysroot="$SYSROOT" \
    --disable-nls --disable-werror --disable-gdb --disable-sim \
    --disable-libdecnumber --disable-readline --disable-gprofng
make -j"$JOBS"
make install
cd ..

echo "==> gcc"
mkdir -p build-gcc-quark && cd build-gcc-quark
"$GCC_SRC/configure" --target=$TARGET --prefix="$PREFIX" \
    --with-sysroot="$SYSROOT" \
    --enable-languages=c \
    --disable-nls --disable-shared --disable-threads \
    --disable-libssp --disable-libquadmath --disable-libatomic \
    --disable-libgomp --disable-libvtv --disable-libstdcxx
make -j"$JOBS" all-gcc
make -j"$JOBS" all-target-libgcc
make install-gcc install-target-libgcc
cd ..

echo
echo "Done. Add $PREFIX/bin to PATH, then:"
echo "    x86_64-quark-gcc hello.c -o hello"
