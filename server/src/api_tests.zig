//! API tests: everything goes through `api.handle` against an in-memory database, with a pinned
//! clock. Walks the main flow: register, faction, location, engage, gear, missions, store, clans,
//! contact, echoes, strongholds and raids.

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("ctx.zig");
const api = @import("api.zig");
const tick = @import("tick.zig");
const live = @import("live.zig");
const model = @import("model.zig");

const testing = std.testing;
const Value = std.json.Value;
const geo = game.geo;
const spawns = game.spawns;

/// A Wednesday, noon UTC.
const wednesday: i64 = 1_793_188_800_000;
/// A Saturday, noon UTC.
const saturday: i64 = 1_793_448_000_000;
const base_lat = 40.7484;
const base_lon = -73.9857;

const Res = struct {
    status: u16,
    raw: api.Response,
    parsed: ?std.json.Parsed(Value),

    fn deinit(self: *Res) void {
        if (self.parsed) |*p| p.deinit();
        self.raw.deinit(testing.allocator);
    }

    fn root(self: *const Res) Value {
        return self.parsed.?.value;
    }

    /// Walk a dotted path ("me.items.0.uid").
    fn at(self: *const Res, path: []const u8) !Value {
        return walk(self.root(), path);
    }

    fn int(self: *const Res, path: []const u8) !i64 {
        return switch (try self.at(path)) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => error.NotANumber,
        };
    }

    fn str(self: *const Res, path: []const u8) ![]const u8 {
        return switch (try self.at(path)) {
            .string => |s| s,
            else => error.NotAString,
        };
    }

    fn len(self: *const Res, path: []const u8) !usize {
        return switch (try self.at(path)) {
            .array => |a| a.items.len,
            .object => |o| o.count(),
            else => error.NotAContainer,
        };
    }

    fn errorCode(self: *const Res) ![]const u8 {
        return self.str("error");
    }
};

fn walk(start: Value, path: []const u8) !Value {
    var v = start;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |part| {
        switch (v) {
            .object => |o| v = o.get(part) orelse return error.MissingField,
            .array => |a| v = a.items[try std.fmt.parseInt(usize, part, 10)],
            else => return error.MissingField,
        }
    }
    return v;
}

const Harness = struct {
    ctx: ctx_mod.Ctx,

    fn init(h: *Harness, opts: ctx_mod.Options) !void {
        h.ctx = try ctx_mod.Ctx.init(testing.allocator, testing.io, ":memory:", opts);
        h.ctx.clock_ms = wednesday;
    }

    fn deinit(h: *Harness) void {
        h.ctx.deinit();
    }

    fn call(h: *Harness, method: []const u8, path: []const u8, token: ?[]const u8, body: []const u8) !Res {
        var q: []const u8 = "";
        var p = path;
        if (std.mem.indexOfScalar(u8, path, '?')) |i| {
            p = path[0..i];
            q = path[i + 1 ..];
        }
        const raw = api.handle(&h.ctx, method, p, q, token, body);
        const parsed: ?std.json.Parsed(Value) = if (raw.json.len > 0) try std.json.parseFromSlice(Value, testing.allocator, raw.json, .{}) else null;
        return .{ .status = raw.status, .raw = raw, .parsed = parsed };
    }

    fn get(h: *Harness, path: []const u8, token: ?[]const u8) !Res {
        return h.call("GET", path, token, "");
    }

    fn post(h: *Harness, path: []const u8, token: ?[]const u8, body: []const u8) !Res {
        return h.call("POST", path, token, body);
    }

    /// POST with a formatted body, expecting 200.
    fn ok(h: *Harness, path: []const u8, token: []const u8, comptime fmt: []const u8, args: anytype) !Res {
        const body = try std.fmt.allocPrint(testing.allocator, fmt, args);
        defer testing.allocator.free(body);
        const r = try h.post(path, token, body);
        if (r.status != 200) std.debug.print("{s}: {d} {s}\n", .{ path, r.status, r.raw.json });
        try testing.expectEqual(@as(u16, 200), r.status);
        return r;
    }

    /// POST with a formatted body; any status.
    fn postf(h: *Harness, path: []const u8, token: ?[]const u8, comptime fmt: []const u8, args: anytype) !Res {
        const body = try std.fmt.allocPrint(testing.allocator, fmt, args);
        defer testing.allocator.free(body);
        return h.post(path, token, body);
    }

    fn advance(h: *Harness, ms: i64) void {
        h.ctx.clock_ms = h.ctx.clock_ms.? + ms;
    }

    /// Register and choose a faction. The token is copied into `out`.
    fn player(h: *Harness, name: []const u8, faction: []const u8, out: *[64]u8) !void {
        const body = try std.fmt.allocPrint(testing.allocator, "{{\"callsign\":\"{s}\"}}", .{name});
        defer testing.allocator.free(body);
        var r = try h.post("/api/register", null, body);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 200), r.status);
        @memcpy(out, try r.str("token"));
        var f = try h.ok("/api/faction", out, "{{\"faction\":\"{s}\"}}", .{faction});
        f.deinit();
    }

    fn grantXp(h: *Harness, token: []const u8, xp: u64) !void {
        var r = try h.ok("/api/dev/grant", token, "{{\"xp\":{d}}}", .{xp});
        r.deinit();
    }

    fn reachLevel(h: *Harness, token: []const u8, level: u32) !void {
        var total: u64 = 0;
        for (1..level) |l| total += game.progression.xpToNext(@intCast(l));
        try h.grantXp(token, total);
    }

    fn location(h: *Harness, token: []const u8, lat: f64, lon: f64) !Res {
        return h.ok("/api/location", token, "{{\"lat\":{d},\"lon\":{d},\"acc\":5,\"sanctuary\":false}}", .{ lat, lon });
    }

    fn playerId(h: *Harness, name: []const u8) !i64 {
        return (try h.ctx.db.scalar("SELECT id FROM players WHERE callsign = ?", .{name})).?;
    }
};

/// A spot with an enemy in the clock's current window.
fn findEnemy(seed: u64, now: i64) spawns.Enemy {
    var cell = geo.encode(base_lat, base_lon, 7);
    const window = spawns.windowIndex(now, spawns.enemy_window_ms);
    var buf: [spawns.max_enemies_per_cell]spawns.Enemy = undefined;
    while (true) {
        const found = spawns.enemiesInCell(seed, cell, window, &buf);
        // Not an elite: new players cannot see those.
        for (found) |e| {
            if (e.visibleTo(1)) return e;
        }
        cell = geo.neighbors(cell)[2].?;
    }
}

test "register, callsign rules, faction choice, recovery" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();

    var bad = try h.post("/api/register", null, "{\"callsign\":\"ab\"}");
    defer bad.deinit();
    try testing.expectEqual(@as(u16, 400), bad.status);
    try testing.expectEqualStrings("callsign_invalid", try bad.errorCode());
    var rude = try h.post("/api/register", null, "{\"callsign\":\"Sh1t_lord\"}");
    defer rude.deinit();
    try testing.expectEqual(@as(u16, 400), rude.status);
    var junk = try h.post("/api/register", null, "not json");
    defer junk.deinit();
    try testing.expectEqual(@as(u16, 400), junk.status);

    var r = try h.post("/api/register", null, "{\"callsign\":\"NightOwl\"}");
    defer r.deinit();
    try testing.expectEqual(@as(u16, 200), r.status);
    const token = try r.str("token");
    try testing.expectEqual(@as(usize, 64), token.len);
    const code = try r.str("recovery_code");
    try testing.expectEqual(@as(usize, 19), code.len);
    try testing.expect(code[4] == '-' and code[9] == '-' and code[14] == '-');
    try testing.expect((try r.at("me.faction")) == .null);

    var dup = try h.post("/api/register", null, "{\"callsign\":\"nightowl\"}");
    defer dup.deinit();
    try testing.expectEqual(@as(u16, 409), dup.status);
    try testing.expectEqualStrings("callsign_taken", try dup.errorCode());

    // Needs a faction first.
    var nf = try h.post("/api/location", token, "{\"lat\":1,\"lon\":2}");
    defer nf.deinit();
    try testing.expectEqual(@as(u16, 409), nf.status);
    try testing.expectEqualStrings("no_faction", try nf.errorCode());
    var unauth = try h.get("/api/me", null);
    defer unauth.deinit();
    try testing.expectEqual(@as(u16, 401), unauth.status);

    var f = try h.ok("/api/faction", token, "{{\"faction\":\"human\"}}", .{});
    defer f.deinit();
    try testing.expectEqualStrings("human", try f.str("me.faction"));
    try testing.expectEqual(@as(usize, 3), try f.len("me.items"));
    try testing.expectEqual(@as(i64, 3), try f.int("me.consumables.heal_s"));
    try testing.expectEqual(@as(i64, try f.int("me.max_hp")), try f.int("me.hp"));
    try testing.expect((try f.at("me.equipped.weapon")) == .string);
    try testing.expectEqualStrings("baseball_bat", try f.str("me.items.0.base"));
    var again = try h.post("/api/faction", token, "{\"faction\":\"zombie\"}");
    defer again.deinit();
    try testing.expectEqual(@as(u16, 409), again.status);
    try testing.expectEqualStrings("already_chosen", try again.errorCode());

    // Recovery code in any case/spacing issues a new token and retires the old one.
    const lower = try std.ascii.allocLowerString(testing.allocator, code);
    defer testing.allocator.free(lower);
    const body = try std.fmt.allocPrint(testing.allocator, "{{\"recovery_code\":\"{s}\"}}", .{lower});
    defer testing.allocator.free(body);
    var rec = try h.post("/api/recover", null, body);
    defer rec.deinit();
    try testing.expectEqual(@as(u16, 200), rec.status);
    try testing.expect(!std.mem.eql(u8, token, try rec.str("token")));
    try testing.expectEqualStrings("NightOwl", try rec.str("me.callsign"));
    var old = try h.get("/api/me", token);
    defer old.deinit();
    try testing.expectEqual(@as(u16, 401), old.status);
    var nope = try h.post("/api/recover", null, "{\"recovery_code\":\"AAAA-AAAA-AAAA-AAAA\"}");
    defer nope.deinit();
    try testing.expectEqual(@as(u16, 404), nope.status);
}

