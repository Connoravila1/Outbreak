# OUTBREAK: Humanity's Last Stand — Game Design

This is the game. It realizes the original design (`Original_Outbreak_GDD_v1.docx`, written by the
creator's father) as a shippable real-world GPS faction RPG. Where this document departs from the
original, the reason is given. Numbers here are the source of truth for the server's game data;
change them here first.

## 1. The promise

Choose Human or Zombie — forever. Walk your real neighbourhood. Hunt, scavenge, fight. When an
enemy player crosses your path, a fight breaks out automatically: you don't know who they are, only
that they're close. Win, earn loot and experience, grow stronger, join a clan, hold ground for your
side in a war that resets every week.

The signature moment, kept from the original:

> You're in a coffee shop. Your phone buzzes: CONTACT. A Zombie is here. You are fighting. You
> don't know who.

## 2. Design pillars

1. **Always something to do.** A solo player in an empty town must have a full game. Other players
   make it better, never possible.
2. **Every level means something.** No dead levels. Each one adds stats and inventory, and most add
   an unlock you can name.
3. **Legible over clever.** "I found a Rare Shotgun" beats "+3% to a hidden multiplier." Stats are
   few and visible.
4. **The choice matters.** Faction is permanent and reshapes names, gear, abilities, enemies, and
   look. It is presented as the most important moment in the game.
5. **Safe in the real world.** No one can use the game to find a specific person. Opponents in
   real-world fights are anonymous; nobody's live location is shown to anyone else.

## 3. Factions

Both factions share the same stat tables (fairness), but every name, icon, enemy, ability and
colour differs, and each has a trait.

| | Humans — "The Survivors" | Zombies — "The Infected" |
|---|---|---|
| Fantasy | Scavenge, fortify, hold the line | Mutate, hunt, spread |
| Colour | Flare orange on night blue | Blight green on bruise purple |
| Gear slots | Weapon / Armor / Gear | Claws / Hide / Strain |
| Trait | **Resolve**: +10% Defense, +5% max HP; healing items 25% stronger | **Hunger**: +5% Attack; heal 5% of damage dealt; regenerate 25% faster |
| PvE enemies | The infected (Shamblers, Runners, Brutes…) | Survivors (Scavengers, Soldiers, Raiders…) |
| Caches | Supply Crates | Fresh Remains |

**Underdog bonus.** If one faction has fewer active players this week (global), it earns bonus XP:
`bonus = min(25%, (share_gap) * 50%)` where share_gap = majority share − minority share. Shown on
the choosing screen so the choice can be made with that in mind.

**Permanence.** No switching, ever. Account deletion is the only way out (and starts over).

## 4. Stats and combat

Four stats: **HP**, **Attack (ATK)**, **Defense (DEF)**, **Speed (SPD)**.

Base stats by level L (before gear and trait):

    HP  = 100 + 14*(L-1)
    ATK = 10  + 2.0*(L-1)
    DEF = 6   + 1.5*(L-1)
    SPD = 10  + 0.6*(L-1)

Gear adds flat stats. At endgame, gear is roughly half of total power, so loot matters.

Total stats are computed as: base + the flat stats of the three equipped items, then multiplied once
by `1 + (faction trait + active buff + perk bonuses)` — percentages add, they do not compound.
Perks on equipped items apply to the wearer's totals (Brutal +8% ATK is +8% of your total ATK, two
Brutal items give +16%). An item's own displayed stats are `base × rarity × (1 + 0.04·upgrade)`.

**Combat details.** The faster side acts first each round, re-evaluated every round (Adrenaline can
change it); equal speed is decided by the seed. A dodge costs the attacker the attack, but an
armed Aimed Shot / Pounce stays armed until an attack lands. Crits multiply the damage before
rounding. Hunger/Leech heal is a share of the HP the target actually lost. Thorns reflect a share
of each hit taken, never after a killing blow. Burn/rot ticks at the end of each round, starting the
round it is applied. Second Wind/Devour trigger after any damage, including burn and thorns. Last
Stand/Undying cannot be used twice. Extra attacks (Overwatch/Swarm) are full attacks and cannot
chain.

### Resolution (identical for PvE, PvP, Echo, raids)

