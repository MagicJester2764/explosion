# ExplOSion

A Quark meta-distro. This is where the system is assembled and run, and where
other people's software is built for it.

```
../quark            the microkernel
../quarkutils       the programs that run on it
../bang             the UEFI bootloader
../quark-toolchain  the cross compilers, for the ports
./                  this: staging, image assembly, QEMU targets, every port
                    of somebody else's software, and the programs that make
                    a distribution of it: its packages, its installer, its
                    guide, and who its users are
```

The dependency runs one way. ExplOSion reaches down to the three trees beside
it; none of them knows it exists, and none of them knows what an image looks
like.

## Build and run

```bash
make stage   # build ../quark, ../quarkutils and ../bang, collect into stage/
make hd      # assemble hdimage.bin (GPT: EFI system partition + ext2 root)
make run     # boot it in QEMU
make iso     # assemble explosion.iso: the installation disc
make run-iso # boot that, with DISK=<image> as a disk to install onto
make run-disk DISK=<image>   # boot a disk as it is: what was installed
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

It is the installation disc: it greets whoever logs in with where the guide
is, and [`docs/install.md`](docs/install.md) is the guide. See *Installing*.

`make clean` removes the staging directory and the images. `make distclean`
also cleans the trees next door.

It needs, besides what the three trees need to build: `mtools`, `mkgpt`,
`e2fsprogs` (`mkfs.ext2`, `mkfs.ext4`, `debugfs`), `xorriso` for the ISO, and
`qemu-system-x86_64`; and for `tools/install-test.sh`, `sfdisk` and
`dosfstools`, which check what the guest made. The firmware is Bang's copy of
OVMF; set `OVMF_PATH` to use another.

QEMU is started with `-cpu max`, deliberately: the default CPU models expose
neither SMEP nor SMAP, so without it the kernel's supervisor-mode protections
are silently off and a boot proves nothing about them. It gets a gigabyte of
memory, four processors (`make run SMP=1` for one), and KVM when the machine
has it.

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
stage/usr/bin/qpkg, bang-install, guide                             (here)
stage/usr/lib/explosion/boot/   what the firmware starts, again     (here)
stage/usr/share/doc/explosion/install.md   the guide                (here)
stage/var/lib/qpkg/   whose every file is                           (here)
```

The last four are what lets a system install another. The root carries a
copy of everything on the EFI partition — Bang, the kernel, its modules and
`boot.img` — because an installer has nothing to copy from but the system it
is running on.

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

Two ports are in every image, and their programs are tracked here.
`fstools/` holds `mkfs.ext4`, `mkfs.ext2`, `mkfs.fat` and the two checkers,
`e2fsck` and `fsck.fat` — e2fsprogs and dosfstools, unpatched. A system that
cannot make a filesystem cannot install itself, and assembling the image
that does should not need a cross compiler. `FSTOOLS=` leaves them out.
`dbus/` holds D-Bus, unpatched (`toolchain/build-dbus.sh`): the message bus
a desktop's programs find each other on, and its tools. `DBUS=` leaves it
out.

A session has a bus when it asks for one. `dbus-run-session` starts a bus
for a command and ends it with the command — `dbus-run-session wm
weston-terminal`, and everything the compositor starts is on the bus — as
on any system whose session nothing else starts one for. A GTK program
there registers its application on the bus, and `gdbus` and `dbus-send`
call whatever is on it. The bus takes a connection from its own user only.
What tells two machines apart, `/etc/machine-id`, is made by `init` the
first time a system starts, so an installation is a machine of its own and
not the image it was made from.

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

And how a machine gets somewhere to put memory it has run out of room for. A
third kind of line starts a program and leaves it running, and `swapd` is one
to start: it keeps pages the kernel takes from programs that are not using
them, in a file, and gives them back when they are touched.

```
start /usr/bin/swapd /var/swap 64
```

is a file of up to sixty-four megabytes, made empty when the machine starts
and as long as the most that was ever written out at once. With it, a
program that wants more memory than the machine has waits for some to be
written out; without it, it is ended. `free` says how much memory there is,
how much is written out, and how much has gone out and come back since the
machine was started. It is not started unless a line says so: an
installation disc runs from memory, and a file there is memory too.

