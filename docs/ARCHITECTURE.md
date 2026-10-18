# PuralvOS image architecture

How the two images are built, and the one decision that actually matters.

## The two images

| build | boots to | installs to disk | how |
| --- | --- | --- | --- |
| **PuralvOS Live** (default) | full workstation, live | no | `tools/build-live.sh` |
| **PuralvOS** | full workstation, live | yes, stock Ubuntu installer | `PURALVOS_INSTALLER=1 tools/build-live.sh` |

Both are built from the same curated root filesystem. The only difference is
whether snapd is kept, because the stock installer (`ubuntu-desktop-bootstrap`)
is a snap.

That is not a cosmetic choice. On the stock image, snapd re-runs install and
configure hooks for sixteen seeded snaps on the first live boot — Thunderbird
alone is minutes of hook work — and it is the largest single item in the boot
budget. [`excludes.list`](../excludes.list) already says "NO SNAP", so the
default build enforces it: `snapd.service`, `snapd.seeded`, `snapd.socket`, the
kernel's snap mounts and the installer service are all masked, and the boot
menu says "try out" rather than offering an install. `PURALVOS_INSTALLER=1`
keeps them and pays the cost.

## What the base already gives us

Ubuntu Studio 26.04.1 ships the installer and the live machinery, so none of
this is being written from scratch:

```
/pool/main/u/ubiquity/ubiquity_26.04.1_amd64.deb
/pool/main/u/ubiquity/ubiquity-casper_26.04.2_all.deb
/pool/main/u/ubiquity/ubiquity-frontend-gtk_26.04.1_amd64.deb
/pool/main/u/ubiquity/ubiquity-frontend-debconf_26.04.1_amd64.deb
/casper/minimal.squashfs
/casper/minimal.standard.squashfs
/casper/minimal.standard.live.squashfs
```

Note the live filesystem is layered rather than a single `filesystem.squashfs`:
that changed in 24.04 and is the first thing to trip up anyone rebuilding it.

## What the boot path costs, and what is masked

