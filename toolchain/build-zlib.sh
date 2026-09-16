#!/bin/sh
# Build zlib for Quark, and zlib's own two test programs.
#
#     ./build-zlib.sh /path/to/zlib-1.3.2 [outdir]
#
# zlib's configure is its own, not autoconf: CHOST names the cross tools. It
# adds -fPIC whatever it is told; the compiler wrapper drops it.
set -e
SRC=${1:?usage: build-zlib.sh <zlib-src> [outdir]}
OUT=${2:-$PWD/zlib-tests}
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}
mkdir -p "$OUT"
cd "$SRC"
[ -f Makefile ] && make distclean >/dev/null 2>&1 || true
CHOST=x86_64-quark CC=x86_64-quark-musl-gcc CFLAGS=-O2 ./configure --static --prefix="$PREFIX"
make -j"$(nproc)" libz.a example minigzip
make install
cp example minigzip "$OUT"/
echo "zlib installed into $PREFIX; its tests are in $OUT"
