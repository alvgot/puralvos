# PuralvOS work report

**Period:** 2026-10-16 11:55 → 2026-10-17
**Repo:** `/root/puralvos`

Two parts. §1–§3 are the state of the work as of the end of 16 October. §4–§6
are what the follow-up session found and changed, and **the one thing that is
still broken**.

---

## 1. Where the project stood

PuralvOS builds a bootable, verifiable ISO. That was done: 7.18 GB images in
`out/`, each with a verified boot record and a full in-guest self test that
reads the real time kernel out of the serial port.

The last image known to boot (`out/puralvos-live-20261016-1822.iso`, serial log
`/tmp/opencode/kvmrun/v1bios/serial.log`) reported:

```
ok=17 bad=16
RESULT tier2 PASS kernel-is-realtime #38.1-Ubuntu SMP PREEMPT_RT Thu Sep 10 15:24:56 UTC 2026
RESULT tier3 PASS os-release-name PuralvOS
RESULT tier2 PASS user-in-audio-group
```

PREEMPT_RT confirmed on hardware emulation, and the image reports itself as
PuralvOS. Both of those were false for every build before 18:22.

## 2. What was done, in order (16 October)

| # | Commit | What it settled |
| --- | --- | --- |
| 1 | `9a6485f` | Base, task set, upgrade policy. `tasks.list` taken from upstream's own `METAPACKAGES` in `ubuntustudio-installer` 2.0.7, minus photography and publishing. Not invented. |
| 2 | `ebff111` | `tools/kernel-select.py`. **The find of the day:** on 26.04 `linux-lowlatency` depends on `linux-image-generic` — the generic kernel with boot flags, not a real time one. `linux-realtime` is the PREEMPT_RT build. The same name means different things across releases, so the tool asks apt instead of hardcoding. |
| 3 | `8d91453` | `docs/BASELINE.md` plus `scripts/kvmtest.sh`, `kvmconsole.sh`, `qmp-key.py`. A KVM harness, because the base has to be measured before it is modified. |
| 4 | `2242a57` | Identity. `brand/tokens.json` is the only input; `tools/make-brand.py` derives mark, wordmark, three glyphs and three wallpapers. `docs/PERFORMANCE.md` turns "fast" into numbers that can fail. |
| 5 | `acf268e` | `tools/puralvos-selftest` (858 lines) and `make-package-declaration.py`. The dyneV lineage was dropped from the repo. |
| 6 | `933ba07` | `tools/puralvos-rt-fix`, and a fix to a trap in the stock helper that silently skips adding the live user to the audio group when `PKEXEC_UID` is unset. |
| 7 | `8ac366d` | `docs/STANDARD-TOOLS.md`: use Ubuntu's own tools first, with an audited exception list. |
| 8 | `82020f8` | `tools/build-live.sh`. The wallpapers were redrawn as a field of vivid sinusoids on black. |
| 9 | `e6d356d` | The build pipeline proper: casper layer union, kernel, branding, RT fix, repack, `grub-mkrescue`. |
| 10 | `3367715` | `tools/report-packages.py` + `docs/PACKAGES.md`. Inventory read out of the built rootfs so it cannot drift. Found the product missing applications: video 8/13, graphics 5/8. |
| 11 | `d8af176` | Snap census: **16 snaps, 2035 MB of payloads**. Largest single saving, and not a package count. |
| 12 | `e0cd649` | Firefox without snap. The archive's `firefox` is version `1:1snap1-0ubuntu8` — a transitional wrapper whose only job is installing the snap. So Firefox comes from `packages.mozilla.org`, pinned by apt. Decision recorded: **Firefox yes, LibreOffice yes, snap no.** |
| 13 | `1c1e8a5` | All 3360 packages with versions, flat and greppable, replacing a prefix-grouped view that had produced 2028 "groups" for 3360 packages. |
| — | uncommitted | The top-layer bug and its fallout. See §3. |

## 3. The uncommitted work: the top-layer bug

This is the substantive finding of the session, and it is worth stating plainly
because it invalidates a class of "verified" builds.

**The top layer was computed as `comm -13 base.list full.list`.** That returns
paths present only in `full.list` — new files. It silently discards every file
this build *edited*. Measured on the working tree: **15 090 new paths, 2 454
edited ones thrown away**, among them:

