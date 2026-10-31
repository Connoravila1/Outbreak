//! Deterministic fight resolution (DESIGN.md section 4). Identical for PvE, PvP, Echo and raids.
//!
//! A fight is up to 30 rounds. Each round both sides act once, the faster first. The result and
//! the turn log are pure functions of the two combatants and the seed.
//!
//! Turn log conventions (the `Turn` JSON shape):
//!  - `actor` is who acted; for a `dot` it is the side that applied it.
//!  - `hit`/`crit`/`dodge`: an attack; `dmg` is HP lost by the target, `heal` is HP the attacker
//!    regained from Hunger/Leech in the same moment. Thorns shows only as a drop in the attacker's
//!    hp. `ability` is set when an ability shaped the attack (Aimed Shot, Pounce, Overwatch, Swarm).
//!  - `ability`: an announcement (Barricade, Calcify, Adrenaline, Bloodlust's first stack,
//!    Molotov, Infectious Bite) or Last Stand saving someone (`heal` = 1).
//!  - `heal`: Second Wind / Devour. `revive`: Undying (`heal` = HP restored).
//!  - hp_a / hp_b are both sides' HP after the event, never below 0.

const std = @import("std");
const data = @import("data.zig");
const rng_mod = @import("rng.zig");
const stats_mod = @import("stats.zig");

const Ability = data.Ability;
const Stats = data.Stats;

pub const max_turns = 30;
/// Upper bound on log entries for one fight; a buffer this big can never overflow.
pub const max_log = 768;

pub const Side = enum {
    a,
    b,

    pub fn other(self: Side) Side {
        return if (self == .a) .b else .a;
    }
};

pub const Ev = enum { hit, crit, dodge, ability, dot, heal, revive };

pub const Turn = struct {
    actor: Side,
    ev: Ev,
    ability: ?Ability,
    dmg: i32,
    heal: i32,
    hp_a: i32,
    hp_b: i32,
};

pub const Combatant = struct {
    faction: data.Faction,
    /// Total stats; `stats.hp` is max HP.
    stats: Stats,
    /// HP at the start of the fight.
    hp: i32,
    abilities: std.EnumSet(Ability) = .initEmpty(),
    mods: stats_mod.Mods = .{},
    /// Situational factors (stance, counters): added to the dodge chance when defending, and
    /// multipliers on the damage this side deals and takes.
    dodge: f32 = 0,
    dmg_out: f32 = 1.0,
    dmg_in: f32 = 1.0,
};

pub const Result = struct {
    winner: Side,
    hp_a: i32,
    hp_b: i32,
    /// Rounds played.
    rounds: u8,
    /// Entries written to the log.
    len: usize,
};

// Ability numbers (DESIGN.md section 4).
const heal_threshold = 0.35;
const heal_fraction = 0.30;
const guard_reduction = 0.35;
const guard_rounds = 3;
const rush_threshold = 0.5;
const rush_spd = 0.25;
const rush_atk = 0.15;
const bloodlust_step = 0.06;
const bloodlust_max = 5;
const dot_fraction = 0.05;
const dot_ticks = 4;
const extra_attack_chance = 0.20;
const stand_atk = 0.30;
const undying_fraction = 0.25;
pub const crit_multiplier = 1.7;
/// Base dodge and crit chance before the speed difference is applied.
pub const base_chance = 0.07;
pub const spread_lo = 0.75;
pub const spread_hi = 1.25;
/// Each side also draws a "form" factor U(1 - form_spread, 1 + form_spread) once per fight and
/// scales all its damage by it. Unlike the per-hit spread it does not average out over a fight,
/// which is what lets a modest gear edge lose now and then.
pub const form_spread = 0.5;
/// dmg = coefficient * ATK^2 / (ATK + DEF) * U(0.75, 1.25) * form. Tuned so even fights last 5 to 8 rounds.
pub const damage_coefficient = 2.4;

