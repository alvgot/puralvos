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
base/puralvos/            generated package list and declaration
brand/tokens.json          the palette, one input for the whole identity
brand/assets/              generated mark, wordmark, glyphs, wallpapers
tools/make-brand.py        generate every brand asset from tokens.json
tools/make-package-declaration.py   derive the package list from tasks.list
tools/report-packages.py   inventory and removal proposal, from the built rootfs
tools/build-live.sh        build the live image
tools/puralvos-selftest    verify a booted image from the inside
tools/puralvos-selftest.service  the unit that runs it at boot, opt-in
tools/puralvos-rt-fix      the in-image real time audio fix
tools/lib/desktop-exec.sh  read the executable out of a .desktop file
tools/test-desktop-exec    prove it reads the real entries correctly
tools/kernel-select.py     find the real time kernel by asking apt
tools/upgrade-curated.sh   upgrade our packages, leave yours alone
scripts/kvmtest.sh         boot an image headlessly, capture serial + screenshots
scripts/qmp-key.py         send keys to a running guest
docs/ARCHITECTURE.md       how the images are built
docs/STANDARD-TOOLS.md    Ubuntu's tools first, and the audited exceptions
docs/BASELINE.md           what the stock base actually contains, measured
docs/PACKAGES.md           what the built image carries, and what could go
docs/BRANDING.md           every place Ubuntu's name has to go, and why
docs/PERFORMANCE.md        what "fast" means here, as numbers that can fail
docs/WORK-REPORT.md        where the build stands and what is still open
```

## Getting started

```sh
make base          # fetch and verify the Ubuntu Studio ISO
make kernel        # ask apt which real time kernel to use
make brand         # generate the identity assets
make packages      # derive the package declaration from tasks.list
make packages-report   # what the built image carries, and what could go
make test-parser       # prove the desktop-entry parser reads real entries
```

Building an image needs about 45 GB free and takes roughly half an hour:

```sh
PURALVOS_RESUME=0 make live     # from scratch
make live                       # reuse the unpacked layers
make boot-test                  # boot it under KVM and read the serial log
```

`PURALVOS_RESUME=0` is the from-scratch switch. Without it the build reuses an
existing unpacked tree, which is much faster and is what you want while
iterating. See the note on the resume marker in `tools/build-live.sh`.

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

**No licence file. With none, the default is all rights reserved and nobody,
including us, may legally reuse anything here — and there is code in this
repository.** This is the most overdue thing in the project.

GPL-3.0 matches the Ubuntu base and is the obvious candidate, but the choice is
yours and it has consequences for anyone who takes this further: GPL-3.0 makes
derivatives GPL-3.0, and it is incompatible with proprietary redistribution.

**Ubuntu and Ubuntu Studio are trademarks of Canonical Ltd, and Ubuntu Studio is
not affiliated with Canonical.** This is a derivative and must not use either
name in its own branding. PuralvOS keeps `ID_LIKE=ubuntu` and
`UBUNTU_CODENAME` in `os-release` on purpose — see
[docs/BRANDING.md](docs/BRANDING.md) — and the self test checks for *Ubuntu
Studio* rather than for the substring *ubuntu*, so those two stay.

## Status

The image builds and boots. A booted image reports its own kernel, its own
`os-release` and every check's result over the serial port, so "is this image
actually PuralvOS" is answered from outside the machine rather than by looking
at the build log.

See [docs/WORK-REPORT.md](docs/WORK-REPORT.md) for where the last build stands
and what is still open.

Not yet done:

- a licence — **still the first thing to do.** Everything in this repository is
  currently all rights reserved by default, and `tools/make-brand.py` has code
  in it.
- the non-free manifest tool, so that shipping proprietary software stays a
  tracked decision (`tools/manifest.py`)
- the installer decision: whether an installed system gets this package set
  through a preseed, through an install-then-exclude pass, or by shipping a
  curated filesystem wholesale. It is Alv and Puria's to make.
- the icon theme, the Plasma theme and the app menu XML. `ubuntustudio-look`,
  `ubuntustudio-icon-theme` and `ubuntustudio-menu` are still installed and
  still Ubuntu Studio's, which makes the icon theme the largest remaining
  branding gap. See [docs/BRANDING.md](docs/BRANDING.md).
- audio verified on real hardware. Every real time claim in this repository has
  been verified on a machine with no sound card, which is enough to prove the
  *configuration* and not enough to prove the *performance*. `jack-xruns` in the
  self test skips itself for exactly this reason rather than reporting a pass it
  did not earn.
