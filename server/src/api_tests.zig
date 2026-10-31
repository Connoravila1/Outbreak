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
        // The real calendar must not change what a test sees; the event tests start events themselves.
        h.ctx.opts.events = false;
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
        const body = try std.fmt.allocPrint(testing.allocator, "{{\"callsign\":\"{s}\",\"terms\":1}}", .{name});
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

    var bad = try h.post("/api/register", null, "{\"callsign\":\"ab\",\"terms\":1}");
    defer bad.deinit();
    try testing.expectEqual(@as(u16, 400), bad.status);
    try testing.expectEqualStrings("callsign_invalid", try bad.errorCode());
    var rude = try h.post("/api/register", null, "{\"callsign\":\"Sh1t_lord\",\"terms\":1}");
    defer rude.deinit();
    try testing.expectEqual(@as(u16, 400), rude.status);
    var junk = try h.post("/api/register", null, "not json");
    defer junk.deinit();
    try testing.expectEqual(@as(u16, 400), junk.status);

    var r = try h.post("/api/register", null, "{\"callsign\":\"NightOwl\",\"terms\":1}");
    defer r.deinit();
    try testing.expectEqual(@as(u16, 200), r.status);
    const token = try r.str("token");
    try testing.expectEqual(@as(usize, 64), token.len);
    const code = try r.str("recovery_code");
    try testing.expectEqual(@as(usize, 19), code.len);
    try testing.expect(code[4] == '-' and code[9] == '-' and code[14] == '-');
    try testing.expect((try r.at("me.faction")) == .null);

    var dup = try h.post("/api/register", null, "{\"callsign\":\"nightowl\",\"terms\":1}");
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

test "dev down and spawn_raid: Downed on demand, a boss at the caller's stronghold" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Tester", "human", &tok);

    var nowhere = try h.post("/api/dev/spawn_raid", &tok, "{}");
    defer nowhere.deinit();
    try testing.expectEqualStrings("no_position", try nowhere.errorCode());

    var w0 = try h.location(&tok, base_lat, base_lon);
    w0.deinit();
    var r = try h.ok("/api/dev/spawn_raid", &tok, "{{\"hp\":5000}}", .{});
    r.deinit();
    var w = try h.location(&tok, base_lat, base_lon);
    defer w.deinit();
    try testing.expectEqual(@as(usize, 1), try w.len("raids"));
    try testing.expectEqual(@as(i64, 5000), try w.int("raids.0.hp"));

    var d = try h.ok("/api/dev/down", &tok, "{{}}", .{});
    defer d.deinit();
    try testing.expectEqual(@as(i64, 0), try d.int("me.hp"));
    try testing.expect((try d.at("me.downed_until")) == .integer);
}

test "catalog abilities name their faction; Me carries the next expansion price" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Catalog", "zombie", &tok);

    var c = try h.get("/api/catalog", null);
    defer c.deinit();
    const list = (try c.at("abilities")).array.items;
    var human: usize = 0;
    var zombie: usize = 0;
    for (list) |a| {
        const f = a.object.get("faction").?.string;
        if (std.mem.eql(u8, f, "human")) human += 1 else zombie += 1;
    }
    try testing.expectEqual(@as(usize, 7), human);
    try testing.expectEqual(@as(usize, 7), zombie);

    try h.reachLevel(&tok, 3);
    var g = try h.ok("/api/dev/grant", &tok, "{{\"salvage\":2000}}", .{});
    try testing.expectEqual(@as(i64, 400), try g.int("me.expansion_price"));
    g.deinit();
    var buy = try h.ok("/api/store/buy", &tok, "{{\"sku\":\"inventory\"}}", .{});
    defer buy.deinit();
    try testing.expectEqual(@as(i64, 600), try buy.int("me.expansion_price"));
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
    try testing.expect(try b.len("turns") >= 1); // a crit can end it in one or two blows
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
    try testing.expectEqual(@as(i64, 0), try me.int("record.contacts_won"));
    try testing.expectEqualStrings("Unbloodied", try me.str("contact_rank.name"));
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
    // 500 granted, the bat's 3, 20 for level 5 and 30 for the first Rare (achievements).
    try testing.expectEqual(@as(i64, 553), try sc.int("me.salvage"));
    try testing.expectEqual(@as(usize, 3), try sc.len("me.items"));

    const cost = try sc.int("me.items.2.upgrade_cost");
    var up = try h.ok("/api/upgrade", &tok, "{{\"uid\":\"{s}\"}}", .{machete});
    defer up.deinit();
    try testing.expectEqual(@as(i64, 553) - cost, try up.int("me.salvage"));
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

/// The salvage the achievements listed at `path` paid.
fn achievementPay(r: *const Res, path: []const u8) !i64 {
    var total: i64 = 0;
    for ((try r.at(path)).array.items) |e| total += e.object.get("salvage").?.integer;
    return total;
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
    // The requisition may turn up a Rare, which is an achievement and pays on top.
    const pay = try achievementPay(&req, "rewards.achievements");
    try testing.expectEqual(@as(i64, 830) + pay, try req.int("me.salvage"));
    try testing.expectEqual(@as(usize, 1), try req.len("rewards.items"));
    try testing.expect(!std.mem.eql(u8, "common", try req.str("rewards.items.0.rarity")));
    try testing.expectEqual(@as(usize, 4), try req.len("me.items"));
    var inv = try h.ok("/api/store/buy", &tok, "{{\"sku\":\"inventory\"}}", .{});
    defer inv.deinit();
    try testing.expectEqual(@as(i64, 430) + pay, try inv.int("me.salvage"));
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
    // What is left of the level 5 and 10 achievements (20 + 50) after the 500 salvage fee.
    try testing.expectEqual(@as(i64, 70), try made.int("me.salvage"));
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
    // Both kits are described for drawing: slot, the wearer's own faction names, rarity; never ids.
    const gd = ba.get("b").?.object.get("gear_detail").?.array.items;
    try testing.expectEqual(ba.get("b").?.object.get("gear").?.array.items.len, gd.len);
    try testing.expectEqualStrings("Rotten Teeth", gd[0].object.get("name").?.string);
    try testing.expectEqualStrings("weapon", gd[0].object.get("slot").?.string);
    try testing.expect(gd[0].object.get("rarity") != null and gd[0].object.get("upgrade") != null and gd[0].object.get("unique") != null);
    try testing.expect(gd[0].object.get("uid") == null);
    try testing.expect(ba.get("a").?.object.get("gear_detail").?.array.items.len > 0);
    try testing.expect(ba.get("b").?.object.get("stance") != null);
    // The record keeps Contact wins and losses apart and ranks the winner.
    const won_first = std.mem.eql(u8, ba.get("winner").?.string, "a");
    var rec_a = try h.get("/api/me", &a);
    defer rec_a.deinit();
    try testing.expectEqual(@as(i64, if (won_first) 1 else 0), try rec_a.int("record.contacts_won"));
    try testing.expectEqual(@as(i64, if (won_first) 0 else 1), try rec_a.int("record.contacts_lost"));
    try testing.expectEqualStrings(if (won_first) "Blooded" else "Unbloodied", try rec_a.str("contact_rank.name"));
    try testing.expectEqual(@as(i64, if (won_first) 5 else 1), try rec_a.int("contact_rank.next_at"));
    var board = try h.get("/api/leaderboard?board=contacts", &a);
    defer board.deinit();
    try testing.expectEqual(@as(usize, 1), try board.len("entries"));
    try testing.expectEqualStrings(if (won_first) "Hank" else "Zed", try board.str("entries.0.callsign"));
    try testing.expectEqual(@as(i64, 1), try board.int("entries.0.value"));
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

test "dev bot contact can stage a rogue with a chosen, mixed-rarity kit" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    try h.player("Lonely", "human", &a);
    var r = try h.ok("/api/dev/bot_contact", &a, "{{\"rarity\":\"rare\",\"as\":\"rogue\"}}", .{});
    r.deinit();
    var w = try h.location(&a, base_lat, base_lon);
    defer w.deinit();
    const ev = (try eventOfType(&w, "contact")) orelse return error.NoContactEvent;
    const battle = ev.object.get("battle").?.object;
    try testing.expectEqualStrings("echo", battle.get("kind").?.string);
    const foe = battle.get("b").?.object;
    try testing.expectEqualStrings("rogue", foe.get("kind").?.string);
    const gear = foe.get("gear_detail").?.array.items;
    try testing.expect(gear.len >= 1);
    try testing.expectEqualStrings("rare", gear[0].object.get("rarity").?.string);
    if (gear.len > 1) try testing.expectEqualStrings("uncommon", gear[1].object.get("rarity").?.string);
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

    // A simulated location cannot take ground.
    h.advance(60_000);
    var fake = try h.ok("/api/location", &a, "{{\"lat\":{d},\"lon\":{d},\"acc\":5,\"sanctuary\":false,\"mock\":true}}", .{ slat, slon });
    fake.deinit();
    var spoofed = try h.postf("/api/stronghold/claim", &a, "{{\"id\":\"{s}\"}}", .{sid});
    defer spoofed.deinit();
    try testing.expectEqualStrings("simulated_location", try spoofed.errorCode());

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
    // Every contributor takes exactly one note from the wreckage.
    try testing.expectEqual(@as(usize, 1), ev.object.get("rewards").?.object.get("notes").?.array.items.len);
    try testing.expectEqual(@as(?i64, 1), try h.ctx.db.scalar("SELECT COUNT(*) FROM player_notes WHERE player_id = ?", .{pa}));
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

// --- Accounts: guests, sign-in, linking, deletion ----------------------------------------------------

const fx = @import("jwt_fixture.zig");

/// A guest with no callsign (the new onboarding order): faction first, callsign later.
fn guest(h: *Harness, out: *[64]u8) !void {
    var r = try h.post("/api/register", null, "{\"terms\":1}");
    defer r.deinit();
    try testing.expectEqual(@as(u16, 200), r.status);
    @memcpy(out, try r.str("token"));
}

/// Turn on Google and Apple with the fixture signing key; the network is never touched.
fn withProviders(h: *Harness) !void {
    h.ctx.auth.config = .{ .google_client_ids = &.{ fx.web_client_id, "android.apps.googleusercontent.com" }, .apple_audiences = &.{ fx.apple_bundle, "com.outbreak.web" } };
    h.ctx.auth.fetch_enabled = false;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try h.ctx.auth.inject(arena.allocator(), .google, fx.jwks);
    try h.ctx.auth.inject(arena.allocator(), .apple, fx.jwks);
}

/// POST `{"id_token": ...}` expecting 200.
fn okToken(h: *Harness, path: []const u8, token: ?[]const u8, id_token: []const u8) !Res {
    const body = try std.fmt.allocPrint(testing.allocator, "{{\"id_token\":\"{s}\",\"terms\":1}}", .{id_token});
    defer testing.allocator.free(body);
    const r = try h.post(path, token, body);
    if (r.status != 200) std.debug.print("{s}: {d} {s}\n", .{ path, r.status, r.raw.json });
    try testing.expectEqual(@as(u16, 200), r.status);
    return r;
}

test "guest flow: no callsign needed, faction before or after it, callsign once" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var t: [64]u8 = undefined;
    try guest(&h, &t);

    var me = try h.get("/api/me", &t);
    defer me.deinit();
    try testing.expect((try me.at("callsign")) == .null);
    try testing.expect((try me.at("account.guest")).bool);
    try testing.expectEqual(@as(usize, 0), try me.len("account.providers"));
    try testing.expect((try me.at("account.email")) == .null);

    // Faction first; the game still waits for a callsign.
    var f = try h.ok("/api/faction", &t, "{{\"faction\":\"zombie\"}}", .{});
    f.deinit();
    var early = try h.post("/api/location", &t, "{\"lat\":1,\"lon\":2}");
    defer early.deinit();
    try testing.expectEqual(@as(u16, 409), early.status);
    try testing.expectEqualStrings("no_callsign", try early.errorCode());

    var bad = try h.post("/api/callsign", &t, "{\"callsign\":\"x\"}");
    defer bad.deinit();
    try testing.expectEqualStrings("callsign_invalid", try bad.errorCode());
    var c = try h.ok("/api/callsign", &t, "{{\"callsign\":\"Grey_Fox\"}}", .{});
    defer c.deinit();
    try testing.expectEqualStrings("Grey_Fox", try c.str("me.callsign"));
    var twice = try h.post("/api/callsign", &t, "{\"callsign\":\"Other\"}");
    defer twice.deinit();
    try testing.expectEqual(@as(u16, 409), twice.status);
    try testing.expectEqualStrings("callsign_set", try twice.errorCode());
    var w = try h.location(&t, base_lat, base_lon);
    w.deinit();

    // Taken names are refused for the next guest, case-insensitively; two callsign-less guests
    // never collide on the placeholder.
    var t2: [64]u8 = undefined;
    try guest(&h, &t2);
    var dup = try h.post("/api/callsign", &t2, "{\"callsign\":\"grey_fox\"}");
    defer dup.deinit();
    try testing.expectEqualStrings("callsign_taken", try dup.errorCode());
}

test "health advertises a self-hosted tile source only when one is configured" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var none = try h.get("/api/health", null);
    defer none.deinit();
    try testing.expect((try none.at("tiles")) == .null);

    var served: Harness = undefined;
    try served.init(.{ .tiles = .{ .file = "/data/region.pmtiles", .glyphs = "https://fonts.example/{fontstack}/{range}.pbf" } });
    defer served.deinit();
    var a = try served.get("/api/health", null);
    defer a.deinit();
    try testing.expectEqualStrings("/tiles/map.pmtiles", try a.str("tiles.pmtiles"));
    try testing.expectEqualStrings("https://fonts.example/{fontstack}/{range}.pbf", try a.str("tiles.glyphs"));

    var remote: Harness = undefined;
    try remote.init(.{ .tiles = .{ .url = "https://tiles.example.com/region.pmtiles" } });
    defer remote.deinit();
    var b = try remote.get("/api/health", null);
    defer b.deinit();
    try testing.expectEqualStrings("https://tiles.example.com/region.pmtiles", try b.str("tiles.pmtiles"));
    try testing.expect((try b.at("tiles.glyphs")) == .null);
}

test "health reports which providers are on; unconfigured ones answer 503" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var off = try h.get("/api/health", null);
    defer off.deinit();
    try testing.expect(!(try off.at("providers.google")).bool);
    try testing.expect(!(try off.at("providers.apple")).bool);
    try testing.expect(!(try off.at("providers.dev")).bool);
    var g = try h.post("/api/auth/google", null, "{\"id_token\":\"x.y.z\"}");
    defer g.deinit();
    try testing.expectEqual(@as(u16, 503), g.status);
    try testing.expectEqualStrings("provider_not_configured", try g.errorCode());
    // The dev provider does not exist on a production server.
    var d = try h.post("/api/auth/dev", null, "{\"subject\":\"x\",\"terms\":1}");
    defer d.deinit();
    try testing.expectEqual(@as(u16, 404), d.status);

    try withProviders(&h);
    var on = try h.get("/api/health", null);
    defer on.deinit();
    try testing.expect((try on.at("providers.google")).bool);
    try testing.expect((try on.at("providers.apple")).bool);
    try testing.expectEqualStrings(fx.web_client_id, try on.str("providers.google_web_client_id"));
    try testing.expectEqualStrings("com.outbreak.web", try on.str("providers.apple_web_service_id"));
}

test "Google sign-in: a new identity creates a player, the same identity returns it" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    try withProviders(&h);

    var first = try okToken(&h, "/api/auth/google", null, fx.google_1);
    defer first.deinit();
    try testing.expect((try first.at("created")).bool);
    try testing.expect((try first.at("me.callsign")) == .null);
    try testing.expect(!(try first.at("me.account.guest")).bool);
    try testing.expectEqualStrings("google", try first.str("me.account.providers.0"));
    try testing.expectEqualStrings("g-sub-1@example.com", try first.str("me.account.email"));
    const id = try testing.allocator.dupe(u8, try first.str("me.id"));
    defer testing.allocator.free(id);
    const old_token = try testing.allocator.dupe(u8, try first.str("token"));
    defer testing.allocator.free(old_token);

    // Another device signs in: same player, fresh token, the old one is retired.
    var again = try okToken(&h, "/api/auth/google", null, fx.google_https_iss);
    defer again.deinit();
    try testing.expect(!(try again.at("created")).bool);
    try testing.expectEqualStrings(id, try again.str("me.id"));
    var stale = try h.get("/api/me", old_token);
    defer stale.deinit();
    try testing.expectEqual(@as(u16, 401), stale.status);
    try testing.expectEqual(@as(?i64, 1), try h.ctx.db.scalar("SELECT COUNT(*) FROM players", .{}));
}

test "sign-in refuses bad tokens with explained errors" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    try withProviders(&h);
    const cases = [_]struct { token: []const u8, status: u16, code: []const u8 }{
        .{ .token = fx.google_expired, .status = 401, .code = "token_expired" },
        .{ .token = fx.google_wrong_aud, .status = 401, .code = "invalid_token" },
        .{ .token = fx.google_wrong_iss, .status = 401, .code = "invalid_token" },
        .{ .token = fx.google_bad_sig, .status = 401, .code = "invalid_token" },
        .{ .token = fx.google_tampered, .status = 401, .code = "invalid_token" },
        .{ .token = fx.google_unknown_kid, .status = 401, .code = "invalid_token" },
        .{ .token = "garbage", .status = 400, .code = "invalid_token" },
    };
    for (cases) |c| {
        var r = try h.postf("/api/auth/google", null, "{{\"id_token\":\"{s}\"}}", .{c.token});
        defer r.deinit();
        try testing.expectEqual(c.status, r.status);
        try testing.expectEqualStrings(c.code, try r.errorCode());
    }
    var missing = try h.post("/api/auth/google", null, "{}");
    defer missing.deinit();
    try testing.expectEqual(@as(u16, 400), missing.status);
    try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar("SELECT COUNT(*) FROM players", .{}));
}

test "Apple sign-in checks the nonce" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    try withProviders(&h);
    var wrong = try h.postf("/api/auth/apple", null, "{{\"id_token\":\"{s}\",\"nonce\":\"nope\"}}", .{fx.apple_1});
    defer wrong.deinit();
    try testing.expectEqual(@as(u16, 401), wrong.status);
    var ok = try h.postf("/api/auth/apple", null, "{{\"id_token\":\"{s}\",\"nonce\":\"{s}\",\"terms\":1}}", .{ fx.apple_1, fx.raw_nonce });
    defer ok.deinit();
    try testing.expectEqual(@as(u16, 200), ok.status);
    try testing.expect((try ok.at("created")).bool);
    try testing.expectEqualStrings("apple", try ok.str("me.account.providers.0"));
}

test "a guest links an identity and keeps its progress" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var t: [64]u8 = undefined;
    try guest(&h, &t);
    var f = try h.ok("/api/faction", &t, "{{\"faction\":\"human\"}}", .{});
    f.deinit();
    var c = try h.ok("/api/callsign", &t, "{{\"callsign\":\"Linker\"}}", .{});
    c.deinit();
    try h.reachLevel(&t, 3);

    var l = try h.ok("/api/auth/dev", &t, "{{\"subject\":\"dev-1\",\"terms\":1,\"email\":\"a@b.co\"}}", .{});
    defer l.deinit();
    try testing.expect(!(try l.at("created")).bool);
    try testing.expectEqualStrings("Linker", try l.str("me.callsign"));
    try testing.expectEqual(@as(i64, 3), try l.int("me.level"));
    try testing.expect(!(try l.at("me.account.guest")).bool);
    try testing.expectEqualStrings("a@b.co", try l.str("me.account.email"));

    // The new token works; a fresh sign-in on another device finds the same character.
    var me = try h.get("/api/me", try l.str("token"));
    defer me.deinit();
    try testing.expectEqualStrings("Linker", try me.str("callsign"));
    var other = try h.post("/api/auth/dev", null, "{\"subject\":\"dev-1\",\"terms\":1}");
    defer other.deinit();
    try testing.expectEqualStrings("Linker", try other.str("me.callsign"));
    try testing.expect(!(try other.at("created")).bool);
}

