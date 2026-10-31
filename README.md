# Outbreak: Humanity's Last Stand

The outbreak is in your neighbourhood. Choose a side: fight to stay human, or let the infection in.
The choice is permanent.

Outbreak is a real-world GPS game. Walk your own streets to hunt, scavenge and fight. When a player
from the other side crosses your path, a fight breaks out automatically, and you'll never know who
it was. Earn experience and loot, climb fifty levels, join a clan, take ground for your side, and
bring down the weekend raid boss together.

## Features

- **Two sides, two ways of seeing.** Humans see the city as a survivor's marked-up survey map.
  Zombies see it as heat, with every living thing glowing. Each side has its own gear, abilities,
  enemies and voice.
- **Fifty levels.** Every level raises your stats and inventory, unlocks abilities, and earns a new
  title every five levels.
- **37 pieces of equipment** across weapons, armor and utility gear, in four rarities. Gear can carry
  perks, named legendaries, and upgrades up to +10.
- **Always something to do.** Enemies and supply caches spawn around you as you walk, and airdrops
  fall across your area.
- **Contact.** Opposing players within about 60 m fight automatically, and both stay anonymous.
- **Echoes.** Fight snapshots of real players' builds, so there's always PvP even when nobody is
  nearby.
- **Missions and the weekly war.** Daily and weekly missions with streaks, and a Humans vs Zombies
  war scored worldwide and per district.
- **Clans, strongholds and raids.** Clans hold strongholds and take on weekend raid bosses together.
- **Sanctuaries.** Hospitals, schools and places of worship are always out of bounds for fighting.

## Your location stays yours

Nobody else ever sees where you are. The server keeps your latest position in memory for two
minutes to run the game, never writes it down, and never shares it. Opponents are anonymous.

## Project layout

| Folder | Contents |
|---|---|
| `server/` | The game server: one Zig 0.16 binary holding the game rules, a JSON API and SQLite. See `server/README.md`. |
| `client/` | The app: TypeScript, Preact and MapLibre, packaged for Android and iOS with Capacitor. See `client/MOBILE.md`. |
| `deploy/` | Hosting a server: Caddy for automatic HTTPS, and a systemd unit. |
| `docs/` | `DESIGN.md` (the game and its numbers), `ARCHITECTURE.md` (the API), `UI.md` (the interface). |

## Running it locally

```sh
cd server && zig build run -- --dev      # game server on :8080
cd client && npm install && npm run dev  # then open http://localhost:5173
```

The desktop build includes a GPS simulator: walk with WASD or click the map, and teleport between
cities.

Store screenshots (`npm run shots`), app icons (`npm run icons`) and a self-hosted map tile archive
(`--tiles`, see `docs/TILES.md`) are described in `client/MOBILE.md`.

## Credits

Map data © OpenStreetMap contributors. Map tiles by OpenFreeMap. Icons from game-icons.net. Third-party
assets and their licences are listed in `ATTRIBUTIONS.md`.

## License

No license has been granted yet. All rights reserved.