Combat is automatic and server-resolved, deterministic from a seed. A fight is a sequence of
**turns** (max 30). Each turn, both combatants act once, the higher SPD first (ties: seed).

For each attack, attacker A vs defender D:

    dodge = clamp(0.07 + 0.5*(D.SPD - A.SPD)/(D.SPD + A.SPD), 0.02, 0.30)
    crit  = clamp(0.07 + 0.5*(A.SPD - D.SPD)/(A.SPD + D.SPD), 0.02, 0.35)  (+ perks)
    dmg   = max(1, round(2.4 * A.ATK^2 / (A.ATK + D.DEF) * U(0.75, 1.25) * form_A))
    crit hit: dmg *= 1.7

`form` is a per-fight factor, drawn once per side from U(0.5, 1.5), that scales all of that side's
damage in the fight. Unlike the per-hit spread it does not average out, so a fight is never a
foregone conclusion: it is what makes a gear edge a strong tilt rather than a guarantee.

A combatant at 0 HP loses. After 30 turns, higher HP fraction wins (a tie goes to the defender,
side B). Expected: an even fight ends in 5–8 turns (the simulator measures 5–7 for equal kits). Same level, standard kits: Uncommon beats Common ≈ 63–73% of the time, Rare beats Common ≈ 83–85%. The client plays the turn log back as an animation (≈4–8 s), skippable.

### Health, downed, recovery

- HP persists between fights. This paces play and makes healing items matter.
- Out of combat you regenerate 2% max HP per minute (Zombies 2.5%): empty to full in 50 minutes
  (Zombies 40). Reaching a new level heals you fully.
- At 0 HP you are **Downed**: no PvE, no PvP, no raids. 5 minutes below L5, 10 minutes from L5.
  You revive at 30% HP. A revive item skips this. Losing never costs items or XP.

### New-player grace (L1–4) and First Blood

PvP protection ends at L5, and so does the gentle start. For a viewer below L5:

- Enemies come at level offsets −2..0 only (never above you, minimum level 1), and **no elites** are
  generated or visible.
- Enemy HP, ATK and DEF are multiplied by a grace factor: 0.75 at L1, 0.80 at L2, 0.87 at L3,
  0.94 at L4, 1.0 from L5.

**First Blood.** While a player has **0 wins**, `/api/location` adds one extra enemy with
`tutorial: true` (every enemy object carries the flag; it is false for normal ones): a Shambler
(mirrored per faction) at the player's own level, HP/ATK/DEF ×0.6 (replacing, not stacking with,
the grace factor), never elite, standing 25–35 m from the player. The spot is derived from
(server seed, player, re-anchor count) and held in memory like positions; it is placed again near
the player if they get more than 150 m from it. Its id is `t.<player_id>` and engaging it
validates like any other enemy (reach, not Downed, not in a sanctuary). A win pays normal PvE
rewards plus a guaranteed Uncommon-or-better item from the player's level pool, and ends the
tutorial enemy for good. A loss leaves it standing.

### Abilities

Unlocked by level, equipped into ability slots (1 slot at L3, 2 at L12, 3 at L25). They trigger
automatically in combat. Pairs are mirrored in power, different in flavour.

| Lvl | Human | Zombie | Effect |
|---|---|---|---|
| 3 | Second Wind | Devour | Once per fight, when HP < 35%, heal 30% max HP |
| 7 | Aimed Shot | Pounce | Your first attack is a guaranteed crit (Pounce also always acts first on turn 1) |
| 12 | Barricade | Calcify | Take 35% less damage for the first 3 turns |
| 18 | Adrenaline | Bloodlust | Human: +25% SPD and +15% ATK while HP < 50%. Zombie: +6% ATK per hit landed (max 5 stacks) |
| 25 | Molotov | Infectious Bite | Your first hit applies a burn/rot: 5% of target max HP per turn for 4 turns |
| 33 | Overwatch | Swarm | 20% chance to make an extra attack each turn |
| 42 | Last Stand | Undying | Once per fight, a lethal hit leaves you at 1 HP (Undying: revive at 25% HP) and you gain +30% ATK |

## 5. Levels and progression

Levels 1–50. XP to go from level L to L+1:

    xpToNext(L) = round_to_10(5.1 * L^2.65 + 440)

