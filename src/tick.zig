//! CORE (B1, B2). The tick (0.7).
//!
//! MODULE BOUNDARY: this file and `world.zig` are ONE MODULE (see world.zig's header). The
//! `Run` indexes below name rows in the world's own columns, and an index is meaningless
//! without its array (A5) -- so they never leave this module. The combat module, which IS a
//! separate module, receives slices of plain values and never an index (B5).
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

const Crowd = combat.Crowd;
const Momentum = combat.Momentum;
const PlayerId = world_mod.PlayerId;
const World = world_mod.World;

/// What one player learns when a tick resolves.
///
/// Everything here is either about you (your damage, your hp, your XP), or is categorical
/// and fight-wide (momentum, crowd). No identity, of anyone, at any point, ever (I1).
///
/// Note what is absent and must stay absent: an EXACT occupant count, refreshed each tick.
/// That is the thing that identifies a person -- watch it fall by one as a specific person
/// walks out of the door and you have named a player without a position ever being sent.
/// What is here instead is a coarse band, sampled once when the fight began. It gives the
/// player the scale of what they walked into and gives an observer nothing to watch move.
pub const Tell = struct {
    player: PlayerId, // u32
    damage: u16,
    hp: u16,
    xp: u16,
    momentum: Momentum, // u8
    /// How big the thing you walked into is. A BAND, sampled once when the fight began, and
    /// never refreshed -- so there is no tick-to-tick delta to watch, and a person leaving
    /// the room moves nothing (I5). See combat.Crowd.
    crowd: Crowd, // u8

    comptime {
        // THE SIZE GUARD (A7). One per presence in every live cell, every tick: the
        // second-hottest struct in the system. 4 + 2 + 2 + 2 + 1 + 1 = 12 bytes packed.
        //
        // The crowd band costs nothing: it occupies the byte that was padding.
        assert(@sizeOf(Tell) == 12);
    }
};

