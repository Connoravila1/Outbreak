//! Sign-in with Google / Apple (and `dev` on dev servers), guest linking, unlinking and account
//! deletion. Verification of the provider's ID token happens before any database work, and the
//! global lock is released while signing keys are fetched.

const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const auth_mod = @import("../auth.zig");
const jwt = @import("../jwt.zig");
const views = @import("../views.zig");
const warstate = @import("../warstate.zig");
const account = @import("account.zig");
const social = @import("social.zig");

const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;
const Stringify = std.json.Stringify;
const Provider = auth_mod.Provider;

const Body = struct {
    id_token: ?[]const u8 = null,
    nonce: ?[]const u8 = null,
    /// Abandon the current (guest) character for the one this identity already owns.
    @"switch": ?bool = null,
    /// `dev` provider only.
    subject: ?[]const u8 = null,
    email: ?[]const u8 = null,
};

/// The provider named by the last path segment ("/api/auth/link/google" -> google).
fn providerOf(req: *Req) HandlerError!Provider {
    const i = std.mem.lastIndexOfScalar(u8, req.path, '/') orelse return req.fail(404, "not_found", "No such endpoint.");
    return Provider.fromName(req.path[i + 1 ..]) orelse req.fail(404, "not_found", "No such endpoint.");
}

fn niceName(p: Provider) []const u8 {
    return switch (p) {
        .google => "Google",
        .apple => "Apple",
        .dev => "dev",
    };
}

fn tokenFailure(req: *Req, e: jwt.Error) error{ Api, OutOfMemory } {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Expired => req.fail(401, "token_expired", "That sign-in expired. Please try again."),
        error.NotYetValid => req.fail(401, "invalid_token", "That sign-in is not valid yet. Check your device's clock."),
        error.Malformed, error.UnsupportedAlg => req.fail(400, "invalid_token", "That sign-in token is not valid."),
        error.UnknownKey, error.BadSignature => req.fail(401, "invalid_token", "That sign-in could not be verified."),
        error.BadIssuer, error.BadAudience => req.fail(401, "invalid_token", "That sign-in was not issued for this game."),
        error.BadNonce => req.fail(401, "invalid_token", "That sign-in did not match this request."),
    };
}

/// Verify a Google/Apple ID token (fetching signing keys if needed, with the lock released).
fn verifyToken(req: *Req, p: Provider, token: []const u8, nonce: ?[]const u8) HandlerError!jwt.Identity {
    const ctx = req.ctx;
    const v = &ctx.auth;
    if (!v.configured(p)) {
        return req.fail(503, "provider_not_configured", "Sign in with that provider is not available on this server.");
    }
    const parsed = jwt.parse(req.arena, token) catch |e| return tokenFailure(req, e);

    var fetch_failed = false;
    var key = v.find(p, parsed.kid, req.now);
    if (key == null and v.takeFetchTurn(p, req.now)) {
        // Network I/O: nothing else may be mid-transaction, and others should not wait for it.
        std.debug.assert(!req.in_txn);
        ctx.unlock();
        const fetched = auth_mod.fetchJwks(ctx.gpa, ctx.io, v.url(p));
        ctx.lock();
        if (fetched) |f| {
            defer ctx.gpa.free(f.body);
            v.store(req.arena, p, f.body, f.ttl_s, req.now) catch {
                fetch_failed = true;
            };
        } else |_| fetch_failed = true;
        key = v.find(p, parsed.kid, req.now);
    }
    const k = key orelse {
        if (fetch_failed) return req.fail(503, "provider_unavailable", "Could not reach the sign-in provider. Please try again.");
        return tokenFailure(req, error.UnknownKey);
    };
    jwt.verifySignature(parsed, k) catch |e| return tokenFailure(req, e);
    return jwt.checkClaims(parsed, @divFloor(req.now, 1000), v.spec(p), nonce) catch |e| tokenFailure(req, e);
}

fn resolveIdentity(req: *Req, p: Provider, body: Body) HandlerError!jwt.Identity {
    if (p == .dev) {
        const sub = std.mem.trim(u8, body.subject orelse "", " ");
        if (sub.len == 0 or sub.len > 255) return req.fail(400, "bad_request", "A dev sign-in needs a subject.");
        return .{ .subject = sub, .email = body.email };
    }
    const token = body.id_token orelse return req.fail(400, "bad_request", "Missing id_token.");
    return verifyToken(req, p, token, body.nonce);
}

// --- Identity rows ---------------------------------------------------------------------------------

fn owner(req: *Req, p: Provider, subject: []const u8) HandlerError!?i64 {
    return req.ctx.db.scalar("SELECT player_id FROM identities WHERE provider = ? AND subject = ?", .{ @tagName(p), subject });
}

fn identityCount(req: *Req, pid: i64) HandlerError!i64 {
    return (try req.ctx.db.scalar("SELECT COUNT(*) FROM identities WHERE player_id = ?", .{pid})) orelse 0;
}

fn hasProvider(req: *Req, pid: i64, p: Provider) HandlerError!bool {
    return (try req.ctx.db.scalar("SELECT id FROM identities WHERE player_id = ? AND provider = ?", .{ pid, @tagName(p) })) != null;
}

fn hasProgress(req: *Req, pid: i64) HandlerError!bool {
    return (try req.ctx.db.scalar("SELECT id FROM players WHERE id = ? AND faction IS NOT NULL", .{pid})) != null;
}

