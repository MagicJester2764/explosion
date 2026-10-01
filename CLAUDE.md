# Working on ExplOSion

ExplOSion is where Quark is assembled into something that boots, and where
other people's software is built for it. It is one of six repositories that
are checked out as siblings:

```
repos/
  quark/       the kernel
  quarkutils/  everything that runs on it
  bang/        the UEFI bootloader
  quark-toolchain/  the cross compilers every C program here is built with
  explosion/   this repo — staging, images, QEMU targets, and the ports
  rust/        fork of rust-lang/rust with the x86_64-unknown-quark std PAL
```

The dependency runs one way: this tree reaches down to the kernel, the
userland and the bootloader, and uses the compilers; none of them knows it
exists. Rules about the kernel are in
`../quark/CLAUDE.md`; rules about programs, the screen, files and the toolkits
are in `../quarkutils/CLAUDE.md`. Read those before changing what an image
*does*; this file is about how one is made and checked.

## Before anything else

```bash
export PATH="$HOME/.local/bin:$HOME/opt/cross/bin:$PATH"
```

Staging strips every program it takes in with `x86_64-quark-strip`, and where
that is not on `PATH` it carries on without stripping. Nothing fails; the root
filesystem fills up instead, and the error is `Could not allocate block` from
`debugfs`, a long way from the cause.

## Build and run

```bash
make stage     # install ../quark, then ../quarkutils, then Bang, into stage/
make hd        # hdimage.bin with an ext2 root   (hd-ext4, hd-fat32)
make run       # boot it                         (run-ext4, run-fat32)
make iso       # explosion.iso: the root in memory, from a file Bang loads
make run-iso   # boot it, with DISK=<image> attached to install onto
```

- **The kernel is installed before the userland**, into the same directory.
  The userland checks its copy of the system call numbers against the header
  the kernel just put there, and `REQUIRE_ABI=1` makes a missing header an
  error. This is the one place the two repositories meet.
- **An image built without a variable has nothing of that variable's in it.**
  `COREUTILS`, `WAYLAND_CLIENTS`, `TEST_SUITES` and `ROOT_OVERLAYS` each stage
  somebody else's build, and each stager records what it put in the stage and
  takes it back out when it runs again without. So the same command line has
  to be given every time, or the image quietly loses its fonts.
- **The ISO's root is a boot module.** `live.img` is an ext2 image of the
  stage, put on the EFI partition as `\drivers\LIVE.IMG`; Bang loads every
  file there, `init` starts `ramdisk` on that one with the right to map
  exactly its memory, and the file server is told its root is `ram0`. So a
  live system costs its root in memory, twice while Bang reads it, and
  `-m 1G` is not generous. `tools/make-esp.sh` builds both EFI partitions.
- **`make -o stage hd` does not rebuild `fat.img`.** A change to `init` or to
  the kernel needs the image rules to run; when in doubt, `make stage` first.
- **Names.** Quark's own install names files the way FAT wants them
  (`HELLO.ELF`, `PASSWD`). `tools/populate-ext.sh` gives those the names the
  shell and `init` look for (`hello`, `passwd`) and leaves every name with a
  lowercase letter in it alone — `DejaVuSans.ttf` was chosen on purpose.
- **Staged times reach the image, in whole seconds.** fontconfig decides
  whether a cache is stale by a directory's time, and Quark's clock has no
  fraction.

## Testing

A program's output goes to the framebuffer, not the serial line. The result of
a test is what is on the screen; serial only shows kernel faults. The text
console's screen can be read back as text — it draws one bitmap font on a
grid, so a screendump of it is its text exactly (`tools/screentext.py`) — and
that is what lets a test wait for a prompt and keep what was printed, instead
of sleeping for a guess and looking at a picture.

```bash
tools/boot-test.sh <keys-file> <shot.ppm>     # IMG=… RUNDIR=… for a second boot
tools/check-rootfs.sh hdimage.bin             # e2fsck what the boot left
tools/crash-test.sh                           # stop mid-write, recover, check
```

