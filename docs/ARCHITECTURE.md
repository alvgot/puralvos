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
that changed in 24.04 and is the first thing to trip up anyone rebuilding this
the way dyneV does it.

## The decision: how does the installed system get *our* package set

This is the part that is not obvious, and it decides everything else.

Ubuntu Studio's own installer knows to install the Studio task set. Ours must
install **audio + video + graphics and nothing else**, and it must not install
the general kernel. Three ways to do it:

### 1. Preseed ubiquity with our package list

ubiquity runs a package install during install; a preseed can say which
packages to add and which to remove.

- **For:** small, declarative, no second copy of the build logic.
- **Against:** the removal half is a long list of "remove this, that and the
  other", and anything ubiquity pulls in on its own has to be enumerated by
  hand and kept in step with excludes.list.

### 2. Install the base, then apply our tasks and exclusions afterwards

- **For:** one place for the logic; excludes.list is applied exactly as it is
  on the live side.
- **Against:** slow. Installing the full Studio desktop and then tearing
  several hundred packages back out downloads and unpacks the very things the
  image is supposed not to contain. It also leaves autoremovable orphans and
  makes "what is actually installed" depend on the order of two operations.

### 3. Build the curated root filesystem ourselves and install that

- **For:** the installed system is exactly the tested filesystem. No
  install-then-remove window where the machine is wrong. No orphan packages
  by construction.
- **Against:** the most work, and it means owning partition setup, bootloader
  and the installer front end rather than reusing ubiquity's.

### Recommendation

**1 for the shipped image, 2 for the live image, 3 if the image grows a
lifetime.**

That sounds like fence-sitting, so the reasoning: the live image is
overlaid onto casper at build time, so it never needs to install anything —
the exclusion pass is free there. The installer only runs on the real path,
and ubiquity's own install step is where a curated package list belongs. If
PuralvOS ever gets an upgrade path, the answer stops being a build-time
question and becomes a filesystem question, which is when option 3 starts
paying for itself.

**This is not decided.** It needs Alv and Puria's preference, because it is a
commitment about how the project grows, not a technical detail.

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

The dyneV harness is reusable and should be copied rather than reinvented:

```
scripts/kvmtest.sh      boot an ISO headless, wait for the desktop
scripts/kvmconsole.sh   serial console into the guest
```

`dyne-selftest` is worth porting too. Its most useful property is that it
launches applications **as the real user in the real session** and waits for a
window, which is the only way to catch an application that installs correctly
and starts to nothing. Two lessons from that file travel with it:

- an application must be given time to start before you call it broken
- a version probe exiting non-zero without `DISPLAY` is not evidence of
  breakage, and neither is `Exec=env FOO=bar prog`, where the first word is not
  the program
