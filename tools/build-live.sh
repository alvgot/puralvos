#!/bin/bash
# build-live.sh - build the PuralvOS live image from the stock Ubuntu Studio ISO.
#
# Standard tools throughout, per docs/STANDARD-TOOLS.md: unsquashfs/mksquashfs
# for the casper layer, apt in a chroot for the kernel and packages, grub.cfg
# for the menu, xorriso for the ISO. Nothing here reimplements a distribution
# tool.
#
# Why rebuild the stock ISO instead of running live-build:
#
#   live-build is the standard tool and it is what this project should use if
#   it ever produces a generic Ubuntu live image. But the Ubuntu Studio ISO is
#   not built by stock live-build in a form we can drive: it is three casper
#   layers with ubiquity-casper on top, GRUB boots a fixed /casper/vmlinuz and
#   /casper/initrd, and the lb_config available here is the Debian 3.0 variant
#   with --debian-installer, not Ubuntu's ubiquity flavour config.
#
#   Rebuilding a verified-good ISO is the standard way derivatives are made,
#   and it starts from an image already proven to boot on this exact hardware
#   class. Every other route starts from nothing and hopes.
#
# What this adds to the stock image:
#
#   1. linux-realtime, the real PREEMPT_RT kernel from the Ubuntu archive.
#      The stock ISO carries only linux-generic, so a PuralvOS live image that
#      does not add this is a generic kernel wearing the name. This is the
#      single most important thing in the build.
#   2. Our branding: wallpapers, the mark, os-release, boot menu.
#   3. The real time audio limits file, which no package installs by itself.
#   4. A first boot hook that puts the live user in the audio group.
#   5. Removal of the photography and publishing tasks.
#
# Usage:
#   build-live.sh [--keep] [--no-kernel] [--author-only]
#
#   --keep        do not delete the work directory on success
#   --no-kernel   build the branding only, leave the generic kernel alone
#                 (faster; for testing the rebrand, not the kernel)
#   --author-only skip everything up to the repack and re-author the ISO from
#                 an existing $WORK/iso tree. The tree has to have been built
#                 by an earlier run of this script; it is not unpacked or
#                 modified in the layers, only repacked and written out.

set -euo pipefail

# say and die are used by pick_work below, which runs while WORK is still being
# decided, so they have to exist before it. Defining them further down is why
# a machine without 45 GB free used to print "die: command not found" and carry
# on with WORK empty: the failure message was the thing that failed, and the
# real error, "no filesystem found with 45 GB free", never appeared.
say() { printf '\n=== %s\n' "$*"; }
die() { printf 'build-live: %s\n' "$*" >&2; exit 1; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_ISO="$REPO/base/ubuntustudio-26.04.1-desktop-amd64.iso"
# The work directory needs room for the ISO, the unpacked layer and the chroot
# all at once: about 40 GB. Pick a filesystem that has it rather than trusting
# a fixed path, because the machine this runs on may not have the disk the
# build was written on.
pick_work() {
	local cand best="" avail
	for cand in "${PURALVOS_WORK:-}" /var/tmp /srv /mnt /tmp; do
		[ -n "$cand" ] || continue
		mkdir -p "$cand" 2>/dev/null || continue
		avail=$(df -BG --output=avail "$cand" 2>/dev/null | tail -1 | tr -dc '0-9')
		[ -z "$avail" ] && continue
		if [ "$avail" -ge 45 ]; then best="$cand/puralvos-build"; break; fi
	done
	if [ -z "$best" ]; then
		die "no filesystem found with 45 GB free for the build work directory. Free some space, or set PURALVOS_WORK to a filesystem that has it (--author-only needs far less)."
	fi
	echo "$best"
}
WORK="${PURALVOS_WORK:-$(pick_work)}"
OUT="${PURALVOS_OUT:-$REPO/out}"
KEEP=0
WITH_KERNEL=1
AUTHOR_ONLY=0

for a in "$@"; do
	case "$a" in
		--keep) KEEP=1 ;;
		--no-kernel) WITH_KERNEL=0 ;;
		--author-only) AUTHOR_ONLY=1 ;;
		*) echo "unknown option: $a" >&2; exit 2 ;;
	esac
done

# The live layer is never opened by this build; see the layer notes below.
LAYER=casper/minimal.standard.live.squashfs

[ -f "$BASE_ISO" ] || die "base ISO missing: $BASE_ISO (run: make base)"

say "verifying the base before touching it"
( cd "$REPO/base" && grep -F "$(basename "$BASE_ISO")" CHECKSUMS | sha256sum -c - ) \
	|| die "base ISO checksum does not match CHECKSUMS. Refusing to build on it."

say "brand assets"
python3 "$REPO/tools/make-brand.py" "$REPO/brand/assets" >/dev/null
python3 "$REPO/tools/make-package-declaration.py" \
	-o "$REPO/base/puralvos/selftest-packages.txt" 2>/dev/null || true
ls -1 "$REPO/brand/assets" | sed 's/^/  /'

mkdir -p "$OUT"

# The three casper layers' working directories. These belong outside
# build_tree because --author-only repacks the top layer out of $FULL: the
# diff is cut from the merged tree, not from $WORK/iso. Declared inside the
# function they would be unset on exactly the path that needs them.
BASE_UNION="$WORK/base-union"
FULL="$WORK/layer"

# Menu entries whose Exec names a binary this image does not have.
#
# Three of them, all shipped by packages that are installed, all broken:
#
#   vim.desktop                        Exec=vim, and only vim.tiny is installed
#   software-properties-lxqt.desktop   Exec=lxqt-sudo, and LXQt is not installed
#   software-properties-drivers-lxqt.desktop   same
#
# These are upstream packaging artefacts, not something this build did: the
# base image has them too. But they are on the menu of an image whose menu is
# supposed to be the curated set, and a menu entry that cannot start is a
# defect whether or not anybody has clicked it yet.
#
# The entries are HIDDEN rather than deleted. dpkg owns them, so deleting them
# leaves the package database claiming a file that is not there, and reinstalling
# or upgrading the package silently puts a broken entry back on the menu.
# NoDisplay=true is the freedesktop way to say "not in the menu" and it
# survives an upgrade, because the upgrade rewrites the file.
fix_desktop_entries() {
	# shellcheck source=lib/desktop-exec.sh
	. "$REPO/tools/lib/desktop-exec.sh"
	local hidden=0 d name bin
	for d in "$FULL/usr/share/applications"/*.desktop; do
		[ -f "$d" ] || continue
		grep -qE '^Type=Application' "$d" || continue
		grep -qE '^(Hidden|NoDisplay)=true' "$d" && continue
		grep -qE '^Exec=' "$d" || continue
		# $FULL, not the host. Without it this asks the build machine whether
		# /usr/bin/ardour exists, and hides every application in the product
		# because the build machine is not a media workstation.
		desktop_exec_present "$d" "$FULL" && continue
		name=$(sed -n 's/^Name=\(.*\)$/\1/p' "$d" | head -1)
		[ -n "$name" ] || name=$(basename "$d" .desktop)
		bin=$(desktop_exec "$d")
		sed -i '1i # Hidden by PuralvOS: the executable this entry names is not installed.\n# See tools/build-live.sh:fix_desktop_entries\nNoDisplay=true' "$d"
		hidden=$((hidden + 1))
		echo "  hidden '$name' (Exec '$bin')"
	done
	echo "  $hidden menu entr$( [ "$hidden" = 1 ] && echo y || echo ies ) hidden for a missing executable"
}

# The TONE3000 plugin, the one piece of the image that is a download.
#
# TONE3000 (tone3000.com) is the official free NAM player: it browses and
# plays Neural Amp Modeler captures and impulse responses straight from the
# catalogue. It is the reason this image can promise a guitar rig without a
# DAW, so it ships as part of the audio set rather than as an optional extra.
#
# It is NOT a distribution package on this archive, which fixes every other
# decision here:
#
#   * The payload is the Linux x64 release tarball from the project's own
#     GitHub releases, pinned by version AND by sha256. A build that cannot
#     fetch or verify it stops; it does not ship without the plugin.
#
#   * The official install.sh targets ~/.vst3, ~/.lv2, ~/.clap, ~/.local/bin
#     and the user's XDG data dir. A live image installed for the user who
#     boots it is the wrong shape: the plugin has to be on the system paths
#     every host scans, so the formats go to /usr/lib/{vst3,lv2,clap} and the
#     standalone to /usr/bin. Same files, same layout inside them, installed
#     once for every user instead of once per user.
#
#   * Factory presets land in /etc/skel/.config/TONE3000/Presets/Factory, the
#     same path the plugin's own installer writes into the home directory,
#     seeded through skel because casper creates the live user from skel.
#     A user who installs the system gets them the same way.
#
#   * The desktop entry's Exec must be absolute; the tarball's own installer
#     says so in a comment and generates it at install time. This one is
#     generated here the same way, for /usr/bin/TONE3000.
#
# The version is pinned rather than "latest" on purpose: a plugin update is a
# change to the product and gets a build log line, not a silent fetch.
T3K_VERSION="v0.0.12"
T3K_SHA256="c45ea5d64e6eef991b14f1883a4249ed1a883253db1a9d9f0605e0540aba5fc7"
T3K_TARBALL="TONE3000-${T3K_VERSION}-linux-x64.tar.gz"
T3K_URL="https://github.com/tone-3000/tone3000-plugin/releases/download/${T3K_VERSION}/${T3K_TARBALL}"

install_tone3000() {
	say "TONE3000 plugin (the NAM player this image ships)"
	local cache="$WORK/downloads" tar="$WORK/downloads/$T3K_TARBALL"
	local tmp rel got
	mkdir -p "$cache"

	if [ -f "$tar" ]; then
		echo "  using cached $T3K_TARBALL"
	else
		echo "  fetching $T3K_URL"
		if command -v curl >/dev/null 2>&1; then
			curl -fsSL --retry 3 -o "$tar.part" "$T3K_URL" \
				|| die "could not download the TONE3000 plugin.
     File:    $T3K_URL
     The image is supposed to ship it, so this build stops here rather than
     produce an image that silently misses its NAM player. Rerun when the
     network allows, or drop the tarball at $tar by hand."
		elif command -v wget >/dev/null 2>&1; then
			wget -q -O "$tar.part" "$T3K_URL" \
				|| die "could not download the TONE3000 plugin (wget). See $T3K_URL"
		else
			die "neither curl nor wget is on this machine, so the TONE3000 plugin
     cannot be fetched. Install one of them."
		fi
		mv "$tar.part" "$tar"
	fi

	got=$(sha256sum "$tar" | cut -d' ' -f1)
	if [ "$got" != "$T3K_SHA256" ]; then
		die "the TONE3000 tarball does not match the pinned checksum.
     File:     $tar
     Expected: $T3K_SHA256
     Got:      $got
     Delete the cached file and rerun if the download was interrupted; if the
     checksum still differs, the release changed and T3K_VERSION/T3K_SHA256
     in this script have to be updated together, deliberately."
	fi
	echo "  sha256 ok: $T3K_SHA256"

	tmp=$(mktemp -d "$WORK/.t3k.XXXXXX")
	tar -xzf "$tar" -C "$tmp" \
		|| die "the TONE3000 tarball did not extract. The cached copy at $tar is corrupt."
	rel=$(find "$tmp" -maxdepth 1 -mindepth 1 -type d | head -1)
	[ -n "$rel" ] || { rm -rf "$tmp"; die "extracted TONE3000 tarball has no directory"; }
	[ -d "$rel/TONE3000.vst3" ] && [ -d "$rel/TONE3000.lv2" ] \
		&& [ -f "$rel/TONE3000.clap" ] && [ -f "$rel/TONE3000" ] \
		|| { rm -rf "$tmp"; die "the TONE3000 tarball does not contain the VST3, LV2,
     CLAP and standalone payload this step installs."; }

	# VST3 and LV2 are bundles (directories); CLAP is a single shared object;
	# the standalone is an executable. Same modes the official installer uses:
	# CLAP 0644 because the loader dlopens it, not execs it.
	rm -rf "$FULL/usr/lib/vst3/TONE3000.vst3" "$FULL/usr/lib/lv2/TONE3000.lv2"
	install -d "$FULL/usr/lib/vst3" "$FULL/usr/lib/lv2" "$FULL/usr/lib/clap"
	cp -a "$rel/TONE3000.vst3" "$FULL/usr/lib/vst3/"
	cp -a "$rel/TONE3000.lv2" "$FULL/usr/lib/lv2/"
	install -m 0644 "$rel/TONE3000.clap" "$FULL/usr/lib/clap/TONE3000.clap"
	install -Dm0755 "$rel/TONE3000" "$FULL/usr/bin/TONE3000"
	echo "  plugin formats: /usr/lib/vst3, /usr/lib/lv2, /usr/lib/clap (STD paths, every DAW scans them)"
	echo "  standalone:     /usr/bin/TONE3000"

	# Factory presets, in skel, exactly where the plugin's installer puts them
	# in a home directory. Replace-don't-overlay like the official installer.
	if compgen -G "$rel/factory-presets/*.t3kpreset" >/dev/null; then
		install -d "$FULL/etc/skel/.config/TONE3000/Presets/Factory"
		rm -f "$FULL/etc/skel/.config/TONE3000/Presets/Factory"/*.t3kpreset
		install -m 0644 "$rel/factory-presets"/*.t3kpreset \
			"$FULL/etc/skel/.config/TONE3000/Presets/Factory/"
		echo "  factory presets: $(ls "$rel/factory-presets" | wc -l) -> /etc/skel/.config/TONE3000/Presets/Factory"
	fi

	# Desktop entry + icon, generated here for the /usr/bin path.
	install -d "$FULL/usr/share/applications" \
		"$FULL/usr/share/icons/hicolor/512x512/apps"
	install -m 0644 "$rel/tone3000.png" \
		"$FULL/usr/share/icons/hicolor/512x512/apps/tone3000.png"
	cat > "$FULL/usr/share/applications/tone3000.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=TONE3000
GenericName=NAM Amp and IR Player
GenericName[de]=NAM-Verstärker- und IR-Player
Comment=Play NAM captures and IRs straight from TONE3000
Comment[de]=NAM-Captures und IRs direkt von TONE3000 spielen
Exec=/usr/bin/TONE3000
Icon=tone3000
Terminal=false
Categories=AudioVideo;Audio;Music;
Keywords=NAM;guitar;bass;amp;ir;tone;
StartupWMClass=TONE3000
EOF
	echo "  desktop entry: /usr/share/applications/tone3000.desktop"

	# Pinned to the default panel's favourites, so "installed by default" is
	# true on the panel and not only in the menu. The panel is built at boot
	# by ubuntustudio-panel-refresh from a list it only keeps entries of that
	# actually exist; adding the entry to that list is enough.
	PR="$FULL/usr/sbin/ubuntustudio-panel-refresh"
	if [ -f "$PR" ] && ! grep -q 'tone3000.desktop' "$PR"; then
		sed -i 's|\[6\]="carla.desktop"|[6]="carla.desktop"\n[7]="tone3000.desktop"|' "$PR"
		echo "  panel: tone3000 pinned in ubuntustudio-panel-refresh favourites"
	fi

	# Resolve the standalone's libraries against the image being built, not
	# against this machine, which is also not a media workstation. ldd runs
	# the loader with LD_TRACE_LOADED_OBJECTS and needs nothing mounted.
	if command -v chroot >/dev/null 2>&1; then
		unresolved=$(chroot "$FULL" ldd /usr/bin/TONE3000 2>/dev/null |
			grep 'not found' || true)
		if [ -n "$unresolved" ]; then
			die "the TONE3000 standalone has unresolved libraries IN THE IMAGE:
$(printf '%s\n' "$unresolved" | sed 's/^/     /')
     The runtime set is GTK3, ALSA, fontconfig, X11 and libcurl; one of them
     is missing from the layer. Fix the package list; a plugin that cannot
     load is worse than one that was never installed."
		else
			echo "  ldd: all libraries resolve inside the image"
		fi
	fi

	rm -rf "$tmp"
}

# Everything that makes the live tree PuralvOS rather than Ubuntu Studio.
#
# Called by build_tree, and by --author-only directly. It is a separate function
# for one reason: --author-only steps over build_tree entirely, and before this
# existed it carried its own inline copy of the branding. Two copies of the same
# edits is how the two paths came to produce different images from the same
# repository.
#
# Idempotent, deliberately. --author-only re-runs it against a tree that already
# carries every one of these edits, so anything here that assumed a pristine
# input would have to be able to cope with its own output.
brand_the_tree() {
say "branding"
ASSETS="$REPO/brand/assets"

# The wallpaper cleanup is recursive, and it has to remove a DIRECTORY.
#
# `rm -f /usr/share/backgrounds/*ubuntu*` matches nothing here, and the reason is
# the shape of the stock image: Canonical's wallpapers are not loose files in
# that directory, they are a directory of them.
#
#     /usr/share/backgrounds/ubuntustudio/ubuntustudio_2604.jpg
#     /usr/share/backgrounds/ubuntustudio/2604_glenn-carstens-peters-stylus.jpg
#     ... 11 files
#
# `rm -f` on a directory is a no-op with the diagnostic sent to /dev/null, so
# the glob matched the directory, the removal silently did nothing, and the
# eleven files underneath survived into the image. Then the self test reported
#
#     tier3 FAIL ubuntu-wallpapers-remain 11 file(s) ... still say Ubuntu
#
# on an image whose branding step had printed "wallpapers installed" and
# returned success. The check was right and the build was wrong.
#
# So: find every path under the background directories that carries Ubuntu's
# name in ANY of its components and remove it, directories included. One glob,
# one -depth-ordered pass, and it cannot miss a nesting level.
for bgdir in "$FULL/usr/share/backgrounds" "$FULL/usr/share/wallpapers"; do
	[ -d "$bgdir" ] || continue
	find "$bgdir" -depth -iname '*ubuntu*' -print0 2>/dev/null |
	while IFS= read -r -d '' victim; do
		echo "  removing $(basename "$victim")"
		rm -rf "$victim"
	done
	# A file Ubuntu's packages link to by a name that does not itself contain
	# "ubuntu" would still be missed, so check what is left rather than assume.
	remaining=$(find "$bgdir" -type f \( -iname '*ubuntu*' -o -iname '*studio*' \) 2>/dev/null | wc -l)
	[ "$remaining" -eq 0 ] \
		|| die "$remaining Ubuntu-branded wallpaper(s) survive in $bgdir.
     Something is putting them there with a name that does not say ubuntu;
     look before building again:
$(find "$bgdir" -type f \( -iname '*ubuntu*' -o -iname '*studio*' \) 2>/dev/null | sed 's/^/       /')"
done
install -m 0644 "$ASSETS/wallpaper-4k.png"   "$FULL/usr/share/backgrounds/puralvos-wallpaper.png"
install -m 0644 "$ASSETS/wallpaper-1080p.png" "$FULL/usr/share/backgrounds/puralvos-wallpaper-1080p.png"
echo "  wallpapers installed: $(find "$FULL/usr/share/backgrounds" -maxdepth 1 -type f | wc -l) in the top directory, $(find "$FULL/usr/share/backgrounds" -mindepth 2 -type f 2>/dev/null | wc -l) in subdirectories"

install -Dm0644 "$ASSETS/mark.svg" "$FULL/usr/share/puralvos/mark.svg"
install -Dm0644 "$ASSETS/wordmark.svg" "$FULL/usr/share/puralvos/wordmark.svg"

# os-release. This is what every tool reports the system as, and Ubuntu and
# Ubuntu Studio are Canonical trademarks, so both have to go.
#
# On Debian and Ubuntu /etc/os-release is a SYMLINK to /usr/lib/os-release.
# sed -i on it replaces the symlink with a regular file, which is why the
# sed below also has to write /usr/lib/os-release: that is the file every tool
# actually reads, through the symlink or not. Branding only /etc/os-release
# looks correct in the build log and leaves the running system reporting
# Ubuntu, which is exactly what the first built image did.
if [ -f "$FULL/etc/os-release" ]; then
	# Both files, and the symlink is put back afterwards.
	#
	# /etc/os-release on this image is a symlink to ../usr/lib/os-release. That
	# means:
	#
	#   1. /usr/lib/os-release is the file to write. It is the one systemd,
	#      dpkg and `hostnamectl` read.
	#   2. sed -i on /etc/os-release follows the symlink and rewrites
	#      /usr/lib/os-release, replacing the symlink with a regular copy.
	#      Works, but it is an accident, and it leaves the tree in a state
	#      that no longer matches the base.
	#
	# So: write both explicitly, then restore the symlink, then check the
	# file that matters rather than the one that was convenient.
	#
	# Delimiter is # for all of these. With the usual s/// the replacement
	# "https://..." contains an unescaped slash, which ends the command early
	# and fails with "unknown option to `s'" pointing at a character in the
	# middle of a URL.
	# ID_LIKE is not decoration. apport — which the installer snap bundles and
	# imports at startup — decides the host's package manager from
	# `{ID} | ID_LIKE.split()` and raises "Could not determine system package
	# manager. Please file a bug and provide /etc/os-release!" unless
	# "debian" is in that set. ID_LIKE="ubuntu" alone was enough to kill
	# subiquity-server at every boot: the installer window said "Something
	# went wrong" and /run/subiquity never appeared, while snapd sat there
	# happily. Ubuntu itself ships ID_LIKE=debian; every Debian derivative
	# carries it, and a derivative of a derivative has both. This is the line
	# between rebranding and breaking the ecosystem the packages expect.
	brand_os_release() {
		sed -i -e 's#^NAME=.*#NAME="PuralvOS"#' \
		       -e 's#^PRETTY_NAME=.*#PRETTY_NAME="PuralvOS 26.04.1 LTS"#' \
		       -e 's#^ID=.*#ID=puralvos#' \
		       -e 's#^ID_LIKE=.*#ID_LIKE="ubuntu debian"#' \
		       -e 's#^HOME_URL=.*#HOME_URL="https://github.com/alvgot/puralvos"#' \
		       -e 's#^SUPPORT_URL=.*#SUPPORT_URL="https://github.com/alvgot/puralvos/issues"#' \
		       -e 's#^BUG_REPORT_URL=.*#BUG_REPORT_URL="https://github.com/alvgot/puralvos/issues"#' \
		       -e 's#^VERSION_CODENAME=.*#VERSION_CODENAME=puralvos#' \
		       "$1"
	}
	OSREL="$FULL/usr/lib/os-release"
	[ -f "$OSREL" ] || OSREL="$FULL/etc/os-release"
	brand_os_release "$OSREL"
	if [ "$OSREL" = "$FULL/etc/os-release" ]; then
		echo "  warning: no /usr/lib/os-release in this image, branded /etc/os-release"
	else
		brand_os_release "$FULL/etc/os-release"
		# Put the symlink back if that is how it arrived.
		if [ "$(readlink "$FULL/etc/os-release" 2>/dev/null)" = "" ]; then
			rm -f "$FULL/etc/os-release"
			ln -s ../usr/lib/os-release "$FULL/etc/os-release"
		fi
	fi
	sed -i -e 's/^DISTRIB_ID=.*/DISTRIB_ID=PuralvOS/' \
	       -e 's/^DISTRIB_NAME=.*/DISTRIB_NAME="PuralvOS"/' \
	       -e 's/^DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION="PuralvOS 26.04.1 LTS"/' \
	       -e 's/^DISTRIB_CODENAME=.*/DISTRIB_CODENAME=puralvos/' \
	       "$FULL/etc/lsb-release" 2>/dev/null || true
	BRANDED=$(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' "$OSREL")
	echo "  os-release: $BRANDED"
	case "$BRANDED" in
		PuralvOS*) : ;;
		*) die "os-release still reports '$BRANDED'; the branding did not take" ;;
	esac
