# Outbreak — Architecture

```
client/   TypeScript + Preact + Vite + MapLibre GL. The whole interface.
          Runs in a desktop browser (dev, with a GPS simulator) and inside Capacitor
          on Android and iOS.
server/   Zig 0.16. One binary: HTTP JSON API, game rules, SQLite persistence.
deploy/   Caddy (HTTPS), systemd unit, Dockerfile, and a hosting guide.
docs/     DESIGN.md (the game, all numbers), this file, the original GDD.
assets/   Source art, fonts, audio, icons.
```

The server is authoritative over every outcome. The client renders state and sends intents.

## Server

- **Language**: Zig 0.16 (`std.http.Server` over `std.Io.net`). No dependencies except vendored
  SQLite (`server/vendor/sqlite/`, the amalgamation compiled by `build.zig`).
- **Layout**:
  - `src/main.zig` — flags/env config, open DB, start listener + tick thread.
  - `src/http.zig` — accept loop, thread per connection, request parsing, routing, JSON
    responses, CORS (`Access-Control-Allow-Origin: *`; auth is bearer tokens, no cookies).
  - `src/api.zig` (+ `src/api/*.zig` as it grows) — one handler per endpoint.
  - `src/jwt.zig` (pure ID-token + JWKS verification on `std.crypto.Certificate.rsa`), `src/auth.zig`
    (provider config, key cache, JWKS fetch), `src/api/auth.zig` (sign-in, link, unlink, delete).
  - `src/db.zig` — thin SQLite wrapper (prepare/bind/step), schema + migrations by `user_version`.
  - `src/game/` — **pure** game logic, no I/O, fully unit-tested: `data.zig` (catalogue from
    DESIGN.md), `stats.zig`, `combat.zig`, `loot.zig`, `progression.zig`, `geo.zig` (geohash,
    haversine), `spawns.zig` (deterministic world content), `missions.zig`, `war.zig`, `rng.zig`, `stance.zig` (stance, counters), `daynight.zig` (solar phase), `landmarks.zig` (place validation, windows, rate limit), `notes.zig` + `notes_data.zig` (found notes: the 60 texts, drop rules, set rewards; see LORE.md).
  - `src/notes.zig` — what a player holds (`player_notes`), set claims (`note_claims`), titles. `src/api/notes.zig` — the archive endpoints.
  - `src/achievements.zig` + `src/api/collection.zig` + `src/game/achievements.zig` + `src/game/cosmetics.zig` — achievements (pure definitions; counters, earned rows, discoveries, cosmetics owned; the check run inside `rewards.apply`), the collection log and cosmetic equip. See DESIGN.md section 17.
  - `src/worldevents.zig` + `src/api/events.zig` + `src/game/events.zig` — limited-time world events (DESIGN.md section 18): pure calendar, modifiers and goal maths; event rows, contributions, settling and the Exchange; the endpoints. `--no-events` turns the calendar off (tests use it; an admin can still start one).
  - `src/live.zig` — in-memory state: latest position per player (never persisted, expires in
    2 min, or 4 min when it came from a Patrol check-in), active echoes, rate limits, and reported landmarks per geohash-6 area (12 h TTL, capped, never persisted).
  - `src/tick.zig` — every 5 s: PvP contact matching, raid/war housekeeping.
  - `src/names.zig` — the name blocklist (callsigns, clan names, tags). `src/api/report.zig` — player reports. `src/api/client_error.zig` — anonymous crash reports. `src/client_version.zig` — the forced-update version compare. `src/admin.zig` — the `outbreak-server admin ...` moderation commands, run against the SQLite file directly (no network surface); see `docs/MODERATING.md`.
  - `src/sim.zig` — balance simulator (`zig build sim`): simulates players and prints pacing.
- **Concurrency**: one global mutex around game state and the single SQLite connection. Correct
  and fast enough for thousands of players; revisit only with evidence.
- **Persistence**: SQLite in WAL mode at `--data <dir>/outbreak.db`. Positions are never stored.
- **Determinism**: world content = f(server_seed, cell, window). `server_seed` is created on first
  start and stored in the DB. Combat = f(seed) and is reproducible from the stored seed.
