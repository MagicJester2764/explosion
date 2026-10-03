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
  explosion/   this repo — staging, images, QEMU targets, the ports, and
               the installer
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
  takes it back out when it runs again without (`tools/stage-forget.sh`, at
  the start of a stage and before the installs, from the records `.clients`,
  `.suites` and `.overlays` at the top of the stage — before, because a file
  an overlay replaced has to be put back by the tree that owns it). So the same command line has to be given every
  time, or the image quietly loses its fonts. The suites were the one that
  did not for a long time, and it showed when a package list was first made
  of a stage: the "default" disc had every test in it.
- **The ISO's root is a boot module.** `live.img` is an ext2 image of the
  stage, put on the EFI partition as `\drivers\LIVE.IMG`; Bang loads every
  file there, `init` starts `ramdisk` on that one with the right to map
  exactly its memory, and the file server is told its root is `ram0`. So a
  live system costs its root in memory, twice while Bang reads it, and
  `-m 1G` is not generous. `tools/make-esp.sh` builds both EFI partitions.
- **`boot.img` is made while staging**, not after: the root carries a copy
  of everything the firmware starts (`usr/lib/explosion/boot`), because a
  system installs another by copying what it was started with, and
  `bang-install` has nowhere else to get it.
- **Every staged file is some package's.** `packages.conf` says whose, the
  first pattern that matches wins, and `system` takes what is left;
  `tools/stage-packages.py` writes the lists last and stops on a file
  nothing claims. A new kind of file in an image is a decision about which
  set installs it — a test in `base` is a test on every installed system.
- **The lists name files as the image has them**, not as the stage does:
  `stage-packages.py` has the same renaming rule as `populate-ext.sh`
  (`QSH.ELF` is `/usr/bin/qsh`). Change one and change the other.
- **`live/` is the installation disc's own**, staged for `make iso` and
  nothing else. Its greeting (`etc/issue`, `etc/motd`) is package `live`,
  which no set an installer asks for has; its `etc/init.conf` is `system`'s,
  so what is installed has the session it was installed from.
- **The programs in `programs/` are ExplOSion's**: `qpkg`, `bang-install`
  and `guide` are built here against `../quarkutils/quark-rt`, with the
  same toolchain pin as the three trees below. The dependency still runs one
  way.
- **`make -o stage hd` does not rebuild `fat.img`.** A change to `init` or to
  the kernel needs the image rules to run; when in doubt, `make stage` first.
- **Names.** Quark's own install names files the way FAT wants them
  (`HELLO.ELF`, `PASSWD`). `tools/populate-ext.sh` gives those the names the
  shell and `init` look for (`hello`, `passwd`) and leaves every name with a
  lowercase letter in it alone — `DejaVuSans.ttf` was chosen on purpose.
