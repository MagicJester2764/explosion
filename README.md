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
