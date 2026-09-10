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
INC="-I$WL_SRC/src -I$WL_SRC/build-quark/src"
LIB="$WL_SRC/build-quark/src/libwayland-client.a -lffi"

echo "==> wlprobe"
x86_64-quark-musl-gcc -O2 -o "$OUT/wlprobe" "$HERE/wlprobe.c" $INC $LIB

echo
echo "built into $OUT; stage with"
echo "  make hd WAYLAND_CLIENTS=$OUT"
