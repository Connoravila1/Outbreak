# Outbreak

A location-based faction game. Zig server, native mobile clients.

The game is built around one refusal: **it never tells anyone where anyone is.**

You choose a faction, permanently. You then live your ordinary life, and the game reads only which ~38-metre *cell* of the world you are in. Most of the time it says nothing. When enough people occupy one cell — a café, a platform, a bar — the cell goes live, and if hostiles are present, combat resolves silently on the server. You learn that a fight is happening and how it is going. You never learn who you are fighting. There is no map pin, no bearing, no distance, no name.

That refusal is not a safety feature bolted onto a game. It is the reason the game is safe, the reason it resists cheating, and the reason it is interesting — those turn out to be the same property.

## Status

**Phase 0 — the core, in isolation.** No network, no phone, no map, no server. The game currently runs entirely as a test suite and a simulation.

Phase 0 is complete. Its exit criterion — ten thousand synthetic players through a simulated week, any tick replaying deterministically, zero leaks — is met.

## Build

Requires **Zig 0.16.0**, pinned.

```
zig build test    # the test suite, under a leak-detecting allocator
zig build         # compiles; fails on any size-guard or forbidden-construct regression
```

A leak fails the build. It is not a warning.

## The simulation

```
zig build sim -Doptimize=ReleaseFast
```

Runs ten thousand synthetic players through a simulated week, replays it, and checks the replay is byte-identical. Prints numbers: tick cost against budget, live cells, and a per-hour histogram of how much of a player's day is spent in a fight.

It prints numbers because that is all it needs to do. It is not a visualiser and will not become one.

## Layout

The core is pure: plain data in arrays, transformed by free functions. No I/O, no clock, no randomness, no allocation that isn't handed an allocator. The shell is thin and holds everything impure.

| | |
|---|---|
| `src/spatial.zig` | Quantization, the cell, the coarsening rule, and *k*. The one module that touches a coordinate — and only in `spatial/geohash.zig`, for the length of one expression. |
| `src/world.zig` | The world as columns. Group-by-cell, and the quorum filter. |
| `src/combat.zig` | Combat and progression. Pure transform over one cell's occupants. |
| `src/tick.zig` | `(world, seed, index) → (world', tells)`. Pure, deterministic, replayable. |
| `src/integrity.zig` | Plausibility and farm detection, as pure functions. |
| `src/territory.zig` | Sustained clan presence, decaying. Confers no reward. |
| `src/city.zig` | The synthetic city. Pure, and has no coordinates. |
| `src/sim.zig` | The driver. Owns the clock, the allocator, and stdout. |
| `src/guard.zig` | Compile-time enforcement of the rules below. |

## What the compiler refuses to build

Some rules cannot be left to code review, because the code that breaks them looks reasonable on the day someone writes it. These fail at compile time:

- **No geometry.** No distance, bearing, heading, radius, neighbour search, or inverse quantizer. A cell id is a group-by key, not a compressed coordinate. There is no function that converts one back toward a latitude, and its absence is deliberate.
- **No coordinate in the core.** A float cannot appear in a file classified core. The raw coordinate dies at the shell boundary, so the core cannot leak a location it was never given.
- **No automated punishment, no attestation.** A suspicion score dampens XP and does nothing else. There is no ban, no root detection, no mock-location check, no device fingerprint.
- **Every hot struct asserts its exact size.** Adding a `bool` to the hot struct costs eight bytes per player per tick, and fails the build rather than passing review.

## Balance

Every tunable number, why it holds its current value, and what it costs to change it: **[GAME_RULES.md](GAME_RULES.md)**.

Nobody has played this yet. Most of those numbers are wrong, and the document says so.
