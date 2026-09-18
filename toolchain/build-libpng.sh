#!/bin/sh
# Build libpng for Quark.
#
#     ./build-libpng.sh /path/to/libpng-1.6.44
#
# Needed by weston's `shared/image-loader.c`, which the toytoolkit's
# `cairo-util.c` calls into: decorations and image loading are one library
# there, so a terminal that draws a title bar links the code that reads a PNG.
#
# It is an ordinary autotools package and zlib is already built for this
# target, so the only thing worth saying is `--disable-shared`: everything
# here is static, and the target has no dynamic loader.
set -e
SRC=${1:?usage: build-libpng.sh <libpng-src>}
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}

HERE=$(cd "$(dirname "$0")" && pwd)
sh "$HERE/teach-config-sub.sh" "$SRC/config.sub"

cd "$SRC"
mkdir -p build-quark && cd build-quark
../configure --host=x86_64-quark --prefix="$PREFIX" \
    --disable-shared --enable-static \
    CC=x86_64-quark-musl-gcc CFLAGS="-O2" \
    CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib"
make -j"$(nproc)"
make install
echo "libpng installed into $PREFIX"