test "a guest with progress meets an identity that already has a character" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    // The existing character, reachable by sign-in.
    var existing = try h.post("/api/auth/dev", null, "{\"subject\":\"dev-9\",\"terms\":1}");
    defer existing.deinit();
    var et: [64]u8 = undefined;
    @memcpy(&et, try existing.str("token"));
    var ec = try h.ok("/api/callsign", &et, "{{\"callsign\":\"Veteran\"}}", .{});
    ec.deinit();
    var ef = try h.ok("/api/faction", &et, "{{\"faction\":\"zombie\"}}", .{});
    ef.deinit();

    // A new phone: a guest that has played.
    var g: [64]u8 = undefined;
    try guest(&h, &g);
    var gf = try h.ok("/api/faction", &g, "{{\"faction\":\"human\"}}", .{});
    gf.deinit();
    var gc = try h.ok("/api/callsign", &g, "{{\"callsign\":\"Newbie\"}}", .{});
    gc.deinit();

    var clash = try h.post("/api/auth/dev", &g, "{\"subject\":\"dev-9\",\"terms\":1}");
    defer clash.deinit();
    try testing.expectEqual(@as(u16, 409), clash.status);
    try testing.expectEqualStrings("identity_in_use", try clash.errorCode());
    try testing.expect((try clash.at("message")) == .string);
    // Nothing changed.
    try testing.expectEqual(@as(?i64, 2), try h.ctx.db.scalar("SELECT COUNT(*) FROM players", .{}));
    var still = try h.get("/api/me", &g);
    defer still.deinit();
    try testing.expectEqualStrings("Newbie", try still.str("callsign"));

    // The player agrees to switch: the guest is discarded.
    var sw = try h.ok("/api/auth/dev", &g, "{{\"subject\":\"dev-9\",\"terms\":1,\"switch\":true}}", .{});
    defer sw.deinit();
    try testing.expectEqualStrings("Veteran", try sw.str("me.callsign"));
    try testing.expect(!(try sw.at("created")).bool);
    try testing.expectEqual(@as(?i64, 1), try h.ctx.db.scalar("SELECT COUNT(*) FROM players", .{}));
    var gone = try h.get("/api/me", &g);
    defer gone.deinit();
    try testing.expectEqual(@as(u16, 401), gone.status);
}

test "a guest with no faction is discarded silently when it signs in to an existing identity" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var existing = try h.post("/api/auth/dev", null, "{\"subject\":\"dev-5\",\"terms\":1}");
    existing.deinit();
    var g: [64]u8 = undefined;
    try guest(&h, &g);
    var r = try h.ok("/api/auth/dev", &g, "{{\"subject\":\"dev-5\",\"terms\":1}}", .{});
    defer r.deinit();
    try testing.expect(!(try r.at("created")).bool);
    try testing.expectEqual(@as(?i64, 1), try h.ctx.db.scalar("SELECT COUNT(*) FROM players", .{}));
}

test "link and unlink: second provider, conflicts, never the last identity" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    try withProviders(&h);
    var a = try h.post("/api/auth/dev", null, "{\"subject\":\"dev-a\",\"terms\":1}");
    defer a.deinit();
    var at: [64]u8 = undefined;
    @memcpy(&at, try a.str("token"));

    var noauth = try h.post("/api/auth/link/google", null, "{}");
    defer noauth.deinit();
    try testing.expectEqual(@as(u16, 401), noauth.status);

    var lk = try okToken(&h, "/api/auth/link/google", &at, fx.google_1);
    defer lk.deinit();
    try testing.expectEqual(@as(usize, 2), try lk.len("me.account.providers"));
    // Linking the same identity again is harmless.
    var lk2 = try okToken(&h, "/api/auth/link/google", &at, fx.google_1);
    lk2.deinit();
    // A different Google account on the same player is refused.
    var second = try h.postf("/api/auth/link/google", &at, "{{\"id_token\":\"{s}\"}}", .{fx.google_2});
    defer second.deinit();
    try testing.expectEqualStrings("already_linked", try second.errorCode());

    // Another player cannot take that Google identity.
    var b = try h.post("/api/auth/dev", null, "{\"subject\":\"dev-b\",\"terms\":1}");
    defer b.deinit();
    var bt: [64]u8 = undefined;
    @memcpy(&bt, try b.str("token"));
    var taken = try h.postf("/api/auth/link/google", &bt, "{{\"id_token\":\"{s}\"}}", .{fx.google_1});
    defer taken.deinit();
    try testing.expectEqual(@as(u16, 409), taken.status);
    try testing.expectEqualStrings("identity_in_use", try taken.errorCode());

    var un = try h.ok("/api/auth/unlink/dev", &at, "{{}}", .{});
    defer un.deinit();
    try testing.expectEqual(@as(usize, 1), try un.len("me.account.providers"));
    var last = try h.post("/api/auth/unlink/google", &at, "{}");
    defer last.deinit();
    try testing.expectEqual(@as(u16, 409), last.status);
    try testing.expectEqualStrings("last_identity", try last.errorCode());
    var missing = try h.post("/api/auth/unlink/apple", &at, "{}");
    defer missing.deinit();
    try testing.expectEqualStrings("not_linked", try missing.errorCode());
}

test "deleting an account removes everything it owned and tidies the clan and chat" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    try h.player("Founder", "human", &a);
    try h.player("Second", "human", &b);
    for ([_][]const u8{ &a, &b }) |t| try h.reachLevel(t, 10);
    var gr = try h.ok("/api/dev/grant", &a, "{{\"salvage\":500}}", .{});
    gr.deinit();
    var made = try h.ok("/api/clans", &a, "{{\"name\":\"Last Light\",\"tag\":\"LL\"}}", .{});
    defer made.deinit();
    var joined = try h.ok("/api/clans/join", &b, "{{\"code\":\"{s}\"}}", .{try made.str("clan.code")});
    joined.deinit();
    var m = try h.ok("/api/clan/chat", &a, "{{\"text\":\"remember me\"}}", .{});
    m.deinit();
    // Some game state: a position, an event, war points, a contact record, an identity.
    var w = try h.location(&a, base_lat, base_lon);
    w.deinit();
    const pid = try h.playerId("Founder");
    try h.ctx.db.run("INSERT INTO events(player_id, at, type, text) VALUES(?, 1, 'x', 'y')", .{pid});
    try h.ctx.db.run("INSERT INTO contact_log(a, b, at) VALUES(?, 999, 1)", .{pid});
    try h.ctx.db.run("INSERT INTO war_player(week, player_id, district, points) VALUES(1, ?, 'd', 40)", .{pid});
    try h.ctx.db.run("INSERT INTO war_district(week, district, faction, points) VALUES(1, 'd', 0, 40)", .{});
    try h.ctx.db.run("INSERT INTO identities(provider, subject, player_id, created_at) VALUES('dev', 'founder', ?, 1)", .{pid});

    var del = try h.call("DELETE", "/api/account", &a, "");
    defer del.deinit();
    try testing.expectEqual(@as(u16, 200), del.status);

    const owned = [_][:0]const u8{
        "SELECT COUNT(*) FROM players WHERE id = ?",
        "SELECT COUNT(*) FROM items WHERE player_id = ?",
        "SELECT COUNT(*) FROM consumables WHERE player_id = ?",
        "SELECT COUNT(*) FROM buffs WHERE player_id = ?",
        "SELECT COUNT(*) FROM mission_progress WHERE player_id = ?",
        "SELECT COUNT(*) FROM events WHERE player_id = ?",
        "SELECT COUNT(*) FROM war_player WHERE player_id = ?",
        "SELECT COUNT(*) FROM raid_damage WHERE player_id = ?",
        "SELECT COUNT(*) FROM snapshots WHERE player_id = ?",
        "SELECT COUNT(*) FROM done WHERE player_id = ?",
        "SELECT COUNT(*) FROM identities WHERE player_id = ?",
        "SELECT COUNT(*) FROM clan_chat WHERE player_id = ?",
        "SELECT COUNT(*) FROM contact_log WHERE a = ? OR b = ?1",
    };
    for (owned) |sql| {
        const n = (try h.ctx.db.scalar(sql, .{pid})).?;
        if (n != 0) std.debug.print("rows left: {s}\n", .{sql});
        try testing.expectEqual(@as(i64, 0), n);
    }
    try testing.expect(h.ctx.live.position(pid, h.ctx.now()) == null);
    // Aggregate war totals stay; the chat line stays but is anonymous.
    try testing.expectEqual(@as(?i64, 1), try h.ctx.db.scalar("SELECT COUNT(*) FROM war_district", .{}));
    var chat = try h.get("/api/clan/chat", &b);
    defer chat.deinit();
    try testing.expectEqualStrings("[deleted]", try chat.str("messages.0.callsign"));
    try testing.expectEqualStrings("remember me", try chat.str("messages.0.text"));
    // Leadership passed to the other member.
    var clan = try h.get("/api/clan", &b);
    defer clan.deinit();
    try testing.expectEqual(@as(usize, 1), try clan.len("clan.members"));
    try testing.expectEqualStrings("leader", try clan.str("clan.members.0.role"));
    // The token and the callsign are free again.
    var gone = try h.get("/api/me", &a);
    defer gone.deinit();
    try testing.expectEqual(@as(u16, 401), gone.status);
    var reuse = try h.post("/api/register", null, "{\"callsign\":\"Founder\",\"terms\":1}");
    defer reuse.deinit();
    try testing.expectEqual(@as(u16, 200), reuse.status);

    // A sole clan member takes the clan with them.
    var del2 = try h.call("DELETE", "/api/account", &b, "");
    defer del2.deinit();
    try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar("SELECT COUNT(*) FROM clans", .{}));
    try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar("SELECT COUNT(*) FROM clan_chat", .{}));
}

test "deleting needs a token" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var r = try h.call("DELETE", "/api/account", null, "");
    defer r.deinit();
    try testing.expectEqual(@as(u16, 401), r.status);
}

// --- Real places, stances, day and night -------------------------------------------------------------------

/// POST /api/location with a `places` array (raw JSON text).
fn locationWith(h: *Harness, token: []const u8, lat: f64, lon: f64, places: []const u8) !Res {
    return h.ok("/api/location", token, "{{\"lat\":{d},\"lon\":{d},\"acc\":5,\"sanctuary\":false,\"places\":{s}}}", .{ lat, lon, places });
}

/// `{key, kind, lat, lon, name}` for a place `north_m` metres north of the base point.
fn placeJson(buf: []u8, key: []const u8, kind: []const u8, north_m: f64, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{{\"key\":\"{s}\",\"kind\":\"{s}\",\"lat\":{d},\"lon\":{d},\"name\":\"{s}\"}}", .{ key, kind, base_lat + north_m / 111_320.0, base_lon, name });
}

fn landmarkIn(w: *const Res, kind: []const u8) !?std.json.ObjectMap {
    for ((try w.at("landmarks")).array.items) |l| {
        if (std.mem.eql(u8, l.object.get("kind").?.string, kind)) return l.object;
    }
    return null;
}

test "landmarks: reported places become caches once per window, with rolls and the cache XP" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Looter", "human", &tok);

    var b1: [200]u8 = undefined;
    var b2: [200]u8 = undefined;
    var b3: [200]u8 = undefined;
    const arr = try std.fmt.allocPrint(testing.allocator, "[{s},{s},{s}]", .{
        try placeJson(&b1, "n1001", "pharmacy", 15, "Duane   Reade <b>"),
        try placeJson(&b2, "n1002", "diner", 200, "Joe's"),
        try placeJson(&b3, "n1003", "hospital", 10, "St. Mary's"),
    });
    defer testing.allocator.free(arr);

    var w = try locationWith(&h, &tok, base_lat, base_lon, arr);
    defer w.deinit();
    // The hospital is not a kind at all (a sanctuary); the others are listed with sanitized names.
    try testing.expectEqual(@as(usize, 2), try w.len("landmarks"));
    const ph = (try landmarkIn(&w, "pharmacy")).?;
    try testing.expectEqualStrings("Duane Reade b", ph.get("name").?.string);
    try testing.expect(ph.get("available").?.bool);
    try testing.expect(ph.get("available_at").? == .null);
    const window = @divFloor(h.ctx.now(), game.landmarks.window_ms);
    const want_id = try std.fmt.allocPrint(testing.allocator, "l.n1001.{d}", .{window});
    defer testing.allocator.free(want_id);
    try testing.expectEqualStrings(want_id, ph.get("id").?.string);
    try testing.expectEqualStrings(want_id, (try landmarkIn(&w, "pharmacy")).?.get("id").?.string);

    // 200 m away: listed, but not in reach.
    const far = (try landmarkIn(&w, "diner")).?;
    var too_far = try h.postf("/api/open", &tok, "{{\"id\":\"{s}\"}}", .{far.get("id").?.string});
    defer too_far.deinit();
    try testing.expectEqual(@as(u16, 409), too_far.status);
    try testing.expectEqualStrings("too_far", try too_far.errorCode());

    // Open the pharmacy: two rolls, +25% salvage per roll, plus the cache XP; it counts as a cache.
    var o = try h.ok("/api/open", &tok, "{{\"id\":\"{s}\"}}", .{want_id});
    defer o.deinit();
    const rolls = try o.len("loot.items") + blk: {
        var n: i64 = 0;
        var it = (try o.at("loot.consumables")).object.iterator();
        while (it.next()) |e| n += e.value_ptr.integer;
        break :blk @as(usize, @intCast(n));
    };
    try testing.expectEqual(@as(usize, 2), rolls);
    const salvage_each: i64 = @intFromFloat(@round(@as(f32, @floatFromInt(game.loot.pveSalvage(1))) * 1.25));
    try testing.expectEqual(2 * salvage_each, try o.int("loot.salvage") - try o.int("loot.auto_scrapped"));
    try testing.expectEqual(@as(i64, game.progression.cacheXp(1)), try o.int("loot.xp"));
    try testing.expectEqual(@as(i64, 1), try o.int("me.record.caches"));

    // Not twice in one window; the map shows when it restocks.
    var again = try h.postf("/api/open", &tok, "{{\"id\":\"{s}\"}}", .{want_id});
    defer again.deinit();
    try testing.expectEqual(@as(u16, 409), again.status);
    try testing.expectEqualStrings("already_opened", try again.errorCode());
    h.advance(5000);
    var w2 = try locationWith(&h, &tok, base_lat, base_lon, arr);
    defer w2.deinit();
    const used = (try landmarkIn(&w2, "pharmacy")).?;
    try testing.expect(!used.get("available").?.bool);
    try testing.expectEqual(game.landmarks.nextWindowAt(h.ctx.now()), used.get("available_at").?.integer);

    // An id from an old window or for an unknown place does not validate.
    const stale = try std.fmt.allocPrint(testing.allocator, "l.n1001.{d}", .{window - 1});
    defer testing.allocator.free(stale);
    var bad1 = try h.postf("/api/open", &tok, "{{\"id\":\"{s}\"}}", .{stale});
    defer bad1.deinit();
    try testing.expectEqual(@as(u16, 404), bad1.status);
    var bad2 = try h.postf("/api/open", &tok, "{{\"id\":\"l.nope.{d}\"}}", .{window});
    defer bad2.deinit();
    try testing.expectEqual(@as(u16, 404), bad2.status);

    // Four hours on it is stocked again (the new window's id).
    h.advance(game.landmarks.window_ms);
    var w3 = try locationWith(&h, &tok, base_lat, base_lon, arr);
    defer w3.deinit();
    const fresh = (try landmarkIn(&w3, "pharmacy")).?;
    try testing.expect(fresh.get("available").?.bool);
    try testing.expect(!std.mem.eql(u8, fresh.get("id").?.string, want_id));
    var o2 = try h.ok("/api/open", &tok, "{{\"id\":\"{s}\"}}", .{fresh.get("id").?.string});
    o2.deinit();
}

test "landmarks: validation is loose but bounded; places belong to who reported them" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    var z: [64]u8 = undefined;
    try h.player("Mapper", "human", &a);
    try h.player("Other", "zombie", &z);

    var bufs: [6][200]u8 = undefined;
    // 449 m is in, 500 m is out; unknown kinds, bad keys and bad coordinates are skipped.
    const arr = try std.fmt.allocPrint(testing.allocator, "[{s},{s},{s},{s},{s}]", .{
        try placeJson(&bufs[0], "ok1", "fuel", 380, "Shell"),
        try placeJson(&bufs[1], "far1", "fuel", 500, "Too far"),
        try placeJson(&bufs[2], "sch1", "school", 20, "School"),
        try placeJson(&bufs[3], "bad.key", "fuel", 20, "Dotted"),
        "{\"key\":\"nan1\",\"kind\":\"fuel\",\"lat\":999,\"lon\":0}",
    });
    defer testing.allocator.free(arr);
    var w = try locationWith(&h, &a, base_lat, base_lon, arr);
    defer w.deinit();
    try testing.expectEqual(@as(usize, 1), try w.len("landmarks"));
    try testing.expectEqualStrings("fuel", try w.str("landmarks.0.kind"));

    // Another player does not see Mapper's places until their own map reports them too.
    var wz = try h.location(&z, base_lat, base_lon);
    defer wz.deinit();
    try testing.expectEqual(@as(usize, 0), try wz.len("landmarks"));
    var wz2 = try locationWith(&h, &z, base_lat, base_lon, arr);
    defer wz2.deinit();
    try testing.expectEqual(@as(usize, 1), try wz2.len("landmarks"));
    // The zombie sees the same landmark under its own name for the kind (the id is shared).
    try testing.expectEqualStrings(try w.str("landmarks.0.id"), try wz2.str("landmarks.0.id"));

    // The same key reported somewhere else does not move the landmark.
    var moved: [200]u8 = undefined;
    const moved_arr = try std.fmt.allocPrint(testing.allocator, "[{s}]", .{try placeJson(&moved, "ok1", "fuel", 300, "Shell")});
    defer testing.allocator.free(moved_arr);
    h.advance(5000);
    var wm = try locationWith(&h, &z, base_lat, base_lon, moved_arr);
    defer wm.deinit();
    try testing.expectEqual(@as(usize, 1), try wm.len("landmarks"));
    const lat0 = try wm.at("landmarks.0");
    try testing.expect(@abs(lat0.object.get("lat").?.float - (base_lat + 380.0 / 111_320.0)) < 1e-6);

    // More than 40 places in one report: the first 40 are used, the request still works.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    try big.append(testing.allocator, '[');
    for (0..60) |i| {
        if (i > 0) try big.append(testing.allocator, ',');
        var item: [200]u8 = undefined;
        var key: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&key, "bulk{d}", .{i});
        try big.appendSlice(testing.allocator, try placeJson(&item, k, "diner", 10 + @as(f64, @floatFromInt(i)), "Diner"));
    }
    try big.append(testing.allocator, ']');
    h.advance(5000);
    var wb = try locationWith(&h, &a, base_lat, base_lon, big.items);
    defer wb.deinit();
    // 40 reported now, plus Mapper's earlier fuel stop still fresh.
    try testing.expectEqual(@as(usize, 40), try wb.len("landmarks"));

    // No landmarks are served (or remembered) from a sanctuary.
    var ws = try h.ok("/api/location", &a, "{{\"lat\":{d},\"lon\":{d},\"acc\":5,\"sanctuary\":true,\"places\":{s}}}", .{ base_lat, base_lon, arr });
    defer ws.deinit();
    try testing.expectEqual(@as(usize, 0), try ws.len("landmarks"));
    var open_in = try h.postf("/api/open", &a, "{{\"id\":\"l.ok1.{d}\"}}", .{@divFloor(h.ctx.now(), game.landmarks.window_ms)});
    defer open_in.deinit();
    try testing.expectEqualStrings("sanctuary", try open_in.errorCode());
}

