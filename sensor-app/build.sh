#!/usr/bin/env bash
#
# Build (and optionally install) Sensor Info -- a minimal live sensor viewer
# for bigtab01, used to check the waydroid-sensord IIO daemon from the Android
# side and to give the magnetometer a subscriber so it is actually streamed.
#
# WHY NO GRADLE
#
# The app deliberately depends on nothing but the platform: no AndroidX, no
# Compose, no Kotlin coroutines. The whole UI is built programmatically. That
# means the build needs no dependency resolution at all, so it is four tool
# invocations rather than a Gradle daemon and a Maven cache -- which matches
# how phase2/build.sh drives the NDK directly.
#
#   aapt2 compile   res/                -> compiled resources
#   aapt2 link      + AndroidManifest   -> an APK with resources but no code
#   kotlinc         src/                -> JVM .class files
#   d8              .class + kotlin-stdlib -> classes.dex
#   zipalign, apksigner                 -> an installable, signed APK
#
# The signing key is a throwaway debug key generated on first run. This app is
# a diagnostic, not something to publish.
#
# TOOLCHAIN
#
# Everything lands under build/android (gitignored, on the big disk):
#   build/android/sdk      Android SDK: platforms/android-33, build-tools/34.0.0
#   build/android/kotlinc  Kotlin 2.0.21 compiler
# Fetch them with --deps. Needs a JDK; Debian's default is 25, which Android's
# tooling does not accept, so we pin JDK 21.
#
# Usage:
#   sensor-app/build.sh              # build the APK
#   sensor-app/build.sh --deps       # fetch the SDK and Kotlin compiler first
#   sensor-app/build.sh --install    # build, install into Waydroid and launch
#
# Env: HOST=<ip>  OUT=<dir>
set -euo pipefail

HOST="${HOST:-10.42.0.137}"

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
TOOLS="${TOOLS:-$repo/build/android}"
OUT="${OUT:-$repo/build/sensor-app}"

SDK="$TOOLS/sdk"
BT="$SDK/build-tools/34.0.0"
PLATFORM="$SDK/platforms/android-33/android.jar"
KOTLINC="$TOOLS/kotlinc/bin/kotlinc"
PKG=lan.syshlt.sensorinfo

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

# ---------------------------------------------------------------- dependencies

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
mkdir -p "$OUT/res" "$OUT/classes"

# ------------------------------------------------------------------ resources

echo "== aapt2 compile"
"$BT/aapt2" compile --dir "$here/res" -o "$OUT/res.zip"

echo "== aapt2 link"
# No --java: the app references resources only from the manifest, so there is
# no R class to generate and kotlinc never has to see generated Java.
"$BT/aapt2" link \
	-o "$OUT/base.apk" \
	-I "$PLATFORM" \
	--manifest "$here/AndroidManifest.xml" \
	--min-sdk-version 29 \
	--target-sdk-version 33 \
	"$OUT/res.zip"

# ----------------------------------------------------------------------- code

echo "== kotlinc"
"$KOTLINC" \
	-classpath "$PLATFORM" \
	-jvm-target 17 \
	-nowarn \
	-d "$OUT/classes" \
	"$here/src"

echo "== d8"
# kotlin-stdlib has to be dexed in: the app uses Kotlin's stdlib types, and
# there is no Gradle here to add it as a dependency.
find "$OUT/classes" -name '*.class' > "$OUT/classlist"
"$BT/d8" \
	--min-api 29 \
	--lib "$PLATFORM" \
	--output "$OUT" \
	--classpath "$OUT/classes" \
	@"$OUT/classlist" \
	"$TOOLS/kotlinc/lib/kotlin-stdlib.jar"

# ------------------------------------------------------------------- assemble

echo "== packaging"
(cd "$OUT" && zip -q "$OUT/base.apk" classes.dex)

"$BT/zipalign" -f -p 4 "$OUT/base.apk" "$OUT/aligned.apk"

KEYSTORE="$TOOLS/debug.keystore"
if [ ! -f "$KEYSTORE" ]; then
	echo "== generating a throwaway debug key"
	keytool -genkeypair -keystore "$KEYSTORE" -alias debug \
		-storepass android -keypass android \
		-keyalg RSA -keysize 2048 -validity 10000 \
		-dname "CN=bigtab01 sensor-info debug, OU=none, O=none, C=CA" >/dev/null 2>&1
fi

"$BT/apksigner" sign \
	--ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android \
	--out "$OUT/sensor-info.apk" "$OUT/aligned.apk"

rm -f "$OUT/aligned.apk" "$OUT/base.apk" "$OUT/classlist" "$OUT/res.zip"

echo
echo "== built $OUT/sensor-info.apk"
ls -l "$OUT/sensor-info.apk"
"$BT/apksigner" verify --print-certs "$OUT/sensor-info.apk" | head -3

# -------------------------------------------------------------------- install

if [ "$DO_INSTALL" = 1 ]; then
	echo
	echo "== installing into Waydroid on $HOST"
	# Two traps here, both hit the first time round:
	#
	#  1. `waydroid app install` fails SILENTLY -- no output, no non-zero exit,
	#     no package. Use pm install inside the container, which reports errors.
	#  2. The container cannot see the host's /tmp. Its /data/local/tmp is the
	#     host's ~/.local/share/waydroid/data/local/tmp, owned by 2000:2000, so
	#     the copy needs sudo and a chown or pm cannot open the file.
	#
	# Play Protect (Finsky VerifyApps) rejects a self-signed APK with
	# "verdict 9", so the package verifier is turned off for the install and
	# restored afterwards.
	#
	#  3. `waydroid shell` always exits non-zero with a cosmetic
	#     "ERROR: [Errno 13] Permission denied: 1", so the remote script must
	#     NOT use `set -e` -- it aborted the cleanup the first time.
	DATA=/home/jmelanso/.local/share/waydroid/data/local/tmp
	scp -q "$OUT/sensor-info.apk" "$HOST:/tmp/sensor-info.apk"
	ssh "$HOST" "
		sudo waydroid shell -- sh -c 'settings put global package_verifier_enable 0' >/dev/null 2>&1
		sudo cp /tmp/sensor-info.apk $DATA/sensor-info.apk || exit 1
		sudo chown 2000:2000 $DATA/sensor-info.apk
		sudo chmod 644 $DATA/sensor-info.apk
		sudo waydroid shell -- sh -c 'pm install -r -g /data/local/tmp/sensor-info.apk' 2>/dev/null
		sudo waydroid shell -- sh -c 'settings delete global package_verifier_enable' >/dev/null 2>&1
		sudo rm -f $DATA/sensor-info.apk
		rm -f /tmp/sensor-info.apk
		exit 0
	"
	echo
	echo "== launching"
	ssh "$HOST" "sudo waydroid shell -- sh -c 'am start -n $PKG/.MainActivity' 2>/dev/null" | head -2
fi