- **Config**: `--port` (8080), `--bind` (0.0.0.0), `--data` (./data), `--dev` (enables `/api/dev/*`,
  the `dev` sign-in provider and relaxed rate limits), `--google-client-ids` (comma list: web, Android,
  iOS OAuth client IDs; the first is the web one), `--apple-audiences` (comma list: the iOS bundle id
  `com.outbreak.game` and the web Services ID). Same as env vars `OUTBREAK_PORT`,
  `OUTBREAK_GOOGLE_CLIENT_IDS`, etc. See `docs/ACCOUNTS_SETUP.md`.
- **Additive wire details** (nothing above changed shape): `Rewards` may carry `auto_scrapped`
  (the salvage value of items scrapped on pickup because the pack was full; already counted in `salvage`); `/api/catalog` abilities carry `faction` (each ability id belongs to one side; `names` still gives the pair) and items and abilities also
  carry `lore_zombie`, `text_zombie`, `note`, `flavour`; `raids[].boss` is the boss's display name
  for the viewer's faction; `Me.expansion_price` is the salvage price of the next inventory expansion (the catalog price is the first); `/api/feed` events omit `battle` and `rewards` when there are none;
  `/api/clan` with no clan answers 409 `no_clan`. Combat adds a per-fight "form" factor
  (U(0.5,1.5) per side) on top of the per-hit spread; see DESIGN.md section 4.
- **TLS**: terminated by Caddy in front (automatic HTTPS). Zig std has no TLS server.

## Client

- Vite + Preact + TypeScript. MapLibre GL JS with OpenFreeMap vector tiles (no key) and custom lens
  styles. A server can advertise its own PMTiles archive (`--tiles` / `--tiles-url`, `tiles` in
  `/api/health`); the client then reads it through the `pmtiles` protocol (`src/map/tiles.ts`). See
  `docs/TILES.md`.
- Code split: the first map needs only the shell; the battle layer, tabs, onboarding, note reader and
  the desktop simulator panel are lazy chunks (`src/ui/lazy.tsx`), preloaded when idle.
- Foreground state (`src/native/active.ts`): polling, the GPS watch, ambient CSS animation and audio all
  pause while the app is backgrounded.
- Capacitor for Android/iOS: Geolocation, Haptics, Preferences, Local Notifications, App.
- Server URL is a runtime setting (default from build env `VITE_SERVER_URL`; editable in Settings),
  so a self-hosted server needs no rebuild.
- In a desktop browser the client offers a **GPS simulator** (WASD / click-to-walk at walking
  speed, teleport) so the whole game is playable on a laptop.

## API (v1)

All JSON. Auth: `Authorization: Bearer <token>`. Errors: HTTP 4xx/5xx with
`{"error":"<code>","message":"<human text>"}`. Times are unix milliseconds. Coordinates are
degrees (WGS84). `faction` is `"human"` or `"zombie"`. Slots are `"weapon" | "armor" | "utility"`.

