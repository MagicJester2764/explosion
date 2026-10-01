# ExplOSion

A Quark meta-distro. This is where the system is assembled and run, and where
other people's software is built for it.

```
../quark            the microkernel
../quarkutils       the programs that run on it
../bang             the UEFI bootloader
../quark-toolchain  the cross compilers, for the ports
./                  this: staging, image assembly, QEMU targets, and every
                    port of somebody else's software
```

The dependency runs one way. ExplOSion reaches down to the three trees beside
it; none of them knows it exists, and none of them knows what an image looks
like.

## Build and run

```bash
make stage   # build ../quark, ../quarkutils and ../bang, collect into stage/
make hd      # assemble hdimage.bin (GPT: EFI system partition + ext2 root)
make run     # boot it in QEMU
make iso     # assemble explosion.iso: a system that runs from memory
make run-iso # boot that
```

The root is ext2 unless asked otherwise: `make hd-ext4` and `make run-ext4`
give it ext4 with a journal, `make hd-fat32` and `make run-fat32` FAT32.

`explosion.iso` is the same system with its root somewhere else. The root
filesystem is one more file on the EFI partition, which Bang loads into
memory with the kernel and a RAM disk serves; nothing in it has to be able
to read the disc it came on. The one image boots as a CD and, written to a
USB stick, as a disk: its EFI partition is named in an El Torito catalog
for the first and in a GPT for the second. What is written to the root
while it runs is written to memory and gone at power-off.

`make clean` removes the staging directory and the images. `make distclean`
also cleans the trees next door.

It needs, besides what the three trees need to build: `mtools`, `mkgpt`,
`e2fsprogs` (`mkfs.ext2`, `mkfs.ext4`, `debugfs`), `xorriso` for the ISO, and
`qemu-system-x86_64`. The firmware is Bang's copy of OVMF; set `OVMF_PATH` to
use another.

QEMU is started with `-cpu max`, deliberately: the default CPU models expose
neither SMEP nor SMAP, so without it the kernel's supervisor-mode protections
are silently off and a boot proves nothing about them. It gets a gigabyte of
memory, and KVM when the machine has it.

## What goes in an image

`make stage` collects into `stage/`:

```
stage/kernel.bin      the kernel, loaded by Bang                    (quark)
stage/drivers/        modules Bang hands the kernel…                (quark)
                      …plus init.elf                                (quarkutils)
stage/usr/include/quark/abi.h   the system call numbers             (quark)
stage/usr/share/doc/quark/abi.md  and what they mean                (quark)
stage/boot/           essential services, packed into boot.img      (quarkutils)
stage/usr/bin/        everything else, packed into the root         (quarkutils)
stage/etc/            passwd                                        (quarkutils)
stage/bin/sh          the shell, where a program looks for one      (here)
stage/BOOTX64.EFI     Bang itself, installed to the ESP             (bang)
```

The kernel and the userland each produce their share through
`make install DESTDIR=…`, so nothing here reaches into a source tree. The
kernel goes first: the userland checks its own copy of the system call numbers
against the header the kernel has just installed, and here — where both are
present — a missing header is an error rather than a skipped check. That stage
directory is the only place the two repositories meet.

The image is two partitions. The first is the EFI system partition: Bang, the
kernel, `bang.cfg`, and `drivers/` — the kernel's two modules, `init.elf`, and
`boot.img`, a small FAT image of the services `init` starts before there is a
root filesystem to read. The second is the root.

`bang.cfg` is written to match what is actually in the image. It always offers
Quark; a UEFI shell is added if this machine has one (`SHELL_EFI`), and a Linux
kernel if `LINUX_KERNEL` names a bzImage — both there to show that Bang can
boot something that is not Quark.

### Other people's software

Everything above builds from the three checkouts. What is built with the cross
toolchain is an *install* rather than a checkout, so the image takes it from
wherever it was built, by variable, and leaves it out by default:

| Variable | What it stages |
|---|---|
| `COREUTILS=<build>/src` | GNU coreutils, into `/usr/bin`. Quark's own `ls`, `cat` and `echo` keep their names. |
| `WAYLAND_CLIENTS=<dir>` | Every executable in the directory into `/usr/bin`, and its `share/` into `/usr/share`. `clients/` here is one: weston's clients, the small test clients, and GTK's `hello-world`. |
| `TEST_SUITES="<dir> …"` | Each directory's programs into `/usr/bin` and its `*.tests` lists into `/etc`, for `runtests`. |
| `ROOT_OVERLAYS="<dir> …"` | Trees laid out like the root — fonts, their configuration, keyboard data — copied over the stage as they are. |

