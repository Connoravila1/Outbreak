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
  - `src/db.zig` — thin SQLite wrapper (prepare/bind/step), schema + migrations by `user_version`.
  - `src/game/` — **pure** game logic, no I/O, fully unit-tested: `data.zig` (catalogue from
    DESIGN.md), `stats.zig`, `combat.zig`, `loot.zig`, `progression.zig`, `geo.zig` (geohash,
    haversine), `spawns.zig` (deterministic world content), `missions.zig`, `war.zig`, `rng.zig`.
  - `src/live.zig` — in-memory state: latest position per player (never persisted, expires in
    2 min), active echoes, rate limits.
  - `src/tick.zig` — every 5 s: PvP contact matching, raid/war housekeeping.
  - `src/sim.zig` — balance simulator (`zig build sim`): simulates players and prints pacing.
- **Concurrency**: one global mutex around game state and the single SQLite connection. Correct
  and fast enough for thousands of players; revisit only with evidence.
- **Persistence**: SQLite in WAL mode at `--data <dir>/outbreak.db`. Positions are never stored.
- **Determinism**: world content = f(server_seed, cell, window). `server_seed` is created on first
  start and stored in the DB. Combat = f(seed) and is reproducible from the stored seed.
- **Config**: `--port` (8080), `--bind` (0.0.0.0), `--data` (./data), `--dev` (enables `/api/dev/*`
  and relaxed rate limits). Same as env vars `OUTBREAK_PORT`, etc.
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
| GET | `/api/health` | | `{ok, version, players_online}` |
| GET | `/api/catalog` | | static game data (below); cacheable by `version` |
| GET | `/api/factions` | | `{human:{share, players}, zombie:{...}, underdog:"human"|"zombie"|null, underdog_bonus}` |
| POST | `/api/register` | `{callsign}` | `{token, recovery_code, me}` |
| POST | `/api/recover` | `{recovery_code}` | `{token, me}` |
| POST | `/api/faction` | `{faction}` | `{me}` — once only; 409 `already_chosen` |
| GET | `/api/me` | | `Me` |
| POST | `/api/avatar` | `{avatar:{...}}` | `{me}` |

### World
| Method | Path | Body | Returns |
|---|---|---|---|
| POST | `/api/location` | `{lat, lon, acc, sanctuary}` | `WorldView` — call every ~5 s in foreground |
| POST | `/api/engage` | `{id}` (enemy spawn or echo id) | `Battle` |
| POST | `/api/open` | `{id}` (cache or airdrop id) | `{loot: Rewards, me}` |

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
| GET | `/api/leaderboard?board=weekly|level` | | `{entries:[{rank, callsign, level, title, faction, value, clan_tag}]}` |
| GET | `/api/feed` | | `{events:[Event]}` — the last 50 events |
| GET | `/api/clans?q=` | | `{clans:[{id, name, tag, members, level_sum, faction}]}` |
| POST | `/api/clans` | `{name, tag}` | `{clan, me}` |
| POST | `/api/clans/join` | `{id}` or `{code}` | `{clan, me}` |
| POST | `/api/clans/leave` | | `{me}` |
| GET | `/api/clan` | | `{clan:{id, name, tag, code, members:[{callsign, level, title, role, weekly_points}], strongholds, perks}}` |
| GET/POST | `/api/clan/chat` | `{text}` | `{messages:[{id, callsign, text, at}]}` |
| POST | `/api/stronghold/claim` | `{id}` | `{battles:[Battle], claimed, me}` |
| POST | `/api/raid/attack` | `{id}` | `Battle` |

### Dev only (`--dev`)
`POST /api/dev/grant {xp?, salvage?, item?:{base, rarity}, consumable?:{id, n}}`,
`POST /api/dev/heal`, `POST /api/dev/reset_cooldowns`, `POST /api/dev/bot_contact` (stages an
immediate Contact against a generated opponent so PvP can be tested alone).

### Shapes

```ts
Stats = { hp: number, atk: number, def: number, spd: number }

Item = { uid: string, base: string, slot: Slot, rarity: "common"|"uncommon"|"rare"|"legendary",
         upgrade: number, perks: string[], unique: string|null, req: number,
         stats: Stats /* final, incl. rarity+upgrade */, power: number, scrap_value: number,
         upgrade_cost: number|null /* null at +10 */ }

Me = { id, callsign, faction: Faction|null, level, xp, xp_next, title,
       hp, max_hp, downed_until: number|null, stats: Stats /* total */, base_stats: Stats,
       salvage, inventory_cap, equipped: {weapon: uid|null, armor: uid|null, utility: uid|null},
       items: Item[], consumables: Record<string, number>,
       abilities: { unlocked: string[], equipped: string[], slots: number },
       buffs: {kind: string, until: number}[],
       missions: { daily: Mission[], weekly: Mission|null, streak: number, resets_at: number },
       clan: {id, name, tag, role}|null, avatar: object|null,
       pvp_protected: boolean, underdog_bonus: number, war_points_week: number }

Mission = { id, kind, text, target, progress, rewards: Rewards, claimed: boolean }

WorldView = { now, me: MeLite /* hp, max_hp, downed_until, level, xp, xp_next, salvage */,
  hostiles_near: boolean,
  enemies: {id, archetype, level, elite, lat, lon, expires_at}[],      // undefeated only
  caches: {id, kind:"cache"|"airdrop", lat, lon, expires_at}[],        // unopened only
  echoes: {id, level, faction, title, rogue: boolean, lat, lon, expires_at}[],
  strongholds: {id, lat, lon, clan: {tag, name, faction}|null}[],
  raids: {id, boss, lat, lon, hp, max_hp, ends_at, fighters, can_attack_at}[],
  events: Event[] /* undelivered; delivered once */ }

Combatant = { name, faction, level, title, kind: "player"|"enemy"|"echo"|"rogue"|"boss",
              archetype: string|null, max_hp, hp_start, stats: Stats,
              abilities: string[], gear: string[] /* display names */ }

Turn = { actor: "a"|"b", ev: "hit"|"crit"|"dodge"|"ability"|"dot"|"heal"|"revive",
         ability: string|null, dmg: number, heal: number, hp_a: number, hp_b: number }

Battle = { id, kind: "pve"|"pvp"|"echo"|"raid"|"garrison", a: Combatant /* always you */,
           b: Combatant, turns: Turn[], winner: "a"|"b", rewards: Rewards, me: Me }

Rewards = { xp, salvage, items: Item[], consumables: Record<string,number>, war_points,
            level_up: {from, to, unlocks: string[]}|null }

Event = { id, at, type: "contact"|"echo_report"|"level_up"|"raid"|"war_result"|"clan",
          text: string, battle?: Battle, rewards?: Rewards }
```

`/api/catalog` returns `{version, items:[{id, slot, req, names:{human, zombie}, stats}],
uniques:[{id, base, names, lore, perks}], rarities, perks:[{id, name, text}],
consumables:[{id, names, text, price}], abilities:[{id, level, names, text}],
enemies:[{id, names, text}], levels:{xp_to_next:[...], titles:{human:[], zombie:[]},
unlocks:[{level, text}]}, store:[{sku, name, price, text}]}`.
