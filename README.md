# Outbreak: Humanity's Last Stand

A real-world GPS faction RPG. Choose Human or Zombie, forever. Walk your own streets to hunt,
scavenge and fight. When an enemy player crosses your path, a fight breaks out automatically. You
never learn who they were. Earn experience and loot, climb fifty levels, join a clan, take ground
for your side, and bring down the weekend raid boss together.

Based on the original game design by the creator's father (`docs/Original_Outbreak_GDD_v1.docx`).

## What's in the game

- **Two factions, two ways of seeing.** Humans see their city as a survivor's marked-up survey map.
  Zombies see it as thermal heat. Each side has its own gear names, abilities, enemies and voice.
- **Fifty levels.** Every level raises your stats and inventory. There are 14 abilities and a title
  every five levels.
- **37 pieces of equipment** across weapons, armor and utility gear, in four rarities. Items can
  carry perks, named legendaries and upgrades up to +10.
- **Fights everywhere.** Enemies and supply caches spawn around you as you walk, and airdrops
  arrive across your area.
- **Contact.** Opposing players within about 60 m fight automatically and anonymously.
- **Echoes.** Snapshots of real players' builds let you fight PvP even when nobody is nearby. They
  are always labelled as Echoes.
- **Daily and weekly missions** with streaks.
- **The weekly war**, scored worldwide and per district, plus clans, strongholds and weekend raids.
- **Sanctuaries.** Hospitals, schools and places of worship are no-fight zones.

## Privacy

Nobody's live location is shown to anyone else. The server keeps each player's latest position in
memory for two minutes and never writes it down. Opponents in real-world fights are anonymous.

## Layout

| Folder | What's in it |
|---|---|
| `server/` | Zig 0.16. A single binary: JSON API, all game rules, SQLite. See `server/README.md`. |
| `client/` | The app: TypeScript + Preact + MapLibre, packaged for Android and iOS with Capacitor. See `client/MOBILE.md`. |
| `deploy/` | Caddy (automatic HTTPS) and a systemd unit for hosting a server. |
| `docs/` | `DESIGN.md` (the game and every number), `ARCHITECTURE.md` (the API), `UI.md` (the interface). |

## Play it on a laptop

```sh
cd server && zig build run -- --dev      # game server on :8080
cd client && npm install && npm run dev  # open http://localhost:5173
```

The desktop build includes a GPS simulator. Walk with WASD or click the map, and teleport between
cities.

## Credits

Map data © OpenStreetMap contributors. Tiles by OpenFreeMap. Icons from game-icons.net. See
`ATTRIBUTIONS.md` for the full list.