/// What a tick did, in aggregate.
///
/// These are WORLD-WIDE totals, and that is what makes them safe to look at (I3). "How many
/// cells were live across the entire city" is an operational number. "How many people are in
/// YOUR cell" is an identifying signal, and it is not here, is not computed, and is not
/// obtainable from anything that is.
///
/// A7.2: cold struct, size guard waived -- one per tick, never in a hot loop.
pub const TickResult = struct {
    tells: []Tell,
    /// Cells that reached quorum anywhere in the world.
    live_cells: u32,
    /// Cells actually hosting an engagement: live, hostile, and not spent.
    engaged_cells: u32,
    /// Engagements that BEGAN on this tick. A fight is an event, so this is the number that
    /// says how eventful the world is -- not what fraction of it is permanently at war.
    engagements_started: u32,
    /// Presences standing in one of those. A live cell with no hostiles, or a room that has
    /// already had its fight, contributes nobody.
    live_presences: u32,
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
/// TWO ALLOCATORS, ON PURPOSE (C3, C4).
///
/// `gpa` owns LONG-LIVED WORLD STATE -- the engagement table, which outlives this tick and
/// every tick after it.
///
/// `scratch` owns PER-TICK WORKING MEMORY -- the runs, the outcomes, the tells. It is meant
/// to be an arena that the caller resets wholesale at the end of the tick.
///
/// They are separate parameters because the first version of this took one allocator, the
/// simulation passed it the per-tick arena, and the arena then freed the world's engagement
/// table out from under the world at the end of every tick. It segfaulted on the next one.
/// That is C4 in a single line of code: one subsystem freeing memory owned by another. The
/// signature now makes the mistake impossible to make silently.
pub fn tick(
    world: *World,
    gpa: Allocator,
    scratch: Allocator,
    seed: u64,
    index: u64,
    rules: combat.Rules,
) Allocator.Error!TickResult {
    // Sort, scan, and discard everything below quorum. Sub-quorum runs do not survive
    // this call and nothing downstream can see them (I3).
    const runs = try world_mod.liveRuns(world, scratch, spatial.quorum);
    defer scratch.free(runs);

    const players = world.presences.items(.player);
    const factions = world.presences.items(.faction);
    const cells = world.presences.items(.cell);
    const hps = world.presences.items(.hp);

    // Everyone recovers. The people actually in a fight then take damage that dwarfs it.
    //
    // You heal when you are not fighting. There is no death and no permanence, because
    // nothing may be at stake that is worth stalking someone over.
    recover(hps, rules);

    // FIRST PASS: which rooms are actually fighting?
    //
    // A live cell is not necessarily a fight. It needs hostiles in it, and it needs to not
    // have had its fight already. Everything else is a room with people in it.
    var fighting: std.ArrayList(world_mod.Run) = .empty;
    defer fighting.deinit(scratch);

    var live_presences: usize = 0;
    for (runs) |run| {
        const start = run.start;
        const end = run.start + run.len;

        // A live cell full of your own faction is not a fight. Nothing happens, nobody
        // earns, nobody is told anything -- being among your own side is not an event.
        const heads = headCount(factions[start..end]);
        if (heads.humans == 0 or heads.zombies == 0) continue;

        // Is this room hosting an engagement right now, or is it spent?
        if (try engage(world, gpa, cells[start], index, rules, heads) == null) continue;

        try fighting.append(scratch, run);
        live_presences += run.len;
    }

    const outcomes = try scratch.alloc(combat.Outcome, live_presences);
    defer scratch.free(outcomes);

    // The tells belong to the caller, and come from the caller's scratch: they are the
    // product of one tick and they do not outlive it.
    const tells = try scratch.alloc(Tell, live_presences);
    errdefer scratch.free(tells);

    // SECOND PASS: resolve the fights.
    var written: usize = 0;
    var started_here: u32 = 0;

    for (fighting.items) |run| {
        const start = run.start;
        const end = run.start + run.len;
        const cell = cells[start]; // a run is one cell; that is what a run is

        // The head counts the fight STARTED with -- not the ones it has now. This is what
        // makes the crowd band immovable, and immovable is what makes it safe (I5).
        const at_start = world.engagements.get(cell).?;
        if (at_start.started == index) started_here += 1;

        const out = outcomes[written..][0..run.len];
        const momentum = combat.resolve(
            players[start..end],
            factions[start..end],
            hps[start..end],
            cell,
            seed,
            index,
            rules,
            out,
        );

        for (out, factions[start..end], hps[start..end], tells[written..][0..run.len]) |outcome, faction, *hp, *tell| {
            hp.* = outcome.hp_after;

            // THE ONLY XP IN THE GAME (H3). One call site, and it pays for one thing: a tick in
            // a live cell with a hostile present. Before this, the game awarded XP every tick
            // and then THREW IT AWAY -- the tell carried a delta out on the wire and nobody
            // kept a total. Everybody was level one forever.
            world_mod.award(world, outcome.player, outcome.xp);

            // Your hostiles are the other side's headcount. A Human is told how many Zombies
            // are here, in bands; a Zombie is told the reverse.
            const hostiles: u32 = switch (faction) {
                .human => at_start.zombies,
                .zombie => at_start.humans,
            };

            tell.* = .{
                .player = outcome.player,
                .damage = outcome.damage,
                .hp = outcome.hp_after,
                .xp = outcome.xp,
                .momentum = momentum,
                .crowd = combat.crowdOf(hostiles),
            };
        }

        written += run.len;
    }

    assert(written == live_presences);
    expire(world, index, rules);

    return .{
        .tells = tells,
        .live_cells = @intCast(runs.len),
        .engaged_cells = @intCast(fighting.items.len),
        .engagements_started = started_here,
        .live_presences = @intCast(written),
    };
}

const Heads = struct { humans: u16, zombies: u16 };

fn headCount(factions: []const world_mod.Faction) Heads {
    var humans: u32 = 0;
    var zombies: u32 = 0;
    for (factions) |faction| switch (faction) {
        .human => humans += 1,
        .zombie => zombies += 1,
    };
    return .{
        .humans = @intCast(@min(humans, std.math.maxInt(u16))),
        .zombies = @intCast(@min(zombies, std.math.maxInt(u16))),
    };
}

/// Is this room fighting on this tick?
///
/// A cell with hostiles in it starts an engagement. It runs for `engagement_ticks`, and then
/// the room is spent for `cooldown_ticks` -- during which the cell is live, and silent, and
/// nothing happens in it.
///
/// The room being spent, rather than the player being spent, is deliberate. It is what stops
/// a crowded office from being an eight-hour war, and it is what makes GOING SOMEWHERE NEW
/// the thing that produces a fight. The café you fought in is quiet; the café across the
/// street is not.
fn engage(
    world: *World,
    gpa: Allocator,
    cell: spatial.CellId,
    index: u64,
    rules: combat.Rules,
    heads: Heads,
) Allocator.Error!?world_mod.Engagement {
    const fresh: world_mod.Engagement = .{
        .started = index,
        .humans = heads.humans,
        .zombies = heads.zombies,
    };

    const entry = try world.engagements.getOrPut(gpa, cell);

    if (!entry.found_existing) {
        entry.value_ptr.* = fresh; // the fight starts now, and the crowd is sampled now
        return fresh;
    }

    const elapsed = index -| entry.value_ptr.started;

    // How long THIS room's fight lasts, from the crowd it began with. A café is a skirmish;
    // a stadium is a siege (O5).
    const occupants: u32 = @as(u32, entry.value_ptr.humans) + entry.value_ptr.zombies;
    const length = combat.engagementLength(occupants, rules);

    if (elapsed < length) return entry.value_ptr.*; // still fighting
    if (elapsed < length + rules.cooldown_ticks) return null; // spent

    // The room has rested. A new fight, and a newly sampled crowd.
    entry.value_ptr.* = fresh;
    return fresh;
}

/// Forget engagements that are over and rested. The world remembers nothing it does not
/// need (I7).
fn expire(world: *World, index: u64, rules: combat.Rules) void {
    var it = world.engagements.iterator();
    while (it.next()) |entry| {
        const occupants: u32 = @as(u32, entry.value_ptr.humans) + entry.value_ptr.zombies;
        const lifetime = combat.engagementLength(occupants, rules) + rules.cooldown_ticks;

        if (index -| entry.value_ptr.started > lifetime) {
            _ = world.engagements.remove(entry.key_ptr.*);
        }
    }
}

fn recover(hps: []u16, rules: combat.Rules) void {
    for (hps) |*hp| hp.* = @min(rules.max_hp, hp.* + rules.recovery_per_tick);
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

    const result = try tick(&world, gpa, gpa, 0xABC, 1, .default);
    defer gpa.free(result.tells);
    const tells = result.tells;

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

    const result_a = try tick(&a, gpa, gpa, 0xDEADBEEF, 42, .default);
    defer gpa.free(result_a.tells);
    const result_b = try tick(&b, gpa, gpa, 0xDEADBEEF, 42, .default);
    defer gpa.free(result_b.tells);
    const tells_a = result_a.tells;
    const tells_b = result_b.tells;

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

    const result_f = try tick(&forward, gpa, gpa, 7, 3, .default);
    defer gpa.free(result_f.tells);
    const result_b = try tick(&backward, gpa, gpa, 7, 3, .default);
    defer gpa.free(result_b.tells);

    try testing.expectEqualSlices(Tell, result_f.tells, result_b.tells);
    try testing.expectEqual(result_f.live_cells, result_b.live_cells);
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
        const result = try tick(&first, gpa, gpa, seed, i, .default);
        defer gpa.free(result.tells);
        for (result.tells) |t| checksum_first +%= @as(u64, t.damage) *% 31 +% @as(u64, t.xp);
    }

    // Same world, same seed, same indices. A different run of the same tape.
    var second: World = .empty;
    defer world_mod.deinit(&second, gpa);
    try buildCity(&second, gpa);

    var checksum_second: u64 = 0;
    i = 0;
    while (i < ticks_in_a_week) : (i += 1) {
        const result = try tick(&second, gpa, gpa, seed, i, .default);
        defer gpa.free(result.tells);
        for (result.tells) |t| checksum_second +%= @as(u64, t.damage) *% 31 +% @as(u64, t.xp);
    }

    try testing.expectEqual(checksum_first, checksum_second);
    try testing.expectEqualSlices(u16, first.presences.items(.hp), second.presences.items(.hp));
}