Pacing targets (active play time, verified by the balance simulator): **L5 ≈ 1 h, L10 ≈ 5 h,
L20 ≈ 25 h, L30 ≈ 70 h, L50 ≈ 300 h.** Tune `xpToNext` and the XP sources against these.

The simulator (`zig build sim`) assumes a player who is active ~2 h a day (HP is full at the start
of each day), walks constantly, fights whenever HP ≥ 60% (healing from stock under 50%, otherwise
waiting for regeneration), and does the dailies and weekly. Median results (100 players): see
`server/src/sim.zig`; the curve above lands within about ±10% of every target (last run, 100 players: L5 1.05 h, L10
4.9 h, L20 23.3 h, L30 66 h, L50 304 h). The 440 offset keeps the first levels from flying by now
that missions pay in wins. Total XP from L1 to L50 is about 2.1 million.

### XP sources

| Source | XP |
|---|---|
| PvE win | `20 + 6*E` (E = enemy level), ×1.5 elite, ×4 boss |
| PvE loss | 25% of win value |
| Cache opened | `10 + 2*L` |
| Walking | 1 XP per 20 m at ≤ 7 m/s (no XP in vehicles), max 300 XP/day |
| PvP win | `60 + 10*opp_level` |
| PvP loss | 30% of win value |
| Echo win | `40 + 7*echo_level` |
| Daily mission | `k * pveWinXp(L)`, k = 2.0–3.0 by difficulty (weekly: k = 10); `pveWinXp(L)` is a standard enemy's win at your own level |
| Raid contribution | scaled by damage share |

### Every level matters

Every level: base stats rise, inventory +2 slots (start 30, cap 130 before store expansions), and
the level ring fills. Unlocks:

| Lvl | Unlock |
|---|---|
| 1 | Starter kit, map, PvE, caches |
| 2 | The Store |
| 3 | Ability slot 1 + first ability |
| 4 | Item upgrading |
| 5 | PvP protection ends (real-world fights begin); weekly missions; Echoes |
| 7 | Ability: Aimed Shot / Pounce |
| 8 | Airdrops visible |
| 10 | Clans |
| 12 | Ability slot 2 + Barricade / Calcify |
| 15 | Territory: plant flags at Strongholds |
| 18 | Ability: Adrenaline / Bloodlust |
| 20 | Raids |
| 25 | Ability slot 3 + Molotov / Infectious Bite |
| 30+ | Legendary drop rate +50% |
| 33 | Ability: Overwatch / Swarm |
| 42 | Ability: Last Stand / Undying |

Titles every 5 levels (shown under your callsign):

- Human: Survivor (1), Scavenger (5), Defender (10), Ranger (15), Sentinel (20), Warden (25),
  Vanguard (30), Commander (35), Hero (40), Legend (45), Last Hope (50).
- Zombie: Turned (1), Shambler (5), Lurker (10), Stalker (15), Ravager (20), Brute (25), Alpha (30),
  Dread (35), Blight (40), Plaguebringer (45), Patient Zero (50).

## 6. Items

Three equipment slots. Each **base item** has one stat definition and two names (Human / Zombie).
Bases unlock at a required level; drops favour bases near your level.

### Rarity (four tiers, as in the original)

| Rarity | Stat multiplier | Perks | Drop weight | Scrap salvage |
|---|---|---|---|---|
| Common | ×1.00 | 0 | 64 | 3 |
| Uncommon | ×1.20 | 0 | 26 | 8 |
| Rare | ×1.45 | 1 | 8.5 | 20 |
| Legendary | ×1.80 | 2 | 1.5 | 50 |

Scrap salvage is multiplied by `(1 + req_level/10)`. Legendary weight ×1.5 at L30+.

### Upgrades

Each item can be upgraded **+1 to +10** with salvage; each step adds +4% to the item's stats.
Cost of step n: `round(12 * n^1.8 * (1 + req_level/10) * rarity_cost)` with rarity_cost
1/1.3/1.7/2.2. This lets a favourite item stay relevant for a while and is the main salvage sink.

### Perks (Rare: 1, Legendary: 2, rolled from this pool)

