# PuralvOS

An audio, video and graphics workstation built on **Ubuntu Studio 26.10**.

Named for the two of us: **Pur**ia + **Alv**.

---

## What this is

Ubuntu Studio, narrowed to three disciplines and with a real time kernel, so
that every machine that comes off this build is a working audio, video and
graphics workstation out of the box.

Three things define it:

1. **Only what does the work.** Audio, video, graphics. No LibreOffice, no
   snapd, no printer drivers, no synaptic.
2. **The real time kernel, from the distro.** `linux-realtime` out of the
   Ubuntu archive. Not a PPA, so it keeps getting security updates.
3. **Our packages upgrade; yours don't.** The curated set we ship stays
   current. Anything you install afterwards is yours, and we leave it alone.

## Base

| | |
| --- | --- |
| Base | Ubuntu Studio 26.10 "Stonking Stingray" |
| Codename | `stonking` |
| Support | until July 2027 (interim release) |
| Kernel | `linux-realtime` (PREEMPT_RT) 7.3, from the archive |
| Desktop | Plasma (KDE), inherited from the base |
| Architecture | amd64 |

ISO: `ubuntustudio-26.10-desktop-amd64.iso`, 6.6 GB, checksum pinned in
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

`main` builds the full product: **all three media disciplines** — audio, video
and graphics — in the same live image. The audio-only, video-only and
graphics-only variants live on their own branches and are not built from this
image. Each has its own docs and naming. Main is the branch this repo keeps
the whole product on.

| branch | product | contains |
| --- | --- | --- |
| **main** | `puralvos-full-*` | audio + video + graphics |
| `audio-only` | `puralvos-audio-*` | audio only |
| `video-only` | `puralvos-video-*` | video only |
| `graphics-only` | `puralvos-graphics-*` | graphics only |

ISO timestamps use the ISO name "puralvos-{discipline}-YYYYMMDD-HHMM.iso,"
where "FULL" means the full union of all three disciplines and not "bigger
than stock".

There are two build variants within main: a live-only image and an
installable one. Both give the full set the same curated package tree and
both have exactly the same boot time; only the second copies the packages to
an installed system. Main defaults to the *live* build. The installer lives
on a separate branch because it is a different product and its boot path is
not measured yet.

The default build on main is the Live image because it is measured and used:
snapd is one of the two largest boot costs on the stock ISO and it is already
excluded by [`excludes.list`](excludes.list). The other cost is `ldconfig`.
`PURALVOS_INSTALLER=1` builds the installable variant with snapd kept for
installer use. Its boot-time has not been re-measured.

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
tools/build-live.sh        build the full image (or the installable one)
scripts/kvmboottime.sh     measure boot-to-desktop, with the ISO throttled
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

The build command now emits `puralvos-full-YYYYMMDD-HHMM.iso`.
`make live` is the target. ISO names stay consistent with the branch family:
`puralvos-audio-YYYYMMDD-HHMM.iso`, `puralvos-video-YYYYMMDD-HHMM.iso`,
`puralvos-graphics-YYYYMMDD-HHMM.iso`.

---
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
PURALVOS_RESUME=0 make live     # from scratch, puralvos-full-*.iso
make live                       # reuse the unpacked layers
make boot-test                  # boot it under KVM and read the serial log
```

`PURALVOS_RESUME=0` is the from-scratch switch. Without it the build reuses an
existing unpacked tree, which is much faster and is what you want while
iterating. See the note on the resume marker in `tools/build-live.sh`.

## The kernel

**`linux-realtime`, discovered at build time, not hardcoded.**

This one caught us out. On Ubuntu 26.10:

```
linux-lowlatency   Depends: linux-image-generic     ← the GENERIC kernel
linux-realtime     Depends: linux-image-realtime    ← a real PREEMPT_RT build
```

`linux-lowlatency` is the generic kernel with low-latency boot arguments. It
still preempts cooperatively and will still glitch. And the same name means
different things per release — on 24.04 it pulls `linux-image-lowlatency`, on
26.10 it pulls `linux-image-generic` — so a hardcoded name would have been
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

The Ubuntu Studio 26.10 full image builds with the real time kernel, the three
task bundles and the full graphics set. The live session autologins as
`puralvos` and an ordinary `puralv` account exists for a console or ssh login.
The 26.10 full ISO still has to finish KVM boot and in-guest verification
before its numbers replace the historical 26.04 measurements.

Verification is opt-in so it does not cost boot time or launch applications:
`PURALVOS_SELFTEST=1` puts `console=ttyS0,115200n8` and `puralvos.selftest=1`
on the menu entries, and the self test then reports the running kernel,
`os-release` and every check over the serial port. A normal build boots with
the stock kernel line; `scripts/kvmboottime.sh` is the boot-time measurement,
using the marker the live session writes to the serial port.

See [docs/WORK-REPORT.md](docs/WORK-REPORT.md) for where the last build stands
and what is still open.

Not yet done:

- a licence — **still the first thing to do.** Everything in this repository is
  currently all rights reserved by default, and `tools/make-brand.py` has code
  in it.
- the non-free manifest tool, so that shipping proprietary software stays a
  tracked decision (`tools/manifest.py`)
- the installer path. The default build is the Live image (snapd masked);
  `PURALVOS_INSTALLER=1` keeps snapd and the stock snap installer. How the
  installed system should get this package set — preseed, install-then-exclude,
  or the curated filesystem wholesale — is still Alv and Puria's to decide.
- the icon theme, the Plasma theme and the app menu XML. `ubuntustudio-look`,
  `ubuntustudio-icon-theme` and `ubuntustudio-menu` are still installed and
  still Ubuntu Studio's, which makes the icon theme the largest remaining
  branding gap. See [docs/BRANDING.md](docs/BRANDING.md).
- audio verified on real hardware. Every real time claim in this repository has
  been verified on a machine with no sound card, which is enough to prove the
  *configuration* and not enough to prove the *performance*. `jack-xruns` in the
  self test skips itself for exactly this reason rather than reporting a pass it
  did not earn.
