#!/usr/bin/env bash
#
# Build (and optionally install) Bluetooth -- the Android half of the BlueZ
# work. See docs/50-bluetooth.md; the host half is artifacts/bluetooth/.
#
# WHY NO GRADLE
#
# Same trade as sensor-app/build.sh and media-app/build.sh: the app depends on
# nothing but the platform -- no AndroidX, no Compose, no coroutines -- so there
# is no dependency resolution to do and the build is a handful of tool
# invocations instead of a Gradle daemon and a Maven cache.
#
#   aapt2 compile/link  res/ + AndroidManifest -> APK with resources
#   kotlinc             src/                   -> JVM .class files
#   d8                  .class + kotlin-stdlib -> classes.dex
#   zipalign, apksigner                        -> an installable, signed APK
#
# UNLIKE media-app this one does NOT generate R. The only resources are the
# launcher icon and the app label, both referenced from the manifest and neither
# from code, so aapt2 needs no --java and there is no javac step. Add one back
# the moment anything here wants a resource id at runtime -- getIdentifier()
# would trade a compile error for a silent runtime null.
#
# Usage:
#   bt-app/build.sh              # build the APK
#   bt-app/build.sh --deps       # fetch the SDK and Kotlin compiler first
#   bt-app/build.sh --install    # build, install into Waydroid, launch
#
# Env: HOST=<ip>  OUT=<dir>
set -euo pipefail

HOST="${HOST:-10.42.0.137}"

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
TOOLS="${TOOLS:-$repo/build/android}"
OUT="${OUT:-$repo/build/bt-app}"

SDK="$TOOLS/sdk"
BT="$SDK/build-tools/34.0.0"
PLATFORM="$SDK/platforms/android-33/android.jar"
KOTLINC="$TOOLS/kotlinc/bin/kotlinc"
PKG=lan.syshlt.bluetooth
APK=bluetooth.apk

CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
KOTLIN_URL="https://github.com/JetBrains/kotlin/releases/download/v2.0.21/kotlin-compiler-2.0.21.zip"

# Android's build-tools reject very new JDKs; Debian trixie's default is 25.
for candidate in /usr/lib/jvm/java-21-openjdk-amd64 /usr/lib/jvm/java-17-openjdk-amd64; do
	[ -x "$candidate/bin/java" ] && export JAVA_HOME="$candidate" && break
done
: "${JAVA_HOME:?no JDK 17 or 21 found -- apt install openjdk-21-jdk-headless}"
export PATH="$JAVA_HOME/bin:$PATH"

DO_DEPS=0
DO_INSTALL=0
while [ $# -gt 0 ]; do
	case "$1" in
	--deps) DO_DEPS=1; shift ;;
	--install) DO_INSTALL=1; shift ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

if [ "$DO_DEPS" = 1 ]; then
	mkdir -p "$TOOLS"
	echo "== fetching Android cmdline-tools and the Kotlin compiler"
	curl -sSL -o "$TOOLS/cmdline-tools.zip" "$CMDLINE_TOOLS_URL"
	curl -sSL -o "$TOOLS/kotlin-compiler.zip" "$KOTLIN_URL"
	(cd "$TOOLS" && unzip -q -o cmdline-tools.zip && unzip -q -o kotlin-compiler.zip)
	echo "== installing SDK platform 33 and build-tools 34.0.0"
	yes 2>/dev/null | "$TOOLS/cmdline-tools/bin/sdkmanager" --sdk_root="$SDK" \
		"platforms;android-33" "build-tools;34.0.0" >/dev/null
fi

for f in "$BT/aapt2" "$BT/d8" "$BT/zipalign" "$BT/apksigner" "$PLATFORM" "$KOTLINC"; do
	[ -e "$f" ] || { echo "missing $f -- run with --deps" >&2; exit 1; }
done

rm -rf "$OUT"
mkdir -p "$OUT/classes"

echo "== aapt2 compile"
"$BT/aapt2" compile --dir "$here/res" -o "$OUT/res.zip"

echo "== aapt2 link"
"$BT/aapt2" link \
	-o "$OUT/base.apk" \
	-I "$PLATFORM" \
	--manifest "$here/AndroidManifest.xml" \
	--min-sdk-version 29 \
	--target-sdk-version 33 \
	"$OUT/res.zip"

echo "== kotlinc"
"$KOTLINC" \
	-classpath "$PLATFORM" \
	-jvm-target 17 \
	-nowarn \
	-d "$OUT/classes" \
	"$here/src"

echo "== d8"
find "$OUT/classes" -name '*.class' > "$OUT/classlist"
"$BT/d8" \
	--min-api 29 \
	--lib "$PLATFORM" \
	--output "$OUT" \
	--classpath "$OUT/classes" \
	@"$OUT/classlist" \
	"$TOOLS/kotlinc/lib/kotlin-stdlib.jar"

echo "== packaging"
(cd "$OUT" && zip -q "$OUT/base.apk" classes.dex)
"$BT/zipalign" -f -p 4 "$OUT/base.apk" "$OUT/aligned.apk"

KEYSTORE="$TOOLS/debug.keystore"
if [ ! -f "$KEYSTORE" ]; then
	echo "== generating a throwaway debug key"
	keytool -genkeypair -keystore "$KEYSTORE" -storepass android -keypass android \
		-alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
		-dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1
fi

"$BT/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:android \
	--key-pass pass:android --out "$OUT/$APK" "$OUT/aligned.apk"

echo
echo "built: $OUT/$APK"

if [ "$DO_INSTALL" = 1 ]; then
	echo
	echo "== installing on $HOST"
	scp -q "$OUT/$APK" "$HOST:/tmp/$APK"
	# /data inside the container IS ~<user>/.local/share/waydroid/data on the
	# host, so the APK can simply be copied into place; /data/local/tmp is owned
	# 2000:2000 and needs root to write (docs/14).
	ssh "$HOST" "sudo cp /tmp/$APK \
		~jmelanso/.local/share/waydroid/data/local/tmp/$APK && \
		sudo chown 2000:2000 ~jmelanso/.local/share/waydroid/data/local/tmp/$APK"

	# `pm install` takes MINUTES on this Core M, and an interrupted one leaves
	# the package FROZEN -- "is currently frozen!" in logcat, an app that will
	# not launch, and `pm list packages` showing nothing. Never wrap this in
	# `|| true`: a half-install has to be loud, and recovery is `pm uninstall`.
	echo "== pm install (slow: minutes, do not interrupt)"
	result=$(ssh "$HOST" \
		"sudo waydroid shell -- pm install -r -g /data/local/tmp/$APK" \
		2>&1 | grep -v 'Permission denied: 1' || true)
	echo "$result"
	case "$result" in
	*Success*) ;;
	*) echo "install FAILED -- recover with: sudo waydroid shell -- pm uninstall $PKG" >&2
	   exit 1 ;;
	esac

	# The daemon polls for the package directory every 30 s and drops the
	# connection profile in as soon as it exists, so a fresh install is
	# connectable within half a minute without restarting anything.
	echo "== waiting for waydroid-btd to publish the connection profile"
	for _ in $(seq 1 12); do
		if ssh "$HOST" "sudo test -f ~jmelanso/.local/share/waydroid/data/data/$PKG/files/btd.json"; then
			echo "   profile published"
			break
		fi
		sleep 5
	done

	ssh "$HOST" "sudo waydroid shell -- am start -n $PKG/.MainActivity" \
		2>&1 | grep -v 'Permission denied: 1' || true
	echo "== installed and launched"
fi
