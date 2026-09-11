//! CORE. Personal world threats for a sparse launch population.
//!
//! An ambient encounter is explicitly NOT another player. It is a server-authored pressure event:
//! feral infected for a Human, a containment patrol for a Zombie. It never enters the presence
//! columns, never contributes to quorum, and never changes what a sub-quorum cell reveals about
//! the real people inside it. The response labels the source, so presentation cannot imply that a
//! synthetic threat was a nearby human being.

const std = @import("std");
const combat = @import("combat.zig");
const loadout = @import("loadout.zig");
const rand = @import("rand.zig");
const world = @import("world.zig");

pub const rounds: u8 = 5;
/// Four hours at the production thirty-second heartbeat. Ambient pressure fills a sparse world;
/// it does not become a grind that overwhelms the real-contact game.
pub const cooldown_ticks: u64 = 480;
pub const xp_per_round: u16 = 6;

pub const Phase = enum(u8) { waiting, active, cooling };

pub const State = struct {
    phase: Phase = .waiting,
    round: u8 = 0,
    next_tick: u64 = 1,
};

pub const Step = struct {
    damage: u16,
    xp: u16,
    momentum: combat.Momentum,
    started: bool,
};

pub fn init(now: u64) State {
    return .{ .next_tick = now + 1 };
}

/// A restored player resumes under cooldown. The journal intentionally stores durable player
/// progress rather than this ephemeral timer; a process restart must not mint another first-round
/// item immediately and become a loot exploit.
pub fn afterRestore(now: u64) State {
    return .{ .phase = .cooling, .next_tick = now + cooldown_ticks };
}

/// Resolve one ambient round. `null` means the personal threat clock is quiet this tick.
/// Deterministic: every value is a function of server seed, tick, player, and authored equipment.
pub fn resolve(
    state: *State,
    seed: u64,
    tick: u64,
    player: world.PlayerId,
    faction: world.Faction,
    hp: u16,
    equipped: loadout.Loadout,
) ?Step {
    if (state.phase == .cooling) {
        if (tick < state.next_tick) return null;
        state.phase = .waiting;
    }
    if (state.phase == .waiting) {
        if (tick < state.next_tick) return null;
        state.phase = .active;
        state.round = 0;
    }

    const began = state.round == 0;
    const stats = loadout.equippedStats(equipped);
    const roll = rand.draw(&.{ seed, tick, @intFromEnum(player), state.round, 0xA6B1_EA7 });
    const threat: u16 = if (faction == .human) 11 else 10;
    const jitter: u16 = @intCast(roll % 4);
    const evade: u16 = if (roll % 10 < stats.initiative) 1 else 0;
    const raw = threat + jitter -| @as(u16, stats.defense) -| evade;
    const damage = @min(hp, @max(@as(u16, 2), raw));

    const own_force: u16 = @as(u16, stats.attack) + @as(u16, stats.initiative / 2);
    const hostile_force: u16 = threat + @as(u16, @intCast((roll >> 8) % 3));
    const own_ahead = own_force >= hostile_force;
    const decisive = if (own_ahead) own_force - hostile_force >= 3 else hostile_force - own_force >= 3;
    const momentum: combat.Momentum = switch (faction) {
        .human => if (own_ahead)
            (if (decisive) .humans_winning else .humans_edge)
        else
            (if (decisive) .zombies_winning else .zombies_edge),
        .zombie => if (own_ahead)
            (if (decisive) .zombies_winning else .zombies_edge)
        else
            (if (decisive) .humans_winning else .humans_edge),
    };

    state.round += 1;
    if (state.round >= rounds) {
        state.phase = .cooling;
        state.round = 0;
        state.next_tick = tick + cooldown_ticks;
    }

    return .{ .damage = damage, .xp = xp_per_round, .momentum = momentum, .started = began };
}

test "a lone player's first world threat starts quickly and then cools down" {
    var state = init(0);
    const player: world.PlayerId = @enumFromInt(7);
    try std.testing.expect(resolve(&state, 1, 0, player, .human, 100, .{}) == null);
    const first = resolve(&state, 1, 1, player, .human, 100, .{}).?;
    try std.testing.expect(first.started);
    try std.testing.expect(first.damage > 0);
    var i: u8 = 1;
    while (i < rounds) : (i += 1) {
        const next = resolve(&state, 1, 1 + i, player, .human, 100, .{}).?;
        try std.testing.expect(!next.started);
    }
    try std.testing.expect(resolve(&state, 1, 1 + rounds, player, .human, 100, .{}) == null);
}

test "ambient pressure is equipment-sensitive" {
    var bare = init(0);
    var armored = init(0);
    const player: world.PlayerId = @enumFromInt(9);
    const light = resolve(&bare, 4, 1, player, .human, 100, loadout.starter_loadout).?;
    const heavy = resolve(&armored, 4, 1, player, .human, 100, .{
        .weapon = .salvaged_pipe,
        .armor = .last_wall,
        .utility = .field_radio,
    }).?;
    try std.testing.expect(heavy.damage <= light.damage);
}
