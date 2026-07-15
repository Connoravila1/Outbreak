#!/usr/bin/env bash
#
# Build, package, sign and install the APK.
#
#     android/package.sh            # build + install to the connected phone
#     android/package.sh --no-install
#
# There is no Gradle here and there is not going to be. Gradle exists to orchestrate a Java
# toolchain, and there is no Java: `android:hasCode="false"` means the framework loads
# `liboutbreak.so` directly and calls `ANativeActivity_onCreate`. What is left is four tools
# in a row -- link the manifest, add the library, align, sign -- and hiding four commands
# behind a build system that downloads its own dependencies at run time is not simplicity.
#
# The toolchain is passed by environment, not discovered. A script that hunts the filesystem
# for an SDK is a script that behaves differently on two machines.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --diagnostic builds the cafe readout onto the screen (O3). Off by default: the flag is a decision
# the compiler records, and a shipping build must not carry it.
ZIG_FLAGS=""
INSTALL=1
for arg in "$@"; do
    case "$arg" in
        --diagnostic) ZIG_FLAGS="-Ddiagnostic=true" ;;
        --no-install) INSTALL=0 ;;
    esac
done

: "${ANDROID_HOME:=$HOME/Android/Sdk}"
: "${JAVA_HOME:=$HOME/Android/jdk}"
: "${NDK:=$ANDROID_HOME/ndk/26.3.11579264}"
: "${BUILD_TOOLS:=$ANDROID_HOME/build-tools/34.0.0}"
: "${PLATFORM:=$ANDROID_HOME/platforms/android-34/android.jar}"

AAPT2="$BUILD_TOOLS/aapt2"
ZIPALIGN="$BUILD_TOOLS/zipalign"
APKSIGNER="$BUILD_TOOLS/apksigner"
ADB="$ANDROID_HOME/platform-tools/adb"
KEYTOOL="$JAVA_HOME/bin/keytool"

export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

OUT="$ROOT/zig-out/apk"
KEYSTORE="$ROOT/zig-out/debug.keystore"

# ---- 1. the library. This is where android.zig is finally LINKED, not merely type-checked.
echo "==> linking liboutbreak.so"
( cd "$ROOT" && zig build so -Dndk="$NDK" $ZIG_FLAGS )

test -f "$OUT/lib/arm64-v8a/liboutbreak.so" || { echo "no .so; aborting"; exit 1; }

# ---- 1b. THE JAVA. Still one source file, one top-level class.
#
# Android has no native location API -- there is no LocationManager in the NDK and there never has
# been. Every route to a live fix runs through a Java callback object, which needs a class, which
# needs a dex. So there is one source file: OutbreakService.java.
#
# javac -> .class -> d8 -> classes.dex. NOTE: one source file can compile to MORE than one .class --
# an anonymous listener (the significant-motion trigger) becomes OutbreakService$1.class. d8 must
# dex ALL of them, or the missing inner class is a NoClassDefFoundError the moment the service runs.
# It compiles and dexes clean either way; the crash is at class-load time on the phone. (This bit
# once: d8 was handed only OutbreakService.class by name.)
echo "==> compiling the Java"
rm -rf "$OUT/classes"
mkdir -p "$OUT/classes"
"$JAVA_HOME/bin/javac" \
    -source 8 -target 8 \
    -bootclasspath "$PLATFORM" \
    -classpath "$PLATFORM" \
    -d "$OUT/classes" \
    "$ROOT/android/java/com/outbreak/game/OutbreakService.java" 2>&1 | grep -v "bootstrap class path\|source value 8\|target value 8\|deprecat" || true

test -f "$OUT/classes/com/outbreak/game/OutbreakService.class" || { echo "no OutbreakService.class; aborting"; exit 1; }

echo "==> d8 (every compiled class, inner classes included)"
"$BUILD_TOOLS/d8" \
    --lib "$PLATFORM" \
    --output "$OUT" \
    "$OUT/classes/com/outbreak/game/"*.class

test -f "$OUT/classes.dex" || { echo "no classes.dex; aborting"; exit 1; }

# ---- 2. resources, then the manifest, into a binary APK.
#
# There is still no UI in here -- the game is drawn pixel by pixel from ui.zig. The only resources
# are the two icons Android insists on referencing by name: the launcher icon (your logo) and the
# notification icon (a clean stencil O, because the status bar renders a monochrome silhouette and
# the full wordmark would be an illegible white smear at 24dp).
echo "==> aapt2 compile resources"
rm -rf "$OUT/res-compiled"; mkdir -p "$OUT/res-compiled"
"$AAPT2" compile --dir "$ROOT/android/res" -o "$OUT/res-compiled/res.zip"

echo "==> aapt2 link"
"$AAPT2" link \
    -I "$PLATFORM" \
    --manifest "$ROOT/android/AndroidManifest.xml" \
    --min-sdk-version 24 \
    --target-sdk-version 34 \
    "$OUT/res-compiled/res.zip" \
    -o "$OUT/unsigned.apk"

# ---- 3. the library goes in at lib/<abi>/. `zip -j` would flatten the path and the loader
#         would never find it.
echo "==> adding lib/arm64-v8a/liboutbreak.so and classes.dex"
( cd "$OUT" && zip -q -u unsigned.apk lib/arm64-v8a/liboutbreak.so classes.dex )

# ---- 4. align, then sign. In that order: zipalign rewrites offsets, so signing first and
#         aligning second invalidates the signature.
echo "==> zipalign"
"$ZIPALIGN" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

if [ ! -f "$KEYSTORE" ]; then
    echo "==> creating a debug keystore (this is NOT a release key)"
    "$KEYTOOL" -genkeypair -v \
        -keystore "$KEYSTORE" \
        -alias outbreak-debug \
        -keyalg RSA -keysize 2048 -validity 10000 \
        -storepass android -keypass android \
        -dname "CN=Outbreak Debug, OU=, O=, L=, S=, C=" > /dev/null 2>&1
fi

echo "==> apksigner"
"$APKSIGNER" sign \
    --ks "$KEYSTORE" \
    --ks-pass pass:android \
    --key-pass pass:android \
    --out "$OUT/outbreak.apk" \
    "$OUT/aligned.apk"

"$APKSIGNER" verify "$OUT/outbreak.apk" && echo "==> signed: $OUT/outbreak.apk"
ls -la "$OUT/outbreak.apk"

# ---- 5. onto the phone.
if [ "$INSTALL" = "1" ]; then
    echo "==> installing"
    "$ADB" install -r "$OUT/outbreak.apk"
    echo "==> launching"
    "$ADB" shell am start -n com.outbreak.game/android.app.NativeActivity
fi
