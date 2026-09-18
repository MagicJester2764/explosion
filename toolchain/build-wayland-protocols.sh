#!/bin/sh
# Install wayland-protocols into the Quark prefix.
#
#     ./build-wayland-protocols.sh /path/to/wayland-protocols-1.38
#
# There is nothing to compile: the package is XML and a pkg-config file, and
# what reads it is `wayland-scanner`, which runs on this machine. It is
# installed into the target prefix all the same, because that is where a
# cross-compiling build system looks for it — GTK asks pkg-config for
# `wayland-protocols` and then for the directory it names.
#
# The `-Dtests=false` is not optional here: the test suite wants a libwayland
# it can link and run, which is the one thing this prefix cannot provide.
set -e

SRC=${1:?usage: build-wayland-protocols.sh <wayland-protocols-src>}
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}

# The scanner that reads the XML runs on this machine, and its pkg-config file
# is in the host prefix build-wayland.sh installed it into.
HOSTPREFIX=${HOSTPREFIX:-$(cd "$(dirname "$0")/.." && pwd)/host-tools}
for d in "$HOSTPREFIX/lib64/pkgconfig" "$HOSTPREFIX/lib/pkgconfig"; do
    [ -d "$d" ] && PKG_CONFIG_PATH="$d:$PKG_CONFIG_PATH"
done
export PKG_CONFIG_PATH

cd "$SRC"
rm -rf build-quark
meson setup build-quark --prefix="$PREFIX" -Dtests=false
ninja -C build-quark install
echo
echo "wayland-protocols installed into $PREFIX"
