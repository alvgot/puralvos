#!/bin/bash
# build-live.sh - build the PuralvOS Graphics live image from the stock Ubuntu
# Studio ISO.
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
#      does not add this is a generic kernel wearing the name.
#   2. Our branding: wallpapers, the mark, os-release, boot menu.
#   3. The real time limits file, which no package installs by itself.
#   4. A first boot hook that puts the live user in the audio and video groups.
#   5. Removal of the audio, video, photography and publishing tasks,
#      leaving the graphics task and its runtime dependencies.
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
#
# Environment:
#   PURALVOS_INSTALLER=1  build the INSTALLABLE variant. Default is the Live
#                         image: snapd and the snap installer are masked,
#                         which is worth about 8 s of first boot (measured).
#   PURALVOS_SELFTEST=1   add console=ttyS0,115200n8 and puralvos.selftest=1
#                         to every menu entry (verification builds only).
#   PURALVOS_DIAG=1       the same, with puralvos.diag=1 for the diag unit.
#   PURALVOS_WORK=DIR     build under DIR (needs ~45 GB free).
#   PURALVOS_OUT=DIR      write the ISO to DIR (default: repo out/).

set -euo pipefail

# say and die are used by pick_work below, which runs while WORK is still being
# decided, so they have to exist before it. Defining them further down is why
# a machine without 45 GB free used to print "die: command not found" and carry
# on with WORK empty: the failure message was the thing that failed, and the
# real error, "no filesystem found with 45 GB free", never appeared.
say() { printf '\n=== %s\n' "$*"; }
die() { printf 'build-live: %s\n' "$*" >&2; exit 1; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT="PuralvOS Graphics"
PRODUCT_SLUG="puralvos-graphics"
BASE_ISO="$REPO/base/ubuntustudio-26.10-desktop-amd64.iso"
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
		sed -i -e "s#^NAME=.*#NAME=\"$PRODUCT\"#" \
		       -e "s#^PRETTY_NAME=.*#PRETTY_NAME=\"$PRODUCT 26.10\"#" \
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
	       -e "s/^DISTRIB_NAME=.*/DISTRIB_NAME=\"$PRODUCT\"/" \
	       -e "s/^DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION=\"$PRODUCT 26.10\"/" \
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
#     Ubuntu 26.10
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
	printf '%s 26.10 \\n \\l\n' "$PRODUCT" > "$issue"
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
# this file assumed ("PuralvOS 26.10 - Live amd64" looked tidy and cost
# a whole verification boot). The desktop installer — ubuntu-desktop-
# bootstrap, the window the live session opens by itself — parses this file
# too, and it wants the stock shape:
#
#     <Flavour> <version> <LTS?> "<codename>" - <Release|Official> amd64 (<date>)
#
# Its Flutter binary reads the quoted codename (a "get:codeName" symbol and
# the dynamic "installationTypeTPMInfo<CodeName>" message keys live in
# libapp.so) and a line without it is not a display problem: the installer
# fails its parse, shows "Something went wrong" instead of the install
# screens, and the reason is nowhere on screen. The base image's line is
# "Ubuntu-Studio 26.10 \"Stonking Stingray\" - Official amd64 (20261014)";
# this keeps every field of that except the name and the word Official, so
# casper still reads "puralvos" off the first token and the installer finds
# its codename. 26.10 is an interim release, so no "LTS" appears, exactly as
# the stock line has none.
if [ -f "$WORK/iso/.disk/info" ]; then
	printf 'PuralvOS 26.10 "Stonking Stingray" - Release amd64 (%s)\n' \
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
	# The menu says what this build can do. A Live build has no installer,
	# so it must not offer one; the strings are still the stock ones at this
	# point, which is why the substitution is anchored on them.
	if [ "${PURALVOS_INSTALLER:-0}" = "1" ]; then
		MENU_NAME="$PRODUCT Live — install or try out"
	else
		MENU_NAME="$PRODUCT Live — try out"
	fi
	sed -i \
	  -e "s/Try or Install Ubuntu Studio/$MENU_NAME/" \
	  -e "s/Ubuntu Studio (safe graphics)/$PRODUCT Live (safe graphics)/" \
	  -e 's/^set timeout=.*/set timeout=1/' \
	  -e '/^grub_platform$/d' \
	  "$G"
	# Realtime parity and a second or two of early boot: no speculative
	# execution mitigations, no softlockup watchdog. Both are what the
	# lowlatency kernel's own boot arguments do on Ubuntu Studio, and both are
	# product decisions for a workstation rather than a server.
	if ! grep -q 'mitigations=off' "$G"; then
		# loglevel=0 keeps the console silent from GRUB to the greeter: the
		# Bluetooth stack on some laptops prints firmware/command complaints
		# during probe, and systemd prints red FAILED lines for units that are
		# allowed to fail. Both still reach the journal and dmesg; neither is
		# something a person booting a workstation should have to read past.
		sed -i -E 's|^([[:space:]]*linux[[:space:]]+/casper/vmlinuz)([[:space:]])|\1 mitigations=off nowatchdog loglevel=0 vt.global_cursor_default=0 systemd.show_status=0\2|' "$G"
	fi
	echo "  menu entries now:"
	grep -E '^\s*menuentry' "$G" | sed 's/^/    /'
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

# A known local account.
#
# The live session logs itself in as `puralvos`: casper creates that account at
# boot from .disk/info, pinned to uid 1000 (25adduser in the initrd does
# `db_set passwd/user-uid 1000`). `puralv` is an ordinary account that exists
# in the image, password `puralv`, for logging in at SDDM or over ssh instead
# of the autologin account. useradd picks the next free uid (1001 on the stock
# tree), deliberately not 1000: a collision there would leave casper unable to
# create the live session's own user.
#
# The groups are the usual desktop user's set plus audio and video, which are
# the ones this image exists for; sudo matches what the first account of an
# installed system gets.
if ! chroot "$FULL" getent passwd puralv >/dev/null; then
	chroot "$FULL" useradd -m -u 1001 -s /bin/bash \
		-G adm,audio,cdrom,dialout,dip,plugdev,sudo,video puralv
fi
echo 'puralv:puralv' | chroot "$FULL" chpasswd
echo "  user puralv: uid $(chroot "$FULL" id -u puralv), password set"

# Pre-create the live user (puralvos, uid 1000) so SDDM autologin works.
# Casper creates this user at boot, but SDDM starts before casper finishes
# and needs the user to exist in /etc/passwd for autologin.
LIVE_USER=$(sed -n '1s/[[:space:]].*//p' "$WORK/iso/.disk/info" | tr '[:upper:]' '[:lower:]')
if ! chroot "$FULL" getent passwd "$LIVE_USER" >/dev/null; then
	chroot "$FULL" useradd -m -u 1000 -s /bin/bash \
		-G adm,audio,cdrom,dialout,dip,plugdev,sudo,video "$LIVE_USER"
fi
# No password needed for autologin, but set one for console access
echo "$LIVE_USER:$LIVE_USER" | chroot "$FULL" chpasswd
echo "  live user $LIVE_USER: uid $(chroot "$FULL" id -u "$LIVE_USER"), password set"

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

# The self test runs a comprehensive verification and opens every application,
# so it is opt-in. A production live session must not pay that cost; a
# verification build (PURALVOS_SELFTEST=1) must actually run the thing the
# kernel command line asks for, so the two decisions are made together here.
if [ "${PURALVOS_SELFTEST:-0}" = 1 ]; then
	chroot "$FULL" systemctl enable puralvos-selftest.service >/dev/null 2>&1 \
		|| die "could not enable puralvos-selftest.service in the chroot"
	[ -L "$FULL/etc/systemd/system/multi-user.target.wants/puralvos-selftest.service" ] \
		|| die "puralvos-selftest.service did not get enabled"
	echo "  self test unit: enabled (verification build)"
else
	chroot "$FULL" systemctl disable puralvos-selftest.service >/dev/null 2>&1 || true
	rm -f "$FULL/etc/systemd/system/multi-user.target.wants/puralvos-selftest.service"
	echo "  self test unit: disabled for live session (faster boot)"
fi

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

# Hide specific autostart entries (e.g., applications we don't want to start automatically)
hide_autostart_entries() {
	local autostart_dir="$FULL/etc/xdg/autostart"
	local entry
	for entry in "$@"; do
		local file="$autostart_dir/$entry"
		[ -f "$file" ] || continue
		grep -qE '^(Hidden|X-GNOME-Autostart-enabled)=false|^Hidden=true' "$file" && continue
		# Hidden=true is the XDG autostart key that means "do not start".
		# NoDisplay=true only keeps an entry out of menus, and setting it here
		# instead (as this did) left every "hidden" application starting at
		# login, which is the exact complaint this function exists to fix.
		sed -i '1i # Hidden by PuralvOS: this autostart entry must not run.\n# See tools/build-live.sh:hide_autostart_entries\nHidden=true\nNoDisplay=true' "$file"
		echo "  hid autostart entry: $entry"
	done
}

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
	# NEW is the intended list. It used to be "the live user alone", but
	# puralv is a real account that belongs in audio too, and useradd has
	# already put it there; demanding a one-name list would now fail on a
	# correct file.
	if [ "$(awk -F: '/^audio:/{print $4}' "$FULL/etc/group.puralvos-new")" = "$NEW" ]; then
		cat "$FULL/etc/group.puralvos-new" > "$FULL/etc/group"
		rm -f "$FULL/etc/group.puralvos-new"
	else
		rm -f "$FULL/etc/group.puralvos-new"
		die "could not rewrite the audio group in $FULL/etc/group"
	fi
fi

# Membership, not sole membership: the list is allowed to hold other real
# accounts, it is not allowed to miss the live user.
AUDIO_MEMBERS=",$(awk -F: '/^audio:/{print $4}' "$FULL/etc/group"),"
case "$AUDIO_MEMBERS" in
	*",$LIVE_USER,"*)
		echo "  live user $LIVE_USER is in the audio group: $(awk -F: '/^audio:/{print $4}' "$FULL/etc/group")" ;;
	*)
		echo "  WARNING: live user $LIVE_USER is NOT in the audio group" >&2
		echo "           audio group is now: $(awk -F: '/^audio:/{print $4}' "$FULL/etc/group")" >&2 ;;
