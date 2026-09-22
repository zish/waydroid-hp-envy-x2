#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Render one modification's RPM spec from packaging/mods/<name>.mod.
#
# WHY A GENERATOR
#
# The unit of release here is the modification, not the subsystem: a fix to the
# camera wrapper must not reissue Widevine (docs/47-package-split.md). That means
# roughly twenty-five source packages, and twenty-five hand-maintained specs
# drift -- a packaging fix gets applied to the four somebody remembered. So each
# modification declares only what is true about IT, in a .mod file, and every
# spec is rendered from one template.
#
# The .mod file is shell-sourceable key=value because this repository has no
# YAML parser and does not want one; every other tool here is stdlib Python or
# POSIX shell for the same reason.
#
# Usage:
#     packaging/gen-spec.sh camera-gbm            # print the spec
#     packaging/gen-spec.sh -o DIR camera-gbm …   # write DIR/waydroid-ext-<n>.spec
#     packaging/gen-spec.sh --list                # every known modification
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
MODDIR="$here/mods"
TEMPLATE="$here/templates/rpm.spec.in"
outdir=""

while [ $# -gt 0 ]; do
	case "$1" in
	-o|--outdir) outdir="$2"; shift 2 ;;
	--list)
		for m in "$MODDIR"/*.mod; do
			[ -e "$m" ] || continue
			n=$(basename "$m" .mod)
			s=$(. "$m" >/dev/null 2>&1; printf '%s' "${SUMMARY:-}")
			printf '%-28s %s\n' "$n" "$s"
		done
		exit 0 ;;
	-h|--help) sed -n '19,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	-*) echo "unknown argument: $1" >&2; exit 2 ;;
	*) break ;;
	esac
done

[ $# -gt 0 ] || { echo "usage: $0 [-o DIR] <mod>..." >&2; exit 2; }

# ------------------------------------------------------------------- rendering
#
# Tokens are @NAME@. A token alone on a line is replaced by a whole block, which
# is how multi-line %files and %install lists get in; a token inside a line is
# replaced by a single value. Blocks live in files under $tmp so awk can splice
# them without any quoting question ever arising.

render_one() {
	mod=$1
	modfile="$MODDIR/$mod.mod"
	[ -f "$modfile" ] || { echo "no such modification: $mod ($modfile)" >&2; exit 1; }

	# Defaults, then the .mod file overrides whatever it cares about.
	NAME=$mod VERSION=0.0.0 RELEASE=1 SUMMARY="" DESCRIPTION="" LICENSE="GPL-3.0-or-later"
	ARCH=noarch KIND=host REQUIRES="" RECOMMENDS="" CONFLICTS="" BUILDREQUIRES=""
	DOCS="" FILES="" PAYLOAD_FILES="" INSTALL="" BUILD="" SCRIPTLETS="" GLOBALS=""
	CHECK=""
	# shellcheck disable=SC1090
	. "$modfile"

	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT INT TERM

	# --- dependency lines -------------------------------------------------
	: >"$tmp/REQUIRES"
	: >"$tmp/RECOMMENDS"
	: >"$tmp/CONFLICTS"
	: >"$tmp/BUILDREQUIRES"
	# One dependency per LINE, not per word: a versioned dependency is
	# "pkgconfig(libgbinder) >= 1.1.47" and word-splitting would make three
	# of it. Squeezing the spaces out instead produces
	# comparison-operator-in-deptoken, which rpm parses but which is wrong.
	deps() {
		printf '%s\n' "$2" | while IFS= read -r r; do
			r=$(printf '%s' "$r" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
			[ -n "$r" ] || continue
			case "$r" in \#*) continue ;; esac
			printf '%-15s %s\n' "$1:" "$r"
		done
	}
	deps BuildRequires "$BUILDREQUIRES" >"$tmp/BUILDREQUIRES"
	deps Requires      "$REQUIRES"      >"$tmp/REQUIRES"
	deps Recommends    "$RECOMMENDS"    >"$tmp/RECOMMENDS"
	deps Conflicts     "$CONFLICTS"     >"$tmp/CONFLICTS"

	# --- arch -------------------------------------------------------------
	#
	# noarch only when the payload really is architecture-independent. Overlay
	# components carrying Android ELF are NOT: an x86_64 .so in a noarch package
	# would install happily on an aarch64 host and break Android there rather
	# than on the shelf. docs/47.
	case "$ARCH" in
	noarch) echo "BuildArch:      noarch" >"$tmp/ARCHLINE" ;;
	any)    : >"$tmp/ARCHLINE" ;;
	*)      echo "ExclusiveArch:  $ARCH" >"$tmp/ARCHLINE" ;;
	esac

	# --- %build, %install, %files, scriptlets ------------------------------
	: >"$tmp/GLOBALS"
	: >"$tmp/INSTALL"
	: >"$tmp/FILES"
	: >"$tmp/SCRIPTLETS"
	: >"$tmp/CHECK"
	printf '%s\n' "${BUILD:-# Nothing to build.}" >"$tmp/BUILD"

	case "$KIND" in
	overlay)
		# rpm's dependency generator would read the Android ELF in the payload
		# and emit Requires nothing on this host provides -- libutils.so()(64bit)
		# and friends -- making the package uninstallable. Scoped to the payload
		# directory so the shell still gets its ordinary /bin/sh dependency.
		cat >"$tmp/GLOBALS" <<-EOG

		# /usr/lib and not /usr/share: most components carry Android ELF, and
		# /usr/share is defined as architecture-independent data. rpmlint flags
		# the old location as arch-dependent-file-in-usr-share and is right.
		%global overlay_dir %{_prefix}/lib/waydroid-overlay
		%global __requires_exclude_from ^%{overlay_dir}/.*\$
		%global __provides_exclude_from ^%{overlay_dir}/.*\$
		%global debug_package %{nil}
		%global __brp_strip %{nil}
		%global __brp_strip_comment_note %{nil}
		%global __brp_strip_static_archive %{nil}
		%global __brp_check_rpaths %{nil}
		EOG

		{
			echo "COMP=$NAME DESTDIR=%{buildroot} PREFIX=%{_prefix} STAGEDIR=%{overlay_dir} \\"
			echo "    sh packaging/stage-overlay.sh <<'PAYLOAD'"
			printf '%s\n' "$FILES" | sed '/^[[:space:]]*$/d'
			echo "PAYLOAD"
		} >"$tmp/INSTALL"

		{
			echo "%{overlay_dir}/$NAME/"
			echo "%{overlay_dir}/manifests/$NAME.manifest"
		} >"$tmp/FILES"

		# The reconcile is safe to run at any moment: it exits 0 when
		# /var/lib/waydroid does not exist, which is both the not-yet-initialised
		# host and the rpm-ostree compose. `|| :` because no scriptlet may fail a
		# transaction, and `$1 -eq 0` because %postun also runs on upgrade, where
		# removing files the new version is about to reinstall would be wrong.
		# Nothing restarts the container: on a kiosk host that drops the session
		# to the greeter. docs/47.
		# Not box-ticking for rpmlint's no-%check-section: this is the one
		# guarantee that matters for a package of prebuilt payload. The manifest
		# is what waydroid-overlay-sync trusts at deploy time, and it refuses to
		# copy a file whose hash does not match -- so a manifest that disagrees
		# with its own payload produces a package that installs and then quietly
		# deploys nothing. Catch it here instead.
		cat >"$tmp/CHECK" <<-EOC
		%check
		fail=0
		cd %{buildroot}%{overlay_dir}
		while read -r mode sha rel; do
		    case "\$mode" in ''|\#*) continue ;; esac
		    have=\$(sha256sum "$NAME/\$rel" | cut -d' ' -f1)
		    if [ "\$have" != "\$sha" ]; then
		        echo "payload does not match manifest: \$rel" >&2
		        fail=1
		    fi
		done < manifests/$NAME.manifest
		[ "\$fail" = 0 ]

		EOC

		cat >"$tmp/SCRIPTLETS" <<-EOS
		%post
		%{_bindir}/waydroid-overlay-sync --quiet || :

		%postun
		if [ \$1 -eq 0 ]; then %{_bindir}/waydroid-overlay-sync --quiet || :; fi

		EOS
		;;
	group)
		echo "# Metapackage: it is nothing but its dependencies." >"$tmp/BUILD"
		echo "# Metapackage: no payload." >"$tmp/INSTALL"
		printf '%s\n' "$SCRIPTLETS" | sed '/^[[:space:]]*$/d' >"$tmp/SCRIPTLETS"
		;;
	host|fetch)
		printf '%s\n' "$INSTALL" | sed '/^[[:space:]]*$/d' >"$tmp/INSTALL"
		printf '%s\n' "$PAYLOAD_FILES" | sed '/^[[:space:]]*$/d' >"$tmp/FILES"
		printf '%s\n' "$SCRIPTLETS" | sed '/^[[:space:]]*$/d' >"$tmp/SCRIPTLETS"
		;;
	*)
		echo "$mod: unknown KIND=$KIND" >&2; exit 1 ;;
	esac

	: >"$tmp/DOCFILES"
	for d in $DOCS; do
		[ -f "$repo/$d" ] || { echo "$mod: DOCS names $d, which does not exist" >&2; exit 1; }
		echo "%doc $d" >>"$tmp/DOCFILES"
	done

	printf '%s\n' "$DESCRIPTION" | sed 's/[[:space:]]*$//' >"$tmp/DESCRIPTION"

	if [ -f "$MODDIR/$mod.changelog" ]; then
		cat "$MODDIR/$mod.changelog" >"$tmp/CHANGELOG"
	else
		echo "$mod: no changelog at $MODDIR/$mod.changelog" >&2; exit 1
	fi

	# --- splice -----------------------------------------------------------
	awk -v tmp="$tmp" -v mod="$NAME" -v version="$VERSION" -v release="$RELEASE" \
	    -v summary="$SUMMARY" -v license="$LICENSE" '
	function block(name,   line, out) {
		out = ""
		while ((getline line < (tmp "/" name)) > 0) out = out line "\n"
		close(tmp "/" name)
		sub(/\n$/, "", out)
		return out
	}
	{
		gsub(/@MOD@/, mod)
		gsub(/@VERSION@/, version)
		gsub(/@RELEASE@/, release)
		gsub(/@SUMMARY@/, summary)
		gsub(/@LICENSE@/, license)
		if ($0 ~ /^@[A-Z_]+@$/) {
			name = substr($0, 2, length($0) - 2)
			b = block(name)
			if (b != "") print b
			next
		}
		print
	}' "$TEMPLATE" | awk '
		# Collapse runs of blank lines the empty blocks leave behind.
		/^$/ { if (blank++) next } !/^$/ { blank = 0 } { print }'

	rm -rf "$tmp"
	trap - EXIT INT TERM
}

for mod in "$@"; do
	if [ -n "$outdir" ]; then
		mkdir -p "$outdir"
		render_one "$mod" >"$outdir/waydroid-ext-$mod.spec"
		echo "rendered $outdir/waydroid-ext-$mod.spec"
	else
		render_one "$mod"
	fi
done