A program that is to be kept running is a `service` line: a name, the
services it needs, the name it is up once it has registered, and what is
done when it ends — started again when it fails, unless it says otherwise.
`init` starts each once what it needs is up, starts it again if it fails, and
answers `svc`, which says what every service is doing and what it has
printed lately; everything a service prints is also in `/var/log/messages`.

```
service NAME [needs=A,B] [restart=always|on-failure|never] [register=X] PATH [ARGUMENT...]
```

`../quarkutils/docs/services.md` says it whole.

## Installing

`make iso` makes the installation disc, and `docs/install.md` is how it is
used: partition a disk, make filesystems, mount them, copy the system in,
install the boot loader, restart. Each step is a command typed at a shell,
as on Arch, whose installation this takes its shape from. On the disc the
guide is `guide`, a section at a time.

```
parts disk0 init
parts disk0 new efi 256M
parts disk0 new root
mkfs.fat -F 32 /dev/disk0p1
mkfs.ext4 /dev/disk0p2
mount /dev/disk0p2 /mnt
mount --mkdir /dev/disk0p1 /mnt/boot
qpkg strap /mnt base
passwd --root /mnt root
user --root /mnt add ada
passwd --root /mnt ada
user --root /mnt ada may power become
bang-install /mnt
umount /mnt/boot
umount /mnt
shutdown -r
```

What is under those commands is not Linux's, and four things about it are
this system's own:

- **A mount is a server.** `mount` starts a file server for the partition
  and hands it to the one its directory is in. `mount` with no arguments
  says which process serves each filesystem, `ps` shows them, and the FAT
  code reading an EFI partition somebody just made is in another address
  space from the code serving the root.
- **A disk is claimed, not locked.** A driver gives each partition to one
  writer at a time, so a filesystem that is mounted cannot be formatted —
  not because a tool checks, but because the file server serving it holds
  it. `disks` shows who holds what.
- **A package says what its programs may do.** Every program here carries
  what it asks the system to allow it — ports, interrupts, its device's
  registers, a scheduling band — and a spawner grants from that. `qpkg info NAME` reads it out:
  what a package can do is known before it is installed. And a system
  installs another by copying itself: `qpkg strap` takes the packages from
  the running system, with the lists that say what they are.
- **An account is what it may do.** See *Users*, below: the user the guide
  makes can turn the machine off and run a command as root because the
  fourth of those lines says so, and for no other reason.

To try it by hand, give the disc a blank disk and follow the guide; the disk
then starts by itself:

```bash
truncate -s 1G disk.img
make run-iso DISK=disk.img      # install, and `shutdown` when done
make run-disk DISK=disk.img     # what was installed
```

`tools/install-test.sh` does the same without anybody at the keyboard: it
types the guide's own commands at the disc, with a blank disk attached, and
a password wherever one is asked for; restarts into the disk; logs in as the
user the guide made — not with a wrong password, and with the right one —
and holds that user to being one; and has this machine's `sfdisk`,
`fsck.fat` and `e2fsck` look at what was made.

## Users

There is more than one user, and each has a password (`passwd`). Whose a
file is, and who may read it, is Unix's: owners, groups and modes, kept by
the file server. What is this system's own is the rest of what "root" means
anywhere else.

On Unix, a program run by root may do anything, and a program that needs to
do one privileged thing is marked to run as root whoever starts it. Neither
exists here. A program on Quark may do what it holds a *capability* for, and
it holds what whoever started it handed over — so what a user's programs can
do is decided once, when the session begins, by what the session is handed.
`/etc/rights` says what that is, account by account, and `user` edits it:

```
~$ user
NAME             ID  HOME                 MAY
root              0  /home/root           everything
ada            1000  /home/ada            power, become
~$ user ada may tasks
ada may: power, tasks, become. From their next login.
~$ user ada may not power
```

| right | what a session of the account is handed |
|-------|------------------------------------------|
| `power` | the right to turn the machine off and restart it |
| `tasks` | authority over every task: ending anybody's program |
| `become` | nothing at login; it lets `as` take the account's own password |
| `clock` | the right to set the date: `date -s 2026-10-02 18:30:00` |
| `all` | all of it, and the right to say who a task is. Root's, unless a line says otherwise |

A program that needs a right its account has not got says so — `shutdown:
this account may not turn the machine off` — where it used to do nothing.