test "landmarks: at most six caches per half hour, with a clear reason" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Greedy", "zombie", &tok);

    var arr: std.ArrayList(u8) = .empty;
    defer arr.deinit(testing.allocator);
    try arr.append(testing.allocator, '[');
    const kinds = [_][]const u8{ "pharmacy", "grocery", "hardware", "fuel", "police", "outfitter", "diner" };
    for (kinds, 0..) |k, i| {
        if (i > 0) try arr.append(testing.allocator, ',');
        var item: [200]u8 = undefined;
        var key: [16]u8 = undefined;
        const key_s = try std.fmt.bufPrint(&key, "k{d}", .{i});
        try arr.appendSlice(testing.allocator, try placeJson(&item, key_s, k, 5 + @as(f64, @floatFromInt(i)), ""));
    }
    try arr.append(testing.allocator, ']');

    var w = try locationWith(&h, &tok, base_lat, base_lon, arr.items);
    w.deinit();
    const window = @divFloor(h.ctx.now(), game.landmarks.window_ms);
    for (0..6) |i| {
        var r = try h.ok("/api/open", &tok, "{{\"id\":\"l.k{d}.{d}\"}}", .{ i, window });
        r.deinit();
        h.advance(1000);
    }
    var seventh = try h.postf("/api/open", &tok, "{{\"id\":\"l.k6.{d}\"}}", .{window});
    defer seventh.deinit();
    try testing.expectEqual(@as(u16, 409), seventh.status);
    try testing.expectEqualStrings("landmark_limit", try seventh.errorCode());
    try testing.expect(std.mem.indexOf(u8, try seventh.str("message"), "Try again in") != null);
    // A refused attempt did not use the place up.
    h.advance(game.landmarks.limit_window_ms - 6000 + 1);
    var w2 = try locationWith(&h, &tok, base_lat, base_lon, arr.items);
    w2.deinit();
    var ok7 = try h.ok("/api/open", &tok, "{{\"id\":\"l.k6.{d}\"}}", .{window});
    ok7.deinit();
    // And the window of six slides: the second-oldest opening frees the next one.
    var eighth = try h.postf("/api/open", &tok, "{{\"id\":\"l.k0.{d}\"}}", .{window});
    defer eighth.deinit();
    try testing.expectEqual(@as(u16, 409), eighth.status);
}

test "stance: default careful, validated, shown in the battle, and the hint counts are tracked" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Stancer", "human", &tok);

    var me0 = try h.get("/api/me", &tok);
    defer me0.deinit();
    try testing.expectEqualStrings("careful", try me0.str("stance"));
    try testing.expectEqual(@as(i64, 0), try me0.int("bestiary.runner"));
    try testing.expect((try me0.at("bestiary")).object.get("abomination") == null);

    var set = try h.ok("/api/stance", &tok, "{{\"stance\":\"evasive\"}}", .{});
    defer set.deinit();
    try testing.expectEqualStrings("evasive", try set.str("me.stance"));
    var bad = try h.post("/api/stance", &tok, "{\"stance\":\"berserk\"}");
    defer bad.deinit();
    try testing.expectEqual(@as(u16, 400), bad.status);
    var set2 = try h.ok("/api/stance", &tok, "{{\"stance\":\"careful\"}}", .{});
    set2.deinit();

    const en = findEnemy(h.ctx.seed, h.ctx.now());
    const id = en.id();
    var w = try h.location(&tok, en.lat, en.lon);
    w.deinit();
    var badreq = try h.postf("/api/engage", &tok, "{{\"id\":\"{s}\",\"stance\":\"nope\"}}", .{id.str()});
    defer badreq.deinit();
    try testing.expectEqual(@as(u16, 400), badreq.status);

    // Evasive costs 10% of the HP pool for the fight; the battle says which stance it was.
    var b = try h.ok("/api/engage", &tok, "{{\"id\":\"{s}\",\"stance\":\"evasive\"}}", .{id.str()});
    defer b.deinit();
    try testing.expectEqualStrings("evasive", try b.str("stance"));
    const real_max = try b.int("me.max_hp");
    try testing.expectEqual(@as(i64, @intFromFloat(@round(@as(f64, @floatFromInt(real_max)) * 0.9))), try b.int("a.max_hp"));
    // HP afterwards is on the real scale, never above the real pool.
    try testing.expect(try b.int("me.hp") <= real_max);
    var path_buf: [48]u8 = undefined;
    try testing.expectEqual(@as(i64, 1), try b.int(try std.fmt.bufPrint(&path_buf, "me.bestiary.{s}", .{@tagName(en.archetype)})));
}

test "stance: the default is careful when the request says nothing, and counters change the fight" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Plain", "human", &tok);
    const en = findEnemy(h.ctx.seed, h.ctx.now());
    var w = try h.location(&tok, en.lat, en.lon);
    w.deinit();
    var b = try h.ok("/api/engage", &tok, "{{\"id\":\"{s}\"}}", .{en.id().str()});
    defer b.deinit();
    try testing.expectEqualStrings("careful", try b.str("stance"));
    // Careful: +25% DEF (and +10% by day for a Human), -8% ATK on the shown totals.
    var me = try h.get("/api/me", &tok);
    defer me.deinit();
    const base_atk: f64 = @floatFromInt(try me.int("stats.atk"));
    const base_def: f64 = @floatFromInt(try me.int("stats.def"));
    try testing.expectEqual(@as(i64, @intFromFloat(@round(base_atk * 0.92))), try b.int("a.stats.atk"));
    try testing.expectEqual(@as(i64, @intFromFloat(@round(base_def * 1.35))), try b.int("a.stats.def"));
}

test "stance: Contact fights use each player's saved default" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    var z: [64]u8 = undefined;
    try h.player("Hank", "human", &a);
    try h.player("Zed", "zombie", &z);
    try h.reachLevel(&a, 6);
    try h.reachLevel(&z, 7);
    var s = try h.ok("/api/stance", &a, "{{\"stance\":\"aggressive\"}}", .{});
    s.deinit();
    try placePair(&h, &a, &z, 30);
    tick.runLocked(&h.ctx, h.ctx.now());
    var wa = try h.location(&a, base_lat, base_lon);
    defer wa.deinit();
    var wz = try h.location(&z, base_lat + 30.0 / 111_320.0, base_lon);
    defer wz.deinit();
    const ea = (try eventOfType(&wa, "contact")) orelse return error.NoContactEvent;
    const ez = (try eventOfType(&wz, "contact")) orelse return error.NoContactEvent;
    try testing.expectEqualStrings("aggressive", ea.object.get("battle").?.object.get("stance").?.string);
    try testing.expectEqualStrings("careful", ez.object.get("battle").?.object.get("stance").?.string);
}

test "day and night: WorldView carries the phase and the next change, by the player's longitude" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Clock", "human", &tok);
    // Wednesday noon UTC: noon at Greenwich, midnight on the antimeridian.
    var w0 = try h.location(&tok, 51.5, 0.0);
    defer w0.deinit();
    try testing.expectEqualStrings("day", try w0.str("time.phase"));
    try testing.expectEqual(wednesday + 8 * 3600_000, try w0.int("time.changes_at"));
    h.advance(10_000);
    var w1 = try h.location(&tok, 51.5, 179.9);
    defer w1.deinit();
    // Not a walkable jump, so the position stays at the old fix and the phase with it.
    try testing.expectEqualStrings("day", try w1.str("time.phase"));
    // A second player teleports freely on a fresh fix.
    var t2: [64]u8 = undefined;
    try h.player("Antipode", "zombie", &t2);
    var w2 = try h.location(&t2, 51.5, 179.9);
    defer w2.deinit();
    try testing.expectEqualStrings("night", try w2.str("time.phase"));
    // 179.9 E is 11.99 h ahead: 23:59 local, dawn in about 6 h.
    const to_dawn = try w2.int("time.changes_at") - h.ctx.now();
    try testing.expect(to_dawn > 6 * 3600_000 and to_dawn < 6 * 3600_000 + 10 * 60_000);

    // Exactly 20:00 at Greenwich is night, the millisecond before is day.
    var t3: [64]u8 = undefined;
    try h.player("Dusk", "human", &t3);
    h.ctx.clock_ms = wednesday + 8 * 3600_000 - 1;
    var d1 = try h.location(&t3, 51.5, 0.0);
    defer d1.deinit();
    try testing.expectEqualStrings("day", try d1.str("time.phase"));
    h.advance(1);
    var d2 = try h.location(&t3, 51.5, 0.0);
    defer d2.deinit();
    try testing.expectEqualStrings("night", try d2.str("time.phase"));
    // 06:00 is day again.
    h.ctx.clock_ms = wednesday + 18 * 3600_000 - 1; // 05:59:59.999
    var d3 = try h.location(&t3, 51.5, 0.0);
    defer d3.deinit();
    try testing.expectEqualStrings("night", try d3.str("time.phase"));
    h.advance(1);
    var d4 = try h.location(&t3, 51.5, 0.0);
    defer d4.deinit();
    try testing.expectEqualStrings("day", try d4.str("time.phase"));
}

/// An enemy cell near (lat, lon) whose night extra exists.
fn findNightExtra(seed: u64, now: i64, lat: f64, lon: f64) spawns.Enemy {
    var cell = geo.encode(lat, lon, 7);
    const window = spawns.windowIndex(now, spawns.enemy_window_ms);
    while (true) {
        if (spawns.enemy(seed, cell, window, spawns.night_extra_idx)) |e| {
            if (e.visibleTo(1)) return e;
        }
        cell = geo.neighbors(cell)[2].?;
    }
}

fn enemyIdsIn(w: *const Res, id: []const u8) !bool {
    for ((try w.at("enemies")).array.items) |e| {
        if (std.mem.eql(u8, e.object.get("id").?.string, id)) return true;
    }
    return false;
}

test "night: Humans meet an extra spawn and tougher enemies, Zombies and daytime Humans do not" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var hu: [64]u8 = undefined;
    var zo: [64]u8 = undefined;
    try h.player("Hum", "human", &hu);
    try h.player("Zom", "zombie", &zo);
    // 170 E at 12:00 UTC is 23:20 local: night.
    const lat0 = 40.0;
    const lon0 = 170.0;
    const extra = findNightExtra(h.ctx.seed, h.ctx.now(), lat0, lon0);
    const id = extra.id();
    var wh = try h.location(&hu, extra.lat, extra.lon);
    defer wh.deinit();
    try testing.expectEqualStrings("night", try wh.str("time.phase"));
    try testing.expect(try enemyIdsIn(&wh, id.str()));
    var wz = try h.location(&zo, extra.lat, extra.lon);
    defer wz.deinit();
    try testing.expect(!try enemyIdsIn(&wz, id.str()));
    var zeng = try h.postf("/api/engage", &zo, "{{\"id\":\"{s}\"}}", .{id.str()});
    defer zeng.deinit();
    try testing.expectEqual(@as(u16, 404), zeng.status);

    // The Human fights it at +10% HP/ATK/DEF (level 1 grace factor on top) and earns +15% XP.
    var b = try h.ok("/api/engage", &hu, "{{\"id\":\"{s}\"}}", .{id.str()});
    defer b.deinit();
    const lvl: u32 = @intCast(try b.int("b.level"));
    const want = game.stats.enemyStatsScaled(extra.archetype, lvl, game.stats.graceFactor(1) * 1.10);
    try testing.expectEqual(@as(i64, want.hp), try b.int("b.max_hp"));
    try testing.expectEqual(@as(i64, want.atk), try b.int("b.stats.atk"));
    const row = game.data.archetype(extra.archetype);
    const base_xp = game.progression.pveWinXp(lvl, .normal, row.reward_mult);
    const win_xp: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(base_xp)) * 1.15));
    const expect_xp = if (std.mem.eql(u8, try b.str("winner"), "a")) win_xp else game.progression.pveLossXp(win_xp);
    // A first win also lands a level or two of walking-free XP: only XP from the fight is in rewards.
    try testing.expectEqual(@as(i64, expect_xp), try b.int("rewards.xp"));

    // By day (twelve hours on: 11:20 local) the extra is gone for Humans too.
    h.advance(12 * 3600_000);
    var wd = try h.location(&hu, extra.lat, extra.lon);
    defer wd.deinit();
    try testing.expectEqualStrings("day", try wd.str("time.phase"));
    try testing.expect(!try enemyIdsIn(&wd, id.str()));
}

test "day: Zombies earn +15% PvE XP, and the same enemy is softer for a Human than at night" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var zo: [64]u8 = undefined;
    try h.player("Zom", "zombie", &zo);
    // New York at noon UTC is 07:00 local: day.
    const en = findEnemy(h.ctx.seed, h.ctx.now());
    var w = try h.location(&zo, en.lat, en.lon);
    defer w.deinit();
    try testing.expectEqualStrings("day", try w.str("time.phase"));
    var b = try h.ok("/api/engage", &zo, "{{\"id\":\"{s}\"}}", .{en.id().str()});
    defer b.deinit();
    const lvl: u32 = @intCast(try b.int("b.level"));
    const want = game.stats.enemyStatsScaled(en.archetype, lvl, game.stats.graceFactor(1));
    // Zombies are never hit by the night bonus, and the day does not soften enemies.
    try testing.expectEqual(@as(i64, want.hp), try b.int("b.max_hp"));
    const row = game.data.archetype(en.archetype);
    const base_xp = game.progression.pveWinXp(lvl, .normal, row.reward_mult);
    const win_xp: f32 = @as(f32, @floatFromInt(base_xp)) * 1.15;
    const won = std.mem.eql(u8, try b.str("winner"), "a");
    const expect_xp: u32 = if (won) @intFromFloat(@round(win_xp)) else game.progression.pveLossXp(@intFromFloat(@round(win_xp)));
    // The underdog bonus can add to a Zombie's XP when Humans outnumber Zombies; allow for it.
    const got: u32 = @intCast(try b.int("rewards.xp"));
    try testing.expect(got >= expect_xp and got <= expect_xp * 5 / 4 + 1);
}

// --- Patrol ------------------------------------------------------------------------------------------------

fn patrol(h: *Harness, token: []const u8, lat: f64, lon: f64) !Res {
    return h.ok("/api/patrol", token, "{{\"lat\":{d},\"lon\":{d},\"acc\":20}}", .{ lat, lon });
}

test "patrol: a check-in answers with events, hp and downed_until only, and needs a faction" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    try h.player("Walker", "human", &a);

    var r = try patrol(&h, &a, base_lat, base_lon);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.root().object.count());
    try testing.expectEqual(@as(usize, 0), try r.len("events"));
    try testing.expect(try r.int("hp") > 0);
    try testing.expect((try r.at("downed_until")) == .null);
    const pid = try h.playerId("Walker");
    try testing.expect(h.ctx.live.position(pid, h.ctx.now()).?.source == .patrol);

    var bad = try h.post("/api/patrol", &a, "{\"lat\":91,\"lon\":0}");
    defer bad.deinit();
    try testing.expectEqual(@as(u16, 400), bad.status);
    var nobody = try h.post("/api/patrol", null, "{\"lat\":1,\"lon\":2}");
    defer nobody.deinit();
    try testing.expectEqual(@as(u16, 401), nobody.status);
}

test "patrol: a check-in keeps a player live for four minutes; a jump is refused" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    try h.player("Walker", "human", &a);
    const pid = try h.playerId("Walker");

    var r = try patrol(&h, &a, base_lat, base_lon);
    r.deinit();
    h.advance(live.position_ttl_ms + 1000);
    try testing.expect(h.ctx.live.position(pid, h.ctx.now()) != null);
    h.advance(live.patrol_ttl_ms - live.position_ttl_ms - 1000);
    try testing.expect(h.ctx.live.position(pid, h.ctx.now()) != null);
    h.advance(1);
    try testing.expect(h.ctx.live.position(pid, h.ctx.now()) == null);

    // A fresh foreground fix has the short life again.
    var w = try h.location(&a, base_lat, base_lon);
    w.deinit();
    try testing.expect(h.ctx.live.position(pid, h.ctx.now()).?.source == .foreground);

    // An impossible jump keeps the old position.
    h.advance(60_000);
    var j = try patrol(&h, &a, base_lat + 0.5, base_lon);
    j.deinit();
    const pos = h.ctx.live.position(pid, h.ctx.now()).?;
    try testing.expect(@abs(pos.lat - base_lat) < 0.001);
}

test "patrol: walking is paid over a one minute cadence" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    try h.player("Walker", "human", &a);
    const pid = try h.playerId("Walker");

    var r = try patrol(&h, &a, base_lat, base_lon);
    r.deinit();
    // 80 m in 60 s is a walk.
    for (1..4) |i| {
        h.advance(60_000);
        var s = try patrol(&h, &a, base_lat + @as(f64, @floatFromInt(i)) * 80.0 / 111_320.0, base_lon);
        s.deinit();
    }
    const walked = (try h.ctx.db.scalar("SELECT distance_m FROM players WHERE id = ?", .{pid})).?;
    try testing.expect(walked >= 200);
}

test "patrol: a foreground and a patrol player fight; patrol notifies, the app still delivers" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    var z: [64]u8 = undefined;
    try h.player("Hank", "human", &a);
    try h.player("Zed", "zombie", &z);
    try h.reachLevel(&a, 6);
    try h.reachLevel(&z, 7);

    // Hank is out on patrol; Zed has the app open. Three minutes pass, then Zed's next fix arrives.
    var p0 = try patrol(&h, &a, base_lat, base_lon);
    p0.deinit();
    h.advance(3 * 60 * 1000);
    var wz = try h.location(&z, base_lat + 30.0 / 111_320.0, base_lon);
    defer wz.deinit();
    tick.runLocked(&h.ctx, h.ctx.now());
    try testing.expectEqual(@as(?i64, 1), try h.ctx.db.scalar("SELECT COUNT(*) FROM contact_log", .{}));
    try testing.expect((try eventOfType(&wz, "contact")) == null); // Zed's fix came before the fight

    // The patrol check-in carries a plain notice: no Battle, no Rewards.
    var p1 = try patrol(&h, &a, base_lat, base_lon);
    defer p1.deinit();
    try testing.expectEqual(@as(usize, 1), try p1.len("events"));
    const notice = (try eventOfType(&p1, "contact")).?.object;
    try testing.expectEqual(@as(usize, 4), notice.count());
    try testing.expect(std.mem.startsWith(u8, notice.get("text").?.string, "CONTACT. A Zombie, level 7."));
    try testing.expect(notice.get("battle") == null and notice.get("rewards") == null);
    // XP, HP and loot applied as in any Contact.
    const pid = try h.playerId("Hank");
    try testing.expectEqual(@as(?i64, 1), try h.ctx.db.scalar("SELECT contacts FROM players WHERE id = ?", .{pid}));

    // Notified once.
    var p2 = try patrol(&h, &a, base_lat, base_lon);
    defer p2.deinit();
    try testing.expectEqual(@as(usize, 0), try p2.len("events"));
    try testing.expectEqual(@as(?i64, 1), try h.ctx.db.scalar("SELECT COUNT(*) FROM events WHERE player_id = ? AND type = 'contact' AND notified = 1 AND delivered = 0", .{pid}));

    // Opening the app still delivers it, with the full Battle, exactly once.
    var wa = try h.location(&a, base_lat, base_lon);
    defer wa.deinit();
    const full = (try eventOfType(&wa, "contact")).?.object;
    try testing.expectEqualStrings("pvp", full.get("battle").?.object.get("kind").?.string);
    try testing.expect(full.get("rewards").?.object.get("xp").?.integer > 0);
    try testing.expectEqualStrings(notice.get("id").?.string, full.get("id").?.string);
    var wa2 = try h.location(&a, base_lat, base_lon);
    defer wa2.deinit();
    try testing.expect((try eventOfType(&wa2, "contact")) == null);
    try testing.expectEqual(@as(?i64, 1), try h.ctx.db.scalar("SELECT COUNT(*) FROM events WHERE player_id = ? AND type = 'contact' AND notified = 1 AND delivered = 1", .{pid}));
}

