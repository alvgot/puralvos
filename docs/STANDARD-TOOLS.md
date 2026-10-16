# Standard tools first

**PuralvOS is built on Ubuntu because Ubuntu works. Do not reinvent the wheel.**

This is a rule for the project, not a sentiment about it, so it is written
down where it can be checked against. The question to ask about any part of
the build is not "can I write this" but "does Ubuntu already do this". Usually
it does.

The two words mean different things and both apply:

- **Use the standard tool.** `live-build` builds live images, `debootstrap`
  and `mmdebstrap` build root filesystems, `plymouth-set-default-theme` sets
  the boot splash, `grub-mkconfig` writes the boot menu, `ubiquity` installs
  Ubuntu, `xorriso` authors the ISO. None of these are PuralvOS's job to
  reimplement, and a private implementation of any of them would be worse
  than the original: fewer bug fixes, fewer contributors, more of ours to
  maintain on two machines.
- **Use the stock package even for one line of it.** If Ubuntu ships a script
  that does one useful thing, call that script. Do not copy its logic into
  ours "so it is clearer". See `tools/puralvos-rt-fix`, which wraps Ubuntu
  Studio's own helper and sets `PKEXEC_UID` correctly, instead of
  reimplementing a limits file.

## What each build job uses

| Job | Tool | Notes |
| --- | --- | --- |
| Build the live image | `live-build` | The standard Ubuntu/Debian live image builder. |
| Build a root filesystem | `debootstrap`, `mmdebstrap` | `mmdebstrap` where we need the finer control. |
| Install Ubuntu on the target | `ubiquity`, preseeded | Standard unattended install. |
| Choose the task packages | `apt-get` | This is what `ubuntustudio-installer` does internally. |
| Real time audio permissions | `ubuntustudio-installer-helper fix` | Stock. Called through our wrapper. |
| Find the RT kernel | `apt-cache` / `python-apt` | `tools/kernel-select.py` asks apt, it does not guess. |
| Boot splash | `plymouth-set-default-theme` | Not a hand-copied theme into `/usr/share/plymouth`. |
| Boot menu | `grub-mkconfig`, `grub-mkfont` | Not a hand-written `grub.cfg`. |
| Login screen | SDDM's own theme directory | Its own mechanism, not a patch. |
| Wallpapers | `/usr/share/backgrounds` + the DE's own settings tool | Plasma's `plasma-apply-wallpaperimage`, or the standard gsettings path. |
| Alternatives | `update-alternatives` | For editor, browser, and anything with a default. |
| Package upgrades | `apt-get --only-upgrade` | `tools/upgrade-curated.sh`. |
| Author the ISO | `xorriso` | |
| Verify the base | `sha256sum -c` | Against Canonical's published checksum. |

## The hand-rolled parts, and why each one is justified

These are the only things we wrote that Ubuntu did not already provide. Each
one is here because no standard tool does the job, and none of them shadows
something that already works.

| File | Why it exists |
| --- | --- |
| `tools/puralvos-selftest` | Nothing in Ubuntu verifies that an image's audio is *actually* real time and that its branding is *actually* ours. Ubuntu tests packages; this tests the assembled workstation. It already delegates where it can: `dpkg-query` for package state, `setpriv` to drop privileges, `pactl` for the sound stack. |
| `tools/puralvos-rt-fix` | A wrapper, not a replacement. The wheel it turns is Ubuntu Studio's. It exists only to set `PKEXEC_UID` so the stock helper does its whole job, and then to check it did. |
| `tools/kernel-select.py` | Asks apt which kernel a metapackage depends on, because the names lie (`linux-lowlatency` pulls the *generic* image on 26.04) and a hardcoded name silently ships the wrong kernel. This is a question apt can answer and we were not. |
| `tools/make-brand.py` | No standard tool draws a logo. Generates from `brand/tokens.json` so the palette has one definition. |
| `tools/make-package-declaration.py` | Derives the self test's package list from `tasks.list` so there is no second copy to drift. Arguably `awk`; kept in Python only because the section-heading classification is real logic rather than a substitution. If it ever needs to become more than that, it should become `awk`. |
| `scripts/qmp-key.py` | Sends a key to a guest sitting in a GRUB menu over QMP. There is no standard tool for this. The alternative is setting `timeout=0` in the boot menu, which is the right answer for **our** images and is not available when testing the **stock** base ISO, which we do not control. Both are legitimate; the timeout is preferred for our own builds. |

## Audited, not just asserted

The rule is only worth having if it can be checked. Every tool the repository
already uses:

```
dpkg-query                 puralvos-selftest, upgrade-curated.sh
setpriv                    puralvos-selftest
pactl                      puralvos-selftest
apt-get                    upgrade-curated.sh
apt-cache                  kernel-select.py
usermod                    puralvos-rt-fix
sha256sum                  Makefile (verify-base)
```

**Nothing in this repository reimplements something Ubuntu already does.**
The self test asks `dpkg-query` for package state, `setpriv` to drop
privileges, and `pactl` for the sound stack, rather than reading
`/var/lib/dpkg` or parsing audio state itself. The upgrade tool is a curated
list plus `apt-get --only-upgrade`. The kernel tool asks apt.

The tools named for the image build — `live-build`, `debootstrap`,
`mmdebstrap`, `xorriso`, `grub-mkconfig`, `plymouth-set-default-theme`,
`update-alternatives` — appear in no script here, because **the image build
has not been written yet.** That is the correct state: the build has not
replaced them with anything, and when it is written this table is what it
must be written from.

Re-run this audit when the image build lands. If a standard tool appears in
the table and something hand-rolled appears beside it, one of them is wrong.

## The rule for a new piece of code

Before writing something, check in this order:

1. Does Ubuntu or Debian already have it? `apt-cache search`, then read the
   source if the name is unhelpful.
2. Does an installed standard tool do it as a side effect?
3. Is there a stock script that does the one useful thing?
4. Only then, write it, and put it in the table above with the reason.

If a new file cannot be justified by that list, it should not be merged.

## What this rules out

- A custom live image builder. `live-build` exists and is maintained by the
  distribution.
- Hand-written `grub.cfg`. `grub-mkconfig` is what makes a boot menu that
  keeps working across kernel upgrades.
- Hand-copied Plymouth themes or SDDM themes. Both have their own tooling and
  their own directory conventions.
- Own package management. `apt` is the package manager. This is also why the
  upgrade story is a curated list plus `--only-upgrade` rather than anything
  clever: `dpkg` records no provenance, so there is no way to ask it which
  packages are ours.
- Tracking Ubuntu Studio's fixes by copying their code. They are upstream for
  the task list and for the real time helper, and we use both as-is.