test "public endpoints, error shapes and CORS-relevant statuses" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var health = try h.get("/api/health", null);
    defer health.deinit();
    try testing.expect((try health.at("ok")) == .bool);
    try testing.expectEqualStrings(ctx_mod.version, try health.str("version"));
    var cat = try h.get("/api/catalog", null);
    defer cat.deinit();
    try testing.expectEqual(@as(usize, 37), try cat.len("items"));
    try testing.expectEqual(@as(usize, 50), try cat.len("levels.xp_to_next"));
    try testing.expectEqual(@as(usize, 14), try cat.len("abilities"));
    try testing.expectEqual(@as(usize, 12), try cat.len("store"));
    try testing.expectEqualStrings("Baseball Bat", try cat.str("items.1.names.human"));
    var fac = try h.get("/api/factions", null);
    defer fac.deinit();
    try testing.expect((try fac.at("underdog")) == .null);

    var nf = try h.get("/api/nothing", null);
    defer nf.deinit();
    try testing.expectEqual(@as(u16, 404), nf.status);
    try testing.expectEqualStrings("not_found", try nf.errorCode());
    try testing.expect((try nf.at("message")) == .string);
    var wrong = try h.get("/api/register", null);
    defer wrong.deinit();
    try testing.expectEqual(@as(u16, 405), wrong.status);
    const opt = api.handle(&h.ctx, "OPTIONS", "/api/me", "", null, "");
    try testing.expectEqual(@as(u16, 204), opt.status);
    const big = try testing.allocator.alloc(u8, api.max_body_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, ' ');
    var huge = try h.post("/api/register", null, big);
    defer huge.deinit();
    try testing.expectEqual(@as(u16, 413), huge.status);
}

test "dev endpoints exist only with --dev" {
    var h: Harness = undefined;
    try h.init(.{ .dev = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Dev1", "zombie", &tok);
    var r = try h.post("/api/dev/heal", &tok, "{}");
    defer r.deinit();
    try testing.expectEqual(@as(u16, 404), r.status);
}

test "rate limit: a burst is allowed, then 429" {
    var h: Harness = undefined;
    try h.init(.{ .dev = false, .limits = true });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Spammer", "human", &tok);
    var limited = false;
    for (0..60) |_| {
        var r = try h.get("/api/me", &tok);
        defer r.deinit();
        if (r.status == 429) {
            limited = true;
            try testing.expectEqualStrings("rate_limited", try r.errorCode());
            break;
        }
    }
    try testing.expect(limited);
    h.advance(10_000);
    var r = try h.get("/api/me", &tok);
    defer r.deinit();
    try testing.expectEqual(@as(u16, 200), r.status);
}

test "location, engage an enemy, rewards and the defeated list" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Scout", "human", &tok);

    const en = findEnemy(h.ctx.seed, h.ctx.now());
    const id = en.id();
    // Engaging before the server has a position is refused.
    var early = try h.post("/api/engage", &tok, "{\"id\":\"e.dr5ru7k.1.0\"}");
    defer early.deinit();
    try testing.expectEqual(@as(u16, 409), early.status);

    var world = try h.location(&tok, en.lat, en.lon);
    defer world.deinit();
    try testing.expect(try world.len("enemies") >= 1);
    var found = false;
    for ((try world.at("enemies")).array.items) |e| {
        if (std.mem.eql(u8, e.object.get("id").?.string, id.str())) {
            found = true;
            try testing.expect(e.object.get("level").?.integer >= 1);
        }
    }
    try testing.expect(found);
    try testing.expectEqual(@as(usize, 0), try world.len("events"));

    var b = try h.ok("/api/engage", &tok, "{{\"id\":\"{s}\"}}", .{id.str()});
    defer b.deinit();
    try testing.expectEqualStrings("pve", try b.str("kind"));
    try testing.expectEqualStrings("Scout", try b.str("a.name"));
    try testing.expectEqualStrings("enemy", try b.str("b.kind"));
    try testing.expect(try b.len("turns") > 2);
    try testing.expect(try b.int("rewards.xp") > 0);
    const won = std.mem.eql(u8, try b.str("winner"), "a");
    // The log ends where the result says.
    const last = try b.at("turns");
    const final = last.array.items[last.array.items.len - 1].object;
    try testing.expectEqual(@as(i64, 0), if (won) final.get("hp_b").?.integer else final.get("hp_a").?.integer);
    try testing.expectEqual(try b.int("rewards.xp"), try b.int("me.xp"));
    if (won) {
        try testing.expectEqual(@as(i64, 1), try b.int("rewards.war_points"));
        const body = try std.fmt.allocPrint(testing.allocator, "{{\"id\":\"{s}\"}}", .{id.str()});
        defer testing.allocator.free(body);
        var dup = try h.post("/api/engage", &tok, body);
        defer dup.deinit();
        try testing.expectEqual(@as(u16, 409), dup.status);
        try testing.expectEqualStrings("already_defeated", try dup.errorCode());
        var w2 = try h.location(&tok, en.lat, en.lon);
        defer w2.deinit();
        for ((try w2.at("enemies")).array.items) |e| try testing.expect(!std.mem.eql(u8, e.object.get("id").?.string, id.str()));
        var war = try h.get("/api/war", &tok);
        defer war.deinit();
        try testing.expectEqual(@as(i64, 1), try war.int("my_points"));
        try testing.expectEqual(@as(i64, 1), try war.int("global.human"));
    } else {
        try testing.expect((try b.at("me.downed_until")) != .null);
        var dn = try h.post("/api/engage", &tok, "{\"id\":\"x\"}");
        defer dn.deinit();
        try testing.expectEqualStrings("downed", try dn.errorCode());
    }
    // Far away is too far.
    var far = try h.post("/api/engage", &tok, "{\"id\":\"e.dr5ru7k.1.0\"}");
    defer far.deinit();
    try testing.expect(far.status == 404 or far.status == 409);
}

/// The tutorial enemy in a /api/location answer, if there is one.
fn tutorialIn(world: *const Res) !?std.json.ObjectMap {
    for ((try world.at("enemies")).array.items) |e| {
        try testing.expect(e.object.get("tutorial") != null);
        if (e.object.get("tutorial").?.bool) return e.object;
    }
    return null;
}

test "First Blood: one gentle Shambler while a player has no wins, a guaranteed Uncommon, then gone" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Rookie", "human", &tok);
    const pid = try h.playerId("Rookie");

    var w = try h.location(&tok, base_lat, base_lon);
    defer w.deinit();
    const t = (try tutorialIn(&w)).?;
    try testing.expectEqualStrings("shambler", t.get("archetype").?.string);
    try testing.expectEqual(@as(i64, 1), t.get("level").?.integer);
    try testing.expect(!t.get("elite").?.bool);
    const tid = try std.fmt.allocPrint(testing.allocator, "t.{d}", .{pid});
    defer testing.allocator.free(tid);
    try testing.expectEqualStrings(tid, t.get("id").?.string);
    const d = geo.haversineM(base_lat, base_lon, t.get("lat").?.float, t.get("lon").?.float);
    try testing.expect(d >= 24 and d <= 36);
    // Exactly one, and world enemies are flagged false.
    var n: usize = 0;
    for ((try w.at("enemies")).array.items) |e| {
        if (e.object.get("tutorial").?.bool) n += 1;
    }
    try testing.expectEqual(@as(usize, 1), n);

    // It stays put while the player stays near, and follows once they are 150 m away from it.
    h.advance(5000);
    var w2 = try h.location(&tok, base_lat + 0.0001, base_lon);
    defer w2.deinit();
    const t2 = (try tutorialIn(&w2)).?;
    try testing.expectEqual(t.get("lat").?.float, t2.get("lat").?.float);
    var far_lat: f64 = base_lat;
    for (0..8) |_| { // about 100 m a step: out of range of the old anchor after 2
        h.advance(30_000);
        far_lat += 0.0009;
        var step = try h.location(&tok, far_lat, base_lon);
        step.deinit();
    }
    var w3 = try h.location(&tok, far_lat, base_lon);
    defer w3.deinit();
    const t3 = (try tutorialIn(&w3)).?;
    const d3 = geo.haversineM(far_lat, base_lon, t3.get("lat").?.float, t3.get("lon").?.float);
    try testing.expect(d3 >= 24 and d3 <= 36);

    // Someone else's id does not validate.
    var bad = try h.post("/api/engage", &tok, "{\"id\":\"t.999\"}");
    defer bad.deinit();
    try testing.expectEqual(@as(u16, 404), bad.status);

    var b = try h.ok("/api/engage", &tok, "{{\"id\":\"{s}\"}}", .{tid});
    defer b.deinit();
    try testing.expectEqualStrings("a", try b.str("winner"));
    try testing.expect(try b.int("rewards.xp") >= 26);
    var uncommon_plus = false;
    for ((try b.at("rewards.items")).array.items) |it| {
        if (!std.mem.eql(u8, it.object.get("rarity").?.string, "common")) uncommon_plus = true;
    }
    try testing.expect(uncommon_plus);
    try testing.expectEqual(@as(i64, 1), try b.int("me.record.wins"));

    // Gone for good.
    var again = try h.postf("/api/engage", &tok, "{{\"id\":\"{s}\"}}", .{tid});
    defer again.deinit();
    try testing.expectEqual(@as(u16, 404), again.status);
    h.advance(5000);
    var w4 = try h.location(&tok, far_lat, base_lon);
    defer w4.deinit();
    try testing.expect((try tutorialIn(&w4)) == null);
}

