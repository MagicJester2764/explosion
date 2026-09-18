# ExplOSion — a Quark meta-distro.
#
# This is where the system is assembled and run. Quark builds a kernel and the
# programs that run on it; Bang builds a bootloader; neither knows what an image
# looks like. ExplOSion stages both and turns them into something bootable.
#
#   make stage   collect artifacts from ../quark and ../bang into stage/
#   make hd      assemble hdimage.bin (GPT: EFI system partition + ext2 root)
#   make run     boot it in QEMU
#
# Nothing here is reached into by its neighbours: the dependency runs one way,
# from the distro down to the kernel and the bootloader.

QUARK_DIR ?= ../quark
BANG_DIR  ?= ../bang

# The firmware lives in Bang because that is what needs it to exist; point this
# at /usr/share/OVMF instead if you would rather use the system copy.
OVMF_PATH ?= $(BANG_DIR)/firmware-redist/ovmf

STAGE := stage

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

.PHONY: all stage hd hd-ext4 hd-fat32 cd run run-ext4 run-fat32 run-iso clean distclean FORCE

all: hd

# ---------------------------------------------------------------------------
# Staging
# ---------------------------------------------------------------------------

# `make -C ../quark install` lays out kernel.bin, drivers/, boot/, usr/bin/ and
# etc/ for us. Bang contributes only BOOTX64.EFI.
stage: FORCE
	@mkdir -p $(STAGE)
	$(MAKE) -C $(QUARK_DIR) install DESTDIR=$(CURDIR)/$(STAGE)
	$(MAKE) -C $(BANG_DIR) build
	@cp $(BANG_DIR)/BOOTX64.EFI $(STAGE)/BOOTX64.EFI
	@mkdir -p $(STAGE)/home/root $(STAGE)/bin
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
			x86_64-quark-strip $(STAGE)/usr/bin/$$b 2>/dev/null || true; \
			n=$$((n + 1)); \
		done; \
		echo "wayland: staged $$n clients"; \
		if [ -d "$(WAYLAND_CLIENTS)/share" ]; then \
			mkdir -p $(STAGE)/usr/share; \
			cp -r $(WAYLAND_CLIENTS)/share/* $(STAGE)/usr/share/; \
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
			*.tests) cp "$$f" $(STAGE)/etc/$$b ;; \
			*) [ -x "$$f" ] || continue; \
			   cp "$$f" $(STAGE)/usr/bin/$$b; \
			   x86_64-quark-strip $(STAGE)/usr/bin/$$b 2>/dev/null || true; \
			   n=$$((n + 1)) ;; \
			esac; \
		done; \
		echo "tests: staged $$n programs from $$d"; \
	done
	@# Runs either way, like stage-coreutils.sh, so unsetting it un-stages.
	@./tools/stage-overlays.sh $(STAGE) $(ROOT_OVERLAYS)
	@# After the overlays, whose fonts and configuration it needs.
	@./tools/stage-font-caches.sh $(STAGE)
	@# Last, since it lists every program the stage now has.
	@./tools/gen-hostile-tests.sh $(STAGE)
	@echo "staged into $(STAGE)"

# ---------------------------------------------------------------------------
# Filesystem images
# ---------------------------------------------------------------------------

# The essential services, mounted by init before a real root filesystem exists.
$(BOOT_IMG): stage
	dd if=/dev/zero of=$(BOOT_IMG) bs=1k count=$(BOOT_IMG_SIZE_KB) status=none
	mformat -i $(BOOT_IMG) -F ::
	@cd $(STAGE)/boot && find . -type f | while read f; do \
		mcopy -i $(CURDIR)/$(BOOT_IMG) "$$f" "::$$f"; \
	done

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
# hands the kernel. boot.img rides along as a module.
fat.img: stage $(BOOT_IMG)
	$(eval BOOT_FAT_KB := $(shell expr $(ROOTFS_SIZE_KB) + 3072))
	dd if=/dev/zero of=fat.img bs=1k count=$(BOOT_FAT_KB) status=none
	mformat -i fat.img ::
	mmd -i fat.img ::/EFI
	mmd -i fat.img ::/EFI/BOOT
	mcopy -i fat.img $(STAGE)/BOOTX64.EFI ::/EFI/BOOT
	mcopy -i fat.img $(STAGE)/kernel.bin ::/kernel.bin
	@# The boot menu is written to match what actually goes into the image, so
	@# it never offers something that is not there. Anything beyond Quark is
	@# whatever this build host happened to have lying around: a UEFI shell to
	@# show that Bang can hand off to another EFI application at all — which is
	@# how it would reach a Windows boot manager — and a Linux kernel to show
	@# the handover protocol working.
	@cp bang.cfg $(STAGE)/bang.cfg
	@if [ -f $(SHELL_EFI) ]; then \
		mmd -i fat.img ::/EFI/tools; \
		mcopy -i fat.img $(SHELL_EFI) ::/EFI/tools/Shell.efi; \
		printf '\nentry UEFI Shell\n    chainload \\EFI\\tools\\Shell.efi\n' >> $(STAGE)/bang.cfg; \
	 fi
	@if [ -n "$(LINUX_KERNEL)" ] && [ -f "$(LINUX_KERNEL)" ]; then \
		mcopy -i fat.img $(LINUX_KERNEL) ::/vmlinuz; \
		printf '\nentry Linux\n    linux   \\vmlinuz\n' >> $(STAGE)/bang.cfg; \
		if [ -f initrd.img ]; then \
			mcopy -i fat.img initrd.img ::/initrd.img; \
			printf '    initrd  \\initrd.img\n' >> $(STAGE)/bang.cfg; \
		fi; \
		printf '    options console=ttyS0 earlyprintk=serial,ttyS0 panic=5\n' >> $(STAGE)/bang.cfg; \
	 fi
	mcopy -i fat.img $(STAGE)/bang.cfg ::/bang.cfg
	mmd -i fat.img ::/drivers
	@for f in $(STAGE)/drivers/*; do mcopy -i fat.img "$$f" ::/drivers/; done
	mcopy -i fat.img $(BOOT_IMG) ::/drivers/boot.img

# ---------------------------------------------------------------------------
# Disk images
# ---------------------------------------------------------------------------

HD_SECTORS = $(shell expr '(' $(ROOTFS_SIZE_KB) + 3072 + $(ROOTFS_SIZE_KB) + 2048 ')' '*' 2)

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

cd: fat.img
	mkdir -p iso
	cp fat.img iso
	xorriso -as mkisofs -R -f -e fat.img -no-emul-boot -o cdimage.iso iso

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

QEMU_FLAGS = $(KVM) -cpu max -L $(OVMF_PATH)/ -pflash $(OVMF_PATH)/OVMF_CODE.fd \
             -device rtl8139,netdev=n -netdev user,id=n

run: hd
	qemu-system-x86_64 $(QEMU_FLAGS) -serial stdio -hda $(HD_IMG)

run-ext4: hd-ext4
	qemu-system-x86_64 $(QEMU_FLAGS) -serial stdio -hda $(HD_IMG)

run-fat32: hd-fat32
	qemu-system-x86_64 $(QEMU_FLAGS) -hda $(HD_IMG)

run-iso: cd
	qemu-system-x86_64 $(QEMU_FLAGS) -cdrom cdimage.iso

# ---------------------------------------------------------------------------

clean:
	rm -rf $(STAGE) iso
	rm -f fat.img $(BOOT_IMG) $(ROOTFS_IMG) $(ROOTFS_EXT2_IMG) $(ROOTFS_EXT4_IMG) $(HD_IMG) cdimage.iso

# Also clean the trees we build from.
distclean: clean
	$(MAKE) -C $(QUARK_DIR) clean
	$(MAKE) -C $(BANG_DIR) clean

FORCE:
