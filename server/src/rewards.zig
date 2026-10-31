//! Paying out: XP with every bonus, salvage, items (with the inventory cap), consumables, war
//! points, level-ups with their unlocks. Handlers collect what a fight or action earned in an
//! `Acc`, then `apply` turns it into database changes and the `Rewards` shape.

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("ctx.zig");
const model = @import("model.zig");
const views = @import("views.zig");
const warstate = @import("warstate.zig");
const notes_db = @import("notes.zig");
const ach_db = @import("achievements.zig");

const data = game.data;
const stats = game.stats;
const progression = game.progression;
const loot = game.loot;
const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;
const Player = model.Player;

pub const Acc = struct {
    /// XP before bonuses; `apply` multiplies it.
    xp: u32 = 0,
    /// Pay `xp` as it is (mission XP already includes the streak).
    flat_xp: bool = false,
    salvage: u32 = 0,
    items: std.ArrayList(stats.Item) = .empty,
    consumables: [model.consumable_count]u32 = [_]u32{0} ** model.consumable_count,
    war_points: u32 = 0,
    /// Indexes into `game.notes.notes` found with this payout.
    notes: std.ArrayList(u16) = .empty,
    /// Indexes into `game.cosmetics.list` found with this payout.
    cosmetics: std.ArrayList(u8) = .empty,
    /// Queue the level-up as an undelivered event (for gains the player is not looking at, like
    /// walking); otherwise the response already shows it and the event only goes to the feed.
    deliver_level_up: bool = false,

    pub fn addDrop(self: *Acc, req: *Req, d: loot.Drop) error{OutOfMemory}!void {
        self.salvage += d.salvage;
        for (d.itemSlice()) |it| try self.items.append(req.arena, it);
        for (d.consumableSlice()) |c| self.consumables[@intFromEnum(c)] += 1;
    }

    pub fn addNote(self: *Acc, req: *Req, idx: u16) error{OutOfMemory}!void {
        for (self.notes.items) |n| if (n == idx) return;
        try self.notes.append(req.arena, idx);
    }

    /// Roll for a note from `src`. It uses its own random stream (from `seed`), so item drops are
    /// the same with or without notes.
    pub fn rollNote(self: *Acc, req: *Req, p: *const Player, src: game.notes.Source, place: ?data.PlaceKind, seed: u64) HandlerError!void {
        var found = try notes_db.foundSet(req, p.id);
        for (self.notes.items) |i| found.set(i);
        var rng = game.rng.Rng.init(game.rng.hash(seed, .{"note"}));
        if (game.notes.roll(&rng, p.fac(), found, src, place)) |i| try self.notes.append(req.arena, i);
    }

    /// Roll for a found cosmetic from `src`, on its own random stream (from `seed`) so item drops
    /// are the same with or without it.
    pub fn rollCosmetic(self: *Acc, req: *Req, src: game.cosmetics.Source, seed: u64) error{OutOfMemory}!void {
        var rng = game.rng.Rng.init(game.rng.hash(seed, .{"cosmetic"}));
        if (game.cosmetics.roll(&rng, src, req.ctx.cosmetic_odds)) |i| try self.cosmetics.append(req.arena, i);
    }

    pub fn addConsumable(self: *Acc, c: data.Consumable, n: u32) void {
        self.consumables[@intFromEnum(c)] += n;
    }
};

/// Total loot multiplier: Lucky perks and the loot buff.
pub fn lootMult(p: *const Player, now: i64) f32 {
    var m: f32 = 1.0 + p.computed(now).mods.loot;
    if (model.Buffs.on(p.buffs.loot, now)) m += 0.5;
    return m;
}

/// The XP multiplier for `p` right now. `district` is the war district the XP is earned in.
pub fn xpMultiplier(req: *Req, p: *const Player, district: ?[]const u8) HandlerError!f32 {
    const f = p.faction orelse return 1.0;
    const sh = try warstate.shares(req);
    return progression.xpMultiplier(.{
        .underdog = sh.bonusFor(f),
        .buff_xp = model.Buffs.on(p.buffs.xp, req.now),
        .boost = model.Buffs.on(p.buffs.boost, req.now),
        .district = if (district) |d| try warstate.wonDistrictLastWeek(req, f, d) else false,
        .adjacency = if (p.clan_id) |c| try warstate.adjacencyBonus(req, c) else 0,
    });
}

