#!/bin/sh
# Build the ports' tests: one small program per library, doing the thing the
# library is for on the system it was ported to.
#
#     ./build-tests.sh [outdir]
#
# A port that compiles has said nothing yet. zlib has to inflate what it
# deflated, cairo has to draw, pango has to lay out a line — on Quark, through
# Quark's C library. These are what say so, and the lists beside them
# (`cairo.tests`, `toolkit.tests`, ...) are what `runtests` reads.
#
# The C library's own tests are not here: they are quarkutils'
# (`tools/build-ctests.sh` there), and a suite directory built from each goes
# into an image side by side.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$PWD/tests-out}
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}
mkdir -p "$OUT"
# A test that links a ported library says so on its first line:
#     // LINK: -lcairo -lpixman-1 -lm
# or, for a library whose headers need a -I to be found, names the pkg-config
# modules to ask instead:
#     // PKG: freetype2
# which keeps what each test needs next to the test rather than in here. One
# whose library is not built yet is skipped, and says so, rather than stopping
# the tests that need nothing.
#
# pkg-config looks in the musl prefix and nowhere else: the host's own
# freetype2.pc would otherwise do, and name the host's headers.
pc() {
    PKG_CONFIG_PATH= PKG_CONFIG_SYSROOT_DIR= \
        PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" pkg-config "$@"
}
for src in "$HERE"/tests/*.c "$HERE"/tests/*.cpp; do
    [ -f "$src" ] || continue
    case $src in
    *.cpp) name=$(basename "$src" .cpp); cc=x86_64-quark-musl-g++ ;;
    *)     name=$(basename "$src" .c);   cc=x86_64-quark-musl-gcc ;;
    esac
    flags=$(sed -n '1s|^// LINK: ||p' "$src")
    pkgs=$(sed -n '1s|^// PKG: ||p' "$src")
    missing=
    for f in $flags; do
        case $f in
        -l*) [ -e "$PREFIX/lib/lib${f#-l}.a" ] || missing="$missing ${f#-l}" ;;
        esac
    done
    for m in $pkgs; do
        pc --exists "$m" || missing="$missing $m"
    done
    if [ -n "$missing" ]; then
        echo "==> $name skipped, not built yet:$missing"
        continue
    fi
    # shellcheck disable=SC2086
    [ -z "$pkgs" ] || flags="$flags $(pc --cflags --libs --static $pkgs)"
    echo "==> $name"
    # --strip-debug and not -s: the symbol table is what turns a faulting rip
    # into a function name, and the DWARF behind a statically linked glib is
    # ten megabytes the image has not got.
    $cc -O2 -Wl,--strip-debug -o "$OUT/$name" "$src" $flags
done
# The lists runtests reads, staged beside the programs they name.
cp "$HERE"/tests/*.tests "$OUT"/ 2>/dev/null || true
echo "built into $OUT"
