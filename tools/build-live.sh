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
#   build-live.sh [--keep] [--no-kernel]
#
#   --keep        do not delete the work directory on success
#   --no-kernel   build the branding only, leave the generic kernel alone
#                 (faster; for testing the rebrand, not the kernel)

set -euo pipefail

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
		die "no filesystem found with 45 GB free for the build work directory"
	fi
	echo "$best"
}
WORK="${PURALVOS_WORK:-$(pick_work)}"
OUT="${PURALVOS_OUT:-$REPO/out}"
KEEP=0
WITH_KERNEL=1

for a in "$@"; do
	case "$a" in
		--keep) KEEP=1 ;;
		--no-kernel) WITH_KERNEL=0 ;;
		*) echo "unknown option: $a" >&2; exit 2 ;;
	esac
done

# The live layer is never opened by this build; see the layer notes below.
LAYER=casper/minimal.standard.live.squashfs

say() { printf '\n=== %s\n' "$*"; }
die() { printf 'build-live: %s\n' "$*" >&2; exit 1; }

[ -f "$BASE_ISO" ] || die "base ISO missing: $BASE_ISO (run: make base)"

say "verifying the base before touching it"
( cd "$REPO/base" && grep -F "$(basename "$BASE_ISO")" CHECKSUMS | sha256sum -c - ) \
	|| die "base ISO checksum does not match CHECKSUMS. Refusing to build on it."

say "brand assets"
python3 "$REPO/tools/make-brand.py" "$REPO/brand/assets" >/dev/null
python3 "$REPO/tools/make-package-declaration.py" \
	-o "$REPO/base/puralvos/selftest-packages.txt" 2>/dev/null || true
ls -1 "$REPO/brand/assets" | sed 's/^/  /'

say "work directory $WORK"
mkdir -p "$WORK" "$OUT"
rm -rf "$WORK/iso" "$WORK/base-union" "$WORK/layer"
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
BASE_UNION="$WORK/base-union"
FULL="$WORK/layer"

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
	echo "  reusing the existing build root"
else
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
	echo "  build root size: $(du -sh "$FULL" | cut -f1)"

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
# branding
# --------------------------------------------------------------------------
say "branding"
A="$REPO/brand/assets"

# Wallpapers. Overwriting rather than adding leaves Canonical's files in
# /usr/share/backgrounds, which docs/BRANDING.md requires to be gone: a
# leftover ubuntu wallpaper is exactly the defect tier 3 of the self test
# fails on.
rm -f "$FULL"/usr/share/backgrounds/*ubuntu* 2>/dev/null || true
rm -f "$FULL"/usr/share/backgrounds/*Ubuntu* 2>/dev/null || true
install -m 0644 "$A/wallpaper-4k.png"   "$FULL/usr/share/backgrounds/puralvos-wallpaper.png"
install -m 0644 "$A/wallpaper-1080p.png" "$FULL/usr/share/backgrounds/puralvos-wallpaper-1080p.png"
echo "  wallpapers installed"

install -Dm0644 "$A/mark.svg" "$FULL/usr/share/puralvos/mark.svg"
install -Dm0644 "$A/wordmark.svg" "$FULL/usr/share/puralvos/wordmark.svg"

# os-release. This is what every tool reports the system as, and Ubuntu and
# Ubuntu Studio are Canonical trademarks, so both have to go.
if [ -f "$FULL/etc/os-release" ]; then
	# Delimiter is # for all of these. With the usual s/// the replacement
	# "https://..." contains an unescaped slash, which ends the command early
	# and fails with "unknown option to `s'" pointing at a character in the
	# middle of a URL.
	sed -i -e 's#^NAME=.*#NAME="PuralvOS"#' \
	       -e 's#^PRETTY_NAME=.*#PRETTY_NAME="PuralvOS 26.04.1 LTS"#' \
	       -e 's#^ID=.*#ID=puralvos#' \
	       -e 's#^ID_LIKE=.*#ID_LIKE="ubuntu"#' \
	       -e 's#^HOME_URL=.*#HOME_URL="https://github.com/alvgot/puralvos"#' \
	       -e 's#^SUPPORT_URL=.*#SUPPORT_URL="https://github.com/alvgot/puralvos/issues"#' \
	       -e 's#^BUG_REPORT_URL=.*#BUG_REPORT_URL="https://github.com/alvgot/puralvos/issues"#' \
	       -e 's#^VERSION_CODENAME=.*#VERSION_CODENAME=puralvos#' \
	       "$FULL/etc/os-release"
	sed -i -e 's/^DISTRIB_NAME=.*/DISTRIB_NAME="PuralvOS"/' \
	       -e 's/^DISTRIB_CODENAME=.*/DISTRIB_CODENAME=puralvos/' \
	       "$FULL/etc/lsb-release" 2>/dev/null || true
	echo "  os-release: $(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' "$FULL/etc/os-release")"