const Fighter = struct {
    c: Combatant,
    hp: i32,
    max_hp: i32,
    /// Fight-wide damage factor (see `form_spread`).
    form: f64 = 1.0,
    healed: bool = false,
    survived: bool = false,
    stand: bool = false,
    crit_spent: bool = false,
    opened: bool = false,
    rush_announced: bool = false,
    stacks: u8 = 0,
    dot_left: u8 = 0,
    dot_dmg: i32 = 0,
    dot_source: Ability = .molotov,

    fn init(c: Combatant) Fighter {
        return .{ .c = c, .hp = std.math.clamp(c.hp, 1, c.stats.hp), .max_hp = c.stats.hp };
    }

    fn has(self: *const Fighter, a: Ability) bool {
        return self.c.abilities.contains(a);
    }

    fn rushing(self: *const Fighter) bool {
        return (self.has(.adrenaline)) and
            @as(f64, @floatFromInt(self.hp)) < rush_threshold * @as(f64, @floatFromInt(self.max_hp));
    }

    fn atk(self: *const Fighter) f64 {
        var m: f64 = 1.0;
        if (self.rushing()) m += rush_atk;
        m += bloodlust_step * @as(f64, @floatFromInt(self.stacks));
        if (self.stand) m += stand_atk;
        return @as(f64, @floatFromInt(self.c.stats.atk)) * m;
    }

    fn spd(self: *const Fighter) f64 {
        const m: f64 = if (self.rushing()) 1.0 + rush_spd else 1.0;
        return @as(f64, @floatFromInt(self.c.stats.spd)) * m;
    }

    fn firstAttackAbility(self: *const Fighter) ?Ability {
        if (self.crit_spent) return null;
        if (self.has(.aimed_shot)) return .aimed_shot;
        if (self.has(.pounce)) return .pounce;
        return null;
    }

    fn healAbility(self: *const Fighter) ?Ability {
        if (self.has(.second_wind)) return .second_wind;
        if (self.has(.devour)) return .devour;
        return null;
    }

    fn dotAbility(self: *const Fighter) ?Ability {
        if (self.has(.molotov)) return .molotov;
        if (self.has(.infectious_bite)) return .infectious_bite;
        return null;
    }

    fn hasGuard(self: *const Fighter) ?Ability {
        if (self.has(.barricade)) return .barricade;
        if (self.has(.calcify)) return .calcify;
        return null;
    }

    fn hasExtraAttack(self: *const Fighter) ?Ability {
        if (self.has(.overwatch)) return .overwatch;
        if (self.has(.swarm)) return .swarm;
        return null;
    }
};

