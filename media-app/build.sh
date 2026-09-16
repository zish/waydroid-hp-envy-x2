#!/usr/bin/env bash
#
# Build (and optionally install) Removable Media -- the Android half of goal 6.
# See docs/46-removable-media.md; the host half is artifacts/media/waydroid-mediad.
#
# WHY NO GRADLE
#
# Same trade as sensor-app/build.sh: the app depends on nothing but the
# platform -- no AndroidX, no Compose -- so there is no dependency resolution to
# do and the build is a handful of tool invocations instead of a Gradle daemon
# and a Maven cache.
#
#   aapt2 compile/link  res/ + AndroidManifest -> APK with resources, and R.java
#   javac               R.java                 -> R.class
#   kotlinc             src/                   -> JVM .class files
#   d8                  .class + kotlin-stdlib -> classes.dex
#   zipalign, apksigner                        -> an installable, signed APK
#
# UNLIKE sensor-app this one DOES generate R: the notification needs
# R.drawable.ic_media and R.string at runtime, so aapt2 is run with --java and
# the result is compiled with javac before kotlinc sees it on the classpath.
# The alternative -- resources.getIdentifier() -- avoids two build steps by
# moving a compile-time error to a silent runtime null, which is a bad trade for
# an icon that would then just not appear.
#
# Usage:
#   media-app/build.sh              # build the APK
#   media-app/build.sh --deps       # fetch the SDK and Kotlin compiler first
#   media-app/build.sh --install    # build, install into Waydroid, grant, launch
#
# Env: HOST=<ip>  OUT=<dir>
set -euo pipefail

HOST="${HOST:-10.42.0.137}"

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
TOOLS="${TOOLS:-$repo/build/android}"
OUT="${OUT:-$repo/build/media-app}"

SDK="$TOOLS/sdk"
BT="$SDK/build-tools/34.0.0"
PLATFORM="$SDK/platforms/android-33/android.jar"
KOTLINC="$TOOLS/kotlinc/bin/kotlinc"
PKG=lan.syshlt.removablemedia

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
mkdir -p "$OUT/classes" "$OUT/gen"

echo "== aapt2 compile"
"$BT/aapt2" compile --dir "$here/res" -o "$OUT/res.zip"

echo "== aapt2 link"
"$BT/aapt2" link \
	-o "$OUT/base.apk" \
	-I "$PLATFORM" \
	--manifest "$here/AndroidManifest.xml" \
	--java "$OUT/gen" \
	--min-sdk-version 29 \
	--target-sdk-version 33 \
	"$OUT/res.zip"

echo "== javac (R)"
javac -nowarn -source 17 -target 17 -classpath "$PLATFORM" \
	-d "$OUT/classes" $(find "$OUT/gen" -name 'R.java')

echo "== kotlinc"
"$KOTLINC" \
	-classpath "$PLATFORM:$OUT/classes" \
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
	--key-pass pass:android --out "$OUT/removable-media.apk" "$OUT/aligned.apk"

echo
echo "built: $OUT/removable-media.apk"

if [ "$DO_INSTALL" = 1 ]; then
	echo
	echo "== installing on $HOST"
	scp -q "$OUT/removable-media.apk" "$HOST:/tmp/removable-media.apk"
	# /data inside the container IS ~<user>/.local/share/waydroid/data on the
	# host, so the APK can simply be copied into place; /data/local/tmp is owned
	# 2000:2000 and needs root to write (docs/14).
	ssh "$HOST" "sudo cp /tmp/removable-media.apk \
		~jmelanso/.local/share/waydroid/data/local/tmp/removable-media.apk && \
		sudo chown 2000:2000 ~jmelanso/.local/share/waydroid/data/local/tmp/removable-media.apk"

	# `pm install` takes MINUTES on this Core M, and an interrupted one leaves
	# the package FROZEN -- "is currently frozen!" / "not installed for user 0"
	# in logcat, a receiver that never fires, and `pm list packages` showing
	# nothing. It cost a debugging round once. Never wrap this in `|| true`:
	# a half-install has to be loud, and the recovery is `pm uninstall` first.
	echo "== pm install (slow: minutes, do not interrupt)"
	result=$(ssh "$HOST" \
		"sudo waydroid shell -- pm install -r -g /data/local/tmp/removable-media.apk" \
		2>&1 | grep -v 'Permission denied: 1' || true)
	echo "$result"
	case "$result" in
	*Success*) ;;
	*) echo "install FAILED -- recover with: sudo waydroid shell -- pm uninstall $PKG" >&2
	   exit 1 ;;
	esac

	# Android 13 gates notifications behind a runtime grant and a kiosk has
	# nobody to tap Allow. -g above covers install-time grants; do it explicitly
	# too, because POST_NOTIFICATIONS is not always included by -g.
	ssh "$HOST" "sudo waydroid shell -- pm grant $PKG android.permission.POST_NOTIFICATIONS" \
		2>&1 | grep -v 'Permission denied: 1' || true
	echo "== installed and granted"
fi
