# The x86_64-quark cross toolchain

`build.sh` turns a binutils and a gcc source tree into a compiler that targets
Quark, installed under `~/opt/cross` by default. Everything else here is a
port built with it: one script per library, each saying at its top what it
takes and what it needed.

In the order they need each other:

| | Scripts | Gives |
|---|---|---|
| The compiler | `build.sh`, then `build-musl.sh`, then `build-libstdcxx.sh` | `x86_64-quark-gcc`, and `x86_64-quark-musl-gcc` and `-g++` for everything below |
| coreutils | `build-coreutils.sh` | 102 programs |
| Wayland | `bootstrap-wayland.sh`, which runs `build-libffi.sh` and `build-wayland.sh` | libwayland, and a scanner that runs here |
| The font stack | `bootstrap-fonts.sh`, then `build-zlib.sh`, `-freetype`, `-expat`, `-fontconfig`, `-pixman`, `-libpng`, `-cairo`, `-xkbcommon`, `stage-fonts.sh` | text on a surface |
| Weston's clients | `build-weston-client.sh`, `build-weston-toytoolkit.sh` | `weston-simple-shm`, `weston-terminal` |
| The toolkit | `bootstrap-toolkit.sh`, then `build-pcre2.sh`, `-glib`, `-harfbuzz`, `-fribidi`, `-pango`, `-graphene`, `-libjpeg`, `-libtiff`, `-gdk-pixbuf`, `-epoxy`, `install-egl-headers.sh`, `build-wayland-protocols.sh`, `build-gtk.sh`, `build-gtk-client.sh`, `stage-xkb.sh` | GTK 4, and `hello-world` |
| Tests | `build-tests.sh` | the C library's suite, as a `TEST_SUITES` directory |

Sources live under `$QUARK_SRC` (`~/opt/src`), the compiler under `~/opt/cross`,
and what a build needs to *run on this machine* — a native glib's tools, a
native `fc-cache`, gperf — under `$QUARK_HOSTDEPS` (`~/opt/src/host-deps`).
None of it is in `/tmp`, which a reboot empties.

**The rule every port follows: nothing patches an upstream program or library.**
If a port needs something, Quark grows it. Teaching a package's `config.sub`
the word `quark` (`teach-config-sub.sh`) is not a patch to the package; it is
a patch to autoconf's idea of what operating systems exist. One port predates
the rule and still carries a patch, small and described below: fontconfig
(one line). coreutils carried one too, and no longer does.

## Why a target and not a pile of flags

Quark is x86-64 and so is every machine this has been built on, so
`-ffreestanding -nostdlib` plus our own headers already produced working
binaries — that is how quarkutils' `libc` and the programs against it were built
before this existed.

What a target triple buys is that the compiler knows the answers itself. A
Quark program loads above 512 GiB, is not relocated, runs with no red zone,
links against a C library called `libc.a`, starts at a `crt0.o` that builds
argv out of a page the spawner maps, and is laid out by a script that belongs
to the system rather than to any one program. Those are properties of the
platform. A build system that was not written for Quark has no way to be told
them, and `./configure` will not accept them from somebody who already knows —
it runs the compiler and believes what happens.

So the difference is not what can be built but what can be *ported*.

## What was changed

Small and in the usual places, the same shape as any other OS target:

- **binutils** — `config.sub` accepts `quark` as an operating system;
  `bfd/config.bfd`, `gas/configure.tgt` and `ld/configure.tgt` map
  `x86_64-*-quark*` onto the ordinary x86-64 ELF vectors. Nothing about the
  object format is unusual, so nothing about it is new.
- **gcc** — the same `config.sub` line, a target in `gcc/config.gcc` built like
  the bare `x86_64-*-elf*` one plus `gcc/config/quark.h`, and the target added
  to `libgcc/config.host`.
- **`gcc/config/quark.h`** — the whole port, and it is short: the default code
  model, red zone and PIC settings; `crt0.o`; `-lc`; the link script by
  absolute path through the sysroot; and `__quark__`.
