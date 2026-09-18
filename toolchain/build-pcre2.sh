#!/bin/sh
# Build PCRE2 for Quark.
#
#     ./build-pcre2.sh /path/to/pcre2-10.44
#
# glib requires it: `GRegex` is PCRE2 with a GLib face on it, and glib's build
# refuses to start without it. Nothing else here wants regular expressions.
set -e
SRC=${1:?usage: build-pcre2.sh <pcre2-src>}
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}
HERE=$(cd "$(dirname "$0")" && pwd)

sh "$HERE/teach-config-sub.sh" "$SRC/config.sub"

cd "$SRC"
mkdir -p build-quark && cd build-quark
../configure --host=x86_64-quark --prefix="$PREFIX" \
    --disable-shared --enable-static --enable-unicode \
    --disable-pcre2grep-libz --disable-pcre2grep-libbz2 \
    --disable-pcre2test-libreadline \
    CC=x86_64-quark-musl-gcc CFLAGS="-O2"
make -j"$(nproc)" libpcre2-8.la
make install-libLTLIBRARIES install-nodist_includeHEADERS install-pkgconfigDATA 2>/dev/null \
    || make install
echo "pcre2 installed into $PREFIX"