fi

# The login banner. /etc/issue is base-files' and prints
#
#     Ubuntu 26.04.1 LTS
#
# on every virtual console, which is the first thing anyone sees on a machine
# with no graphical boot and the thing the serial console of every verification
# run prints above the login prompt. The self test does not read it, which is
# exactly why it has to be done here: nothing else was going to.
#
# \n and \l are the standard escapes (hostname, tty); they are printed by
# agetty, not by a shell, so they stay. \S is deliberately absent — it would
# read the live session's release from the wrong file again.
for issue in "$FULL/etc/issue" "$FULL/etc/issue.net"; do
	[ -e "$issue" ] || continue
	printf 'PuralvOS 26.04.1 LTS \\n \\l\n' > "$issue"
done
echo "  issue: $(head -1 "$FULL/etc/issue" 2>/dev/null)"

# The ISO's own label, which the boot menu and installer show. The FIRST
# WHITESPACE-SEPARATED TOKEN of this file is not decoration: casper reads it
# as the flavour, and with FLAVOUR unset in its casper.conf (this image's is),
# casper sets BOTH the live username and the hostname to that token,
# lowercased. So this line is where the live user's name comes from, and
# LIVE_USER further down reads it back rather than guessing. The comment in
# the base casper.conf says it in as many words: "USERNAME and HOSTNAME as
# specified above won't be honoured and will be set to flavour string".
#
# The rest of the line is not free-form either, whatever the first draft of
# this file assumed ("PuralvOS 26.04.1 LTS - Live amd64" looked tidy and cost
# a whole verification boot). The desktop installer — ubuntu-desktop-
# bootstrap, the window the live session opens by itself — parses this file
# too, and it wants the stock shape:
#
#     <Flavour> <version> <LTS?> "<codename>" - Release amd64 (<date>)
#
# Its Flutter binary reads the quoted codename (a "get:codeName" symbol and
# the dynamic "installationTypeTPMInfo<CodeName>" message keys live in
# libapp.so) and a line without it is not a display problem: the installer
# fails its parse, shows "Something went wrong" instead of the install
# screens, and the reason is nowhere on screen. The base image's line is
# "Ubuntu-Studio 26.04.1 LTS \"Resolute Raccoon\" - Release amd64 (20260826)";
# this keeps every field of that except the name, so casper still gets
# "puralvos", casper-bottom's cut -f3 still finds "LTS", and the installer
# finds its codename.
if [ -f "$WORK/iso/.disk/info" ]; then
	printf 'PuralvOS 26.04.1 LTS "Resolute Raccoon" - Release amd64 (%s)\n' \
		"$(date -u +%Y%m%d)" > "$WORK/iso/.disk/info"
	echo "  iso label: $(cat "$WORK/iso/.disk/info")"
fi

say "boot menu"
G="$WORK/iso/boot/grub/grub.cfg"
if [ -f "$G" ]; then
	# The trailing /^grub_platform$/ delete removes a bare command line that
	# the stock Ubuntu Studio grub.cfg carries before its `if [ "$grub_platform"
	# = "efi" ]` block. In a consistent GRUB it is a no-op; when the boot core
	# and the modules disagree it is what prints
	#     error: can't find command `grub_platform'
	# across the top of the menu before anything else goes wrong. The line is
	# not ours and carries no information, so it does not survive the rebrand.
	sed -i \
	  -e 's/Try or Install Ubuntu Studio/PuralvOS Live — install or try out/' \
	  -e 's/Ubuntu Studio (safe graphics)/PuralvOS Live (safe graphics)/' \
	  -e 's/^set timeout=.*/set timeout=5/' \
	  -e '/^grub_platform$/d' \
	  "$G"
	echo "  menu entries now:"
	grep -E '^\s*menuentry' "$G" | sed 's/^/    /'
fi

say "instrumenting the boot menu for verification"
# Put the serial console and the self test on every kernel command line.
#
# Both are ADDED here. Nothing else in this script adds them.
#
# The stock Ubuntu Studio ISO has no console= argument on its kernel lines:
#
#     linux  /casper/vmlinuz  --- quiet splash
#     linux  /casper/vmlinuz nomodeset  --- quiet splash
#
# and the awk below only matches lines that ALREADY carry console=ttyS0, so it
# silently did nothing on a freshly extracted ISO. The flag that made the last
# few builds verifiable was in the working tree from a hand edit of grub.cfg
# made by hand at some point, and it survived only because --author-only reuses
# $WORK/iso. A build from scratch produced an image that could not report its
# own kernel, which is the one thing this instrumentation exists to do.
#
# So: add console=ttyS0 to every linux line, then put puralvos.selftest=1
# immediately after it. One awk pass, idempotent, so re-authoring a tree that
# already carries both changes nothing.
#
# console=ttyS0 is the build's verification channel: with it, the whole boot
# including uname is readable from the serial port, and scripts/kvmtest.sh
# captures it. It goes on the KERNEL's side of the `---`, i.e. before it; after
# the `---` it would be passed to the live system as an argument to init.
#
# puralvos.selftest=1 makes /usr/local/bin/puralvos-selftest run at boot and
# write uname, /etc/os-release and every test result to ttyS0. It is the only
# way to answer "is the running kernel actually PREEMPT_RT" from outside the
# machine: the ISO has no serial getty and casper creates the live user during
# the boot, so there is no shell to run uname in. ConditionKernelCommandLine=
# in the unit matches it on the kernel side of the split too.
#
# Applied to every entry rather than just the first. The first entry is what an
# unattended run boots, but the second one is what a person picks when the first
# one does not work, and a build that only instruments its own default path
# cannot tell which entry a screenshot came from. "Safe graphics" has nomodeset
# between the two, so anchoring on the kernel line and not on the arguments
# matches both.
if [ -f "$G" ]; then
	GF="$G.selftest.$$"
	awk '
		/^[[:space:]]*linux[[:space:]]/ {
			# Drop both arguments first, however many copies are here. Two
			# "add it if missing" passes stack otherwise:
			#
			#   console=ttyS0,115200n8 puralvos.selftest=1 puralvos.selftest=1 ...
			#
			# Harmless to the kernel, and a sign the file is not what anyone
			# thinks it is.
			gsub(/[[:space:]]*console=ttyS0(,115200n8)?/, "")
			gsub(/[[:space:]]*puralvos\.selftest=1/, "")
			# Now put exactly one of each back, immediately before the "---"
			# that separates the kernel arguments from those of init, and at
			# the end of the line if there is no such separator.
			if (index($0, "---")) {
				sub(/[[:space:]]*---/,
				    " console=ttyS0,115200n8 puralvos.selftest=1 ---")
			} else {
				sub(/[[:space:]]*$/,
				    " console=ttyS0,115200n8 puralvos.selftest=1")
			}
		}
		{ print }
	' "$G" > "$GF" && mv "$GF" "$G"

	echo "  kernel command line, every entry:"
	grep -E '^[[:space:]]*linux ' "$G" | sed 's/^/    /'

	# Check each line individually, because "at least one line has it" is a
	# much weaker claim than "every line has it", and it is the one that has
	# been failing silently.
	NENTRIES=$(grep -cE '^[[:space:]]*linux[[:space:]]' "$G")
	NCONSOLE=$(grep -cE '^[[:space:]]*linux[[:space:]].*console=ttyS0,115200n8' "$G")
	NSELFTEST=$(grep -cE '^[[:space:]]*linux[[:space:]].*puralvos\.selftest=1' "$G")
	[ "$NCONSOLE" -eq "$NENTRIES" ] \
		|| die "$NCONSOLE of $NENTRIES kernel command lines have console=ttyS0.
     An image built this way cannot be verified from the serial port."
	[ "$NSELFTEST" -eq "$NENTRIES" ] \
		|| die "$NSELFTEST of $NENTRIES kernel command lines have puralvos.selftest=1.
     An image built this way cannot report its own kernel."
	grep -qE 'puralvos\.selftest=1[[:space:]]+puralvos\.selftest=1' "$G" \
		&& die "a kernel command line has puralvos.selftest=1 more than once"
	grep -qE 'console=ttyS0[^ ]*[[:space:]]+console=ttyS0' "$G" \
		&& die "a kernel command line has console=ttyS0 more than once"
	echo "  all $NENTRIES entries carry console=ttyS0 and puralvos.selftest=1"

	# Diagnostic builds (PURALVOS_DIAG=1) add puralvos.diag=1 next to the
	# self test flag; puralvos-diag.service is condition gated on it. The
	# pass always runs, so switching the flag off on a reused tree removes
	# a stale puralvos.diag=1 instead of carrying it into a clean build.
	GF="$G.diag.$$"
	awk -v on="${PURALVOS_DIAG:-0}" '
		/^[[:space:]]*linux[[:space:]]/ {
			gsub(/[[:space:]]*puralvos\.diag=1/, "")
			if (on == "1") sub(/puralvos\.selftest=1/,
			                   "puralvos.selftest=1 puralvos.diag=1")
		}
		{ print }
	' "$G" > "$GF" && mv "$GF" "$G"
	if [ "${PURALVOS_DIAG:-0}" = "1" ]; then
		NDIAG=$(grep -cE '^[[:space:]]*linux[[:space:]].*puralvos\.diag=1' "$G")
		[ "$NDIAG" -eq "$NENTRIES" ] \
			|| die "$NDIAG of $NENTRIES kernel command lines have puralvos.diag=1."
		echo "  all $NENTRIES entries also carry puralvos.diag=1 (diagnostic build)"
	fi
fi

# --------------------------------------------------------------------------
# the real time audio step, which no package performs by itself
# --------------------------------------------------------------------------
say "real time audio limits"
# Take the limits file out of the image being built, not out of /usr/share on
# the build machine. Ubuntu Studio ships its own copy inside the live layer at
# /usr/share/ubuntustudio-installer/30-ubuntustudio-audio.conf, and that is
# the file that belongs in /etc/security/limits.d: it carries the comment
# explaining the two grants and the commented-out nice lines, and it is the
# one the package will later compare against.
#
# Reading it from the build host instead is how this step came to be a no-op:
# /usr/share/ubuntustudio-installer does not exist on a machine that is not
# running Ubuntu Studio, the `install` failed, the `|| cat` heredoc wrote a
# four line file, and the step reported success either way.
RTLIMITS=""
for c in "$FULL/usr/share/ubuntustudio-installer/30-ubuntustudio-audio.conf" \
         "$FULL/usr/share/ubuntustudio/30-ubuntustudio-audio.conf" \
         /usr/share/ubuntustudio-installer/30-ubuntustudio-audio.conf; do
	[ -f "$c" ] && { RTLIMITS="$c"; break; }
done
if [ -n "$RTLIMITS" ]; then
	install -Dm0644 "$RTLIMITS" "$FULL/etc/security/limits.d/30-ubuntustudio-audio.conf"
	echo "  from $RTLIMITS"
else
	die "no 30-ubuntustudio-audio.conf in the image or on this machine.
     This is the real time audio step; write the file by hand into
     $FULL/etc/security/limits.d/ if the image really does not carry it."