A keys file is one operation per line (`tools/drive-qemu.py` has the list):
`sleep`, `type`, `key`, `move dx dy [n]`, `click`, `press`, `release`, `wheel`,
`shot`, `expect`, `text`, `transcript`, `hmp`, `quit`. `boot-test.sh` exits 1
if an `expect` gave up or the kernel faulted.

- **`expect <seconds> <regex>` matches the last line on the screen**, which
  after a command is its output until it finishes and the prompt when it has.
  `expect 300 \$$` after `type dtest\n` is "wait for dtest". A window is not
  text; under a compositor it is `sleep` and `shot` again.
- **`transcript <path>` is everything the console showed while the script was
  looking**, joined where one screen overlaps the next. Where the console
  scrolled a whole screen between two looks there is a `[...]`: what a test
  must not miss, it prints last.
- **`move` sends its delta `n` times, eight by default.** `move 10 10` moves
  eighty pixels. To put the pointer somewhere, run it into a corner
  (`move -300 -200 8`) and then make one step of the distance wanted
  (`move 412 230 1`).
- **Read a window's frame out of a screenshot before aiming at it.** Where a
  window is depends on what was started before it.
- **One emulator per image.** Two boots can run at once only on two images,
  with `IMG` and `RUNDIR` set for the second.
- **Never kill the emulator by name.** The shell running the test matches too.
  The script kills by pid.
- **The timing is in the Python driver**, because a foreground `sleep` in an
  agent's tool call can be blocked.
- **The screen is read by the font it was drawn in.** `screentext.py` knows
  the console's built-in ASCII; an image that loads a font at boot is read
  with `QUARK_FONT_HEX` naming that font's `.hex` file, or every character
  on it is a `?`.

What to run on the machine: `dtest` (the kernel, through its ABI),
`runtests /etc/libc.tests` (the C library's tests, which are quarkutils':
`tools/build-ctests.sh` there builds the suite directory) and the ports' lists
in `/etc`, `qfuzz <rounds> <seed>`. After anything that writes to the disk, `check-rootfs.sh` — on ext2
*and* ext4, since they share less code than it looks.

## The toolchain

`toolchain/README.md` is the account of every port. The rules:

- **Nothing patches an upstream program or library.** If a port needs
  something, Quark grows it. `teach-config-sub.sh` is the one exception in
  kind, and it patches autoconf's list of operating systems rather than the
  package. fontconfig carries one small patch from before the rule;
  coreutils did, and is built without it now (`coreutils-musl.mk`).
- **Static, and not PIC.** There is no dynamic loader. meson builds take
  `meson-cross-quark.ini`, cmake takes `cmake-cross-quark.cmake`, and the
  compiler wrapper drops `-fPIC` and `-pthread` whatever a build asks for.
- **Anything built for musl installs into musl's prefix**, never the sysroot.
  Two C libraries sharing an include directory is `-I` beating `-isystem`, and
  `<fcntl.h>` resolving to the wrong one.
- **What must run on this machine during a build is built for this machine.**
  A native glib's tools, `quark-fc-cache` and gperf live in `$QUARK_HOSTDEPS`
  (`~/opt/src/host-deps`); the wayland scanner is in `host-tools/` here. A
  cross-built copy of a build tool is a Quark program and cannot run here.
- **The compiler is not built here.** `x86_64-quark-musl-gcc` and `-g++`
  come from `../quark-toolchain`, on `PATH`. Its musl specs name three paths
  inside `../quarkutils` absolutely; if that checkout moves, its
  `musl-wrappers.sh` writes them again.
- **A C program is linked against whatever `liblinux-abi.a` is at that path
  now.** After changing the layer, relink the programs that should see it:
  nothing tracks that dependency for a program built outside quarkutils.
- **`clients/` holds built programs, and they are tracked**, so that an image
  with a compositor's clients in it can be assembled on a machine with no
  cross toolchain. Rebuilding one means running its script in `toolchain/`
  again and committing the result.
