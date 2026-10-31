//! Stance and the situational side of a fight: what the chosen approach, the enemy's counter
//! relationship and the time of day do to a combatant. Pure; the combat engine only sees the
//! adjusted `Combatant` (DESIGN.md section 4).

const std = @import("std");
const data = @import("data.zig");
const combat = @import("combat.zig");
const daynight = @import("daynight.zig");

pub const Stance = data.Stance;

/// A stance's fractional change to the totals for one fight.
pub const Effect = struct { atk: f32 = 0, def: f32 = 0, spd: f32 = 0, hp: f32 = 0, dodge: f32 = 0 };

pub fn effect(s: Stance) Effect {
    return switch (s) {
        .aggressive => .{ .atk = 0.20, .def = -0.20 },
        .careful => .{ .def = 0.25, .dodge = 0.03, .atk = -0.08 },
        .evasive => .{ .spd = 0.20, .dodge = 0.05, .hp = -0.10 },
    };
}

/// Extra damage dealt, and the cut in damage taken, from standing in the stance that beats an
/// enemy. Standing in the one it punishes is the reverse.
pub const counter_swing = 0.10;

pub const Relation = enum { neutral, countered, punished };

/// How `s` fares against `foe`: `countered` means the stance beats the enemy.
pub fn relation(s: Stance, foe: ?data.Archetype) Relation {
    const f = foe orelse return .neutral;
    const row = data.archetype(f);
    if (row.counter) |c| if (c == s) return .countered;
    if (row.punished) |p| if (p == s) return .punished;
    return .neutral;
}

pub fn parse(text: []const u8) ?Stance {
    return std.meta.stringToEnum(Stance, text);
}

pub const default: Stance = .careful;

/// A combatant ready to fight, plus the factor its HP was scaled by (so the HP left can be
/// converted back to the player's real HP).
pub const Adjusted = struct {
    c: combat.Combatant,
    hp_scale: f32 = 1.0,
};

/// Apply stance, the counter relationship against `foe`, and the phase of the day (`night`:
/// null when the position is unknown) to a player's combatant. Stance and phase percentages add
/// and are applied once to the totals.
pub fn adjust(base: combat.Combatant, s: Stance, foe: ?data.Archetype, night: ?bool) Adjusted {
    const e = effect(s);
    const t: daynight.PlayerEffect = if (night) |n| daynight.playerEffect(base.faction, n) else .{};
    var c = base;
    c.stats.atk = scaled(base.stats.atk, 1 + e.atk + t.atk, 1);
    c.stats.def = scaled(base.stats.def, 1 + e.def + t.def, 0);
    c.stats.spd = scaled(base.stats.spd, 1 + e.spd, 1);
    c.stats.hp = scaled(base.stats.hp, 1 + e.hp, 1);
    const hp_scale: f32 = @as(f32, @floatFromInt(c.stats.hp)) / @as(f32, @floatFromInt(@max(1, base.stats.hp)));
    c.hp = std.math.clamp(scaled(base.hp, hp_scale, 1), 1, c.stats.hp);
    c.dodge += e.dodge;
    switch (relation(s, foe)) {
        .neutral => {},
        .countered => {
            c.dmg_out *= 1.0 + counter_swing;
            c.dmg_in *= 1.0 - counter_swing;
        },
        .punished => {
            c.dmg_out *= 1.0 - counter_swing;
            c.dmg_in *= 1.0 + counter_swing;
        },
    }
    return .{ .c = c, .hp_scale = hp_scale };
}

fn scaled(v: i32, f: f32, floor: i32) i32 {
    return @max(floor, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(v)) * f))));
}

/// The player's real HP after a fight fought at `hp_scale`: 0 stays 0 (Downed), a survivor keeps
/// at least 1.
pub fn realHp(fight_hp: i32, hp_scale: f32, real_max: i32) i32 {
    if (fight_hp <= 0) return 0;
    const back: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(fight_hp)) / hp_scale));
    return std.math.clamp(back, 1, real_max);
}

// --- Tests ---------------------------------------------------------------------------------------

const testing = std.testing;

fn sample() combat.Combatant {
    return .{ .faction = .human, .stats = .{ .hp = 200, .atk = 40, .def = 32, .spd = 20 }, .hp = 150 };
}

test "stance effects on the totals" {
    const a = adjust(sample(), .aggressive, null, null);
    try testing.expectEqual(@as(i32, 48), a.c.stats.atk); // +20%
    try testing.expectEqual(@as(i32, 26), a.c.stats.def); // -20% = 25.6
    try testing.expectEqual(@as(i32, 20), a.c.stats.spd);
    try testing.expectEqual(@as(i32, 200), a.c.stats.hp);
    try testing.expectEqual(@as(f32, 0), a.c.dodge);

    const c = adjust(sample(), .careful, null, null);
    try testing.expectEqual(@as(i32, 37), c.c.stats.atk); // -8% = 36.8
    try testing.expectEqual(@as(i32, 40), c.c.stats.def); // +25%
    try testing.expectApproxEqAbs(0.03, c.c.dodge, 1e-6);

    const e = adjust(sample(), .evasive, null, null);
    try testing.expectEqual(@as(i32, 24), e.c.stats.spd); // +20%
    try testing.expectEqual(@as(i32, 180), e.c.stats.hp); // -10% for the fight
    try testing.expectEqual(@as(i32, 135), e.c.hp); // current HP scales with it
    try testing.expectApproxEqAbs(0.05, e.c.dodge, 1e-6);
    try testing.expectApproxEqAbs(0.9, e.hp_scale, 1e-6);
    try testing.expectEqual(@as(i32, 40), e.c.stats.atk);
}

