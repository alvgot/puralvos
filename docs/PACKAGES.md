# What PuralvOS carries

Measured from `/var/tmp/puralvos-build/layer`, not from a list somebody wrote down.

## Totals

| | |
| --- | --- |
| Installed packages | **3360** |
| Removal candidates | **69** (2.1%) |
| Would remain | **3291** |

## Where the weight is

The largest families, by package-name prefix:

| prefix | count |
| --- | --- |
| `python3` | 230 |
| `pd` | 86 |
| `fonts` | 72 |
| `qml6` | 69 |
| `linux` | 34 |
| `gir1.2` | 32 |
| `plasma` | 29 |
| `libxcb` | 26 |
| `fcitx` | 21 |
| `libreoffice` | 20 |
| `qml` | 19 |
| `ubuntustudio` | 19 |
| `kde` | 16 |
| `vlc` | 14 |
| `cups` | 13 |

## Removal candidates

Nothing here is applied automatically. Each group has a reason and a
decision attached to it; the decision is recorded in `excludes.list`.

### office — 21 packages

The whole office suite. 20 packages. PuralvOS is audio, video and graphics; this is a word processor and a spreadsheet.

`libreoffice-base-core`, `libreoffice-calc`, `libreoffice-common`, `libreoffice-core`, `libreoffice-draw`, `libreoffice-impress`, `libreoffice-kf6`, `libreoffice-math`, `libreoffice-plasma`, `libreoffice-qt6`, `libreoffice-style-breeze`, `libreoffice-style-colibre`, ... (9 more)

### input method — 21 packages

28 packages of Chinese/Japanese/Korean input method. Nobody has asked for CJK text entry on a two-person English-language workstation. Remove unless one of you types Japanese.

`fcitx`, `fcitx-bin`, `fcitx-data`, `fcitx-frontend-all`, `fcitx-frontend-fbterm`, `fcitx-frontend-gtk2`, `fcitx-frontend-gtk3`, `fcitx-frontend-qt5`, `fcitx-frontend-qt6`, `fcitx-googlepinyin`, `fcitx-module-cloudpinyin`, `fcitx-module-dbus`, ... (9 more)

### printing — 16 packages

21 packages of printer support, including HP drivers. A workstation in a room is not a print server.

`bluez-cups`, `cups`, `cups-browsed`, `cups-bsd`, `cups-client`, `cups-common`, `cups-core-drivers`, `cups-daemon`, `cups-filters`, `cups-filters-core-drivers`, `cups-ipp-utils`, `cups-pk-helper`, ... (4 more)

### snap — 3 packages

Snapd and its libraries. Snaps add a second package manager with its own update schedule, which is exactly the thing the curated upgrade path exists to avoid.

`libsnapd-glib-2-1`, `libsnapd-qt-2-1`, `snapd`

### package manager — 1 packages

A GTK front end for apt. apt is the package manager and it stays.

`synaptic`

### photography — 1 packages

Photography. Not in the product: audio, video, graphics.

`darktable`

### mDNS — 0 packages

7 packages of Zeroconf/mDNS service discovery. Useful for a network workstation with shared speakers, useless otherwise.



### web — 1 packages

A general web browser on a machine that already has one job. Ardour and VLC will open URLs without it.

`firefox`

### evolution — 1 packages

Contacts and calendar backend with nothing in front of it.

`evolution-data-server-common`

### CJK fonts — 1 packages

CJK font set, tens of megabytes, for text nobody will type.

`fonts-noto-cjk`

### modem — 1 packages

Dial-up modem support. There is no modem.

`ppp`

### usb modeswitch — 2 packages

Flips USB devices between modes on first boot. Useful for some 3G dongles, noise otherwise.

`usb-modeswitch`, `usb-modeswitch-data`

## Do not remove these

They look exactly like the cruft above and they are not.

| package | why |
| --- | --- |
| `avahi-daemon` | may be wanted for network audio discovery; decide once, not by accident. |
| `jackd2` | JACK, for real time audio clients that do not use PipeWire. |
| `libbluetooth-dev` | development headers for the above. |
| `libbluetooth3` | PipeWire's Bluetooth audio. See above. |
| `libqt6bluetooth6` | Qt Bluetooth, used by the audio stack's pairing UI. |
| `libspa-0.2-bluetooth` | PipeWire's Bluetooth audio. Removing this takes wireless headphones with it. |
| `linux-firmware-nvidia-graphics` | proprietary graphics firmware. PuralvOS ships proprietary software on purpose and this is the graphics card. |
| `pipewire` | the audio server. This is the product. |
| `python3-dbus` | everything on the desktop talks over D-Bus. |
| `wireplumber` | PipeWire's session manager. Without it nothing routes. |

Anything marked *NOT INSTALLED* is worth a look: either the image is
wrong, or the protection is obsolete.

## Is the product actually there

Checked directly against the built filesystem. A miss here is a
build failure, not a trimming opportunity.

| audio | 11/11 present | |
| video | 8/13 present | missing: `shotcut`, `olive-editor`, `openshot-qt`, `pitivi`, `handbrake` |
| graphics | 5/8 present | missing: `scribus`, `freecad`, `openscad` |
| realtime | 3/4 present | missing: `libasound2-plugins` |

`linux-realtime` is in the realtime row on purpose. The stock Ubuntu
Studio ISO carries only `linux-generic`, so its presence here is
this build's single most important difference from the base.

## How to regenerate

```sh
python3 tools/report-packages.py                     # markdown, to stdout
python3 tools/report-packages.py --list-only          # bare package names
```

## The bigger finding: the base live image is not a full Studio install

Eight applications that `tasks.list` promises are simply not in the stock
Ubuntu Studio live image:

```
shotcut  olive-editor  openshot-qt  pitivi  handbrake
scribus  freecad       openscad
```

Audio is complete (Ardour, Audacity, Mixxx, JACK, qjackctl, Musescore) and the
core of video is there (Kdenlive with MLT, VLC, OBS, subtitleeditor). What is
missing is the long tail.

**This is not a trimming problem, it is a gap in the build.** The stock live
layer carries what Ubuntu Studio's *live session* ships, which is deliberately
smaller than a full desktop install. `ubuntustudio-video` and
`ubuntustudio-graphics` being installed is not the same as their contents
being present.

So the build has to install the curated task packages into the chroot
explicitly, not rely on inheriting them from the base. `tools/build-live.sh`
does not do that yet, and until it does, the live image is missing part of the
product no matter how much else is trimmed.

Worth deciding: does the live image need the full application set at all, or
is a lean live image that installs the full set on first boot the better
shape? The second is smaller and is what Ubuntu Studio itself does.
