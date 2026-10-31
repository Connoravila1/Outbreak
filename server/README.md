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

Flags override environment variables. `--dev` enables `/api/dev/*` (grants, healing, staged
contacts) and loosens rate limits. Never run it on a public server.

The server logs one line per request (method, path, status, milliseconds). Positions and tokens are
never logged.

## Data

Everything lives in `<data>/outbreak.db` (SQLite, WAL mode). Player positions are held in memory
only and are deliberately never written to disk; after a restart players reappear with their next
location update. The world seed is created on first start and stored in the database, so keep the
database if you want the same world.

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
