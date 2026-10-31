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
| Sign in with Google / Apple via `@capgo/capacitor-social-login` (ID token only; the server verifies it). Needs the IDs, the iOS URL scheme in `Info.plist` and the Sign in with Apple entitlement (`ios/App/App/App.entitlements`): see `../docs/ACCOUNTS_SETUP.md` | `src/auth/social.ts` |

## Patrol mode (background location)

Patrol keeps the player in the world with the app closed. A native plugin (`Patrol`, JS wrapper
`src/native/patrol.ts`) runs a background location service that posts a light check-in to
`POST /api/patrol` (see `docs/ARCHITECTURE.md`); each event the server returns becomes a local
notification, and the app replays the fights in "While you were patrolling" when it opens. The
token and server URL are passed from JS at `Patrol.start`; native code never reads WebView storage.

API: `Patrol.start({serverUrl, token, intervalSec?, durationSec?})` (`durationSec` 0 = until stopped),
`stop()`, `status()` -> `{active, endsAt, intervalSec, lastCheckIn, lastError, fineLocation,
backgroundLocation, notifications}`, `requestBackground()`, `openSettings()`.

Interval: 60 s by default. For testing set `VITE_PATROL_INTERVAL_SEC=15` at build time, or
`outbreak.patrol.interval` in app storage (clamped to 10..600 s).

### Android

`android/.../PatrolPlugin.java` (bridge, registered in `MainActivity`) and `PatrolService.java`.

- Foreground service of type `location`, persistent low-importance notification "Outbreak is
  patrolling - tap to open" with a Stop action. Survives the app being swiped away; stops itself
  after the chosen duration, when the token is rejected (401), or if permission is withdrawn.
- `LocationManager` only (no Play Services): PASSIVE + NETWORK + GPS providers, `minTime` 60 s,
  `minDistance` 40 m, fixes worse than 150 m ignored. The check-in is driven by an inexact
  `setAndAllowWhileIdle` alarm every `intervalSec` (re-announcing the last fix, so a standing-still
  player stays matchable); a partial wake lock is held only for the POST. Failures back off
  (interval x 2^n, capped at 10 min).
- Notifications: "Patrol" (low, the service), "Contacts" (high, one per Contact: title CONTACT,
  body "A Zombie found you. You held."), "Patrol updates" (level-ups, raids, patrol ending).
- Permissions: `ACCESS_BACKGROUND_LOCATION`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION`,
  `POST_NOTIFICATIONS`, `WAKE_LOCK`. Flow: fine location (onboarding) -> notifications (asked at
  Patrol start) -> an in-app explanation screen -> `requestBackground()` (Android 11+ opens the
  location settings page: "Allow all the time"). If the player declines, Patrol still starts
  because the service is started from the visible app, which keeps "while in use" location alive;
  the UI says plainly that if Android ends the service, the player must reopen the app, because a
  service cannot restart itself into the foreground from the background.
- Play review: background location needs a declaration, a privacy-policy line and a short video.
  Update the Data safety form ("location, collected in the background, not shared").
- Expected cost: GPS/network fixes at most once a minute and only after 40 m of movement, plus one
  small POST per minute (a few hundred bytes). The old prototype's equivalent service measured very
  battery-efficient; measure this one on the Pixel with `adb shell dumpsys batterystats` over a 1 h
  walk and a 1 h stationary run and record the numbers here.
- Doze: with the phone stationary and the screen off, Android may batch the inexact alarm (up to
  several minutes). The server keeps a patrol position for 4 minutes, so a stationary phone can drop
  out of matching until the next check-in; moving phones are not affected.

### iOS (written without a Mac: nothing below has been built or run)

`ios/App/App/PatrolPlugin.swift` (engine + bridge) and `ViewController.swift` (registers the plugin;
`Main.storyboard` now points at it). `CLLocationManager` with `allowsBackgroundLocationUpdates`,
`pausesLocationUpdatesAutomatically`, 40 m distance filter, significant-change monitoring so the
system can relaunch the app (`AppDelegate` resumes patrol), `URLSession` POSTs wrapped in a
background task, and `UNUserNotificationCenter` local notifications (Contacts are time-sensitive).
`Info.plist` gains `UIBackgroundModes: location` and `NSLocationAlwaysAndWhenInUseUsageDescription`.

Verify on a Mac:

1. The project builds: `PatrolPlugin.swift` and `ViewController.swift` were added to
   `project.pbxproj` by hand; check both are in the App target's Sources, and that the storyboard's
   view controller class is `ViewController` (module App). Fix the CAPBridgedPlugin conformance if
   Capacitor 8's signature differs.
2. Permission flow: When In Use first, then "Always" upgrade via `requestBackground()`; confirm the
   iOS Always prompt appears (it may only appear once; otherwise the UI offers Settings).
3. Background behaviour: lock the phone, walk, confirm check-ins reach the server and the blue
   location indicator shows. Check that a stationary phone still checks in (the 15-minute stale
   limit) or document that it cannot (iOS suspends a stationary app; the timer only runs while the
   system keeps it alive).
4. Termination: force-quit the app, move 500 m, confirm the significant-change relaunch resumes
   patrol. (A user force-quit normally disables relaunch until the next manual open.)
5. Notifications: a Contact arrives as a time-sensitive notification; tapping opens the app and the
   "While you were patrolling" card plays it.
6. App Review: background location needs a clear purpose string and review notes.
7. Token storage: it is in UserDefaults for now; move it to the Keychain.
