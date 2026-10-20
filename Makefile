# PuralvOS build entry points.
#
# The image build is not here yet. What exists is everything around it: fetch
# the base and prove it is the base we think it is.

SHELL := /bin/bash
BASE_DIR := base
BASE_ISO := $(BASE_DIR)/ubuntustudio-26.10-desktop-amd64.iso
BASE_URL := https://cdimage.ubuntu.com/ubuntustudio/releases/stonking/release/ubuntustudio-26.10-desktop-amd64.iso
SCRIPTS  := scripts
TOOLS   := tools

.PHONY: help base verify-base kernel brand packages packages-all packages-docs \
	packages-report snap-census selftest rt-fix test-booth test-parser live \
	boot-test check
ROOTFS ?= /var/tmp/puralvos-build/layer
ISO    ?= $(shell ls -1t out/puralvos-video-*.iso 2>/dev/null | head -1)

# Snap is a decision, not a lean. excludes.list carries it, but the census is
# here because the saving is in gigabytes and a package list hides that.
snap-census:
	@echo "snaps under \$$ROOTFS/var/lib/snapd/snaps:"
	@ls -1 $(ROOTFS)/var/lib/snapd/snaps/*.snap 2>/dev/null | xargs -r -n1 basename | sed 's/^/  /' || echo "  none"
	@du -sh $(ROOTFS)/var/lib/snapd 2>/dev/null | sed 's/^/  total: /' || true
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

packages-all: ## write the complete installed package list
	python3 $(TOOLS)/report-packages.py --all $(ROOTFS) > $(BASE_DIR)/puralvos/packages-installed.txt
	@wc -l < $(BASE_DIR)/puralvos/packages-installed.txt | sed 's/^/  /'
	@echo "  packages listed with versions, sorted, one per line"

packages-docs: ## copy the complete package list into the documentation
	@extra=""; i=$$(ls -1t out/puralvos-video-*.iso 2>/dev/null | head -1); \
	[ -n "$$i" ] && extra="--iso $$i"; \
	python3 $(TOOLS)/make-packages-doc.py $$extra \
		$(BASE_DIR)/puralvos/packages-installed.txt > docs/PACKAGES-INSTALLED.md
	@echo "  docs/PACKAGES-INSTALLED.md written: $$(wc -l < $(BASE_DIR)/puralvos/packages-installed.txt) packages"

snap-census: ## list the snaps in the built image

selftest: ## run the self test in a booted image (not on this machine)
	@echo "puralvos-selftest runs INSIDE a booted PuralvOS image, not here."
	@echo "Pass puralvos.selftest=1 on the kernel command line, or run it by hand:"
	@echo "  /usr/local/bin/puralvos-selftest"
	@echo
	@echo "Smoke test only, anywhere:"
	@echo "  XWAIT=2 tools/puralvos-selftest   # XWAIT=2 skips the desktop wait"

# The checks that can run here, on this machine, without a booted image. Small,
# and they catch the class of bug where a verification tool itself is wrong.
#
# The desktop-entry parser had two implementations, one in the build and one in
# the self test, and between them they reported OpenLP, Ardour and VLC as broken
# applications on an image where all three are installed and working. That is
# the worst kind of bug in a verification tool: it looks like a product defect,
# and the response is to go and look for one.
check: test-parser ## run every check that does not need a booted image
	@echo "all local checks passed"

test-parser: ## prove the desktop-entry parser reads the real Exec lines
	bash $(TOOLS)/test-desktop-exec

live: ## build the live image (needs ~45 GB; PURALVOS_RESUME=0 to rebuild from scratch)
	$(TOOLS)/build-live.sh --keep

# Boot the most recent ISO headlessly and print what it said about itself.
#
# The image writes uname, os-release and every check's result to the serial port,
# so the result is in the log and does not need a screenshot to be read.
boot-test: ## boot the newest ISO under KVM and show what it reported about itself
	@ls -1t out/puralvos-video-*.iso 2>/dev/null | head -1 | \
		{ read i; echo "booting $$i"; \
		  $(SCRIPTS)/kvmtest.sh "$$i" puralvos-boot 900 30; \
		  echo; \
		  echo "=== what the image said about itself ==="; \
		  grep -E '^(INFO|RESULT|PURALVOS SELFTEST END)' /tmp/opencode/kvmrun/puralvos-boot/serial.log || \
			echo "no serial output; the image may not have been built with console=ttyS0"; }
	@echo
	@echo "Screenshots: /tmp/opencode/kvmrun/puralvos-boot/"

test-booth: ## boot the base under KVM and wait for the desktop
	$(SCRIPTS)/kvmtest.sh $(BASE_ISO) puralvos-base 600 60
	@echo
	@echo "GRUB waits for a keypress. Get past it with:"
	@echo "  python3 $(SCRIPTS)/qmp-key.py /tmp/opencode/kvmrun/puralvos-base ret"
	@echo
	@echo "There is no serial console on this ISO. Judge it from screenshots."
