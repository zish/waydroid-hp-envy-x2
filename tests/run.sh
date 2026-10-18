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
#   sanitize the same tests again under AddressSanitizer and UBSan. The code
#            they cover builds and decodes 802.11 elements byte by byte and
#            parses sysfs text, which is where an off-by-one reads past a
#            buffer and still passes. About five seconds, mostly compiling.
#   selftest artifacts/*/selftest.sh, the RPMs' %check scripts
#   kotlin   <app>/test/Tests.kt for every Kotlin app that has one, compiled
#            with the app's whole src/ against android.jar and run on the JVM;
#            see tests/kotlin/Harness.kt. Needs a JDK 17/21, kotlinc, an
#            android-33 android.jar and the jars tests/kotlin/fetch-deps.sh
#            puts in build/test-deps. KOTLIN_APPS="a b" limits it to those.
#   lint     shellcheck -S warning over every shell script, ruff's pyflakes
#            and bugbear rules (F, B) over every Python one, actionlint and
#            zizmor over .github/, and gitleaks over the whole history. All
#            clean as of 2026-10-17. Shellcheck was gated at -S error first and
#            raised once its 31 warnings were worked off, which found one real
#            bug in two test scripts. ruff's E (style) is not gated.
#   policy   tests/policy.py, the repository rules no compiler checks: every
#            tracked binary is in tests/binary-allowlist with its sha256, and
#            every relative Markdown link and #anchor resolves, and every
#            tracked XML file parses.
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

