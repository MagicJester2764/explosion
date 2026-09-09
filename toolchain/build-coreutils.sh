#!/bin/sh
# Build GNU coreutils for Quark.
#
#     ./build-coreutils.sh /path/to/coreutils-9.11
#
# Needs x86_64-quark-musl-gcc on PATH, which build-musl.sh installs.
#
# This is the thing a cross toolchain exists for. Nothing here tells the
# compiler where a Quark program loads or what its C library is called;
# `configure` runs the compiler and believes what happens, which is only
# possible because the target knows those things itself.
set -e

CU_SRC=${1:?usage: build-coreutils.sh <coreutils-src>}
HERE=$(cd "$(dirname "$0")" && pwd)

echo "==> patching $CU_SRC"
( cd "$CU_SRC" && patch -p1 -N -r - < "$HERE/patches/coreutils-9.11-quark.patch" || true )

mkdir -p build-coreutils-quark && cd build-coreutils-quark
"$CU_SRC/configure" \
    --host=x86_64-quark \
    CC=x86_64-quark-musl-gcc \
    --disable-nls --disable-acl --disable-xattr --disable-libcap \
    --disable-threads --without-selinux --without-openssl \
    --enable-no-install-program=stdbuf
make

echo
echo "Built. src/ holds the programs; strip them before putting them in an"
echo "image, because the debug info is most of their size."
