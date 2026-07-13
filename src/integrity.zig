//! CORE (B1, B2). Integrity, as pure functions (0.8).
//!
//! A sealed module (D1). Plausibility and farm-detection heuristics are decisions that
//! will move constantly once real data exists, so they live behind this boundary and
//! nothing outside it learns how suspicion is computed.
//!
//! These are core transforms, written now, not a subsystem bolted on later. They are cheap
//! here and impossible to retrofit -- retrofitting them would mean discovering, two phases
//! from now, that the data we needed was never kept.
//!
//! WE DECLINE THE ATTESTATION ARMS RACE (H6). There is no client attestation here, no root
//! detection, no mock-location check, no signature verification. All are bypassable, all
//! break real players' phones, all demand perpetual maintenance -- and all are unnecessary,
//! because no location carries a reward worth spoofing toward (H2). The guard fails the
//! build if anyone adds one.
//!
//! NOTHING HERE IS PUNITIVE (H4). This module computes a number. It does not ban, suspend,
//! flag, or restrict anybody, and there is no function in this codebase that turns a
//! suspicion score into an automated punishment. A legitimate player's receiver once
//! reported fifty thousand kilometres in one second; a false positive here must cost a real
//! person slightly less XP, never their account.
//!
//! ---
//!
//! WHY PLAUSIBILITY IS NOT WHAT IT USUALLY IS
//!
//! Everywhere else in the industry, "implausible movement" means: this player travelled a
//! distance that no body could travel in that time. That is a statement about distance, and
//! distance does not exist here -- no coordinates, no bearings, no adjacency, no inverse
//! quantizer (A9, I2). The standard implementation is unavailable to us BY LAW, and no
//! amount of cleverness inside this file will conjure it, because the information was
//! destroyed at the shell boundary on purpose.
//!
//! What survives quantization is CHURN, and churn needs no geometry:
//!
//!   - a real person occupies few distinct rooms in a window, and LINGERS in them;
//!   - they move in runs -- home, home, home, train, train, office, office, office;
//!   - a spoofer hopping between wherever the fights are changes room almost every tick
//!     and dwells nowhere.
//!
//! So we score dwell, not distance. It is a weaker signal than geometry would give, and
//! that is the correct trade: the geometry we gave up is the same geometry that would let
//! this server be subpoenaed for where someone was standing.
//!
//! It is also honest about its own weakness. A commuter on a fast train churns. This score
//! must never do more than dampen.

