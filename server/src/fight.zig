//! Running a fight and describing it: combatant views (anonymous for real opponents), the turn
//! log from either side's point of view, and the `Battle` shape.

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("ctx.zig");
const model = @import("model.zig");
const views = @import("views.zig");
const snapshot = @import("snapshot.zig");

const stance_rules = game.stance;
const daynight = game.daynight;
const data = game.data;
const stats = game.stats;
const combat = game.combat;
const progression = game.progression;
const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;
const Player = model.Player;
const Allocator = std.mem.Allocator;

pub const CombatantKind = enum { player, enemy, echo, rogue, boss };
pub const BattleKind = enum { pve, pvp, echo, raid, garrison };

pub const CombatantView = struct {
    name: []const u8,
    faction: data.Faction,
    level: u32,
    title: []const u8,
    kind: CombatantKind,
    archetype: ?[]const u8,
    max_hp: i32,
    hp_start: i32,
    stats: data.Stats,
    abilities: []const []const u8,
    gear: []const []const u8,
};

pub const BattleView = struct {
    id: []const u8,
    kind: BattleKind,
    /// The stance you fought in (null for Echo/Rogue playback of other people's fights).
    stance: ?data.Stance,
    a: CombatantView,
    b: CombatantView,
    turns: []const combat.Turn,
    winner: combat.Side,
    rewards: views.RewardsView,
    me: views.MeView,
};

/// One side of a fight: what the engine needs plus how to show it.
pub const Side = struct {
    combatant: combat.Combatant,
    view: CombatantView,
    /// The stance this side fought in (players only).
    stance: ?data.Stance = null,
    /// A stance can scale the HP pool for the fight (Evasive); the real pool and the factor let
    /// the HP left be converted back.
    hp_scale: f32 = 1.0,
    real_max_hp: i32 = 0,
};

/// A player's real HP after the fight `o` (where this side was "a").
pub fn hpAfter(side: Side, o: Outcome) i32 {
    if (side.real_max_hp == 0) return o.result.hp_a;
    return stance_rules.realHp(o.result.hp_a, side.hp_scale, side.real_max_hp);
}

pub const Outcome = struct {
    seed: u64,
    result: combat.Result,
    turns: []combat.Turn,

    pub fn won(self: Outcome) bool {
        return self.result.winner == .a;
    }
};

fn names(arena: Allocator, set: std.EnumSet(data.Ability)) Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = set;
    var iter = it.iterator();
    while (iter.next()) |ab| try list.append(arena, @tagName(ab));
    return list.items;
}

fn gearNames(arena: Allocator, b: *const snapshot.Build) Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (b.items) |maybe| {
        if (maybe) |it| try list.append(arena, it.name(b.faction));
    }
    return list.items;
}

/// You, as side "a", in your saved stance (Contact and anything else that does not ask).
pub fn selfSide(req: *Req, p: *const Player) Allocator.Error!Side {
    return selfSideWith(req, p, p.stance, null);
}

/// You, as side "a": `stance` and the phase of the day (from your position) applied to your totals;
/// `foe` is the PvE archetype, if any, whose counter relationship counts.
pub fn selfSideWith(req: *Req, p: *const Player, stance: data.Stance, foe: ?data.Archetype) Allocator.Error!Side {
    const now = req.now;
    const comp = p.computed(now);
    const b = p.build();
    const night: ?bool = if (req.ctx.live.position(p.id, now)) |pos| daynight.isNight(now, pos.lon) else null;
    const base = combat.Combatant{ .faction = p.fac(), .stats = comp.stats, .hp = p.hp, .abilities = p.abilities, .mods = comp.mods };
    const adj = stance_rules.adjust(base, stance, foe, night);
    return .{
        .combatant = adj.c,
        .stance = stance,
        .hp_scale = adj.hp_scale,
        .real_max_hp = comp.stats.hp,
        .view = .{
            .name = p.callsign,
            .faction = p.fac(),
            .level = p.level,
            .title = p.title(),
            .kind = .player,
            .archetype = null,
            .max_hp = adj.c.stats.hp,
            .hp_start = adj.c.hp,
            .stats = adj.c.stats,
            .abilities = try names(req.arena, p.abilities),
            .gear = try gearNames(req.arena, &b),
        },
    };
}

/// A build as an opponent: anonymous when it is a real player ("A Zombie"), labelled when it is
/// an Echo or a Rogue. `hp` is the HP it starts with (null: full).
pub fn buildSide(arena: Allocator, b: *const snapshot.Build, kind: CombatantKind, hp: ?i32) Allocator.Error!Side {
    var c = b.combatant();
    if (hp) |h| c.hp = std.math.clamp(h, 1, c.stats.hp);
    const f = b.faction;
    const label = switch (kind) {
        .echo => "Echo",
        .rogue => "Rogue",
        else => if (f == .zombie) "A Zombie" else "A Human",
    };
    return .{
        .combatant = c,
        .view = .{
            .name = label,
            .faction = f,
            .level = b.level,
            .title = progression.title(f, b.level),
            .kind = kind,
            .archetype = null,
            .max_hp = c.stats.hp,
            .hp_start = c.hp,
            .stats = c.stats,
            .abilities = try names(arena, b.abilities),
            .gear = try gearNames(arena, b),
        },
    };
}