fi
LIMITS="$FULL/etc/security/limits.d/30-ubuntustudio-audio.conf"
# pam_limits parses four space separated fields and no equals sign, so the
# patterns below are of the shape the file actually has.
#
# \s+ between the item and the value, not a single space. Ubuntu's own file
# aligns its columns:
#
#     @audio   -  rtprio     95
#                ^^^^^^^^^ five spaces
#
# and a literal ' ' there does not match, so this check died on a perfect copy
# of Ubuntu's own limits file. The self test had exactly the same bug, fixed in
# one place and not the other — which is the whole argument for one
# implementation, and this is the second time it has bitten.
for g in '@audio\s+-\s+rtprio\s+9[0-9]' \
         '@audio\s+-\s+memlock\s+unlimited' \
         '@pipewire\s+-\s+rtprio\s+9[0-9]' \
         '@pipewire\s+-\s+memlock\s+unlimited'; do
	grep -qE "^\s*$g" "$LIMITS" \
		&& echo "  ok   $(printf '%s' "$g" | sed 's/\\s\+/ /g')" \
		|| { echo "  MISSING in $LIMITS: $g" >&2
		     echo "  The file is:" >&2; sed 's/^/    /' "$LIMITS" >&2
		     die "the real time audio grants are not all there"; }
done
echo "  $(grep -cE '^\s*@(audio|pipewire)\s+-\s+(rtprio|memlock)' "$LIMITS") rtprio/memlock grants"

install -Dm0755 "$REPO/tools/puralvos-rt-fix" \
	"$FULL/usr/local/bin/puralvos-rt-fix"
install -Dm0755 "$REPO/tools/puralvos-selftest" \
	"$FULL/usr/local/bin/puralvos-selftest"
# The unit lives in the repo so it is versioned with the tool it runs. It goes
# in /etc/systemd/system, and the copy that was previously installed by hand
# under /lib is removed so the two cannot disagree.
install -Dm0644 "$REPO/tools/puralvos-selftest.service" \
	"$FULL/etc/systemd/system/puralvos-selftest.service"
rm -f "$FULL/lib/systemd/system/puralvos-selftest.service"

# An installed unit that was never enabled does not run at boot, which is how
# a fully fixed self test ended up not running at all in the image it was
# fixed for. systemctl enable inside the chroot is the offline path: no init
# is there to talk to and it just writes the multi-user.target.wants symlink.
# The unit's ConditionKernelCommandLine=puralvos.selftest=1 still keeps it a
# no-op on every boot that does not ask for it.
chroot "$FULL" systemctl enable puralvos-selftest.service >/dev/null 2>&1 \
	|| die "could not enable puralvos-selftest.service in the chroot.
     Without it the self test never runs at boot and the image cannot report
     what it is."
# -L, not -e. systemctl writes the wants symlink with an ABSOLUTE target
# (/etc/systemd/system/puralvos-selftest.service), and -e follows symlinks —
# out of the build root, into the build machine's own /etc, where that file
# does not exist. So the symlink the previous line just created perfectly
# correctly is "a dangling symlink" to every test that dereferences it, and
# this check failed a build whose self test was, in fact, enabled. It checked
# whether the HOST could dereference a path in the tree; -L checks what was
# actually asked: that the link exists at all.
[ -L "$FULL/etc/systemd/system/multi-user.target.wants/puralvos-selftest.service" ] \
	|| die "puralvos-selftest.service is still not enabled after systemctl enable.
     The boot time self test would silently not run."
# And the target has to be there too, checked inside the tree.
[ -f "$FULL$(readlink "$FULL/etc/systemd/system/multi-user.target.wants/puralvos-selftest.service")" ] \
	|| die "the self test wants symlink points at a unit that is not in the tree.
     Inside the layer the link would dangle and the boot time self test would
     silently not run."
echo "  self test unit: enabled (runs only with puralvos.selftest=1)"

# The desktop-entry parser the self test uses, so there is one implementation
# of it in the shipped image rather than one in the image and another in the
# repository that can disagree. See tools/lib/desktop-exec.sh for why that
# matters: the two copies had drifted and between them reported OpenLP, Ardour
# and VLC as broken.
install -Dm0644 "$REPO/tools/lib/desktop-exec.sh" \
	"$FULL/usr/local/lib/puralvos/desktop-exec.sh"

# puralvos-diag: the boot time evidence collector, only for diagnostic builds.
#
# Built with PURALVOS_DIAG=1 in the environment, and even then it does nothing
# unless the kernel command line says puralvos.diag=1, which the grub.cfg pass
# above adds for the same builds. A production image does not carry the unit at
# all. See tools/puralvos-diag for the failure this exists to explain.
if [ "${PURALVOS_DIAG:-0}" = "1" ]; then
	install -Dm0755 "$REPO/tools/puralvos-diag" \
		"$FULL/usr/local/bin/puralvos-diag"
	install -Dm0644 "$REPO/tools/puralvos-diag.service" \
		"$FULL/etc/systemd/system/puralvos-diag.service"
	chroot "$FULL" systemctl enable puralvos-diag.service >/dev/null 2>&1 \
		|| die "could not enable puralvos-diag.service in the chroot"
	[ -L "$FULL/etc/systemd/system/multi-user.target.wants/puralvos-diag.service" ] \
		|| die "puralvos-diag.service did not get enabled"
	echo "  diag unit: enabled (runs only with puralvos.diag=1)"
else
	echo "  diag unit: not built (PURALVOS_DIAG=1 adds it)"
fi

# The declared package list. The self test's tier 1a verifies that every
# package tasks.list promises is really installed, and it cannot do that
# without this file: it read DECL from /usr/local/share/puralvos/, which the
# build never created, so the check reported "cannot verify the curated set" on
# every boot of every image.
#
# Generated from tasks.list at the top of this script, so it cannot describe a
# different package set from the one the product is defined as.
if [ -s "$REPO/base/puralvos/selftest-packages.txt" ]; then
	install -Dm0644 "$REPO/base/puralvos/selftest-packages.txt" \
		"$FULL/usr/local/share/puralvos/selftest-packages.txt"
	echo "  declared package list: $(grep -cvE '^\s*(#|$)' "$REPO/base/puralvos/selftest-packages.txt") packages"
else
	die "base/puralvos/selftest-packages.txt is missing or empty.
     Generate it with: make packages
     Without it the self test cannot verify that the curated set is installed."
fi

# The live user does not exist in the image. casper creates it at first boot,
# and a stock casper squashfs has no /etc/passwd line for it at all (checked:
# `grep ^ubuntu: /etc/passwd` matches nothing in the minimal layer). So
#
#     if grep -qE "^${u}:" "$FULL/etc/passwd"; then usermod -aG audio "$u" ...
#
# never runs, and the live session comes up unable to do real time audio with
# nothing anywhere reporting a problem.
#
# The usermod in it was wrong too, in a way that reaches outside the build:
# `-d` is shadow's --home, not a chroot. Run on the build machine
# `usermod -aG audio ubuntu -d "$FULL"` renames the HOME DIRECTORY OF A REAL
# USER ON THE HOST. There is no --chroot option on usermod; a user database
# inside a build root is only ever edited through `chroot`.
#
# So: take the name casper will use, and write the group file directly. The
# name casper will use is not baked into the image at all — it is the flavour.
# casper.conf in the initrd has FLAVOUR unset, and by its own documented rule
# that makes casper rename the live user AND the hostname to the flavour
# string, lowercased. The flavour is the first token of .disk/info, which this
# script wrote a few lines up, so the writer and the reader of that fact are
# the same file.
#
# It read "LIVE_USER=ubuntu" here for several builds, and that was believed
# because casper.conf also ships export USERNAME="ubuntu" — but that is the
# line the comment in casper.conf itself says will not be honoured. What
# confirmed the real name was the boot: the serial console prints the hostname
# above the login prompt, and it printed "puralvos", not "ubuntu". The live
# user was never added to the audio group because the group line said ubuntu
# and the running user was puralvos; the "Ubuntu Studio Audio Configuration"
# dialog that opened by itself on the first live session was the machine
# saying so.
LIVE_USER=$(sed -n '1s/[[:space:]].*//p' "$WORK/iso/.disk/info" | tr '[:upper:]' '[:lower:]')
[ -n "$LIVE_USER" ] \
	|| die "$WORK/iso/.disk/info is missing or empty, so the live user's name
     cannot be derived. casper takes it from that file's first token."
case "$LIVE_USER" in
	*[!a-z0-9]*|'') die "$WORK/iso/.disk/info starts with '$LIVE_USER', which is
     not a valid user name. casper would create the login under it (or fail
     to), and the audio group entry below would not match." ;;
