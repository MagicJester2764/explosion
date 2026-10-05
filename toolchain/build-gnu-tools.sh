#!/bin/sh
# Build the GNU programs a build on Quark runs — bash, make, sed, grep,
# gawk, diffutils and findutils — laid out as a root for an image to carry.
#
#     ./build-gnu-tools.sh <outdir>
#
# The kernel's and the userland's Makefiles, and the scripts they run, are
# written for a POSIX shell, make, and Unix's text tools: a system that
# builds itself has to have them. coreutils is build-coreutils.sh's, and is
# staged with COREUTILS. Quark's own shell stays /bin/sh; a build runs
# `make SHELL=/usr/bin/bash`, and bash runs a script it is handed as one.
#
# Each comes from its tarball in $QUARK_SRC (~/opt/src), checked against its
# signature when it was fetched, and unpacked fresh under build-gnu-tools-quark
# here. Its config.sub is taught quark, it is configured for x86_64-quark
# with the musl compiler and built, and its programs go into <outdir> as
# usr/bin/..., stripped. Nothing in any of them is patched:
#
#   - what configure cannot find out without running a program on Quark it
#     is told, by gnu-tools.site — bash's above all;
#   - gnulib's one file that asks which C library it is compiled against is
#     told, by coreutils-musl.mk, as coreutils' is;
#   - make's configure tests the compiler with C written before C23, so it
#     is told which C it is.
set -e
OUT=${1:?usage: build-gnu-tools.sh <outdir>}
SRC=${QUARK_SRC:-$HOME/opt/src}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT/usr/bin"
OUT=$(cd "$OUT" && pwd)
WORK=$(pwd)/build-gnu-tools-quark
JOBS=${JOBS:-$(nproc)}
export CONFIG_SITE="$HERE/gnu-tools.site"
STRIP=${STRIP:-x86_64-quark-strip}

# build NAME TARBALL CONFIG.SUB -- PROGRAM... -- CONFIGURE-ARGUMENT...
build() {
    name=$1 tarball=$2 sub=$3
    shift 4
    programs=
    while [ "$1" != -- ]; do
        programs="$programs $1"
        shift
    done
    shift
    echo "==> $name"
    mkdir -p "$WORK"
    rm -rf "$WORK/$name"
    mkdir "$WORK/$name"
    tar -C "$WORK/$name" -xf "$SRC/$tarball"
    src=$(cd "$WORK/$name"/* && pwd)
    sh "$HERE/teach-config-sub.sh" "$src/$sub"
    (cd "$src" && ./configure --host=x86_64-quark --prefix=/usr CC=x86_64-quark-musl-gcc "$@" &&
        MAKEFILES="$HERE/coreutils-musl.mk" make -j"$JOBS")
    for p in $programs; do
        cp "$src/$p" "$OUT/usr/bin/$(basename "$p")"
        "$STRIP" "$OUT/usr/bin/$(basename "$p")"
    done
}

build bash bash-5.3.tar.gz support/config.sub -- bash -- \
    CPPFLAGS=-DNEED_EXTERN_PC --without-bash-malloc --disable-nls --enable-static-link
build make make-4.4.1.tar.gz build-aux/config.sub -- make -- \
    CFLAGS="-O2 -std=gnu17" --disable-nls --without-guile --disable-load
build sed sed-4.10.tar.xz build-aux/config.sub -- sed/sed -- \
    --disable-nls --disable-acl --without-selinux
build grep grep-3.12.tar.xz build-aux/config.sub -- src/grep -- \
    --disable-nls --disable-perl-regexp
build gawk gawk-5.4.1.tar.xz build-aux/config.sub -- gawk -- \
    --disable-nls --disable-extensions --without-readline --without-mpfr
build diffutils diffutils-3.12.tar.xz build-aux/config.sub -- src/diff src/cmp src/diff3 src/sdiff -- \
    --disable-nls
build findutils findutils-4.11.0.tar.xz build-aux/config.sub -- find/find xargs/xargs -- \
    --disable-nls --without-selinux

# awk is gawk by another name, as on a GNU system: a copy, because FAT32
# has no links.
cp "$OUT/usr/bin/gawk" "$OUT/usr/bin/awk"
echo
echo "built into $OUT/usr/bin: $(ls "$OUT/usr/bin" | tr '\n' ' ')"
