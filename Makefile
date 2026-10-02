# ExplOSion — a Quark meta-distro.
#
# This is where the system is assembled and run. Quark builds a kernel,
# quarkutils builds the programs that run on it and Bang builds a bootloader;
# none of them knows what an image looks like. ExplOSion stages all three and
# turns them into something bootable.
#
#   make stage   collect artifacts from ../quark, ../quarkutils and ../bang
#   make hd      assemble hdimage.bin (GPT: EFI system partition + ext2 root)
#   make run     boot it in QEMU
#   make iso     assemble explosion.iso, which boots from memory
#   make run-iso boot that, with DISK=<image> as a disk to install onto
#   make run-disk DISK=<image>   boot a disk as it is: what was installed
#
# Nothing here is reached into by its neighbours: the dependency runs one way,
# from the distro down to the kernel, the userland and the bootloader.

QUARK_DIR      ?= ../quark
QUARKUTILS_DIR ?= ../quarkutils
BANG_DIR       ?= ../bang

# The firmware lives in Bang because that is what needs it to exist; point this
# at /usr/share/OVMF instead if you would rather use the system copy.
OVMF_PATH ?= $(BANG_DIR)/firmware-redist/ovmf

STAGE := stage

# What every package in an image built here says its version is.
VERSION := 0.21

# ExplOSion's own programs: its package tool, what puts the boot loader on a
# new system, and the reader of the installation guide. They are built
# against ../quarkutils' runtime, as that tree's programs are.
PROGRAMS := qpkg bang-install guide

# Room for the fonts and the font stack's programs and tests; 33 MiB was
# nearly full without them, and 64 MiB filled up the moment a program linked
# glib statically -- one of those is four megabytes on its own.
ROOTFS_SIZE_KB  := 131072
BOOT_IMG_SIZE_KB := 1024

BOOT_IMG        := boot.img
ROOTFS_IMG      := rootfs.img
ROOTFS_EXT2_IMG := rootfs-ext2.img
ROOTFS_EXT4_IMG := rootfs-ext4.img
HD_IMG          := hdimage.bin

# An EFI application to offer in the boot menu, if this host has one.
SHELL_EFI       ?= /usr/share/edk2/ovmf/Shell.efi
# And a Linux kernel, to show the handover protocol working. Empty by default:
# an 18 MB kernel belongs in a boot test, not in every image this makes. Set it
# to a bzImage to get a Linux entry in the menu.
LINUX_KERNEL    ?=

# GNU coreutils for Quark, if a build of it is around. Point this at the `src/`
# directory `toolchain/build-coreutils.sh` leaves behind and the image carries
# the programs. Empty by default for the same reason as LINUX_KERNEL: it is 15
# MB of somebody else's build, and the toolchain that produces it is an install
# rather than a checkout.
COREUTILS       ?=

# Wayland clients built against the ported libwayland, by
# `toolchain/build-weston-client.sh`. Same arrangement and same reason as
# COREUTILS: they are musl programs, and the toolchain that makes them is an
# install rather than a checkout.
WAYLAND_CLIENTS ?=

# Directories of test programs and the lists `runtests` reads, as made by
# `toolchain/build-tests.sh` and the port build scripts. Space-separated; each
# contributes its executables to /usr/bin and its `*.tests` files to /etc.
TEST_SUITES     ?=

# Directories laid out like the root filesystem — usr/share/fonts, etc/fonts,
# var/cache — as made by `toolchain/stage-fonts.sh` and the port build
# scripts. Space-separated; each is copied over the stage as it is, names and
# all, and a later stage without it takes its files back out.
ROOT_OVERLAYS   ?=

# The programs that make and check filesystems — mkfs.ext4, mkfs.fat and
# their checkers — as `toolchain/build-e2fsprogs.sh` and
# `build-dosfstools.sh` leave them. On by default and tracked, unlike the
# ports above: a system that cannot make a filesystem cannot install itself,
# and assembling the image that does should not need a cross compiler.
FSTOOLS         ?= fstools

# What makes an installation disc of a system: how it greets, and a session
# on a terminal. Staged for `make iso` and nothing else.
LIVE_OVERLAY    :=
iso: LIVE_OVERLAY := live

.PHONY: all stage hd hd-ext4 hd-fat32 iso run run-ext4 run-fat32 run-iso run-disk clean distclean FORCE

all: hd

# ---------------------------------------------------------------------------
# Staging
# ---------------------------------------------------------------------------

