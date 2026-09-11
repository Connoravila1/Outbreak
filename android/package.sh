#!/usr/bin/env bash
#
# SUSPENDED — see CURRENT.md.
#
# This script packaged the WebView build: it linked liboutbreak.so from src/android.zig,
# dexed the WebView activity and the location service, and signed the APK. The presentation
# layer is being rebuilt on DVUI over SDL, so there is no launchable APK to package until the
# new host lands.
#
# What survives the swap and will be needed again: the location service
# (android/java/com/outbreak/game/OutbreakService.java), the manifest, the signing flow.
# What is gone for good: the WebView activity, the JNI bridge, the GLES host.
#
# The old script is in git history. This stub fails loudly rather than half-building something.

echo "android/package.sh is suspended: no launchable APK exists until the DVUI/SDL host lands." >&2
echo "See CURRENT.md for the active sequence." >&2
exit 1