/// A PvE enemy as the viewer's opposing faction sees it. `mult` scales its HP, ATK and DEF
/// (new-player grace, First Blood; 1.0 otherwise).
pub fn enemySide(arena: Allocator, viewer: data.Faction, arch: data.Archetype, level: u32, elite: bool, boss: bool, mult: f32) Allocator.Error!Side {
    _ = arena;
    const s = stats.enemyStatsScaled(arch, level, mult);
    const row = data.archetype(arch);
    return .{
        .combatant = .{ .faction = viewer.opposite(), .stats = s, .hp = s.hp },
        .view = .{
            .name = row.name.get(viewer),
            .faction = viewer.opposite(),
            .level = level,
            .title = if (boss) "Raid Boss" else if (elite) "Elite" else row.note,
            .kind = if (boss) .boss else .enemy,
            .archetype = @tagName(arch),
            .max_hp = s.hp,
            .hp_start = s.hp,
            .stats = s,
            .abilities = &.{},
            .gear = &.{},
        },
    };
}

/// Fight seed: server seed, the two parties and the time.
pub fn seedFor(req: *Req, a_id: i64, extra: u64) u64 {
    const ctx = req.ctx;
    return game.rng.hash(ctx.seed, .{ "fight", a_id, req.now, extra, ctx.rng.next() });
}

pub fn run(req: *Req, a: Side, b: Side, seed: u64) Allocator.Error!Outcome {
    var log: [combat.max_log]combat.Turn = undefined;
    const result = combat.fight(a.combatant, b.combatant, seed, &log);
    return .{ .seed = seed, .result = result, .turns = try req.arena.dupe(combat.Turn, log[0..result.len]) };
}

/// The same fight seen from the other side: actors and HP columns swapped.
pub fn flip(arena: Allocator, o: Outcome) Allocator.Error!Outcome {
    const turns = try arena.alloc(combat.Turn, o.turns.len);
    for (o.turns, 0..) |t, i| {
        turns[i] = t;
        turns[i].actor = t.actor.other();
        turns[i].hp_a = t.hp_b;
        turns[i].hp_b = t.hp_a;
    }
    var r = o.result;
    r.winner = r.winner.other();
    std.mem.swap(i32, &r.hp_a, &r.hp_b);
    return .{ .seed = o.seed, .result = r, .turns = turns };
}

pub fn battleView(req: *Req, kind: BattleKind, a: Side, b: Side, o: Outcome, rewards: views.RewardsView, me: views.MeView) Allocator.Error!BattleView {
    return .{
        .id = try std.fmt.allocPrint(req.arena, "{x:0>16}", .{o.seed}),
        .kind = kind,
        .stance = a.stance,
        .a = a.view,
        .b = b.view,
        .turns = o.turns,
        .winner = o.result.winner,
        .rewards = rewards,
        .me = me,
    };
}

/// Serialize any shape to a JSON string in the request arena.
pub fn toJson(arena: Allocator, value: anytype) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(arena, value, .{});
}

test "flipping a fight twice gives the original" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = snapshot.kitBuild(.human, 10, .common);
    const b = snapshot.kitBuild(.zombie, 10, .uncommon);
    var log: [combat.max_log]combat.Turn = undefined;
    const r = combat.fight(a.combatant(), b.combatant(), 5, &log);
    const o = Outcome{ .seed = 5, .result = r, .turns = log[0..r.len] };
    const f = try flip(arena.allocator(), o);
    try std.testing.expectEqual(o.result.winner.other(), f.result.winner);
    try std.testing.expectEqual(o.result.hp_a, f.result.hp_b);
    const ff = try flip(arena.allocator(), f);
    try std.testing.expectEqualSlices(combat.Turn, o.turns, ff.turns);
    try std.testing.expectEqual(o.result, ff.result);
}

test "opponent views are anonymous for players and labelled for echoes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = snapshot.kitBuild(.zombie, 14, .rare);
    const real = try buildSide(arena.allocator(), &b, .player, 50);
    try std.testing.expectEqualStrings("A Zombie", real.view.name);
    try std.testing.expectEqual(@as(i32, 50), real.view.hp_start);
    const echo = try buildSide(arena.allocator(), &b, .rogue, null);
    try std.testing.expectEqualStrings("Rogue", echo.view.name);
    try std.testing.expectEqual(echo.view.max_hp, echo.view.hp_start);
    try std.testing.expectEqualStrings("Lashing Tendril", real.view.gear[0]);
}