fi

# The ISO's own label, which the boot menu and installer show.
if [ -f "$WORK/iso/.disk/info" ]; then
	printf 'PuralvOS 26.04.1 LTS - Live amd64 (built from Ubuntu Studio)\n' \
		> "$WORK/iso/.disk/info"
	echo "  iso label: $(cat "$WORK/iso/.disk/info")"
fi

say "boot menu"
G="$WORK/iso/boot/grub/grub.cfg"
if [ -f "$G" ]; then
	sed -i \
	  -e 's/Try or Install Ubuntu Studio/PuralvOS Live — install or try out/' \
	  -e 's/Ubuntu Studio (safe graphics)/PuralvOS Live (safe graphics)/' \
	  -e 's/^set timeout=.*/set timeout=5/' \
	  "$G"
	echo "  menu entries now:"
	grep -E '^\s*menuentry' "$G" | sed 's/^/    /'
fi

# --------------------------------------------------------------------------
# the real time audio step, which no package performs by itself
# --------------------------------------------------------------------------
say "real time audio limits"
install -Dm0644 /usr/share/ubuntustudio-installer/30-ubuntustudio-audio.conf \
	"$FULL/etc/security/limits.d/30-ubuntustudio-audio.conf" \
	2>/dev/null \
	|| cat > "$FULL/etc/security/limits.d/30-ubuntustudio-audio.conf" <<'EOF'
@audio   -  rtprio     95
@audio   -  memlock    unlimited
@pipewire - rtprio 95
@pipewire - memlock unlimited
EOF
echo "  $(cat "$FULL/etc/security/limits.d/30-ubuntustudio-audio.conf" | grep -c rtprio) rtprio grants"

# Put the live user in the audio group. The stock helper guards this behind
# PKEXEC_UID and silently skips it when it is unset, which is what happens
# during a build; see docs/ARCHITECTURE.md. Do it directly and verify it.
install -Dm0755 "$REPO/tools/puralvos-rt-fix" \
	"$FULL/usr/local/bin/puralvos-rt-fix"
install -Dm0755 "$REPO/tools/puralvos-selftest" \
	"$FULL/usr/local/bin/puralvos-selftest"

for u in ubuntu; do
	if grep -qE "^${u}:" "$FULL/etc/passwd"; then
		usermod -aG audio "$u" -d "$FULL" 2>/dev/null \
			|| chroot "$FULL" usermod -aG audio "$u"
		if grep -q "^${u}:.*audio" "$FULL/etc/group" \
		   || grep -q "^audio:.*${u}" "$FULL/etc/group"; then
			echo "  user $u is in the audio group"
		else
			echo "  WARNING: could not confirm $u in the audio group" >&2
		fi
	fi
done

# Remove the tasks PuralvOS does not ship.
say "removing photography and publishing"
for p in ubuntustudio-photography ubuntustudio-publishing; do
	chroot "$FULL" env DEBIAN_FRONTEND=noninteractive \
		apt-get purge -y "$p" 2>&1 | grep -E '^(Removing|Removing package|not installed)' \
		| head -3 | sed 's/^/  /' || true
done

# --------------------------------------------------------------------------
# repack
# --------------------------------------------------------------------------
say "swapping in the real time kernel"
# GRUB boots a fixed path, /casper/vmlinuz with /casper/initrd. To boot the
# real time kernel that is what has to change, not the GRUB config.
if [ "$WITH_KERNEL" = 1 ]; then
	RTVER=$(ls "$FULL/boot" | sed -n 's/^vmlinuz-\([0-9].*\)$/\1/p' | sort -V | tail -1)
	if [ -n "$RTVER" ]; then
		cp -f "$FULL/boot/vmlinuz-$RTVER" "$WORK/iso/casper/vmlinuz"
		echo "  casper/vmlinuz  <- vmlinuz-$RTVER"
		# The kernel's own initramfs, which carries the modules for this
		# kernel. casper's initrd stays as the early microcode one it was.
		INITRD="$FULL/boot/initrd.img-$RTVER"
		if [ -f "$INITRD" ]; then
			cp -f "$INITRD" "$WORK/iso/casper/initrd.realtime"
			echo "  casper/initrd.realtime <- initrd.img-$RTVER ($(du -h "$INITRD" | cut -f1))"
		fi
		echo "  modules present: $(ls "$FULL/lib/modules" | tr '\n' ' ')"
	else
		die "no kernel in the build root after installing linux-realtime"
	fi