esac

# Devede 4.21 ships a desktop entry whose TryExec/Exec name /usr/bin/devede,
# while the package installs /usr/bin/devede_ng. On the first video build the
# hygiene pass hid the entry as a dead launcher even though the application was
# installed. Point it at the binary the package actually ships, and clear the
# NoDisplay line an earlier run of this function may have added.
DEV="$FULL/usr/share/applications/devede_ng.desktop"
if [ -x "$FULL/usr/bin/devede_ng" ] && [ -f "$DEV" ]; then
	sed -i -e 's#^TryExec=/usr/bin/devede$#TryExec=/usr/bin/devede_ng#' \
	       -e 's#^Exec=/usr/bin/devede$#Exec=/usr/bin/devede_ng#' \
	       -e '/^# Hidden by PuralvOS: the executable this entry names is not installed\.$/d' \
	       -e '/^# See tools\/build-live.sh:fix_desktop_entries$/d' \
	       -e '/^NoDisplay=true$/d' "$DEV"
	echo "  devede menu entry: Exec corrected to /usr/bin/devede_ng"
fi

# PikoPixel ships a GNUstep desktop entry that launches through openapp(1).
# openapp needs dpkg-architecture, which the toolchain trim removes, so the
# menu entry dies with "Can't find the required application" while the
# PikoPixel binary itself is installed and works. Point the entry at the
# binary the package ships.
PIKO="$FULL/usr/share/applications/PikoPixel.desktop"
if [ -x "$FULL/usr/bin/PikoPixel" ] && [ -f "$PIKO" ]; then
	sed -i -e 's#^Exec=/usr/bin/openapp PikoPixel %F$#Exec=/usr/bin/PikoPixel %F#' \
	       -e '/^# Hidden by PuralvOS: the executable this entry names is not installed\.$/d' \
	       -e '/^# See tools\/build-live.sh:fix_desktop_entries$/d' \
	       -e '/^NoDisplay=true$/d' "$PIKO"
	echo "  pikopixel menu entry: Exec corrected to /usr/bin/PikoPixel"
fi

say "desktop entry hygiene"
fix_desktop_entries

# Hide unwanted autostart entries (e.g., applications we don't want to start automatically)
hide_autostart_entries \
	ardour.desktop \
	gimp.desktop \
	audacity.desktop \
	in.desktop \
	blender.desktop \
	kdenlive.desktop \
	krita.desktop \
	mixxx.desktop \
	shotcut.desktop \
	baloo_file.desktop \
	geoclue-demo-agent.desktop \
	kup-daemon.desktop \
	orca-autostart.desktop \
	snap-userd-autostart.desktop \
	org.kde.discover.notifier.desktop \
	pam_kwallet_init.desktop \
	z-displaycal-apply-profiles.desktop \
	org.kde.plasma-fallback-session-restore.desktop

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

# Enable the display manager (SDDM) so the live session actually starts
# The wait-for-snapd-seeding.conf drop-in delays display-manager.service until
# snapd.seeded.service completes, but display-manager.service must be enabled
# (symlinked into multi-user.target.wants) for this to work at all.
# The sddm.service file is in the base-union, not in the layer squashfs,
# so we create the symlinks directly in the layer filesystem.
ln -sf /usr/lib/systemd/system/sddm.service "$FULL/etc/systemd/system/display-manager.service"
ln -sf /usr/lib/systemd/system/sddm.service "$FULL/etc/systemd/system/multi-user.target.wants/display-manager.service"
echo "  display manager: sddm enabled (via display-manager.service)"

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

# The light counterpart. The stock desktop ships the same theme in light and
# dark, and the first audio-only boot review asked for the light one back: a
# workstation used all day needs it. This is the stock light theme with this
# product's names, copied before the deletion loop below runs, and pointed at
# the same wallpaper. Everything it references is already in the image:
# ColorScheme=Orchis, Theme=puralvos (the renamed light Plasma style), Icon
# Theme=puralvos, kvantum and the Orchis window decoration.
if [ -d "$LF/org.ubuntustudio.desktop" ]; then
	rm -rf "$LF/org.puralvos-light.desktop"
	cp -a "$LF/org.ubuntustudio.desktop" "$LF/org.puralvos-light.desktop"
	grep -rIl 'Ubuntu Studio\|ubuntu-studio\|ubuntustudio' \
		"$LF/org.puralvos-light.desktop" 2>/dev/null |
	while IFS= read -r f; do
		sed -i \
			-e 's/Ubuntu Studio/PuralvOS/g' \
			-e 's/ubuntu-studio-devel@ubuntu\.com/alvgot@users.noreply.github.com/g' \
			-e 's#https://www\.ubuntustudio\.org#https://github.com/alvgot/puralvos#g' \
			-e 's/org\.ubuntustudio\.desktop/org.puralvos-light.desktop/g' \
			-e 's/ubuntustudio/puralvos/g' \
			"$f"
	done
	sed -i 's/"Name": "PuralvOS"/"Name": "PuralvOS Light"/' \
		"$LF/org.puralvos-light.desktop/metadata.json"
	D="$LF/org.puralvos-light.desktop/contents/defaults"
	if [ -f "$D" ]; then
		sed -i -e 's/^Image=.*/Image=puralvos/' -e '/^\[ksplashrc\]/,$d' "$D"
	fi
	rm -rf "$LF/org.puralvos-light.desktop/contents/splash" \
	       "$LF/org.puralvos-light.desktop/contents/lockscreen"
	install -m 0644 "$ASSETS/preview-mark.png" \
		"$LF/org.puralvos-light.desktop/contents/previews/preview.png"
	install -m 0644 "$ASSETS/preview-mark.png" \
		"$LF/org.puralvos-light.desktop/contents/previews/splash.png"
	install -m 0644 "$ASSETS/lnf-fullscreenpreview.jpg" \
		"$LF/org.puralvos-light.desktop/contents/previews/fullscreenpreview.jpg"
	rm -rf "$LF/org.ubuntustudio.desktop"
	echo "  look-and-feel: org.puralvos-light.desktop (renamed from org.ubuntustudio.desktop)"

	# The light copy's own layout still asks for things the rename created:
	# loadTemplate("org.puralvos-light.desktop.defaultPanel") names a template
	# that does not exist (the templates are org.puralvos.desktop.*), and the
	# puralvos-default*.png wallpapers were deleted with the stock artwork.
	# With the template missing the layout script fails, Plasma falls back to
	# its built-in panel, and that fallback is what came up dark whatever the
	# theme said. Point both at what the image ships.
	LLJS="$LF/org.puralvos-light.desktop/contents/layouts/org.kde.plasma.desktop-layout.js"
	if [ -f "$LLJS" ]; then
		sed -i \
			-e 's/org\.puralvos-light\.desktop\.defaultPanel/org.puralvos.desktop.defaultPanel/g' \
			-e 's/org\.puralvos-light\.desktop\.dock/org.puralvos.desktop.dock/g' \
			-e 's/org\.puralvos-light\.desktop\.classicPanel/org.puralvos.desktop.classicPanel/g' \
			-e 's/org\.puralvos-light\.desktop\.livePanel/org.puralvos.desktop.livePanel/g' \
			-e 's/org\.puralvos-light\.desktop\.globalMenuPanel/org.puralvos.desktop.globalMenuPanel/g' \
			-e 's#file:///usr/share/wallpapers/puralvos-default2\.png#file:///usr/share/wallpapers/puralvos/contents/images/2560x1440.png#' \
			-e 's#file:///usr/share/wallpapers/puralvos-default\.png#file:///usr/share/wallpapers/puralvos/contents/images/3840x2160.png#' \
			"$LLJS"
		echo "  light layout: template and wallpapers repointed"
	fi
