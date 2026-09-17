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
# Weston's own tree, for the clients that come from it. Optional: without it
# only wlprobe is built, and Quark still boots.
WESTON_SRC=${WESTON_SRC:-}
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}

mkdir -p "$OUT"
INC="-I$WL_SRC/src -I$WL_SRC/build-quark/src -I$OUT"
LIB="$WL_SRC/build-quark/src/libwayland-client.a -lffi"

# xdg-shell is a wayland-protocols extension rather than part of libwayland, so
# its client stubs are generated here from the XML the host has. The scanner is
# the one built alongside libwayland for the host -- generating with a different
# version than the library was built against is how a client ends up calling
# into interface structures laid out differently.
SCANNER=$WL_SRC/build-native/src/wayland-scanner
PROTO_DIR=${WAYLAND_PROTOCOLS:-/usr/share/qt6/wayland/protocols}
stubs() {
    xml=$1
    name=$2
    if [ ! -f "$xml" ]; then
        echo "no $xml; set WAYLAND_PROTOCOLS" >&2
        exit 1
    fi
    "$SCANNER" client-header "$xml" "$OUT/$name-client-protocol.h"
    "$SCANNER" private-code  "$xml" "$OUT/$name-protocol.c"
}

echo "==> protocol stubs"
stubs "$PROTO_DIR/xdg-shell/xdg-shell.xml" xdg-shell
stubs "$PROTO_DIR/fullscreen-shell/fullscreen-shell-unstable-v1.xml" \
      fullscreen-shell-unstable-v1
stubs "$PROTO_DIR/xdg-decoration/xdg-decoration-unstable-v1.xml" \
      xdg-decoration-unstable-v1
# The primary selection, whose file two distributions spell differently: Qt
# ships it as wp-primary-selection and wayland-protocols as
# unstable/primary-selection.
PRIMARY_XML=$PROTO_DIR/wp-primary-selection/wp-primary-selection-unstable-v1.xml
if [ ! -f "$PRIMARY_XML" ]; then
    PRIMARY_XML=$PROTO_DIR/unstable/primary-selection/primary-selection-unstable-v1.xml
fi
stubs "$PRIMARY_XML" primary-selection-unstable-v1

echo "==> wlclip"
x86_64-quark-musl-gcc -O2 -o "$OUT/wlclip" "$HERE/wlclip.c" \
    "$OUT/xdg-shell-protocol.c" "$OUT/primary-selection-unstable-v1-protocol.c" \
    $INC $LIB

echo "==> wlscroll"
x86_64-quark-musl-gcc -O2 -o "$OUT/wlscroll" "$HERE/wlscroll.c" \
    "$OUT/xdg-shell-protocol.c" $INC $LIB

echo "==> wlprobe"
x86_64-quark-musl-gcc -O2 -o "$OUT/wlprobe" "$HERE/wlprobe.c" \
    "$OUT/xdg-shell-protocol.c" "$OUT/xdg-decoration-unstable-v1-protocol.c" \
    $INC $LIB

# Without libwayland, which would refuse to send most of what this sends: it
# writes the wire format itself, to see whether the compositor survives it.
echo "==> wlfuzz"
x86_64-quark-musl-gcc -O2 -o "$OUT/wlfuzz" "$HERE/wlfuzz.c"

# Drawn with cairo, once build-cairo.sh has installed it, and written with the
# font stack under it. Linked without the debug information cairo and pixman
# were built with, which is four fifths of the file; the symbols stay, so a
# fault's address can still be named.
if [ -f "$PREFIX/lib/libcairo.a" ]; then
    echo "==> wlcairo"
    x86_64-quark-musl-gcc -O2 -Wl,--strip-debug -o "$OUT/wlcairo" \
        "$HERE/wlcairo.c" "$OUT/xdg-shell-protocol.c" \
        $INC -lcairo -lpixman-1 -lfontconfig -lfreetype -lexpat -lz -lm $LIB
fi

if [ -n "$WESTON_SRC" ]; then
    # weston-simple-shm, from Weston's tree and not touched.
    #
    # What is supplied around it is scaffolding its own build system supplies:
    # a config.h, the protocol code its meson.build generates, and the shared
    # helper it links. The client itself compiles as it ships -- if it needed
    # changing to run here, that would be a compositor bug and the change would
    # belong in the compositor.
    echo "==> weston-simple-shm"
    cat > "$OUT/config.h" <<'CFG'
/* What Weston's meson build would generate. Only what its clients read. */
#define PACKAGE_STRING "weston 13.0.0"
#define HAVE_MEMFD_CREATE 1
#define HAVE_POSIX_FALLOCATE 1
CFG
    # Weston's own tree is on the include path at its root only. Adding
    # shared/ as well would put its `signal.h` -- a helper about listeners, not
    # about signals -- ahead of the C library's, and the client would compile
    # against the wrong one of the two.
    # -D_GNU_SOURCE is what Weston's own meson passes, and what memfd_create
    # and MFD_ALLOW_SEALING are behind in musl's headers.
    x86_64-quark-musl-gcc -O2 -D_GNU_SOURCE -o "$OUT/weston-simple-shm" \
        "$WESTON_SRC/clients/simple-shm.c" \
        "$WESTON_SRC/shared/os-compatibility.c" \
        "$OUT/xdg-shell-protocol.c" \
        "$OUT/fullscreen-shell-unstable-v1-protocol.c" \
        -I"$WESTON_SRC" -I"$WESTON_SRC/include" \
        $INC $LIB
fi

echo
echo "built into $OUT; stage with"
echo "  make hd WAYLAND_CLIENTS=$OUT"
