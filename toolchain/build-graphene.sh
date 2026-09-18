#!/bin/sh
# Build graphene for Quark: the vector and matrix types GSK renders with.
#
#     ./build-graphene.sh /path/to/graphene-1.10.8
#
# Points, rectangles, 4x4 matrices and quaternions, with SSE where the compiler
# has it. GTK requires the GObject flavour, so `-Dgobject_types=true`, which is
# why glib has to be built first.
set -e

SRC=${1:?usage: build-graphene.sh <graphene-src>}
HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}

CROSS=$(mktemp)
trap 'rm -f "$CROSS"' EXIT
sed -e "s|@WAYLAND_SCANNER@|/bin/false|" -e "s|@HOME@|$HOME|g" \
    "$HERE/meson-cross-quark.ini" > "$CROSS"

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
    -Dgobject_types=true -Dintrospection=disabled -Dgtk_doc=false \
    -Dtests=false -Dinstalled_tests=false
ninja -C build-quark
ninja -C build-quark install
echo
echo "graphene installed into $PREFIX"
