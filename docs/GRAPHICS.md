# PuralvOS Graphics

**Branch:** `graphics-only`
**Base branch:** `video-only` at `aa310ca`
**Built:** 20 October 2026
**Product:** PuralvOS Graphics, Ubuntu Studio 26.10, real time kernel

This document is the record of the graphics-only branch: what it installs,
what it removes, why some removal lists are disabled, what went wrong during
the first builds, and what the booted image actually did. The video branch's
record is in [VIDEO.md](VIDEO.md); the audio branch's earlier history remains
in [WORK-REPORT.md](WORK-REPORT.md).

## 1. The product

The task set is [`tasks.list`](../tasks.list):

```
ubuntustudio-graphics
ubuntustudio-lowlatency-settings
ubuntustudio-performance-tweaks
ubuntustudio-default-settings
ubuntustudio-menu
ubuntustudio-pipewire-config
linux-realtime
```

`linux-realtime` is resolved to `linux-image-realtime` by the package
declaration, so the image carries the PREEMPT_RT kernel and not the generic
kernel with low-latency boot flags.

The graphics applications come from `ubuntustudio-graphics`:

| role | applications |
| --- | --- |
| raster painting and editing | GIMP, Krita, MyPaint |
| vector illustration | Inkscape |
| 3D modelling and animation | Blender |
| 2D animation | Pencil2D, Synfig Studio |
| pixel art | PikoPixel |
| scanning | Skanpage |
| colour | KColorChooser |
| resources | `create-resources`, `openclipart-svg` |
| tablet input | `xserver-xorg-input-wacom` |

The audio runtime is kept even though the audio applications are not:
PipeWire, WirePlumber, `pipewire-jack` and the JACK compatibility library are
used for preview audio and desktop integration. ImageMagick and FFmpeg stay
because the graphics stack needs them:

- GIMP links `libgs10` and `libpoppler-glib8t64`;
- Inkscape links `libpoppler-glib8t64` and `libpoppler162`;
- Krita links `libpoppler-qt6-3t64`, `libmlt7` and `libmlt++7`;
- Synfig Studio links `libmlt++7`;
- Krita, Pencil2D and ImageMagick depend on the `ffmpeg` package.

## 2. How the image is made

The build does not start from an empty debootstrap. It uses the stock Ubuntu
Studio ISO's package set and removes what the product does not need:

1. unpack the base layers into a read-only union;
2. copy the union into the writable layer;
3. apply the package and branding changes;
4. purge the names in `tools/graphics-trim/*.list` in numeric order;
5. mark the graphics applications and their runtime libraries manual before
   the purge, so a later autoremove cannot reinterpret them as orphans;
6. replace the generic kernel with `linux-realtime`;
7. repack only the files that differ from the read-only union, including
   whiteouts for removed paths;
8. write the ISO with the PuralvOS Graphics menu, os-release, issue, panel and
   volume label.

The package declaration in
[`base/puralvos/selftest-packages.txt`](../base/puralvos/selftest-packages.txt)
is generated from `tasks.list` and is checked by the in-guest self test.

### Why the trim is verified with apt, not with a package list

A package list says what someone intended to remove. It does not say what the
archive's dependency solver will remove as collateral. Every trim batch was
therefore replayed against the unpacked base with:

```sh
apt-get -s purge -y --auto-remove <names in the batch>
```

and the protected product packages were checked after each batch. This branch
found two collisions that the video branch did not have: the documents batch
and the GNUstep batch. Both are described below.

## 3. Trim lists and the disabled batches

The active lists are under [`tools/graphics-trim`](../tools/graphics-trim):

| list | purpose |
| --- | --- |
| `01-leaks.list` | input methods, printing, snap store, stock desktop leaks |
| `02-audio.list` | DAWs, synths, guitar rigs, audio utilities |
| `02-video-optical.list` | video editors, capture, players and disc tools |
| `04-libreoffice.list` | LibreOffice |
| `05-documents.list` | Okular and standalone document tools, shared libraries kept |
| `06-services.list` | OpenLP, accessibility, cloud-init, FTP clients |
| `08-tex.list` | TeX |
| `09-toolchain.list` | tracing and kernel tools for the replaced generic kernel |

`02-audio.list` replaces the video branch's `02-video-optical.list`; the
numbering is retained because the purge order is part of the audit. It removes
audio applications but deliberately keeps `libjack-jackd2-0`, PipeWire and
`osspd`.