```
etc/os-release                                        still said Ubuntu
etc/lsb-release                                       still said ubuntu
etc/security/limits.d/30-ubuntustudio-audio.conf       reverted to the base
etc/group                                             lost the live user
```

All four edits had been made, all four verified in the working copy, all four
absent from the ISO. The image booted, the kernel was PREEMPT_RT, and the image
was not PuralvOS. Only reading the kernel command line out of a booted guest
found it: `INFO distro=Ubuntu 26.04.1 LTS`.

**The fix**, in the working tree:

- `rsync -ani --delete` against the read-only union instead of `comm`. It
  compares content *and type*, and `--delete` supplies the other direction.
  Under 2 seconds against 4m43s for the equivalent `cmp` loop over 435 529 paths.
- Two rsync output traps, each of which cost a build: the 11-character flag
  field yields a **leading space** on the path (110 paths silently skipped), and
  symlink lines carry ` -> target` which `tar` then fails to stat.
- `tar --no-recursion`, not `rsync --files-from`. rsync recurses into every
  directory named in the list; given `etc/` it copies the whole of `/etc`, which
  turned a 950 MB top layer into 8.5 GB and the ISO into 9.9 GB.
- **Whiteouts.** A file the build removed has to become `.wh.<name>` in the top
  layer or the base layer's copy reappears when the overlay is assembled.
- A verification that counts what actually arrived: `staged 13473 of 13473`.

Alongside it, in the same diff: `say`/`die` hoisted above `pick_work` (a machine
without 45 GB free used to print `die: command not found` and carry on with an
empty `WORK`, so the real error never appeared); `/usr/lib/os-release` written
explicitly because `/etc/os-release` is a symlink and `sed -i` replaces it with
a regular file; the RT limits file taken from inside the image rather than from
the build host, where it does not exist; the boot-record check reading the GPT
signature at byte 512 with `bs=1` (`bs=512 skip=1` is eight sectors, 4096 bytes,
and never matched a correct image); `puralvos.selftest=1` applied idempotently
to every menu entry by `awk`, because two "add if missing" seds stack on a
`--author-only` re-author.

`tools/puralvos-selftest` also had a check that required `rtprio = 95` with an
equals sign. `pam_limits` parses four space-separated fields and Ubuntu's own
file has no `=`. It reported FAIL on an image carrying Ubuntu Studio's limits
file verbatim — the worst kind of wrong, because it sends you hunting a
packaging bug that is not there. Now it checks each of the four grants by
domain and item and names the ones that are missing.

## 4. Open, and worth knowing

