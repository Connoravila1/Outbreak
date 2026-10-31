//! Gear and character endpoints: equip, unequip, scrap, upgrade, use, abilities, mission claims,
//! and the store.

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("../ctx.zig");
const model = @import("../model.zig");
const views = @import("../views.zig");
const rewards = @import("../rewards.zig");
const missions = @import("../missions.zig");
const warstate = @import("../warstate.zig");

const data = game.data;
const stats = game.stats;
const progression = game.progression;
const loot = game.loot;
const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;
const Player = model.Player;
const Stringify = std.json.Stringify;

pub const store_min_level = 2;
pub const upgrade_min_level = 4;
pub const flag_min_level = 15;
pub const buff_ms: i64 = 30 * 60 * 1000;
pub const boost_ms: i64 = 60 * 60 * 1000;
pub const max_scrap_batch = 100;

fn loadP(req: *Req) HandlerError!Player {
    return (try model.load(req, req.pid)).?;
}

fn meOut(req: *Req, jw: *Stringify, p: *Player) HandlerError!void {
    try jw.write(.{ .me = try views.meFresh(req, p.id) });
}

pub fn equip(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { uid: []const u8 });
    var p = try loadP(req);
    const o = p.find(body.uid) orelse return req.fail(404, "not_found", "You do not have that item.");
    if (o.item.req() > p.level) return req.fail(409, "level_too_low", "You need a higher level to equip that.");
    const slot = o.item.slot();
    // One item per slot: clear the slot, then set this one.
    for (p.items) |other| {
        if (other.equipped and other.item.slot() == slot) {
            try req.ctx.db.run("UPDATE items SET equipped = 0 WHERE id = ?", .{other.id});
        }
    }
    try req.ctx.db.run("UPDATE items SET equipped = 1 WHERE id = ?", .{o.id});
    var fresh = try loadP(req);
    try model.refreshSnapshot(req, &fresh);
    try meOut(req, jw, &fresh);
}

pub fn unequip(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { slot: []const u8 });
    const slot = std.meta.stringToEnum(data.Slot, body.slot) orelse return req.fail(400, "bad_request", "Unknown slot.");
    const p = try loadP(req);
    for (p.items) |o| {
        if (o.equipped and o.item.slot() == slot) try req.ctx.db.run("UPDATE items SET equipped = 0 WHERE id = ?", .{o.id});
    }
    var fresh = try loadP(req);
    try model.refreshSnapshot(req, &fresh);
    try meOut(req, jw, &fresh);
}

pub fn scrap(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { uids: []const []const u8 });
    if (body.uids.len == 0 or body.uids.len > max_scrap_batch) return req.fail(400, "bad_request", "Scrap between 1 and 100 items at a time.");
    var p = try loadP(req);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var gained: u32 = 0;
    var count: u32 = 0;
    for (body.uids) |uid| {
        const gop = try seen.getOrPut(req.arena, uid);
        if (gop.found_existing) continue;
        const o = p.find(uid) orelse return req.fail(404, "not_found", "You do not have that item.");
        if (o.equipped) return req.fail(409, "equipped", "Unequip an item before scrapping it.");
        gained += loot.scrapValue(o.item);
        count += 1;
    }
    var it = seen.keyIterator();
    while (it.next()) |uid| try req.ctx.db.run("DELETE FROM items WHERE player_id = ? AND uid = ?", .{ p.id, uid.* });
    p.salvage += gained;
    try model.save(req, &p);
    try missions.event(req, &p, .{ .kind = .item_scrap, .amount = count });
    try jw.write(.{ .salvage_gained = gained, .me = try views.meFresh(req, p.id) });
}

pub fn upgrade(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { uid: []const u8 });
    var p = try loadP(req);
    if (p.level < upgrade_min_level) return req.fail(409, "locked", "Item upgrading unlocks at level 4.");
    const o = p.find(body.uid) orelse return req.fail(404, "not_found", "You do not have that item.");
    const cost = loot.upgradeCost(o.item) orelse return req.fail(409, "max_upgrade", "That item is already at +10.");
    if (p.salvage < cost) return req.fail(409, "not_enough_salvage", "Not enough salvage.");
    p.salvage -= cost;
    try req.ctx.db.run("UPDATE items SET upgrade = upgrade + 1 WHERE id = ?", .{o.id});
    try model.save(req, &p);
    try missions.event(req, &p, .{ .kind = .item_upgrade });
    var fresh = try loadP(req);
    if (o.equipped) try model.refreshSnapshot(req, &fresh);
    try meOut(req, jw, &fresh);
}

pub fn use(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { consumable: []const u8 });
    const c = std.meta.stringToEnum(data.Consumable, body.consumable) orelse return req.fail(400, "bad_request", "Unknown consumable.");
    var p = try loadP(req);
    const now = req.now;
    const max = p.maxHp(now);
    if (c == .flag) return req.fail(409, "not_usable", "Flags are planted at Strongholds.");
    if (p.consumableCount(c) == 0) return req.fail(409, "none_left", "You have none of those.");

    switch (c) {
        .heal_s, .heal_m, .revive => {
            const is_down = p.downed(now);
            if (is_down and c != .revive) return req.fail(409, "downed", "You are down. Only a revive gets you up.");
            if (!is_down and p.hp >= max) return req.fail(409, "full_health", "You are already at full health.");
            if (c == .revive) {
                p.downed_until = null;
                p.setHp(max, now);
            } else {
                p.setHp(@min(max, p.hp + stats.healAmount(c, p.fac(), max)), now);
            }
        },
        .buff_atk, .buff_def, .buff_spd, .buff_xp, .buff_loot => {
            const idx = @intFromEnum(c) - @intFromEnum(data.Consumable.buff_atk);
            try model.setBuff(req, p.id, model.Buffs.names[idx], now + buff_ms);
        },
        .flag => unreachable,
    }
    _ = try model.takeConsumable(req, p.id, c);
    try model.save(req, &p);
    try missions.event(req, &p, .{ .kind = .consumable_use });
    try meOut(req, jw, &p);
}

