#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# `systemd-analyze verify` every systemd unit the built packages ship.
#
# WHY THE PACKAGES AND NOT artifacts/
#
# The units in artifacts/ say ExecStart=@BINDIR@/..., filled in by each
# install.sh, so verifying the source files reports every one of them broken.
# The RPMs hold what a host actually gets -- placeholders substituted, files at
# their real paths -- so they are extracted (rpm2cpio, no root, no rpm database)
# and those are verified. A placeholder that survives into a package is then a
# failure, which is a bug worth catching in its own right.
#
# WHAT IS CHECKED
#
# Each unit is loaded with the extracted tree first on systemd's unit search
# path and the checking machine's own units after it, so Wants=/After= on
# sysinit.target and friends resolve. verify reports unknown keys, malformed
# values, missing dependency units and Exec*= binaries that are not
# executable. A binary is looked up in the extracted tree, because verify
# itself can only look on the machine it runs on.
#
# Units that other packages provide -- waydroid's, today only dev-binderfs.mount
# and waydroid-container.service -- are stubbed below. The stub for
# waydroid-container.service is what lets binder-nice's drop-in be verified at
# all: a drop-in is only parsed as part of the unit it extends.
#
# Not checked: Documentation=man: pages (--man=no). verify looks a man page up
# on the checking machine, exactly as it does a binary, and a man page has no
# extracted-tree equivalent: the one referenced today, swtpm(8), is swtpm's, not
# ours. So the answer is about the checker, never the host -- the dev box passes
# it, and CI's Fedora container, installed without documentation, failed
# waydroid-swtpm.service on it in CI's third run (2026-10-23) with nothing wrong.
#
# Not checked: `systemd-analyze security`. Every daemon here is a root service
# that mounts, labels or reaches into the container's namespaces, so the score
# is 9.x UNSAFE for all of them by design and would be noise (docs/53).
#
# Usage:
#   packaging/verify-units.sh          # newest build of each package in
#                                      # $TOP/RPMS (default build/rpm)
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
TOP=${TOP:-$repo/build/rpm}

for tool in systemd-analyze rpm rpm2cpio cpio; do
	command -v "$tool" >/dev/null 2>&1 || { echo "$tool not found" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root=$work/root
stubs=$work/stubs
mkdir -p "$root" "$stubs"

# Newest build of each package only: build/rpm/RPMS keeps every version ever
# built, and an old unit that no longer ships is not worth failing on.
find "$TOP/RPMS" -name '*.rpm' ! -name '*.src.rpm' | while read -r f; do
	printf '%s\t%s\n' "$(rpm -qp --qf '%{NAME}\t%{VERSION}-%{RELEASE}' "$f" 2>/dev/null)" "$f"
done | sort -t "$(printf '\t')" -k1,1 -k2,2V | awk -F '\t' '
	$1 != prev && prev != "" { print last }
	{ prev = $1; last = $3 }
	END { if (prev != "") print last }' >"$work/rpms"
[ -s "$work/rpms" ] || { echo "no RPMs under $TOP/RPMS -- build them first" >&2; exit 1; }
while read -r f; do
	(cd "$root" && rpm2cpio "$f" | cpio -idm --quiet 2>/dev/null)
done <"$work/rpms"

cat >"$stubs/dev-binderfs.mount" <<'EOF'
# Stub: shipped by the waydroid package.
[Mount]
What=binder
Where=/dev/binderfs
Type=binder
EOF
cat >"$stubs/waydroid-container.service" <<'EOF'
# Stub: shipped by the waydroid package. Present so drop-ins under
# waydroid-container.service.d/ are parsed.
[Service]
ExecStart=/bin/true
EOF

unitdir=$root/usr/lib/systemd/system
units=$(find "$unitdir" -maxdepth 1 -type f \( -name '*.service' -o -name '*.timer' \
	-o -name '*.socket' -o -name '*.path' -o -name '*.mount' -o -name '*.target' \) | sort)
# Every drop-in directory whose unit we only stubbed.
for d in "$unitdir"/*.d; do
	[ -d "$d" ] || continue
	u=$(basename "$d" .d)
	[ -f "$unitdir/$u" ] || units="$units
$stubs/$u"
done

pass=0
fail=0
for u in $units; do
	name=$(basename "$u")
	out=$(SYSTEMD_UNIT_PATH="$unitdir:$stubs:" systemd-analyze verify --man=no "$u" 2>&1) || true
	# verify loads every unit on the search path and complains about any of
	# them, so keep only the lines naming THIS unit or its drop-ins -- every
	# unit gets its own turn, so nothing is lost, and nothing verify says about
	# the checking machine's own units is ours to fix. Then drop "not
	# executable" for a binary the packages do provide.
	problems=$(printf '%s\n' "$out" | grep -F -e "/$name:" -e "/$name.d/" -e "$name: " \
		-e "Unit $name " | while IFS= read -r line; do
		case $line in
		*"Command "*" is not executable"*)
			cmd=${line#*Command }
			cmd=${cmd%% is not executable*}
			[ -x "$root$cmd" ] && continue
			;;
		esac
		printf '%s\n' "$line"
	done)
	if [ -n "$problems" ]; then
		printf '%s\n' "$problems" | sed "s#$root##g; s#$stubs/##g; s#^#  #"
		echo "FAIL $name"
		fail=$((fail + 1))
	else
		echo "ok   $name"
		pass=$((pass + 1))
	fi
done
echo "$pass passed, $fail failed, from $(wc -l <"$work/rpms") packages"
[ "$fail" -eq 0 ]