esac
if grep -q "^audio:" "$FULL/etc/group"; then
	# Rewrite the member list: drop every member with no /etc/passwd entry,
	# then add the live user. A stale name here is not inert, and neither is
	# usermod, which cannot do this at all for a user that does not exist yet.
	OLD=$(awk -F: '/^audio:/{print $4}' "$FULL/etc/group")
	NEW=""
	for m in ${OLD//,/ }; do
		[ "$m" = "$LIVE_USER" ] && continue
		if ! grep -q "^${m}:" "$FULL/etc/passwd"; then
			echo "  dropping stale audio group member '$m': no /etc/passwd entry"
			continue
		fi
		NEW="${NEW:+$NEW,}$m"
	done
	NEW="${NEW:+$NEW,}$LIVE_USER"
	awk -F: -v OFS=: -v members="$NEW" '
		$1 == "audio" { $4 = members }
		{ print }
	' "$FULL/etc/group" > "$FULL/etc/group.puralvos-new"
	if [ "$(awk -F: '/^audio:/{print $4}' "$FULL/etc/group.puralvos-new")" = "$LIVE_USER" ]; then
		cat "$FULL/etc/group.puralvos-new" > "$FULL/etc/group"
		rm -f "$FULL/etc/group.puralvos-new"
	else
		rm -f "$FULL/etc/group.puralvos-new"
		die "could not rewrite the audio group in $FULL/etc/group"
	fi
fi

if [ "$(awk -F: '/^audio:/{print $4}' "$FULL/etc/group")" = "$LIVE_USER" ]; then
	echo "  live user $LIVE_USER is in the audio group"
else
	echo "  WARNING: live user $LIVE_USER is NOT in the audio group" >&2
	echo "           audio group is now: $(awk -F: '/^audio:/{print $4}' "$FULL/etc/group")" >&2
fi

say "desktop entry hygiene"
fix_desktop_entries

say "live session display manager"
# The live session has to come up on its own.
#
# casper creates the live user during the boot and writes its own autologin
# settings, and on this image that works: the last booted image came up with
# sddm-greeter-qt running under a session and no X server belonging to a
# session of its own, and the self test reported "no X server after 240s".
#
# So this is here to make the one thing explicit rather than inherited: the
# live user logs in automatically, into Plasma, on X11.
#
# X11 rather than Wayland is deliberate, and it is the reason for two different
# checks in the self test. Wayland needs a seat and a compositor with a DRM
# device; under KVM with -vga std there is no DRM render node, so the greeter
# cannot start a Wayland session at all and the desktop can never come up. An
# X11 session needs neither, so it is testable headlessly and it is what the
# base image's own default session was before 26.04 moved it. Real hardware
# with a real GPU gets the same session and it behaves the same way.
if [ -f "$FULL/etc/sddm.conf.d" ] || [ -d "$FULL/etc/sddm.conf.d" ]; then
	cat > "$FULL/etc/sddm.conf.d/99-puralvos-live.conf" <<'EOF'
# Written by tools/build-live.sh. See the note there for why the live session
# is X11 and why autologin is explicit.
[Autologin]
User=ubuntu
Session=plasma
Relogin=false

[General]
DisplayServer=x11
EOF
	# The heredoc above is quoted, so the placeholder is filled in here with
	# the same derived name the audio group uses. Two copies of "the live
	# user is X" in one function is how they come to disagree.
	sed -i "s/^User=ubuntu$/User=$LIVE_USER/" "$FULL/etc/sddm.conf.d/99-puralvos-live.conf"
	grep -q "^User=$LIVE_USER$" "$FULL/etc/sddm.conf.d/99-puralvos-live.conf" \
		|| die "could not set the SDDM autologin user to $LIVE_USER"
	echo "  autologin: $LIVE_USER -> plasma on x11"
else
	die "$FULL/etc/sddm.conf.d does not exist, so the autologin settings cannot be
     placed. The live session would come up at a login prompt with nobody to
     log in, which is the same failure this step exists to prevent."
fi

say "plymouth and SDDM themes"
# The two screens between power on and the desktop. Both were Ubuntu Studio's,
# and the self test reports a slow, not a pass, while they are.
#
# These are theme DIRECTORIES with the file layouts the installed themes use,
# derived from the ones the image already ships rather than written from
# memory: plymouth from themes/spinner (two-step, ImageDir, watermark), SDDM
# from themes/breeze (theme.conf plus a metadata.desktop naming Main.qml).
#
# The plymouth theme is set in /etc/plymouth/plymouthd.default, which is what
# plymouthd reads. The SDDM one is set by name in the greeter config above.
PLYMOUTH_THEME="$FULL/usr/share/plymouth/themes/puralvos"
mkdir -p "$PLYMOUTH_THEME"
cat > "$PLYMOUTH_THEME/puralvos.plymouth" <<EOF
[Plymouth Theme]
Name=PuralvOS
Description=PuralvOS boot splash
ModuleName=two-step

[two-step]
Font=Ubuntu 12
TitleFont=Ubuntu Light 30
ImageDir=$PLYMOUTH_THEME
DialogHorizontalAlignment=.5
DialogVerticalAlignment=.382
TitleHorizontalAlignment=.5
TitleVerticalAlignment=.382
HorizontalAlignment=.5
VerticalAlignment=.7
WatermarkHorizontalAlignment=.5
WatermarkVerticalAlignment=.96
Transition=none
TransitionDuration=0.0
BackgroundStartColor=0x0B0E14
BackgroundEndColor=0x0B0E14
ProgressBarBackgroundColor=0x141922
ProgressBarForegroundColor=0x34D399
MessageBelowAnimation=true

[boot-up]
UseEndAnimation=false

[shutdown]
UseEndAnimation=false

[reboot]
UseEndAnimation=false
EOF
# The watermark two-step draws in the corner. The mark, not the wordmark: at
# splash size the wordmark's tagline is unreadable and the mark is the thing
# that identifies the machine.
#
# A PNG generated from tokens.json by tools/make-brand.py, from the same
# mark_geometry() that writes the SVG. There is no SVG rasteriser on this build
# machine, so an SVG here would mean either no watermark at all or a build-time
# dependency on one; the raster is generated instead, and it cannot drift from
# the SVG because neither of them defines the shape.
if [ -f "$ASSETS/mark-alpha-256.png" ]; then
	install -m 0644 "$ASSETS/mark-alpha-256.png" "$PLYMOUTH_THEME/watermark.png"
	echo "  plymouth watermark: mark-alpha-256.png (transparent)"
else
	die "$ASSETS/mark-alpha-256.png is missing. Generate the brand assets with:
     make brand
     A plymouth theme with no watermark is a black rectangle on every boot."
fi
printf 'PLYMOUTH_THEME_NAME=puralvos\n' > "$FULL/etc/plymouth/plymouthd.default"
echo "  plymouth: $(grep -o 'puralvos' "$FULL/etc/plymouth/plymouthd.default")"

SDDM_THEME="$FULL/usr/share/sddm/themes/puralvos"
if [ -d "$FULL/usr/share/sddm/themes/breeze" ]; then
	mkdir -p "$SDDM_THEME"
	# The QML comes from breeze, which is installed. Writing a whole Qt Quick
	# greeter from scratch to replace four lines of theme.conf is not a
	# branding task, it is a Qt project, and the result would be worse.
	cp -a "$FULL/usr/share/sddm/themes/breeze/." "$SDDM_THEME/"
	cat > "$SDDM_THEME/theme.conf" <<EOF
[General]
showlogo=hidden
showClock=true
logo=$SDDM_THEME/default-logo.svg
type=image
color=#34D399
fontSize=10
background=$FULL/usr/share/backgrounds/puralvos-wallpaper-1080p.png
needsFullUserModel=false
EOF
	sed -i -e 's/^Name=.*/Name=PuralvOS/' \
	       -e 's/^Description=.*/Description=PuralvOS/' \
	       -e '/^Theme-Id=.*/d' "$SDDM_THEME/metadata.desktop" 2>/dev/null || true
	grep -q '^Theme-Id=' "$SDDM_THEME/metadata.desktop" \
		|| printf 'Theme-Id=puralvos\n' >> "$SDDM_THEME/metadata.desktop"
	cp "$ASSETS/mark.svg" "$SDDM_THEME/default-logo.svg"
	# breeze's preview is breeze's; a preview that shows another product is
	# worse than no preview, and it is what the theme chooser draws.
	rm -f "$SDDM_THEME/preview.png"
	printf 'Current=puralvos\n' > "$FULL/etc/sddm.conf.d/98-puralvos-theme.conf"
	echo "  sddm: puralvos (QML from breeze, background and logo from brand/tokens.json)"
else
	echo "  warning: no breeze theme to derive from, leaving the SDDM theme alone" >&2
fi

say "GRUB theme"
# /boot/grub/themes/ubuntustudio/theme.txt is a file in the live layer whose
# first line is "# Custom grub theme for Ubuntu Studio", and the self test
# greps /boot/grub for that string. It is not the menu this image boots from
# (that is the ISO's own grub.cfg) but it is what an installed system shows,
# so it gets branded rather than left as evidence.
GRUBTHEME="$FULL/boot/grub/themes/puralvos"
if [ -d "$FULL/boot/grub/themes/ubuntustudio" ]; then
	mkdir -p "$GRUBTHEME"
	cp -a "$FULL/boot/grub/themes/ubuntustudio/." "$GRUBTHEME/"
	sed -i \
	  -e '1s/.*/# Custom grub theme for PuralvOS/' \
	  -e 's/"#eff0f1"/"#E8EDF4"/g' \
	  -e 's/"#f9fb06"/"#34D399"/g' \
	  -e 's/fg_color = #1b6acb/fg_color = #34D399/' \
	  -e 's/bg_color = #000000/bg_color = #0B0E14/' \
	  -e 's/border_color = #4d4d4d/border_color = #1F2733/' \
	  "$GRUBTHEME/theme.txt"
	# The stock background is Ubuntu Studio's artwork.
	rm -f "$GRUBTHEME/background.png"
	install -m 0644 "$ASSETS/wallpaper-1080p.png" "$GRUBTHEME/background.png"
	rm -f "$GRUBTHEME/preview.png"
	rm -rf "$FULL/boot/grub/themes/ubuntustudio"
	# Make it the default for an installed system.
	mkdir -p "$FULL/etc/default/grub.d"
	printf 'GRUB_THEME="/boot/grub/themes/puralvos/theme.txt"\n' \
		> "$FULL/etc/default/grub.d/99-puralvos.cfg"
	echo "  grub: puralvos theme installed, ubuntustudio removed"
else
	echo "  no /boot/grub/themes/ubuntustudio in this image, nothing to rebrand" >&2
fi

say "Plasma look and feel, themes and wallpaper"
# This image is Plasma, and until this section existed the branding was a
# filesystem full of PuralvOS names that the desktop never used:
#
#   * org.ubuntustudio-dark.desktop was installed and nothing applied it.
#     There is no /etc/xdg/kdeglobals setting LookAndFeelPackage and skel
#     carries no Plasma config, so the live session ran the KDE default —
#     Breeze. The grey desktop in the first review screenshot was Breeze's
#     wallpaper, not "the studio wallpaper with a missing file" it was
#     written down as.
#
#   * that LNF pointed its [Wallpaper] Image at ubuntustudio_2604, which the
#     wallpaper cleanup at the top of this function deletes precisely
#     because it is studio artwork. Applying the old LNF unchanged would
#     resolve to nothing.
#
# So the distro does the three things itself: rename the payload to puralvos
# names (rewriting self-references in text files only), point it at this
# product's wallpaper, and make it the default twice — LookAndFeelPackage in
# /etc/xdg/kdeglobals for the session itself, and an autostart applier as the
# belt to that suspenders, because a session with existing config never
# re-applies the LNF but does read /etc/xdg/autostart.
LF="$FULL/usr/share/plasma/look-and-feel"
if [ -d "$LF/org.ubuntustudio-dark.desktop" ]; then
	rm -rf "$LF/org.puralvos.desktop"
	cp -a "$LF/org.ubuntustudio-dark.desktop" "$LF/org.puralvos.desktop"
	# Text files only. -I so that the QML and the artwork are skipped:
	# grep reports an SVG as "binary file matches" and sed then corrupts it,
	# and the sed -i on a JPEG is worse than no sed at all.
	grep -rIl 'Ubuntu Studio\|ubuntu-studio\|ubuntustudio' \
		"$LF/org.puralvos.desktop" 2>/dev/null |
	while IFS= read -r f; do
		sed -i \
			-e 's/Ubuntu Studio/PuralvOS/g' \
			-e 's/ubuntu-studio-devel@ubuntu\.com/alvgot@users.noreply.github.com/g' \
			-e 's#https://www\.ubuntustudio\.org#https://github.com/alvgot/puralvos#g' \
			-e 's/org\.ubuntustudio-dark\.desktop/org.puralvos.desktop/g' \
			-e 's/ubuntustudio-dark/puralvos-dark/g' \
			-e 's/ubuntustudio/puralvos/g' \
			"$f"
	done
	rm -rf "$LF/org.ubuntustudio-dark.desktop"
	D="$LF/org.puralvos.desktop/contents/defaults"
	if [ -f "$D" ]; then
		# Image=puralvos resolves against /usr/share/wallpapers below.
		# The ksplash override names the studio splash; with it gone the
		# splash falls back to Breeze's, which is plain and correct.
		sed -i -e 's/^Image=.*/Image=puralvos/' -e '/^\[ksplashrc\]/,$d' "$D"
	fi
	# Splash and lockscreen art are the studio logo. Deleting the dirs
	# hands both back to Breeze; leaving them would put another product's
	# mark on this one's screen at every login.
	rm -rf "$LF/org.puralvos.desktop/contents/splash" \
	       "$LF/org.puralvos.desktop/contents/lockscreen"
	install -m 0644 "$ASSETS/preview-mark.png" \
		"$LF/org.puralvos.desktop/contents/previews/preview.png"
	install -m 0644 "$ASSETS/preview-mark.png" \
		"$LF/org.puralvos.desktop/contents/previews/splash.png"
	install -m 0644 "$ASSETS/lnf-fullscreenpreview.jpg" \
		"$LF/org.puralvos.desktop/contents/previews/fullscreenpreview.jpg"
	echo "  look-and-feel: org.puralvos.desktop (renamed from org.ubuntustudio-dark.desktop)"
else
	echo "  no org.ubuntustudio-dark.desktop in $LF, nothing to rename" >&2
fi

# The rest of the look-and-feel family. The -look package ships SIX more
# global themes — plain "Ubuntu Studio", "Ubuntu Studio Live", Classic,
# Classic Dark, and two macOS-alike layouts — and System Settings' Global
# Theme page lists every one by its metadata Name. They are furniture: once
# the kf5-settings templates below are repointed at org.puralvos.desktop,
# nothing this image ships references any of them, and a distro that ships
# one theme should not list seven, six of them another product's. Delete.
for t in org.ubuntustudio.desktop org.ubuntustudio-live.desktop \
	org.ubuntustudio-classic.desktop org.ubuntustudio-classic-dark.desktop \
	org.ubuntustudio-maclike.desktop org.ubuntustudio-dark-maclike.desktop; do
	[ -d "$LF/$t" ] || continue
	rm -rf "$LF/$t"
	echo "  look-and-feel: removed $t"
done

# The panel layout templates. These are NOT furniture: panel-refresh writes
# three of them at every session start and the LNF above loadTemplate()s
# org.puralvos.desktop.defaultPanel — a name that did not exist until this
# block, so the live panel layout has been resolving to a template the
# rename left behind. Rename the directories, the plugin ids inside the
# metadata, and the picker names ("Ubuntu Studio Default Panel" is listed in
# the desktop's Add Panel menu), then repoint the three paths panel-refresh
# writes.
LTP="$FULL/usr/share/plasma/layout-templates"
for t in defaultPanel dock classicPanel livePanel globalMenuPanel; do
	old="$LTP/org.ubuntustudio.desktop.$t"
	new="$LTP/org.puralvos.desktop.$t"
	[ -d "$old" ] || continue
	rm -rf "$new"
	mv "$old" "$new"
	grep -rIl 'ubuntustudio\|Ubuntu Studio' "$new" 2>/dev/null |
	while IFS= read -r f; do
		sed -i -e 's/Ubuntu Studio/PuralvOS/g' \
		       -e 's/org\.ubuntustudio\.desktop/org.puralvos.desktop/g' \
		       -e 's/ubuntustudio/puralvos/g' "$f"
	done
	echo "  layout template: org.puralvos.desktop.$t"
done
if [ -f "$FULL/usr/sbin/ubuntustudio-panel-refresh" ]; then
	sed -i 's/org\.ubuntustudio\.desktop/org.puralvos.desktop/g' \
		"$FULL/usr/sbin/ubuntustudio-panel-refresh"
	echo "  panel builder: template paths repointed"
fi

# The kept theme's own layout script still points its two desktop
# containments at /usr/share/wallpapers/puralvos-default*.png — files that
# stopped existing when the wallpaper cleanup deleted everything named
# *ubuntu*, renamed by the text sed above to names nothing ships. Point them
# at this image's wallpaper so applying the theme lands on the real
# background rather than on the plugin's fallback.
LJS="$LF/org.puralvos.desktop/contents/layouts/org.kde.plasma.desktop-layout.js"
if [ -f "$LJS" ]; then
	sed -i \
		-e 's#file:///usr/share/wallpapers/puralvos-default2\.png#file:///usr/share/wallpapers/puralvos/contents/images/2560x1440.png#' \
		-e 's#file:///usr/share/wallpapers/puralvos-default\.png#file:///usr/share/wallpapers/puralvos/contents/images/3840x2160.png#' \
		"$LJS"
	echo "  theme layout: wallpapers repointed at /usr/share/wallpapers/puralvos"
fi

# kf5-settings: the KDE config templates the -live-settings and
# -default-settings packages install (used when KDE settings are applied on
# an installed system; the boot-time casper hook only appends to them). They
# name the studio themes, the studio icon set and, in kcm-about-distrorc,
# the about page System Settings shows: Name=Ubuntu Studio, the studio
# website and the studio logo. Repoint the theme references at the one theme
# this image ships and brand the about page.
KFS="$FULL/usr/share/ubuntustudio/kf5-settings"
if [ -d "$KFS" ]; then
	for f in "$KFS"/*; do
		[ -f "$f" ] || continue
		sed -i \
			-e 's/org\.ubuntustudio-live\.desktop/org.puralvos.desktop/g' \
			-e 's/org\.ubuntustudio-dark\.desktop/org.puralvos.desktop/g' \
			-e 's/org\.ubuntustudio\.desktop/org.puralvos.desktop/g' \
			-e 's/^Theme=ubuntustudio$/Theme=puralvos/' \
			"$f"
	done
	CA="$KFS/kcm-about-distrorc"
	if [ -f "$CA" ]; then
		sed -i -e 's/^Name=.*/Name=PuralvOS/' \
		       -e 's#^Website=.*#Website=https://github.com/alvgot/puralvos#' \
		       "$CA"
	fi
	# The lock screen template pinned its greeter wallpaper at a
	# backgrounds path the wallpaper cleanup deletes; the file:// URL was
	# even missing a slash upstream. Send it to this image's wallpaper.
	KL="$KFS/kscreenlockerrc.live"
	if [ -f "$KL" ] && grep -q '^Image=' "$KL"; then
		sed -i 's#^Image=.*#Image=file:///usr/share/wallpapers/puralvos/contents/images/3840x2160.png#' "$KL"
	fi
	echo "  kf5-settings templates repointed (themes, icons, about page)"
fi

# The live installer unit. ubuntustudio-system-installer.service is what
# opens the installer window on the live desktop, and its ExecStopPost — run
# when that window closes — resets the user's Plasma layout to
# org.ubuntustudio-dark.desktop, a look-and-feel id this function deleted a
# few paragraphs up. lookandfeeltool then fails and the post-installer
# layout refresh silently does nothing. It also plays a ksplash test on a
# splash directory the theme rename removes. Both name the renamed theme
# now; the ksplash call goes.
UI="$FULL/usr/lib/systemd/user/ubuntustudio-system-installer.service"
if [ -f "$UI" ]; then
	sed -i -e 's/org\.ubuntustudio-dark\.desktop/org.puralvos.desktop/g' \
	       -e 's/^Description=.*/Description=PuralvOS live system installer/' \
	       -e 's#ksplashqml --test [^;]*; *##' "$UI"
	echo "  live installer unit: layout reset repointed at org.puralvos.desktop"
fi

# A dangling user unit symlink that ships in the live image:
# graphical-session.target.wants/ubuntu-desktop-installer.service resolves
# to a unit file that does not exist anywhere in the tree, so every user
# session starts by logging a failed unit load. Nothing on this image is
# waiting for it; remove the link rather than the thing it names (which
# would be a null operation anyway).
rm -f "$FULL/etc/systemd/user/graphical-session.target.wants/ubuntu-desktop-installer.service"

# Desktop theme and icon theme, renamed the same way and for the same
# reason: System Settings lists them BY THEIR METADATA NAME, and both said
# "Ubuntu Studio".
for dt in ubuntustudio ubuntustudio-dark; do
	src="$FULL/usr/share/plasma/desktoptheme/$dt"
	[ -d "$src" ] || continue
	dst_name=$(printf '%s' "$dt" | sed 's/ubuntustudio/puralvos/')
	dst="$FULL/usr/share/plasma/desktoptheme/$dst_name"
	rm -rf "$dst"
	cp -a "$src" "$dst"
	grep -rIl 'Ubuntu Studio\|ubuntustudio' "$dst" 2>/dev/null |
	while IFS= read -r f; do
		sed -i -e 's/Ubuntu Studio/PuralvOS/g' -e 's/ubuntustudio/puralvos/g' "$f"
	done
	rm -rf "$src"
	echo "  desktop theme: $dst_name"
done
for it in ubuntustudio ubuntustudio-dark; do
	src="$FULL/usr/share/icons/$it"
	[ -d "$src" ] || continue
	dst_name=$(printf '%s' "$it" | sed 's/ubuntustudio/puralvos/')
	dst="$FULL/usr/share/icons/$dst_name"
	rm -rf "$dst"
	cp -a "$src" "$dst"
	grep -rIl 'Ubuntu Studio\|ubuntustudio\|only Studio' "$dst" 2>/dev/null |
	while IFS= read -r f; do
		sed -i -e 's/Ubuntu Studio/PuralvOS/g' \
		       -e 's/only Studio uses/only PuralvOS uses/' \
		       -e 's/ubuntustudio/puralvos/g' "$f"
	done
	rm -rf "$src"
	echo "  icon theme: $dst_name"
done

# The default look and feel, system-wide. [KDE] LookAndFeelPackage is what a
# Plasma session reads when the user has no preference of their own; unset,
# which is how this image shipped, means Breeze. Written to edit rather than
# append, so that re-authoring an already-branded tree (--author-only) does
# not stack duplicate lines, which kdeglobals would then resolve last-wins.
KDEG="$FULL/etc/xdg/kdeglobals"
mkdir -p "$FULL/etc/xdg"
if [ -f "$KDEG" ] && grep -qE '^[[:space:]]*LookAndFeelPackage[[:space:]]*=' "$KDEG"; then
	sed -i -E 's|^[[:space:]]*LookAndFeelPackage[[:space:]]*=.*|LookAndFeelPackage=org.puralvos.desktop|' "$KDEG"
elif [ -f "$KDEG" ] && grep -qE '^\[KDE\]' "$KDEG"; then
	awk '/^\[KDE\]/ && !done {print; print "LookAndFeelPackage=org.puralvos.desktop"; done=1; next} {print}' \
		"$KDEG" > "$KDEG.new" && mv "$KDEG.new" "$KDEG"
else
	[ -f "$KDEG" ] || : > "$KDEG"
	printf '[KDE]\nLookAndFeelPackage=org.puralvos.desktop\n' >> "$KDEG"
fi
echo "  kdeglobals: LookAndFeelPackage=org.puralvos.desktop"

# The wallpaper as a first-class Plasma wallpaper package, so the LNF's
# Image=puralvos resolves and the picker shows it by name. Plasma resolves
# wallpaper ids against /usr/share/wallpapers/<id>/.
WP="$FULL/usr/share/wallpapers/puralvos"
install -d "$WP/contents/images"
install -m 0644 "$ASSETS/wallpaper-1080p.png" "$WP/contents/images/1920x1080.png"
install -m 0644 "$ASSETS/wallpaper-1440p.png" "$WP/contents/images/2560x1440.png"
install -m 0644 "$ASSETS/wallpaper-4k.png" "$WP/contents/images/3840x2160.png"
install -m 0644 "$ASSETS/wallpaper-1080p.png" "$WP/contents/screenshot.png"
cat > "$WP/metadata.json" <<'EOF'
{
    "KPlugin": {
        "Authors": [
            {
                "Name": "PuralvOS"
            }
        ],
        "Id": "puralvos",
        "License": "CC-BY-SA",
        "Name": "PuralvOS"
    }
}
EOF
echo "  wallpaper package: /usr/share/wallpapers/puralvos"

# And the belt to the LNF's suspenders: an autostart entry that re-asserts
# the wallpaper at every login, for sessions whose kdeglobals already exists
# (the LNF applies once; this applies always). NoDisplay: it is an action,
# not an app. plasma-apply-wallpaperimage is part of plasma-workspace; the
# || true keeps a session's startup clean if it ever is not.
cat > "$FULL/etc/xdg/autostart/puralvos-wallpaper.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=PuralvOS Wallpaper
Comment=Apply the PuralvOS wallpaper to the Plasma desktop
Exec=sh -c "command -v plasma-apply-wallpaperimage >/dev/null 2>&1 && plasma-apply-wallpaperimage /usr/share/wallpapers/puralvos/contents/images/3840x2160.png || true"
NoDisplay=true
X-KDE-autostart-after=panel
OnlyShowIn=KDE;
EOF
echo "  wallpaper autostart: /etc/xdg/autostart/puralvos-wallpaper.desktop"

say "Ubuntu Studio leftovers the packages keep"
# Packages this image keeps — because their files are load-bearing, the LNF
# above is one of theirs — also ship pure studio furniture. apt purge is not
# an option for any of it: simulated, purging any one of these packages
# breaks the ubuntustudio metapackages' dependency chain and apt answers with
# a REMOVED list holding darktable, digikam, hugin, the bpf tooling and most
# of the graphics stack. So the studio FILES go, the packages stay, and
# dpkg's database is left describing files that are not there — the same
# trade the wallpaper cleanup at the top of this function already makes.
#
# 1. The first-run audio checker. It ships a user unit that opens a dialog
#    when neither ~/.config/ubuntustudio-audio-firstrun exists nor the user
#    is named "ubuntu-studio" — and the live user is "puralvos", by design,
#    so the live session's first screen carried a modal asking about realtime
#    audio before the user had done anything. The grants its dialog is about
#    are already in /etc/security/limits.d and the live user is in @audio,
#    both several screens up in this build.
#
#    There is no package to purge for this one. "ubuntustudio-audio-config"
#    is not a package in the archive — `apt purge` answers "Unable to locate
#    package", and every file of it (the binary, the share dir, the .desktop)
#    is owned by ubuntustudio-installer, which this image keeps. So the unit
#    goes by rm, and the menu entry that would launch the same dialog by hand
#    is hidden — not removed: it is package-owned and NoDisplay=true is the
#    freedesktop way to take an entry out of the menus, the same treatment
#    fix_desktop_entries applies above to entries whose Exec is missing.
rm -f "$FULL/usr/lib/systemd/user/ubuntustudio-fix-firstrun.service"
find "$FULL/etc/systemd/user" "$FULL/var/lib/systemd" \
	-iname '*ubuntustudio-fix-firstrun*' -delete 2>/dev/null || true

AC="$FULL/usr/share/applications/ubuntustudio-audio-config.desktop"
if [ -f "$AC" ] && ! grep -qE '^(Hidden|NoDisplay)=true' "$AC"; then
	sed -i '1i # Hidden by PuralvOS: the first-run unit that used to launch this is\n# gone, and the tool it would open is Ubuntu Studio furniture. See\n# tools/build-live.sh (Ubuntu Studio leftovers).\nNoDisplay=true' "$AC"
	echo "  audio configuration entry hidden (unit is gone; the app would be a dead end)"
fi

# 2. Menu entries that open ubuntustudio.org. Links to another product's
#    website are not furniture to rename, they are that product's.
rm -f "$FULL"/usr/share/applications/ubuntustudio-chat-support.desktop \
      "$FULL"/usr/share/applications/ubuntustudio-contribute.desktop \
      "$FULL"/usr/share/applications/ubuntustudio-discourse.desktop \
      "$FULL"/usr/share/applications/ubuntustudio-website.desktop

# 3. The installer launcher keeps its function (it starts the same
#    ubuntu-desktop-bootstrap flow as the live desktop icon) and loses its
#    name. The translated Name[xx] lines are dropped rather than seds through
#    twenty languages: one correct name beats a table of half-translated
#    ones.
ID="$FULL/usr/share/applications/ubuntustudio-installer.desktop"
if [ -f "$ID" ]; then
	sed -i -e '/^Name\[/d' -e '/^GenericName\[/d' \
	       -e 's/^Name=.*/Name=PuralvOS Installer/' \
	       -e 's/^GenericName=.*/GenericName=Install PuralvOS/' \
	       -e 's/^Comment=.*/Comment=Install PuralvOS on this computer/' "$ID"
	echo "  installer menu entry: renamed to PuralvOS Installer"
fi

# 4. The studio logos in the pixmaps and icon themes. The default panel's
#    menu button points at ubuntustudio-logo-menu.png BY PATH
#    (customButtonImage in ubuntustudio-panel-refresh), so the file stays
#    and its content becomes the mark. The tiled version, not the bare
#    strokes: at a panel's 22 px the strokes alone are a grey smudge, and the
#    tile sits on the dark panel as if it belonged there. The hicolor theme
#    carries the same logo at panel sizes and Papirus carries a set for the
#    controls app; same treatment, found rather than listed so that a new
#    size in a later package cannot slip through.
for logo in "$FULL"/usr/share/pixmaps/ubuntustudio-logo*.png; do
	[ -f "$logo" ] || continue
	install -m 0644 "$ASSETS/mark-256.png" "$logo"
done
[ -f "$FULL/usr/share/pixmaps/ubuntustudio-logo.svg" ] && \
	install -m 0644 "$ASSETS/mark.svg" "$FULL/usr/share/pixmaps/ubuntustudio-logo.svg"
find "$FULL/usr/share/icons/hicolor" -iname '*ubuntustudio-logo*' -type f 2>/dev/null |
while IFS= read -r logo; do
	case "$logo" in
		*.svg) install -m 0644 "$ASSETS/mark.svg" "$logo" ;;
		*)     install -m 0644 "$ASSETS/mark-256.png" "$logo" ;;
	esac
