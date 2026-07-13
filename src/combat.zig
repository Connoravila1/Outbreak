//! CORE (B1, B2). Combat resolution: a pure transform over one run (0.5).
//!
//! A sealed module (D1). The combat and progression rules are the decisions that will be
//! tuned forever, so they live behind this boundary and nothing outside it learns how a
//! fight is decided.
//!
//! COMBAT IS ASYNCHRONOUS (I4). Resolution happens here, server-side, on the tick. There
//! is no aiming, no reaction, no real-time anything. Walking toward another player confers
//! no mechanical advantage whatsoever -- there is no term in any formula below that could
//! express one, because the only spatial fact available is "in this cell", and it is a
//! boolean the caller has already established.
//!
//! Kill the incentive to approach, and the approach never happens. That is not a courtesy
//! to the safety story; it is the mechanism of it.
//!
//! DETERMINISM (B7, B8). Every draw is derived from (seed, tick_index, cell, player) and
//! from nothing else -- in particular, not from a presence's position in the array. Two
//! worlds holding the same people resolve identically no matter what order the presences
//! arrived in, or how the sort happened to break a tie between them. A tick that resolved
//! differently after a shuffle would still look deterministic in a replay test and would
//! be wrong in production, which is the worst kind of wrong.
//!
//! This module allocates nothing. The caller provides the output buffer (C1, C2).

const std = @import("std");
const rand = @import("rand.zig");
const spatial = @import("spatial.zig");
const world = @import("world.zig");

const CellId = spatial.CellId;
const Faction = world.Faction;
const PlayerId = world.PlayerId;

/// PROVISIONAL. Nobody has played this game. These numbers are placeholders chosen to be
/// obviously provisional rather than deceptively considered, and tuning them before
/// Phase 5 would be tuning against an imagination (roadmap: Phase 1's named trap).
///
/// They live here, behind the module boundary, precisely so that retuning them is a
/// one-file change forever.
pub const Rules = struct {
    /// Damage a presence takes per hostile sharing its cell, per tick.
    damage_per_hostile: u16 = 6,
    /// The width of the random jitter added to each presence's incoming damage.
    jitter: u16 = 5,
    /// Hit points recovered per tick by a presence that is not in a live cell.
    ///
    /// There is no death and no permanence. A downed player is removed from the fight and
    /// recovers over time, because nothing may be at stake that is worth stalking someone
    /// over.
    recovery_per_tick: u16 = 1,
    /// The ceiling recovery restores toward.
    max_hp: u16 = 100,

    /// XP for one tick spent in a live cell with at least one hostile present.
    ///
    /// THIS IS THE ONLY THING THAT EARNS (H3). Not distance travelled. Not cells
    /// visited. Not items picked up. Those are trivially spoofable, and they are not
    /// weighted low here -- they do not exist. There is no other call site in this
    /// codebase that adds XP, and there is not meant to be.
    xp_per_tick: u16 = 10,

    pub const default: Rules = .{};
};

/// What a tick did to one presence.
///
/// Keyed by PlayerId, never by slot: an index into the caller's columns would be
/// meaningless outside the module that owns them (A5).
///
/// There is no `downed: bool` -- flags do not go on hot structs (A6). A presence is downed
/// when its hp reaches zero, which the hp column already says.
pub const Outcome = struct {
    player: PlayerId, // u32
    damage: u16,
    hp_after: u16,
    xp: u16,
    _pad: u16 = 0,

    comptime {
        // THE SIZE GUARD (A7). One per presence in every live cell, every tick.
        //
        // A7.1 -- BUDGET RAISED FROM 8 TO 12, DELIBERATELY.
        //
        // The xp field is the reason. XP is earned by exactly one thing: duration in a
        // live cell with hostiles present (H3). Duration is integrated by awarding it on
        // the tick, which makes the award a per-presence result of resolution -- the same
        // shape as damage, produced by the same pass.
        //
        // The alternative was to leave Outcome at 8 bytes and infer the award from
        // `damage > 0`. That is smaller and it is wrong: a presence already at zero hp
        // takes no further damage, so the inference would silently stop paying a downed
        // player who is still standing in the fight. The reward would then quietly depend
        // on a health value rather than on presence, which is not what H3 says and not
        // what we want to be true.
        //
        // 4 + 2 + 2 + 2 + 2 = 12 bytes packed. Four bytes per presence per live cell per
        // tick, against a thirty-second budget (G3). The trade is accepted.
        assert(@sizeOf(Outcome) == 12);
    }
};