The live image is a USB stick and a laptop, so every unit that starts is a
second somebody watches a splash. The boot budget was measured with
[`scripts/kvmboottime.sh`](../scripts/kvmboottime.sh), which boots the ISO
under KVM with the CD throttled to 25 MB/s (a USB stick's real throughput) and
waits for the marker the live session writes to `/dev/ttyS0` from inside
Plasma. On 2026-10-18 the same harness measured the image at 68.7 s before
this work and about 43 s after, kernel start to desktop.

The units that were costing the time, and why masking them is correct rather
than a workaround:

| unit | cost | why it is not this product |
| --- | --- | --- |
| `ldconfig.service` | ~11 s, every boot | rebuilds `/etc/ld.so.cache`, which the archive already ships and this build does not invalidate. The `.updated` stamps do not silence it: its conditions are trigger conditions |
| `snapd` + seed hooks | ~8 s, first boot (measured; an earlier 20–30 s estimate from a serial log was high) | runs install/configure hooks for 16 snaps; `excludes.list` says NO SNAP |
| `casper-md5check` | reads 7 GB | verifies the ISO against `md5sum.txt`; a build artifact, not a workstation task |
| `cloud-init` | ~2 s + a network wait | there is no cloud |
| ZFS units | module load + udev | nothing here is on ZFS |
| cups, ModemManager, apport, unattended-upgrades, apt-daily, rsyslog, ufw, smartd, sysstat, anacron | small each | a live media workstation does not print, does not have a modem, and does not need a package refresh at boot |

Masking, not disabling: a unit mask is a symlink to `/dev/null` in
`/etc/systemd/system`, which beats a `WantedBy` symlink in any lower casper
layer. See `tools/build-live.sh`, the `boot time` section, for the full list.

Two more costs are paid once per session rather than per unit:
Plasma builds `ksycoca` and fontconfig's user cache on first login by walking
every desktop file, service and font on the USB. Both are pre-built into
`/etc/skel/.cache` at image time. Baloo, the snap user daemon, DisplayCAL's
profile applier and the session-restore helper are `Hidden=true` in
`/etc/xdg/autostart`; `Hidden` is the key that means "do not start", where
`NoDisplay` only keeps an entry out of menus.

The console is silenced from GRUB to the greeter with `loglevel=0`,
`vt.global_cursor_default=0` and `systemd.show_status=0`, so a Bluetooth probe
complaint or a red FAILED line for a unit that is allowed to fail does not
appear in front of the splash. Everything still reaches the journal and
`dmesg`; `PURALVOS_SELFTEST=1` restores the serial console when it is needed.

## The decision: how does the installed system get *our* package set

> **Reality check (2026-10-18).** The shipped installable variant does not use
> ubiquity. Ubuntu Studio 26.04.1's live installer is the
> `ubuntu-desktop-bootstrap` snap, which is why the Live build disables snapd
> and loses the installer with it, and why the default boot menu says "try
> out". `PURALVOS_INSTALLER=1` keeps snapd and boots the stock snap installer
> unchanged. The preseed analysis below is the plan for how an *installed*
> system gets the curated package set, not a description of the current ISO.

**Decided: option 1, preseed ubiquity. Use Ubuntu's own tools.** The rule that
governs the whole build is in [STANDARD-TOOLS.md](STANDARD-TOOLS.md):
`live-build` for live images, `debootstrap`/`mmdebstrap` for a root filesystem,
`plymouth-set-default-theme` for the splash, `grub-mkconfig` for the menu,
`xorriso` for the ISO. None of these are ours to reimplement.

PuralvOS is built on Ubuntu, so it is built with Ubuntu's tools rather than
with a private build system. That is the decision, and it settles the
question rather than deferring it: ubiquity preseeded, apt for packages, and
the stock Ubuntu Studio helper for the real time step. Nothing here is a
reimplementation of something Ubuntu already ships.

### What "the standard tools" turns out to be, exactly

Checked against the real packages rather than assumed. `ubuntustudio-installer`
2.0.7 (resolute) is a **GUI**. It takes package names as arguments, shows a
GTK or Qt checklist, and has no command line flags and no preseed hook of its
own — verified, not assumed.

So what it does has to be read out of its backend, and it turns out to be
three apt commands and one tiny helper:

| What the GUI does | What it actually is |
| --- | --- |
| tick a task, Install | `pkexec /usr/sbin/ubuntustudio-installer-helper install <pkgs>` |
| the Apply fix button | `pkexec /usr/sbin/ubuntustudio-installer-helper fix` |
| untick a task, Remove | `pkexec /usr/sbin/ubuntustudio-installer-helper autoremove <pkgs>` |

So the standard tool's entire effect on a system is: install these metapackages
with apt, run `fix`, optionally autoremove. Nothing more. Driving apt directly
is not working around the standard tool, it is doing what it does, minus the
mouse.

That is what makes option 1 workable rather than a compromise. The task list
comes from upstream's own `METAPACKAGES` tuple in `backend.py` — it is
already in `tasks.list` — so the GUI was only ever a checklist over ten
metapackages. Preseeding eight of them is not a workaround.

### The plan

- **ubiquity, preseeded**, with the curated package set from `tasks.list` and
  the removals from `excludes.list`. Preseed is Ubuntu's own supported
  mechanism for an unattended install and needs no polkit agent or a
  graphical session.
- **apt-get**, for the task packages, exactly as the standard helper does it.
- **the stock `ubuntustudio-installer-helper fix`**, called as root during the
  build — see the trap immediately below, because calling it naively does not
  do what it looks like it does.

### The trap: the helper silently skips the audio group

This is verified, not theoretical. The `fix` action in
`/usr/sbin/ubuntustudio-installer-helper` is:

```bash
if (( PKEXEC_UID > 999 )); then
        pexuid=$(id -nu "${PKEXEC_UID}")
        /usr/sbin/usermod -aG audio ${pexuid}
fi
```

`PKEXEC_UID` is an environment variable **set by pkexec**. Called the obvious
way during a build — as root, directly, no pkexec — it is unset:

```
PKEXEC_UID unset  ->  (( > 999 ))  ->  false  ->  no usermod  ->  exit 0
```

So the helper copies the limits file into place, **skips adding the user to
the `audio` group, and exits 0 saying it worked.**

That produces precisely the failure this whole design is trying to avoid: a
workstation that installs cleanly, has every application, opens its mixer, and
cannot run audio at real time priority, with no error anywhere. A helper that
exits 0 having done half its job is the worst kind of bug, because the build
reports success.

The build therefore sets `PKEXEC_UID` to the real user's uid when it calls
the helper, and `tools/puralvos-selftest` checks the group membership
independently rather than trusting the helper's exit status. That check exists
for exactly this reason.

## What has to be true before any of this builds

- [ ] curated root filesystem builds from `tasks.list` + `excludes.list`
- [ ] `linux-realtime` is what boots, verified from inside the built image
      with `uname -a`, not from a package list
- [ ] the real time audio limits land: this is `fix` in
      `ubuntustudio-installer-helper`, which enables
      `/etc/security/limits.d/30-ubuntustudio-audio.conf` and adds the user to
      the `audio` group. **Without this the workstation installs fine and
      still cannot run audio at real time priority.** It is the single most
      important non-package step in the whole build.
- [ ] audio, video and graphics applications each launch
- [ ] PipeWire reports a sink
- [ ] the general kernel is absent, so an upgrade cannot boot the wrong one

## Testing

```
scripts/kvmtest.sh      boot an ISO headless, wait for the desktop
scripts/kvmconsole.sh   serial console into the guest
scripts/qmp-key.py      send a keystroke to a guest that is sitting in a menu
scripts/puralvos-selftest   verify a booted image from the inside
```

`puralvos-selftest` is the important one. Its most useful property is that it
launches applications **as the real user in the real session** and waits for a
window, which is the only way to catch an application that installs correctly
and starts to nothing. Two lessons shape it:

- an application must be given time to start before you call it broken
- a version probe exiting non-zero without `DISPLAY` is not evidence of
  breakage, and neither is `Exec=env FOO=bar prog`, where the first word is not
  the program