test "an empty world ticks" {
    // E4: nothing to do is not an error. It is an empty result.
    const gpa = testing.allocator;

    var world: World = .empty;
    defer world_mod.deinit(&world, gpa);

    const result = try tick(&world, gpa, gpa, 1, 1, .default);
    defer gpa.free(result.tells);

    try testing.expectEqual(@as(usize, 0), result.tells.len);
    try testing.expectEqual(@as(u32, 0), result.live_cells);
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

    const result = try tick(&world, gpa, gpa, 1, 1, .default);
    defer gpa.free(result.tells);

    try testing.expectEqual(@as(usize, 0), result.tells.len);
    try testing.expectEqual(@as(u32, 0), result.live_cells);
    for (world.presences.items(.hp)) |hp| try testing.expectEqual(@as(u16, 100), hp);
}

test "a fight ends" {
    // THE POINT OF THE ENGAGEMENT MODEL. Six people stand in a café and do not move. Before
    // this existed, they fought forever -- and a player who worked in a large office was at
    // war for eight hours a day, which is not a game, it is weather.
    const gpa = testing.allocator;
    const rules: combat.Rules = .default;

    var world: World = .empty;
    defer world_mod.deinit(&world, gpa);
    try buildCity(&world, gpa);

    // Six people: a skirmish. The length comes from the crowd BAND, never the exact count --
    // deriving it from the headcount leaked an invertible headcount through the clock (I5).
    const length = combat.engagementLength(6, rules);
    try testing.expectEqual(rules.engagement_ticks, length);

    var fought: u64 = 0;
    var i: u64 = 0;
    while (i < length * 3) : (i += 1) {
        const result = try tick(&world, gpa, gpa, 1, i, rules);
        defer gpa.free(result.tells);
        if (result.tells.len > 0) fought += 1;
    }

    // Nobody moved. The room is still full. The fight still stopped.
    try testing.expectEqual(length, fought);
}

