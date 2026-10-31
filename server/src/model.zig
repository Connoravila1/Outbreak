//! A player as the server holds it for one request: loaded from SQLite, changed in memory and by
//! targeted SQL, saved back. Also HP rules (lazy regeneration, Downed), stat totals, items and
//! consumables.

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("ctx.zig");
const snapshot = @import("snapshot.zig");
const achievements = @import("achievements.zig");

const data = game.data;
const stats = game.stats;
const progression = game.progression;
const Req = ctx_mod.Req;
const Allocator = std.mem.Allocator;
const HandlerError = ctx_mod.HandlerError;

pub const consumable_count = data.consumables.len;

pub const Owned = struct {
    id: i64,
    uid: []const u8,
    item: stats.Item,
    equipped: bool,
};

/// Expiry times (ms) of timed buffs; zero or past means off.
pub const Buffs = struct {
    atk: i64 = 0,
    def: i64 = 0,
    spd: i64 = 0,
    xp: i64 = 0,
    loot: i64 = 0,
    boost: i64 = 0,

    /// Wire names, in field order; stored in the buffs table and sent to the client.
    pub const names = [_][]const u8{ "buff_atk", "buff_def", "buff_spd", "buff_xp", "buff_loot", "xp_boost" };

    pub fn ptr(self: *Buffs, kind: []const u8) ?*i64 {
        const slots = [_]*i64{ &self.atk, &self.def, &self.spd, &self.xp, &self.loot, &self.boost };
        for (names, slots) |n, s| {
            if (std.mem.eql(u8, n, kind)) return s;
        }
        return null;
    }

    pub fn on(until: i64, now: i64) bool {
        return until > now;
    }
};

pub const Player = struct {
    id: i64,
    callsign: []const u8,
    faction: ?data.Faction,
    level: u8,
    xp: u32,
    /// Effective HP at load time (regeneration applied). 0 while Downed.
    hp: i32,
    hp_at: i64,
    hp_dirty: bool = false,
    downed_until: ?i64,
    salvage: u32,
    expansions: u32,
    avatar: ?[]const u8,
    abilities: std.EnumSet(data.Ability),
    last_seen: i64,
    last_pvp_at: i64,
    streak: u32,
    last_claim_day: i64,
    mday: i64,
    mlevel: u8,
    mweek: i64,
    wlevel: u8,
    walk_day: i64,
    walk_xp_today: u32,
    wins: u32,
    losses: u32,
    contacts: u32,
    echoes: u32,
    /// Real-world Contact fights won and lost (Echoes and Rogues count separately).
    contacts_won: u32 = 0,
    contacts_lost: u32 = 0,
    echoes_won: u32 = 0,
    caches: u32,
    distance_m: u64,
    clan_id: ?i64,
    clan_role: ?[]const u8,
    /// The saved default stance (Contact uses it; PvE asks per fight).
    stance: data.Stance = .careful,
    /// Fights per enemy archetype, in `data.Archetype` order.
    bestiary: [data.archetypes.len]u32 = [_]u32{0} ** data.archetypes.len,
    /// Equipped cosmetics (cosmetics.zig ids); empty for none. Changed only through the equip endpoint.
    callsign_color: []const u8 = "",
    avatar_frame: []const u8 = "",

    items: []Owned = &.{},
    consumables: [consumable_count]u32 = [_]u32{0} ** consumable_count,
    buffs: Buffs = .{},

    pub fn fac(self: *const Player) data.Faction {
        return self.faction orelse .human;
    }

    pub fn equippedItems(self: *const Player, buf: *[3]stats.Item) []const stats.Item {
        var n: usize = 0;
        for (self.items) |o| {
            if (o.equipped and n < 3) {
                buf[n] = o.item;
                n += 1;
            }
        }
        return buf[0..n];
    }

    pub fn computed(self: *const Player, now: i64) stats.Computed {
        var buf: [3]stats.Item = undefined;
        return stats.playerStats(self.level, self.fac(), self.equippedItems(&buf), .{
            .atk = Buffs.on(self.buffs.atk, now),
            .def = Buffs.on(self.buffs.def, now),
            .spd = Buffs.on(self.buffs.spd, now),
        });
    }

    pub fn maxHp(self: *const Player, now: i64) i32 {
        return self.computed(now).stats.hp;
    }

    pub fn downed(self: *const Player, now: i64) bool {
        return if (self.downed_until) |d| d > now else false;
    }

    pub fn inventoryCap(self: *const Player) u32 {
        return progression.inventoryCap(self.level, self.expansions);
    }

    pub fn title(self: *const Player) []const u8 {
        return progression.title(self.fac(), self.level);
    }

    /// The build that fights for this player right now (equipment and equipped abilities).
    pub fn build(self: *const Player) snapshot.Build {
        var b = snapshot.Build{ .faction = self.fac(), .level = self.level, .abilities = self.abilities };
        for (self.items) |o| {
            if (o.equipped) b.items[@intFromEnum(o.item.slot())] = o.item;
        }
        return b;
    }

    /// Change HP now: records the time so later regeneration counts from here.
    pub fn setHp(self: *Player, hp: i32, now: i64) void {
        self.hp = hp;
        self.hp_at = now;
        self.hp_dirty = true;
    }

    /// Start the Downed countdown.
    pub fn down(self: *Player, now: i64) void {
        self.downed_until = now + stats.downedMs(self.level);
        self.setHp(0, now);
    }

    pub fn find(self: *const Player, uid: []const u8) ?*const Owned {
        for (self.items) |*o| {
            if (std.mem.eql(u8, o.uid, uid)) return o;
        }
        return null;
    }

    pub fn consumableCount(self: *const Player, c: data.Consumable) u32 {
        return self.consumables[@intFromEnum(c)];
    }
};

