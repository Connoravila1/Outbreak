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

    /// VENUE COUNTS ARE A STATEMENT ABOUT PLAYER DENSITY, NOT ABOUT ARCHITECTURE.
    ///
    /// What matters is not how many cafés a city has -- it is how many PLAYERS share one.
    /// A game with 10,000 players in a city of a million has roughly 1% penetration, so a
    /// 38-metre cell holding 200 residents holds about two players. These numbers are chosen
    /// to produce that, and the first version of them did not: 250 workplaces for 7,500
    /// commuters put thirty players in every office, and 30 stations put 250 on every
    /// platform for two solid hours. That was not a city. It was a stadium.
    ///
    /// Homes: mostly solitary. This is what a quiet suburb is made of, and it is why your
    /// home is safe unless your neighbours happen to play.
    homes: u64 = 9000,
    /// Workplaces: a handful of players each. An office building, not a stadium.
    workplaces: u64 = 1200,
    /// Stations: genuinely dense, genuinely briefly. The platform is the one place in a real
    /// city where a hundred strangers stand still together.
    stations: u64 = 80,
    /// Cafés: small rooms, a few players, for the length of a lunch.
    cafes: u64 = 400,

    /// How widely commute times are spread, in ticks. 60 ticks = 30 minutes either side.
    commute_spread: u64 = 60,
    /// How long a person stands on a platform. 10 ticks = 5 minutes.
    platform_dwell: u64 = 10,
    /// How long lunch lasts. 40 ticks = 20 minutes.
    cafe_dwell: u64 = 40,

    /// MASS EVENTS. A concert, a stadium, a festival.
    ///
    /// The most dramatic moment the game can offer -- "you are surrounded by hundreds" --
    /// and until this existed the simulation had never produced one, so nobody had seen what
    /// it does to quorum, to the tick, or to a player's evening.
    ///
    /// A real stadium holds fifty thousand people; at ~1% player penetration that is five
    /// hundred players in one place. Which is exactly the point: a crowd this size is where
    /// an exact hostile count stops being an instrument for finding a person and starts
    /// being pure scale (see GAME_RULES O1).
    venues: u64 = 2,
    /// The fraction of players who go out to a mass event on an event night.
    event_pct: u32 = 10,

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
const venue_base: u64 = 0x5000_0000;

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
    const venue = venue_base + (attribute(player, seed, 9) % params.venues);

    const homebody = attribute(player, seed, 5) % 100 < params.homebody_pct;
    const goes_out = attribute(player, seed, 10) % 100 < params.event_pct;

    const day = tick / params.ticks_per_day;
    const now = tick % params.ticks_per_day; // ticks into the day
    const per_hour = params.ticks_per_day / 24;

    // NOBODY LEAVES AT THE SAME MOMENT. The first version of this model marched the entire
    // city onto the platform at 07:00 and held it there for two hours. Real platforms fill
    // and empty over minutes, and the difference is not cosmetic: a synchronised city
    // manufactures crowds that do not exist, and every number downstream inherits the lie.
    const stagger = attribute(player, seed, 7) % (2 * params.commute_spread);
    const offset = stagger -| params.commute_spread; // 0 .. 2*spread, centred

    const leaves = 7 * per_hour + offset;
    const returns = 17 * per_hour + offset;
    const lunches = 12 * per_hour + (attribute(player, seed, 8) % per_hour);

    // Weekends. The city empties, the offices go dark, and the game finds out what it is like
    // to be quiet -- a thing worth knowing before ten thousand real people find out for us.
    const weekend = (day % 7) >= 5;

    // Friday and Saturday night. The one time this city does something at scale.
    //
    // Nobody leaves a concert to go and identify a stranger. That would be absurd, and it is
    // the whole reason a crowd this size is a different kind of place: the scale is the
    // experience, and at this scale no number tells you anything about any person.
    const event_night = (day % 7) == 4 or (day % 7) == 5;
    if (goes_out and event_night and now >= 19 * per_hour and now < 23 * per_hour) {
        return cell(venue);
    }

    if (homebody or weekend) {
        // Even a homebody goes out for coffee.
        if (now >= lunches and now < lunches + params.cafe_dwell) return cell(cafe);
        return cell(home);
    }

    // The morning platform: dense, and brief. You are not on it for two hours.
    if (now >= leaves and now < leaves + params.platform_dwell) return cell(station);
    if (now >= returns and now < returns + params.platform_dwell) return cell(station);

    if (now >= lunches and now < lunches + params.cafe_dwell) return cell(cafe);

    if (now >= leaves + params.platform_dwell and now < returns) return cell(work);

    return cell(home);
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
/// The city says WHERE each person is. The world decides how that is stored, and does the
/// writing -- a module never mutates another module's arrays (C4).
pub fn advance(world: *World, params: Params, seed: u64, tick: u64) void {
    const Where = struct {
        params: Params,
        seed: u64,
        tick: u64,

        fn cellOf(ctx: @This(), player: world_mod.PlayerId, _: CellId) CellId {
            return cellFor(@intFromEnum(player), ctx.tick, ctx.params, ctx.seed);
        }
    };

    world_mod.relocate(world, Where{ .params = params, .seed = seed, .tick = tick }, Where.cellOf);
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
    const at_10am = cellFor(commuter, 10 * ticks_per_hour, params, seed);
    const at_11pm = cellFor(commuter, 23 * ticks_per_hour, params, seed);

    // Home at night, at a desk in the morning, home again by bedtime.
    try testing.expectEqual(at_3am, at_11pm);
    try testing.expect(at_3am != at_10am);

    // And somewhere in the morning they passed through a station -- briefly. Not for two
    // hours: a platform is a place you stand for five minutes, and the model now says so.
    var on_a_platform: u64 = 0;
    var t: u64 = 6 * ticks_per_hour;
    while (t < 9 * ticks_per_hour) : (t += 1) {
        const at = cellFor(commuter, t, params, seed);
        if (at != at_3am and at != at_10am) on_a_platform += 1;
    }

    try testing.expect(on_a_platform > 0);
    try testing.expectEqual(params.platform_dwell, on_a_platform);
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
    try testing.expectEqual(@as(usize, 500), world_mod.population(&world));

    const capacity = world_mod.capacityOf(&world);
    advance(&world, params, 1, 5000);
    try testing.expectEqual(capacity, world_mod.capacityOf(&world));
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

test "a mass event produces a crowd worth being awed by" {
    // O4. Until mass events existed, the simulation had never produced a crowd bigger than
    // "dozens" -- so the most dramatic moment the game can offer had never occurred in it,
    // and the exact-count question (O1) had no evidence to be decided against.
    const gpa = std.testing.allocator;
    const params: Params = .default;
    const seed: u64 = 0xC0FFEE;

    var world: World = .empty;
    defer world_mod.deinit(&world, gpa);
    try populate(&world, gpa, params, seed);

    // Friday, 20:00. Two venues, and a tenth of the city is out.
    const friday_night = 4 * params.ticks_per_day + 20 * (params.ticks_per_day / 24);
    advance(&world, params, seed, friday_night);

    // Count how many people are standing in the largest room in the city.
    var counts: std.AutoHashMapUnmanaged(CellId, u32) = .empty;
    defer counts.deinit(gpa);

    for (world_mod.cellsOf(&world)) |c| {
        const entry = try counts.getOrPut(gpa, c);
        entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
    }

    var biggest: u32 = 0;
    var it = counts.iterator();
    while (it.next()) |entry| biggest = @max(biggest, entry.value_ptr.*);

    // Hundreds of people, in one room. Roughly half of them hostile to any given player,
    // which lands the tell in the `hundreds` band -- the awe, with no number that could ever
    // point at a person.
    try std.testing.expect(biggest > 300);
    try std.testing.expectEqual(combat.Crowd.hundreds, combat.crowdOf(biggest / 2));
}
