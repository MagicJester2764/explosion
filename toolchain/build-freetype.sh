#!/bin/sh
# Build FreeType for Quark, as a static library on build-zlib.sh's zlib.
#
#     ./build-freetype.sh /path/to/freetype-2.14.3
#
# Installs libfreetype.a, freetype2.pc and the headers, under
# include/freetype2, into the musl prefix.
#
# -Dmmap=enabled: FreeType's Unix stream maps the whole font, and Quark maps a
# file a page at a time, as each is touched, so a face costs the tables a line
# of text reads rather than all 740 KiB of DejaVu Sans. It was disabled while a
# file could not be mapped and memory was backed when it was mapped: then the
# stream read every face whole before the first glyph, and the portable stream,
# which seeks to what it is asked for, was cheaper.
#
# PNG, brotli, bzip2 and HarfBuzz are off: nothing here needs colour glyphs,
# WOFF2 or compressed bitmap fonts, and HarfBuzz is built on FreeType rather
# than under it. --wrap-mode=nofallback, as for cairo, so that a dependency
# pkg-config cannot find fails the build instead of being built from
# FreeType's subprojects.
#
# It also builds the same FreeType for the host, with its own copy of zlib,
# and runs tests/fttest.c with it on the DejaVu Sans in $DEJAVU. That prints
# the checksum and glyph count fttest expects, which is the only use of the
# host build.
set -e
SRC=${1:?usage: build-freetype.sh <freetype-src>}
HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}
DEJAVU=${DEJAVU:-$HOME/opt/src/dejavu-fonts-ttf-2.37/ttf}

CROSS=$(mktemp)
trap 'rm -f "$CROSS"' EXIT
sed -e "s|@WAYLAND_SCANNER@|/bin/false|" -e "s|@HOME@|$HOME|g" \
    "$HERE/meson-cross-quark.ini" > "$CROSS"

OPTIONS="--buildtype=debugoptimized -Ddefault_library=static -Db_staticpic=false
    --wrap-mode=nofallback -Dmmap=enabled -Dpng=disabled -Dbrotli=disabled
    -Dbzip2=disabled -Dharfbuzz=disabled -Dtests=disabled"

cd "$SRC"
rm -rf build-quark
# shellcheck disable=SC2086
meson setup build-quark --cross-file "$CROSS" --prefix="$PREFIX" $OPTIONS -Dzlib=system
ninja -C build-quark
ninja -C build-quark install
echo
echo "FreeType installed into $PREFIX"

HOST="$SRC/build-host"
rm -rf "$HOST"
# shellcheck disable=SC2086
meson setup "$HOST" --prefix="$HOST/root" --libdir=lib $OPTIONS -Dzlib=internal
ninja -C "$HOST"
ninja -C "$HOST" install >/dev/null
FLAGS=$(PKG_CONFIG_PATH="$HOST/root/lib/pkgconfig" pkg-config --cflags --libs --static freetype2)
# shellcheck disable=SC2086
cc -O2 -o "$HOST/fttest" "$HERE/tests/fttest.c" $FLAGS
echo
echo "on the host, which is what tests/fttest.c's EXPECTED and GLYPHS should say:"
"$HOST/fttest" "$DEJAVU/DejaVuSans.ttf" || true
