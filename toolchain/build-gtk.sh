#!/bin/sh
# Build GTK 4 for Quark, static, with the Wayland backend.
#
#     ./build-gtk.sh /path/to/gtk-4.16.7
#
# Everything under it was built first: glib, cairo with its GObject bindings,
# pango, harfbuzz, fribidi, graphene, gdk-pixbuf, libpng, libjpeg, libtiff,
# libepoxy, xkbcommon, wayland and wayland-protocols.
#
# **There is no OpenGL here.** GTK links libepoxy whatever it draws with, and
# epoxy was built with no window system to find one through, so every GL call
# fails at run time. That is the supported way to run GTK without GL rather
# than a workaround: `GSK_RENDERER=cairo` picks the software renderer, which
# draws through the cairo already used for everything else, and
# `GDK_DEBUG=gl-disable` stops it trying to make a context first. A Mesa
# software rasteriser would be a project of its own.
#
# The backends other than Wayland are off because their libraries are not here,
# and everything that would talk to a service that does not exist — CUPS,
# GStreamer, tracker, colord, cloud providers, sysprof — is off with them.
#
# **GTK 4 has no static build.** `gtk/meson.build` says `shared_library('gtk-4')`
# with no choice about it, and there are no shared libraries here. What it also
# has is `static_library('gtk')`, which the shared one is made by wrapping — so
# the static halves are built and a program is linked against them directly,
# the way build-weston-toytoolkit.sh links against a build tree. `b_staticpic`
# is on only so that meson's own rule about linking a non-PIC library into a
# shared one does not stop the configure; the compiler wrapper drops `-fPIC`,
# as it must for this target, so nothing is actually built position-independent
# and the shared library is never linked.
set -e

SRC=${1:?usage: build-gtk.sh <gtk-src>}
HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}
HOSTPREFIX=${HOSTPREFIX:-$(cd "$HERE/.." && pwd)/host-tools}

SCANNER=$HOSTPREFIX/bin/wayland-scanner
[ -x "$SCANNER" ] || { echo "no wayland-scanner at $SCANNER (build-wayland.sh)" >&2; exit 1; }

CROSS=$(mktemp)
trap 'rm -f "$CROSS"' EXIT
sed -e "s|@WAYLAND_SCANNER@|$SCANNER|" -e "s|@HOME@|$HOME|g" \
    "$HERE/meson-cross-quark.ini" > "$CROSS"

# glib's code generators and gdk-pixbuf's, which run here and write C.
# glib's tools, native ones first: `glib-compile-resources` and
# `glib-compile-schemas` are C programs, and the copies in the target prefix
# are Quark binaries that cannot run here.
HOSTDEPS=${QUARK_HOSTDEPS:-$HOME/opt/src/host-deps}
PATH="$HOSTDEPS/bin:$PREFIX/bin:$PATH"
export PATH

cd "$SRC"
rm -rf build-quark
meson setup build-quark --cross-file "$CROSS" --prefix="$PREFIX" \
    --buildtype=debugoptimized -Ddefault_library=static -Db_staticpic=true \
    --wrap-mode=nofallback \
    -Dwayland-backend=true -Dx11-backend=false -Dbroadway-backend=false \
    -Dwin32-backend=false -Dmacos-backend=false \
    -Dvulkan=disabled -Dmedia-gstreamer=disabled \
    -Dprint-cups=disabled -Dprint-cpdb=disabled \
    -Dcloudproviders=disabled -Dsysprof=disabled -Dtracker=disabled \
    -Dcolord=disabled -Dintrospection=disabled -Ddocumentation=false \
    -Dman-pages=false -Dscreenshots=false \
    -Dbuild-demos=false -Dbuild-testsuite=false -Dbuild-examples=false \
    -Dbuild-tests=false
# Only the static halves, in dependency order. `ninja` with no target would
# link the shared library, which cannot be done here.
STATICS="gtk/libgtk.a gtk/css/libgtk_css.a gdk/libgdk.a gdk/wayland/libgdk-wayland.a \
         gdk/wayland/cursor/libwayland+cursor.a gsk/libgsk.a gsk/libgsk_f16c.a"
# shellcheck disable=SC2086
ninja -C build-quark $STATICS
echo
echo "built:"
for a in $STATICS; do
    echo "    $SRC/build-quark/$a"
done
echo
echo "Link a program against them with build-gtk-client.sh."
