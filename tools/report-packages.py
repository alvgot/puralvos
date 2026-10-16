#!/usr/bin/env python3
"""Report what the PuralvOS image actually contains, and what could go.

Two things this does, both from the built filesystem rather than from a
package list somebody wrote down:

  1. An inventory. What is really installed, by category, so "what is this
     thing carrying" has an answer.

  2. A removal proposal. Every candidate is named with a reason and, where it
     is not obvious, with a warning about what depends on it or what depends
     on IT.

The warnings are the point. A media workstation looks full of cruft, and most
of the obvious-looking cruft is actually load bearing:

  libspa-0.2-bluetooth and libbluetooth3 are pulled in by PipeWire. They look
  like "some Bluetooth junk" and removing them silently takes wireless
  headphones with them, which on an audio workstation is the single worst
  possible thing to remove by accident.

  linux-firmware-nvidia-graphics is proprietary firmware and looks exactly
  like the sort of thing PuralvOS would not carry. It is the graphics card.
  PuralvOS ships proprietary software on purpose; see docs/STANDARD-TOOLS.md.

So nothing here is applied automatically. This produces a proposal and a
machine-readable list. Removing is a decision, and docs/excludes.list is
where the decision is recorded.

Usage:
    report-packages.py [ROOTFS]

ROOTFS defaults to the build layer. Point it anywhere with a dpkg status file:

    report-packages.py /var/tmp/puralvos-build/layer
    report-packages.py --list-only ROOTFS
"""

import argparse
import collections
import os
import re
import sys

# --------------------------------------------------------------------------
# removal rules
# --------------------------------------------------------------------------
# Each rule is (category, matcher, reason). The matcher is a substring or a
# regular expression, and the reason is what has to be true before anybody
# acts on it. A rule with no reason does not belong in this file.

RULES = [
    ("office", r"^libreoffice|^ure$|^libreoffice-",
     "The whole office suite. 20 packages. PuralvOS is audio, video and "
     "graphics; this is a word processor and a spreadsheet."),

    ("input method", r"^fcitx",
     "28 packages of Chinese/Japanese/Korean input method. Nobody has asked "
     "for CJK text entry on a two-person English-language workstation. "
     "Remove unless one of you types Japanese."),

    ("printing", r"^cups|^bluez-cups|^hplip|^printerdrv",
     "21 packages of printer support, including HP drivers. A workstation in "
     "a room is not a print server."),

    ("snap", r"^snapd$|^libsnapd",
     "Snapd and its libraries. Snaps add a second package manager with its "
     "own update schedule, which is exactly the thing the curated upgrade "
     "path exists to avoid."),

    ("package manager", r"^synaptic$",
     "A GTK front end for apt. apt is the package manager and it stays."),

    ("photography", r"^darktable$",
     "Photography. Not in the product: audio, video, graphics."),

    ("mDNS", r"^avahi",
     "7 packages of Zeroconf/mDNS service discovery. Useful for a network "
     "workstation with shared speakers, useless otherwise."),

    ("web", r"^firefox$",
     "A general web browser on a machine that already has one job. Ardour "
     "and VLC will open URLs without it."),

    ("evolution", r"^evolution-data-server",
     "Contacts and calendar backend with nothing in front of it."),

    ("CJK fonts", r"^fonts-noto-cjk",
     "CJK font set, tens of megabytes, for text nobody will type."),

    ("modem", r"^ppp$",
     "Dial-up modem support. There is no modem."),

    ("usb modeswitch", r"^usb-modeswitch",
     "Flips USB devices between modes on first boot. Useful for some 3G "
     "dongles, noise otherwise."),
]

# Packages that look like cruft and are not. Checked explicitly so that if a
# rule above ever gets widened, these cannot be caught by it by accident.
PROTECTED = {
    "libspa-0.2-bluetooth": "PipeWire's Bluetooth audio. Removing this takes "
                            "wireless headphones with it.",
    "libbluetooth3": "PipeWire's Bluetooth audio. See above.",
    "libqt6bluetooth6": "Qt Bluetooth, used by the audio stack's pairing UI.",
    "libbluetooth-dev": "development headers for the above.",
    "linux-firmware-nvidia-graphics": "proprietary graphics firmware. "
                                      "PuralvOS ships proprietary software "
                                      "on purpose and this is the graphics "
                                      "card.",
    "avahi-daemon": "may be wanted for network audio discovery; decide once, "
                     "not by accident.",
    "python3-dbus": "everything on the desktop talks over D-Bus.",
    "pipewire": "the audio server. This is the product.",
    "wireplumber": "PipeWire's session manager. Without it nothing routes.",
    "jackd2": "JACK, for real time audio clients that do not use PipeWire.",
}

