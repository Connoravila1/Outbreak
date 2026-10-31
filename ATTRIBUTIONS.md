# Attributions

Everything in this project that someone else made, what it is licensed under, and where it came
from. **This file is not a courtesy.** The OFL and CC BY both require the notice to travel with the
work, so a licence we cannot prove we honoured is a licence we have broken.

**If you add an asset, you add a row here in the same commit.** An asset whose provenance is only
in someone's memory is an asset we will one day have to delete.

---

## Code

No third-party code ships in the project today. (stb_truetype was removed with the GLES
renderer when presentation moved to DVUI; DVUI itself lands as a vendored dependency with its
own row here when it does.)

---

## Fonts

Both are **SIL Open Font License 1.1**. The OFL requires the copyright notice and licence to be
distributed with the font, which is why the licence files sit next to the `.ttf`s rather than being
linked from here.

| | |
|---|---|
| **Inter** (Regular) | `assets/fonts/Inter-Regular.ttf` |
| Copyright | © 2016 The Inter Project Authors — https://github.com/rsms/inter |
| Licence | SIL OFL 1.1 — `assets/fonts/Inter-OFL.txt` |
| Used for | **Body prose.** The sentences the player actually reads. |

| | |
|---|---|
| **Oxanium** (SemiBold, Bold, ExtraBold) | `assets/fonts/Oxanium-*.ttf` |
| Copyright | © 2019 The Oxanium Project Authors — https://github.com/sevmeyer/oxanium |
| Licence | SIL OFL 1.1 — `assets/fonts/Oxanium-OFL.txt` |
| Used for | **Labels, headings, and the alarm.** The chrome, and the things the game shouts. |

> A note worth keeping, because it nearly bit us. The prior art these were ported from carried
> comments claiming it embedded IBM Plex Sans; its build file embedded Inter. Ported carelessly,
> this repository would have shipped a false attribution for a font it does not contain.
> **Verify what is embedded, not what a comment says is embedded.**

---

## Client sound set (`client/public/audio/`)

All of it is **CC0 (public domain)**, so no credit is legally owed. It is credited anyway, in the in-app
Credits screen. Raw downloads are not in the repository. Every sound is rebuilt by
`client/scripts/sound/build.py`, which also records what was recorded and what was synthesised.
The recordings were fetched from the OpenGameArt.org CC0 pages (kenney.nl blocks scripted downloads;
the same Kenney packs are mirrored there).

| Source | Author | URL | Licence | Used for |
|---|---|---|---|---|
| Interface Sounds | Kenney | https://opengameart.org/content/interface-sounds | CC0 | Layers in tap, tab, sheet and claim sounds |
| 50 RPG sound effects (RPG Audio) | Kenney | https://opengameart.org/content/50-rpg-sound-effects | CC0 | Latch, leather, chop, cloth, book and door layers in equip, scrap, upgrade, claim, loot flip, hit, commit, ambience |
| RPG Sound Pack | artisticdude | https://opengameart.org/content/rpg-sound-pack | CC0 | Coin, bottle, bubble, slime, giant/ogre/shade/beast growls and bite layers in the Zombie variants, purchase, heal, bitten |
| 16 Monster Growls | StarNinjas | https://opengameart.org/content/16-monster-growls | CC0 | Growl layers in engage.z and the CONTACT zombie alarm |
| Mild Wind Background Noise | Bashar3A | https://opengameart.org/content/mild-wind-background-noise | CC0 | Human map ambience (filtered, looped) |
| horror breathing | primbal | https://opengameart.org/content/horror-breathing | CC0 | Zombie map ambience (pitched down, filtered) |
| Frequency Static Sound Effects | bretbernhoft | https://opengameart.org/content/frequency-static-sound-effects | CC0 | Emergency broadcast static |

**Synthesised in Python (numpy/scipy), no recording involved:** the whole Human CONTACT klaxon, the
level-up fanfares, rarity reveals, brass, bells, heartbeats, riser, burn, flatline, typing ticks, hit and
dodge bodies, the hostile ping, echo report, downed/revived, and the main menu theme (original, 96 s).

---

## Client (`client/`)

| | |
|---|---|
| **Game-icons.net icons** | via `@iconify-json/game-icons`; a generated subset in `client/src/ui/icon-data.ts` |
| Authors | Lorc, Delapouite and other game-icons.net contributors (https://game-icons.net; authors listed in the package's `info.json` and the project licence file) |
| Licence | CC BY 3.0 — https://creativecommons.org/licenses/by/3.0/ |
| **Big Shoulders Display**, **Barlow**, **Permanent Marker** | bundled via `@fontsource/*`, served from our own origin |
| Licence | SIL OFL 1.1 (Big Shoulders Display © Patric King / Chicago Tribune; Barlow © Jeremy Tribby; Permanent Marker © Font Diner / Stephen Hicks) |
| **OpenFreeMap** tiles and **OpenMapTiles** schema | https://openfreemap.org — vector tiles, no key |
| **OpenStreetMap** data | © OpenStreetMap contributors, ODbL 1.0 — https://www.openstreetmap.org/copyright. The map always carries the attribution control (and the split-lens screen prints it). |
| **MapLibre GL JS** | BSD-3-Clause, `maplibre-gl` |
| **Preact**, **@preact/signals** | MIT |
