#!/bin/sh
# Build libjpeg-turbo for Quark, static.
#
#     ./build-libjpeg.sh /path/to/libjpeg-turbo-3.0.4
#
# GTK 4 decodes JPEG itself rather than through gdk-pixbuf, and asks for it by
# pkg-config name, which is what libjpeg-turbo installs and the original IJG
# library does not.
#
# The SIMD paths are off: they are written in assembly that nasm builds, and
# the C fallback is a complete implementation. Nothing here decodes a JPEG in a
# hurry.
set -e

SRC=${1:?usage: build-libjpeg.sh <libjpeg-turbo-src>}
HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}

cd "$SRC"
rm -rf build-quark
cmake -S . -B build-quark \
    -DCMAKE_TOOLCHAIN_FILE="$HERE/cmake-cross-quark.cmake" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_SHARED=FALSE -DENABLE_STATIC=TRUE \
    -DWITH_SIMD=FALSE -DWITH_TURBOJPEG=FALSE
cmake --build build-quark -j"$(nproc)"
cmake --install build-quark
echo
echo "libjpeg-turbo installed into $PREFIX"
