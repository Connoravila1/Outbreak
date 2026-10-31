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

Icons and splash are generated: see "Icons and splash" below. The splash background is the neutral
`#0B0C0E`; the Android 12+ splash icon is `drawable-nodpi/splash_icon.png`.

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
`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` per upload. The icon and launch image come from
`npm run icons` (see "Icons and splash"). Fill the App Privacy questionnaire
(location, not linked to identity in the shipped design) before external TestFlight.

## Icons and splash

The mark is a ring split down the middle by a grease-pencil crack: Survey paper (grey, survey grid, ink
ring) on the left, Heat (thermal red, hot ring) on the right. Sources are SVG in `resources/`:
`icon.svg` (full-bleed master), `icon-background.svg` / `icon-foreground.svg` (Android adaptive layers,
ring inside the 66% safe zone), `icon-mono.svg` (themed icon) and `splash.svg`.

```sh
npm run icons      # headless Chromium via playwright-core; CHROME_PATH overrides the browser
```

It writes every Android density (`mipmap-*/ic_launcher{,_round,_bg,_fg,_mono}.png`, the
`mipmap-anydpi-v26` adaptive XML with a `<monochrome>` layer, `drawable-nodpi/splash_icon.png`), the
iOS 1024 `AppIcon` and the 2732 launch images, and the web favicon, apple-touch, 192/512 and maskable
icons in `public/`. It also leaves a 512 Play Store icon, 48/96/192 renders and a light/dark home screen
mock in `resources/out/` (git-ignored). The old `assets/android-icons` and `assets/logo.png` are no
longer used by the build.

## Store screenshots

`scripts/store-shots.mjs` drives the web build in headless Chromium against a `--dev` server and saves
the split-lens choice, Survey map with enemies, Heat map, a fight, the loot result, a level-up and the
PvP stage to `client/shots/` (git-ignored), at Play (1080x1920) and iOS 6.7" (1290x2796).

```sh
cd ../server && zig build && ./zig-out/bin/outbreak-server --dev --port 18504 --data /tmp/outbreak-shots &
OUTBREAK_API=http://localhost:18504 npx vite --port 5184 &       # in client/
npm run shots                                                    # SIZES=play or SIZES=ios for one
```

It needs internet (map tiles) and uses the dev endpoints (`/api/dev/grant`, `/api/dev/bot_contact`).
Env: `API`, `WEB`, `OUT`, `SIZES`, `CHROME_PATH`. The first-fight coach and the guest-account nudge are
hidden in the shots only.

## Battery and performance

What the app does when idle, measured with `scripts/perf-idle.mjs` (headless Chromium, 390x844 at 2.6x,
Seattle, a level-1 character, 30 s windows; "backgrounded" = the page reports `document.hidden`).
Headless has no GPU or battery, so these are wake-up counts, not milliwatts.

| | Before | After |
|---|---|---|
| Foreground idle, map only: rAF callbacks | 0.2 /s | 0.2 /s (MapLibre renders on demand; nothing spins when the map is still) |
| Foreground idle: API requests | 12 /min (one `/api/location` per 5 s) | 12 /min |
| Foreground idle: tile requests | 0 | 0 |
| Backgrounded: API requests | 0 | 0 |
| Backgrounded: running CSS animations, Survey / Heat | 2 / 52 | 0 / 0 |
| Backgrounded: timer callbacks | 2.2 /s | 2.2 /s (the 1 s clocks still wake but do nothing) |
| Main app chunk | 1.28 MB | 41 KB app + 1.09 MB MapLibre chunk, the rest split (battle 32 KB, tabs 4 to 18 KB, onboarding 19 KB) |

Findings and changes:

- **Location watch.** It ran `enableHighAccuracy` with no Android interval, so the plugin reused
  `timeout` (20 s), and it kept running with the app in the background. Now the watch stops when the app
  is backgrounded and restarts on return (Patrol is a separate native service and is untouched), and on
  Android it asks for a fix every 10 s with a 5 s floor (`interval`, `minimumUpdateInterval`). There is no
  distance filter in the Capacitor API; the Patrol service already uses 40 m / 60 s natively.
- **Foreground state** (`src/native/active.ts`) combines `visibilitychange` and Capacitor
  `appStateChange`, because the Android WebView keeps timers and CSS animations running after you leave.
  It gates polling (and polls at once on return), the GPS watch, the 1 s clocks and 60 s sheet polls, the
  audio context, and sets `data-active="false"` on `<html>`, which pauses every CSS animation.
