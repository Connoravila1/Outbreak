# Outbreak mobile (Capacitor)

The web client is wrapped as native Android and iOS apps with Capacitor 8
(`com.outbreak.game`, web assets from `dist`). The web build is unchanged: in a desktop browser the
GPS simulator still appears. Native behaviour is switched on by `Capacitor.isNativePlatform()`
(`src/native/platform.ts`).

## Toolchain

- Node 22+, npm.
- Android: JDK 21, Android SDK platform 36 + build-tools 36.0.0 (Capacitor 8 defaults:
  compileSdk/targetSdk 36, minSdk 24). Set `JAVA_HOME` to a JDK 21 and `ANDROID_HOME` (or
  `android/local.properties`, git-ignored, `sdk.dir=...`).
- iOS: a Mac with Xcode 26+ (Swift Package Manager; no CocoaPods needed), iOS 15+ target.

## Pointing the app at a server

On native, same-origin means nothing. Order of precedence:

1. The address saved in the app (first-launch "Server address" screen, or Settings > Server URL).
2. `VITE_SERVER_URL` baked in at build time: `VITE_SERVER_URL=https://play.example.com npm run android:build`.
3. Neither: the app shows the **Server address** screen (with Test connection against `/api/health`)
   before onboarding.

Network calls go through Capacitor's native HTTP (`CapacitorHttp`), so the server needs no CORS
headers for the app. Plain `http://` is for development only:

- Android debug builds allow cleartext to any host (`android/app/src/debug/res/xml/network_security_config.xml`).
  Release builds allow cleartext only to `localhost`, `10.0.2.2` and `127.0.0.1`; use https in production.
- iOS: `NSAllowsLocalNetworking` in `Info.plist` allows http to LAN IPs and `.local` hosts. For a
  non-local http server add an `NSExceptionDomains` entry (do not ship `NSAllowsArbitraryLoads`).

## Android

```sh
export JAVA_HOME=~/Android/jdk21 ANDROID_HOME=~/Android/Sdk
npm run android:build      # build web, cap sync, assembleDebug
# -> android/app/build/outputs/apk/debug/app-debug.apk
npm run android:release    # build web, cap sync, bundleRelease
# -> android/app/build/outputs/bundle/release/app-release.aab
```

Signing: create `android/keystore.properties` (git-ignored, as are `*.jks`/`*.keystore`):

```
storeFile=/absolute/path/outbreak-upload.jks
storePassword=...
keyAlias=upload
keyPassword=...
```

Generate a key once with `keytool -genkeypair -v -keystore outbreak-upload.jks -alias upload -keyalg RSA -keysize 2048 -validity 10000`
and back it up. With the file present the bundle is signed; without it `bundleRelease` produces an
unsigned bundle.

Play upload: bump `versionCode` (and `versionName`) in `android/app/build.gradle`, build the `.aab`,
upload it in Play Console > Testing (internal track first) and enrol in Play App Signing. The
location permission needs a Data safety entry and a privacy policy URL; location is foreground-only.
The Local Notifications plugin adds `SCHEDULE_EXACT_ALARM` to the manifest; Play may ask for a
justification, or you can remove it (alerts then fire inexactly).

Icons come from `assets/android-icons/res` (copied into `android/app/src/main/res`). The splash is
the neutral `#0B0C0E`.

## iOS (needs a Mac)

The `ios/` project was generated on Linux with SPM (`ios/App/CapApp-SPM`). Not built or opened
here. On a Mac:

```sh
npm ci
npm run ios:sync           # build web + cap sync ios
npx cap open ios           # opens ios/App/App.xcodeproj
```

In Xcode: select the App target > Signing & Capabilities, set your Team (bundle id
`com.outbreak.game`), pick a device, Run. To ship: Product > Archive, then Distribute App >
App Store Connect > Upload; the build appears in TestFlight after processing. Bump
`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` per upload. Regenerate the icon and launch image
with `npm run icons:ios` (ImageMagick; from `assets/logo.png`). Fill the App Privacy questionnaire
(location, not linked to identity in the shipped design) before external TestFlight.

## Native capabilities in use

| Capability | Where |
|---|---|
| Geolocation (watch, high accuracy, permission flow in the Locate step; simulator never shown) | `src/location/native.ts` |
| Preferences storage (hydrated into memory before render, write-through) | `src/api/storage.ts`, `src/main.tsx` |
| Haptics (hit, crit, contact, level up, generic patterns) | `src/native/haptics.ts` |
| Local notifications: "Daily missions reset" at 00:00 UTC (next 7 days, rescheduled on resume); "Back on your feet" / "you rise again." when Downed ends. Permission asked once, right after onboarding | `src/native/notify.ts` |
| Status bar overlay, safe-area insets (`--sa-*` from `env(safe-area-inset-*)`), splash hidden on first screen | `src/native/lifecycle.ts` |
| Android back: closes the top sheet (`src/ui/back.ts`), otherwise minimizes | `src/native/lifecycle.ts` |

## Next step: Patrol mode (background location)

Today nothing is read while the app is closed. Patrol mode needs:

- Android: a foreground service of type `location` with a persistent notification, the
  `ACCESS_BACKGROUND_LOCATION` permission (separate prompt, Play review), and a native plugin
  that posts fixes to the server (or queues them for the next foreground poll).
- iOS: the "Location updates" background mode (`UIBackgroundModes`), an "Always" authorization
  request with `NSLocationAlwaysAndWhenInUseUsageDescription`, and significant-change or
  continuous updates via CoreLocation.
- Update the Locate copy ("Nothing is read while the app is closed") and the privacy disclosures.