pub const select_player =
    \\SELECT id, callsign, faction, level, xp, hp, hp_at, downed_until, salvage, expansions, avatar,
    \\  abilities, last_seen, last_pvp_at, streak, last_claim_day, mday, mlevel, mweek, wlevel,
    \\  walk_day, walk_xp_today, wins, losses, contacts, echoes, caches, distance_m, clan_id, clan_role,
    \\  stance, bestiary, contacts_won, contacts_lost, echoes_won,
    \\  callsign_color, avatar_frame
    \\FROM players
;

/// Load a player with items, consumables and buffs. Applies the end of Downed (revive at 30%) and
/// lazy regeneration to `hp`.
pub fn load(req: *Req, id: i64) HandlerError!?Player {
    const ctx = req.ctx;
    const a = req.arena;
    var st = try ctx.db.query(select_player ++ " WHERE id = ?", .{id});
    defer st.finalize();
    if (!try st.step()) return null;
    var p = Player{
        .id = st.int(0),
        .callsign = try st.dupe(a, 1),
        .faction = if (st.optInt(2)) |f| @enumFromInt(f) else null,
        .level = @intCast(st.int(3)),
        .xp = @intCast(st.int(4)),
        .hp = @intCast(st.int(5)),
        .hp_at = st.int(6),
        .downed_until = st.optInt(7),
        .salvage = @intCast(st.int(8)),
        .expansions = @intCast(st.int(9)),
        .avatar = if (st.optText(10)) |t| try a.dupe(u8, t) else null,
        .abilities = parseAbilities(st.text(11)),
        .last_seen = st.int(12),
        .last_pvp_at = st.int(13),
        .streak = @intCast(st.int(14)),
        .last_claim_day = st.int(15),
        .mday = st.int(16),
        .mlevel = @intCast(st.int(17)),
        .mweek = st.int(18),
        .wlevel = @intCast(st.int(19)),
        .walk_day = st.int(20),
        .walk_xp_today = @intCast(st.int(21)),
        .wins = @intCast(st.int(22)),
        .losses = @intCast(st.int(23)),
        .contacts = @intCast(st.int(24)),
        .echoes = @intCast(st.int(25)),
        .caches = @intCast(st.int(26)),
        .distance_m = @intCast(st.int(27)),
        .clan_id = st.optInt(28),
        .clan_role = if (st.optText(29)) |t| try a.dupe(u8, t) else null,
        .stance = std.enums.fromInt(data.Stance, st.int(30)) orelse .careful,
        .bestiary = parseBestiary(st.text(31)),
        .contacts_won = @intCast(st.int(32)),
        .contacts_lost = @intCast(st.int(33)),
        .echoes_won = @intCast(st.int(34)),
        .callsign_color = try st.dupe(a, 35),
        .avatar_frame = try st.dupe(a, 36),
    };
    try loadCollections(req, &p);
    const now = req.now;
    const max = p.maxHp(now);
    if (p.downed_until) |d| {
        if (d <= now) {
            // Back on their feet at 30%, regenerating from the moment the countdown ended.
            p.downed_until = null;
            p.hp = @max(1, @as(i32, @intFromFloat(@ceil(stats.revive_fraction * @as(f64, @floatFromInt(max))))));
            p.hp_at = d;
            p.hp_dirty = true;
        } else p.hp = 0;
    }
    if (p.downed_until == null) {
        const minutes = @as(f64, @floatFromInt(@max(0, now - p.hp_at))) / 60000.0;
        p.hp = @min(max, p.hp + stats.regenHp(p.fac(), max, minutes));
    }
    if (p.hp_dirty) try save(req, &p);
    return p;
}

const bestiary_text_max = data.archetypes.len * 11;

