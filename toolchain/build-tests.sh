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
mkdir -p "$OUT"
# A test that links a ported library says so on its first line:
#     // LINK: -lcairo -lpixman-1 -lm
# which keeps what each test needs next to the test rather than in here.
for src in "$HERE"/tests/*.c; do
    name=$(basename "$src" .c)
    flags=$(sed -n '1s|^// LINK: ||p' "$src")
    echo "==> $name"
    x86_64-quark-musl-gcc -O2 -o "$OUT/$name" "$src" $flags
done
# The lists runtests reads, staged beside the programs they name.
cp "$HERE"/tests/*.tests "$OUT"/ 2>/dev/null || true
echo "built into $OUT"