Each is recorded as it is staged, so building again without the variable takes
its files back out. Programs are stripped on the way in, which needs
`x86_64-quark-strip` on `PATH`; without it they go in unstripped and the root
fills up.

After the overlays, staging builds fontconfig's caches for whatever fonts are
there (`tools/stage-font-caches.sh`), and writes `/etc/hostile.tests`: every
staged program with sixteen sets of arguments nobody would give it on purpose.

An overlay is also how a session gets a terminal. `init` starts `login`
straight onto the console unless `/etc/init.conf` names something else, and an
overlay holding `etc/init.conf` with the one line `session /usr/bin/getty` has
it start `getty`, which runs `login` on the console's pseudo-terminal — where
`isatty` is true and Ctrl-D ends a file.

And how the console gets a font. It is UTF-8, and was built with ASCII and
nothing else: an accent or a line-drawing character is drawn out of a font
it is given at boot. `toolchain/stage-unifont.sh` lays GNU Unifont out as an
overlay, and a second line in `etc/init.conf` loads it before the session
starts:

```
run /usr/bin/setfont /usr/share/consolefonts/unifont.hex
session /usr/bin/getty
```

Without one the console draws the nearest ASCII to each character it has no
picture of, and a box where there is none.

## The ports

`toolchain/` builds coreutils, libwayland, the font stack, cairo, weston's
clients, glib and GTK 4 for Quark, with the cross compilers
[quark-toolchain](https://github.com/MagicJester2764/quark-toolchain) makes.
One script per port, each saying what it needed; `toolchain/README.md` is the
account of all of it.

## Testing

Verification is a boot. A program's output goes to the framebuffer rather than
to the serial line, so the result of a test is what is on the screen: a
screenshot, or — because the text console draws one font on a grid — the same
screen read back as text.

```bash
tools/boot-test.sh keys.txt shot.ppm     # boot, type, take the picture
tools/check-rootfs.sh hdimage.bin        # e2fsck the root the guest just wrote
tools/crash-test.sh                      # stop the machine mid-write; recover
```

`boot-test.sh` drives QEMU over QMP from a script of operations — `type`,
`key`, `sleep`, `move`, `press`, `shot`, `quit`, and `expect`, which waits
until the last line on the console matches (a prompt, usually) instead of
for a number of seconds — and serves an echo on the host for the network
tests to reach. `transcript` writes down everything the console showed, and
`tools/screentext.py` reads any screenshot of it. The script fails if an
`expect` gave up or the kernel faulted. `IMG` and `RUNDIR` let an ext2 boot and an
ext4 boot run side by side. `check-rootfs.sh` runs `e2fsck` from the host on
the image a boot has just used, which is the check for any change to the file
server: it has found what reading the code did not.

On the machine itself, `dtest` checks the kernel through its ABI, `runtests
/etc/<suite>.tests` runs a list of test programs, and `qfuzz` sends every
service requests made from a seed.

## Packages

`tools/qpkg` builds, inspects and installs packages. A package is a gzipped tar
holding `PKGINFO` and a `files/` tree rooted at the target's filesystem root —
nothing exotic; the point is that installing a program is a defined operation
with metadata attached rather than a `cp` in a Makefile.

```bash
cd stage
../tools/qpkg build drivers 0.1.0 boot/DISK.ELF boot/KEYBOARD.ELF
../tools/qpkg info drivers-0.1.0.qpkg
../tools/qpkg install drivers-0.1.0.qpkg /path/to/root
```

`info` reads the capability manifest out of each binary, the same way the
spawner finds it at runtime, so what a package will be allowed to do is
inspectable before it is installed rather than discovered when it runs:

```
capabilities requested:
  boot/DISK.ELF:
    band driver
    ioport 0x1F0-0x1F7
    ioport 0x3F6-0x3F6
    irq 14
  boot/KEYBOARD.ELF:
    band driver
    ioport 0x60-0x64
    irq 1
    irq 12
```

A program that requests nothing shows nothing, and gets nothing.

## Disclaimer

This is primarily an AI-assisted experimental project, not a production system. It was built as a vehicle for exploring OS development concepts with AI tooling. Use at your own risk.