### Account
| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/api/health` | | `{ok, version, terms_version, players_online, providers:{google, apple, dev, google_web_client_id?, apple_web_service_id?}, tiles:{pmtiles, glyphs}|null}` — which sign-ins this server offers, and the IDs a browser needs; `tiles` points the map at a self-hosted PMTiles archive (null: OpenFreeMap); `min_client` (null or a version) and `store:{android, ios}|null` are the forced-update gate (below) |
| GET | `/tiles/map.pmtiles` | | the `--tiles` archive, HTTP range requests (206); only routed when the server was started with `--tiles` |
| GET | `/api/catalog` | | static game data (below); cacheable by `version` |
| GET | `/api/factions` | | `{human:{share, players}, zombie:{...}, underdog:"human"|"zombie"|null, underdog_bonus}` |
| POST | `/api/register` | `{terms, callsign?}` | `{token, me}` — creates a **guest**: a player with no sign-in identity. `terms` is the terms version the player accepted (`health.terms_version`); anything else is 400 `terms_required` and nothing is created |
| POST | `/api/terms` | `{version}` | `{me}` — accept the terms now in force (the re-accept sheet); 400 `terms_required` for any other version |
| POST | `/api/callsign` | `{callsign}` | `{me}` — once only (again after a moderator reset it, while `me.must_rename`); 409 `callsign_set`, `callsign_taken`; 400 `callsign_invalid` (also for a name on the blocklist: message "That name is not allowed here. Please pick another name.") |
| POST | `/api/faction` | `{faction}` | `{me}` — once only; 409 `already_chosen`. Works before or after the callsign |
| POST | `/api/auth/{google\|apple}` | `{id_token, nonce?, switch?, terms}` + optional `Authorization` of the current player | `{token, me, created}` — see below |
| POST | `/api/auth/link/{google\|apple}` | `{id_token, nonce?}` (auth) | `{me}` — 409 `identity_in_use` (taken by another player), 409 `already_linked` (this player already has that provider) |
| POST | `/api/auth/unlink/{provider}` | | `{me}` — 404 `not_linked`; 409 `last_identity` for the only identity |
| DELETE | `/api/account` | | `{ok}` — deletes the player and everything owned (auth) |
| GET | `/api/me` | | `Me` |
| POST | `/api/avatar` | `{avatar:{...}}` | `{me}` — fields `body skin face hair hcol facial scar look`, all small integers in range (400 otherwise); `look` is the faction treatment (0 automatic, 1-6 from `catalog.avatar_looks`), 409 `look_locked` above the player's level |

**Accounts.** A player with no row in `identities(provider, subject, player_id, email, created_at)`
is a guest; its only credential is the bearer token. `POST /api/auth/{provider}` verifies the
provider's ID token (RS256 against the provider's JWKS; `iss`, `aud`, `exp` with 60 s leeway, `iat`,
and `nonce` when the client sends one: the claim may equal the raw nonce or its SHA-256 hex) and then:

- identity exists: returns that player's session (a fresh token; any older token stops working) with
  `created:false`. If a different player's token was also sent: a guest without a faction is
  discarded; one with a faction gets **409 `identity_in_use`** unless the body has `switch:true`, in
  which case the guest is deleted.
- identity is new and a token was sent: it is linked to that player (`created:false`).
- identity is new and no token: a new player (no faction, no callsign) is created (`created:true`).
  The body must carry `terms` (the current terms version) or this is 400 `terms_required`; on an
  existing identity a matching `terms` is recorded as accepted, a missing one changes nothing.

**Terms and age.** `data.terms_version` (`server/src/game/data.zig`) is the version of
`client/public/terms.html`. `players.terms_accepted` / `terms_accepted_at` record the version a
player accepted and when (0: never; players from before terms existed are asked once). `Me.terms`
tells the client: `current`, `accepted`, `needs_accept` (accepted < current), and the client then
shows a short re-accept sheet that posts `/api/terms`. The age screen is entirely on the device:
the birth year is never sent, never stored, and an under-13 answer sends nothing to the server.

Errors: 503 `provider_not_configured` (server has no client IDs for it), 503 `provider_unavailable`
(JWKS fetch failed), 401 `token_expired` / `invalid_token`, 400 `invalid_token` (not a JWT).
Signing keys are cached per `kid` for the JWKS `Cache-Control: max-age` (default 1 h) and refetched
on an unknown `kid`, at most every 30 s. With `--dev`, provider `dev` accepts
`POST /api/auth/dev {subject, email?}` (and `/api/auth/link/dev`, `/api/auth/unlink/dev`) with no verification.
A player with no callsign cannot use the game endpoints (409 `no_callsign`), nor one with no faction (409 `no_faction`).

**Deletion** removes the player's items, consumables, buffs, missions, events, war points, raid damage,
snapshots, contact records and identities. Clan leadership passes to the most senior officer, else the
highest level (the clan closes if they were alone). Their clan chat lines stay, shown as `[deleted]`.
Weekly war totals survive only as per-district aggregates. `POST /api/recover` still works for
accounts that have a recovery code but is no longer used by the client.

### World
| Method | Path | Body | Returns |
|---|---|---|---|
| POST | `/api/location` | `{lat, lon, acc, sanctuary, mock?, places?:[{key, kind, lat, lon, name?}]}` (<= 40) | `WorldView` — call every ~5 s in foreground. `mock: true` says the phone's fix came from a mock provider (see "Simulated locations"); `me.simulated_location` echoes the flag |
| POST | `/api/patrol` | `{lat, lon, acc?, sanctuary?, mock?}` | `{events:[{id, type, text, at}], hp, downed_until}` — Patrol check-in, see below |
| POST | `/api/engage` | `{id, stance?}` (enemy spawn or echo id; stance `aggressive`/`careful`/`evasive`, default careful; 409 `in_transit`) | `Battle` |
| POST | `/api/stance` | `{stance}` (default for Contact PvP) | `{me}` |
| POST | `/api/open` | `{id}` (cache, airdrop or landmark id; 409 `landmark_limit`, 409 `in_transit`) | `{loot: Rewards, me}` |

**In transit.** The server watches the speed between a player's consecutive fixes (from
`/api/location` and `/api/patrol`; `game/transit.zig`). A speed over 7 m/s (distance reduced by both
fixes' accuracy radii; fixes vaguer than 100 m ignored; a rejected jump counts as fast) two fixes in a
row puts the player *in transit*; each further fast fix extends it to 60 s past the last one. While in
transit: `/api/engage`, `/api/open`, `/api/stronghold/claim` and `/api/raid/attack` answer 409
`in_transit`; the 5 s Contact tick leaves the player out (and `hostiles_near` ignores them);
`hostiles_near` is false for them; a Patrol check-in returns no events (they stay queued). The state is
in memory only. `WorldView.in_transit` carries it so the client can show the banner and disable Engage.
There is no passenger override.

**Patrol mode.** `POST /api/patrol` is the background check-in (the phone's Patrol service sends
one about every 60 s, bearer token as usual). It validates the position exactly like
`/api/location` (speed limit, `sanctuary` optional, walking XP paid; a gap of up to 150 s still
counts as walking) and stores it with `source = patrol`, which lives 4 minutes instead of 2, so a
once-a-minute cadence keeps the player matchable. The 5 s Contact tick treats patrol-live and
foreground players alike; eligibility is unchanged (level >= 5 and so on). Nothing is computed
for the world around the player. The answer holds only the events not yet *notified*, each as
`{id, type, text, at}` (no Battle, no Rewards), and `hp` / `downed_until`. Events have two flags:
`notified` (a Patrol answer carried it) and `delivered` (`/api/location` carried it with its full
Battle). Patrol sets only `notified`; `/api/location` sets both, so the app still plays every
fight it missed and never notifies about one it already showed. The latest schema version adds `events.notified`
(existing rows copy `delivered`).

### Gear and character
| Method | Path | Body | Returns |
|---|---|---|---|
| POST | `/api/equip` | `{uid}` | `{me}` |
| POST | `/api/unequip` | `{slot}` | `{me}` |
| POST | `/api/scrap` | `{uids:[...]}` | `{salvage_gained, me}` |
| POST | `/api/upgrade` | `{uid}` | `{me}` |
| POST | `/api/use` | `{consumable}` | `{me}`; an XP token (`xp_token`) answers `{rewards, me}` with `rewards.xp` and any `level_up` (409 `none_left`) |
| POST | `/api/abilities` | `{equipped:[ids]}` | `{me}` |
| POST | `/api/missions/claim` | `{id}` | `{rewards, me}` |
| POST | `/api/store/buy` | `{sku}` | `{rewards?, me}` |

### Achievements, collection and cosmetics (DESIGN.md section 17)
| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/api/achievements` | | `{earned:[{id, at}], progress:{metric: n}, fresh?:[Earned]}` — runs the check first |
| GET | `/api/collection` | | `{bases:[ids], uniques:[ids], rarities:[...]}` — everything ever held, scrapped or not |
| POST | `/api/cosmetics/equip` | `{kind:"color"|"frame", id|null}` | `{me}` — 400 `bad_request` (kind, or the id is another kind), 404 `not_found`, 409 `not_owned` |

Cosmetics are bought with `POST /api/store/buy {sku: <cosmetic id>}` (`{me}`; 409 `owned`, 409 `not_for_sale` for earned-only ones, 409 `not_enough_salvage`). Achievements are checked inside every payout; each new one pays its salvage, may unlock a cosmetic, and is pushed as an `achievement` event (`rewards.achievements`), so `/api/location` toasts it and `/api/feed` keeps it. `callsign_color` (a cosmetic id or null) rides on leaderboard entries, `war.top`, clan members and chat messages, never on a Contact, battle or opponent. Schema 7 adds `players.callsign_color`, `players.avatar_frame` and the tables `counters`, `achievements`, `cosmetics`, `discoveries` (all cascade on account deletion); it backfills discoveries from held items and the counters from older tables.

### World events (DESIGN.md section 18)
| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/api/events` | | `{now, live: LiveEvent|null, upcoming:[{type, kind, starts_at, ends_at}], exchange: {open, min_level, items:[{sku, price, limit, bought, owned}]}}` — settles any ended event first |
| POST | `/api/events/exchange` | `{sku}` | `{rewards?, me}` — 404 `not_found`, 409 `no_event`, `locked` (below level 10), `sold_out`, `owned`, `not_enough_salvage`, `inventory_full` |

```ts
LiveEvent = { id, type: EventType, kind: string|null /* swarm archetype */, admin: boolean, starts_at, ends_at,
              active_players: number,
              goal: {target, progress, done},
              district: {id, target, progress, done}|null /* the district you stand in, once it has a goal */,
              mine: {n: number, tier: 0|1|2|3, next_at: number|null, goal_met: boolean} }
