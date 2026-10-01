#!/bin/sh
# Write the specs file and the two wrappers that make musl a choice the
# compiler knows how to make.
#
#     ./musl-wrappers.sh
#
# build-musl.sh runs this last. It is a script of its own because what it
# writes names three things inside the userland's checkout by absolute path —
# the C library's headers, `manifest.o` and `liblinux-abi.a` — so when that
# checkout moves, these have to be written again and musl does not have to be
# built again. It moved once already: the userland was `quark/user/` and is
# `quarkutils/` now.
#
# Nothing here is compiled. Run it whenever QUARKUTILS_DIR or PREFIX changes,
# or after a compiler upgrade, since the C++ wrapper names the compiler's
# version.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}
# The userland: quark-rt, the C library and the Linux system-call layer. A
# sibling of this repository by default, and made absolute here because a
# specs file is read from wherever the compiler happens to be run.
QUARKUTILS_DIR=${QUARKUTILS_DIR:-$HERE/../../quarkutils}
if [ ! -d "$QUARKUTILS_DIR/linux-abi" ] || [ ! -d "$QUARKUTILS_DIR/libc/include" ]; then
    echo "no userland at $QUARKUTILS_DIR (set QUARKUTILS_DIR)" >&2
    exit 1
fi
QUARKUTILS_DIR=$(cd "$QUARKUTILS_DIR" && pwd)
mkdir -p "$PREFIX/lib"

# Make musl a choice the compiler knows how to make, rather than a pile of
# flags every build system would have to be told. This is what musl-gcc is on
# Linux, and it is what lets `./configure && make` work on software that was
# not written for Quark.
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
-nostdinc -isystem $PREFIX/include -isystem include%s -isystem $QUARKUTILS_DIR/libc/include %(old_cpp_options)

*cc1:
%(cc1_cpu) -nostdinc -isystem $PREFIX/include -isystem include%s -isystem $QUARKUTILS_DIR/libc/include

# crtbegin.o and crtend.o are here for one thing: the first contributes the
# empty .eh_frame the unwinder is handed and a constructor that registers it,
# the second the zero word that ends it. A C++ program that throws walks that
# table to find its handler, and without them the table has no beginning and
# no end. They bracket everything else on the line, which is what makes the
# table one run of frames rather than several.
*startfile:
$PREFIX/lib/crt1.o $PREFIX/lib/crti.o crtbegin.o%s $QUARKUTILS_DIR/linux-abi/src/manifest.o

*endfile:
crtend.o%s $PREFIX/lib/crtn.o

*lib:
$PREFIX/lib/libc.a $QUARKUTILS_DIR/linux-abi/liblinux-abi.a

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

# The same wrapper for C++. The include directories have to be named: the specs
# say -nostdinc, which takes away the compiler's own idea of where its headers
# are, and the C++ ones are among them. They are where build-libstdcxx.sh
# installs them, which is why the version is asked of the compiler rather than
# written down.
GCCVER=$(x86_64-quark-g++ -dumpversion 2>/dev/null || echo unknown)
cat > "$BINDIR/x86_64-quark-musl-g++" <<WRAPXX
#!/bin/sh
# x86_64-quark, with musl and libstdc++.
#
# The argument rotation is the C wrapper's, for the same reasons; see it.
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
exec x86_64-quark-g++ -specs="$PREFIX/lib/musl-quark.specs" \
	-isystem "$PREFIX/include/c++/$GCCVER" \
	-isystem "$PREFIX/include/c++/$GCCVER/x86_64-quark" \
	-isystem "$PREFIX/include/c++/$GCCVER/backward" "\$@"
WRAPXX
chmod +x "$BINDIR/x86_64-quark-musl-g++"

echo "wrote $PREFIX/lib/musl-quark.specs"
echo "      $BINDIR/x86_64-quark-musl-gcc"
echo "      $BINDIR/x86_64-quark-musl-g++"
echo "against the userland in $QUARKUTILS_DIR"