test "new players see no elites and nothing above their level" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Newbie", "zombie", &tok);
    var lat: f64 = base_lat;
    for (0..25) |_| {
        var w = try h.location(&tok, lat, base_lon);
        defer w.deinit();
        for ((try w.at("enemies")).array.items) |e| {
            try testing.expect(!e.object.get("elite").?.bool);
            try testing.expect(e.object.get("level").?.integer <= try w.int("me.level"));
        }
        lat += 0.002;
        h.advance(60_000);
    }
}

test "Me has a record of wins, losses, contacts, echoes, caches and distance" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Recorder", "human", &tok);
    const pid = try h.playerId("Recorder");
    try h.ctx.db.run("UPDATE players SET wins = 4, losses = 2, contacts = 1, echoes = 3, caches = 5, distance_m = 1234 WHERE id = ?", .{pid});
    var me = try h.get("/api/me", &tok);
    defer me.deinit();
    try testing.expectEqual(@as(i64, 4), try me.int("record.wins"));
    try testing.expectEqual(@as(i64, 2), try me.int("record.losses"));
    try testing.expectEqual(@as(i64, 1), try me.int("record.contacts"));
    try testing.expectEqual(@as(i64, 3), try me.int("record.echoes"));
    try testing.expectEqual(@as(i64, 5), try me.int("record.caches"));
    try testing.expectEqual(@as(i64, 1234), try me.int("record.distance_m"));
}

test "healing pace: a level-up heals fully; Downed lasts 5 minutes below level 5, 10 from 5" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Healer", "human", &tok);
    const pid = try h.playerId("Healer");
    try h.ctx.db.run("UPDATE players SET hp = 5, hp_at = ? WHERE id = ?", .{ h.ctx.now(), pid });
    try h.grantXp(&tok, game.progression.xpToNext(1));
    var me = try h.get("/api/me", &tok);
    defer me.deinit();
    try testing.expectEqual(@as(i64, 2), try me.int("level"));
    try testing.expectEqual(try me.int("max_hp"), try me.int("hp"));

    var p: model.Player = undefined;
    p.level = 4;
    p.down(h.ctx.now());
    try testing.expectEqual(h.ctx.now() + 5 * 60 * 1000, p.downed_until.?);
    p.level = 5;
    p.down(h.ctx.now());
    try testing.expectEqual(h.ctx.now() + 10 * 60 * 1000, p.downed_until.?);
}

test "sanctuary hides content; a teleport is rejected; walking pays XP" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Walker", "zombie", &tok);
    const pid = try h.playerId("Walker");
    const en = findEnemy(h.ctx.seed, h.ctx.now());

    var sanct = try h.ok("/api/location", &tok, "{{\"lat\":{d},\"lon\":{d},\"acc\":5,\"sanctuary\":true}}", .{ en.lat, en.lon });
    defer sanct.deinit();
    try testing.expectEqual(@as(usize, 0), try sanct.len("enemies"));
    try testing.expectEqual(@as(usize, 0), try sanct.len("caches"));
    try testing.expectEqual(@as(usize, 0), try sanct.len("echoes"));
    const id = en.id();
    var eng = try h.postf("/api/engage", &tok, "{{\"id\":\"{s}\"}}", .{id.str()});
    defer eng.deinit();
    try testing.expectEqualStrings("sanctuary", try eng.errorCode());

    // 3 km in 5 s is not walking: the old position stays.
    h.advance(5000);
    var jump = try h.location(&tok, en.lat + 0.03, en.lon);
    defer jump.deinit();
    const pos = h.ctx.live.position(pid, h.ctx.now()).?;
    try testing.expectApproxEqAbs(en.lat, pos.lat, 1e-9);

    // Walk 4 m/s north for two minutes: about 480 m, 24 XP.
    var lat = en.lat;
    var xp: i64 = 0;
    for (0..24) |_| {
        h.advance(5000);
        lat += 20.0 / 111_320.0;
        var r = try h.location(&tok, lat, en.lon);
        defer r.deinit();
        xp = try r.int("me.xp");
    }
    try testing.expect(xp >= 20 and xp <= 26);
    try testing.expect((try h.ctx.db.scalar("SELECT distance_m FROM players WHERE id = ?", .{pid})).? >= 400);
}