```

Events are rows in `world_events`: scheduled ones are made the first time anything looks at the
calendar (unique on `starts_at`), admin ones by `admin event start` or the dev endpoint. An admin event
replaces the running one, which ends then and is not remade. `settled` is set before the payouts in the
same transaction, so each event pays exactly once; housekeeping (`tick.zig`) and `GET /api/events` both
settle ended events and prune rows older than 60 days. Spawn changes are evaluated at the start of the
spawn window the id names (`spawns.idWindowStart`), so spawns stay pure and ids validate by recomputation.
Contributions are recorded as the actions happen (`worldevents.credit`) in `world_event_player` and
`world_event_district`; no positions are stored, only the district id an action happened in.

`/api/location` carries `event: {id, type, kind, starts_at, ends_at, target, progress, mine}|null` for the map banner. Payouts arrive as
an `event_reward` feed event whose `rewards` is a `Rewards` with `unlocks:[{kind:"cosmetic"|"title", id, name}]`.
`/api/catalog` (version 3) adds `events:[{id, names, blurb, unit, monthly, goal, per_player, min_target, tiers:[3], salvage:[3], consolation, cosmetic, title, mods}]`,
`event_exchange:{min_level, items:[{sku, names, text, price, limit}]}` and `cosmetics[].event` / `cosmetics[].exchange`. Schema 11 adds `world_events`,
`world_event_district`, `world_event_player`, `world_event_buys` and `event_titles`.

### Notes (docs/LORE.md)
| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/api/notes` | | `{sets:[{id, name, title, blurb, total, found, reward, claimed}], notes:[Note]}` — only the sets this faction can read (Patient Zero shows as `???` until its first piece); only found notes carry text, the rest are `{id, set, rarity, locked:true}` with the other fields null |
| POST | `/api/notes/claim` | `{set}` | `{rewards, title, me}` — a complete set pays salvage (sum of its notes: common 10, uncommon 20, rare 40, legendary 100) and its cosmetic title; 404 `not_found` (unknown set or not for your faction), 409 `set_incomplete`, 409 `already_claimed` |

**Drops.** One roll per payout, on its own random stream (item drops are unchanged by it), never a
note the player holds, never one their faction cannot read. Chances: supply cache 12%, landmark cache
25%, PvE win 3%, elite win 10%, airdrop 35%, every raid-kill contributor 100%. First Blood always
leaves `starlite.04`. Landmark kinds bias the set (pharmacy: Project Lantern, diner: Starlite, police:
Containment) and each "Along the Road" note comes only from its own kind of place. Patient Zero
pieces come only from airdrops, elites and raids, and only once the player holds at least half of
the other notes they can read. Found notes appear in `Rewards.notes`; deleting an account removes
them.