/// Pay `acc` to `p` (saves the player). `district` is where war points and the district XP bonus
/// land; null skips both.
pub fn apply(req: *Req, p: *Player, acc: *Acc, district: ?[]const u8) HandlerError!views.RewardsView {
    const a = req.arena;
    var out = views.RewardsView{};

    var xp = acc.xp;
    if (!acc.flat_xp and xp > 0) {
        const m = try xpMultiplier(req, p, district);
        xp = @intFromFloat(@round(@as(f32, @floatFromInt(xp)) * m));
    }
    out.xp = xp;

    const before = p.level;
    const lr = progression.applyXp(p.level, p.xp, xp);
    p.xp = lr.xp;
    p.level = lr.level;
    if (lr.levels_gained > 0) {
        var texts: [24][]const u8 = undefined;
        const n = progression.unlockTexts(before, p.level, &texts);
        out.level_up = .{ .from = before, .to = p.level, .unlocks = try a.dupe([]const u8, texts[0..n]) };
        model.fillAbilities(p);
        // Levelling up heals fully.
        if (!p.downed(req.now)) p.setHp(p.maxHp(req.now), req.now);
    }

    var salvage = acc.salvage;
    const cap = p.inventoryCap();
    var have = try model.itemCount(req, p.id);
    const item_views = try a.alloc(views.ItemView, acc.items.items.len);
    var kept: usize = 0;
    for (acc.items.items) |it| {
        if (have < cap) {
            const uid = try a.dupe(u8, &(try model.insertItem(req, p.id, it, false)));
            item_views[kept] = try views.itemView(a, uid, it);
            kept += 1;
            have += 1;
        } else {
            const v = loot.scrapValue(it);
            salvage += v;
            out.auto_scrapped += v;
            try ach_db.discover(req, p.id, it);
        }
    }
    out.items = item_views[0..kept];

    // Found cosmetics: new ones are owned for good; one you already have becomes salvage.
    if (acc.cosmetics.items.len > 0) {
        const finds = try a.alloc(views.CosmeticFind, acc.cosmetics.items.len);
        var n: usize = 0;
        for (acc.cosmetics.items) |ci| {
            const c = game.cosmetics.list[ci];
            const dup = try ach_db.owns(req, p.id, c.id);
            const sv: u32 = if (dup) game.cosmetics.duplicateSalvage(c) else 0;
            if (!dup) try ach_db.grantCosmetic(req, p.id, c.id);
            salvage += sv;
            finds[n] = .{ .id = c.id, .kind = @tagName(c.kind), .duplicate = dup, .salvage = sv };
            n += 1;
        }
        out.cosmetics = finds[0..n];
    }
    out.salvage = salvage;
    p.salvage += salvage;

    for (acc.consumables, 0..) |n, i| {
        try model.addConsumable(req, p.id, @enumFromInt(i), n);
        out.consumables.counts[i] = n;
    }

    if (acc.notes.items.len > 0) {
        const refs = try a.alloc(views.NoteRef, acc.notes.items.len);
        var n: usize = 0;
        for (acc.notes.items) |idx| {
            if (!try notes_db.grant(req, p.id, idx)) continue;
            refs[n] = views.noteRef(idx);
            n += 1;
        }
        out.notes = refs[0..n];
    }

    // A simulated location earns no war points (the fight itself still pays).
    if (acc.war_points > 0 and !req.ctx.live.simulated(p.id, req.now)) {
        if (district) |d| {
            try warstate.addPoints(req, p.id, p.fac(), d, acc.war_points);
            out.war_points = acc.war_points;
        }
    }

    // Milestones last: they count what this payout just changed. Their salvage lands in `p` here.
    out.achievements = try ach_db.check(req, p, acc.deliver_level_up);

    try model.save(req, p);
    if (lr.levels_gained > 0) {
        try model.refreshSnapshot(req, p);
        const text = try std.fmt.allocPrint(a, "Reached level {d}.", .{p.level});
        const body: ?[]const u8 = if (acc.deliver_level_up) try std.json.Stringify.valueAlloc(a, out, .{}) else null;
        try model.pushEvent(req, p.id, "level_up", text, null, body, !acc.deliver_level_up);
    }
    return out;
}

/// Record the end of a fight on the player's HP: Downed at 0, otherwise the surviving HP.
pub fn settleHp(p: *Player, hp_after: i32, now: i64) void {
    if (hp_after <= 0) p.down(now) else p.setHp(hp_after, now);
}
