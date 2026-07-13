//! CORE (B1, B2). Territory (0.9): sustained clan presence, accumulated over days, decaying.
//!
//! ---
//!
//! READ THIS BEFORE ADDING ANYTHING TO THIS FILE
//!
//! Territory is the most dangerous feature in the design, because it is the one that most
//! naturally wants to break H2: VALUE LIVES IN PEOPLE, NOT PLACES.
//!
//! The instinct is obvious and it is wrong. Territory is a place you hold, so surely
//! holding it should pay -- a bonus in your own turf, a resource that accrues, a reason to
//! go and take a cell from someone. Every one of those makes a specific location worth
//! travelling to, and a location worth travelling to is the thing that funds the entire
//! GPS-spoofing industry. It is the single most important integrity rule in the project,
//! and it is a design rule, not a code one, which means the compiler cannot save us here.
//!
//! So: TERRITORY CONFERS NOTHING. It is a statistic. It grants no XP, no loot, no combat
//! modifier, no quorum advantage, and no mechanical benefit of any kind. There is no
//! function in this module that returns a reward, and adding one is a violation of H2 no
//! matter how it is dressed.
//!
//! What territory is FOR: it is a map of where a clan's members actually live and work,
//! accumulated from where they really were. It maps to real communities -- a university, a
//! neighbourhood, a transit line -- and it cannot be seized by a coordinated group
//! teleporting to a spot, because the claim requires sustained presence by distinct real
//! accounts over days. It is a picture, and a picture is enough.
//!
//! ---
//!
//! Two structural defences against the takeover-by-teleport that this feature invites:
//!
//!   1. Only LIVE cells contribute. A clan cannot claim an empty field by standing in it,
//!      because a sub-quorum cell does not exist as far as the system is concerned (I3). To
//!      hold ground you need k real humans in a room, and no exploit conjures strangers.
//!
//!   2. A tick's contribution is CAPPED. Fifty accounts appearing in one cell for one tick
//!      cannot outweigh five people who are genuinely there every day. Territory is earned
//!      in the time dimension, which is the dimension a spoofer cannot cheat.