test "patrol: events seen in the app are not notified afterwards" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    try h.player("Hank", "human", &a);
    var w0 = try h.location(&a, base_lat, base_lon);
    w0.deinit();
    var r = try h.ok("/api/dev/bot_contact", &a, "{{}}", .{});
    r.deinit();
    var w = try h.location(&a, base_lat, base_lon);
    defer w.deinit();
    try testing.expect((try eventOfType(&w, "contact")) != null);
    var p = try patrol(&h, &a, base_lat, base_lon);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), try p.len("events"));
}

// --- Notes (docs/LORE.md) -------------------------------------------------------------------------

fn noteSet(notes: *const Res, id: []const u8) !?std.json.ObjectMap {
    for ((try notes.at("sets")).array.items) |x| {
        if (std.mem.eql(u8, x.object.get("id").?.string, id)) return x.object;
    }
    return null;
}

test "notes: First Blood always leaves Dale's last text, readable in the archive" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Rookie", "human", &tok);
    const pid = try h.playerId("Rookie");

    var before = try h.get("/api/notes", &tok);
    defer before.deinit();
    try testing.expectEqual(@as(i64, 0), (try noteSet(&before, "lantern")).?.get("found").?.integer);

    var w = try h.location(&tok, base_lat, base_lon);
    defer w.deinit();
    const tid = try std.fmt.allocPrint(testing.allocator, "t.{d}", .{pid});
    defer testing.allocator.free(tid);
    var b = try h.ok("/api/engage", &tok, "{{\"id\":\"{s}\"}}", .{tid});
    defer b.deinit();
    try testing.expectEqual(@as(usize, 1), try b.len("rewards.notes"));
    try testing.expectEqualStrings("starlite.04", try b.str("rewards.notes.0.id"));
    try testing.expectEqualStrings("Dale's Last Text", try b.str("rewards.notes.0.title"));
    try testing.expectEqualStrings("starlite", try b.str("rewards.notes.0.set"));
    try testing.expectEqual(@as(i64, 1), try b.int("me.notes.found"));
    try testing.expectEqual(@as(i64, 52), try b.int("me.notes.total"));

    var arch = try h.get("/api/notes", &tok);
    defer arch.deinit();
    var held: usize = 0;
    for ((try arch.at("notes")).array.items) |n| {
        if (n.object.get("locked").?.bool) {
            // Locked notes are silhouettes: set and rarity, no text.
            try testing.expect(n.object.get("body").? == .null);
            try testing.expect(n.object.get("title").? == .null);
        } else {
            held += 1;
            try testing.expectEqualStrings("starlite.04", n.object.get("id").?.string);
            try testing.expect(std.mem.indexOf(u8, n.object.get("body").?.string, "everybody smells so good") != null);
            try testing.expect(n.object.get("found_at").?.integer > 0);
        }
    }
    try testing.expectEqual(@as(usize, 1), held);
    try testing.expectEqual(@as(i64, 1), (try noteSet(&arch, "starlite")).?.get("found").?.integer);
}

test "notes: each faction sees only its own sets, Patient Zero stays sealed, nothing duplicates" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var hu: [64]u8 = undefined;
    var zo: [64]u8 = undefined;
    try h.player("Living", "human", &hu);
    try h.player("Turned", "zombie", &zo);

    var a = try h.get("/api/notes", &hu);
    defer a.deinit();
    var z = try h.get("/api/notes", &zo);
    defer z.deinit();
    try testing.expect((try noteSet(&a, "survey")) != null);
    try testing.expect((try noteSet(&a, "hunger")) == null);
    try testing.expect((try noteSet(&z, "hunger")) != null);
    try testing.expect((try noteSet(&z, "survey")) == null);
    try testing.expectEqual(@as(usize, 7), try a.len("sets"));
    try testing.expectEqualStrings("???", (try noteSet(&a, "zero")).?.get("name").?.string);
    for ((try z.at("notes")).array.items) |n| try testing.expect(!std.mem.startsWith(u8, n.object.get("id").?.string, "survey"));

    // Granting one note twice holds it once.
    for (0..2) |_| {
        var g = try h.ok("/api/dev/grant", &hu, "{{\"note\":\"survey.03\"}}", .{});
        try testing.expectEqual(@as(i64, 1), try g.int("me.notes.found"));
        g.deinit();
    }
    var bad = try h.post("/api/dev/grant", &hu, "{\"note\":\"nope.99\"}");
    defer bad.deinit();
    try testing.expectEqual(@as(u16, 400), bad.status);
    var all = try h.ok("/api/dev/grant", &zo, "{{\"note\":\"all\"}}", .{});
    defer all.deinit();
    try testing.expectEqual(@as(i64, 52), try all.int("me.notes.found"));
    const zid = try h.playerId("Turned");
    try testing.expectEqual(@as(?i64, 52), try h.ctx.db.scalar("SELECT COUNT(*) FROM player_notes WHERE player_id = ?", .{zid}));
    try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar("SELECT COUNT(*) FROM player_notes WHERE player_id = ? AND note_id LIKE 'survey.%'", .{zid}));
}

test "notes: a completed set is claimed once for salvage and a title" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Reader", "human", &tok);

    var unk = try h.post("/api/notes/claim", &tok, "{\"set\":\"nope\"}");
    defer unk.deinit();
    try testing.expectEqual(@as(u16, 404), unk.status);
    var hungry = try h.post("/api/notes/claim", &tok, "{\"set\":\"hunger\"}");
    defer hungry.deinit();
    try testing.expectEqual(@as(u16, 404), hungry.status);
    var early = try h.post("/api/notes/claim", &tok, "{\"set\":\"starlite\"}");
    defer early.deinit();
    try testing.expectEqual(@as(u16, 409), early.status);
    try testing.expectEqualStrings("set_incomplete", try early.errorCode());

    var g = try h.ok("/api/dev/grant", &tok, "{{\"note\":\"all\"}}", .{});
    g.deinit();
    var me0 = try h.get("/api/me", &tok);
    defer me0.deinit();
    const salvage0 = try me0.int("salvage");
    try testing.expectEqual(@as(usize, 0), try me0.len("titles_extra"));

    var c = try h.ok("/api/notes/claim", &tok, "{{\"set\":\"starlite\"}}", .{});
    defer c.deinit();
    const want: i64 = game.notes.setReward(.starlite);
    try testing.expectEqual(want, try c.int("rewards.salvage"));
    // The set pays its notes' worth, and the first claim is an achievement worth 100 more.
    try testing.expectEqual(salvage0 + want + 100, try c.int("me.salvage"));
    try testing.expectEqualStrings("Archivist of the Starlite", try c.str("title"));
    try testing.expectEqualStrings("Archivist of the Starlite", try c.str("me.titles_extra.0"));
    var twice = try h.post("/api/notes/claim", &tok, "{\"set\":\"starlite\"}");
    defer twice.deinit();
    try testing.expectEqual(@as(u16, 409), twice.status);
    try testing.expectEqualStrings("already_claimed", try twice.errorCode());

    var arch = try h.get("/api/notes", &tok);
    defer arch.deinit();
    try testing.expect((try noteSet(&arch, "starlite")).?.get("claimed").?.bool);
    try testing.expect(!(try noteSet(&arch, "lantern")).?.get("claimed").?.bool);
    try testing.expectEqual(@as(i64, 7), (try noteSet(&arch, "starlite")).?.get("total").?.integer);
    try testing.expectEqual(want, (try noteSet(&arch, "starlite")).?.get("reward").?.integer);
}

test "notes: landmark caches can drop one, never twice; deleting the account takes them" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Scavenger", "human", &tok);
    const pid = try h.playerId("Scavenger");

    // A pharmacy a round, half an hour apart: a quarter of the searches turn up a note, and each
    // one is in its reward and in the table exactly once.
    var seen: u32 = 0;
    for (0..48) |round| {
        h.advance(31 * 60 * 1000);
        var key: [16]u8 = undefined;
        const key_s = try std.fmt.bufPrint(&key, "p{d}", .{round});
        var item: [200]u8 = undefined;
        var arr: [220]u8 = undefined;
        const places = try std.fmt.bufPrint(&arr, "[{s}]", .{try placeJson(&item, key_s, "pharmacy", 5, "")});
        var w = try locationWith(&h, &tok, base_lat, base_lon, places);
        w.deinit();
        const window = @divFloor(h.ctx.now(), game.landmarks.window_ms);
        var o = try h.ok("/api/open", &tok, "{{\"id\":\"l.{s}.{d}\"}}", .{ key_s, window });
        defer o.deinit();
        seen += @intCast(try o.len("loot.notes"));
    }
    try testing.expect(seen >= 3);
    try testing.expect(seen <= 48);
    try testing.expectEqual(@as(?i64, seen), try h.ctx.db.scalar("SELECT COUNT(*) FROM player_notes WHERE player_id = ?", .{pid}));
    // A pharmacy's notes are Project Lantern's or the roadside ones.
    try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar("SELECT COUNT(*) FROM player_notes WHERE note_id LIKE 'hunger.%' OR note_id LIKE 'zero.%'", .{}));

    var del = try h.call("DELETE", "/api/account", &tok, "");
    defer del.deinit();
    try testing.expectEqual(@as(u16, 200), del.status);
    try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar("SELECT COUNT(*) FROM player_notes", .{}));
}

// --- Achievements, the collection log and cosmetics ------------------------------------------------

/// Whether the array at `path` has an object whose `field` equals `want`.
fn hasEntry(r: *const Res, path: []const u8, field: []const u8, want: []const u8) !bool {
    for ((try r.at(path)).array.items) |e| {
        if (std.mem.eql(u8, e.object.get(field).?.string, want)) return true;
    }
    return false;
}

fn hasId(r: *const Res, path: []const u8, want: []const u8) !bool {
    for ((try r.at(path)).array.items) |e| {
        if (std.mem.eql(u8, e.string, want)) return true;
    }
    return false;
}

test "achievements: the catalog lists them, an earned one pays once and reaches the player" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Gleaner", "human", &tok);

    var cat = try h.get("/api/catalog", null);
    defer cat.deinit();
    try testing.expectEqual(game.achievements.list.len, try cat.len("achievements"));
    try testing.expectEqual(game.cosmetics.list.len, try cat.len("cosmetics"));
    try testing.expectEqualStrings("First Steps", try cat.str("achievements.0.names.human"));
    try testing.expectEqualStrings("First Shamble", try cat.str("achievements.0.names.zombie"));
    try testing.expect(try hasEntry(&cat, "cosmetics", "id", "frame_wreath"));

    var none = try h.get("/api/achievements", &tok);
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), try none.len("earned"));
    try testing.expectEqual(@as(i64, 1), try none.int("progress.best_rarity"));
    var me0 = try h.get("/api/me", &tok);
    defer me0.deinit();
    const salvage0 = try me0.int("salvage");
    try testing.expectEqual(@as(i64, 0), try me0.int("achievements.earned"));
    try testing.expectEqual(@as(i64, game.achievements.list.len), try me0.int("achievements.total"));

    // A Rare item turns up: "Something Good" pays 30 once, however many Rares follow.
    var g = try h.ok("/api/dev/grant", &tok, "{{\"item\":{{\"base\":\"machete\",\"rarity\":\"rare\"}}}}", .{});
    defer g.deinit();
    try testing.expectEqual(salvage0 + 30, try g.int("me.salvage"));
    try testing.expectEqual(@as(i64, 1), try g.int("me.achievements.earned"));
    var g2 = try h.ok("/api/dev/grant", &tok, "{{\"item\":{{\"base\":\"fire_axe\",\"rarity\":\"rare\"}}}}", .{});
    defer g2.deinit();
    try testing.expectEqual(salvage0 + 30, try g2.int("me.salvage"));

    var list = try h.get("/api/achievements", &tok);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), try list.len("earned"));
    try testing.expectEqualStrings("rare_1", try list.str("earned.0.id"));
    try testing.expectEqual(@as(i64, 3), try list.int("progress.best_rarity"));
    try testing.expect(try list.int("progress.bases_found") >= 5);

    // The player hears about it with their next poll, named for their side, once.
    var w = try h.location(&tok, base_lat, base_lon);
    defer w.deinit();
    const ev = (try eventOfType(&w, "achievement")) orelse return error.NoAchievementEvent;
    const first = ev.object.get("rewards").?.object.get("achievements").?.array.items[0].object;
    try testing.expectEqualStrings("rare_1", first.get("id").?.string);
    try testing.expectEqualStrings("Something Good", first.get("name").?.string);
    var w2 = try h.location(&tok, base_lat, base_lon);
    defer w2.deinit();
    try testing.expect((try eventOfType(&w2, "achievement")) == null);
}

test "achievements: a fight win reports its milestone in the same response, a zombie sees zombie names" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Hungry", "zombie", &tok);
    try h.reachLevel(&tok, 12);
    const en = findEnemy(h.ctx.seed, h.ctx.now());
    var w = try h.location(&tok, en.lat, en.lon);
    w.deinit();
    var b = try h.ok("/api/engage", &tok, "{{\"id\":\"{s}\"}}", .{en.id().str()});
    defer b.deinit();
    const pve_wins = try h.ctx.db.scalar("SELECT n FROM counters WHERE key = 'pve_wins'", .{});
    if (std.mem.eql(u8, try b.str("winner"), "a")) {
        try testing.expectEqual(@as(?i64, 1), pve_wins);
        try testing.expect(try hasEntry(&b, "rewards.achievements", "id", "wins_1"));
        try testing.expect(try hasEntry(&b, "rewards.achievements", "name", "First Taste"));
    } else {
        try testing.expectEqual(@as(?i64, null), pve_wins);
        try testing.expect(!(try hasEntry(&b, "rewards.achievements", "id", "wins_1")));
    }
}

test "achievements: levels, titles, cosmetic unlocks and days survived" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Lifer", "human", &tok);
    var me0 = try h.get("/api/me", &tok);
    defer me0.deinit();
    const salvage0 = try me0.int("salvage");

    // Level 10 earns the level 5 and 10 milestones: 20 + 50 salvage.
    try h.reachLevel(&tok, 10);
    var me1 = try h.get("/api/me", &tok);
    defer me1.deinit();
    try testing.expectEqual(salvage0 + 70, try me1.int("salvage"));
    try testing.expectEqual(@as(i64, 2), try me1.int("achievements.earned"));
    try testing.expectEqual(@as(usize, 0), try me1.len("cosmetics.owned"));

    // A hundred days later the day counts are credited on the next look, with their titles.
    h.advance(100 * game.war.day_ms);
    var list = try h.get("/api/achievements", &tok);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 5), try list.len("earned"));
    try testing.expect(try list.int("progress.days") >= 100);
    var me2 = try h.get("/api/me", &tok);
    defer me2.deinit();
    try testing.expectEqualStrings("Old Hand", try me2.str("titles_extra.0"));
    try testing.expectEqual(salvage0 + 70 + 30 + 100 + 300, try me2.int("salvage"));

    // Level 50 unlocks the Laurels frame, owned and not bought.
    try h.reachLevel(&tok, 50);
    var me3 = try h.get("/api/me", &tok);
    defer me3.deinit();
    try testing.expect(try hasId(&me3, "cosmetics.owned", "frame_wreath"));
    var wear = try h.ok("/api/cosmetics/equip", &tok, "{{\"kind\":\"frame\",\"id\":\"frame_wreath\"}}", .{});
    defer wear.deinit();
    try testing.expectEqualStrings("frame_wreath", try wear.str("me.cosmetics.frame"));
}

test "cosmetics: buy with salvage, own forever, equip and take off; refusals" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Dapper", "human", &tok);
    try h.reachLevel(&tok, 2);
    var me0 = try h.get("/api/me", &tok);
    defer me0.deinit();
    const base = try me0.int("salvage");

    var poor = try h.post("/api/store/buy", &tok, "{\"sku\":\"color_amber\"}");
    defer poor.deinit();
    try testing.expectEqual(@as(u16, 409), poor.status);
    try testing.expectEqualStrings("not_enough_salvage", try poor.errorCode());

    var gr = try h.ok("/api/dev/grant", &tok, "{{\"salvage\":700}}", .{});
    gr.deinit();
    var bought = try h.ok("/api/store/buy", &tok, "{{\"sku\":\"color_amber\"}}", .{});
    defer bought.deinit();
    try testing.expectEqual(base + 700 - 250, try bought.int("me.salvage"));
    try testing.expect(try hasId(&bought, "me.cosmetics.owned", "color_amber"));
    // Bought is not worn.
    try testing.expect((try bought.at("me.cosmetics.color")) == .null);

    var again = try h.post("/api/store/buy", &tok, "{\"sku\":\"color_amber\"}");
    defer again.deinit();
    try testing.expectEqualStrings("owned", try again.errorCode());
    var earned_only = try h.post("/api/store/buy", &tok, "{\"sku\":\"color_gold\"}");
    defer earned_only.deinit();
    try testing.expectEqualStrings("not_for_sale", try earned_only.errorCode());
    // 450 left: a 500 salvage frame is out of reach, and the failed buy takes nothing.
    var short = try h.post("/api/store/buy", &tok, "{\"sku\":\"frame_tape\"}");
    defer short.deinit();
    try testing.expectEqualStrings("not_enough_salvage", try short.errorCode());
    var me1 = try h.get("/api/me", &tok);
    defer me1.deinit();
    try testing.expectEqual(base + 450, try me1.int("salvage"));

    var unowned = try h.post("/api/cosmetics/equip", &tok, "{\"kind\":\"frame\",\"id\":\"frame_tape\"}");
    defer unowned.deinit();
    try testing.expectEqualStrings("not_owned", try unowned.errorCode());
    var wrong = try h.post("/api/cosmetics/equip", &tok, "{\"kind\":\"frame\",\"id\":\"color_amber\"}");
    defer wrong.deinit();
    try testing.expectEqual(@as(u16, 400), wrong.status);
    var nope = try h.post("/api/cosmetics/equip", &tok, "{\"kind\":\"color\",\"id\":\"color_nope\"}");
    defer nope.deinit();
    try testing.expectEqual(@as(u16, 404), nope.status);

    var wear = try h.ok("/api/cosmetics/equip", &tok, "{{\"kind\":\"color\",\"id\":\"color_amber\"}}", .{});
    defer wear.deinit();
    try testing.expectEqualStrings("color_amber", try wear.str("me.cosmetics.color"));
    // It shows where callsigns show: boards, the war page and the clan page.
    var board = try h.get("/api/leaderboard?board=level", &tok);
    defer board.deinit();
    try testing.expectEqualStrings("color_amber", try board.str("entries.0.callsign_color"));
    var off = try h.ok("/api/cosmetics/equip", &tok, "{{\"kind\":\"color\",\"id\":null}}", .{});
    defer off.deinit();
    try testing.expect((try off.at("me.cosmetics.color")) == .null);
    try testing.expect(try hasId(&off, "me.cosmetics.owned", "color_amber"));
    var board2 = try h.get("/api/leaderboard?board=level", &tok);
    defer board2.deinit();
    try testing.expect((try board2.at("entries.0.callsign_color")) == .null);
}

