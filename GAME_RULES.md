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
| Level curve | `level n costs n² × 100 XP` | Quadratic: levelling slows without ever stopping. At 10 XP/tick in a fight — level 2 is ~7 minutes of fighting, level 10 ~3 hours, level 50 ~3 days of accumulated combat. **A shape you can argue with**, rather than a number tuned in the dark. |
| `engagement_ticks` | **10** (5 min) | The **floor**: shortest a fight can be, however small the room. |
| `engagement_dozens_ticks` | **60** (30 min) | A busy bar. |
| `engagement_scores_ticks` | **180** (90 min) | |
| `engagement_hundreds_ticks` | **360** (3 h) | A siege. |
| `engagement_max_ticks` | **480** (4 h) | The concert. |

**Duration comes from the crowd *band*, never the exact count.** The first version was `10 + 2 × occupants` — which is invertible. A player timing their own fight recovered an **exact headcount of everyone in the room**, through the clock, with no count ever transmitted. Enormous care went into making the crowd a coarse band so no number could leak, and the number leaked out through the duration instead. **A side channel does not care which field you were guarding.** There are now exactly five possible durations in the game — one per band — so inverting one tells a player the band they were already told.
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

## 5a. GPS cadence & battery — `src/gps.zig`

**Full detail: [MOBILE_ROADMAP.md](MOBILE_ROADMAP.md) §2.** Summary here.

**Battery is a hard constraint (G5)** and the one criterion that can fail Phase 3 outright.

### A correction, recorded

The first policy suspended reporting in a vehicle — *"moving means you are nowhere."* **That was a game-design decision wearing an engineer's coat.** A parked car is a place. A crowded carriage holds three real humans in one room. *"Is a vehicle a room?"* is the designer's question; **the battery does not get to answer it.** The policy now contains **no rule about vehicles**.

### The four levers (none of them are Zig)

Battery is radio duty cycle and wakeups, not CPU. **Being fast is worth nothing; being asleep is worth everything.**

1. **Fix only when the room might have changed** — the hardware motion trigger says so for free.
2. **A geofence, offloaded to the sensor hub.** The app sleeps; the *chip* watches. **The biggest lever.**
3. **Report only when the room CHANGES.** The server already keeps your last room if you say nothing.
4. **No socket when quiet.** Quiet is the normal state. A push wakes us when the cell goes live.

### The numbers (a simulated commuter's day)

| | Dead v1.0 spec | Now |
|---|---|---|
| GPS fixes/day | 17,280 | **304** |
| Sends/day | 2,880 | **16** |
| Socket open | all day | **12.5 min** |

**It proves the radio is no longer the problem — i.e. that the real measurement is worth taking.** It does not prove the phase passes. Only eight hours on real hardware does that (3.5).

