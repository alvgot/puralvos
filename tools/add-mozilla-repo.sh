#!/bin/bash
# add-mozilla-repo.sh - make packages.mozilla.org usable, reproducibly.
#
# PuralvOS has no snap, and on Ubuntu 26.04 that means Firefox has to come from
# Mozilla's own apt repository. See apt/mozilla.sources for why.
#
# What this does, in the order that matters:
#
#   1. creates /etc/apt/keyrings if it does not exist. Modern apt reads keys
#      from there and nowhere else that matters. On a chroot unpacked from a
#      live image the directory may simply not be there, and writing the key
#      to the old location silently produces an unsigned source that apt
#      refuses much later with a confusing error.
#   2. fetches Mozilla's signing key and dearmours it to a fixed fingerprint.
#   3. VERIFIES that fingerprint before trusting it.
#
# Step 3 is the reason this is a script and not two lines in the build. A key
# fetched over HTTPS from a URL in the repository is only as trustworthy as
# that fetch. Pinning the fingerprint means a changed or substituted key fails
# the build instead of quietly becoming trusted.
#
# Usage:
#   add-mozilla-repo.sh [ROOTFS]
#
# ROOTFS defaults to /. Run it against a chroot before apt-get update.

set -euo pipefail

ROOT="${1:-}"
KEYRING="$ROOT/etc/apt/keyrings/mozilla.gpg"
KEYURL="https://packages.mozilla.org/apt/repo-signing-key.gpg"

# Mozilla's repository signing key fingerprint, cross-checked against Mozilla's
# own published instructions and several independent write-ups before being
# written down here.
#
# This value started out as a guess and the check below caught it. That is the
# argument for the check existing: it caught the author. It also means the
# fingerprint must never be taken from the same place the key comes from,
# because a substituted key serves its own fingerprint and would sail through.
# It has to come from somewhere independent.
EXPECTED_FPR="35BA A0B3 3E9E B396 F59C A838 C0BA 5CE6 DC63 15A3"

say() { printf '  %s\n' "$*"; }
die() { printf 'add-mozilla-repo: %s\n' "$*" >&2; exit 1; }

[ -d "$ROOT/etc/apt" ] || die "no apt in $ROOT/etc/apt. Point this at a rootfs."
mkdir -p "$ROOT/etc/apt/sources.list.d"

mkdir -p "$ROOT/etc/apt/keyrings" "$ROOT/etc/apt/sources.list.d" "$ROOT/etc/apt/preferences.d"
say "keyring directory: $ROOT/etc/apt/keyrings"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "fetching $KEYURL"
if command -v curl >/dev/null 2>&1; then
	curl -fsSL --retry 3 -o "$tmp/key.asc" "$KEYURL" \
		|| die "could not fetch the signing key"
elif command -v wget >/dev/null 2>&1; then
	wget -q -O "$tmp/key.asc" "$KEYURL" \
		|| die "could not fetch the signing key"
else
	die "neither curl nor wget is available"
fi

say "dearmouring"
if command -v gpg >/dev/null 2>&1; then
	gpg --batch --yes --dearmor -o "$tmp/mozilla.gpg" "$tmp/key.asc" \
		|| die "gpg could not dearmour the key"
else
	# A dearmoured key is binary OpenPGP; an ASCII .asc is acceptable to apt
	# directly on recent versions, so this is not fatal.
	cp "$tmp/key.asc" "$tmp/mozilla.gpg"
	say "note: gpg not available, using the ASCII key as-is"
fi

say "checking the fingerprint"
ACTUAL=$(gpg --show-keys --with-colons "$tmp/mozilla.gpg" 2>/dev/null \
	| awk -F: '/^fpr:/ {print $10; exit}' \
	| sed 's/\([0-9A-F]\{4\}\)/\1 /g; s/ $//' | tr 'a-f' 'A-F')
if [ -z "$ACTUAL" ]; then
	die "could not read a fingerprint from the fetched key. Refusing to trust it."
fi
say "  expected: $EXPECTED_FPR"
say "  actual:   $ACTUAL"
[ "$ACTUAL" = "$EXPECTED_FPR" ] \
	|| die "fingerprint mismatch. The key at $KEYURL is not Mozilla's. Not trusting it."

install -m 0644 "$tmp/mozilla.gpg" "$KEYRING"
say "installed $KEYRING, fingerprint verified"

# Pinning. Without this the Ubuntu archive wins the version comparison and you
# get the archive's `firefox`, which is the transitional snap wrapper, and
# PuralvOS is back on snap through the front door after excluding it through
# the back one. Mozilla's own instructions call this out and they are right.
cat > "$ROOT/etc/apt/preferences.d/mozilla" <<'PINEOF'
# Mozilla's repository wins for its own package.
#
# The Ubuntu archive also has a package called firefox, and in 26.04 it is a
# transitional wrapper whose only job is to install the snap. Without this pin
# apt may prefer that one.
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
PINEOF
say "installed the apt preference pinning Mozilla's repository"

if [ -n "$ROOT" ]; then
	# Copy the source in too, so a chroot is complete rather than half set up.
	if [ -f "$(dirname "$(dirname "$0")")/apt/mozilla.sources" ]; then
		install -m 0644 "$(dirname "$(dirname "$0")")/apt/mozilla.sources" \
			"$ROOT/etc/apt/sources.list.d/mozilla.sources"
		say "installed the mozilla.sources entry"
	fi
fi

say "done"