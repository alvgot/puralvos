#!/usr/bin/env python3
"""Pick the real time kernel for PuralvOS by asking apt, not by guessing.

Why this exists
---------------
The obvious move is to hardcode ``linux-lowlatency``. On Ubuntu 26.04 that is
wrong, and wrong in a way that hides itself:

    linux-lowlatency  Depends: linux-image-generic (= 7.0.0-14.14)
                      Description: Complete Generic Linux kernel and headers
                                   with lowlatency boot configuration

It is the *generic* kernel with low latency boot arguments, not a real time
scheduler. Meanwhile:

    linux-realtime    Depends: linux-image-realtime (= 7.0.0-14.14.1)
                      Description: Complete Linux kernel for real-time systems

That is a PREEMPT_RT build. For an audio workstation running at real time
priority the difference is the whole point: a generic kernel with mitigations
disabled still preempts cooperatively, and will still glitch.

The same name means different things in different releases, which is why this
is discovered rather than written down. Asked about the two:

    Ubuntu 24.04 (noble)     linux-lowlatency -> linux-image-lowlatency
    Ubuntu 26.04 (resolute)  linux-lowlatency -> linux-image-generic

A hardcoded "linux-lowlatency" would have been correct on 24.04 and silently
wrong on 26.04, giving a machine that believed it had a real time kernel and
did not. An upstream rename should break the build loudly, not the audio.

So the kernel is discovered from apt at build time instead of being written
down. A hardcoded name is a bet that upstream keeps meaning the same thing by
it, and this is exactly the release where that bet would have lost.

Usage:
    kernel-select.py [--policy realtime|lowlatency] [--json] [--chroot DIR]

With no --chroot it queries this system's apt, which is what a build host
running resolute wants. With --chroot it queries the target system's apt.
"""

import argparse
import json
import os
import re
import subprocess
import sys

# The Ubuntu Studio release this image is built from. The -hwe- metapackages
# embed it and the STALE filter compares against it, so a rebase is one edit
# here.
RELEASE = "26.10"

# Candidate metapackages, best first. "realtime" is a real PREEMPT_RT build;
# "lowlatency" is the generic kernel with low latency boot arguments and is
# only acceptable as a fallback.
CANDIDATES = {
    "realtime": [
        "linux-realtime",
        "linux-realtime-hwe-" + RELEASE,
    ],
    "lowlatency": [
        "linux-lowlatency",
        "linux-lowlatency-hwe-" + RELEASE,
    ],
}

# Anything matching these is a stale or transitional package rather than a
# kernel worth booting. liblowlatency-hwe-24.04 currently Depends on
# linux-lowlatency-hwe-26.04, which is an obvious packaging leftover, and a
# kernel metapackage whose name names a different release than the one it pulls
# is not something to put on a machine.
STALE = re.compile(r"-hwe-(?!" + re.escape(RELEASE) + r"$)")


def apt(args, chroot=None):
    cmd = ["apt-cache"] + args
    if chroot:
        cmd = ["chroot", chroot] + cmd
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        return None, str(e)
    if r.returncode != 0:
        return None, (r.stderr or "").strip()
    return r.stdout, None


def candidate_available(pkg, chroot=None):
    """Return (available, version) for pkg."""
    out, err = apt(["policy", pkg], chroot)
    if err or not out:
        return None, None
    version = None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("Candidate:"):
            version = line.split(":", 1)[1].strip()
    if version is None or version == "(none)":
        return None, None
    return True, version


def depends_on_image(pkg, chroot=None):
    """The linux-image-* package this metapackage pulls in, if any.

    apt-cache depends prints lines like

        linux-realtime
          Depends: linux-image-realtime
          Recommends: linux-tools-6.8.1-1015-realtime

    so the name is looked for anywhere within a Depends: line, taking the
    first alternative of an "a | b" dependency. Anchoring the match at the
    start of the line finds nothing, which is how this first reported
    "image: unknown" and skipped the very check that tells a real time kernel
    from a generic one wearing the same name.
    """
    out, _ = apt(["depends", pkg], chroot)
    if not out:
        return None
    for line in out.splitlines():
        if "Depends:" not in line:
            continue
        for alt in line.split(":", 1)[1].split("|"):
            m = re.match(r"\s*(linux-image-[A-Za-z0-9._-]+)", alt)
            if m:
                return m.group(1)
    return None


def choose(policy, chroot=None, verbose=True):
    """Return (package, version, image_package, notes)."""
    notes = []
    order = CANDIDATES[policy] + CANDIDATES["realtime" if policy != "realtime" else "lowlatency"]

    for pkg in order:
        if STALE.search(pkg) and not pkg.endswith(RELEASE):
            notes.append("skipped %s: names a release this base is not" % pkg)
            continue
        ok, version = candidate_available(pkg, chroot)
        if not ok:
            notes.append("not available: %s" % pkg)
            continue
        image = depends_on_image(pkg, chroot)
        chosen = (pkg, version, image)

        if image and "realtime" not in image and policy == "realtime":
            notes.append("%s pulls %s, which is not a realtime image" % (pkg, image))
            if pkg != order[-1]:
                continue
        return chosen + (notes,)

    return None, None, None, notes + ["no realtime or lowlatency kernel found in the archive"]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--policy", choices=sorted(CANDIDATES), default="realtime",
                    help="realtime = PREEMPT_RT (default); lowlatency = generic+bootargs")
    ap.add_argument("--chroot", help="query this chroot's apt instead of the local one")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    pkg, version, image, notes = choose(args.policy, args.chroot)

    if args.json:
        print(json.dumps({"package": pkg, "version": version,
                          "image": image, "notes": notes}, indent=2))
        return 0 if pkg else 1

    print("real time kernel for PuralvOS (policy: %s)" % args.policy)
    print()
    if pkg:
        print("  package : %s" % pkg)
        print("  version : %s" % version)
        print("  image   : %s" % (image or "unknown"))
    else:
        print("  NONE FOUND")
    if notes:
        print()
        for n in notes:
            print("  note: %s" % n)
    return 0 if pkg else 1


if __name__ == "__main__":
    sys.exit(main())