### Social and war (L10+ for clans)
| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/api/war` | | `{week, ends_at, global:{human,zombie}, district:{id, human, zombie}|null, top:[{callsign, level, title, points}], my_points}` |
| GET | `/api/leaderboard?board=weekly|contacts|level` | | `{entries:[{rank, callsign, level, title, faction, value, clan_tag}]}` |
| GET | `/api/feed` | | `{events:[Event]}` — the last 50 events |
| GET | `/api/clans?q=` | | `{clans:[{id, name, tag, members, level_sum, faction}]}` |
| POST | `/api/clans` | `{name, tag}` | `{clan, me}` |
| POST | `/api/clans/join` | `{id}` or `{code}` | `{clan, me}` |
| POST | `/api/clans/leave` | | `{me}` |
| GET | `/api/clan` | | `{clan:{id, name, tag, code, members:[{callsign, level, title, role, weekly_points}], strongholds, perks}}` |
| GET/POST | `/api/clan/chat` | `{text}` | `{messages:[{id, callsign, text, at}]}` |
| POST | `/api/stronghold/claim` | `{id, stance?}` | `{battles:[Battle], claimed, me}` — 409 `in_transit`, or `simulated_location` while the latest fix is flagged `mock` |
| POST | `/api/raid/attack` | `{id, stance?}` | `Battle` |

### Reports and suspensions
| Method | Path | Body | Returns |
|---|---|---|---|
| POST | `/api/report` | `{kind:"player"\|"clan"\|"message", target, reason:"name"\|"harassment"\|"cheating"\|"other", note?}` | `{ok}` |

`target` is the callsign for `player`, the clan id for `clan`, the message id for `message` (only
visible to, and so reportable by, members of that clan). `note` is at most 140 characters. Errors:
404 `not_found`, 400 `bad_request` (own callsign, bad reason, long note), 409 `already_reported` (one open
report per reporter per target), 429 `report_limit` (five an hour). Reports are stored in `reports`
and read with `outbreak-server admin reports`; there is no endpoint that lists them. Clan creation
with a blocked name or tag answers 400 `name_not_allowed` with the same plain message.

**Forced update.** The client sends its version (`package.json`, baked in at build time) in an
`X-Outbreak-Client: <semver>` header on every request. With `--min-client X.Y.Z` (or
`OUTBREAK_MIN_CLIENT`) the server answers an older client **426**
`{error:"update_required", message, min_client, store:{android, ios}|null}` to every request except
`GET /api/health` and `DELETE /api/account`. The store URLs come from `--store-android` /
`--store-ios` (either may be null). A request with **no** header (curl, the web dev build, a Patrol
check-in from a build that does not send one) or an unreadable one is always allowed. Versions compare
numerically (`0.10.0` is newer than `0.9.0`; a `-beta` or `+build` suffix is ignored). The client
also reads `min_client` from `/api/health` at boot and shows the full-screen "Update to keep playing"
(`src/shell/UpdateRequired.tsx`) on either signal. CORS allows the header.

**Crash and error reports.**

| Method | Path | Body | Returns |
|---|---|---|---|
| POST | `/api/client-error` | `{message, stack?, version?, platform?, screen?, ts?}` or `{reports:[...]}` (<= 10) | `{ok, stored}` |

Anonymous: a token is not needed and none is stored or logged; the server stamps its own time (`ts` is
ignored). `message` is cut to 500 bytes, `stack` to 4000, `version`/`platform`/`screen` to 32/16/32; a
report without a message is skipped. Both client and server scrub anything that could be a place
before it is kept: query strings and fragments on URLs, and decimals that look like a latitude or
longitude (up to three whole digits, four or more fractional ones). Rate limited by a bucket per
token (6 burst, one per 10 s), or one shared bucket for unauthenticated senders (30 burst, two a
second); 429 `rate_limited`, which the client ignores. Stored in `client_errors` (schema 8), capped
at the newest 5000 rows, grouped by a hash of the message (digit runs folded) plus the top stack frame
(`api/client_error.zig`). Read with `outbreak-server admin errors [--since 7d]`; `errors clear` empties
it. The client (`src/report/errors.ts`) catches `window` errors, unhandled rejections, Preact render
errors (`ErrorBoundary`, a plain "Something broke. Reload" card) and failed native plugin calls,
dedupes identical reports per session (and sends at most 25), batches them every 5 s, and drops them
silently when offline.

**Simulated locations.** `mock: true` on `/api/location` or `/api/patrol` marks a fix as coming from a
mock provider. The server keeps the flag on the in-memory position (never on disk); while it is set the
player is skipped by Contact matching (`tick.zig`), earns no walking XP (`acceptFix`) and no war
points (`rewards.apply`), and their snapshot is not served as an Echo for ten minutes
(`echo.zig`). `players.mock_sessions` / `players.mock_at` (schema 8) count sessions for `admin player`.
`me.simulated_location` (and `MeLite.simulated_location` in `/api/location`) is true while the
live position is flagged. Android reads the flag in `MockLocation.java` (called from the Patrol
plugin's `mockCheck` and from `PatrolService`), iOS in `PatrolPlugin.swift`; the client asks
`Patrol.mockCheck()` before each `/api/location` (`src/location/mock.ts`). The desktop simulator never
sets it, except the dev panel's "Report as mock GPS" box.

**Suspended accounts.** Every authenticated endpoint except `DELETE /api/account` answers **403** to a suspended player (they can always erase their account):

```json
{"error":"banned","message":"This account is suspended.","reason":"Cheating with a GPS spoofer","until":1793793600000}
```

`until` is unix ms, or `null` for a permanent suspension. The token stays valid (so the client can
keep showing the reason); a suspension that has run out simply stops applying. Suspended players are
left out of the leaderboards and war top lists, their stored snapshot is never chosen as an Echo or
garrison (an Echo already rolled from it is withdrawn), and their sessions get nothing else.
`players.banned_until` is `0` for none and the largest integer for permanent.

**Forced rename.** `admin rename` replaces the callsign with `Survivor####` and sets
`players.must_rename`; `Me.must_rename` is then `true` until the player posts a new callsign to
`POST /api/callsign`. The client shows the callsign screen at once.