- **libgcc is built without coverage.** `libgcov` calls `fork` and `exec`,
  and when this was configured Quark had neither. It has both now; coverage
  stays off because nothing has asked for it, and turning it on is one
  `--enable-gcov` and a rebuild.

## The sysroot

`make -C ../../quarkutils/libc install-sysroot` puts the headers, `libc.a`,
`crt0.o` and the link script where the toolchain looks. It has to run *before*
`build.sh`, because gcc compiles its own support library against those headers.

Two gaps in the C library were found by exactly that, and both were real rather
than gcc being fussy: there was no `sys/types.h` and no `time.h`, and `stdio.h`
had no `FILE` — `fprintf` took a descriptor. A library that cannot say
`fprintf(stderr, ...)` is not one anybody can port to.

## C++

`build.sh` builds `c,c++`, which gives `x86_64-quark-g++` and `cc1plus`;
`build-libstdcxx.sh` builds the standard library afterwards, against musl. The
two are separate because gcc's in-tree libstdc++ would be built against the
sysroot's C library — the hand-written `libc` in quarkutils, enough for libgcc and
no more — and libstdc++ wants `wchar.h`, a locale and threads. libstdc++-v3
configures on its own, so it is built like any other port: with the musl
wrapper, for the musl prefix.

The port needed three lines, in the usual places:

- **`libstdc++-v3/crossconfig.m4`** (and the generated `configure`) list the
  hosts libstdc++ knows how to be cross-built for, and an unknown one is
  "No support for this host/target combination". `*-quark*` joins the Linux
  arm, which is the truthful one: the C library underneath is musl.
- **`libgcc/config.host`** builds `crtbegin.o` and `crtend.o` for quark. They
  are not about constructors here — `--enable-initfini-array` puts those in
  `.init_array` — but about `.eh_frame`: crtbegin contributes the empty frame
  table the unwinder is handed and the constructor that registers it, crtend
  the zero word that ends it.
- **Quark's user link script** used to discard `.eh_frame`, which was free
  while nothing unwound. The first C++ `throw` walked a table that was not
  there and took a page fault instead of finding its handler.

`tests/cxxtest.cpp` is the check: a constructor before `main`, the containers,
a virtual call, a `dynamic_cast`, and an exception thrown through twenty frames
and caught by type with a destructor run on the way out.

## musl

`build-musl.sh` builds musl against the same target. It runs: a musl program
prints, allocates, reads its arguments and exits on Quark.

The patch is four files, which is the point — musl's system call interface is
that narrow. `syscall_arch.h` calls a translation layer instead of issuing the
`syscall` instruction, because Quark's numbers mean different things; two
assembly files that issue `syscall` themselves are pointed at the same layer;
and `crt_arch.h` builds the argc/argv/environment/auxv block musl expects to
find on its stack out of the page Quark's spawner maps instead.

The layer itself is `quarkutils/linux-abi`. It is mostly an IPC client wearing
Linux's numbers: on a microkernel, `write` to a descriptor is a message to
whatever is on the other end of it, and `open` is a message to the VFS. Where
there is no equivalent it returns `-ENOSYS` rather than pretending — a libc
told "no" copes, and one handed a lie fails somewhere unrelated and much later.

`build-musl.sh` also writes a specs file and an `x86_64-quark-musl-gcc`
wrapper, so musl is a choice the compiler knows how to make rather than a pile
of flags every build system would have to be told. That is what makes the next
part possible at all.

The writing is `musl-wrappers.sh`, a script of its own, because the specs name
three things inside the userland's checkout by absolute path: the C library's
headers, `manifest.o` and `liblinux-abi.a`. Every musl program is linked
against whatever is at those paths *now* — which is why the userland's `make`
builds the layer even though nothing there links it — so when the checkout
moves, the specs have to be written again and musl does not have to be built
again. It has moved once: `quark/user/` became `quarkutils/`. Run
`./musl-wrappers.sh`, with `QUARKUTILS_DIR` set if the userland is not the
sibling `../../quarkutils`.