test "gear: equip, scrap, upgrade, consumables, abilities" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Smith", "human", &tok);

    var locked = try h.post("/api/upgrade", &tok, "{\"uid\":\"nope\"}");
    defer locked.deinit();
    try testing.expectEqualStrings("locked", try locked.errorCode());

    try h.reachLevel(&tok, 5);
    var g = try h.ok("/api/dev/grant", &tok, "{{\"item\":{{\"base\":\"machete\",\"rarity\":\"rare\"}},\"salvage\":500}}", .{});
    defer g.deinit();
    try testing.expectEqual(@as(i64, 5), try g.int("me.level"));
    try testing.expectEqual(@as(usize, 4), try g.len("me.items"));
    const machete = try g.str("me.items.3.uid");
    try testing.expectEqual(@as(usize, 1), try g.len("me.items.3.perks"));
    try testing.expectEqualStrings("rare", try g.str("me.items.3.rarity"));
    const bat = try testing.allocator.dupe(u8, try g.str("me.items.0.uid"));
    defer testing.allocator.free(bat);
    const atk_before = try g.int("me.stats.atk");

    var eq = try h.ok("/api/equip", &tok, "{{\"uid\":\"{s}\"}}", .{machete});
    defer eq.deinit();
    try testing.expectEqualStrings(machete, try eq.str("me.equipped.weapon"));
    try testing.expect(try eq.int("me.stats.atk") > atk_before);

    var sc_eq = try h.postf("/api/scrap", &tok, "{{\"uids\":[\"{s}\"]}}", .{machete});
    defer sc_eq.deinit();
    try testing.expectEqualStrings("equipped", try sc_eq.errorCode());
    var sc = try h.ok("/api/scrap", &tok, "{{\"uids\":[\"{s}\",\"{s}\"]}}", .{ bat, bat });
    defer sc.deinit();
    try testing.expectEqual(@as(i64, 3), try sc.int("salvage_gained"));
    try testing.expectEqual(@as(i64, 503), try sc.int("me.salvage"));
    try testing.expectEqual(@as(usize, 3), try sc.len("me.items"));

    const cost = try sc.int("me.items.2.upgrade_cost");
    var up = try h.ok("/api/upgrade", &tok, "{{\"uid\":\"{s}\"}}", .{machete});
    defer up.deinit();
    try testing.expectEqual(@as(i64, 503) - cost, try up.int("me.salvage"));
    try testing.expectEqual(@as(i64, 1), try up.int("me.items.2.upgrade"));

    // Heals: refused at full health, work when hurt, and level-5 abilities are auto-equipped.
    // (Gear perks can raise max HP above the stored value, so top up first.)
    try h.ctx.db.run("UPDATE players SET hp = 100000, hp_at = ?", .{h.ctx.now()});
    var full = try h.post("/api/use", &tok, "{\"consumable\":\"heal_s\"}");
    defer full.deinit();
    try testing.expectEqualStrings("full_health", try full.errorCode());
    try testing.expectEqual(@as(usize, 1), try up.len("me.abilities.equipped"));
    try testing.expectEqualStrings("second_wind", try up.str("me.abilities.equipped.0"));
    var ab = try h.post("/api/abilities", &tok, "{\"equipped\":[\"aimed_shot\"]}");
    defer ab.deinit();
    try testing.expectEqualStrings("not_unlocked", try ab.errorCode());
    var ab2 = try h.post("/api/abilities", &tok, "{\"equipped\":[\"second_wind\",\"second_wind\"]}");
    defer ab2.deinit();
    try testing.expectEqual(@as(u16, 200), ab2.status);
    var ab3 = try h.ok("/api/abilities", &tok, "{{\"equipped\":[]}}", .{});
    defer ab3.deinit();
    try testing.expectEqual(@as(usize, 0), try ab3.len("me.abilities.equipped"));

    const pid = try h.playerId("Smith");
    try h.ctx.db.run("UPDATE players SET hp = 20, hp_at = ? WHERE id = ?", .{ h.ctx.now(), pid });
    var hurt = try h.get("/api/me", &tok);
    defer hurt.deinit();
    try testing.expectEqual(@as(i64, 20), try hurt.int("hp"));
    var heal = try h.ok("/api/use", &tok, "{{\"consumable\":\"heal_s\"}}", .{});
    defer heal.deinit();
    try testing.expect(try heal.int("me.hp") > 20);
    try testing.expectEqual(@as(i64, 2), try heal.int("me.consumables.heal_s"));
    var buff = try h.ok("/api/dev/grant", &tok, "{{\"consumable\":{{\"id\":\"buff_atk\",\"n\":1}}}}", .{});
    buff.deinit();
    var used = try h.ok("/api/use", &tok, "{{\"consumable\":\"buff_atk\"}}", .{});
    defer used.deinit();
    try testing.expectEqualStrings("buff_atk", try used.str("me.buffs.0.kind"));
    var none = try h.post("/api/use", &tok, "{\"consumable\":\"buff_def\"}");
    defer none.deinit();
    try testing.expectEqualStrings("none_left", try none.errorCode());
}

test "HP regenerates lazily; Downed ends at 30%; revive and not-usable flags" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Hurt", "zombie", &tok);
    const pid = try h.playerId("Hurt");
    var me0 = try h.get("/api/me", &tok);
    defer me0.deinit();
    const max = try me0.int("max_hp");

    try h.ctx.db.run("UPDATE players SET hp = 10, hp_at = ? WHERE id = ?", .{ h.ctx.now(), pid });
    h.advance(10 * 60 * 1000);
    var me1 = try h.get("/api/me", &tok);
    defer me1.deinit();
    // Zombies regenerate 2.5% of max HP per minute.
    try testing.expectEqual(10 + game.stats.regenHp(.zombie, @intCast(max), 10), try me1.int("hp"));

    try h.ctx.db.run("UPDATE players SET hp = 0, hp_at = ?, downed_until = ? WHERE id = ?", .{ h.ctx.now(), h.ctx.now() + 10 * 60 * 1000, pid });
    var down = try h.get("/api/me", &tok);
    defer down.deinit();
    try testing.expectEqual(@as(i64, 0), try down.int("hp"));
    try testing.expect((try down.at("downed_until")) != .null);
    var hu = try h.post("/api/use", &tok, "{\"consumable\":\"heal_s\"}");
    defer hu.deinit();
    try testing.expectEqualStrings("downed", try hu.errorCode());
    var fl = try h.post("/api/use", &tok, "{\"consumable\":\"flag\"}");
    defer fl.deinit();
    try testing.expectEqualStrings("not_usable", try fl.errorCode());

    h.advance(10 * 60 * 1000 + 1000);
    var up = try h.get("/api/me", &tok);
    defer up.deinit();
    try testing.expect((try up.at("downed_until")) == .null);
    const expect_hp: i64 = @intFromFloat(@ceil(0.3 * @as(f64, @floatFromInt(max))));
    try testing.expect(try up.int("hp") >= expect_hp);
    try testing.expect(try up.int("hp") <= expect_hp + 3);

    // A Trauma Kit gets a downed player up at once, at full HP.
    try h.ctx.db.run("UPDATE players SET hp = 0, hp_at = ?, downed_until = ? WHERE id = ?", .{ h.ctx.now(), h.ctx.now() + 600_000, pid });
    var gr = try h.ok("/api/dev/grant", &tok, "{{\"consumable\":{{\"id\":\"revive\",\"n\":1}}}}", .{});
    gr.deinit();
    var rv = try h.ok("/api/use", &tok, "{{\"consumable\":\"revive\"}}", .{});
    defer rv.deinit();
    try testing.expect((try rv.at("me.downed_until")) == .null);
    try testing.expectEqual(max, try rv.int("me.hp"));
}

test "missions: progress, claim once, streak, reset by day" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Grinder", "human", &tok);
    const pid = try h.playerId("Grinder");

    var me = try h.get("/api/me", &tok);
    defer me.deinit();
    try testing.expectEqual(@as(usize, 3), try me.len("missions.daily"));
    const mid = try testing.allocator.dupe(u8, try me.str("missions.daily.0.id"));
    defer testing.allocator.free(mid);
    const target = try me.int("missions.daily.0.target");
    var early = try h.postf("/api/missions/claim", &tok, "{{\"id\":\"{s}\"}}", .{mid});
    defer early.deinit();
    try testing.expectEqualStrings("incomplete", try early.errorCode());
    var bogus = try h.post("/api/missions/claim", &tok, "{\"id\":\"d.1.0\"}");
    defer bogus.deinit();
    try testing.expectEqual(@as(u16, 404), bogus.status);

    try h.ctx.db.run("INSERT INTO mission_progress(player_id, mid, progress) VALUES(?,?,?)", .{ pid, mid, target });
    var c = try h.ok("/api/missions/claim", &tok, "{{\"id\":\"{s}\"}}", .{mid});
    defer c.deinit();
    try testing.expect(try c.int("rewards.salvage") > 0);
    try testing.expectEqual(@as(i64, 1), try c.int("me.missions.streak"));
    try testing.expectEqual(true, (try c.at("me.missions.daily.0.claimed")).bool);
    var dup = try h.postf("/api/missions/claim", &tok, "{{\"id\":\"{s}\"}}", .{mid});
    defer dup.deinit();
    try testing.expectEqualStrings("already_claimed", try dup.errorCode());

    // Next day: a new list, the streak survives; a missed day lapses it.
    h.advance(game.war.day_ms);
    var next = try h.get("/api/me", &tok);
    defer next.deinit();
    try testing.expect(!std.mem.eql(u8, mid, try next.str("missions.daily.0.id")));
    try testing.expectEqual(@as(i64, 1), try next.int("missions.streak"));
    h.advance(2 * game.war.day_ms);
    var lapsed = try h.get("/api/me", &tok);
    defer lapsed.deinit();
    try testing.expectEqual(@as(i64, 0), try lapsed.int("missions.streak"));

    // Finishing all three dailies pays the bonus consumable.
    for (0..3) |i| {
        const path = try std.fmt.allocPrint(testing.allocator, "missions.daily.{d}", .{i});
        defer testing.allocator.free(path);
        const idp = try std.fmt.allocPrint(testing.allocator, "{s}.id", .{path});
        defer testing.allocator.free(idp);
        const tp = try std.fmt.allocPrint(testing.allocator, "{s}.target", .{path});
        defer testing.allocator.free(tp);
        const id = try testing.allocator.dupe(u8, try lapsed.str(idp));
        defer testing.allocator.free(id);
        try h.ctx.db.run("INSERT INTO mission_progress(player_id, mid, progress) VALUES(?,?,?)", .{ pid, id, try lapsed.int(tp) });
        var claim = try h.ok("/api/missions/claim", &tok, "{{\"id\":\"{s}\"}}", .{id});
        defer claim.deinit();
        if (i == 2) try testing.expectEqual(@as(i64, 1), try claim.int("rewards.consumables.heal_m"));
    }
}