/// The aggregate momentum of a fight: how it is going, and nothing else.
///
/// This is the only fight-wide fact a player is ever permitted to learn (I5). It is
/// categorical, not geometric. It carries no position, no direction, no identity, and no
/// count -- in particular it does not reveal how many hostiles are present, because a
/// count is a step toward a person.
pub const Momentum = enum(u8) { humans_ahead, even, zombies_ahead };

const assert = std.debug.assert;

/// CORE. Resolve one run: the presences of a single live cell.
///
/// The caller has already established quorum (I3) and grouped the run (0.3). `out` must be
/// the same length as the run, and receives one Outcome per presence, in the same order.
///
/// If only one faction is present there is no fight, everyone takes zero damage, and the
/// momentum is even. Being alone with your own faction is not an event.
pub fn resolve(
    players: []const PlayerId,
    factions: []const Faction,
    hps: []const u16,
    cell: CellId,
    seed: u64,
    tick_index: u64,
    rules: Rules,
    out: []Outcome,
) Momentum {
    assert(players.len == factions.len);
    assert(players.len == hps.len);
    assert(out.len == players.len);

    var humans: u32 = 0;
    var zombies: u32 = 0;
    for (factions) |faction| switch (faction) {
        .human => humans += 1,
        .zombie => zombies += 1,
    };

    const cell_entropy = spatial.hash(cell);

    var damage_to_humans: u64 = 0;
    var damage_to_zombies: u64 = 0;

    for (players, factions, hps, out) |player, faction, hp, *outcome| {
        const hostiles: u32 = switch (faction) {
            .human => zombies,
            .zombie => humans,
        };

        // The draw depends on who you are, not where you sit in the array.
        const roll = rand.draw(&.{ seed, tick_index, cell_entropy, @intFromEnum(player) });
        const jitter: u16 = if (rules.jitter == 0) 0 else @intCast(roll % rules.jitter);

        const raw: u32 = if (hostiles == 0)
            0
        else
            @as(u32, rules.damage_per_hostile) * hostiles + jitter;

        // Saturate at the presence's remaining hp: a downed player is at zero, never
        // below it, and damage never wraps.
        const damage: u16 = @intCast(@min(raw, @as(u32, hp)));

        // The only thing that earns: you were here, and so was someone hostile (H3).
        //
        // Note what is NOT a term in this: how much damage you dealt, how much you took,
        // whether you won, whether you survived. A downed player standing in a live cell
        // is still present, and presence among real hostile humans is the one input a
        // spoofer cannot fabricate -- it requires k real people to actually be in a room.
        const xp: u16 = if (hostiles == 0) 0 else rules.xp_per_tick;

        outcome.* = .{
            .player = player,
            .damage = damage,
            .hp_after = hp - damage,
            .xp = xp,
        };

        switch (faction) {
            .human => damage_to_humans += damage,
            .zombie => damage_to_zombies += damage,
        }
    }

    // Momentum is which side is absorbing less punishment PER MEMBER.
    //
    // Not in aggregate. A side that outnumbers its enemy three to one absorbs more total
    // damage merely by having more bodies to absorb it, so a total-damage comparison
    // reports the outnumbered side as winning almost every time. That is a headcount
    // wearing a fight's clothes, and it would have been a plausible-looking lie in every
    // tell the game ever emitted.
    //
    // Compared by cross-multiplication rather than division, so the arithmetic is exact
    // and no rounding decides who is winning.
    if (humans == 0 or zombies == 0) return .even;

    const humans_per_capita = damage_to_humans * zombies;
    const zombies_per_capita = damage_to_zombies * humans;

    if (humans_per_capita == zombies_per_capita) return .even;
    return if (humans_per_capita < zombies_per_capita) .humans_ahead else .zombies_ahead;
}

const testing = std.testing;

/// Build a run of alternating factions for tests.
fn runOf(comptime n: usize, factions: [n]Faction, hps: [n]u16) struct {
    players: [n]PlayerId,
    factions: [n]Faction,
    hps: [n]u16,
} {
    var players: [n]PlayerId = undefined;
    for (&players, 0..) |*p, i| p.* = @enumFromInt(@as(u32, @intCast(i + 1)));
    return .{ .players = players, .factions = factions, .hps = hps };
}

