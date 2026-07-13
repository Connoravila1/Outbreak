//! CORE (B1, B2). The tick (0.7).
//!
//!     (world, seed, index) -> (world', tells)
//!
//! Pure. Deterministic. Byte-identical on replay (B7, B8). Time and randomness enter as
//! the two explicit parameters the shell chose; the core never asks what time it is.
//!
//! THE TICK IS SACRED (E5). Nothing here can fail except running out of memory. There is
//! no network condition, no malformed packet, no database stall, and no corrupt presence
//! that can abort it, delay it, or apply it halfway -- a presence that fails validation
//! was dropped at the shell and never arrived. The tick resolves the world from the data
//! it has.
//!
//! The whole of it: sort, scan runs, discard everything below quorum, resolve what
//! survives. There is no spatial index because there is no spatial question.

const std = @import("std");
const combat = @import("combat.zig");
const spatial = @import("spatial.zig");
const world_mod = @import("world.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Momentum = combat.Momentum;
const PlayerId = world_mod.PlayerId;
const World = world_mod.World;

/// What one player learns when a tick resolves.
///
/// Everything here is either about you (your damage, your hp, your XP) or is categorical
/// and fight-wide (momentum). There is no occupant count, no faction breakdown, no
/// hostile tally, no tenure list, and no identity -- of anyone, at any point, ever (I1).
///
/// Note what is absent and must stay absent: the number of people in your cell. A count is
/// not a position, but it is the first step toward one, and a count that could ever dip
/// below k is itself an identifying signal (I3, I5). It is not emitted, so it cannot leak.
pub const Tell = struct {
    player: PlayerId, // u32
    damage: u16,
    hp: u16,
    xp: u16,
    momentum: Momentum, // u8
    _pad: u8 = 0,

    comptime {
        // THE SIZE GUARD (A7). One per presence in every live cell, every tick: the
        // second-hottest struct in the system. 4 + 2 + 2 + 2 + 1 + 1 = 12 bytes packed.
        assert(@sizeOf(Tell) == 12);
    }
};

/// CORE. Resolve the whole world for one tick.
///
/// Presences whose cells are live have their hp updated in place; everyone else is
/// untouched, because nothing happened to them. The returned tells belong to the caller
/// and are freed with the same allocator (C1, C5).
///
/// A player in a cell below quorum receives no tell. Not an empty one, not a quiet one --
/// none. They are indistinguishable from a player alone in a field, because as far as this
/// function is concerned they are (I3).
pub fn tick(
    world: *World,
    gpa: Allocator,
    seed: u64,
    index: u64,
    rules: combat.Rules,
) Allocator.Error![]Tell {
    // Sort, scan, and discard everything below quorum. Sub-quorum runs do not survive
    // this call and nothing downstream can see them (I3).
    const runs = try world_mod.liveRuns(world, gpa, spatial.quorum);
    defer gpa.free(runs);

    var live_presences: usize = 0;
    for (runs) |run| live_presences += run.len;

    const outcomes = try gpa.alloc(combat.Outcome, live_presences);
    defer gpa.free(outcomes);

    const tells = try gpa.alloc(Tell, live_presences);
    errdefer gpa.free(tells);

    const players = world.presences.items(.player);
    const factions = world.presences.items(.faction);
    const cells = world.presences.items(.cell);
    const hps = world.presences.items(.hp);

    var written: usize = 0;
    for (runs) |run| {
        const start = run.start;
        const end = run.start + run.len;

        const out = outcomes[written..][0..run.len];
        const momentum = combat.resolve(
            players[start..end],
            factions[start..end],
            hps[start..end],
            cells[start], // every presence in a run shares one cell; that is what a run is
            seed,
            index,
            rules,
            out,
        );

        for (out, hps[start..end], tells[written..][0..run.len]) |outcome, *hp, *tell| {
            hp.* = outcome.hp_after;
            tell.* = .{
                .player = outcome.player,
                .damage = outcome.damage,
                .hp = outcome.hp_after,
                .xp = outcome.xp,
                .momentum = momentum,
            };
        }

        written += run.len;
    }

    assert(written == live_presences);
    return tells;
}

const testing = std.testing;

fn addPresence(w: *World, gpa: Allocator, cell: spatial.CellId, id: u32, faction: world_mod.Faction, hp: u16) !void {
    try world_mod.add(w, gpa, .{
        .cell = cell,
        .player = @enumFromInt(id),
        .hp = hp,
        .faction = faction,
    });
}

/// A café with three humans and three zombies in it, and a quiet street corner with two
/// people standing on it.
fn buildCity(w: *World, gpa: Allocator) !void {
    const p = spatial.default_precision;
    const cafe = spatial.cellFromKey(0xCAFE, p);
    const corner = spatial.cellFromKey(0x0C0C, p);

    try addPresence(w, gpa, cafe, 1, .human, 100);
    try addPresence(w, gpa, cafe, 2, .zombie, 100);
    try addPresence(w, gpa, cafe, 3, .human, 100);
    try addPresence(w, gpa, cafe, 4, .zombie, 100);
    try addPresence(w, gpa, cafe, 5, .human, 100);
    try addPresence(w, gpa, cafe, 6, .zombie, 100);

    // Below quorum. These two must not exist as far as the tick is concerned.
    try addPresence(w, gpa, corner, 7, .human, 100);
    try addPresence(w, gpa, corner, 8, .zombie, 100);
}

test "the tick resolves live cells and is silent everywhere else" {
    const gpa = testing.allocator;

    var world: World = .empty;
    defer world_mod.deinit(&world, gpa);
    try buildCity(&world, gpa);

    const tells = try tick(&world, gpa, 0xABC, 1, .default);
    defer gpa.free(tells);

    // Six people in the café get a tell. The two on the corner get nothing -- not an
    // empty tell, not a quiet one. Nothing.
    try testing.expectEqual(@as(usize, 6), tells.len);
    for (tells) |t| try testing.expect(@intFromEnum(t.player) <= 6);

    // And the two below quorum were not touched: no damage, no XP, no state change.
    const players = world.presences.items(.player);
    const hps = world.presences.items(.hp);
    for (players, hps) |player, hp| {
        if (@intFromEnum(player) >= 7) try testing.expectEqual(@as(u16, 100), hp);
    }
}

test "a tick replays byte-identically" {
    // THE EXIT CRITERION, in miniature (B8). Two worlds built identically, ticked with the
    // same seed and index, must produce identical tells and identical world state.
    const gpa = testing.allocator;

    var a: World = .empty;
    defer world_mod.deinit(&a, gpa);
    try buildCity(&a, gpa);

    var b: World = .empty;
    defer world_mod.deinit(&b, gpa);
    try buildCity(&b, gpa);

    const tells_a = try tick(&a, gpa, 0xDEADBEEF, 42, .default);
    defer gpa.free(tells_a);
    const tells_b = try tick(&b, gpa, 0xDEADBEEF, 42, .default);
    defer gpa.free(tells_b);

    try testing.expectEqualSlices(Tell, tells_a, tells_b);
    try testing.expectEqualSlices(u16, a.presences.items(.hp), b.presences.items(.hp));
}

test "the same facts in a different order produce the same tick" {
    // The property that a replay test alone would NOT catch. Two servers handed the same
    // eight people in a different sequence must resolve identically -- otherwise arrival
    // order is a hidden input to the game, and it would only ever show up as two nodes
    // quietly disagreeing about a fight.
    const gpa = testing.allocator;
    const p = spatial.default_precision;
    const cafe = spatial.cellFromKey(0xCAFE, p);

    var forward: World = .empty;
    defer world_mod.deinit(&forward, gpa);
    try addPresence(&forward, gpa, cafe, 1, .human, 100);
    try addPresence(&forward, gpa, cafe, 2, .zombie, 90);
    try addPresence(&forward, gpa, cafe, 3, .human, 80);
    try addPresence(&forward, gpa, cafe, 4, .zombie, 70);

    var backward: World = .empty;
    defer world_mod.deinit(&backward, gpa);
    try addPresence(&backward, gpa, cafe, 4, .zombie, 70);
    try addPresence(&backward, gpa, cafe, 3, .human, 80);
    try addPresence(&backward, gpa, cafe, 2, .zombie, 90);
    try addPresence(&backward, gpa, cafe, 1, .human, 100);

    const tells_f = try tick(&forward, gpa, 7, 3, .default);
    defer gpa.free(tells_f);
    const tells_b = try tick(&backward, gpa, 7, 3, .default);
    defer gpa.free(tells_b);

    try testing.expectEqualSlices(Tell, tells_f, tells_b);
}

test "a week of ticks replays from (world, seed, index)" {
    const gpa = testing.allocator;
    const seed: u64 = 0x0B5E55ED;

    // 2 tick/minute * 60 * 24 = 2880 ticks in a simulated day. A week is 20160.
    const ticks_in_a_week: u64 = 20160;

    var first: World = .empty;
    defer world_mod.deinit(&first, gpa);
    try buildCity(&first, gpa);

    var checksum_first: u64 = 0;
    var i: u64 = 0;
    while (i < ticks_in_a_week) : (i += 1) {
        const tells = try tick(&first, gpa, seed, i, .default);
        defer gpa.free(tells);
        for (tells) |t| checksum_first +%= @as(u64, t.damage) *% 31 +% @as(u64, t.xp);
    }

    // Same world, same seed, same indices. A different run of the same tape.
    var second: World = .empty;
    defer world_mod.deinit(&second, gpa);
    try buildCity(&second, gpa);

    var checksum_second: u64 = 0;
    i = 0;
    while (i < ticks_in_a_week) : (i += 1) {
        const tells = try tick(&second, gpa, seed, i, .default);
        defer gpa.free(tells);
        for (tells) |t| checksum_second +%= @as(u64, t.damage) *% 31 +% @as(u64, t.xp);
    }

    try testing.expectEqual(checksum_first, checksum_second);
    try testing.expectEqualSlices(u16, first.presences.items(.hp), second.presences.items(.hp));
}

test "an empty world ticks" {
    // E4: nothing to do is not an error. It is an empty result.
    const gpa = testing.allocator;

    var world: World = .empty;
    defer world_mod.deinit(&world, gpa);

    const tells = try tick(&world, gpa, 1, 1, .default);
    defer gpa.free(tells);

    try testing.expectEqual(@as(usize, 0), tells.len);
}

test "a world entirely below quorum ticks silently" {
    const gpa = testing.allocator;
    const p = spatial.default_precision;

    var world: World = .empty;
    defer world_mod.deinit(&world, gpa);

    // A thousand people, every one of them alone or in a pair. A whole city of near
    // misses. The tick says nothing at all.
    var id: u32 = 0;
    var key: u64 = 0;
    while (key < 500) : (key += 1) {
        const cell = spatial.cellFromKey(key, p);
        try addPresence(&world, gpa, cell, id, .human, 100);
        id += 1;
        try addPresence(&world, gpa, cell, id, .zombie, 100);
        id += 1;
    }

    const tells = try tick(&world, gpa, 1, 1, .default);
    defer gpa.free(tells);

    try testing.expectEqual(@as(usize, 0), tells.len);
    for (world.presences.items(.hp)) |hp| try testing.expectEqual(@as(u16, 100), hp);
}
