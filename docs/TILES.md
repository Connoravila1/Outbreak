# Self-hosted map tiles

By default the client draws its map from OpenFreeMap (`https://tiles.openfreemap.org/planet`, no key).
A server operator can instead point every client at a **PMTiles** archive of their own region:
one file, no tile server, read with HTTP range requests.

Nothing here is required to play. Without it the game behaves exactly as before.

## What the server does

| Flag | Environment | Effect |
|---|---|---|
| `--tiles FILE.pmtiles` | `OUTBREAK_TILES` | The server serves the file itself at `GET /tiles/map.pmtiles` with `Range` support (single ranges, answers capped at 8 MiB, CORS open). `/api/health` advertises it. |
| `--tiles-url URL` | `OUTBREAK_TILES_URL` | The archive is hosted elsewhere (Caddy `file_server`, nginx, S3/R2, any static host that supports range requests). `/api/health` advertises the URL. Ignored when `--tiles` is set. |
| `--tiles-glyphs URL` | `OUTBREAK_TILES_GLYPHS` | Optional font URL template (`https://host/fonts/{fontstack}/{range}.pbf`) for fully offline hosting. Default: OpenFreeMap's. |

`GET /api/health` then carries `"tiles": {"pmtiles": "/tiles/map.pmtiles", "glyphs": null}` (otherwise
`"tiles": null`). A path is relative to the server address the client already uses; a full URL is used as is.

The client reads this at start-up (and again after signing in or changing the server address), and every
map created afterwards uses `pmtiles://<url>` through MapLibre and the `pmtiles` protocol. If the server
says nothing, or the check fails, it uses OpenFreeMap. The attribution control stays on either way.

## The schema must be OpenMapTiles

The map styles (`client/src/map/styles/`) and the sanctuary and place detection (`map/sanctuary.ts`,
`map/places.ts`) read the **OpenMapTiles** schema: layers `water`, `landcover`, `landuse`, `park`,
`transportation`, `building`, `poi`, `place`, ... OpenFreeMap serves exactly that.

The **Protomaps basemap tiles use a different schema** (`earth`, `roads`, `pois`, ...) and will draw nothing
useful here. Do not extract from a Protomaps daily build. Use an archive built with the OpenMapTiles
profile, for example:

- **Planetiler** (Apache-2.0) builds a regional OpenMapTiles archive straight from an OSM extract. Its
  default profile is OpenMapTiles, and the output can be `.pmtiles`.
- Any other OpenMapTiles-schema PMTiles planet or country build you are licensed to use.

## Making a regional extract

Tools you install yourself (this repository downloads nothing):

- the [`pmtiles` CLI](https://github.com/protomaps/go-pmtiles) (BSD-3-Clause), and
- either Planetiler plus a Geofabrik `.osm.pbf`, or an existing OpenMapTiles-schema PMTiles archive.

### A. Cut a region out of an OpenMapTiles-schema planet archive

```sh
# bbox is min_lon,min_lat,max_lon,max_lat; --maxzoom 15 is plenty (the game map stops at z19.5 and
# MapLibre overzooms the last level)
pmtiles extract https://example.org/openmaptiles-planet.pmtiles seattle.pmtiles \
  --bbox=-122.55,47.45,-122.10,47.80 --maxzoom=15
pmtiles show seattle.pmtiles          # check bounds, zooms, and that the layers are OpenMapTiles
```

`pmtiles extract` reads only the needed ranges from a remote archive, so you never download the planet.
You can also extract from a local planet file, or give a GeoJSON region with `--region=area.geojson`
instead of `--bbox`.

### B. Build a region yourself with Planetiler

```sh
java -Xmx4g -jar planetiler.jar --download --area=washington --output=washington.pmtiles
```

(`--download` fetches the OSM extract and the helper data Planetiler needs; run it on your own machine.)
A city or a state is a few hundred MB; a country a few GB. Keep it as small as your players need: the
map only draws within the zooms the game uses (12 to 19.5), so `--maxzoom=15` keeps the file small.

### Serve it

```sh
outbreak-server --data ./data --tiles /srv/outbreak/region.pmtiles
# or, hosted elsewhere:
outbreak-server --data ./data --tiles-url https://tiles.example.com/region.pmtiles
```

Behind Caddy, nothing changes: `/tiles/*` goes to the game server like `/api/*`. Tiles are cacheable
(`Cache-Control: public, max-age=3600`), so a CDN in front helps big communities.

Check from a shell:

```sh
curl -s localhost:8080/api/health            # ... "tiles":{"pmtiles":"/tiles/map.pmtiles","glyphs":null}
curl -s -H 'Range: bytes=0-16383' -D- -o /dev/null localhost:8080/tiles/map.pmtiles   # 206, Content-Range
```

## Limits and notes

- Players outside the extract see an empty map (the game still runs: it only uses the map for look and for
  sanctuary and place detection, and those fall back to "none" where there are no tiles).
- Place and sanctuary detection use whatever the `poi` and `landuse` layers hold, so an extract built
  without those layers loses sanctuaries and real-place spawns. Planetiler's OpenMapTiles profile has them.
- The glyph (font) files are small and cached by the app; the default keeps using OpenFreeMap's. Host your
  own with `--tiles-glyphs` if the server must not talk to any third party.
- On native builds, range requests ride through `CapacitorHttp` like every other call. Verify on a device
  with a self-hosted archive before relying on it (see the checklist in `client/MOBILE.md`).

## Attribution

Map data is © OpenStreetMap contributors (ODbL), and the schema and styles derive from OpenMapTiles.
The in-app attribution control and the split-lens credit line stay on regardless of the tile source.
If you publish an archive, carry the same credit with it. See `ATTRIBUTIONS.md`.
