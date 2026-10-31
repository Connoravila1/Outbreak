//! The JSON shapes of docs/ARCHITECTURE.md as Zig structs, plus the builders that fill them.
//! Field names are the wire names: `std.json.Stringify.write` emits them as they are.

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("ctx.zig");
const model = @import("model.zig");
const missions = @import("missions.zig");
const warstate = @import("warstate.zig");
const notes_db = @import("notes.zig");

const data = game.data;
const stats = game.stats;
const progression = game.progression;
const loot = game.loot;
const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;
const Player = model.Player;
const Allocator = std.mem.Allocator;

pub const ItemView = struct {
    uid: []const u8,
    base: []const u8,
    slot: data.Slot,
    rarity: data.Rarity,
    upgrade: u8,
    perks: []const []const u8,
    unique: ?[]const u8,
    req: u8,
    stats: data.Stats,
    power: i32,
    scrap_value: u32,
    upgrade_cost: ?u32,
};

pub fn itemView(arena: Allocator, uid: []const u8, item: stats.Item) Allocator.Error!ItemView {
    const perks = try arena.alloc([]const u8, item.perk_count);
    for (item.perks(), 0..) |pk, i| perks[i] = @tagName(pk);
    return .{
        .uid = uid,
        .base = item.row().id,
        .slot = item.slot(),
        .rarity = item.rarity,
        .upgrade = item.upgrade,
        .perks = perks,
        .unique = if (item.unique) |u| data.uniques[u].id else null,
        .req = item.req(),
        .stats = stats.itemStats(item),
        .power = stats.itemPower(item),
        .scrap_value = loot.scrapValue(item),
        .upgrade_cost = loot.upgradeCost(item),
    };
}

/// `Record<string, number>` of consumable counts (zeros are left out).
pub const ConsumableMap = struct {
    counts: [model.consumable_count]u32 = [_]u32{0} ** model.consumable_count,

    pub fn jsonStringify(self: ConsumableMap, jw: anytype) !void {
        try jw.beginObject();
        for (self.counts, 0..) |n, i| {
            if (n == 0) continue;
            try jw.objectField(@tagName(@as(data.Consumable, @enumFromInt(i))));
            try jw.write(n);
        }
        try jw.endObject();
    }
};

/// `Record<archetype, number>`: how often each enemy type has been fought (the raid boss is left out).
pub const BestiaryMap = struct {
    counts: [data.archetypes.len]u32 = [_]u32{0} ** data.archetypes.len,

    pub fn jsonStringify(self: BestiaryMap, jw: anytype) !void {
        try jw.beginObject();
        for (data.archetypes, 0..) |a, i| {
            if (a.weight == 0) continue;
            try jw.objectField(@tagName(a.id));
            try jw.write(self.counts[i]);
        }
        try jw.endObject();
    }
};

pub const LevelUp = struct { from: u8, to: u8, unlocks: []const []const u8 };

/// A found note as a payout line: enough to draw the card; the text is read through /api/notes.
pub const NoteRef = struct { id: []const u8, title: []const u8, set: []const u8, rarity: data.Rarity, form: game.notes.Form };

pub fn noteRef(idx: u16) NoteRef {
    const n = game.notes.notes[idx];
    return .{ .id = n.id, .title = n.title, .set = @tagName(n.set), .rarity = n.rarity, .form = n.form };
}

pub const RewardsView = struct {
    xp: u32 = 0,
    salvage: u32 = 0,
    items: []const ItemView = &.{},
    consumables: ConsumableMap = .{},
    war_points: u32 = 0,
    level_up: ?LevelUp = null,
    /// Salvage from items that did not fit in the inventory (already included in `salvage`).
    auto_scrapped: u32 = 0,
    /// Notes found with this payout.
    notes: []const NoteRef = &.{},
};

pub const EquippedView = struct { weapon: ?[]const u8, armor: ?[]const u8, utility: ?[]const u8 };

pub const AbilitiesView = struct {
    unlocked: []const []const u8,
    equipped: []const []const u8,
    slots: u8,
};

pub const BuffView = struct { kind: []const u8, until: i64 };

pub const MissionView = struct {
    id: []const u8,
    kind: []const u8,
    text: []const u8,
    target: u32,
    progress: u32,
    rewards: RewardsView,
    claimed: bool,
};

pub const MissionsView = struct {
    daily: []const MissionView,
    weekly: ?MissionView,
    streak: u32,
    resets_at: i64,
};

