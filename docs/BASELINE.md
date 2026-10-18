# Baseline: stock Ubuntu Studio 26.04.1

What the unmodified base actually is, measured rather than assumed.

Everything below was read out of the verified ISO, not from the marketing page.
This is the reference point the strip-down is measured against: if PuralvOS
breaks something, this is what says whether the base broke it or we did.

## Provenance

| | |
| --- | --- |
| Image | `ubuntustudio-26.04.1-desktop-amd64.iso` |
| Size | 6.6 GB |
| sha256 | `2b25d06203c8a2f60da23e20e3afd1fa400f8ff8104fd074c1b7e49fc3768084` |
| Verified | matches Canonical's published checksum |
| Support | until April 2029 |

## It boots

Booted under KVM (`scripts/kvmtest.sh`), on a 4 GB VM, which is Ubuntu Studio's
stated minimum.

- GRUB waits at its menu for a keypress. **An unattended boot needs
  `scripts/qmp-key.py <run-dir> ret`** to get past it, or the run looks like a
  hang when it is only a menu.
- Boots to a Plasma desktop.
- The stock installer (`ubuntu-desktop-bootstrap`, a snap) launches inside
  the live session automatically.

There is **no serial console output**. The ISO does not mirror to `ttyS0`, so
the serial log stays empty on a perfectly healthy boot. Do not read that as
failure, and do not spend time hunting a kernel panic that was never printed.
Use `scripts/qmp-key.py` plus QMP screenshots to see the screen instead.

## What is in it

**3362 packages** in the live layer (`casper/minimal.standard.live.squashfs`).

### The kernel is the generic one

```
linux-generic            7.0.0-14.14
linux-image-generic       7.0.0-14.14
linux-headers-generic
```

**No `linux-lowlatency` and no `linux-realtime` on the live image.** The real
time kernel is installed into the *installed* system by the Ubuntu Studio
installer, not present on the ISO you boot to try things.

So a live PuralvOS that does not add the kernel itself is a generic kernel. If
the promise is a real time workstation, the live image needs the kernel added at
build time, not just the installed one.

### Firmware: what the non-free decision actually buys

18 `linux-firmware-*` packages, including:

```
linux-firmware-intel-wireless      ← the Intel 8260 firmware
linux-firmware-broadcom-wireless
linux-firmware-realtek
linux-firmware-mediatek
linux-firmware-nvidia-graphics
linux-firmware-amd-graphics
linux-firmware-qualcomm-wireless
```

This is the entire point of PuralvOS shipping proprietary software, and it shows
up immediately. Eighteen firmware packages are carried, and one of them,
`linux-firmware-intel-wireless`, is exactly the firmware a specific laptop's
Intel 8260 wireless adapter needs in order to have a working network at all.

A main-only image is a tidier idea and a worse workstation: it is missing the
file that makes the wifi turn on. Recorded here so the trade-off stays a
decision instead of turning into folklore.

### Tasks installed

```
ubuntustudio-desktop              ← the umbrella we do not want
ubuntustudio-desktop-core
ubuntustudio-audio                ← keep
ubuntustudio-audio-core
ubuntustudio-audio-plugins
ubuntustudio-video                ← keep
ubuntustudio-graphics             ← keep
ubuntustudio-photography          ← remove
ubuntustudio-pipewire-config
ubuntustudio-lowlatency-settings
ubuntustudio-performance-tweaks
ubuntustudio-default-settings
ubuntustudio-installer            ← the task selector, keep
ubuntustudio-menu
ubuntustudio-wallpapers(-resolute)
ubuntustudio-fonts / -icon-theme / -look
```

`ubuntustudio-desktop` is present and pulls the general-purpose desktop with it.
`ubuntustudio-photography` is present and is not wanted. These are the two
metapackages the strip-down has to deal with; see `excludes.list`.

## The step that is not a package

From `ubuntustudio-installer`'s helper, the `fix` action:

```
/etc/security/limits.d/30-ubuntustudio-audio.conf    ← real time priority
usermod -aG audio <user>
```

This is what makes audio run at real time priority. Without it the workstation
installs cleanly, every application is present, the mixer opens, and audio
still glitches under load because the process was never actually granted RT
priority. It has to be verified from **inside the built image**, by reading the
limits file and the group membership, not by assuming a package pulled it in.

## Before we strip anything

- [ ] record the exact installed package set of the base, for comparison
- [ ] confirm which applications actually launch on the base, so that "PuralvOS
      is broken" can be told apart from "this application was already broken"
- [ ] measure the image size, so the saving from stripping is a number and not
      a feeling

`tools/puralvos-selftest` is the tool for the second of those, and it should be
run against this base as well as against PuralvOS. Two rules it follows, both
learned the hard way, are worth keeping: a check that cries wolf is worse than
no check because it trains you to ignore the one that matters, and a self test
that reports a pass it did not earn is how a broken image ships.

## Live image layout, for anyone rebuilding it

Ubuntu 24.04 changed this and it is the first thing to trip people up:

```
/casper/minimal.squashfs
/casper/minimal.standard.squashfs
/casper/minimal.standard.live.squashfs
/casper/vmlinuz
```

There is no `casper/filesystem.squashfs` any more. A live image is the base
layer plus the standard layer plus the live layer, and overlays go on top of
that. Anything that assumes a single squashfs — which is most tooling written
before 24.04 — will not work here.
