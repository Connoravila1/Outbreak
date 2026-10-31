//! The API: routing, bearer-token auth, rate limits and error mapping, independent of any socket.
//! `handle` is what http.zig calls and what tests call directly.

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("ctx.zig");
const account = @import("api/account.zig");
const world = @import("api/world.zig");
const gear = @import("api/gear.zig");
const social = @import("api/social.zig");
const war = @import("api/war.zig");
const dev = @import("api/dev.zig");
const auth = @import("api/auth.zig");
const notes = @import("api/notes.zig");
const report = @import("api/report.zig");
const collection = @import("api/collection.zig");
const client_error = @import("api/client_error.zig");
const client_version = @import("client_version.zig");

const Ctx = ctx_mod.Ctx;
const Req = ctx_mod.Req;
const Method = ctx_mod.Method;
const HandlerError = ctx_mod.HandlerError;
const Stringify = std.json.Stringify;

pub const max_body_bytes = 64 * 1024;

pub const Response = struct {
    status: u16,
    json: []const u8,
    /// True when `json` was allocated from the context's allocator.
    owned: bool = true,

    pub fn deinit(self: Response, gpa: std.mem.Allocator) void {
        if (self.owned) gpa.free(self.json);
    }
};

const Handler = *const fn (*Req, *Stringify) HandlerError!void;
/// `optional`: a bearer token is used when it is valid, and its absence is fine. `player` needs an
/// account; `faction` needs a callsign and a faction too.
const Access = enum { public, optional, player, faction };

const Route = struct {
    method: Method,
    path: []const u8,
    access: Access,
    handler: Handler,
    dev_only: bool = false,
    /// The handler applies its own rate limit instead of the shared anonymous budget.
    own_limit: bool = false,
};

const routes = [_]Route{
    .{ .method = .get, .path = "/api/health", .access = .public, .handler = account.health },
    .{ .method = .get, .path = "/api/catalog", .access = .public, .handler = account.catalog },
    .{ .method = .get, .path = "/api/factions", .access = .public, .handler = account.factions },
    .{ .method = .post, .path = "/api/register", .access = .public, .handler = account.register },
    .{ .method = .post, .path = "/api/recover", .access = .public, .handler = account.recover },
    .{ .method = .post, .path = "/api/callsign", .access = .player, .handler = account.setCallsign },
    .{ .method = .post, .path = "/api/faction", .access = .player, .handler = account.chooseFaction },
    .{ .method = .get, .path = "/api/me", .access = .player, .handler = account.getMe },
    .{ .method = .post, .path = "/api/avatar", .access = .player, .handler = account.setAvatar },
    .{ .method = .delete, .path = "/api/account", .access = .player, .handler = auth.deleteAccount },

    .{ .method = .post, .path = "/api/auth/google", .access = .optional, .handler = auth.signIn },
    .{ .method = .post, .path = "/api/auth/apple", .access = .optional, .handler = auth.signIn },
    .{ .method = .post, .path = "/api/auth/dev", .access = .optional, .handler = auth.signIn, .dev_only = true },
    .{ .method = .post, .path = "/api/auth/link/google", .access = .player, .handler = auth.link },
    .{ .method = .post, .path = "/api/auth/link/apple", .access = .player, .handler = auth.link },
    .{ .method = .post, .path = "/api/auth/link/dev", .access = .player, .handler = auth.link, .dev_only = true },
    .{ .method = .post, .path = "/api/auth/unlink/google", .access = .player, .handler = auth.unlink },
    .{ .method = .post, .path = "/api/auth/unlink/apple", .access = .player, .handler = auth.unlink },
    .{ .method = .post, .path = "/api/auth/unlink/dev", .access = .player, .handler = auth.unlink, .dev_only = true },

    .{ .method = .post, .path = "/api/location", .access = .faction, .handler = world.location },
    .{ .method = .post, .path = "/api/patrol", .access = .faction, .handler = world.patrol },
    .{ .method = .post, .path = "/api/engage", .access = .faction, .handler = world.engage },
    .{ .method = .post, .path = "/api/open", .access = .faction, .handler = world.open },
    .{ .method = .post, .path = "/api/stance", .access = .faction, .handler = world.setStance },

    .{ .method = .post, .path = "/api/equip", .access = .faction, .handler = gear.equip },
    .{ .method = .post, .path = "/api/unequip", .access = .faction, .handler = gear.unequip },
    .{ .method = .post, .path = "/api/scrap", .access = .faction, .handler = gear.scrap },
    .{ .method = .post, .path = "/api/upgrade", .access = .faction, .handler = gear.upgrade },
    .{ .method = .post, .path = "/api/use", .access = .faction, .handler = gear.use },
    .{ .method = .post, .path = "/api/abilities", .access = .faction, .handler = gear.abilities },
    .{ .method = .post, .path = "/api/missions/claim", .access = .faction, .handler = gear.claimMission },
    .{ .method = .post, .path = "/api/store/buy", .access = .faction, .handler = gear.buy },

    .{ .method = .get, .path = "/api/notes", .access = .faction, .handler = notes.list },
    .{ .method = .post, .path = "/api/notes/claim", .access = .faction, .handler = notes.claim },

    .{ .method = .get, .path = "/api/achievements", .access = .faction, .handler = collection.achievements },
    .{ .method = .get, .path = "/api/collection", .access = .faction, .handler = collection.collection },
    .{ .method = .post, .path = "/api/cosmetics/equip", .access = .faction, .handler = collection.equipCosmetic },

    .{ .method = .get, .path = "/api/war", .access = .faction, .handler = war.war },
    .{ .method = .get, .path = "/api/leaderboard", .access = .faction, .handler = war.leaderboard },
    .{ .method = .get, .path = "/api/feed", .access = .faction, .handler = war.feed },
    .{ .method = .get, .path = "/api/clans", .access = .faction, .handler = social.clans },
    .{ .method = .post, .path = "/api/clans", .access = .faction, .handler = social.createClan },
    .{ .method = .post, .path = "/api/clans/join", .access = .faction, .handler = social.joinClan },
    .{ .method = .post, .path = "/api/clans/leave", .access = .faction, .handler = social.leaveClan },
    .{ .method = .get, .path = "/api/clan", .access = .faction, .handler = social.clan },
    .{ .method = .get, .path = "/api/clan/chat", .access = .faction, .handler = social.chat },
    .{ .method = .post, .path = "/api/clan/chat", .access = .faction, .handler = social.chat },
    .{ .method = .post, .path = "/api/report", .access = .faction, .handler = report.report },
    .{ .method = .post, .path = "/api/client-error", .access = .optional, .handler = client_error.submit, .own_limit = true },
    .{ .method = .post, .path = "/api/stronghold/claim", .access = .faction, .handler = social.claimStronghold },
    .{ .method = .post, .path = "/api/raid/attack", .access = .faction, .handler = social.raidAttack },

    .{ .method = .post, .path = "/api/dev/grant", .access = .faction, .handler = dev.grant, .dev_only = true },
    .{ .method = .post, .path = "/api/dev/heal", .access = .faction, .handler = dev.heal, .dev_only = true },
    .{ .method = .post, .path = "/api/dev/down", .access = .faction, .handler = dev.down, .dev_only = true },
    .{ .method = .post, .path = "/api/dev/spawn_raid", .access = .faction, .handler = dev.spawnRaid, .dev_only = true },
    .{ .method = .post, .path = "/api/dev/reset_cooldowns", .access = .faction, .handler = dev.resetCooldowns, .dev_only = true },
    .{ .method = .post, .path = "/api/dev/bot_contact", .access = .faction, .handler = dev.botContact, .dev_only = true },
};

