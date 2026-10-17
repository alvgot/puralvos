# desktop-exec.sh - read the executable out of a freedesktop .desktop file.
#
# One implementation, sourced by both the build and the self test. They each
# carried their own copy of this parser and they disagreed:
#
#   build-live.sh      only skipped a leading "env", so it read
#                      "env -u WAYLAND_DISPLAY openlp %F" as the executable "-u"
#   puralvos-selftest  the same, and reported OpenLP as a broken menu entry
#
# OpenLP is a perfectly good application. Two parsers, one of them wrong, and a
# self test that reports a healthy application as broken is worse than no self
# test, because it trains you to ignore it.
#
# Source it, then use:
#
#   desktop_exec FILE            print the executable, or nothing
#   desktop_exec_present FILE    true when that executable exists
#
# Both are deliberately quiet: no diagnostics, no exit codes that mean anything
# beyond the one they say.

# The executable named by the first Exec= line of a .desktop file.
#
# Field codes are stripped first (%f %u %U %F %d %D %n %i %c %k %v %m). They are
# removed before parsing rather than skipped during it, because a field code can
# be glued to the executable ("openlp%u") and a token-level parser sees the
# whole thing as one word.
#
# Then, step over things that are not the executable:
#
#   * a leading "env", including its options. "env -u WAYLAND_DISPLAY openlp" is
#     the modern form of this line and "env -i" and "--unset=NAME" and
#     "-C NAME" all turn up in practice.
#   * "VAR=value" pairs after env.
#
# A token that is not a plausible executable name (it begins with "-", or it
# contains characters a path would not) is treated as an option and stepped
# over, which is what keeps this from having to enumerate every flag any
# wrapper ever grows.
desktop_exec() {
	local f=$1
	[ -r "$f" ] || return 0
	sed -n 's/^Exec=//p' "$f" | head -1 |
	sed -e 's/%%/%/g' -e 's/%[fFuUdDnNickvm]//g' |
	awk '
		# A plausible executable: an absolute path, or a bare name.
		#
		# The absolute case is not optional. "/usr/bin/ardour" fails a
		# ^[A-Za-z0-9_.+] test on its leading slash, and Ardour ships exactly
		# that. With the slash excluded, Ardour, VLC and every other entry
		# that names its binary by full path read as having no executable at
		# all, which is how the first version of this parser reported the
		# three most important applications in the product as broken.
		function plausible(t) {
			return t ~ /^\/[A-Za-z0-9_.+\/-]+$/ ||
			       t ~ /^[A-Za-z0-9_.+][A-Za-z0-9_.+\/-]*$/
		}
		{
			# Step over any leading "env" and its options. This loop runs at
			# most as many times as there are env words, which in practice is
			# once.
			#
			# Only "env" is treated as a wrapper. Treating the FIRST word of
			# every Exec line as one is wrong in a way that is easy to miss:
			# "pkexec env DISPLAY=$DISPLAY software-properties-qt" is a pkexec
			# line, and reading it as a wrapper turned pkexec into a search for
			# what comes after it, which is "env". So the desktop entry for
			# Software Sources claimed to be launched by the env binary.
			i = 1
			while (i <= NF) {
				# A bare VAR=value at the START of an Exec line is an
				# environment assignment for everything after it. Ardour ships
				# "Exec=FLTK_BACKEND=x11 /usr/bin/ardour %f", and a parser
				# that only knew about "env" read Ardour as having no
				# executable at all. Ardour is the first thing anyone checks.
				if ($i ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { i++; continue }

				# Only a LEADING "env" is a wrapper. Treating the first word of
				# every Exec line as one is wrong in a way that is easy to miss:
				# "pkexec env DISPLAY=$DISPLAY software-properties-qt" is a
				# pkexec line, and reading past it turned pkexec into a search
				# for what follows, which is "env". So the desktop entry for
				# Software Sources claimed to be launched by the env binary.
				if ($i == "env") {
					i++
					while (i <= NF) {
						if ($i ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { i++; continue }
						if ($i == "-u" || $i == "--unset" ||
						    $i == "-C" || $i == "--chdir") { i += 2; continue }
						if ($i ~ /^--unset=/ || $i ~ /^--chdir=/) { i++; continue }
						if ($i ~ /^-/) { i++; continue }                   # -i, -0, ...
						break
					}
					continue
				}
				break
			}
			if (i <= NF && plausible($i)) print $i
		}'
}

# True when the executable a .desktop file names actually exists.
#
# ROOT is the filesystem to look in. It defaults to /, which is right inside a
# running image and wrong during a build.
#
# This matters more than it looks. The build runs on the build machine and
# inspects a tree that is not the build machine's root, so with no ROOT the
# check asks the HOST whether /usr/bin/ardour exists. On a machine that is not
# an audio workstation the answer is no, for all 154 of them, and the hygiene
# step hides every application in the product:
#
#     hidden 'Ardour' (Exec '/usr/bin/ardour')
#     hidden 'Yoshimi' (Exec 'yoshimi')
#     154 menu entries hidden for a missing executable
#
# while all 154 are present in the image being built. That is the worst failure
# this check has had: it is loud, it is wrong, and it removes the product.
#
# So the caller passes the tree root, and every lookup below is relative to it.
#
# PATH is searched first when looking at the running system, because a desktop
# entry can name something on a PATH that is not in these directories. Inside a
# build tree there is no meaningful PATH to consult — the build machine's is the
# wrong one — so only the fixed directories are searched, which is the right
# answer for a question about an image.
#
# There is deliberately no /usr/games or /usr/local/games here. Both used to be
# in this list, carried over from checking desktop images generally, and on this
# image /usr/games exists and is empty: dpkg creates the directory and no
# package ever puts anything in it, because PuralvOS ships no games. A search
# path that includes a directory belonging to a class of software this product
# does not have is an assumption about the product, and assumptions like that are
# how a check ends up passing for the wrong reason.
desktop_exec_present() {
	local f=$1 root=${2:-/} bin d
	bin=$(desktop_exec "$f")
	[ -n "$bin" ] || return 1
	[ "${root%/}" = "" ] && root="/"
	case "$bin" in
		/*) [ -x "$root$bin" ] && return 0 || return 1 ;;
	esac
	# PATH only means anything when checking the system we are running on.
	if [ "$root" = "/" ]; then
		command -v "$bin" >/dev/null 2>&1 && return 0
	fi
	for d in usr/local/bin usr/bin usr/local/sbin usr/sbin bin sbin opt; do
		[ -x "$root/$d/$bin" ] && return 0
	done
	return 1
}