test "store: levels, prices, requisitions, inventory expansion" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Shopper", "human", &tok);

    var locked = try h.post("/api/store/buy", &tok, "{\"sku\":\"heal_s\"}");
    defer locked.deinit();
    try testing.expectEqualStrings("locked", try locked.errorCode());
    try h.reachLevel(&tok, 2);
    var poor = try h.post("/api/store/buy", &tok, "{\"sku\":\"heal_s\"}");
    defer poor.deinit();
    try testing.expectEqualStrings("not_enough_salvage", try poor.errorCode());
    var unknown = try h.post("/api/store/buy", &tok, "{\"sku\":\"gold\"}");
    defer unknown.deinit();
    try testing.expectEqual(@as(u16, 404), unknown.status);

    var gr = try h.ok("/api/dev/grant", &tok, "{{\"salvage\":1000}}", .{});
    gr.deinit();
    var heal = try h.ok("/api/store/buy", &tok, "{{\"sku\":\"heal_s\"}}", .{});
    defer heal.deinit();
    try testing.expectEqual(@as(i64, 980), try heal.int("me.salvage"));
    try testing.expectEqual(@as(i64, 4), try heal.int("me.consumables.heal_s"));
    try testing.expectEqual(@as(i64, 1), try heal.int("rewards.consumables.heal_s"));
    var req = try h.ok("/api/store/buy", &tok, "{{\"sku\":\"requisition\"}}", .{});
    defer req.deinit();
    try testing.expectEqual(@as(i64, 830), try req.int("me.salvage"));
    try testing.expectEqual(@as(usize, 1), try req.len("rewards.items"));
    try testing.expect(!std.mem.eql(u8, "common", try req.str("rewards.items.0.rarity")));
    try testing.expectEqual(@as(usize, 4), try req.len("me.items"));
    var inv = try h.ok("/api/store/buy", &tok, "{{\"sku\":\"inventory\"}}", .{});
    defer inv.deinit();
    try testing.expectEqual(@as(i64, 430), try inv.int("me.salvage"));
    try testing.expectEqual(@as(i64, 42), try inv.int("me.inventory_cap"));
    var boost = try h.ok("/api/store/buy", &tok, "{{\"sku\":\"xp_boost\"}}", .{});
    defer boost.deinit();
    try testing.expectEqualStrings("xp_boost", try boost.str("me.buffs.0.kind"));
    var flag = try h.post("/api/store/buy", &tok, "{\"sku\":\"flag\"}");
    defer flag.deinit();
    try testing.expectEqualStrings("locked", try flag.errorCode());
}

test "clans: found, join by code, chat with rate limit, leave and succession" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    var z: [64]u8 = undefined;
    try h.player("Leader", "human", &a);
    try h.player("Member", "human", &b);
    try h.player("Enemy", "zombie", &z);

    var early = try h.post("/api/clans", &a, "{\"name\":\"Last Light\",\"tag\":\"LL\"}");
    defer early.deinit();
    try testing.expectEqualStrings("locked", try early.errorCode());
    for ([_][]const u8{ &a, &b, &z }) |t| try h.reachLevel(t, 10);
    var poor = try h.post("/api/clans", &a, "{\"name\":\"Last Light\",\"tag\":\"LL\"}");
    defer poor.deinit();
    try testing.expectEqualStrings("not_enough_salvage", try poor.errorCode());
    var gr = try h.ok("/api/dev/grant", &a, "{{\"salvage\":500}}", .{});
    gr.deinit();

    var made = try h.ok("/api/clans", &a, "{{\"name\":\"Last Light\",\"tag\":\"ll\"}}", .{});
    defer made.deinit();
    try testing.expectEqualStrings("LL", try made.str("clan.tag"));
    try testing.expectEqualStrings("leader", try made.str("me.clan.role"));
    try testing.expectEqual(@as(i64, 0), try made.int("me.salvage"));
    const code = try testing.allocator.dupe(u8, try made.str("clan.code"));
    defer testing.allocator.free(code);
    try testing.expectEqual(@as(usize, 8), code.len);
    var dup = try h.post("/api/clans", &b, "{\"name\":\"last light\",\"tag\":\"XX\"}");
    defer dup.deinit();
    try testing.expectEqual(@as(u16, 409), dup.status);

    var list = try h.get("/api/clans?q=light", &b);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), try list.len("clans"));
    try testing.expectEqual(@as(i64, 1), try list.int("clans.0.members"));
    var other = try h.get("/api/clans?q=light", &z);
    defer other.deinit();
    try testing.expectEqual(@as(usize, 0), try other.len("clans"));
    var wrong = try h.postf("/api/clans/join", &z, "{{\"code\":\"{s}\"}}", .{code});
    defer wrong.deinit();
    try testing.expectEqualStrings("wrong_faction", try wrong.errorCode());

    var joined = try h.ok("/api/clans/join", &b, "{{\"code\":\"{s}\"}}", .{code});
    defer joined.deinit();
    try testing.expectEqual(@as(usize, 2), try joined.len("clan.members"));
    try testing.expectEqualStrings("Leader", try joined.str("clan.members.0.callsign"));
    try testing.expectEqualStrings("member", try joined.str("me.clan.role"));
    var again = try h.postf("/api/clans/join", &b, "{{\"code\":\"{s}\"}}", .{code});
    defer again.deinit();
    try testing.expectEqualStrings("already_in_clan", try again.errorCode());

    // Chat: one message per 3 seconds per player, 200 characters.
    var m1 = try h.ok("/api/clan/chat", &a, "{{\"text\":\"hold the line\"}}", .{});
    defer m1.deinit();
    try testing.expectEqual(@as(usize, 1), try m1.len("messages"));
    var m2 = try h.post("/api/clan/chat", &a, "{\"text\":\"again\"}");
    defer m2.deinit();
    try testing.expectEqual(@as(u16, 429), m2.status);
    try testing.expectEqualStrings("slow_down", try m2.errorCode());
    var m3 = try h.ok("/api/clan/chat", &b, "{{\"text\":\"copy\"}}", .{});
    defer m3.deinit();
    h.advance(3500);
    const long = try testing.allocator.alloc(u8, 201);
    defer testing.allocator.free(long);
    @memset(long, 'a');
    var m4 = try h.postf("/api/clan/chat", &a, "{{\"text\":\"{s}\"}}", .{long});
    defer m4.deinit();
    try testing.expectEqual(@as(u16, 400), m4.status);
    var m5 = try h.ok("/api/clan/chat", &a, "{{\"text\":\"ok\"}}", .{});
    defer m5.deinit();
    var hist = try h.get("/api/clan/chat", &b);
    defer hist.deinit();
    try testing.expectEqual(@as(usize, 3), try hist.len("messages"));
    try testing.expectEqualStrings("Leader", try hist.str("messages.0.callsign"));
    try testing.expectEqualStrings("hold the line", try hist.str("messages.0.text"));

    var detail = try h.get("/api/clan", &b);
    defer detail.deinit();
    try testing.expectEqualStrings(code, try detail.str("clan.code"));

    // The leader leaves: the other member takes over; the last one out closes the clan.
    var left = try h.ok("/api/clans/leave", &a, "{{}}", .{});
    defer left.deinit();
    try testing.expect((try left.at("me.clan")) == .null);
    var d2 = try h.get("/api/clan", &b);
    defer d2.deinit();
    try testing.expectEqualStrings("leader", try d2.str("clan.members.0.role"));
    var left2 = try h.ok("/api/clans/leave", &b, "{{}}", .{});
    left2.deinit();
    try testing.expectEqual(@as(?i64, null), try h.ctx.db.scalar("SELECT id FROM clans", .{}));
    var none = try h.get("/api/clan", &b);
    defer none.deinit();
    try testing.expectEqualStrings("no_clan", try none.errorCode());
}

/// Put two players of opposite factions `metres` apart (north-south) and return nothing else.
fn placePair(h: *Harness, a: []const u8, b: []const u8, metres: f64) !void {
    var ra = try h.location(a, base_lat, base_lon);
    ra.deinit();
    var rb = try h.location(b, base_lat + metres / 111_320.0, base_lon);
    rb.deinit();
}

fn eventOfType(r: *const Res, kind: []const u8) !?Value {
    for ((try r.at("events")).array.items) |e| {
        if (std.mem.eql(u8, e.object.get("type").?.string, kind)) return e;
    }
    return null;
}

