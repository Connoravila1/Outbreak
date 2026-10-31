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
    haversine), `spawns.zig` (deterministic world content), `missions.zig`, `war.zig`, `rng.zig`, `stance.zig` (stance, counters), `daynight.zig` (solar phase), `landmarks.zig` (place validation, windows, rate limit).
  - `src/live.zig` — in-memory state: latest position per player (never persisted, expires in
    2 min), active echoes, rate limits, and reported landmarks per geohash-6 area (12 h TTL, capped, never persisted).
  - `src/tick.zig` — every 5 s: PvP contact matching, raid/war housekeeping.
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

- Vite + Preact + TypeScript. MapLibre GL JS with OpenFreeMap vector tiles (no key; can be
  self-hosted later with a PMTiles file) and a custom dark style.
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
| GET | `/api/health` | | `{ok, version, players_online, providers:{google, apple, dev, google_web_client_id?, apple_web_service_id?}}` — which sign-ins this server offers, and the IDs a browser needs |
| GET | `/api/catalog` | | static game data (below); cacheable by `version` |
| GET | `/api/factions` | | `{human:{share, players}, zombie:{...}, underdog:"human"|"zombie"|null, underdog_bonus}` |
| POST | `/api/register` | `{}` (optional `{callsign}`) | `{token, me}` — creates a **guest**: a player with no sign-in identity |
| POST | `/api/callsign` | `{callsign}` | `{me}` — once only, same rules as before; 409 `callsign_set`, `callsign_taken`; 400 `callsign_invalid` |
| POST | `/api/faction` | `{faction}` | `{me}` — once only; 409 `already_chosen`. Works before or after the callsign |
| POST | `/api/auth/{google\|apple}` | `{id_token, nonce?, switch?}` + optional `Authorization` of the current player | `{token, me, created}` — see below |
| POST | `/api/auth/link/{google\|apple}` | `{id_token, nonce?}` (auth) | `{me}` — 409 `identity_in_use` (taken by another player), 409 `already_linked` (this player already has that provider) |
| POST | `/api/auth/unlink/{provider}` | | `{me}` — 404 `not_linked`; 409 `last_identity` for the only identity |
| DELETE | `/api/account` | | `{ok}` — deletes the player and everything owned (auth) |
| GET | `/api/me` | | `Me` |
| POST | `/api/avatar` | `{avatar:{...}}` | `{me}` |

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
| POST | `/api/location` | `{lat, lon, acc, sanctuary, places?:[{key, kind, lat, lon, name?}]}` (<= 40) | `WorldView` — call every ~5 s in foreground |
| POST | `/api/engage` | `{id, stance?}` (enemy spawn or echo id; stance `aggressive`/`careful`/`evasive`, default careful) | `Battle` |
| POST | `/api/stance` | `{stance}` (default for Contact PvP) | `{me}` |
| POST | `/api/open` | `{id}` (cache, airdrop or landmark id; 409 `landmark_limit`) | `{loot: Rewards, me}` |

### Gear and character
| Method | Path | Body | Returns |
|---|---|---|---|
| POST | `/api/equip` | `{uid}` | `{me}` |
| POST | `/api/unequip` | `{slot}` | `{me}` |
| POST | `/api/scrap` | `{uids:[...]}` | `{salvage_gained, me}` |
| POST | `/api/upgrade` | `{uid}` | `{me}` |
| POST | `/api/use` | `{consumable}` | `{me}` |
| POST | `/api/abilities` | `{equipped:[ids]}` | `{me}` |
| POST | `/api/missions/claim` | `{id}` | `{rewards, me}` |
| POST | `/api/store/buy` | `{sku}` | `{rewards?, me}` |

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
| POST | `/api/stronghold/claim` | `{id, stance?}` | `{battles:[Battle], claimed, me}` |
| POST | `/api/raid/attack` | `{id, stance?}` | `Battle` |

### Dev only (`--dev`)
`POST /api/dev/grant {xp?, salvage?, item?:{base, rarity}, consumable?:{id, n}}`,
`POST /api/dev/heal`, `POST /api/dev/reset_cooldowns`, `POST /api/dev/bot_contact` (stages an
immediate Contact against a generated opponent so PvP can be tested alone; `POST /api/dev/down` puts the caller in Downed; `POST /api/dev/spawn_raid {hp?}` puts a raid boss at the stronghold of the cell the caller stands in, so raids can be tried on any day).

### Shapes

```ts
Stats = { hp: number, atk: number, def: number, spd: number }

Item = { uid: string, base: string, slot: Slot, rarity: "common"|"uncommon"|"rare"|"legendary",
         upgrade: number, perks: string[], unique: string|null, req: number,
         stats: Stats /* final, incl. rarity+upgrade */, power: number, scrap_value: number,
         upgrade_cost: number|null /* null at +10 */ }

Me = { id, callsign: string|null, faction: Faction|null, level, xp, xp_next, title,
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
       account: { guest: boolean, providers: ("google"|"apple"|"dev")[], email: string|null } }

Mission = { id, kind, text, target, progress, rewards: Rewards, claimed: boolean }

WorldView = { now, me: MeLite /* hp, max_hp, downed_until, level, xp, xp_next, salvage */,
  hostiles_near: boolean,
  enemies: {id, archetype, level, elite, tutorial: boolean, lat, lon, expires_at}[], // undefeated only
  caches: {id, kind:"cache"|"airdrop", lat, lon, expires_at}[],        // unopened only
  echoes: {id, level, faction, title, rogue: boolean, lat, lon, expires_at}[],
  landmarks: {id, kind: PlaceKind, name: string|null, lat, lon, available: boolean, available_at: number|null}[],
  time: {phase: "day"|"night", changes_at: number},
  strongholds: {id, lat, lon, clan: {tag, name, faction}|null}[],
  raids: {id, boss, lat, lon, hp, max_hp, ends_at, fighters, can_attack_at}[],
  events: Event[] /* undelivered; delivered once */ }

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
            level_up: {from, to, unlocks: string[]}|null }

Event = { id, at, type: "contact"|"echo_report"|"level_up"|"raid"|"war_result"|"clan",
          text: string, battle?: Battle, rewards?: Rewards }
```

`/api/catalog` (version 2) also carries `stances`, `places` and per-enemy `counter`, `punished`, `hint`, `hint_zombie`. It returns `{version, items:[{id, slot, req, names:{human, zombie}, stats}],
uniques:[{id, base, names, lore, perks}], rarities, perks:[{id, name, text}],
consumables:[{id, names, text, price}], abilities:[{id, level, names, text}],
enemies:[{id, names, text}], levels:{xp_to_next:[...], titles:{human:[], zombie:[]},
unlocks:[{level, text}]}, store:[{sku, name, price, text}]}`.

### Contact rank and the `contacts` board

Contact rank is lifetime Contact wins (Echo and Rogue wins do not count): Human Unbloodied 0, Blooded 1,
Tracker 5, Veteran 15, Warden 40, Legend 100; Zombie Unfed, Blooded, Stalker, Ravener, Apex, Legend.
`record.contacts_won/contacts_lost` count real-world fights only; `echoes_won` counts Echo wins.
`GET /api/leaderboard?board=contacts` is this week's Contact wins (table `contact_week`). An opponent's
`gear_detail` and `stance` carry no identity: only what is worn (and how they fought), never a name,
avatar, clan, place or history with the viewer. Echoes are labelled `echo`, rogues `rogue`.
