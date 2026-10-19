#!/bin/bash
# Upgrade the PuralvOS curated package set, and nothing else.
#
# The rule PuralvOS is built around:
#
#   packages PuralvOS installed  -> always kept up to date from the archive
#   packages the user installed  -> left alone
#
# Why this is not just "apt upgrade": apt has no record of who installed what.
# dpkg tracks that a package is installed, not whether it came from our task
# set or from the user typing a command, so a plain upgrade sweeps both. On a
# machine whose promise is "these are the packages we tested", an untested
# upgrade is exactly the failure we are trying to avoid.
#
# So the curated set is written down (see tasks.list and the generated
# manifest), and upgrades are driven from that list.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${1:-$HERE/build/curated-packages.txt}"
REPO="${PURALVOS_REPO:-stonking}"

if [ ! -r "$MANIFEST" ]; then
    echo "curated package manifest not found: $MANIFEST" >&2
    echo "generate it with: make manifest" >&2
    exit 1
fi

# Only-upgrade, never install: if a curated package has been removed by the
# user on purpose, this puts it back without being asked. Use "restore" for
# that on purpose.
pkgs=()
while read -r p; do
    case "$p" in ''|\#*) continue ;; esac
    dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null | grep -q "^installed$" || continue
    pkgs+=("$p")
done < "$MANIFEST"

if [ "${#pkgs[@]}" -eq 0 ]; then
    echo "no curated packages are installed; nothing to upgrade"
    exit 0
fi

echo "==> ${#pkgs[@]} curated packages, upgrading from $REPO"

echo "==> refreshing the package cache"
apt-get update -q

echo "==> what would change (dry run)"
apt-get install --only-upgrade --dry-run "${pkgs[@]}" 2>&1 | grep -E "^(Inst|Conf|The following|[0-9]+ upgraded)" || true

if [ "${PURALVOS_APPLY:-0}" != "1" ]; then
    echo
    echo "dry run only. Set PURALVOS_APPLY=1 to actually upgrade."
    exit 0
fi

echo "==> upgrading"
apt-get install --only-upgrade -y "${pkgs[@]}"

echo "==> done. Anything outside this list was not touched."
