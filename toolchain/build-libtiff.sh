#!/bin/sh
# Build libtiff for Quark, static.
#
#     ./build-libtiff.sh /path/to/tiff-4.7.0
#
# GTK 4 links it to decode TIFF, the way it links libpng and libjpeg. Nothing
# on a Quark image is a TIFF; the dependency is unconditional in GTK's build,
# so the library is built rather than the build patched.
#
# Everything optional is off — no tools, no tests, no codecs beyond what zlib
# and libjpeg give — because none of it is reachable from GTK's decoder. The
# C++ API goes with them: `--disable-cxx`, since the one file it adds is the
# only thing in libtiff that needs a C++ compiler.
set -e

SRC=${1:?usage: build-libtiff.sh <tiff-src>}
HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}

sh "$HERE/teach-config-sub.sh" "$SRC/config/config.sub"

cd "$SRC"
rm -rf build-quark
mkdir -p build-quark
cd build-quark
../configure --host=x86_64-quark --prefix="$PREFIX" \
    --disable-shared --enable-static \
    --disable-tools --disable-tests --disable-contrib --disable-docs \
    --disable-webp --disable-jbig --disable-lerc --disable-lzma --disable-zstd \
    --disable-libdeflate --disable-cxx \
    CC=x86_64-quark-musl-gcc CXX=x86_64-quark-musl-g++ CFLAGS="-O2" CXXFLAGS="-O2"
make -j"$(nproc)"
make install
echo
echo "libtiff installed into $PREFIX"