const Fight = struct {
    f: [2]Fighter,
    rng: rng_mod.Rng,
    log: []Turn,
    len: usize = 0,
    round: u8 = 0,

    fn emit(self: *Fight, actor: usize, ev: Ev, ability: ?Ability, dmg: i32, heal: i32) void {
        if (self.len >= self.log.len) return;
        self.log[self.len] = .{
            .actor = if (actor == 0) .a else .b,
            .ev = ev,
            .ability = ability,
            .dmg = dmg,
            .heal = heal,
            .hp_a = self.f[0].hp,
            .hp_b = self.f[1].hp,
        };
        self.len += 1;
    }

    fn bothAlive(self: *const Fight) bool {
        return self.f[0].hp > 0 and self.f[1].hp > 0;
    }

    /// Who acts first this round.
    fn first(self: *Fight) usize {
        if (self.round == 1) {
            const pa = self.f[0].has(.pounce);
            const pb = self.f[1].has(.pounce);
            if (pa != pb) return if (pa) 0 else 1;
        }
        const sa = self.f[0].spd();
        const sb = self.f[1].spd();
        if (sa == sb) return self.rng.below(2);
        return if (sa > sb) 0 else 1;
    }

    fn checkRush(self: *Fight, i: usize) void {
        const x = &self.f[i];
        if (x.rushing() and !x.rush_announced) {
            x.rush_announced = true;
            self.emit(i, .ability, .adrenaline, 0, 0);
        }
    }

    /// Lethal-hit rescues (Last Stand, Undying) and Second Wind / Devour, after `i` took damage.
    fn afterDamage(self: *Fight, i: usize) void {
        const x = &self.f[i];
        const max: f64 = @floatFromInt(x.max_hp);
        if (x.hp <= 0) {
            if (x.survived) return;
            if (x.has(.last_stand)) {
                x.hp = 1;
                x.survived = true;
                x.stand = true;
                self.emit(i, .ability, .last_stand, 0, 1);
            } else if (x.has(.undying)) {
                x.hp = @max(1, roundInt(undying_fraction * max));
                x.survived = true;
                x.stand = true;
                self.emit(i, .revive, .undying, 0, x.hp);
            }
            return;
        }
        if (x.healAbility()) |ab| {
            if (!x.healed and @as(f64, @floatFromInt(x.hp)) < heal_threshold * max) {
                x.healed = true;
                const before = x.hp;
                x.hp = @min(x.max_hp, x.hp + roundInt(heal_fraction * max));
                self.emit(i, .heal, ab, 0, x.hp - before);
            }
        }
    }

    fn attack(self: *Fight, i: usize, via: ?Ability) void {
        const j = 1 - i;
        self.checkRush(i);
        self.checkRush(j);
        const me = &self.f[i];
        const foe = &self.f[j];

        const s_me = me.spd();
        const s_foe = foe.spd();
        const diff = 0.5 * (s_foe - s_me) / (s_foe + s_me);
        const dodge_p = std.math.clamp(base_chance + diff, 0.02, 0.30) + foe.c.dodge;
        const crit_p = std.math.clamp(base_chance - diff, 0.02, 0.35) + me.c.mods.crit;

        const dodged = self.rng.float() < dodge_p;
        const rolled_crit = self.rng.float() < crit_p;
        const spread = self.rng.range(spread_lo, spread_hi);
        if (dodged) {
            self.emit(i, .dodge, via, 0, 0);
            return;
        }

        const forced = me.firstAttackAbility();
        const is_crit = forced != null or rolled_crit;
        const a_atk = me.atk();
        const d_def: f64 = @floatFromInt(foe.c.stats.def);
        var raw = damage_coefficient * a_atk * a_atk / (a_atk + d_def) * spread * me.form;
        if (is_crit) raw *= crit_multiplier;
        if (foe.hasGuard() != null and self.round <= guard_rounds) raw *= 1.0 - guard_reduction;
        raw *= @as(f64, me.c.dmg_out) * @as(f64, foe.c.dmg_in);
        const dmg = @max(1, roundInt(raw));
        if (forced != null) me.crit_spent = true;

        const dealt = @min(dmg, foe.hp);
        foe.hp = @max(0, foe.hp - dmg);

        var healed: i32 = 0;
        if (me.c.mods.leech > 0 and me.hp > 0) {
            const want = roundInt(me.c.mods.leech * @as(f64, @floatFromInt(dealt)));
            healed = @min(want, me.max_hp - me.hp);
            me.hp += healed;
        }
        if (foe.hp > 0 and foe.c.mods.thorns > 0) {
            me.hp = @max(0, me.hp - roundInt(foe.c.mods.thorns * @as(f64, @floatFromInt(dmg))));
        }
        const stacked = me.has(.bloodlust) and me.stacks < bloodlust_max;
        if (stacked) me.stacks += 1;

        self.emit(i, if (is_crit) .crit else .hit, via orelse forced, dmg, healed);

        if (stacked and me.stacks == 1) self.emit(i, .ability, .bloodlust, 0, 0);
        if (!me.opened) {
            me.opened = true;
            if (me.dotAbility()) |ab| {
                if (foe.hp > 0) {
                    foe.dot_left = dot_ticks;
                    foe.dot_dmg = @max(1, roundInt(dot_fraction * @as(f64, @floatFromInt(foe.max_hp))));
                    foe.dot_source = ab;
                    self.emit(i, .ability, ab, 0, 0);
                }
            }
        }
        self.afterDamage(j);
        self.afterDamage(i);
    }

    fn tickDots(self: *Fight, order: [2]usize) void {
        for (order) |i| {
            const x = &self.f[i];
            if (x.dot_left == 0 or x.hp <= 0) continue;
            x.dot_left -= 1;
            const dmg = @min(x.dot_dmg, x.hp);
            x.hp -= dmg;
            self.emit(1 - i, .dot, x.dot_source, dmg, 0);
            self.afterDamage(i);
            if (!self.bothAlive()) return;
        }
    }
};

fn roundInt(x: f64) i32 {
    return @intFromFloat(@round(x));
}

