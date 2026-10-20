# What PuralvOS Video carries

Measured from `/var/tmp/puralvos-build/layer`, not from a list somebody wrote down.

Every package here is a stock, signed package from an upstream archive, at the version that archive publishes. PuralvOS builds, patches and forks no packages. The video branch ships the `ubuntustudio-video` task and `linux-realtime`; the audio and graphics application sets are removed. TONE3000, which belongs to the audio branch, is not in this image.

## Totals

| | |
| --- | --- |
| Installed packages | **2377** |
| Removal candidates | **3** (0.1%) |
| Would remain | **2374** |

## Where the weight is

The largest families, by package-name prefix:

| prefix | count |
| --- | --- |
| `python3` | 92 |
| `qml6` | 68 |
| `fonts` | 65 |
| `linux` | 30 |
| `plasma` | 28 |
| `libxcb` | 24 |
| `kde` | 15 |
| `ubuntustudio` | 14 |
| `vlc` | 14 |
| `gir1.2` | 13 |
| `libopencv` | 13 |
| `qt6` | 12 |
| `libtss2` | 11 |
| `qml` | 11 |
| `libblockdev` | 9 |

## Snap census

Snap is not a package count, it is disk. Counted off the built
rootfs rather than assumed.

No snaps installed.

## Removal candidates

Nothing here is applied automatically. Each group has a reason and a
decision attached to it; the decision is recorded in `excludes.list`.

### snap — 1 packages

Snapd, its libraries, Plasma's snap backend, and Thunderbird, which is itself a snap. This is the largest single saving in the build and it is not a package count: the stock image carries 14 snaps and about 4 GB of /var/lib/snapd, against a whole 69-package trim that saves far less. Firefox and Thunderbird go with it, because in the archive those packages are transitional wrappers whose only job is to install the snap.

`libsnapd-glib-2-1`

### web — 1 packages

A general web browser on a machine that already has one job. Kdenlive and VLC will open URLs without it.

`firefox`

### evolution — 1 packages

Contacts and calendar backend with nothing in front of it.

`evolution-data-server-common`

## Kept on purpose

Software that looks removable and is not, because these two people
use it. A removal proposal that ignores this is a removal proposal
nobody acted on.

| kept | why |
| --- | --- |
| `firefox` | from packages.mozilla.org, NOT the Ubuntu archive copy. The archive's is `1:1snap1`, a wrapper whose only job is installing the snap. See `apt/mozilla.sources`. |
| `kdenlive` | the timeline editor. It is the reason the video task exists, and it is also the package that makes the accounts and ML trims unsafe. |
| `blender` | modelling, animation and compositing. It pulls the OpenImageIO/OpenCV/GDAL chain, which is why the geometry trim is disabled on this branch. |
| `obs-studio` | capture and streaming. The video task's other headline application. |

## Do not remove these

They look exactly like the cruft above and they are not.

| package | why |
| --- | --- |
| `avahi-daemon` | may be wanted for network audio discovery; decide once, not by accident. |
| `libbluetooth-dev` | development headers for the above. |
| `libbluetooth3` | PipeWire's Bluetooth audio. See above. |
| `libqt6bluetooth6` | Qt Bluetooth, used by the audio stack's pairing UI. |
| `libspa-0.2-bluetooth` | PipeWire's Bluetooth audio. Removing this takes wireless headphones with it. |
| `linux-firmware-nvidia-graphics` | proprietary graphics firmware. PuralvOS ships proprietary software on purpose and this is the graphics card. |
| `pipewire` | the audio server. Video playback, capture and editing all route through it; removing it breaks Kdenlive and OBS. |
| `python3-dbus` | everything on the desktop talks over D-Bus. |
| `wireplumber` | PipeWire's session manager. Without it nothing routes. |

Anything marked *NOT INSTALLED* is worth a look: either the image is
wrong, or the protection is obsolete.

## Is the product actually there

Checked directly against the built filesystem. A miss here is a
build failure, not a trimming opportunity.

| video | 15/15 present | |
| realtime | 4/4 present | |

`linux-realtime` is in the realtime row on purpose. The stock Ubuntu
Studio ISO carries only `linux-generic`, so its presence here is
this build's single most important difference from the base.
