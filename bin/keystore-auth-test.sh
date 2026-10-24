#!/bin/sh
# keystore-auth-test.sh -- StrongBox keys bound to the lockscreen credential,
# driven from an ordinary app, end to end (goal 10, docs/74).
#
#     bin/keystore-auth-test.sh
#
# Runs from the dev box. Needs, on bigtab01:
#   - the stage-5 strongbox serving the running session: waydroid-ext-keystored
#     and waydroid-ext-strongbox installed (docs/75), or
#     artifacts/keystore/hand-deploy.sh, then a logout and login;
#   - Keystore Probe with the auth modes (keystore-probe/build.sh --install);
#   - Android unlocked once since boot, or the probe cannot run at all (docs/73).
#
# The user authentication comes one of two ways, chosen by whether Android has
# a lockscreen credential (`dumpsys lock_settings`, which verifies nothing):
#   - none: this sets a temporary PIN, 246810, authenticates with
#     `cmd lock_settings verify --old PIN`, and clears the PIN on every way out
#     of the script. If it is killed hard enough to skip its trap,
#     `cmd lock_settings clear --old 246810` inside the container undoes it.
#   - the owner's own: this never sets, verifies or clears it -- a wrong guess
#     would count against the owner's lockout. It locks the screen and the
#     person at the machine unlocks it, which is the real lockscreen path. One
#     shell inside the container waits for `deviceLocked=0` in `dumpsys trust`
#     and starts the probe the moment it appears, because the keys' 15 s
#     window is too short to spend on ssh round trips. It refuses if the screen
#     does not lock, since then an "unlock" would prove nothing.
#
# The phases, each one launch of the probe (Probe.kt, the auth-* modes):
#   basic       the stage-4 suite, unchanged, as the regression check;
#   wait out the keys' 15 s timeout (after setting the PIN, if it sets one);
#   auth-gen    StrongBox and TEE keys bound to the device credential; neither
#               signs, because nothing has authenticated since;
#   a user authentication -- either way, gatekeeper verifies the credential and
#               gatekeeperd hands keystore2 a real auth token;
#   auth-fresh  both keys sign, and the signatures verify in software;
#   wait out the timeout again;
#   auth-stale  neither signs;
#   auth-clean  the keys are deleted; then the PIN is cleared.
#
# Afterwards it prints the daemon's auth lines for the run, which is where the
# gatekeeper's real token (an all-zero MAC) and the TEE's real verification
# token are seen arriving -- the live half of what km-bench checks synthetically.
set -eu

HOST=${HOST:-10.42.0.137}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
PIN=246810
TIMEOUT=15   # Probe.AUTH_TIMEOUT_S
PKG=com.systemhalted.keystoreprobe
WDATA=/home/jmelanso/.local/share/waydroid/data
REPORTDIR=$WDATA/media/0/Android/data/$PKG/files/reports
OUT=$repo/build/keystore-probe-report
mkdir -p "$OUT"
fail=0

# One command inside the container. waydroid shell always prints a cosmetic
# error and exits non-zero (AGENTS.md), so its status is not the command's. The
# error goes to stdout and ends with the whole command line, so it is cut off
# here: anything matching on this output would otherwise match the command's
# own text -- which is how an "UNLOCKED" marker once matched a wait that had
# timed out.
wsh() {
	{ ssh "$HOST" "sudo waydroid shell -- sh -c '$1' 2>/dev/null" </dev/null || true; } |
		sed '/--details-to-stdout/,$d'
}

report() { echo "keystore-probe${1:+-$1}.txt"; }
launch() { echo "am start -n $PKG/.MainActivity${1:+ --es mode $1}"; }

# One launch of the probe in mode $1 is prepare, launch, collect; phase() does
# all three, and the owner-unlock path puts its own wait between the first two.
prepare() {
	ssh "$HOST" "sudo rm -f '$REPORTDIR/$(report "$1")'" </dev/null
	wsh "am force-stop $PKG"
}
phase() {
	prepare "$1"
	wsh "$(launch "$1")" >/dev/null
	collect "$1"
}
collect() {
	name=$(report "$1")
	i=0
	until ssh "$HOST" "sudo test -s '$REPORTDIR/$name'" </dev/null; do
		i=$((i + 1))
		[ $i -gt 90 ] && { echo "** no $name after 90 s **"; fail=1; return 0; }
		sleep 1
	done
	ssh "$HOST" "sudo cat '$REPORTDIR/$name'" </dev/null >"$OUT/$name"
	sed -n '4,$p' "$OUT/$name"
	grep -q ' 0 failed$' "$OUT/$name" || fail=1
}