/// Resolve a fight. Writes the turn log into `log` (use `max_log` entries to be safe; excess
/// events are dropped) and returns the outcome. `a` is conventionally the player.
pub fn fight(a: Combatant, b: Combatant, seed: u64, log: []Turn) Result {
    return fightWith(a, b, seed, log, form_spread);
}

fn fightWith(a: Combatant, b: Combatant, seed: u64, log: []Turn, form: f64) Result {
    var fx = Fight{
        .f = .{ Fighter.init(a), Fighter.init(b) },
        .rng = rng_mod.Rng.init(seed),
        .log = log,
    };
    for (&fx.f) |*x| x.form = fx.rng.range(1.0 - form, 1.0 + form);

    while (fx.round < max_turns and fx.bothAlive()) {
        fx.round += 1;
        if (fx.round == 1) {
            for (0..2) |i| {
                if (fx.f[i].hasGuard()) |g| fx.emit(i, .ability, g, 0, 0);
            }
        }
        const lead = fx.first();
        const order = [2]usize{ lead, 1 - lead };
        for (order) |i| {
            if (!fx.bothAlive()) break;
            fx.attack(i, null);
            if (fx.bothAlive()) {
                if (fx.f[i].hasExtraAttack()) |ab| {
                    if (fx.rng.chance(extra_attack_chance)) fx.attack(i, ab);
                }
            }
        }
        if (fx.bothAlive()) fx.tickDots(order);
    }

    const fa = fx.f[0];
    const fb = fx.f[1];
    const winner: Side = if (fa.hp <= 0)
        .b
    else if (fb.hp <= 0)
        .a
    else if (@as(i64, fa.hp) * fb.max_hp > @as(i64, fb.hp) * fa.max_hp)
        .a
    else
        .b;
    return .{ .winner = winner, .hp_a = fa.hp, .hp_b = fb.hp, .rounds = fx.round, .len = fx.len };
}

// --- Tests -----------------------------------------------------------------------------------

const testing = std.testing;

/// A fight without the per-fight form factor, so mechanics tests see plain damage numbers.
fn flat(a: Combatant, b: Combatant, seed: u64, log: []Turn) Result {
    return fightWith(a, b, seed, log, 0);
}

fn mk(atk: i32, def: i32, spd: i32, hp: i32) Combatant {
    return .{ .faction = .human, .stats = .{ .hp = hp, .atk = atk, .def = def, .spd = spd }, .hp = hp };
}

fn withAbility(c: Combatant, ab: Ability) Combatant {
    var out = c;
    out.abilities.insert(ab);
    return out;
}

fn countEv(log: []const Turn, ev: Ev, ab: ?Ability) usize {
    var n: usize = 0;
    for (log) |t| {
        if (t.ev == ev and (ab == null or t.ability == ab)) n += 1;
    }
    return n;
}

test "same inputs give the same fight; different seeds differ" {
    var l1: [max_log]Turn = undefined;
    var l2: [max_log]Turn = undefined;
    const a = mk(20, 10, 12, 120);
    const b = mk(18, 12, 10, 130);
    const r1 = flat(a, b, 99, &l1);
    const r2 = flat(a, b, 99, &l2);
    try testing.expectEqual(r1, r2);
    try testing.expectEqualSlices(Turn, l1[0..r1.len], l2[0..r2.len]);
    var differs = false;
    for (0..20) |s| {
        const r3 = flat(a, b, 1000 + s, &l2);
        if (r3.len != r1.len or r3.hp_a != r1.hp_a) differs = true;
    }
    try testing.expect(differs);
}

test "log is consistent: hp tracks, ends with the winner, never exceeds bounds" {
    var log: [max_log]Turn = undefined;
    const a = mk(20, 10, 12, 120);
    const b = mk(18, 12, 10, 130);
    for (0..300) |s| {
        const r = flat(a, b, s, &log);
        try testing.expect(r.len > 0 and r.len < max_log);
        const last = log[r.len - 1];
        try testing.expectEqual(r.hp_a, last.hp_a);
        try testing.expectEqual(r.hp_b, last.hp_b);
        if (r.winner == .a) try testing.expect(r.hp_b == 0 or r.rounds == max_turns) else try testing.expect(r.hp_a == 0 or r.rounds == max_turns);
        for (log[0..r.len]) |t| {
            try testing.expect(t.hp_a >= 0 and t.hp_a <= 120 and t.hp_b >= 0 and t.hp_b <= 130);
            try testing.expect(t.ability == null);
        }
    }
}

