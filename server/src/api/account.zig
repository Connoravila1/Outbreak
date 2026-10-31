//! Account endpoints: health, catalog, factions, register (guest), callsign, recover, faction, me,
//! avatar. Sign-in, linking and deletion are in auth.zig.

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("../ctx.zig");
const model = @import("../model.zig");
const views = @import("../views.zig");
const name_rules = @import("../names.zig");
const warstate = @import("../warstate.zig");

const data = game.data;
const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;
const Stringify = std.json.Stringify;

// --- Tokens and codes ------------------------------------------------------------------------------

const code_alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

pub fn hashHex(secret: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(secret, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn newToken(req: *Req) [64]u8 {
    var raw: [32]u8 = undefined;
    req.ctx.randomBytes(&raw);
    return std.fmt.bytesToHex(raw, .lower);
}

/// "XXXX-XXXX-XXXX-XXXX" from an alphabet without 0/O/1/I.
fn newRecoveryCode(req: *Req) [19]u8 {
    var raw: [16]u8 = undefined;
    req.ctx.randomBytes(&raw);
    var out: [19]u8 = undefined;
    var n: usize = 0;
    for (raw, 0..) |b, i| {
        if (i > 0 and i % 4 == 0) {
            out[n] = '-';
            n += 1;
        }
        out[n] = code_alphabet[b & 31];
        n += 1;
    }
    return out;
}

/// Uppercase and drop separators, so "abcd efgh" and "ABCD-EFGH" are the same code.
fn normalizeCode(buf: []u8, text: []const u8) []const u8 {
    var n: usize = 0;
    for (text) |c| {
        if (c == '-' or c == ' ') continue;
        if (n == buf.len) return buf[0..0];
        buf[n] = std.ascii.toUpper(c);
        n += 1;
    }
    return buf[0..n];
}

// --- Callsigns --------------------------------------------------------------------------------------

/// The blocklist lives in names.zig.
pub fn callsignAllowed(name: []const u8) bool {
    return name_rules.allowed(name);
}

fn callsignValid(name: []const u8) bool {
    if (name.len < 3 or name.len > 16) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }
    return true;
}

// --- Handlers ---------------------------------------------------------------------------------------

pub fn health(req: *Req, jw: *Stringify) HandlerError!void {
    const cfg = req.ctx.auth.config;
    const auth = &req.ctx.auth;
    try jw.write(.{
        .ok = true,
        .version = ctx_mod.version,
        .players_online = req.ctx.live.online(req.now),
        .providers = .{
            .google = auth.configured(.google),
            .apple = auth.configured(.apple),
            .dev = req.ctx.opts.dev,
            .google_web_client_id = cfg.googleWebClientId(),
            .apple_web_service_id = cfg.appleWebServiceId(),
        },
    });
}

/// Check a callsign and return its lowercase form (for the unique index). Fails the request when
/// it is malformed, not allowed or taken.
fn vetCallsign(req: *Req, name: []const u8) HandlerError![]const u8 {
    if (!callsignValid(name)) return req.fail(400, "callsign_invalid", "Callsigns are 3 to 16 characters: letters, digits, _ and -.");
    if (!callsignAllowed(name)) return req.fail(400, "callsign_invalid", name_rules.rejection);
    const lc = try std.ascii.allocLowerString(req.arena, name);
    if ((try req.ctx.db.scalar("SELECT id FROM players WHERE callsign_lc = ?", .{lc})) != null) {
        return req.fail(409, "callsign_taken", "That callsign is taken.");
    }
    return lc;
}

pub const NewPlayer = struct { id: i64, token: [64]u8, recovery_code: [19]u8 };

/// Insert a player with a fresh session token. Without a callsign the row holds an empty
/// callsign and a unique placeholder (`#` is not a legal callsign character).
pub fn createPlayer(req: *Req, callsign: ?[]const u8) HandlerError!NewPlayer {
    const db = &req.ctx.db;
    const token = newToken(req);
    const code = newRecoveryCode(req);
    var norm_buf: [32]u8 = undefined;
    const token_hash = hashHex(&token);
    const code_hash = hashHex(normalizeCode(&norm_buf, &code));
    var name: []const u8 = "";
    var lc: []const u8 = try std.fmt.allocPrint(req.arena, "#{s}", .{@as([]const u8, &token_hash)});
    if (callsign) |c| {
        lc = try vetCallsign(req, c);
        name = c;
    }
    try db.run(
        "INSERT INTO players(callsign, callsign_lc, token_hash, recovery_hash, created_at, last_seen, abilities) VALUES(?,?,?,?,?,?,'')",
        .{ name, lc, @as([]const u8, &token_hash), @as([]const u8, &code_hash), req.now, req.now },
    );
    return .{ .id = db.lastInsertId(), .token = token, .recovery_code = code };
}

/// Make a new session token for a player; the old device's token stops working.
pub fn rotateToken(req: *Req, pid: i64) HandlerError![64]u8 {
    const token = newToken(req);
    try req.ctx.db.run("UPDATE players SET token_hash = ? WHERE id = ?", .{ @as([]const u8, &hashHex(&token)), pid });
    return token;
}

/// Create a guest. The callsign is optional here; it can be chosen later with /api/callsign.
pub fn register(req: *Req, jw: *Stringify) HandlerError!void {
    const Body = struct { callsign: ?[]const u8 = null };
    const body = if (req.body.len == 0) Body{} else try req.json(Body);
    var name: ?[]const u8 = null;
    if (body.callsign) |c| {
        const t = std.mem.trim(u8, c, " ");
        if (t.len > 0) name = t;
    }
    try req.begin();
    const np = try createPlayer(req, name);
    const me = try views.meFresh(req, np.id);
    try jw.write(.{ .token = @as([]const u8, &np.token), .recovery_code = @as([]const u8, &np.recovery_code), .me = me });
}

pub fn setCallsign(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { callsign: []const u8 });
    const name = std.mem.trim(u8, body.callsign, " ");
    const db = &req.ctx.db;
    // A callsign is permanent, unless a moderator reset it (`admin rename`).
    if ((try db.scalar("SELECT id FROM players WHERE id = ? AND callsign <> '' AND must_rename = 0", .{req.pid})) != null) {
        return req.fail(409, "callsign_set", "Your callsign is permanent.");
    }
    const lc = try vetCallsign(req, name);
    try db.run("UPDATE players SET callsign = ?, callsign_lc = ?, must_rename = 0 WHERE id = ?", .{ name, lc, req.pid });
    try jw.write(.{ .me = try views.meFresh(req, req.pid) });
}

