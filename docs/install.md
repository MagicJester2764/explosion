# Installing ExplOSion

This is the system the disc starts: ExplOSion, running from memory, with
nothing on any disk touched. Installing it is done by hand, a step at a
time, from the shell you are at — partition a disk, make filesystems, mount
them, copy the system in, install the boot loader. Nothing here asks
questions or decides for you.

On the installation disc this guide is the command `guide`. Every line set
apart like a command is one to type, in the order they come: that is all
`tools/install-test.sh` does, and it installs a system that starts.

## Before you begin

You need a machine that starts with UEFI, a disk you are willing to erase,
and to be root, which the installation disc's only user is: log in as
`root`.

See what disks there are:

```
disks
```

Each line is a disk or a partition of one: its size, what is on it, and
which process holds it. `disk0` is the first disk; `ram0` is the memory the
running system lives in, and is not somewhere to install to.

What follows installs to `disk0`. Everything on it will be gone.

## Partition the disk

A system that starts with UEFI needs two partitions: a small one the
firmware can read, and the rest for the system.

```
parts disk0 init
parts disk0 new efi 256M
parts disk0 new root
parts disk0
```

`init` writes a new, empty table and forgets whatever was there. `new efi`
makes the EFI system partition, `disk0p1`; `new root` gives everything left
to `disk0p2`. The last command shows the result.

`parts` refuses a disk any part of which is in use.

## Make the filesystems

FAT for the firmware, ext4 for the system:

```
mkfs.fat -F 32 /dev/disk0p1
mkfs.ext4 /dev/disk0p2
```

These are the programs you know: dosfstools and e2fsprogs, unchanged. `ext2`
works too (`mkfs.ext2`), without a journal.

## Mount them

The new root goes on `/mnt`, and its EFI partition on `boot` inside it:

```
mount /dev/disk0p2 /mnt
mount --mkdir /dev/disk0p1 /mnt/boot
mount
```

On ExplOSion a mount is a server: each of those started a file server of
its own for that partition, and the last command shows them, with the
process that serves each. `disks` now shows who holds what.

## Install the system

```
qpkg sets
qpkg strap /mnt base
```

`qpkg sets` shows what there is to install. `base` is a system that starts
and can be worked at. If the disc has them, `desktop` is windows and `tests`
is what the system is checked with: name them after `base`, as in
`qpkg strap /mnt base desktop`.

`strap` copies those packages from the running system into the new root,
with the lists that say what they are. `qpkg info NAME` says what a
package's programs ask to be allowed to do, before or after.

## Install the boot loader

```
bang-install /mnt
```

This copies Bang, the kernel and the services a system starts with onto the
EFI partition, and writes down which partition the root is on. The firmware
finds Bang by where it is, so there is nothing to set in the firmware.

## Restart

Take the filesystems away, innermost first, and start again:

```
umount /mnt/boot
umount /mnt
shutdown -r
```

Remove the installation disc when the machine restarts — or `shutdown`
without `-r`, remove it, and turn the machine on. It starts from the disk:
log in as `root`. There is no password yet, and no other user.

## When something goes wrong

- `mount` says a disk *has no filesystem this system knows, or is in use*:
  make one first, or look at `disks` for who holds it.
- `umount` says a directory *is in use*: a program is in it, or has a file
  in it open, or something is mounted inside it. `cd /` and try again.
- `parts` says a disk *is in use*: one of its partitions is mounted.
  `umount` it.
- `mkfs.ext4` says *Resource busy*: the same.
- The machine starts the disc again instead of the disk: take the disc out,
  or choose the disk in the firmware's boot menu.
- To start over, start over: `umount` everything and begin at
  *Partition the disk*. Nothing is kept anywhere but on the disk.
