#!/bin/sh
# selftest.sh -- stand up a throwaway swtpm and run the stage-1 engine against
# it. No sudo, no service socket, no container: it builds (or reuses) the
# keystore-engine binary, starts a private swtpm in a temp dir, runs the engine
# selftest through it, and tears the swtpm down. Exit status is the selftest's.
#
# This is the reproducible form of the stage-1 verification in docs/73, and the
# shape a future CI %check / tests/ hook would take. It needs swtpm and
# tpm2-tools on PATH (the waydroid-ext-swtpm deps).
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
bin=${KEYSTORE_ENGINE:-"$here/../build/keystore-engine"}

[ -x "$bin" ] || sh "$here/build.sh" "$bin"

command -v swtpm >/dev/null 2>&1 || { echo "swtpm not found" >&2; exit 2; }
command -v tpm2_createprimary >/dev/null 2>&1 || { echo "tpm2-tools not found" >&2; exit 2; }

# swtpm refuses a long unixio path (docs/65), so keep it short under /tmp.
dir=$(mktemp -d /tmp/wks-st.XXXXXX)
mkdir -p "$dir/state"
cleanup() {
    [ -S "$dir/s.ctrl" ] && swtpm_ioctl --unix "$dir/s.ctrl" -s 2>/dev/null || true
    rm -rf "$dir"
}
trap cleanup EXIT INT TERM

swtpm socket --tpm2 --tpmstate dir="$dir/state" \
    --server type=unixio,path="$dir/s" \
    --ctrl   type=unixio,path="$dir/s.ctrl" \
    --flags not-need-init,startup-clear --daemon 2>"$dir/err"

# Wait for the socket rather than sleeping a fixed time.
i=0
while [ ! -S "$dir/s" ] && [ $i -lt 50 ]; do i=$((i + 1)); sleep 0.1; done
[ -S "$dir/s" ] || { echo "swtpm did not start:" >&2; cat "$dir/err" >&2; exit 2; }

"$bin" selftest --tcti "swtpm:path=$dir/s"
