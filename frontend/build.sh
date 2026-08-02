#!/usr/bin/env bash
# Build the Outbreak WebView frontend into a signed debug APK.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
: "${ANDROID_HOME:=$HOME/Android/Sdk}"
: "${JAVA_HOME:=$HOME/Android/jdk}"
export PATH="$JAVA_HOME/bin:$PATH"
BT="$ANDROID_HOME/build-tools/34.0.0"
PLATFORM="$ANDROID_HOME/platforms/android-34/android.jar"
ADB="$ANDROID_HOME/platform-tools/adb"
OUT="$HERE/build"; rm -rf "$OUT/classes"; mkdir -p "$OUT/assets" "$OUT/classes"

# 1. assets — boot.html verbatim; app.html with Oxanium inlined from the repo's fonts
cp "$HERE/boot.html" "$OUT/assets/boot.html"
python3 - "$HERE/app.html" "$OUT/assets/app.html" "$ROOT/assets/fonts" <<'PY'
import base64,sys
src=open(sys.argv[1]).read(); fonts=sys.argv[3]
b=lambda p: base64.b64encode(open(p,'rb').read()).decode()
face=("@font-face{font-family:'Oxanium';font-weight:400;src:url(data:font/ttf;base64,%s) format('truetype');}\n"
      "@font-face{font-family:'Oxanium';font-weight:700;src:url(data:font/ttf;base64,%s) format('truetype');}"
      % (b(fonts+'/Oxanium-SemiBold.ttf'), b(fonts+'/Oxanium-Bold.ttf')))
open(sys.argv[2],'w').write(src.replace('/*FONTFACE*/',face,1))
PY

# 2. java -> dex
javac -source 8 -target 8 -bootclasspath "$PLATFORM" -classpath "$PLATFORM" -d "$OUT/classes" "$HERE/android/MainActivity.java"
"$BT/d8" --lib "$PLATFORM" --output "$OUT" "$OUT/classes/com/outbreak/sonar/"*.class

# 3. package, align, sign
"$BT/aapt2" link -I "$PLATFORM" --manifest "$HERE/android/AndroidManifest.xml" \
    --min-sdk-version 24 --target-sdk-version 34 -A "$OUT/assets" -o "$OUT/unsigned.apk"
( cd "$OUT" && zip -q -u unsigned.apk classes.dex )
"$BT/zipalign" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
KS="$OUT/debug.keystore"
[ -f "$KS" ] || "$JAVA_HOME/bin/keytool" -genkeypair -v -keystore "$KS" -alias k \
    -keyalg RSA -keysize 2048 -validity 10000 -storepass android -keypass android \
    -dname "CN=Outbreak Frontend Debug" >/dev/null 2>&1
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
    --out "$OUT/outbreak-frontend.apk" "$OUT/aligned.apk"
echo "built: $OUT/outbreak-frontend.apk"
if [ "${1:-}" = "--install" ]; then
    "$ADB" install -r "$OUT/outbreak-frontend.apk"
    "$ADB" shell am start -n com.outbreak.sonar/.MainActivity
fi