/// "3,0,12,..." in archetype order.
pub fn bestiaryText(counts: *const [data.archetypes.len]u32, buf: *[bestiary_text_max]u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    for (counts, 0..) |n, i| {
        if (i > 0) w.writeByte(',') catch unreachable;
        w.print("{d}", .{n}) catch unreachable;
    }
    return w.buffered();
}

pub fn parseBestiary(text: []const u8) [data.archetypes.len]u32 {
    var out = [_]u32{0} ** data.archetypes.len;
    var it = std.mem.splitScalar(u8, text, ',');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= out.len) break;
        out[i] = std.fmt.parseInt(u32, part, 10) catch 0;
    }
    return out;
}

pub fn parseAbilities(text: []const u8) std.EnumSet(data.Ability) {
    var set: std.EnumSet(data.Ability) = .initEmpty();
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |n| {
        if (std.meta.stringToEnum(data.Ability, n)) |a| set.insert(a);
    }
    return set;
}

fn loadCollections(req: *Req, p: *Player) HandlerError!void {
    const db = &req.ctx.db;
    const a = req.arena;
    var items: std.ArrayList(Owned) = .empty;
    {
        var st = try db.query("SELECT id, uid, base, rarity, upgrade, uniq, perk_count, perk0, perk1, equipped FROM items WHERE player_id = ? ORDER BY id", .{p.id});
        defer st.finalize();
        while (try st.step()) {
            try items.append(a, .{
                .id = st.int(0),
                .uid = try st.dupe(a, 1),
                .item = .{
                    .base = @intCast(st.int(2)),
                    .rarity = @enumFromInt(st.int(3)),
                    .upgrade = @intCast(st.int(4)),
                    .unique = if (st.int(5) >= 0) @intCast(st.int(5)) else null,
                    .perk_count = @intCast(st.int(6)),
                    .perk_ids = .{ @enumFromInt(st.int(7)), @enumFromInt(st.int(8)) },
                },
                .equipped = st.int(9) != 0,
            });
        }
    }
    p.items = items.items;
    {
        var st = try db.query("SELECT kind, n FROM consumables WHERE player_id = ?", .{p.id});
        defer st.finalize();
        while (try st.step()) {
            const k: usize = @intCast(st.int(0));
            if (k < consumable_count) p.consumables[k] = @intCast(st.int(1));
        }
    }
    {
        var st = try db.query("SELECT kind, until FROM buffs WHERE player_id = ?", .{p.id});
        defer st.finalize();
        while (try st.step()) {
            if (p.buffs.ptr(st.text(0))) |slot| slot.* = st.int(1);
        }
    }
}

/// Write every scalar column. HP is written only when it was changed on purpose (`setHp`), so
/// regeneration is never rounded away by unrelated saves.
pub fn save(req: *Req, p: *Player) HandlerError!void {
    const db = &req.ctx.db;
    var ab_buf: [256]u8 = undefined;
    var bestiary_buf: [bestiary_text_max]u8 = undefined;
    var w = std.Io.Writer.fixed(&ab_buf);
    const b = snapshot.Build{ .faction = p.fac(), .level = p.level, .abilities = p.abilities };
    try b.encodeAbilities(&w);
    try db.run(
        \\UPDATE players SET level = ?, xp = ?, salvage = ?, expansions = ?, avatar = ?, abilities = ?,
        \\  last_pvp_at = ?, streak = ?, last_claim_day = ?, mday = ?, mlevel = ?, mweek = ?, wlevel = ?,
        \\  walk_day = ?, walk_xp_today = ?, wins = ?, losses = ?, contacts = ?, echoes = ?, caches = ?,
        \\  distance_m = ?, clan_id = ?, clan_role = ?, downed_until = ?, stance = ?, bestiary = ?,
        \\  contacts_won = ?, contacts_lost = ?, echoes_won = ?
        \\WHERE id = ?
    , .{
        p.level,                p.xp,                                     p.salvage,        p.expansions, p.avatar,    w.buffered(),
        p.last_pvp_at,          p.streak,                                 p.last_claim_day, p.mday,       p.mlevel,    p.mweek,
        p.wlevel,               p.walk_day,                               p.walk_xp_today,  p.wins,       p.losses,    p.contacts,
        p.echoes,               p.caches,                                 p.distance_m,     p.clan_id,    p.clan_role, p.downed_until,
        @intFromEnum(p.stance), bestiaryText(&p.bestiary, &bestiary_buf), p.contacts_won, p.contacts_lost, p.echoes_won,
        p.id,
    });
    if (p.hp_dirty) {
        try db.run("UPDATE players SET hp = ?, hp_at = ? WHERE id = ?", .{ p.hp, p.hp_at, p.id });
        p.hp_dirty = false;
    }
}

// --- Items, consumables, buffs ----------------------------------------------------------------------