else
	echo "  no org.ubuntustudio.desktop in $LF, no light theme to rename" >&2
fi

# Only one look-and-feel may claim to be the default. Both stock themes carry
# EnabledByDefault, and with no explicit choice Plasma takes the first one it
# finds, which is org.puralvos.desktop (the dark one) — that is why a fresh
# live user came up dark and wrote a dark ~/.config/kdedefaults whatever
# kdeglobals said. The light theme is the default; the dark one is a choice.
python3 - "$LF/org.puralvos.desktop/metadata.json" \
           "$LF/org.puralvos-light.desktop/metadata.json" <<'PYLNF'
import json, sys
dark, light = sys.argv[1:3]
for path, enabled in ((dark, False), (light, True)):
    with open(path, encoding="utf-8") as fh:
        meta = json.load(fh)
    meta.setdefault("KPlugin", {})["EnabledByDefault"] = enabled
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=4)
        fh.write("\n")
PYLNF
echo "  look-and-feel: light is the only EnabledByDefault theme"

# The dark look-and-feel package is not shipped. With it present the session
# applied it and wrote ~/.config/kdedefaults with name=puralvos-dark,
# ColorScheme=OrchisDark and widgetStyle=kvantum-dark, and that file wins over
# plasmarc, kdeglobals and /etc/xdg/kdedefaults alike — every "make light the
# default" attempt still came up dark because of it, whatever the theme
# markers said. The dark Plasma style and icon theme stay installed and can be
# selected in System Settings; only the package that auto-applies dark is gone.
rm -rf "$LF/org.puralvos.desktop"
echo "  look-and-feel: dark package removed (style and icons remain selectable)"

# The rest of the look-and-feel family. The -look package ships the desktop
# in seven flavours — plain, Live, Classic, Classic Dark, two macOS-alike
# layouts and the two this image keeps — and System Settings' Global Theme
# page lists every one by its metadata Name. The rest is furniture: once the
# kf5-settings templates below are repointed at org.puralvos.desktop,
# nothing this image ships references any of them. Delete everything except
# the dark theme (the default) and the light theme copied above.
for t in org.ubuntustudio-live.desktop \
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
	# Plasma 6.7's default panel background is Adaptive, which tints the bar
	# from the wallpaper; over a near-black wallpaper that is why the light
	# panel still rendered dark. Opaque selects the theme's solid variant.
	lj="$new/contents/layout.js"
	if [ -f "$lj" ]; then
		sed -i 's/^\(panel\.height = gridUnit \* [0-9.]*\)$/\1\npanel.opacity = "opaque"/' "$lj"
	fi
done

# The stock panel ships a virtual desktop pager and a show-desktop button.
# With a single virtual desktop the pager draws as an unlabelled white box,
# and the show-desktop icon is invisible against this theme; on the first
# audio-only boot both read as broken buttons. The launcher list also pins
# Discover, which the online-accounts trim removes — the first audio-only
# boot showed it as a white placeholder square. Drop all three from the
# shipped templates and from the generator, which rewrites the templates at
# session start.
#
# The menu applet is another stock assumption that does not hold: these
# templates add "org.kde.plasma.kicker", but 26.10 ships no such plasmoid.
# The Application Dashboard (kickerdash), which the stock dock layout uses,
# is in plasma-widgets-addons; the online-accounts batch removes that package
# because the purpose/kaccounts chain it shares goes with it, so the package
# is installed back after the trim (see the Dolphin step). Point its button
# at the tight PuralvOS mark and the puralvos path.
for f in "$FULL"/usr/share/plasma/layout-templates/org.puralvos.desktop.*/contents/layout.js; do
	[ -f "$f" ] || continue
	sed -i -e '/org\.kde\.plasma\.pager/d' \
	       -e '/org\.kde\.plasma\.minimizeall/d' \
	       -e 's/,[[:space:]]*"applications:org\.kde\.discover\.desktop"//g' \
	       -e 's/org\.kde\.krita\.desktop/org.inkscape.Inkscape.desktop/g' \
	       -e 's/gimp\.desktop/mypaint.desktop/g' \
	       -e 's/patchance\.desktop/gimp.desktop/g' \
	       -e 's/ardour\.desktop/org.kde.krita.desktop/g' \
	       -e 's/com\.obsproject\.Studio\.desktop/blender.desktop/g' \
	       -e 's/org\.kde\.kdenlive\.desktop/org.synfig.SynfigStudio.desktop/g' \
	       -e 's/org\.kde\.digikam\.desktop/org.kde.kcolorchooser.desktop/g' \
	       -e 's/org\.darktable\.darktable\.desktop/org.kde.skanpage.desktop/g' \
	       -e 's/raysession\.desktop/blender.desktop/g' \
	       -e 's/carla\.desktop/gimp.desktop/g' \
	       -e 's/"org\.kde\.plasma\.kicker"/"org.kde.plasma.kickerdash"/g' \
	       -e 's#/usr/share/pixmaps/ubuntustudio-logo-menu\.png#/usr/share/pixmaps/puralvos-logo-menu.png#g' \
	       -e 's/kickerdash\.writeConfig("customButtonImage", "app-launcher")/kickerdash.writeConfig("customButtonImage", "\/usr\/share\/pixmaps\/puralvos-logo-menu.png")/' \
	       -e 's/\(var kicker = panel\.addWidget("org\.kde\.plasma\.kickerdash")\)/\1\nkicker.writeConfig("useCustomButtonImage", "true")/' \
	       -e 's/^\(panel\.height = gridUnit \* [0-9.]*\)$/\1\npanel.opacity = "opaque"/' "$f"
done
if [ -f "$FULL/usr/sbin/ubuntustudio-panel-refresh" ]; then
	sed -i -e 's/org\.ubuntustudio\.desktop/org.puralvos.desktop/g' \
	       -e '/org\.kde\.plasma\.pager/d' \
	       -e '/org\.kde\.plasma\.minimizeall/d' \
	       -e 's/"applications:org\.kde\.discover\.desktop",[[:space:]]*//g' \
	       -e 's/org\.kde\.krita\.desktop/org.inkscape.Inkscape.desktop/g' \
	       -e 's/gimp\.desktop/mypaint.desktop/g' \
	       -e 's/patchance\.desktop/gimp.desktop/g' \
	       -e 's/ardour\.desktop/org.kde.krita.desktop/g' \
	       -e 's/com\.obsproject\.Studio\.desktop/blender.desktop/g' \
	       -e 's/org\.kde\.kdenlive\.desktop/org.synfig.SynfigStudio.desktop/g' \
	       -e 's/org\.kde\.digikam\.desktop/org.kde.kcolorchooser.desktop/g' \
	       -e 's/org\.darktable\.darktable\.desktop/org.kde.skanpage.desktop/g' \
	       -e 's/raysession\.desktop/blender.desktop/g' \
	       -e 's/carla\.desktop/gimp.desktop/g' \
	       -e 's#/usr/share/pixmaps/ubuntustudio-logo-menu\.png#/usr/share/pixmaps/puralvos-logo-menu.png#g' \
	       -e 's/"org\.kde\.plasma\.kicker"/"org.kde.plasma.kickerdash"/g' \
	       -e 's/kickerdash\.writeConfig("customButtonImage", "app-launcher")/kickerdash.writeConfig("customButtonImage", "\/usr\/share\/pixmaps\/puralvos-logo-menu.png")/' \
	       -e 's/\(kicker\.writeConfig("customButtonImage", "\/usr\/share\/pixmaps\/puralvos-logo-menu\.png")\)/\1\nkicker.writeConfig("useCustomButtonImage", "true")/' \
	       -e 's/^\(panel\.height = gridUnit \* [0-9.]*\)$/\1\npanel.opacity = "opaque"/' \
		"$FULL/usr/sbin/ubuntustudio-panel-refresh"
	echo "  panel builder: menu applet repointed to kickerdash, graphics launchers pinned, pager/show-desktop/discover dropped"
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
	# The stock dark Plasma theme declares the LIGHT icon theme in its
	# metadata (Icons.Theme "ubuntustudio" -> "puralvos"), so the panel drew
	# dark glyphs on a black bar and the icons disappeared. Each theme points
	# at its own icon set, and the two display names say which is which.
	case "$dst_name" in
		puralvos-dark) theme_icons=puralvos-dark; theme_title="PuralvOS Dark" ;;
		*)             theme_icons=puralvos;      theme_title="PuralvOS" ;;
	esac
	METADATA="$dst/metadata.json"
	if [ -f "$METADATA" ]; then
		python3 - "$METADATA" "$theme_icons" "$theme_title" <<'PYMETA'
