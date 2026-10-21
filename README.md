# PuralvOS Graphics

A graphics-only workstation built on **Ubuntu Studio 26.10**.

Named for the two of us: **Pur**ia + **Alv**.

---

## What this is

Ubuntu Studio, narrowed to graphics and with a real time kernel, so that every
machine that comes off this build is a working graphics workstation out of the
box. This is the graphics branch of a four-image family: the full merged ISO
and the audio-only and video-only branches are built from the same harness.

Three things define it:

1. **Only what does the work.** Graphics. No DAWs or audio plugins, no video
   editors, no LibreOffice, no snapd, no printer drivers, no synaptic.
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
| Kernel | `linux-realtime` 7.3, from the archive |
| Desktop | Plasma (KDE), inherited from the base |
| Architecture | amd64 |

ISO: `ubuntustudio-26.10-desktop-amd64.iso`, 6.4 GB, checksum pinned in
[`base/CHECKSUMS`](base/CHECKSUMS) and verified on download.

## What is in the graphics image

The product set comes from Ubuntu Studio's own `ubuntustudio-graphics` task
plus the archive's real time kernel:

- **Raster painting and editing** — GIMP, Krita, MyPaint
- **Vector illustration** — Inkscape
- **3D modelling and animation** — Blender
- **2D animation** — Pencil2D, Synfig Studio
- **Pixel art** — PikoPixel
- **Scanning** — Skanpage
- **Colour** — KColorChooser
- **Brushes and clip art** — `create-resources`, `openclipart-svg`
- **Tablet input** — `xserver-xorg-input-wacom`

The audio, video, photography and publishing task bundles are removed.
PipeWire, WirePlumber and the JACK compatibility library stay because the
graphics applications use them for preview audio and desktop integration.
ImageMagick and FFmpeg stay as runtimes: Krita, Pencil2D and ImageMagick link
or invoke FFmpeg, and Synfig uses ImageMagick.

The trim is a set of explicit lists under
[`tools/graphics-trim`](tools/graphics-trim), applied by the build and audited
with `apt-get -s purge` before an ISO is written. Five lists are deliberately
disabled because removing them would take product packages with them:

| list | why it is disabled |
| --- | --- |
| `03-graphics` | this is the product bundle, not a trim |
| `07-online-accounts` | Skanpage → `qml6-module-org-kde-purpose` → `libkaccounts6-2` |
| `10-gnustep` | PikoPixel is a GNUstep application; the batch removes its runtime |
| `11-geo` | Blender → `libopenimageio2.5` → OpenCV → GDAL |
| `12-ml-video` | Krita/MLT depend on OpenCV; the batch removes the ONNX/TensorFlow runtime |

`05-documents` is active but deliberately reduced. It removes Okular and the
standalone document tools, while keeping the poppler libraries, Ghostscript
and the font package that GIMP, Inkscape, Krita and Skanpage link. Removing
the whole batch took all four editors with it during the first graphics build.

The details, including the exact dependency paths and the failed first build,
are in [docs/GRAPHICS.md](docs/GRAPHICS.md).

## ISO naming

The family uses `puralvos-<product>-<YYYYMMDD-HHMM>.iso`, with the build stamp
in the name:

| product | current file |
| --- | --- |
| audio | `out/puralvos-audio-20261020-0103.iso` |
| video | `out/puralvos-video-20261020-0239.iso` |
| graphics | `out/puralvos-graphics-20261020-0827.iso` |
| full | `out/puralvos-full-20261019-1855.iso` |

The existing audio and full ISOs were renamed from `puralvos-live-*` to this
convention. The graphics build writes the new name directly. The audio-only
and full branch build scripts still carry their old `puralvos-live` slug; that
is a follow-up on those branches, not a graphics-branch change.

## On proprietary software

PuralvOS ships proprietary software on purpose.

This is a deliberate position. PuralvOS enables `multiverse` and `restricted`
because everything that works is the requirement: NVIDIA drivers, Intel and
Broadcom WiFi firmware, unfree codecs. A media workstation that refuses to
drive the graphics card in the machine is not a workstation.

The cost is that PuralvOS cannot claim to be free software. `tools/manifest.py`
exists so that stays a tracked decision rather than a surprise.

## Images

Both are built from the same curated filesystem, so the thing you try live is
the thing you get installed.

| build | boots to | installs to disk | how |
| --- | --- | --- | --- |
| **PuralvOS Graphics Live** (default) | full workstation, live | no | `tools/build-live.sh` |
| **PuralvOS Graphics** (installable) | full workstation, live | yes, via the stock Ubuntu installer | `PURALVOS_INSTALLER=1 tools/build-live.sh` |

The default is the Live image because that is the one that is measured and
used: it masks snapd, one of the two largest boot costs on the stock ISO (the
other is `ldconfig`), and it is already excluded by
[`excludes.list`](excludes.list). The cost is the snap-based installer;
`PURALVOS_INSTALLER=1` builds the other variant with snapd kept.

