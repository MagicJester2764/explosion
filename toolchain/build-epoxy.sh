#!/bin/sh
# Build libepoxy for Quark: the GL dispatch library GTK links whatever it
# draws with.
#
#     ./build-epoxy.sh /path/to/libepoxy-1.5.10
#
# There is no OpenGL on Quark — that would be Mesa's software rasteriser, which
# is a project of its own. What is built is the dispatch table and nothing to
# dispatch to: every entry point resolves through `dlopen`, which in a static
# program finds nothing, so every GL call fails at run time.
#
# EGL is on and GLX and X11 are off. That is not a contradiction: epoxy
# generates the whole of `epoxy/egl.h` from its own copy of the registry and
# needs no EGL implementation to do it, and GTK's Wayland backend includes that
# header whether or not it ever makes a context.
#
# That is the honest shape of it rather than a stub: epoxy's whole job is to
# find a GL implementation at run time and it correctly finds none. GTK is then
# run with `GDK_DEBUG=gl-disable` and `GSK_RENDERER=cairo`, which is the
# supported way to use it without GL, and epoxy is never called.
set -e

SRC=${1:?usage: build-epoxy.sh <libepoxy-src>}
HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}

CROSS=$(mktemp)
trap 'rm -f "$CROSS"' EXIT
sed -e "s|@WAYLAND_SCANNER@|/bin/false|" -e "s|@HOME@|$HOME|g" \
    "$HERE/meson-cross-quark.ini" > "$CROSS"

cd "$SRC"
rm -rf build-quark
meson setup build-quark --cross-file "$CROSS" --prefix="$PREFIX" \
    --buildtype=debugoptimized -Ddefault_library=static -Db_staticpic=false \
    --wrap-mode=nofallback \
    -Degl=yes -Dglx=no -Dx11=false -Dtests=false
ninja -C build-quark
ninja -C build-quark install
echo
echo "libepoxy installed into $PREFIX"
