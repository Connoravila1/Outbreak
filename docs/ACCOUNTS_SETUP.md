# Setting up Sign in with Google and Sign in with Apple

Outbreak lets players sign in with Google or Apple, or play as a guest and link an account later.
The game never sees a password and never talks to Google or Apple on a player's behalf: the phone
or browser gets a signed **ID token** from the provider, sends it to our server, and the server
checks the signature and who the token was issued for. So all you need from each provider is a set
of **IDs** (no secrets, no keys). This guide gets them and says exactly where each one goes.

You need: a Google account, an Apple Developer Program membership (paid, for Apple sign-in), and the
public domain the game runs on. Below, `play.example.com` stands for your domain, and
`com.outbreak.game` is the app's bundle / package id (already set in the project).

Nothing here is needed to try the game locally: start the server with `--dev` and the sign-in
screens show a "Dev sign-in" box that works without any provider.

---

## What goes where (the short version)

| Value | Server | Client build (`client/.env.local`) | Native files |
|---|---|---|---|
| Google **web** client ID | `--google-client-ids` (first) | `VITE_GOOGLE_WEB_CLIENT_ID` | |
| Google **Android** client ID | `--google-client-ids` | | none (matched by package + SHA-1) |
| Google **iOS** client ID | `--google-client-ids` | `VITE_GOOGLE_IOS_CLIENT_ID` | `ios/App/App/Info.plist` URL scheme |
| Apple **bundle id** `com.outbreak.game` | `--apple-audiences` | | entitlement (already added) |
| Apple **Services ID** | `--apple-audiences` | `VITE_APPLE_SERVICE_ID` | |
| Apple return URL | | `VITE_APPLE_REDIRECT_URL` | |

Server example (the same values as environment variables work too, handy for systemd):

    outbreak-server \
      --google-client-ids "WEB.apps.googleusercontent.com,ANDROID.apps.googleusercontent.com,IOS.apps.googleusercontent.com" \
      --apple-audiences  "com.outbreak.game,com.outbreak.game.web"

    # /etc/outbreak.env (loaded by deploy/outbreak.service)
    OUTBREAK_GOOGLE_CLIENT_IDS=WEB.apps.googleusercontent.com,ANDROID...,IOS...
    OUTBREAK_APPLE_AUDIENCES=com.outbreak.game,com.outbreak.game.web

The web client ID must come **first** in the Google list (the website learns it from the server's
`/api/health`). If a provider has no IDs, the server answers `provider_not_configured` and the game
hides that provider's button.

---

## Part 1: Google

### 1. Create a project and the consent screen

1. Go to <https://console.cloud.google.com/> and create a project called "Outbreak".
2. Open **APIs & Services, OAuth consent screen** (newer consoles call it **Google Auth Platform**).
3. Choose **External**. Fill in the app name, a support email, and the developer contact email.
4. Add your links: **Privacy policy** `https://play.example.com/privacy.html`.
5. Scopes: only the defaults (`openid`, `email`, `profile`). These need no Google review.
6. While you test, keep the app in **Testing** and add your own Google account under **Test users**.
   When you are ready for everyone, press **Publish app**.

### 2. Create the three OAuth clients

Open **APIs & Services, Credentials, Create credentials, OAuth client ID**, three times.

**a) Web application** ("Outbreak web")

- Authorized JavaScript origins: `https://play.example.com` (add `http://localhost:5173` for local work).
- Authorized redirect URIs: `https://play.example.com/` (with the trailing slash; add `http://localhost:5173/` for local work).
- Copy the **Client ID**. This is your *web client ID*. Android uses it too.

**b) Android** ("Outbreak Android")

- Package name: `com.outbreak.game`
- SHA-1 certificate fingerprint: the fingerprint of the key that signs the app you install.
  - Debug builds (what `./gradlew assembleDebug` makes):

        keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android

    Copy the line that starts with `SHA1:`.
  - Your own release keystore:

        keytool -list -v -keystore /path/to/release.keystore -alias YOUR_ALIAS

  - If you publish on Google Play with **Play App Signing** (the default), Google re-signs the app.
    Also copy the SHA-1 from **Play Console, your app, Test and release, App signing**
    ("App signing key certificate") and create another Android client with it.
- Create one Android client per SHA-1 and add them all to the server's `--google-client-ids` list.
  (A phone only ever matches the one for the key that signed its build.)

**c) iOS** ("Outbreak iOS")

- Bundle ID: `com.outbreak.game`
- Copy the **Client ID**, which looks like `1234567890-abcdefg.apps.googleusercontent.com`.

### 3. Paste the values