`02-video-optical.list` removes Kdenlive, OBS Studio, VLC, Subtitle Editor,
QPrompt, Xjadeo, DevedeNG, K3b, `melt`, MPlayer and their leaf libraries. It
does **not** remove `libmlt7`, `libmlt++7`, `libmlt-data` or `ffmpeg`:
Krita and Synfig link MLT, and Krita, Pencil2D and ImageMagick depend on
FFmpeg.

### `03-graphics.list.disabled`

This is the product bundle, not a trim. It is retained as `.list.disabled` so
the batch numbering stays legible and so nobody re-applies the video branch's
graphics removal to the graphics product.

### `05-documents.list`: reduced, not removed

The first graphics build applied the video branch's full documents batch. It
removed GIMP, Inkscape and Krita as collateral:

```
gimp      -> libpoppler-glib8t64
inkscape  -> libpoppler-glib8t64, libpoppler162
krita     -> libpoppler-qt6-3t64
```

The batch also removed `gsfonts-other`, which GIMP uses for PostScript
output. The revised list removes Okular and the standalone document tools but
keeps the shared poppler libraries, Ghostscript and the font package. The
resulting batch removes 51 packages and leaves the image editors installed.
Skanpage is covered separately by the disabled online-accounts batch below.

### `07-online-accounts.list.disabled`

Removing the online-accounts stack removes Skanpage. The dependency path is:

```
skanpage
  -> qml6-module-org-kde-purpose
  -> libkaccounts6-2
```

The video branch disabled this batch because it removes Kdenlive. The graphics
branch reaches the same decision through Skanpage and leaves the batch
disabled.

### `10-gnustep.list.disabled`

The graphics product ships PikoPixel, which is a GNUstep application. The
GNUstep batch removes `pikopixel.app` and its runtime, so the batch is disabled
and retained as a record.

### `11-geo.list.disabled`

Removing GDAL removes Blender. The dependency path is:

```
blender
  -> libopenimageio2.5
  -> libopencv-imgcodecs410
  -> libgdal39
```

The geospatial libraries look like obvious cruft on a graphics machine, but
GDAL is load-bearing through OpenImageIO and OpenCV. The list is disabled
rather than edited to remove only the leaf packages, because the whole chain is
present for Blender's image I/O.

### `12-ml-video.list.disabled`

Removing the OpenCV/ONNX/TensorFlow runtime breaks Krita and MLT:

```
krita -> libmlt7 -> libopencv-contrib410, libopencv-core410,
                    libopencv-imgproc410, libopencv-video410

libmlt7 -> libopencv-contrib410 and friends
```

The list is disabled in full. The audio branch's version of this batch removed
Embree, Imath, OpenColorIO, OpenEXR, OpenImageIO, OpenVDB and OpenXR as well;
those are direct Blender dependencies and are explicitly excluded from the
graphics-protected set.

## 4. Package versions in the built image

Measured from the built layer's dpkg database:

```
blender              5.0.1+dfsg-5
ffmpeg               7:8.1.2-2ubuntu2
gimp                 3.2.6-1
inkscape             1.4.3-2
kcolorchooser        4:26.08.1-0ubuntu1
krita                1:6.0.3+dfsg-1build1
libgdal39            3.13.3+dfsg-1ubuntu4
libmlt++7            7.40.0-1
libmlt7              7.40.0-1
libopenimageio2.5    2.5.19.1+dfsg-2build2
linux-image-realtime 7.3.0-9.9.1
mypaint              2.0.1-15
pencil2d             0.7.2-1
pikopixel.app        1.0-b10c-1
skanpage             26.08.1-0ubuntu1
synfigstudio         1.5.5-2
```

The removed bundles are absent:

```
ubuntustudio-audio
ubuntustudio-video
ubuntustudio-photography
kdenlive
obs-studio
vlc
darktable
```

The built image carries 2378 installed packages. `dpkg --audit` is clean.
`dpkg-query -W` counts 2379 because `dracut` remains in the config-files
state after the kernel trim; the self test reports that number. Only 2378 are
actually installed.

## 5. Branding and desktop

The build writes:

- `NAME="PuralvOS Graphics"` and
  `PRETTY_NAME="PuralvOS Graphics 26.10"` in `/etc/os-release` and
  `/usr/lib/os-release`;
