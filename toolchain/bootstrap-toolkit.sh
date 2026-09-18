#!/bin/sh
# Fetch what a toolkit is built from, above the font stack.
#
#     ./toolchain/bootstrap-toolkit.sh
#
# Idempotent, and every tarball is checked against the SHA-256 it was tested
# with, for the same reason bootstrap-fonts.sh does it: a mirror serving
# something else should stop here rather than an hour into a build.
#
# The builds are separate scripts, run in this order because each needs the one
# before: build-pcre2.sh, build-glib.sh, build-harfbuzz.sh, build-fribidi.sh,
# build-pango.sh. They stand on bootstrap-fonts.sh's freetype, fontconfig and
# cairo, and on bootstrap-wayland.sh's libffi.
set -e

SRC=${QUARK_SRC:-$HOME/opt/src}
mkdir -p "$SRC"

# fetch <url> <tarball> <sha256> <the directory it unpacks as>
fetch() {
    url=$1
    tarball=$SRC/$2
    sum=$3
    dir=$4
    if [ ! -f "$tarball" ] && [ ! -d "$SRC/$dir" ]; then
        echo "==> fetching $2"
        curl -fsSL -o "$tarball.part" "$url"
        mv "$tarball.part" "$tarball"
    fi
    if [ -f "$tarball" ] && ! echo "$sum  $tarball" | sha256sum -c --status -; then
        echo "$tarball is not the file this was tested with (sha256 $sum)" >&2
        exit 1
    fi
    if [ -d "$SRC/$dir" ]; then
        echo "==> $dir already unpacked"
        return
    fi
    echo "==> unpacking $dir"
    tar -C "$SRC" -xf "$tarball"
}

# PCRE2 first: GRegex is PCRE2 with a GLib face on it, and glib's build will
# not start without it.
fetch https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.bz2 \
    pcre2-10.44.tar.bz2 \
    d34f02e113cf7193a1ebf2770d3ac527088d485d4e047ed10e5d217c6ef5de96 \
    pcre2-10.44
fetch https://download.gnome.org/sources/glib/2.82/glib-2.82.5.tar.xz \
    glib-2.82.5.tar.xz \
    05c2031f9bdf6b5aba7a06ca84f0b4aced28b19bf1b50c6ab25cc675277cbc3f \
    glib-2.82.5
# harfbuzz is C++, which is what build-libstdcxx.sh is for.
fetch https://github.com/harfbuzz/harfbuzz/releases/download/10.1.0/harfbuzz-10.1.0.tar.xz \
    harfbuzz-10.1.0.tar.xz \
    6ce3520f2d089a33cef0fc48321334b8e0b72141f6a763719aaaecd2779ecb82 \
    harfbuzz-10.1.0
fetch https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz \
    fribidi-1.0.16.tar.xz \
    1b1cde5b235d40479e91be2f0e88a309e3214c8ab470ec8a2744d82a5a9ea05c \
    fribidi-1.0.16
fetch https://download.gnome.org/sources/pango/1.54/pango-1.54.0.tar.xz \
    pango-1.54.0.tar.xz \
    8a9eed75021ee734d7fc0fdf3a65c3bba51dfefe4ae51a9b414a60c70b2d1ed8 \
    pango-1.54.0

echo
echo "Sources are in $SRC. Build them in this order:"
echo "    ./build-pcre2.sh    $SRC/pcre2-10.44"
echo "    ./build-glib.sh     $SRC/glib-2.82.5"
echo "    ./build-harfbuzz.sh $SRC/harfbuzz-10.1.0"
echo "    ./build-fribidi.sh  $SRC/fribidi-1.0.16"
echo "    ./build-pango.sh    $SRC/pango-1.54.0"
