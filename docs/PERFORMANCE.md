# Performance

The request was that PuralvOS be very fast as an OS. "Fast" is not a
specification, so this file turns it into numbers that can fail a build.

## The uncomfortable part first

There are two different things being asked for, and they do not always want the
same trade.

**Low xruns** — audio must not glitch. This wants the real-time kernel, RT
priority, no CPU frequency scaling, no USB autosuspend, no deep C-states, a
big enough JACK memory pool.

**Fast boot, low idle load** — this wants the opposite. Save power aggressively,
defer everything, start less.

They directly conflict. `intel_pstate` in `powersave` mode makes boot and idle
feel great and will produce xruns the moment someone opens a 24-track session
and moves a fader. You cannot have both from the same settings.

**Decision: this is a workstation, it is plugged in, real time wins.** Frequency
scaling goes to `performance`, autosuspend goes off for the audio interface,
C-states go as low as the board allows. Boot time is optimised by *not
running services*, not by power management. This is the right trade for a
machine that spends its life with a session open, and it is the wrong trade for
a laptop on a train.

The one place it costs something: **battery life on a laptop will be worse than
Ubuntu Studio's.** That is accepted, not overlooked.

## Measuring RT priority, and why `setpriv` cannot

`ulimit -r` has to be read through a PAM session, which in practice means
`su - USER -c 'ulimit -r'`. Anything else measures the wrong thing.

`pam_limits` is a PAM **session** module. It applies limits at the moment a
session is opened, by matching the user against the groups in
`/etc/security/limits.d/*.conf`. `setpriv` does not open a session: it re-execs
with different credentials and inherits the limits of whatever called it. So

```sh
setpriv --reuid=1000 --regid=1000 --init-groups bash -c 'ulimit -r'
```

prints **0** on a perfectly configured image and 0 on a badly configured one.
It never reads `/etc/security/limits.d` at all. The self test used exactly this
for several builds, reported `rtprio is 0, audio WILL glitch under load`, and
that failure was ignored — correctly — because it had never once been capable
of reporting anything else. A check that cannot pass is worse than no check.

`su`, `login`, `sddm` and `sddm-autologin` all carry `session required
pam_limits.so`, so a real login gets the limits. That is the measurement, and it
is what tier 2 of `tools/puralvos-selftest` now does.

