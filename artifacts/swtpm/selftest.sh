#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build-time self-test for waydroid-ext-swtpm. No root, no SELinux, no network,
# no systemd -- it runs in %check on a build host that has none of them.
#
# TWO HALVES.
#
# The static half cross-validates the three files against each other, because
# each one carries a fact the others depend on and nothing else connects them:
# the unit names the runtime directory, the wrapper names the socket inside it,
# and waydroid-tpm-check hardcodes the resulting path as its default TCTI. Rename
# one and the check goes on defaulting to a socket that no longer exists, which
# presents as "is the service running?" on a host where it is.
#
# The live half runs the real thing: swtpm through the wrapper exactly as the
# unit would start it, waydroid-tpm-check against it, a restart on the same
# state, and a fresh state that must be told apart. It needs swtpm, tpm2-tools
# and tcti-swtpm. Where they are missing it SKIPs, unless
# WAYDROID_SWTPM_SELFTEST_LIVE=require -- which %check sets, because the .mod's
# BuildRequires guarantee the tools there, so a skip in %check would be a test
# quietly not running.
set -u

src=$(CDPATH="" cd -- "$(dirname -- "$0")" && pwd)
UNIT=$src/waydroid-swtpm.service
WRAP=$src/waydroid-swtpm
CHECK=$src/waydroid-tpm-check

pass=0; fail=0; skip=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '         want: %s\n         got:  %s\n' "$3" "$2"; fi; }

echo "waydroid-ext-swtpm selftest"

key() { sed -n "s/^$1=//p" "$UNIT" | tail -n 1; }

# 1. The label trap: Fedora's waydroid policy claims /var/lib/waydroid(.*)? and
#    /run/waydroid-(?!lxc).* by prefix.
state=$(key StateDirectory); runtime=$(key RuntimeDirectory)
case $state in
    ''|waydroid*) bad "StateDirectory escapes waydroid_data_t (got '$state')" ;;
    *) ok "StateDirectory=$state escapes waydroid_data_t" ;;
esac
case $runtime in
    ''|waydroid*) bad "RuntimeDirectory escapes waydroid_var_run_t (got '$runtime')" ;;
    *) ok "RuntimeDirectory=$runtime escapes waydroid_var_run_t" ;;
esac

# 2. The check's default socket is the one the unit and the wrapper produce.
# shellcheck disable=SC2016  # the $ is the wrapper's literal text, not ours
wrap_sock=$(sed -n 's|.*--server "type=unixio,path=$RUNTIME_DIRECTORY/\([^,"]*\).*|\1|p' "$WRAP")
want_tcti="swtpm:path=/run/$runtime/$wrap_sock"
# shellcheck disable=SC2016  # likewise the check's literal ${TPM2TOOLS_TCTI:-...}
got_tcti=$(sed -n 's/^TCTI=\${TPM2TOOLS_TCTI:-\(.*\)}$/\1/p' "$CHECK")
check "waydroid-tpm-check defaults to the socket the unit creates" "$got_tcti" "$want_tcti"

# 3. tcti-swtpm derives the control socket by appending .ctrl to the server path.
# shellcheck disable=SC2016  # the wrapper's literal text
wrap_ctrl=$(sed -n 's|.*--ctrl "type=unixio,path=$RUNTIME_DIRECTORY/\([^,"]*\).*|\1|p' "$WRAP")
check "control socket is the server path plus .ctrl" "$wrap_ctrl" "$wrap_sock.ctrl"

# 4. The wrapper refuses to run outside the unit rather than inventing paths.
if env -u STATE_DIRECTORY -u RUNTIME_DIRECTORY sh "$WRAP" >/dev/null 2>&1; then
    bad "wrapper refuses to run without StateDirectory/RuntimeDirectory"
else
    ok "wrapper refuses to run without StateDirectory/RuntimeDirectory"
fi