- **Reduced motion.** With the in-app or system setting on, every ambient loop (blink, pulse, bloom,
  flicker) now stops after one iteration; loading spinners stay. Idle Heat has about 52 running CSS
  animations (marker bloom, hostile pulse); on a weak phone, Settings > Reduced motion is the lever.
- **MapLibre.** The pixel ratio is capped at 2 (a 3x phone draws a quarter fewer pixels); `fadeDuration`
  was already short. Idle, the map does not render at all.
- **Audio.** The context is suspended 0.4 s after the app is backgrounded and resumed on return (already
  so on visibility change; now also on native app state). Sound off keeps it suspended.
- **Bundle.** Battle layer, tabs, onboarding, note reader and the desktop simulator panel are lazy chunks,
  preloaded when idle after the map is up.

### On-device checklist (Pixel)

1. Install the debug build, sign in, walk for 5 minutes with the screen on. Settings > Battery > Battery
   usage for Outbreak: note %/h. Repeat with Settings > Reduced motion on and compare.
2. Leave the app, lock the phone for 10 minutes, come back: the map recentres within a few seconds, the
   first poll fires at once, and `adb shell dumpsys batterystats --charged com.outbreak.game` shows no
   location or CPU use while backgrounded (Patrol off).
3. Patrol on, phone locked, 30 minutes: check-ins arrive about once a minute (server log) and the
   foreground service notification stays.
4. Heat lens, 5 minutes on an idle map: the device does not get warm (the 52 CSS animations are the
   thing to watch). If it does, note the model and the frame rate from `adb shell dumpsys gfxinfo`.
5. The map on a 2.6x to 3x screen: roads and labels still look crisp with the pixel ratio capped at 2.
   If not, raise the cap in `src/map/factory.ts`.
6. Open a fight and each tab right after launch: no visible blank frame (the chunks are preloaded when idle).
7. With a self-hosted PMTiles server (`docs/TILES.md`) on the same Wi-Fi: the map draws from it, and
   Chrome `chrome://inspect` shows `/tiles/map.pmtiles` range requests answering 206.
8. Home screen: the icon at 48 px is a split disc with a ring (light and dark wallpaper, round and
   squircle masks, themed icon in Android 13+).

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

## Fake-GPS detection

The server pauses real-world fights and war points while a fix is flagged as simulated (DESIGN.md
section 7). Foreground fixes come from `@capacitor/geolocation`, which hides the flag, so the web
layer asks the Patrol plugin (`Patrol.mockCheck()`, called before each `/api/location`, see
`src/location/mock.ts`) and sends `mock: true`; the Patrol service adds the flag to its own
`/api/patrol` fixes.

- **Android** (`MockLocation.java`, used by `PatrolPlugin.mockCheck` and `PatrolService`): the newest
  fix any provider (gps, network, passive, fused) holds, if under a minute old, is mock when
  `Location.isMock()` (API 31+) or `isFromMockProvider()` says so. No fix, no permission, a stale
  fix or any exception reads as "not mocked". **Written without a build: compile it and, on a phone
  with Developer options > "Select mock location app" set to a fake-GPS app, check that the banner
  appears within ~10 s and goes away when the app is deselected.** Also check an unmocked phone never
  shows it.
- **iOS** (`PatrolEngine.simulated` / `isSimulated` in `PatrolPlugin.swift`):
  `CLLocation.sourceInformation?.isSimulatedBySoftware` (iOS 15+). TODO, needs a Mac: nothing has been
  built or run. `CLLocationManager.location` is only fresh while some manager is receiving updates;
  the plugin reads its own manager (and the last Patrol fix), so in the foreground with Patrol off the
  answer may be "not simulated" even for a simulated fix. If that matters, run a short-lived
  `startUpdatingLocation()` in `mockCheck` or add a watch of its own.
- **Web and the desktop simulator** never report it (a browser cannot tell). The dev panel has a
  "Report as mock GPS" box to try the server's policy.

## Version and error reports

`package.json`'s version is baked in at build time (`__APP_VERSION__`, `vite.config.ts`) and sent as
`X-Outbreak-Client` on every request; bump it for each store release, and raise the server's
`--min-client` once the build is live. The native Patrol services do not send the header (a missing
header is allowed). Crashes, unhandled rejections, render errors and failed plugin calls are reported
anonymously to `/api/client-error` (`src/report/errors.ts`); read them with `outbreak-server admin
errors`.

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
