#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build-time self-test for waydroid-ext-binder-policy. No root, no SELinux, no
# network, no container -- this runs in %check on a build host that has none of
# them.
#
# WHAT IT IS ACTUALLY FOR
#
# waydroid-binder-policy does not parse the CIL. It carries its own hardcoded
# idea of which permissions and which pair of domains to verify, and its header
# says so deliberately: those are what Android's boot demands, so they are the
# thing to test against, and a CIL that stopped producing them is the regression
# the check should catch.
#
# The cost of that choice is drift. Edit the .cil and the loader goes on
# checking the old rules -- cheerfully reporting "ok" for permissions the policy
# no longer grants, or "REFUSED" for ones it never promised. Neither shows up
# until a container will not boot. So the two are cross-validated here, at build
# time, where disagreement is a failed build instead of a failed boot.
set -eu

src=$(dirname "$0")
CIL="$src/waydroid_binder.cil"
LOADER="$src/waydroid-binder-policy"
UNIT="$src/waydroid-binder-policy.service"
INSTALL="$src/install.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '         want: %s\n         got:  %s\n' "$3" "$2"; fi; }

echo "waydroid-ext-binder-policy selftest"

# 1-3. The policy itself. Statements only: CIL comments start with ';'.
rules=$(grep -v '^[[:space:]]*;' "$CIL" | grep -c '(allow ' || :)
check "the CIL has exactly two allow rules and no others" "$rules" "2"

# Nothing but allow rules -- no typeattribute, no booleans, no dontaudit that
# would hide the very denials this module exists to remove.
others=$(grep -v '^[[:space:]]*;' "$CIL" \
         | grep -oE '^\([a-z]+' | grep -v '^(allow' | sort -u | tr '\n' ' ' || :)
check "the CIL contains no statement other than allow" "$(echo $others)" ""

classes=$(grep -v '^[[:space:]]*;' "$CIL" \
          | sed -n 's/.*(\([a-z_]*\) (\([a-z_ ]*\))).*/\1/p' | sort -u | tr '\n' ' ')
check "every rule is about the binder class" "$(echo $classes)" "binder"

# 4. The permission set, as the policy grants it.
cil_perms=$(grep -v '^[[:space:]]*;' "$CIL" \
            | sed -n 's/.*(binder (\([a-z_ ]*\))).*/\1/p' | tr ' ' '\n' \
            | sort -u | tr '\n' ' ')
loader_perms=$(sed -n "s/^PERMS='\([a-z_ ]*\)'/\1/p" "$LOADER" | tr ' ' '\n' \
               | sort -u | tr '\n' ' ')
check "the loader checks exactly the permissions the CIL grants" \
      "$(echo $loader_perms)" "$(echo $cil_perms)"

# 5. The domain pairs, in both directions. The CIL names bare types; the loader
# names full contexts, because that is what selinuxfs wants. Compare the types.
cil_pairs=$(grep -v '^[[:space:]]*;' "$CIL" \
            | sed -n 's/^(allow \([a-z_]*\) \([a-z_]*\) .*/\1 \2/p' | sort | tr '\n' ';')
loader_pairs=$(sed -n "/^PAIRS='/,/'\$/p" "$LOADER" \
               | grep -oE '[a-z_]+:[a-z_]+:[a-z_]+:s0' \
               | sed 's/^[a-z_]*:[a-z_]*:\([a-z_]*\):s0$/\1/' \
               | paste -d' ' - - | sort | tr '\n' ';')
check "the loader checks exactly the domain pairs the CIL grants" \
      "$loader_pairs" "$cil_pairs"

# 6. Shell syntax, for the two scripts an install actually runs.
for f in "$INSTALL" "$LOADER" "$src/selftest.sh"; do
	if sh -n "$f" 2>/dev/null; then ok "sh -n $(basename "$f")"
	else bad "sh -n $(basename "$f")"; fi
done

# 7. The unit's @BINDIR@ really is substituted. An earlier installer in this
# repository shipped a literal @BINDIR@ and failed silently (docs/25), which is
# why this is a test and not an assumption.
if grep -q '@BINDIR@' "$UNIT"; then ok "the shipped unit still carries the @BINDIR@ token"
else bad "the shipped unit has no @BINDIR@ token to substitute"; fi

# 8. Staging. Everything the spec's %files claims must appear, with no literal
# token left in it.
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT INT TERM
DESTDIR="$stage" PREFIX=/usr CILDIR=/usr/share/waydroid-binder \
	UNITDIR=/usr/lib/systemd/system sh "$INSTALL" >/dev/null

staged=$(cd "$stage" && find . -type f -o -type l | sed 's|^\./||' | sort | tr '\n' ' ')
want="usr/bin/waydroid-binder-policy usr/lib/systemd/system/multi-user.target.wants/waydroid-binder-policy.service usr/lib/systemd/system/waydroid-binder-policy.service usr/share/waydroid-binder/waydroid_binder.cil "
check "install.sh stages exactly the packaged file set" "$staged" "$want"

if grep -q '@BINDIR@' "$stage/usr/lib/systemd/system/waydroid-binder-policy.service"; then
	bad "the staged unit still contains a literal @BINDIR@"
else
	ok "the staged unit has @BINDIR@ substituted"
fi
if grep -q '^ExecStart=/usr/bin/waydroid-binder-policy --quiet$' \
	"$stage/usr/lib/systemd/system/waydroid-binder-policy.service"; then
	ok "the staged unit's ExecStart points at the packaged loader"
else
	bad "the staged unit's ExecStart is not /usr/bin/waydroid-binder-policy --quiet"
fi

# 9. The no-SELinux path. A build host has no selinuxenabled, which is exactly
# the condition the loader must treat as "not my problem" rather than as an
# error -- the unit would otherwise fail on every non-SELinux machine.
empty=$(mktemp -d)
trap 'rm -rf "$stage" "$empty"' EXIT INT TERM
# /bin/sh by absolute path, not `sh`: the PATH assignment applies to the lookup
# of the command it prefixes too, so `PATH=$empty sh ...` fails to find sh
# itself and exits 127, which looks exactly like the loader failing.
if PATH="$empty" CIL="$CIL" STATE_DIR="$empty/state" \
	/bin/sh "$LOADER" --quiet >/dev/null 2>&1; then
	ok "the loader exits 0 where SELinux is unavailable"
else
	bad "the loader fails where SELinux is unavailable (rc=$?)"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
