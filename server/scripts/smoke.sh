#!/usr/bin/env bash
# Start the server with --dev on a temp data dir and walk the main flow with curl.
# Usage: scripts/smoke.sh [path/to/outbreak-server]   (build first: zig build)
set -u
cd "$(dirname "$0")/.."
BIN="${1:-zig-out/bin/outbreak-server}"
PORT="${PORT:-18081}"
DATA="$(mktemp -d)"
LOG="$DATA/server.log"
BASE="http://127.0.0.1:$PORT"
fails=0

"$BIN" --dev --port "$PORT" --bind 127.0.0.1 --data "$DATA" >"$LOG" 2>&1 &
PID=$!
cleanup() { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; rm -rf "$DATA"; }
trap cleanup EXIT

for _ in $(seq 50); do
  curl -s -o /dev/null "$BASE/api/health" && break
  sleep 0.1
done

# call METHOD PATH EXPECTED_STATUS [TOKEN] [BODY]; the response body lands in $BODY_OUT.
call() {
  local method=$1 path=$2 want=$3 token=${4:-} body=${5:-}
  local args=(-s -o "$DATA/body" -w '%{http_code}' -X "$method" "$BASE$path")
  [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' -d "$body")
  local got
  got=$(curl "${args[@]}")
  BODY_OUT=$(cat "$DATA/body")
  if [ "$got" = "$want" ]; then echo "ok   $method $path -> $got"; else echo "FAIL $method $path -> $got (wanted $want): $BODY_OUT"; fails=$((fails + 1)); fi
}
field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" <<<"$BODY_OUT" | head -1; }

call GET /api/health 200
call GET /api/catalog 200
call GET /api/factions 200
call GET /api/me 401
call GET /api/nope 404
call POST /api/register 200 "" '{"callsign":"Smoke","terms":1}'
TOKEN=$(field token)
[ -n "$TOKEN" ] || { echo "FAIL no token in register response"; exit 1; }
call POST /api/faction 200 "$TOKEN" '{"faction":"human"}'
call GET /api/me 200 "$TOKEN"
call POST /api/dev/grant 200 "$TOKEN" '{"xp":2000,"salvage":100}'
call POST /api/location 200 "$TOKEN" '{"lat":51.5,"lon":-0.12,"acc":5,"sanctuary":false}'
call GET /api/feed 200 "$TOKEN"
call GET /api/leaderboard 200 "$TOKEN"
call GET /api/war 200 "$TOKEN"
call POST /api/dev/bot_contact 200 "$TOKEN" '{}'
call POST /api/location 200 "$TOKEN" '{"lat":51.5,"lon":-0.12,"acc":5,"sanctuary":false}'
call POST /api/use 409 "$TOKEN" '{"consumable":"flag"}'
call OPTIONS /api/me 204

grep -qiE 'token|51\.5' "$LOG" && { echo "FAIL the log mentions a token or a position"; fails=$((fails + 1)); }

if [ "$fails" -eq 0 ]; then echo "smoke: all passed"; else echo "smoke: $fails failed"; exit 1; fi