Keen (+6% crit), Swift (+8% SPD), Brutal (+8% ATK), Sturdy (+8% DEF), Vital (+10% max HP),
Leech (heal 5% of damage dealt), Thorns (reflect 8% of damage taken), Lucky (+15% loot chance).

### Weapons (ATK primary)

Stats are at +0 Common. Format: req level — Human name / Zombie name — ATK, SPD, DEF.

| Req | Human | Zombie | ATK | SPD | DEF |
|---|---|---|---|---|---|
| 1 | Kitchen Knife | Broken Nails | 5 | 3 | 0 |
| 1 | Baseball Bat | Rotten Teeth | 7 | 0 | 0 |
| 3 | Crowbar | Bone Spur | 8 | 0 | 2 |
| 5 | Machete | Jagged Claws | 10 | 3 | 0 |
| 8 | Fire Axe | Crushing Fist | 14 | -1 | 0 |
| 11 | Revolver | Spitter Gland | 15 | 4 | 0 |
| 14 | Compound Bow | Lashing Tendril | 17 | 6 | 0 |
| 17 | Pump Shotgun | Gaping Maw | 22 | -2 | 0 |
| 21 | Katana | Razor Talons | 22 | 7 | 0 |
| 25 | Hunting Rifle | Barbed Tongue | 27 | 3 | 0 |
| 29 | Assault Rifle | Acid Glands | 30 | 5 | 0 |
| 34 | Chainsaw | Bone Saw Arm | 37 | -3 | 3 |
| 39 | Flamethrower | Bile Cannon | 40 | 0 | 0 |
| 44 | Prototype Railgun | Hivemind Lance | 46 | 4 | 0 |

### Armor (DEF primary, HP secondary)

| Req | Human | Zombie | DEF | HP | SPD |
|---|---|---|---|---|---|
| 1 | Hoodie | Torn Skin | 3 | 5 | 1 |
| 1 | Leather Jacket | Thick Hide | 4 | 8 | 0 |
| 4 | Hockey Pads | Calloused Flesh | 6 | 12 | 0 |
| 7 | Motorcycle Leathers | Gristle Plates | 8 | 18 | 0 |
| 10 | Riot Vest | Bone Plating | 11 | 22 | -1 |
| 14 | Kevlar Vest | Chitin Shell | 13 | 30 | 0 |
| 18 | Hazmat Suit | Fungal Carapace | 15 | 40 | 0 |
| 23 | SWAT Armor | Necrotic Mass | 19 | 50 | -1 |
| 28 | Ghillie Rig | Shadow Skin | 18 | 45 | 5 |
| 33 | Military Plate | Ironbone Hulk | 25 | 70 | -2 |
| 38 | Exo-Frame | Abomination Shell | 29 | 85 | 0 |
| 44 | Juggernaut Suit | Titan Carapace | 34 | 110 | -2 |

### Gear / Strain (utility — mixed stats)

| Req | Human | Zombie | ATK | DEF | SPD | HP |
|---|---|---|---|---|---|---|
| 1 | Flashlight | Night Eyes | 0 | 1 | 3 | 0 |
| 1 | Backpack | Scavenger Gut | 0 | 2 | 0 | 10 |
| 4 | Walkie-Talkie | Hive Whisper | 2 | 0 | 4 | 0 |
| 7 | Binoculars | Keen Scent | 3 | 0 | 5 | 0 |
| 10 | Gas Mask | Spore Lungs | 0 | 5 | 2 | 15 |
| 14 | Night Vision | Pale Sight | 3 | 2 | 7 | 0 |
| 19 | Combat Stims | Fever Strain | 6 | 0 | 6 | 0 |
| 24 | Drone Scout | Carrion Swarm | 5 | 3 | 8 | 10 |
| 30 | Tactical Exo-Brace | Adrenal Gland | 8 | 5 | 6 | 20 |
| 37 | Field Medic Kit | Regenerative Strain | 4 | 8 | 4 | 45 |
| 43 | Signal Jammer | Mind Blight | 10 | 6 | 10 | 25 |

### Legendary uniques

Rare named Legendaries (≈1 in 6 Legendary drops) with a fixed perk set and a line of lore. Their
stats are their base item's Legendary stats +10%.

