#!/usr/bin/env bash
#
# Build (and optionally install) Audio Probe -- settles whether an ordinary app
# is actually GRANTED a fast track on this device, and with what buffer.
# Written for goal 5 (docs/44), after the audio HAL was patched to report one
# card period instead of the whole card buffer, which created a FastMixer where
# there had been none.
#
# `dumpsys media.audio_flinger` can show that a FastMixer EXISTS. It cannot show
# that an app gets to use it -- a media player yields `Fast tracks:
# activeMask=0x1`, slot 0 being the normal-mixer submix, because media players
# deliberately ask for deep buffers. This probe asks for the opposite.
#
# It plays QUIETLY: 1 kHz at a quarter of full scale, track volume 0.2, 1.5 s per
# arm, three arms. Audibility is not the measurement.
#
# Same no-Gradle approach and the same toolchain under build/android as
# sensor-app/build.sh, drm-probe/build.sh and quat-monitor/build.sh, so --deps in
# any of them covers all four:
#
#   aapt2 compile/link -> kotlinc -> d8 -> zipalign -> apksigner
#
# NO PERMISSIONS ARE NEEDED -- PCM output requires none. The probe runs with
# exactly the privileges an ordinary audio app has, or its answers would not be
# about ordinary audio apps.
#
# Usage:
#   audio-probe/build.sh                # build the APK
#   audio-probe/build.sh --deps         # fetch SDK + Kotlin compiler first
#   audio-probe/build.sh --install      # build, install, launch, print the report
#   audio-probe/build.sh --pull         # copy the report off the device
#
# Env: HOST=<ip>  OUT=<dir>
set -euo pipefail

HOST="${HOST:-10.42.0.137}"

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
TOOLS="${TOOLS:-$repo/build/android}"
OUT="${OUT:-$repo/build/audio-probe}"

SDK="$TOOLS/sdk"
BT="$SDK/build-tools/34.0.0"
PLATFORM="$SDK/platforms/android-33/android.jar"
KOTLINC="$TOOLS/kotlinc/bin/kotlinc"
PKG=com.systemhalted.audioprobe
APK=audio-probe.apk

# Waydroid's data root for the session user. NOT /var/lib/waydroid/data, which
# does not exist on this host -- that mistake cost time once already.
WDATA=/home/jmelanso/.local/share/waydroid/data
REPORTDIR="$WDATA/media/0/Android/data/$PKG/files/reports"

CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
KOTLIN_URL="https://github.com/JetBrains/kotlin/releases/download/v2.0.21/kotlin-compiler-2.0.21.zip"

for candidate in /usr/lib/jvm/java-21-openjdk-amd64 /usr/lib/jvm/java-17-openjdk-amd64; do
	[ -x "$candidate/bin/java" ] && export JAVA_HOME="$candidate" && break
done
: "${JAVA_HOME:?no JDK 17 or 21 found -- apt install openjdk-21-jdk-headless}"
export PATH="$JAVA_HOME/bin:$PATH"

DO_DEPS=0; DO_INSTALL=0; DO_PULL=0
while [ $# -gt 0 ]; do
	case "$1" in
	--deps) DO_DEPS=1; shift ;;
	--install) DO_INSTALL=1; shift ;;
	--pull) DO_PULL=1; shift ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

pull_report() {
	local dest="$repo/build/audio-probe-report"
	mkdir -p "$dest"
	ssh "$HOST" "sudo cat '$REPORTDIR/audio-probe.txt' 2>/dev/null" > "$dest/audio-probe.txt"
	if [ -s "$dest/audio-probe.txt" ]; then
		echo "== report at $dest/audio-probe.txt"
	else
		echo "== no report file yet (has the app been launched?)" >&2
	fi
}

if [ "$DO_PULL" = 1 ] && [ "$DO_INSTALL" = 0 ] && [ "$DO_DEPS" = 0 ]; then
	pull_report; exit 0
fi

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
	[ -e "$f" ] || { echo "missing $f -- run this with --deps" >&2; exit 1; }
done

rm -rf "$OUT"
mkdir -p "$OUT/res" "$OUT/classes"

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
	keytool -genkeypair -keystore "$KEYSTORE" -alias debug \
		-storepass android -keypass android \
		-keyalg RSA -keysize 2048 -validity 10000 \
		-dname "CN=bigtab01 audio-probe debug, OU=none, O=none, C=CA" >/dev/null 2>&1
fi

"$BT/apksigner" sign \
	--ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android \
	--out "$OUT/$APK" "$OUT/aligned.apk"

rm -f "$OUT/aligned.apk" "$OUT/base.apk" "$OUT/classlist" "$OUT/res.zip"

echo
echo "== built $OUT/$APK"
ls -l "$OUT/$APK"

if [ "$DO_INSTALL" = 1 ]; then
	echo
	echo "== installing into Waydroid on $HOST"
	# Traps inherited from sensor-app/build.sh, all still live:
	#  1. `waydroid app install` fails SILENTLY; use pm install inside.
	#  2. The container cannot see the host's /tmp; stage through
	#     $WDATA/local/tmp, owned 2000:2000.
	#  3. `waydroid shell` always exits non-zero with a cosmetic
	#     "ERROR: [Errno 13] Permission denied: 1", so no `set -e` remotely.
	#  4. Play Protect rejects a self-signed APK ("verdict 9"), so the package
	#     verifier is disabled for the install and restored after.
	scp -q "$OUT/$APK" "$HOST:/tmp/$APK"
	ssh "$HOST" "
		sudo waydroid shell -- sh -c 'settings put global package_verifier_enable 0' >/dev/null 2>&1
		sudo cp /tmp/$APK $WDATA/local/tmp/$APK || exit 1
		sudo chown 2000:2000 $WDATA/local/tmp/$APK
		sudo chmod 644 $WDATA/local/tmp/$APK
		sudo waydroid shell -- sh -c 'pm install -r -g /data/local/tmp/$APK' 2>/dev/null
		sudo waydroid shell -- sh -c 'settings delete global package_verifier_enable' >/dev/null 2>&1
		sudo rm -f $WDATA/local/tmp/$APK
		rm -f /tmp/$APK
		exit 0
	"
	echo "== launching"
	ssh "$HOST" "sudo waydroid shell -- sh -c 'am start -n $PKG/.MainActivity' 2>/dev/null" | head -2
	sleep 16
	DO_PULL=1
fi

if [ "$DO_PULL" = 1 ]; then
	echo
	pull_report
	[ -s "$repo/build/audio-probe-report/audio-probe.txt" ] && cat "$repo/build/audio-probe-report/audio-probe.txt"
fi
