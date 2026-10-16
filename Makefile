# PuralvOS build entry points.
#
# The image build is not here yet. What exists is everything around it: fetch
# the base and prove it is the base we think it is.

SHELL := /bin/bash
BASE_DIR := base
BASE_ISO := $(BASE_DIR)/ubuntustudio-26.04.1-desktop-amd64.iso
BASE_URL := https://cdimage.ubuntu.com/ubuntustudio/releases/resolute/release/ubuntustudio-26.04.1-desktop-amd64.iso
SCRIPTS  := scripts
TOOLS   := tools

.PHONY: help base verify-base kernel brand packages packages-report selftest rt-fix test-booth
ROOTFS ?= /var/tmp/puralvos-build/layer
help:
	@echo "PuralvOS"
	@grep -E '^[a-z-]+:.*?##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | expand -t18

$(BASE_ISO):
	mkdir -p $(BASE_DIR)
	curl -fSL --retry 3 -o $@ $(BASE_URL)

base: $(BASE_ISO) ## fetch the Ubuntu Studio base image

verify-base: ## check the base against Canonical's published checksum
	cd $(BASE_DIR) && grep -F "$(notdir $(BASE_ISO))" CHECKSUMS | sha256sum -c -

kernel: ## ask apt which real time kernel to use
	python3 $(TOOLS)/kernel-select.py --policy realtime

brand: ## generate the identity assets from brand/tokens.json
	python3 $(TOOLS)/make-brand.py

packages: ## generate the package declaration from tasks.list
	python3 $(TOOLS)/make-package-declaration.py -o $(BASE_DIR)/puralvos/selftest-packages.txt

rt-fix: ## apply the real time audio fix, and verify it actually took
	@echo "Runs inside a booted PuralvOS image as root, not on this machine."
	@echo "  tools/puralvos-rt-fix           # the invoking or sudo user"
	@echo "  tools/puralvos-rt-fix USER"

packages-report: ## inventory the built image and propose removals
	python3 $(TOOLS)/report-packages.py $(ROOTFS) | tee docs/PACKAGES.md
	@echo
	@echo "Bare list of candidate package names:"
	@echo "  python3 $(TOOLS)/report-packages.py --list-only"

selftest: ## run the self test in a booted image (not on this machine)
	@echo "puralvos-selftest runs INSIDE a booted PuralvOS image, not here."
	@echo "Pass puralvos.selftest=1 on the kernel command line, or run it by hand:"
	@echo "  /usr/local/bin/puralvos-selftest"
	@echo
	@echo "Smoke test only, anywhere:"
	@echo "  XWAIT=2 tools/puralvos-selftest   # XWAIT=2 skips the desktop wait"

test-booth: ## boot the base under KVM and wait for the desktop
	$(SCRIPTS)/kvmtest.sh $(BASE_ISO) puralvos-base 600 60
	@echo
	@echo "GRUB waits for a keypress. Get past it with:"
	@echo "  python3 $(SCRIPTS)/qmp-key.py /tmp/opencode/kvmrun/puralvos-base ret"
	@echo
	@echo "There is no serial console on this ISO. Judge it from screenshots."