| Base | Human unique | Zombie unique | Perks |
|---|---|---|---|
| Baseball Bat / Rotten Teeth | **Old Faithful** — "Dad swore it never missed." | **The First Bite** | Brutal, Lucky |
| Pump Shotgun / Gaping Maw | **The Last Word** | **Hungry Hungry** | Brutal, Keen |
| Katana / Razor Talons | **Moonlight** | **Nightreaper** | Swift, Keen |
| Riot Vest / Bone Plating | **The Wall** | **Ossuary** | Sturdy, Thorns |
| Hazmat Suit / Fungal Carapace | **Clean Room** | **The Bloom** | Vital, Sturdy |
| Signal Jammer / Mind Blight | **Dead Air** | **The Choir** | Swift, Leech |

### Starter kit

L1, Common: Baseball Bat / Rotten Teeth, Hoodie / Torn Skin, Flashlight / Night Eyes, plus 3 small
heals.

### Consumables (stackable, faction-named, same effect)

| Id | Human | Zombie | Effect |
|---|---|---|---|
| heal_s | Bandage | Raw Meat | Heal 25% max HP |
| heal_m | First Aid Kit | Fresh Kill | Heal 60% max HP |
| revive | Trauma Kit | Mutagen Vial | Revive from Downed at 100%, or full heal |
| buff_atk | Adrenaline Shot | Rage Gland | +15% ATK for 30 min |
| buff_def | Painkillers | Bone Marrow | +15% DEF for 30 min |
| buff_spd | Energy Drink | Fever Gland | +15% SPD for 30 min |
| buff_xp | Field Manual | Hive Memory | +25% XP for 30 min |
| buff_loot | Lucky Coin | Carrion Scent | +50% cache/loot chance for 30 min |
| flag | Territory Flag | Infestation Marker | Claim a Stronghold for your clan |

Human Resolve makes heals 25% stronger. Buffs of the same kind refresh, they don't stack.

## 7. The world

The world is the real map. Your own position is shown to you. The server only keeps each
player's latest position in memory, drops it after 2 minutes, and never writes positions to disk.

### Cells and spawns

The world is split into **geohash-7 cells** (≈153 m × 153 m). Content is generated
deterministically from `(server_seed, cell, time_window)`, so everyone near a place sees the same
things, and the server can recompute and validate any id without storing spawns.

- **Enemies**: every 10-minute window, each cell has 0–2 enemy spawns (55% / 35% / 10%, mean
  0.55). Each spawn has a position inside the cell, an archetype, and a level offset. Enemy level is
  shown relative to the viewer: `player_level + offset` with offset in −2..+2 (elite: +3..+5, 8%
  chance, gold ring); viewers below L5 get −2..0 and no elites (section 4, grace). A player can
  defeat each spawn once.
- **Caches**: every 30-minute window, each cell has a 30% chance of one cache. One open per player.
- **Airdrops** (L8+): each geohash-5 region (≈4.9 km) gets one airdrop per 2-hour window, live for
  45 minutes, visible from 2 km. Better loot, higher Legendary chance (×3).
- **Strongholds** (clans): one per geohash-6 cell (≈1.2 km × 0.6 km), at a fixed point.

Interaction range is **50 m** (generous for GPS error). Content is shown within **400 m**: about 14–18 enemies
and 7–10 caches at mid latitudes (cells are narrower the further from the equator; about 14 / 7 at
30° N, 16 / 8.5 at 41° N), so there is always something to do without clutter.

### Enemy archetypes (mirrored per faction)

Stats are a multiple of a same-level player's base stats plus **reference gear** (the best Common
base in each slot at that level, no upgrades or perks), then HP, ATK and DEF are scaled by
`0.95 + 0.85 * L/50` (players out-grow Common gear with rarity and upgrades; this keeps enemies
even). Speed is not scaled. Players with level-appropriate gear should win standard fights ~85%
of the time and lose ~30–45% HP. The simulator measures the spawn-weighted mix at full HP, with
the gear real players end up with: 90–95% wins and 31–43% HP lost at L10–35, 84% and 48% at
L45+ (79% at L5, where Brutes and Hordes bite hardest) (Brutes and Hordes are meant to be dangerous at parity).

