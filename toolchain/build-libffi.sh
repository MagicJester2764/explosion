#!/bin/sh
# Build libffi for Quark. libwayland hard-depends on it.
#
#     ./build-libffi.sh /path/to/libffi-3.4.6
#
# One hunk of patch: config.sub learning that quark is an operating system,
# which is the same hunk every autoconf package needs. Everything else about
# libffi cross-compiles unmodified, including the x86-64 assembly.
#
# It installs into musl's prefix and *not* into the shared sysroot, which
# matters: pkg-config reports its includedir, a build system turns that into
# -I, and -I beats -isystem. With libffi in the sysroot beside Quark's own C
# library headers, <fcntl.h> resolved to Quark's instead of musl's and every
# file that wanted fcntl stopped compiling. Two C libraries must not share an
# include directory.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)

FFI_SRC=${1:?usage: build-libffi.sh <libffi-src>}
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}

cd "$FFI_SRC"
sh "$HERE/teach-config-sub.sh" config.sub

./configure --host=x86_64-quark --prefix="$PREFIX" \
    CC=x86_64-quark-musl-gcc --disable-shared --disable-docs
make
make install
echo "built and installed: $PREFIX/lib/libffi.a"
