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
brand/assets/wallpaper-*.png   1080p, 1440p, 4k
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

- [ ] SDDM theme
- [ ] Plymouth boot splash
- [ ] GRUB theme and menu strings
- [ ] Icon theme
- [ ] Plasma theme and window decoration
- [ ] App menu XML
- [ ] Installer artwork override
- [ ] `/etc/os-release`
- [ ] the branding test described above