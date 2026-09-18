#!/bin/sh
# Build libstdc++ for Quark, against musl.
#
#     ./build-libstdcxx.sh /path/to/gcc
#
# Needs build.sh (which now builds a C++ compiler) and build-musl.sh (which
# writes the `x86_64-quark-musl-g++` wrapper) to have run.
#
# gcc's own build cannot do this. Its target C library is the sysroot's, which
# is Quark's hand-written `user/libc` -- enough to compile libgcc and no more,
# with no wchar.h, no locale and no threads. libstdc++-v3 configures on its
# own, so it is built here like any other port: with the musl wrapper, for the
# musl prefix, seeing nothing of the other sysroot.
#
# `configure.host` has no case for quark, which is the right answer rather than
# a gap: it falls through to os/generic, and generic is what this is -- a
# POSIX-shaped C library with no OS-specific error list, ctype table or
# atomicity header to borrow.
set -e

SRC=${1:?usage: build-libstdcxx.sh <gcc-src>}
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}
JOBS=${JOBS:-$(nproc)}
VER=$(cat "$SRC/gcc/BASE-VER")

BUILD=$SRC/build-libstdcxx-quark
rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

# --disable-libstdcxx-verbose: the verbose terminate handler prints through
#   fputs to stderr from inside the unwinder, which is the worst moment here to
#   ask the C library for anything. The quiet one calls abort, which the kernel
#   turns into a task that ends with a signal number -- and that is visible.
# --disable-libstdcxx-pch: a precompiled <bits/stdc++.h> nothing here includes.
# --disable-libstdcxx-threads is *not* passed: musl has pthreads, and the
#   gthread header the compiler was built with decides this anyway.
"$SRC/libstdc++-v3/configure" \
    --host=x86_64-quark --prefix="$PREFIX" \
    --disable-shared --enable-static \
    --disable-nls --disable-libstdcxx-pch --disable-libstdcxx-verbose \
    --with-gxx-include-dir="$PREFIX/include/c++/$VER" \
    CC=x86_64-quark-musl-gcc CXX=x86_64-quark-musl-g++ \
    CFLAGS="-O2" CXXFLAGS="-O2"
make -j"$JOBS"
make install

echo
echo "libstdc++ $VER installed into $PREFIX"