pub const ClanRef = struct { id: []const u8, name: []const u8, tag: []const u8, role: []const u8 };

/// Pre-serialized JSON written as it is.
pub const Raw = struct {
    text: []const u8,

    pub fn jsonStringify(self: Raw, jw: anytype) !void {
        try jw.beginWriteRaw();
        try jw.writer.writeAll(self.text);
        jw.endWriteRaw();
    }
};

pub const RecordView = struct {
    wins: u32,
    losses: u32,
    contacts: u32,
    contacts_won: u32,
    contacts_lost: u32,
    echoes: u32,
    echoes_won: u32,
    caches: u32,
    distance_m: u64,
};

/// Notes found, and how many this faction can find in all.
pub const NotesTally = struct { found: u32, total: u32 };

pub const AccountView = struct { guest: bool, providers: []const []const u8, email: ?[]const u8 };

pub const MeView = struct {
    id: []const u8,
    /// Null until the player picks one.
    callsign: ?[]const u8,
    /// A moderator reset the callsign; the player must choose a new one.
    must_rename: bool,
    faction: ?data.Faction,
    level: u8,
    xp: u32,
    xp_next: u32,
    title: []const u8,
    hp: i32,
    max_hp: i32,
    downed_until: ?i64,
    stats: data.Stats,
    base_stats: data.Stats,
    salvage: u32,
    inventory_cap: u32,
    /// Salvage price of the next inventory expansion (it rises with each one bought).
    expansion_price: u32,
    equipped: EquippedView,
    items: []const ItemView,
    consumables: ConsumableMap,
    abilities: AbilitiesView,
    buffs: []const BuffView,
    missions: MissionsView,
    clan: ?ClanRef,
    avatar: ?Raw,
    pvp_protected: bool,
    underdog_bonus: f32,
    war_points_week: u32,
    record: RecordView,
    contact_rank: progression.ContactRank,
    account: AccountView,
    /// The saved default stance (used in Contact); PvE asks per fight.
    stance: data.Stance,
    bestiary: BestiaryMap,
    notes: NotesTally,
    /// Cosmetic titles from completed note sets (the level title stays in `title`).
    titles_extra: []const []const u8,
};

pub const MeLite = struct {
    hp: i32,
    max_hp: i32,
    downed_until: ?i64,
    level: u8,
    xp: u32,
    xp_next: u32,
    salvage: u32,
};

pub fn meLite(p: *const Player, now: i64) MeLite {
    return .{
        .hp = p.hp,
        .max_hp = p.maxHp(now),
        .downed_until = if (p.downed(now)) p.downed_until else null,
        .level = p.level,
        .xp = p.xp,
        .xp_next = progression.xpToNext(p.level),
        .salvage = p.salvage,
    };
}

pub fn rewardsPreview(xp: u32, salvage: u32) RewardsView {
    return .{ .xp = xp, .salvage = salvage };
}

fn missionView(req: *Req, p: *const Player, e: missions.Entry, streak: u32) Allocator.Error!MissionView {
    const buf = try req.arena.alloc(u8, 96);
    const r = game.missions.reward(e.m, p.level, streak);
    return .{
        .id = e.id,
        .kind = @tagName(e.m.kind),
        .text = e.m.text(p.fac(), buf),
        .target = e.m.target,
        .progress = e.progress,
        .rewards = rewardsPreview(r.xp, r.salvage),
        .claimed = e.claimed,
    };
}

