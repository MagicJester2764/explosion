#!/bin/sh
# Build fribidi for Quark: the Unicode bidirectional algorithm, static.
#
#     ./build-fribidi.sh /path/to/fribidi-1.0.16
#
# pango requires it, and it is what decides the order glyphs are laid out in
# when a line mixes left-to-right and right-to-left text. Nothing here is in
# Arabic or Hebrew yet; the algorithm still runs on every line, because
# "is this line all one direction" is the first thing it answers.
set -e

SRC=${1:?usage: build-fribidi.sh <fribidi-src>}
HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}

CROSS=$(mktemp)
trap 'rm -f "$CROSS"' EXIT
sed -e "s|@WAYLAND_SCANNER@|/bin/false|" -e "s|@HOME@|$HOME|g" \
    "$HERE/meson-cross-quark.ini" > "$CROSS"

cd "$SRC"
rm -rf build-quark
# -Dbin=false: the command-line tool is built for the host that runs the build
# and would be cross-compiled here for no one to run.
meson setup build-quark --cross-file "$CROSS" --prefix="$PREFIX" \
    --buildtype=debugoptimized -Ddefault_library=static -Db_staticpic=false \
    --wrap-mode=nofallback \
    -Ddocs=false -Dbin=false -Dtests=false
ninja -C build-quark
ninja -C build-quark install
echo
echo "fribidi installed into $PREFIX"
