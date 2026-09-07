#!/usr/bin/env bash
#
# Build (and optionally install) Quat Monitor -- logs the ITE8350's
# hardware-fused quaternion against AOSP's software fusion at 20 Hz, and lets a
# rotation anomaly be reported the moment it is seen.
#
# Same no-Gradle approach as sensor-app/build.sh, and the same toolchain under
# build/android, so --deps there covers this too:
#
#   aapt2 compile/link -> kotlinc -> d8 -> zipalign -> apksigner
#
# WHY THE EXTRA GRANTS ON INSTALL
#
# READ_LOGS and DUMP are both signature|privileged|development. The
# `development` flag is what makes `pm grant` able to hand them to a normal
# app. Without READ_LOGS, an app's logcat call silently returns only its OWN
# log lines, which would make every anomaly capture look like a suspiciously
# quiet system. Without DUMP, the capture cannot record what WindowManager
# thought the rotation was -- the single most useful fact about a rotation
# glitch. Neither is fatal: the capture says which one was missing.
#
# Usage:
#   quat-monitor/build.sh                # build the APK
#   quat-monitor/build.sh --deps         # fetch SDK + Kotlin compiler first
#   quat-monitor/build.sh --install      # build, install, grant, launch
#   quat-monitor/build.sh --pull         # copy the logs off the device
#
# Env: HOST=<ip>  OUT=<dir>
set -euo pipefail

HOST="${HOST:-10.42.0.137}"

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
TOOLS="${TOOLS:-$repo/build/android}"
OUT="${OUT:-$repo/build/quat-monitor}"

SDK="$TOOLS/sdk"
BT="$SDK/build-tools/34.0.0"
PLATFORM="$SDK/platforms/android-33/android.jar"
KOTLINC="$TOOLS/kotlinc/bin/kotlinc"
PKG=lan.syshlt.quatmon
APK=quat-monitor.apk

# Waydroid's data root for the session user; the app's files live under it.
WDATA=/home/jmelanso/.local/share/waydroid/data
LOGDIR="$WDATA/media/0/Android/data/$PKG/files/logs"

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

# ------------------------------------------------------------------ pull only

if [ "$DO_PULL" = 1 ] && [ "$DO_INSTALL" = 0 ] && [ "$DO_DEPS" = 0 ]; then
	dest="$repo/build/quat-logs"
	mkdir -p "$dest"
	echo "== pulling $LOGDIR from $HOST"
	ssh "$HOST" "sudo tar -C '$LOGDIR' -cf - . 2>/dev/null" | tar -C "$dest" -xf -
	echo "== into $dest"
	ls -lh "$dest" | tail -20
	exit 0
fi

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
	[ -e "$f" ] || { echo "missing $f -- run sensor-app/build.sh --deps or this with --deps" >&2; exit 1; }
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
		-dname "CN=bigtab01 quat-monitor debug, OU=none, O=none, C=CA" >/dev/null 2>&1
fi

"$BT/apksigner" sign \
	--ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android \
	--out "$OUT/$APK" "$OUT/aligned.apk"

rm -f "$OUT/aligned.apk" "$OUT/base.apk" "$OUT/classlist" "$OUT/res.zip"

echo
echo "== built $OUT/$APK"
ls -l "$OUT/$APK"

# -------------------------------------------------------------------- install

if [ "$DO_INSTALL" = 1 ]; then
	echo
	echo "== installing into Waydroid on $HOST"
	# Traps, all inherited from sensor-app/build.sh and all still live:
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
		echo '== granting development permissions'
		for p in android.permission.READ_LOGS android.permission.DUMP \
		         android.permission.POST_NOTIFICATIONS; do
			out=\$(sudo waydroid shell -- sh -c \"pm grant $PKG \$p\" 2>&1 | grep -v 'Errno 13')
			if [ -n \"\$out\" ]; then echo \"   \$p: \$out\"; else echo \"   \$p: granted\"; fi
		done
		exit 0
	"
	echo
	echo "== launching"
	ssh "$HOST" "sudo waydroid shell -- sh -c 'am start -n $PKG/.MainActivity' 2>/dev/null" | head -2
fi

if [ "$DO_PULL" = 1 ]; then
	dest="$repo/build/quat-logs"
	mkdir -p "$dest"
	echo
	echo "== pulling logs into $dest"
	ssh "$HOST" "sudo tar -C '$LOGDIR' -cf - . 2>/dev/null" | tar -C "$dest" -xf -
	ls -lh "$dest" | tail -20
fi
