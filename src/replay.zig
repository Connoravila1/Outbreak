//! CORE (B1, B2). Replay (1.4): rebuild a world from a journal and run it again.
//!
//! "This tool will catch more bugs than any test you write on purpose." The roadmap is right
//! about that, and the reason is structural: a replay does not test a property you thought
//! of. It tests the ONLY property that matters -- that the world is a function of its inputs
//! -- and it tests it against every tick that ever happened, including the ones nobody would
//! have thought to write a case for.
//!
//! A tick that cannot be replayed from (world, seed, index) is broken (B8), and a log you
//! cannot replay is not a log. It is a large file.
//!
//! Pure: bytes in, world out. No disk, no clock (B3).

const std = @import("std");
const combat = @import("combat.zig");
const journal = @import("journal.zig");
const spatial = @import("spatial.zig");
const tick_mod = @import("tick.zig");
const world_mod = @import("world.zig");

const Allocator = std.mem.Allocator;

const World = world_mod.World;

pub const Error = journal.Error || Allocator.Error || error{NoRoster};

/// What a replay produced. Compare two of these; if they differ, the tick is not a function
/// of its inputs, and everything downstream of it is a rumour.
pub const Summary = struct {
    ticks: u64 = 0,
    tells: u64 = 0,
    /// Folds every field of every tell of every tick. One bit anywhere moves it.
    checksum: u64 = 0,
};

/// CORE. Replay a journal from the beginning, and hand back the world it ends in.
///
/// The caller owns the world and deinits it (C5).
pub fn replay(gpa: Allocator, bytes: []const u8, rules: combat.Rules) Error!struct {
    world: World,
    summary: Summary,
} {
    const opened = try journal.open(bytes);

    var world: World = .empty;
    errdefer world_mod.deinit(&world, gpa);

    var summary: Summary = .{};
    var have_roster = false;

    var cursor = opened.cursor;
    while (try journal.next(&cursor)) |record| switch (record) {
        .roster => |roster| {
            // A snapshot REPLACES the world. Replay begins at the most recent one, because a
            // pruned journal has no earlier history to begin from -- that is what pruning is.
            world_mod.deinit(&world, gpa);
            world = .empty;
            try world_mod.ensureCapacity(&world, gpa, roster.count);

            var i: usize = 0;
            while (i < roster.count) : (i += 1) {
                const entry = journal.rosterEntry(roster.payload, i);
                try world_mod.add(&world, gpa, .{
                    // Nowhere. The next tick record says where they really were; until then
                    // nobody is anywhere, which is the honest state of affairs -- and crucially
                    // they are not all in a room TOGETHER.
                    .cell = spatial.nowhere,
                    .player = entry.player,
                    .hp = entry.hp,
                    .faction = entry.faction,
                });
            }
            have_roster = true;
        },

        .engagements => |e| {
            // The fights that were in progress when the world was written down. Without
            // these, replaying from a snapshot would restart every fight that was running --
            // and resolve them all differently.
            var i: usize = 0;
            while (i < e.count) : (i += 1) {
                const entry = journal.engagementEntry(e.payload, i);
                try world.engagements.put(gpa, entry.cell, entry.engagement);
            }
        },

        .tick => |t| {
            if (!have_roster) return Error.NoRoster;

            try place(&world, gpa, t.payload, t.count);

            const result = try tick_mod.tick(&world, gpa, gpa, opened.header.seed, t.index, rules);
            defer gpa.free(result.tells);

            summary.ticks += 1;
            summary.tells += result.tells.len;
            for (result.tells) |tell| {
                summary.checksum = summary.checksum *% 31 +%
                    @as(u64, @intFromEnum(tell.player)) +%
                    @as(u64, tell.damage) *% 7 +%
                    @as(u64, tell.hp) *% 13 +%
                    @as(u64, tell.xp) *% 17 +%
                    @as(u64, @intFromEnum(tell.momentum)) *% 19 +%
                    @as(u64, @intFromEnum(tell.crowd)) *% 23;
            }
        },
    };

    return .{ .world = world, .summary = summary };
}