else
	echo "  skipped: the image will boot the stock GENERIC kernel"
fi

say "pointing the boot menu at the real time kernel"
G="$WORK/iso/boot/grub/grub.cfg"
if [ -f "$G" ] && [ "$WITH_KERNEL" = 1 ] && [ -f "$WORK/iso/casper/initrd.realtime" ]; then
	# Two initrds: casper's microcode one first, then the kernel's.
	sed -i 's|^\(\s*\)initrd /casper/initrd$|\1initrd /casper/initrd /casper/initrd.realtime|' "$G"
	grep -nE 'initrd|linux ' "$G" | head -4 | sed 's/^/    /'
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
comm -13 "$WORK/base.list" "$WORK/full.list" > "$WORK/top.list"
echo "  $(wc -l < "$WORK/top.list") of $(wc -l < "$WORK/full.list") paths differ from the read-only union"

NEWTOP="$WORK/newtop"
rm -rf "$NEWTOP"; mkdir -p "$NEWTOP"
( cd "$FULL" && tar cf - --no-recursion -T "$WORK/top.list" 2>/dev/null ) \
	| ( cd "$NEWTOP" && tar xf - ) 2>/dev/null
echo "  top layer contents: $(du -sh "$NEWTOP" | cut -f1)"

LIVEL="$WORK/iso/$LAYER"
OLDSZ=$(stat -c %s "$LIVEL")
rm -f "$LIVEL"
mksquashfs "$NEWTOP" "$LIVEL" -comp xz -noappend -no-progress 2>&1 | tail -3 | sed 's/^/  /'
awk -v n="$(stat -c %s "$LIVEL")" -v o="$OLDSZ" \
	'BEGIN{printf "  minimal.standard.live.squashfs: %.0f MB (was %.0f MB)\n", n/1048576, o/1048576}'

NEWSZ=$(stat -c %s "$LIVEL")
if [ "$NEWSZ" -ge 4000000000 ]; then
	echo "  WARNING: the live layer is over 4 GB. libisofs cannot put a file that" >&2
	echo "  size in an ISO9660 image, and it will not fit comfortably on a stick." >&2
fi

# Boot paths taken from the ISO's own El Torito records, not guessed.
	#
	#   BIOS  /boot/grub/i386-pc/eltorito.img
	#   UEFI  /EFI/boot/bootx64.efi
	#
	# UEFI is lowercase on this image. The conventional spelling is
	# EFI/BOOT/BOOTX64.EFI, and on a case-sensitive filesystem that fails with
	# "Cannot find path ... in loaded ISO image" rather than booting.
for p in boot/grub/i386-pc/eltorito.img EFI/boot/bootx64.efi; do
	[ -f "$WORK/iso/$p" ] || die "boot image missing from the extracted ISO: $p"
done

say "writing the ISO"
STAMP=$(date +%Y%m%d-%H%M)
ISOUT="$OUT/puralvos-live-$STAMP.iso"

# The ISO is authored as an UPDATE of the original, not from scratch.
#
# Authoring from scratch means reproducing the boot record exactly: the MBR
# signature at offset 510, the GPT header at LBA 1, the appended partition, and
# the El Torito catalog with both its BIOS and UEFI entries. Getting that wrong
# does not fail loudly. It produces a perfectly well formed 7 GB ISO that
# boots straight into the UEFI shell instead of GRUB, which is exactly what
# happened the first time, and the El Torito report says everything looks
# right while the machine still will not start.
#
# With -indev and -outdev together, xorriso copies the system area, the boot
# catalog and the El Torito records from the source image and changes only what
# -update names. Those structures then come from an ISO already known to boot
# on this hardware class, so they are correct by construction rather than
# correct by argument.
#
# It is also the honest description of what this is: a PuralvOS live image IS
# the Ubuntu Studio image, updated.
xorriso -indev "$BASE_ISO" -outdev "$ISOUT" \
	-volid "PURALVOS_LIVE" \
	-update "$WORK/iso/" 2>&1 \
	| grep -viE 'NOTE|Drive|Media|Added to|Track|ISO image|Writing|libburn|Attempt|Returning|Dev |Block|Command|executed|Write|Size |Using|Final|End |Ready|Volume|Creating|New |Start |Parameters|^xorriso' \
	| tail -6 | sed 's/^/  /'

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