#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build-time self-test for waydroid-ext-wifid. No root, no container, no
# gbinder, no compiled daemon -- this runs in %check on a build host that has
# none of them, and on the --prebuilt path where the binary was built
# elsewhere. Everything here is a source-level assertion.
#
# WHAT IT IS ACTUALLY FOR: THE PROTOCOL TRIPWIRE
#
# wifid talks to Android's service manager over gbinder, and WHICH WIRE
# PROTOCOL it must speak is a property of the Android image, not of this
# daemon. Waydroid picks it in tools/helpers/protocol.py:
#
#     Android 13 (API 33)   service_manager_protocol = aidl3
#     Android 16 (API 36)   service_manager_protocol = aidl6   <-- the change
#
# and the binder/RPC protocol stays aidl3 across both. Measured on vidiot01's
# live waydroid.cfg, which reads binder_protocol = aidl3 and
# service_manager_protocol = aidl6. docs/64.
#
# service.cpp hardcodes both as #defines. That is fine while the package claims
# one Android version and is a silent lie the moment it claims two, because one
# compiled constant cannot be aidl3 and aidl6 at the same time. So this check
# pins the constants, and the rule it enforces is:
#
#   IF YOU CHANGE SM_PROTOCOL HERE, CHANGE ANDROID= IN packaging/mods/wifid.mod
#   IN THE SAME COMMIT -- and if you want wifid to support BOTH images, the
#   constant has to stop being a constant first. A #define cannot be two values,
#   so ANDROID="13 16" with a hardcoded SM_PROTOCOL is a package that is wrong
#   on one of the two hosts it claims.
#
# This is the same idiom as the .orig files in docs/47: not a restore point, a
# tripwire. It cannot verify the daemon works -- that needs a container -- but
# it makes the one cross-image assumption impossible to change silently.
set -eu

src=$(dirname "$0")
repo=$(cd "$src/../.." && pwd)
SERVICE="$repo/wifi/service.cpp"

pass=0; fail=0; skip=0
# A SKIP IS REPORTED, NEVER SILENT. artifacts/wifi/ holds the payload of two
# modifications -- wifid and wifi-sync -- and each package's tarball carries
# only its own, so three of the files below are legitimately absent when this
# runs inside wifid's %check. Absent is fine; absent and unmentioned is how
# "11 passed" quietly becomes "8 passed" and nobody asks why.
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
note(){ skip=$((skip+1)); printf '  --   skipped: %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '         want: %s\n         got:  %s\n' "$3" "$2"; fi; }

echo "waydroid-ext-wifid selftest"

[ -f "$SERVICE" ] || { echo "  FAIL cannot find wifi/service.cpp at $SERVICE"; exit 1; }

# --- the tripwire -----------------------------------------------------------
define_of() {
	sed -n "s/^#define[[:space:]]\+$1[[:space:]]\+\"\([a-z0-9]*\)\".*/\1/p" "$SERVICE" | head -1
}
sm=$(define_of SM_PROTOCOL)
rpc=$(define_of RPC_PROTOCOL)

check "SM_PROTOCOL is aidl3 (Android 13; A16 needs aidl6)" "$sm"  "aidl3"
check "RPC_PROTOCOL is aidl3 (unchanged across 13 and 16)" "$rpc" "aidl3"

# The macros must actually reach gbinder. A literal passed at the call site
# would make the two assertions above true and meaningless.
if grep -q 'gbinder_servicemanager_new2(device, SM_PROTOCOL, RPC_PROTOCOL)' "$SERVICE"; then
	ok "the service manager is opened with the macros, not literals"
else
	bad "gbinder_servicemanager_new2 does not use SM_PROTOCOL/RPC_PROTOCOL"
fi

# Written as a real pipeline, not `grep -q | grep -qv`: -q produces no output,
# so that form feeds the second grep an empty stream and can never fire. It
# passed for the wrong reason until this was noticed.
if grep -nE '"aidl[0-9]"' "$SERVICE" | grep -v '#define' | grep -q .; then
	bad "a bare aidlN literal appears outside the #defines"
	grep -nE '"aidl[0-9]"' "$SERVICE" | grep -v '#define' | sed 's/^/         /'
else
	ok "no bare aidlN literal outside the #defines"
fi

# --- the ordinary hygiene the other packages here also get ------------------
# Each script is parsed by the interpreter ITS OWN shebang names.
# waydroid-wifi-sync is #!/bin/bash and `sh -n` is dash here, which rejects
# perfectly good bash -- checking everything with `sh -n` reports a failure
# that is the test's fault and not the code's.
for f in "$src/install.sh" "$src/waydroid-wifi-nudge" "$src/waydroid-wifi-sync" \
         "$src/selftest.sh"; do
	[ -f "$f" ] || { note "$(basename "$f") (not in this package's payload)"; continue; }
	interp=$(sed -n '1s|^#!\s*\(/[^ ]*\).*|\1|p' "$f")
	[ -n "$interp" ] && [ -x "$interp" ] || interp=/bin/sh
	if "$interp" -n "$f" 2>/dev/null; then ok "$(basename "$interp") -n $(basename "$f")"
	else bad "$(basename "$interp") -n $(basename "$f")"; fi
done

# @BINDIR@ must still be there to substitute. An earlier installer in this
# repository shipped the literal token and failed silently (docs/25).
for u in "$src"/*.service "$src"/*.timer; do
	[ -f "$u" ] || continue   # the glob itself, when nothing matches
	if grep -q '@BINDIR@' "$u"; then
		ok "$(basename "$u") still carries the @BINDIR@ token"
	else
		case "$(basename "$u")" in
		*.timer) ok "$(basename "$u") needs no @BINDIR@" ;;
		*) bad "$(basename "$u") has no @BINDIR@ token to substitute" ;;
		esac
	fi
done

if [ "$skip" -gt 0 ]; then
	echo "$pass passed, $fail failed, $skip skipped"
else
	echo "$pass passed, $fail failed"
fi
[ "$fail" -eq 0 ]