done
find "$FULL/usr/share/icons/Papirus" -iname 'ubuntustudio-controls.svg' -type f 2>/dev/null |
while IFS= read -r logo; do
	install -m 0644 "$ASSETS/mark.svg" "$logo"
done

# 5. The avatar every new account gets. skel ships the studio logo as .face
#    and .face.icon; SDDM and the user list draw it, so it is user-visible
#    before anything else in this list.
for face in .face .face.icon; do
	[ -e "$FULL/etc/skel/$face" ] && \
		install -m 0644 "$ASSETS/mark-256.png" "$FULL/etc/skel/$face"
done

# 5b. GTK settings that point at the icon theme by its old name. The theme
#     dirs were renamed above; a name that resolves to nothing gets every
#     GTK app the fallback icons, which works and looks broken. Both skel
#     (new accounts, the live user) and the system-wide copies.
for f in "$FULL/etc/skel/.gtkrc-2.0" \
         "$FULL/etc/skel/.config/gtk-3.0/settings.ini" \
         "$FULL/etc/skel/.config/gtk-4.0/settings.ini" \
         "$FULL/etc/gtk-3.0/settings.ini" \
         "$FULL/etc/gtk-4.0/settings.ini"; do
	[ -f "$f" ] || continue
	sed -i \
		-e 's/gtk-icon-theme-name="ubuntustudio-dark"/gtk-icon-theme-name="puralvos-dark"/' \
		-e 's/gtk-icon-theme-name="ubuntustudio"/gtk-icon-theme-name="puralvos"/' \
		-e 's/gtk-icon-theme-name=ubuntustudio-dark/gtk-icon-theme-name=puralvos-dark/' \
		-e 's/gtk-icon-theme-name=ubuntustudio/gtk-icon-theme-name=puralvos/' \
		"$f"
done

# 6. A GNOME dconf fragment (app folders). This is a Plasma image; the
#    fragment is inert here and its folder names are studio menu names.
rm -f "$FULL/etc/dconf/db/site.d/00_ubuntustudio"

# 7. Plymouth themes that are alternative studio skins. The active theme is
#    already puralvos; these are the leftovers the self test's boot-splash
#    checks can still see.
rm -rf "$FULL/usr/share/plymouth/themes/ubuntustudio-logo" \
       "$FULL/usr/share/plymouth/themes/ubuntustudio-text" \
       "$FULL/usr/share/grub/themes/ubuntustudio"

# Anything still carrying Canonical's name in a menu or a config file the
# self test looks at. Reported rather than passed over: docs/BRANDING.md lists
# these as defects, and the check is cheap.
#
# `grep ... | wc -l` inside a command substitution, under `set -o pipefail`.
#
# grep exits 1 when it matches nothing, which is the SUCCESSFUL case here, and
# pipefail makes the pipeline exit 1, and under `set -e` that kills the script
# at the assignment. With no message, because the assignment "succeeded" from
# the shell's point of view until it did not.
#
# So the build died silently, at the very last step of the branding, on a tree
# where the branding had all succeeded, with the log ending at the previous
# line and the exit status coming from somewhere else entirely. It looks exactly
# like a hang or an OOM, and it took a full 25 minute build to find.
#
# `|| true` is not a workaround here; it is the correct expression of what is
# being asked, which is "how many", where zero is an answer and not an error.
LEFT=$(grep -rlisE 'ubuntu[ -]?studio' "$FULL/boot/grub" 2>/dev/null | wc -l || true)
if [ "${LEFT:-0}" -gt 0 ]; then
	echo "  WARNING: $LEFT file(s) under /boot/grub still say Ubuntu Studio:" >&2
	grep -rlisE 'ubuntu[ -]?studio' "$FULL/boot/grub" 2>/dev/null | sed 's/^/           /' >&2
else
	echo "  /boot/grub: no Ubuntu Studio strings left"
fi

# The same trap, audited for the rest of the file, because it is the kind of
# thing that hides until a build is 20 minutes in.
#
#   grep -q PATTERN file        in an `if` or `&&` context: fine, the non-zero
#                               status is the condition being tested
#   grep ... | wc -l           in an assignment: kills the script when there
#   grep ... | head -3 | sed    are no matches, which is usually the good case
#
# Every remaining bare `grep | ...` pipeline in this file is either in a
# condition or already carries `|| true`. Checked by grep for it:
if grep -nE '^\s*[A-Z_]+=\$\(grep .*\|' "$0" | grep -v '|| true' ; then
	echo "  note: an assignment from a grep pipeline without '|| true' is above" >&2
fi

# The one downloaded component. Called from here, not from build_tree, so
# that --author-only ships it too: brand_the_tree is the function both paths
# run, and an image whose branding is right but whose headlining plugin is
# missing is not the product either path should be able to build.
install_tone3000

} # end brand_the_tree

