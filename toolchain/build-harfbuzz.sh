#!/bin/sh
# Build harfbuzz for Quark: text shaping, static.
#
#     ./build-harfbuzz.sh /path/to/harfbuzz-10.1.0
#
# Shaping is what turns a string and a font into positioned glyphs, and it is
# not a table lookup: ligatures, kerning, marks and the scripts that join are
# all here. pango needs it, so GTK needs it, and so would Qt.
#
# harfbuzz is C++, which is the whole reason build-libstdcxx.sh exists. It is
# built without exceptions or RTTI, which is what harfbuzz asks for itself.
#
# ICU is off: it is a second, larger, copy of the Unicode tables, and
# harfbuzz's own are enough for what runs here. The glib integration is on
# because pango uses it for the Unicode functions.
set -e

SRC=${1:?usage: build-harfbuzz.sh <harfbuzz-src>}
HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}

CROSS=$(mktemp)
trap 'rm -f "$CROSS"' EXIT
sed -e "s|@WAYLAND_SCANNER@|/bin/false|" -e "s|@HOME@|$HOME|g" \
    "$HERE/meson-cross-quark.ini" > "$CROSS"
# glib-mkenums and glib-genmarshal are Python scripts that run on the build
# machine and write C. They are installed with glib, in the target prefix,
# because that is where glib was installed — and without them on PATH meson
# falls back to building glib's own subproject, which `--wrap-mode=nofallback`
# does not prevent for a *program*.
# glib's tools, native ones first: `glib-compile-resources` and
# `glib-compile-schemas` are C programs, and the copies in the target prefix
# are Quark binaries that cannot run here.
HOSTDEPS=${QUARK_HOSTDEPS:-$HOME/opt/src/host-deps}
PATH="$HOSTDEPS/bin:$PREFIX/bin:$PATH"
export PATH

cd "$SRC"
rm -rf build-quark
meson setup build-quark --cross-file "$CROSS" --prefix="$PREFIX" \
    --buildtype=debugoptimized -Ddefault_library=static -Db_staticpic=false \
    --wrap-mode=nofallback \
    -Dtests=disabled -Ddocs=disabled -Dintrospection=disabled \
    -Dutilities=disabled -Dbenchmark=disabled \
    -Dglib=enabled -Dgobject=enabled -Dfreetype=enabled -Dcairo=enabled \
    -Dicu=disabled -Dgraphite2=disabled -Dchafa=disabled
ninja -C build-quark
ninja -C build-quark install
echo
echo "harfbuzz installed into $PREFIX"

# The same harfbuzz for the build machine, with everything optional off, so
# that tests/hbtest.c can be run here and the numbers it expects come from the
# shaper rather than from somebody's judgement. Its own OpenType parser reads
# the font, so this build needs nothing else.
HOST=$SRC/build-host
DEJAVU=${DEJAVU:-$HOME/opt/src/dejavu-fonts-ttf-2.37/ttf}
[ -d "$DEJAVU" ] || exit 0
rm -rf "$HOST"
meson setup "$HOST" --prefix="$HOST/root" --libdir=lib \
    --buildtype=debugoptimized -Ddefault_library=static \
    --wrap-mode=nofallback \
    -Dtests=disabled -Ddocs=disabled -Dintrospection=disabled \
    -Dutilities=disabled -Dbenchmark=disabled \
    -Dglib=disabled -Dgobject=disabled -Dfreetype=disabled -Dcairo=disabled \
    -Dicu=disabled -Dgraphite2=disabled -Dchafa=disabled
ninja -C "$HOST" >/dev/null
ninja -C "$HOST" install >/dev/null
FLAGS=$(PKG_CONFIG_PATH="$HOST/root/lib/pkgconfig" pkg-config --cflags --libs --static harfbuzz)
# shellcheck disable=SC2086
cc -O2 -DDEJAVU="\"$DEJAVU/DejaVuSans.ttf\"" -o "$HOST/hbtest" "$HERE/tests/hbtest.c" $FLAGS -lm
echo
echo "on the host, which is what tests/hbtest.c should expect:"
"$HOST/hbtest" || true
