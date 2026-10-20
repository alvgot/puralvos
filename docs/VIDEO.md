# PuralvOS Video

**Branch:** `video-only`
**Base branch:** `audio-only` at `349921d`
**Built:** 20 October 2026
**Product:** PuralvOS Video, Ubuntu Studio 26.10, real time kernel

This document is the record of the video-only branch: what it installs, what
it removes, why some removal lists are disabled, and what the build and the
booted image actually did. The audio branch's history remains in
[WORK-REPORT.md](WORK-REPORT.md); this is the video branch's own record.

## 1. The product

The task set is [`tasks.list`](../tasks.list):

```
ubuntustudio-video
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

The video applications come from `ubuntustudio-video`:

| role | applications |
| --- | --- |
| editing | Kdenlive, MLT (`melt`) |
| compositing / animation | Blender |
| capture / streaming | OBS Studio |
| playback / conversion | VLC, FFmpeg, ffprobe |
| subtitles | Subtitle Editor |
| motion graphics | Synfig Studio |
| teleprompter | QPrompt |
| video/audio sync | Xjadeo |
| DVD authoring | DevedeNG, K3b |

The audio runtime is kept even though the audio applications are not:
PipeWire, WirePlumber, `pipewire-jack` and the JACK compatibility library are
required by Kdenlive, OBS, VLC and the video applications' audio monitoring.

## 2. How the image is made

The build does not start from an empty debootstrap. It uses the stock Ubuntu
Studio ISO's package set and removes what the product does not need:

1. unpack the base layers into a read-only union;
2. copy the union into the writable layer;
3. apply the package and branding changes;
4. purge the names in `tools/video-trim/*.list` in numeric order;
5. re-add the product anchors that a purge would have taken as a dependency;
6. replace the generic kernel with `linux-realtime`;
7. repack only the files that differ from the read-only union, including
   whiteouts for removed paths;
8. write the ISO with the PuralvOS Video menu, os-release, issue, panel and
   volume label.

The package declaration in [`base/puralvos/selftest-packages.txt`](../base/puralvos/selftest-packages.txt)
is generated from `tasks.list` and is checked by the in-guest self test.

### Why the trim is verified with apt, not with a package list

A package list says what someone intended to remove. It does not say what the
archive's dependency solver will remove as collateral. Every trim batch was
therefore replayed against the unpacked base with:

```sh
apt-get -s purge -y --auto-remove <names in the batch>
```

and the protected product packages were checked after each batch. The
simulation found three lists that could not be applied on this branch.

## 3. Trim lists and the three disabled batches

The active lists are under [`tools/video-trim`](../tools/video-trim):

| list | purpose |
| --- | --- |
| `01-leaks.list` | input methods, printing, snap store, stock desktop leaks |
| `02-audio.list` | DAWs, synths, guitar rigs, audio utilities |
| `03-graphics.list` | GIMP, Krita, Inkscape, digiKam, Hugin, MyPaint |
| `04-libreoffice.list` | LibreOffice |
| `05-documents.list` | Okular, poppler, mupdf, ghostscript |
| `06-services.list` | OpenLP, accessibility, cloud-init, FTP clients |
| `08-tex.list` | TeX |
| `09-toolchain.list` | tracing and kernel tools for the replaced generic kernel |
| `10-gnustep.list` | GNUstep, already removed as collateral |

`02-audio.list` replaces the audio branch's `02-video-optical.list`. The
numbering is retained because the purge order is part of the audit. The list
removes audio applications but deliberately keeps `libjack-jackd2-0`,
PipeWire and `osspd`; a video editor still needs an audio path.

`03-graphics.list` deliberately keeps ImageMagick: Devede and Synfig depend on
it at runtime, even though the graphics applications around it are removed.

### `07-online-accounts.list.disabled`

Removing the online-accounts stack removes Kdenlive. The dependency path is:

```
kdenlive
  -> libkf6purpose-bin
  -> libkaccounts6-2
```

`libkaccounts6-2` is supplied by the online-accounts packages. On a video
workstation, Kdenlive wins: the list stays in the repository as
`.list.disabled` so the next person can see why it is not applied.

### `11-geo.list.disabled`

Removing GDAL removes Blender. The dependency path is:

```
blender
  -> libopenimageio2.5
  -> libopencv-imgcodecs410
  -> libgdal39
```

The geospatial libraries look like obvious cruft on a video machine, but GDAL
is load-bearing through OpenImageIO and OpenCV. The list is disabled rather
than edited to remove only the leaf packages, because the whole chain is
present for Blender's image I/O.

### `12-ml-video.list.disabled`

Removing the OpenCV/ONNX/TensorFlow runtime breaks MLT and Kdenlive:

```
libmlt7 -> libopencv-contrib410, libopencv-core410,
           libopencv-imgproc410, libopencv-video410

kdenlive -> gstreamer1.0-plugins-bad
  -> libonnxruntime1.23
  -> libtensorflow-lite2.14.1
  -> libopenni2-0
```

The list also contains OpenCV packages that MLT needs directly. It is disabled
in full. The audio branch's version of this batch removed Embree, Imath,
OpenColorIO, OpenEXR, OpenImageIO, OpenVDB and OpenXR as well; those are direct
Blender dependencies and are explicitly excluded from the video version.

## 4. Branding and desktop

The build now writes:

- `NAME="PuralvOS Video"` and `PRETTY_NAME="PuralvOS Video 26.10"` in
  `/etc/os-release` and `/usr/lib/os-release`;
- `DISTRIB_NAME`/`DISTRIB_DESCRIPTION` in `/etc/lsb-release`;
- the issue text and the GRUB menu entries as **PuralvOS Video Live**;
- the ISO file name as `puralvos-video-<stamp>.iso` and the volume label as
  `PURALVOS_VIDEO`;
- the live user remains `puralvos`, because `.disk/info` still starts with
  `PuralvOS` and the stock installer parses that line's shape;
- the panel pins and both layout templates use the video stack: Blender, VLC,
  OBS Studio, Subtitle Editor, Synfig Studio, Kdenlive, Xjadeo and K3b.

The TONE3000 NAM player that belonged to the audio branch was removed from
`tools/build-live.sh`; no TONE3000 files were found in the built layer.

### DevedeNG desktop entry

The first video build exposed a packaging bug: Devede's desktop entry has
`TryExec=/usr/bin/devede` and `Exec=/usr/bin/devede`, while the package installs
`/usr/bin/devede_ng`. The hygiene pass correctly hid the entry as a dead
launcher. The build now corrects both fields to `/usr/bin/devede_ng` before
`fix_desktop_entries` runs. The verification build reports
`menu:DevedeNG PASS`.

### Self test unit

The self-test unit used to be disabled unconditionally, so
`PURALVOS_SELFTEST=1` added the kernel argument but no service ever read it.
The build now enables the unit only for a verification build and keeps it
disabled for production. This is what made the 20 October verification run
possible.

## 5. Build result

Production build:

| | |
| --- | --- |
| Command | `PURALVOS_RESUME=0 tools/build-live.sh --keep` |
| Log | `/tmp/opencode/build-video-20261020-0234.log` |
| ISO | `out/puralvos-video-20261020-0239.iso` |
| Size | 6.57 GB |
| SHA-256 | `a3d1f76b466a864f031eddf2dd07639802af7e509c7d09da1be61e217c68a219` |
| Installed packages | 2377 (dpkg status; the self test's query sees 2378) |
| Top layer | 661 MB |
| Squashfs | 302 MB |
| Kernel | 7.3.0-9-realtime, PREEMPT_RT |

Layer checks:

```
ubuntustudio-video        26.10.8   installed
ubuntustudio-audio                  absent
ubuntustudio-graphics               absent
kdenlive, blender, obs-studio, vlc, ffmpeg, subtitleeditor,
synfigstudio, qprompt, xjadeo, devede, k3b, melt, libmlt7,
libopenimageio2.5, libgdal39, libonnxruntime1.23   installed
dpkg --audit             clean
```

The built layer's `/etc/os-release` reports:

```
NAME="PuralvOS Video"
PRETTY_NAME="PuralvOS Video 26.10"
ID=puralvos
```

The live user `puralvos` is in `adm dialout cdrom sudo audio dip video plugdev`,
and there are no TONE3000 files under `/usr/lib/{vst3,lv2,clap}` or `/usr/bin`.

## 6. Boot verification

The production ISO was booted headlessly with `scripts/kvmtest.sh`:

```sh
./scripts/kvmtest.sh out/puralvos-video-20261020-0239.iso puralvos-video-final 300 30
```

Results:

| check | result |
| --- | --- |
| GRUB menu | `PuralvOS Video Live — try out`, safe graphics entry present |
| Desktop marker | `PURALVOS_DESKTOP_READY 22.69` |
| Boot report | complete; no failed units, no serial probe failure |
| systemd | kernel 9.662 s + userspace 2.952 s = 12.615 s to graphical target |
| Screenshot | desktop with the video panel and PuralvOS wallpaper |

Logs and artifacts:

- `/tmp/opencode/kvm-video-final.log`
- `/tmp/opencode/kvmrun/puralvos-video-final/serial.log`
- `/tmp/opencode/kvmrun/puralvos-video-final/final.png`

The boot report's own summary:

```
serial failed
(empty)
```

The only build-time warning is the known initrd microcode warning, which the
build explains: the stock initrd is dropped so the realtime initrd is used, and
microcode loads late instead of early. It is not a video-branch regression.

## 7. In-guest self test

The production ISO keeps the self test disabled. A separate verification ISO
was built with the unit enabled:

```sh
PURALVOS_RESUME=0 PURALVOS_SELFTEST=1 \
  PURALVOS_OUT=/tmp/opencode/selftest-out tools/build-live.sh --keep

./scripts/kvmtest.sh \
  /tmp/opencode/selftest-out/puralvos-video-20261020-0252.iso \
  puralvos-video-selftest 900 60
```

Verification ISO SHA-256:
`6f1abe80fa9e8f0ebf05b4e50b37caffb2c179168cf9421766c9596e22d812fe`.

Summary:

```
pass=87 fail=13 slow=1 skip=17
elapsed=628s
```

(The final `ok=88` line includes one pass counted outside the tier totals.)

### What passed

- `dpkg` database, rootfs, writable home and network reachability;
- `kernel-is-realtime` (#9.1-Ubuntu SMP PREEMPT_RT);
- `rtprio-limit 95` and `memlock-limit unlimited` in a real login session;
- PipeWire rlimits, limits file, user in the audio group;
- `os-release-name PuralvOS Video`;
- wallpapers, Plymouth, SDDM, GRUB menus;
- 7 declared packages, 69 desktop entries;
- Kdenlive, OBS Studio, VLC, QPrompt, Xjadeo, DevedeNG (the fixed entry),
  K3b and the FFmpeg/ffprobe/display checks.

### The 13 failures

These are the failures as the self test reported them. None is a package
missing from the image.

| test | reported reason | assessment |
| --- | --- | --- |
| `blender` | no window within 60 s: Zink/Mesa failed to choose a pdev | QEMU has no GPU. The screenshot at 02:56 shows Blender's Quick Setup window; it opens after the 60 s probe. Hardware GPU test still required. |
| `subtitleeditor` | no window within 60 s: missing GSettings groups | The screenshot at 02:54 shows the Subtitle Editor window. First-run startup on this host exceeds the probe; the warnings are non-fatal. |
| `synfig` | no window within 60 s: auto-recover messages | A clean Xvfb run against the built layer opens "Synfig Studio" in under 5 s. The failure is the live QEMU/first-run timing, not the binary. |
| `menu:Report a problem...` | exited immediately | Apport's crash reporter has no crash to report; not a video application. |
| `menu:Blender` | same Zink/Mesa failure | Same as the direct Blender test. |
| `menu:Keyboard layout viewer` | double free/core dump under `setpriv` | The test's privilege wrapper, not a normal user session. |
| `menu:MPlayer-nogui` | exited immediately | The menu entry is a terminal-only player. Candidate for hiding in a later pass; it is not a video product launcher. |
| `menu:Subtitle Editor` | no window within 60 s | Same as the direct test; the app opened visually. |
| `menu:cpupower-gui` | exited immediately | `gapplication` exits when invoked without the arguments the desktop entry supplies. |
| `menu:Synfig Studio` | no window within 60 s | Same as the direct Synfig test. |
| `menu:Additional Drivers` | polkit cannot open a controlling tty | QEMU serial has no tty for the authentication agent. |
| `menu:Reset Applications Overview` | Zink/Mesa pdev failure | QEMU GPU limitation. |
| `menu:ALSA Scarlett Control Panel` | Zink/Mesa pdev failure | QEMU GPU limitation. |

The one `SLOW` is `udev-audio-rules`: there is no audio udev rule, so USB
autosuspend can still glitch an interface. That is the audio branch's open
item, not a video-package regression.

The failures are recorded rather than hidden. A future revision should either
raise the window probe for first-run applications or mark the GPU/polkit tests
as environment-dependent. The important product evidence is that Kdenlive,
OBS, VLC, DevedeNG, K3b, FFmpeg, QPrompt and Xjadeo pass, and that Blender and
Subtitle Editor were seen running in the same boot.

## 8. Known limitations

- No real GPU, capture card or video hardware has been tested. QEMU's Zink
  failures are evidence about the VM, not about the installed system.
- No throttled USB-stick boot measurement exists for this branch. The 22.69 s
  marker is KVM with an unthrottled ISO.
- The self test's 60 s window probe is too short for first-run Blender,
  Subtitle Editor and Synfig on this host.
- The audio branch's 90 s boot-gap investigation is unchanged by this branch.
- The graphics-only branch has not been started yet.
- The installer path and the licence remain open as described in the README.

## 9. Reproduce

```sh
# package declaration from tasks.list
python3 tools/make-package-declaration.py \
  -o base/puralvos/selftest-packages.txt

# production image
PURALVOS_RESUME=0 tools/build-live.sh --keep

# boot it and inspect
./scripts/kvmtest.sh out/puralvos-video-*.iso puralvos-video 300 30
grep -a 'PURALVOS_DESKTOP_READY' \
  /tmp/opencode/kvmrun/puralvos-video/serial.log

# verification image
PURALVOS_RESUME=0 PURALVOS_SELFTEST=1 \
  PURALVOS_OUT=/tmp/opencode/selftest-out tools/build-live.sh --keep
./scripts/kvmtest.sh \
  /tmp/opencode/selftest-out/puralvos-video-*.iso \
  puralvos-video-selftest 900 60
```
