# GAME RULES — the living balance document

**Status:** Phase 0. Nobody has played. Every number here is provisional and most are wrong.

This document tracks **every tunable decision** in the game and **why it is what it is**. It exists because balance decisions get made quietly, in a module header, at 2am, and then become load-bearing without anyone noticing.

**Where code and THE_RULESET disagree, the code is wrong (J5).** This document is not the Ruleset and cannot override it. Section I is not negotiable here — nothing on this page may be tuned in a direction that reveals *who* or *where*.

**How to read the columns:** *Locked* means changing it breaks a law. *Cheap* means change it today. *Expensive* means it gets expensive after Phase 2 (protocol) or Phase 3 (client ships).

---

## 1. The constants that are not balance

These look like knobs. They are not knobs.

| Symbol | Value | Where | Status |
|---|---|---|---|
| *k* (quorum) | **3** | `spatial.zig` | **LOCKED as a floor.** May be raised. **Never lowered** (I8). Sparse regions are solved by growing the cell, never by dropping *k*. |
| Sub-quorum output | **nothing** | `world.zig` `liveRuns` | **LOCKED** (I3). Not a count, not a flag, not "quiet". Discarded at the only place that could have known. |
| Tell contents | damage, hp, xp, momentum | `tick.zig` | **LOCKED shape** (I1, I5). No occupant count. No identity. No geometry. Additions require a Section I review by name. |
| Territory reward | **none** | `territory.zig` | **LOCKED** (H2). Territory confers no XP, no loot, no combat modifier, no quorum advantage. It is a statistic. |
| Automated punishment | **none** | `integrity.zig` | **LOCKED** (H4). Suspicion dampens XP and does nothing else, ever. |

---

## 2. Spatial — `src/spatial.zig`

| Knob | Value | Rationale | Cost to change |
|---|---|---|---|
| `default_precision` | **39 bits** | ~38 m square (~125 ft) at the equator. Odd bit count is deliberate: longitude spans twice the range of latitude, so the extra longitude bit is what makes the room *square*. An even precision gives a room twice as wide as tall. Design target was ~150 ft; 39 is the nearest square room to it. | **Cheap now, expensive after Phase 2.** Behind the module boundary (D1). |
| Coarsening step | caller's choice of bits | A bit-shift. Each bit dropped quadruples the room's area. | Cheap. |
| Cell encoding | sentinel bit | Payload, then a single `1`, then zeros. Precision = `63 - @ctz(v)`. Prevents a coarse and a fine cell colliding to the same `u64` and fusing two unrelated rooms. Also makes `0` an invalid cell. | **Expensive.** Every module is keyed on this. |

**Open question:** 39 bits was chosen for squareness, not from data. A café is ~15 m; an office floor is ~50 m; a train platform is ~200 m. One cell size cannot fit all three, and the cell size decides what "a room" means. This is the most consequential unvalidated number in the project.

---

## 3. Combat — `src/combat.zig` (`Rules`)

All provisional. Phase 1's named trap is tuning these before anyone has played.

| Knob | Value | Rationale |
|---|---|---|
| `damage_per_hostile` | **6** | Placeholder chosen to be obviously provisional rather than deceptively considered. At 100 hp, being outnumbered 3:1 downs you in ~5 ticks (2.5 minutes). |
| `jitter` | **5** | Width of the random damage jitter. Keeps identical fights from resolving identically. |
| `recovery_per_tick` | **1** | You heal when you are **not** in a live cell. Full recovery from zero takes 100 ticks (50 minutes). There is no death and no permanence — nothing may be at stake worth stalking someone over. |
| `max_hp` | **100** | Placeholder. |
| `xp_per_tick` | **10** | Earned for **one thing**: a tick in a live cell with ≥1 hostile present (H3). |

### Decisions made, and why

- **Momentum is damage *per member*, not damage in total.** A side that outnumbers its enemy 3:1 absorbs more total damage purely by having more bodies, so a total-damage comparison reports the *outnumbered* side as winning almost every time. It would have been a headcount wearing a fight's clothes, and it would have been wrong in every tell the game ever emitted.
- **XP does not depend on performance.** Winning, losing, untouched, and downed all pay the same. The reward tracks *presence among real humans* — the one input a spoofer cannot fabricate — not skill.
- **A downed player still earns.** They are still standing in the fight. XP is an explicit field rather than inferred from `damage > 0`, precisely so this stays true.
- **Randomness keys off `PlayerId`, never array slot.** Otherwise a stable sort becomes a game rule and a tie-break decides a fight.

---

## 4. Integrity — `src/integrity.zig` (`Params`)

| Knob | Value | Rationale |
|---|---|---|
| `min_history` | **8 ticks** | Below this, score is always 0. A new player is not a suspect; silence is not evidence. |
| `settled_dwell` | **3 ticks** | Ticks in one room before it counts as a place you *are* rather than passed through. |
| `max_dampening_pct` | **40%** | The **most** a suspicion score may ever cost. The worst-scoring player imaginable still earns 60% of their XP, still plays, still exists (H4). |
| `min_co_sightings` | **20** | Co-sightings before a pair means anything. Two accounts together twice are two friends having coffee. |

### The structural point

