//! CORE (B1, B2). A deterministic, accelerated field test for the playable vertical slice.
//!
//! This is not a second production authority. It is a clearly labelled training encounter that
//! runs the same authored kits and combat resolver without requiring three phones to be standing
//! in one room. Its rewards and XP never enter `world.Progress`, the journal, or the live record.
//! The purpose is narrower: make the complete encounter experience playable in seconds so its
//! clarity, pacing, and kit trade-offs can be judged on a real phone.

const std = @import("std");
const combat = @import("combat.zig");
const loadout = @import("loadout.zig");
const spatial = @import("spatial.zig");
const world = @import("world.zig");

pub const rounds: u8 = 7;
pub const contact_ms: u32 = 1800;
pub const round_ms: u32 = 900;

pub const Phase = enum(u8) {
    idle,
    contact,
    resolving,
    debrief,
};

pub const Result = enum(u8) {
    none,
    held,
    fell,
};

/// Everything the accelerated field test needs. It contains synthetic opponents only; no cell,
/// location, identity, production reward, or live progression ever enters this value.
pub const State = struct {
    phase: Phase = .idle,
    encounter: u8 = 0,
    phase_ms: u32 = 0,
    round: u8 = 0,
    hp: u16 = 100,
    hostile_a_hp: u16 = 100,
    hostile_b_hp: u16 = 100,
    last_damage: u16 = 0,
    damage_taken: u16 = 0,
    damage_dealt: u16 = 0,
    xp_earned: u16 = 0,
    momentum: combat.Momentum = .even,
    kit: loadout.Kit = .field,
    reward: loadout.Reward = .none,
    equipped: loadout.Loadout = loadout.starter_loadout,
    reward_item: u8 = loadout.no_item,
    result: Result = .none,

    /// Encounter-one figures survive its debrief so encounter two can make the equipment choice
    /// concrete. These remain training figures and never appear in the live Record.
    first_kit: loadout.Kit = .field,
    first_equipped: loadout.Loadout = loadout.starter_loadout,
    first_damage_taken: u16 = 0,
    first_damage_dealt: u16 = 0,
};

pub fn active(state: State) bool {
    return state.phase == .contact or state.phase == .resolving;
}

pub fn canStart(state: State, kit: loadout.Kit) bool {
    return canStartEquipped(state, loadout.preset(kit));
}

pub fn canStartEquipped(state: State, equipped: loadout.Loadout) bool {
    if (active(state) or state.encounter >= 2) return false;
    return state.encounter == 0 or !loadout.same(equipped, state.first_equipped);
}

/// Begin the next encounter. The second intentionally refuses the first kit: the point of this
/// slice is to let the player see that their equipment decision changed a real resolution.
pub fn start(state: State, kit: loadout.Kit) State {
    var next = startEquipped(state, loadout.preset(kit));
    next.kit = kit;
    next.first_kit = if (state.encounter == 0) kit else state.first_kit;
    return next;
}

pub fn startEquipped(state: State, equipped: loadout.Loadout) State {
    if (!canStartEquipped(state, equipped)) return state;

    return .{
        .phase = .contact,
        .encounter = state.encounter + 1,
        .kit = state.kit,
        .reward = if (state.encounter == 0) .weapon_parts else .armor_parts,
        .equipped = equipped,
        // The first cache is deliberately a weapon upgrade so the comparison encounter can
        // demonstrate one exact discovery changing the real resolver. It remains training data.
        .reward_item = if (state.encounter == 0)
            @intFromEnum(loadout.ItemId.nail_driver)
        else
            @intFromEnum(loadout.ItemId.scavenger_rig),
        .first_kit = state.first_kit,
        .first_equipped = if (state.encounter == 0) equipped else state.first_equipped,
        .first_damage_taken = state.first_damage_taken,
        .first_damage_dealt = state.first_damage_dealt,
    };
}

pub fn reset(_: State) State {
    return .{};
}

/// A different kit after encounter one is the explicit transition out of its debrief and into the
/// comparison-ready state. Merely visiting Gear changes nothing; the authored choice is the step.
pub fn prepare(state: State, kit: loadout.Kit) State {
    if (state.phase != .debrief or state.encounter != 1 or
        loadout.same(loadout.preset(kit), state.first_equipped)) return state;
    var next = prepareEquipment(state, loadout.preset(kit));
    next.kit = kit;
    return next;
}