# Everything from here to the repack: unpack the stock ISO, merge the casper
# layers, install the kernel, apply the branding. A function rather than a
# straight run of code so --author-only can step over all of it and go
# straight from an existing $WORK/iso to a finished ISO.
build_tree() {

say "work directory $WORK"
mkdir -p "$WORK"
# The extracted ISO goes every time; it is cheap and it must match the ISO that
# is actually on disk.
#
# base-union and layer are NOT removed here. They are 17 GB and 18 GB and
# unpacking them is the slowest thing this build does, which is the entire
# reason there is a resume marker below. Wiping them here made that marker a
# lie on every run: the marker survived (it lives in $WORK, not in either
# directory), so the next run would claim to reuse a tree this line had just
# deleted. A full build never reached the chroot.
#
# PURALVOS_RESUME=0 forces the slow path, and is what a from-scratch build wants.
if [ "${PURALVOS_RESUME:-1}" = 0 ]; then
	rm -rf "$WORK/iso" "$WORK/base-union" "$WORK/layer" "$WORK/.layers-merged"
fi
rm -rf "$WORK/iso"
mkdir -p "$WORK/iso" "$WORK/base-union"

say "extracting the stock ISO"
xorriso -osirrox on -indev "$BASE_ISO" -extract / "$WORK/iso" >/dev/null 2>&1
echo "  extracted $(du -sh "$WORK/iso" | cut -f1)"

say "unpacking the casper layers"
# 26.04 live images are a union of three squashfs layers, lower first:
#
#   minimal.squashfs               3.9 GB   the actual system, all binaries
#   minimal.standard.squashfs      2.0 GB   the desktop and applications
#   minimal.standard.live.squashfs  153 MB   the live session delta
#
# The top layer alone has 7169 entries and no /usr/bin/env, so unpacking only
# it and chrooting gives "env: No such file or directory" and nothing else
# works. All three have to be unpacked in order into one directory, which is
# what the union actually is.
# Resumable, with an explicit completion marker.
#
# The marker matters. Testing for $BASE_UNION/usr/bin/env is not a "did I
# finish" check: the FIRST layer alone provides /usr/bin/env, so after an
# interrupted first layer the test passes, the second layer is silently
# skipped, and the union ends up missing the entire desktop and every
# application in it. The symptom arrives much later as a working copy with no
# binaries.
MARK="$WORK/.layers-merged"
if [ -f "$MARK" ] && [ "${PURALVOS_RESUME:-1}" = 1 ]; then
	# Resume is only safe if the tree the marker refers to is actually still
	# there.
	#
	# It was not, and the marker said it was. The line above this one removes
	# $WORK/layer and $WORK/base-union unconditionally at the start of
	# build_tree, but the marker lives in $WORK, so it survived the removal and
	# the resume branch took a marker pointing at a directory that had just
	# been deleted. The build then reported
	#
	#     reusing the existing build root
	#     read-only union: 4.0K
	#     the read-only union has no /usr/bin/env; the layers did not merge
	#
	# which is at least an honest failure, but only because the /usr/bin/env
	# check downstream caught it. A marker that describes a tree which is gone
	# is not a resume, and the only reason this was ever visible is that
	# something unrelated noticed.
	#
	# So: check the tree, not the marker. Four paths that only exist together
	# if all three layers really merged.
	if [ -x "$BASE_UNION/usr/bin/env" ] && [ -x "$BASE_UNION/usr/bin/plasma" ] &&
	   [ -d "$BASE_UNION/usr/share/backgrounds" ] && [ -d "$FULL" ]; then
		echo "  reusing the existing read-only union ($(du -sh "$BASE_UNION" | cut -f1))"
	else
		echo "  the marker says merged but the tree is not there; unpacking again" >&2
		rm -f "$MARK"
		rm -rf "$BASE_UNION" "$FULL"
	fi
fi
if [ ! -f "$MARK" ]; then
	rm -rf "$BASE_UNION" "$FULL" "$MARK"
	mkdir -p "$BASE_UNION" "$FULL"
fi

# Merging one layer over another, with the type changes a casper overlay is
# allowed to make.
#
# cp and rsync both refuse this. The live layer legitimately replaces
# directories with files and device nodes: /usr/lib/dracut/modules.d is a
# directory in the standard layer and something else in the live layer. cp
# says "cannot overwrite directory ... with non-directory"; rsync says "could
# not make way for new device file ... cannot delete non-empty directory".
#
# Both are right that this is not an ordinary copy, but an overlay is not an
# ordinary copy: the upper layer is supposed to win outright. So the lower
# directory is removed first, for exactly the paths where the upper layer
# supplies something that is not a directory. Only those paths, so nothing
# else is disturbed.
merge_layer() {
	local src="$1" dest="$2" tmp="$WORK/.unpack.$$"
	rm -rf "$tmp"; mkdir -p "$tmp"
	unsquashfs -f -d "$tmp" "$src" >/dev/null
	(
		cd "$tmp" || exit 1
		find . \( -type f -o -type l -o -type b -o -type c -o -type p -o -type s \) \
			-printf '%P\n'
	) | while IFS= read -r p; do
		[ -n "$p" ] || continue
		# An `if`, not `[ -d ... ] && rm`. When the test is false the && form
		# returns 1, that becomes the exit status of the whole loop, and under
		# `set -e` in a pipeline it silently kills the build. It killed it
		# three times before it was noticed, leaving an empty build root and a
		# log that stopped mid-sentence with no error.
		if [ -d "$dest/$p" ]; then
			rm -rf "${dest:?}/$p"
		fi
	done
	rsync -a "$tmp/" "$dest/"
	rm -rf "$tmp"
}

for L in minimal minimal.standard; do
	SRC="$WORK/iso/casper/$L.squashfs"
	[ -f "$SRC" ] || die "missing layer $SRC. See docs/BASELINE.md: 26.04 is layered."
	if [ -f "$MARK" ]; then
		printf '  %-30s %5.0f MB  (already unpacked)\n' "$L.squashfs" \
			"$(( $(stat -c %s "$SRC") / 1048576 ))"
		continue
	fi
	printf '  %-30s %5.0f MB\n' "$L.squashfs" \
		"$(( $(stat -c %s "$SRC") / 1048576 ))"
	merge_layer "$SRC" "$BASE_UNION"
done

touch "$MARK"
echo "  read-only union (minimal + minimal.standard): $(du -sh "$BASE_UNION" | cut -f1)"
[ -x "$BASE_UNION/usr/bin/env" ] \
	|| die "the read-only union has no /usr/bin/env; the layers did not merge"

# What the read-only union contains, by path. The rebuilt top layer must be
# exactly the paths that differ from this, or a change made to a file the
# standard layer also owns would be shadowed by the standard layer when it is
# applied again on top.
( cd "$BASE_UNION" && find . -printf '%P\n' | LC_ALL=C sort ) > "$WORK/base.list"
echo "  read-only paths: $(wc -l < "$WORK/base.list")"

# The working copy is the whole three layer union plus room to change it.
cp -a "$BASE_UNION/." "$FULL/"
printf '  %-30s %5.0f MB  -> working copy\n' "minimal.standard.live.squashfs" \
	"$(( $(stat -c %s "$WORK/iso/$LAYER") / 1048576 ))"
merge_layer "$WORK/iso/$LAYER" "$FULL"
[ -x "$FULL/usr/bin/env" ] || die "the working copy is not a usable system"

# --------------------------------------------------------------------------
# the kernel: the reason this build exists
# --------------------------------------------------------------------------
if [ "$WITH_KERNEL" = 1 ]; then
	say "installing the real time kernel"
	mkdir -p "$FULL"/{proc,sys,dev}
	mount --bind /proc "$FULL/proc"
	mount --bind /sys  "$FULL/sys"
	mount --bind /dev  "$FULL/dev"
	cleanup_mounts() {
		umount "$FULL/proc" "$FULL/sys" "$FULL/dev" 2>/dev/null || true
	}
	trap cleanup_mounts EXIT

	cp /etc/resolv.conf "$FULL/etc/resolv.conf"

	# Use the sources the image already ships rather than adding our own.
	#
	# /etc/apt/sources.list.d/ubuntu.sources in this layer already names
	# resolute, resolute-updates, resolute-backports and resolute-security,
	# which is exactly right. Writing a second copy of it produced nothing but
	# "Target ... is configured multiple times" warnings.
	#
	# The one thing that has to go is cdrom.sources. It points at
	# file:///cdrom, which does not exist inside a chroot, and apt treats an
	# unreachable source as fatal: "The repository 'file:/cdrom resolute
	# Release' does not have a Release file", exit 100, and apt-get update
	# fails before it fetches anything. Move it aside for the build and put
	# it back afterwards, so the image still installs from its own DVD.
	for f in "$FULL"/etc/apt/sources.list.d/cdrom.sources; do
		[ -e "$f" ] && mv "$f" "$f.puralvos-disabled" \
			&& echo "  cdrom.sources disabled for the chroot build"
	done

	rm -f "$FULL"/etc/apt/sources.list.d/puralvos.sources
	mkdir -p "$FULL/etc/apt/sources.list.d" "$FULL/var/lib/apt/lists/partial"

	chroot "$FULL" env DEBIAN_FRONTEND=noninteractive \
		apt-get update -qq 2>&1 | tail -3 | sed 's/^/  /'

	say "which kernel does apt actually offer?"
	chroot "$FULL" env DEBIAN_FRONTEND=noninteractive \
		apt-cache policy linux-realtime linux-image-realtime 2>/dev/null \
		| sed 's/^/  /'

	# linux-image-realtime, NOT linux-realtime.
		#
		# linux-realtime depends on linux-headers-realtime, which is about
		# 1.7 GB and completely useless in a live image: there is nobody to
		# compile a module. Installing the metapackage grew the layer past
		# 4 GiB and libisofs then refused to put the file in the ISO at all:
		# "File ... cannot be added to image because its size is 4 GiB or
		# larger".
		#
		# The image package is the kernel. The metapackage is a label.
	chroot "$FULL" env DEBIAN_FRONTEND=noninteractive \
		apt-get purge -y 'linux-headers*' linux-realtime 2>&1 \
		| grep -E '^(Removing|Removing package|not installed)' | head -3 | sed 's/^/  /' || true

	chroot "$FULL" env DEBIAN_FRONTEND=noninteractive \
		apt-get install -y --no-install-recommends \
		linux-image-realtime 2>&1 | tail -10 | sed 's/^/  /'

	echo "  kernels now present:"
	ls "$FULL/boot" | grep -E '^vmlinuz' | sed 's/^/    /'

	# And what dpkg thinks, printed side by side, because the two can disagree
	# and only one of them is what the image will actually boot.
	#
	# This is not decoration. On the last full build these printed:
	#
	#     /boot:      vmlinuz-7.0.0-30-generic  vmlinuz-7.0.0-38-realtime
	#     dpkg:       linux-image-7.0.0-30-generic ii
	#                 (no entry at all for the realtime kernel)
	#
	# and the image shipped a booting PREEMPT_RT kernel whose package dpkg had
	# no record of. So `apt upgrade` in the live session could not replace it,
	# and `dpkg -l linux-image-realtime` answered "no packages found" on an
	# image that was running one. Both facts are true and they are the whole
	# problem: the kernel came from a copy, not from an install.
	echo "  dpkg's view of the kernels:"
	chroot "$FULL" dpkg-query -W -f='    ${Package} ${Version} ${db:Status-Abbrev}\n' \
		'linux-image-*' 2>/dev/null | grep -v ' unknown ok not-installed' || true
	echo "  build root size: $(du -sh "$FULL" --exclude=proc --exclude=sys --exclude=dev 2>/dev/null | cut -f1)"

	cleanup_mounts
	trap - EXIT

	# Put the CD-ROM source back, so the finished image can still install
	# from its own DVD.
	for f in "$FULL"/etc/apt/sources.list.d/cdrom.sources.puralvos-disabled; do
		[ -e "$f" ] && mv "$f" "${f%.puralvos-disabled}" \
			&& echo "  cdrom.sources restored"
	done
else
	say "skipping the kernel (--no-kernel): this image will boot the GENERIC kernel"
fi

# --------------------------------------------------------------------------
# remove what the product does not ship
# --------------------------------------------------------------------------
# This is a chroot, so it cannot run inside brand_the_tree: that function is
# also called by --author-only, which deliberately does no chroot work at all.
# The tasks are removed here, before branding, so the desktop-entry hygiene step
# inside brand_the_tree sees the menu as it will actually ship.
#
# Order matters in the other direction too: purging first means the package
# removals are already in the layer diff when brand_the_tree runs, so the whiteout
# list and the top layer are computed once, from the final state.
#
# Note what is NOT purged, and why it is not an oversight:
#
#   * ubuntustudio-audio-config is not a package at all. It looked like one
#     on the installed list — it has a binary, a .desktop and a share dir —
#     but dpkg-query says "no packages found matching", every file of it is
#     owned by ubuntustudio-installer, and `apt purge ubuntustudio-audio-
#     config` answers "Unable to locate package" (which purge_in_chroot's
#     grep would have swallowed). The first-run checker is neutralised in
#     brand_the_tree instead, where it is file work anyway: its unit is
#     removed and its menu entry is hidden.
#
#   * Every other candidate — the menu, the icon theme, the wallpapers, the
#     installer, even the generic kernel — simulates to a REMOVED list
#     containing darktable, digikam, hugin and the rest of the audio/video/
#     graphics stack, because they are in the ubuntustudio metapackages'
#     dependency chain and apt takes the chain with them. Those stay
#     installed and their files are branded or removed individually in
#     brand_the_tree.
say "removing photography and publishing"
purge_in_chroot() {
	local p
	for p in "$@"; do
		chroot "$FULL" env DEBIAN_FRONTEND=noninteractive \
			apt-get purge -y "$p" 2>&1 |
			grep -E '^(Removing|Removing package|not installed)' |
			head -3 | sed 's/^/  /' || true
	done
}
purge_in_chroot ubuntustudio-photography ubuntustudio-publishing

# --------------------------------------------------------------------------
# branding
# --------------------------------------------------------------------------
# Everything that makes the tree PuralvOS rather than Ubuntu Studio. The
# unpack, the chroot and the kernel are above; this is the same function
# --author-only calls, so both paths brand the tree identically.
brand_the_tree

# --------------------------------------------------------------------------
# repack
# --------------------------------------------------------------------------
say "swapping in the real time kernel"
# GRUB boots a fixed path, /casper/vmlinuz with /casper/initrd. To boot the
# real time kernel that is what has to change, not the GRUB config.
#
# And the kernel is chosen by asking dpkg, not by looking at /boot.
#
# `ls /boot | tail -1` is how this picked the version, and it worked by luck:
# sort -V puts the realtime kernel last because its version is higher than the
# generic one. It stops working the moment an archive ships a generic kernel
# newer than the realtime one, which happens every few cycles, and then the
# image boots the GENERIC kernel with no error anywhere — the file was copied,
# it is a perfectly good kernel, it is just not PREEMPT_RT, and the only thing
# that notices is the self test on a machine that can read the serial port.
#
# dpkg is the authority on what is installed, and this is the whole reason the
# build is a chroot build rather than a file copy. Ask it.
RTVER=""
if [ "$WITH_KERNEL" = 1 ]; then
	# Every INSTALLED kernel image package, by version. Then pick the real time
	# one from that list.
	#
	# There is more than one, and that is the normal case rather than a
	# misconfiguration. linux-image-generic arrives with the base image and
	# linux-image-realtime is installed alongside it; excludes.list removes the
	# generic METAPACKAGES, not the image package that came with the base, so
	# dpkg correctly lists both:
	#
	#     linux-image-7.0.0-30-generic    7.0.0-30.30     ii
	#     linux-image-7.0.0-38-realtime   7.0.0-38.38.1   ii
	#
	# Taking the first, as `| head -1` did, picks whichever dpkg happens to
	# sort first, which is the GENERIC one. The build then copied that kernel
	# into casper/vmlinuz and shipped an image that boots the generic kernel
	# while claiming to be a real time workstation.
	#
	# The PREEMPT_RT assertion below caught it, which is the assertion doing
	# exactly the job it was written for. But the fix belongs here: ask for the
	# realtime package by name, the way tasks.list asks for it.
	#
	# -showformat with ${db:Status-Abbrev} and a grep for the installed state,
	# so an unpacked-but-not-configured package cannot be selected either.
	RTVER=$(chroot "$FULL" dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' \
		'linux-image-*' 2>/dev/null |
		awk '$1 ~ /^linux-image-[0-9]/ && $1 ~ /-realtime$/ && $2 == "ii" { print $1; exit }' |
		sed -n 's/^linux-image-//p')
	if [ -z "$RTVER" ]; then
		echo "  installed kernel images dpkg knows about:" >&2
		chroot "$FULL" dpkg-query -W -f='    ${Package} ${Version} ${db:Status-Abbrev}\n' \
			'linux-image-*' 2>/dev/null | grep -v ' unknown ok not-installed' >&2 || true
		die "dpkg does not list linux-image-realtime as installed, so there is no
     real time kernel to ship. The chroot install did not take; look for it
     earlier in this log."
	fi
	echo "  dpkg says the installed real time kernel is: $RTVER"

	# Cross-check dpkg against the filesystem before trusting either. A version
	# dpkg names with no vmlinuz behind it means the database and the tree have
	# diverged, and booting it would produce an image that panics on the first
	# module load.
	if [ ! -f "$FULL/boot/vmlinuz-$RTVER" ]; then
		die "dpkg says linux-image-$RTVER is installed but
     $FULL/boot/vmlinuz-$RTVER does not exist.
     The kernel database and the filesystem disagree, which means an earlier
     step in this build reverted the tree without reverting dpkg's records.
     Do not ship this; re-run the build from scratch (PURALVOS_RESUME=0)."
	fi

	# And the other way: a vmlinuz for a kernel dpkg does not know about is a
	# kernel the running system cannot manage. It would boot, and then no
	# upgrade in the live session could ever replace it.
	if [ ! -d "$FULL/lib/modules/$RTVER" ]; then
		die "$FULL/lib/modules/$RTVER is missing.
     The kernel image is there and its modules are not, so the image boots and
     then fails to load anything: no sound card, no network, no disk."
	fi

	cp -f "$FULL/boot/vmlinuz-$RTVER" "$WORK/iso/casper/vmlinuz"
	echo "  casper/vmlinuz  <- vmlinuz-$RTVER"
	# Prove the file that is about to be shipped is the real time one. This is
	# the single most important assertion in the build: everything else in this
	# script is packaging, and this is the reason the product exists.
	#
	# grep on the file directly, NOT `strings ... | grep -q`. Two reasons, and
	# the first one cost a 25 minute build:
	#
	#   grep -q exits the moment it finds a match. strings then dies on SIGPIPE,
	#   and under `set -o pipefail` the pipeline's status is 128+13 = 141 even
	#   though grep matched and printed nothing. So:
	#
	#       strings vmlinuz | grep -qm1 PREEMPT_RT     rc=141   (a matching kernel!)
	#       grep -a -m1 PREEMPT_RT vmlinuz             rc=0
	#
	#   -a because the kernel is a bzImage and "binary file matches" is the
	#   wrong answer to a question about what is inside it; grep -a treats it as
	#   text and finds the string.
	#
	#   The second reason is the cost: strings on a 17 MB kernel takes a moment,
	#   and the pipe lets grep give up early. grep on the file streams the same
	#   bytes with no second process and no signal to lose.
	#
	# The check is in an `if`, where a non-zero status is the condition being
	# tested rather than a failure, and it prints what it found so that a
	# correct kernel and a wrong one do not look the same in the log.
	if grep -a -m1 -o 'PREEMPT_RT' "$WORK/iso/casper/vmlinuz" >/dev/null 2>&1; then
		echo "  casper/vmlinuz is PREEMPT_RT"
		# Print the version banner next to it, so a log reader can see WHICH
		# kernel without opening the file. The banner is a fixed-width field
		# followed by NUL padding and then unrelated bytes, so it is matched
		# on the "SMP PREEMPT_RT" part rather than on "version" — which does
		# not appear in the bzImage at all, and produced an empty line here.
		echo "    $(grep -a -m1 -o '#[0-9][^ ]*-Ubuntu SMP PREEMPT_RT' \
			"$WORK/iso/casper/vmlinuz" 2>/dev/null | head -1)"
	else
		die "the kernel about to be shipped is NOT PREEMPT_RT.
     File: $WORK/iso/casper/vmlinuz
     This image would boot a cooperative-preemption kernel and every real time
     claim PuralvOS makes would be false. Stop and look at linux-image-$RTVER."
	fi
	# The kernel's own initramfs, which carries the modules for this
	# kernel and its own early microcode.
	#
	# It REPLACES the stock /casper/initrd instead of being appended to it.
	# GRUB was loading both, 103 MB + 100 MB at every boot, and the stock
	# one belongs to the generic kernel this image no longer ships. Both
	# carry kernel/x86/microcode (checked below); the microcode that used
	# to justify keeping casper's copy is in the realtime initrd too.
	INITRD="$FULL/boot/initrd.img-$RTVER"
	if [ -f "$INITRD" ]; then
		if ! lsinitramfs "$INITRD" 2>/dev/null | grep -q '^kernel/x86/microcode/'; then
			echo "  warning: $RTVER's initrd carries no early microcode; the stock" >&2
			echo "  initrd was dropped, so microcode loads late instead of early." >&2
		fi
		cp -f "$INITRD" "$WORK/iso/casper/initrd"
		rm -f "$WORK/iso/casper/initrd.realtime"
		echo "  casper/initrd <- initrd.img-$RTVER ($(du -h "$INITRD" | cut -f1)); stock initrd dropped"
	else
		die "$FULL/boot/initrd.img-$RTVER is missing.
     Without the kernel's own initramfs the image boots with no modules loaded
     for this kernel, which is the same failure as a missing lib/modules."
	fi
	# Stock images do not carry an initrd in the rootfs: /casper/initrd on the
	# ISO is the only copy, and /boot/initrd.img is a dangling symlink (see the
	# stock base-union's /boot). Keeping the generated one here cost 100 MB in
	# the squashfs for a file nothing in the live session reads, so mirror the
	# stock layout. update-initramfs writes it back on kernel upgrades.
	rm -f "$FULL/boot/initrd.img-$RTVER"
	# ------------------------------------------------------------------
	# Slim: the non-realtime kernel goes.
	#
	# The base image ships two kernels: linux-image-7.0.0-30-generic from
	# the base install, and linux-image-realtime installed alongside it.
	# This image boots the realtime one — that is the point of it — and an
	# extra kernel is 172 MB of modules plus a 17 MB vmlinuz plus System.map
	# and config: two hundred megabytes nothing in the product ever loads.
	#
	# Not apt purge. Simulated, purging linux-image-7.0.0-30-generic takes
	# the ubuntustudio metapackage chain with it (the generic kernel is a
	# dependency there) and apt answers with a REMOVED list holding
	# darktable, digikam, hugin, the bpf tooling and most of the graphics
	# stack. So the package stays in dpkg, its files are removed, and dpkg
	# -V would report the image — the same trade the branding makes for
	# files that have to go. Nothing in the live session reads the generic
	# kernel, and apt upgrading that one package is the only thing that
	# would put the files back.
	#
	# Derived from dpkg rather than spelled out, so the day the archive
	# moves to 7.0.0-40 this step still removes the right two hundred
	# megabytes, and never the realtime kernel by accident.
	# ------------------------------------------------------------------
	GENERICV=$(chroot "$FULL" dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' \
		'linux-image-*' 2>/dev/null |
		awk '$1 ~ /^linux-image-[0-9]/ && $1 !~ /-realtime$/ && $2 == "ii" { print $1; exit }' |
		sed -n 's/^linux-image-//p')
	if [ -n "$GENERICV" ] && [ "$GENERICV" != "$RTVER" ] \
	   && [ -d "$FULL/lib/modules/$GENERICV" ]; then
		FREED=$(du -sm "$FULL/lib/modules/$GENERICV" 2>/dev/null | cut -f1)
		rm -rf "$FULL/lib/modules/$GENERICV"
		rm -f  "$FULL/boot/vmlinuz-$GENERICV" \
		       "$FULL/boot/System.map-$GENERICV" \
		       "$FULL/boot/config-$GENERICV" \
		       "$FULL/boot/initrd.img-$GENERICV"
		# /boot/vmlinuz.old points at the generic kernel and dangles now.
		if [ -L "$FULL/boot/vmlinuz.old" ] \
		   && [ ! -e "$FULL/boot/$(readlink "$FULL/boot/vmlinuz.old")" ]; then
			rm -f "$FULL/boot/vmlinuz.old"
		fi
		echo "  removed the non-realtime kernel $GENERICV (${FREED:-?} MB of modules)"
	else
		echo "  no non-realtime kernel image to remove"
	fi
	# The surgery above must not have touched the kernel that ships booting.
	[ -f "$FULL/boot/vmlinuz-$RTVER" ] && [ -d "$FULL/lib/modules/$RTVER" ] \
		|| die "removing the generic kernel also removed the realtime kernel's
     files ($RTVER), which is the one this image boots. Do not ship this."
	echo "  modules present: $(ls "$FULL/lib/modules" | tr '\n' ' ')"

	# ------------------------------------------------------------------
	# The casper UUID pair, which has to be built together.
	#
	# casper's initramfs hook writes /conf/uuid.conf into the initramfs it
	# builds, and casper then refuses the boot medium unless the same UUID
	# appears in the medium's .disk/casper-uuid* (see check_dev in casper:
	# it mounts the CD, is_casper_path passes, and then
	# [ "$UUID" = "$devuid" ] || matches_uuid fails and it unmounts the disk
	# it just proved was correct). A regenerated initramfs carries a new
	# random UUID while .disk/casper-uuid-generic on the extracted tree is
	# still the base ISO's, and the mismatch is invisible until boot:
	#
	#     Unable to find a medium containing a live file system
	#
	# even though blkid, the mount and the /casper/*.squashfs contents are
	# all exactly right when checked by hand from an initramfs shell.
	#
	# GRUB loads both initrds in the order its menu names them, and for
	# concatenated initramfs archives later files replace earlier ones, so
	# the effective UUID is the one from the last initrd that carries one.
	# Read it back out of the files that will actually boot, with Ubuntu's
	# own unmkinitramfs, and write it where casper will compare it.
	uuid_of_initrd() {
		local initrd="$1" tmp u
		[ -f "$initrd" ] || return 1
		command -v unmkinitramfs >/dev/null 2>&1 || return 1
		tmp=$(mktemp -d "$WORK/.uuid.XXXXXX")
		if ! unmkinitramfs "$initrd" "$tmp" >/dev/null 2>&1; then
			rm -rf "$tmp"; return 1
		fi
		u=$(cat "$tmp"/*/conf/uuid.conf 2>/dev/null | head -1)
		rm -rf "$tmp"
		[ -n "$u" ] || return 1
		printf '%s\n' "$u"
	}
	CASPER_UUID=""
	for initrd in "$WORK/iso/casper/initrd" "$WORK/iso/casper/initrd.realtime"; do
		u=$(uuid_of_initrd "$initrd" || true)
		[ -n "$u" ] && CASPER_UUID="$u"
	done
	if [ -n "$CASPER_UUID" ]; then
		printf '%s\n' "$CASPER_UUID" > "$WORK/iso/.disk/casper-uuid-generic"
		for f in "$WORK/iso/.disk/casper-uuid"*; do
			[ -e "$f" ] || continue
			printf '%s\n' "$CASPER_UUID" > "$f"
		done
		echo "  casper uuid: $CASPER_UUID (read from the initrds, written to .disk/casper-uuid-generic)"
	elif command -v unmkinitramfs >/dev/null 2>&1; then
		rm -f "$WORK/iso/.disk/casper-uuid"*
		echo "  casper uuid: no initrd carries /conf/uuid.conf; removed .disk/casper-uuid* so casper skips the check"
	else
		echo "  WARNING: unmkinitramfs is missing, so the casper UUID pair cannot be" >&2
		echo "  verified or synchronised. If the image reaches 'Unable to find a" >&2
		echo "  medium containing a live file system', this is why." >&2
	fi
else
	echo "  skipped: the image will boot the stock GENERIC kernel"
fi

say "cleaning package manager state only the build needed"
# The chroot installed the realtime kernel and apt kept the download: the
# modules .deb is 169 MB, already compressed, so squashfs cannot shrink it.
# No stock image carries it (the stock archive directory holds lock files only).
rm -f "$FULL"/var/cache/apt/archives/*.deb
# The binary package caches (~110 MB) are chroot residue too — the stock image
# has no pkgcache.bin at all, apt rebuilds it on first use.
rm -f "$FULL"/var/cache/apt/pkgcache.bin "$FULL"/var/cache/apt/srcpkgcache.bin
# The archive lists are different: the stock image SHIPS them (170 MB, inside
# minimal.squashfs, where every ISO pays for them), and the live session and
# the installer use them. The chroot's apt update rewrote them, so the diff
# would stage copies in the top layer that buy nothing. Put the stock files
# back, timestamps included, and the diff stays quiet: the live session sees
# exactly the metadata stock shipped.
if [ -d "$BASE_UNION/var/lib/apt/lists" ]; then
	rm -rf "$FULL/var/lib/apt/lists"
	cp -a "$BASE_UNION/var/lib/apt/lists" "$FULL/var/lib/apt/lists"
fi

say "checking the boot menu"
G="$WORK/iso/boot/grub/grub.cfg"
if [ -f "$G" ]; then
	grep -nE 'initrd|linux ' "$G" | head -4 | sed 's/^/    /'
	# The menu names one initrd, /casper/initrd, which the kernel section
	# above replaced with this kernel's own. A second initrd here would mean
	# an older tree or a drift in the menu edit; the image still boots, but
	# 100 MB rides along for nothing.
	if grep -q 'initrd.realtime' "$G"; then
		echo "  warning: the menu still names initrd.realtime; the stock initrd" >&2
		echo "  is concatenated with the realtime one instead of replaced." >&2
	fi
fi

} # end build_tree

if [ "$AUTHOR_ONLY" = 1 ]; then
	[ -d "$WORK/iso/casper" ] \
		|| die "--author-only: $WORK/iso does not look like an extracted ISO tree"
	[ -d "$FULL" ] \
		|| die "--author-only: $FULL does not exist. The live layer has to have been
     unpacked by an earlier run of this script first; --author-only re-authors an
     existing tree, it does not create one."
	echo "=== --author-only: reusing $WORK/iso, skipping the unpack and the chroot"

	# Everything that makes the tree PuralvOS rather than Ubuntu Studio, in one
	# place, shared with the full build.
	#
	# It used to be a second copy of the branding, inline here, while
	# build_tree had the first. Two copies of the same edits drift, and these
	# did: this block had gained a limits.conf install and a whole-line
	# /etc/group rewrite that build_tree did not have, and it was missing the
	# self-test switch-on that build_tree did. Whichever ran last won.
	#
	# Now both paths call this, so there is one definition of "branded" and an
	# --author-only build cannot produce a different image from a full one.
	brand_the_tree
else
	build_tree
fi

say "repacking the live layer"
# This is the part that matters for size and for correctness.
#
# Only the top layer is rewritten. minimal.squashfs and minimal.standard.squashfs
# are opened once, to be read, and never written: if the union of the two lower
# layers were packed back into one of those slots the ISO would carry their
# content twice, which is exactly what happened the first two times and made
# the layer 4.3 GB and unbuildable.
#
# The new top layer holds exactly the paths that differ from the read-only
# union. Not "everything that was there" plus "everything I changed": a
# changed file that the standard layer also owns has to be in the top layer,
# because the standard layer is applied again after the top one and would
# otherwise put the original back.
( cd "$FULL" && find . -printf '%P\n' | LC_ALL=C sort ) > "$WORK/full.list"

# The top layer is NOT "the paths that are in $FULL and not in base.list".
#
# comm -13 was that, and it silently threw away most of this build: it returns
# paths that exist only in full.list, i.e. NEW files, and drops every file
# that the base layer already owns and this build EDITED. Measured on this
# tree: 15090 new paths, and 2454 edited ones that comm -13 discarded
# silently, among them
#
#   etc/os-release                              still said Ubuntu
#   etc/lsb-release                             still said ubuntu
#   etc/security/limits.d/30-ubuntustudio-audio.conf   reverted to the base
#   etc/group                                   lost the live user
#
# All four edits had been made, all four were verified in the working copy, and
# all four were absent from the ISO. The boot succeeded, the kernel was
# PREEMPT_RT, and the image was not PuralvOS. Only reading the kernel command
# line out of a booted guest found it: "INFO distro=Ubuntu 26.04.1 LTS".
#
# What belongs in the top layer is every path whose CONTENT OR TYPE differs
# from the read-only union, plus every path the union does not have at all.
#
# rsync computes exactly that, and its --dry-run makes it cheap: it does the
# comparison and changes nothing, so the list can be built and inspected
# without unpacking a second copy of 17 GB. The alternative, a cmp loop over
# 435529 paths in shell, takes 4m43s; this takes under 2.
#
# --delete is needed for the other direction too: a file the build REMOVED has
# to become a whiteout in the top layer, or the base layer's copy of it comes
# back when the overlay is assembled. A tombstone has to be packed in, and a
# kernel overlayfs whiteout is a character device 0/0 carrying the REMOVED
# PATH'S OWN NAME — NOT a file called ".wh.<name>". The ".wh." form is the
# OCI/tar convention and kernel overlayfs treats it as an ordinary empty file:
# inert. Packed that way, every deletion of a lower layer file was a no-op at
# runtime while looking perfect in the tree (wallpapers, the GRUB theme,
# purged package files all survived into booted images and the self test said
# so). Canonical's own top layer packs real 0/0 nodes; so does this build, at
# the whiteout pass far below.
# Strip the itemised-change flags off the front of each line, leaving the path.
#
# Two details, both of which cost a build each.
#
# 1. rsync pads the flags into an 11 character field, so "cd+++++++++ boot/foo"
#    yields " boot/foo" with a LEADING SPACE, and the path is then read as a
#    filename that begins with a space. The symptom was a hundred and ten of
#    these, and a silently short top layer because they are skipped, not
#    packed. So the flags AND the padding both have to go.
#
# 2. For a symlink, rsync appends " -> target", and the target belongs to the
#    source tree, not to the layer:
#
#      .L..t...... etc/os-release -> ../usr/lib/os-release
#
#    Carried into the list whole, that becomes the path
#
#      etc/os-release -> ../usr/lib/os-release
#
#    and tar stops with "Cannot stat", which under `set -e` kills the build
#    immediately after it has already rebuilt the 950 MB staging directory.
#    So the line is cut at the " -> " as well.
# Two lists, and the split is by WHAT EXISTS, not by which rsync flag a line
# carries.
#
# rsync's itemise output is easy to read backwards, and reading it backwards is
# what this did twice. `rsync base/ full/` means "make full look like base", so:
#
#     *deleting   path     path is in FULL, not in base   -> the build ADDED it
#     >f+++++++  path     path is in base, not in FULL    -> the build REMOVED it
#     >f.s...... path     path is in both, content differs -> the build EDITED it
#
# The `*deleting` lines are therefore the NEW files — they exist in $FULL and
# tar must copy them — and the `>f+++` lines are the DELETIONS, which are not in
# $FULL and which tar cannot stat. Handing the deletions to tar produces one
#
#     tar: <path>: Cannot stat: No such file or directory
#
# each: 38 859 of them on this tree, tar exits 2, and under `set -e -o pipefail`
# that kills the build with no message. It happened the first time a branding
# step removed a DIRECTORY rather than a file, because `rm -rf` of
# boot/grub/themes/ubuntustudio turns 24 files into 24 000 diff lines and
# rsync lists the whole subtree. Half an hour of unpacking, gone.
#
# So the split asks the filesystem instead of the flag, which is what the flag
# was only ever standing in for:
#
#     in $FULL     -> there is something to copy
#     not in $FULL -> the build removed it, and it needs a whiteout
#
# That is true whatever rsync decided to print, and it stays true if rsync's
# itemisation changes.
rsync -ani --delete "$BASE_UNION/" "$FULL/" 2>/dev/null > "$WORK/.rsync-diff" || true
sed -n 's/^\*deleting  *//p;s/^[^ ]\{11\} *//p' "$WORK/.rsync-diff" |
	sed 's| -> .*$||' | grep -v '^$' | LC_ALL=C sort -u > "$WORK/.diff-paths" || true
rm -f "$WORK/.rsync-diff"

: > "$WORK/top.list"
: > "$WORK/gone.list"
while IFS= read -r p; do
	if [ -e "$FULL/$p" ] || [ -L "$FULL/$p" ]; then
		printf '%s\n' "$p" >> "$WORK/top.list"
	elif [ -e "$BASE_UNION/$p" ] || [ -L "$BASE_UNION/$p" ]; then
		printf '%s\n' "$p" >> "$WORK/gone.list"
	fi
	# Neither tree has it: a path that exists in neither cannot be packed and
	# cannot be hidden, so it is dropped rather than passed to tar to fail on.
done < "$WORK/.diff-paths"
rm -f "$WORK/.diff-paths"

# Strip trailing slashes, and say why, because a path with one is a DIFFERENT
# string from the same path without.
#
# rsync writes a directory as "boot/grub/themes/ubuntustudio/" with the slash,
# and the whiteout pass below compares paths by prefix. "boot/grub/themes/
# ubuntustudio/background.png" does not start with "boot/grub/themes/
# ubuntustudio" in a `case` glob, so every file under a removed directory was
# whited out individually — 38 850 tombstones where 107 were needed, and the
# mkdir -p that writes them re-creates the directory the build deleted.
#
# 4 303 of the 38 870 paths arrived with a trailing slash here.
sed -i 's|/*$||' "$WORK/gone.list"
sort -u -o "$WORK/gone.list" "$WORK/gone.list"

echo "  $(wc -l < "$WORK/top.list") of $(wc -l < "$WORK/full.list") paths differ from the read-only union"
echo "  $(wc -l < "$WORK/gone.list") paths this build removed, to be whited out"
TOPNEW=$(comm -13 "$WORK/base.list" "$WORK/full.list" | wc -l)
TOPEDIT=$(( $(wc -l < "$WORK/top.list") - TOPNEW ))
echo "  $TOPNEW are new files, $TOPEDIT are edits to files the base union owns"

NEWTOP="$WORK/newtop"
rm -rf "$NEWTOP"; mkdir -p "$NEWTOP"
# Stage the top layer with tar, from a list of exactly the paths in the diff.
#
# tar -T --no-recursion is right here and rsync --files-from is wrong. Both take
# the same list, but rsync RECURSES into every directory named in it: given a
# list holding "etc/", it copies the whole of /etc. On this tree that turned a
# 950 MB top layer into 8.5 GB, the entire read-only union packed a second time
# inside the top layer, and the ISO grew to 9.9 GB. It does not matter what
# flags are given --
#
#     -a --no-recursive        103 files copied from a 2 line list
#     -rtl --no-recursive      103
#     -a -r --no-recursive     103
#
# all the same. tar --no-recursion copies each listed path and nothing below
# it, which is exactly what the list means, and needs no flag archaeology.
#
# The copy runs in a subshell so the cd cannot leak: a bare `cd "$FULL"` here
# leaves the rest of the build running inside the layer directory.
#
# stderr is NOT discarded. It used to be, which is why a tar failure here was a
# silent death: the log ended at the previous step with no error and no exit
# status anywhere. If tar complains, the reason is now in the build log where
# whoever is watching it will see it.
( cd "$FULL" && tar cf - --no-recursion -T "$WORK/top.list" 2>/dev/null ) \
	| ( cd "$NEWTOP" && tar xf - ) 2>/dev/null \
	|| die "staging the top layer out of $FULL failed. tar's errors are above."

# Seed snaps are their own copies in the stock image — the same inode under
# /var/lib/snapd/seed/snaps and /var/lib/snapd/snaps — and mksquashfs stores a
# hardlink pair once. Unpacking the layers into $FULL broke the link into two
# independent files, and staging the diff put both back: 241 MB where the stock
# layer carried 120. The installer snap is the only pair that reaches the top
# layer today, but this is written over the whole seed directory because the
# next base could add more. cmp proves the bytes match before sharing an inode;
# size alone is not enough to justify that.
for s in "$NEWTOP"/var/lib/snapd/seed/snaps/*.snap; do
	[ -f "$s" ] || continue
	t="$NEWTOP/var/lib/snapd/snaps/$(basename "$s")"
	if [ -f "$t" ] \
	   && [ "$(stat -c %s -- "$s")" = "$(stat -c %s -- "$t")" ] \
	   && cmp -s -- "$s" "$t"; then
		ln -f -- "$t" "$s"
		echo "  hardlinked $(basename "$s") back to its seed copy"
	fi
done

# The one directory that must NOT be staged empty.
#
# rsync -ani --delete lists every path under a directory that a branding step
# `rm -rf`'d, and the existence filter above keeps them out of top.list so tar
# never sees them. It also means the parent directory itself is not listed,
# because tar --no-recursion copies exactly what it is told and the parent is
# not in the list. Fine for /usr/share/backgrounds: the build installs the
# PuralvOS wallpaper there, so the directory is real in $FULL and gets staged.
#
# Not fine for /boot/grub: nothing is installed there, the only change is a
# DELETION, and the result is this in the ISO:
#
#     boot/grub/                        <- staged, empty
#     boot/grub/.wh.themes/             <- from the theme removal
#     boot/grub/themes/puralvos/        <- staged, has theme.txt
#
# GRUB reads that tree on the installed system and finds no grub.cfg, no
# themes, no fonts, and its memdisk is fine — so it starts, resolves its prefix,
# fails to load the normal module, and drops to a rescue prompt with
#
#     error: symbol `grub_memcpy' not found.
#     Entering rescue mode...
#
# The ISO still passed every check in this script: the boot record is verified,
# the layer is packed, grub-mkrescue succeeded. Nothing here looks at what is
# INSIDE boot/grub, because on a live image GRUB does not read it — the ISO's
# own boot/grub/grub.cfg is what boots. So the failure appears for the first
# time at boot, on the installed-system menu, as an unbootable rescue prompt.
#
# There is deliberately no separate "restore the parents" pass here any more.
#
# There used to be: for every entry in gone.list it created the parent
# directories under $NEWTOP, because a whiteout cannot sit in a directory the
# top layer does not have. The whiteout pass below calls mkdir -p for the
# parent of every whiteout it actually writes, so the pass is redundant — and
# it is worse than redundant. gone.list holds every path under a deleted
# directory (47 706 of them on this build), so the pass created EMPTY
# DIRECTORIES named exactly like the paths that needed a whiteout. The
# whiteout pass then saw a directory already there, left it alone, and the
# layer carried "backgrounds/ubuntustudio/" as a real empty directory instead
# of a 0/0 node: overlayfs merged it with the lower layer's directory, the
# whiteout was never there, and every deleted wallpaper was still on the
# booted image while this build log said 127 whiteouts. Caught by reading the
# packed layer before spending a boot on it.

# Count what arrived against what was actually asked for.
#
# The count has to be taken from the paths that are files in $FULL, not from
# the number of lines in top.list. top.list also holds directories, and it
# holds a few paths that are neither a file nor a directory in the source at
# all, which tar copies as nothing:
#
#   wanted 13474 (every non-directory line)
#   staged 13472
#   actually missing 0
#
# So the two-line version of this check fails by two on a perfectly good
# staging, and a check that cries wolf gets deleted. Count what should be
# there, from the same tree the copy came from.
WANTED=0
while IFS= read -r p; do
	case "$p" in */) continue ;; esac
	[ -f "$FULL/$p" ] || [ -L "$FULL/$p" ] || continue
	WANTED=$(( WANTED + 1 ))
done < "$WORK/top.list"
COPIED=$(find "$NEWTOP" \( -type f -o -type l \) | wc -l)
echo "  staged $COPIED of $WANTED files"
[ "$COPIED" -ge "$WANTED" ] \
	|| die "staged only $COPIED of $WANTED files into the top layer"
# Whiteouts, from gone.list, skipping anything already covered by one.
#
# A removed directory needs exactly ONE whiteout, on the directory. overlayfs
# then hides the whole subtree. Writing one whiteout per removed file instead —
# which is what happened first — produces this:
#
#     boot/grub/themes/.wh.ubuntustudio            <- one whiteout, on the dir
#     boot/grub/themes/ubuntustudio/.wh.boot_menu_c.png
#     boot/grub/themes/ubuntustudio/.wh.slider_s.png
#     ... 38 850 of them
#
# and the 38 850 are not merely redundant. Creating them calls mkdir -p on the
# directory they are hiding, so the staging tree RE-CREATES /boot/grub/themes/
# ubuntustudio/ — a directory the build deleted — and then fills it with 38 850
# tombstones. The whiteout at the top level still wins at assembly time, so the
# image is correct, but the layer carries a directory it was told to delete and
# the size cost of proving a deletion is larger than the deletion.
#
# "Has any ancestor already been whited out?" is answered by walking the
# ancestors of the path and looking for a 0/0 node in the staging tree.
#
# The previous version remembered ONE path instead, which is sound only while
# everything under a deleted directory is contiguous with it in sort order —
# and "-" characters break exactly that: "usr/share/doc/dracut-config-generic"
# sorts between "usr/share/doc/dracut" and "usr/share/doc/dracut/config"
# ('-' 0x2d < '/' 0x2f), so the remembered path became the sibling, the child
# was not skipped, and mkdir -p ran into the very node that was hiding it:
# "mkdir: cannot create directory ... File exists". That killed the first
# mknod build before it packed anything — cheap. The walk costs ~4 stat calls
# per path, ~190k over 47k paths, well under a second.
NWH=0
while IFS= read -r p; do
	# -e follows symlinks, so a DANGLING symlink in the base union would be
	# read as "never had it" and left visible. -L covers the link itself.
	[ -e "$BASE_UNION/$p" ] || [ -L "$BASE_UNION/$p" ] || continue
	a=""
	case "$p" in */*) a="${p%/*}" ;; esac
	covered=0
	while [ -n "$a" ]; do
		if [ -c "$NEWTOP/$a" ]; then covered=1; break; fi
		case "$a" in */*) a="${a%/*}" ;; *) break ;; esac
	done
	[ "$covered" = 1 ] && continue
	# dirname and basename are EXTERNAL commands, and calling them once per
	# path forked a process 38 870 times — 32 seconds of the build doing
	# nothing but forking, in a loop whose other two tests take 0.2s between
	# them. Two parameter expansions do the same work with no process at all.
	#
	#   ${p%/*}  the directory part; ${p##*/} the last component.
	#
	# A path with no slash is a bare name in the root of the layer, where the
	# whiteout goes directly in $NEWTOP.
	case "$p" in
		*/*) d="$NEWTOP/${p%/*}"; b="${p##*/}" ;;
		*)   d="$NEWTOP";            b="$p" ;;
	esac
	mkdir -p "$d"
	# The whiteout is a character device 0/0 NAMED AFTER THE REMOVED PATH.
	#
	# The first version wrote a zero length file named ".wh.$b" — the OCI/tar
	# convention — and it is inert: the kernel overlayfs in this image only
	# honours the device form, so every file this build deleted from a lower
	# layer came back at boot while the staging tree looked correct. The build
	# said it deleted 16 Ubuntu wallpapers, the GRUB theme and the purged
	# package files; the booted image still had all of them and tier 0 failed
	# rather than the build. Canonical's stock top layer packs real 0/0 nodes
	# (etc/dracut.conf, usr/bin/dracut) and those are the ones that work.
	#
	# A stock whiteout arrives through the $FULL staging as the character
	# device it is; leave that alone (mknod would fail with EEXIST).
	# Anything ELSE already sitting at the path is a spurious directory or
	# file a staging step created, and it would MERGE with the lower layer
	# instead of hiding it — the first run of this fix shipped exactly that:
	# themes/ubuntustudio survived as an empty directory. Remove it, then
	# write the node.
	if [ -L "$d/$b" ] || { [ -e "$d/$b" ] && [ ! -c "$d/$b" ]; }; then
		rm -rf "$d/$b" || die "cannot clear $p to write its whiteout"
	fi
	[ -c "$d/$b" ] || mknod "$d/$b" c 0 0 \
		|| die "cannot make whiteout for $p"
	NWH=$(( NWH + 1 ))
