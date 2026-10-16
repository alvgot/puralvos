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

This is a deliberate position and the opposite of the dyneV image, which is
main-only with no blobs anywhere including its kernel. PuralvOS enables
`multiverse` and `restricted` because everything that works is the requirement:
NVIDIA drivers, Intel and Broadcom WiFi firmware, unfree codecs. A media
workstation that refuses to drive the graphics card in the machine is not a
workstation.

The cost is that PuralvOS cannot claim to be free software. `tools/manifest.py`
exists so that stays a tracked decision rather than a surprise.

## Layout

```
tasks.list              what we install, and why. The single source of truth
excludes.list           what we deliberately do not ship, with reasons
apt/puralvos.sources    archive and components
base/CHECKSUMS         pinned checksum of the base ISO
tools/upgrade-curated.sh  upgrade our packages, leave yours alone
tools/manifest.py       list what non-free software the image carries
```

## Getting started

```sh
make base      # fetch and verify the Ubuntu Studio ISO
make audit     # report what non-free software the base carries
```

## Licence and trademarks

No licence file yet — **add one before there is code in the repository.** With
none, the default is all rights reserved and nobody, including us, may legally
reuse anything here. GPL-3.0 matches the Ubuntu base.

**Ubuntu and Ubuntu Studio are trademarks of Canonical Ltd, and Ubuntu Studio is
not affiliated with Canonical.** This is a derivative and must not use either
name in its own branding.

## Status

Early. The base image is fetched and verified; the task set is defined from
upstream's own task table; the upgrade policy is written. Not yet done:

- the image build itself
- booting and verifying it under KVM
- the non-free manifest tool
- a curated package manifest for the upgrade policy