/// Mean damage before spread and crits.
fn expectedDamage(atk: f64, def: f64) f64 {
    return damage_coefficient * atk * atk / (atk + def);
}

test "damage follows coefficient*ATK^2/(ATK+DEF) with +-25% spread and x1.7 crits" {
    // 20 vs 10 at coefficient 2.4: 32 -> 24..40; crit 40.8..68
    var log: [max_log]Turn = undefined;
    const a = mk(20, 10, 10, 100000);
    const b = mk(20, 10, 10, 100000);
    var lo: i32 = 1000;
    var hi: i32 = 0;
    var crit_lo: i32 = 1000;
    var crit_hi: i32 = 0;
    var sum: f64 = 0;
    var n: f64 = 0;
    for (0..100) |s| {
        const r = flat(a, b, s, &log);
        for (log[0..r.len]) |t| switch (t.ev) {
            .hit => {
                lo = @min(lo, t.dmg);
                hi = @max(hi, t.dmg);
                sum += @floatFromInt(t.dmg);
                n += 1;
            },
            .crit => {
                crit_lo = @min(crit_lo, t.dmg);
                crit_hi = @max(crit_hi, t.dmg);
            },
            else => {},
        };
    }
    const mean = expectedDamage(20, 10);
    try testing.expectEqual(@as(i32, @intFromFloat(@round(mean * spread_lo))), lo);
    try testing.expectEqual(@as(i32, @intFromFloat(@round(mean * spread_hi))), hi);
    try testing.expect(crit_lo >= @as(i32, @intFromFloat(@round(mean * spread_lo * crit_multiplier))));
    try testing.expect(crit_hi <= @as(i32, @intFromFloat(@round(mean * spread_hi * crit_multiplier))) and crit_hi >= 60);
    try testing.expectApproxEqAbs(mean, sum / n, 0.3);
}

test "dodge rate follows the speed formula" {
    // Defender SPD 20 vs attacker SPD 10: 0.07 + 0.5*10/30 = 0.2367. Attacks by a only count.
    var log: [max_log]Turn = undefined;
    var dodges: f64 = 0;
    var attacks: f64 = 0;
    for (0..300) |s| {
        const r = flat(mk(5, 100, 10, 100000), mk(5, 100, 20, 100000), s, &log);
        for (log[0..r.len]) |t| {
            if (t.actor != .a) continue;
            attacks += 1;
            if (t.ev == .dodge) dodges += 1;
        }
    }
    try testing.expectApproxEqAbs(0.2367, dodges / attacks, 0.02);
}

test "the faster side acts first; ties are decided by the seed" {
    var log: [max_log]Turn = undefined;
    for (0..50) |s| {
        _ = flat(mk(20, 10, 10, 100), mk(20, 10, 20, 100), s, &log);
        try testing.expectEqual(Side.b, log[0].actor);
    }
    var a_first: usize = 0;
    for (0..200) |s| {
        _ = flat(mk(20, 10, 10, 100), mk(20, 10, 10, 100), s, &log);
        if (log[0].actor == .a) a_first += 1;
    }
    try testing.expect(a_first > 60 and a_first < 140);
}

test "30 turn cap: higher HP fraction wins" {
    var log: [max_log]Turn = undefined;
    const r = flat(mk(1, 1000, 10, 1000), mk(1, 1000, 10, 1000), 3, &log);
    try testing.expectEqual(@as(u8, 30), r.rounds);
    // Fraction decides: a starts wounded
    var hurt = mk(1, 1000, 10, 1000);
    hurt.hp = 400;
    const r2 = flat(hurt, mk(1, 1000, 10, 1000), 3, &log);
    try testing.expectEqual(Side.b, r2.winner);
    var hurt_b = mk(1, 1000, 10, 1000);
    hurt_b.hp = 400;
    const r3 = flat(mk(1, 1000, 10, 1000), hurt_b, 3, &log);
    try testing.expectEqual(Side.a, r3.winner);
}

