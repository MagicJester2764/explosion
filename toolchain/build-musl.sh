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
# The patch is five files and no more, which is the interesting part: musl's
# system call interface really is that narrow. Four of them are about issuing a
# system call at all; the fifth is `clone`, which is the one place musl asks
# the kernel for something Quark does not have the shape of — Linux has the
# child *return from the same call* on a new stack, and Quark starts a task at
# an entry point. That file becomes a tail call into the translation layer.
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

#
# The include order is musl's, then the compiler's own, then Quark's platform
# headers. -nostdinc removes all three, so each has to be put back, and the
# middle one is the easy one to forget: \`include%s\` is gcc's private directory,
# which holds the intrinsics (xmmintrin.h, cpuid.h), stdatomic.h and the rest of
# what the compiler supplies rather than the C library. musl-gcc on Linux lists
# it in exactly this position. Without it every program using SSE intrinsics or
# C11 atomics fails to compile, which pixman's test suite was the first to do.
# musl comes first so that its stddef.h and friends win over gcc's.

%rename cpp_options old_cpp_options

*cpp_options:
-nostdinc -isystem $PREFIX/include -isystem include%s -isystem $QUARK_SRC/user/libc/include %(old_cpp_options)

*cc1:
%(cc1_cpu) -nostdinc -isystem $PREFIX/include -isystem include%s -isystem $QUARK_SRC/user/libc/include

*startfile:
$PREFIX/lib/crt1.o $PREFIX/lib/crti.o $QUARK_SRC/user/linux-abi/src/manifest.o

*endfile:
$PREFIX/lib/crtn.o

*lib:
$PREFIX/lib/libc.a $QUARK_SRC/user/linux-abi/liblinux-abi.a

# musl ships empty archives for the libraries Unix split out and it did not:
# librt, libpthread, libm, libdl and the rest are all inside libc.a. Somebody
# else's build system will still pass -lrt or -lpthread, so the directory
# holding those stubs has to be searchable — otherwise the link fails looking
# for a library whose contents are already present.
#
# link_libgcc rather than link, because this must precede the user's own -l
# flags on the command line and that spec does.
%rename link_libgcc old_link_libgcc

*link_libgcc:
-L$PREFIX/lib %(old_link_libgcc)
SPECS

BINDIR=$(dirname "$(command -v x86_64-quark-gcc)")
cat > "$BINDIR/x86_64-quark-musl-gcc" <<WRAP
#!/bin/sh
# x86_64-quark, with musl as its C library.
#
# -pthread is dropped rather than passed on. It asks for a separate threading
# library and a feature macro, and musl has neither: threads are in libc. The
# driver would otherwise refuse an option it has no target handling for, which
# stops any build system that asks for threads the usual way.
#
# -fPIC, -fpic, -fPIE, -fpie and -pie are dropped too. Nothing here is a
# shared library or a position-independent executable, and with the large
# code model a program built -fPIC reaches its globals through a GOT whose
# base it never sets up: their addresses come out as zero. libwayland found
# that; zlib's configure adds -fPIC whatever it is told.
#
# The list is rotated rather than rebuilt with eval: an argument like
# -DFOO="a b" loses its quoting the moment eval re-parses it.
n=\$#
while [ "\$n" -gt 0 ]; do
	a=\$1
	shift
	n=\$((n - 1))
	case "\$a" in
	-pthread|-fPIC|-fpic|-fPIE|-fpie|-pie) ;;
	*) set -- "\$@" "\$a" ;;
	esac
done
exec x86_64-quark-gcc -specs="$PREFIX/lib/musl-quark.specs" "\$@"
WRAP
chmod +x "$BINDIR/x86_64-quark-musl-gcc"

echo
echo "Done. Programs build with no flags at all:"
echo "    x86_64-quark-musl-gcc hello.c -o hello"