## coreutils

`build-coreutils.sh` builds GNU coreutils 9.11: 102 programs, and they run.
`wc /etc/passwd` on Quark reports the same counts as `cwc`, the hand-written
program that was the previous high-water mark for this phase, and pipelines
work — `seq 1 12 | wc -l` says 12.

Nothing in it is patched. Its `config.sub` is taught that quark is an
operating system, as every autoconf package's is. And one file of gnulib,
`getlocalename_l-unsafe.c`, stops with an `#error` that asks, in as many
words, to be ported: it has to reach into the C library for the name of a
locale, asks which library by asking which system, and has never heard of
this one. It used to be patched with a branch for Quark. But the C library
here is musl, and the file already knows musl's way — it keeps it under the
heading of Linux, the only place it has met musl — so that one object is
compiled being told it is on Linux (`coreutils-musl.mk`, read through
`MAKEFILES`), and nothing else is. That is how
[GNU/Quark](https://github.com/MagicJester2764/gnu-quark) builds it too.

Three things were needed on the Quark side, and each was a real gap rather
than a workaround:

- **A stack worth the name.** Programs got sixteen kilobytes. GNU `wc` puts a
  quarter of a megabyte on its stack in one frame and faulted on the first
  write to it. It is a megabyte now, and all of it is given when the program
  starts: the spawner builds the stack in its own memory and moves the pages
  across — which is why it is not Linux's eight.
- **A manifest per image, not per program.** File data moved through a page the
  program owned then, so a program that opened a file needed a capability to
  allocate one. coreutils does not know that; it called `fopen`. The C library
  declared it, in an object linked beside the entry point, and a spawner grants
  every manifest block in an image rather than the first one it finds. File
  data is lent to the VFS with each call now, and the C library's manifest asks
  for nothing; the object stays because the specs name it on every link.
- **Closing a standard descriptor is not an error.** Every tool that tidies up
  after itself calls `close(0)`, and answering EBADF made all of them print a
  complaint they could do nothing about.
- **`access(2)`, answered by the server.** gnulib's `euidaccess` tries
  `faccessat2`, then `faccessat`, and reports whatever the last one said, so
  refusing both made `sort /etc/passwd` say "cannot read" about a file it could
  read perfectly well. The layer answers by opening the file — that runs the
  VFS's own permission check — and the open reply now carries the file's mode
  and what *this* caller may do with it. Deriving that here would have meant
  keeping a second copy of the permission policy in every C library.
- **One CPU, said out loud.** `sched_getaffinity` reports a mask with one bit,
  which is a fact about this kernel rather than a placeholder, and it is what
  makes `nproc` right.
- **`fadvise` is advice.** Doing nothing with it is a complete implementation;
  refusing it is not.

Still refused, and harmless so far: `getrlimit` and `sysinfo`, which `sort`
asks for when sizing its buffer and copes without. `EXTRA_CFLAGS=-DQUARK_ABI_TRACE`
on the layer makes every unimplemented call name itself on stderr, which is how
each of the above was found — an ENOSYS otherwise reaches the program as a bare
errno and gets reported as whatever it was doing at the time.

## Putting them in an image

ExplOSion does not build coreutils — that needs this toolchain, which is an
install rather than a checkout — so it takes a directory somebody else built:

    make -C ../explosion hd COREUTILS=/path/to/build-coreutils-quark/src

The programs are stripped on the way in, because the debug info is three
quarters of 54 MB. Quark's own userland keeps its names: `ls` here is
quarkutils' one, and so are `cat` and `echo`. coreutils' would do the job too
— the layer answers `getdents64` — but ExplOSion is the distribution that
shows Quark's own programs. With `COREUTILS` unset the staging step takes
back anything a previous one put there.

## libffi and libwayland

Both build for `x86_64-quark`, and libwayland needs no patch at all. That was
the largest unknown in Phase 8 and it turned out to be mostly a toolchain
question rather than a porting one.

`build-libffi.sh` needs one hunk: `config.sub` learning that quark is an
operating system, the same hunk every autoconf package wants. The x86-64
assembly, the closure machinery, all of it cross-compiles unmodified.

`build-wayland.sh` runs meson twice — once natively for `wayland-scanner`,
because a cross build still needs a scanner that runs on *this* machine, and
once cross for the libraries. `libwayland-client.a` and, unexpectedly,
`libwayland-server.a` both build clean.

Three things had to change on our side, and each was a real gap rather than a
workaround:

- **`-pthread` is dropped by the wrapper.** It asks for a separate threading
  library and a feature macro; musl has neither, because threads are in libc.
  The driver would otherwise refuse an option it has no target handling for,
  which stops any build system that asks for threads the ordinary way.
- **musl's stub archives had to be findable.** musl ships empty `librt.a`,
  `libpthread.a`, `libm.a` and friends, since their contents are all inside
  `libc.a` — but the specs named `libc.a` by path and added no `-L`, so `-lrt`
  failed to find a library whose contents were already linked.
- **Two C libraries must not share an include directory.** libffi installed
  into the sysroot, pkg-config reported that as its `includedir`, meson turned
  it into `-I`, and `-I` beats `-isystem` — so `<fcntl.h>` resolved to Quark's
  own C library instead of musl's and every file wanting `fcntl` stopped
  compiling. Anything built for musl installs into musl's prefix now.

- **`-Db_staticpic=false`, and every meson package will need it.** meson
  compiles static libraries `-fPIC` by default. A Quark program is static and
  not PIE, and the target forces `-mcmodel=large`; in that combination taking
  the address of a default-visibility symbol goes through the GOT using a base
  register a non-PIE binary never sets up, and the address comes out zero.

That last one is worth the space because of how far it failed from its cause.
libwayland built, linked, connected over a socketpair, and then died — and the
reason was that `&wl_display_interface` evaluated to NULL inside libwayland's
own code, while `nm` showed the symbol perfectly well placed. Four rounds of
bisecting the marshal path found it; nothing about the symptom pointed at a
compiler flag.

**Where it gets to.** An unmodified musl program now does this on Quark:

```
WAYLAND_SOCKET=3
wl_display_connect: OK
get_registry: OK
flush wrote 12 bytes
disconnected
```

Twelve bytes of real Wayland protocol, marshalled by upstream libwayland and
written down a Quark socketpair. That was the whole of it when this was
written; the thing on the other end is `wm` now, in quarkutils, and
`quarkutils/docs/wayland.md` says what it implements.

`build-wayland.sh` also installs the libraries, the headers and the scanner
into the musl prefix, and `build-wayland-protocols.sh` puts the protocol XML
beside them, which is where GTK's build looks.

## The font stack

zlib, FreeType, expat, fontconfig and libxkbcommon build for Quark, and cairo
draws text with them: `wlcairo` writes two lines in DejaVu Sans and DejaVu Sans
Mono, found by fontconfig in a cache it wrote on Quark, from fonts read off the
disk.

    ./toolchain/bootstrap-fonts.sh
    ./toolchain/build-zlib.sh ~/opt/src/zlib-1.3.2 /tmp/suite-zlib
    ./toolchain/build-freetype.sh ~/opt/src/freetype-2.14.3
    ./toolchain/build-expat.sh ~/opt/src/expat-2.6.4.tar.xz
    ./toolchain/build-fontconfig.sh ~/opt/src/fontconfig-2.18.3 /tmp/suite-fc /tmp/overlay
    ./toolchain/build-cairo.sh ~/opt/src/cairo-1.18.4 ~/opt/src/pixman-0.44.2 ~/opt/src/freetype-2.14.3
    ./toolchain/build-xkbcommon.sh ~/opt/src/libxkbcommon-xkbcommon-1.13.2 /tmp/overlay
    ./toolchain/stage-fonts.sh ~/opt/src/dejavu-fonts-ttf-2.37/ttf /tmp/overlay
    ./toolchain/build-tests.sh /tmp/suite-c
    make hd WAYLAND_CLIENTS=$PWD/clients ROOT_OVERLAYS=/tmp/overlay \
        TEST_SUITES="/tmp/suite-c /tmp/suite-zlib /tmp/suite-fc"

`bootstrap-fonts.sh` fetches every source, checks each tarball against the
SHA-256 it was tested with, and builds gperf, which fontconfig runs while it
builds. The order above is the order they need each other in; libxkbcommon
needs none of them.

The image comes with its font caches. `build-fontconfig.sh` also builds the
same fontconfig for this machine and installs its `fc-cache` as
`quark-fc-cache` in `$QUARK_HOSTDEPS/bin`; `make stage` runs
`tools/stage-font-caches.sh`, which sets the staged font directories to a
whole second and runs it over the stage as a sysroot. The caches are the ones
fontconfig on Quark writes, byte for byte, except for the directory times
they record — which is why `tools/populate-ext.sh` carries every staged time
into the image, in whole seconds, and why `fctest` checks that the cache it
loads is older than the boot.

What each needed:

- **zlib**: nothing of its own. Its `configure` adds `-fPIC` whatever it is
  told, so the compiler wrapper now drops `-fPIC`, `-fpic`, `-fPIE`, `-fpie`
  and `-pie` as it drops `-pthread` — the same GOT trap as meson's static PIC
  above. The wrapper also rotates its arguments instead of re-parsing them with
  `eval`, which lost the quoting of `-DFOO="a b"`.
- **FreeType**: `-Dmmap=enabled`. Its Unix stream maps each face, and a
  mapped file is paged in as it is touched, so a line of text costs the tables
  it reads. (It was disabled while no file could be mapped and memory was
  backed when mapped, when that stream read every face whole.)
  `build-freetype.sh` builds the same FreeType for the host as well, and
  `fttest` renders a line on Quark to the host's checksum.
- **expat**: the `config.sub` hunk, which is `teach-config-sub.sh` now and used
  by libffi's script too, and a private copy of the tree, since the host's
  expat is configured in place in the shared one. It salts its hash tables
  with `getrandom`, which Quark answers from the kernel's generator.
- **fontconfig**: one line in `fcstat.c`, which reads Linux's `f_type` only on
  Linux and stops the build elsewhere (Quark's `struct statfs` is Linux's). It
  installs through `DESTDIR`, because `--sysconfdir=/etc` would otherwise write
  into this machine's `/etc`; the `conf.d` links are copied as files, and
  `-Dadditional-fonts-dirs=no` keeps the build machine's X11 font directories
  out of `fonts.conf`. Its cache writer found the last two gaps below.
- **cairo**: its FreeType and fontconfig backends switched on. The host cairo
  gets FreeType only, and gives `cairotext` its checksum.
- **libxkbcommon**: the library alone. A Wayland client compiles the keymap
  the compositor sends, so for most clients the image needs no keyboard data
  at all; it carries that one keymap, as `/usr/share/xkb/us.xkb`, for
  `xkbtest`. GTK is the exception — it builds a default keymap by name before
  it has heard from a compositor — and `stage-xkb.sh` stages the part of
  `xkeyboard-config` that takes.

**The fonts.** `stage-fonts.sh` lays four DejaVu faces out in
`/usr/share/fonts/dejavu` with their `LICENSE`: the fonts may be copied
freely provided the notices go with every copy, and an image is a copy.
`ROOT_OVERLAYS` copies such a tree over the stage, names and all, and takes it
back out when unset. The ext2 and ext4 roots are filled by
`tools/populate-ext.sh` in one debugfs run, which lowercases only Quark's own
FAT-style names in `usr/bin` and `etc` and keeps `DejaVuSans.ttf` as it is.

**Tests that need a `-I`.** A test whose library's headers are not directly
under `include/` names its pkg-config modules on its first line instead of its
libraries — `// PKG: freetype2`, `// PKG: cairo-ft cairo-fc` — and
`build-tests.sh` asks pkg-config, in the musl prefix only.

What the ports needed of the system, and got:

- **Files that behave.** Paths up to 4095 bytes; creating, removing, renaming
  and shortening files; `O_TRUNC`, `O_EXCL` and `O_DIRECTORY`; `stat` with
  real inode numbers, link counts and times; `getdents64`, `statfs`,
  `readlink`, `uname` and `getcwd`. The VFS protocol is written down in
  `quarkutils/docs/vfs.md`.
- **A clock.** The kernel reads the CMOS clock at boot, so files are dated and
  `time()` is the time. fontconfig compares dates to decide whether a cache is
  stale, and `e2fsck` reads a small deletion time as something else entirely.
- **`dup` on files.** fontconfig's configure looks for `mkostemp` without
  `_GNU_SOURCE`, does not find it, and makes its lock with `mkstemp` and
  `fcntl(F_DUPFD_CLOEXEC)` — which the layer refused for a file. Every cache
  write failed, silently, and left a temporary file behind. Descriptors now
  share an open file, as they do on Linux.
- **A scheduler that does not lose a task.** With the caches failing,
  fontconfig scanned every font twice, and about one run in two hung for good:
  a call's hand-over reopened interrupts between marking the callee runnable
  and switching to it, and a tick there left the callee in no queue. `dtest
  calls` reproduces that in three seconds and has not seen it since the fix.

## Weston's clients

`weston-simple-shm` and `weston-terminal` are weston's own, compiled from its
tree as they are.

    ./toolchain/build-pixman.sh ~/opt/src/pixman-0.44.2 /tmp/suite-pixman
    ./toolchain/build-libpng.sh ~/opt/src/libpng-1.6.44
    ./toolchain/build-weston-client.sh ~/opt/src/wayland-1.23.1 clients
    ./toolchain/build-weston-toytoolkit.sh ~/opt/src/wayland-1.23.1 clients
    make hd WAYLAND_CLIENTS=$PWD/clients

`build-weston-client.sh` also builds the five small clients whose sources are
here — `wlprobe`, `wlcairo`, `wlclip`, `wlscroll` and `wlfuzz` — and generates
the `xdg-shell` stubs with the scanner that was built beside libwayland,
because stubs from a different version describe interface structures laid out
differently.

`clients/window.c` is the toolkit every weston client with a window is written
against, and `weston-terminal` is one program on top of it. It is not a
library anybody ships, which is why it was the right thing to port: ordinary
client code, written against Wayland and POSIX and nothing else, so everything
it wanted that Quark had not got was a hole in Quark. `fork`, `execve`, a
pseudo-terminal and `timerfd` were all found this way. Weston builds with
meson and a generated `config.h`; `build-weston-toytoolkit.sh` writes the
small part of it these files read, since setting meson up to cross-compile a
project whose compositor half cannot build here is a larger thing than the
eight files that are wanted.

pixman builds its generic C path and nothing else — the SIMD paths are chosen
at run time and each is a change to measure — and brings its own test suite,
thirty-one programs, as `pixman.tests`.

## The toolkit

glib, harfbuzz, fribidi, pango, graphene, gdk-pixbuf and GTK 4 build for
Quark, and `hello-world` is GTK's own `examples/hello/hello-world.c`: a window,
a button, and "Hello World" on the console when it is clicked.

    ./toolchain/bootstrap-toolkit.sh
    ./toolchain/build-libstdcxx.sh ~/opt/src/gcc
    ./toolchain/build-pcre2.sh    ~/opt/src/pcre2-10.44
    ./toolchain/build-glib.sh     ~/opt/src/glib-2.82.5
    ./toolchain/build-harfbuzz.sh ~/opt/src/harfbuzz-10.1.0
    ./toolchain/build-fribidi.sh  ~/opt/src/fribidi-1.0.16
    ./toolchain/build-pango.sh    ~/opt/src/pango-1.54.0
    ./toolchain/build-graphene.sh ~/opt/src/graphene-1.10.8
    ./toolchain/build-libjpeg.sh  ~/opt/src/libjpeg-turbo-3.0.4
    ./toolchain/build-libtiff.sh  ~/opt/src/tiff-4.7.0
    ./toolchain/build-gdk-pixbuf.sh ~/opt/src/gdk-pixbuf-2.42.12
    ./toolchain/build-epoxy.sh    ~/opt/src/libepoxy-1.5.10
    ./toolchain/install-egl-headers.sh
    ./toolchain/build-wayland-protocols.sh ~/opt/src/wayland-protocols-1.38
    ./toolchain/build-gtk.sh      ~/opt/src/gtk-4.16.7
    ./toolchain/build-gtk-client.sh ~/opt/src/gtk-4.16.7 clients
    ./toolchain/stage-xkb.sh ~/opt/src/xkeyboard-config-2.43 /tmp/overlay
    make hd WAYLAND_CLIENTS=$PWD/clients ROOT_OVERLAYS=/tmp/overlay

What is true of every one of them:

- **Static, and not PIC.** There is no dynamic loader, so
  `-Ddefault_library=static -Db_staticpic=false` is on every meson build
  (`meson-cross-quark.ini`), cmake gets the same from
  `cmake-cross-quark.cmake`, and the compiler wrapper drops `-fPIC` whatever a
  build system says. A module that would be `dlopen`ed has to be built in:
  gdk-pixbuf's loaders are, which is also why no loader cache is needed.
- **glib is built twice.** Three of its tools are C programs rather than
  Python — `glib-compile-resources`, `glib-compile-schemas`,
  `gio-querymodules` — and GTK's build runs two of them to turn XML into C.
  The copies in the target prefix are Quark programs and cannot run here, so
  `build-glib.sh` also builds a native glib into `$QUARK_HOSTDEPS`, and every
  script after it puts that on `PATH` first.
- **C++ is its own step.** harfbuzz is C++. `build.sh` builds `cc1plus`, and
  `build-libstdcxx.sh` builds the library against musl afterwards.

What each needed:

- **glib** needed the most, and all of it from Quark: `eventfd`, a futex wait
  that honours its timeout, an `O_NONBLOCK` that `read` and `write` obey, and
  a `poll` with no descriptors that waits. Its main loop wakes itself by
  writing to an eventfd and drains it "until it is empty"; with a read that
  waited instead of answering `EAGAIN`, the loop stopped holding its own lock.
  `tests/gsync.c` and `tests/polltest.c` are those four as tests.
- **harfbuzz** and **pango** needed nothing but the above, and a program
  bigger than four megabytes to be loadable: a spawner reads the whole image
  before it gives the pages away, and its limit was 4 MiB. It is 32.
- **libjpeg-turbo** is the one cmake build. **libtiff** is built for GTK,
  which decodes TIFF itself; gdk-pixbuf's own TIFF loader is off
  (`-Dtiff=disabled`), since gdk-pixbuf's tools do not carry libtiff on their
  link line. Every other loader is built in, because a loader left out is
  built as a shared module, and a shared module cannot link the non-PIC static
  library everything else here is.
- **libepoxy** is built with EGL "on" and the Khronos headers installed beside
  it, because GTK includes `epoxy/egl.h` whatever it draws with. There is no
  GL: epoxy looks for an implementation at run time and correctly finds none,
  and GSK falls back to its cairo renderer.
- **GTK** has no static build — `gtk/meson.build` says `shared_library` and
  offers no choice. It does have the `static_library` the shared one wraps, so
  `build-gtk.sh` builds those targets and `build-gtk-client.sh` links a
  program against them, the same shape as the toytoolkit.
- **The compiler says this is a Unix.** `gcc/config/quark.h` defines
  `__unix__`, because portable code asks that rather than asking for a system
  by name. The Khronos EGL headers were the first to stop without it: their
  platform list has an arm for `__unix__` and an `#error` after it.
- **The sysroot's Linux headers lost `linux/dma-buf.h`.** Every other header
  there describes something a program can ask for and be told no. That one is
  asked at build time, and a yes makes a toolkit compile a path that cannot
  work.

A toolkit program is twenty-five megabytes and is in memory twice while it
starts, so QEMU is given a gigabyte and the root filesystem is 128 MiB.


## Tests, and the two fuzzers

`runtests` reads a list from `/etc` and runs each line as a program with its
arguments, one after another:

```
# a comment
tlstest                 must exit 0
? ls /no/such/place     any exit status passes; a fault or a hang does not
@30 dchild sleep        thirty seconds, then it is killed and the line fails
? @600 qfuzz 2000 1     both
```

A line's program is looked up in `/usr/bin`, gets the environment the shell
gives a program and no standard input, and is watched rather than waited for,
so a program that never exits costs its deadline and not the run. Failures are
said as they happen and again at the end, with the arguments that caused them,
because a list of five hundred lines scrolls the first ones off the screen.

Each port's suite is a list of its own: `libc.tests` (the C library's own
tests, one per lie a port has caught it telling), `zlib.tests`,
`pixman.tests`, `fontconfig.tests`, `fonts.tests`, `cairo.tests`, `xml.tests`,
`xkb.tests`. `selftest.tests` is runtests testing itself: four lines that pass
and three that must fail.

