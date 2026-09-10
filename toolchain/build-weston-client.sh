#!/bin/sh
# Build Wayland clients for Quark.
#
#     ./build-weston-client.sh /path/to/wayland-1.23.1 [outdir]
#
# Needs x86_64-quark-musl-gcc, and libwayland built for Quark by
# build-wayland.sh. The clients are musl programs, so Quark's own Makefile does
# not build them — that needs the cross toolchain, which is an install rather
# than a checkout. ExplOSion stages them, the same arrangement as coreutils.
#
# Nothing here patches a client. If one needs changing to run, that is a
# compositor bug and the change belongs there.
set -e

WL_SRC=${1:?usage: build-weston-client.sh <wayland-src> [outdir]}
OUT=${2:-$PWD/clients}
HERE=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$OUT"
INC="-I$WL_SRC/src -I$WL_SRC/build-quark/src -I$OUT"
LIB="$WL_SRC/build-quark/src/libwayland-client.a -lffi"

# xdg-shell is a wayland-protocols extension rather than part of libwayland, so
# its client stubs are generated here from the XML the host has. The scanner is
# the one built alongside libwayland for the host -- generating with a different
# version than the library was built against is how a client ends up calling
# into interface structures laid out differently.
SCANNER=$WL_SRC/build-native/src/wayland-scanner
XDG_XML=${XDG_SHELL_XML:-/usr/share/qt6/wayland/protocols/xdg-shell/xdg-shell.xml}
if [ ! -f "$XDG_XML" ]; then
    echo "no xdg-shell.xml; set XDG_SHELL_XML" >&2
    exit 1
fi
echo "==> xdg-shell stubs"
"$SCANNER" client-header "$XDG_XML" "$OUT/xdg-shell-client-protocol.h"
"$SCANNER" private-code  "$XDG_XML" "$OUT/xdg-shell-protocol.c"

echo "==> wlprobe"
x86_64-quark-musl-gcc -O2 -o "$OUT/wlprobe" "$HERE/wlprobe.c" "$OUT/xdg-shell-protocol.c" $INC $LIB

echo
echo "built into $OUT; stage with"
echo "  make hd WAYLAND_CLIENTS=$OUT"
