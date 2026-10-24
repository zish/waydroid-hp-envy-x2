#!/bin/sh
# selftest.sh -- stand up a throwaway swtpm and run the stage-1 engine against
# it. No sudo, no service socket, no container: it builds (or reuses) the
# keystore-engine binary, starts a private swtpm in a temp dir, runs the engine
# selftest through it, and tears the swtpm down. Exit status is the selftest's.
#
# This is the reproducible form of the stage-1 verification in docs/73, and the
# shape a future CI %check / tests/ hook would take. It needs swtpm and
# tpm2-tools on PATH (the waydroid-ext-swtpm deps), and openssl for the checks
# that verify signatures independently; without it those are SKIPPED.
set -eu

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# KEYSTORE_ENGINE names a prebuilt binary -- how it runs on bigtab01, which has
# no compiler. Otherwise rebuild every time: a stale binary passing is worse
# than a slow run.
if [ -n "${KEYSTORE_ENGINE:-}" ]; then
    bin=$KEYSTORE_ENGINE
else
    bin="$here/../build/keystore-engine"
    sh "$here/build.sh" "$bin" >/dev/null
fi

command -v swtpm >/dev/null 2>&1 || { echo "swtpm not found" >&2; exit 2; }
command -v tpm2_createprimary >/dev/null 2>&1 || { echo "tpm2-tools not found" >&2; exit 2; }

# swtpm refuses a long unixio path (docs/65), so keep it short under /tmp.
dir=$(mktemp -d /tmp/wks-st.XXXXXX)
mkdir -p "$dir/state"
# Stopped by the PID it writes, not swtpm_ioctl: that is swtpm-tools, which
# bigtab01 does not have, so the old `swtpm_ioctl -s 2>/dev/null` failed silently
# there and left one swtpm running per selftest (docs/74).
cleanup() {
    [ -s "$dir/pid" ] && kill "$(cat "$dir/pid")" 2>/dev/null || true
    rm -rf "$dir"
}
trap cleanup EXIT INT TERM

swtpm socket --tpm2 --tpmstate dir="$dir/state" \
    --server type=unixio,path="$dir/s" \
    --ctrl   type=unixio,path="$dir/s.ctrl" \
    --pid file="$dir/pid" \
    --flags not-need-init,startup-clear --daemon 2>"$dir/err"

# Wait for the socket rather than sleeping a fixed time.
i=0
while [ ! -S "$dir/s" ] && [ $i -lt 50 ]; do i=$((i + 1)); sleep 0.1; done
[ -S "$dir/s" ] || { echo "swtpm did not start:" >&2; cat "$dir/err" >&2; exit 2; }

"$bin" selftest --tcti "swtpm:path=$dir/s"
