#!/bin/sh
# keystore-bench.sh -- test a keystore build on bigtab01 over real binder, with
# no logout, no sudo and nothing Android can see (goal 10, docs/73, docs/74).
#
#     bin/keystore-bench.sh            # after keystore/build.sh and keystore/hal/build.sh
#
# keystore2 binds the strongbox once per Waydroid session, so a build tested
# through Android costs the owner a logout. This runs everything short of that,
# from the dev box, in four steps on the host:
#
#   1. `keystore-engine selftest` against its own throwaway swtpm;
#   2. a second throwaway swtpm, and the daemon under test registered on the
#      container's hwservicemanager as `strongbox-bench` -- an instance no VINTF
#      manifest declares, so keystore2 never looks at it;
#   3. km-bench against that instance, twice: the daemon as it starts by
#      default, then with --accept-unsigned-auth-tokens (km-bench reads which
#      mode it is facing off the key characteristics, docs/74);
#   4. km-bench --tee-probe, two read-only calls to the image's own TEE
#      keymaster that check the shared-key derivation against it.
#
# Why none of it needs root: /dev/hwbinder is 0666, so the daemon can register
# as the ssh user (unconfined_t); swtpm runs as that user on a state directory
# it owns; and km-bench must run as container_runtime_t anyway, because host
# processes may not binder-call each other here (docs/73 finding 4) --
# unconfined_t may enter that domain through runcon on a bin_t-labelled file.
# The service swtpm, its socket and its state are never touched.
#
# The remote half runs from a file, not `sh -s` on stdin: a command that reads
# stdin would otherwise swallow the rest of the script and exit 0 (docs/55).
# Processes are stopped by PID, never `pkill -f`, which over ssh matches the
# remote shell's own command line -- and swtpm by the PID file it writes, since
# bigtab01 has no swtpm_ioctl.
set -eu

HOST=${HOST:-10.42.0.137}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
HAL=${HAL:-$repo/build/keystore-hal}
ENGINE=${ENGINE:-$repo/build/keystore-engine}
D=/var/tmp/wks-bench

for f in "$HAL/waydroid-keystored" "$HAL/km-bench" "$ENGINE"; do
	[ -x "$f" ] || { echo "missing $f -- run keystore/build.sh and keystore/hal/build.sh" >&2; exit 2; }
done

remote=$(mktemp)
trap 'rm -f "$remote"' EXIT
cat >"$remote" <<'EOF'
set -u
D=/var/tmp/wks-bench
cd "$D" || exit 2
fail=0
chcon -t bin_t km-bench waydroid-keystored keystore-engine </dev/null
# Run a step to a log, keep its exit status (a pipe into tail would not), and
# show the end of it.
step() {
	n=$1; shift
	"$@" </dev/null >"$D/$n.out" 2>&1
	rc=$?
	tail -"${SHOW:-40}" "$D/$n.out"
	[ $rc -eq 0 ] || { fail=1; echo "   ** $n exited $rc **"; }
}

echo "== 1. keystore-engine selftest (throwaway swtpm)"
SHOW=2 && step selftest env "KEYSTORE_ENGINE=$D/keystore-engine" sh "$D/selftest.sh"
unset SHOW

echo "== 2. a throwaway swtpm for the bench daemon"
mkdir -p "$D/tpm"
swtpm socket --tpm2 --tpmstate dir="$D/tpm" \
	--server type=unixio,path="$D/tpm/s" --ctrl type=unixio,path="$D/tpm/s.ctrl" \
	--pid file="$D/swtpm.pid" \
	--flags not-need-init,startup-clear --daemon </dev/null || { echo "swtpm failed"; exit 2; }

for mode in default unsigned; do
	flag=
	[ "$mode" = unsigned ] && flag=--accept-unsigned-auth-tokens
	echo "== 3. km-bench, daemon started with ${flag:-no flags}"
	# shellcheck disable=SC2086  # $flag is empty or one word
	./waydroid-keystored --name strongbox-bench --tcti "swtpm:path=$D/tpm/s" $flag \
		</dev/null >"$D/daemon-$mode.log" 2>&1 &
	pid=$!
	i=0
	until grep -q 'Added "' "$D/daemon-$mode.log" 2>/dev/null; do
		i=$((i + 1))
		[ $i -gt 50 ] && { echo "daemon never registered:"; cat "$D/daemon-$mode.log"; fail=1; break; }
		sleep 0.2
	done
	step "bench-$mode" runcon -t container_runtime_t ./km-bench
	kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
	echo "-- daemon log, auth lines:"
	grep -E 'auth|computeSharedHmac|tokens:' "$D/daemon-$mode.log" | sed 's/^/   /' | tail -20
done
# By PID: bigtab01 has no swtpm_ioctl (swtpm-tools), see keystore/selftest.sh.
kill "$(cat "$D/swtpm.pid")" 2>/dev/null

echo "== 4. km-bench --tee-probe (read-only, the image's TEE keymaster)"
step tee-probe runcon -t container_runtime_t ./km-bench --tee-probe

cd / && rm -rf "$D"
exit $fail
EOF

ssh "$HOST" "rm -rf $D && mkdir -p $D/tpm"
scp -q "$HAL/waydroid-keystored" "$HAL/km-bench" "$ENGINE" "$repo/keystore/selftest.sh" \
	"$HOST:$D/"
scp -q "$remote" "$HOST:$D/run.sh"
ssh "$HOST" "sh $D/run.sh"
