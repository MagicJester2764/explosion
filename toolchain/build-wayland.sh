#!/bin/sh
# Build libwayland for Quark.
#
#     ./build-wayland.sh /path/to/wayland-1.23.1
#
# Needs x86_64-quark-musl-gcc on PATH (build-musl.sh), meson and ninja, and a
# host expat for wayland-scanner. HOSTPREFIX is where the host-side tools go.
#
# Two builds, because a cross build still needs a wayland-scanner that runs on
# *this* machine: one native with only the scanner, installed so its pkg-config
# file exists, and one cross with only the libraries.
#
# No patch. `wl_display_connect` checks WAYLAND_SOCKET before it looks at
# $WAYLAND_DISPLAY or a socket path, and takes it as an already-connected
# descriptor — which is exactly the shape Quark has, so upstream is used
# unmodified. That is also why no filesystem socket namespace was ever needed.
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
meson setup build-quark \
    --cross-file /tmp/quark-cross.ini --native-file /tmp/quark-native.ini \
    -Dlibraries=true -Dscanner=false -Dtests=false \
    -Ddocumentation=false -Ddtd_validation=false -Ddefault_library=static
ninja -C build-quark

echo
echo "built: build-quark/src/libwayland-client.a"
echo "       build-quark/src/libwayland-server.a"