pub fn abilities(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { equipped: []const []const u8 });
    var p = try loadP(req);
    var buf: [7]data.Ability = undefined;
    const unlocked = progression.unlockedAbilities(p.fac(), p.level, &buf);
    var set: std.EnumSet(data.Ability) = .initEmpty();
    for (body.equipped) |name| {
        const a = std.meta.stringToEnum(data.Ability, name) orelse return req.fail(400, "bad_request", "Unknown ability.");
        if (std.mem.indexOfScalar(data.Ability, unlocked, a) == null) return req.fail(409, "not_unlocked", "That ability is not unlocked.");
        set.insert(a);
    }
    if (set.count() > progression.abilitySlots(p.level)) return req.fail(409, "too_many", "You do not have that many ability slots.");
    p.abilities = set;
    try model.save(req, &p);
    try model.refreshSnapshot(req, &p);
    try meOut(req, jw, &p);
}

pub fn claimMission(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { id: []const u8 });
    var p = try loadP(req);
    const e = (try missions.find(req, &p, body.id)) orelse return req.fail(404, "not_found", "That is not one of your missions.");
    if (e.claimed) return req.fail(409, "already_claimed", "Already claimed.");
    if (e.progress < e.m.target) return req.fail(409, "incomplete", "That mission is not finished.");

    const day = game.war.dayIndex(req.now);
    const streak = if (e.m.weekly) 0 else missions.streakIfClaimed(req, &p);
    const r = game.missions.reward(e.m, p.level, streak);
    var acc = rewards.Acc{ .xp = r.xp, .flat_xp = true, .salvage = r.salvage };
    var rng = game.rng.Rng.init(game.rng.hash(req.ctx.seed, .{ "mission", p.id, e.id }));
    if (r.item_min_rarity) |min| try acc.items.append(req.arena, loot.rollItem(&rng, .{ .level = p.level, .min_rarity = min }));

    try req.ctx.db.run("UPDATE mission_progress SET claimed = 1 WHERE player_id = ? AND mid = ?", .{ p.id, e.id });
    if (!e.m.weekly) {
        p.streak = streak;
        p.last_claim_day = day;
        // The third daily of the day pays a bonus consumable.
        var claimed: u32 = 0;
        const t = try missions.today(req, &p);
        for (t.daily) |d| {
            if (d.claimed or std.mem.eql(u8, d.id, e.id)) claimed += 1;
        }
        if (claimed == game.missions.daily_count) acc.addConsumable(game.missions.all_dailies_bonus, 1);
    }
    const rw = try rewards.apply(req, &p, &acc, null);
    try jw.write(.{ .rewards = rw, .me = try views.meFresh(req, p.id) });
}

// --- Store -------------------------------------------------------------------------------------------------

pub fn buy(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { sku: []const u8 });
    var p = try loadP(req);
    if (p.level < store_min_level) return req.fail(409, "locked", "The Store unlocks at level 2.");
    const idx = data.findSku(body.sku) orelse return req.fail(404, "not_found", "No such item for sale.");
    const sku = data.store[idx];

    const is_expansion = std.mem.eql(u8, sku.sku, "inventory");
    const price: u32 = if (is_expansion) data.inventoryExpansionPrice(p.expansions) else sku.price;
    if (std.mem.eql(u8, sku.sku, "flag")) {
        if (p.level < flag_min_level) return req.fail(409, "locked", "Flags unlock at level 15.");
        if (p.clan_id == null) return req.fail(409, "no_clan", "Join a clan to buy a flag.");
    }
    if (p.salvage < price) return req.fail(409, "not_enough_salvage", "Not enough salvage.");

    var out_rewards: ?views.RewardsView = null;
    if (std.meta.stringToEnum(data.Consumable, sku.sku)) |c| {
        p.salvage -= price;
        try model.addConsumable(req, p.id, c, 1);
        var cm = views.ConsumableMap{};
        cm.counts[@intFromEnum(c)] = 1;
        out_rewards = .{ .consumables = cm };
    } else if (std.mem.eql(u8, sku.sku, "requisition")) {
        if (try model.itemCount(req, p.id) >= p.inventoryCap()) return req.fail(409, "inventory_full", "Your inventory is full.");
        p.salvage -= price;
        var rng = game.rng.Rng.init(game.rng.hash(req.ctx.seed, .{ "req", p.id, req.now, req.ctx.rng.next() }));
        const item = loot.rollItem(&rng, .{ .level = p.level, .min_rarity = .uncommon });
        const uid = try req.arena.dupe(u8, &(try model.insertItem(req, p.id, item, false)));
        const list = try req.arena.alloc(views.ItemView, 1);
        list[0] = try views.itemView(req.arena, uid, item);
        out_rewards = .{ .items = list };
    } else if (is_expansion) {
        p.salvage -= price;
        p.expansions += 1;
    } else if (std.mem.eql(u8, sku.sku, "xp_boost")) {
        p.salvage -= price;
        try model.setBuff(req, p.id, "xp_boost", req.now + boost_ms);
    } else return req.fail(500, "server_error", "Unhandled store item.");

    try model.save(req, &p);
    const me = try views.meFresh(req, p.id);
    if (out_rewards) |r| try jw.write(.{ .rewards = r, .me = me }) else try jw.write(.{ .me = me });
}
