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

echo "==> wlprobe"
x86_64-quark-musl-gcc -O2 -o "$OUT/wlprobe" "$HERE/wlprobe.c" "$OUT/xdg-shell-protocol.c" $INC $LIB

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
