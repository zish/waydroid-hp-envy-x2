#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Install every built package into a throwaway root, edit its files behind its
# back, uninstall it, and check that what happened is what we decided should
# happen. Run on the dev box: no sudo, no container runtime, no reboot, and
# bigtab01 is never touched.
#
# WHY THIS EXISTS RATHER THAN A TEST ON THE HOST
#
# bigtab01 is rpm-ostree, so every install/uninstall cycle there costs a reboot,
# and applying anything that touches the overlay restarts the container, which on
# a kiosk drops the session back to the SDDM greeter and needs someone standing
# at the machine. That is the right place to verify the FINAL migration and the
# wrong place to iterate. rpm's own file handling does not need a real host to be
# exercised -- it needs a root directory and a database, and `unshare -r` gives
# both without privilege.
#
# WHAT IT CAN AND CANNOT SEE
#
# Scriptlets are NOT run: rpm chroots into the test root to run them and there is
# no shell in there to run them with. They are syntax-checked with `sh -n`
# instead, which catches the error that actually happens (a typo in a %postun
# nobody executed before shipping) and not the one that does not (a scriptlet
# that runs and misbehaves). Dependencies are skipped for the same reason -- the
# root holds one package, not a Fedora.
#
# THE POLICY THIS ENFORCES
#
# Decided 2026-09-23: an uninstall must never fail, and must never silently
# discard a file somebody edited. rpm gives exactly that for %config files --
# they are preserved as .rpmsave with a warning printed -- and gives the opposite
# for everything else, which it deletes without a word. So the rule this checks
# is: anything under /etc must be marked %config, because /etc is where an
# administrator edits. Everything else lands in /usr, which is read-only on the
# target host and cannot be edited in place at all.
#
# Usage:
#   packaging/test-install.sh --all           every package in build/rpm/RPMS
#   packaging/test-install.sh overlay-sync …  named modifications only
#   packaging/test-install.sh --keep …        leave the test roots for inspection
set -eu

# Re-exec inside a user namespace, where we are root and may chroot. Without it
# `rpm --root` fails with "Unable to change root directory: Operation not
# permitted" and every check below is skipped rather than failed, which is the
# worst of the three outcomes.
#
# Done before the arguments are parsed, so "$@" is still exactly what the caller
# typed: re-exec'ing after the parse meant passing the EXPANDED list back in, and
# --all arrived on the second pass as a package named "ALL".
if [ "${TEST_INSTALL_NS:-0}" != 1 ]; then
	command -v unshare >/dev/null 2>&1 || {
		echo "unshare not found -- cannot make a user namespace to chroot into" >&2
		exit 1
	}
	export TEST_INSTALL_NS=1
	exec unshare -r -m "$0" "$@"
fi

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
TOP="${TOP:-$repo/build/rpm}"
WORK="${WORK:-$TOP/test-install}"
KEEP=0
SELFTEST=0
mods=""

while [ $# -gt 0 ]; do
	case "$1" in
	--all)  mods="ALL"; shift ;;
	--keep) KEEP=1; shift ;;
	--selftest) SELFTEST=1; shift ;;
	-h|--help) sed -n '44,47p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	-*) echo "unknown argument: $1" >&2; exit 2 ;;
	*)  mods="$mods $1"; shift ;;
	esac
done
[ -n "$mods" ] || [ "$SELFTEST" = 1 ] || {
	echo "usage: $0 [--keep] [--selftest] --all | <mod>..." >&2; exit 2; }

