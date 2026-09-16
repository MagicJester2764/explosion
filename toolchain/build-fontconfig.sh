#!/bin/sh
# Build fontconfig for Quark, with its tools and the configuration it reads.
#
#     ./build-fontconfig.sh /path/to/fontconfig-2.18.3 <suite-dir> <overlay-dir>
#
# Installs libfontconfig.a, fontconfig.pc and the headers into the musl
# prefix; puts the fc-* programs and fontconfig.tests in <suite-dir>, for
# TEST_SUITES; and lays out /etc/fonts and an empty /var/cache/fontconfig in
# <overlay-dir>, for ROOT_OVERLAYS.
#
# It installs through DESTDIR. fontconfig's configuration belongs in the
# target's /etc, so it is configured with --sysconfdir=/etc, and a plain
# install would write into this machine's. The library comes out of the
# staging tree into the prefix and the configuration into the overlay. The
# conf.d entries are links into a conf.avail the image does not carry, so they
# are copied as the files they name.
#
# The cache is not built here (-Dcache-build=disabled): fc-cache is a Quark
# program, and fontconfig.tests runs it on Quark, into /var/cache/fontconfig.
# -Dadditional-fonts-dirs=no because its default looks for X11 font
# directories on the machine doing the build.
#
# gperf is needed while it builds; bootstrap-fonts.sh makes one in
# $QUARK_HOSTDEPS. The one patch teaches src/fcstat.c that Quark's struct
# statfs is Linux's.
set -e
USAGE="usage: build-fontconfig.sh <fontconfig-src> <suite-dir> <overlay-dir>"
SRC=${1:?$USAGE}
SUITE=${2:?$USAGE}
OVERLAY=${3:?$USAGE}
HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}
HOSTDEPS=${QUARK_HOSTDEPS:-${QUARK_SRC:-$HOME/opt/src}/host-deps}
PATH=$HOSTDEPS/bin:$PATH
export PATH
if ! command -v gperf >/dev/null 2>&1; then
    echo "build-fontconfig.sh: no gperf; toolchain/bootstrap-fonts.sh builds one" >&2
    exit 1
fi
mkdir -p "$SUITE" "$OVERLAY"
SUITE=$(cd "$SUITE" && pwd)
OVERLAY=$(cd "$OVERLAY" && pwd)

cd "$SRC"
if ! grep -q __quark__ src/fcstat.c; then
    echo "==> patching $SRC"
    patch -p1 < "$HERE/patches/fontconfig-2.18.3-quark.patch"
fi

CROSS=$(mktemp)
DEST=$(mktemp -d)
trap 'rm -rf "$CROSS" "$DEST"' EXIT
sed -e "s|@WAYLAND_SCANNER@|/bin/false|" -e "s|@HOME@|$HOME|g" \
    "$HERE/meson-cross-quark.ini" > "$CROSS"

rm -rf build-quark
meson setup build-quark --cross-file "$CROSS" --prefix="$PREFIX" \
    --sysconfdir=/etc --localstatedir=/var \
    --buildtype=debugoptimized -Ddefault_library=static -Db_staticpic=false \
    --wrap-mode=nofallback -Dxml-backend=expat -Ddoc=disabled -Dnls=disabled \
    -Dtests=disabled -Dcache-build=disabled -Dtools=enabled \
    -Diconv=disabled -Dfontations=disabled -Dadditional-fonts-dirs=no
ninja -C build-quark
DESTDIR="$DEST" meson install -C build-quark --no-rebuild >/dev/null

# The library, where the ports that use it look.
mkdir -p "$PREFIX/lib" "$PREFIX/include"
cp -R "$DEST$PREFIX/lib/." "$PREFIX/lib/"
cp -R "$DEST$PREFIX/include/." "$PREFIX/include/"

# The tools, and the list that runs them.
n=0
for tool in "$DEST$PREFIX"/bin/fc-*; do
    cp "$tool" "$SUITE/"
    n=$((n + 1))
done
cp "$HERE/tests/fontconfig.tests" "$SUITE/"

# The configuration, and somewhere for the cache to go.
rm -rf "$OVERLAY/etc/fonts" "$OVERLAY/var/cache/fontconfig"
mkdir -p "$OVERLAY/etc/fonts/conf.d" "$OVERLAY/var/cache/fontconfig"
cp "$DEST/etc/fonts/fonts.conf" "$OVERLAY/etc/fonts/"
for conf in "$DEST"/etc/fonts/conf.d/*.conf; do
    cp -L "$conf" "$OVERLAY/etc/fonts/conf.d/"
done

echo
echo "fontconfig installed into $PREFIX"
echo "$n tools in $SUITE, and its configuration in $OVERLAY"
