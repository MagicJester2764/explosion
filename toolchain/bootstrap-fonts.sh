#!/bin/sh
# Fetch what the font stack is built from, and the one host tool it needs.
#
#     ./toolchain/bootstrap-fonts.sh
#
# Idempotent. Every tarball is checked against the SHA-256 it was tested with,
# so a mirror serving something else stops here rather than an hour into a
# build. Sources land under $QUARK_SRC (default ~/opt/src); gperf, which
# fontconfig runs while it builds, goes into $QUARK_HOSTDEPS beside the host
# expat that bootstrap-wayland.sh makes.
#
# The builds are separate scripts, run in this order because each needs the
# one before: build-zlib.sh, build-freetype.sh, build-expat.sh,
# build-fontconfig.sh, then build-cairo.sh again for text, and
# build-xkbcommon.sh, which needs none of them.
set -e

SRC=${QUARK_SRC:-$HOME/opt/src}
HOSTDEPS=${QUARK_HOSTDEPS:-$SRC/host-deps}

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

fetch https://zlib.net/zlib-1.3.2.tar.xz \
    zlib-1.3.2.tar.xz \
    d7a0654783a4da529d1bb793b7ad9c3318020af77667bcae35f95d0e42a792f3 \
    zlib-1.3.2
fetch https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.xz \
    freetype-2.14.3.tar.xz \
    36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f \
    freetype-2.14.3
fetch https://github.com/libexpat/libexpat/releases/download/R_2_6_4/expat-2.6.4.tar.xz \
    expat-2.6.4.tar.xz \
    a695629dae047055b37d50a0ff4776d1d45d0a4c842cf4ccee158441f55ff7ee \
    expat-2.6.4
fetch https://gitlab.freedesktop.org/api/v4/projects/890/packages/generic/fontconfig/2.18.3/fontconfig-2.18.3.tar.xz \
    fontconfig-2.18.3.tar.xz \
    4f7b554a38cdf78c033f666c8871f3749e14a094f65a07f630c91ed0b43d35e3 \
    fontconfig-2.18.3
# GitHub names the archive after the tag, and it unpacks under the repository's
# name as well.
fetch https://github.com/xkbcommon/libxkbcommon/archive/refs/tags/xkbcommon-1.13.2.tar.gz \
    libxkbcommon-1.13.2.tar.gz \
    acc4d5f7c3cbba5f9f8d08d8bdbeede84ecede46792f47929aa9321873385528 \
    libxkbcommon-xkbcommon-1.13.2
fetch https://github.com/dejavu-fonts/dejavu-fonts/releases/download/version_2_37/dejavu-fonts-ttf-2.37.tar.bz2 \
    dejavu-fonts-ttf-2.37.tar.bz2 \
    fa9ca4d13871dd122f61258a80d01751d603b4d3ee14095d65453b4e846e17d7 \
    dejavu-fonts-ttf-2.37
fetch https://ftp.gnu.org/gnu/gperf/gperf-3.3.tar.gz \
    gperf-3.3.tar.gz \
    fd87e0aba7e43ae054837afd6cd4db03a3f2693deb3619085e6ed9d8d9604ad8 \
    gperf-3.3

# fontconfig generates a perfect hash of its object names at build time. Few
# machines have gperf installed, and it is small.
if [ ! -x "$HOSTDEPS/bin/gperf" ]; then
    echo "==> host gperf"
    (cd "$SRC/gperf-3.3" && \
        ./configure --prefix="$HOSTDEPS" >/dev/null && \
        make -j"$(nproc)" >/dev/null && make install >/dev/null)
fi

cat <<EOF

Sources are in $SRC and gperf is in $HOSTDEPS/bin. Next:

  ./toolchain/build-zlib.sh $SRC/zlib-1.3.2
EOF