test "a spent room is quiet, and the cell stays live throughout" {
    // The room going quiet is NOT the cell going below quorum. Six people are still standing
    // there and the cell is still live -- there is simply nothing happening in it. That
    // distinction matters: a cell that dropped below quorum must be silent (I3), but a spent
    // room is silent for an entirely different reason, and no player can tell the difference,
    // which is exactly as it should be.
    const gpa = testing.allocator;
    const rules: combat.Rules = .default;

    var world: World = .empty;
    defer world_mod.deinit(&world, gpa);
    try buildCity(&world, gpa);

    // Burn through the engagement.
    const length = combat.engagementLength(6, rules);
    var i: u64 = 0;
    while (i < length) : (i += 1) {
        const result = try tick(&world, gpa, gpa, 1, i, rules);
        gpa.free(result.tells);
    }

    // Mid-cooldown: the cell is live, and nothing is happening.
    const spent = try tick(&world, gpa, gpa, 1, length + 5, rules);
    defer gpa.free(spent.tells);

    try testing.expectEqual(@as(usize, 0), spent.tells.len);
    try testing.expectEqual(@as(u32, 0), spent.engaged_cells);
    try testing.expect(spent.live_cells > 0); // the room is still full of people
}

test "a rested room can fight again" {
    const gpa = testing.allocator;
    const rules: combat.Rules = .default;

    var world: World = .empty;
    defer world_mod.deinit(&world, gpa);
    try buildCity(&world, gpa);

    const length = combat.engagementLength(6, rules);
    var i: u64 = 0;
    while (i < length) : (i += 1) {
        const result = try tick(&world, gpa, gpa, 1, i, rules);
        gpa.free(result.tells);
    }

    // After the room has rested, the same café hosts another fight.
    const after = length + rules.cooldown_ticks + 1;
    const again = try tick(&world, gpa, gpa, 1, after, rules);
    defer gpa.free(again.tells);

    try testing.expect(again.tells.len > 0);
    try testing.expectEqual(@as(u32, 1), again.engaged_cells);
}

