#!/bin/sh
# Build pixman for Quark: the generic C path, a static library, and the test
# suite, which is how the port is checked.
#
#     ./build-pixman.sh /path/to/pixman-0.44.2 [test-outdir]
#
# Installs libpixman-1.a, pixman.h and pixman-1.pc into the musl prefix, where
# cairo's build finds them. The test programs named in pixman.tests, and the
# list itself, go to test-outdir, which is a TEST_SUITES directory:
#
#     make hd TEST_SUITES=<test-outdir>
#     runtests /etc/pixman.tests            # on Quark
#
# The SIMD paths stay off. They are chosen at run time by cpuid and each is a
# performance change to measure on its own, not part of getting pixman to work.
#
# Porting pixman found eight platform bugs, none of them in pixman. Five came
# from the first program: the specs file dropped the compiler's own headers,
# tasks shared their SSE registers, musl could not find its thread-local
# template, a failed assert halted the machine, and no constructor had ever
# run. Three more took the whole suite to find, because each only mattered
# after enough programs: every program a spawner started stayed allocated
# until the spawner exited, a dead program was only reaped when the machine
# next went idle, and a mapping too big for the machine kept what it had got
# before it was refused. Each has a test, here in tests/ or in Quark's dtest.
set -e
SRC=${1:?usage: build-pixman.sh <pixman-src> [test-outdir]}
OUT=${2:-$PWD/pixman-tests}
HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}

CROSS=$(mktemp)
trap 'rm -f "$CROSS"' EXIT
sed -e "s|@WAYLAND_SCANNER@|/bin/false|" -e "s|@HOME@|$HOME|g" \
    "$HERE/meson-cross-quark.ini" > "$CROSS"

cd "$SRC"
rm -rf build-quark
meson setup build-quark --cross-file "$CROSS" --prefix="$PREFIX" \
    -Ddefault_library=static -Db_staticpic=false \
    -Dmmx=disabled -Dsse2=disabled -Dssse3=disabled -Dvmx=disabled \
    -Dloongson-mmi=disabled -Darm-simd=disabled -Dneon=disabled \
    -Da64-neon=disabled -Dmips-dspr2=disabled -Drvv=disabled \
    -Dopenmp=disabled -Dgtk=disabled -Dlibpng=disabled \
    -Ddemos=disabled -Dtests=enabled
ninja -C build-quark
ninja -C build-quark install

mkdir -p "$OUT"
grep -v '^#' "$HERE/pixman.tests" | while read -r t; do
    [ -n "$t" ] && cp "build-quark/test/$t" "$OUT/"
done
cp "$HERE/pixman.tests" "$OUT/"
echo
echo "pixman installed into $PREFIX"
echo "tests in $OUT: make hd TEST_SUITES=$OUT, then runtests /etc/pixman.tests"
