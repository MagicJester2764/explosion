#!/bin/sh
# Build glib for Quark: GLib, GObject, GModule, GThread and GIO, static.
#
#     ./build-glib.sh /path/to/glib-2.82.5
#
# glib is the floor every GNOME-shaped toolkit stands on, and it is a large
# floor: a main loop, a type system, a thread pool, a virtual filesystem and a
# great deal of assumed Unix. Most of what it assumes Quark now has; what it
# assumed and Quark had not is listed in the plan for this phase, and each of
# those was added to the system rather than configured out of glib.
#
# Nothing here patches glib. The options below turn off things Quark has no
# equivalent of at all (SELinux, systemtap, libmount) and things that are not
# wanted (documentation, introspection, translations).
set -e

SRC=${1:?usage: build-glib.sh <glib-src>}
HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}

CROSS=$(mktemp)
trap 'rm -f "$CROSS"' EXIT
sed -e "s|@WAYLAND_SCANNER@|/bin/false|" -e "s|@HOME@|$HOME|g" \
    "$HERE/meson-cross-quark.ini" > "$CROSS"

# The answers meson cannot get by running a program on the target. Each is a
# fact about musl or about Quark rather than a guess:
#
#   *printf      musl's are C99 and Unix98, so glib uses them instead of
#                compiling its own copy of gnulib's.
#   growing_stack   a Quark stack is a mapping of a fixed size; it does not
#                grow, so glib must not put unbounded things on it.
#   va_val_copy  va_list is copyable by value on x86-64 SysV.
#   have_proc_self_cmdline   there is no /proc.
PROPS=$(mktemp)
trap 'rm -f "$CROSS" "$PROPS"' EXIT
cat > "$PROPS" <<'PROPS_EOF'
have_c99_vsnprintf = true
have_c99_snprintf = true
have_unix98_printf = true
growing_stack = false
va_val_copy = true
have_proc_self_cmdline = false
have_strlcpy = true
PROPS_EOF
# Into `[properties]`, not after the last section: an ini file is read by
# section, and meson takes everything under `[host_machine]` for strings.
awk -v f="$PROPS" '{print} /^\[properties\]$/ {while ((getline l < f) > 0) print l}' \
    "$CROSS" > "$CROSS.new" && mv "$CROSS.new" "$CROSS"

cd "$SRC"
rm -rf build-quark
meson setup build-quark --cross-file "$CROSS" --prefix="$PREFIX" \
    --buildtype=debugoptimized -Ddefault_library=static -Db_staticpic=false \
    --wrap-mode=nofallback \
    -Dselinux=disabled -Dxattr=false -Dlibmount=disabled \
    -Dman-pages=disabled -Ddtrace=disabled -Dsystemtap=disabled \
    -Dsysprof=disabled -Ddocumentation=false -Dintrospection=disabled \
    -Dnls=disabled -Dlibelf=disabled -Dtests=false -Dglib_debug=disabled \
    -Dglib_assert=true -Dglib_checks=true
ninja -C build-quark
ninja -C build-quark install
echo
echo "glib installed into $PREFIX"
