#!/bin/sh
# Build pango for Quark: text layout, static.
#
#     ./build-pango.sh /path/to/pango-1.54.0
#
# Above harfbuzz, which shapes a run of one script and one font, pango is what
# turns a paragraph into lines: itemisation into runs, font selection through
# fontconfig, the bidirectional algorithm through fribidi, line breaking, and
# then a cairo backend that draws the result. GTK draws every piece of text
# through it.
#
# Everything here was already built for Quark: glib, harfbuzz, fribidi, cairo,
# freetype and fontconfig. Pango adds no system requirements of its own, which
# is why this script is short.
set -e

SRC=${1:?usage: build-pango.sh <pango-src>}
HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}

CROSS=$(mktemp)
trap 'rm -f "$CROSS"' EXIT
sed -e "s|@WAYLAND_SCANNER@|/bin/false|" -e "s|@HOME@|$HOME|g" \
    "$HERE/meson-cross-quark.ini" > "$CROSS"

# glib's code generators, as for harfbuzz: they run here and write C.
# glib's tools, native ones first: `glib-compile-resources` and
# `glib-compile-schemas` are C programs, and the copies in the target prefix
# are Quark binaries that cannot run here.
HOSTDEPS=${QUARK_HOSTDEPS:-$HOME/opt/src/host-deps}
PATH="$HOSTDEPS/bin:$PREFIX/bin:$PATH"
export PATH

cd "$SRC"
rm -rf build-quark
meson setup build-quark --cross-file "$CROSS" --prefix="$PREFIX" \
    --buildtype=debugoptimized -Ddefault_library=static -Db_staticpic=false \
    --wrap-mode=nofallback \
    -Dintrospection=disabled -Ddocumentation=false -Dbuild-testsuite=false \
    -Dbuild-examples=false \
    -Dcairo=enabled -Dfontconfig=enabled -Dfreetype=enabled \
    -Dxft=disabled -Dlibthai=disabled
ninja -C build-quark
ninja -C build-quark install
echo
echo "pango installed into $PREFIX"