import json, sys
path, icons, title = sys.argv[1:4]
with open(path, encoding="utf-8") as fh:
    meta = json.load(fh)
meta.setdefault("Icons", {})["Theme"] = icons
meta.setdefault("KPlugin", {})["Name"] = title
with open(path, "w", encoding="utf-8") as fh:
    json.dump(meta, fh, indent=4)
    fh.write("\n")
PYMETA
	fi
	# The dark panel background is black at 65% over a near-black wallpaper,
	# so dark app icons (Audacity, the mixer, the settings tiles) sink into
	# the bar. Lift the body and its edge pieces to a dark slate that still
	# reads as the dark theme but gives those icons something to sit on.
	# Done in the three panel variants Plasma picks from: adaptive (base),
	# translucent, and solid.
	if [ "$dst_name" = puralvos-dark ]; then
		for panel in "$dst/widgets/panel-background.svg" \
		             "$dst/translucent/widgets/panel-background.svg" \
		             "$dst/solid/widgets/panel-background.svg"; do
			[ -f "$panel" ] || continue
			sed -i \
				-e 's/style="fill:#000000;opacity:0.65"/style="fill:#29323f;opacity:0.92"/g' \
				-e 's/style="fill:#282828;opacity:1;fill-opacity:1"/style="fill:#29323f;opacity:1;fill-opacity:1"/g' \
				"$panel"
		done
	fi
	rm -rf "$src"
	echo "  desktop theme: $dst_name (icons $theme_icons)"
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
	sed -i -E 's|^[[:space:]]*LookAndFeelPackage[[:space:]]*=.*|LookAndFeelPackage=org.puralvos-light.desktop|' "$KDEG"
elif [ -f "$KDEG" ] && grep -qE '^\[KDE\]' "$KDEG"; then
	awk '/^\[KDE\]/ && !done {print; print "LookAndFeelPackage=org.puralvos-light.desktop"; done=1; next} {print}' \
		"$KDEG" > "$KDEG.new" && mv "$KDEG.new" "$KDEG"
else
	[ -f "$KDEG" ] || : > "$KDEG"
	printf '[KDE]\nLookAndFeelPackage=org.puralvos-light.desktop\n' >> "$KDEG"
fi
echo "  kdeglobals: LookAndFeelPackage=org.puralvos-light.desktop (light default)"

# LookAndFeelPackage is a marker, not an instruction: a live first login does
# not reliably run the LNF applier, which is why the first build with the
# light default still came up on the dark widgets. Set the pieces the LNF
# would have set, in the files the session reads directly.
kde_key() {
	# kde_key FILE SECTION KEY VALUE -- set one key in one section, creating
	# the section if needed and never touching the same key in another one.
	python3 - "$@" <<'PYK'
import sys
path, sec, key, val = sys.argv[1:5]
try:
    lines = open(path, encoding="utf-8").read().splitlines()
except FileNotFoundError:
    lines = []
out, insec, done = [], False, False
for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        if insec and not done:
            out.append(f"{key}={val}")
            done = True
        insec = stripped == f"[{sec}]"
        out.append(line)
        continue
    if insec and stripped.split("=", 1)[0].strip() == key:
        out.append(f"{key}={val}")
        done = True
        continue
    out.append(line)
if insec and not done:
    out.append(f"{key}={val}")
    done = True
if not done:
    if out and out[-1].strip():
        out.append("")
    out.extend([f"[{sec}]", f"{key}={val}"])
with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(out) + "\n")
PYK
}
kde_key "$KDEG" General ColorScheme Orchis
kde_key "$KDEG" Icons Theme puralvos
kde_key "$FULL/etc/xdg/plasmarc" Theme name puralvos
kde_key "$FULL/etc/xdg/kwinrc" org.kde.kdecoration2 library org.kde.kwin.aurorae
kde_key "$FULL/etc/xdg/kwinrc" org.kde.kdecoration2 theme __aurorae__svg__Orchis
echo "  kdeglobals: ColorScheme=Orchis, Icons=puralvos; plasmarc Theme=puralvos"

# kdedefaults is the directory KDE reads as the *defaults* layer, and on a
# live first login it is what actually decides the Plasma style: the session
# wrote ~/.config/kdedefaults/plasmarc with name=puralvos-dark even though
# plasmarc said puralvos, which is why the panel stayed dark whatever the
# theme was set to. Ship the defaults in every place they are read from.
KDF="$FULL/etc/xdg/kdedefaults"
install -d "$KDF"
cat > "$KDF/plasmarc" <<'EOF'
[Theme]
name=puralvos
EOF
cat > "$KDF/kdeglobals" <<'EOF'
[KDE]
LookAndFeelPackage=org.puralvos-light.desktop

[General]
ColorScheme=Orchis

[Icons]
Theme=puralvos
EOF
install -d "$FULL/etc/skel/.config/kdedefaults"
cp -a "$KDF/." "$FULL/etc/skel/.config/kdedefaults/"
echo "  kdedefaults: plasmarc name=puralvos, light kdeglobals"

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

# A one-line boot marker, written from inside the real session.
#
# The image ships no serial console, so every boot-time question has had to be
# answered by looking at screenshots, which is how "still slow" stays a
# feeling instead of a number. This runs once, inside the real Plasma session,
# after the panel is up, and writes the kernel uptime to /dev/ttyS0. Harmless
# on a machine with no serial port (the script skips), and it gives the KVM
# harness the exact second the desktop became usable.
install -d "$FULL/usr/local/bin"
cat > "$FULL/usr/local/bin/puralvos-bootmark" <<'EOS'
#!/bin/sh
# Record the desktop-ready time once, on the serial port if there is one.
if [ -c /dev/ttyS0 ]; then
	read -r up _ < /proc/uptime
	printf 'PURALVOS_DESKTOP_READY %s\n' "$up" > /dev/ttyS0
fi
EOS
chmod 0755 "$FULL/usr/local/bin/puralvos-bootmark"
cat > "$FULL/etc/xdg/autostart/puralvos-bootmark.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=PuralvOS Boot Marker
Comment=Record the desktop-ready time on the serial port
Exec=/usr/local/bin/puralvos-bootmark
NoDisplay=true
X-KDE-autostart-after=panel
OnlyShowIn=KDE;
EOF
echo "  boot marker: /etc/xdg/autostart/puralvos-bootmark.desktop"

# A boot report on the desktop, written once per session.
#
# "It takes 3m40s" is not actionable and cannot be checked from a KVM host,
# because the host boots from NVMe and the laptop boots from a USB stick. This
# puts systemd's own account of the boot in ~/boot-report.txt after login, so
# the slow unit and the critical chain can be read off the machine that is
# actually slow. The full journal is included: the first report showed a
# 90 second hole before sysinit.target with no unit owning it, which is the
# signature of a job timeout (a device that never appears) and cannot be
# resolved from the summary sections alone. The initramfs probes are compiled
# into the main archive and listed in scripts/*/ORDER; they appear in dmesg as
# PURALVOS_BOOTPROBE and bracket casper so an initramfs stall is visible too.
cat > "$FULL/usr/local/bin/puralvos-boot-report" <<'EOS'
#!/bin/sh
out="$HOME/boot-report.txt"
{
	printf 'PuralvOS boot report %s\n' "$(date -Is)"
	echo
	echo '== cmdline =='
	cat /proc/cmdline
	echo
	echo '== lsblk =='
	lsblk -o NAME,MODEL,TRAN,SIZE,ROTA 2>&1
	echo
	echo '== systemd-analyze =='
	systemd-analyze 2>&1
	echo
	echo '== critical-chain =='
	systemd-analyze critical-chain 2>&1
	echo
	echo '== cryptsetup / sysinit =='
	systemctl show cryptsetup.target sysinit.target \
		-p Id,Wants,After,Before,ActiveEnterTimestamp 2>&1
	echo
	echo '== cryptsetup dependencies =='
	systemctl list-dependencies cryptsetup.target --all --no-pager 2>&1
	echo
	echo '== jobs at report time =='
	systemctl list-jobs --no-pager 2>&1
	echo
	echo '== blame (top 60) =='
	systemd-analyze blame 2>&1 | head -60
	echo
	echo '== failed units =='
	systemctl --failed --no-legend 2>&1
	echo
	echo '== fstab / crypttab =='
	cat /etc/fstab 2>&1
	cat /etc/crypttab 2>&1
	echo
	echo '== dmesg =='
	dmesg 2>&1
	echo
	echo '== journal =='
	journalctl -b -o short-precise --no-pager 2>&1
} > "$out" 2>&1
chmod 0644 "$out"
# The plot is the one view that shows the 90 second hole directly.
systemd-analyze plot > "$HOME/boot-plot.svg" 2>/dev/null || true
if [ -c /dev/ttyS0 ]; then
	{
		printf 'PURALVOS_BOOTREPORT_BEGIN\n'
		head -n 30 "$out"
		echo
		echo '== serial blame =='
		systemd-analyze blame 2>&1 | head -40
		echo
		echo '== serial critical-chain =='
		systemd-analyze critical-chain 2>&1
		echo
		echo '== serial failed =='
		systemctl --failed --no-legend 2>&1
		echo
		echo '== serial probes =='
		dmesg 2>&1 | grep -E 'PURALVOS_BOOTPROBE|PURALVOS_DESKTOP_READY' || true
		printf 'PURALVOS_BOOTREPORT_END\n'
	} > /dev/ttyS0 2>/dev/null || true
