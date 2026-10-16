# What PuralvOS carries

Measured from `/var/tmp/puralvos-build/layer`, not from a list somebody wrote down.

## Totals

| | |
| --- | --- |
| Installed packages | **3360** |
| Removal candidates | **71** (2.1%) |
| Would remain | **3289** |

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

## Snap census

Snap is not a package count, it is disk. Counted off the built
rootfs rather than assumed.

| | |
| --- | --- |
| Snaps installed | **16** |
| .snap payloads | **2035 MB** |

`bare`, `core24`, `desktop-security-center`, `firefox`, `firmware-updater`, `freeshow`, `gnome-46-2404`, `gtk-common-themes`, `gtk-theme-orchis`, `icon-theme-breeze`, `mesa-2404`, `prompting-client`, `snapd`, `snapd-desktop-integration`, `thunderbird`, `ubuntu-desktop-bootstrap`

PuralvOS ships none of these. See `excludes.list`.

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

### snap — 5 packages

Snapd, its libraries, Plasma's snap backend, and the two applications that are themselves snaps. This is the largest single saving in the build and it is not a package count: the stock image carries 14 snaps and about 4 GB of /var/lib/snapd, against a whole 69-package trim that saves far less. Firefox and Thunderbird go with it, because in the archive those packages are transitional wrappers whose only job is to install the snap.

`firefox`, `libsnapd-glib-2-1`, `libsnapd-qt-2-1`, `plasma-discover-backend-snap`, `snapd`

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

## Snap is out. Not as a lean, as a rule.

Alv: "never use snap to install apps, it's really terrible." Agreed, and the
size of it is worth stating plainly:

| | |
| --- | --- |
| Snaps in the stock image | **16** |
| `/var/lib/snapd` | **4.0 GB** |
| `.snap` payloads alone | **2.0 GB** |

That is **more than the entire 69-package trim saves.** The largest single
saving available anywhere in this build is not removing software, it is
removing a second package manager.

```
bare  core24  desktop-security-center  firefox  firmware-updater  freeshow
gnome-46-2404  gtk-common-themes  gtk-theme-orchis  icon-theme-breeze
mesa-2404  prompting-client  snapd  snapd-desktop-integration
thunderbird  ubuntu-desktop-bootstrap
```

### The consequence worth deciding now

**Firefox and Thunderbird are snaps on the stock image.** Excluding snapd
removes them, and purging the `firefox` deb does not help either — in the
Ubuntu archive that package is a *transitional wrapper* whose only job is to
install the snap.

So if either is wanted, the choice is Mozilla's own apt repository (a real
repository, real signing, upstream-maintained debs) or nothing. That is not
the same trade as snap and it is worth making deliberately rather than
discovering a missing browser after burning an ISO.

Everything else in the curated set — Ardour, Kdenlive, VLC, GIMP, Inkscape,
OBS, JACK, PipeWire — is deb-based already and is unaffected.