test "contact: two players 30 m apart fight; each sees an anonymous foe from their side" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    var z: [64]u8 = undefined;
    try h.player("Hank", "human", &a);
    try h.player("Zed", "zombie", &z);
    try h.reachLevel(&a, 6);
    try h.reachLevel(&z, 7);

    try placePair(&h, &a, &z, 30);
    tick.runLocked(&h.ctx, h.ctx.now());

    var wa = try h.location(&a, base_lat, base_lon);
    defer wa.deinit();
    var wz = try h.location(&z, base_lat + 30.0 / 111_320.0, base_lon);
    defer wz.deinit();
    const ea = (try eventOfType(&wa, "contact")) orelse return error.NoContactEvent;
    const ez = (try eventOfType(&wz, "contact")) orelse return error.NoContactEvent;
    const ba = ea.object.get("battle").?.object;
    const bz = ez.object.get("battle").?.object;
    try testing.expectEqualStrings("pvp", ba.get("kind").?.string);
    try testing.expectEqualStrings("Hank", ba.get("a").?.object.get("name").?.string);
    try testing.expectEqualStrings("A Zombie", ba.get("b").?.object.get("name").?.string);
    try testing.expectEqual(@as(i64, 7), ba.get("b").?.object.get("level").?.integer);
    try testing.expectEqualStrings("Zed", bz.get("a").?.object.get("name").?.string);
    try testing.expectEqualStrings("A Human", bz.get("b").?.object.get("name").?.string);
    // Opposite results, mirrored logs, opponent gear in the opponent's own faction names.
    try testing.expect(!std.mem.eql(u8, ba.get("winner").?.string, bz.get("winner").?.string));
    try testing.expectEqual(ba.get("turns").?.array.items.len, bz.get("turns").?.array.items.len);
    try testing.expectEqualStrings("Rotten Teeth", ba.get("b").?.object.get("gear").?.array.items[0].string);
    try testing.expectEqualStrings("Baseball Bat", bz.get("b").?.object.get("gear").?.array.items[0].string);
    const t0a = ba.get("turns").?.array.items[0].object;
    const t0z = bz.get("turns").?.array.items[0].object;
    try testing.expect(!std.mem.eql(u8, t0a.get("actor").?.string, t0z.get("actor").?.string));
    try testing.expectEqual(t0a.get("hp_a").?.integer, t0z.get("hp_b").?.integer);
    try testing.expect(ea.object.get("rewards").?.object.get("xp").?.integer > 0);
    // Delivered once.
    var wa2 = try h.location(&a, base_lat, base_lon);
    defer wa2.deinit();
    try testing.expect((try eventOfType(&wa2, "contact")) == null);
    // The loser is hurt (possibly Downed), the winner keeps fighting fit.
    const won_a = std.mem.eql(u8, ba.get("winner").?.string, "a");
    var me_loser = try h.get("/api/me", if (won_a) &z else &a);
    defer me_loser.deinit();
    try testing.expect(try me_loser.int("hp") < try me_loser.int("max_hp"));

    // Not again within 4 hours, even after the 10 minute fight pause.
    h.advance(11 * 60 * 1000);
    try h.ctx.db.run("UPDATE players SET hp = 100000, hp_at = ?, downed_until = NULL", .{h.ctx.now()});
    try placePair(&h, &a, &z, 30);
    tick.runLocked(&h.ctx, h.ctx.now());
    try testing.expectEqual(@as(?i64, 1), try h.ctx.db.scalar("SELECT COUNT(*) FROM contact_log", .{}));
    var feed = try h.get("/api/feed", &a);
    defer feed.deinit();
    try testing.expectEqualStrings("contact", try feed.str("events.0.type"));
    h.advance(4 * 60 * 60 * 1000);
    try placePair(&h, &a, &z, 30);
    tick.runLocked(&h.ctx, h.ctx.now());
    try testing.expectEqual(@as(?i64, 2), try h.ctx.db.scalar("SELECT COUNT(*) FROM contact_log", .{}));
}

test "contact needs every condition: range, level, sanctuary, faction, protection" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    var z: [64]u8 = undefined;
    var h2: [64]u8 = undefined;
    try h.player("Alpha1", "human", &a);
    try h.player("Zeta1", "zombie", &z);
    try h.player("Hotel2", "human", &h2);
    try h.reachLevel(&a, 8);
    try h.reachLevel(&z, 8);
    try h.reachLevel(&h2, 8);
    const count = "SELECT COUNT(*) FROM contact_log";

    try placePair(&h, &a, &z, 90); // too far
    tick.runLocked(&h.ctx, h.ctx.now());
    try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar(count, .{}));

    var rh = try h.location(&h2, base_lat + 5.0 / 111_320.0, base_lon); // same faction as A
    rh.deinit();
    var near = try h.location(&a, base_lat, base_lon);
    near.deinit();
    tick.runLocked(&h.ctx, h.ctx.now());
    try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar(count, .{}));

    // Hostile signal: a zombie within 500 m shows as a flag, nothing more.
    h.advance(30_000);
    var hostile = try h.location(&z, base_lat + 300.0 / 111_320.0, base_lon);
    defer hostile.deinit();
    try testing.expectEqual(true, (try hostile.at("hostiles_near")).bool);

    // In a sanctuary: no match.
    h.advance(30_000);
    var s = try h.ok("/api/location", &z, "{{\"lat\":{d},\"lon\":{d},\"acc\":5,\"sanctuary\":true}}", .{ base_lat + 20.0 / 111_320.0, base_lon });
    s.deinit();
    tick.runLocked(&h.ctx, h.ctx.now());
    try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar(count, .{}));
    var s2 = try h.location(&a, base_lat, base_lon);
    defer s2.deinit();
    try testing.expectEqual(false, (try s2.at("hostiles_near")).bool);

    // Under level 5: protected.
    try h.ctx.db.run("UPDATE players SET level = 4 WHERE callsign = 'Zeta1'", .{});
    var back = try h.location(&z, base_lat + 20.0 / 111_320.0, base_lon);
    back.deinit();
    tick.runLocked(&h.ctx, h.ctx.now());
    try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar(count, .{}));
    // Level band: 8 against 30 is out of range.
    try h.ctx.db.run("UPDATE players SET level = 30 WHERE callsign = 'Zeta1'", .{});
    tick.runLocked(&h.ctx, h.ctx.now());
    try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar(count, .{}));
    // Back in range, everything holds: they fight.
    try h.ctx.db.run("UPDATE players SET level = 12 WHERE callsign = 'Zeta1'", .{});
    tick.runLocked(&h.ctx, h.ctx.now());
    try testing.expectEqual(@as(?i64, 1), try h.ctx.db.scalar(count, .{}));
}

test "dev bot contact stages a Contact against a generated opponent" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    try h.player("Lonely", "human", &a);
    var r = try h.ok("/api/dev/bot_contact", &a, "{{}}", .{});
    r.deinit();
    var w = try h.location(&a, base_lat, base_lon);
    defer w.deinit();
    const ev = (try eventOfType(&w, "contact")) orelse return error.NoContactEvent;
    try testing.expectEqualStrings("A Zombie", ev.object.get("battle").?.object.get("b").?.object.get("name").?.string);
}

test "echoes: a real opposing snapshot (reported to its owner), or a labelled rogue" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    var z: [64]u8 = undefined;
    try h.player("Seeker", "human", &a);
    try h.reachLevel(&a, 5);

    // Alone on the server: the echo is a Rogue and says so.
    var first: ?Value = null;
    var res: Res = undefined;
    var tries: usize = 0;
    while (tries < 60) : (tries += 1) {
        res = try h.location(&a, base_lat, base_lon);
        if (try res.len("echoes") > 0) {
            first = try res.at("echoes.0");
            break;
        }
        res.deinit();
        h.advance(echoWindow());
    }
    defer res.deinit();
    const echo = first orelse return error.NoEchoAppeared;
    try testing.expectEqual(true, echo.object.get("rogue").?.bool);
    try testing.expectEqualStrings("zombie", echo.object.get("faction").?.string);

    // Walk to it (the 45 m/s check allows 300 m in 10 s) and fight.
    const elat = echo.object.get("lat").?.float;
    const elon = echo.object.get("lon").?.float;
    const eid = try testing.allocator.dupe(u8, echo.object.get("id").?.string);
    defer testing.allocator.free(eid);
    h.advance(10_000);
    var at = try h.location(&a, elat, elon);
    at.deinit();
    var b = try h.ok("/api/engage", &a, "{{\"id\":\"{s}\"}}", .{eid});
    defer b.deinit();
    try testing.expectEqualStrings("echo", try b.str("kind"));
    try testing.expectEqualStrings("Rogue", try b.str("b.name"));
    try testing.expectEqualStrings("rogue", try b.str("b.kind"));
    var gone = try h.location(&a, elat, elon);
    defer gone.deinit();
    for ((try gone.at("echoes")).array.items) |e| try testing.expect(!std.mem.eql(u8, e.object.get("id").?.string, eid));
    var dup = try h.postf("/api/engage", &a, "{{\"id\":\"{s}\"}}", .{eid});
    defer dup.deinit();
    try testing.expect(dup.status == 404 or dup.status == 409);

    // Now a Zombie of similar level exists; the next echo is their snapshot.
    try h.player("Ghoul", "zombie", &z);
    try h.reachLevel(&z, 6);
    try h.ctx.db.run("UPDATE players SET last_pvp_at = 0", .{});
    var found: ?Value = null;
    var res2: Res = undefined;
    tries = 0;
    while (tries < 60) : (tries += 1) {
        h.advance(echoWindow());
        res2 = try h.location(&a, base_lat, base_lon);
        if (try res2.len("echoes") > 0) {
            found = try res2.at("echoes.0");
            break;
        }
        res2.deinit();
    }
    defer res2.deinit();
    const real = found orelse return error.NoEchoAppeared;
    try testing.expectEqual(false, real.object.get("rogue").?.bool);
    try testing.expectEqual(@as(i64, 6), real.object.get("level").?.integer);
    const eid2 = try testing.allocator.dupe(u8, real.object.get("id").?.string);
    defer testing.allocator.free(eid2);
    h.advance(10_000);
    var at2 = try h.location(&a, real.object.get("lat").?.float, real.object.get("lon").?.float);
    at2.deinit();
    var b2 = try h.ok("/api/engage", &a, "{{\"id\":\"{s}\"}}", .{eid2});
    defer b2.deinit();
    try testing.expectEqualStrings("Echo", try b2.str("b.name"));
    try testing.expectEqualStrings("echo", try b2.str("b.kind"));

    // The Zombie hears about it.
    var zw = try h.location(&z, base_lat + 0.5, base_lon);
    defer zw.deinit();
    const report = (try eventOfType(&zw, "echo_report")) orelse return error.NoReport;
    const text = report.object.get("text").?.string;
    if (std.mem.eql(u8, try b2.str("winner"), "a")) {
        try testing.expectEqualStrings("Your echo fell.", text);
    } else {
        try testing.expect(std.mem.startsWith(u8, text, "Your echo held against a Human (+"));
    }
}