test "one faction alone is not a fight" {
    const r = runOf(3, .{ .human, .human, .human }, .{ 100, 100, 100 });
    var out: [3]Outcome = undefined;

    const momentum = resolve(&r.players, &r.factions, &r.hps, spatial.cellFromKey(1, 39), 42, 1, .default, &out);

    for (out) |o| {
        try testing.expectEqual(@as(u16, 0), o.damage);
        try testing.expectEqual(@as(u16, 100), o.hp_after);
    }
    try testing.expectEqual(Momentum.even, momentum);
}

test "hostiles sharing a cell do damage" {
    const r = runOf(3, .{ .human, .zombie, .zombie }, .{ 100, 100, 100 });
    var out: [3]Outcome = undefined;

    _ = resolve(&r.players, &r.factions, &r.hps, spatial.cellFromKey(1, 39), 42, 1, .default, &out);

    // The lone human faces two zombies; each zombie faces one human. Outnumbered hurts.
    try testing.expect(out[0].damage > out[1].damage);
    try testing.expect(out[0].damage > 0);
    try testing.expect(out[1].damage > 0);
}

test "resolution is identical under any ordering of the run" {
    // The property that makes the tick's determinism real. The same people in the same
    // room must resolve to the same outcomes no matter what order they sit in -- otherwise
    // a stable sort is load-bearing, a tie-break is a game rule, and a replay is a
    // coincidence.
    const cell = spatial.cellFromKey(0xC0FFEE, 39);

    const forward = runOf(4, .{ .human, .zombie, .human, .zombie }, .{ 100, 90, 80, 70 });
    var out_forward: [4]Outcome = undefined;
    const m1 = resolve(&forward.players, &forward.factions, &forward.hps, cell, 7, 3, .default, &out_forward);

    // The same four people, reversed.
    const players_rev = [4]PlayerId{ forward.players[3], forward.players[2], forward.players[1], forward.players[0] };
    const factions_rev = [4]Faction{ .zombie, .human, .zombie, .human };
    const hps_rev = [4]u16{ 70, 80, 90, 100 };
    var out_rev: [4]Outcome = undefined;
    const m2 = resolve(&players_rev, &factions_rev, &hps_rev, cell, 7, 3, .default, &out_rev);

    try testing.expectEqual(m1, m2);
    // Each player's outcome is the same, wherever they were standing in the array.
    for (out_forward) |a| {
        for (out_rev) |b| {
            if (a.player == b.player) {
                try testing.expectEqual(a.damage, b.damage);
                try testing.expectEqual(a.hp_after, b.hp_after);
            }
        }
    }
}

test "the same tick replays byte-identically" {
    const cell = spatial.cellFromKey(0xBEEF, 39);
    const r = runOf(4, .{ .human, .zombie, .zombie, .human }, .{ 100, 100, 50, 25 });

    var a: [4]Outcome = undefined;
    var b: [4]Outcome = undefined;
    const m1 = resolve(&r.players, &r.factions, &r.hps, cell, 99, 12, .default, &a);
    const m2 = resolve(&r.players, &r.factions, &r.hps, cell, 99, 12, .default, &b);

    try testing.expectEqual(m1, m2);
    try testing.expectEqualSlices(Outcome, &a, &b);
}

test "a different tick index resolves differently" {
    const cell = spatial.cellFromKey(0xBEEF, 39);
    const r = runOf(4, .{ .human, .zombie, .zombie, .human }, .{ 100, 100, 100, 100 });

    var a: [4]Outcome = undefined;
    var b: [4]Outcome = undefined;
    _ = resolve(&r.players, &r.factions, &r.hps, cell, 99, 12, .default, &a);
    _ = resolve(&r.players, &r.factions, &r.hps, cell, 99, 13, .default, &b);

    var differs = false;
    for (a, b) |x, y| {
        if (x.damage != y.damage) differs = true;
    }
    try testing.expect(differs);
}

test "hp saturates at zero and never wraps" {
    // A presence on 2 hp facing three hostiles takes far more than 2 damage. It must land
    // on exactly zero, not wrap to 65535 and become the most durable player in the city.
    const r = runOf(4, .{ .human, .zombie, .zombie, .zombie }, .{ 2, 100, 100, 100 });
    var out: [4]Outcome = undefined;

    _ = resolve(&r.players, &r.factions, &r.hps, spatial.cellFromKey(1, 39), 5, 5, .default, &out);

    try testing.expectEqual(@as(u16, 0), out[0].hp_after);
    try testing.expectEqual(@as(u16, 2), out[0].damage);
}

