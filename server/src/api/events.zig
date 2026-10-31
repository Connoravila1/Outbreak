//! Limited-time events (DESIGN.md section 18): GET /api/events (what is live, your part in it, what
//! is coming, the Exchange) and POST /api/events/exchange. The rules are in game/events.zig, the
//! bookkeeping in worldevents.zig.

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("../ctx.zig");
const model = @import("../model.zig");
const views = @import("../views.zig");
const ach_db = @import("../achievements.zig");
const worldevents = @import("../worldevents.zig");

const data = game.data;
const gev = game.events;
const loot = game.loot;
const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;
const Stringify = std.json.Stringify;

const GoalView = struct { target: u32, progress: u32, done: bool };
const DistrictView = struct { id: []const u8, target: u32, progress: u32, done: bool };
const MineView = struct { n: u32, tier: u8, next_at: ?u32, goal_met: bool };
const LiveView = struct {
    id: i64,
    type: data.EventType,
    kind: ?[]const u8,
    admin: bool,
    starts_at: i64,
    ends_at: i64,
    active_players: u32,
    goal: GoalView,
    district: ?DistrictView,
    mine: MineView,
};
const UpcomingView = struct { type: data.EventType, kind: ?[]const u8, starts_at: i64, ends_at: i64 };
const ExchangeItem = struct { sku: []const u8, price: u32, limit: u8, bought: u32, owned: bool };

fn liveView(req: *Req, row: worldevents.Row, pid: i64) HandlerError!LiveView {
    const def = row.def();
    const n = try worldevents.contribution(req, row.id, pid);
    const tier = gev.tier(def, n);
    const dg = try worldevents.districtGoal(req, row, pid);
    return .{
        .id = row.id,
        .type = row.type,
        .kind = worldevents.kindOf(row),
        .admin = row.admin,
        .starts_at = row.starts_at,
        .ends_at = row.ends_at,
        .active_players = row.active_players,
        .goal = .{ .target = row.target, .progress = row.progress, .done = row.done() },
        .district = if (dg) |d| .{ .id = d.id, .target = d.target, .progress = d.progress, .done = d.progress >= d.target } else null,
        .mine = .{ .n = n, .tier = tier, .next_at = if (tier < 3) def.tiers[tier] else null, .goal_met = try worldevents.goalMet(req, row, pid) },
    };
}

fn exchangeView(req: *Req, row: ?worldevents.Row, p: *const model.Player) HandlerError![]const ExchangeItem {
    const items = try req.arena.alloc(ExchangeItem, data.event_exchange.len);
    for (data.event_exchange, items) |s, *out| {
        out.* = .{
            .sku = s.sku,
            .price = s.price,
            .limit = s.limit,
            .bought = if (row) |r| try worldevents.bought(req, r.id, p.id, s.sku) else 0,
            .owned = if (game.cosmetics.find(s.sku) != null) try ach_db.owns(req, p.id, s.sku) else false,
        };
    }
    return items;
}

pub fn list(req: *Req, jw: *Stringify) HandlerError!void {
    try worldevents.upkeep(req);
    const p = (try model.load(req, req.pid)).?;
    const row = try worldevents.live(req);

    var buf: [6]gev.Occurrence = undefined;
    var coming: std.ArrayList(UpcomingView) = .empty;
    for (gev.upcoming(req.now, &buf)) |o| {
        if (o.starts_at <= req.now) continue;
        const kind: ?[]const u8 = if (o.type == .horde) @tagName(@as(data.Archetype, @enumFromInt(o.param))) else null;
        try coming.append(req.arena, .{ .type = o.type, .kind = kind, .starts_at = o.starts_at, .ends_at = o.ends_at });
    }
    try jw.write(.{
        .now = req.now,
        .live = if (row) |r| try liveView(req, r, p.id) else null,
        .upcoming = coming.items,
        .exchange = .{
            .open = row != null and p.level >= data.exchange_min_level,
            .min_level = data.exchange_min_level,
            .items = try exchangeView(req, row, &p),
        },
    });
}