/// Per-token request budget: a burst, then a steady rate. Foreground play needs about one
/// location call per 5 s plus taps.
const player_burst = 40.0;
const player_rate = 8.0;
/// Registration and recovery share one global budget.
const anon_burst = 30.0;
const anon_rate = 5.0;

const static_500 = Response{
    .status = 500,
    .json = "{\"error\":\"server_error\",\"message\":\"Something went wrong on the server.\"}",
    .owned = false,
};

fn parseMethod(m: []const u8) Method {
    if (std.mem.eql(u8, m, "GET")) return .get;
    if (std.mem.eql(u8, m, "POST")) return .post;
    if (std.mem.eql(u8, m, "DELETE")) return .delete;
    if (std.mem.eql(u8, m, "OPTIONS")) return .options;
    return .other;
}

fn errorResponse(gpa: std.mem.Allocator, status: u16, code: []const u8, message: []const u8) Response {
    const json = Stringify.valueAlloc(gpa, .{ .@"error" = code, .message = message }, .{}) catch return static_500;
    return .{ .status = status, .json = json };
}

/// Handle one request. `path` excludes the query string; `token` is the bearer token without the
/// "Bearer " prefix. Thread-safe: takes the global lock.
pub fn handle(ctx: *Ctx, method: []const u8, path: []const u8, query: []const u8, token: ?[]const u8, body: []const u8) Response {
    return handleClient(ctx, method, path, query, token, null, body);
}

/// `handle` for a request that carried an `X-Outbreak-Client` header (the client's version).
pub fn handleClient(ctx: *Ctx, method: []const u8, path: []const u8, query: []const u8, token: ?[]const u8, client: ?[]const u8, body: []const u8) Response {
    ctx.lock();
    defer ctx.unlock();
    return handleLocked(ctx, method, path, query, token, client, body);
}

/// The 426 answer for a client older than `--min-client`: where to get the new version, if known.
fn updateRequired(gpa: std.mem.Allocator, u: ctx_mod.Update) Response {
    const store = account.storeAdvert(u);
    const json = Stringify.valueAlloc(gpa, .{
        .@"error" = "update_required",
        .message = "This version of Outbreak is too old. Update to keep playing.",
        .min_client = u.min_client_text,
        .store = store,
    }, .{}) catch return static_500;
    return .{ .status = 426, .json = json };
}

