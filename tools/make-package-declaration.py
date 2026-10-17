#!/usr/bin/env python3
"""Turn tasks.list into the declaration the self test checks.

puralvos-selftest verifies that every package we say we ship is really
installed. It reads that declaration from a plain list at
/usr/local/share/puralvos/selftest-packages.txt, because that is a file the
image can carry and the tool can read without parsing a build script.

Deriving it from tasks.list is the whole point: tasks.list is the single source
of truth for what PuralvOS ships, and a hand kept copy of it here would drift
the first time somebody adds a task. Nothing gets to be declared by hand.

Two kinds of line matter and they are treated differently:

  metapackages   ubuntustudio-audio and friends. These name whole disciplines,
                 and the real test is not "is this installed" but "did the
                 applications inside it get installed". dpkg can only answer
                 the first, so it is reported as a metapackage presence check
                 and the application check is left to tier 4, which actually
                 launches the things.

  packages       individual applications and libraries. These are checked
                 directly, and a missing one is a build failure.

Usage:
    make-package-declaration.py [-o OUTPUT] [tasks.list]

Default output is stdout, so it can be inspected before being installed.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, os.pardir)


def is_comment(line):
    s = line.strip()
    return (not s) or s.startswith("#")


def load_tasks(path):
    """Split tasks.list into metapackages and packages, using its own sections.

    tasks.list is prose with package names inside it, organised under
    headings like:

        # --- the three tasks that define the product ---

    The heading is what says what kind of entry it is. The first pass here
    guessed from the package name and got it wrong: it filed
    ubuntustudio-audio, which is a whole discipline, in with the settings
    packages as though it were one library. Checking the name is not how you
    tell, and neither is counting on an "=" suffix that this file never uses.
    The file already says. Read the file.

    Everything indented under a "#" is prose and is skipped, which is how
    ubuntustudio-photography, publishing and wallpapers stay out: they are
    named in the "deliberately absent" section precisely so nobody adds them
    by accident, and a parser that ignored comments would add all three.

    Returns (metapackages, packages, sections) in file order.
    """
    # a bare package name: starts with a lowercase letter, no spaces, may
    # contain + - _ .
    name_re = re.compile(r"^[a-z0-9][a-z0-9+._-]*$")
    # "# --- anything ---"
    section_re = re.compile(r"^#\s*-{3,}\s*(.+?)\s*-{3,}\s*$")

    # The section whose entries name whole disciplines rather than individual
    # packages. Matched on the words actually used in tasks.list, so if it is
    # reworded this reports zero metapackages and the difference is visible
    # rather than silent.
    meta_sections = ("define the product",)

    meta, pkgs, sections = [], [], []
    current = ""

    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            stripped = line.strip()

            m = section_re.match(stripped)
            if m:
                current = m.group(1).strip()
                sections.append(current)
                continue

            if is_comment(line):
                continue

            body = stripped
            if body.startswith(("- ", "* ", "+ ")):
                body = body[2:].strip()
            if "=" in body:
                body = body.split("=", 1)[0].strip()

            # skip anything that is prose rather than a bare package name
            if not body or " " in body or not name_re.match(body):
                continue

            if any(k in current.lower() for k in meta_sections):
                meta.append(body)
            else:
                pkgs.append(body)

    def uniq(seq):
        seen, out = set(), []
        for x in seq:
            if x not in seen:
                seen.add(x)
                out.append(x)
        return out

    return uniq(meta), uniq(pkgs), sections


# tasks.list names what we WANT. This maps that to the package that actually
# CARRIES it, which is not always the same name, and the difference matters
# because this file is checked against dpkg.
#
# linux-realtime -> linux-image-realtime
#
# tasks.list says `linux-realtime`, and that is the right thing to want: it is
# the metapackage that tracks the real time kernel. But a live image must not
# install it, because it Depends on linux-headers-realtime — about 1.7 GB of
# kernel headers, for a machine with nobody to compile a module on. So the
# build installs linux-image-realtime, the image package, which is the kernel
# itself, and purges the metapackage.
#
# Which means declaring `linux-realtime=pkg` produces a self test that fails on
# every image this build makes, because the package it names is one the build
# deliberately removes. The declaration has to name what ships.
#
# So: the intent stays in tasks.list and this table carries the one translation
# between intent and implementation. It is here rather than hidden in the build
# because this file is the thing the self test reads, and a mismatch between
# them is exactly the kind of failure that reads as a packaging bug.
CARRIED_BY = {
    # tasks.list wants the metapackage, which tracks the real time kernel.
    # The build installs the image package instead, because the metapackage
    # Depends on ~1.7 GB of kernel headers and a live image has nobody to
    # compile a module. The declaration has to name what SHIPS, because the
    # self test checks this file against dpkg.
    "linux-realtime": "linux-image-realtime",
}


def main(argv):
    out = None
    args = []
    i = 1
    while i < len(argv):
        if argv[i] in ("-o", "--output"):
            i += 1
            out = argv[i]
        else:
            args.append(argv[i])
        i += 1

    path = args[0] if args else os.path.join(REPO, "tasks.list")
    if not os.path.isfile(path):
        sys.stderr.write("no such file: %s\n" % path)
        return 1

    meta, pkgs, sections = load_tasks(path)

    lines = [
        "# PuralvOS package declaration.",
        "#",
        "# Generated from tasks.list by tools/make-package-declaration.py.",
        "# Do not edit this file by hand: it is checked by puralvos-selftest and",
        "# a hand edited copy would drift the first time a task is added.",
        "#",
        "# Format is <name>=<kind>, one per line. The kind tells the self test",
        "# how strictly to check it.",
        "#",
        "#   meta  a discipline metapackage. Checked as present; the",
        "#         applications it contains are checked by tier 4, which",
        "#         actually launches them.",
        "#   pkg   an individual package. Checked as installed. A miss is",
        "#         a build failure.",
        "",
    ]

    for name in meta:
        lines.append("%s=meta" % name)
    for name in pkgs:
        lines.append("%s=pkg" % CARRIED_BY.get(name, name))

    # Say what was translated, so the difference between tasks.list and the
    # declaration is visible in the build output and not only in this file.
    for want, have in sorted(CARRIED_BY.items()):
        if want in pkgs:
            sys.stderr.write(
                "  %s is declared as %s:\n"
                "    the metapackage pulls in kernel headers a live image has no\n"
                "    use for, and the declaration is checked against dpkg\n"
                % (want, have))

    text = "\n".join(lines) + "\n"

    if out:
        os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
        with open(out, "w", encoding="utf-8") as fh:
            fh.write(text)
        sys.stderr.write("wrote %s\n" % out)
        sys.stderr.write("  %d metapackages, %d packages\n" % (len(meta), len(pkgs)))
        sys.stderr.write("  from %d section(s) in %s\n" % (len(sections), path))
        # Say it out loud when a section produced nothing. A section that
        # silently yields zero entries is the shape of a parser bug, and it is
        # much cheaper to notice here than three builds later.
        if not meta:
            sys.stderr.write(
                "  WARNING: no metapackages parsed. The section headings in\n"
                "  tasks.list are what classify them; if they were reworded,\n"
                "  update meta_sections in this script.\n")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))