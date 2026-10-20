#!/usr/bin/env python3
"""Turn the installed package list into the copy that lives in docs/.

The list itself is the build artifact: base/puralvos/packages-installed.txt,
written by `make packages-all` out of the built rootfs, so it cannot drift
from what is installed. This tool wraps that list in the provenance header
the documentation wants and writes docs/PACKAGES-INSTALLED.md, so "what does
this image carry" has an answer inside the repository and not only in a
build directory.

Usage:
    make-packages-doc.py [--iso ISO_NAME] PAIRLIST > docs/PACKAGES-INSTALLED.md

PAIRLIST is the name<tab>version format report-packages.py --all writes.
"""

import argparse
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iso", default="",
                    help="ISO the list was read from, for the header")
    ap.add_argument("pairlist", help="name<tab>version lines, sorted")
    args = ap.parse_args()

    with open(args.pairlist, encoding="utf-8") as f:
        lines = [l.rstrip("\n") for l in f if l.strip()]
    n = len(lines)

    source = args.iso or "the most recent built image"
    sys.stdout.write(f"""# Installed packages

The complete package list of the PuralvOS Graphics live image: name and version, one
per line, tab separated and sorted, so it stays greppable.

    grep '^linux-image' docs/PACKAGES-INSTALLED.md
    grep -c . docs/PACKAGES-INSTALLED.md

Provenance: extracted from `/var/lib/dpkg/status` inside `{source}` — the
image's own database, not a list somebody wrote down. **{n} packages
installed.**

dpkg can also remember the configuration of a package that was removed, and
`dpkg-query -W` counts those, so the boot self test can report one more
package than this file lists. They are not installed; only their
configuration is remembered.

The same list, as the build artifact it is first written to, lives at
`base/puralvos/packages-installed.txt`. This copy lives in `docs/` so the
answer ships with the repository. Regenerate with `make packages-docs`.

## The complete list ({n})

```
""")
    for line in lines:
        sys.stdout.write(line + "\n")
    sys.stdout.write("```\n")


if __name__ == "__main__":
    main()
