//! CORE (B1, B2). The synthetic city (0.10).
//!
//! A first-class artifact, not a script. This is the entire product for the next two
//! phases: the only way to find out whether the game is COHERENT before a single phone
//! exists. Does quorum ever fire at realistic density? Is a commuter's day ever live? Does
//! combat converge or oscillate? Those questions are answerable now, for free, and they are
//! murderously expensive to answer in Phase 5.
//!
//! The city is PURE. It takes a seed and a tick index and says which room each person is
//! in. No clock, no randomness, no I/O (B3, B4) -- and, notably, NO COORDINATES. A room is
//! an identity, so a synthetic city needs no latitudes to be synthetic about. It fabricates
//! cell ids directly (spatial.cellFromKey), which means even the simulation cannot leak a
//! position it never had.
//!
//! WHAT IT MODELS
//!
//! People have homes, and most homes are shared with nobody. People have workplaces, and
//! workplaces are shared with many. People pass through stations at the same time as each
//! other, and drink coffee at the same few places at the same hour. Some people never leave
//! their neighbourhood at all.
//!
//! That is the whole model, and it is enough to produce the thing we actually want to
//! observe: a city where a suburb is silent all day, a platform is a warzone at 08:00, and
//! a café is briefly alive at lunch. Nobody authored that. It falls out of where people are.

const std = @import("std");
const combat = @import("combat.zig");
const spatial = @import("spatial.zig");
const rand = @import("rand.zig");
const world_mod = @import("world.zig");

const Allocator = std.mem.Allocator;

const CellId = spatial.CellId;
const World = world_mod.World;

/// PROVISIONAL, and provisional forever: this is a model of a city, not a city.
pub const Params = struct {
    population: u32 = 10_000,

    /// 30-second ticks: 120 an hour, 2880 a day.
    ticks_per_day: u64 = 2880,

    /// Homes are many and mostly solitary. This is what a dead suburb is made of.
    homes: u64 = 6000,
    /// Workplaces are few and crowded. This is where quorum lives.
    workplaces: u64 = 250,
    /// Stations are very few and briefly enormous. The 08:00 platform.
    stations: u64 = 30,
    /// Cafés: few, and alive for about an hour a day.
    cafes: u64 = 120,

    /// The fraction of the population who do not commute at all -- retired, unemployed,
    /// working from home, or simply not going anywhere today. Their day is spent in a cell
    /// that will almost never reach quorum, and the game must be honest about how many of
    /// them there are.
    homebody_pct: u32 = 25,

    pub const default: Params = .{};
};

/// Distinct key spaces, so a home and an office can never collide into the same room.
const home_base: u64 = 0x1000_0000;
const work_base: u64 = 0x2000_0000;
const station_base: u64 = 0x3000_0000;
const cafe_base: u64 = 0x4000_0000;

/// Each attribute of a person gets its OWN independent draw.
///
/// The first version of this took one mixed value `who` and sliced it: home was
/// `who % homes`, faction was `who & 1`. That is a trap, and the simulation walked straight
/// into it. `homes` is even, so `who % 6000` preserves the low bit of `who` -- which means
/// home cell and faction were CORRELATED, and every person sharing a home was necessarily
/// the same faction as their neighbours. Home cells could not contain a hostile. The fight
/// histogram read exactly 0.00% at night, every night, and it read that way for a reason
/// that had nothing whatsoever to do with the game.
///
/// A slice of a hash is not an independent draw. Mix per attribute.
fn attribute(player: u32, seed: u64, comptime which: u64) u64 {
    return rand.mix(rand.mix(seed ^ rand.mix(player)) ^ rand.mix(which));
}

/// CORE. Which faction a person carries. Chosen once, permanently, at registration.
pub fn factionFor(player: u32, seed: u64) world_mod.Faction {
    return if (attribute(player, seed, 6) & 1 == 0) .human else .zombie;
}

/// CORE. Where a person is, at a tick. Pure, and derived entirely from who they are.
pub fn cellFor(player: u32, tick: u64, params: Params, seed: u64) CellId {
    const home = home_base + (attribute(player, seed, 1) % params.homes);
    const work = work_base + (attribute(player, seed, 2) % params.workplaces);
    const station = station_base + (attribute(player, seed, 3) % params.stations);
    const cafe = cafe_base + (attribute(player, seed, 4) % params.cafes);

    const homebody = attribute(player, seed, 5) % 100 < params.homebody_pct;

    const day = tick / params.ticks_per_day;
    const into_day = tick % params.ticks_per_day;
    const hour = (into_day * 24) / params.ticks_per_day;

    // Weekends. The city empties, the offices go dark, and the game finds out what it is
    // like to be quiet -- which is a thing worth knowing before ten thousand real people
    // find out for us.
    const weekend = (day % 7) >= 5;

    if (homebody or weekend) {
        // Even a homebody goes for coffee. Without this the suburbs are not quiet, they are
        // dead, and a model that says "nothing ever happens to a quarter of your players"
        // should be made to say it honestly rather than by accident.
        if (hour == 11 and !homebody) return cell(cafe);
        return cell(home);
    }

    return switch (hour) {
        0...6 => cell(home),
        7...8 => cell(station), // the morning platform
        9...11 => cell(work),
        12 => cell(cafe), // lunch
        13...16 => cell(work),
        17...18 => cell(station), // the evening platform
        else => cell(home),
    };
}

