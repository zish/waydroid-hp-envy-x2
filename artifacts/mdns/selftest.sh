#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Check waydroid-mdns-reflector's merge against the files docs/45-mdns-reflection.md
# was verified with. Runs anywhere, changes nothing outside a temp directory,
# needs no avahi, no firewalld and no root -- which is why it can be the RPM's
# %check as well as something to run from a checkout.
#
# WHY THIS IS NOT BOX-TICKING
#
# The merge is the only part of this modification that edits a file belonging to
# another package, and it has one failure mode that is worse than not working:
# avahi refuses to START on an unknown key, so a merge that puts a key in the
# wrong section leaves the host with no mDNS at all, including the host's own.
# Appending to the end of the file -- which is exactly what the dexopt
# reconciler's flat key=value merge does, correctly, for a property file --
# would land `enable-reflector=yes` inside [rlimits]. Case 1 below is the test
# that would catch it, and it is strict: byte-for-byte equality with the file
# that printed a page on 2026-09-11.
#
#     sh artifacts/mdns/selftest.sh
set -eu

src=$(cd "$(dirname "$0")" && pwd)
tool=$src/waydroid-mdns-reflector
conf=$src/waydroid-mdns.conf
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# The installed tool substitutes @SYSCONFDIR@; here --config is always passed, so
# the default never matters and the unsubstituted source runs as-is.
run() { sh "$tool" --config "$conf" "$@"; }

# --- 1: stock Fedora avahi-daemon.conf becomes the configuration that worked ---
#
# .orig is what the avahi package shipped; the other is what was on the host when
# a test page came out of the Canon. If the merge cannot reproduce the second
# from the first, this package does not do what docs/45 says it does.
if run --render "$src/avahi-daemon.conf.orig" >"$work/merged" 2>"$work/err"; then
	if cmp -s "$work/merged" "$src/avahi-daemon.conf"; then
		ok "stock avahi-daemon.conf merges to the verified file, byte for byte"
	else
		bad "merged file differs from artifacts/mdns/avahi-daemon.conf"
		diff -u "$src/avahi-daemon.conf" "$work/merged" | sed 's/^/       /' || :
	fi
else
	bad "--render failed: $(tr '\n' ' ' <"$work/err")"
fi

# --- 2: idempotent -------------------------------------------------------------
#
# The claim a reconciler lives or dies by. A second run must change nothing, or
# every boot restarts avahi.
if run --render "$src/avahi-daemon.conf" >"$work/again" 2>/dev/null &&
   cmp -s "$work/again" "$src/avahi-daemon.conf"; then
	ok "re-merging the already-merged file is a no-op"
else
	bad "merge is not idempotent"
	diff -u "$src/avahi-daemon.conf" "$work/again" | sed 's/^/       /' || :
fi

# --- 3: the key goes in the right section, even with no section to put it in ----
#
# The failure this whole file exists for. With no [reflector] section the keys
# must arrive under one we add, never at the end of whatever section happens to
# be last.
cat >"$work/nosection" <<'INNER'
[server]
use-ipv4=yes

[rlimits]
#rlimit-nproc=3
INNER
run --render "$work/nosection" >"$work/nosection.out" 2>/dev/null
if [ "$(sed -n '$=' "$work/nosection.out")" ] &&
   awk '/^\[/ { sec = $0 } /^enable-reflector=/ { print sec }' "$work/nosection.out" |
       grep -qx '\[reflector\]' &&
   awk '/^\[/ { sec = $0 } /^reflect-filters=/ { print sec }' "$work/nosection.out" |
       grep -qx '\[reflector\]'; then
	ok "a file with no [reflector] section gets one, and both keys land in it"
else
	bad "keys did not land under [reflector] when the section was absent"
	sed 's/^/       /' "$work/nosection.out"
fi

# --- 4: nothing outside [reflector] is touched ---------------------------------
#
# A key with the same name in another section is not ours to rewrite, and the
# sixty lines this edit is supposed to leave alone have to actually survive.
if [ "$(grep -c . "$work/nosection.out")" -ge "$(grep -c . "$work/nosection")" ] &&
   grep -qx 'use-ipv4=yes' "$work/nosection.out" &&
   grep -qx '#rlimit-nproc=3' "$work/nosection.out"; then
	ok "lines in other sections are preserved verbatim"
else
	bad "the merge altered lines outside [reflector]"
fi