fn echoWindow() i64 {
    return 30 * 60 * 1000;
}

test "strongholds: claim with a flag, then a rival clan fights the garrison" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    var z: [64]u8 = undefined;
    try h.player("Holder", "human", &a);
    try h.player("Raider", "zombie", &z);
    for ([_][]const u8{ &a, &z }) |t| {
        try h.reachLevel(t, 15);
        var gr = try h.ok("/api/dev/grant", t, "{{\"salvage\":600,\"consumable\":{{\"id\":\"flag\",\"n\":2}}}}", .{});
        gr.deinit();
    }
    var ca = try h.ok("/api/clans", &a, "{{\"name\":\"Holders\",\"tag\":\"HLD\"}}", .{});
    ca.deinit();
    var cz = try h.ok("/api/clans", &z, "{{\"name\":\"Raiders\",\"tag\":\"RDR\"}}", .{});
    cz.deinit();

    var w = try h.location(&a, base_lat, base_lon);
    defer w.deinit();
    try testing.expect(try w.len("strongholds") >= 1);
    const sh = (try w.at("strongholds.0")).object;
    const sid = try testing.allocator.dupe(u8, sh.get("id").?.string);
    defer testing.allocator.free(sid);
    const slat = sh.get("lat").?.float;
    const slon = sh.get("lon").?.float;
    try testing.expect(sh.get("clan").? == .null);

    // Too far to plant a flag.
    var far = try h.postf("/api/stronghold/claim", &a, "{{\"id\":\"{s}\"}}", .{sid});
    defer far.deinit();
    try testing.expectEqualStrings("too_far", try far.errorCode());

    h.advance(60_000);
    var at = try h.location(&a, slat, slon);
    at.deinit();
    var claim = try h.ok("/api/stronghold/claim", &a, "{{\"id\":\"{s}\"}}", .{sid});
    defer claim.deinit();
    try testing.expectEqual(true, (try claim.at("claimed")).bool);
    try testing.expectEqual(@as(usize, 0), try claim.len("battles"));
    try testing.expectEqual(@as(i64, 1), try claim.int("me.consumables.flag"));
    var again = try h.postf("/api/stronghold/claim", &a, "{{\"id\":\"{s}\"}}", .{sid});
    defer again.deinit();
    try testing.expectEqualStrings("already_held", try again.errorCode());

    var seen = try h.location(&a, slat, slon);
    defer seen.deinit();
    var tag: []const u8 = "";
    for ((try seen.at("strongholds")).array.items) |s| {
        if (std.mem.eql(u8, s.object.get("id").?.string, sid)) tag = s.object.get("clan").?.object.get("tag").?.string;
    }
    try testing.expectEqualStrings("HLD", tag);

    var at2 = try h.location(&z, slat, slon);
    at2.deinit();
    var take = try h.ok("/api/stronghold/claim", &z, "{{\"id\":\"{s}\"}}", .{sid});
    defer take.deinit();
    try testing.expectEqual(@as(usize, 1), try take.len("battles"));
    try testing.expectEqualStrings("garrison", try take.str("battles.0.kind"));
    try testing.expectEqualStrings("Echo", try take.str("battles.0.b.name"));
    const won = std.mem.eql(u8, try take.str("battles.0.winner"), "a");
    try testing.expectEqual(won, (try take.at("claimed")).bool);
    const holder = try h.ctx.db.scalar("SELECT clan_id FROM strongholds", .{});
    const expect_name: []const u8 = if (won) "RDR" else "HLD";
    var st = try h.ctx.db.query("SELECT tag FROM clans WHERE id = ?", .{holder.?});
    defer st.finalize();
    try testing.expect(try st.step());
    try testing.expectEqualStrings(expect_name, st.text(0));

    // The weekly purge empties the board, and holding pays war points by the hour.
    h.advance(3 * 60 * 60 * 1000);
    tick.runLocked(&h.ctx, h.ctx.now());
    try testing.expect((try h.ctx.db.scalar("SELECT SUM(points) FROM war_district", .{})).? >= 4);
    h.advance(game.war.week_ms);
    tick.runLocked(&h.ctx, h.ctx.now());
    try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar("SELECT COUNT(*) FROM strongholds", .{}));
}

test "raids: weekend spawn, attack once an hour, damage share rewards on the kill" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    var z: [64]u8 = undefined;
    h.ctx.seed = 0x5eed; // fixed: a level-20 starter kit can legitimately deal 0 to a boss, so pin the dice
    try h.player("Slayer", "human", &a);
    try h.player("Helper", "zombie", &z);
    try h.reachLevel(&a, 20);
    try h.reachLevel(&z, 20);
    const pa = try h.playerId("Slayer");
    const pz = try h.playerId("Helper");

    // No raids on a weekday, even in an active district.
    const district = game.war.districtId(base_lat, base_lon).str();
    try h.ctx.db.run("INSERT INTO war_player(week, player_id, district, points) VALUES(?,?,?,5)", .{ game.war.weekIndex(h.ctx.now()), pa, district });
    try h.ctx.db.run("INSERT INTO war_player(week, player_id, district, points) VALUES(?,?,?,5)", .{ game.war.weekIndex(h.ctx.now()), pz, district });
    tick.runLocked(&h.ctx, h.ctx.now());
    try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar("SELECT COUNT(*) FROM raids", .{}));

    h.ctx.clock_ms = saturday;
    tick.runLocked(&h.ctx, h.ctx.now());
    try testing.expectEqual(@as(?i64, 1), try h.ctx.db.scalar("SELECT COUNT(*) FROM raids", .{}));
    try testing.expectEqual(@as(?i64, 30_000), try h.ctx.db.scalar("SELECT max_hp FROM raids", .{}));

    var st = try h.ctx.db.query("SELECT id, site FROM raids", .{});
    const rid = try testing.allocator.dupe(u8, blk: {
        try testing.expect(try st.step());
        break :blk st.text(0);
    });
    defer testing.allocator.free(rid);
    const cell = try geo.Geohash.parse(st.text(1));
    st.finalize();
    const site = spawns.stronghold(h.ctx.seed, cell);

    var w = try h.location(&a, site.lat, site.lon);
    defer w.deinit();
    try testing.expectEqual(@as(usize, 1), try w.len("raids"));
    try testing.expectEqualStrings("Abomination", try w.str("raids.0.boss"));
    try testing.expectEqual(@as(i64, 30_000), try w.int("raids.0.hp"));
    try testing.expectEqual(@as(i64, 0), try w.int("raids.0.fighters"));

    try h.ctx.db.run("UPDATE players SET hp = 100000, hp_at = ?", .{h.ctx.now()});
    var hit = try h.ok("/api/raid/attack", &a, "{{\"id\":\"{s}\"}}", .{rid});
    defer hit.deinit();
    try testing.expectEqualStrings("raid", try hit.str("kind"));
    try testing.expectEqualStrings("boss", try hit.str("b.kind"));
    const left = (try h.ctx.db.scalar("SELECT hp FROM raids", .{})).?;
    try testing.expect(left <= 30_000);
    try testing.expect(try hit.int("rewards.xp") >= 1);
    var cd = try h.postf("/api/raid/attack", &a, "{{\"id\":\"{s}\"}}", .{rid});
    defer cd.deinit();
    try testing.expect(cd.status == 409);
    try testing.expect(std.mem.eql(u8, try cd.errorCode(), "cooldown") or std.mem.eql(u8, try cd.errorCode(), "downed"));

    // A second fighter, an hour later: the boss is nearly dead, so this attack kills it.
    h.advance(61 * 60 * 1000);
    try h.ctx.db.run("UPDATE players SET downed_until = NULL, hp = 100000, hp_at = ?", .{h.ctx.now()});
    try h.ctx.db.run("UPDATE raids SET hp = 1", .{});
    var wz = try h.location(&z, site.lat, site.lon);
    wz.deinit();
    // A starter kit can deal 0 to a boss, so make sure the first fighter is on the board and retry the kill.
    try h.ctx.db.run("INSERT INTO raid_damage(raid_id, player_id, damage, last_attack_at) VALUES(?,?,1000,0) ON CONFLICT(raid_id, player_id) DO UPDATE SET damage = MAX(damage, 1000)", .{ rid, pa });
    for (0..40) |_| {
        var k = try h.ok("/api/raid/attack", &z, "{{\"id\":\"{s}\"}}", .{rid});
        k.deinit();
        if ((try h.ctx.db.scalar("SELECT settled FROM raids", .{})).? == 1) break;
        h.advance(61 * 60 * 1000);
        try h.ctx.db.run("UPDATE players SET downed_until = NULL, hp = 100000, hp_at = ?", .{h.ctx.now()});
        try h.ctx.db.run("UPDATE raids SET hp = 1", .{});
        var wz2 = try h.location(&z, site.lat, site.lon);
        wz2.deinit();
    }
    try testing.expectEqual(@as(?i64, 1), try h.ctx.db.scalar("SELECT settled FROM raids", .{}));
    try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar("SELECT hp FROM raids", .{}));

    var wa = try h.location(&a, site.lat, site.lon);
    defer wa.deinit();
    const ev = (try eventOfType(&wa, "raid")) orelse return error.NoRaidEvent;
    try testing.expect(ev.object.get("rewards").?.object.get("salvage").?.integer >= 50);
    try testing.expect(ev.object.get("rewards").?.object.get("items").?.array.items.len >= 1);
    try testing.expectEqual(@as(usize, 0), try wa.len("raids"));

    // An untouched raid just expires after 48 hours.
    h.advance(game.war.week_ms);
    tick.runLocked(&h.ctx, h.ctx.now());
}