/// The full `Me` for a player (loaded fresh from `p`).
pub fn meView(req: *Req, p: *Player) HandlerError!MeView {
    const a = req.arena;
    const now = req.now;
    const comp = p.computed(now);

    const items = try a.alloc(ItemView, p.items.len);
    var eq = EquippedView{ .weapon = null, .armor = null, .utility = null };
    for (p.items, 0..) |o, i| {
        items[i] = try itemView(a, o.uid, o.item);
        if (o.equipped) switch (o.item.slot()) {
            .weapon => eq.weapon = o.uid,
            .armor => eq.armor = o.uid,
            .utility => eq.utility = o.uid,
        };
    }

    var unlocked_buf: [7]data.Ability = undefined;
    const unlocked_ids = progression.unlockedAbilities(p.fac(), p.level, &unlocked_buf);
    const unlocked = try a.alloc([]const u8, unlocked_ids.len);
    for (unlocked_ids, 0..) |id, i| unlocked[i] = @tagName(id);
    var equipped: std.ArrayList([]const u8) = .empty;
    for (unlocked_ids) |id| {
        if (p.abilities.contains(id)) try equipped.append(a, @tagName(id));
    }

    var buffs: std.ArrayList(BuffView) = .empty;
    var b = p.buffs;
    for (model.Buffs.names) |n| {
        const until = b.ptr(n).?.*;
        if (model.Buffs.on(until, now)) try buffs.append(a, .{ .kind = n, .until = until });
    }

    const t = try missions.today(req, p);
    const streak_now = game.missions.streakShown(p.streak, p.last_claim_day, game.war.dayIndex(now));
    const preview_streak = missions.streakIfClaimed(req, p);
    const daily = try a.alloc(MissionView, t.daily.len);
    for (t.daily, 0..) |e, i| daily[i] = try missionView(req, p, e, preview_streak);
    const weekly: ?MissionView = if (t.weekly) |w| try missionView(req, p, w, 0) else null;

    var consumables = ConsumableMap{};
    consumables.counts = p.consumables;

    var clan: ?ClanRef = null;
    if (p.clan_id) |cid| {
        var st = try req.ctx.db.query("SELECT name, tag FROM clans WHERE id = ?", .{cid});
        defer st.finalize();
        if (try st.step()) clan = .{
            .id = try std.fmt.allocPrint(a, "{d}", .{cid}),
            .name = try st.dupe(a, 0),
            .tag = try st.dupe(a, 1),
            .role = p.clan_role orelse "member",
        };
    }

    var providers: std.ArrayList([]const u8) = .empty;
    var email: ?[]const u8 = null;
    {
        var st = try req.ctx.db.query("SELECT provider, email FROM identities WHERE player_id = ? ORDER BY id", .{p.id});
        defer st.finalize();
        while (try st.step()) {
            try providers.append(a, try st.dupe(a, 0));
            if (email == null) {
                if (st.optText(1)) |e| email = try a.dupe(u8, e);
            }
        }
    }

    const sh = try warstate.shares(req);
    return .{
        .id = try std.fmt.allocPrint(a, "{d}", .{p.id}),
        .callsign = if (p.callsign.len > 0) p.callsign else null,
        .must_rename = ((try req.ctx.db.scalar("SELECT must_rename FROM players WHERE id = ?", .{p.id})) orelse 0) != 0,
        .faction = p.faction,
        .level = p.level,
        .xp = p.xp,
        .xp_next = progression.xpToNext(p.level),
        .title = p.title(),
        .hp = p.hp,
        .max_hp = comp.stats.hp,
        .downed_until = if (p.downed(now)) p.downed_until else null,
        .stats = comp.stats,
        .base_stats = stats.baseStats(p.level),
        .salvage = p.salvage,
        .inventory_cap = p.inventoryCap(),
        .expansion_price = data.inventoryExpansionPrice(p.expansions),
        .equipped = eq,
        .items = items,
        .consumables = consumables,
        .abilities = .{ .unlocked = unlocked, .equipped = equipped.items, .slots = progression.abilitySlots(p.level) },
        .buffs = buffs.items,
        .missions = .{ .daily = daily, .weekly = weekly, .streak = streak_now, .resets_at = game.missions.dailyResetsAt(now) },
        .clan = clan,
        .avatar = if (p.avatar) |text| .{ .text = text } else null,
        .pvp_protected = progression.pvpProtected(p.level),
        .underdog_bonus = if (p.faction) |f| sh.bonusFor(f) else 0,
        .war_points_week = try warstate.weekPoints(req, p.id),
        .record = .{ .wins = p.wins, .losses = p.losses, .contacts = p.contacts, .contacts_won = p.contacts_won, .contacts_lost = p.contacts_lost, .echoes = p.echoes, .echoes_won = p.echoes_won, .caches = p.caches, .distance_m = p.distance_m },
        .contact_rank = progression.contactRank(p.fac(), p.contacts_won),
        .account = .{ .guest = providers.items.len == 0, .providers = providers.items, .email = email },
        .stance = p.stance,
        .bestiary = .{ .counts = p.bestiary },
        .notes = .{ .found = @intCast((try notes_db.foundSet(req, p.id)).count()), .total = game.notes.visibleTotal(p.fac()) },
        .titles_extra = try notes_db.titles(req, p.id),
    };
}

/// Reload the player and build `Me` (use after changes made by SQL).
pub fn meFresh(req: *Req, pid: i64) HandlerError!MeView {
    var p = (try model.load(req, pid)) orelse return req.fail(404, "not_found", "No such player.");
    return meView(req, &p);
}