test "Second Wind and Devour heal 30% once, below 35%" {
    var log: [max_log]Turn = undefined;
    for ([_]Ability{ .second_wind, .devour }) |ab| {
        var a = withAbility(mk(1, 0, 10, 200), ab);
        a.hp = 80;
        var seen: usize = 0;
        for (0..40) |s| {
            const r = flat(a, mk(15, 0, 10, 100000), s, &log);
            const n = countEv(log[0..r.len], .heal, ab);
            try testing.expect(n <= 1);
            seen += n;
            for (log[0..r.len], 0..) |t, k| {
                if (t.ev == .heal) {
                    try testing.expectEqual(@as(i32, 60), t.heal);
                    try testing.expect(log[k - 1].hp_a < 70);
                }
            }
        }
        try testing.expectEqual(@as(usize, 40), seen);
    }
}

test "Aimed Shot and Pounce: first landed attack is a crit; Pounce acts first" {
    var log: [max_log]Turn = undefined;
    for ([_]Ability{ .aimed_shot, .pounce }) |ab| {
        for (0..100) |s| {
            const a = withAbility(mk(20, 10, 5, 100), ab);
            const r = flat(a, mk(20, 10, 30, 100), s, &log);
            if (ab == .pounce) try testing.expectEqual(Side.a, log[0].actor);
            for (log[0..r.len]) |t| {
                if (t.actor == .a and t.ev != .dodge) {
                    try testing.expectEqual(Ev.crit, t.ev);
                    try testing.expectEqual(@as(?Ability, ab), t.ability);
                    break;
                }
            }
        }
    }
}

test "Barricade and Calcify cut damage by 35% for the first 3 rounds" {
    var log: [max_log]Turn = undefined;
    for ([_]Ability{ .barricade, .calcify }) |ab| {
        for (0..100) |s| {
            // The foe (side a) hits 20 vs 10: plain 24..40, guarded at most round(40*0.65) = 26.
            const guarded = withAbility(mk(20, 10, 10, 100000), ab);
            const r = flat(mk(20, 10, 10, 100000), guarded, s, &log);
            try testing.expectEqual(Ev.ability, log[0].ev);
            try testing.expectEqual(@as(?Ability, ab), log[0].ability);
            try testing.expectEqual(Side.b, log[0].actor);
            var attacks: usize = 0;
            for (log[0..r.len]) |t| {
                if (t.actor != .a) continue;
                attacks += 1;
                if (attacks > guard_rounds) break;
                if (t.ev == .hit) try testing.expect(t.dmg <= 26);
            }
        }
    }
}

test "Adrenaline announces once when HP drops under 50%" {
    var log: [max_log]Turn = undefined;
    var a = withAbility(mk(20, 10, 10, 100), .adrenaline);
    a.hp = 40;
    const r = flat(a, mk(5, 100, 10, 100000), 4, &log);
    try testing.expectEqual(@as(usize, 1), countEv(log[0..r.len], .ability, .adrenaline));
    // Healthy at the start: the announcement only appears after the HP threshold is crossed.
    const fresh = withAbility(mk(20, 10, 10, 1000), .adrenaline);
    const r2 = flat(fresh, mk(30, 0, 10, 100000), 4, &log);
    const idx = for (log[0..r2.len], 0..) |t, k| {
        if (t.ability == .adrenaline) break k;
    } else return error.NoAdrenaline;
    try testing.expect(log[idx - 1].hp_a * 2 < 1000);
}

test "Adrenaline lifts ATK while wounded" {
    var log: [max_log]Turn = undefined;
    // 100 vs 100 defense: 110 a hit; at +15% ATK: 2.2 * 115^2 / 215 = 135.3.
    var a = withAbility(mk(100, 100, 10, 100000), .adrenaline);
    a.hp = 40000;
    var sum: f64 = 0;
    var n: f64 = 0;
    for (0..300) |s| {
        const r = flat(a, mk(1, 100, 1, 100000), s, &log);
        for (log[0..r.len]) |t| {
            if (t.actor == .a and t.ev == .hit) {
                sum += @floatFromInt(t.dmg);
                n += 1;
            }
        }
    }
    try testing.expectApproxEqRel(expectedDamage(115, 100), sum / n, 0.04);
}