since=$(ssh "$HOST" "date '+%F %T'" </dev/null)

echo "== the stage-4 suite, against the stage-5 daemon"
phase ""

cred=$(wsh 'dumpsys lock_settings' | sed -n 's/^ *CredentialType: *//p' | head -1)
case "$cred" in
None)
	echo "== no lockscreen credential: setting the temporary PIN ($PIN)"
	cleanup() {
		echo "== clearing the temporary PIN"
		wsh "cmd lock_settings clear --old $PIN"
	}
	trap cleanup EXIT INT TERM
	wsh "cmd lock_settings set-pin $PIN"
	;;
'')
	echo "could not read the lockscreen credential type: refusing" >&2; exit 3 ;;
*)
	echo "== the owner's lockscreen credential ($cred) will be used, never touched"
	case "$(wsh 'dumpsys trust')" in
	*trusted=1*) echo "a trust agent is granting trust, so an unlock would prove nothing: refusing" >&2; exit 3 ;;
	esac
	;;
esac
echo "   waiting $((TIMEOUT + 3)) s so that no authentication is recent"
sleep $((TIMEOUT + 3))

echo "== auth-gen: keys bound to the credential, nothing authenticated since"
phase auth-gen

if [ "$cred" = None ]; then
	echo "== a user authentication: cmd lock_settings verify"
	wsh "cmd lock_settings verify --old $PIN"
	echo "== auth-fresh"
	phase auth-fresh
else
	echo "== a user authentication: the owner unlocks the lockscreen"
	prepare auth-fresh
	wsh 'input keyevent KEYCODE_SLEEP; sleep 1; input keyevent KEYCODE_WAKEUP'
	i=0
	until wsh 'dumpsys trust' | grep -q 'deviceLocked=1'; do
		i=$((i + 1))
		[ $i -gt 10 ] && { echo "the screen did not lock: refusing, an unlock would prove nothing" >&2; exit 3; }
		sleep 1
	done
	echo "   >> UNLOCK ANDROID NOW with your own credential (waiting up to 10 minutes) <<"
	# The wait and the launch are one shell inside the container, so the probe
	# starts within about a second of the unlock. The \$ are for that shell.
	wait_then_launch="end=\$((\$(date +%s) + 600)); while dumpsys trust | grep -q deviceLocked=1; do"
	wait_then_launch="$wait_then_launch [ \$(date +%s) -ge \$end ] && { echo TIMEOUT; exit 0; }; sleep 0.3; done;"
	got=$(wsh "$wait_then_launch $(launch auth-fresh) >/dev/null; echo UNLOCKED at \$(date +%T)")
	case "$got" in
	*UNLOCKED*) echo "== auth-fresh, started at the unlock ($got)" ;;
	*) echo "** nobody unlocked in 10 minutes **"; exit 1 ;;
	esac
	collect auth-fresh
fi

echo "   waiting $((TIMEOUT + 3)) s for that authentication to expire"
sleep $((TIMEOUT + 3))
echo "== auth-stale"
phase auth-stale

echo "== auth-clean"
phase auth-clean

echo "== the daemon: this session's negotiation, and its auth decisions during the run"
# The packaged daemon logs to its unit's journal; a hand-deployed one to
# hand-deploy.sh's file, which outlives it -- so read the journal whenever the
# unit exists, or this prints another session's lines as if they were this
# run's. Its messages carry the same leading timestamp either way.
ssh "$HOST" "if systemctl cat waydroid-keystored.service >/dev/null 2>&1; then
		kslog() { sudo journalctl -b -u waydroid-keystored -o cat --no-pager; }
	else
		kslog() { sudo cat /var/tmp/waydroid-keystored.log; }
	fi
	kslog | grep -E 'computeSharedHmac|auth tokens:' | tail -2
	kslog | awk -v t='$since' 'substr(\$0, 1, 19) >= t' |
	grep -E 'auth:|USER_SECURE_ID' | tail -30" </dev/null

[ $fail = 0 ] && echo "== all phases passed" || echo "== FAILED (reports in $OUT)"
exit $fail