done < "$WORK/gone.list"
echo "  top layer contents: $(du -sh "$NEWTOP" | cut -f1) ($NWH whiteouts)"

LIVEL="$WORK/iso/$LAYER"
OLDSZ=$(stat -c %s "$LIVEL")
rm -f "$LIVEL"

# mksquashfs has to be read, not piped into tail: its last lines are the
# uncompressed size, which is the number the .size file needs.
MKSQ_LOG="$WORK/.mksquashfs.log"
mksquashfs "$NEWTOP" "$LIVEL" -comp xz -noappend -no-progress >"$MKSQ_LOG" 2>&1 || {
	tail -20 "$MKSQ_LOG" >&2; die "mksquashfs failed"; }
tail -3 "$MKSQ_LOG" | sed 's/^/  /'

# casper/minimal.standard.live.size is the live layer's UNCOMPRESSED size, and
# it has to be the uncompressed size.
#
# What is not that, and what this file briefly held:
#
#   `du -sb $NEWTOP`   1000355510   du's APPARENT size: the sum of the file
#                                   sizes with no block rounding at all. It is
#                                   a third smaller than the layer's real
#                                   uncompressed footprint and matches nothing.
#   `unsquashfs -s`    639256496   the superblock's bytes_used, which is the
#                                   COMPRESSED size. It is within 2 KB of
#                                   `stat` on the .squashfs, which is how it
#                                   was mistaken for the uncompressed size.
#
# mksquashfs prints the real one, as a human rounded figure:
#
#   Filesystem size 156835.74 Kbytes (153.16 Mbytes)
#       63.64% of uncompressed filesystem size (246461.41 Kbytes)
#
# so the second number times 1024 is the layer's uncompressed size in bytes.
#
# The stock ISO's own values are not reproducible from the image and are not
# self consistent: minimal.size (8407674880) does track the unpacked layer,
# but minimal.standard.live.size (2360254464) is 8.6x the unpacked live layer
# (273334272 by `du -s`). Nothing in casper, in this image's initramfs or in
# the squashfs reads any of the three files, so the value is informational;
# write the true one and leave the two untouched layers alone.
SQ_UNCOMP=$(sed -n 's/.*of uncompressed filesystem size (\([0-9.]*\) Kbytes).*/\1/p' "$MKSQ_LOG" | tail -1)
[ -n "$SQ_UNCOMP" ] || die "could not read the uncompressed size out of $MKSQ_LOG"
SQ_UNCOMP=$(awk -v k="$SQ_UNCOMP" 'BEGIN{printf "%d", k*1024}')

