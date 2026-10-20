# What PuralvOS Graphics carries

Measured from `/var/tmp/puralvos-build/layer`, not from a list somebody wrote down.

Every package here is a stock, signed package from an upstream archive, at the version that archive publishes. PuralvOS builds, patches and forks no packages. The graphics branch ships the `ubuntustudio-graphics` task and `linux-realtime`; the audio and video application sets are removed. TONE3000, which belongs to the audio branch, is not in this image.

## Totals

| | |
| --- | --- |
| Installed packages | **2378** |
| Removal candidates | **3** (0.1%) |
| Would remain | **2375** |

## Where the weight is

The largest families, by package-name prefix:

| prefix | count |
| --- | --- |
| `python3` | 107 |
| `qml6` | 68 |
| `fonts` | 66 |
| `linux` | 30 |
| `plasma` | 28 |
| `libxcb` | 23 |
| `gir1.2` | 17 |
| `kde` | 14 |
| `ubuntustudio` | 14 |
| `libopencv` | 13 |
| `qt6` | 12 |
| `libtss2` | 11 |
| `qml` | 11 |
| `gnustep` | 9 |
| `libblockdev` | 9 |

## Snap census

Snap is not a package count, it is disk. Counted off the built
rootfs rather than assumed.

No snaps installed.

## Removal candidates

Nothing here is applied automatically. Each group has a reason and a
decision attached to it; the decision is recorded in `excludes.list`.

### snap — 1 packages

Snapd, its libraries, Plasma's snap backend, and Thunderbird, which is itself a snap. This is the largest single saving in the build and it is not a package count: the stock image carries 14 snaps and about 4 GB of /var/lib/snapd, against the 1072-package graphics trim, which saves far less. Firefox and Thunderbird go with it, because in the archive those packages are transitional wrappers whose only job is to install the snap.

`libsnapd-glib-2-1`

### web — 1 packages

A general web browser on a machine that already has one job. None of the graphics applications need it to open local files.

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
| `gimp` | the raster editor. It links `libgs10`, so the Ghostscript libraries stay even though the document viewers do not. |
| `krita` | digital painting and animation. It needs `libmlt7` and `libmlt++7`, so the video front end goes but the MLT runtime stays. |
| `blender` | modelling, animation and compositing. It pulls the OpenImageIO/OpenCV/GDAL chain, which is why the geometry and ML trims are disabled on this branch. |
| `inkscape` | vector illustration. It shares the GIMP/GTK runtime and is one of the task's headline applications. |

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
| `pipewire` | the audio server. Preview playback, screen capture and desktop integration route through it; removing it breaks the graphics session. |
| `python3-dbus` | everything on the desktop talks over D-Bus. |
| `wireplumber` | PipeWire's session manager. Without it nothing routes. |

Anything marked *NOT INSTALLED* is worth a look: either the image is
wrong, or the protection is obsolete.

## Is the product actually there

Checked directly against the built filesystem. A miss here is a
build failure, not a trimming opportunity.

| graphics | 15/15 present | |
| realtime | 4/4 present | |

`linux-realtime` is in the realtime row on purpose. The stock Ubuntu
Studio ISO carries only `linux-generic`, so its presence here is
this build's single most important difference from the base.