pub fn recover(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { recovery_code: []const u8 });
    var norm_buf: [32]u8 = undefined;
    const norm = normalizeCode(&norm_buf, body.recovery_code);
    if (norm.len != 16) return req.fail(404, "not_found", "No account matches that recovery code.");
    const db = &req.ctx.db;
    const pid = (try db.scalar("SELECT id FROM players WHERE recovery_hash = ?", .{@as([]const u8, &hashHex(norm))})) orelse
        return req.fail(404, "not_found", "No account matches that recovery code.");
    // The old device's token stops working.
    const token = try rotateToken(req, pid);
    try jw.write(.{ .token = @as([]const u8, &token), .me = try views.meFresh(req, pid) });
}

pub fn getMe(req: *Req, jw: *Stringify) HandlerError!void {
    try jw.write(try views.meFresh(req, req.pid));
}

pub fn chooseFaction(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { faction: []const u8 });
    const f = std.meta.stringToEnum(data.Faction, body.faction) orelse
        return req.fail(400, "bad_request", "Faction must be \"human\" or \"zombie\".");
    var p = (try model.load(req, req.pid)).?;
    if (p.faction != null) return req.fail(409, "already_chosen", "Your faction is permanent.");
    p.faction = f;
    try req.ctx.db.run("UPDATE players SET faction = ? WHERE id = ?", .{ f, p.id });

    // Starter kit: bat, hoodie, flashlight (equipped) and three small heals.
    for ([_][]const u8{ "baseball_bat", "hoodie", "flashlight" }) |id| {
        _ = try model.insertItem(req, p.id, .{ .base = data.findBase(id).? }, true);
    }
    try model.addConsumable(req, p.id, .heal_s, 3);
    model.fillAbilities(&p);
    p.setHp(0, req.now);
    try model.save(req, &p);

    // Reload for the real max HP, then start at full health.
    var fresh = (try model.load(req, p.id)).?;
    fresh.setHp(fresh.maxHp(req.now), req.now);
    try model.save(req, &fresh);
    try model.refreshSnapshot(req, &fresh);
    warstate.invalidateShares(req.ctx);
    try jw.write(.{ .me = try views.meView(req, &fresh) });
}