fn addIdentity(req: *Req, pid: i64, p: Provider, ident: jwt.Identity) HandlerError!void {
    try req.ctx.db.run(
        "INSERT INTO identities(provider, subject, player_id, email, created_at) VALUES(?,?,?,?,?)",
        .{ @tagName(p), ident.subject, pid, ident.email, req.now },
    );
}

/// An email that arrives later (or changes) refreshes the stored one; never blanks it.
fn refreshEmail(req: *Req, p: Provider, ident: jwt.Identity) HandlerError!void {
    if (ident.email) |e| {
        try req.ctx.db.run("UPDATE identities SET email = ? WHERE provider = ? AND subject = ?", .{ e, @tagName(p), ident.subject });
    }
}

// --- Handlers ---------------------------------------------------------------------------------------

/// POST /api/auth/{google|apple|dev}: sign in, or create, or link the guest that sent its token.
pub fn signIn(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(Body);
    const p = try providerOf(req);
    const ident = try resolveIdentity(req, p, body);
    try req.begin();

    if (try owner(req, p, ident.subject)) |target| {
        if (req.pid != 0 and req.pid != target) {
            // A character is already attached here; the caller is holding another one.
            if (try hasProgress(req, req.pid)) {
                if (!(body.@"switch" orelse false)) {
                    return req.fail(409, "identity_in_use", "That account already has a survivor. Switch to it? The survivor on this phone will be lost.");
                }
            }
            if ((try identityCount(req, req.pid)) == 0) try deletePlayer(req, req.pid);
        }
        try refreshEmail(req, p, ident);
        const token = try account.rotateToken(req, target);
        const me = try views.meFresh(req, target);
        return jw.write(.{ .token = @as([]const u8, &token), .me = me, .created = false });
    }

    if (req.pid != 0) {
        if (try hasProvider(req, req.pid, p)) {
            return req.fail(409, "already_linked", "This survivor is already linked to a different account of that kind.");
        }
        try addIdentity(req, req.pid, p, ident);
        const token = try account.rotateToken(req, req.pid);
        const me = try views.meFresh(req, req.pid);
        return jw.write(.{ .token = @as([]const u8, &token), .me = me, .created = false });
    }

    const np = try account.createPlayer(req, null);
    try addIdentity(req, np.id, p, ident);
    const me = try views.meFresh(req, np.id);
    try jw.write(.{ .token = @as([]const u8, &np.token), .me = me, .created = true });
}

/// POST /api/auth/link/{provider}: attach another sign-in to the current player.
pub fn link(req: *Req, jw: *Stringify) HandlerError!void {
    if (req.pid == 0) return req.fail(401, "unauthorized", "Missing token.");
    const body = try req.json(Body);
    const p = try providerOf(req);
    const ident = try resolveIdentity(req, p, body);
    try req.begin();

    if (try owner(req, p, ident.subject)) |other| {
        if (other != req.pid) {
            return req.fail(409, "identity_in_use", try std.fmt.allocPrint(req.arena, "That {s} account is already linked to another survivor.", .{niceName(p)}));
        }
        try refreshEmail(req, p, ident);
    } else {
        if (try hasProvider(req, req.pid, p)) {
            return req.fail(409, "already_linked", try std.fmt.allocPrint(req.arena, "A different {s} account is already linked.", .{niceName(p)}));
        }
        try addIdentity(req, req.pid, p, ident);
    }
    try jw.write(.{ .me = try views.meFresh(req, req.pid) });
}

/// POST /api/auth/unlink/{provider}: refuses to remove the last way back into the account.
pub fn unlink(req: *Req, jw: *Stringify) HandlerError!void {
    const p = try providerOf(req);
    if (!try hasProvider(req, req.pid, p)) return req.fail(404, "not_linked", "That account is not linked.");
    if ((try identityCount(req, req.pid)) <= 1) {
        return req.fail(409, "last_identity", "That is your only sign-in. Link another before removing it.");
    }
    try req.ctx.db.run("DELETE FROM identities WHERE player_id = ? AND provider = ?", .{ req.pid, @tagName(p) });
    try jw.write(.{ .me = try views.meFresh(req, req.pid) });
}

/// DELETE /api/account
pub fn deleteAccount(req: *Req, jw: *Stringify) HandlerError!void {
    try deletePlayer(req, req.pid);
    try jw.write(.{ .ok = true });
}

/// Remove a player and everything they own. Clan leadership passes on (or the clan disbands if
/// they were alone); chat lines stay as "[deleted]"; weekly war totals stay only as the
/// per-district aggregates, which never held a player id.
pub fn deletePlayer(req: *Req, pid: i64) HandlerError!void {
    const db = &req.ctx.db;
    var clan_id: ?i64 = null;
    var leader = false;
    {
        var st = try db.query("SELECT clan_id, clan_role FROM players WHERE id = ?", .{pid});
        defer st.finalize();
        if (try st.step()) {
            clan_id = st.optInt(0);
            leader = if (st.optText(1)) |r| std.mem.eql(u8, r, "leader") else false;
        }
    }
    if (clan_id) |cid| {
        try db.run("UPDATE players SET clan_id = NULL, clan_role = NULL WHERE id = ?", .{pid});
        try social.afterMemberLeft(req, cid, leader);
    }
    try db.run("DELETE FROM contact_log WHERE a = ? OR b = ?", .{ pid, pid });
    // Items, consumables, buffs, missions, events, war points, raid damage, snapshots, markers and
    // identities cascade; clan chat keeps its lines with the author cleared.
    try db.run("DELETE FROM players WHERE id = ?", .{pid});
    req.ctx.live.forget(pid);
    warstate.invalidateShares(req.ctx);
}