test "cosmetics: a callsign colour never appears in a Contact or in any battle" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    var z: [64]u8 = undefined;
    try h.player("Hank", "human", &a);
    try h.player("Zed", "zombie", &z);
    try h.reachLevel(&a, 6);
    try h.reachLevel(&z, 7);
    // Each wears a different colour, so a leak across the fight can be told apart from one's own.
    const colors = [_][]const u8{ "color_oxblood", "color_amber" };
    for ([_]*[64]u8{ &a, &z }, colors) |t, color| {
        var g = try h.ok("/api/dev/grant", t, "{{\"salvage\":500}}", .{});
        g.deinit();
        var b = try h.ok("/api/store/buy", t, "{{\"sku\":\"{s}\"}}", .{color});
        b.deinit();
        var e = try h.ok("/api/cosmetics/equip", t, "{{\"kind\":\"color\",\"id\":\"{s}\"}}", .{color});
        e.deinit();
    }

    try placePair(&h, &a, &z, 30);
    tick.runLocked(&h.ctx, h.ctx.now());
    var wa = try h.location(&a, base_lat, base_lon);
    defer wa.deinit();
    var wz = try h.location(&z, base_lat + 30.0 / 111_320.0, base_lon);
    defer wz.deinit();
    const ea = (try eventOfType(&wa, "contact")) orelse return error.NoContactEvent;
    const ez = (try eventOfType(&wz, "contact")) orelse return error.NoContactEvent;
    // Neither side's event holds the other's colour anywhere, and the combatants and the turn log
    // hold no colour at all. (`battle.me` is the player's own profile, which has their own.)
    const other = [_][]const u8{ "amber", "oxblood" };
    for ([_]Value{ ea, ez }, other) |ev, foreign| {
        const text = try std.json.Stringify.valueAlloc(testing.allocator, ev, .{});
        defer testing.allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, foreign) == null);
        const battle = ev.object.get("battle").?.object;
        for ([_][]const u8{ "a", "b", "turns", "rewards" }) |key| {
            const part = try std.json.Stringify.valueAlloc(testing.allocator, battle.get(key).?, .{});
            defer testing.allocator.free(part);
            try testing.expect(std.mem.indexOf(u8, part, "color") == null);
        }
    }
    try testing.expectEqualStrings("A Zombie", ea.object.get("battle").?.object.get("b").?.object.get("name").?.string);
    try testing.expectEqualStrings("A Human", ez.object.get("battle").?.object.get("b").?.object.get("name").?.string);

    // A staged Contact and a fight against an enemy carry none either (the real fight may have downed a).
    var heal0 = try h.ok("/api/dev/heal", &a, "{{}}", .{});
    heal0.deinit();
    var bot = try h.ok("/api/dev/bot_contact", &a, "{{}}", .{});
    bot.deinit();
    var w3 = try h.location(&a, base_lat, base_lon);
    defer w3.deinit();
    try testing.expect(std.mem.indexOf(u8, w3.raw.json, "callsign_color") == null);
    h.advance(30 * 60 * 1000); // far enough apart in time to walk to the enemy
    const en = findEnemy(h.ctx.seed, h.ctx.now());
    var w4 = try h.location(&a, en.lat, en.lon);
    w4.deinit();
    var heal = try h.ok("/api/dev/heal", &a, "{{}}", .{});
    heal.deinit();
    var b = try h.ok("/api/engage", &a, "{{\"id\":\"{s}\"}}", .{en.id().str()});
    defer b.deinit();
    // The Battle's `me` is the player's own profile (their colour is theirs to see); the two
    // combatants and the turn log hold none.
    const battle = b.root().object;
    for ([_][]const u8{ "a", "b", "turns" }) |key| {
        const text = try std.json.Stringify.valueAlloc(testing.allocator, battle.get(key).?, .{});
        defer testing.allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "color") == null);
    }
}

test "collection: items seen are recorded once, and stay seen after scrapping" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Hoarder", "human", &tok);

    var c0 = try h.get("/api/collection", &tok);
    defer c0.deinit();
    // The starter kit: a bat, a hoodie, a flashlight, all Common.
    try testing.expectEqual(@as(usize, 3), try c0.len("bases"));
    try testing.expect(try hasId(&c0, "bases", "baseball_bat"));
    try testing.expectEqual(@as(usize, 0), try c0.len("uniques"));
    try testing.expectEqual(@as(usize, 1), try c0.len("rarities"));

    var g = try h.ok("/api/dev/grant", &tok, "{{\"item\":{{\"base\":\"katana\",\"rarity\":\"legendary\"}}}}", .{});
    g.deinit();
    var g2 = try h.ok("/api/dev/grant", &tok, "{{\"item\":{{\"base\":\"katana\",\"rarity\":\"legendary\"}}}}", .{});
    g2.deinit();
    var c1 = try h.get("/api/collection", &tok);
    defer c1.deinit();
    try testing.expectEqual(@as(usize, 4), try c1.len("bases"));
    try testing.expect(try hasId(&c1, "rarities", "legendary"));

    // Scrapping gives nothing back: it was seen, and stays seen.
    var me = try h.get("/api/me", &tok);
    defer me.deinit();
    var uid: []const u8 = "";
    for ((try me.at("items")).array.items) |it| {
        if (std.mem.eql(u8, it.object.get("base").?.string, "katana")) uid = it.object.get("uid").?.string;
    }
    var sc = try h.ok("/api/scrap", &tok, "{{\"uids\":[\"{s}\"]}}", .{uid});
    sc.deinit();
    var c2 = try h.get("/api/collection", &tok);
    defer c2.deinit();
    try testing.expect(try hasId(&c2, "bases", "katana"));
    // The Rare and Legendary milestones came with the legendary.
    var list = try h.get("/api/achievements", &tok);
    defer list.deinit();
    try testing.expect(try hasEntry(&list, "earned", "id", "legendary_1"));
    try testing.expect(try hasEntry(&list, "earned", "id", "rare_1"));
    try testing.expectEqual(@as(i64, 4), try list.int("progress.best_rarity"));
}

test "achievements and cosmetics are removed with the account" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Goner", "zombie", &tok);
    try h.reachLevel(&tok, 2);
    var g = try h.ok("/api/dev/grant", &tok, "{{\"salvage\":300,\"item\":{{\"base\":\"machete\",\"rarity\":\"rare\"}}}}", .{});
    g.deinit();
    var b = try h.ok("/api/store/buy", &tok, "{{\"sku\":\"color_amber\"}}", .{});
    b.deinit();
    try testing.expect((try h.ctx.db.scalar("SELECT COUNT(*) FROM achievements", .{})).? > 0);
    var del = try h.call("DELETE", "/api/account", &tok, "");
    defer del.deinit();
    inline for (.{ "achievements", "cosmetics", "counters", "discoveries" }) |t| {
        try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar("SELECT COUNT(*) FROM " ++ t, .{}));
    }
}

// --- Moderation ------------------------------------------------------------------------------------------------

const admin = @import("admin.zig");

/// Run an admin command against the harness's database, discarding what it prints.
fn adminCmd(h: *Harness, line: []const []const u8) !void {
    var buf: [64]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&buf);
    var rng = game.rng.Rng.init(99);
    try admin.run(testing.allocator, &h.ctx.db, h.ctx.now(), &rng, line, &sink.writer);
}

test "names: blocked callsigns and clan names are refused plainly, innocent ones pass" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();

    var bad = try h.post("/api/register", null, "{\"callsign\":\"xX_Fuck_Xx\",\"terms\":1}");
    defer bad.deinit();
    try testing.expectEqual(@as(u16, 400), bad.status);
    try testing.expectEqualStrings("That name is not allowed here. Please pick another name.", try bad.str("message"));
    var leet = try h.post("/api/register", null, "{\"callsign\":\"TheCuntKing\",\"terms\":1}");
    defer leet.deinit();
    try testing.expectEqual(@as(u16, 400), leet.status);
    var fine = try h.post("/api/register", null, "{\"callsign\":\"Scunthorpe\",\"terms\":1}");
    defer fine.deinit();
    try testing.expectEqual(@as(u16, 200), fine.status);

    var a: [64]u8 = undefined;
    try h.player("Founder", "human", &a);
    try h.reachLevel(&a, 10);
    var gr = try h.ok("/api/dev/grant", &a, "{{\"salvage\":1000}}", .{});
    gr.deinit();
    var rude = try h.post("/api/clans", &a, "{\"name\":\"Nazi Hunters\",\"tag\":\"NH\"}");
    defer rude.deinit();
    try testing.expectEqual(@as(u16, 400), rude.status);
    try testing.expectEqualStrings("name_not_allowed", try rude.errorCode());
    var rude_tag = try h.post("/api/clans", &a, "{\"name\":\"Fine Name\",\"tag\":\"f4g\"}");
    defer rude_tag.deinit();
    try testing.expectEqual(@as(u16, 400), rude_tag.status);
    var ok_clan = try h.post("/api/clans", &a, "{\"name\":\"Scunthorpe Rangers\",\"tag\":\"SCR\"}");
    defer ok_clan.deinit();
    try testing.expectEqual(@as(u16, 200), ok_clan.status);
}

test "reports: player, clan and message, deduped and rate limited" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    try h.player("Reporter", "human", &a);
    try h.player("Rowdy", "human", &b);
    for ([_][]const u8{ &a, &b }) |t| try h.reachLevel(t, 10);
    var gr = try h.ok("/api/dev/grant", &a, "{{\"salvage\":500}}", .{});
    gr.deinit();
    var made = try h.ok("/api/clans", &a, "{{\"name\":\"Last Light\",\"tag\":\"LL\"}}", .{});
    defer made.deinit();
    const clan_id = try testing.allocator.dupe(u8, try made.str("clan.id"));
    defer testing.allocator.free(clan_id);
    var joined = try h.ok("/api/clans/join", &b, "{{\"code\":\"{s}\"}}", .{try made.str("clan.code")});
    joined.deinit();
    var msg = try h.ok("/api/clan/chat", &b, "{{\"text\":\"rude words\"}}", .{});
    defer msg.deinit();
    const msg_id = try testing.allocator.dupe(u8, try msg.str("messages.0.id"));
    defer testing.allocator.free(msg_id);

    var r1 = try h.ok("/api/report", &a, "{{\"kind\":\"player\",\"target\":\"rowdy\",\"reason\":\"harassment\",\"note\":\"keeps pinging me\"}}", .{});
    r1.deinit();
    var dup = try h.post("/api/report", &a, "{\"kind\":\"player\",\"target\":\"Rowdy\",\"reason\":\"cheating\"}");
    defer dup.deinit();
    try testing.expectEqual(@as(u16, 409), dup.status);
    try testing.expectEqualStrings("already_reported", try dup.errorCode());
    // Someone else may report the clan; the message report names the author.
    var r2 = try h.ok("/api/report", &b, "{{\"kind\":\"clan\",\"target\":\"{s}\",\"reason\":\"name\"}}", .{clan_id});
    r2.deinit();
    var r3 = try h.ok("/api/report", &a, "{{\"kind\":\"message\",\"target\":\"{s}\",\"reason\":\"harassment\"}}", .{msg_id});
    r3.deinit();

    var self = try h.post("/api/report", &a, "{\"kind\":\"player\",\"target\":\"reporter\",\"reason\":\"other\"}");
    defer self.deinit();
    try testing.expectEqual(@as(u16, 400), self.status);
    var nobody = try h.post("/api/report", &a, "{\"kind\":\"player\",\"target\":\"nobody\",\"reason\":\"other\"}");
    defer nobody.deinit();
    try testing.expectEqual(@as(u16, 404), nobody.status);
    var reason = try h.post("/api/report", &a, "{\"kind\":\"player\",\"target\":\"rowdy\",\"reason\":\"smells\"}");
    defer reason.deinit();
    try testing.expectEqual(@as(u16, 400), reason.status);
    var outsider: [64]u8 = undefined;
    try h.player("Outsider", "zombie", &outsider);
    var spy = try h.postf("/api/report", &outsider, "{{\"kind\":\"message\",\"target\":\"{s}\",\"reason\":\"other\"}}", .{msg_id});
    defer spy.deinit();
    try testing.expectEqual(@as(u16, 404), spy.status);

    try testing.expectEqual(@as(?i64, 3), try h.ctx.db.scalar("SELECT COUNT(*) FROM reports WHERE status = 'open'", .{}));
    try testing.expectEqual(@as(?i64, try h.playerId("Rowdy")), try h.ctx.db.scalar("SELECT target_player_id FROM reports WHERE kind = 'message'", .{}));

    // Five an hour: two are used, three more go through, the sixth waits.
    var toks: [4][64]u8 = undefined;
    const callsigns = [_][]const u8{ "Target1", "Target2", "Target3", "Target4" };
    for (callsigns, 0..) |c, i| try h.player(c, "zombie", &toks[i]);
    for (callsigns[0..3]) |c| {
        var r = try h.postf("/api/report", &a, "{{\"kind\":\"player\",\"target\":\"{s}\",\"reason\":\"cheating\"}}", .{c});
        defer r.deinit();
        try testing.expectEqual(@as(u16, 200), r.status);
    }
    var limited = try h.postf("/api/report", &a, "{{\"kind\":\"player\",\"target\":\"{s}\",\"reason\":\"cheating\"}}", .{callsigns[3]});
    defer limited.deinit();
    try testing.expectEqual(@as(u16, 429), limited.status);
    try testing.expectEqualStrings("report_limit", try limited.errorCode());
    h.advance(61 * 60 * 1000);
    var later = try h.postf("/api/report", &a, "{{\"kind\":\"player\",\"target\":\"{s}\",\"reason\":\"cheating\"}}", .{callsigns[3]});
    defer later.deinit();
    try testing.expectEqual(@as(u16, 200), later.status);

    // Once resolved, the same target can be reported again.
    try adminCmd(&h, &.{ "resolve", "1" });
    var again = try h.ok("/api/report", &a, "{{\"kind\":\"player\",\"target\":\"rowdy\",\"reason\":\"cheating\"}}", .{});
    again.deinit();
}

test "ban: 403 with reason and end date everywhere, no Echo, no board, unban restores" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    var z: [64]u8 = undefined;
    try h.player("Seeker", "human", &a);
    try h.reachLevel(&a, 5);
    try h.player("Ghoul", "zombie", &z);
    try h.reachLevel(&z, 6);
    var w = try h.location(&z, base_lat + 0.5, base_lon);
    w.deinit();

    try adminCmd(&h, &.{ "ban", "ghoul", "--days", "3", "--reason", "Cheating with a GPS spoofer" });
    const until = wednesday + 3 * std.time.ms_per_day;

    const paths = [_][2][]const u8{
        .{ "GET", "/api/me" },
        .{ "GET", "/api/war" },
        .{ "GET", "/api/clan" },
        .{ "GET", "/api/leaderboard?board=level" },
        .{ "GET", "/api/notes" },
        .{ "POST", "/api/location" },
        .{ "POST", "/api/report" },
        .{ "POST", "/api/callsign" },
        .{ "POST", "/api/clan/chat" },
    };
    for (paths) |p| {
        var r = try h.call(p[0], p[1], &z, "{}");
        defer r.deinit();
        try testing.expectEqual(@as(u16, 403), r.status);
        try testing.expectEqualStrings("banned", try r.errorCode());
        try testing.expectEqualStrings("Cheating with a GPS spoofer", try r.str("reason"));
        try testing.expectEqual(until, try r.int("until"));
    }

    // Off the boards, and never offered as an Echo.
    var board = try h.get("/api/leaderboard?board=level", &a);
    defer board.deinit();
    for ((try board.at("entries")).array.items) |e| try testing.expect(!std.mem.eql(u8, e.object.get("callsign").?.string, "Ghoul"));
    try h.ctx.db.run("UPDATE players SET last_pvp_at = 0", .{});
    var tries: usize = 0;
    while (tries < 40) : (tries += 1) {
        h.advance(echoWindow());
        var res = try h.location(&a, base_lat, base_lon);
        defer res.deinit();
        for ((try res.at("echoes")).array.items) |e| try testing.expectEqual(true, e.object.get("rogue").?.bool);
    }

    // A ban that has run out no longer applies.
    h.advance(3 * std.time.ms_per_day);
    var expired = try h.get("/api/me", &z);
    defer expired.deinit();
    try testing.expectEqual(@as(u16, 200), expired.status);

    // A permanent ban has no end date; unban restores the account and its Echoes.
    try adminCmd(&h, &.{ "ban", "ghoul" });
    var perm = try h.get("/api/me", &z);
    defer perm.deinit();
    try testing.expectEqual(@as(u16, 403), perm.status);
    try testing.expect((try perm.at("until")) == .null);
    try adminCmd(&h, &.{ "unban", "ghoul" });
    var me = try h.get("/api/me", &z);
    defer me.deinit();
    try testing.expectEqual(@as(u16, 200), me.status);
    var real = false;
    tries = 0;
    while (tries < 60 and !real) : (tries += 1) {
        h.advance(echoWindow());
        var res = try h.location(&a, base_lat, base_lon);
        defer res.deinit();
        for ((try res.at("echoes")).array.items) |e| {
            if (!e.object.get("rogue").?.bool) real = true;
        }
    }
    try testing.expect(real);
}

test "rename: the player is flagged and may choose again once" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    try h.player("Badname", "human", &a);
    try adminCmd(&h, &.{ "rename", "badname" });

    var me = try h.get("/api/me", &a);
    defer me.deinit();
    try testing.expectEqual(true, (try me.at("must_rename")).bool);
    try testing.expect(std.mem.startsWith(u8, try me.str("callsign"), "Survivor"));
    var rude = try h.post("/api/callsign", &a, "{\"callsign\":\"Shit_Head\"}");
    defer rude.deinit();
    try testing.expectEqual(@as(u16, 400), rude.status);
    var c = try h.ok("/api/callsign", &a, "{{\"callsign\":\"Better_Name\"}}", .{});
    defer c.deinit();
    try testing.expectEqualStrings("Better_Name", try c.str("me.callsign"));
    try testing.expectEqual(false, (try c.at("me.must_rename")).bool);
    var twice = try h.post("/api/callsign", &a, "{\"callsign\":\"Another\"}");
    defer twice.deinit();
    try testing.expectEqual(@as(u16, 409), twice.status);
}

