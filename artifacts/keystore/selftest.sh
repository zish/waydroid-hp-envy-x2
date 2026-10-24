#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build-time self-test for waydroid-ext-keystored (docs/75). No root, no
# binder, no container -- it runs in %check and in tests/run.sh.
#
# TWO HALVES, as artifacts/swtpm/selftest.sh has.
#
# The static half cross-checks facts that live in different files with nothing
# else connecting them: the TPM socket the daemon defaults to, the one the conf
# documents and the one waydroid-tpm-check uses; the binder node the unit names
# and the mount it requires; the variable the conf sets and the unit expands;
# the stock and result hashes waydroid-ext-strongbox's derive row pins and the
# ones strongbox-manifest.sh pins; and the installed layout. A check whose files
# are not in this tree (the RPM's tarball carries only its own) is skipped.
#
# The live half runs keystore/selftest.sh: the TPM keyblob engine against a
# throwaway swtpm, every expected value from an outside reference (docs/73,
# docs/74). It needs swtpm, tpm2-tools and a C++ compiler, and SKIPs without
# them unless WAYDROID_KEYSTORE_SELFTEST_LIVE=require -- which %check sets,
# because the .mod's BuildRequires guarantee them there.
set -u

src=$(CDPATH="" cd -- "$(dirname -- "$0")" && pwd)
repo=$(cd "$src/../.." && pwd)
UNIT=$src/waydroid-keystored.service
CONF=$src/waydroid-keystored.conf

pass=0; fail=0; skip=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
skp()  { skip=$((skip+1)); printf '  skip %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '         want: %s\n         got:  %s\n' "$3" "$2"; fi; }

echo "waydroid-ext-keystored selftest"

# 1. One TPM socket, named in three places.
daemon_tcti=$(sed -n 's/.*const char\* tcti = "\([^"]*\)";.*/\1/p' "$repo/keystore/hal/service.cpp")
# The conf names it mid-sentence, so the trailing full stop is not part of it.
conf_tcti=$(sed -n 's/^#.*\(swtpm:path=[^ ,]*[^ ,.]\).*/\1/p' "$CONF" | head -n 1)
check "the conf documents the daemon's default TPM" "$conf_tcti" "$daemon_tcti"
if [ -f "$repo/artifacts/swtpm/waydroid-tpm-check" ]; then
	# shellcheck disable=SC2016  # the check's literal ${TPM2TOOLS_TCTI:-...}
	tpmcheck_tcti=$(sed -n 's/^TCTI=\${TPM2TOOLS_TCTI:-\(.*\)}$/\1/p' "$repo/artifacts/swtpm/waydroid-tpm-check")
	check "the daemon defaults to waydroid-swtpm's socket" "$daemon_tcti" "$tpmcheck_tcti"
else
	skp "waydroid-tpm-check is not in this tree"
fi

# 2. The binder node by its binderfs name, and the mount that makes it.
exec_dev=$(sed -n 's/^ExecStart=.* \(\/dev\/[^ ]*\)$/\1/p' "$UNIT")
check "ExecStart names hwbinder by its binderfs path" "$exec_dev" "/dev/binderfs/hwbinder"
grep -q '^Requires=dev-binderfs.mount$' "$UNIT" && ok "the unit requires dev-binderfs.mount" || bad "the unit does not require dev-binderfs.mount"

# 3. The variable the conf sets is the one the unit expands.
var=$(sed -n 's/^\([A-Z_]*\)=.*/\1/p' "$CONF" | head -n 1)
grep -q "^ExecStart=.*\\\$$var " "$UNIT" && ok "the unit expands \$$var, which the conf sets" || bad "the unit does not expand \$$var"
grep -q '^EnvironmentFile=-/etc/waydroid-keystored.conf$' "$UNIT" && ok "the unit reads /etc/waydroid-keystored.conf, optionally" || bad "EnvironmentFile is not /etc/waydroid-keystored.conf"

# 4. Two places pin the strongbox manifest's hashes; they must be one pair.
mod=$repo/packaging/mods/strongbox.mod
if [ -f "$mod" ] && [ -f "$src/strongbox-manifest.sh" ]; then
	row=$(sed -n 's/^derive .* vendor \/etc\/vintf\/manifest.xml \([0-9a-f]\{64\}\) \([0-9a-f]\{64\}\) .*/\1 \2/p' "$mod")
	pinned="$(sed -n 's/^STOCK_SHA=//p' "$src/strongbox-manifest.sh") $(sed -n 's/^RESULT_SHA=//p' "$src/strongbox-manifest.sh")"
	check "strongbox.mod's derive row and strongbox-manifest.sh pin the same stock and result" "$row" "$pinned"
else
	skp "strongbox.mod and strongbox-manifest.sh are not both in this tree"
fi

# 5. The installed layout, into a scratch DESTDIR with a stand-in daemon.
t=$(mktemp -d)
printf '#!/bin/sh\n' >"$t/daemon"; chmod +x "$t/daemon"
if DESTDIR="$t/root" PREFIX=/usr UNITDIR=/usr/lib/systemd/system SYSCONFDIR=/etc \
	KEYSTORED_BIN="$t/daemon" sh "$src/install.sh" >/dev/null; then
	for f in usr/bin/waydroid-keystored usr/lib/systemd/system/waydroid-keystored.service etc/waydroid-keystored.conf; do
		[ -f "$t/root/$f" ] && ok "installs /$f" || bad "does not install /$f"
	done
	check "the unit is enabled by a relative .wants link" \
		"$(readlink "$t/root/usr/lib/systemd/system/multi-user.target.wants/waydroid-keystored.service")" \
		"../waydroid-keystored.service"
	check "@BINDIR@ is substituted with the install's own bindir" \
		"$(sed -n 's/^ExecStart=\([^ ]*\) .*/\1/p' "$t/root/usr/lib/systemd/system/waydroid-keystored.service")" \
		"/usr/bin/waydroid-keystored"
else
	bad "install.sh failed into a scratch DESTDIR"
fi
rm -rf "$t"

# 6. The live half.
if command -v swtpm >/dev/null 2>&1 && command -v tpm2_createprimary >/dev/null 2>&1 &&
   command -v "${CXX:-g++}" >/dev/null 2>&1; then
	if sh "$repo/keystore/selftest.sh" >"${TMPDIR:-/tmp}/keystore-selftest.$$" 2>&1; then
		ok "the keyblob engine against a throwaway swtpm: $(tail -n 1 "${TMPDIR:-/tmp}/keystore-selftest.$$")"
	else
		cat "${TMPDIR:-/tmp}/keystore-selftest.$$"
		bad "the keyblob engine against a throwaway swtpm"
	fi
	rm -f "${TMPDIR:-/tmp}/keystore-selftest.$$"
elif [ "${WAYDROID_KEYSTORE_SELFTEST_LIVE:-}" = require ]; then
	bad "swtpm, tpm2-tools or a C++ compiler is missing, and the live half is required"
else
	skp "the live half: swtpm, tpm2-tools or a C++ compiler is missing"
fi

echo "$pass passed, $fail failed, $skip skipped"
[ "$fail" = 0 ]
