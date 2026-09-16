#!/bin/sh
# Build cairo for Quark: the image backend and nothing else, as a static
# library on top of build-pixman.sh's pixman.
#
#     ./build-cairo.sh /path/to/cairo-1.18.4 [/path/to/pixman-0.44.2]
#
# Installs libcairo.a, cairo.pc and the headers, under include/cairo, into the
# musl prefix.
#
# Every backend but the image surface is off, and so is everything that would
# need another library: freetype and fontconfig arrive with the rest of the
# font stack, and PNG and zlib with the first thing that has to write a file.
# --wrap-mode=nofallback keeps it that way — without it, a dependency pkg-config
# cannot find is downloaded and built from cairo's subprojects instead, pixman
# included, which would quietly test a pixman that is not the one installed.
#
# Given pixman's source as well, it also builds the same cairo for the host,
# against the host pixman in that tree's build-host (configured as
# build-pixman.sh configures it for Quark), and runs tests/cairotest.c with it.
# That prints the checksum cairotest expects, which is the only use of the host
# build.
set -e
SRC=${1:?usage: build-cairo.sh <cairo-src> [pixman-src]}
PIXMAN=$2
HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}

CROSS=$(mktemp)
trap 'rm -f "$CROSS"' EXIT
sed -e "s|@WAYLAND_SCANNER@|/bin/false|" -e "s|@HOME@|$HOME|g" \
    "$HERE/meson-cross-quark.ini" > "$CROSS"

# debugoptimized is what pixman asks for; cairo asks for nothing, which meson
# takes as -O0.
OPTIONS="--buildtype=debugoptimized -Ddefault_library=static -Db_staticpic=false
    --wrap-mode=nofallback
    -Ddwrite=disabled -Dfontconfig=disabled -Dfreetype=disabled
    -Dpng=disabled -Dquartz=disabled -Dtee=disabled -Dxcb=disabled
    -Dxlib=disabled -Dxlib-xcb=disabled -Dzlib=disabled -Dlzo=disabled
    -Dglib=disabled -Dspectre=disabled -Dsymbol-lookup=disabled
    -Dgtk2-utils=disabled -Dgtk_doc=false -Dtests=disabled"

cd "$SRC"
rm -rf build-quark
# shellcheck disable=SC2086
meson setup build-quark --cross-file "$CROSS" --prefix="$PREFIX" $OPTIONS
ninja -C build-quark
ninja -C build-quark install
echo
echo "cairo installed into $PREFIX"

[ -n "$PIXMAN" ] || exit 0

HOST="$SRC/build-host"
rm -rf "$HOST"
# shellcheck disable=SC2086
PKG_CONFIG_PATH="$PIXMAN/build-host/meson-uninstalled" \
    meson setup "$HOST" --prefix="$HOST/root" --libdir=lib $OPTIONS
ninja -C "$HOST"
ninja -C "$HOST" install >/dev/null
# cairo.pc names include/cairo; the test includes <cairo/cairo.h>.
FLAGS=$(PKG_CONFIG_PATH="$HOST/root/lib/pkgconfig:$PIXMAN/build-host/meson-uninstalled" \
    pkg-config --cflags --libs --static cairo)
# shellcheck disable=SC2086
cc -O2 -o "$HOST/cairotest" "$HERE/tests/cairotest.c" -I"$HOST/root/include" $FLAGS -lm
echo
echo "on the host, which is what tests/cairotest.c's EXPECTED should say:"
"$HOST/cairotest" "$HOST/cairotest.ppm" || true