# 5. The installer substitutes every placeholder and enables the unit.
stage=$(mktemp -d "${TMPDIR:-/tmp}/swtpm-selftest-stage.XXXXXX")
DESTDIR=$stage PREFIX=/usr UNITDIR=/usr/lib/systemd/system sh "$src/install.sh" >/dev/null
check "installed unit runs the installed wrapper" \
      "$(sed -n 's/^ExecStart=//p' "$stage/usr/lib/systemd/system/waydroid-swtpm.service")" \
      "/usr/libexec/waydroid-swtpm"
check "no @PLACEHOLDER@ survives installation" \
      "$(grep -rl '@[A-Z]*@' "$stage" 2>/dev/null | wc -l | tr -d ' ')" "0"
check "multi-user.target.wants symlink points at the unit" \
      "$(readlink "$stage/usr/lib/systemd/system/multi-user.target.wants/waydroid-swtpm.service")" \
      "../waydroid-swtpm.service"
for f in usr/libexec/waydroid-swtpm usr/bin/waydroid-tpm-check; do
    if [ -x "$stage/$f" ]; then ok "installed executable: /$f"; else bad "installed executable: /$f"; fi
done
rm -rf "$stage"

# 6-9. Live.
live=yes
for t in swtpm tpm2_getcap tpm2_createprimary tpm2_unseal; do
    command -v "$t" >/dev/null 2>&1 || { live="no ($t not found)"; break; }
done
if [ "$live" = yes ]; then
    run=$(mktemp -d "${TMPDIR:-/tmp}/swtpm-selftest.XXXXXX")
    # Relative socket paths: swtpm refuses a unixio path longer than sun_path,
    # and a build host's TMPDIR can be deep. The check accepts a relative TCTI.
    cd "$run" || exit 1
    mkdir st st2 r
    spid=
    start() {
        STATE_DIRECTORY=$1 RUNTIME_DIRECTORY=r sh "$WRAP" >>swtpm.log 2>&1 &
        spid=$!
        i=0; while [ ! -S r/sock ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
    }
    stop() { [ -n "$spid" ] && kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null; spid=; rm -f r/sock r/sock.ctrl; }
    trap 'stop; cd /; rm -rf "$run"' EXIT

    start st
    if [ -S r/sock ]; then
        check "server socket mode is 0660" "$(stat -c %a r/sock)" "660"
        check "control socket mode is 0660" "$(stat -c %a r/sock.ctrl)" "660"
    else
        bad "swtpm did not create its socket"; sed 's/^/         /' swtpm.log
    fi
    if TMPDIR=$run sh "$CHECK" --tcti swtpm:path=r/sock --save saved >check1.log 2>&1; then
        ok "waydroid-tpm-check passes against the wrapper"
    else
        bad "waydroid-tpm-check passes against the wrapper"; sed 's/^/         /' check1.log
    fi
    # Without the per-step flush, swtpm's three transient slots run out on the
    # third object and every later command fails until swtpm restarts.
    if TMPDIR=$run sh "$CHECK" --tcti swtpm:path=r/sock >check2.log 2>&1; then
        ok "a second run finds the slots free again (nothing leaked)"
    else
        bad "a second run finds the slots free again (nothing leaked)"; sed 's/^/         /' check2.log
    fi
    stop

    start st
    if TMPDIR=$run sh "$CHECK" --tcti swtpm:path=r/sock --verify-saved saved >check3.log 2>&1; then
        ok "after a restart on the same state the sealed blob still unseals"
    else
        bad "after a restart on the same state the sealed blob still unseals"; sed 's/^/         /' check3.log
    fi
    stop

    start st2
    if TMPDIR=$run sh "$CHECK" --tcti swtpm:path=r/sock --verify-saved saved >check4.log 2>&1; then
        bad "a fresh state is told apart (--verify-saved must fail)"
    else
        if grep -q 'owner primary differs' check4.log; then
            ok "a fresh state is told apart (--verify-saved must fail)"
        else
            bad "a fresh state is told apart, for the right reason"; sed 's/^/         /' check4.log
        fi
    fi
    stop
else
    if [ "${WAYDROID_SWTPM_SELFTEST_LIVE:-}" = require ]; then
        bad "live half required but cannot run: $live"
    else
        skip=$((skip+1)); echo "  SKIP live half: $live"
    fi
fi

echo "$pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
