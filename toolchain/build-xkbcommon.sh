#!/bin/sh
# Build libxkbcommon for Quark, and lay out the keymap its clients are sent.
#
#     ./build-xkbcommon.sh /path/to/libxkbcommon-xkbcommon-1.13.2 <overlay-dir>
#
# Installs libxkbcommon.a, xkbcommon.pc and the headers into the musl prefix,
# and copies the compositor's keymap (quark/user/wm/src/us.xkb) to
# <overlay-dir>/usr/share/xkb/us.xkb, for ROOT_OVERLAYS and xkb.tests.
#
# No xkeyboard-config comes with it. A Wayland client is sent a whole keymap
# by the compositor and compiles that; it is building a keymap from rules,
# models and layouts that needs the data files, and nothing here does. The
# data paths are Linux's so that a program which asks for them looks in the
# usual place and finds nothing, rather than somewhere odd.
#
# Only the library is built: libxkbcommon's own tests want those data files.
# The X11, Wayland and registry pieces, the tools and the documentation are
# all off.
set -e
USAGE="usage: build-xkbcommon.sh <libxkbcommon-src> <overlay-dir>"
SRC=${1:?$USAGE}
OVERLAY=${2:?$USAGE}
HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}
KEYMAP=$HERE/../../quark/user/wm/src/us.xkb
[ -f "$KEYMAP" ] || { echo "build-xkbcommon.sh: no $KEYMAP" >&2; exit 1; }
mkdir -p "$OVERLAY"
OVERLAY=$(cd "$OVERLAY" && pwd)

CROSS=$(mktemp)
trap 'rm -f "$CROSS"' EXIT
sed -e "s|@WAYLAND_SCANNER@|/bin/false|" -e "s|@HOME@|$HOME|g" \
    "$HERE/meson-cross-quark.ini" > "$CROSS"

cd "$SRC"
rm -rf build-quark
meson setup build-quark --cross-file "$CROSS" --prefix="$PREFIX" \
    --buildtype=debugoptimized -Ddefault_library=static -Db_staticpic=false \
    --wrap-mode=nofallback -Denable-tools=false -Denable-x11=false \
    -Denable-wayland=false -Denable-xkbregistry=false -Denable-docs=false \
    -Denable-bash-completion=false \
    -Dxkb-config-root=/usr/share/X11/xkb -Dx-locale-root=/usr/share/X11/locale
ninja -C build-quark libxkbcommon.a
meson install -C build-quark --no-rebuild

mkdir -p "$OVERLAY/usr/share/xkb"
cp "$KEYMAP" "$OVERLAY/usr/share/xkb/us.xkb"
echo
echo "libxkbcommon installed into $PREFIX; the keymap is in $OVERLAY/usr/share/xkb"