/// Avatar fields (all small integers) and their exclusive upper bounds; keep in step with client/src/avatar/spec.ts.
const avatar_limits = [_]struct { key: []const u8, count: i64 }{
    .{ .key = "body", .count = 3 },  .{ .key = "skin", .count = 8 }, .{ .key = "face", .count = 6 },
    .{ .key = "hair", .count = 10 }, .{ .key = "hcol", .count = 8 }, .{ .key = "facial", .count = 4 },
    .{ .key = "scar", .count = 4 },
};

/// Known keys only, each an in-range integer.
fn avatarValid(obj: std.json.ObjectMap) bool {
    var it = obj.iterator();
    while (it.next()) |e| {
        const limit = for (avatar_limits) |l| {
            if (std.mem.eql(u8, l.key, e.key_ptr.*)) break l.count;
        } else return false;
        if (e.value_ptr.* != .integer) return false;
        if (e.value_ptr.integer < 0 or e.value_ptr.integer >= limit) return false;
    }
    return true;
}

pub fn setAvatar(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { avatar: std.json.Value });
    if (body.avatar != .object) return req.fail(400, "bad_request", "The avatar must be an object.");
    if (!avatarValid(body.avatar.object)) return req.fail(400, "bad_request", "The avatar has unknown fields or values out of range.");
    const text = try Stringify.valueAlloc(req.arena, body.avatar, .{});
    if (text.len > 300) return req.fail(400, "bad_request", "The avatar is too large.");
    var p = (try model.load(req, req.pid)).?;
    p.avatar = text;
    try model.save(req, &p);
    try jw.write(.{ .me = try views.meView(req, &p) });
}

pub fn factions(req: *Req, jw: *Stringify) HandlerError!void {
    const sh = try warstate.shares(req);
    const under = sh.underdog();
    try jw.write(.{
        .human = .{ .share = sh.share(.human), .players = sh.human },
        .zombie = .{ .share = sh.share(.zombie), .players = sh.zombie },
        .underdog = under,
        .underdog_bonus = if (under) |f| sh.bonusFor(f) else 0,
    });
}

// --- Catalog ----------------------------------------------------------------------------------------

const PairView = struct { human: []const u8, zombie: []const u8 };

fn pairView(p: data.Pair) PairView {
    return .{ .human = p.human, .zombie = p.zombie };
}

pub const catalog_version = 2;

const StanceRow = struct { id: data.Stance, names: PairView, text: []const u8 };
const stance_rows = [_]StanceRow{
    .{ .id = .aggressive, .names = .{ .human = "Aggressive", .zombie = "frenzy" }, .text = "+20% Attack, -20% Defense." },
    .{ .id = .careful, .names = .{ .human = "Careful", .zombie = "stalk" }, .text = "+25% Defense, +3% dodge, -8% Attack." },
    .{ .id = .evasive, .names = .{ .human = "Evasive", .zombie = "slink" }, .text = "+20% Speed, +5% dodge, -10% HP for the fight." },
};

