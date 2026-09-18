#!/bin/sh
# Link a GTK program for Quark against build-gtk.sh's static libraries.
#
#     ./build-gtk-client.sh /path/to/gtk-4.16.7 [outdir]
#
# GTK 4 has no static build — `gtk/meson.build` says `shared_library` with no
# choice about it — so build-gtk.sh builds the static halves the shared one is
# made of and this links a program against them, the way
# build-weston-toytoolkit.sh links against weston's build tree.
#
# The program is `examples/hello/hello-world.c` from GTK's own documentation:
# somebody else's program, against somebody else's toolkit, unmodified.
set -e

SRC=${1:?usage: build-gtk-client.sh <gtk-src> [outdir]}
OUT=${2:-$PWD/clients}
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}
BUILD=$SRC/build-quark

[ -f "$BUILD/gtk/libgtk.a" ] || { echo "no $BUILD/gtk/libgtk.a — run build-gtk.sh" >&2; exit 1; }
mkdir -p "$OUT"

pc() {
    PKG_CONFIG_PATH= PKG_CONFIG_SYSROOT_DIR= \
        PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig" pkg-config "$@"
}

DEPS="gio-2.0 gobject-2.0 gmodule-2.0 pangocairo pangoft2 cairo-gobject
      gdk-pixbuf-2.0 graphene-gobject-1.0 harfbuzz harfbuzz-subset fribidi
      epoxy xkbcommon wayland-client wayland-cursor wayland-egl
      libpng libjpeg libtiff-4 fontconfig freetype2"

# GTK's own headers come from the source and the build tree, because nothing
# was installed: `gtk/gtk.h` is in the first and the generated `gtkconfig.h`,
# `gdkconfig.h` and `gtkversion.h` are in the second.
# shellcheck disable=SC2086
INC="-I$SRC -I$BUILD -I$SRC/gtk -I$BUILD/gtk -I$SRC/gdk -I$BUILD/gdk \
     -I$SRC/gsk -I$BUILD/gsk $(pc --cflags $DEPS)"

# The static halves, inside a group: gtk calls gdk, gdk calls gsk, gsk calls
# gtk's CSS machinery, and a linker walking the list once resolves none of it.
GTK_LIBS="$BUILD/gtk/libgtk.a $BUILD/gtk/css/libgtk_css.a \
          $BUILD/gsk/libgsk.a $BUILD/gsk/libgsk_f16c.a \
          $BUILD/gdk/libgdk.a $BUILD/gdk/wayland/libgdk-wayland.a \
          $BUILD/gdk/wayland/cursor/libwayland+cursor.a"
# shellcheck disable=SC2086
LIBS="-Wl,--start-group $GTK_LIBS $(pc --libs --static $DEPS) -Wl,--end-group -lm"

# GTK reads its own settings through GSettings, which reads a compiled schema
# file and aborts when it cannot find one. The schemas are XML in GTK's source
# and glib's; `glib-compile-schemas` turns a directory of them into the single
# file that is looked for, and it is the native one that runs here.
HOSTDEPS=${QUARK_HOSTDEPS:-$HOME/opt/src/host-deps}
SCHEMAS=$OUT/share/glib-2.0/schemas
echo "==> settings schemas"
mkdir -p "$SCHEMAS"
cp "$SRC"/gtk/*.gschema.xml "$SCHEMAS/"
cp "$HOSTDEPS"/share/glib-2.0/schemas/*.xml "$SCHEMAS/" 2>/dev/null || true
"$HOSTDEPS/bin/glib-compile-schemas" "$SCHEMAS"
# The XML is only the source of the compiled file; the image carries one file.
rm -f "$SCHEMAS"/*.xml
echo "built $SCHEMAS/gschemas.compiled"

PROG=${PROG:-$SRC/examples/hello/hello-world.c}
NAME=$(basename "$PROG" .c)
echo "==> $NAME"
# shellcheck disable=SC2086
x86_64-quark-musl-gcc -O2 -Wl,--strip-debug -Wl,--allow-multiple-definition \
    -o "$OUT/$NAME" "$PROG" $INC $LIBS
echo "built $OUT/$NAME"