**Plausibility here is not what it is anywhere else.** Everywhere else it means "no body could travel that far that fast" — a claim about *distance*, which does not exist in this system by law. The standard implementation is unavailable to us, and no cleverness will conjure it back.

What survives quantization is **churn**: a real person occupies few rooms and lingers; a spoofer chasing live cells changes room every tick and dwells nowhere. So we score **dwell, not distance.** It is a weaker signal, and that is the correct trade — the geometry we gave up is the same geometry that would let this server be subpoenaed for where someone was standing.

**Known weakness:** a commuter on a fast train churns hard. This is why the score may only ever dampen.

**Farm detection** is co-occurrence: the signal is not that accounts are *together often* (friends are together often) but that they are **never apart**. A farm has no home to go to.

---

## 5. Territory — `src/territory.zig` (`Params`)

| Knob | Value | Rationale |
|---|---|---|
| `max_contribution_per_tick` | **3** | The anti-teleport constant. Fifty accounts appearing for one tick are worth three. Territory accrues in the **time** dimension, which is the axis a spoofer cannot cheat. |
| `decay_pct` | **25% per week** | Nothing is held forever. A clan that stops turning up loses the ground. |
| `min_strength` | **10** | Below this a claim is dropped entirely rather than lingering at nearly nothing. |

Contested ground (a tie) is held by **nobody**. We do not invent a winner to tidy the map.

---

## 6. The synthetic city — `src/city.zig` (`Params`)

**This is a model of a city, not a city.** Its numbers are the least trustworthy on this page, and conclusions drawn from it must say so.

| Knob | Value | Note |
|---|---|---|
| `population` | 10,000 | The exit-criterion figure. |
| `ticks_per_day` | 2,880 | 30-second ticks. |
| `homes` | 6,000 | **Arbitrary.** ~1.7 players per home cell. |
| `workplaces` | 250 | **Over-concentrated:** ~30 players per office. |
| `stations` | 30 | **Badly over-concentrated:** ~250 players per platform, for two solid hours. |
| `cafes` | 120 | |
| `homebody_pct` | 25% | Players who never commute. |

**Known modelling flaws (do not draw conclusions past these):**
- Everyone commutes on the *same* schedule with no stagger. Real platforms fill and empty over minutes; ours holds 250 people for two hours.
- Home assignment is uniform. Real housing is heavy-tailed — most cells hold 0–1 players, a few towers hold many.
- Nobody travels, visits, goes out at night, or takes a day off.

**Fixed bug worth remembering:** home cell and faction were once sliced from the same hashed value. `homes` is even, so `who % homes` preserved the low bit that chose the faction — **everyone sharing a home was the same faction**, home cells could never hold a hostile, and the fight histogram read exactly 0.00% at night. A slice of a hash is not an independent draw.

---

## 7. What the simulation currently says

At 10,000 players over a simulated week, with the model above:

| Measure | Value |
|---|---|
| Tick cost (mean) | **270 µs** |
| Tick cost (max) | 1.4 ms |
| Fraction of the 30 s budget | **0.0009%** |
| Live cells per tick | 972 mean, 1,421 peak |
| **A player is in a fight** | **54% of their entire week** |
| Replay | byte-identical checksum |
| Leaks | zero |

### The finding that needs a decision

**The game is on more or less constantly, and that is not what the design describes.**

GAME_DESIGN says *"most of the time it says nothing at all"* and rests on the coffee-shop moment being **rare and precious**. A player in a fight 54% of the time is not having a rare precious moment; they are having ambient noise.

Sensitivity (one day, varying only home density):

| home cells | players/home | live | fighting |
|---|---|---|---|
| 3,000 | 3.33 | 81.7% | 76.7% |
| 6,000 | 1.67 | 63.4% | 58.7% |
| 12,000 | 0.83 | 48.1% | 45.9% |
| 25,000 | 0.40 | 41.1% | 40.2% |
| 60,000 | 0.17 | 38.4% | **38.1%** |

Even with homes so sparse they are effectively solitary, fighting stays near 38% — that floor comes from **workplaces, stations, and cafés**, which my model over-concentrates badly.

**So the honest reading is: this number is mostly about the model, not about the game.** What is *robust* is the direction — the roadmap worried that quorum would **never fire**; the simulation says it fires **easily**, wherever people cluster. The risk is the opposite of the one we planned for.

**The decision this forces (yours, not mine):** *what fraction of a player's day should be live?* Once that number exists, it drives cell size, *k*, and possibly an XP cap. It cannot be derived from code.

---

## 8. Change log

| Date | Change | Why |
|---|---|---|
| 2026-07-13 | Momentum: total damage → damage per member | Total damage called the outnumbered side the winner |
| 2026-07-13 | `Outcome` size budget 8 → 12 bytes (A7.1) | Explicit `xp` field; inferring it from `damage > 0` silently stops paying a downed player |
| 2026-07-13 | `sortByCell` → total order (cell, then player) | Unstable sort made event order depend on arrival order |
| 2026-07-13 | splitmix64 written in-house, not `std.Random.DefaultPrng` | "Default" may change in any Zig release, breaking replay across a toolchain upgrade |
| 2026-07-13 | City attributes: one hash sliced → one mix per attribute | Home and faction were correlated; home cells could never hold a hostile |
