#!/bin/sh
# Build D-Bus for Quark: the message bus a session's programs find each other
# on, and the tools that talk to it.
#
#     ./build-dbus.sh /path/to/dbus-1.16.2.tar.xz [outdir]
#
# Takes the tarball, and unpacks a private copy, $QUARK_SRC/dbus-1.16.2-quark,
# afresh every time. Installs two things:
#
#   - the library, its headers and dbus-1.pc into the musl prefix, for what is
#     built against libdbus;
#   - into OUTDIR, laid out like the root (ExplOSion's `dbus/` by default),
#     what a running system carries: dbus-daemon, dbus-send, dbus-monitor,
#     dbus-run-session and dbus-uuidgen, stripped, and the session bus's
#     configuration, with Quark's one line of it (below).
#
# It is configured for the paths it runs at — /usr, /etc and /var — because
# libdbus compiles them in: where the machine's id is, where a session's
# socket goes. The copy in the musl prefix is the same library; its .pc file
# is rewritten to say where it is.
#
# Nothing here patches D-Bus. It builds as a Unix that is not Linux, which in
# D-Bus's eyes it is — Quark's compiler defines no __linux__ — and that
# decides three things:
#
#   epoll    D-Bus's epoll(4) backend stops at an #error without __linux__.
#            It polls with poll(2) instead, as it does on every other Unix.
#   sockets  there is no abstract namespace: unix:tmpdir= makes a socket on a
#            path in /tmp, which is where the session bus listens.
#   peers    who is connecting is asked of the socket with SO_PEERCRED, which
#            the C layer answers for a local socket.
#
# No system bus is run, and nothing for systemd, launchd, X11, SELinux,
# AppArmor or the audit log is built.
set -e
TARBALL=${1:?usage: build-dbus.sh <dbus-tarball> [outdir]}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${2:-$HERE/../dbus}
SRC=${QUARK_SRC:-$HOME/opt/src}
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}
TARBALL=$(cd "$(dirname "$TARBALL")" && pwd)/$(basename "$TARBALL")
TREE=$SRC/$(basename "$TARBALL" | sed 's/\.tar\..*$//')-quark
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

rm -rf "$TREE"
mkdir -p "$TREE"
tar -C "$TREE" --strip-components=1 -xf "$TARBALL"
cd "$TREE"

CROSS=$(mktemp)
trap 'rm -f "$CROSS"' EXIT
sed -e "s|@WAYLAND_SCANNER@|/bin/false|" -e "s|@HOME@|$HOME|g" \
    "$HERE/meson-cross-quark.ini" > "$CROSS"

meson setup build-quark --cross-file "$CROSS" \
    --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
    --buildtype=release -Ddefault_library=static -Db_staticpic=false \
    --wrap-mode=nofallback -Drelocation=disabled \
    -Depoll=disabled -Dinotify=enabled -Dkqueue=disabled \
    -Dsystemd=disabled -Duser_session=false -Dlaunchd=disabled \
    -Dx11_autolaunch=disabled -Dselinux=disabled -Dapparmor=disabled \
    -Dlibaudit=disabled -Dmodular_tests=disabled \
    -Ddoxygen_docs=disabled -Dducktype_docs=disabled -Dxml_docs=disabled \
    -Dqt_help=disabled
ninja -C build-quark -j"${JOBS:-$(nproc)}"
STAGE=$TREE/stage
DESTDIR=$STAGE meson install -C build-quark --no-rebuild >/dev/null

# The library, for what is built against it.
mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$PREFIX/lib/dbus-1.0"
cp "$STAGE/usr/lib/libdbus-1.a" "$PREFIX/lib/"
rm -rf "$PREFIX/include/dbus-1.0" "$PREFIX/lib/dbus-1.0/include"
cp -R "$STAGE/usr/include/dbus-1.0" "$PREFIX/include/"
cp -R "$STAGE/usr/lib/dbus-1.0/include" "$PREFIX/lib/dbus-1.0/"
sed -e "s|^prefix=.*|prefix=$PREFIX|" "$STAGE/usr/lib/pkgconfig/dbus-1.pc" \
    > "$PREFIX/lib/pkgconfig/dbus-1.pc"

# What a system carries. Made fresh: a program that is no longer built must
# not stay behind in a tracked directory.
rm -rf "$OUT/usr" "$OUT/etc"
mkdir -p "$OUT/usr/bin" "$OUT/usr/share/dbus-1"
for p in dbus-daemon dbus-send dbus-monitor dbus-run-session dbus-uuidgen; do
    x86_64-quark-strip -o "$OUT/usr/bin/$p" "$STAGE/usr/bin/$p"
done
cp "$STAGE/usr/share/dbus-1/session.conf" "$OUT/usr/share/dbus-1/"

# How a session bus is told who is connecting. libdbus's programs say it by
# EXTERNAL: the bus asks the socket (SO_PEERCRED) and compares. GLib's GDBus
# does too, but only where GLib knows how a platform passes credentials,
# which it decides by macro, and Quark is not one it knows: it says it is
# user -1, and a bus that takes EXTERNAL alone — D-Bus's default — refuses
# it. So the session bus also takes DBUS_COOKIE_SHA1, which proves the same
# thing, that the caller is the bus's user, by a cookie in that user's home,
# which nobody else can read. This is configuration, in the place D-Bus
# keeps for it, and not a change to either.
mkdir -p "$OUT/etc/dbus-1/session.d"
cat > "$OUT/etc/dbus-1/session.d/quark.conf" <<'CONF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <!-- GLib says who it is by EXTERNAL only where it knows how the platform
       passes credentials, and Quark is not one it knows. The cookie proves
       the same thing by a file in the user's home. -->
  <auth>EXTERNAL</auth>
  <auth>DBUS_COOKIE_SHA1</auth>
</busconfig>
CONF
echo
echo "dbus: libdbus-1.a into $PREFIX, and the bus and its tools into $OUT"
