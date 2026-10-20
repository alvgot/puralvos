# Baseline: stock Ubuntu Studio 26.10

> **Branch note (20 October 2026).** This is still the stock base measurement
> and applies unchanged to every branch. The graphics product built on it
> reaches `PURALVOS_DESKTOP_READY 24.00` under unthrottled KVM, installs 2378
> packages and removes 1072 through `tools/graphics-trim`. See
> [GRAPHICS.md](GRAPHICS.md).

What the unmodified base actually is, measured rather than assumed.

Everything below was read out of the verified ISO, not from the marketing page.
This is the reference point the strip-down is measured against: if PuralvOS
breaks something, this is what says whether the base broke it or we did.

## Provenance

| | |
| --- | --- |
| Image | `ubuntustudio-26.10-desktop-amd64.iso` |
| Size | 6.4 GB |
| sha256 | `00d1fb881501101b9f7e9fe5b22c5473f6c96fa4bb2b69f9c00e9ee69f537fe7` |
| Verified | matches Canonical's published checksum |
| Support | until July 2027 (interim release) |

## It boots

Booted under KVM (`scripts/kvmtest.sh`), on a 4 GB VM, which is Ubuntu Studio's
stated minimum.

- GRUB shows a text menu (`Try or Install Ubuntu Studio`, safe graphics, ...)
  and **boots the default entry by itself after a 13-second countdown** — no
  keypress is needed. `scripts/qmp-key.py <run-dir> ret` picks the entry
  immediately when a run should not wait. (PuralvOS's own ISO sets
  `timeout=1` and boots without any key at all.)
- Boots to a Plasma desktop.
- The stock installer (`ubuntu-desktop-bootstrap`, a snap) launches inside
  the live session automatically.

Serial carries **no kernel or live-session output**: the ISO does not mirror to
`ttyS0`, so the serial log holds only the UEFI firmware chatter and GRUB's
text-mode rendering, nothing from the kernel. Do not read the firmware bytes as
failure, and do not spend time hunting a kernel panic that was never printed.
Use `scripts/qmp-key.py` plus QMP screenshots to see the screen instead.

## What is in it

**3410 packages** in the live layer (`casper/minimal.standard.live.squashfs`).

### The kernel is the generic one

```
linux-generic            7.3.0-9.9
linux-image-generic      7.3.0-9.9
linux-headers-generic
```

**No `linux-lowlatency` and no `linux-realtime` on the live image.** The real
time kernel is installed into the *installed* system by the Ubuntu Studio
installer, not present on the ISO you boot to try things.

So a live PuralvOS that does not add the kernel itself is a generic kernel. If
the promise is a real time workstation, the live image needs the kernel added at
build time, not just the installed one.

### Firmware: what the non-free decision actually buys

19 `linux-firmware` packages (18 subpackages plus the base), including:

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
up immediately. Nineteen firmware packages are carried, and one of them,
`linux-firmware-intel-wireless`, is exactly the firmware a specific laptop's
Intel 8260 wireless adapter needs in order to have a working network at all.

A main-only image is a tidier idea and a worse workstation: it is missing the
file that makes the wifi turn on. Recorded here so the trade-off stays a
decision instead of turning into folklore.

### Tasks installed

```
ubuntustudio-desktop              ← the umbrella we do not want
ubuntustudio-desktop-core
ubuntustudio-audio                ← remove, video-only
ubuntustudio-audio-core           ← remove
ubuntustudio-audio-plugins        ← remove
ubuntustudio-video                ← keep
ubuntustudio-graphics             ← remove, video-only
ubuntustudio-photography          ← remove, video-only
ubuntustudio-publishing           ← remove, video-only
ubuntustudio-pipewire-config
ubuntustudio-lowlatency-settings
ubuntustudio-performance-tweaks
ubuntustudio-default-settings
ubuntustudio-installer            ← the task selector, keep
ubuntustudio-menu
ubuntustudio-wallpapers(-stonking)
ubuntustudio-fonts / -icon-theme / -look
```

`ubuntustudio-desktop` is present and pulls the general-purpose desktop with it.
On the graphics branch the four other task bundles (`-audio`, `-video`,
`-photography`, `-publishing`) are present and are not wanted. The umbrella is
kept out via `excludes.list` and the bundles are purged at build time
(`purge_in_chroot` in `tools/build-live.sh`) — with them go their orphaned
chains (QLC+ and the lighting stack), while `xserver-xorg-core` and
`xserver-xorg-input-wacom` are deliberately marked manual so the sweep cannot
take the graphics session or tablet support with them.

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