test "Bloodlust stacks to +30% ATK" {
    var log: [max_log]Turn = undefined;
    const a = withAbility(mk(100, 100, 10, 100000), .bloodlust);
    // At 5 stacks a plain hit averages 2.2 * 130^2 / 230 = 161.7; without them it would be 110.
    var late_sum: f64 = 0;
    var late_n: f64 = 0;
    for (0..40) |s| {
        const r = flat(a, mk(1, 100, 1, 100000), s, &log);
        try testing.expectEqual(@as(usize, 1), countEv(log[0..r.len], .ability, .bloodlust));
        var landed: usize = 0;
        for (log[0..r.len]) |t| {
            if (t.actor != .a or (t.ev != .hit and t.ev != .crit)) continue;
            landed += 1;
            if (landed > 6 and t.ev == .hit) {
                late_sum += @floatFromInt(t.dmg);
                late_n += 1;
            }
        }
    }
    try testing.expectApproxEqRel(expectedDamage(130, 100), late_sum / late_n, 0.06);
}

test "Molotov and Infectious Bite: one burn of 4 ticks at 5% max HP" {
    var log: [max_log]Turn = undefined;
    for ([_]Ability{ .molotov, .infectious_bite }) |ab| {
        const a = withAbility(mk(5, 100, 10, 100000), ab);
        const r = flat(a, mk(5, 100, 10, 1000), 8, &log);
        try testing.expectEqual(@as(usize, 1), countEv(log[0..r.len], .ability, ab));
        try testing.expectEqual(@as(usize, 4), countEv(log[0..r.len], .dot, ab));
        for (log[0..r.len]) |t| {
            if (t.ev == .dot) {
                try testing.expectEqual(@as(i32, 50), t.dmg);
                try testing.expectEqual(Side.a, t.actor);
            }
        }
    }
}

test "Overwatch and Swarm add extra attacks about 20% of rounds" {
    var log: [max_log]Turn = undefined;
    for ([_]Ability{ .overwatch, .swarm }) |ab| {
        var extras: f64 = 0;
        var rounds: f64 = 0;
        for (0..100) |s| {
            const r = flat(withAbility(mk(5, 100, 10, 100000), ab), mk(5, 100, 10, 100000), s, &log);
            for (log[0..r.len]) |t| {
                if (t.ability == ab) extras += 1;
            }
            rounds += @floatFromInt(r.rounds);
        }
        try testing.expectApproxEqAbs(0.2, extras / rounds, 0.03);
    }
}

test "Last Stand leaves 1 HP once and boosts ATK" {
    var log: [max_log]Turn = undefined;
    var a = withAbility(mk(1, 0, 10, 100), .last_stand);
    a.hp = 10;
    for (0..30) |s| {
        const r = flat(a, mk(200, 0, 10, 100000), s, &log);
        try testing.expectEqual(@as(usize, 1), countEv(log[0..r.len], .ability, .last_stand));
        for (log[0..r.len], 0..) |t, k| {
            if (t.ability == .last_stand) {
                try testing.expectEqual(@as(i32, 1), t.hp_a);
                try testing.expectEqual(@as(i32, 0), log[k - 1].hp_a);
            }
        }
        try testing.expectEqual(Side.b, r.winner);
    }
}

test "Undying raises at 25% HP once" {
    var log: [max_log]Turn = undefined;
    var a = withAbility(mk(1, 0, 10, 200), .undying);
    a.hp = 10;
    for (0..30) |s| {
        const r = flat(a, mk(400, 0, 10, 100000), s, &log);
        try testing.expectEqual(@as(usize, 1), countEv(log[0..r.len], .revive, .undying));
        for (log[0..r.len]) |t| {
            if (t.ev == .revive) {
                try testing.expectEqual(@as(i32, 50), t.hp_a);
                try testing.expectEqual(@as(i32, 50), t.heal);
            }
        }
    }
}