fi
EOS
chmod 0755 "$FULL/usr/local/bin/puralvos-boot-report"
cat > "$FULL/etc/xdg/autostart/puralvos-boot-report.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=PuralvOS Boot Report
Comment=Write systemd's boot timing account to ~/boot-report.txt
Exec=/usr/local/bin/puralvos-boot-report
NoDisplay=true
X-KDE-autostart-after=panel
OnlyShowIn=KDE;
EOF
echo "  boot report: ~/boot-report.txt at login"

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
#    and its content becomes the mark. mark-menu.png is the bare mark cropped
#    to its ink and padded by 6%: mark-256.png is the mark on a black tile,
#    and at a 22 px kicker button the tile is invisible on the dark panel
#    while the letters inside it collapse to a dot — measured on the first
#    audio-only boot. The tight version fills the button instead. Both the
#    stock path and the PuralvOS path (used by the renamed layout templates)
#    are installed; the hicolor theme carries the same logo at panel sizes
#    and Papirus carries a set for the controls app; same treatment, found
#    rather than listed so that a new size in a later package cannot slip
#    through.
for logo in "$FULL"/usr/share/pixmaps/ubuntustudio-logo*.png; do
	[ -f "$logo" ] || continue
	install -m 0644 "$ASSETS/mark-menu.png" "$logo"
done
install -m 0644 "$ASSETS/mark-menu.png" \
	"$FULL/usr/share/pixmaps/puralvos-logo-menu.png"
[ -f "$FULL/usr/share/pixmaps/ubuntustudio-logo.svg" ] && \
	install -m 0644 "$ASSETS/mark.svg" "$FULL/usr/share/pixmaps/ubuntustudio-logo.svg"
find "$FULL/usr/share/icons/hicolor" -iname '*ubuntustudio-logo*' -type f 2>/dev/null |
while IFS= read -r logo; do
	case "$logo" in
		*.svg) install -m 0644 "$ASSETS/mark.svg" "$logo" ;;
		*)     install -m 0644 "$ASSETS/mark-menu.png" "$logo" ;;
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

# --------------------------------------------------------------------------
# boot time
# --------------------------------------------------------------------------
say "boot time"
# A live image is a USB stick and a laptop, and every second here is a second
# somebody spends watching a splash. Three things dominate a stock Ubuntu
# Studio live boot and none of them does anything this product needs:
#
#   1. casper-md5check verifies every byte of the 7 GB ISO. It is IO-idle and
#      niceness 19, but on a USB 2.0 bus it is still the reader, so the
#      desktop's own reads queue behind it and the desktop comes up late.
#   2. display-manager.service carries a drop-in that waits for
#      snapd.seeded.service. Seeding is a store-side concern; the desktop does
#      not use it, and waiting for it put minutes between Plymouth and the
#      greeter.
#   3. ZFS: the stock tree enables zfs.target and its import/mount/zed units.
#      Nothing in this product is on ZFS, and loading its modules costs time
#      on hardware that has none.
#
# The units are MASKED rather than disabled. A mask is a symlink to /dev/null
# in /etc/systemd/system, which beats any WantedBy symlink in a lower layer;
# this build's working copy is the whole union, so editing wants directories
# would work too, but a mask is the one mechanism that stays correct if the
# base image ever moves an enablement link somewhere else.
mask_unit() {
	local u
	for u in "$@"; do
		ln -sfn /dev/null "$FULL/etc/systemd/system/$u"
	done
}
# The 7 GB checksum pass.
mask_unit casper-md5check.service
# The first real-hardware report showed a 90.065 s gap after
# systemd-ask-password-wall.path and before cryptsetup.target, with no unit in
# `systemd-analyze blame` owning it and no failed units. systemd's default
# start timeout is 90 s, which is exactly the shape of that hole: a wanted job
# that never completes, is cancelled at the timeout, and leaves the target to
# activate afterwards. Cap the default at 30 s so a stuck job cannot cost a
# minute and a half again; the full journal now shipped in the boot report
# names the unit that hit the cap. This is a ceiling, not a diagnosis: the
# normal units on this image finish in under two seconds.
install -d "$FULL/etc/systemd/system.conf.d"
cat > "$FULL/etc/systemd/system.conf.d/99-puralvos-timeout.conf" <<'EOF'
[Manager]
DefaultTimeoutStartSec=30s
DefaultTimeoutStopSec=30s
EOF
# No ZFS in this product.
mask_unit zfs.target zfs-import-cache.service zfs-import-scan.service \
	zfs-load-module.service zfs-mount.service zfs-share.service \
	zfs-volume-wait.service zfs-zed.service zed.service
# Waiting for the network before the desktop is a server concern.
mask_unit NetworkManager-wait-online.service systemd-networkd-wait-online.service
# Hardware nobody doing audio, video or graphics needs at boot. Bluetooth and
# Avahi stay: BT audio/MIDI and PipeWire's network discovery are audio
# features, and both start lazily enough not to matter.
mask_unit ModemManager.service \
	cups.service cups.path cups.socket cups-browsed.service
# Housekeeping that belongs in the background, not in a boot path.
mask_unit apport.service whoopsie.path whoopsie.service \
	unattended-upgrades.service ua-reboot-cmds.service \
	ubuntu-advantage.service apt-daily.service apt-daily-upgrade.service \
	motd-news.service
mask_unit e2scrub_reap.service grub-initrd-fallback.service \
	grub2-common.service secureboot-db.service
mask_unit smartmontools.service sysstat.service lm-sensors.service \
	anacron.service cron.service \
	networkd-dispatcher.service osspd.service rsyslog.service \
	cpupower-gui.service ufw.service chrony.service
# The drop-in that made the display manager wait for snapd. Removing the
# directory removes its only file, and the build whiteouts both.
rm -rf "$FULL/etc/systemd/system/display-manager.service.d"
# Rebuild of the dynamic linker cache is a 12-second job on this image and it
# buys nothing: /etc/ld.so.cache ships from the archive and the build installs
# no userspace library the cache could be missing. systemd runs it because
# /etc/.updated is absent, which is the "this system was just installed"
# signal. The stamps make the condition false; systemd-update-done is skipped
# for the same reason.
touch -t 202601010000 "$FULL/usr/.updated" "$FULL/etc/.updated"
# The stamps alone do not stop it: the unit's conditions are trigger
# conditions and it still runs (15 s measured). The cache it would rebuild is
# the one the archive shipped and nothing in this build installs a userspace
# library, so the unit is masked outright.
mask_unit ldconfig.service systemd-update-done.service
# Cloud-init has no cloud, and its network stage waits for one.
mask_unit cloud-init.service cloud-init-local.service cloud-config.service \
	cloud-final.service cloud-init-network.service cloud-init.target \
	cloud-init-hotplugd.socket cloud-init-hotplugd.service
# Snapshot/refresh timers and notifiers, which only put failed units in the
# journal on a live boot.
mask_unit apt-daily.timer apt-daily-upgrade.timer anacron.timer \
	motd-news.timer update-notifier-motd.timer update-notifier-download.timer \
	update-notifier-download.service fwupd-refresh.timer \
	plocate-updatedb.timer man-db.timer logrotate.timer \
	dpkg-db-backup.timer fstrim.timer e2scrub_all.timer xfs_scrub_all.timer \
	systemd-tmpfiles-clean.timer
# NO SNAP, for real. The seed is 16 snaps and snapd re-runs their install and
# configure hooks on every live boot (thunderbird alone is minutes of hook
# work), which is both the largest remaining boot cost and a direct violation
# of excludes.list.
#
# This is the LIVE image, so snapd is masked by default and the snap-based
# installer goes with it. PURALVOS_INSTALLER=1 builds the installable variant
# instead: same filesystem and same branding, snapd kept, first boot slower by
# the seeding cost.
if [ "${PURALVOS_INSTALLER:-0}" = "1" ]; then
	echo "  snap: kept (installable build; first boot pays the snap seeding cost)"
else
mask_unit snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service \
	snapd.autoimport.service snapd.core-fixup.service \
	snapd.recovery-chooser-trigger.service snapd.hold.service \
	snapd.mounts.target snap.ubuntu-desktop-bootstrap.subiquity-server.service
