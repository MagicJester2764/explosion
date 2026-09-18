#!/bin/sh
# Build cairo for Quark: the image backend and text, as a static library on
# top of build-pixman.sh's pixman and the font stack.
#
#     ./build-cairo.sh /path/to/cairo-1.18.4 [/path/to/pixman-0.44.2 [/path/to/freetype-2.14.3]]
#
# Installs libcairo.a, cairo.pc, cairo-ft.pc, cairo-fc.pc and the headers,
# under include/cairo, into the musl prefix.
#
# Every surface but the image is off. Text comes from FreeType
# (build-freetype.sh) and fonts are found by fontconfig (build-fontconfig.sh),
# which need expat and zlib under them; PNG stays off until something has to
# write a file. --wrap-mode=nofallback keeps it that way -- without it, a
# dependency pkg-config cannot find is downloaded and built from cairo's
# subprojects instead, pixman included, which would quietly test a pixman
# that is not the one installed.
#
# Given pixman's source as well, it also builds the same cairo for the host,
# against the host pixman in that tree's build-host (configured as
# build-pixman.sh configures it for Quark), and runs tests/cairotest.c with it.
# Given FreeType's too, the host cairo draws text with the host FreeType that
# build-freetype.sh left in its build-host, and tests/cairotext.c runs on the
# DejaVu Sans in $DEJAVU. They print the checksums the two tests expect, which
# is the only use of the host build. The host cairo leaves fontconfig out:
# the checksum comes from a face opened by name, and the host's own fonts
# are no business of a test that runs on Quark.
set -e
SRC=${1:?usage: build-cairo.sh <cairo-src> [pixman-src [freetype-src]]}
PIXMAN=$2
FREETYPE=$3
HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}
DEJAVU=${DEJAVU:-$HOME/opt/src/dejavu-fonts-ttf-2.37/ttf}

CROSS=$(mktemp)
trap 'rm -f "$CROSS"' EXIT
sed -e "s|@WAYLAND_SCANNER@|/bin/false|" -e "s|@HOME@|$HOME|g" \
    "$HERE/meson-cross-quark.ini" > "$CROSS"

# debugoptimized is what pixman asks for; cairo asks for nothing, which meson
# takes as -O0.
OPTIONS="--buildtype=debugoptimized -Ddefault_library=static -Db_staticpic=false
    --wrap-mode=nofallback
    -Ddwrite=disabled -Dquartz=disabled -Dtee=disabled
    -Dxcb=disabled -Dxlib=disabled -Dxlib-xcb=disabled -Dzlib=disabled
    -Dlzo=disabled -Dspectre=disabled
    -Dsymbol-lookup=disabled -Dgtk2-utils=disabled -Dgtk_doc=false
    -Dtests=disabled"

cd "$SRC"
rm -rf build-quark
# shellcheck disable=SC2086
# PNG is on for the target and off for the host build below: weston's
# decorations call `cairo_image_surface_create_from_png`, and libpng is built
# for this target. The host copy is only there to checksum a scene.
# glib is on for the target: `cairo-gobject` is a hard dependency of GTK, and
# it is the only thing cairo's glib option builds.
# glib's tools, native ones first: `glib-compile-resources` and
# `glib-compile-schemas` are C programs, and the copies in the target prefix
# are Quark binaries that cannot run here.
HOSTDEPS=${QUARK_HOSTDEPS:-$HOME/opt/src/host-deps}
PATH="$HOSTDEPS/bin:$PREFIX/bin:$PATH"
export PATH
meson setup build-quark --cross-file "$CROSS" --prefix="$PREFIX" $OPTIONS \
    -Dpng=enabled -Dfreetype=enabled -Dfontconfig=enabled -Dglib=enabled
ninja -C build-quark
ninja -C build-quark install
echo
echo "cairo installed into $PREFIX"

[ -n "$PIXMAN" ] || exit 0

HOST="$SRC/build-host"
HOST_PC="$PIXMAN/build-host/meson-uninstalled"
if [ -n "$FREETYPE" ]; then
    HOST_PC="$HOST_PC:$FREETYPE/build-host/root/lib/pkgconfig"
    TEXT=-Dfreetype=enabled
else
    TEXT=-Dfreetype=disabled
fi
rm -rf "$HOST"
# shellcheck disable=SC2086
PKG_CONFIG_PATH="$HOST_PC" \
    meson setup "$HOST" --prefix="$HOST/root" --libdir=lib $OPTIONS \
    -Dpng=disabled $TEXT -Dfontconfig=disabled -Dglib=disabled
ninja -C "$HOST"
ninja -C "$HOST" install >/dev/null
# cairo.pc names include/cairo; the tests include <cairo/cairo.h>.
FLAGS=$(PKG_CONFIG_PATH="$HOST/root/lib/pkgconfig:$HOST_PC" \
    pkg-config --cflags --libs --static cairo)
# shellcheck disable=SC2086
cc -O2 -o "$HOST/cairotest" "$HERE/tests/cairotest.c" -I"$HOST/root/include" $FLAGS -lm
echo
echo "on the host, which is what tests/cairotest.c's EXPECTED should say:"
"$HOST/cairotest" "$HOST/cairotest.ppm" || true

[ -n "$FREETYPE" ] || exit 0
FLAGS=$(PKG_CONFIG_PATH="$HOST/root/lib/pkgconfig:$HOST_PC" \
    pkg-config --cflags --libs --static cairo-ft)
# shellcheck disable=SC2086
cc -O2 -o "$HOST/cairotext" "$HERE/tests/cairotext.c" -I"$HOST/root/include" $FLAGS -lm
echo
echo "on the host, which is what tests/cairotext.c's EXPECTED should say:"
"$HOST/cairotext" "$DEJAVU/DejaVuSans.ttf" || true