| Human sees | Zombie sees | HP | ATK | DEF | SPD | Notes |
|---|---|---|---|---|---|---|
| Shambler | Scavenger | 0.8 | 0.8 | 0.8 | 0.7 | Common (40%) |
| Runner | Scout | 0.6 | 0.8 | 0.6 | 1.5 | Fast (20%) |
| Bloater | Barricader | 1.6 | 0.7 | 1.2 | 0.6 | Tanky (15%) |
| Brute | Soldier | 1.3 | 1.15 | 1.1 | 0.8 | Strong (12%) |
| Horde | Raider Gang | 2.2 | 0.9 | 0.8 | 0.9 | Group, +50% XP and loot (8%) |
| Screamer | Medic | 0.7 | 0.6 | 0.7 | 1.1 | Rare (5%), guaranteed consumable drop |
| Abomination | Warlord | raid boss only | | | | See Raids |

### Loot

Each PvE win rolls: 35% item, 50% consumable, salvage always (`3 + E/2`); Horde multiplies the
chances and salvage by 1.5 and a Screamer always drops a consumable. Caches give 1–3 rolls, each
55% item and otherwise a consumable, plus `3 + L/2` salvage per roll. Airdrops give 3–4 rolls,
each 75% item (Uncommon or better, Legendary ×3), with double salvage. Contact and Echo wins give
`10 + opp_level` salvage and a 25% item roll. The item roll picks a base from those with
`req ≤ L`, weighted toward the top (`weight = 1 + 3*max(0, 1 - (L - req)/8)`), then a rarity from
the table above. Consumable drops (relative weights): heal_s 38, heal_m 20, revive 4, each buff 6;
never flags. Lucky perks and the loot buff multiply the item and consumable chances.

### Sanctuaries (Safe Zones, from the original)

Hospitals, schools, and places of worship are **Sanctuaries**, read from the map's own data on the
device. Inside a sanctuary: no spawns are shown, no fights start, and you cannot be matched for PvP.
The map shades them softly. This keeps the game out of places where it shouldn't be played.

### Anti-cheat (light)

Positions implying > 45 m/s are rejected; walking XP needs ≤ 7 m/s. Engage requests are validated
against the last accepted position. Rate limits per account.

## 8. Encounters

### PvE (always available)

Tap an enemy within range → a sheet shows it (archetype, level, threat colour vs you) → **Engage**
→ the fight plays out → result card (XP, salvage, drops). Lost fights still give some XP.

### PvP — Contact (the signature)

Automatic, as in the original. While the app is open (later: in the background with Patrol mode),
the server checks every 5 s for opposing players within **60 m** of each other.

Conditions: both level ≥ 5, levels within ±12 (or the lower one is ≥ 30), neither Downed or in a
sanctuary, no fight between that pair in the last 4 h, and neither in a PvP fight in the last 10 min.

What you see: a full-screen **CONTACT** alert with haptics — "A Zombie is close. Level 14.
Fighting." — then the fight plays back. Opponents are always anonymous: faction, level, title,
equipped item names. Never callsign, never position, never direction. Afterwards: XP, salvage, a
25% item roll (generated, not stolen), war points. The loser loses HP, keeps everything else.

**Hostile signal.** If an opposing active player is within 500 m, the HUD shows "Hostiles in the
area" — no count, no direction. Tension without tracking.

### Echoes — PvP for small populations

The server keeps a snapshot of every player's build (level, stats, equipment, abilities). When you
haven't had a real Contact in 2 hours, the map may show an **Echo**: a snapshot of a real enemy
player of similar level from anywhere in the world, clearly labelled "Echo — Lv 14 Zombie". Defeat
it for PvP-style rewards. The real player later gets a report: "Your echo held against a Human
(+15 XP)" or "Your echo fell." Echoes are honest: always labelled, always real builds.

If no real snapshot of a fitting level exists (very early servers), the server uses a generated
"Rogue" build, labelled "Rogue — Lv 14 Zombie" (a bot, and it says so).

## 9. Missions