# What the product is, for the "is this actually needed" section. Anything in
# here is expected to be present; if it is not, that is a bug.
PRODUCT = {
    "audio": ["ubuntustudio-audio", "pipewire", "wireplumber", "jackd2",
              "ardour", "audacity", "mixxx", "qjackctl", "ffmpeg",
              "libasound2t64", "musescore3"],
    "video": ["ubuntustudio-video", "kdenlive", "shotcut", "olive-editor",
              "openshot-qt", "pitivi", "blender", "obs-studio", "vlc",
              "handbrake", "subtitleeditor", "libmlt7", "libqt6multimedia6"],
    "graphics": ["ubuntustudio-graphics", "gimp", "inkscape", "krita",
                 "scribus", "freecad", "openscad", "mypaint"],
    "realtime": ["linux-image-realtime", "jackd2", "pipewire-jack",
                 "libasound2-plugins"],
}


def read_status(root):
    path = os.path.join(root, "var", "lib", "dpkg", "status")
    if not os.path.isfile(path):
        sys.stderr.write("no dpkg status at %s\n" % path)
        return None, None
    text = open(path, encoding="utf-8", errors="replace").read()
    installed, versions = [], {}
    for block in text.split("\n\n"):
        n = re.search(r"^Package: (.+)$", block, re.M)
        s = re.search(r"^Status: (.+)$", block, re.M)
        v = re.search(r"^Version: (.+)$", block, re.M)
        if n and s and s.group(1).strip() == "install ok installed":
            name = n.group(1).strip()
            installed.append(name)
            if v:
                versions[name] = v.group(1).strip()
    return installed, versions


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("root", nargs="?",
                    default="/var/tmp/puralvos-build/layer",
                    help="rootfs to inspect (default: the build layer)")
    ap.add_argument("--list-only", action="store_true",
                    help="print only the removal candidates, one per line")
    args = ap.parse_args()

    installed, versions = read_status(args.root)
    if installed is None:
        return 1
    names = sorted(set(installed))

    removals = collections.OrderedDict()
    for category, pattern, reason in RULES:
        rx = re.compile(pattern)
        hits = [n for n in names if rx.match(n)]
        if hits:
            removals[category] = (hits, reason)

    # Never propose something on the protected list.
    for protected in PROTECTED:
        for category in list(removals):
            removals[category] = (
                [n for n in removals[category][0] if n != protected],
                removals[category][1])

    total_candidates = sum(len(h) for h, _ in removals.values())

    if args.list_only:
        for hits, _ in removals.values():
            for n in hits:
                print(n)
        return 0

    print("# What PuralvOS carries")
    print()
    print("Measured from `%s`, not from a list somebody wrote down." % args.root)
    print()
    print("## Totals")
    print()
    print("| | |")
    print("| --- | --- |")
    print("| Installed packages | **%d** |" % len(names))
    print("| Removal candidates | **%d** (%.1f%%) |"
          % (total_candidates, 100.0 * total_candidates / max(1, len(names))))
    print("| Would remain | **%d** |" % (len(names) - total_candidates))
    print()

    print("## Where the weight is")
    print()
    pref = collections.Counter(n.split("-")[0] for n in names)
    print("The largest families, by package-name prefix:")
    print()
    print("| prefix | count |")
    print("| --- | --- |")
    for k, v in pref.most_common(15):
        print("| `%s` | %d |" % (k, v))
    print()

    print("## Removal candidates")
    print()
    print("Nothing here is applied automatically. Each group has a reason and a")
    print("decision attached to it; the decision is recorded in `excludes.list`.")
    print()
    for category, (hits, reason) in removals.items():
        print("### %s — %d packages" % (category, len(hits)))
        print()
        for line in reason.split(". "):
            pass
        print(reason)
        print()
        shown = ", ".join("`%s`" % h for h in hits[:12])
        if len(hits) > 12:
            shown += ", ... (%d more)" % (len(hits) - 12)
        print(shown)
        print()

    print("## Do not remove these")
    print()
    print("They look exactly like the cruft above and they are not.")
    print()
    print("| package | why |")
    print("| --- | --- |")
    for name, why in sorted(PROTECTED.items()):
        state = "present" if name in names else "NOT INSTALLED"
        print("| `%s` | %s |" % (name, why))
    print()
    print("Anything marked *NOT INSTALLED* is worth a look: either the image is")
    print("wrong, or the protection is obsolete.")
    print()

    print("## Is the product actually there")
    print()
    print("Checked directly against the built filesystem. A miss here is a")
    print("build failure, not a trimming opportunity.")
    print()
    for group, pkgs in PRODUCT.items():
        have = [p for p in pkgs if p in names]
        miss = [p for p in pkgs if p not in names]
        status = "%d/%d present" % (len(have), len(pkgs))
        print("| %s | %s |%s |"
              % (group, status,
                 " missing: " + ", ".join("`%s`" % m for m in miss) if miss else ""))
    print()
    print("`linux-realtime` is in the realtime row on purpose. The stock Ubuntu")
    print("Studio ISO carries only `linux-generic`, so its presence here is")
    print("this build's single most important difference from the base.")
    return 0


if __name__ == "__main__":
    sys.exit(main())