/// Move everyone to where the journal says they were.
///
/// A row is not a person: the tick sorts the world, so row order changes under us and a
/// player must be found by id, never by position (A5's spirit -- an index is meaningless
/// without its array).
///
/// The first version of this looked each player up with a linear scan, which is O(n^2) per
/// tick: at ten thousand players that is a hundred million comparisons every thirty seconds,
/// and the simulation simply stopped. It is a map now. (G2: the profiler indicted it
/// immediately, by never finishing.)
fn place(world: *World, gpa: Allocator, payload: []const u8, count: u32) Allocator.Error!void {
    const players = world.presences.items(.player);
    const cells = world.presences.items(.cell);

    var rows: std.AutoHashMapUnmanaged(world_mod.PlayerId, u32) = .empty;
    defer rows.deinit(gpa);
    try rows.ensureTotalCapacity(gpa, @intCast(players.len));

    for (players, 0..) |player, row| {
        rows.putAssumeCapacity(player, @intCast(row));
    }

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const r = journal.report(payload, i);
        if (rows.get(r.player)) |row| cells[row] = r.cell;
    }
}

const testing = std.testing;

/// A journal of a small city living its life, for `ticks` ticks.
fn recordCity(gpa: Allocator, ticks: u64, seed: u64) !std.ArrayList(u8) {
    return recordCityWithSnapshots(gpa, ticks, seed, ticks + 1); // one snapshot, at the start
}

fn recordCityWithSnapshots(gpa: Allocator, ticks: u64, seed: u64, snapshot_every: u64) !std.ArrayList(u8) {
    const city = @import("city.zig");
    // A dense little town, not a sparse city: the point of this test is to replay a world in
    // which things actually HAPPEN. A replay of an empty night proves nothing.
    const params: city.Params = .{
        .population = 400,
        .homes = 60,
        .workplaces = 20,
        .stations = 5,
        .cafes = 10,
        .venues = 1,
    };

    var live: World = .empty;
    defer world_mod.deinit(&live, gpa);
    try city.populate(&live, gpa, params, seed);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try journal.writeHeader(&out, gpa, .{ .seed = seed, .precision = spatial.default_precision });
    try journal.writeRoster(
        &out,
        gpa,
        0,
        live.presences.items(.player),
        live.presences.items(.faction),
        live.presences.items(.hp),
    );

    var i: u64 = 0;
    while (i < ticks) : (i += 1) {
        city.advance(&live, params, seed, i);

        // Snapshot the world periodically. This is what lets retention delete the past and
        // still leave a journal that replays (I7).
        if (i > 0 and i % snapshot_every == 0) {
            const fights = try world_mod.engagementsSorted(&live, gpa);
            defer gpa.free(fights.cells);
            defer gpa.free(fights.engagements);

            try journal.writeSnapshot(
                &out,
                gpa,
                i,
                live.presences.items(.player),
                live.presences.items(.faction),
                live.presences.items(.hp),
                fights.cells,
                fights.engagements,
            );
        }

        // The shell writes down what it was handed, BEFORE the core touches it. This is what
        // makes the log an input rather than a summary of an output.
        try journal.writeTick(
            &out,
            gpa,
            i,
            live.presences.items(.player),
            live.presences.items(.cell),
        );

        const result = try tick_mod.tick(&live, gpa, gpa, seed, i, .default);
        gpa.free(result.tells);
    }

    return out;
}

test "a world replays from its journal, byte for byte" {
    // THE PHASE 1 EXIT CRITERION, in miniature: the world is restored from disk into an
    // identical world. If this ever fails, the tick is not a function of its inputs and every
    // recorded fight in the system is a rumour.
    const gpa = testing.allocator;

    var log = try recordCity(gpa, 300, 0xB0A7);
    defer log.deinit(gpa);

    var first = try replay(gpa, log.items, .default);
    defer world_mod.deinit(&first.world, gpa);

    var second = try replay(gpa, log.items, .default);
    defer world_mod.deinit(&second.world, gpa);

    try testing.expectEqual(first.summary.checksum, second.summary.checksum);
    try testing.expectEqual(@as(u64, 300), first.summary.ticks);
    try testing.expect(first.summary.tells > 0); // the city actually did something

    // And the worlds themselves are identical, column for column.
    try testing.expectEqualSlices(u16, first.world.presences.items(.hp), second.world.presences.items(.hp));
    try testing.expectEqualSlices(
        world_mod.PlayerId,
        first.world.presences.items(.player),
        second.world.presences.items(.player),
    );
}