for m in "$FULL"/etc/systemd/system/snap-*.mount "$FULL"/etc/systemd/system/multi-user.target.wants/snap-*.mount; do
	[ -e "$m" ] || continue
	ln -sfn /dev/null "$FULL/etc/systemd/system/$(basename "$m")"
done
rm -f "$FULL"/etc/systemd/system/multi-user.target.wants/snapd.seeded.service \
      "$FULL"/etc/systemd/system/multi-user.target.wants/snapd.service \
      "$FULL"/etc/systemd/system/multi-user.target.wants/snapd.apparmor.service \
      "$FULL"/etc/systemd/system/multi-user.target.wants/snapd.autoimport.service \
      "$FULL"/etc/systemd/system/multi-user.target.wants/snapd.core-fixup.service \
      "$FULL"/etc/systemd/system/multi-user.target.wants/snapd.recovery-chooser-trigger.service
echo "  snap: masked (Live build; PURALVOS_INSTALLER=1 keeps snapd and the installer)"
fi
# The live layer still carries the installer's config mount: an ext4 device
# unit keyed to a build-host UUID, plus an override that makes that device
# want the mount with JobRunningTimeoutSec=0. It is not part of a live
# session. The UUID is not this ISO's and is not in the base image's crypttab,
# but a stale device unit is exactly the kind of hidden job that can sit in
# sysinit for the default timeout, so remove it from the live build. The
# installable variant keeps it because the installer uses it.
if [ "${PURALVOS_INSTALLER:-0}" != "1" ]; then
	rm -f "$FULL/usr/lib/systemd/system/subiquity_config.mount"
	rm -rf "$FULL"/etc/systemd/system/dev-disk-by*x2duuid-00c629d6*.device.d
	echo "  subiquity_config mount/device override: removed from live build"
fi
# Bluetooth stays available, but it should not fail because the radio is
# rfkill-blocked (common on ThinkPads with the hardware switch off), which
# produced the red line this image showed before the splash.
install -d "$FULL/etc/systemd/system/bluetooth.service.d"
cat > "$FULL/etc/systemd/system/bluetooth.service.d/unblock.conf" <<'EOF'
[Service]
ExecStartPre=-/usr/sbin/rfkill unblock bluetooth
EOF
echo "  masked $(find "$FULL/etc/systemd/system" -maxdepth 1 -type l -lname /dev/null 2>/dev/null | wc -l) services; display manager no longer waits for snapd"

# --------------------------------------------------------------------------
# first login
# --------------------------------------------------------------------------
# The last slow thing in the boot is Plasma's first paint. It builds its
# service database (ksycoca) by walking every .desktop file, service, plugin
# and mimetype on the system, and on a live session with an empty home that
# walk happens on the USB stick while the desktop is trying to appear. Build
# the database at image time, in the chroot, and seed it through skeleton so
# casper's live user starts with it already done.
if chroot "$FULL" test -x /usr/bin/kbuildsycoca6; then
	rm -rf "$FULL/etc/skel/.cache"
	mkdir -p "$FULL/etc/skel/.cache" "$FULL/etc/skel/.config"
	if chroot "$FULL" env HOME=/etc/skel XDG_CACHE_HOME=/etc/skel/.cache \
		XDG_CONFIG_HOME=/etc/skel/.config \
		XDG_DATA_DIRS=/usr/local/share:/usr/share XDG_CONFIG_DIRS=/etc/xdg \
		XDG_RUNTIME_DIR=/tmp QT_QPA_PLATFORM=offscreen \
		kbuildsycoca6 --noincremental >/dev/null 2>&1; then
		echo "  ksycoca: pre-built $(du -sh "$FULL/etc/skel/.cache" | cut -f1) into /etc/skel/.cache"
	else
		echo "  ksycoca: pre-build failed; first login will build it" >&2
	fi
	# Fontconfig builds a per-user cache on first use by walking every font
	# directory, which is more USB reads in the middle of the login. The
	# system-wide cache already exists; give the user one as well.
	if chroot "$FULL" env HOME=/etc/skel XDG_CACHE_HOME=/etc/skel/.cache \
		fc-cache -f >/dev/null 2>&1; then
		echo "  fontconfig: pre-built user cache into /etc/skel/.cache"
	fi
fi
# The pre-created accounts were made before that cache existed, and
# useradd -m copies skeleton at creation time.
# The light theme as the user's own default, not just the system fallback.
# /etc/xdg alone did not take on the live first login (the session still came
# up on puralvos-dark), so the same keys are written where the session reads
# them: skeleton, which casper copies for the live user, and the pre-created
# accounts' homes below.
install -d "$FULL/etc/skel/.config"
cat > "$FULL/etc/skel/.config/kdeglobals" <<'EOF'
[KDE]
LookAndFeelPackage=org.puralvos-light.desktop

[General]
ColorScheme=Orchis

[Icons]
Theme=puralvos
EOF
cat > "$FULL/etc/skel/.config/plasmarc" <<'EOF'
[Theme]
name=puralvos
EOF
cat > "$FULL/etc/skel/.config/kwinrc" <<'EOF'
[org.kde.kdecoration2]
library=org.kde.kwin.aurorae
theme=__aurorae__svg__Orchis
EOF