**1. The image built at 07:49 on 17 Oct does not boot. Not fixed.**

    error: symbol `grub_memcpy' not found.
    Entering rescue mode...
    grub rescue>

under UEFI, and an isolinux "unable to find a medium containing a live file
system" under SeaBIOS. Every structural check passed: MBR 55aa, GPT at LBA 1,
El Torito BIOS and UEFI entries present, `grub.cfg` in the ISO byte-identical to
the working tree, `vmlinuz` verified PREEMPT_RT. The stock base ISO boots under
the same harness, so it is our image.

The strong hypothesis is a GRUB version mismatch:

| | |
| --- | --- |
| `/usr/lib/grub` on the build machine | **2.12** |
| `boot/grub` inside the base ISO | **2.14** |

`grub-mkrescue` builds the boot core from the *build machine's* `/usr/lib/grub`
and the modules it then loads come from the *ISO tree's* `boot/grub`. A 2.12
core asking 2.14 modules for `grub_memcpy` produces exactly that error.

Three things about this that are worth knowing before anyone spends time on it:

- **`grub-mkrescue -d` does not fix it.** `-d` expects a flat single-platform
  module directory. The ISO's platform directories have no `kernel.img`, no
  `.img` boot targets and no `modinfo.sh`, so it fails on successive attempts
  with `moddep.lst: No such file`, then `biosdisk.mod: No such file`. Two dead
  ends were tried and abandoned; the error text is in the script.
- **It contradicts an earlier success.** An ISO built the same way at 18:22 on
  16 Oct booted and produced a full serial log. Same build machine, same GRUB,
  same ISO tree. So either the theory is wrong or something else changed that
  this report has not identified. It is recorded as a hypothesis, not a finding.
- **The real fix is environmental**: build on a machine whose GRUB matches the
  base ISO, or install matching GRUB modules. `tools/build-live.sh` now prints
  both versions on every build and warns when they differ.

**2. The rest of the list, all fixed in this session** — see §6.

## 5. Honest assessment

The build works up to the ISO. What is verified is the packaging: the curated
package set, the real time kernel's presence and its PREEMPT_RT nature, the
branding, the RT limits file, the top-layer reconstruction. What is *not*
verified is that the finished ISO boots, because the last one tried did not.

Two things to be careful about. First, the branding was broken in every image
built before 18:22 while the build log said `os-release: PuralvOS 26.04.1 LTS`
and every check passed; the log was reporting on the working tree, not on the
artifact. That class of check — verify the thing you ship, not the thing you
edited — is now enforced where it could be, but item 4 above shows the habit is
not yet complete. Second, the desktop has never been seen running on a real
machine. Everything verified so far was verified on a host with no sound card
and no GPU.

## 6. What this session fixed

Bugs found and repaired, with the check added that would have caught each one:

| # | Bug | Was | Now |
| --- | --- | --- | --- |
| 1 | `build_tree` read `$ASSETS`, which nothing set | the full build died a third of the way in, after unpacking 17 GB | one `brand_the_tree()`, called by both build paths |
| 2 | Branding applied in two places | `--author-only` produced a different image from a full build | single definition, both paths call it |
| 3 | `rm -f backgrounds/*ubuntu*` matched a **directory** | 11 Ubuntu wallpapers survived; tier 3 failed, build said success | `find -depth -iname`, then verify none remain |
| 4 | Desktop-entry parser, two copies, both wrong | OpenLP, Ardour and VLC reported broken | one `tools/lib/desktop-exec.sh`, with `tools/test-desktop-exec` |
| 5 | Parser called every Exec line a wrapper | Software Sources claimed to be `env` | only a leading `env` is a wrapper |
| 6 | Parser rejected absolute paths | Ardour, VLC had "no executable" | leading `/` accepted |
| 7 | `desktop_exec_present` consulted the **host** | hid all 154 applications from the menu | takes a root; `$FULL` passed by the build |
| 8 | `rtprio` measured via `setpriv` | `pam_limits` is a session module; `setpriv` opens none, so it could only ever print 0 | measured through `su -` (a real PAM session) |
| 9 | `os-release-not-ubuntu` grepped `ubuntu` | failed on `ID_LIKE=ubuntu`, which is deliberate and required | greps `ubuntu[ _-]?studio` |
| 10 | Kernel chosen by `ls /boot \| tail -1` | would pick the generic kernel the day the archive ships a newer one; picks the wrong one today with two installed | chosen from dpkg by package name |
| 11 | No PREEMPT_RT assertion on the shipped kernel | a generic kernel would ship silently | `grep -a PREEMPT_RT` on `casper/vmlinuz`, dies if absent |
| 12 | `console=ttyS0` was never *added*, only matched | a from-scratch ISO could not report its own kernel | added by idempotent awk; every entry checked individually |
| 13 | `linux-realtime` declared, `linux-image-realtime` shipped | tier 1a failed on every image | `CARRIED_BY` translation, printed when it applies |
| 14 | `selftest-packages.txt` never installed | tier 1a: "cannot verify the curated set", always | installed, and the build dies without it |
| 15 | `grep … \| wc -l` under `pipefail` | `grep` exits 1 on no matches, killing the build silently at the last step of branding | `\|\| true`, and a note on the trap |
| 16 | Deleted paths fed to `tar` | 38 859 "Cannot stat", tar exit 2, silent death of a 25-minute build | list split by existence: copy vs whiteout |
| 17 | rsync itemisation read backwards | `*deleting` is a **new** file, not a deleted one | split by what exists, not by flag |
| 18 | Whiteout per file, not per directory | 38 850 tombstones re-creating the deleted directories | one per removed path, children skipped (107 → 89) |
| 19 | Prefix test had operands reversed | matched nothing, so every child got its own whiteout | `case "$p" in "$LASTWH"/*)` |
| 20 | `dirname`/`basename` per path | 38 870 forks, 32s of forking | parameter expansion |
| 21 | Ancestor test walked the tree with an associative array | bash rehashes on every nested expansion; did not finish in 400s | one remembered path, since the list is sorted (0.2s) |
| 22 | `strings \| grep -q` | `grep -q` exits early, `strings` takes SIGPIPE, `pipefail` returns 141 — on a **correct** kernel | `grep -a` on the file |
| 23 | Resume marker survived the `rm -rf` | "reusing the existing build root" pointing at a deleted tree | marker validated against the tree, not trusted |
| 24 | No plymouth, SDDM or GRUB theme | Ubuntu Studio's on all three screens | generated from `tokens.json`, checked active not just present |
| 25 | No autologin; X11 assumed | live session sat at a login prompt nobody would answer | explicit autologin into Plasma on X11 |
| 26 | Splash/login checks tested a directory, not a selection | a theme that exists but is not used would pass | theme present **and** configured |
| 27 | Games and education tools in the curated list | 8 SKIP lines per boot for things deliberately excluded | list mirrors `tasks.list`; `/usr/games` dropped from every search path |
| 28 | `kwin_x11` only | Wayland sessions reported a dead desktop | either compositor accepted |
| 29 | `DISPLAY=:0` hardcoded | a session on `:1` reported as no desktop at all | discovered from the session's own process |
| 30 | Stale `.pyc` tracked in git | committed in a wallpaper commit | untracked, `.gitignore` updated |
## 7. Session 2026-10-18: the installer, the audio checks, and the ISO size

### The installer was killed by a branding line

Every boot of every build since branding began ended with the installer
window showing "Something went wrong", while the rest of the live session
was healthy. The serial console pointed at
`snap.ubuntu-desktop-bootstrap.subiquity-server` failing four times in two
seconds, but the unit's own journal was hidden behind the GUI's
once-a-second socket retries until the diag unit was taught to read
`journalctl -u` for that unit directly.

The traceback ends in the snap's bundled apport:

    RuntimeError: Could not determine system package manager.
                  Please file a bug and provide /etc/os-release!

apport decides the host's package manager from `{ID} | ID_LIKE.split()` and
requires `debian` in that set. The branding had written `ID_LIKE="ubuntu"`,
which is true and sufficient for humans and most tools — but not for apport.
`ID_LIKE` is now `"ubuntu debian"`: PuralvOS is a derivative of a derivative,
and Ubuntu itself ships `ID_LIKE=debian`. `ID` stays `puralvos`.

Verified in the brand7 boot: subiquity-server active (running), its two
processes visible in the cgroup, `/run/subiquity/socket` present, installer
GUI up, no traceback.

### Three self-test faults, three false FAILs

The brand3 boot showed tier 2 failing on a machine where every underlying
fact was correct. All three were measurement bugs, not image bugs:

| check | what it measured | why it failed | fix |
| --- | --- | --- | --- |
| `user-in-audio-group` | `GROUPS=$(id -nG ...)` | `GROUPS` is a bash special variable; assignments are ignored, so it read root's `0` | renamed `UGNAMES`; failure keeps the raw `id`/`getent` evidence |
| `pipewire-rlimits` | `/proc/PID/limits` with `/^Max real-time priority/` | the kernel spells it `Max realtime priority`; the pattern matched nothing and defaulted to 0 | correct pattern; doc updated (the kernel's spelling, no hyphen) |
| `pipewire-rt-policy` | `chrt -p` on the main thread, threshold 95 | PipeWire's main thread is SCHED_OTHER by design; RT lives on the data threads, and rtkit grants `rt.prio=20` | any thread with rtprio > 0 passes; the priority is reported, 95 explained as the JACK limit |

sddm and sddm-autologin do include `pam_limits.so`, and the limits are real:
`pipewire-rlimits` now reads `rtprio 95, memlock unlimited` from the running
daemon. The lesson recorded in the script: a check that contradicts another
check is a broken check until proven otherwise — `rtprio-limit` was passing
through a real PAM session while `GROUPS` insisted nobody was in `audio`.

### A diag unit that survives the boot

`tools/puralvos-diag` + `tools/puralvos-diag.service`, installed and enabled
only when `PURALVOS_DIAG=1`, gated at boot by `ConditionKernelCommandLine=
puralvos.diag=1`. It waits (360 s by default, `PURALVOS_DIAG_WAIT`), then
dumps user, groups, limits, PipeWire threads, the user's systemd units (via
`runuser` + `XDG_RUNTIME_DIR`, not as root, which had been reading the wrong
session), failed units, installer unit status/journal, `/run/subiquity`, snap
changes, and leftovers to the serial console. The cmdline pass that turns it
on is idempotent and strips stale flags on every build.

With it, the remaining tier 4 FAILs are attributable: audacity, blender, gimp
and friends are software-rendering timing in a VM, not missing binaries.
One inherited blemish: the stock `ubuntustudio-dark` icon theme's index.theme
has no `Size=` field for `places/scalable` or `places/128`, so GTK logs a
warning under the puralvos-dark rename; it is stock behaviour, not a rename
artifact.

### The ISO came out smaller than the one it derives from

The build had been shipping 319 MB of package-manager residue, a 120.8 MB
duplicate installer snap (hardlink broken by the layer merge), a generated
initrd in the rootfs and a second initrd on the ISO, and 616 MB of content
the base layer already hid behind whiteouts. Details, numbers and the method
are in `docs/ISO-SIZE.md`; the result:

| | bytes |
| --- | ---: |
| stock Ubuntu Studio 26.04.1 | 7 127 195 648 |
| PuralvOS, first bootable build | 7 751 788 544 |
| PuralvOS, final | 7 031 140 352 |

sha256 `805a8f1ced8a734238844c2c8e395857a28951f933084242ff3d6f62153c11fa`.
The final image is 92 MiB smaller than stock while also carrying TONE3000 in
four plugin formats and the realtime kernel's modules. Booted as brand7:
desktop at 59.9 s, every tier 0/2/3 check PASS, installer active.

### Whiteouts: the layer was hiding nothing

The branding relies on deletions in the top layer — Ubuntu Studio's
wallpapers, themes, grub menus, documentation. They were not deleted at
runtime. The build wrote AUFS-style `.wh.<name>` files, and overlayfs does
not know that convention: a whiteout in its lower layers is a character
device with major/minor 0/0. The `.wh.` files were packed into the layer,
ignored by the kernel, and every removed wallpaper and menu entry came back
in the merged view. The tier 3 checks caught it precisely because they read
the running system: `ubuntu-wallpapers-remain` and `grub-menus` failed on
an image whose build log said the files were gone.

The write path now does what overlayfs expects:

- `[ -c "$d/$b" ] || mknod "$d/$b" c 0 0` — a char-device tombstone per
  removed path, and stock tombstones already present in the tree are staged
  through tar untouched (they are regular entries to tar, not something to
  recreate);
- the "does this remove cover this path" test walks the *ancestors*, because
  mknod needs the parent directory to exist and the parent may itself be a
  tombstone;
- the single-remembered-path optimisation was removed: `gone.list` is sorted,
  but `usr/share/doc/dracut-config-generic` sorts between
  `usr/share/doc/dracut` and `usr/share/doc/dracut/config` (`-` is 0x2d,
  `/` is 0x2f), so one remembered path skipped the `dracut` tombstone and the
  build died with `mkdir: cannot create directory '.../usr/share/doc/dracut':
  File exists`;
- a parent-restore pass written for that failure was itself the bug and was
  deleted: re-creating directories at whiteout paths put empty directories
  back into the layer, and overlayfs merged them with the lower ones
  (themes/ubuntustudio reappeared as an empty tree);
- the existence test is `[ -e ] || [ -L ]`, so dangling symlinks are not
  mistaken for absent files.

Proof in the brand3 boot: `ubuntu-wallpapers-remain`, `grub-menus` and
`iso-label` all PASS against the merged live filesystem, the packed layer
holds 165 char-device whiteouts (including the stock ones) and zero `.wh.`
files.

Two checks were also repaired so the next failure of this kind reports itself:
`iso-label` falls back to `/cdrom/.disk/info` when the installed-system file
is absent, and `grub-menus` names the files it read instead of only saying
the result was wrong.
