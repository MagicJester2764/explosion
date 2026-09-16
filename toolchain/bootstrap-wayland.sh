#!/bin/sh
# Fetch and build everything a Wayland client for Quark is linked against.
#
#     ./toolchain/bootstrap-wayland.sh
#
# Idempotent, and safe to run on a machine that has just been turned on. It
# exists because the pieces below are not in any repository and are not part of
# the cross toolchain either: they were living in a scratch directory, and a
# reboot took them along with the twenty minutes it costs to work out what they
# were.
#
# Everything lands under $QUARK_SRC (default ~/opt/src), which survives a
# reboot, rather than under /tmp, which does not.
#
# What this does not do: install the cross compiler or musl. See build-musl.sh.
set -e

SRC=${QUARK_SRC:-$HOME/opt/src}
HOSTDEPS=${QUARK_HOSTDEPS:-$SRC/host-deps}
HERE=$(cd "$(dirname "$0")" && pwd)

WAYLAND_VER=1.23.1
WESTON_VER=13.0.0
EXPAT_VER=2.6.4

mkdir -p "$SRC"

fetch() {
    url=$1
    tarball=$SRC/$(basename "$url")
    dir=$2
    if [ -d "$SRC/$dir" ]; then
        echo "==> $dir already unpacked"
        return
    fi
    [ -f "$tarball" ] || curl -fsSL -o "$tarball" "$url"
    echo "==> unpacking $dir"
    tar -C "$SRC" -xf "$tarball"
}

# wayland-scanner needs expat's *headers*, which a distribution's `expat`
# package does not include -- that is `expat-devel`, and this builds a private
# copy rather than requiring one.
if [ ! -f "$HOSTDEPS/lib/pkgconfig/expat.pc" ]; then
    fetch "https://github.com/libexpat/libexpat/releases/download/R_$(echo $EXPAT_VER | tr . _)/expat-$EXPAT_VER.tar.xz" "expat-$EXPAT_VER"
    echo "==> host expat"
    (cd "$SRC/expat-$EXPAT_VER" && \
        ./configure --prefix="$HOSTDEPS" --disable-shared --enable-static \
                    --without-docbook --without-tests >/dev/null && \
        make -j"$(nproc)" >/dev/null && make install >/dev/null)
fi

fetch "https://gitlab.freedesktop.org/wayland/wayland/-/releases/$WAYLAND_VER/downloads/wayland-$WAYLAND_VER.tar.xz" "wayland-$WAYLAND_VER"
fetch "https://gitlab.freedesktop.org/wayland/weston/-/releases/$WESTON_VER/downloads/weston-$WESTON_VER.tar.xz" "weston-$WESTON_VER"

PKG_CONFIG_PATH="$HOSTDEPS/lib/pkgconfig:$PKG_CONFIG_PATH"
export PKG_CONFIG_PATH

echo "==> libwayland"
sh "$HERE/build-wayland.sh" "$SRC/wayland-$WAYLAND_VER"

cat <<EOF

Ready. To build the clients and stage them:

  WESTON_SRC=$SRC/weston-$WESTON_VER \\
    ./toolchain/build-weston-client.sh $SRC/wayland-$WAYLAND_VER
  make hd WAYLAND_CLIENTS=\$PWD/clients

Both paths are the defaults for those scripts if QUARK_SRC is set.
EOF
