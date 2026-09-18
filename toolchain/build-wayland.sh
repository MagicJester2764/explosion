#!/bin/sh
# Build libwayland for Quark.
#
#     ./build-wayland.sh /path/to/wayland-1.23.1
#
# Needs x86_64-quark-musl-gcc on PATH (build-musl.sh), meson and ninja, and a
# host expat for wayland-scanner. HOSTPREFIX is where the host-side tools go.
#
# A distribution's `expat` package is the shared library only; the scanner needs
# the headers and the pkg-config file, which come from `expat-devel` or from
# building expat into a prefix of your own and pointing PKG_CONFIG_PATH at it.
#
# Two builds, because a cross build still needs a wayland-scanner that runs on
# *this* machine: one native with only the scanner, installed so its pkg-config
# file exists, and one cross with only the libraries.
#
# No patch. `wl_display_connect` checks WAYLAND_SOCKET before it looks at
# $WAYLAND_DISPLAY or a socket path, and takes it as an already-connected
# descriptor — which is exactly the shape Quark has, so upstream is used
# unmodified. That is also why no filesystem socket namespace was ever needed.
#
# -Db_staticpic=false is not a preference, and every meson package built for
# this target will need it. meson compiles static libraries -fPIC by default;
# a Quark program is static and not PIE, and the target forces -mcmodel=large.
# In that combination, taking the address of a default-visibility symbol goes
# through the GOT with a base register that a non-PIE binary never sets up, so
# the address comes out as zero. It fails nowhere near the cause: libwayland
# linked, connected, and then found `&wl_display_interface` was NULL.
set -e

WL_SRC=${1:?usage: build-wayland.sh <wayland-src>}
HOSTPREFIX=${HOSTPREFIX:-$PWD/host-tools}
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}
HERE=$(cd "$(dirname "$0")" && pwd)

cd "$WL_SRC"

echo "==> wayland-scanner, for this machine"
rm -rf build-native
meson setup build-native --prefix="$HOSTPREFIX" \
    -Dlibraries=false -Dscanner=true -Dtests=false \
    -Ddocumentation=false -Ddtd_validation=false
ninja -C build-native install

echo "==> libwayland, for Quark"
SCANNER="$HOSTPREFIX/bin/wayland-scanner"
sed -e "s|@WAYLAND_SCANNER@|$SCANNER|" -e "s|@HOME@|$HOME|g" \
    "$HERE/meson-cross-quark.ini" > /tmp/quark-cross.ini
sed -e "s|@HOSTPREFIX@|$HOSTPREFIX|g" \
    "$HERE/meson-native-quark.ini" > /tmp/quark-native.ini

rm -rf build-quark
meson setup build-quark --prefix="$PREFIX" \
    --cross-file /tmp/quark-cross.ini --native-file /tmp/quark-native.ini \
    -Dlibraries=true -Dscanner=false -Dtests=false \
    -Ddocumentation=false -Ddtd_validation=false -Ddefault_library=static \
    -Db_staticpic=false
ninja -C build-quark
# Installed as well as built, now that something looks for it through
# pkg-config rather than naming the build directory: GTK asks for
# `wayland-client`, `wayland-cursor` and `wayland-egl` by name. The clients
# built here still name the build directory, which is why both exist.
#
# `libwayland-egl` is a set of symbols with nothing behind them — on a real
# system Mesa's EGL replaces them — and that is the honest thing to install on
# a machine with no GL: a program that calls one gets an error rather than a
# missing symbol at link time.
ninja -C build-quark install

echo
echo "built: build-quark/src/libwayland-client.a"
echo "       build-quark/src/libwayland-server.a"
echo "installed into $PREFIX"