fn cell(key: u64) CellId {
    return spatial.cellFromKey(key, spatial.default_precision);
}

/// CORE. Populate a world with a whole city, at rest, at full health.
pub fn populate(world: *World, gpa: Allocator, params: Params, seed: u64) Allocator.Error!void {
    try world_mod.ensureCapacity(world, gpa, params.population);

    var player: u32 = 0;
    while (player < params.population) : (player += 1) {
        try world_mod.add(world, gpa, .{
            .cell = cellFor(player, 0, params, seed),
            .player = @enumFromInt(player),
            .hp = (combat.Rules.default).max_hp,
            .faction = factionFor(player, seed),
        });
    }
}

/// CORE. Move the whole city to where it should be at `tick`.
///
/// Reads each row's player id rather than assuming row order, because the tick sorts the
/// world and a row is not a person. Allocates nothing.
pub fn advance(world: *World, params: Params, seed: u64, tick: u64) void {
    const players = world.presences.items(.player);
    const cells = world.presences.items(.cell);

    for (players, cells) |player, *c| {
        c.* = cellFor(@intFromEnum(player), tick, params, seed);
    }
}

const testing = std.testing;

test "the city is deterministic" {
    const params: Params = .default;
    try testing.expectEqual(cellFor(42, 1000, params, 7), cellFor(42, 1000, params, 7));
    try testing.expect(cellFor(42, 1000, params, 7) != cellFor(42, 1000, params, 8));
}

test "a person's day has a shape" {
    const params: Params = .default;
    const seed: u64 = 0xC17;

    // Find someone who actually commutes.
    var player: u32 = 0;
    const commuter = while (player < 100) : (player += 1) {
        const night = cellFor(player, 0, params, seed); // 00:00
        const workday = cellFor(player, 1200, params, seed); // 10:00
        if (night != workday) break player;
    } else unreachable;

    const ticks_per_hour = params.ticks_per_day / 24;

    const at_3am = cellFor(commuter, 3 * ticks_per_hour, params, seed);
    const at_8am = cellFor(commuter, 8 * ticks_per_hour, params, seed);
    const at_10am = cellFor(commuter, 10 * ticks_per_hour, params, seed);
    const at_11pm = cellFor(commuter, 23 * ticks_per_hour, params, seed);

    // Home at night, a station in the rush, work in the morning, home again.
    try testing.expectEqual(at_3am, at_11pm);
    try testing.expect(at_3am != at_8am);
    try testing.expect(at_8am != at_10am);
}

test "the weekend empties the offices" {
    const params: Params = .default;
    const seed: u64 = 0xC17;
    const ticks_per_hour = params.ticks_per_day / 24;

    var player: u32 = 0;
    const commuter = while (player < 100) : (player += 1) {
        if (cellFor(player, 0, params, seed) != cellFor(player, 1200, params, seed)) break player;
    } else unreachable;

    const weekday_10am = cellFor(commuter, 10 * ticks_per_hour, params, seed);
    const saturday_10am = cellFor(commuter, 5 * params.ticks_per_day + 10 * ticks_per_hour, params, seed);
    const saturday_midnight = cellFor(commuter, 5 * params.ticks_per_day, params, seed);

    try testing.expect(weekday_10am != saturday_10am);
    try testing.expectEqual(saturday_midnight, saturday_10am); // home, all day
}

test "a city populates and moves without allocating per tick" {
    const gpa = testing.allocator;
    const params: Params = .{ .population = 500 };

    var world: World = .empty;
    defer world_mod.deinit(&world, gpa);

    try populate(&world, gpa, params, 1);
    try testing.expectEqual(@as(usize, 500), world.presences.len);

    const capacity = world.presences.capacity;
    advance(&world, params, 1, 5000);
    try testing.expectEqual(capacity, world.presences.capacity);
}

test "faction is independent of where a person lives" {
    // THE REGRESSION. Home cell and faction were once derived from slices of the same mixed
    // value, and `homes` is even, so `who % homes` preserved the low bit that chose the
    // faction. Everyone sharing a home was the same faction, home cells could never hold a
    // hostile, and the simulation reported 0.00% fighting at night -- a number that looked
    // like a finding and was an artifact.
    //
    // Assert independence directly: among people who share a home, both factions occur.
    // A small city, so that sharing is guaranteed and the sample is not empty.
    const params: Params = .{ .homes = 50 };
    const seed: u64 = 0x51DE;

    var humans_sharing: u32 = 0;
    var zombies_sharing: u32 = 0;

    var player: u32 = 0;
    while (player < 1000) : (player += 1) {
        // Everyone who lives in the same home cell as each other.
        if (attribute(player, seed, 1) % params.homes != 0) continue;
        switch (factionFor(player, seed)) {
            .human => humans_sharing += 1,
            .zombie => zombies_sharing += 1,
        }
    }

    // Roughly twenty people share this home. If either faction is absent from it, the draws
    // are correlated again and the city is lying to us.
    try testing.expect(humans_sharing + zombies_sharing >= 5);
    try testing.expect(humans_sharing > 0);
    try testing.expect(zombies_sharing > 0);
}