| Knob | Value |
|---|---|
| `base_seconds` | 30 (one tick) |
| `armed_seconds` | 3600 — a geofence is best-effort, so we look once an hour regardless |
| `engaged_seconds` | 60 — so walking out of a fight registers |
| `patience` | 2 unchanged fixes before we arm and sleep |

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
| **Fights per player** | **5.4 a day** |
| **Time at war** | **4.1% of a player's week** |
| Crowd bands seen | `a few`, `dozens`, `hundreds` (concerts) |
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
| ~~O1~~ | ~~Exact hostile count, or a band?~~ | **DECIDED 2026-07-13: generic. No specific number of people.** The author's call. Implemented as the crowd band. | closed |
| O2 | How often *should* a fight happen? | ~5/day, 5 min each — an accident of two constants, not a target | Phase 1 (cheap to retune forever, but the target should exist) |
| **O3** 🟡 | **Cell size (39 bits)** — was **the most consequential unvalidated number in the project** | **The flicker fear did not materialise on the first device measured.** A Pixel 10 Pro, indoors (the hard case — the game is played indoors), on a diagnostic build fixing GPS once a second: a **stationary phone held its room** across dozens of fixes, at **~4 m reported accuracy** — comfortably inside the 24 m cell — with **zero room changes after the initial GPS convergence**, and normal in-room movement did not cross a boundary either. The concern was #2 below: *"a player sitting still would flicker between cells and break their own quorum."* On this hardware, they do not. **The number holds.** What is NOT yet proven: cheaper phones with worse receivers, dense-urban and deep-indoor environments, and the *feel* half of O3 (*"six people in this coffee shop"*), which needs multiplayer that does not exist yet. So: **de-risked, not universally closed.** Re-measure on a low-end device before it decides anything for launch. *(The three original forces for coarser, kept for the record: (1) GPS barely works indoors; (2) the flicker fear, now not seen; (3) privacy. Against them, the fantasy wants the cell to BE the room. The battery argument was withdrawn — with geofencing, GNSS costs 0.02%/8 h.)* Validated with the on-phone readout: `./android/package.sh --diagnostic`. | **Phase 3 — measured 2026-07-14** |
| **O6** | Make cell precision **server-directed** | Planned for Phase 2's handshake | Phase 2 |
| **O8** | **Accessibility overlay** — a custom-rendered surface is invisible to TalkBack/VoiceOver | Owed. An ambient *text* game a blind player could otherwise play perfectly. | Before launch |
| **O9** | **iOS graphics path** — EGL/GLES does not exist on iOS | **Answered, and it is not a rewrite.** `CAMetalLayer` + **ANGLE's Metal backend, statically linked**: the GLES renderer, shaders, and atlas stay **byte-identical**. Already hardware-proven on a foreign OS through ANGLE. Six bounded tasks, not a second graphics stack. **ANGLE would be a second sanctioned dependency (F1/F6) and needs its own written justification at the import site.** | Phase 5 |
| **O10** | Interaction polish: fling, momentum, long-press, selection, haptics | The long tail a native toolkit gives free and a custom renderer must earn — **once, not twice** | Phase 3+ |
| **O7** | **Rooms that bind to places** — the café is the room, the concert expands to the venue | Not built. A safe version exists; the obvious version does not | Post-Phase 3 |
| O4 | Do mass events (concerts, stadiums) behave? | **Answered, and they revealed O5.** The city now has concerts; they produce `hundreds`-scale crowds | done |
| ~~O5~~ | ~~Should a big room fight differently from a small one?~~ | **DONE.** A café is a skirmish, a stadium is a siege: engagement length scales with the crowd | closed |

### O7 — rooms that bind to places (and why the obvious way is forbidden)

**The vision (Connor, 2026-07-13):** on the street, a grid cell is fine. But if you step into Frank's coffee shop, the room should *be* the shop — you're insulated to that spot, and there's a lovely dynamic in escaping the street by ducking inside. At a concert, the room should expand to the whole venue.

**How Pokémon Go does it:** a hierarchical grid (Google S2 — level 17 allocates PokéStops, level 14 decides Gym counts, level 20 handles spawns) *plus* a **place database**. The POIs come from Ingress, crowdsourced from players over four years. The grid decides how many; the database decides where.

**What that cost them, and why it is our I6:**

Niantic built that database by centring reward destinations on **where people already congregate** — which sounds category-blind and safe. It produced PokéStops on at least three individual graves at Arlington National Cemetery, and at the US Holocaust Memorial Museum, the 9/11 Memorial, the Vietnam Veterans Memorial, and Auschwitz. In Ingress, players could *battle for control of former concentration camps* — Auschwitz, Dachau, Sachsenhausen. Removal was reactive: a report form and a takedown queue.

Nobody sat down and enumerated memorials. They derived places from where humans gather — the most innocent-sounding method available — **and it still put a game objective on a war grave.** "Crowd-derived" is not a safety property.