test "ban: a suspended player can still delete their account" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var z: [64]u8 = undefined;
    try h.player("Ghoul", "zombie", &z);
    try adminCmd(&h, &.{ "ban", "ghoul", "--reason", "Spam" });
    var me = try h.get("/api/me", &z);
    defer me.deinit();
    try testing.expectEqual(@as(u16, 403), me.status);
    var del = try h.call("DELETE", "/api/account", &z, "");
    defer del.deinit();
    try testing.expectEqual(@as(u16, 200), del.status);
    try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar("SELECT COUNT(*) FROM players WHERE callsign = 'Ghoul'", .{}));
}

// --- In transit ------------------------------------------------------------------------------------------

/// Drive north at 15 m/s, ending at (`lat`, `lon`): `n` fixes two seconds apart.
fn drive(h: *Harness, tok: []const u8, lat: f64, lon: f64, n: usize) !Res {
    var last: ?Res = null;
    var i: usize = n;
    while (i > 0) : (i -= 1) {
        h.advance(2000);
        if (last) |*l| l.deinit();
        last = try h.location(tok, lat - @as(f64, @floatFromInt(i - 1)) * 30.0 / 111_320.0, lon);
    }
    return last.?;
}

test "in transit: fast fixes block fights, claims, Contact and notices until a minute on foot" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    var z: [64]u8 = undefined;
    try h.player("Hank", "human", &a);
    try h.player("Zed", "zombie", &z);
    try h.reachLevel(&a, 6);
    try h.reachLevel(&z, 7);
    const pid = try h.playerId("Hank");
    const en = findEnemy(h.ctx.seed, h.ctx.now());
    const id = en.id();
    const zlat = en.lat + 30.0 / 111_320.0;

    // Start 120 m south of the enemy, on foot. Zed stands 30 m from where Hank will stop.
    var start = try h.location(&a, en.lat - 120.0 / 111_320.0, en.lon);
    defer start.deinit();
    try testing.expect(!(try start.at("in_transit")).bool);
    var zw = try h.location(&z, zlat, en.lon);
    zw.deinit();

    // One fast fix is not enough (a GPS jump looks the same)...
    h.advance(2000);
    var one = try h.location(&a, en.lat - 90.0 / 111_320.0, en.lon);
    defer one.deinit();
    try testing.expect(!(try one.at("in_transit")).bool);
    // ...two in a row are: 15 m/s all the way to the enemy.
    var two = try drive(&h, &a, en.lat, en.lon, 3);
    defer two.deinit();
    try testing.expect((try two.at("in_transit")).bool);
    try testing.expect(!(try two.at("hostiles_near")).bool);

    var eng = try h.postf("/api/engage", &a, "{{\"id\":\"{s}\"}}", .{id.str()});
    defer eng.deinit();
    try testing.expectEqual(@as(u16, 409), eng.status);
    try testing.expectEqualStrings("in_transit", try eng.errorCode());
    var opn = try h.post("/api/open", &a, "{\"id\":\"c.dr5ru7k.1.0\"}");
    defer opn.deinit();
    try testing.expectEqualStrings("in_transit", try opn.errorCode());

    // Not matched for Contact from the road: Zed stays live and in range.
    var zw2 = try h.location(&z, zlat, en.lon);
    zw2.deinit();
    tick.runLocked(&h.ctx, h.ctx.now());
    try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar("SELECT COUNT(*) FROM contact_log", .{}));
    // A queued notice stays queued on a Patrol check-in.
    try h.ctx.db.run("INSERT INTO events(player_id, at, type, text) VALUES(?,?,?,?)", .{ pid, h.ctx.now(), "echo_report", "Your echo fell." });
    var pt = try patrol(&h, &a, en.lat, en.lon);
    defer pt.deinit();
    try testing.expectEqual(@as(usize, 0), try pt.len("events"));

    // Standing still for 50 s changes nothing; a minute past the last fast fix it clears.
    for (0..10) |_| {
        h.advance(5000);
        var w = try h.location(&a, en.lat, en.lon);
        w.deinit();
        var zk = try h.location(&z, zlat, en.lon);
        zk.deinit();
    }
    var still = try h.location(&a, en.lat, en.lon);
    try testing.expect((try still.at("in_transit")).bool);
    still.deinit();
    for (0..3) |_| {
        h.advance(5000);
        var w = try h.location(&a, en.lat, en.lon);
        w.deinit();
        var zk = try h.location(&z, zlat, en.lon);
        zk.deinit();
    }
    var free = try h.location(&a, en.lat, en.lon);
    defer free.deinit();
    try testing.expect(!(try free.at("in_transit")).bool);
    tick.runLocked(&h.ctx, h.ctx.now());
    try testing.expectEqual(@as(?i64, 1), try h.ctx.db.scalar("SELECT COUNT(*) FROM contact_log", .{}));
    var notice = try patrol(&h, &a, en.lat, en.lon);
    defer notice.deinit();
    try testing.expect(try notice.len("events") >= 1);
}

test "in transit: engaging works again once the player is back on foot" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    try h.player("Hank", "human", &a);
    const en = findEnemy(h.ctx.seed, h.ctx.now());
    const id = en.id();
    var start = try h.location(&a, en.lat - 120.0 / 111_320.0, en.lon);
    start.deinit();
    var d = try drive(&h, &a, en.lat, en.lon, 4);
    d.deinit();
    var blocked = try h.postf("/api/engage", &a, "{{\"id\":\"{s}\"}}", .{id.str()});
    defer blocked.deinit();
    try testing.expectEqualStrings("in_transit", try blocked.errorCode());
    // A minute and a bit at a standstill.
    for (0..14) |_| {
        h.advance(5000);
        var w = try h.location(&a, en.lat, en.lon);
        w.deinit();
    }
    var b = try h.ok("/api/engage", &a, "{{\"id\":\"{s}\"}}", .{id.str()});
    b.deinit();
}

test "in transit: a wobbling signal on a standing phone is not movement" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    try h.player("Hank", "human", &a);
    for (0..8) |i| {
        h.advance(3000);
        // 25 m of sideways jitter on a 20 m accuracy radius.
        const off: f64 = if (i % 2 == 0) 0 else 25.0 / 111_320.0;
        var r = try h.ok("/api/location", &a, "{{\"lat\":{d},\"lon\":{d},\"acc\":20,\"sanctuary\":false}}", .{ base_lat + off, base_lon });
        defer r.deinit();
        try testing.expect(!(try r.at("in_transit")).bool);
    }
}

// --- Terms of service ------------------------------------------------------------------------------------

test "terms: a new account must accept the current version, which is recorded; older versions are asked again" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();

    var health = try h.get("/api/health", null);
    defer health.deinit();
    try testing.expectEqual(@as(i64, game.data.terms_version), try health.int("terms_version"));

    for ([_][]const u8{ "{}", "{\"terms\":0}", "{\"terms\":99}" }) |body| {
        var no = try h.post("/api/register", null, body);
        defer no.deinit();
        try testing.expectEqual(@as(u16, 400), no.status);
        try testing.expectEqualStrings("terms_required", try no.errorCode());
    }
    var dev = try h.post("/api/auth/dev", null, "{\"subject\":\"kid\"}");
    defer dev.deinit();
    try testing.expectEqualStrings("terms_required", try dev.errorCode());
    try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar("SELECT COUNT(*) FROM players", .{}));

    var r = try h.post("/api/register", null, "{\"terms\":1}");
    defer r.deinit();
    try testing.expectEqual(@as(i64, 1), try r.int("me.terms.accepted"));
    try testing.expect(!(try r.at("me.terms.needs_accept")).bool);
    const pid = (try h.ctx.db.scalar("SELECT id FROM players", .{})).?;
    try testing.expectEqual(h.ctx.now(), (try h.ctx.db.scalar("SELECT terms_accepted_at FROM players WHERE id = ?", .{pid})).?);

    // A player from before terms existed (or from an older version) is asked once.
    const token = try r.str("token");
    try h.ctx.db.run("UPDATE players SET terms_accepted = 0, terms_accepted_at = 0 WHERE id = ?", .{pid});
    var me = try h.get("/api/me", token);
    defer me.deinit();
    try testing.expect((try me.at("terms.needs_accept")).bool);
    try testing.expectEqual(@as(i64, game.data.terms_version), try me.int("terms.current"));
    var wrong = try h.post("/api/terms", token, "{\"version\":0}");
    defer wrong.deinit();
    try testing.expectEqualStrings("terms_required", try wrong.errorCode());
    h.advance(1000);
    var ok = try h.post("/api/terms", token, "{\"version\":1}");
    defer ok.deinit();
    try testing.expectEqual(@as(u16, 200), ok.status);
    try testing.expect(!(try ok.at("me.terms.needs_accept")).bool);
    try testing.expectEqual(h.ctx.now(), (try h.ctx.db.scalar("SELECT terms_accepted_at FROM players WHERE id = ?", .{pid})).?);

    // Signing in to an existing account with the terms attached records them too.
    var created = try h.post("/api/auth/dev", null, "{\"subject\":\"kid\",\"terms\":1}");
    created.deinit();
    const pid2 = (try h.ctx.db.scalar("SELECT player_id FROM identities WHERE subject = 'kid'", .{})).?;
    try h.ctx.db.run("UPDATE players SET terms_accepted = 0 WHERE id = ?", .{pid2});
    var again = try h.post("/api/auth/dev", null, "{\"subject\":\"kid\",\"terms\":1}");
    defer again.deinit();
    try testing.expect(!(try again.at("me.terms.needs_accept")).bool);
}

// --- Forced update ---------------------------------------------------------------------------------------------

const client_version = @import("client_version.zig");

fn updateOpts(min: []const u8, android: []const u8, ios: []const u8) ctx_mod.Options {
    return .{ .dev = true, .limits = false, .update = .{ .min_client = client_version.parse(min), .min_client_text = min, .store_android = android, .store_ios = ios } };
}

/// A request that carried an `X-Outbreak-Client` header.
fn callClient(h: *Harness, client: ?[]const u8, method: []const u8, path: []const u8, token: ?[]const u8) !Res {
    const raw = api.handleClient(&h.ctx, method, path, "", token, client, "");
    const parsed: ?std.json.Parsed(Value) = if (raw.json.len > 0) try std.json.parseFromSlice(Value, testing.allocator, raw.json, .{}) else null;
    return .{ .status = raw.status, .raw = raw, .parsed = parsed };
}

test "forced update: older clients get 426 with the stores, equal and newer pass, no header passes" {
    var h: Harness = undefined;
    try h.init(updateOpts("0.2.0", "https://play.example/outbreak", ""));
    defer h.deinit();

    var old = try callClient(&h, "0.1.9", "GET", "/api/factions", null);
    defer old.deinit();
    try testing.expectEqual(@as(u16, 426), old.status);
    try testing.expectEqualStrings("update_required", try old.errorCode());
    try testing.expect((try old.str("message")).len > 0);
    try testing.expectEqualStrings("https://play.example/outbreak", try old.str("store.android"));
    try testing.expect((try old.at("store.ios")) == .null);

    // The gate comes before authentication and applies to POSTs too.
    var old_post = try callClient(&h, "0.1.0", "POST", "/api/register", null);
    defer old_post.deinit();
    try testing.expectEqual(@as(u16, 426), old_post.status);

    for ([_][]const u8{ "0.2.0", "0.2.1", "0.10.0", "1.0.0", "v0.3.0", "0.2.0-beta" }) |v| {
        var r = try callClient(&h, v, "GET", "/api/factions", null);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 200), r.status);
    }
    // No header (curl, the web dev build) and an unreadable one are allowed.
    var none = try callClient(&h, null, "GET", "/api/factions", null);
    defer none.deinit();
    try testing.expectEqual(@as(u16, 200), none.status);
    var junk = try callClient(&h, "banana", "GET", "/api/factions", null);
    defer junk.deinit();
    try testing.expectEqual(@as(u16, 200), junk.status);

    // Health stays open so an old client can learn it must update; a player may always erase their account.
    var health = try callClient(&h, "0.0.1", "GET", "/api/health", null);
    defer health.deinit();
    try testing.expectEqual(@as(u16, 200), health.status);
    try testing.expectEqualStrings("0.2.0", try health.str("min_client"));
    try testing.expectEqualStrings("https://play.example/outbreak", try health.str("store.android"));
    var del = try callClient(&h, "0.0.1", "DELETE", "/api/account", null);
    defer del.deinit();
    try testing.expectEqual(@as(u16, 401), del.status);
}

test "forced update: no stores configured means store is null; the gate is off by default" {
    var h: Harness = undefined;
    try h.init(updateOpts("1.0.0", "", ""));
    defer h.deinit();
    var old = try callClient(&h, "0.9.0", "GET", "/api/factions", null);
    defer old.deinit();
    try testing.expectEqual(@as(u16, 426), old.status);
    try testing.expect((try old.at("store")) == .null);

    var both: Harness = undefined;
    try both.init(updateOpts("1.0.0", "https://play.example/o", "https://apps.example/o"));
    defer both.deinit();
    var r = try callClient(&both, "0.9.0", "GET", "/api/factions", null);
    defer r.deinit();
    try testing.expectEqualStrings("https://apps.example/o", try r.str("store.ios"));

    var open: Harness = undefined;
    try open.init(.{});
    defer open.deinit();
    var ok = try callClient(&open, "0.0.1", "GET", "/api/factions", null);
    defer ok.deinit();
    try testing.expectEqual(@as(u16, 200), ok.status);
    var health = try open.get("/api/health", null);
    defer health.deinit();
    try testing.expect((try health.at("min_client")) == .null);
}

// --- Client error reports --------------------------------------------------------------------------------------

fn clientErrorCount(h: *Harness) !i64 {
    return (try h.ctx.db.scalar("SELECT COUNT(*) FROM client_errors", .{})).?;
}

test "client errors: accepted anonymously, scrubbed, cut to size and grouped" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();

    var r = try h.post("/api/client-error", null,
        \\{"message":"fix 47.60970,-122.33310 failed at http://x.test/a.js?lat=47.6&lon=-122.3","stack":"Error: boom\n    at go (http://x.test/a.js?v=3:10:5)\n    at run (http://x.test/a.js:1:1)","version":"0.1.0","platform":"android","screen":"map","ts":1793188800000}
    );
    defer r.deinit();
    try testing.expectEqual(@as(u16, 200), r.status);
    try testing.expectEqual(@as(i64, 1), try r.int("stored"));
    {
        var st = try h.ctx.db.query("SELECT message, stack, frame, version, platform, screen, length(hash) FROM client_errors", .{});
        defer st.finalize();
        try testing.expect(try st.step());
        try testing.expectEqualStrings("fix ~,~ failed at http://x.test/a.js", st.text(0));
        try testing.expect(std.mem.indexOf(u8, st.text(1), "?v=3") == null and std.mem.indexOf(u8, st.text(1), "a.js:10:5") != null);
        try testing.expectEqualStrings("at go (http://x.test/a.js:10:5)", st.text(2));
        try testing.expectEqualStrings("0.1.0", st.text(3));
        try testing.expectEqualStrings("android", st.text(4));
        try testing.expectEqualStrings("map", st.text(5));
        try testing.expectEqual(@as(i64, 16), st.int(6));
    }

    // A token is not needed, and a junk one does not matter either.
    var junk_token = try h.post("/api/client-error", "not-a-token", "{\"message\":\"x\"}");
    defer junk_token.deinit();
    try testing.expectEqual(@as(u16, 200), junk_token.status);

    // No message: nothing stored. Not JSON: 400.
    var empty = try h.post("/api/client-error", null, "{\"stack\":\"only a stack\"}");
    defer empty.deinit();
    try testing.expectEqual(@as(i64, 0), try empty.int("stored"));
    var bad = try h.post("/api/client-error", null, "nope");
    defer bad.deinit();
    try testing.expectEqual(@as(u16, 400), bad.status);

    // The same fault with other numbers lands in the same group.
    var a = try h.post("/api/client-error", null, "{\"message\":\"Row 12 missing\",\"stack\":\"at f (u.js:1:2)\"}");
    a.deinit();
    var b = try h.post("/api/client-error", null, "{\"message\":\"Row 9041 missing\",\"stack\":\"at f (u.js:1:2)\"}");
    b.deinit();
    try testing.expectEqual(@as(?i64, 1), try h.ctx.db.scalar("SELECT COUNT(DISTINCT hash) FROM client_errors WHERE message LIKE 'Row % missing'", .{}));
    try testing.expectEqual(@as(?i64, 2), try h.ctx.db.scalar("SELECT COUNT(*) FROM client_errors WHERE message LIKE 'Row % missing'", .{}));
}

test "client errors: message cut to 500, stack to 4000, batches to ten, only the newest 5000 kept" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();

    const long_msg = try testing.allocator.alloc(u8, 900);
    defer testing.allocator.free(long_msg);
    @memset(long_msg, 'm');
    const long_stack = try testing.allocator.alloc(u8, 9000);
    defer testing.allocator.free(long_stack);
    @memset(long_stack, 's');
    var r = try h.postf("/api/client-error", null, "{{\"message\":\"{s}\",\"stack\":\"{s}\"}}", .{ long_msg, long_stack });
    defer r.deinit();
    try testing.expectEqual(@as(u16, 200), r.status);
    try testing.expectEqual(@as(?i64, 500), try h.ctx.db.scalar("SELECT length(message) FROM client_errors", .{}));
    try testing.expectEqual(@as(?i64, 4000), try h.ctx.db.scalar("SELECT length(stack) FROM client_errors", .{}));

    var batch: std.ArrayList(u8) = .empty;
    defer batch.deinit(testing.allocator);
    try batch.appendSlice(testing.allocator, "{\"reports\":[");
    for (0..14) |i| {
        if (i > 0) try batch.append(testing.allocator, ',');
        const one = try std.fmt.allocPrint(testing.allocator, "{{\"message\":\"batch item {c}\",\"version\":\"0.1.0\"}}", .{@as(u8, 'a') + @as(u8, @intCast(i))});
        defer testing.allocator.free(one);
        try batch.appendSlice(testing.allocator, one);
    }
    try batch.appendSlice(testing.allocator, "]}");
    var rb = try h.post("/api/client-error", null, batch.items);
    defer rb.deinit();
    try testing.expectEqual(@as(i64, 10), try rb.int("stored"));

    // Fill the table past the cap; one more report trims it to the newest 5000.
    try h.ctx.db.exec("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 5200) INSERT INTO client_errors(at, hash, message) SELECT 1, 'old', 'old' FROM n");
    try testing.expect(try clientErrorCount(&h) > 5200);
    var one_more = try h.post("/api/client-error", null, "{\"message\":\"the newest\"}");
    one_more.deinit();
    try testing.expectEqual(@as(i64, 5000), try clientErrorCount(&h));
    try testing.expectEqual(@as(?i64, 1), try h.ctx.db.scalar("SELECT COUNT(*) FROM client_errors WHERE message = 'the newest'", .{}));
}