if [ "$mods" = "ALL" ]; then
	mods=""
	for r in "$TOP"/RPMS/*/*.rpm; do
		[ -e "$r" ] || continue
		n=$(basename "$r"); n=${n#waydroid-ext-}
		mods="$mods ${n%%-[0-9]*}"
	done
	[ -n "$mods" ] || { echo "no packages in $TOP/RPMS -- run packaging/build-mod.sh first" >&2; exit 1; }
fi

# ---------------------------------------------------------------------- selftest
#
# Every package in this repository happens to ship no %config file, so the two
# checks that matter most below -- that an edited %config survives as .rpmsave,
# and that a plain file under /etc is caught before it ships -- never fire on
# real input. A check that has never failed is not known to work. So --selftest
# builds two deliberate fixtures, one correct and one wrong, and asserts this
# script reaches the right verdict on each.

selftest() {
	ft="$WORK/fixtures"
	rm -rf "$ft"; mkdir -p "$ft"/SPECS "$ft"/RPMS "$ft"/BUILD "$ft"/BUILDROOT "$ft"/SOURCES "$ft"/SRPMS

	# good: the /etc file is %config, which is what the policy requires.
	# bad:  the same file shipped plain, which is the mistake being hunted.
	for kind in good bad; do
		if [ "$kind" = good ]; then cfg='%config(noreplace) /etc/wetest/keep.conf'
		else cfg='/etc/wetest/keep.conf'; fi
		cat >"$ft/SPECS/$kind.spec" <<-EOS
		Name:           waydroid-ext-$kind
		Version:        1.0.0
		Release:        1
		Summary:        test-install.sh fixture ($kind)
		License:        GPL-3.0-or-later
		BuildArch:      noarch
		%description
		A fixture. Not a package anybody installs.
		%install
		mkdir -p %{buildroot}/etc/wetest %{buildroot}%{_bindir}
		echo conf > %{buildroot}/etc/wetest/keep.conf
		echo tool > %{buildroot}%{_bindir}/wetest-tool
		chmod 0755 %{buildroot}%{_bindir}/wetest-tool
		%files
		$cfg
		%{_bindir}/wetest-tool
		EOS
		rpmbuild --define "_topdir $ft" -bb "$ft/SPECS/$kind.spec" >"$ft/$kind.log" 2>&1 || {
			echo "selftest: could not build the $kind fixture" >&2
			sed 's/^/      /' "$ft/$kind.log" | tail -5 >&2
			return 1
		}
	done

	out="$ft/verdicts"
	TOP="$ft" TEST_INSTALL_NS=1 WORK="$ft/roots" sh "$0" good bad >"$out" 2>&1 || :

	sfail=0
	expect() {
		if grep -qF "$2" "$out"; then printf '  ok  selftest: %s\n' "$1"
		else printf '  FAIL selftest: %s\n' "$1"; sfail=1; fi
	}
	expect "an edited %config is kept as .rpmsave and announced" \
	       "ok  every edited %config kept as .rpmsave"
	expect "a plain file under /etc is reported, not passed" \
	       "FAIL under /etc and not %config"
	expect "uninstall still exits 0 in both fixtures" \
	       "ok  uninstall succeeds with edited files present"

	if [ "$sfail" != 0 ]; then
		echo "  the checks below cannot be trusted; full fixture run:" >&2
		sed 's/^/      /' "$out" >&2
		return 1
	fi
	return 0
}

pass=0
fail=0
note() { printf '      %s\n' "$*"; }
ok()   { printf '  ok  %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }

rm -rf "$WORK"
mkdir -p "$WORK"

if [ "$SELFTEST" = 1 ]; then
	printf '== selftest\n'
	if selftest; then pass=$((pass + 3)); else fail=$((fail + 1)); fi
	[ -n "$mods" ] || { printf '\ntest-install: selftest only\n'; [ "$fail" = 0 ]; exit $?; }
fi

for mod in $mods; do
	rpmfile=$(ls -1t "$TOP"/RPMS/*/waydroid-ext-"$mod"-[0-9]*.rpm 2>/dev/null | head -1 || true)
	if [ -z "$rpmfile" ]; then
		printf '\n== %s\n' "$mod"
		bad "no built package: $TOP/RPMS/*/waydroid-ext-$mod-*.rpm (run build-mod.sh)"
		continue
	fi

	printf '\n== %s  (%s)\n' "$mod" "$(basename "$rpmfile")"
	R="$WORK/$mod"
	mkdir -p "$R"

	# --- scriptlets: syntax only, for the reason in the header ---------------
	scripts=$(rpm -qp --scripts "$rpmfile" 2>/dev/null || true)
	if [ -n "$scripts" ]; then
		# Strip rpm's "postinstall scriptlet (using /bin/sh):" banners; what is
		# left is the shell it would run.
		printf '%s\n' "$scripts" | grep -v 'scriptlet (using' >"$R.scripts"
		if sh -n "$R.scripts" 2>"$R.scripts.err"; then
			ok "scriptlets are valid shell"
		else
			bad "scriptlet syntax error: $(head -2 "$R.scripts.err" | tr '\n' ' ')"
		fi
	else
		note "no scriptlets"
	fi

	# --- install -------------------------------------------------------------
	if ! rpm --root "$R" --initdb 2>/dev/null; then
		bad "rpm --initdb failed"; continue
	fi
	if rpm --root "$R" --nodeps --noscripts -i "$rpmfile" 2>"$R.install.err"; then
		ok "installs"
	else
		bad "install failed: $(head -3 "$R.install.err" | tr '\n' ' ')"
		continue
	fi

	# Every path the package claims must actually be on disk.
	missing=0
	for f in $(rpm -qlp "$rpmfile" 2>/dev/null); do
		[ -e "$R$f" ] || { note "claimed but absent: $f"; missing=$((missing + 1)); }
	done
	[ "$missing" = 0 ] && ok "every %files entry is on disk" \
	                   || bad "$missing file(s) claimed by %files and not installed"

	# --- classification: anything under /etc must be %config -----------------
	rpm -qp --configfiles "$rpmfile" 2>/dev/null | sed '/^$/d' | sort >"$R.config"
	rpm -qlp "$rpmfile" 2>/dev/null | sed '/^$/d' | sort >"$R.all"
	unguarded=""
	while read -r f; do
		case "$f" in
		/etc/*) grep -qxF "$f" "$R.config" || unguarded="$unguarded $f" ;;
		esac
	done <"$R.all"
	if [ -n "$unguarded" ]; then
		bad "under /etc and not %config -- an edit here is deleted silently on erase:"
		for f in $unguarded; do note "$f"; done
	else
		ok "no unguarded /etc files"
	fi

	# --- tamper, then erase --------------------------------------------------
	#
	# Edit every regular file the package owns, which is what an administrator
	# chasing a problem does, and then remove the package the ordinary way.
	edited=0
	while read -r f; do
		[ -f "$R$f" ] || continue
		[ -L "$R$f" ] && continue
		printf 'edited-by-hand\n' >>"$R$f"
		edited=$((edited + 1))
	done <"$R.all"
	note "edited $edited file(s) behind rpm's back"

	set +e
	rpm --root "$R" --nodeps --noscripts -e "waydroid-ext-$mod" >"$R.erase.out" 2>&1
	erc=$?
	set -e
	if [ "$erc" = 0 ]; then
		ok "uninstall succeeds with edited files present (exit 0)"
	else
		bad "uninstall exited $erc -- an erase that fails cannot be retried without --noscripts"
		sed 's/^/      /' "$R.erase.out" | head -5
	fi

	# Config files must survive as .rpmsave, and rpm must have said so.
	saved_ok=1
	while read -r f; do
		[ -n "$f" ] || continue
		if [ -e "$R$f.rpmsave" ]; then
			grep -q "$f saved as" "$R.erase.out" || {
				note "preserved but not announced: $f"; saved_ok=0; }
		else
			note "%config NOT preserved: $f"; saved_ok=0
		fi
	done <"$R.config"
	if [ -s "$R.config" ]; then
		[ "$saved_ok" = 1 ] && ok "every edited %config kept as .rpmsave, with a warning" \
		                    || bad "a %config file was not preserved or not announced"
	else
		note "package ships no %config files"
	fi

	# Everything else must be gone: that is what makes an uninstall an uninstall.
	left=""
	while read -r f; do
		case "$f" in
		"") continue ;;
		esac
		grep -qxF "$f" "$R.config" && continue
		[ -e "$R$f" ] && left="$left $f"
	done <"$R.all"
	if [ -n "$left" ]; then
		bad "left behind after erase:"
		for f in $left; do note "$f"; done
	else
		ok "all non-config files removed"
	fi
done

printf '\n%s\n' "----------------------------------------------------------------"
printf 'test-install: %d passed, %d failed\n' "$pass" "$fail"
[ "$KEEP" = 1 ] && printf 'roots kept under %s\n' "$WORK" || rm -rf "$WORK"
[ "$fail" = 0 ]
