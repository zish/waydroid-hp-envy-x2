#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fetch what the Kotlin unit tests need and the dev box may not have, into
# build/test-deps/ (gitignored). Pinned by version and verified by SHA-256 --
# the policy is that no third-party binary is committed (docs/54), so it is
# fetched at test time and checked against a digest recorded here instead.
#
#   org.json 20240303   A real JSON implementation for the JVM. android.jar's
#                       org.json is stubs that throw, and bt-app and pw-app
#                       speak JSON to their daemons. Android's own org.json is
#                       a different implementation of the same API; the tests
#                       stick to behaviour both share.
#   kotlinc 2.0.21      The same compiler every app's build.sh uses. Only
#                       fetched when build/android/kotlinc is absent, which on
#                       the dev box it is not.
#
# Both digests were checked against upstream's own on 2026-10-17: Maven
# Central's .sha1 for the jar, and JetBrains' published .sha256 for the zip.
#
# android.jar is not fetched here: it comes from an Android SDK, either the
# dev box's build/android/sdk or $ANDROID_HOME on a CI runner, where the
# workflow installs platforms;android-33 with sdkmanager.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
deps=${TEST_DEPS:-$repo/build/test-deps}
mkdir -p "$deps"

JSON_URL=https://repo1.maven.org/maven2/org/json/json/20240303/json-20240303.jar
JSON_SHA256=3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed
KOTLIN_URL=https://github.com/JetBrains/kotlin/releases/download/v2.0.21/kotlin-compiler-2.0.21.zip
KOTLIN_SHA256=0352c0a45bd22f80f6b26e485cd04da8047baa5de54865281fb9f89a4a7bcf2a

fetch() { # url sha256 dest
	if [ -f "$3" ] && echo "$2  $3" | sha256sum -c --status; then
		return 0
	fi
	echo "fetching $1"
	curl -sSfL -o "$3.part" "$1"
	if ! echo "$2  $3.part" | sha256sum -c --status; then
		rm -f "$3.part"
		echo "checksum mismatch for $1 -- refusing to use it" >&2
		exit 1
	fi
	mv "$3.part" "$3"
}

fetch "$JSON_URL" "$JSON_SHA256" "$deps/json.jar"

if [ ! -x "$repo/build/android/kotlinc/bin/kotlinc" ] && [ ! -x "$deps/kotlinc/bin/kotlinc" ]; then
	fetch "$KOTLIN_URL" "$KOTLIN_SHA256" "$deps/kotlin-compiler.zip"
	(cd "$deps" && unzip -q -o kotlin-compiler.zip)
fi
echo "test deps ready in $deps"
