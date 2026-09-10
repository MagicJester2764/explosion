# The x86_64-quark cross toolchain

`build.sh` turns a binutils and a gcc source tree into a compiler that targets
Quark, installed under `~/opt/cross` by default.

## Why a target and not a pile of flags

Quark is x86-64 and so is every machine this has been built on, so
`-ffreestanding -nostdlib` plus our own headers already produced working
binaries — that is how `user/libc` and the programs against it were built
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
- **libgcc is built without coverage.** `libgcov` calls `fork` and `exec`, and
  Quark has neither. That is not a gap to fill later — a system where a task is
  created, given an address space and started does not have a fork to offer, so
  the honest configuration is the one that does not ask for it.

## The sysroot

`make -C ../../quark/user/libc install-sysroot` puts the headers, `libc.a`,
`crt0.o` and the link script where the toolchain looks. It has to run *before*
`build.sh`, because gcc compiles its own support library against those headers.

Two gaps in the C library were found by exactly that, and both were real rather
than gcc being fussy: there was no `sys/types.h` and no `time.h`, and `stdio.h`
had no `FILE` — `fprintf` took a descriptor. A library that cannot say
`fprintf(stderr, ...)` is not one anybody can port to.

## musl

`build-musl.sh` builds musl against the same target. It runs: a musl program
prints, allocates, reads its arguments and exits on Quark.

The patch is four files, which is the point — musl's system call interface is
that narrow. `syscall_arch.h` calls a translation layer instead of issuing the
`syscall` instruction, because Quark's numbers mean different things; two
assembly files that issue `syscall` themselves are pointed at the same layer;
and `crt_arch.h` builds the argc/argv/environment/auxv block musl expects to
find on its stack out of the page Quark's spawner maps instead.

The layer itself is `quark/user/linux-abi`. It is mostly an IPC client wearing
Linux's numbers: on a microkernel, `write` to a descriptor is a message to
whatever is on the other end of it, and `open` is a message to the VFS. Where
there is no equivalent it returns `-ENOSYS` rather than pretending — a libc
told "no" copes, and one handed a lie fails somewhere unrelated and much later.

`build-musl.sh` also writes a specs file and an `x86_64-quark-musl-gcc`
wrapper, so musl is a choice the compiler knows how to make rather than a pile
of flags every build system would have to be told. That is what makes the next
part possible at all.

## coreutils

`build-coreutils.sh` builds GNU coreutils 9.11: 102 programs, and they run.
`wc /etc/passwd` on Quark reports the same counts as `cwc`, the hand-written
program that was the previous high-water mark for this phase, and pipelines
work — `seq 1 12 | wc -l` says 12.

The patch is two hunks. One teaches coreutils' own `config.sub` that quark is
an operating system, which every autoconf package will need. The other adds a
branch to a gnulib file whose `#error` asks, in as many words, to be ported:
Quark has one locale and it is "C", so that is what it says. Everything else
about coreutils built unmodified.

Three things were needed on the Quark side, and each was a real gap rather
than a workaround:

- **A stack worth the name.** Programs got sixteen kilobytes. GNU `wc` puts a
  quarter of a megabyte on its stack in one frame and faulted on the first
  write to it. It is a megabyte now, mapped eagerly because there is no demand
  paging — which is also why it is not Linux's eight.
- **A manifest per image, not per program.** File data moves through a page the
  program owns, so a program that opens a file needs a capability to allocate
  one. coreutils does not know that; it called `fopen`. The C library declares
  it, in an object linked beside the entry point, and a spawner now grants
  every manifest block in an image rather than the first one it finds.
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
quarters of 54 MB and the root filesystem is 33. Quark's own userland keeps its
names: `ls` here would be coreutils' `ls`, which wants `getdents64`, while the
in-tree one lists a directory over the VFS protocol and works. With `COREUTILS`
unset the staging step takes back anything a previous one put there.

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
written down a Quark socketpair. What is missing is the thing on the other end.