/// Three item rolls, Uncommon or better; the best one is kept (rarity first, then what it scraps for).
fn bestOfThree(rng: *game.rng.Rng, level: u32) game.stats.Item {
    var best = loot.rollItem(rng, .{ .level = level, .min_rarity = .uncommon });
    for (0..2) |_| {
        const it = loot.rollItem(rng, .{ .level = level, .min_rarity = .uncommon });
        if (@intFromEnum(it.rarity) > @intFromEnum(best.rarity) or
            (it.rarity == best.rarity and loot.scrapValue(it) > loot.scrapValue(best))) best = it;
    }
    return best;
}

pub fn exchange(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { sku: []const u8 });
    var p = (try model.load(req, req.pid)).?;
    const row = (try worldevents.live(req)) orelse return req.fail(409, "no_event", "The Exchange is closed. It opens while an event is live.");
    if (p.level < data.exchange_min_level) return req.fail(409, "locked", "The Exchange opens at level 10.");
    const idx = data.findExchange(body.sku) orelse return req.fail(404, "not_found", "No such item for sale.");
    const sku = data.event_exchange[idx];
    if (try worldevents.bought(req, row.id, p.id, sku.sku) >= sku.limit) return req.fail(409, "sold_out", "You have bought all you can of that this event.");
    const cosmetic = game.cosmetics.find(sku.sku);
    if (cosmetic != null and try ach_db.owns(req, p.id, sku.sku)) return req.fail(409, "owned", "You already own that.");
    if (p.salvage < sku.price) return req.fail(409, "not_enough_salvage", "Not enough salvage.");
    const needs_room: u32 = if (std.mem.eql(u8, sku.sku, "ex_requisition") or std.mem.eql(u8, sku.sku, "ex_crate")) 1 else 0;
    if (needs_room > 0 and try model.itemCount(req, p.id) >= p.inventoryCap()) return req.fail(409, "inventory_full", "Your inventory is full.");

    p.salvage -= sku.price;
    var rw = views.RewardsView{};
    var rng = game.rng.Rng.init(game.rng.hash(req.ctx.seed, .{ "exchange", p.id, row.id, req.now, req.ctx.rng.next() }));
    if (cosmetic != null) {
        try ach_db.grantCosmetic(req, p.id, sku.sku);
        const c = game.cosmetics.list[cosmetic.?];
        const unlocks = try req.arena.alloc(views.UnlockRef, 1);
        unlocks[0] = .{ .kind = @tagName(c.kind), .id = c.id, .name = c.name.get(p.fac()) };
        rw.unlocks = unlocks;
    } else if (std.mem.eql(u8, sku.sku, "ex_requisition")) {
        const item = bestOfThree(&rng, p.level);
        const uid = try req.arena.dupe(u8, &(try model.insertItem(req, p.id, item, false)));
        const list_ = try req.arena.alloc(views.ItemView, 1);
        list_[0] = try views.itemView(req.arena, uid, item);
        rw.items = list_;
        rw.achievements = try ach_db.check(req, &p, false);
    } else if (std.mem.eql(u8, sku.sku, "ex_crate")) {
        const item = loot.rollItem(&rng, .{ .level = p.level, .min_rarity = .rare, .legendary_mult = 2.0 });
        const uid = try req.arena.dupe(u8, &(try model.insertItem(req, p.id, item, false)));
        const list_ = try req.arena.alloc(views.ItemView, 1);
        list_[0] = try views.itemView(req.arena, uid, item);
        rw.items = list_;
        for (0..2) |_| {
            const c = loot.rollConsumable(&rng);
            try model.addConsumable(req, p.id, c, 1);
            rw.consumables.counts[@intFromEnum(c)] += 1;
        }
        rw.achievements = try ach_db.check(req, &p, false);
    } else return req.fail(500, "server_error", "Unhandled Exchange item.");

    try worldevents.recordBuy(req, row.id, p.id, sku.sku);
    try model.save(req, &p);
    try jw.write(.{ .rewards = rw, .me = try views.meFresh(req, p.id) });
}
