# Outbreak

A location-based faction game. Zig server, native mobile clients.

A mobile game where you choose a faction, human or zombie, held permanent for the game. You then live your ordinary life, and the game reads only which ~38-metre *cell* of the world you are in. Most of the time it says nothing. When enough people occupy one cell — a café, a platform, a bar — the cell goes live, and if hostiles are present, combat resolves silently on the server. You learn that a fight is happening and how it is going.

## Status

**Phase 0 — the core, in isolation.** No network, no phone, no map, no server. The game currently runs entirely as a test suite and a simulation.

Phase 0 is complete (10k synthetic players through a simulated week, deterministic replay, zero leaks). Phases 1–2 are done: the world persists to disk and restarts identically, and byte- and time-identical silence is proven over a real TCP socket.

**Phase 3 (the phone) is running on real hardware, and its exit criterion — the battery number — has been met.** The Android host, the GLES renderer, the glyph engine, the boot sequence, GPS, a background foreground-service, and the client socket all work on a device. A real GPS fix becomes a room and the coordinate dies in one function; the phone connects to the server, reports its room, and receives the tell; and networked combat resolves across the wire. The GPS now sleeps once your room settles and wakes when you move. The cell size (O3) has been measured in the field, the 8-hour battery number has been taken on real hardware (below), and the phone raises a categorical *"your cell is live"* notification the moment a fight begins — a crowd band and nothing else. Still owed for the phase: a real registration flow.

## Build

Requires **Zig 0.16.0**, pinned.

```
zig build test    # the test suite, under a leak-detecting allocator
zig build         # compiles; fails on any size-guard or forbidden-construct regression
```


## The simulation

```
zig build sim -Doptimize=ReleaseFast
```

Runs ten thousand synthetic players through a simulated week, replays it, and checks the replay is byte-identical. Prints numbers: tick cost against budget, live cells, and a per-hour histogram of how much of a player's day is spent in a fight.

It prints numbers because that is all it needs to do. It is not a visualiser and will not become one.

## Layout

Every file is classified **core** (pure: no I/O, no clock, no randomness, no hidden allocation) or **shell** (impure, thin, and quarantined). There is no third category and nothing unclassified.

The directories are **not** `core/` and `shell/`. Files are grouped by the *decision they hide* — quantization, combat rules, persistence, integrity — because those are the things that change, and a module exists to absorb a change rather than to sort files by a property. The clearest case is `spatial/`: `cell.zig` is core and `geohash.zig` is shell, and they are two halves of one sealed decision. Splitting them across `core/` and `shell/` would tear a module in half to satisfy a filing system.

The classification is enforced, not documented: `src/guard.zig` holds the registry, and the compile-time coordinate ban keys off it. A file that is not classified is not guarded, and the build says so.

| File | | |
|---|---|---|
| `src/spatial.zig` | **core** | Quantization, the cell, the coarsening rule, and *k*. |
| `src/spatial/cell.zig` | **core** | The cell id and its encoding. Pure `u64` work. |
| `src/spatial/geohash.zig` | **shell** | **The only file in the system permitted to hold a coordinate**, and it holds one for the length of one expression. |
| `src/world.zig` | **core** | The world as columns. Group-by-cell, and the quorum filter. |
| `src/combat.zig` | **core** | Combat, progression, engagements. Pure transform over one cell's occupants. |
| `src/tick.zig` | **core** | `(world, seed, index) → (world', tells)`. Deterministic, replayable. |
| `src/integrity.zig` | **core** | Plausibility and farm detection, as pure functions. |
| `src/territory.zig` | **core** | Sustained clan presence, decaying. Confers no reward. |
| `src/journal.zig` | **core** | What the world writes down (a room and a tick), and when it deletes it. |
| `src/replay.zig` | **core** | Rebuild a world from its journal and prove it is the same world. |
| `src/city.zig` | **core** | The synthetic city. Pure, and has no coordinates. |
| `src/rand.zig` | **core** | Deterministic mixing, pinned by us so replay never drifts. |
| `src/store.zig` | **shell** | The disk. Four functions. It handles bytes and cannot understand a record. |
| `src/sim.zig` | **shell** | The driver. Owns the clock, the allocator, and stdout. |
| `src/guard.zig` | — | Compile-time enforcement of the rules below, and the classification registry. |

## What the compiler refuses to build

Some rules cannot be left to code review, because the code that breaks them looks reasonable on the day someone writes it. These fail at compile time:

- **No geometry.** No distance, bearing, heading, radius, neighbour search, or inverse quantizer. A cell id is a group-by key, not a compressed coordinate. There is no function that converts one back toward a latitude, and its absence is deliberate.
- **No coordinate in the core.** A float cannot appear in a file classified core. The raw coordinate dies at the shell boundary, so the core cannot leak a location it was never given.
- **No automated punishment, no attestation.** A suspicion score dampens XP and does nothing else. There is no ban, no root detection, no mock-location check, no device fingerprint.
- **Every hot struct asserts its exact size.** Adding a `bool` to the hot struct costs eight bytes per player per tick, and fails the build rather than passing review.

## Android

```
zig build android
```

Cross-compiles the core to a static library for `aarch64-linux-android` and `x86_64-linux-android`, in `ReleaseSafe` — this code parses bytes from a server the phone cannot verify, inside a JVM where a panic is a corrupted runtime rather than a debuggable crash, so the overflow and bounds checks stay on.

The C ABI is `include/outbreak.h`. **Ten functions.** What is absent is the point: there is no combat, no tick, no quorum, no XP, no damage in that library. The phone can quantize a GPS reading into a room, put bytes on a wire, and read bytes off it. It cannot resolve a fight, because the code to resolve one is not there — and the build fails if anyone makes it reachable.

`outbreak_quantize()` is the only function in the entire system, on either side of the network, that accepts a latitude. **The platform shell must take the location, call it, and drop the coordinate in the same function.** The server has no coordinate and cannot leak one; the phone is the only place a coordinate ever exists, so the phone is the only place it can leak from.

## Battery

**From ~10% of a phone battery every 8 hours to a measured 0.009%** — and not one line of it was an optimization in the usual sense. It came from asking the GPS for a fix less often, and from noticing that a phone that has not moved has not changed rooms.

It used to say *projected 0.50%*, and that a projection does not count until it is measured on real hardware over eight real hours. So it was: **Pixel 10 Pro, screen off, still, eight hours — the app drew 0.472 mAh, with the GPS awake for four and a half minutes the whole night.** About 0.009% of the battery. The exit criterion is *under 5%*; the design clears it by roughly 550×.

The reduction came from noticing that the game never wanted the data. It doesn't follow you — it only learns which room you're in, and only when you stop. **The thing that makes it private is the thing that makes it cheap.**

## Balance

Every tunable number, why it holds its current value, and what it costs to change it: **[GAME_RULES.md](GAME_RULES.md)**.

Nobody has played this yet. Most of those numbers are wrong, and the document says so.