test "a crowded room of allies is never a fight" {
    // The have-a-crowded-job exploit, and the reason it is not one. Ten people share an
    // office and every one of them is a Human. The cell is live all day. Nothing ever
    // happens, and nobody earns a single point of XP.
    const gpa = testing.allocator;
    const p = spatial.default_precision;
    const office = spatial.cellFromKey(0x0FF1CE, p);

    var world: World = .empty;
    defer world_mod.deinit(&world, gpa);

    var id: u32 = 1;
    while (id <= 10) : (id += 1) {
        try addPresence(&world, gpa, office, id, .human, 100);
    }

    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        const result = try tick(&world, gpa, gpa, 1, i, .default);
        defer gpa.free(result.tells);
        try testing.expectEqual(@as(usize, 0), result.tells.len);
        try testing.expectEqual(@as(u32, 0), result.engaged_cells);
        try testing.expect(result.live_cells > 0);
    }
}

test "the engagement table forgets rooms it no longer needs" {
    // I7: the world remembers nothing it does not need. An engagement that is over and
    // rested is dropped, so the table tracks live rooms rather than growing forever.
    const gpa = testing.allocator;
    const rules: combat.Rules = .default;

    var world: World = .empty;
    defer world_mod.deinit(&world, gpa);
    try buildCity(&world, gpa);

    const first = try tick(&world, gpa, gpa, 1, 0, rules);
    gpa.free(first.tells);
    try testing.expectEqual(@as(usize, 1), world.engagements.count());

    // Long after the fight is over and the room has rested, the entry is gone.
    const length = combat.engagementLength(6, rules);
    const much_later = try tick(&world, gpa, gpa, 1, length + rules.cooldown_ticks + 100, rules);
    gpa.free(much_later.tells);

    // It fought again on that tick (the room had rested), so there is one fresh entry --
    // not an accumulation of every room that ever fought.
    try testing.expectEqual(@as(usize, 1), world.engagements.count());
}

test "the crowd band gives scale, and does not move when someone leaves" {
    // THE CONCERT, AND THE CAFÉ, IN ONE TEST.
    //
    // The concert: you are among thousands, and the game says so. That is the moment worth
    // having, and nothing here takes it away.
    //
    // The café: someone walks out, and the tell does not move. It cannot move, because it was
    // sampled when the fight began and is never refreshed. There is no delta to watch, so
    // there is no way to correlate a number with a person standing up (I1, I5).
    const gpa = testing.allocator;
    const p = spatial.default_precision;
    const cafe = spatial.cellFromKey(0xCAFE, p);

    var world: World = .empty;
    defer world_mod.deinit(&world, gpa);

    // Four humans, four zombies. A small room.
    var id: u32 = 1;
    while (id <= 4) : (id += 1) try addPresence(&world, gpa, cafe, id, .human, 100);
    while (id <= 8) : (id += 1) try addPresence(&world, gpa, cafe, id, .zombie, 100);

    const first = try tick(&world, gpa, gpa, 1, 0, .default);
    defer gpa.free(first.tells);

    // The lowest band carries no number at all: four hostiles and one hostile are the same
    // word, which is the entire point of the band.
    for (first.tells) |t| try testing.expectEqual(combat.Crowd.a_few, t.crowd);

    // A zombie leaves the room, mid-fight.
    const cells = world.presences.items(.cell);
    const players = world.presences.items(.player);
    for (players, cells) |player, *c| {
        if (@intFromEnum(player) == 8) c.* = spatial.cellFromKey(0xE15E, p);
    }

    const second = try tick(&world, gpa, gpa, 1, 1, .default);
    defer gpa.free(second.tells);

    // The humans' tell is IDENTICAL. Nobody can correlate the departure with anything.
    for (second.tells) |t| try testing.expectEqual(combat.Crowd.a_few, t.crowd);
}

