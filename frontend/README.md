# Outbreak — web frontend (WebView)

An experimental presentation layer for Outbreak: the whole UI as HTML/Canvas in a
native-hosted WebView, fed only categorical, sub-quorum-safe view state. See
`../FRONTEND_RULESET.md` (local-only) for the law this layer lives under.

**Not** a replacement for the Zig core — this is the render/experience layer only.
GPS, the socket, the tick, quorum, and every outcome stay native and authoritative.

## Layout
- `app.html`   — the app shell: flow (login → side-select → app) + the 5 tab screens
                 (Here / World / Arsenal / Clans / You). `/*FONTFACE*/` is where the
                 build inlines Oxanium from `../assets/fonts`.
- `boot.html`  — the boot/opening sequence (terminal → infection → glitch-in),
                 loaded in an iframe; posts `boot-done` when finished.
- `android/`   — the minimal WebView Activity + manifest (`com.outbreak.sonar`),
                 no INTERNET permission (assets are local).

## Build
    ./build.sh            # build a signed debug APK into build/
    ./build.sh --install  # ...and install + launch on the connected phone

Toolchain by env (same posture as `android/package.sh`):
`ANDROID_HOME` (default ~/Android/Sdk), `JAVA_HOME` (default ~/Android/jdk).