# The kernel installs kernel.bin, its two modules and its ABI; the userland
# installs drivers/init.elf, boot/, usr/bin/ and etc/. Bang contributes only
# BOOTX64.EFI.
#
# In that order, and into one directory, which is the whole of how the two meet:
# the userland checks its own copy of the system call numbers against the
# header the kernel has just put in the stage, and REQUIRE_ABI makes a missing
# header an error rather than a skipped check. Neither repository names the
# other; this is the only place that knows there are two.
stage: FORCE
	@mkdir -p $(STAGE)
	@# What the last stage took from WAYLAND_CLIENTS, TEST_SUITES and the
	@# overlays, back out: this one may have been asked for none of them.
	@# Before the installs, so that a file one of those had replaced — an
	@# overlay's /etc/passwd — is put back by the tree that owns it.
	@./tools/stage-forget.sh $(STAGE) .clients .suites .overlays
	$(MAKE) -C $(QUARK_DIR) install DESTDIR=$(CURDIR)/$(STAGE)
	$(MAKE) -C $(QUARKUTILS_DIR) install DESTDIR=$(CURDIR)/$(STAGE) REQUIRE_ABI=1
	$(MAKE) -C $(BANG_DIR) build
	@cp $(BANG_DIR)/BOOTX64.EFI $(STAGE)/BOOTX64.EFI
	@for p in $(PROGRAMS); do \
		(cd programs/$$p && cargo build --release) || exit 1; \
		cp programs/$$p/target/x86_64-unknown-none/release/$$p $(STAGE)/usr/bin/$$p; \
	done
	@mkdir -p $(STAGE)/home/root $(STAGE)/bin
	@# What the firmware starts, kept in the root as well: a system installs
	@# another by copying what it was started with, and tools/make-esp.sh
	@# lays the same files out for an image built here.
	@./tools/make-boot-img.sh $(STAGE) $(BOOT_IMG) $(BOOT_IMG_SIZE_KB)
	@mkdir -p $(STAGE)/usr/lib/explosion/boot/drivers $(STAGE)/usr/share/doc/explosion
	@cp $(STAGE)/BOOTX64.EFI $(STAGE)/kernel.bin bang.cfg $(STAGE)/usr/lib/explosion/boot/
	@cp $(STAGE)/drivers/* $(BOOT_IMG) $(STAGE)/usr/lib/explosion/boot/drivers/
	@cp docs/install.md $(STAGE)/usr/share/doc/explosion/install.md
	@# `/bin/sh` is where a program that starts a shell looks for one —
	@# weston-terminal execs `$$SHELL` or this — and nothing in Quark's tree
	@# decides where a distribution puts its shell. A copy rather than a link,
	@# because FAT32 has none and the image is assembled for three
	@# filesystems.
	@cp $(STAGE)/usr/bin/QSH.ELF $(STAGE)/bin/sh
	@# Runs either way: with no COREUTILS it takes back what a previous stage
	@# put there, so unsetting it un-stages them.
	@./tools/stage-coreutils.sh $(STAGE) $(COREUTILS)
	@if [ -n "$(WAYLAND_CLIENTS)" ]; then \
		n=0; \
		for f in $(WAYLAND_CLIENTS)/*; do \
			[ -f "$$f" ] && [ -x "$$f" ] || continue; \
			b=`basename $$f`; \
			cp "$$f" $(STAGE)/usr/bin/$$b; \
			echo "usr/bin/$$b" >> $(STAGE)/.clients; \
			x86_64-quark-strip $(STAGE)/usr/bin/$$b 2>/dev/null || true; \
			n=$$((n + 1)); \
		done; \
		echo "wayland: staged $$n clients"; \
		if [ -d "$(WAYLAND_CLIENTS)/share" ]; then \
			mkdir -p $(STAGE)/usr/share; \
			cp -r $(WAYLAND_CLIENTS)/share/* $(STAGE)/usr/share/; \
			(cd $(WAYLAND_CLIENTS) && find share \( -type f -o -type l \)) \
				| sed 's|^|usr/|' >> $(STAGE)/.clients; \
			echo "wayland: staged the data its clients read"; \
		fi; \
	fi
	@# A test suite is a directory of programs and the lists runtests reads.
	@# Programs go where commands go; a list goes to /etc under its own name.
	@for d in $(TEST_SUITES); do \
		n=0; \
		for f in $$d/*; do \
			[ -f "$$f" ] || continue; \
			b=`basename $$f`; \
			case "$$b" in \
			*.tests) cp "$$f" $(STAGE)/etc/$$b; \
			   echo "etc/$$b" >> $(STAGE)/.suites ;; \
			*) [ -x "$$f" ] || continue; \
			   cp "$$f" $(STAGE)/usr/bin/$$b; \
			   echo "usr/bin/$$b" >> $(STAGE)/.suites; \
			   x86_64-quark-strip $(STAGE)/usr/bin/$$b 2>/dev/null || true; \
			   n=$$((n + 1)) ;; \
			esac; \
		done; \
		echo "tests: staged $$n programs from $$d"; \
	done
	@./tools/stage-overlays.sh $(STAGE) $(FSTOOLS) $(ROOT_OVERLAYS) $(LIVE_OVERLAY)
	@# After the overlays, whose fonts and configuration it needs.
	@./tools/stage-font-caches.sh $(STAGE)
	@# Nearly last, since it lists every program the stage now has.
	@./tools/gen-hostile-tests.sh $(STAGE)
	@# And last: whose every file is.
	@./tools/stage-packages.py $(STAGE) packages.conf $(VERSION)
	@echo "staged into $(STAGE)"

# ---------------------------------------------------------------------------
# Filesystem images
# ---------------------------------------------------------------------------

# The essential services, mounted by init before a real root filesystem
# exists. Staging makes it (tools/make-boot-img.sh), because the root carries
# a copy.
$(BOOT_IMG): stage
	@true

# FAT32 root. Names keep their case here, and a long one gets a short alias
# that is all Quark's FAT32 reads.
$(ROOTFS_IMG): stage
	dd if=/dev/zero of=$(ROOTFS_IMG) bs=1k count=$(ROOTFS_SIZE_KB) status=none
	mformat -i $(ROOTFS_IMG) -F ::
	mmd -i $(ROOTFS_IMG) ::/dev
	@cd $(STAGE) && \
	find bin usr etc home -mindepth 0 -type d | sort | while read d; do \
		mmd -i $(CURDIR)/$(ROOTFS_IMG) "::$$d" 2>/dev/null || true; \
	done; \
	find bin usr etc home -type f | while read f; do \
		mcopy -i $(CURDIR)/$(ROOTFS_IMG) "$$f" "::$$f"; \
	done

# An ext2 or ext4 root, filled from the stage by tools/populate-ext.sh, which
# also gives Quark's own programs the names the shell and init look for there.
#
# One recipe for both: the two differ in the mkfs invocation and nothing else,
# since debugfs speaks to either and the directory layout is the same. $(1) is
# the image, $(2) the mkfs command.
#
# The ext4 root carries a journal. 1 MiB is the smallest mke2fs will make with
# 1 KiB blocks, and a transaction here is a dozen blocks, so the size is set by
# what the tool allows rather than by what is needed.
define ROOTFS_RULE
$(1): stage
	dd if=/dev/zero of=$(1) bs=1k count=$$(ROOTFS_SIZE_KB) status=none
	$(2) $(1)
	./tools/populate-ext.sh $(1) $$(STAGE)
endef

$(eval $(call ROOTFS_RULE,$(ROOTFS_EXT2_IMG),mkfs.ext2 -b 1024 -F -q))
$(eval $(call ROOTFS_RULE,$(ROOTFS_EXT4_IMG),mkfs.ext4 -b 1024 -F -q -J size=1))

# The EFI system partition: the loader, the kernel it loads, and the modules it
# hands the kernel. boot.img rides along as a module. tools/make-esp.sh says
# what goes in and writes the boot menu to match.
ESP_KB   := $(shell expr $(ROOTFS_SIZE_KB) + 3072)
ESP_ENV   = SHELL_EFI="$(SHELL_EFI)" LINUX_KERNEL="$(LINUX_KERNEL)" INITRD="initrd.img"

fat.img: stage $(BOOT_IMG)
	FAT32=1 $(ESP_ENV) ./tools/make-esp.sh fat.img $(ESP_KB) $(STAGE) $(BOOT_IMG)

# ---------------------------------------------------------------------------
# Disk images
# ---------------------------------------------------------------------------

HD_SECTORS = $(shell expr '(' $(ESP_KB) + $(ROOTFS_SIZE_KB) + 2048 ')' '*' 2)

hd: fat.img $(ROOTFS_EXT2_IMG)
	mkgpt -o $(HD_IMG) --image-size $(HD_SECTORS) \
		--part fat.img --type system \
		--part $(ROOTFS_EXT2_IMG) --type linux

hd-ext4: fat.img $(ROOTFS_EXT4_IMG)
	mkgpt -o $(HD_IMG) --image-size $(HD_SECTORS) \
		--part fat.img --type system \
		--part $(ROOTFS_EXT4_IMG) --type linux

hd-fat32: fat.img $(ROOTFS_IMG)
	mkgpt -o $(HD_IMG) --image-size $(HD_SECTORS) \
		--part fat.img --type system \
		--part $(ROOTFS_IMG) --type linux

# ---------------------------------------------------------------------------
# The live system, and the ISO it boots from
# ---------------------------------------------------------------------------

# A system that runs from memory. Its root is a filesystem image the
# bootloader loads as a module — one more file in \drivers — and a RAM disk
# serves. Nothing on it has to be able to read the medium it was booted from,
# which is what lets one image boot from a CD and from a USB stick on a
# machine there is no disk driver for.
LIVE_IMG := live.img
ESP_LIVE := fat-live.img
ISO      := explosion.iso
# The root, and what the FAT around it needs for itself.
ESP_LIVE_KB := $(shell expr $(ROOTFS_SIZE_KB) + 16384)

$(eval $(call ROOTFS_RULE,$(LIVE_IMG),mkfs.ext2 -b 1024 -F -q))

$(ESP_LIVE): stage $(BOOT_IMG) $(LIVE_IMG)
	$(ESP_ENV) ./tools/make-esp.sh $(ESP_LIVE) $(ESP_LIVE_KB) $(STAGE) $(BOOT_IMG) $(LIVE_IMG):LIVE.IMG

# One image for both: the EFI partition is appended to an ISO 9660
# filesystem and named twice — in an El Torito catalog, which is where
# firmware looks on a CD, and in a GPT, which is where it looks on a disk.
# What the ISO filesystem itself holds is for whoever opens the disc on
# another system: what this is, and how to install it.
iso: $(ESP_LIVE)
	rm -rf iso
	mkdir -p iso
	cp README.md iso/README.TXT
	xorriso -as mkisofs -R -J -V EXPLOSION -o $(ISO) \
		-append_partition 2 0xef $(ESP_LIVE) -appended_part_as_gpt \
		-e --interval:appended_partition_2:all:: -no-emul-boot \
		-partition_offset 16 iso

# ---------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------

# -cpu max is deliberate: the default CPU models expose neither SMEP nor SMAP,
# so the kernel's supervisor-mode protections are silently inactive without it
# and a boot test proves nothing about them.
#
# KVM whenever the machine has it. Without it QEMU interprets every
# instruction, and anything that moves pixels — a compositor pushing a
# screenful per frame — runs tens of times slower than the hardware it is
# pretending to be. That reads as "the window manager is broken" rather than
# as "this is an emulator", which is the wrong thing to have to work out.
KVM := $(shell test -w /dev/kvm && echo -enable-kvm)

# -m 1G, not QEMU's default 128 MiB. A program that links a toolkit is tens of
# megabytes, and a spawner reads the whole image into its own memory before
# giving the pages to the child — so the same program is in memory twice while
# it starts. Nothing here is paged out, either.
QEMU_FLAGS = $(KVM) -cpu max -m 1G -L $(OVMF_PATH)/ -pflash $(OVMF_PATH)/OVMF_CODE.fd \
             -device rtl8139,netdev=n -netdev user,id=n

run: hd
	qemu-system-x86_64 $(QEMU_FLAGS) -serial stdio -hda $(HD_IMG)

run-ext4: hd-ext4
	qemu-system-x86_64 $(QEMU_FLAGS) -serial stdio -hda $(HD_IMG)

run-fat32: hd-fat32
	qemu-system-x86_64 $(QEMU_FLAGS) -hda $(HD_IMG)

# With a disk to install onto, if there is one to hand: DISK=target.img.
run-iso: iso
	qemu-system-x86_64 $(QEMU_FLAGS) -serial stdio -cdrom $(ISO) $(if $(DISK),-hda $(DISK))

# A disk as it is, and nothing built: what an installation left. (`run`
# assembles the image it starts, and would assemble it over this one.)
run-disk:
	@test -n "$(DISK)" || { echo "usage: make run-disk DISK=<image>"; exit 2; }
	qemu-system-x86_64 $(QEMU_FLAGS) -serial stdio -hda $(DISK)

# ---------------------------------------------------------------------------

clean:
	rm -rf $(STAGE) iso
	rm -f fat.img $(BOOT_IMG) $(ROOTFS_IMG) $(ROOTFS_EXT2_IMG) $(ROOTFS_EXT4_IMG) $(HD_IMG)
	rm -f $(LIVE_IMG) $(ESP_LIVE) $(ISO)

# Also clean the trees we build from.
distclean: clean
	$(MAKE) -C $(QUARK_DIR) clean
	$(MAKE) -C $(QUARKUTILS_DIR) clean
	$(MAKE) -C $(BANG_DIR) clean

FORCE:
