# Branding: everything says PuralvOS

The request was that the wallpapers, the logos and everything else are
PuralvOS. The version of that worth writing down is that this is **required,
not decorative**.

Ubuntu and Ubuntu Studio are trademarks of Canonical Ltd. Ubuntu Studio is an
independent project and is **not affiliated with or endorsed by Canonical**.
This image is built on Ubuntu Studio, is neither, and redistributes under a
different name. Shipping Canonical's artwork, wallpapers, wordmarks and
installer branding inside it is a trademark exposure, and it also means the
thing that greets a user as they install a PuralvOS workstation is a dialog
saying "Ubuntu". So the rebrand is a correctness task that happens to also be
the cosmetic one.

## Where the branding lives

Not in one place. This is the inventory, and it is the reason "just change the
wallpaper" is not a task.

| Layer | Where it lives | What has to happen |
| --- | --- | --- |
| **ISO label** | `/.disk/info` | Currently `Ubuntu-Studio 26.04.1 LTS "Resolute Raccoon" - Release amd64 (20260826)`. This string is what the boot menu and the installer show. |
| **Boot menu** | GRUB menuentry titles, `grub.cfg` prompts | "Try or Install Ubuntu Studio" → PuralvOS. Also `Try or Install`, `Install (OEM)`, the `f`/`e`/`c` help lines. |
| **Boot splash** | `plymouth-theme-*` | Ubuntu Studio's spinner. Replaced. |
| **Login screen** | SDDM theme, `/usr/share/sddm/themes/` | Ubuntu logo, wordmark, background. |
| **Wallpapers** | `/usr/share/backgrounds/` | See `brand/assets/wallpaper-*.png`. |
| **Icons** | `/usr/share/icons/` | `ubuntustudio-icon-theme`. |
| **Desktop theme** | `ubuntustudio-look` | Colours, window decoration, Plasma theme. |
| **App menu** | `ubuntustudio-menu` XML | Entries and section names. |
| **Installer** | `ubiquity-ubuntu-artwork` | The wizard's artwork. |
| **OS identity** | `/etc/os-release`, `/usr/share/doc`, About dialog | `NAME`, `PRETTY_NAME`, `ID`, `HOME_URL`, `LOGO`. |
| **Support URLs** | `/etc/lsb-release`, help pages, bug reports | Must not point at Canonical or Ubuntu Studio trackers. |

## The one that will bite: `ubiquity-ubuntu-artwork`

> **Note (2026-10-18).** The installer that actually ships on Ubuntu Studio
> 26.04.1 is the `ubuntu-desktop-bootstrap` snap, not ubiquity, and the default
> PuralvOS build is the Live image with snapd masked, so it has no installer at
> all. The `ubiquity-ubuntu-artwork` analysis below is kept because it is the
> path the installable variant and the installed-system plan use; the snap's
> own wizard artwork is inside the snap and is not overridden by this build.

This package is not optional in practice. Ubiquity's templates reference it, so
removing it leaves a broken installer rather than an unbranded one. The
approach is therefore **override, do not remove**: keep the package so the
installer keeps working, and lay our own artwork and templates on top of it in
the image overlay.

That means the rebrand is not "remove Ubuntu Studio branding" but "make sure
that for every path, the file that wins is ours". Which is a checkable
condition, and it wants a test.

## The rule the test should enforce

For any path that carries branding, the file that ends up in the built image
must resolve to PuralvOS. Concretely:

1. Enumerate every branding path the curated package set installs.
2. Overlay `brand/` on top.
3. Re-enumerate the same paths in the built filesystem.
4. Fail the build if any of them is still Ubuntu's or Ubuntu Studio's.

The failure mode this catches is the boring one: a single file that arrived
through a transitive dependency nobody listed, so it is not in `excludes.list`
and not in the overlay, and it silently ships.

## The assets

`brand/tokens.json` is the palette; `tools/make-brand.py` generates everything
from it. One input, so nothing can drift.

```
brand/tokens.json              palette, name, tagline, discipline mapping
brand/assets/mark.svg          the mark
brand/assets/mark-mono.svg     single-colour, for stencilled contexts
brand/assets/wordmark.svg      PuralvOS + tagline
brand/assets/glyph-audio.svg   waveform
brand/assets/glyph-video.svg   play
brand/assets/glyph-graphics.svg aperture
brand/assets/wallpaper-*.png   vivid sinusoids on black: 1080p, 1440p, 4k
```

### About the mark

Pur + Alv. A **P** in the audio accent and an **A** in the video accent, with
the crossbar in graphics. Three accents, one per discipline, used consistently
everywhere.

No orange, because that is Ubuntu's trademark and this image is not Ubuntu's.
No spectrum either: a spectrum is the obvious choice for a three-discipline
logo and it is exactly the mark the Freesh-derived audio lineage already uses,
so an identity built on it would read as somebody else's.

It is also two people, on purpose: this is a workstation built for two specific
users, not a product.

### The wallpapers

A field of vivid sinusoids on black. Every line is a sum of three sines at its
own frequency and phase, so no two repeat, and the golden angle keeps
neighbouring lines from ever lining up into visible stripes.

Lines are drawn thin and bright, then a blurred copy of the same lines is
**added back additively**. That second pass is why they glow rather than merely
being coloured, and it works precisely because the background is true black:
additive blending over black can only brighten. It is also the fix for the
earlier version, where a low-opacity amber wash over dark blue came out olive
mud. On black there is nothing to muddy.

The field is biased low — denser and brighter towards the bottom, thinning out
towards the top where the icon grid lives. There is no logo: a wordmark across
a desktop is an advertisement.

Everything is drawn at 2× and downsampled. PIL has no anti-aliased line
drawing, so a one-pixel diagonal at native resolution is a staircase and a
field of them reads as noise rather than as lines.

The palette is wider than the three accents on purpose. Three colours repeated
down a frame looks like a gradient with stripes; the eight vivid entries keep
every line distinct while staying inside the identity.

Three wallpapers, 1080p to 4K, about 7 MB, generated in fourteen seconds.

### Two things the generator got wrong first time

Recorded because both are easy to reintroduce.

**Duplicated geometry.** The SVG writer and the PIL preview each carried their
own copy of the shape. They drifted: after the strokes were rebalanced, the
preview still rendered the old spiky mark with a stray dot in the corner. A
preview that shows something the product does not do is worse than no preview,
because it gets believed. There is now one `mark_geometry()` and both read it.

**No rasteriser on this machine.** No `rsvg-convert`, no inkscape, no
ImageMagick, no chromium. So the preview is drawn with PIL from the same
geometry. It is faithful enough to judge the design, which is the only reason
it exists — it is not a PNG export path.

## Still to do

Done by `tools/build-live.sh:brand_the_tree`, verified by tier 3 of
`tools/puralvos-selftest`:

- [x] SDDM theme — `/usr/share/sddm/themes/puralvos`, selected by
      `/etc/sddm.conf.d/98-puralvos-theme.conf`. The QML is breeze's, which is
      installed; only the background, the logo and the accent colour are ours.
      Writing a Qt Quick greeter from scratch to replace four lines of
      `theme.conf` is a Qt project, not a branding task.
- [x] Plymouth boot splash — `/usr/share/plymouth/themes/puralvos`, selected by
      `/etc/plymouth/plymouthd.default`. The watermark is a PNG generated from
      `tokens.json`, because plymouth takes no SVG and there is no SVG rasteriser
      on the build machine. The layout is the `two-step` module's, copied from
      the `spinner` theme the image already ships.
- [x] GRUB theme and menu strings — `/boot/grub/themes/puralvos` with the
      palette substituted and Ubuntu Studio's artwork replaced;
      `/etc/default/grub.d/99-puralvos.cfg` selects it. The menuentry titles are
      rewritten in `grub.cfg`.
- [x] `/etc/os-release` — and, because `/etc/os-release` is a symlink to
      `../usr/lib/os-release` on this image, `/usr/lib/os-release` as well, with
      the symlink put back afterwards.
- [x] the branding test — tier 3 of `tools/puralvos-selftest`, which reads the
      *running* system rather than the build tree.

Not done:

- [ ] Icon theme. `ubuntustudio-icon-theme` is still installed and still
      providing the menu's icons. This is the largest remaining branding gap.
- [ ] Plasma theme and window decoration. `ubuntustudio-look` is installed; the
      accent colours come from `tokens.json` instead of Canonical's orange.
- [ ] App menu XML. `ubuntustudio-menu` is installed and its sections are
      still named for Ubuntu Studio.
- [ ] Installer artwork override. ubiquity's own screens.

## What "Ubuntu" may still say

The self test checks for **Ubuntu Studio**, not for the substring `ubuntu`, and
that distinction is deliberate.

`ID_LIKE="ubuntu debian"` and `UBUNTU_CODENAME=resolute` stay. PuralvOS is a
derivative of Ubuntu Studio, which is a derivative of Debian; every Debian
derivative carries the family marker, and Ubuntu itself ships
`ID_LIKE=debian`. `UBUNTU_CODENAME` is what keeps version-locked dependencies
resolving. Remove either and the product stops working as a derivative — so a
check that failed on them would be demanding that this stop being a derivative.

That is not theory: `ID_LIKE=ubuntu` alone broke the installer. apport, which
the `ubuntu-desktop-bootstrap` snap bundles and imports at startup, computes
`{ID} | ID_LIKE.split()` and refuses to run unless `debian` is in that set:

    RuntimeError: Could not determine system package manager.
                  Please file a bug and provide /etc/os-release!

`subiquity-server` died on every boot, `/run/subiquity` never appeared, and
the installer window showed "Something went wrong" — while the rest of the
live session worked. The `ID` is ours; the family markers are not negotiable.

The check that failed on them was `grep -qi ubuntu /etc/os-release`, and it had
failed on every boot of every build. A branding check that cannot pass is a
branding check nobody reads.