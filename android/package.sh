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
( cd "$ROOT" && zig build so -Dndk="$NDK" )

test -f "$OUT/lib/arm64-v8a/liboutbreak.so" || { echo "no .so; aborting"; exit 1; }

# ---- 2. the manifest, compiled into a binary APK. No resources: there is no UI to declare,
#         because the UI is drawn by us, pixel by pixel, from ui.zig.
echo "==> aapt2 link"
"$AAPT2" link \
    -I "$PLATFORM" \
    --manifest "$ROOT/android/AndroidManifest.xml" \
    --min-sdk-version 24 \
    --target-sdk-version 34 \
    -o "$OUT/unsigned.apk"

# ---- 3. the library goes in at lib/<abi>/. `zip -j` would flatten the path and the loader
#         would never find it.
echo "==> adding lib/arm64-v8a/liboutbreak.so"
( cd "$OUT" && zip -q -u unsigned.apk lib/arm64-v8a/liboutbreak.so )

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
if [ "${1:-}" != "--no-install" ]; then
    echo "==> installing"
    "$ADB" install -r "$OUT/outbreak.apk"
    echo "==> launching"
    "$ADB" shell am start -n com.outbreak.game/android.app.NativeActivity
fi