Three **daily missions** (reset 00:00 UTC) from a pool, plus one **weekly** (from L5). Rewards: XP
(`k` standard wins' worth, `k` = 2.0–3.0 for dailies and 10 for the weekly, so it scales with level
the way fights do and is never a token amount), salvage (`10 + L` daily, `80 + 5L` weekly), and
for the weekly a guaranteed Rare-or-better item. The three dailies are distinct kinds, chosen
deterministically per player and day, and gated by what the player can plausibly do: scrap and upgrade missions from L4 (spare gear),
elite, Contact and Echo missions from L5 (elites and real-world fights do not exist before that).
Completing all three dailies adds a bonus consumable. A **streak** counter adds +10% mission XP per
consecutive day on which a daily is claimed, capped at +50%; it lapses after a missed day.

The pool is recomputed from (player, day, frozen level), so existing mission ids stay valid; the
gating applies to whatever is generated from the next selection on.

Pool: defeat N enemies · defeat an elite · open N caches · walk N metres · win a Contact or an
Echo · use a consumable · upgrade an item · scrap N items · defeat N of a specific archetype.

## 10. The War (faction-level, weekly)

Every action earns **war points** for your faction: PvE win 1, elite 3, cache 1, Echo win 3, PvP win
10, raid damage share, Stronghold held per hour 2. Points count globally and per **district**
(geohash-4, ≈39 km × 20 km). The War screen shows the global bar (Humans vs Zombies), your
district's bar, and your faction's top players this week.

Weekly reset Monday 00:00 UTC. The winning faction in each district gets +10% XP there next week.
The global winner gets a banner on the map for the week.

## 11. Clans and territory (from the original)

- **Clans**: L10+, max 50 members, single faction, name + 2–4 character tag, costs 500 salvage.
  Join by search or invite code. Roles: Leader, Officer, Member. Clan chat (short text, rate
  limited, report button). Clan page: roster with callsign, level, title, weekly points.
- **Strongholds**: one per geohash-6 cell. At L15+, while within range, plant a Flag/Marker:
  unclaimed → yours; held by another clan → fight its garrison (Echoes of up to 3 of the holding
  clan's members, in sequence). Win all → it's yours.
- **Holding** pays every member salvage daily and war points hourly. **Adjacency**: a clan holding
  3+ edge-adjacent strongholds gets +5% XP for members; 6+ gets +10% (original: clan perks for
  adjacent zones).
- **Weekly purge**: all strongholds reset at the weekly reset (original: weekly zone purges).

## 12. Raids (from the original's "Legendary Infected Raids")

L20+. On weekends, each district with recent activity gets a raid boss at one of its Stronghold
sites: **the Abomination** (for Humans) / **the Warlord** (for Zombies). Its HP pool scales with the
district's active players. Each player may attack once per hour from within range; damage dealt is
recorded. If the boss dies within 48 h, every contributor gets rewards scaled by share, with a high
Legendary chance for top contributors. It always says how many fighters joined.

## 13. Store and economy

Currency: **Salvage** (earned only; no real money in this version — the original's monetisation is
deferred, cosmetic-only if ever added).

| Item | Price |
|---|---|
| Consumables | heal_s 20, heal_m 50, revive 120, buffs 60, flag 300 |
| Supply Requisition (random item of your level, Uncommon+) | 150 |
| Inventory +10 slots | 400, then +200 each |
| XP Boost (+50% for 1 h) | 200 |
| Cosmetics: map themes, callsign colours, avatar frames | 250–1000 |

## 14. Identity and avatar

- **Callsign**: unique, 3–16 characters. Shown on leaderboards and in your clan, never attached to a
  real-world encounter.
- **Avatar** (original: gender, race, faction skins): layered illustrated portrait — face shape,
  skin tone, hair, and a faction treatment (human: grime, bandages, gear; zombie: decay stages that
  advance with level). More faction skins unlock with titles.
- **Account**: created on first launch with a random token. A **recovery code** is shown once and in
  Settings, to move to a new phone. (Email/Google/Apple sign-in later.)

## 15. Notifications

Contact results, Echo reports, raid start, weekly war result, mission reset. Local notifications
first; push (FCM/APNs) when there is a hosted server.

## 16. What's deferred, honestly

Real-money store, ads, season pass, AR mode, background Patrol mode on iOS (Android first), push
via FCM/APNs, email/social login. The design leaves room for each.