test "the side that outnumbers is the side that is winning" {
    // Three humans, one zombie. The humans take one hostile's worth of damage each; the
    // zombie takes three. The humans are plainly winning -- and yet they absorb MORE
    // damage in total, because there are three of them. Momentum must not be fooled by
    // that, and this test is the reason it is measured per member.
    const r = runOf(4, .{ .human, .human, .human, .zombie }, .{ 100, 100, 100, 100 });
    var out: [4]Outcome = undefined;

    const momentum = resolve(&r.players, &r.factions, &r.hps, spatial.cellFromKey(1, 39), 1, 1, .default, &out);
    try testing.expectEqual(Momentum.humans_ahead, momentum);

    // Sanity: the aggregate really does point the other way.
    const total_human_damage = out[0].damage + out[1].damage + out[2].damage;
    try testing.expect(total_human_damage > out[3].damage);
}

test "sitting with your own faction all day earns nothing" {
    // A crowded cell full of allies is not a fight and never pays. If it did, the way to
    // farm would be to gather your own accounts in a room -- which is precisely the attack
    // H5 exists to catch, and it is better to not pay for it in the first place.
    const r = runOf(5, .{ .human, .human, .human, .human, .human }, .{ 100, 100, 100, 100, 100 });
    var out: [5]Outcome = undefined;

    _ = resolve(&r.players, &r.factions, &r.hps, spatial.cellFromKey(1, 39), 1, 1, .default, &out);

    for (out) |o| try testing.expectEqual(@as(u16, 0), o.xp);
}

test "XP is duration with hostiles, not performance" {
    // Everyone in a live cell with a hostile earns the same, whether they are winning,
    // losing, untouched, or already down. The reward tracks presence among real humans
    // (H3) -- the one input that cannot be faked -- and nothing else.
    const r = runOf(4, .{ .human, .zombie, .zombie, .zombie }, .{ 100, 100, 100, 1 });
    var out: [4]Outcome = undefined;

    _ = resolve(&r.players, &r.factions, &r.hps, spatial.cellFromKey(1, 39), 3, 9, .default, &out);

    const rules: Rules = .default;
    for (out) |o| try testing.expectEqual(rules.xp_per_tick, o.xp);

    // The lone human is being flattened by three zombies and still earns exactly what
    // they earn. Losing pays. Being there is the whole job.
    try testing.expect(out[0].damage > out[1].damage);
}

test "a downed player still present still earns" {
    // hp 0: takes no further damage, because there is none left to take. If XP were
    // inferred from damage dealt or taken, this player would silently stop being paid for
    // standing in the same fight as everyone else. It is an explicit field for this reason.
    const r = runOf(4, .{ .human, .zombie, .zombie, .zombie }, .{ 0, 100, 100, 100 });
    var out: [4]Outcome = undefined;

    _ = resolve(&r.players, &r.factions, &r.hps, spatial.cellFromKey(1, 39), 3, 9, .default, &out);

    const rules: Rules = .default;
    try testing.expectEqual(@as(u16, 0), out[0].damage);
    try testing.expectEqual(@as(u16, 0), out[0].hp_after);
    try testing.expectEqual(rules.xp_per_tick, out[0].xp);
}

test "XP does not depend on the cell" {
    // NO LOCATION CARRIES AN INTRINSIC REWARD (H2). The single most important integrity
    // rule, and it is a design property rather than a code one -- so here it is, asserted
    // as code: the same people fighting the same fight earn the same XP in every room in
    // the world. There is no cell worth travelling to. There is no destination. A spoofer
    // who teleports anywhere arrives at silence, or at the fight they already had.
    const people = runOf(4, .{ .human, .zombie, .human, .zombie }, .{ 100, 100, 100, 100 });

    var here: [4]Outcome = undefined;
    var anywhere: [4]Outcome = undefined;

    _ = resolve(&people.players, &people.factions, &people.hps, spatial.cellFromKey(0x0001, 39), 5, 2, .default, &here);
    _ = resolve(&people.players, &people.factions, &people.hps, spatial.cellFromKey(0xFFFF, 39), 5, 2, .default, &anywhere);

    for (here, anywhere) |a, b| try testing.expectEqual(a.xp, b.xp);
}

test "an even fight reads as even" {
    const r = runOf(4, .{ .human, .human, .zombie, .zombie }, .{ 100, 100, 100, 100 });
    var out: [4]Outcome = undefined;

    // With jitter disabled both sides take exactly the same punishment per member.
    const rules: Rules = .{ .jitter = 0 };
    const momentum = resolve(&r.players, &r.factions, &r.hps, spatial.cellFromKey(1, 39), 1, 1, rules, &out);
    try testing.expectEqual(Momentum.even, momentum);
}