# run_cpp <suite name> [extra compiler flags...]
run_cpp() {
	suite=$1
	shift
	cxx=${CXX:-g++}
	command -v "$cxx" >/dev/null 2>&1 || { skip "$suite" "$cxx not found"; return 0; }
	pkg-config --exists glib-2.0 2>/dev/null || { skip "$suite" "glib-2.0 development files not found"; return 0; }
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
		if "$cxx" -std=gnu++17 -Wall -Wextra -Wno-unused-parameter -Werror "$@" \
			$incs -I"$repo/wifi" \
			$(pkg-config --cflags glib-2.0) "$src" $extra \
			$(pkg-config --libs glib-2.0) -o "$bin" && "$bin"; then
			:
		else
			failed="$failed $suite:$(basename "$src")"
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

find_jdk() {
	# kotlinc 2.0.21 predates JDK 25, which is this box's default java, so
	# prefer an explicit JAVA_HOME and then the same LTS releases the apps'
	# build.sh scripts look for.
	for candidate in ${JAVA_HOME:-} /usr/lib/jvm/java-21-openjdk-amd64 \
		/usr/lib/jvm/java-17-openjdk-amd64 /usr/lib/jvm/java-21-openjdk \
		/usr/lib/jvm/java-17-openjdk; do
		[ -x "$candidate/bin/java" ] && { echo "$candidate"; return 0; }
	done
	return 1
}

run_kotlin() {
	apps=$(cd "$repo" && ls -d ./*/test/Tests.kt 2>/dev/null | cut -d/ -f2 || true)
	# KOTLIN_APPS="pw-app media-app" narrows the run, and the COMPILE, to the
	# named apps -- so one app's half-written test cannot break another's.
	if [ -n "${KOTLIN_APPS:-}" ]; then
		apps=$(for a in $apps; do case " $KOTLIN_APPS " in *" $a "*) echo "$a" ;; esac; done)
	fi
	[ -n "$apps" ] || { skip kotlin "no <app>/test/Tests.kt found"; return 0; }

	jdk=$(find_jdk) || { skip kotlin "no JDK 17 or 21 (set JAVA_HOME)"; return 0; }
	kotlinc=""
	for k in "$repo/build/android/kotlinc" "$repo/build/test-deps/kotlinc"; do
		[ -x "$k/bin/kotlinc" ] && { kotlinc=$k; break; }
	done
	android_jar=""
	for a in "${ANDROID_JAR:-}" \
		"$repo/build/android/sdk/platforms/android-33/android.jar" \
		"${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/nonexistent}}/platforms/android-33/android.jar"; do
		[ -n "$a" ] && [ -f "$a" ] && { android_jar=$a; break; }
	done
	json=$repo/build/test-deps/json.jar
	[ -n "$kotlinc" ] || { skip kotlin "kotlinc not found -- run tests/kotlin/fetch-deps.sh"; return 0; }
	[ -n "$android_jar" ] || { skip kotlin "android-33 android.jar not found (set ANDROID_JAR or ANDROID_HOME)"; return 0; }
	[ -f "$json" ] || { skip kotlin "org.json not fetched -- run tests/kotlin/fetch-deps.sh"; return 0; }

	out=$(mktemp -d)
	lib=$kotlinc/lib
	# One kotlinc for every app: its JVM start is most of the cost (~13 s for
	# all eight against ~10 s for one). The packages are all distinct. The
	# real org.json goes ahead of android.jar's stubs on both classpaths.
	srcs=""
	for app in $apps; do srcs="$srcs $repo/$app/src $repo/$app/test"; done
	# shellcheck disable=SC2086  # $srcs is a word list of repo paths
	if ! JAVA_HOME=$jdk "$kotlinc/bin/kotlinc" -nowarn -jvm-target 17 \
		-classpath "$json:$lib/kotlin-test.jar:$android_jar" \
		-d "$out" "$here/kotlin/Harness.kt" $srcs; then
		failed="$failed kotlin:compile"
		rm -rf "$out"
		return 0
	fi
	cp="$out:$lib/kotlin-stdlib.jar:$lib/kotlin-test.jar:$json:$android_jar"
	for app in $apps; do
		pkg=$(sed -n 's/^package  *//p' "$repo/$app/test/Tests.kt" | head -1)
		"$jdk/bin/java" -cp "$cp" "$pkg.TestsKt" || failed="$failed kotlin:$app"
	done
	rm -rf "$out"
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
		shellcheck -S warning $files && echo "ok   shellcheck ($(echo "$files" | wc -l) files)" ||
			failed="$failed shellcheck"
	else
		skip shellcheck "shellcheck not found"
	fi
	if command -v ruff >/dev/null 2>&1; then
		files=$( { tracked_by_shebang '^#!.*python3'
			git ls-files '*.py'; ls tests/*.py; } | sort -u)
		# shellcheck disable=SC2086
		# F (pyflakes) and B (bugbear), less two bugbear rules that are
		# deliberate here: B904, because every hit wraps an error in a
		# clearer message on purpose and the chained traceback adds nothing
		# for an operator; B905, because zip(a, a[1:]) is MEANT to be uneven.
		ruff check --quiet --no-cache --select F,B --ignore B904,B905 $files &&
			echo "ok   ruff ($(echo "$files" | wc -l) files)" ||
			failed="$failed ruff"
	else
		skip ruff "ruff not found"
	fi
	# The workflow is code that runs with a token, so it is linted too:
	# actionlint for what GitHub would reject or misread, zizmor for what it
	# would accept and should not -- an unpinned `uses:`, a template expanded
	# into a shell, a checkout that leaves the token on disk. --offline: no
	# network, so the same answer on the dev box and the runner.
	if command -v actionlint >/dev/null 2>&1; then
		actionlint && echo "ok   actionlint" || failed="$failed actionlint"
	else
		skip actionlint "actionlint not found"
	fi
	if command -v zizmor >/dev/null 2>&1; then
		zizmor --offline --quiet .github/ && echo "ok   zizmor" || failed="$failed zizmor"
	else
		skip zizmor "zizmor not found"
	fi
	# Every commit on every branch, every time: 340 commits take about two
	# seconds, and the push that matters most is the first public one, when
	# all of history goes out at once. Findings print redacted. Public test
	# certificates (bt-app, pw-app) are not secrets and do not trip it.
	if command -v gitleaks >/dev/null 2>&1; then
		gitleaks git --no-banner --redact --log-level warn . &&
			echo "ok   gitleaks ($(git rev-list --all | wc -l) commits)" ||
			failed="$failed gitleaks"
	else
		skip gitleaks "gitleaks not found"
	fi
	cd - >/dev/null
}

run_policy() {
	command -v python3 >/dev/null 2>&1 || { skip policy "python3 not found"; return 0; }
	python3 -B "$here/policy.py" || failed="$failed policy"
}

suites=${*:-python cpp sanitize selftest kotlin lint policy}
for s in $suites; do
	echo "== $s"
	case $s in
	python)   run_python ;;
	cpp)      run_cpp cpp ;;
	# -O1 so ASan's reports name real frames; no-recover so a UBSan finding
	# fails the test rather than printing and carrying on.
	sanitize) run_cpp sanitize -O1 -g -fno-omit-frame-pointer \
			-fsanitize=address,undefined -fno-sanitize-recover=all ;;
	selftest) run_selftest ;;
	kotlin)   run_kotlin ;;
	lint)     run_lint ;;
	policy)   run_policy ;;
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