pub fn prepareEquipment(state: State, equipped: loadout.Loadout) State {
    if (state.phase != .debrief or state.encounter != 1 or loadout.same(equipped, state.first_equipped)) return state;
    var next = state;
    next.phase = .idle;
    next.phase_ms = 0;
    next.equipped = equipped;
    next.reward = .none;
    next.reward_item = loadout.no_item;
    next.result = .none;
    return next;
}

/// Advance by a caller-supplied duration. Time is data, never something the core reaches for.
/// Large steps are handled exactly like several small ones so replay and tests remain deterministic.
pub fn advance(state: State, elapsed_ms: u32, faction: world.Faction) State {
    if (!active(state) or elapsed_ms == 0) return state;

    var next = state;
    next.phase_ms +|= elapsed_ms;

    if (next.phase == .contact) {
        if (next.phase_ms < contact_ms) return next;
        next.phase_ms -= contact_ms;
        next.phase = .resolving;
    }

    while (next.phase == .resolving and next.phase_ms >= round_ms) {
        next.phase_ms -= round_ms;
        next = resolveRound(next, faction);
    }

    return next;
}

fn resolveRound(state: State, faction: world.Faction) State {
    var next = state;
    const other: world.Faction = if (faction == .human) .zombie else .human;
    const players = [_]world.PlayerId{ @enumFromInt(1), @enumFromInt(2), @enumFromInt(3) };
    const factions = [_]world.Faction{ faction, other, other };
    const hps = [_]u16{ state.hp, state.hostile_a_hp, state.hostile_b_hp };
    const equipped = [_]loadout.Loadout{ state.equipped, loadout.starter_loadout, loadout.starter_loadout };
    var outcomes: [3]combat.Outcome = undefined;

    next.momentum = combat.resolveEquipped(
        &players,
        &factions,
        &hps,
        &equipped,
        spatial.cellFromKey(0xF13D, 39),
        0x0B17_BA5E,
        state.round + 1,
        .{ .damage_per_hostile = 5, .jitter = 3 },
        &outcomes,
    );

    next.last_damage = outcomes[0].damage;
    next.damage_taken +|= outcomes[0].damage;
    next.damage_dealt +|= outcomes[1].damage +| outcomes[2].damage;
    next.xp_earned +|= outcomes[0].xp;
    next.hp = outcomes[0].hp_after;
    next.hostile_a_hp = outcomes[1].hp_after;
    next.hostile_b_hp = outcomes[2].hp_after;
    next.round += 1;

    if (next.round >= rounds or next.hp == 0) {
        next.phase = .debrief;
        next.phase_ms = 0;
        next.result = if (next.hp == 0) .fell else .held;
        if (next.encounter == 1) {
            next.first_damage_taken = next.damage_taken;
            next.first_damage_dealt = next.damage_dealt;
        }
    }

    return next;
}

fn finish(kit: loadout.Kit, faction: world.Faction) State {
    var state = start(.{}, kit);
    state = advance(state, contact_ms + @as(u32, rounds) * round_ms, faction);
    return state;
}

test "field test reaches a complete authoritative debrief" {
    const state = finish(.field, .human);
    try std.testing.expectEqual(Phase.debrief, state.phase);
    try std.testing.expectEqual(rounds, state.round);
    try std.testing.expectEqual(@as(u16, rounds * 10), state.xp_earned);
    try std.testing.expect(state.reward != .none);
    try std.testing.expect(state.damage_taken > 0);
    try std.testing.expect(state.damage_dealt > 0);
    try std.testing.expect(state.result != .none);
}

test "second field test requires a different equipment choice" {
    const first = finish(.field, .zombie);
    try std.testing.expect(!canStart(first, .field));
    try std.testing.expectEqual(first, start(first, .field));

    const ready = prepare(first, .bulwark);
    try std.testing.expectEqual(Phase.idle, ready.phase);
    try std.testing.expectEqual(first.first_damage_taken, ready.first_damage_taken);

    const second = start(ready, .bulwark);
    try std.testing.expectEqual(@as(u8, 2), second.encounter);
    try std.testing.expectEqual(loadout.Kit.field, second.first_kit);
    try std.testing.expectEqual(first.damage_taken, second.first_damage_taken);
}

test "first kit or a gear visit alone cannot dismiss the debrief" {
    const first = finish(.raider, .human);
    try std.testing.expectEqual(first, prepare(first, .raider));
}

test "authored kits materially change the accelerated encounter" {
    const raider = finish(.raider, .human);
    const bulwark = finish(.bulwark, .human);

    try std.testing.expect(bulwark.damage_taken < raider.damage_taken);
    try std.testing.expect(raider.damage_dealt > bulwark.damage_dealt);
}
