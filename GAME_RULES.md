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
| Tell contents | damage, hp, xp, momentum, crowd **band** | `tick.zig` | **LOCKED shape** (I1, I5). No identity, no geometry, and no *exact, refreshing* count — see §3a. Additions require a Section I review by name. |
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
| `engagement_ticks` | **10** (5 min) | How long one fight lasts. **A fight is an event, not a climate.** |
| `cooldown_ticks` | **240** (2 h) | How long a room is spent afterwards. Keyed to the **room**, not the player. |

### The engagement model — the biggest design change so far

Before this existed, combat ran for as long as two hostiles shared a room. Sitting at a desk in a large office meant being **at war for eight straight hours**, and the simulation reported players in a fight **54% of their entire week**. Worse, it made the optimal XP strategy *"have a job in a crowded building"* — an exploit that requires no spoofing, is entirely legitimate, and which no integrity system can ever touch.

Both the original GDD (*"combat ends when one player's HP reaches 0"*) and the feel prototype (a fight runs five resolutions and stops; the quiet screen reads *"last engagement: 2 days ago"*) describe a fight as a **bounded event**. So:

> A cell that goes live with hostiles **starts an engagement**. It runs for `engagement_ticks`, resolves, and then the **room is spent** for `cooldown_ticks`.

The cooldown is keyed to the **room**, not the player. That is what makes *going somewhere new* the thing that produces a fight — the café you fought in is quiet; the café across the street is not. It is the whole of *"walk around your environment to encounter enemies."*

**Effect: time at war fell from 54% of a player's week to 1.8%.** Fights became roughly 5 a day, of 5 minutes each.

**These two numbers are the main tuning dial for how eventful the game feels.** Longer cooldown → rarer, more precious fights. Shorter → more ambient. They are one edit.

## 3a. The crowd band — scale without a scalpel

The feel prototype shows **"Four hostiles are here."** An exact count, refreshed every tick, cannot ship — and the reason is not squeamishness, it is a concrete attack:

> Sit in a café of twenty people. Watch the count fall from 4 to 3 at the exact moment one specific person stands up and walks out of the door. **You have just identified a player and their faction** — and the server never transmitted a position. The tick-to-tick delta did it alone.

But the *feeling* the count provides is real and worth keeping: you are at a concert, your phone says you are surrounded by **thousands**, and you do not leave the concert — that would be absurd. **Scale is awe, and awe is the game.**

What identifies a person is not the size of a crowd. It is **precision** and the **delta**. So:

> The crowd is a **coarse band**, sampled **once** when the engagement begins, and **never refreshed**.

- **Concert:** *"You are surrounded by thousands."* Intact. One person leaving cannot move "thousands" — the number is useless for identification *precisely because it is enormous*.
- **Café:** the lowest band carries **no number at all**. Someone leaves; the tell does not move, because it cannot.

This is lawful, not a compromise. I5 forbids a tell from which an identity can be inferred *"alone or by combining tells across ticks"* — a live counter fails on that last clause; a once-sampled band has no across-ticks channel to combine.

| Band | Hostiles | Note |
|---|---|---|
| `a_few` | < 12 | **Deliberately carries no number.** The difference between one hostile and six is exactly the difference this band exists to destroy. |
| `dozens` | 12–39 | |
| `scores` | 40–149 | |
| `hundreds` | 150–799 | |
| `thousands` | 800+ | The concert. |

**Residual risk, stated honestly:** a fight starting or stopping is itself a signal, and always was — in a room of exactly three people, a hostile leaving ends the fight, and that is observable regardless of any count. The engagement model blunts this (fights end on a timer, not on departure), but it does not eliminate it. In a crowded room it is nothing. In a room of three it is the irreducible cost of telling a player anything at all.

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
| `homes` | 9,000 | Mostly solitary — which is *why home is safe unless your neighbours play.* |
| `workplaces` | 1,200 | ~6 players per office. An office building, not a stadium. |
| `stations` | 80 | Dense, and brief. |
| `cafes` | 400 | Small rooms, a few players, for a lunch. |
| `commute_spread` | 60 ticks | ±30 min. **Nobody leaves at the same moment.** |
| `platform_dwell` | 10 ticks | 5 minutes on a platform, not two hours. |
| `cafe_dwell` | 40 ticks | A 20-minute lunch. |
| `homebody_pct` | 25% | Players who never commute. |

**Venue counts are a statement about PLAYER DENSITY, not architecture.** What matters is not how many cafés a city has — it is how many *players* share one. At ~1% penetration (10,000 players in a city of a million), a 38 m cell holding 200 residents holds about two players. The first version of these numbers put 30 players in every office and 250 on every platform *for two solid hours*. That was not a city, it was a stadium, and every number downstream inherited the lie.