const std = @import("std");
const spatial = @import("spatial.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const CellId = spatial.CellId;

/// An opaque, stable, server-issued id (A8).
pub const ClanId = enum(u32) { _ };

/// PROVISIONAL. Tuned against real data, later, by someone who has watched a real city.
pub const Params = struct {
    /// The most a single tick may add to a claim, however many bodies turn up.
    ///
    /// This is the anti-teleport constant. Territory accrues in time, not in headcount,
    /// because time is the axis a spoofer cannot fake.
    max_contribution_per_tick: u32 = 3,

    /// Percentage of strength lost per decay period (a week).
    ///
    /// Nothing is held forever. A clan that stops turning up loses the ground, which is the
    /// only honest meaning of "this is our neighbourhood".
    decay_pct: u32 = 25,

    /// Strength below which a claim is dropped entirely rather than lingering at nearly
    /// nothing.
    min_strength: u32 = 10,

    pub const default: Params = .{};
};

/// How much presence a clan has accumulated in one cell.
pub const Claim = struct {
    cell: CellId, // u64
    clan: ClanId, // u32
    strength: u32,

    comptime {
        // THE SIZE GUARD (A7). One per (clan, cell) pair with any history at all.
        // 8 + 4 + 4 = 16 bytes packed.
        assert(@sizeOf(Claim) == 16);
    }
};

/// What one clan did in one live cell on one tick: how many of its distinct members were
/// really standing there.
pub const Contribution = struct {
    cell: CellId, // u64
    clan: ClanId, // u32
    members: u32,

    comptime {
        // THE SIZE GUARD (A7).
        assert(@sizeOf(Contribution) == 16);
    }
};

const Key = struct { cell: CellId, clan: ClanId };

/// CORE. Fold a tick's contributions into the standing claims.
///
/// The caller derives contributions from LIVE cells only -- a clan standing alone in an
/// empty field contributes nothing, because that cell does not exist (I3).
///
/// Returns a new sorted claim table. The caller owns it (C1, C5).
pub fn accrue(
    gpa: Allocator,
    claims: []const Claim,
    contributions: []const Contribution,
    params: Params,
) Allocator.Error![]Claim {
    var table: std.AutoHashMapUnmanaged(Key, u32) = .empty;
    defer table.deinit(gpa);

    for (claims) |claim| {
        try table.put(gpa, .{ .cell = claim.cell, .clan = claim.clan }, claim.strength);
    }

    for (contributions) |c| {
        // Capped. Fifty accounts in a room for one tick are worth three ticks of five
        // people who are actually there, and no more.
        const gain = @min(c.members, params.max_contribution_per_tick);

        const entry = try table.getOrPut(gpa, .{ .cell = c.cell, .clan = c.clan });
        entry.value_ptr.* = if (entry.found_existing)
            entry.value_ptr.* +| gain
        else
            gain;
    }

    return collect(gpa, &table);
}

/// CORE. Decay every claim, and drop the ones that have faded to nothing.
///
/// Weekly. Nothing is held forever, and a clan that stops showing up stops holding the
/// ground -- which is the only honest meaning the word "territory" can have when it is
/// derived from where people really are.
pub fn decay(gpa: Allocator, claims: []const Claim, params: Params) Allocator.Error![]Claim {
    var kept: std.ArrayList(Claim) = .empty;
    defer kept.deinit(gpa);

    for (claims) |claim| {
        const remaining = (claim.strength * (100 - params.decay_pct)) / 100;
        if (remaining < params.min_strength) continue; // faded; forgotten entirely
        try kept.append(gpa, .{ .cell = claim.cell, .clan = claim.clan, .strength = remaining });
    }

    const result = try kept.toOwnedSlice(gpa);
    std.mem.sort(Claim, result, {}, lessThanClaim);
    return result;
}

/// CORE. Which clan holds a cell, if any.
///
/// Returns a name, and nothing else. No bonus, no modifier, no reward -- there is nothing
/// in this module to grant, on purpose (H2).
///
/// A tie is held by nobody. Contested ground stays contested; we do not invent a winner to
/// make the presentation tidier.
pub fn holderOf(claims: []const Claim, cell: CellId, params: Params) ?ClanId {
    var best: ?ClanId = null;
    var best_strength: u32 = 0;
    var tied = false;

    for (claims) |claim| {
        if (claim.cell != cell) continue;
        if (claim.strength < params.min_strength) continue;

        if (claim.strength > best_strength) {
            best = claim.clan;
            best_strength = claim.strength;
            tied = false;
        } else if (claim.strength == best_strength) {
            tied = true;
        }
    }

    return if (tied) null else best;
}

fn collect(gpa: Allocator, table: *std.AutoHashMapUnmanaged(Key, u32)) Allocator.Error![]Claim {
    var out: std.ArrayList(Claim) = .empty;
    defer out.deinit(gpa);

    var it = table.iterator();
    while (it.next()) |entry| {
        try out.append(gpa, .{
            .cell = entry.key_ptr.cell,
            .clan = entry.key_ptr.clan,
            .strength = entry.value_ptr.*,
        });
    }

    // Hash map iteration order is not something we rely on. Sorted output, every run, every
    // machine (B8).
    const result = try out.toOwnedSlice(gpa);
    std.mem.sort(Claim, result, {}, lessThanClaim);
    return result;
}

fn lessThanClaim(_: void, x: Claim, y: Claim) bool {
    if (x.cell != y.cell) return spatial.lessThan(x.cell, y.cell);
    return @intFromEnum(x.clan) < @intFromEnum(y.clan);
}

const testing = std.testing;

fn cellOf(key: u64) CellId {
    return spatial.cellFromKey(key, spatial.default_precision);
}

test "sustained presence accumulates" {
    const gpa = testing.allocator;
    const campus = cellOf(0xC0DE);
    const clan: ClanId = @enumFromInt(1);

    var claims: []Claim = try gpa.alloc(Claim, 0);
    defer gpa.free(claims);

    // Two members of the clan, in a live cell, every tick for a fortnight of ticks.
    var day: u32 = 0;
    while (day < 20) : (day += 1) {
        const contributions = [_]Contribution{
            .{ .cell = campus, .clan = clan, .members = 2 },
        };
        const next = try accrue(gpa, claims, &contributions, .default);
        gpa.free(claims);
        claims = next;
    }

    try testing.expectEqual(@as(usize, 1), claims.len);
    try testing.expectEqual(@as(u32, 40), claims[0].strength); // 2 per tick, capped at 3
    try testing.expectEqual(clan, holderOf(claims, campus, .default).?);
}

test "a teleporting swarm cannot outclaim people who are actually there" {
    // THE ATTACK. A clan spoofs fifty accounts into a cell for a single tick and tries to
    // take ground that another clan has held by genuinely being there every day.
    //
    // It fails, and it fails structurally: territory accrues in the time dimension, and time
    // is the axis a spoofer cannot cheat. Fifty bodies for one tick are worth three.
    const gpa = testing.allocator;
    const corner = cellOf(0xBEEF);
    const locals: ClanId = @enumFromInt(1);
    const raiders: ClanId = @enumFromInt(2);

    var claims: []Claim = try gpa.alloc(Claim, 0);
    defer gpa.free(claims);

    // The locals: three people, there every day, for ten days.
    var day: u32 = 0;
    while (day < 10) : (day += 1) {
        const contributions = [_]Contribution{
            .{ .cell = corner, .clan = locals, .members = 3 },
        };
        const next = try accrue(gpa, claims, &contributions, .default);
        gpa.free(claims);
        claims = next;
    }

    // The raid: fifty accounts, one tick, all at once.
    const raid = [_]Contribution{
        .{ .cell = corner, .clan = raiders, .members = 50 },
    };
    const after = try accrue(gpa, claims, &raid, .default);
    gpa.free(claims);
    claims = after;

    try testing.expectEqual(locals, holderOf(claims, corner, .default).?);
}

test "a clan that stops turning up loses the ground" {
    const gpa = testing.allocator;
    const bar = cellOf(0xBA12);
    const clan: ClanId = @enumFromInt(7);

    var claims: []Claim = try gpa.alloc(Claim, 0);
    defer gpa.free(claims);

    var day: u32 = 0;
    while (day < 10) : (day += 1) {
        const contributions = [_]Contribution{
            .{ .cell = bar, .clan = clan, .members = 3 },
        };
        const next = try accrue(gpa, claims, &contributions, .default);
        gpa.free(claims);
        claims = next;
    }
    try testing.expectEqual(clan, holderOf(claims, bar, .default).?);

    // They stop coming. Week after week after week.
    var week: u32 = 0;
    while (week < 12) : (week += 1) {
        const next = try decay(gpa, claims, .default);
        gpa.free(claims);
        claims = next;
    }

    // The ground is nobody's again. Nothing is held forever.
    try testing.expectEqual(@as(usize, 0), claims.len);
    try testing.expectEqual(@as(?ClanId, null), holderOf(claims, bar, .default));
}

test "contested ground is held by nobody" {
    const gpa = testing.allocator;
    const platform = cellOf(0x7A11);

    const contributions = [_]Contribution{
        .{ .cell = platform, .clan = @enumFromInt(1), .members = 3 },
        .{ .cell = platform, .clan = @enumFromInt(2), .members = 3 },
    };

    var claims: []Claim = try gpa.alloc(Claim, 0);
    defer gpa.free(claims);

    var day: u32 = 0;
    while (day < 10) : (day += 1) {
        const next = try accrue(gpa, claims, &contributions, .default);
        gpa.free(claims);
        claims = next;
    }

    // Two clans, dead level. We do not invent a winner to make the map tidier.
    try testing.expectEqual(@as(?ClanId, null), holderOf(claims, platform, .default));
}

test "a weak claim holds nothing" {
    const gpa = testing.allocator;
    const cell = cellOf(0x1234);

    const contributions = [_]Contribution{
        .{ .cell = cell, .clan = @enumFromInt(3), .members = 2 },
    };

    const claims = try accrue(gpa, &.{}, &contributions, .default);
    defer gpa.free(claims);

    // Turning up once is not holding a neighbourhood.
    try testing.expectEqual(@as(?ClanId, null), holderOf(claims, cell, .default));
}

test "the claim table is deterministic" {
    const gpa = testing.allocator;

    var contributions: std.ArrayList(Contribution) = .empty;
    defer contributions.deinit(gpa);

    var i: u32 = 0;
    while (i < 40) : (i += 1) {
        try contributions.append(gpa, .{
            .cell = cellOf(i % 7),
            .clan = @enumFromInt(i % 5),
            .members = 3,
        });
    }

    const first = try accrue(gpa, &.{}, contributions.items, .default);
    defer gpa.free(first);
    const second = try accrue(gpa, &.{}, contributions.items, .default);
    defer gpa.free(second);

    try testing.expectEqualSlices(Claim, first, second);
}
