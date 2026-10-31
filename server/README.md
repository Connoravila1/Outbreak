# Outbreak server

One static binary: the HTTP API, the game tick, and an SQLite database. The pure game rules live
in `src/game/`; everything else here is the shell around them.

## Run

    zig build run -- --dev          # dev server on :8080 with /api/dev/* and relaxed rate limits
    zig build test                  # game core and server tests (no sockets needed)
    zig build sim                   # balance simulator
    scripts/smoke.sh                # start the built binary on a temp dir and curl the main flow
    zig build dist                  # static ReleaseSafe binaries in zig-out/dist/{x86_64,aarch64}

Zig 0.16 is required. SQLite is vendored in `vendor/sqlite/`; nothing else is downloaded.

## Config

| Flag      | Env              | Default  |
|-----------|------------------|----------|
| `--port`  | `OUTBREAK_PORT`  | `8080`   |
| `--bind`  | `OUTBREAK_BIND`  | `0.0.0.0`|
| `--data`  | `OUTBREAK_DATA`  | `./data` |
| `--dev`   | `OUTBREAK_DEV=1` | off      |
| `--google-client-ids` | `OUTBREAK_GOOGLE_CLIENT_IDS` | none (Google sign-in off) |
| `--apple-audiences`   | `OUTBREAK_APPLE_AUDIENCES`   | none (Apple sign-in off)  |

Flags override environment variables. `--dev` enables `/api/dev/*` (grants, healing, staged
contacts) and loosens rate limits. Never run it on a public server.

Sign-in: `--google-client-ids` takes the OAuth client IDs as a comma list, **web first**, then the
Android and iOS ones. `--apple-audiences` takes the iOS bundle id (`com.outbreak.game`) and the web
Services ID. A provider with no IDs answers `503 provider_not_configured` and `/api/health` tells the
client to hide its button. With `--dev` there is also a `dev` provider that needs no real account.
`--google-jwks-url` / `--apple-jwks-url` override where signing keys are fetched (testing only).
Step by step setup: `docs/ACCOUNTS_SETUP.md`.

The server logs one line per request (method, path, status, milliseconds). Positions and tokens are
never logged.

## Data

Everything lives in `<data>/outbreak.db` (SQLite, WAL mode). Player positions are held in memory
only and are deliberately never written to disk; after a restart players reappear with their next
location update. The world seed is created on first start and stored in the database, so keep the
database if you want the same world.

## Moderation

Moderation is a command on the same binary. It works on the database file directly, so it is safe
while the server runs (SQLite WAL, with a busy timeout), and there is no admin page on the network.
`--data` is the same folder the server uses (default `./data`, or `OUTBREAK_DATA`).

    outbreak-server admin --data /opt/outbreak/data reports

| Command | What it does |
|---|---|
| `reports` | Open reports in two tables: one row per target with a count and the reasons, then every report (ID, time, target, reason, reporter, note; a message report shows the message id and what was said). |
| `player <callsign>` | Account summary: faction, level, sign-in type (guest or provider; no email), clan, record, suspension, reports about and by them. No positions and no fight history. |
| `rename <callsign>` | Replaces the callsign with `Survivor####` and flags the player to choose a new one on their next launch (the app asks at once if it is open). |
| `clan-rename <tag>` | Replaces a clan's name and tag with `Clan ###` / `C###`. |
| `delete-message <id>` | Removes one clan chat message. The ids are in `reports`. |
| `ban <callsign> [--days N] [--reason "text"]` | Suspends the account (for good unless `--days`). The player sees the reason and end date; every request from their phone gets 403; their Echo stops being served and they leave the leaderboards. |
| `unban <callsign>` | Lifts a suspension. |
| `resolve <report-id>` | Closes one report without acting on it. |
| `help` | Prints the list. |

`rename`, `clan-rename`, `delete-message` and `ban` also close the open reports about what they acted
on. Callsigns are not case sensitive; a clan tag may be given with or without brackets. Every command
prints what it did in plain words and exits with status 1 and a sentence when something is wrong
(unknown callsign, a bad number). Times are UTC. Step by step guide: `docs/MODERATING.md`.

Players can report from the leaderboards, clan rosters, clan list and clan chat
(`POST /api/report`, five an hour, one open report per reporter per target). Names are checked
against the list in `src/names.zig` when a callsign or clan is created.

## Backup

Online, while the server runs:

    sqlite3 /opt/outbreak/data/outbreak.db ".backup '/backups/outbreak-$(date +%F).db'"

Or stop the service and copy `outbreak.db` (plus `-wal` and `-shm` if present).

## Host your own server

1. `zig build dist` and copy `zig-out/dist/<arch>/outbreak-server` to `/opt/outbreak/`.
2. Install `deploy/outbreak.service` (runs as user `outbreak`, bound to `127.0.0.1:8080`, data in
   `/opt/outbreak/data`) and `systemctl enable --now outbreak`.
3. Put `deploy/Caddyfile` in front of it with your domain; Caddy handles HTTPS.
4. Point the client's server URL at `https://your.domain`.