for h in "$FULL"/home/*; do
	[ -d "$h" ] || continue
	[ -d "$FULL/etc/skel/.cache" ] || break
	mkdir -p "$h/.cache"
	cp -a "$FULL/etc/skel/.cache/." "$h/.cache/" 2>/dev/null || true
	uid=$(stat -c %u "$h")
	gid=$(stat -c %g "$h")
	chown -R "$uid:$gid" "$h/.cache" 2>/dev/null || true
	for f in kdeglobals plasmarc kwinrc; do
		[ -f "$FULL/etc/skel/.config/$f" ] || continue
		install -Dm0644 "$FULL/etc/skel/.config/$f" "$h/.config/$f"
		chown "$uid:$gid" "$h/.config/$f" 2>/dev/null || true
	done
done

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
#     dependency chain and apt takes the chain with them. What actually
#     happens to that stack is decided list by list in the graphics trim below;
#     the generic kernel is unshipped at repack time, by file.
say "removing the non-graphics task bundles"
purge_in_chroot() {
	local p
	for p in "$@"; do
		chroot "$FULL" env DEBIAN_FRONTEND=noninteractive \
			apt-get purge -y "$p" 2>&1 |
			grep -E '^(Removing|Removing package|not installed)' |
			head -3 | sed 's/^/  /' || true
	done
}
purge_in_chroot ubuntustudio-audio ubuntustudio-video \
	ubuntustudio-photography ubuntustudio-publishing

# --------------------------------------------------------------------------
# the graphics trim
# --------------------------------------------------------------------------
# tasks.list decides what this product ships. The lists in tools/graphics-trim
# decide what the stock image leaked in and the product does not ship anyway.
# Active lists are applied in numeric order; a *.list.disabled file is kept
# with its reason and is not applied.
#
# This branch starts from the video branch's batches where the batch is not
# product-specific, and changes the ones that are:
#
#   02-audio.list       removes the audio applications. PipeWire, WirePlumber
#                       and the JACK library stay; Synfig and the graphics
#                       apps use them for preview audio.
#   02-video-optical.list
#                       removes the video editors and disc tools. It keeps
#                       libmlt7, libmlt++7 and libmlt-data because Krita and
#                       Synfig use MLT, and it keeps ffmpeg because Krita,
#                       Pencil2D and ImageMagick depend on it.
#   03-graphics.list    disabled. This is the product bundle, not a trim.
#
#   05-documents.list   active, but reduced to the document viewers. The
#                       poppler libraries, Ghostscript and the font package
#                       stay because GIMP, Inkscape, Krita and Skanpage link
#                       them.
#   10-gnustep.list     disabled. PikoPixel is a GNUstep application, and the
#                       batch would remove its runtime with the rest of
#                       GNUstep.
#   07-online-accounts  disabled. Skanpage depends on
#                       qml6-module-org-kde-purpose, which depends on
#                       libkaccounts6-2; removing the accounts stack would
#                       take the scanner application with it.
#   11-geo              disabled. GDAL is a hard dependency of OpenCV's
#                       imgcodecs, which libopenimageio depends on, which
#                       Blender depends on.
#   12-ml              disabled. Krita and MLT need the OpenCV/ONNX/TensorFlow
#                       runtime the ML batch would remove.
#
# The disabled files stay in the tree because they record the measured
# collisions; deleting them would invite the next person to re-apply the
# video branch's list and break the graphics applications.
#
# The command is:
#
#	apt-get purge -y --auto-remove <names in the list>
#
# Each batch writes $WORK/purge-<list>.log and prints how many packages it
# removed. This is a trim, not a sweep: the desktop, the graphics applications
# and the PipeWire/JACK runtime are marked manual before any of this runs, so
# autoremove can never reach them no matter what a future list says.
say "protecting the graphics stack"
# shellcheck disable=SC2086
#
# xserver-xorg-core is in this list even though it is not a graphics app:
# purging the audio, video and photography task bundles orphans it. It is
# desktop infrastructure, and the X11 sessions SDDM offers depend on it.
#
# Dolphin cannot be saved with a mark: it shares the baloo/kio widgets with
# okular, and the documents batch resolves the whole chain into one purge
# transaction. It is the file manager the panel pins, so it is installed back
# after the trim, next to Firefox.
#
# The Blender, OpenCV and GDAL libraries are marked explicitly because the
# geo and ML batches are disabled today and a future autoremove must not be
# able to reinterpret them as orphaned when a list changes.
chroot "$FULL" apt-mark manual \
	ubuntustudio-graphics ubuntustudio-fonts ubuntustudio-pipewire-config \
	gimp gimp-data gimp-data-extras gir1.2-gimp-3.0 libgimp-3.0-0 \
	inkscape lib2geom1.4.0 \
	krita krita-data \
	mypaint mypaint-data mypaint-data-extras mypaint-brushes \
	libmypaint-1.5-1 libmypaint-common \
	pencil2d pikopixel.app skanpage libksanecore6-1 \
	synfigstudio kcolorchooser create-resources openclipart-svg \
	blender blender-data xserver-xorg-input-wacom \
	libmlt7 libmlt++7 libmlt-data \
	imagemagick imagemagick-7-common imagemagick-7.q16 \
	libmagick++-7.q16-5 libmagickcore-7.q16-10 \
	libmagickcore-7.q16-10-extra libmagickwand-7.q16-10 \
	ffmpeg libgs10 ghostscript gsfonts \
	libembree4-4 libimath-3-1-29t64 libopencolorio2.5 \
	libopenexr-3-4-33 libopenimageio2.5 libopenvdb10.0t64 \
	libopenxr-loader1 libshaderc1 \
	libgdal39 libproj25 libgeotiff5 \
	libopencv-contrib410 libopencv-core410 libopencv-imgproc410 \
	libopencv-video410 libopencv-imgcodecs410 \
	pipewire wireplumber pipewire-jack libjack-jackd2-0 \
	plasma-desktop plasma-workspace sddm systemsettings \
	xserver-xorg-core >/dev/null

say "removing the graphics trim"
TRIM_REMOVED=0
for TRIMFILE in "$REPO"/tools/graphics-trim/*.list; do
	mapfile -t TRIMNAMES < <(grep -vE '^[[:space:]]*(#|$)' "$TRIMFILE")
	[ "${#TRIMNAMES[@]}" -gt 0 ] || continue
	TRIMLOG="$WORK/purge-$(basename "$TRIMFILE" .list).log"
	if chroot "$FULL" env DEBIAN_FRONTEND=noninteractive \
		apt-get purge -y --auto-remove "${TRIMNAMES[@]}" >"$TRIMLOG" 2>&1; then
		TRIMN=$(grep -c '^Removing ' "$TRIMLOG" || true)
		TRIM_REMOVED=$((TRIM_REMOVED + TRIMN))
		printf '  %-26s %4d removed\n' "$(basename "$TRIMFILE")" "$TRIMN"
	else
		die "purging $(basename "$TRIMFILE") failed; the removals are half done.
     The apt output is in $TRIMLOG. Re-run the build; the chroot stage starts
     again from the stock union and re-applies the whole sequence."
	fi
done
# Close with the sweep the batches themselves ran in vetting: anything a
# batch orphaned that no later batch still needed goes here. Then empty the
# apt cache so the download indices are not in the image.
chroot "$FULL" env DEBIAN_FRONTEND=noninteractive \
	apt-get autoremove --purge -y >"$WORK/purge-autoremove.log" 2>&1 || true
chroot "$FULL" env DEBIAN_FRONTEND=noninteractive apt-get clean
echo "  trim: $TRIM_REMOVED packages removed; orphans purged; apt cache empty"

# --------------------------------------------------------------------------
# branding
# --------------------------------------------------------------------------
# Everything that makes the tree PuralvOS rather than Ubuntu Studio. The
# unpack, the chroot and the kernel are above; this is the same function
# --author-only calls, so both paths brand the tree identically.
brand_the_tree

# --------------------------------------------------------------------------
# Firefox
# --------------------------------------------------------------------------
# The archive's firefox in 26.10 is 1:1snap1-0ubuntu11 — a deb that installs
# the snap. This image masks snapd, so that package is not a browser. Mozilla
# publishes Firefox in a signed apt repository under the same name; with the
# origin pinned above the archive, apt installs a real deb that updates with
# the rest of the system, which is the point of putting a browser on the
# image instead of leaving the panel's browser pin empty.
#
# Installed after brand_the_tree so the menu hygiene pass cannot treat the
# new desktop entry as leftover studio furniture.
say "Firefox from Mozilla's apt repository"
install -d -m 0755 "$FULL/etc/apt/keyrings" \
	"$FULL/etc/apt/preferences.d" "$FULL/etc/xdg"
if command -v curl >/dev/null 2>&1; then
	curl -fsSL --retry 3 \
		-o "$FULL/etc/apt/keyrings/packages.mozilla.org.asc" \
		https://packages.mozilla.org/apt/repo-signing-key.gpg \
		|| die "could not fetch the Mozilla apt signing key"
else
	wget -q -O "$FULL/etc/apt/keyrings/packages.mozilla.org.asc" \
		https://packages.mozilla.org/apt/repo-signing-key.gpg \
		|| die "could not fetch the Mozilla apt signing key (wget)"
fi
cat > "$FULL/etc/apt/sources.list.d/mozilla.sources" <<'EOF'
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Signed-By: /etc/apt/keyrings/packages.mozilla.org.asc
EOF
cat > "$FULL/etc/apt/preferences.d/mozilla" <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF
# The image ships cdrom.sources (file:///cdrom) so an installed system can
# use its own DVD; inside the chroot that path does not exist and apt treats
# the unreachable source as fatal. The package stage above disables it and
# restores it afterwards, and this step runs after that restore — so do the
# same dance here, under its own suffix.
for f in "$FULL"/etc/apt/sources.list.d/cdrom.sources; do
	[ -e "$f" ] && mv "$f" "$f.puralvos-firefox-disabled"
done
chroot "$FULL" env DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null \
	|| die "apt-get update with the Mozilla repository failed"
chroot "$FULL" env DEBIAN_FRONTEND=noninteractive \
	apt-get install -y firefox >/dev/null \
	|| die "installing firefox from packages.mozilla.org failed"
chroot "$FULL" env DEBIAN_FRONTEND=noninteractive apt-get clean
for f in "$FULL"/etc/apt/sources.list.d/cdrom.sources.puralvos-firefox-disabled; do
	[ -e "$f" ] && mv "$f" "${f%.puralvos-firefox-disabled}"
done
FFV=$(chroot "$FULL" dpkg-query -W -f='${Version}' firefox 2>/dev/null || true)
case "$FFV" in
	"") die "firefox is not installed after the Mozilla repository install" ;;
	*snap*) die "the installed firefox is the Ubuntu snap stub ($FFV); the Mozilla pin did not take" ;;
esac
# preferred://browser in the panel resolves through the XDG defaults. A live
# user has no ~/.config/mimeapps.list, so /etc/xdg/mimeapps.list is what the
# browser pin and any clicked http(s) link resolve against.
cat > "$FULL/etc/xdg/mimeapps.list" <<'EOF'
[Default Applications]
text/html=firefox.desktop
x-scheme-handler/http=firefox.desktop
x-scheme-handler/https=firefox.desktop
EOF
echo "  firefox: $FFV (packages.mozilla.org)"

# --------------------------------------------------------------------------
# the panel's desktop furniture
# --------------------------------------------------------------------------
# Reinstall what the trim resolves away but the panel is built around. The
# documents batch takes Dolphin with the okular chain (purge-05-documents.log
# lists it as REMOVED even when the package is marked manual), and the
# online-accounts batch takes plasma-widgets-addons with the purpose/
# kaccounts chain (purge-07-online-accounts.log does the same). The latter
# is the only package that provides the kickerdash applet the panel
# templates now add, and the first boots without it showed the menu button
# as a missing-widget placeholder.
#
# Done here, while the package index is current from the Firefox step (the
# trim runs before any network apt update and does not need one), and after
# brand_the_tree so the menu hygiene pass does not see a file manager it
# never expected. --no-install-recommends keeps the thumbnailers and
# kio-extras plugins the trim removed from sneaking back in; both packages
# work from their Depends.
say "restoring Dolphin and the panel menu applet"
FURNITURE="dolphin plasma-widgets-addons"
chroot "$FULL" env DEBIAN_FRONTEND=noninteractive \
	apt-get install -y --no-install-recommends $FURNITURE >/dev/null \
	|| die "restoring dolphin/plasma-widgets-addons after the trim failed"
for p in $FURNITURE; do
	chroot "$FULL" dpkg-query -W -f='${Status}' "$p" 2>/dev/null |
		grep -q 'install ok installed' ||
		die "$p is not installed after the restore"
done
echo "  dolphin $(chroot "$FULL" dpkg-query -W -f='${Version}' dolphin), plasma-widgets-addons $(chroot "$FULL" dpkg-query -W -f='${Version}' plasma-widgets-addons)"

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
		# Boot probes for the report. The first real-hardware report showed a
		# ~90 s hole before sysinit.target that no unit accounts for; it may be
		# a job timeout, but it may equally be time spent in this initramfs
		# where systemd does not exist yet and nothing lands in the journal.
		#
		# The initrd is NOT a flat cpio. It is an uncompressed microcode
		# archive, an uncompressed early2 archive, and then a zstd-compressed
		# main archive (the one holding /init and scripts/casper). Appending a
		# cpio archive to the end relies on a later archive overriding earlier
		# files; the appended archive was not even listed by lsinitramfs and
		# the probe never ran. Splicing one into the zstd stream corrupts the
		# stream and panics the kernel. Repack all three parts, add the probe
		# to the main archive, and list it in scripts/*/ORDER: run_scripts()
		# sources ORDER and only runs what that file names, so a probe file
		# alone is dead weight.
		PROBEDIR="$WORK/.initrd-probe"
		rm -rf "$PROBEDIR"
		unmkinitramfs "$INITRD" "$PROBEDIR"
		for probe_stage in init-top init-premount init-bottom; do
			stage_dir="$PROBEDIR/main/scripts/$probe_stage"
			[ -d "$stage_dir" ] || die "$INITRD has no main/scripts/$probe_stage to probe"
			printf '#!/bin/sh\nread -r up _ < /proc/uptime\necho "PURALVOS_BOOTPROBE %s $up" > /dev/kmsg 2>/dev/null || true\necho "PURALVOS_BOOTPROBE %s $up" > /dev/console 2>/dev/null || true\n' \
				"$probe_stage" "$probe_stage" > "$stage_dir/zz-puralvos-bootprobe"
			chmod 0755 "$stage_dir/zz-puralvos-bootprobe"
			touch "$stage_dir/ORDER"
			printf '/scripts/%s/zz-puralvos-bootprobe "$@"\n[ -e /conf/param.conf ] && . /conf/param.conf\n' \
				"$probe_stage" >> "$stage_dir/ORDER"
		done
		: > "$WORK/iso/casper/initrd"
		for part in early early2 main; do
			[ -d "$PROBEDIR/$part" ] || continue
			if [ "$part" = main ]; then
				( cd "$PROBEDIR/main" && find . -print0 | cpio --null -o -H newc --owner=0:0 2>/dev/null | zstd -T0 -19 -q ) >> "$WORK/iso/casper/initrd"
			else
				( cd "$PROBEDIR/$part" && find . -print0 | cpio --null -o -H newc --owner=0:0 2>/dev/null ) >> "$WORK/iso/casper/initrd"
			fi
		done
		rm -rf "$PROBEDIR"
		rm -f "$WORK/iso/casper/initrd.realtime"
		echo "  casper/initrd <- initrd.img-$RTVER ($(du -h "$INITRD" | cut -f1)); repacked with ordered boot probes ($(du -h "$WORK/iso/casper/initrd" | cut -f1))"
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