- **Server**: all three IDs (web first) into `--google-client-ids` / `OUTBREAK_GOOGLE_CLIENT_IDS`.
- **Client build**: create `client/.env.local` (git-ignored; see `client/.env.example`):

        VITE_GOOGLE_WEB_CLIENT_ID=WEB.apps.googleusercontent.com
        VITE_GOOGLE_IOS_CLIENT_ID=IOS.apps.googleusercontent.com

  A browser build also learns the web ID from the server, so the web variable is only essential for
  the Android and iOS apps.
- **iOS native file**: in `client/ios/App/App/Info.plist`, find
  `com.googleusercontent.apps.REPLACE_WITH_IOS_CLIENT_ID_PREFIX` and replace
  `REPLACE_WITH_IOS_CLIENT_ID_PREFIX` with the part of the iOS client ID **before**
  `.apps.googleusercontent.com`. For `1234567890-abcdefg.apps.googleusercontent.com` the line becomes
  `com.googleusercontent.apps.1234567890-abcdefg`.
- **Android native files**: nothing to edit. The app asks Google for a token for the web client ID.

---

## Part 2: Apple

You do **not** need to create a Sign in with Apple key or a client secret: the server only verifies
the ID token's signature against Apple's public keys.

### 1. Turn on the capability for the app

1. Sign in at <https://developer.apple.com/account/> and open **Certificates, Identifiers & Profiles, Identifiers**.
2. Open (or create) the **App ID** `com.outbreak.game`.
3. Tick **Sign in with Apple** and **Save**.
4. In Xcode (`client/ios/App/App.xcworkspace` after `npx cap open ios`), under **Signing & Capabilities**
   you should see **Sign in with Apple**; the entitlement file `ios/App/App/App.entitlements` is already
   part of the project. Pick your team there.

### 2. Create a Services ID (for the website and Android)

1. **Identifiers**, the **+** button, **Services IDs**, Continue.
2. Description "Outbreak web"; Identifier for example `com.outbreak.game.web` (this is the *Services ID*). Register it.
3. Open it again, tick **Sign in with Apple**, press **Configure**:
   - Primary App ID: `com.outbreak.game`
   - Domains and Subdomains: `play.example.com`
   - Return URLs: `https://play.example.com/` (exactly, HTTPS only; Apple refuses `localhost`)
4. Save, then Continue and Save again.

### 3. Paste the values

- **Server**: `--apple-audiences com.outbreak.game,com.outbreak.game.web` (the bundle id **and** the Services ID).
- **Client build** (`client/.env.local`):

        VITE_APPLE_SERVICE_ID=com.outbreak.game.web
        VITE_APPLE_REDIRECT_URL=https://play.example.com/

  On iOS the system sheet is used and these are not needed. On the web and on Android, Apple sign-in
  goes through Apple's web flow and needs both. To hide the Apple button on a build, leave
  `VITE_APPLE_SERVICE_ID` empty and do not list a web Services ID in the server (iOS keeps working).

Apple only returns the real email on the very first sign-in, and players can choose "Hide My Email";
the game stores whatever address it receives and works without one.

---

## Part 3: Build and publish

1. Fill in `client/.env.local`, then:

        cd client
        npm run build
        npx cap sync

2. Android: `cd android && ./gradlew assembleDebug` (needs `JAVA_HOME` pointing at a JDK 21).
3. iOS: `npx cap open ios`, set your team, build.
4. Store listings and consent screens need two public pages; both ship with the website build:
   - Privacy policy: `https://play.example.com/privacy.html`
   - Account deletion (Google Play "Data safety" requires a web link): `https://play.example.com/delete-account.html`

   Edit the contact address placeholder (`privacy@example.com`) in both files first.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| No Google/Apple button appears | The server has no IDs for it (`/api/health` shows `providers.google: false`), or on web/Android the client IDs above are not set in the build. |
| Android: "Developer console is not set up correctly" (28444) | The Android client's package name or SHA-1 does not match the build you installed. Re-run the `keytool` command against the keystore that signed *this* APK. |
| Server says `invalid_token`: "not issued for this game" | The token's audience is not in `--google-client-ids` / `--apple-audiences`. Add the missing ID. |
| `provider_unavailable` | The server could not download Google/Apple's public keys. Check its outbound HTTPS access. |
| Google web popup: `redirect_uri_mismatch` | The exact page URL (with trailing slash) is missing from the web client's Authorized redirect URIs. |
| Apple web: "invalid_request" | The domain or return URL is not registered on the Services ID exactly as typed. |

## How it is tested

- `zig build test` verifies the whole token path (RS256 signatures, issuer, audience, expiry, nonce)
  with an embedded test key and pre-signed tokens (`server/src/jwt_fixture.zig`), plus sign-in,
  link, unlink and deletion flows. No network is used.
- Things that need your real credentials and a device: the Google/Apple sheets themselves, the Android
  SHA-1 matching, Apple's entitlement and return URL, and fetching Google/Apple's live key sets.