# --- 5: a duplicate active key collapses to one -------------------------------
#
# Two active enable-reflector lines is a file avahi reads the last of. Leaving
# both would make the next --verify disagree with itself forever.
printf '[reflector]\nenable-reflector=no\nenable-reflector=no\n' >"$work/dup"
run --render "$work/dup" >"$work/dup.out" 2>/dev/null
if [ "$(grep -c '^enable-reflector=' "$work/dup.out")" = 1 ] &&
   grep -qx 'enable-reflector=yes' "$work/dup.out"; then
	ok "a duplicated key collapses to one line with our value"
else
	bad "duplicate key handling is wrong"
	sed 's/^/       /' "$work/dup.out"
fi

# --- 6: an unknown key in waydroid-mdns.conf is refused, not passed through ----
#
# Passing it through is the one outcome that stops the host's mDNS entirely.
printf 'enable-reflector=yes\nreflect-everything=yes\n' >"$work/badconf"
if sh "$tool" --config "$work/badconf" --render "$src/avahi-daemon.conf.orig" \
       >"$work/badconf.out" 2>"$work/badconf.err"; then
	bad "an unknown key was accepted -- avahi would refuse to start"
else
	rc=$?
	if [ "$rc" = 2 ] && grep -q 'reflect-everything' "$work/badconf.err"; then
		ok "an unknown key is refused with exit 2 and is named"
	else
		bad "unknown key rejected with exit $rc and no useful message"
		sed 's/^/       /' "$work/badconf.err"
	fi
fi

# --- 7: a value that would not parse is refused -------------------------------
printf 'reflect-filters=_ipp._tcp.local "oops"\n' >"$work/badval"
if sh "$tool" --config "$work/badval" --render "$src/avahi-daemon.conf.orig" \
       >/dev/null 2>"$work/badval.err"; then
	bad "a value containing a quote and a space was accepted"
else
	ok "a value avahi could not parse is refused"
fi

# --- 8: the support gate reads the binary, not the version string -------------
#
# Fedora's 0.9~rc2 reports 0.8 from --version, so --check-support must key off
# the daemon's own strings. Two fixtures: one that contains the key names and one
# that does not.
printf 'junk enable-reflector junk reflect-filters junk\n' >"$work/fake-avahi"
printf 'junk enable-reflector junk\n' >"$work/old-avahi"
chmod 0755 "$work/fake-avahi" "$work/old-avahi"
if WAYDROID_MDNS_AVAHI_BIN="$work/fake-avahi" run --check-support --quiet >/dev/null 2>&1; then
	ok "--check-support passes a daemon whose binary carries both key names"
else
	bad "--check-support rejected a binary that has the keys"
fi
if WAYDROID_MDNS_AVAHI_BIN="$work/old-avahi" run --check-support --quiet >/dev/null 2>&1; then
	bad "--check-support passed a daemon with no reflect-filters -- avahi would not start"
else
	rc=$?
	[ "$rc" = 4 ] && ok "--check-support refuses a daemon without reflect-filters, exit 4" \
	              || bad "--check-support refused with exit $rc, expected 4"
fi

# --- 9: the firewalld rule still matches the one recorded as verified ---------
#
# artifacts/mdns/firewalld-public.xml is the zone file as it was when the probe
# went from silence to a complete answer. The tool builds the rule as a
# firewall-cmd string, so the two can drift apart silently; this ties them.
rule=$(sed -n "s/^RICH_RULE='\(.*\)'$/\1/p" "$tool")
if [ -z "$rule" ]; then
	bad "could not read RICH_RULE out of the tool"
else
	zok=1
	for want in 'family="ipv4"' 'port="5353"' 'protocol="udp"'; do
		case "$rule" in *"$want"*) ;; *) zok=0 ;; esac
	done
	case "$rule" in *accept*) ;; *) zok=0 ;; esac
	grep -q 'family="ipv4"'               "$src/firewalld-public.xml" || zok=0
	grep -q 'port="5353" protocol="udp"'  "$src/firewalld-public.xml" || zok=0
	grep -q '<accept/>'                   "$src/firewalld-public.xml" || zok=0
	grep -q 'source-port'                 "$src/firewalld-public.xml" || zok=0
	[ "$zok" = 1 ] && ok "the rule the tool adds is the rule firewalld-public.xml records" \
	               || bad "the tool's rule and the recorded zone file have drifted apart"
fi

printf '\nmdns selftest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