/// A fresh item id for the player-visible `uid`.
pub fn newUid(req: *Req) [16]u8 {
    var raw: [8]u8 = undefined;
    req.ctx.io.random(&raw);
    var out: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x:0>16}", .{std.mem.readInt(u64, &raw, .little)}) catch unreachable;
    return out;
}

pub fn insertItem(req: *Req, pid: i64, item: stats.Item, equipped: bool) HandlerError![16]u8 {
    const uid = newUid(req);
    try req.ctx.db.run(
        "INSERT INTO items(uid, player_id, base, rarity, upgrade, uniq, perk_count, perk0, perk1, equipped) VALUES(?,?,?,?,?,?,?,?,?,?)",
        .{
            @as([]const u8, &uid),          pid,
            item.base,                      @intFromEnum(item.rarity),
            item.upgrade,                   if (item.unique) |u| @as(i32, u) else -1,
            item.perk_count,                @intFromEnum(item.perk_ids[0]),
            @intFromEnum(item.perk_ids[1]), @intFromBool(equipped),
        },
    );
    try achievements.discover(req, pid, item);
    return uid;
}

pub fn itemCount(req: *Req, pid: i64) HandlerError!u32 {
    return @intCast(try req.ctx.db.scalar("SELECT COUNT(*) FROM items WHERE player_id = ?", .{pid}) orelse 0);
}

pub fn addConsumable(req: *Req, pid: i64, c: data.Consumable, n: u32) HandlerError!void {
    if (n == 0) return;
    try req.ctx.db.run(
        "INSERT INTO consumables(player_id, kind, n) VALUES(?,?,?) ON CONFLICT(player_id, kind) DO UPDATE SET n = n + excluded.n",
        .{ pid, @intFromEnum(c), n },
    );
}

pub fn takeConsumable(req: *Req, pid: i64, c: data.Consumable) HandlerError!bool {
    try req.ctx.db.run("UPDATE consumables SET n = n - 1 WHERE player_id = ? AND kind = ? AND n > 0", .{ pid, @intFromEnum(c) });
    return req.ctx.db.changes() == 1;
}

pub fn setBuff(req: *Req, pid: i64, kind: []const u8, until: i64) HandlerError!void {
    try req.ctx.db.run(
        "INSERT INTO buffs(player_id, kind, until) VALUES(?,?,?) ON CONFLICT(player_id, kind) DO UPDATE SET until = excluded.until",
        .{ pid, kind, until },
    );
}

/// Make sure the abilities slots are filled: unlocked abilities fill free slots, newest first.
pub fn fillAbilities(p: *Player) void {
    var buf: [7]data.Ability = undefined;
    const unlocked = progression.unlockedAbilities(p.fac(), p.level, &buf);
    const slots = progression.abilitySlots(p.level);
    // Drop anything no longer valid (cannot happen today, cheap to be sure).
    var it = p.abilities;
    var iter = it.iterator();
    while (iter.next()) |a| {
        if (std.mem.indexOfScalar(data.Ability, unlocked, a) == null) p.abilities.remove(a);
    }
    var i = unlocked.len;
    while (i > 0 and p.abilities.count() < slots) {
        i -= 1;
        p.abilities.insert(unlocked[i]);
    }
}

/// Rewrite the stored snapshot (Echoes and garrisons fight from it) from the player's current build.
pub fn refreshSnapshot(req: *Req, p: *const Player) HandlerError!void {
    const f = p.faction orelse return;
    var b = p.build();
    b.faction = f;
    var items_buf: [512]u8 = undefined;
    var iw = std.Io.Writer.fixed(&items_buf);
    try b.encodeItems(&iw);
    var ab_buf: [256]u8 = undefined;
    var aw = std.Io.Writer.fixed(&ab_buf);
    try b.encodeAbilities(&aw);
    try req.ctx.db.run(
        "INSERT INTO snapshots(player_id, faction, level, items, abilities, updated_at) VALUES(?,?,?,?,?,?) " ++
            "ON CONFLICT(player_id) DO UPDATE SET faction = excluded.faction, level = excluded.level, items = excluded.items, abilities = excluded.abilities, updated_at = excluded.updated_at",
        .{ p.id, @intFromEnum(f), p.level, iw.buffered(), aw.buffered(), req.now },
    );
}

pub fn pushEvent(req: *Req, pid: i64, kind: []const u8, text: []const u8, battle: ?[]const u8, rewards: ?[]const u8, delivered: bool) HandlerError!void {
    try req.ctx.db.run(
        "INSERT INTO events(player_id, at, type, text, battle, rewards, delivered, notified) VALUES(?,?,?,?,?,?,?,?)",
        .{ pid, req.now, kind, text, battle, rewards, @intFromBool(delivered), @intFromBool(delivered) },
    );
}
