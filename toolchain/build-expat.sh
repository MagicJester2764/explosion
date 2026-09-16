#!/bin/sh
# Build expat for Quark: the XML parser fontconfig reads its configuration
# with.
#
#     ./build-expat.sh /path/to/expat-2.6.4.tar.xz
#
# Takes the tarball, not a source tree. bootstrap-wayland.sh configures and
# builds the host's expat in place in ~/opt/src/expat-2.6.4, and autoconf will
# not configure a second build against a tree configured in place. So this
# unpacks a private copy, $QUARK_SRC/expat-2.6.4-quark, afresh every time.
#
# Installs libexpat.a, expat.pc and the headers into the musl prefix. The
# tests, the examples and xmlwf are left out: they are programs for the build
# machine to run.
#
# expat salts its hash tables from getrandom, which Quark does not answer yet,
# and then /dev/urandom, which it does not have; it falls back to the time and
# the process ID. That is weaker protection against a document built to
# collide in its hash tables, and nothing worse.
set -e
TARBALL=${1:?usage: build-expat.sh <expat-tarball>}
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${QUARK_SRC:-$HOME/opt/src}
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}
TARBALL=$(cd "$(dirname "$TARBALL")" && pwd)/$(basename "$TARBALL")
TREE=$SRC/$(basename "$TARBALL" | sed 's/\.tar\..*$//')-quark

rm -rf "$TREE"
mkdir -p "$TREE"
tar -C "$TREE" --strip-components=1 -xf "$TARBALL"
cd "$TREE"
sh "$HERE/teach-config-sub.sh" conftools/config.sub
./configure --host=x86_64-quark CC=x86_64-quark-musl-gcc CFLAGS=-O2 \
    --prefix="$PREFIX" --disable-shared --enable-static \
    --without-docbook --without-tests --without-examples --without-xmlwf
make -j"$(nproc)"
make install
echo
echo "expat installed into $PREFIX"