test "counters swing damage by 10% each way, punishment is the reverse" {
    // Runner: careful counters, evasive is punished, aggressive is neutral.
    const ok = adjust(sample(), .careful, .runner, null);
    try testing.expectApproxEqAbs(1.1, ok.c.dmg_out, 1e-6);
    try testing.expectApproxEqAbs(0.9, ok.c.dmg_in, 1e-6);
    const bad = adjust(sample(), .evasive, .runner, null);
    try testing.expectApproxEqAbs(0.9, bad.c.dmg_out, 1e-6);
    try testing.expectApproxEqAbs(1.1, bad.c.dmg_in, 1e-6);
    const meh = adjust(sample(), .aggressive, .runner, null);
    try testing.expectEqual(@as(f32, 1.0), meh.c.dmg_out);
    try testing.expectEqual(@as(f32, 1.0), meh.c.dmg_in);
    // No enemy archetype (PvP, Echo) and the neutral Shambler have no relationship.
    for ([_]Stance{ .aggressive, .careful, .evasive }) |s| {
        try testing.expectEqual(Relation.neutral, relation(s, null));
        try testing.expectEqual(Relation.neutral, relation(s, .shambler));
        try testing.expectEqual(Relation.neutral, relation(s, .abomination));
    }
}

test "every archetype the map spawns has a distinct counter and punished stance, or none" {
    for (data.archetypes) |a| {
        if (a.counter) |c| try testing.expect(a.punished == null or a.punished.? != c);
        if (a.id == .abomination or a.id == .shambler) try testing.expect(a.counter == null and a.punished == null);
        if (a.weight > 0) try testing.expect(a.hint.human.len > 0 and a.hint.zombie.len > 0);
    }
    try testing.expectEqual(Relation.countered, relation(.careful, .runner));
    try testing.expectEqual(Relation.countered, relation(.careful, .horde));
    try testing.expectEqual(Relation.countered, relation(.evasive, .brute));
    try testing.expectEqual(Relation.countered, relation(.aggressive, .bloater));
    try testing.expectEqual(Relation.countered, relation(.aggressive, .screamer));
    try testing.expectEqual(Relation.punished, relation(.evasive, .runner));
}

test "time of day adds to the stance percentages, once" {
    // Zombie at night: +10% ATK on top of aggressive's +20% adds to +30%, not 1.2 x 1.1.
    var z = sample();
    z.faction = .zombie;
    try testing.expectEqual(@as(i32, 52), adjust(z, .aggressive, null, true).c.stats.atk);
    try testing.expectEqual(@as(i32, 48), adjust(z, .aggressive, null, false).c.stats.atk);
    try testing.expectEqual(@as(i32, 48), adjust(z, .aggressive, null, null).c.stats.atk);
    // Human by day: +10% DEF; careful's +25% makes it +35% (43.2), not 1.25 x 1.1 (44).
    try testing.expectEqual(@as(i32, 43), adjust(sample(), .careful, null, false).c.stats.def);
    try testing.expectEqual(@as(i32, 40), adjust(sample(), .careful, null, true).c.stats.def);
    // Zombies get no day DEF, Humans no night ATK.
    try testing.expectEqual(@as(i32, 32), adjust(z, .evasive, null, false).c.stats.def);
    try testing.expectEqual(@as(i32, 40), adjust(sample(), .evasive, null, true).c.stats.atk);
}

test "real HP comes back from the scaled fight" {
    try testing.expectEqual(@as(i32, 0), realHp(0, 0.9, 200));
    try testing.expectEqual(@as(i32, 100), realHp(90, 0.9, 200));
    try testing.expectEqual(@as(i32, 200), realHp(180, 0.9, 200));
    try testing.expectEqual(@as(i32, 1), realHp(1, 0.9, 200));
    try testing.expectEqual(@as(i32, 77), realHp(77, 1.0, 200));
}

test "a stance fight is deterministic and the dodge bonus is felt" {
    var log: [combat.max_log]combat.Turn = undefined;
    const foe = combat.Combatant{ .faction = .zombie, .stats = .{ .hp = 200, .atk = 30, .def = 20, .spd = 20 }, .hp = 200 };
    var dodged_plain: usize = 0;
    var dodged_evasive: usize = 0;
    for (0..400) |seed| {
        const r1 = combat.fight(foe, sample(), seed, &log);
        for (log[0..r1.len]) |t| {
            if (t.actor == .a and t.ev == .dodge) dodged_plain += 1;
        }
        const r2 = combat.fight(foe, adjust(sample(), .evasive, null, null).c, seed, &log);
        for (log[0..r2.len]) |t| {
            if (t.actor == .a and t.ev == .dodge) dodged_evasive += 1;
        }
        const again = combat.fight(foe, adjust(sample(), .evasive, null, null).c, seed, &log);
        try testing.expectEqual(r2, again);
    }
    try testing.expect(dodged_evasive > dodged_plain);
}