- `DISTRIB_NAME`/`DISTRIB_DESCRIPTION` in `/etc/lsb-release`;
- the issue text and the GRUB menu entries as **PuralvOS Graphics Live**;
- the ISO file name as `puralvos-graphics-<stamp>.iso` and the volume label as
  `PURALVOS_GRAPHICS`;
- the live user remains `puralvos`, because `.disk/info` still starts with
  `PuralvOS` and the stock installer parses that line's shape;
- the panel slots are mapped to GIMP, Krita, Inkscape, Blender, MyPaint,
  Synfig Studio, Skanpage and KColorChooser; Pencil2D and PikoPixel remain in
  the application menu. Both layout templates use the same mapping.

The panel mapping is deliberately one-for-one with the stock Ubuntu Studio
launchers:

| stock slot | graphics slot |
| --- | --- |
| Patchance | GIMP |
| Ardour | Krita |
| OBS Studio | Blender |
| Krita | Inkscape |
| GIMP | MyPaint |
| Kdenlive | Synfig Studio |
| digiKam | KColorChooser |
| darktable | Skanpage |
| RaySession (favourites) | Blender |
| Carla (favourites) | GIMP |

### PikoPixel desktop entry

PikoPixel's desktop entry launches through `openapp(1)`:

```
Exec=/usr/bin/openapp PikoPixel %F
```

`openapp` needs `dpkg-architecture`, which the `09-toolchain` batch removes.
The binary is installed and works, but the menu entry dies with:

```
Can't find the required application: PikoPixel.app!
usage: openapp [--find] [--debug] application [arguments...]
```

The build now points the entry at `/usr/bin/PikoPixel` before
`fix_desktop_entries` runs. The verification build reports
`pikopixel window after 0s` and skips the duplicate menu entry as covered by
the curated launch test.

### Self-test launch environment

The first graphics self-test reported GIMP, Inkscape, Blender, MyPaint and
Synfig as window-probe timeouts. The screenshots from the same run showed the
applications open. The cause was the probe, not the applications: the session
is KWin Wayland, the applications chose Wayland surfaces, and the self test
looked for new windows with `xwininfo`, which only sees X11/XWayland clients.

The self test now forces the launch tests onto X11:

```
WAYLAND_DISPLAY=
GDK_BACKEND=x11
QT_QPA_PLATFORM=xcb
```

The window timeout is 120 s, and the curated applications are skipped in the
menu sweep so they are not tested twice. This is what changed the second
graphics verification run from 10 failures to 3:

```
gimp window after 0s
inkscape window after 0s
krita window after 0s
blender window after 6s
mypaint window after 0s
pencil2d window after 0s
pikopixel window after 0s
skanpage window after 0s
synfig window after 0s
kcolorchooser window after 0s
```

## 6. Build result

Production build:

| | |
| --- | --- |
| Command | `PURALVOS_RESUME=0 tools/build-live.sh --keep` |
| Log | `/tmp/opencode/build-graphics-20261020-0636.log` |
| ISO | `out/puralvos-graphics-20261020-0642.iso` |
| Size | 6.57 GB |
| SHA-256 | `e700c3369f4ce07a0f4b3f1940021afd80db321e267d2eb9e9a82000188abc8c` |
| Installed packages | 2378 |
| Top layer | 661 MB |
| Squashfs | 302 MB |
| Kernel | 7.3.0-9-realtime, PREEMPT_RT |
| `dpkg --audit` | clean |

The would-be first production build (`out/puralvos-graphics-20261020-0556.iso`)
is not a release candidate: it was built before the documents and GNUstep
fixes, and it is missing GIMP, Inkscape, Krita, Skanpage and PikoPixel. Its log
is retained at `/tmp/opencode/build-graphics-20261020-0551.log` as the record
of the failure.

The trimmed package count by batch in the final build:

```
01-leaks.list               572 removed
02-audio.list               235 removed
02-video-optical.list        25 removed
04-libreoffice.list          98 removed
05-documents.list            51 removed
06-services.list             54 removed
08-tex.list                  19 removed
09-toolchain.list            18 removed
trim: 1072 packages removed
```

Layer checks:

```
ubuntustudio-graphics      26.10.8   installed
ubuntustudio-audio                  absent
ubuntustudio-video                  absent
ubuntustudio-photography            absent
gimp, inkscape, krita, blender, mypaint, pencil2d,
pikopixel.app, skanpage, synfigstudio, kcolorchooser,
libmlt7, libmlt++7, ffmpeg, libopenimageio2.5, libgdal39   installed
dpkg --audit             clean
```