say "boot instrumentation"
# The self test and the serial diag are verification tools, not part of the
# product. A production image boots with the stock kernel line and nothing
# else. The first real-hardware test had puralvos.selftest=1 baked into every
# entry, and tier 4 opens every application in the image to prove its launcher
# resolves: the desktop came up with Audacity, Blender, GIMP, Inkscape and
# KStars opening by themselves, and the machine stayed busy for minutes -
# "the boot is very slow and all the apps start alone".
#
# Both are opt-in now, per build:
#
#     PURALVOS_SELFTEST=1 tools/build-live.sh    # serial + self test
#     PURALVOS_DIAG=1     tools/build-live.sh    # serial + diag dump
#
# Either adds console=ttyS0,115200n8, the channel both write to. The pass
# strips whatever the tree carried, so re-authoring an old image without the
# variables produces the clean production line.
SELFTEST_ON="${PURALVOS_SELFTEST:-0}"
DIAG_ON="${PURALVOS_DIAG:-0}"
G="$WORK/iso/boot/grub/grub.cfg"
if [ -f "$G" ]; then
	GF="$G.cmdline.$$"
	awk -v selftest="$SELFTEST_ON" -v diag="$DIAG_ON" '
		/^[[:space:]]*linux[[:space:]]/ {
			# Remove every copy first. "Add it if missing" passes stack:
			#   console=ttyS0,115200n8 puralvos.selftest=1 puralvos.selftest=1
			# which the kernel tolerates and readers should not have to.
			gsub(/[[:space:]]*console=ttyS0(,115200n8)?/, "")
			gsub(/[[:space:]]*puralvos\.selftest=1/, "")
			gsub(/[[:space:]]*puralvos\.diag=1/, "")
			extra = ""
			if (selftest == "1" || diag == "1")
				extra = " console=ttyS0,115200n8"
			if (selftest == "1") extra = extra " puralvos.selftest=1"
			if (diag == "1") extra = extra " puralvos.diag=1"
			if (extra != "") {
				# Kernel arguments belong before the "---"; after it they
				# are passed to init instead.
				if (index($0, "---")) sub(/[[:space:]]*---/, extra " ---")
				else sub(/[[:space:]]*$/, extra)
			}
		}
		{ print }
	' "$G" > "$GF" && mv "$GF" "$G"

	echo "  kernel command line, every entry:"
	grep -E '^[[:space:]]*linux ' "$G" | sed 's/^/    /'

	# Per line, not "at least one": the weaker claim is the one that failed
	# silently in the past.
	# `|| true` on every count: grep exits 1 when it finds nothing, and a
	# production menu has zero selftest and zero diag flags by definition.
	# Under set -e the assignment inherits grep's status and the build ends
	# right here, silently, with the last line in the log being the clean
	# command line it just verified.
	NENTRIES=$(grep -cE '^[[:space:]]*linux[[:space:]]' "$G" || true)
	NCONSOLE=$(grep -cE '^[[:space:]]*linux[[:space:]].*console=ttyS0,115200n8' "$G" || true)
	NSELFTEST=$(grep -cE '^[[:space:]]*linux[[:space:]].*puralvos\.selftest=1' "$G" || true)
	NDIAG=$(grep -cE '^[[:space:]]*linux[[:space:]].*puralvos\.diag=1' "$G" || true)
	if [ "$SELFTEST_ON" = "1" ] || [ "$DIAG_ON" = "1" ]; then
		[ "$NCONSOLE" -eq "$NENTRIES" ] \
			|| die "$NCONSOLE of $NENTRIES kernel command lines have console=ttyS0.
     A verification build cannot report anything without the serial channel."
	fi
	if [ "$SELFTEST_ON" = "1" ]; then
		[ "$NSELFTEST" -eq "$NENTRIES" ] \
			|| die "$NSELFTEST of $NENTRIES kernel command lines have puralvos.selftest=1."
		echo "  all $NENTRIES entries run the self test (verification build)"
	else
		[ "$NSELFTEST" -eq 0 ] \
			|| die "a production kernel line still carries puralvos.selftest=1."
	fi
	if [ "$DIAG_ON" = "1" ]; then
		[ "$NDIAG" -eq "$NENTRIES" ] \
			|| die "$NDIAG of $NENTRIES kernel command lines have puralvos.diag=1."
		echo "  all $NENTRIES entries run the diag dump (diagnostic build)"
	else
		[ "$NDIAG" -eq 0 ] \
			|| die "a production kernel line still carries puralvos.diag=1."
	fi
	if grep -qE '(console=ttyS0[^ ]* ){2}' "$G"; then
		die "a kernel command line carries console=ttyS0 more than once"
	fi
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
ISOUT="$OUT/$PRODUCT_SLUG-$STAMP.iso"

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

grub-mkrescue -o "$ISOUT" -volid "PURALVOS_GRAPHICS" "$WORK/iso/" 2>&1 \
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

    ./scripts/kvmtest.sh "$ISOUT" $PRODUCT_SLUG 900 60
    python3 scripts/qmp-key.py /tmp/opencode/kvmrun/$PRODUCT_SLUG ret

  There is no serial console on an Ubuntu ISO. Judge it from the screenshots.

  To boot it for real, write it to a USB stick:

    dd if="$ISOUT" of=/dev/sdX bs=4M status=progress conv=fdatasync

EOF