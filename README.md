# PuralvOS

An audio, video and graphics workstation built on **Ubuntu Studio 26.04.1 LTS**.

Named for the two of us: **Pur**ia + **Alv**.

---

## What this is

Ubuntu Studio, narrowed to three disciplines and with a real time kernel, so
that every machine that comes off this build is a working audio, video and
graphics workstation out of the box.

Three things define it:

1. **Only what does the work.** Audio, video, graphics. No LibreOffice, no
   snapd, no printer drivers, no synaptic.
2. **The real time kernel, from the distro.** `linux-lowlatency` out of the
   Ubuntu archive. Not a PPA, so it keeps getting security updates.
3. **Our packages upgrade; yours don't.** The curated set we ship stays
   current. Anything you install afterwards is yours, and we leave it alone.

## Base

| | |
| --- | --- |
| Base | Ubuntu Studio 26.04.1 LTS "Resolute Raccoon" |
| Codename | `resolute` |
| Support | until April 2029 |
| Kernel | `linux-lowlatency` 7.0, from the archive |
| Desktop | Plasma (KDE), inherited from the base |
| Architecture | amd64 |

ISO: `ubuntustudio-26.04.1-desktop-amd64.iso`, 6.6 GB, checksum pinned in
[`base/CHECKSUMS`](base/CHECKSUMS) and verified on download.

## On proprietary software

PuralvOS ships proprietary software on purpose.

This is a deliberate position. PuralvOS enables `multiverse` and `restricted`
because everything that works is the requirement:
NVIDIA drivers, Intel and Broadcom WiFi firmware, unfree codecs. A media
workstation that refuses to drive the graphics card in the machine is not a
workstation.

The cost is that PuralvOS cannot claim to be free software. `tools/manifest.py`
exists so that stays a tracked decision rather than a surprise.

## Images

Two, built from the same curated filesystem so the thing you try live is the
thing you get installed:

| | boots to | installs to disk |
| --- | --- | --- |
| **PuralvOS** | full workstation, live | yes, via ubiquity |
| **PuralvOS Live** | full workstation, live | optional |

Ubuntu Studio 26.04.1 already ships ubiquity 26.04.1 and the casper live
machinery, so neither image is being built from nothing. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how, and for the one decision
still open: whether the installed system gets our package set through a
preseed, through an install-then-exclude pass, or by shipping a curated
filesystem wholesale.

## Layout

```
tasks.list                 what we install, and why. Single source of truth
excludes.list              what we deliberately do not ship, with reasons
apt/puralvos.sources       archive and components
base/CHECKSUMS             pinned checksum of the base ISO
brand/tokens.json          the palette, one input for the whole identity
brand/assets/              generated mark, wordmark, glyphs, wallpapers
tools/make-brand.py        generate every brand asset from tokens.json
tools/make-package-declaration.py   derive the package list from tasks.list
tools/puralvos-selftest    verify a booted image from the inside
tools/kernel-select.py     find the real time kernel by asking apt
tools/upgrade-curated.sh   upgrade our packages, leave yours alone
docs/ARCHITECTURE.md       how the images are built
docs/BASELINE.md           what the stock base actually contains, measured
docs/BRANDING.md           every place Ubuntu's name has to go, and why
docs/PERFORMANCE.md        what "fast" means here, as numbers that can fail
```

## Getting started

```sh
make base          # fetch and verify the Ubuntu Studio ISO
make kernel        # ask apt which real time kernel to use
make brand         # generate the identity assets
make packages      # derive the package declaration from tasks.list
```

## The kernel

**`linux-realtime`, discovered at build time, not hardcoded.**

This one caught us out. On Ubuntu 26.04:

```
linux-lowlatency   Depends: linux-image-generic     ← the GENERIC kernel
linux-realtime     Depends: linux-image-realtime    ← a real PREEMPT_RT build
```

`linux-lowlatency` is the generic kernel with low-latency boot arguments. It
still preempts cooperatively and will still glitch. And the same name means
different things per release — on 24.04 it pulls `linux-image-lowlatency`, on
26.04 it pulls `linux-image-generic` — so a hardcoded name would have been
right on one base and silently wrong on the other.

`tools/kernel-select.py` asks apt what the kernel actually depends on and
refuses any package whose image is not realtime.

## Licence and trademarks

No licence file yet — **add one before there is code in the repository.** With
none, the default is all rights reserved and nobody, including us, may legally
reuse anything here. GPL-3.0 matches the Ubuntu base.

**Ubuntu and Ubuntu Studio are trademarks of Canonical Ltd, and Ubuntu Studio is
not affiliated with Canonical.** This is a derivative and must not use either
name in its own branding.

## Status

Base image fetched and verified. Task set derived from upstream's own task
table. Kernel selection verified against the archive. Upgrade policy written.
Architecture written down.

Not yet done:

- the image build
- booting and verifying under KVM
- the non-free manifest tool
- a licence
- the installer decision, which is Alv and Puria's to make
