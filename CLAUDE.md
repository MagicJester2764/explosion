# Working on ExplOSion

ExplOSion is where Quark is assembled into something that boots, and where
other people's software is built for it. It is one of five repositories that
must be checked out as siblings:

```
repos/
  quark/       the kernel
  quarkutils/  everything that runs on it
  bang/        the UEFI bootloader
  explosion/   this repo — staging, images, QEMU targets, the cross toolchain
  rust/        fork of rust-lang/rust with the x86_64-unknown-quark std PAL
```

The dependency runs one way: this tree reaches down to the other three, and
none of them knows it exists. Rules about the kernel are in
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
a test is a screenshot; serial only shows kernel faults.

```bash
tools/boot-test.sh <keys-file> <shot.ppm>     # IMG=… RUNDIR=… for a second boot
tools/check-rootfs.sh hdimage.bin             # e2fsck what the boot left
tools/crash-test.sh                           # stop mid-write, recover, check
```

A keys file is one operation per line (`tools/drive-qemu.py` has the list):
`sleep`, `type`, `key`, `move dx dy [n]`, `click`, `press`, `release`, `wheel`,
`shot`, `hmp`, `quit`.

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

What to run on the machine: `dtest` (the kernel, through its ABI),
`runtests /etc/libc.tests` and the other lists in `/etc`, `qfuzz <rounds>
<seed>`. After anything that writes to the disk, `check-rootfs.sh` — on ext2
*and* ext4, since they share less code than it looks.

## The toolchain

`toolchain/README.md` is the account of every port. The rules:

- **Nothing patches an upstream program or library.** If a port needs
  something, Quark grows it. `teach-config-sub.sh` is the one exception in
  kind, and it patches autoconf's list of operating systems rather than the
  package. coreutils and fontconfig carry one small patch each from before the
  rule.
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
- **The musl specs name three paths inside `../quarkutils` absolutely.** If
  that checkout moves, run `toolchain/musl-wrappers.sh`; musl itself does not
  need rebuilding.
- **A C program is linked against whatever `liblinux-abi.a` is at that path
  now.** After changing the layer, relink the programs that should see it:
  nothing tracks that dependency for a program built outside quarkutils.
- **`clients/` holds built programs, and they are tracked**, so that an image
  with a compositor's clients in it can be assembled on a machine with no
  cross toolchain. Rebuilding one means running its script in `toolchain/`
  again and committing the result.
