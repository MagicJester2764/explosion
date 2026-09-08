# ExplOSion

A Quark meta-distro. This is where the system is assembled and run.

```
../quark    the microkernel and the programs that run on it
../bang     the UEFI bootloader
./          this: staging, image assembly, QEMU targets
```

## Build and run

```bash
make stage   # build ../quark and ../bang, collect artifacts into stage/
make hd      # assemble hdimage.bin (GPT: EFI system partition + ext2 root)
make run     # boot it in QEMU
```

`make hd` builds an ext2 root; `make hd-fat32` and `make run-fat32` use FAT32
instead. `make cd` and `make run-iso` produce a bootable ISO.

`make clean` removes the staging directory and the images. `make distclean`
also cleans the trees next door.

## Layout

`make stage` collects into `stage/`:

```
stage/kernel.bin      the kernel, loaded by Bang
stage/BOOTX64.EFI     Bang itself, installed to the ESP
stage/drivers/        modules Bang hands the kernel, plus init.elf
stage/boot/           essential services, packed into boot.img
stage/usr/bin/        everything else, packed into the root filesystem
stage/etc/            passwd
```

Quark produces all of that through `make -C ../quark install DESTDIR=…`, so
nothing here reaches into its source tree, and nothing there knows an image
exists.

## Packages

`tools/qpkg` builds, inspects and installs packages. A package is a gzipped tar
holding `PKGINFO` and a `files/` tree rooted at the target's filesystem root —
nothing exotic; the point is that installing a program is a defined operation
with metadata attached rather than a `cp` in a Makefile.

```bash
cd stage
../tools/qpkg build coreutils 0.1.0 usr/bin/CAT.ELF usr/bin/LS.ELF
../tools/qpkg info coreutils-0.1.0.qpkg
../tools/qpkg install coreutils-0.1.0.qpkg /path/to/root
```

`info` reads the capability manifest out of each binary, the same way the
spawner finds it at runtime, so what a package will be allowed to do is
inspectable before it is installed rather than discovered when it runs:

```
capabilities requested:
  usr/bin/CAT.ELF:
    phys_alloc 64 pages
```

A program that requests nothing shows nothing, and gets nothing.
