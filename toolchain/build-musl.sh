#!/bin/sh
# Build musl for Quark.
#
#     ./build-musl.sh /path/to/musl-1.2.5
#
# Needs the x86_64-quark toolchain on PATH (build.sh) and the translation
# layer built (`make -C ../../quark/user/linux-abi`).
#
# musl is written against Linux — not against "a kernel", but against Linux's
# numbers, argument order, error convention and idea of what a process is.
# Quark's calls are a different set with different semantics, so this is a
# translation layer rather than a port, and the layer lives in Quark's tree
# where it can talk to the servers that actually answer most of it.
#
# The patch is four files and no more, which is the interesting part: musl's
# system call interface really is that narrow.
set -e

MUSL_SRC=${1:?usage: build-musl.sh <musl-src>}
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}
HERE=$(cd "$(dirname "$0")" && pwd)

echo "==> patching $MUSL_SRC"
( cd "$MUSL_SRC" && patch -p1 -N -r - < "$HERE/patches/musl-1.2.5-quark.patch" || true )

cd "$MUSL_SRC"
./configure --target=x86_64-quark --prefix="$PREFIX" \
    CC=x86_64-quark-gcc --disable-shared
make
make install

# Make musl a choice the compiler knows how to make, rather than a pile of
# flags every build system would have to be told. This is what musl-gcc is on
# Linux, and it is what lets `./configure && make` work on software that was
# not written for Quark.
QUARK_SRC=${QUARK_SRC:-$HERE/../../quark}
cat > "$PREFIX/lib/musl-quark.specs" <<SPECS
# musl as the C library for x86_64-quark.
#
# Only the pieces that say *which* library are overridden. The link spec is
# left alone on purpose: the base address, the link script, static and non-PIE
# are properties of Quark and are the same whichever libc is on top.

%rename cpp_options old_cpp_options

*cpp_options:
-nostdinc -isystem $PREFIX/include -isystem $QUARK_SRC/user/libc/include %(old_cpp_options)

*cc1:
%(cc1_cpu) -nostdinc -isystem $PREFIX/include -isystem $QUARK_SRC/user/libc/include

*startfile:
$PREFIX/lib/crt1.o $PREFIX/lib/crti.o $QUARK_SRC/user/linux-abi/src/manifest.o

*endfile:
$PREFIX/lib/crtn.o

*lib:
$PREFIX/lib/libc.a $QUARK_SRC/user/linux-abi/liblinux-abi.a
SPECS

BINDIR=$(dirname "$(command -v x86_64-quark-gcc)")
cat > "$BINDIR/x86_64-quark-musl-gcc" <<WRAP
#!/bin/sh
# x86_64-quark, with musl as its C library.
exec x86_64-quark-gcc -specs="$PREFIX/lib/musl-quark.specs" "\$@"
WRAP
chmod +x "$BINDIR/x86_64-quark-musl-gcc"

echo
echo "Done. Programs build with no flags at all:"
echo "    x86_64-quark-musl-gcc hello.c -o hello"