test "a concert reads as thousands" {
    const gpa = testing.allocator;
    const p = spatial.default_precision;
    const arena = spatial.cellFromKey(0xC0DEC2, p);

    var world: World = .empty;
    defer world_mod.deinit(&world, gpa);

    // One human, and a great many zombies. You are at a concert, and you are surrounded.
    try addPresence(&world, gpa, arena, 1, .human, 100);

    var id: u32 = 2;
    while (id <= 1200) : (id += 1) try addPresence(&world, gpa, arena, id, .zombie, 100);

    const result = try tick(&world, gpa, gpa, 1, 0, .default);
    defer gpa.free(result.tells);

    for (result.tells) |t| {
        if (@intFromEnum(t.player) == 1) {
            // The human is told the truth about the scale of it, and nothing about anyone.
            try testing.expectEqual(combat.Crowd.thousands, t.crowd);
        } else {
            // Each zombie faces exactly one human. Not a number -- a word.
            try testing.expectEqual(combat.Crowd.a_few, t.crowd);
        }
    }
}

test "a stadium is a siege, and a cafe is a skirmish" {
    // O5. The concert anticlimax, and its fix. Before this, a room of five hundred people got
    // exactly the same five-minute fight as a room of four -- so you could walk into a
    // concert, fight briefly, and then stand surrounded in a dead room for two hours.
    const rules: combat.Rules = .default;

    const cafe = combat.engagementLength(6, rules);
    const bar = combat.engagementLength(40, rules);
    const concert = combat.engagementLength(500, rules);

    try testing.expect(cafe < bar);
    try testing.expect(bar < concert);

    // The café: minutes. The concert: hours.
    try testing.expect(cafe < 30);
    try testing.expect(concert >= 300);

    // And the floor holds for the smallest possible room.
    try testing.expect(combat.engagementLength(0, rules) >= rules.engagement_ticks);
}

test "THE DURATION OF A FIGHT IS NOT A HEADCOUNT" {
    // I5. The leak that the ruleset audit found, and the test that keeps it closed.
    //
    // The first version derived the length as `10 + 2 * occupants`. That is invertible: a
    // player who timed their own fight recovered an EXACT count of everyone in the room,
    // through the clock, without a single count ever being transmitted.
    //
    // Enormous care went into making the crowd a coarse band so no exact number could leak --
    // and then the number leaked out through the duration instead. A side channel does not care
    // which field you were guarding.
    //
    // Now: two rooms in the same band fight for exactly the same time. Inverting a duration
    // yields the band, which the player was already told, and nothing else.
    const rules: combat.Rules = .default;

    // Every crowd inside the `dozens` band is one duration.
    try testing.expectEqual(combat.engagementLength(12, rules), combat.engagementLength(39, rules));
    // Every crowd inside `hundreds` is one duration.
    try testing.expectEqual(combat.engagementLength(150, rules), combat.engagementLength(799, rules));
    // And a room of four is a room of eleven.
    try testing.expectEqual(combat.engagementLength(4, rules), combat.engagementLength(11, rules));

    // There are exactly five possible durations in the whole game -- one per band. A player who
    // measures one learns a band. They already had the band.
    var seen: [1000]u64 = undefined;
    var n: usize = 0;
    var occupants: u32 = 3;
    while (occupants < 1000) : (occupants += 1) {
        const length = combat.engagementLength(occupants, rules);
        var known = false;
        for (seen[0..n]) |s| {
            if (s == length) known = true;
        }
        if (!known) {
            seen[n] = length;
            n += 1;
        }
    }
    try testing.expect(n <= 5);
}
