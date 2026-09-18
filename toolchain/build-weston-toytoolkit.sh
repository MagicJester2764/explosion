#!/bin/sh
# Build weston's toytoolkit and the clients made from it, for Quark.
#
#     ./build-weston-toytoolkit.sh /path/to/wayland-1.23.1 [outdir]
#
# `clients/window.c` is the toolkit every weston client that has a window is
# written against: it holds the display connection, the event loop, the
# decorations, the input and the surfaces, and `clients/terminal.c` is one
# program on top of it. It is not a library anybody ships, which is exactly
# why it is the right thing to port — it is ordinary client code, written
# against Wayland and POSIX and nothing else, and everything it wants that
# Quark has not got is a hole in Quark.
#
# Nothing here patches weston. The sources are compiled as they are, and what
# they need is added to the system: `fork`, `execve`, a pty, `timerfd` and
# libpng were all found this way.
#
# Weston builds with meson and a generated `config.h`; this writes the small
# part of it these files read, because setting meson up to cross-compile a
# project whose libweston half cannot build here would be a larger thing than
# the eight files that are actually wanted.
set -e

WL_SRC=${1:?usage: build-weston-toytoolkit.sh <wayland-src> [outdir]}
OUT=${2:-$PWD/clients}
HERE=$(cd "$(dirname "$0")" && pwd)
WESTON_SRC=${WESTON_SRC:-$HOME/opt/src/weston-13.0.0}
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}
PROTO_DIR=${WAYLAND_PROTOCOLS:-/usr/share/qt6/wayland/protocols}
SCANNER=$WL_SRC/build-native/src/wayland-scanner

if [ ! -d "$WESTON_SRC/clients" ]; then
    echo "no weston sources at $WESTON_SRC; set WESTON_SRC" >&2
    exit 1
fi

mkdir -p "$OUT" "$OUT/toytoolkit"
BUILD=$OUT/toytoolkit

pc() {
    PKG_CONFIG_PATH= PKG_CONFIG_SYSROOT_DIR= \
        PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" pkg-config "$@"
}

# Where a protocol's XML might be. Distributions disagree: Qt ships a
# directory per protocol with no stable/unstable split, wayland-protocols
# itself has one, and a flatpak runtime has the whole tree under its own
# prefix. `WAYLAND_PROTOCOLS` is searched first when it is set, so one that
# has everything ends the argument.
ROOTS="$PROTO_DIR
$WESTON_SRC/protocol
/usr/share/wayland-protocols
/var/lib/flatpak/runtime/org.freedesktop.Sdk/x86_64/*/*/files/share/wayland-protocols"

xml_for() {
    for root in $ROOTS; do
        [ -d "$root" ] || continue
        found=$(find "$root" -name "$1" -print -quit 2>/dev/null)
        if [ -n "$found" ]; then
            printf '%s\n' "$found"
            return 0
        fi
    done
    echo "no $1 anywhere; set WAYLAND_PROTOCOLS" >&2
    exit 1
}

stubs() {
    xml=$(xml_for "$1")
    name=$2
    "$SCANNER" client-header "$xml" "$BUILD/$name-client-protocol.h"
    "$SCANNER" private-code  "$xml" "$BUILD/$name-protocol.c"
}

echo "==> protocol stubs"
stubs xdg-shell.xml xdg-shell
stubs viewporter.xml viewporter
stubs relative-pointer-unstable-v1.xml relative-pointer-unstable-v1
stubs pointer-constraints-unstable-v1.xml pointer-constraints-unstable-v1
stubs tablet-unstable-v2.xml tablet-unstable-v2
stubs text-cursor-position.xml text-cursor-position
stubs ivi-application.xml ivi-application

# The part of weston's generated config.h that these files read. Everything
# absent is absent on purpose: no JPEG or WebP loader, no libseat, no systemd,
# and no resize pool — the compositor here refuses `wl_shm_pool.resize`, and
# the toolkit's own path makes a new pool instead.
cat > "$BUILD/config.h" <<'CONFIG'
#define PACKAGE_STRING "weston 13.0.0"
#define PACKAGE_VERSION "13.0.0"
#define VERSION "13.0.0"
#define HAVE_MEMFD_CREATE 1
#define HAVE_POSIX_FALLOCATE 1
#define HAVE_MKOSTEMP 1
#define HAVE_STRCHRNUL 1
#define HAVE_XKBCOMMON_COMPOSE 1
#define HAVE_INITIALIZE_TLS 0
CONFIG

