# What PuralvOS carries

Measured from `/var/tmp/puralvos-build/layer`, not from a list somebody wrote down.

## Totals

| | |
| --- | --- |
| Installed packages | **3360** |
| Removal candidates | **49** (1.5%) |
| Would remain | **3311** |

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

### input method — 21 packages

28 packages of Chinese/Japanese/Korean input method. Nobody has asked for CJK text entry on a two-person English-language workstation. Remove unless one of you types Japanese.

`fcitx`, `fcitx-bin`, `fcitx-data`, `fcitx-frontend-all`, `fcitx-frontend-fbterm`, `fcitx-frontend-gtk2`, `fcitx-frontend-gtk3`, `fcitx-frontend-qt5`, `fcitx-frontend-qt6`, `fcitx-googlepinyin`, `fcitx-module-cloudpinyin`, `fcitx-module-dbus`, ... (9 more)

### printing — 16 packages

21 packages of printer support, including HP drivers. A workstation in a room is not a print server.

`bluez-cups`, `cups`, `cups-browsed`, `cups-bsd`, `cups-client`, `cups-common`, `cups-core-drivers`, `cups-daemon`, `cups-filters`, `cups-filters-core-drivers`, `cups-ipp-utils`, `cups-pk-helper`, ... (4 more)

### snap — 4 packages

Snapd, its libraries, Plasma's snap backend, and Thunderbird, which is itself a snap. This is the largest single saving in the build and it is not a package count: the stock image carries 14 snaps and about 4 GB of /var/lib/snapd, against a whole 69-package trim that saves far less. Firefox and Thunderbird go with it, because in the archive those packages are transitional wrappers whose only job is to install the snap.

`libsnapd-glib-2-1`, `libsnapd-qt-2-1`, `plasma-discover-backend-snap`, `snapd`

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

## Kept on purpose

Software that looks removable and is not, because these two people
use it. A removal proposal that ignores this is a removal proposal
nobody acted on.

| kept | why |
| --- | --- |
| `firefox` | from packages.mozilla.org, NOT the Ubuntu archive copy. The archive's is `1:1snap1`, a wrapper whose only job is installing the snap. See `apt/mozilla.sources`. |
| `libreoffice-*` | Alv and Puria write things. 21 packages is not worth saving; snap was 4 GB and this is the trim talking about the wrong thing. |

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

## Firefox without snap, and how it is verified

Decisions from Alv and Puria: **Firefox yes, LibreOffice yes, snap no.**

Firefox is the interesting one, because on Ubuntu 26.04 the archive's
`firefox` package is literally version **`1:1snap1-0ubuntu8`** — a transitional
package whose only job is to install the snap. Removing snapd therefore removes
the browser, and purging the deb does not bring it back.

So Firefox comes from **packages.mozilla.org**: upstream-built debs, signed by
Mozilla, updated on Mozilla's schedule. It is an ordinary `.deb` handled by
apt, pinned by version like everything else. That is the entire point: it is
not a snap with a different name.

Verified working, end to end, against the real archive:

```
firefox:
  Candidate: 158.0~build2
     1:1snap1-0ubuntu5   500   <- Ubuntu's snap wrapper
   158.0~build2        1000   <- packages.mozilla.org   WINS
```

The **apt pin is not optional.** Without it apt prefers the archive's version
and the snap comes back through the front door, having been excluded through
the back one.

### The key fingerprint

`tools/add-mozilla-repo.sh` fetches Mozilla's signing key and **verifies the
fingerprint before trusting it**:

```
35BA A0B3 3E9E B396 F59C A838 C0BA 5CE6 DC63 15A3
```

Worth recording how that value was arrived at, because the first attempt was
wrong. It was written down from memory, and the check in the script rejected
it on the first run. The guard caught the author, which is a decent argument
for guards existing.

The corollary matters more: **the fingerprint must never come from the same
place as the key.** A substituted key serves its own fingerprint and sails
through any check that reads it from the download. This one was cross-checked
against Mozilla's published instructions and several independent write-ups.

### What this costs

A second archive to trust, pin, and update — two things that can break the
build and one more signature to verify. Stated rather than glossed over. The
benefit is that Firefox is a real deb on the curated upgrade path instead of
an unaudited parallel package manager.

If Mozilla ever stops publishing for a release, the build fails loudly at
`apt-get update` rather than shipping a browser nobody can update. That is the
desired failure mode.
