#!/bin/sh
# Build gdk-pixbuf for Quark, static.
#
#     ./build-gdk-pixbuf.sh /path/to/gdk-pixbuf-2.42.12
#
# GTK loads its icons through it. The loaders are built *into* the library
# rather than as modules, which is not a preference: there is no dlopen here,
# so a module is a file nothing can open. `-Dbuiltin_loaders` is what says so,
# and it is why no loader cache is needed either.
#
All of them, because a
# loader left out is built as a shared module instead, and a shared module
# cannot link the non-PIC static library everything else here is. TIFF is off
# rather than built in: GTK decodes those itself, and gdk-pixbuf's own tools do
# not carry libtiff on their link line.
set -e

SRC=${1:?usage: build-gdk-pixbuf.sh <gdk-pixbuf-src>}
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

# gdk-pixbuf's own tools — `gdk-pixbuf-pixdata` and `gdk-pixbuf-csource` —
# link the library without the libraries its built-in loaders call, which a
# system with shared libraries never notices and a static one cannot link.
# They are cross-compiled here and could not run on this machine anyway, but
# the build makes them before it installs anything, so the libraries are named
# once for the whole project rather than the build being patched.
LOADER_LIBS=$(PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" \
    pkg-config --libs --static libjpeg libpng16 | sed "s/ /', '/g")
cat >> "$CROSS" <<PROPS

[built-in options]
c_link_args = ['$LOADER_LIBS']
PROPS

cd "$SRC"
rm -rf build-quark
meson setup build-quark --cross-file "$CROSS" --prefix="$PREFIX" \
    --buildtype=debugoptimized -Ddefault_library=static -Db_staticpic=false \
    --wrap-mode=nofallback \
    -Dpng=enabled -Djpeg=enabled -Dtiff=disabled -Dbuiltin_loaders=all \
    -Dintrospection=disabled -Dman=false \
    -Dtests=false -Dinstalled_tests=false -Dgio_sniffing=false \
    -Dothers=disabled
ninja -C build-quark
ninja -C build-quark install
echo
echo "gdk-pixbuf installed into $PREFIX"