# Deliberately not `-I$WESTON_SRC/shared`: weston has a `shared/signal.h` of
# its own, and on the include path it answers `#include <signal.h>` — which is
# how a terminal ends up without `sigaction`. Its own build includes those
# headers by their directory, and so does this.
INC="-I$BUILD -I$WESTON_SRC -I$WESTON_SRC/include \
     -I$WL_SRC/src -I$WL_SRC/build-quark/src -I$WL_SRC/cursor"
# The paths weston's build normally passes on the command line. They are where
# a Quark image puts them, which is where the terminal will look for its
# configuration and its data.
PATHS="-DDATADIR=\"/usr/share\" -DCONFIGDIR=\"/etc/xdg/weston\" \
       -DLIBEXECDIR=\"/usr/libexec\" -DBINDIR=\"/usr/bin\" \
       -DMODULEDIR=\"/usr/lib/weston\""
CFLAGS="-O2 -D_GNU_SOURCE -DHAVE_CONFIG_H $PATHS $INC $(pc --cflags cairo pixman-1 xkbcommon) -Wno-unused-result"

CC=x86_64-quark-musl-gcc

echo "==> weston's shared pieces"
SHARED="config-parser option-parser signal file-util os-compatibility process-util hash \
        matrix cairo-util frame image-loader"
OBJS=""
for f in $SHARED; do
    src=$WESTON_SRC/shared/$f.c
    [ -f "$src" ] || { echo "missing $src" >&2; exit 1; }
    # shellcheck disable=SC2086
    $CC $CFLAGS -c "$src" -o "$BUILD/$f.o"
    OBJS="$OBJS $BUILD/$f.o"
done

echo "==> the toytoolkit"
# shellcheck disable=SC2086
$CC $CFLAGS -c "$WESTON_SRC/clients/window.c" -o "$BUILD/window.o"
for p in xdg-shell viewporter relative-pointer-unstable-v1 \
         pointer-constraints-unstable-v1 tablet-unstable-v2 \
         text-cursor-position ivi-application; do
    # shellcheck disable=SC2086
    $CC $CFLAGS -c "$BUILD/$p-protocol.c" -o "$BUILD/$p-protocol.o"
    OBJS="$OBJS $BUILD/$p-protocol.o"
done
x86_64-quark-ar rcs "$BUILD/libtoytoolkit.a" "$BUILD/window.o" $OBJS
echo "built $BUILD/libtoytoolkit.a"

# `os_create_anonymous_file` is defined in both weston's `shared/` and
# wayland's `cursor/`, which are the same file copied between two projects.
# On a system with shared libraries the duplicate is invisible; here
# everything is static and the linker has to be told that the two are the same
# function. The rest of each file is needed — weston's has the epoll and
# socketpair helpers, wayland's has the resize one — so neither can simply be
# left out.
MULTI=-Wl,--allow-multiple-definition
LIBS="$BUILD/libtoytoolkit.a \
      $WL_SRC/build-quark/cursor/libwayland-cursor.a \
      $WL_SRC/build-quark/src/libwayland-client.a \
      $(pc --libs --static cairo pixman-1 xkbcommon) -lpng16 -lz -lffi -lm -lutil"

# The images the decorations are made of. `frame_create` loads
# `icon_window.png` and the three signs from `DATADIR/weston`, and *fails* when
# they are not there — a window with no frame is not a window, so the toolkit
# refuses to make one. They are weston's own data files, staged with the
# program rather than built.
echo "==> the decorations' images"
mkdir -p "$OUT/share/weston"
for f in icon_window.png sign_close.png sign_maximize.png sign_minimize.png; do
    cp "$WESTON_SRC/data/$f" "$OUT/share/weston/$f"
done

echo "==> weston-terminal"
# shellcheck disable=SC2086
$CC $CFLAGS $MULTI -Wl,--strip-debug -o "$OUT/weston-terminal" "$WESTON_SRC/clients/terminal.c" $LIBS
echo "built $OUT/weston-terminal"