`as USER COMMAND` runs one command as somebody else: `as root mount
/dev/disk0p1 /mnt`. An account that may `become` is asked for its *own*
password; any other is asked for USER's. There is no program anywhere on the
system that runs as root because of what file it is: `as`, `su`, `login` and
`passwd` hold nothing, and ask the one server that may say who a task is
(`auth`, in `../quarkutils`), which checks the password itself. `qpkg info
boot` shows what that server holds, the way it shows any program's.

What somebody types is theirs too. Each login is a session, a terminal is
the session's that has it, and a program somebody left running when they
logged out cannot read what the next person types or open the terminal by
its name. Nor can it take the keyboard, the mouse or the screen: those are
the person's logged in at the console. That is all true of a terminal —
which an installed system's sessions are on. The plain console an image
built with no `init.conf` starts on keeps what is typed for whoever is
logged in at it, and draws whatever anybody writes to it.

`user add NAME` and `user remove NAME` make and take away accounts; the
Unix-named tools (`useradd`, `groupadd`, `gpasswd`) are there too, for
groups and for the options `user` does not have. All of them take `--root
DIR` first, to work on a system mounted at DIR, which is how the guide makes
the first user of one.

## The ports

`toolchain/` builds coreutils, libwayland, the font stack, cairo, weston's
clients, glib, GTK 4, e2fsprogs and dosfstools for Quark, with the cross
compilers
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
service requests made from a seed. Two of `dtest`'s sections need something
the image has to have: `dtest msi` the driver for the device every test
machine is given, which the device manager starts from `/usr/lib/drivers`
where the `tests` package puts it, and `dtest pressure` somewhere to write
memory out to (`start /usr/bin/swapd /var/swap 16`). Without them each says
so and checks what it can. `lspci` says what is in the machine and which
program drives each device.

## Packages

Every file in an image belongs to a package, and each package is a list in
the image: `/var/lib/qpkg/NAME` says what the package is, which *set* it is
in, every file it owns with its length and a checksum, and what each of its
programs asks to be allowed. `packages.conf` says which files are whose, and
`tools/stage-packages.py` writes the lists while staging. `system` comes last
there and takes what nothing else claimed, so every file is somebody's.

```
~$ qpkg
PACKAGE      SET       VERSION   FILES       SIZE
boot         base      0.22          7    1.8 MiB
fstools      base      0.22          6    3.6 MiB
quark        base      0.22          2    102 KiB
system       base      0.22         40    1.7 MiB
~$ qpkg info boot
boot 0.22
  What the firmware starts: Bang, the kernel, and the services a system runs before it has a root.
  set base, 7 files, 1.8 MiB
What its programs ask to be allowed:
  /usr/lib/explosion/boot/drivers/boot.img:auth band server, set_uid, task_mgmt any, phys_alloc 64 pages, ioport 0x604-0x604, ioport 0xB004-0xB004, ioport 0xCF9-0xCF9
  /usr/lib/explosion/boot/drivers/boot.img:disk band driver, ioport 0x1F0-0x1F7, ioport 0x3F6-0x3F6, irq 14
  /usr/lib/explosion/boot/drivers/boot.img:keyboard band driver, ioport 0x60-0x64, irq 1, irq 12
  /usr/lib/explosion/boot/drivers/boot.img:net band driver, ioport 0x0-0xFFFF, irq any, phys_alloc 64 pages
  ...
```

(The network driver asks for every port there is and any interrupt. This is
where that shows. And `auth` holds everything a session may be handed, since
it is what hands it: the one program with `set_uid`.)

`qpkg files`, `owner` and `verify` are what they say — `verify` reads every
file back against its checksum — and `qpkg strap ROOT SET...` copies the
packages of those sets into another root. A few files are the system's
owner's to change — the accounts, the passwords, what each account may do,
what a session starts (`yours`, in `packages.conf`) — and `verify` asks only
that those are there, and says how many have been changed. `base` is a system that starts;
`desktop` and `tests` are in an image built with the clients and the suites.

What a package's programs may do is read out of the programs themselves,
the way a spawner reads it when it starts one (`tools/readmanifest.py`), so
it is known before the package is installed rather than discovered when it
runs. A program that asks for nothing shows nothing, and gets nothing.

## Disclaimer

This is primarily an AI-assisted experimental project, not a production system. It was built as a vehicle for exploring OS development concepts with AI tooling. Use at your own risk.