The strongest evidence is still not the number but the process: tier 2 also
reads `Max realtime priority` (the kernel's spelling — no hyphen) and
`Max locked memory` out of `/proc/<pipewire pid>/limits`, which is the
kernel's own view of the audio daemon and depends on no tooling at all.

## Targets

Measured on the installed system, not the live session. Numbers, not adjectives.

| Metric | Target | How it is measured |
| --- | --- | --- |
| **JACK xruns** | **0** | `xrun` counter in `jack_control status`, over a 10 minute session with the load below |
| JACK buffer, no xruns | 128 frames (2.67 ms @ 48 kHz) | same run |
| Kernel | `PREEMPT_RT` | `uname -v`, must contain the RT flag |
| RT priority granted | yes | `su - $USER -c 'ulimit -r'`, and `chrt -p $$` inside an audio app |
| Boot to desktop | < 8 s | `systemd-analyze`, NVMe, warm |
| Login to usable | < 3 s | manual |
| Idle RAM | < 900 MB | `free -m` at idle, no apps |
| Install ISO size | < 3 GB | the saving from stripping is a number, not a feeling |
| Suspend to resume | < 3 s | on AC |

**The xruns target is the one that matters.** Everything else is a convenience.
An audio workstation that drops out under load is not a workstation, and boot
time is not what anyone is thinking about when they are mixing.

## Why the kernel on the ISO is not enough

Recorded in [BASELINE.md](BASELINE.md), repeated here because it is the single
most likely way to ship a false promise:

The stock Ubuntu Studio ISO carries `linux-generic`, `linux-image-generic`,
`linux-headers-generic`, and nothing else. **No `linux-lowlatency`, no
`linux-realtime`.** The RT kernel is installed into the *installed* system by
the Ubuntu Studio installer, not present on the image you boot to try things.

So a live PuralvOS that does not add the kernel at build time is a generic
kernel wearing the name. `linux-realtime` is resolved at build time by
`tools/kernel-select.py` — never hardcoded, because the name and the version
differ per release.

## The steps that are not packages

The most important section in this file. A workstation can install perfectly,
every application can be present, the mixer can open, and audio can still
glitch under load because none of this happened.

Every step below is configuration of a stock package — a file in `/etc`, never
a patched binary and never a rebuilt package. That is what keeps
`apt full-upgrade` safe on a running system at any time; see
[PACKAGES.md](PACKAGES.md).

### 1. Limits and group

From `ubuntustudio-installer-helper`'s `fix` action:

Ubuntu Studio already ships this. `/usr/sbin/ubuntustudio-installer-helper fix`
copies `30-ubuntustudio-audio.conf` into `/etc/security/limits.d/`, granting

```
@audio     rtprio 95   memlock unlimited
@pipewire  rtprio 95   memlock unlimited
```

and adds the invoking user to the `audio` group. PuralvOS uses that stock
helper rather than writing its own — see
[ARCHITECTURE.md](ARCHITECTURE.md) for why calling it needs a wrapper.

**`tools/puralvos-rt-fix`** wraps it, and then checks the two things it was
supposed to do. The check is not redundant: the helper exits 0 having skipped
the audio group when `PKEXEC_UID` is unset, which is what happens when a build
calls it directly as root. That check is verified, in ARCHITECTURE.md.

Verified from inside the built image by reading the limits file and the group
membership. Not assumed, because assuming it is how you get a system that
looks right and sounds wrong.

### 2. CPU governor

Ubuntu ships `intel_pstate` in `powersave`. Wrong for real time audio.

```
/etc/default/cpufrequtils          governor=performance
```

### 3. Disable USB autosuspend on the audio interface

The single most common cause of "it glitches when I move the mouse".

```
/etc/udev/rules.d/99-puralvos-audio.rules
  ACTION=="add", SUBSYSTEM=="usb", ATTR{bConfigurationValue}=="1", \
    ATTR{idVendor}=="...", MODE="0666", \
    ATTR{autosuspend}="-1"
```

Vendor ID filled in at build time from the interface actually present.

### 4. Kernel command line

```
preempt=full  threadirqs  tsc=reliable  intel_pstate=disable  isolcpus=managed_irq,domain,thread
nohz_full=managed_irq,domain,thread
```

Isolating the housekeeping CPUs is what keeps the audio thread from being
preempted by a network interrupt. It costs some scheduler throughput, which on
a workstation doing media work is a good deal.

### 5. Memory

```
vm.swappiness=1                  # do not swap, ever, during a session
vm.max_map_count=262144          # JACK and large sessions
```

Huge pages are configured by JACK itself, which does this correctly. Do not
hand-roll it.

## What the strip-down buys

Stripping is a performance change before it is a size change:

- fewer autostarts, so faster boot and less idle RAM
- fewer services, so fewer chances for a timer to fire during a take
- fewer packages on the critical update path

None of these replace the RT configuration above. They make it easier to hit.

## How this gets checked

`tools/puralvos-selftest`, which runs **inside** a booted PuralvOS image and
answers, on a real system:

- is the kernel actually PREEMPT_RT
- is RT priority actually granted, as the user, through the real limits path
- is memlock actually unlimited
- does the limits file exist and grant rtprio
- is the user in `audio`
- is a PipeWire data thread actually real time (rtkit grants 20; the 95 in
  limits.d is what JACK clients schedule themselves with)
- what is the CPU governor, the swappiness, the kernel command line
- are there still Ubuntu's wallpapers, splash and login screen on disk

Tiers 0, 1 and 4 are the ordinary ones. **Tier 2 is the one that matters here**:
it is the only part that can catch a machine which looks perfect and cannot do
real time audio, which is exactly the failure the whole design is about.

Run it on the base as well as on PuralvOS. If Ardour misbehaves after
stripping and the base was never measured, a day disappears blaming work that
did not cause it.

### Two things it will not do

**It will not report an xrun count it did not earn.** `jack-xruns` needs a
JACK server on a real device. Without one it SKIPs with the reason. A self
test that reports a pass it did not earn is how a broken workstation ships,
and that is worse than a gap in the report.

**It will not report 40 broken applications because there is no display.**
Without an X server every launch would time out, and every application would
look broken when the truth is that they are untested. It says that once and
stops.

## Not yet done

- [ ] boot-time baseline measured on the base, so stripping has something to beat
- [ ] `puralvos-xrun-bench`, the tool that actually measures xruns on real hardware
- [ ] the branding checks turned on for real, once the image exists to check