- **Staged times reach the image, in whole seconds.** fontconfig decides
  whether a cache is stale by a directory's time, and a file's time here is
  kept in whole seconds, whatever the clock can say.

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
tools/install-test.sh                         # install from the ISO; start the disk
```

Every run has an echo server to talk to, on port 7007 of this machine, and
there is one of it however many runs there are: a run starts it if nothing
is listening and nobody stops it. It was each run's own, started and
stopped with the run, and two runs at once had one between them — the
first's, which took it away from the second when it ended, and the second's
network test failed. Four images tested together did that to each other
according to which finished first.

Every machine they start has QEMU's `edu` device in it, and the device
manager starts its driver where the image has one: `/usr/lib/drivers`, where
the `tests` package puts it. Then `dtest msi` has a device whose interrupt is
a message of its own to ask about, and `dtest devices` a driver to try what a
driver may not do.

A machine has somewhere to write memory out to if its image starts `swapd`:
`start /usr/bin/swapd /var/swap 16` in `/etc/init.conf`, and then `dtest
pressure` has twenty-three more checks to make, the last of which fills more
memory than the machine has. The file is on the root, which on an image
built here has about twenty megabytes to spare: sixteen is a file that
would not fit if it were ever full, and never is — it is as long as the
most that was out at once, which the checks keep under two. It is written a
page at a time through the file server to a disk driven a word at a time;
that last check takes about ten seconds. `swapd` and `free` are `system`'s,
like any other program of the userland's: on every installed system, and
started on none unless its `init.conf` says so.

Every one of them gives the machine a gigabyte of memory unless `MEM` says
how much. `MEM=6G` is a machine with memory above four gigabytes, and it is
not the same machine made bigger: the firmware loads the bootloader above
the line, which is how Bang came to hand the kernel half an address; the
kernel's first map of memory ends there; and a network card is told where
its buffers are in thirty-two bits. A change to the bootloader, to the
kernel's memory or to a driver that does DMA is tried on one.

Every one of them gives the machine one processor unless `SMP` says how
many, and a change is tested on one and on four (`SMP=4 tools/…`): they
find different mistakes. With one, nothing runs at the same time as
anything. With four, a program is ended in the middle of a call it made, a
child is running before its parent has finished making it, and two threads
are in the same memory at once — a removed directory left on the disk, a
file that would not map and a wait told its child was process 0 were each
found only there. `make run` gives it four.

`IOMMU=1` gives the machine Intel's IOMMU (`-device intel-iommu`), which
QEMU has only on its q35 chipset — a different machine again, whose disks
are on AHCI and nothing answers the old IDE ports; `CHIPSET="-machine q35"`
is that machine without the IOMMU. Either boots a disk image, through the
AHCI driver, or the live ISO (`ISO=explosion.iso`), which runs from
memory. There a device reaches what its driver claimed and was given and
nothing else, and `dtest iommu` holds the kernel to it, with `edu` started;
a driver that does DMA is tried there after a change — the disk's own
among them now — and so is the kernel after a change to who owns memory.
The ATA driver met that machine first, before there was a device manager to
start it only for an IDE controller: nothing at its ports answers 0xFF,
which looked like a drive that was always busy.

`VIRTIO=1` gives the machine the devices a virtual machine is usually
given instead of the ones a PC had: its disk on virtio (`virtio-blk-pci`),
its network card too (`virtio-net-pci`), and its display a virtio GPU with
no VGA beside it (`virtio-gpu-pci`), each with a driver in the boot image
that the device manager starts for it. That display gives the firmware no
framebuffer: the screen is its driver's from the start, and what is drawn
is copied to it as it is said (`dtest display` changes its size and back).
Its size follows the host's as a viewer's window does: the machine has a
VNC socket, and `tools/vnc-size.py "$RUN/vnc.sock" W H`, from a script's
`run` step, asks for a size and waits for the guest to show it. A change to a
driver, to the device manager or to how a device reaches memory is tried
there as well as on the default machine. With `IOMMU=1` it is a q35 machine
with virtio's modern devices behind the IOMMU.

`USB=1` is a machine whose keyboard and mouse are on USB and nowhere else:
q35 with no i8042, and an xHCI controller with a keyboard, a mouse and a FAT
disk of its own on it (`HUB=1` puts the first two behind a hub). Everything
a script types reaches it through the USB keyboard, which is the keyboard's
test; `lsusb`, `mousetest`, and the disk mounted, read, pulled out and put
back are the rest (the acceptance's `e4-usb`).

`NVME=1` puts the disk on an NVMe controller (`-device nvme`) instead: the
firmware starts from it as from any disk, and from there on it is the NVMe
driver's, in the boot image. With `IOMMU=1` the controller is behind the
IOMMU, its queues among what its driver was given.

`crash-test.sh` stops the machine with three things on the disk — a removed
file a program still holds, a file written and synced, and, on ext4, a
directory being changed as it stops — and recovers the disk twice: with
`e2fsck`, and by booting it. The synced file has to be whole both times. On
ext4 it first stops the machine twenty-four times without ending it (`hmp
stop`, a `run` line that recovers a copy of the disk, `hmp cont`), says how
many stops found a transaction committed to the journal and not yet in
place, and boots the first such disk, so that the file server's own replay
is tried and not only `e2fsck`'s. And it does not leave that to a stop: it
makes one more disk with `debugfs` before the machine first starts — a
committed transaction that makes a directory, over the filesystem as it was
with a removed file on the orphan list — and boots that too. A stop found
the server writing back counts it had read before its replay, once in many
runs; the made disk finds it every time.

- **One stop is not a crash test.** It finds the disk between transactions
  nine times in ten. Many stops found, the first time they were tried, that
  a superblock written as two sectors could be caught between them.
- **Run it on ext2 and on ext4** after anything that changes how the file
  server or the disk driver writes, and read the count: a run in which no
  stop found a committed transaction has not tried replay, and says so.

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

- **The guide is the install test's script.** `tools/install-test.sh` types
  every line `docs/install.md` sets apart as a command, in order, so a line
  there that is not a command to type breaks the test — say an alternative
  in the prose. It takes the disc out at `shutdown -r`, as the guide tells a
  person to, and then boots the disk alone.
- **And its passwords are the test's.** A `passwd` line there is answered:
  the test types a password at `New password:` and `Again:`, and whoever
  was given one logs in with it afterwards. A guide that stops giving root
  a password, or stops making a user with one, fails before anything boots.
- **`DRIVE_TIMES=1`** has each `expect` say how long it waited, which is how
  to find out where an install spends its time.
- **Keep `RUNDIR` short.** The emulator's control socket is in it, and a
  socket's path has to fit in about a hundred characters.

What to run on the machine: `dtest` (the kernel, through its ABI),
`runtests /etc/libc.tests` (the C library's tests, which are quarkutils':
`tools/build-ctests.sh` there builds the suite directory) and the ports' lists
in `/etc`, `qfuzz <rounds> <seed>`. After anything that writes to the disk, `check-rootfs.sh` — on ext2
*and* ext4, since they share less code than it looks.

## Users

Who the users are, and what a user may read, is `../quarkutils`' — the
accounts, the passwords, the server that checks them (`auth`), the file
server's rules. Read its `CLAUDE.md` first. What is here is what this
distribution makes of it:

- **`etc/rights` is this distribution's file.** `auth` hands a session what
  its account's line there says, and with no such file gives root everything
  and nobody else anything. Staging copies it into every image; `user NAME
  may ...` (`programs/user`) rewrites it, and `as` (`programs/as`) is what
  the `become` right is for. A right is a capability handed over at login:
  nothing here checks a user id to decide what a program may do, and a new
  right is a new thing for `auth` to hand over, in `../quarkutils`.
- **The account files are the owner's to change.** `packages.conf` says so
  (`yours`), the lists mark them `y`, and `qpkg verify` asks only that they
  are there. Without it the first password set on an installed system made
  the system "not as built". A file that is edited in the ordinary life of
  a system belongs on that line.
- **`qpkg strap` copies who the users are**, with their modes: the passwords
  are 0600 on the system installed because they are 0600 on the one
  installing. The disc has root and no password; the guide gives the new
  system both before it is restarted into.
- **A disk image's EFI partition is FAT32**, said to `tools/make-esp.sh` by
  `FAT32=1`. Left to choose, `mformat` makes anything under half a gigabyte
  FAT16, which Quark does not read — and for a long time the file server
  mounted one anyway and failed every read, so an image built here could not
  look at the partition it had started from. The disc's is left as `mformat`
  makes it: nothing mounts a disc's.
- **More than one user means sessions on a terminal.** A terminal is its
  session's and each login is a session, so what one user leaves running
  cannot read what the next types; the plain console has no notion of whose
  it is. The disc and what it installs say `session /usr/bin/getty`
  (`live/etc/init.conf`); an image built here with no overlay starts on the
  console, which keeps both paths under test and is not somewhere to put a
  second user.
- **Root's home is 0700**, in an image (`tools/populate-ext.sh`) and in what
  `qpkg strap` makes (`dir 0700 home/root`). Both, or one of the two kinds
  of system has a home anybody can read.

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