The production graphics image built on 20 October 2026 reached the desktop
marker at **24.00 seconds** under KVM on this build host. The verification
build reached it at **23.98 seconds**. That is the unthrottled measurement; a
throttled USB-stick measurement has not been taken for this branch yet. The
audio branch's boot-time work and the measurement method are in
[docs/PERFORMANCE.md](docs/PERFORMANCE.md).

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
tools/build-live.sh        build the live image (or the installable one)
scripts/kvmboottime.sh     measure boot-to-desktop, with the ISO throttled
tools/puralvos-selftest    verify a booted image from the inside
tools/puralvos-selftest.service  the unit that runs it at boot, opt-in
tools/puralvos-rt-fix      the in-image real time audio fix
tools/graphics-trim/       package removal lists for this branch
tools/lib/desktop-exec.sh  read the executable out of a .desktop file
tools/test-desktop-exec    prove it reads the real entries correctly
tools/kernel-select.py     find the real time kernel by asking apt
tools/upgrade-curated.sh   upgrade our packages, leave yours alone
scripts/kvmtest.sh         boot an image headlessly, capture serial + screenshots
scripts/qmp-key.py         send keys to a running guest
docs/ARCHITECTURE.md       how the images are built
docs/GRAPHICS.md           this branch: package decisions, build and test record
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

Building an image needs about 45 GB free. On this build host a from-scratch
build takes roughly six minutes:

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

This one caught us out. On Ubuntu 26.10:

```
linux-lowlatency   Depends: linux-image-generic     ← the GENERIC kernel
linux-realtime     Depends: linux-image-realtime    ← a real PREEMPT_RT build
```

`linux-lowlatency` is the generic kernel with low-latency boot arguments. It
still preempts cooperatively and will still glitch. And the same name means
different things per release, so a hardcoded name would have been right on one
base and silently wrong on another.

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

The image builds, boots, and reaches a usable Plasma desktop with the graphics
stack pinned to the panel. The live session autologins as `puralvos` and an
ordinary `puralv` account exists for a console or ssh login.

Build of 20 October 2026:

| | |
| --- | --- |
| ISO | `out/puralvos-graphics-20261020-0642.iso`, 6.57 GB |
| SHA-256 | `e700c3369f4ce07a0f4b3f1940021afd80db321e267d2eb9e9a82000188abc8c` |
| Installed packages | 2378 |
| Desktop marker | 24.00 s under KVM |
| `dpkg --audit` | clean |
| Kernel | 7.3.0-9-realtime, PREEMPT_RT |
| Top layer | 661 MB |
| Squashfs | 302 MB |

The verification build is
`/tmp/opencode/selftest-out/puralvos-graphics-20261020-0708.iso`, SHA-256
`e92509199d40957797651ef5e671725081cb6577b2277b58a1755f8d979463f2`.
Its in-guest self test reports **86 pass, 3 fail, 1 slow, 27 skip** in 135 s.
Every curated graphics launch passes: GIMP, Inkscape, Krita, Blender, MyPaint,
Pencil2D, PikoPixel, Skanpage, Synfig Studio and KColorChooser. The three
failures are system utilities, not graphics applications:

- `menu:Keyboard layout viewer` — `double free or corruption`, the same base
  utility crash seen on the video branch;
- `menu:cpupower-gui` — exits asking for a `gapplication` subcommand; QEMU has
  no cpufreq driver to manage;
- `menu:Additional Drivers` — polkit cannot open a controlling terminal in the
  headless session.

The first graphics self-test run reported 16 failures because the harness ran
the desktop applications through Wayland while using an X11-only window probe.
Forcing `GDK_BACKEND=x11`, `QT_QPA_PLATFORM=xcb` and clearing
`WAYLAND_DISPLAY` for the launch tests made GIMP, Inkscape, Blender, MyPaint and
Synfig visible and passing. The window timeout is now 120 s. The full record,
including the dependency collisions and the PikoPixel launcher fix, is in
[docs/GRAPHICS.md](docs/GRAPHICS.md).

Not yet done:

- graphics verification on real hardware with a real GPU and a real scanner.
  Every runtime check so far was made under QEMU with no GPU and no scanner
- a licence — **still the first thing to do.** Everything in this repository is
  currently all rights reserved by default, and `tools/make-brand.py` has code
  in it.
- the non-free manifest tool, so that shipping proprietary software stays a
  tracked decision (`tools/manifest.py`)
- the installer path. The default build is the Live image (snapd masked);
  `PURALVOS_INSTALLER=1` keeps snapd and the stock snap installer.
- the icon theme, the Plasma theme and the app menu XML. `ubuntustudio-look`,
  `ubuntustudio-icon-theme` and `ubuntustudio-menu` are still installed and
  still Ubuntu Studio's, which makes the icon theme the largest remaining
  branding gap. See [docs/BRANDING.md](docs/BRANDING.md).
- the audio-only 90-second boot-gap investigation, which is tracked on the
  audio branch and is not changed by this branch.
- the full merged image and the audio/full build-script rename from the old
  `puralvos-live` slug to `puralvos-full` and `puralvos-audio`.

See [docs/WORK-REPORT.md](docs/WORK-REPORT.md) for the longer history and
[docs/GRAPHICS.md](docs/GRAPHICS.md) for this branch's decisions.