**`fuzz.tests` and `qfuzz`.** `qfuzz ROUNDS [SEED]` (in `quarkutils/qfuzz`)
sends every registered service requests built from a seed — tags from its own
protocol, from the range the kernel's notices use, and from anywhere; words
small, handle-sized, huge and random; with and without a buffer lent and a
capability offered — and then checks that the service is alive, answers a
ping, and still does its job. `fuzz.tests` runs three fixed seeds. It steers
away from harm that would not be the service's fault: nothing lent to the VFS
holds a slash or a dot, so every name it resolves is under `/tmp/qfuzz`;
addresses given to the network server are on the machine's own subnet, where
nothing answers, so nothing leaves the machine; and a driver is fuzzed only
once it has refused a harmless request.

**`wlfuzz`.** A Wayland client that writes the wire format itself, because
libwayland would refuse to send most of what it sends: object ids that are
gone or were never made, opcodes an interface does not have, sizes shorter
than a header or past what was sent, strings whose length lies, descriptors
where none are wanted and none where one is needed, pools larger than their
memory or made from a pipe, buffers attached after they were destroyed. It
builds a window properly first, so that the parts a bad client can hurt are
there to hurt. Run it under the compositor, beside something that draws:

    wm "wlfuzz 1 500" "wlfuzz 101 500" wlcairo

It stops when the compositor closes the connection, says how far it got and
what the compositor said about it, and exits 0 either way: the test is whether
the compositor lives, and whether the window beside it keeps drawing.

**`hostile.tests`.** Written by `tools/gen-hostile-tests.sh` at staging time
from whatever is in the staged `/usr/bin`: every program, with each of no
arguments, `-`, `--`, `-x`, `--help`, a 300-byte word, `/nonexistent`,
`/etc`, `/dev/null`, `/etc/hostile-sample`, `99999999999999999999`, `-1`,
`0`, `héllo`, a control byte, and fifteen arguments. Each line allows any exit
status and thirty seconds: a program may complain, but it may not fault and it
may not hang. Left out are the programs that would do something other than be
tested — `shutdown`, `login`, `runtests`, `wm`, `qfuzz` — the programs a
port's own suite runs, whose arguments are test numbers and iteration counts,
and `weston-simple-shm`, which asserts that it has a compositor and is not
ours to patch.