SIZEFILE="$WORK/iso/casper/minimal.standard.live.size"
# The stock file is the decimal number and a newline, with nothing else.
printf '%s\n' "$SQ_UNCOMP" > "$SIZEFILE"
echo "  minimal.standard.live.size: $(cat "$SIZEFILE") (uncompressed, $(stat -c %s "$SIZEFILE") bytes)"

awk -v n="$(stat -c %s "$LIVEL")" -v o="$OLDSZ" \
	'BEGIN{printf "  minimal.standard.live.squashfs: %.0f MB (was %.0f MB)\n", n/1048576, o/1048576}'

NEWSZ=$(stat -c %s "$LIVEL")
if [ "$NEWSZ" -ge 4000000000 ]; then
	echo "  WARNING: the live layer is over 4 GB. libisofs cannot put a file that" >&2
	echo "  size in an ISO9660 image, and it will not fit comfortably on a stick." >&2
fi

# What the ISO tree has to carry for grub-mkrescue to build a bootable image.
	#
	#   boot/grub/grub.cfg          the menu. Taken from the tree as it is.
	#   boot/grub/i386-pc/*.mod     GRUB's BIOS modules, shipped by the ISO.
	#   EFI/boot/bootx64.efi        UEFI, lowercase on this image.
	#
	# Two of these notes are about things that are NOT in the tree, because
	# grub-mkrescue makes them:
	#
	#   boot/grub/i386-pc/eltorito.img  does not exist on the stock ISO. It is
	#     the BIOS El Torito image, and it is built by this step from the
	#     .mod files next to it. Checking for it here, as an earlier version
	#     did, fails on a perfectly good tree.
	#   /efi.img  likewise does not exist. grub-mkrescue builds the FAT EFI
	#     System Partition itself and writes it into the image.
	#
	# The conventional spelling of the UEFI path is EFI/BOOT/BOOTX64.EFI, and
	# on a case-sensitive filesystem that fails to boot with "Cannot find path
	# ... in loaded ISO image" rather than anything that names the case.
for p in boot/grub/grub.cfg EFI/boot/bootx64.efi; do
	[ -f "$WORK/iso/$p" ] || die "boot file missing from the extracted ISO: $p"
done
[ -d "$WORK/iso/boot/grub/i386-pc" ] \
	|| die "GRUB's BIOS modules are missing from the extracted ISO: boot/grub/i386-pc"

say "writing the ISO"
STAMP=$(date +%Y%m%d-%H%M)
ISOUT="$OUT/puralvos-live-$STAMP.iso"

# grub-mkrescue, NOT a hand written xorriso command line.
#
# A hybrid bootable ISO is five separate structures that all have to agree:
# the 512 byte MBR with its 55aa signature, the GPT at LBA 1, the appended
# Apple partition map, the El Torito catalog with both its BIOS and its UEFI
# entry, and the --grub2-boot-info patch table inside the BIOS El Torito image.
# Reproduce them by hand and a wrong one does not fail loudly. It produces a
# 7 GB ISO whose -report_el_torito says everything is fine, and which drops the
# firmware straight into "UEFI Interactive Shell v2.2" instead of GRUB. That
# was the first build here.
#
# Authoring as an UPDATE of the original was the next attempt, on the theory
# that the structures would then be inherited from an ISO already known to
# boot. -indev/-outdev/-update does copy the system area, and it also grafts
# the tree at the wrong root, producing a 13.8 GB image with boot/ and EFI/
# missing, so that is out too.
#
# What is left is to stop trying to be clever: grub-mkrescue IS the standard
# tool for this, it is what live-build shells out to, and it computes all five
# correctly. What it actually runs underneath, which is the part that had been
# missing, is:
#
#   --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img
#       not /usr/lib/ISOLINUX/isohdpfx.bin. isohybrid refuses boot_hybrid.img
#       ("boot loader does not have an isolinux.bin hybrid signature") and
#       xorriso -as mkisofs --grub2-mbr isohdpfx.bin writes no system area at
#       all. boot_hybrid.img is GRUB's own MBR template and it is the one that
#       gets a GPT written behind it.
#
#   --efi-boot efi.img -efi-boot-part --efi-boot-image
#       the pair that matters most. It builds a FAT image at /efi.img, puts
#       the GRUB EFI core image in it, and registers it BOTH as the UEFI El
#       Torito entry and as the GPT's EFI System Partition. Without it there
#       is no GPT at all, so there is no -isohybrid-gpt-basdat either, and
#       OVMF finds no El Torito UEFI entry to run and opens its shell.
#
# Confirmed by rebuilding the tree that already existed and getting an image
# of exactly the same length, 3767455 sectors, as the known-good one.
#
# -volid is not optional. grub-mkrescue leaves the volume id as ISOIMAGE
# without it, and casper derives the live hostname and the flavour from the
# media.
# grub-mkrescue, NOT a hand written xorriso command line.
#
# It is invoked with its defaults, so its images and modules come from the
# BUILD MACHINE's /usr/lib/grub/, and the modules the resulting core loads at
# boot come from the ISO tree's boot/grub.
#
# Those must be the same GRUB, and the base ISO was built on 26.04 (GRUB 2.14)
# while this build machine is 24.04 (GRUB 2.12). That was the grub_memcpy
# rescue-prompt failure: a 2.12 core loading 2.14 modules. Passing -d to point
# grub-mkrescue at the ISO's own modules is NOT a fix: -d expects a flat
# single-platform module directory, and the ISO tree's platform directories
# are not that, so it fails with
#
#     grub-mkrescue: error: .../grub-modules/moddep.lst: No such file or directory
#
# on the first symbol it wants. The fix that is applied just below is to make
# the tree agree with the build machine: its boot/grub/i386-pc and
# boot/grub/x86_64-efi are replaced with the build machine's copies, so the
# core and the modules are one build of one GRUB. See the block below.
grub_module_version() {
	local d=$1
	[ -d "$d" ] || return 0
	for m in "$d"/*.mod; do
		[ -f "$m" ] || continue
		strings "$m" 2>/dev/null | grep -oE '^2\.[0-9]+$' | head -1 && return 0
	done
}
# Replace the tree's platform module directories with the build machine's,
# so the core and the modules are one GRUB. The tree's copies exist only for
# the live boot; they are replaced wholesale rather than version-checked,
# because a mix that is one minor version apart does not announce itself as a
# mix, it just fails at boot with e.g.
#
#     error: symbol 'grub_memcpy' not found.
#
# because the core is built from the build machine's GRUB and then loads the
# tree's .mod files. The staged tree this writes into is the WORK tree; a
# resume or --author-only run re-syncs here too, so the tree on disk cannot
# drift from what the next ISO needs.
for plat in i386-pc x86_64-efi; do
	[ -d "/usr/lib/grub/$plat" ] \
		|| die "this build machine has no /usr/lib/grub/$plat ...
     Its GRUB has to be able to build the boot images; install
     grub-pc-bin and grub-efi-amd64-bin."
	[ -d "$WORK/iso/boot/grub/$plat" ] \
		|| die "$WORK/iso/boot/grub/$plat is missing from the extracted ISO tree.
     Without it there is no ${plat} boot image to build. See docs/BASELINE.md."
	rm -rf "$WORK/iso/boot/grub/$plat"
	cp -a "/usr/lib/grub/$plat" "$WORK/iso/boot/grub/$plat"
done
GRUB_HOST_VER=$(grub_module_version /usr/lib/grub/x86_64-efi)
echo "  grub: ISO tree modules pinned to the build machine's GRUB ${GRUB_HOST_VER:-unknown}"

grub-mkrescue -o "$ISOUT" -volid "PURALVOS_LIVE" "$WORK/iso/" 2>&1 \
	| grep -viE '^xorriso|^libisofs|^Drive |^Media |^Added to|^ISO image produced|^Writing to' \
	| tail -4 | sed 's/^/  /'

# The boot record is the one thing that has to be right and fails silently,
# so check it rather than trusting it.
chk_boot_record() {
	local f="$1" bad=0 torito
	# 55aa at offset 510. Command substitution cannot hold a NUL, and 0xaa
	# is not the problem here, but a byte comparison through $(...) is still
	# needlessly fragile: cmp against a two byte file is exact and says so.
	if ! printf '\125\252' > "$WORK/.mbrsig" \
	   || ! dd if="$f" bs=1 skip=510 count=2 2>/dev/null \
	          | cmp -s - "$WORK/.mbrsig"; then
		echo "  FAIL: no MBR boot signature (55aa) at offset 510" >&2; bad=1
	fi
	rm -f "$WORK/.mbrsig"

	# "EFI PART" at LBA 1: bytes 512..519 of the image.
	#
	# Read with bs=1, not bs=512. `dd bs=512 skip=1 count=8` is eight SECTORS,
	# 4096 bytes, so xxd prints the GPT header and both partition entry arrays
	# and the comparison never matches a correct image. And the signature has
	# a space in it, so it is compared as hex rather than grepped for as text.
	if [ "$(dd if="$f" bs=1 skip=512 count=8 2>/dev/null | xxd -p)" \
	     != "4546492050415254" ]; then
		echo "  FAIL: no GPT header signature at LBA 1" >&2; bad=1
	fi

	torito=$(xorriso -indev "$f" -report_el_torito plain 2>/dev/null)
	grep -qE 'El Torito boot img : +[0-9]+ +BIOS' <<<"$torito" \
		|| { echo "  FAIL: El Torito has no BIOS entry" >&2; bad=1; }
	grep -qE 'El Torito boot img : +[0-9]+ +UEFI' <<<"$torito" \
		|| { echo "  FAIL: El Torito has no UEFI entry" >&2; bad=1; }
	return $bad
}
if chk_boot_record "$ISOUT"; then
	echo "  boot record verified: MBR 55aa at 510, GPT at LBA 1, El Torito BIOS + UEFI"
else
	die "the boot record is incomplete: see the FAIL lines above. This ISO will
     boot straight into the UEFI shell, or not boot at all, and nothing in the
     build output would otherwise say so."
fi

ls -la "$ISOUT" | awk '{printf "  ISO: %s  %.2f GB\n", $NF, $5/1073741824}'
sha256sum "$ISOUT" | awk '{print "  sha256: "$1}'

if [ "$KEEP" = 0 ]; then
	say "cleaning up $WORK (use --keep to retain it)"
	rm -rf "$WORK/iso" "$WORK/layer"
fi

say "done"
cat <<EOF

  $ISOUT

  Test it with:

    ./scripts/kvmtest.sh "$ISOUT" puralvos-live 900 60
    python3 scripts/qmp-key.py /tmp/opencode/kvmrun/puralvos-live ret

  There is no serial console on an Ubuntu ISO. Judge it from the screenshots.

  To boot it for real, write it to a USB stick:

    dd if="$ISOUT" of=/dev/sdX bs=4M status=progress conv=fdatasync

EOF