test "a replayed world matches the world that was lived" {
    // Stronger, and the one that actually matters: the world reconstructed from the log is
    // the same world that produced the log. Not "a valid world" -- THE world.
    const gpa = testing.allocator;
    const seed: u64 = 0x11FE;
    const ticks: u64 = 200;

    const city = @import("city.zig");
    const params: city.Params = .{
        .population = 400,
        .homes = 60,
        .workplaces = 20,
        .stations = 5,
        .cafes = 10,
        .venues = 1,
    };

    // Live it.
    var lived: World = .empty;
    defer world_mod.deinit(&lived, gpa);
    try city.populate(&lived, gpa, params, seed);

    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(gpa);

    try journal.writeHeader(&log, gpa, .{ .seed = seed, .precision = spatial.default_precision });
    try journal.writeRoster(
        &log,
        gpa,
        0,
        lived.presences.items(.player),
        lived.presences.items(.faction),
        lived.presences.items(.hp),
    );

    var i: u64 = 0;
    while (i < ticks) : (i += 1) {
        city.advance(&lived, params, seed, i);
        try journal.writeTick(&log, gpa, i, lived.presences.items(.player), lived.presences.items(.cell));
        const result = try tick_mod.tick(&lived, gpa, gpa, seed, i, .default);
        gpa.free(result.tells);
    }

    // Replay it.
    var restored = try replay(gpa, log.items, .default);
    defer world_mod.deinit(&restored.world, gpa);

    // Both worlds are sorted by (cell, player) after their last tick, so they compare
    // directly. Every hit point of every player, identical.
    try testing.expectEqualSlices(u16, lived.presences.items(.hp), restored.world.presences.items(.hp));
    try testing.expectEqualSlices(
        world_mod.PlayerId,
        lived.presences.items(.player),
        restored.world.presences.items(.player),
    );
}

test "a pruned journal still replays the ticks it kept" {
    // Retention deletion (I7) must not break replay of what remains. A log we can no longer
    // read is not a deletion policy, it is data loss.
    const gpa = testing.allocator;

    var log = try recordCityWithSnapshots(gpa, 120, 0x9E7, 50);
    defer log.deinit(gpa);

    var pruned = try journal.prune(gpa, log.items, 110);
    defer pruned.deinit(gpa);

    try testing.expect(pruned.items.len < log.items.len); // the past is actually gone

    var result = try replay(gpa, pruned.items, .default);
    defer world_mod.deinit(&result.world, gpa);

    // Replay resumed from the snapshot at tick 100 and ran the twenty ticks that survived.
    try testing.expectEqual(@as(u64, 20), result.summary.ticks);
}

test "a pruned journal reconstructs the same world the full journal does" {
    // The claim retention actually has to make: deleting the past must not change the
    // present. If the snapshot is faithful, the world that comes out of a pruned journal is
    // the world that comes out of the whole one -- and the deleted history is genuinely
    // surplus rather than quietly load-bearing.
    const gpa = testing.allocator;

    var log = try recordCityWithSnapshots(gpa, 120, 0x5EED, 50);
    defer log.deinit(gpa);

    var full = try replay(gpa, log.items, .default);
    defer world_mod.deinit(&full.world, gpa);

    var pruned = try journal.prune(gpa, log.items, 110);
    defer pruned.deinit(gpa);

    var partial = try replay(gpa, pruned.items, .default);
    defer world_mod.deinit(&partial.world, gpa);

    try testing.expectEqualSlices(
        u16,
        full.world.presences.items(.hp),
        partial.world.presences.items(.hp),
    );
}

test "a snapshot taken mid-fight replays the fight, not a new one" {
    // THE BUG THIS RECORD EXISTS TO PREVENT.
    //
    // A snapshot that records everyone's hit points but NOT the fights they are standing in
    // the middle of is not a snapshot of the world. Replaying from it restarts every running
    // fight -- fresh engagement, fresh crowd sample, fresh cooldown -- and produces a world
    // that is entirely plausible and completely wrong.
    //
    // It is a nasty one, because it only shows up when a snapshot happens to land inside an
    // engagement, which most of them do not. It would have been a rare, unreproducible
    // divergence in production.
    const gpa = testing.allocator;

    // Snapshot every 3 ticks: with fights lasting far longer than that, snapshots land inside
    // engagements constantly, and the bug has nowhere to hide.
    var log = try recordCityWithSnapshots(gpa, 60, 0xF16A7, 3);
    defer log.deinit(gpa);

    var full = try replay(gpa, log.items, .default);
    defer world_mod.deinit(&full.world, gpa);

    // Prune to a boundary deep inside the run: replay must resume from a snapshot that was
    // taken while fights were in progress.
    var pruned = try journal.prune(gpa, log.items, 45);
    defer pruned.deinit(gpa);

    var resumed = try replay(gpa, pruned.items, .default);
    defer world_mod.deinit(&resumed.world, gpa);

    // The world that resumed mid-fight is the world that never stopped.
    try testing.expectEqualSlices(
        u16,
        full.world.presences.items(.hp),
        resumed.world.presences.items(.hp),
    );
    try testing.expect(resumed.world.engagements.count() > 0); // there really were fights
}
