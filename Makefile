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

ROOTFS_SIZE_KB  := 33792
BOOT_IMG_SIZE_KB := 1024

BOOT_IMG        := boot.img
ROOTFS_IMG      := rootfs.img
ROOTFS_EXT2_IMG := rootfs-ext2.img
HD_IMG          := hdimage.bin

.PHONY: all stage hd hd-fat32 cd run run-fat32 run-iso clean distclean FORCE

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
	@mkdir -p $(STAGE)/home/root
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

# FAT32 root. Names keep their case here; the ext2 path below does not.
$(ROOTFS_IMG): stage
	dd if=/dev/zero of=$(ROOTFS_IMG) bs=1k count=$(ROOTFS_SIZE_KB) status=none
	mformat -i $(ROOTFS_IMG) -F ::
	@cd $(STAGE) && \
	find usr etc home -mindepth 0 -type d | sort | while read d; do \
		mmd -i $(CURDIR)/$(ROOTFS_IMG) "::$$d" 2>/dev/null || true; \
	done; \
	find usr etc home -type f | while read f; do \
		mcopy -i $(CURDIR)/$(ROOTFS_IMG) "$$f" "::$$f"; \
	done

# ext2 root, the default. Names are lowercased and the .ELF suffix dropped,
# because that is what the shell and init look for on an ext2 filesystem.
$(ROOTFS_EXT2_IMG): stage
	dd if=/dev/zero of=$(ROOTFS_EXT2_IMG) bs=1k count=$(ROOTFS_SIZE_KB) status=none
	mkfs.ext2 -b 1024 -F -q $(ROOTFS_EXT2_IMG)
	debugfs -w -R "mkdir usr" $(ROOTFS_EXT2_IMG) >/dev/null 2>&1
	debugfs -w -R "mkdir usr/bin" $(ROOTFS_EXT2_IMG) >/dev/null 2>&1
	debugfs -w -R "mkdir etc" $(ROOTFS_EXT2_IMG) >/dev/null 2>&1
	debugfs -w -R "mkdir home" $(ROOTFS_EXT2_IMG) >/dev/null 2>&1
	debugfs -w -R "mkdir home/root" $(ROOTFS_EXT2_IMG) >/dev/null 2>&1
	@cd $(STAGE) && find usr etc -type f | while read f; do \
		target=$$(echo "$$f" | tr '[:upper:]' '[:lower:]' | sed 's/\.elf$$//'); \
		debugfs -w -R "write $$f $$target" $(CURDIR)/$(ROOTFS_EXT2_IMG) >/dev/null 2>&1; \
	done

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
QEMU_FLAGS = -cpu max -L $(OVMF_PATH)/ -pflash $(OVMF_PATH)/OVMF_CODE.fd \
             -device rtl8139,netdev=n -netdev user,id=n

run: hd
	qemu-system-x86_64 $(QEMU_FLAGS) -serial stdio -hda $(HD_IMG)

run-fat32: hd-fat32
	qemu-system-x86_64 $(QEMU_FLAGS) -hda $(HD_IMG)

run-iso: cd
	qemu-system-x86_64 $(QEMU_FLAGS) -cdrom cdimage.iso

# ---------------------------------------------------------------------------

clean:
	rm -rf $(STAGE) iso
	rm -f fat.img $(BOOT_IMG) $(ROOTFS_IMG) $(ROOTFS_EXT2_IMG) $(HD_IMG) cdimage.iso

# Also clean the trees we build from.
distclean: clean
	$(MAKE) -C $(QUARK_DIR) clean
	$(MAKE) -C $(BANG_DIR) clean

FORCE:
