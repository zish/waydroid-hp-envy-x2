#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run every test that needs no host, no container and no privilege.
#
# WHAT THIS IS, AND WHAT IT IS NOT
#
# The bin/*-test.sh scripts are integration tests: they ssh to bigtab01 and
# drive a live Android. They are the only way to know a feature works, and they
# cannot run anywhere else. This is the other half -- the decisions inside the
# daemons (which disk mediad will mount, which service restartd will signal,
# what dBm Android is told) checked in isolation, in about a second, on the dev
# box, in lefthook's pre-push and in GitHub Actions alike. It is one entry point
# so those three can never be running different sets.
#
# Suites:
#   python   tests/test_*.py, stdlib unittest, loads the daemons in artifacts/
#   cpp      tests/cpp/*.cpp, each one g++ line against glib only
#   selftest artifacts/*/selftest.sh, the RPMs' %check scripts
#   lint     shellcheck -S error over every shell script, ruff's pyflakes rules
#            (F) over every Python one. Both were clean when this was added
#            (2026-10-17: 0 errors in 92 shell scripts, 1 F541 in 28 Python
#            files, fixed), so the gate costs nothing today. Shellcheck's 33
#            warnings are NOT gated yet -- raise -S once they are worked off.
#
# A suite whose toolchain is missing is SKIPPED with a message -- except under
# CI=true (set by GitHub Actions) or REQUIRE_ALL=1, where a skip is a failure.
# Locally a missing g++ should not block a push; on the runner it would mean
# the workflow silently stopped testing C++.
#
# Usage:
#   tests/run.sh                 # all suites
#   tests/run.sh python cpp      # named suites only
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
strict=0
case "${CI:-}" in true) strict=1 ;; esac
[ "${REQUIRE_ALL:-0}" = 1 ] && strict=1

failed=""
skipped=""

skip() {
	echo "SKIP $1: $2"
	skipped="$skipped $1"
}

run_python() {
	command -v python3 >/dev/null 2>&1 || { skip python "python3 not found"; return 0; }
	# -B: no __pycache__ in the tree. Started from tests/ so `import _scripts`
	# resolves without a package or a sys.path edit in every file.
	(cd "$here" && python3 -B -W error::ResourceWarning -m unittest discover \
		-s "$here" -p 'test_*.py' -t "$here") || failed="$failed python"
}

run_cpp() {
	cxx=${CXX:-g++}
	command -v "$cxx" >/dev/null 2>&1 || { skip cpp "$cxx not found"; return 0; }
	pkg-config --exists glib-2.0 2>/dev/null || { skip cpp "glib-2.0 development files not found"; return 0; }
	out=$(mktemp -d)
	for src in "$here"/cpp/test_*.cpp; do
		bin=$out/$(basename "$src" .cpp)
		# A test names the translation units it links in its header comment,
		# " * sources: wifi/BeaconIes.cpp", repo-relative. Header-only code
		# under test needs no line.
		# " * includes: tests/cpp/shim sensors" adds -I directories the
		# same way, searched before the default wifi/.
		extra=$(sed -n 's#^ *\*\{0,1\} *sources: *##p' "$src" |
			tr ' ' '\n' | sed "/^$/d; s#^#$repo/#")
		incs=$(sed -n 's#^ *\*\{0,1\} *includes: *##p' "$src" |
			tr ' ' '\n' | sed "/^$/d; s#^#-I$repo/#")
		# Same warning set as the daemons' own builds, plus -Werror.
		# shellcheck disable=SC2046,SC2086  # pkg-config output, $incs and $extra are word lists
		if "$cxx" -std=gnu++17 -Wall -Wextra -Wno-unused-parameter -Werror \
			$incs -I"$repo/wifi" \
			$(pkg-config --cflags glib-2.0) "$src" $extra \
			$(pkg-config --libs glib-2.0) -o "$bin" && "$bin"; then
			:
		else
			failed="$failed cpp:$(basename "$src")"
		fi
	done
	rm -rf "$out"
}

run_selftest() {
	for t in "$repo"/artifacts/*/selftest.sh; do
		name=$(basename "$(dirname "$t")")
		if sh "$t" >"${TMPDIR:-/tmp}/selftest-$name.$$" 2>&1; then
			echo "ok   selftest $name"
		else
			cat "${TMPDIR:-/tmp}/selftest-$name.$$"
			echo "FAIL selftest $name"
			failed="$failed selftest:$name"
		fi
		rm -f "${TMPDIR:-/tmp}/selftest-$name.$$"
	done
}

# Every tracked script by shebang, not by extension: the daemons in artifacts/
# are installed as bare names. Markdown is excluded because docs quote shebangs.
tracked_by_shebang() {
	git -C "$repo" ls-files -z | xargs -0 grep -lIE "$1" -- 2>/dev/null |
		grep -v '\.md$' || true
}

run_lint() {
	cd "$repo"
	if command -v shellcheck >/dev/null 2>&1; then
		files=$( { tracked_by_shebang '^#!(/usr)?/bin/(env )?(ba)?sh'
			git ls-files '*.sh'; } | sort -u)
		# shellcheck disable=SC2086  # one path per word; no tracked path has a space
		shellcheck -S error $files && echo "ok   shellcheck ($(echo "$files" | wc -l) files)" ||
			failed="$failed shellcheck"
	else
		skip shellcheck "shellcheck not found"
	fi
	if command -v ruff >/dev/null 2>&1; then
		files=$( { tracked_by_shebang '^#!.*python3'
			git ls-files '*.py'; ls tests/*.py; } | sort -u)
		# shellcheck disable=SC2086
		ruff check --quiet --no-cache --select F $files && echo "ok   ruff ($(echo "$files" | wc -l) files)" ||
			failed="$failed ruff"
	else
		skip ruff "ruff not found"
	fi
	cd - >/dev/null
}

suites=${*:-python cpp selftest lint}
for s in $suites; do
	echo "== $s"
	case $s in
	python)   run_python ;;
	cpp)      run_cpp ;;
	selftest) run_selftest ;;
	lint)     run_lint ;;
	*) echo "unknown suite: $s" >&2; exit 2 ;;
	esac
done

echo
if [ -n "$failed" ]; then
	echo "FAILED:$failed"
	exit 1
fi
if [ -n "$skipped" ] && [ "$strict" = 1 ]; then
	echo "SKIPPED under CI/REQUIRE_ALL, which counts as failure:$skipped"
	exit 1
fi
echo "all passed${skipped:+ (skipped:$skipped)}"
