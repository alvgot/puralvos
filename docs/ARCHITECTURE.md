# PuralvOS image architecture

How the two images are built, and the one decision that actually matters.

## The two images

| | boots to | installs to disk |
| --- | --- | --- |
| **PuralvOS** (primary) | full workstation, live | yes |
| **PuralvOS Live** | full workstation, live | optional |

The primary image is the one that ships. It behaves like the Ubuntu Studio ISO
it is based on: you boot it, the whole workstation is there to try, and there
is an "Install PuralvOS" entry that writes it to a machine.

The live image is the same workstation with the installer removed. It exists
for evaluation, for demos, and for machines where installing is not wanted.
Its only real difference is the absence of the installer, which is why it is
worth building separately rather than shipping one image and hoping.

Both are built from the same curated root filesystem. That is the whole point:
the thing you try live is byte-for-byte the thing you get installed.

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

## The decision: how does the installed system get *our* package set

**Decided: option 1, preseed ubiquity. Use Ubuntu's own tools.**

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