const std = @import("std");
const spatial = @import("spatial.zig");
const world_mod = @import("world.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const CellId = spatial.CellId;
const PlayerId = world_mod.PlayerId;

/// 0 = ordinary. 255 = absurd. A soft signal and nothing more (H4).
pub const Suspicion = u8;

/// PROVISIONAL. Tuned against real data in Phase 6, not against imagination now.
pub const Params = struct {
    /// A history shorter than this says nothing at all. Silence is not evidence.
    min_history: usize = 8,

    /// Ticks a player must dwell in a room before it looks like a place they are, rather
    /// than a place they passed through.
    settled_dwell: u32 = 3,

    /// The most XP dampening a suspicion score may ever cause, as a percentage.
    ///
    /// A false positive costs a real player a small fraction of their XP (H4). It does not
    /// cost them the game, and there is no value of this constant that could -- 100 would
    /// zero their earnings for a tick, not touch their account.
    max_dampening_pct: u8 = 40,

    /// Sightings a pair must share before co-occurrence means anything. Two accounts seen
    /// together twice are two friends having coffee.
    min_co_sightings: u32 = 20,

    pub const default: Params = .{};
};

/// CORE. Score a player's cell history for churn (H4).
///
/// Pure, and takes no tick index: the history is already in order, and an index would be an
/// unused parameter -- a lie about what the function depends on. Determinism comes from the
/// data, not from a number we pass alongside it.
///
/// The score is high when a player is constantly in a different room and settles in none.
/// It is low when they linger, which is what people do.
pub fn suspicion(history: []const CellId, params: Params) Suspicion {
    // Not enough to say anything. A quiet history is not a suspicious one, and treating it
    // as suspicious would punish new players for being new.
    if (history.len < params.min_history) return 0;

    var transitions: u32 = 0;
    var settled_ticks: u32 = 0;
    var dwell: u32 = 1;

    for (history[1..], history[0 .. history.len - 1]) |now, before| {
        if (now == before) {
            dwell += 1;
        } else {
            transitions += 1;
            if (dwell >= params.settled_dwell) settled_ticks += dwell;
            dwell = 1;
        }
    }
    if (dwell >= params.settled_dwell) settled_ticks += dwell;

    // Churn: the fraction of ticks that were a move rather than a stay.
    const span: u32 = @intCast(history.len);
    const churn = (transitions * 100) / span;

    // Settledness: the fraction of ticks spent in a room the player actually stayed in.
    const settled = (settled_ticks * 100) / span;

    // A player who moves constantly and settles nowhere is the shape we are looking for.
    // A player who moves a lot but settles somewhere is a commuter.
    const raw: i32 = @as(i32, @intCast(churn)) - @as(i32, @intCast(settled));
    if (raw <= 0) return 0;

    const scaled = (@as(u32, @intCast(raw)) * 255) / 100;
    return @intCast(@min(scaled, 255));
}

/// CORE. The ONLY consequence a suspicion score is permitted to have (H4).
///
/// It reduces XP, by a bounded fraction, and that is the end of it. There is no ban here,
/// no suspension, no shadow-restriction, and no quorum exclusion that would let a false
/// positive erase somebody from a room they are really standing in.
///
/// If you are reading this because you want to add a punitive action: the answer is no, and
/// the guard will fail your build (H4, H6).
pub fn dampenXp(xp: u16, score: Suspicion, params: Params) u16 {
    const pct: u32 = (@as(u32, score) * params.max_dampening_pct) / 255;
    const kept: u32 = 100 - pct;
    return @intCast((@as(u32, xp) * kept) / 100);
}

/// One account seen in one room at one tick. The only location data the system retains,
/// and only for as long as these windows need it (I7).
///
/// There is no coordinate here to retain, breach, or subpoena -- because there is no
/// coordinate anywhere.
pub const Sighting = struct {
    cell: CellId, // u64
    player: PlayerId, // u32
    tick: u32,

    comptime {
        // THE SIZE GUARD (A7). One per player per tick across the retention window.
        // 8 + 4 + 4 = 16 bytes packed.
        assert(@sizeOf(Sighting) == 16);
    }
};

/// A pair of accounts that keep turning up in the same room.
///
/// `apart` is the number of sightings where one was seen and the other was not. A farm's
/// distinguishing feature is not that its accounts are together often -- friends are
/// together often -- but that they are NEVER APART (H5).
pub const Pair = struct {
    a: PlayerId, // u32
    b: PlayerId, // u32
    together: u32,
    apart: u32,

    comptime {
        // THE SIZE GUARD (A7). One per suspicious pair; bounded by the window, not by the
        // population.
        assert(@sizeOf(Pair) == 16);
    }
};

/// CORE. Farm detection by co-occurrence (H5). The one integrity feature genuinely worth
/// building.
///
/// The real attack is not a lone spoofer -- a lone spoofer arrives at silence, because a
/// cell is worth nothing without k real humans in it (H2). The real attack is k sock-puppet
/// accounts spoofed into one cell together, manufacturing a quorum out of nobody.
///
/// The defence needs no attestation and no device fingerprint. It is a property of the
/// data: a cluster of accounts that only ever appear together, and never apart, is not a
/// friend group. Friends go home. Colleagues go home. A farm has no home to go to, because
/// its accounts have no lives -- they exist only when they are being farmed.
///
/// Returns pairs whose co-occurrence is total, sorted, so the result is deterministic. The
/// caller owns the slice (C1, C5). This names nobody and does nothing to anybody: it is
/// evidence for a human to look at, not a verdict (H4).
pub fn coOccurringPairs(
    gpa: Allocator,
    sightings: []const Sighting,
    params: Params,
) Allocator.Error![]Pair {
    // How many times each account was seen at all.
    var seen: std.AutoHashMapUnmanaged(PlayerId, u32) = .empty;
    defer seen.deinit(gpa);

    // How many times each pair was seen in the same room at the same tick.
    var together: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer together.deinit(gpa);

    for (sightings) |s| {
        const entry = try seen.getOrPut(gpa, s.player);
        entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
    }

    // Sightings that share a (tick, cell) are co-occurrences. The caller hands them to us
    // grouped -- the same sort-and-scan the tick already does, and for the same reason.
    var start: usize = 0;
    while (start < sightings.len) {
        var end = start + 1;
        while (end < sightings.len and
            sightings[end].tick == sightings[start].tick and
            sightings[end].cell == sightings[start].cell) : (end += 1)
        {}

        const group = sightings[start..end];
        for (group, 0..) |x, i| {
            for (group[i + 1 ..]) |y| {
                const key = pairKey(x.player, y.player);
                const entry = try together.getOrPut(gpa, key);
                entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
            }
        }

        start = end;
    }

    var pairs: std.ArrayList(Pair) = .empty;
    defer pairs.deinit(gpa);

    var it = together.iterator();
    while (it.next()) |entry| {
        const shared = entry.value_ptr.*;
        if (shared < params.min_co_sightings) continue;

        const a: PlayerId = @enumFromInt(@as(u32, @truncate(entry.key_ptr.* >> 32)));
        const b: PlayerId = @enumFromInt(@as(u32, @truncate(entry.key_ptr.*)));

        const seen_a = seen.get(a) orelse 0;
        const seen_b = seen.get(b) orelse 0;

        // Times either was seen without the other. For a farm this is zero: the accounts
        // have no existence outside each other's company.
        const apart = (seen_a - shared) + (seen_b - shared);
        if (apart > 0) continue;

        try pairs.append(gpa, .{ .a = a, .b = b, .together = shared, .apart = apart });
    }

    // Hash map iteration order is not something we will rely on. Sort, so the output is the
    // same on every machine and every run (B8).
    const result = try pairs.toOwnedSlice(gpa);
    std.mem.sort(Pair, result, {}, lessThanPair);
    return result;
}

fn pairKey(x: PlayerId, y: PlayerId) u64 {
    const a = @intFromEnum(x);
    const b = @intFromEnum(y);
    const lo = @min(a, b);
    const hi = @max(a, b);
    return (@as(u64, lo) << 32) | @as(u64, hi);
}

fn lessThanPair(_: void, x: Pair, y: Pair) bool {
    if (x.a != y.a) return @intFromEnum(x.a) < @intFromEnum(y.a);
    return @intFromEnum(x.b) < @intFromEnum(y.b);
}

const testing = std.testing;

test "a settled player is not suspicious" {
    const p = spatial.default_precision;
    const home = spatial.cellFromKey(1, p);
    const office = spatial.cellFromKey(2, p);

    // Home all morning, office all day. The shape of an ordinary life.
    const history = [_]CellId{
        home, home, home, home, home,
        office, office, office, office, office, office, office,
    };

    try testing.expectEqual(@as(Suspicion, 0), suspicion(&history, .default));
}

test "a player who settles nowhere is suspicious" {
    const p = spatial.default_precision;

    // A different room every single tick, forever, dwelling nowhere. Nobody lives like
    // this. This is what a spoofer chasing live cells looks like without geometry.
    var history: [24]CellId = undefined;
    for (&history, 0..) |*c, i| c.* = spatial.cellFromKey(@intCast(i), p);

    try testing.expect(suspicion(&history, .default) > 200);
}

test "a commuter churns but settles, and is forgiven" {
    const p = spatial.default_precision;
    const home = spatial.cellFromKey(1, p);
    const office = spatial.cellFromKey(9, p);

    // Home, then a fast train through six rooms in six ticks, then a long day at a desk.
    // The train alone would look like teleportation to a churn detector. The desk is what
    // saves them -- and a real commuter always has a desk.
    const history = [_]CellId{
        home,                        home,                        home,
        spatial.cellFromKey(3, p),   spatial.cellFromKey(4, p),   spatial.cellFromKey(5, p),
        spatial.cellFromKey(6, p),   spatial.cellFromKey(7, p),   spatial.cellFromKey(8, p),
        office,                      office,                      office,
        office,                      office,                      office,
        office,                      office,                      office,
    };

    try testing.expectEqual(@as(Suspicion, 0), suspicion(&history, .default));
}

test "a short history is never suspicious" {
    const p = spatial.default_precision;
    var history: [4]CellId = undefined;
    for (&history, 0..) |*c, i| c.* = spatial.cellFromKey(@intCast(i), p);

    // Four ticks of nothing but movement -- and we say nothing, because four ticks is not
    // evidence. A new player is not a suspect.
    try testing.expectEqual(@as(Suspicion, 0), suspicion(&history, .default));
}

test "the worst suspicion costs XP, never an account" {
    const params: Params = .default;

    // The maximum possible penalty, applied to the most suspicious player imaginable.
    const damped = dampenXp(100, 255, params);

    // They still earn. They still play. They still exist. That is the whole of H4: the
    // consequence of being wrong about someone must be survivable for them.
    try testing.expect(damped > 0);
    try testing.expectEqual(@as(u16, 60), damped);

    // And an ordinary player loses nothing at all.
    try testing.expectEqual(@as(u16, 100), dampenXp(100, 0, params));
}

fn sighting(player: u32, cell_key: u64, tick: u32) Sighting {
    return .{
        .cell = spatial.cellFromKey(cell_key, spatial.default_precision),
        .player = @enumFromInt(player),
        .tick = tick,
    };
}

test "accounts that are never apart are a farm" {
    const gpa = testing.allocator;

    // Three accounts. They are always in the same room, at every tick, and they are never
    // anywhere else. They have no lives. This is the attack: a manufactured quorum.
    var sightings: std.ArrayList(Sighting) = .empty;
    defer sightings.deinit(gpa);

    var t: u32 = 0;
    while (t < 30) : (t += 1) {
        try sightings.append(gpa, sighting(101, 0xFA12, t));
        try sightings.append(gpa, sighting(102, 0xFA12, t));
        try sightings.append(gpa, sighting(103, 0xFA12, t));
    }

    const farms = try coOccurringPairs(gpa, sightings.items, .default);
    defer gpa.free(farms);

    // Every pair among the three is flagged.
    try testing.expectEqual(@as(usize, 3), farms.len);
    for (farms) |pair| {
        try testing.expectEqual(@as(u32, 0), pair.apart);
        try testing.expectEqual(@as(u32, 30), pair.together);
    }
}

test "friends who go home are not a farm" {
    const gpa = testing.allocator;

    // Two people who work together every day -- far more co-occurrence than the threshold.
    // But they each go home at night, alone. That is the difference, and it is the whole
    // detector: a farm has no home to go to.
    var sightings: std.ArrayList(Sighting) = .empty;
    defer sightings.deinit(gpa);

    var t: u32 = 0;
    while (t < 30) : (t += 1) {
        try sightings.append(gpa, sighting(201, 0x0FF1, t)); // the office
        try sightings.append(gpa, sighting(202, 0x0FF1, t));
    }
    // Evening. They separate.
    while (t < 40) : (t += 1) {
        try sightings.append(gpa, sighting(201, 0xA001, t)); // her flat
        try sightings.append(gpa, sighting(202, 0xB002, t)); // his flat
    }

    const farms = try coOccurringPairs(gpa, sightings.items, .default);
    defer gpa.free(farms);

    try testing.expectEqual(@as(usize, 0), farms.len);
}

test "two accounts together twice are not a farm" {
    const gpa = testing.allocator;

    // Strangers who happened to share a café twice. Below the co-sighting threshold, and
    // therefore not evidence of anything. Coincidence is not a cluster.
    var sightings: std.ArrayList(Sighting) = .empty;
    defer sightings.deinit(gpa);

    try sightings.append(gpa, sighting(301, 0xCAFE, 1));
    try sightings.append(gpa, sighting(302, 0xCAFE, 1));
    try sightings.append(gpa, sighting(301, 0xCAFE, 2));
    try sightings.append(gpa, sighting(302, 0xCAFE, 2));

    const farms = try coOccurringPairs(gpa, sightings.items, .default);
    defer gpa.free(farms);

    try testing.expectEqual(@as(usize, 0), farms.len);
}

test "farm detection is deterministic" {
    const gpa = testing.allocator;

    var sightings: std.ArrayList(Sighting) = .empty;
    defer sightings.deinit(gpa);

    var t: u32 = 0;
    while (t < 25) : (t += 1) {
        var id: u32 = 500;
        while (id < 506) : (id += 1) try sightings.append(gpa, sighting(id, 0xDEAD, t));
    }

    const first = try coOccurringPairs(gpa, sightings.items, .default);
    defer gpa.free(first);
    const second = try coOccurringPairs(gpa, sightings.items, .default);
    defer gpa.free(second);

    // Hash map iteration order is not a thing we trust. The output is sorted, so it is the
    // same on every run and every machine (B8).
    try testing.expectEqualSlices(Pair, first, second);
    try testing.expectEqual(@as(usize, 15), first.len); // 6 choose 2
}