test "Hunger and Leech heal a share of damage dealt; Thorns reflect" {
    var log: [max_log]Turn = undefined;
    var a = mk(30, 10, 10, 500);
    a.hp = 100;
    a.mods.leech = 0.15;
    const r = flat(a, mk(1, 10, 10, 100000), 5, &log);
    var seen: usize = 0;
    for (log[0..r.len]) |t| {
        if (t.actor == .a and t.dmg > 0) {
            const want: i32 = @intFromFloat(@round(0.15 * @as(f64, @floatFromInt(t.dmg))));
            try testing.expect(t.heal == want or t.hp_a == 500);
            seen += 1;
        }
    }
    try testing.expect(seen > 10);

    // Thorns: b holds thorns 10%; every landed hit by a costs a about a tenth of its damage.
    var b = mk(1, 10, 1, 100000);
    b.mods.thorns = 0.10;
    const r2 = flat(mk(30, 0, 100, 100000), b, 5, &log);
    var prev: i32 = 100000;
    var checked: usize = 0;
    for (log[0..r2.len]) |t| {
        if (t.actor == .a and t.dmg > 0) {
            const drop = prev - t.hp_a;
            const want: i32 = @intFromFloat(@round(0.10 * @as(f64, @floatFromInt(t.dmg))));
            try testing.expectEqual(want, drop);
            checked += 1;
        }
        prev = t.hp_a;
    }
    try testing.expect(checked > 10);
}

test "even level-1 fights run 5 to 8 rounds on average" {
    var log: [max_log]Turn = undefined;
    const base = stats_mod.baseStats(1);
    const c = Combatant{ .faction = .human, .stats = base, .hp = base.hp };
    var total: f64 = 0;
    for (0..500) |s| total += @floatFromInt(flat(c, c, s, &log).rounds);
    const mean = total / 500.0;
    try testing.expect(mean > 4.0 and mean < 14.0);
}

test "form factor makes a modest gear edge lose now and then, and is deterministic per seed" {
    var log: [max_log]Turn = undefined;
    const weak = mk(20, 10, 10, 120);
    const strong = mk(22, 11, 10, 130);
    var strong_wins: f64 = 0;
    for (0..2000) |s| {
        if (fight(strong, weak, s, &log).winner == .a) strong_wins += 1;
    }
    try testing.expect(strong_wins / 2000 > 0.6 and strong_wins / 2000 < 0.93);
    try testing.expectEqual(fight(strong, weak, 7, &log), fight(strong, weak, 7, &log));
    // Without it the same edge would be close to a sure thing.
    var flat_wins: f64 = 0;
    for (0..500) |s| {
        if (flat(strong, weak, s, &log).winner == .a) flat_wins += 1;
    }
    try testing.expect(flat_wins / 500 > strong_wins / 2000 + 0.03);
}

test "damage multipliers scale what a side deals and takes" {
    var l1: [max_log]Turn = undefined;
    var l2: [max_log]Turn = undefined;
    const a = mk(20, 10, 10, 400);
    const b = mk(20, 10, 10, 400);
    var strong = a;
    strong.dmg_out = 1.5;
    var sturdy = a;
    sturdy.dmg_in = 0.5;
    // Same seed, no dodges possible to differ (equal speed): the first hit by `a` is bigger.
    const r0 = flat(a, b, 3, &l1);
    const r1 = flat(strong, b, 3, &l2);
    var first0: i32 = 0;
    var first1: i32 = 0;
    for (l1[0..r0.len]) |t| {
        if (t.actor == .a and t.dmg > 0) {
            first0 = t.dmg;
            break;
        }
    }
    for (l2[0..r1.len]) |t| {
        if (t.actor == .a and t.dmg > 0) {
            first1 = t.dmg;
            break;
        }
    }
    try testing.expect(first1 > first0);
    try testing.expectApproxEqRel(@as(f64, @floatFromInt(first0)) * 1.5, @as(f64, @floatFromInt(first1)), 0.1);
    // Taking half damage: b's first hit on `sturdy` is about half of its hit on `a`.
    const r2 = flat(sturdy, b, 3, &l2);
    var hit_b0: i32 = 0;
    var hit_b2: i32 = 0;
    for (l1[0..r0.len]) |t| {
        if (t.actor == .b and t.dmg > 0) {
            hit_b0 = t.dmg;
            break;
        }
    }
    for (l2[0..r2.len]) |t| {
        if (t.actor == .b and t.dmg > 0) {
            hit_b2 = t.dmg;
            break;
        }
    }
    try testing.expect(hit_b2 < hit_b0);
}