/// True when the gate is on, the client named a version and it is older than the minimum. A missing
/// or unreadable header is let through. Health (so the client can check at boot) and account
/// deletion (a player may always leave) are never gated.
fn tooOld(ctx: *const Ctx, client: ?[]const u8, m: Method, path: []const u8) bool {
    const min = ctx.opts.update.min_client orelse return false;
    const v = client_version.parse(client orelse return false) orelse return false;
    if (v.order(min) != .lt) return false;
    if (std.mem.eql(u8, path, "/api/health")) return false;
    if (m == .delete and std.mem.eql(u8, path, "/api/account")) return false;
    return true;
}

fn handleLocked(ctx: *Ctx, method_text: []const u8, path: []const u8, query: []const u8, token: ?[]const u8, client: ?[]const u8, body: []const u8) Response {
    const gpa = ctx.gpa;
    const m = parseMethod(method_text);
    if (m == .options) return .{ .status = 204, .json = "", .owned = false };
    if (body.len > max_body_bytes) return errorResponse(gpa, 413, "too_large", "The request body is too large.");

    var path_known = false;
    var route: ?Route = null;
    for (routes) |r| {
        if (!std.mem.eql(u8, r.path, path)) continue;
        if (r.dev_only and !ctx.opts.dev) continue;
        path_known = true;
        if (r.method == m) route = r;
    }
    const rt = route orelse {
        if (path_known) return errorResponse(gpa, 405, "method_not_allowed", "That method is not allowed here.");
        return errorResponse(gpa, 404, "not_found", "No such endpoint.");
    };

    if (tooOld(ctx, client, m, path)) return updateRequired(gpa, ctx.opts.update);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const now = ctx.now();
    var req = Req{ .ctx = ctx, .arena = arena.allocator(), .now = now, .method = m, .path = path, .query = query, .body = body };

    const result = run(&req, rt, token) catch |e| {
        if (e == error.Api) {
            const f = req.failure.?;
            if (f.ban) |b| {
                const json = Stringify.valueAlloc(gpa, .{ .@"error" = f.code, .message = f.message, .reason = b.reason, .until = b.until }, .{}) catch return static_500;
                return .{ .status = f.status, .json = json };
            }
            return errorResponse(gpa, f.status, f.code, f.message);
        }
        std.log.err("{s} {s}: {s}", .{ method_text, path, @errorName(e) });
        return static_500;
    };
    return .{ .status = 200, .json = gpa.dupe(u8, result) catch return static_500 };
}

const Who = struct { id: i64, has_faction: bool, has_callsign: bool, last_seen: i64, banned_until: i64, ban_reason: []const u8 };

fn authenticate(req: *Req, token: []const u8) HandlerError!?Who {
    const hash = account.hashHex(token);
    var st = try req.ctx.db.query("SELECT id, faction, last_seen, callsign <> '', banned_until, ban_reason FROM players WHERE token_hash = ?", .{@as([]const u8, &hash)});
    defer st.finalize();
    if (!try st.step()) return null;
    return .{ .id = st.int(0), .has_faction = !st.isNull(1), .has_callsign = st.int(3) != 0, .last_seen = st.int(2), .banned_until = st.int(4), .ban_reason = try st.dupe(req.arena, 5) };
}

/// Auth, rate limit, then the handler inside a transaction. Returns the JSON (arena memory).
fn run(req: *Req, rt: Route, token: ?[]const u8) HandlerError![]const u8 {
    const ctx = req.ctx;
    if (rt.access == .public or rt.access == .optional) {
        if (ctx.opts.limits and rt.method != .get and !rt.own_limit) {
            if (!try ctx.live.allow(-1, req.now, anon_burst, anon_rate)) return req.fail(429, "rate_limited", "Slow down.");
        }
        // A stale token on an optional route is the same as none.
        if (rt.access == .optional) {
            if (token) |tok| {
                if (try authenticate(req, tok)) |who| req.pid = who.id;
            }
        }
    } else {
        const tok = token orelse return req.fail(401, "unauthorized", "Missing token.");
        const who = (try authenticate(req, tok)) orelse return req.fail(401, "unauthorized", "Unknown token.");
        req.pid = who.id;
        // A suspended player can still erase their account; nothing else.
        const erasing = rt.method == .delete and std.mem.eql(u8, rt.path, "/api/account");
        if (who.banned_until > req.now and !erasing) return req.failBanned(who.banned_until, who.ban_reason);
        if (rt.access == .faction and !who.has_callsign) return req.fail(409, "no_callsign", "Choose a callsign first.");
        if (rt.access == .faction and !who.has_faction) return req.fail(409, "no_faction", "Choose a faction first.");
        if (ctx.opts.limits and !ctx.opts.dev) {
            if (!try ctx.live.allow(req.pid, req.now, player_burst, player_rate)) return req.fail(429, "rate_limited", "Slow down.");
        }
        try req.begin();
        if (req.now - who.last_seen > 60_000) try ctx.db.run("UPDATE players SET last_seen = ? WHERE id = ?", .{ req.now, req.pid });
    }
    errdefer if (req.in_txn) ctx.db.rollback();

    var aw: std.Io.Writer.Allocating = .init(req.arena);
    var jw = Stringify{ .writer = &aw.writer, .options = .{} };
    try rt.handler(req, &jw);
    if (req.in_txn) try ctx.db.commit();
    return aw.written();
}