**What made it harmful was H2, not the derivation.** Niantic put *rewards* at those places, so players travelled to them. We have no destination: a cell is worth nothing without *k* humans already in it, and nothing in the game ever says "go here." A room that pays nothing draws nobody, even if it coincides with a memorial.

**So:**

- **FORBIDDEN — venue polygons.** Frank's shop as a shape with walls requires enumerating buildings as map features. That is I6 with no wiggle room, and it is the exact machinery that put a PokéStop on a grave.
- **POSSIBLE — precision that adapts per region, derived from our own presence data.** Coarsening is a bit-shift and a coarse cell contains its children by construction, so: a region where people dwell in tight persistent clusters uses *finer* cells (the café is roughly its own room); a concert region uses *coarser* ones (the whole venue is one room); a sparse village coarsens until quorum is reachable (that is I8, already built). Coordinate-free, map-free, category-blind, no third-party data (F1), and it **names nothing** — the system never knows it is Frank's shop, only that people cluster tightly and stay a long time there.

**The honest limitation:** a grid does not follow walls. A shop straddling a cell boundary stays split, and no amount of adaptive precision fixes that. Only polygons do, and polygons are the thing we cannot have. You get *"the room is about the size of the shop"*, never *"the room is the shop."*

**Not needed now. O6 is the enabling primitive** — building server-directed precision in Phase 2 keeps this door open at no cost.

### O6 — kill the cell-size deadline

Cell size is the *only* knob with a hard deadline, and the deadline exists for one reason: the client quantizes GPS to a cell and sends it, so the precision is baked into shipped clients. Change it afterwards and old clients keep sending cells at the old precision — and because precision is carried in the sentinel, a 39-bit cell and a 37-bit cell are **different rooms by construction**. Old and new clients would never meet.

**Fix: the server tells the client what precision to use, in the session handshake.**

Then cell size becomes a server config value. And because the server can always *coarsen* a cell it receives (a bit-shift), even a mid-rollout mix of client versions still shares rooms — coarsen everything to the common precision and the world stays whole. Only going *finer* than a live client's precision requires an app update.

This does **not** mean collecting finer location "just in case": the client still quantizes to exactly the precision it was asked for, and the raw coordinate still dies on the phone (B6).

Cost: one field in the handshake. It turns the project's only hard deadline into a config change.

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

**DECIDED, 2026-07-13 — the author's answer: keep it generic. No specific number of people.**

So the crowd band as implemented is the shipping design, and the threshold idea above is *not* pursued. The tell says *"you are surrounded"*, *"dozens"*, *"hundreds"* — it never says *"four"*. This closes the question in the strictest direction, which is also the direction the ruleset would have forced (I1, I5); it is now settled by intent rather than by law, which is better.

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
| 2026-07-13 | Mass events added to the city | The most dramatic moment the game offers had never occurred in simulation |
| 2026-07-13 | **Engagement length scales with the crowd** (O5) | A concert was a 5-minute skirmish followed by two dead hours. A café is a skirmish; a stadium is a siege |
| 2026-07-13 | **O1 decided: generic, never a number** (author's call) | The tell says "surrounded", never "four" |
| 2026-07-13 | `GAME_DESIGN.md` §3.4 amended (J3) | It said "combat continues while both sides remain present" — a climate, not an event |
| 2026-07-13 | **Fight duration derived from the crowd BAND, not the headcount** | `10 + 2 × occupants` is **invertible**: timing your own fight recovered an exact headcount of the room, through the clock, with no count ever transmitted. Found in the ruleset audit. |
| 2026-07-14 | **XP is now actually kept** | The game awarded XP every tick and **threw it away** — the tell carried a delta out on the wire and nobody kept a total. Everyone was level one, forever. |
| 2026-07-14 | Progress rows preallocated at join | Creating them lazily meant a world at war did hundreds of allocating hash-map inserts per tick and a sleeping world did none — **a timing difference opened by a feature that had nothing to do with timing.** |