### Dev only (`--dev`)
`POST /api/dev/grant {xp?, salvage?, item?:{base, rarity}, consumable?:{id, n}, note?: id | "all"}`,
`POST /api/dev/cosmetic_odds {scale}` (multiplies the chance of a found cosmetic: 1 is the designed rate, 1000
makes every airdrop, landmark or elite win carry one),
`POST /api/dev/heal`, `POST /api/dev/reset_cooldowns`, `POST /api/dev/bot_contact` (stages an
immediate Contact against a generated opponent so PvP can be tested alone; `POST /api/dev/down` puts the caller in Downed; `POST /api/dev/spawn_raid {hp?}` puts a raid boss at the stronghold of the cell the caller stands in, so raids can be tried on any day), `POST /api/dev/event {type, hours?, kind?}` and `POST /api/dev/event_stop` (the same as `admin event start` and `stop`).

### Shapes

```ts
Stats = { hp: number, atk: number, def: number, spd: number }

Item = { uid: string, base: string, slot: Slot, rarity: "common"|"uncommon"|"rare"|"legendary",
         upgrade: number, perks: string[], unique: string|null, req: number,
         stats: Stats /* final, incl. rarity+upgrade */, power: number, scrap_value: number,
         upgrade_cost: number|null /* null at +10 */ }

Me = { id, callsign: string|null, must_rename: boolean, faction: Faction|null, level, xp, xp_next, title,
       hp, max_hp, downed_until: number|null, stats: Stats /* total */, base_stats: Stats,
       salvage, inventory_cap, equipped: {weapon: uid|null, armor: uid|null, utility: uid|null},
       items: Item[], consumables: Record<string, number>,
       abilities: { unlocked: string[], equipped: string[], slots: number },
       buffs: {kind: string, until: number}[],
       missions: { daily: Mission[], weekly: Mission|null, streak: number, resets_at: number },
       clan: {id, name, tag, role}|null, avatar: object|null,
       pvp_protected: boolean, underdog_bonus: number, war_points_week: number,
       stance: Stance, bestiary: Record<string, number> /* fights per archetype */,
       record: { wins, losses, contacts, contacts_won, contacts_lost, echoes, echoes_won, caches, distance_m },
       contact_rank: { name, tier: 0..5, wins, next_at: number|null, next_name: string|null }, // lifetime Contact wins
       account: { guest: boolean, providers: ("google"|"apple"|"dev")[], email: string|null },
       terms: { current: number, accepted: number /* 0: never */, needs_accept: boolean },
       notes: { found: number, total: number /* notes this faction can find */ },
       titles_extra: string[] /* cosmetic titles from claimed note sets and achievements */,
       cosmetics: {owned:[ids], color:id|null, frame:id|null}, achievements: {earned, total},
       token_xp: number /* what an XP token is worth now */ }

Mission = { id, kind, text, target, progress, rewards: Rewards, claimed: boolean }

WorldView = { now, me: MeLite /* hp, max_hp, downed_until, level, xp, xp_next, salvage */,
  hostiles_near: boolean,
  in_transit: boolean, // moving faster than walking pace: fights wait (see In transit)
  enemies: {id, archetype, level, elite, tutorial: boolean, lat, lon, expires_at}[], // undefeated only
  caches: {id, kind:"cache"|"airdrop", lat, lon, expires_at}[],        // unopened only
  echoes: {id, level, faction, title, rogue: boolean, lat, lon, expires_at}[],
  landmarks: {id, kind: PlaceKind, name: string|null, lat, lon, available: boolean, available_at: number|null}[],
  time: {phase: "day"|"night", changes_at: number},
  strongholds: {id, lat, lon, clan: {tag, name, faction}|null}[],
  raids: {id, boss, lat, lon, hp, max_hp, ends_at, fighters, can_attack_at}[],
  events: Event[] /* undelivered; delivered once, also if a Patrol check-in already notified them */ }

Combatant = { name, faction, level, title, kind: "player"|"enemy"|"echo"|"rogue"|"boss",
              archetype: string|null, max_hp, hp_start, stats: Stats,
              abilities: string[], gear: string[] /* display names */,
              gear_detail: {slot, name, rarity, upgrade, unique: boolean}[] /* the kit in its wearer's own faction names; no ids, no stats */,
              stance: Stance|null /* real players only (Contact) */ }

Turn = { actor: "a"|"b", ev: "hit"|"crit"|"dodge"|"ability"|"dot"|"heal"|"revive",
         ability: string|null, dmg: number, heal: number, hp_a: number, hp_b: number }

Stance = "aggressive"|"careful"|"evasive"
PlaceKind = "pharmacy"|"grocery"|"hardware"|"fuel"|"police"|"outfitter"|"diner"

Battle = { id, stance: Stance, kind: "pve"|"pvp"|"echo"|"raid"|"garrison", a: Combatant /* always you */,
           b: Combatant, turns: Turn[], winner: "a"|"b", rewards: Rewards, me: Me }

Rewards = { xp, salvage, items: Item[], consumables: Record<string,number>, war_points,
            level_up: {from, to, unlocks: string[]}|null,
            notes: {id, title, set, rarity, form}[] /* found with this payout */ }

Note = { id, set, rarity, locked: boolean, title, author, date, form, body, found_at }
       /* form: notebook|memo|email|chat|receipt|sticky|radio|poster|letter|review|card */

Event = { id, at, type: "contact"|"echo_report"|"level_up"|"raid"|"war_result"|"clan"|"event_reward",
          text: string, battle?: Battle, rewards?: Rewards }
```