**Known modelling flaws (do not draw conclusions past these):**
- Home assignment is uniform. Real housing is heavy-tailed — most cells hold 0–1 players, a few towers hold many.
- Nobody travels, visits, goes out at night, or takes a day off.
- **There are no mass events.** No concerts, no stadiums, no festivals — so the simulation never produces a `hundreds` or `thousands` crowd, and the most dramatic moment the game can offer is currently untested against real numbers.

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
| **Fights per player** | **5.1 a day**, 5 minutes each |
| **Time at war** | **1.8% of a player's week** |
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

## 8. Open items — decisions deferred, not made

Each of these is *currently* implemented one way and could go another. The column that matters is **when it stops being cheap**.

| # | Question | Status now | Deadline |
|---|---|---|---|
| **O1** | **Exact hostile count, or a band?** | Coarse band, sampled once per engagement | **Phase 2** (protocol freeze) |
| O2 | How often *should* a fight happen? | ~5/day, 5 min each — an accident of two constants, not a target | Phase 1 (cheap to retune forever, but the target should exist) |
| O3 | Cell size (39 bits, ~38 m) | Chosen for squareness, not from data | **Phase 2** |
| O4 | Do mass events (concerts, stadiums) behave? | **Answered, and they revealed O5.** The city now has concerts; they produce `hundreds`-scale crowds | done |
| **O5** | **Should a big room fight differently from a small one?** | **No — and that is probably wrong.** See below | Phase 1 |

### O5 — the concert is an anticlimax

Adding mass events to the simulation immediately exposed a flaw in the engagement model:

> **The room cooldown treats a stadium exactly like a café.**

You walk into a concert with five hundred people. You fight for five minutes. Then **the biggest room in the city is dead for two hours** — while you are still standing in it, surrounded, with the band playing. Over a four-hour concert the simulation produces exactly **two** fights.

That is the precise opposite of the intended feeling. A concert should be the most sustained, most overwhelming thing that ever happens to a player, and right now it is a five-minute skirmish followed by silence.

**The likely fix:** engagement length and cooldown should scale with the size of the crowd. A café is a skirmish; a stadium is a siege. A big room sustains a long fight and recovers slowly, or does not cool down at all while the crowd persists.

This is one function in `combat.zig`. It is cheap now.

**Note how this interacts with O1:** if a stadium becomes a sustained fight, the exact-count question gets *more* interesting, not less — a long fight in a huge crowd is exactly the case where a number is thrilling and harmless.

---

### O1 — the exact count, in full

**The case for the band (implemented):** an exact count refreshed every tick identifies people. Sit in a café of twenty, watch `4 → 3` at the moment one person stands and walks out, and you have named a player and their faction with no position ever transmitted. The delta does it alone (I1, I5).

**The case for the number (Connor, 2026-07-13):** it gives the player *scale*, and scale is the drama. Standing at a concert and being told you are surrounded by three thousand zombies is a genuinely great moment, and you would not leave a concert to go and identify someone — that would be absurd. *"Provided the radius is large enough, it shouldn't really matter."*

**That last clause is the actual insight, and it is probably right.** The identification risk is inversely proportional to how many people are in the room:

- In a crowd of 200, an exact count reveals nothing about any individual. The number is useless as a scalpel *precisely because it is enormous*.
- In a room of 4, it reveals everything.

**So the likely resolution is not "band vs. number" — it is a threshold.** Exact count above some occupancy (where it is safe and thrilling), wordless band below it (where it is a weapon). A band with unlimited resolution at the top *is* an exact count. That is a one-line change to `combat.crowdOf`.

**What it needs before it can be decided:** O4. The simulation has never produced a crowd larger than "dozens", so nobody has yet seen what the exciting case actually looks like in numbers.

**Awaiting:** the author's view (Connor's father).

---

## 9. Change log

| Date | Change | Why |
|---|---|---|
| 2026-07-13 | Momentum: total damage → damage per member | Total damage called the outnumbered side the winner |
| 2026-07-13 | `Outcome` size budget 8 → 12 bytes (A7.1) | Explicit `xp` field; inferring it from `damage > 0` silently stops paying a downed player |
| 2026-07-13 | `sortByCell` → total order (cell, then player) | Unstable sort made event order depend on arrival order |
| 2026-07-13 | splitmix64 written in-house, not `std.Random.DefaultPrng` | "Default" may change in any Zig release, breaking replay across a toolchain upgrade |
| 2026-07-13 | City attributes: one hash sliced → one mix per attribute | Home and faction were correlated; home cells could never hold a hostile |
| 2026-07-13 | **Combat became an engagement**: bounded, with a per-room cooldown | Combat had no end condition — a desk job was an eight-hour war, and the best XP strategy was a crowded workplace. Time at war: 54% → 1.8% |
| 2026-07-13 | Momentum: 3 states → 5 (`even`, `edge`, `winning`) | The prototype speaks in sentences that escalate, not in three buckets |
| 2026-07-13 | **Crowd band added** to the tell, sampled once per engagement | Gives the player scale ("surrounded by thousands") without the tick-to-tick delta that identifies a person leaving a room |
| 2026-07-13 | City: staggered commutes, realistic venue density | The old model marched the whole city onto 30 platforms at 07:00 and held it for two hours |