pub fn catalog(req: *Req, jw: *Stringify) HandlerError!void {
    _ = req;
    try jw.beginObject();
    try jw.objectField("version");
    try jw.write(catalog_version);

    try jw.objectField("items");
    try jw.beginArray();
    for (data.bases) |b| {
        try jw.write(.{ .id = b.id, .slot = b.slot, .req = b.req, .names = pairView(b.name), .flavour = pairView(b.flavour), .stats = b.stats });
    }
    try jw.endArray();

    try jw.objectField("uniques");
    try jw.beginArray();
    for (data.uniques) |u| {
        var perk_ids: [2][]const u8 = undefined;
        for (u.perks, 0..) |pk, i| perk_ids[i] = @tagName(pk);
        try jw.write(.{
            .id = u.id,
            .base = u.base,
            .names = pairView(u.name),
            .lore = u.lore.human,
            .lore_zombie = u.lore.zombie,
            .perks = perk_ids,
        });
    }
    try jw.endArray();

    try jw.objectField("rarities");
    try jw.beginArray();
    for (data.rarities) |r| {
        try jw.write(.{ .id = r.id, .name = r.name, .mult = r.mult, .perks = r.perks, .weight = r.weight, .salvage = r.salvage, .upgrade_cost = r.rarity_cost });
    }
    try jw.endArray();

    try jw.objectField("perks");
    try jw.beginArray();
    for (data.perks) |p| try jw.write(.{ .id = p.id, .name = p.name, .text = p.text });
    try jw.endArray();

    try jw.objectField("consumables");
    try jw.beginArray();
    for (data.consumables) |c| try jw.write(.{ .id = c.id, .names = pairView(c.name), .text = c.text, .flavour = pairView(c.flavour), .price = c.price });
    try jw.endArray();

    try jw.objectField("abilities");
    try jw.beginArray();
    for (data.abilities) |a| {
        const mirror = data.ability(a.mirror);
        const names: PairView = if (a.faction == .human)
            .{ .human = a.name, .zombie = mirror.name }
        else
            .{ .human = mirror.name, .zombie = a.name };
        try jw.write(.{ .id = a.id, .level = a.level, .faction = a.faction, .names = names, .text = a.text });
    }
    try jw.endArray();

    try jw.objectField("enemies");
    try jw.beginArray();
    for (data.archetypes) |a| {
        try jw.write(.{
            .id = a.id,
            .names = pairView(a.name),
            .text = a.flavour.human,
            .text_zombie = a.flavour.zombie,
            .note = a.note,
            .counter = a.counter,
            .punished = a.punished,
            .hint = a.hint.human,
            .hint_zombie = a.hint.zombie,
        });
    }
    try jw.endArray();

    try jw.objectField("stances");
    try jw.beginArray();
    for (stance_rows) |r| {
        const e = game.stance.effect(r.id);
        try jw.write(.{ .id = r.id, .names = r.names, .text = r.text, .atk = e.atk, .def = e.def, .spd = e.spd, .hp = e.hp, .dodge = e.dodge });
    }
    try jw.endArray();

    try jw.objectField("places");
    try jw.beginArray();
    for (data.place_kinds) |k| try jw.write(.{ .id = k.id, .names = pairView(k.name), .text = k.text.human, .text_zombie = k.text.zombie });
    try jw.endArray();

    try jw.objectField("levels");
    try jw.beginObject();
    try jw.objectField("xp_to_next");
    try jw.beginArray();
    var l: u32 = 1;
    while (l <= data.max_level) : (l += 1) try jw.write(game.progression.xpToNext(l));
    try jw.endArray();
    try jw.objectField("titles");
    try jw.write(.{ .human = data.titles.human, .zombie = data.titles.zombie });
    try jw.objectField("unlocks");
    try jw.write(data.unlocks);
    try jw.endObject();

    try jw.objectField("store");
    try jw.write(data.store);
    try jw.endObject();
}

test "recovery codes are normalized" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("ABCD2345", normalizeCode(&buf, "abcd-2345"));
    try std.testing.expectEqualStrings("ABCD2345", normalizeCode(&buf, " ab cd 23-45"));
}

test "callsign filter catches obvious evasions and spares ordinary names" {
    try std.testing.expect(!callsignAllowed("Sh1t_head"));
    try std.testing.expect(!callsignAllowed("xX-FUCK-Xx"));
    try std.testing.expect(callsignAllowed("NightOwl"));
    try std.testing.expect(callsignAllowed("Ranger_77"));
    try std.testing.expect(callsignValid("abc") and !callsignValid("ab") and !callsignValid("has space") and !callsignValid("a" ** 17));
}
