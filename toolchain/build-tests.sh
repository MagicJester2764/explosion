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
for src in "$HERE"/tests/*.c; do
    name=$(basename "$src" .c)
    echo "==> $name"
    x86_64-quark-musl-gcc -O2 -o "$OUT/$name" "$src"
done
echo "built into $OUT"