test "client errors: rate limited per token and for anonymous senders, apart from registration" {
    var h: Harness = undefined;
    try h.init(.{ .dev = false, .limits = true });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Crashy", "human", &tok);

    var limited = false;
    var sent: usize = 0;
    for (0..20) |_| {
        var r = try h.post("/api/client-error", &tok, "{\"message\":\"again\"}");
        defer r.deinit();
        if (r.status == 429) {
            limited = true;
            try testing.expectEqualStrings("rate_limited", try r.errorCode());
            break;
        }
        sent += 1;
    }
    try testing.expect(limited);
    try testing.expect(sent >= 3 and sent <= 8);
    try testing.expectEqual(@as(i64, @intCast(sent)), try clientErrorCount(&h));

    // Anonymous senders share one bucket, and flooding it does not starve registration.
    var anon_limited = false;
    for (0..60) |_| {
        var r = try h.post("/api/client-error", null, "{\"message\":\"anon\"}");
        defer r.deinit();
        if (r.status == 429) {
            anon_limited = true;
            break;
        }
    }
    try testing.expect(anon_limited);
    var reg = try h.post("/api/register", null, "{\"terms\":1,\"callsign\":\"StillWorks\"}");
    defer reg.deinit();
    try testing.expectEqual(@as(u16, 200), reg.status);

    // The player's own game budget is untouched by it, and the bucket refills.
    var me = try h.get("/api/me", &tok);
    defer me.deinit();
    try testing.expectEqual(@as(u16, 200), me.status);
    h.advance(60_000);
    var again = try h.post("/api/client-error", &tok, "{\"message\":\"later\"}");
    defer again.deinit();
    try testing.expectEqual(@as(u16, 200), again.status);
}

// --- Simulated location ----------------------------------------------------------------------------------------

fn fixMock(h: *Harness, token: []const u8, lat: f64, lon: f64, mock: bool) !Res {
    return h.ok("/api/location", token, "{{\"lat\":{d},\"lon\":{d},\"acc\":5,\"sanctuary\":false,\"mock\":{s}}}", .{ lat, lon, if (mock) "true" else "false" });
}

test "simulated location: Me carries the flag, it clears with the next real fix, sessions are counted" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Spoofer", "human", &tok);
    const pid = try h.playerId("Spoofer");

    var real = try fixMock(&h, &tok, base_lat, base_lon, false);
    defer real.deinit();
    try testing.expectEqual(false, (try real.at("me.simulated_location")).bool);

    h.advance(5000);
    var fake = try fixMock(&h, &tok, base_lat, base_lon, true);
    defer fake.deinit();
    try testing.expectEqual(true, (try fake.at("me.simulated_location")).bool);
    var me = try h.get("/api/me", &tok);
    defer me.deinit();
    try testing.expectEqual(true, (try me.at("simulated_location")).bool);

    // Further fixes in the same sitting are one session; a new one after half an hour is another.
    h.advance(5000);
    var f2 = try fixMock(&h, &tok, base_lat, base_lon, true);
    f2.deinit();
    try testing.expectEqual(@as(?i64, 1), try h.ctx.db.scalar("SELECT mock_sessions FROM players WHERE id = ?", .{pid}));
    h.advance(31 * 60 * 1000);
    var f3 = try fixMock(&h, &tok, base_lat, base_lon, true);
    f3.deinit();
    try testing.expectEqual(@as(?i64, 2), try h.ctx.db.scalar("SELECT mock_sessions FROM players WHERE id = ?", .{pid}));

    // A real fix takes the flag off at once, wherever it is (no speed check against a faked position).
    h.advance(5000);
    var back = try fixMock(&h, &tok, base_lat + 1.0, base_lon, false);
    defer back.deinit();
    try testing.expectEqual(false, (try back.at("me.simulated_location")).bool);
    const pos = h.ctx.live.position(pid, h.ctx.now()).?;
    try testing.expectApproxEqAbs(base_lat + 1.0, pos.lat, 1e-9);
    try testing.expectEqual(@as(?i64, 2), try h.ctx.db.scalar("SELECT mock_sessions FROM players WHERE id = ?", .{pid}));
}

test "simulated location: no walking XP" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var fake: [64]u8 = undefined;
    var real: [64]u8 = undefined;
    try h.player("Faker", "zombie", &fake);
    try h.player("Walker", "zombie", &real);

    // Both "walk" 20 m every 5 s for two minutes; only the honest one is paid.
    var lat: f64 = base_lat;
    for (0..24) |_| {
        h.advance(5000);
        lat += 20.0 / 111_320.0;
        var a = try fixMock(&h, &fake, lat, base_lon, true);
        a.deinit();
        var b = try fixMock(&h, &real, lat, base_lon, false);
        b.deinit();
    }
    try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar("SELECT xp FROM players WHERE callsign = 'Faker'", .{}));
    try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar("SELECT distance_m FROM players WHERE callsign = 'Faker'", .{}));
    try testing.expect((try h.ctx.db.scalar("SELECT xp FROM players WHERE callsign = 'Walker'", .{})).? >= 20);
}

test "simulated location: no war points, but PvE still pays XP and loot" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Ghost", "human", &tok);

    var b1: [200]u8 = undefined;
    var b2: [200]u8 = undefined;
    const arr = try std.fmt.allocPrint(testing.allocator, "[{s},{s}]", .{
        try placeJson(&b1, "n7001", "pharmacy", 10, "Corner Drugs"),
        try placeJson(&b2, "n7002", "diner", 12, "Joes"),
    });
    defer testing.allocator.free(arr);
    const window = @divFloor(h.ctx.now(), game.landmarks.window_ms);

    var w = try h.ok("/api/location", &tok, "{{\"lat\":{d},\"lon\":{d},\"acc\":5,\"sanctuary\":false,\"mock\":true,\"places\":{s}}}", .{ base_lat, base_lon, arr });
    w.deinit();
    var open = try h.ok("/api/open", &tok, "{{\"id\":\"l.n7001.{d}\"}}", .{window});
    defer open.deinit();
    try testing.expect(try open.int("loot.xp") > 0);
    try testing.expectEqual(@as(i64, 0), try open.int("loot.war_points"));
    var war = try h.get("/api/war", &tok);
    defer war.deinit();
    try testing.expectEqual(@as(i64, 0), try war.int("my_points"));

    // The same player with a real fix is paid.
    h.advance(5000);
    var w2 = try h.ok("/api/location", &tok, "{{\"lat\":{d},\"lon\":{d},\"acc\":5,\"sanctuary\":false,\"mock\":false,\"places\":{s}}}", .{ base_lat, base_lon, arr });
    w2.deinit();
    var open2 = try h.ok("/api/open", &tok, "{{\"id\":\"l.n7002.{d}\"}}", .{window});
    defer open2.deinit();
    try testing.expectEqual(@as(i64, 1), try open2.int("loot.war_points"));
}

test "simulated location: not matched for Contact, foreground or Patrol; matched again when real" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    var z: [64]u8 = undefined;
    try h.player("Hank", "human", &a);
    try h.player("Zed", "zombie", &z);
    try h.reachLevel(&a, 6);
    try h.reachLevel(&z, 7);
    const count = "SELECT COUNT(*) FROM contact_log";
    const zlat = base_lat + 30.0 / 111_320.0;

    var ra = try fixMock(&h, &a, base_lat, base_lon, true);
    ra.deinit();
    var rz = try fixMock(&h, &z, zlat, base_lon, false);
    rz.deinit();
    tick.runLocked(&h.ctx, h.ctx.now());
    try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar(count, .{}));

    // Patrol check-ins carry the flag too.
    var p = try h.ok("/api/patrol", &a, "{{\"lat\":{d},\"lon\":{d},\"acc\":20,\"mock\":true}}", .{ base_lat, base_lon });
    p.deinit();
    try testing.expect(h.ctx.live.position(try h.playerId("Hank"), h.ctx.now()).?.mock);
    tick.runLocked(&h.ctx, h.ctx.now());
    try testing.expectEqual(@as(?i64, 0), try h.ctx.db.scalar(count, .{}));

    // The same pair, both real: they fight.
    h.advance(5000);
    var ra2 = try fixMock(&h, &a, base_lat, base_lon, false);
    ra2.deinit();
    tick.runLocked(&h.ctx, h.ctx.now());
    try testing.expectEqual(@as(?i64, 1), try h.ctx.db.scalar(count, .{}));
}

test "simulated location: a recently simulated player is not served as an Echo; Rogue echoes still appear" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var a: [64]u8 = undefined;
    var z: [64]u8 = undefined;
    try h.player("Seeker", "human", &a);
    try h.reachLevel(&a, 5);
    try h.player("Ghoul", "zombie", &z);
    try h.reachLevel(&z, 6);
    try h.ctx.db.run("UPDATE players SET last_pvp_at = 0", .{});

    // While Ghoul keeps sending simulated fixes, every Echo Seeker meets is a Rogue.
    var seen: usize = 0;
    for (0..40) |_| {
        h.advance(echoWindow());
        var gz = try fixMock(&h, &z, base_lat + 0.5, base_lon, true);
        gz.deinit();
        var res = try h.location(&a, base_lat, base_lon);
        defer res.deinit();
        if (try res.len("echoes") > 0) {
            seen += 1;
            try testing.expectEqual(true, (try res.at("echoes.0.rogue")).bool);
        }
    }
    try testing.expect(seen > 0);

    // Once Ghoul plays for real (and the quiet minutes pass), their snapshot is offered again.
    var gz = try fixMock(&h, &z, base_lat + 0.5, base_lon, false);
    gz.deinit();
    var real_seen = false;
    for (0..60) |_| {
        h.advance(echoWindow());
        var res = try h.location(&a, base_lat, base_lon);
        defer res.deinit();
        if (try res.len("echoes") > 0 and !(try res.at("echoes.0.rogue")).bool) {
            real_seen = true;
            break;
        }
    }
    try testing.expect(real_seen);
}

// --- Limited-time events (DESIGN.md section 18) ---------------------------------------------------------------
//
// The harness turns the real calendar off; these tests start events themselves (dev endpoint) or turn the
// calendar on with the clock pinned to a known Wednesday, so nothing depends on what the real week holds.
// `wednesday` is on a 2 h boundary, so every spawn window that starts at or after it is inside an event
// started then.

const gev = game.events;

fn startEvent(h: *Harness, tok: []const u8, kind: []const u8, hours: i64) !void {
    var r = try h.ok("/api/dev/event", tok, "{{\"type\":\"{s}\",\"hours\":{d}}}", .{ kind, hours });
    r.deinit();
}

fn latestEventId(h: *Harness) !i64 {
    return (try h.ctx.db.scalar("SELECT MAX(id) FROM world_events", .{})).?;
}

/// Put `n` contributions for a player into an event, as if they had been made in play.
fn contribute(h: *Harness, event_id: i64, pid: i64, n: i64) !void {
    try h.ctx.db.run(
        "INSERT INTO world_event_player(event_id, player_id, district, n) VALUES(?,?,'dr5r',?) ON CONFLICT(event_id, player_id, district) DO UPDATE SET n = excluded.n",
        .{ event_id, pid, n },
    );
}

fn feedCount(h: *Harness, pid: i64, kind: []const u8) !i64 {
    return (try h.ctx.db.scalar("SELECT COUNT(*) FROM events WHERE player_id = ? AND type = ?", .{ pid, kind })).?;
}

/// Win a PvE fight near the base spot (a heal before each try, a new window after a loss).
fn winSomething(h: *Harness, tok: []const u8) !Res {
    for (0..12) |_| {
        const en = findEnemy(h.ctx.seed, h.ctx.now());
        var w = try h.location(tok, en.lat, en.lon);
        w.deinit();
        var heal = try h.ok("/api/dev/heal", tok, "{{}}", .{});
        heal.deinit();
        var b = try h.ok("/api/engage", tok, "{{\"id\":\"{s}\"}}", .{en.id().str()});
        if (std.mem.eql(u8, try b.str("winner"), "a")) return b;
        b.deinit();
        h.advance(spawns.enemy_window_ms);
    }
    return error.NoWin;
}

fn eventsList(h: *Harness, tok: []const u8) !Res {
    return h.get("/api/events", tok);
}

fn listsId(w: *const Res, path: []const u8, id: []const u8) !bool {
    for ((try w.at(path)).array.items) |e| {
        if (std.mem.eql(u8, e.object.get("id").?.string, id)) return true;
    }
    return false;
}

test "events: the calendar makes one row per event, with a goal scaled to the active players" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    h.ctx.opts.events = true;
    var tok: [64]u8 = undefined;
    try h.player("Walker", "human", &tok);

    const occ = gev.occurrenceAt(wednesday).?;
    const def = game.data.eventDef(occ.type);
    var a = try eventsList(&h, &tok);
    defer a.deinit();
    try testing.expectEqualStrings(@tagName(occ.type), try a.str("live.type"));
    try testing.expectEqual(occ.starts_at, try a.int("live.starts_at"));
    try testing.expectEqual(occ.ends_at, try a.int("live.ends_at"));
    // One active player: the goal is the floor, and it is fixed for the event.
    try testing.expectEqual(@as(i64, 1), try a.int("live.active_players"));
    try testing.expectEqual(@as(i64, gev.target(def, 1)), try a.int("live.goal.target"));
    try testing.expectEqual(false, (try a.at("live.admin")).bool);
    var more: [64]u8 = undefined;
    try h.player("Second", "zombie", &more);
    var b = try eventsList(&h, &tok);
    defer b.deinit();
    try testing.expectEqual(try a.int("live.id"), try b.int("live.id"));
    try testing.expectEqual(@as(i64, gev.target(def, 1)), try b.int("live.goal.target"));
    try testing.expectEqual(@as(i64, 1), (try h.ctx.db.scalar("SELECT COUNT(*) FROM world_events", .{})).?);
    // The upcoming list leaves out the running one and is in order.
    try testing.expect(try b.len("upcoming") >= 3);
    try testing.expect(try b.int("upcoming.0.starts_at") > wednesday);
    try testing.expect(try b.int("upcoming.0.starts_at") <= try b.int("upcoming.1.starts_at"));
    // The map poll carries the short form for the banner.
    var w = try h.location(&tok, base_lat, base_lon);
    defer w.deinit();
    try testing.expectEqualStrings(@tagName(occ.type), try w.str("event.type"));
    try testing.expectEqual(@as(i64, 0), try w.int("event.mine"));

    // A stopped calendar event is not made again.
    var stop = try h.ok("/api/dev/event_stop", &tok, "{{}}", .{});
    defer stop.deinit();
    try testing.expectEqual(@as(i64, 1), try stop.int("stopped"));
    var c = try eventsList(&h, &tok);
    defer c.deinit();
    try testing.expect((try c.at("live")) == .null);
    try testing.expectEqual(@as(i64, 1), (try h.ctx.db.scalar("SELECT COUNT(*) FROM world_events", .{})).?);

    // The weekend belongs to the raids.
    h.ctx.clock_ms = saturday;
    var d = try eventsList(&h, &tok);
    defer d.deinit();
    try testing.expect((try d.at("live")) == .null);
}

test "events: an admin's event starts and stops, replaces the running one, and needs the dev switch" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Caller", "human", &tok);
    var none = try eventsList(&h, &tok);
    defer none.deinit();
    try testing.expect((try none.at("live")) == .null);

    var bad = try h.post("/api/dev/event", &tok, "{\"type\":\"nope\"}");
    defer bad.deinit();
    try testing.expectEqual(@as(u16, 400), bad.status);
    try startEvent(&h, &tok, "supply_run", 6);
    var a = try eventsList(&h, &tok);
    defer a.deinit();
    try testing.expectEqualStrings("supply_run", try a.str("live.type"));
    try testing.expectEqual(true, (try a.at("live.admin")).bool);
    try testing.expectEqual(wednesday + 6 * 3600_000, try a.int("live.ends_at"));
    // A second one ends the first.
    try startEvent(&h, &tok, "echo_week", 2);
    var b = try eventsList(&h, &tok);
    defer b.deinit();
    try testing.expectEqualStrings("echo_week", try b.str("live.type"));
    try testing.expectEqual(@as(i64, 1), (try h.ctx.db.scalar("SELECT COUNT(*) FROM world_events WHERE ends_at = ?", .{wednesday})).?);
    var stop = try h.ok("/api/dev/event_stop", &tok, "{{}}", .{});
    stop.deinit();
    var c = try eventsList(&h, &tok);
    defer c.deinit();
    try testing.expect((try c.at("live")) == .null);

    // Without --dev the endpoints do not exist.
    var prod: Harness = undefined;
    try prod.init(.{});
    defer prod.deinit();
    var ptok: [64]u8 = undefined;
    try prod.player("Plain", "human", &ptok);
    var gone = try prod.post("/api/dev/event", &ptok, "{\"type\":\"horde\"}");
    defer gone.deinit();
    try testing.expectEqual(@as(u16, 404), gone.status);
}

test "events: Supply Run adds caches and a second airdrop, and pays airdrop salvage x1.5" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Courier", "human", &tok);
    try h.reachLevel(&tok, 8);
    try startEvent(&h, &tok, "supply_run", 6);
    const ev: spawns.Ev = .{ .type = .supply_run };
    const seed = h.ctx.seed;

    // The second drop of the base region exists only under the event; once it lands it is on the map.
    const region = geo.encode(base_lat, base_lon, 5);
    const aw = spawns.windowIndex(h.ctx.now(), spawns.airdrop_window_ms);
    const drop = spawns.airdropN(seed, region, aw, 1);
    try testing.expect(spawns.hasExtraAirdrop(aw, region, ev) and !spawns.hasExtraAirdrop(aw, region, null));
    h.ctx.clock_ms = drop.starts_at + 60_000;
    const id = drop.id();
    var w = try h.location(&tok, drop.lat, drop.lon);
    defer w.deinit();
    try testing.expect(try listsId(&w, "caches", id.str()));

    // A cache the ordinary rolls leave out is there under the event. (Three minutes on, so the
    // last fix has expired and the next one is not a jump.)
    h.advance(3 * 60_000);
    var cell = geo.encode(base_lat, base_lon, 7);
    const cw = spawns.windowIndex(h.ctx.now(), spawns.cache_window_ms);
    while (spawns.cache(seed, cell, cw) != null or spawns.cacheWith(seed, cell, cw, ev) == null) cell = geo.neighbors(cell)[2].?;
    const extra = spawns.cacheWith(seed, cell, cw, ev).?;
    const cid = extra.id();
    var w2 = try h.location(&tok, extra.lat, extra.lon);
    defer w2.deinit();
    try testing.expect(try listsId(&w2, "caches", cid.str()));

    // Opening the airdrop: its salvage is the roll x1.5, and it counts for the goal.
    h.advance(3 * 60_000);
    var w3 = try h.location(&tok, drop.lat, drop.lon);
    w3.deinit();
    const pid = try h.playerId("Courier");
    var lrng = game.rng.Rng.init(game.rng.hash(seed, .{ "open", pid, @as([]const u8, id.str()), h.ctx.now() }));
    const rolled = game.loot.rollAirdrop(&lrng, 8, 1.0);
    var opened = try h.ok("/api/open", &tok, "{{\"id\":\"{s}\"}}", .{id.str()});
    defer opened.deinit();
    try testing.expectEqual(@as(i64, @intFromFloat(@round(@as(f32, @floatFromInt(rolled.salvage)) * 1.5))), try opened.int("loot.salvage"));
    var after = try eventsList(&h, &tok);
    defer after.deinit();
    try testing.expectEqual(@as(i64, 1), try after.int("live.goal.progress"));
    try testing.expectEqual(@as(i64, 1), try after.int("live.mine.n"));
}