Final boot:

```
./scripts/kvmtest.sh out/puralvos-graphics-20261020-0642.iso \
    puralvos-graphics-final 300 30
PURALVOS_DESKTOP_READY 24.00
```

The verification build:

| | |
| --- | --- |
| Command | `PURALVOS_RESUME=0 PURALVOS_SELFTEST=1 PURALVOS_OUT=/tmp/opencode/selftest-out tools/build-live.sh --keep` |
| Log | `/tmp/opencode/build-graphics-selftest-20261020-0703.log` |
| ISO | `/tmp/opencode/selftest-out/puralvos-graphics-20261020-0708.iso` |
| SHA-256 | `e92509199d40957797651ef5e671725081cb6577b2277b58a1755f8d979463f2` |
| Boot log | `/tmp/opencode/kvmrun/puralvos-graphics-selftest3/serial.log` |
| Desktop marker | `PURALVOS_DESKTOP_READY 23.98` |

## 7. Self-test result

The third verification run, with the X11 launch environment and the corrected
PikoPixel entry:

```
INFO pass=86 fail=3 slow=1 skip=27
INFO elapsed=135s
########## PURALVOS SELFTEST END ok=87 bad=3 ##########
```

Tier 0, tier 2 and tier 3 all passed, including:

```
RESULT tier0 PASS desktop-started X server up on :0 at 23.85s
RESULT tier2 PASS kernel-is-realtime #9.1-Ubuntu SMP PREEMPT_RT
RESULT tier3 PASS os-release-name PuralvOS Graphics
RESULT tier3 PASS iso-label PuralvOS 26.10 "Stonking Stingray" - Release amd64 (20261020)
```

The three remaining failures are not graphics applications:

| result | cause |
| --- | --- |
| `menu:Keyboard layout viewer` | `double free or corruption (out)`; the stock utility crashes under `setpriv`, as it also does on the video branch |
| `menu:cpupower-gui` | exits with `Use "gapplication help COMMAND"`; QEMU has no cpufreq driver |
| `menu:Additional Drivers` | polkit cannot open a controlling terminal: `/dev/tty: No such device or address` |

The 27 skips are the expected non-launchable entries (System Settings,
Discover, Help, Spectacle, Firefox, ImageMagick colour-depth entries), the
curated applications covered by tier 4, and the real-time checks that need
hardware: `cpu-governor`, `swappiness`, `isolcpus`, `nohz_full`, `threadirqs`
and `jack-xruns`. `udev-audio-rules` is SLOW for the same reason as the video
branch: the base has no audio udev rule, so USB audio autosuspend is not
configured. That is inherited, not introduced here.

## 8. What this branch did not solve

- No real GPU, tablet or scanner was available. Every launch check was made
  in QEMU with llvmpipe/Zink; the self test now forces X11 so the window probe
  works, but that is not a substitute for hardware testing.
- The stock icon/Plasma/menu packages are still Ubuntu Studio's. The
  `puralvos` icon theme inherits Papirus and warns
  `Theme directory places/scalable of theme puralvos has no size field`; it
  does not stop Inkscape when the test forces X11, but it is a branding gap.
- The audio branch's 90 s boot-gap investigation is unchanged.
- The audio-only and full branches still write `puralvos-live-<stamp>.iso`.
  Their existing files were renamed to the family convention, but their build
  slugs were not changed in this branch.
- The full merged image was not rebuilt or re-verified on this branch.

## 9. Reproducing the checks

```sh
make check
PURALVOS_RESUME=0 tools/build-live.sh --keep
./scripts/kvmtest.sh out/puralvos-graphics-<stamp>.iso \
    puralvos-graphics-final 300 30

PURALVOS_RESUME=0 PURALVOS_SELFTEST=1 \
    PURALVOS_OUT=/tmp/opencode/selftest-out \
    tools/build-live.sh --keep
./scripts/kvmtest.sh /tmp/opencode/selftest-out/puralvos-graphics-<stamp>.iso \
    puralvos-graphics-selftest 900 60
```

The build needs about 45 GB free. The verification boot needs the 900 s limit:
the final run takes 135 s of self-test time after the desktop appears, but the
outer KVM harness also waits for the login prompt and the shutdown.