`/api/catalog` (version 2) also carries `stances`, `places` and per-enemy `counter`, `punished`, `hint`, `hint_zombie`. It returns `{version, items:[{id, slot, req, names:{human, zombie}, stats}],
uniques:[{id, base, names, lore, perks}], rarities, perks:[{id, name, text}],
consumables:[{id, names, text, price}], abilities:[{id, level, names, text}],
enemies:[{id, names, text}], levels:{xp_to_next:[...], titles:{human:[], zombie:[]},
unlocks:[{level, key, text}]}, store:[{sku, name, price, text}],
achievements:[{id, group, names, text, metric, need, salvage, title:{human,zombie}|null, cosmetic:id|null}],
cosmetics:[{id, kind:"color"|"frame", names, text, price, found, survey, heat, unlock:achievementId|null}],
avatar_looks:[{index, level, names:{human, zombie}}]}`. `found` marks the drop-only cosmetics (price 0, no `unlock`).
`Rewards` also carries `cosmetics:[{id, kind, duplicate, salvage}]`: the cosmetics found with that payout, where a
`duplicate` was already owned and became `salvage` (counted in `Rewards.salvage`). Caches, airdrops, landmark
caches, elite wins and raid kills can carry one; a new one is owned at once.

`levels.unlocks` is the one unlock table (`data.unlocks`): `key` is a stable name (`store`, `contact`, `raids`, ...), `text` is
what the level-up screen lists. Several rows can share a level (level 5 has three). The client keys its first-time
explainers on `key`; their wording is client copy, and which ones were shown is stored on the device only.

### Contact rank and the `contacts` board

Contact rank is lifetime Contact wins (Echo and Rogue wins do not count): Human Unbloodied 0, Blooded 1,
Tracker 5, Veteran 15, Warden 40, Legend 100; Zombie Unfed, Blooded, Stalker, Ravener, Apex, Legend.
`record.contacts_won/contacts_lost` count real-world fights only; `echoes_won` counts Echo wins.
`GET /api/leaderboard?board=contacts` is this week's Contact wins (table `contact_week`). An opponent's
`gear_detail` and `stance` carry no identity: only what is worn (and how they fought), never a name,
avatar, clan, place or history with the viewer. Echoes are labelled `echo`, rogues `rogue`.