test "events: the second airdrop does not exist once the event is over" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Late", "human", &tok);
    try h.reachLevel(&tok, 8);
    try startEvent(&h, &tok, "supply_run", 1);
    const region = geo.encode(base_lat, base_lon, 5);
    // Two hours on, in the next airdrop window, nobody started an event: no second drop, and its id is refused.
    h.advance(2 * 3600_000);
    const aw = spawns.windowIndex(h.ctx.now(), spawns.airdrop_window_ms);
    const drop = spawns.airdropN(h.ctx.seed, region, aw, 1);
    h.ctx.clock_ms = drop.starts_at + 60_000;
    var w = try h.location(&tok, drop.lat, drop.lon);
    defer w.deinit();
    const id = drop.id();
    try testing.expect(!(try listsId(&w, "caches", id.str())));
    var open = try h.postf("/api/open", &tok, "{{\"id\":\"{s}\"}}", .{id.str()});
    defer open.deinit();
    try testing.expectEqual(@as(u16, 404), open.status);
}

test "events: Blood Moon surges elites at night and pays elite XP x1.5" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Moonlit", "human", &tok);
    try h.reachLevel(&tok, 8);
    try startEvent(&h, &tok, "blood_moon", 6);
    const seed = h.ctx.seed;
    const ev: spawns.Ev = .{ .type = .blood_moon };
    const window = spawns.windowIndex(h.ctx.now(), spawns.enemy_window_ms);

    // 170 E at 12:00 UTC is 23:20 local. Find an enemy the event turns elite.
    var cell = geo.encode(40.0, 170.0, 7);
    var target: spawns.Enemy = undefined;
    search: while (true) : (cell = geo.neighbors(cell)[2].?) {
        var bb: [spawns.max_enemies_per_cell]spawns.Enemy = undefined;
        var eb: [spawns.max_enemies_per_cell]spawns.Enemy = undefined;
        const base = spawns.enemiesInCell(seed, cell, window, &bb);
        const with = spawns.enemiesInCellWith(seed, cell, window, &eb, ev);
        for (base, with) |b, e| {
            if (e.elite and !b.elite) {
                target = e;
                break :search;
            }
        }
    }
    var w = try h.location(&tok, target.lat, target.lon);
    defer w.deinit();
    var seen_elite = false;
    for ((try w.at("enemies")).array.items) |e| {
        if (std.mem.eql(u8, e.object.get("id").?.string, target.id().str())) seen_elite = e.object.get("elite").?.bool;
    }
    try testing.expect(seen_elite);

    var heal = try h.ok("/api/dev/heal", &tok, "{{}}", .{});
    heal.deinit();
    var b = try h.ok("/api/engage", &tok, "{{\"id\":\"{s}\"}}", .{target.id().str()});
    defer b.deinit();
    const lvl: u32 = @intCast(try b.int("b.level"));
    const base_xp = game.progression.pveWinXp(lvl, .elite, game.data.archetype(target.archetype).reward_mult);
    const win_xp: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(base_xp)) * game.daynight.pveXpMult(.human, true) * 1.5));
    const won = std.mem.eql(u8, try b.str("winner"), "a");
    try testing.expectEqual(@as(i64, if (won) win_xp else game.progression.pveLossXp(win_xp)), try b.int("rewards.xp"));
    var after = try eventsList(&h, &tok);
    defer after.deinit();
    try testing.expectEqual(@as(i64, @intFromBool(won)), try after.int("live.goal.progress"));
}

test "events: the swarm fills the map with one kind, and winning it counts for the goal" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Hunter", "human", &tok);
    try h.reachLevel(&tok, 12);
    var r = try h.ok("/api/dev/event", &tok, "{{\"type\":\"horde\",\"hours\":6,\"kind\":\"brute\"}}", .{});
    r.deinit();
    const seed = h.ctx.seed;
    const ev: spawns.Ev = .{ .type = .horde, .param = @intFromEnum(game.data.Archetype.brute) };
    const window = spawns.windowIndex(h.ctx.now(), spawns.enemy_window_ms);

    // Count the kind over a stretch of the map with and without the event.
    var cell = geo.encode(base_lat, base_lon, 7);
    var with_brutes: u32 = 0;
    var base_brutes: u32 = 0;
    var with_total: u32 = 0;
    var base_total: u32 = 0;
    var pick: ?spawns.Enemy = null;
    for (0..400) |_| {
        var bb: [spawns.max_enemies_per_cell]spawns.Enemy = undefined;
        var eb: [spawns.max_enemies_per_cell]spawns.Enemy = undefined;
        for (spawns.enemiesInCell(seed, cell, window, &bb)) |e| {
            base_total += 1;
            if (e.archetype == .brute) base_brutes += 1;
        }
        for (spawns.enemiesInCellWith(seed, cell, window, &eb, ev)) |e| {
            with_total += 1;
            if (e.archetype == .brute) with_brutes += 1;
            if (pick == null and e.archetype == .brute and !e.elite) pick = e;
        }
        cell = geo.neighbors(cell)[2].?;
    }
    // About 12% brutes normally; with the swarm, 60% of the enemies are replaced by the kind.
    try testing.expect(@as(f64, @floatFromInt(base_brutes)) / @as(f64, @floatFromInt(base_total)) < 0.2);
    try testing.expect(@as(f64, @floatFromInt(with_brutes)) / @as(f64, @floatFromInt(with_total)) > 0.5);

    var heal = try h.ok("/api/dev/heal", &tok, "{{}}", .{});
    heal.deinit();
    const e = pick.?;
    var w = try h.location(&tok, e.lat, e.lon);
    defer w.deinit();
    var b = try h.ok("/api/engage", &tok, "{{\"id\":\"{s}\"}}", .{e.id().str()});
    defer b.deinit();
    var after = try eventsList(&h, &tok);
    defer after.deinit();
    const won = std.mem.eql(u8, try b.str("winner"), "a");
    try testing.expectEqual(@as(i64, @intFromBool(won)), try after.int("live.goal.progress"));
    try testing.expectEqualStrings("brute", try after.str("live.kind"));
}

test "events: Last Light counts war points double and they count for the goal" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Dawn", "human", &tok);
    try h.reachLevel(&tok, 12);
    try startEvent(&h, &tok, "last_light", 12);
    var b = try winSomething(&h, &tok);
    defer b.deinit();
    // A normal PvE win is 1 war point; the event doubles it.
    try testing.expectEqual(@as(i64, 2), try b.int("rewards.war_points"));
    var a = try eventsList(&h, &tok);
    defer a.deinit();
    try testing.expectEqual(@as(i64, 2), try a.int("live.goal.progress"));
    try testing.expectEqual(@as(i64, 2), try a.int("live.mine.n"));
    try testing.expect((try a.at("live.district")) != .null);
    try testing.expectEqual(@as(i64, 2), try a.int("live.district.progress"));
    var war = try h.get("/api/war", &tok);
    defer war.deinit();
    try testing.expectEqual(@as(i64, 2), try war.int("my_points"));
}

test "events: reaching the goal pays each participant once, at the end, with the cosmetic" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    var idle: [64]u8 = undefined;
    var small: [64]u8 = undefined;
    try h.player("Giver", "human", &tok);
    try h.reachLevel(&tok, 2); // the Store opens at 2
    try h.player("Idler", "zombie", &idle);
    try h.player("Drop_In", "human", &small);
    try startEvent(&h, &tok, "echo_week", 4);
    const id = try latestEventId(&h);
    const giver = try h.playerId("Giver");
    // Giver gave enough for silver (6 Echoes), Drop_In not enough for anything, Idler nothing.
    try contribute(&h, id, giver, 7);
    try contribute(&h, id, try h.playerId("Drop_In"), 1);
    try h.ctx.db.run("UPDATE world_events SET progress = target WHERE id = ?", .{id});
    var me0 = try h.get("/api/me", &tok);
    defer me0.deinit();
    const before = try me0.int("salvage");

    // Nothing is paid while it runs.
    var mid = try eventsList(&h, &tok);
    mid.deinit();
    try testing.expectEqual(@as(i64, 0), try feedCount(&h, giver, "event_reward"));

    h.advance(5 * 3600_000);
    var after = try eventsList(&h, &tok);
    defer after.deinit();
    try testing.expect((try after.at("live")) == .null);
    try testing.expectEqual(@as(i64, 1), try feedCount(&h, giver, "event_reward"));
    try testing.expectEqual(@as(i64, 0), try feedCount(&h, try h.playerId("Drop_In"), "event_reward"));
    try testing.expectEqual(@as(i64, 0), try feedCount(&h, try h.playerId("Idler"), "event_reward"));

    // Delivered through the poll with the rewards and the unlock.
    var w = try h.location(&tok, base_lat, base_lon);
    defer w.deinit();
    var found: ?Value = null;
    for ((try w.at("events")).array.items) |e| {
        if (std.mem.eql(u8, e.object.get("type").?.string, "event_reward")) found = e;
    }
    const ev = found.?.object;
    try testing.expectEqual(@as(i64, 700), ev.get("rewards").?.object.get("salvage").?.integer);
    const unlock = ev.get("rewards").?.object.get("unlocks").?.array.items[0].object;
    try testing.expectEqualStrings("frame_echo", unlock.get("id").?.string);
    try testing.expectEqualStrings("frame", unlock.get("kind").?.string);
    try testing.expectEqualStrings("Static", unlock.get("name").?.string);

    var me1 = try h.get("/api/me", &tok);
    defer me1.deinit();
    try testing.expectEqual(before + 700, try me1.int("salvage"));
    try testing.expect(try hasId(&me1, "cosmetics.owned", "frame_echo"));
    var wear = try h.ok("/api/cosmetics/equip", &tok, "{{\"kind\":\"frame\",\"id\":\"frame_echo\"}}", .{});
    defer wear.deinit();
    try testing.expectEqualStrings("frame_echo", try wear.str("me.cosmetics.frame"));
    // Not for sale, either.
    var buy = try h.post("/api/store/buy", &tok, "{\"sku\":\"frame_echo\"}");
    defer buy.deinit();
    try testing.expectEqualStrings("not_for_sale", try buy.errorCode());

    // Exactly once: another read, the minute tick, and a later request change nothing.
    var again = try eventsList(&h, &tok);
    again.deinit();
    tick.runLocked(&h.ctx, h.ctx.now());
    h.advance(61_000);
    tick.runLocked(&h.ctx, h.ctx.now());
    var me2 = try h.get("/api/me", &tok);
    defer me2.deinit();
    try testing.expectEqual(before + 700, try me2.int("salvage"));
    try testing.expectEqual(@as(i64, 1), try feedCount(&h, giver, "event_reward"));
    var d = try h.get("/api/me", &small);
    defer d.deinit();
    try testing.expect(!(try hasId(&d, "cosmetics.owned", "frame_echo")));
}

test "events: the minute tick pays an ended event too, and a missed goal pays half with no cosmetic" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Tryer", "zombie", &tok);
    try startEvent(&h, &tok, "blood_moon", 2);
    const id = try latestEventId(&h);
    const pid = try h.playerId("Tryer");
    try contribute(&h, id, pid, 11); // silver by contribution, but the goal is not met
    var me0 = try h.get("/api/me", &tok);
    defer me0.deinit();
    const before = try me0.int("salvage");
    h.advance(3 * 3600_000);
    tick.runLocked(&h.ctx, h.ctx.now());
    try testing.expectEqual(@as(i64, 1), try feedCount(&h, pid, "event_reward"));
    var me1 = try h.get("/api/me", &tok);
    defer me1.deinit();
    try testing.expectEqual(before + 350, try me1.int("salvage"));
    try testing.expect(!(try hasId(&me1, "cosmetics.owned", "color_bloodmoon")));
    // A goal reached in the player's own district counts for them even if the world's was missed.
    try startEvent(&h, &tok, "blood_moon", 2);
    const id2 = try latestEventId(&h);
    try contribute(&h, id2, pid, 11);
    try h.ctx.db.run("INSERT INTO world_event_district(event_id, district, active_players, target, progress) VALUES(?,'dr5r',1,10,10)", .{id2});
    h.advance(3 * 3600_000);
    tick.runLocked(&h.ctx, h.ctx.now());
    var me2 = try h.get("/api/me", &tok);
    defer me2.deinit();
    try testing.expectEqual(before + 350 + 700, try me2.int("salvage"));
    try testing.expect(try hasId(&me2, "cosmetics.owned", "color_bloodmoon"));
}

test "events: the monthly event pays a yearly title once, and a Rare or better item at gold" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Veteran", "zombie", &tok);
    const pid = try h.playerId("Veteran");
    var items_before: usize = 0;
    for (0..2) |round| {
        try startEvent(&h, &tok, "day_zero", 2);
        const id = try latestEventId(&h);
        try contribute(&h, id, pid, 250);
        try h.ctx.db.run("UPDATE world_events SET progress = target WHERE id = ?", .{id});
        h.advance(3 * 3600_000);
        var l = try eventsList(&h, &tok);
        l.deinit();
        var me = try h.get("/api/me", &tok);
        defer me.deinit();
        // The same year's title is not issued twice.
        try testing.expectEqual(@as(usize, 1), try me.len("titles_extra"));
        try testing.expectEqualStrings("Of the Turning 2026", try me.str("titles_extra.0"));
        try testing.expect(try hasId(&me, "cosmetics.owned", "frame_dayzero"));
        try testing.expectEqual(@as(i64, @intCast(round + 1)), try feedCount(&h, pid, "event_reward"));
        // Gold pays an item every time (the starter kit is three).
        const n_items = try me.len("items");
        if (round == 0) try testing.expect(n_items >= 4) else try testing.expect(n_items > items_before);
        items_before = n_items;
    }
    var human: [64]u8 = undefined;
    try h.player("Survivor", "human", &human);
    try startEvent(&h, &human, "day_zero", 2);
    try contribute(&h, try latestEventId(&h), try h.playerId("Survivor"), 250);
    try h.ctx.db.run("UPDATE world_events SET progress = target WHERE id = ?", .{try latestEventId(&h)});
    h.advance(3 * 3600_000);
    var l = try eventsList(&h, &human);
    l.deinit();
    var hm = try h.get("/api/me", &human);
    defer hm.deinit();
    try testing.expectEqualStrings("Day Zero Survivor 2026", try hm.str("titles_extra.0"));
}

test "events: the Exchange is open only while an event is live, from level 10, with per-event limits" {
    var h: Harness = undefined;
    try h.init(.{ .dev = true, .limits = false });
    defer h.deinit();
    var tok: [64]u8 = undefined;
    try h.player("Trader", "human", &tok);
    var gr = try h.ok("/api/dev/grant", &tok, "{{\"salvage\":40000}}", .{});
    gr.deinit();
    var closed = try h.post("/api/events/exchange", &tok, "{\"sku\":\"ex_crate\"}");
    defer closed.deinit();
    try testing.expectEqualStrings("no_event", try closed.errorCode());

    try startEvent(&h, &tok, "supply_run", 6);
    var low = try h.post("/api/events/exchange", &tok, "{\"sku\":\"ex_crate\"}");
    defer low.deinit();
    try testing.expectEqualStrings("locked", try low.errorCode());
    try h.reachLevel(&tok, 12);

    var list = try eventsList(&h, &tok);
    defer list.deinit();
    try testing.expectEqual(true, (try list.at("exchange.open")).bool);
    try testing.expectEqual(game.data.event_exchange.len, try list.len("exchange.items"));
    var unknown = try h.post("/api/events/exchange", &tok, "{\"sku\":\"heal_s\"}");
    defer unknown.deinit();
    try testing.expectEqual(@as(u16, 404), unknown.status);

    var me0 = try h.get("/api/me", &tok);
    defer me0.deinit();
    const start_salvage = try me0.int("salvage");
    // Priority Requisition: five a head, one item each, Uncommon or better.
    for (0..5) |_| {
        var r = try h.ok("/api/events/exchange", &tok, "{{\"sku\":\"ex_requisition\"}}", .{});
        defer r.deinit();
        try testing.expectEqual(@as(usize, 1), try r.len("rewards.items"));
        try testing.expect(!std.mem.eql(u8, try r.str("rewards.items.0.rarity"), "common"));
    }
    var sold = try h.post("/api/events/exchange", &tok, "{\"sku\":\"ex_requisition\"}");
    defer sold.deinit();
    try testing.expectEqualStrings("sold_out", try sold.errorCode());
    // The Event Crate: Rare or better, two consumables; two a head.
    for (0..2) |_| {
        var r = try h.ok("/api/events/exchange", &tok, "{{\"sku\":\"ex_crate\"}}", .{});
        defer r.deinit();
        const rarity = try r.str("rewards.items.0.rarity");
        try testing.expect(std.mem.eql(u8, rarity, "rare") or std.mem.eql(u8, rarity, "legendary"));
        var n: i64 = 0;
        var it = (try r.at("rewards.consumables")).object.iterator();
        while (it.next()) |kv| n += kv.value_ptr.integer;
        try testing.expectEqual(@as(i64, 2), n);
    }
    var sold2 = try h.post("/api/events/exchange", &tok, "{\"sku\":\"ex_crate\"}");
    defer sold2.deinit();
    try testing.expectEqualStrings("sold_out", try sold2.errorCode());

    // The cosmetic variants: bought here, never in the Store, owned once.
    var store = try h.post("/api/store/buy", &tok, "{\"sku\":\"color_gilt\"}");
    defer store.deinit();
    try testing.expectEqualStrings("not_for_sale", try store.errorCode());
    var gilt = try h.ok("/api/events/exchange", &tok, "{{\"sku\":\"color_gilt\"}}", .{});
    defer gilt.deinit();
    try testing.expectEqualStrings("color_gilt", try gilt.str("rewards.unlocks.0.id"));
    try testing.expect(try hasId(&gilt, "me.cosmetics.owned", "color_gilt"));
    var again = try h.post("/api/events/exchange", &tok, "{\"sku\":\"color_gilt\"}");
    defer again.deinit();
    try testing.expect(std.mem.eql(u8, try again.errorCode(), "sold_out") or std.mem.eql(u8, try again.errorCode(), "owned"));
    var wear = try h.ok("/api/cosmetics/equip", &tok, "{{\"kind\":\"color\",\"id\":\"color_gilt\"}}", .{});
    defer wear.deinit();
    // Salvage went down by the prices (achievements may add a little back).
    var me1 = try h.get("/api/me", &tok);
    defer me1.deinit();
    const spent = start_salvage - try me1.int("salvage");
    try testing.expect(spent <= 5 * 1200 + 2 * 4000 + 6000 and spent > 5 * 1200 + 2 * 4000 + 6000 - 1500);

    // Over: closed again, and the next event starts the limits afresh.
    h.advance(7 * 3600_000);
    var over = try h.post("/api/events/exchange", &tok, "{\"sku\":\"ex_crate\"}");
    defer over.deinit();
    try testing.expectEqualStrings("no_event", try over.errorCode());
    try startEvent(&h, &tok, "horde", 6);
    var fresh = try h.ok("/api/events/exchange", &tok, "{{\"sku\":\"ex_crate\"}}", .{});
    fresh.deinit();
}

test "events: the catalog carries the events, their numbers and the Exchange" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var cat = try h.get("/api/catalog", null);
    defer cat.deinit();
    try testing.expectEqual(game.data.events.len, try cat.len("events"));
    try testing.expectEqualStrings("Blood Moon", try cat.str("events.0.names.human"));
    try testing.expectEqualStrings("The Red Feast", try cat.str("events.0.names.zombie"));
    try testing.expectEqual(@as(i64, 10), try cat.int("events.0.per_player"));
    try testing.expectEqual(@as(usize, 3), try cat.len("events.0.tiers"));
    try testing.expectEqual(game.data.event_exchange.len, try cat.len("event_exchange.items"));
    try testing.expectEqual(@as(i64, 10), try cat.int("event_exchange.min_level"));
    try testing.expect(try hasEntry(&cat, "cosmetics", "id", "color_gilt"));
}