test "war, factions, leaderboards, avatar" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    var c: [64]u8 = undefined;
    try h.player("Aaa", "human", &a);
    try h.player("Bbb", "zombie", &b);
    try h.player("Ccc", "zombie", &c);

    // 1 human against 2 zombies: the human side is the underdog, +min(25%, gap*50%).
    var f = try h.get("/api/factions", null);
    defer f.deinit();
    try testing.expectEqual(@as(i64, 1), try f.int("human.players"));
    try testing.expectEqual(@as(i64, 2), try f.int("zombie.players"));
    try testing.expectEqualStrings("human", try f.str("underdog"));
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 6.0), (try f.at("underdog_bonus")).float, 1e-5);
    var me = try h.get("/api/me", &a);
    defer me.deinit();
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 6.0), (try me.at("underdog_bonus")).float, 1e-5);
    var mez = try h.get("/api/me", &b);
    defer mez.deinit();
    try testing.expectEqual(@as(i64, 0), try mez.int("underdog_bonus"));

    // Inactive players (unseen for a week) leave the shares.
    try h.ctx.db.run("UPDATE players SET last_seen = ? WHERE callsign = 'Ccc'", .{h.ctx.now() - 8 * game.war.day_ms});
    h.advance(120_000);
    var f2 = try h.get("/api/factions", null);
    defer f2.deinit();
    try testing.expectEqual(@as(i64, 1), try f2.int("zombie.players"));

    const week = game.war.weekIndex(h.ctx.now());
    const pa = try h.playerId("Aaa");
    const pb = try h.playerId("Bbb");
    try h.ctx.db.run("INSERT INTO war_player(week, player_id, district, points) VALUES(?,?,'dr5r',40)", .{ week, pa });
    try h.ctx.db.run("INSERT INTO war_player(week, player_id, district, points) VALUES(?,?,'dr5r',90)", .{ week, pb });
    try h.ctx.db.run("INSERT INTO war_district(week, district, faction, points) VALUES(?,'dr5r',0,40)", .{week});
    try h.ctx.db.run("INSERT INTO war_district(week, district, faction, points) VALUES(?,'dr5r',1,90)", .{week});
    var l = try h.location(&a, base_lat, base_lon);
    l.deinit();
    var w = try h.get("/api/war", &a);
    defer w.deinit();
    try testing.expectEqual(@as(i64, week), try w.int("week"));
    try testing.expectEqual(game.war.weekEnd(h.ctx.now()), try w.int("ends_at"));
    try testing.expectEqual(@as(i64, 40), try w.int("global.human"));
    try testing.expectEqual(@as(i64, 90), try w.int("global.zombie"));
    try testing.expectEqualStrings("dr5r", try w.str("district.id"));
    try testing.expectEqual(@as(i64, 90), try w.int("district.zombie"));
    try testing.expectEqualStrings("Aaa", try w.str("top.0.callsign"));
    try testing.expectEqual(@as(i64, 40), try w.int("my_points"));

    var lb = try h.get("/api/leaderboard?board=weekly", &a);
    defer lb.deinit();
    try testing.expectEqualStrings("Bbb", try lb.str("entries.0.callsign"));
    try testing.expectEqual(@as(i64, 1), try lb.int("entries.0.rank"));
    try testing.expectEqual(@as(i64, 90), try lb.int("entries.0.value"));
    try testing.expectEqualStrings("zombie", try lb.str("entries.0.faction"));
    var lv = try h.get("/api/leaderboard?board=level", &a);
    defer lv.deinit();
    try testing.expectEqual(@as(usize, 3), try lv.len("entries"));
    var badb = try h.get("/api/leaderboard?board=nope", &a);
    defer badb.deinit();
    try testing.expectEqual(@as(u16, 400), badb.status);

    // Winning a district last week is worth +10% XP there this week.
    h.advance(game.war.week_ms);
    var grant = try h.ok("/api/dev/grant", &b, "{{\"xp\":10}}", .{});
    grant.deinit();

    var av = try h.ok("/api/avatar", &a, "{{\"avatar\":{{\"skin\":3,\"hair\":9}}}}", .{});
    defer av.deinit();
    try testing.expectEqual(@as(i64, 3), try av.int("me.avatar.skin"));
    var bad_av = try h.post("/api/avatar", &a, "{\"avatar\":5}");
    defer bad_av.deinit();
    try testing.expectEqual(@as(u16, 400), bad_av.status);
    for ([_][]const u8{ "{\"avatar\":{\"skin\":8}}", "{\"avatar\":{\"hair\":\"short\"}}", "{\"avatar\":{\"bio\":1}}", "{\"avatar\":{\"skin\":-1}}" }) |body| {
        var r = try h.post("/api/avatar", &a, body);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 400), r.status);
    }
    var feed = try h.get("/api/feed", &a);
    defer feed.deinit();
    try testing.expect((try feed.at("events")) == .array);
}

test "positions are never written to the database" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    try h.player("Private", "human", &a);
    var w = try h.location(&a, 12.3456789, 98.7654321);
    w.deinit();
    // No column anywhere stores a coordinate...
    try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar(
        "SELECT COUNT(*) FROM sqlite_master m, pragma_table_info(m.name) c WHERE m.type = 'table' AND (c.name IN ('lat', 'lon', 'latitude', 'longitude') OR c.name LIKE '%\\_lat' ESCAPE '\\' OR c.name LIKE '%\\_lon' ESCAPE '\\')",
        .{},
    ));
    // ...and the value itself is nowhere in the text of any row of the busiest tables.
    var st = try h.ctx.db.query("SELECT COUNT(*) FROM events WHERE text LIKE '%12.3456%' OR battle LIKE '%12.3456%'", .{});
    defer st.finalize();
    try testing.expect(try st.step());
    try testing.expectEqual(@as(i64, 0), st.int(0));
    try testing.expect(h.ctx.live.position(try h.playerId("Private"), h.ctx.now()) != null);
    h.advance(live.position_ttl_ms + 1);
    try testing.expect(h.ctx.live.position(try h.playerId("Private"), h.ctx.now()) == null);
}
