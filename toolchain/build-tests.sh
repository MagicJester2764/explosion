#!/bin/sh
# Build the C library's own tests: small programs that check a piece of the
# platform a ported library leans on, rather than any one library.
#
#     ./build-tests.sh [outdir]
#
# They exist because every port so far has found a lie in the C library that
# nothing else had noticed — fcntl answering 0 to everything, close doing
# nothing, thread-locals landing outside their block — and each was only
# caught because a real program tripped it. A test per lie keeps it caught.
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
for src in "$HERE"/tests/*.c; do
    name=$(basename "$src" .c)
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
    x86_64-quark-musl-gcc -O2 -o "$OUT/$name" "$src" $flags
done
# The lists runtests reads, staged beside the programs they name.
cp "$HERE"/tests/*.tests "$OUT"/ 2>/dev/null || true
echo "built into $OUT"
