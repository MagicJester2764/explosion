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
