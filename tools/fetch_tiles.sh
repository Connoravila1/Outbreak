#!/usr/bin/env bash
# Dev-only tile fetcher. Pulls the raster tiles around LAT LON into the local
# cache the desktop build reads (~/.cache/outbreak/tiles). For development only --
# in production tiles come through our own server so no third party ever sees
# which cell a player is standing in.
#
#   tools/fetch_tiles.sh 40.7580 -73.9855
#
set -euo pipefail
LAT=${1:?usage: fetch_tiles.sh LAT LON [ZOOM]}
LON=${2:?usage: fetch_tiles.sh LAT LON [ZOOM]}
Z=${3:-16}

# Slippy-map tile numbers for the coordinate.
read -r XT YT <<<"$(python3 -c "
import math, sys
lat, lon, z = float('$LAT'), float('$LON'), int('$Z')
n = 2 ** z
xt = int((lon + 180) / 360 * n)
lr = math.radians(lat)
yt = int((1 - math.log(math.tan(lr) + 1/math.cos(lr)) / math.pi) / 2 * n)
print(xt, yt)
")"

DIR="$HOME/.cache/outbreak/tiles"
# A phone-shaped window at z16 spans a few tiles; fetch a generous patch.
for dx in -1 0 1; do
    for dy in -2 -1 0 1 2; do
        x=$((XT + dx)); y=$((YT + dy))
        out="$DIR/$Z/$x/$y.png"
        [ -f "$out" ] && continue
        mkdir -p "$DIR/$Z/$x"
        curl -sf -A "outbreak-dev/0.1 (local development)" \
            -o "$out" "https://tile.openstreetmap.org/$Z/$x/$y.png" \
            && echo "  $Z/$x/$y" || echo "  FAILED $Z/$x/$y"
    done
done
echo "cache: $DIR"
