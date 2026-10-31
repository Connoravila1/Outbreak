//! Shared server state (`Ctx`) and the per-request context (`Req`) every handler receives.

const std = @import("std");
const game = @import("game");
const db_mod = @import("db.zig");
const live_mod = @import("live.zig");
const auth_mod = @import("auth.zig");
const client_version = @import("client_version.zig");

const Allocator = std.mem.Allocator;

pub const version = "0.1.0";

pub const Options = struct {
    /// Enables /api/dev/* endpoints.
    dev: bool = false,
    /// Per-token rate limits (relaxed when `dev` is set).
    limits: bool = true,
    /// Sign-in providers (client IDs, audiences).
    auth: auth_mod.Config = .{},
    /// Optional self-hosted map tiles (a PMTiles archive); see `Tiles`.
    tiles: Tiles = .{},
    /// The forced-update gate (see `Update`).
    update: Update = .{},
};

/// Clients older than `min_client` get 426 `update_required`. A request with no version header
/// (curl, the web dev build) is always let through.
pub const Update = struct {
    /// The oldest client allowed; null lets every version in.
    min_client: ?client_version.Version = null,
    /// `min_client` as the operator wrote it, advertised in /api/health.
    min_client_text: []const u8 = "",
    /// Store pages the update screen opens; empty: the screen shows text only.
    store_android: []const u8 = "",
    store_ios: []const u8 = "",
};

/// Map tile source advertised in /api/health. All fields are optional; with none set the client
/// uses OpenFreeMap.
pub const Tiles = struct {
    /// A PMTiles file this server serves itself at `http.tiles_path`, with range requests.
    file: []const u8 = "",
    /// Absolute URL of a PMTiles archive hosted elsewhere (used when `file` is empty).
    url: []const u8 = "",
    /// Glyph (font) URL template with {fontstack} and {range}; empty keeps OpenFreeMap's.
    glyphs: []const u8 = "",
};

/// Everything the server shares. One mutex guards the database, `live`, `rng` and `shares`.
pub const Ctx = struct {
    gpa: Allocator,
    io: std.Io,
    db: db_mod.Db,
    mutex: std.Io.Mutex = .init,
    seed: u64,
    opts: Options,
    live: live_mod.Live,
    auth: auth_mod.Verifier,
    rng: game.rng.Rng,
    /// Dev servers and tests scale the chance of a found cosmetic here (1 is the designed rate).
    cosmetic_odds: f64 = 1.0,
    /// Tests pin the clock here.
    clock_ms: ?i64 = null,
    shares: SharesCache = .{},
    /// When the once-a-minute tick work last ran.
    housekeeping_at: i64 = std.math.minInt(i64) / 2,

    pub const SharesCache = struct {
        valid: bool = false,
        at: i64 = 0,
        human: u32 = 0,
        zombie: u32 = 0,
    };

    /// Open the database at `path` (":memory:" for tests), creating the server seed on first start.
    pub fn init(gpa: Allocator, io: std.Io, path: [:0]const u8, opts: Options) !Ctx {
        var db = try db_mod.Db.open(path);
        errdefer db.close();
        const seed: u64 = if (try db.metaInt("server_seed")) |s| @bitCast(s) else blk: {
            var buf: [8]u8 = undefined;
            io.random(&buf);
            const s = std.mem.readInt(u64, &buf, .little);
            try db.setMetaInt("server_seed", @bitCast(s));
            break :blk s;
        };
        var seed_bytes: [8]u8 = undefined;
        io.random(&seed_bytes);
        return .{
            .gpa = gpa,
            .io = io,
            .db = db,
            .seed = seed,
            .opts = opts,
            .live = live_mod.Live.init(gpa),
            .auth = .{ .config = opts.auth },
            .rng = game.rng.Rng.init(std.mem.readInt(u64, &seed_bytes, .little)),
        };
    }

    pub fn deinit(self: *Ctx) void {
        self.live.deinit();
        self.db.close();
    }

    pub fn now(self: *const Ctx) i64 {
        return self.clock_ms orelse std.Io.Clock.real.now(self.io).toMilliseconds();
    }

    pub fn lock(self: *Ctx) void {
        self.mutex.lockUncancelable(self.io);
    }

    pub fn unlock(self: *Ctx) void {
        self.mutex.unlock(self.io);
    }

    /// Cryptographically random bytes (tokens, recovery codes).
    pub fn randomBytes(self: *Ctx, buf: []u8) void {
        self.io.random(buf);
    }
};

pub const Method = enum { get, post, delete, options, other };

/// A suspension, sent with a 403 so the client can say why and until when (null: for good).
pub const Ban = struct { until: ?i64, reason: []const u8 };

pub const Failure = struct { status: u16, code: []const u8, message: []const u8, ban: ?Ban = null };

/// Handlers return `error.Api` after `Req.fail` has recorded the HTTP error to send.
pub const HandlerError = error{ Api, OutOfMemory, Sqlite, WriteFailed };

pub const Req = struct {
    ctx: *Ctx,
    /// Freed when the request ends.
    arena: Allocator,
    now: i64,
    method: Method,
    path: []const u8,
    query: []const u8,
    body: []const u8,
    /// Set by the router once the bearer token is checked.
    pid: i64 = 0,
    failure: ?Failure = null,
    /// A transaction is open (the router opens one for authenticated routes; `.optional` routes
    /// call `begin` once they have finished anything slow, such as fetching signing keys).
    in_txn: bool = false,

    pub fn begin(self: *Req) db_mod.Error!void {
        if (self.in_txn) return;
        try self.ctx.db.begin();
        self.in_txn = true;
    }

    pub fn fail(self: *Req, status: u16, code: []const u8, message: []const u8) error{Api} {
        self.failure = .{ .status = status, .code = code, .message = message };
        return error.Api;
    }

    pub fn failBanned(self: *Req, until: i64, reason: []const u8) error{Api} {
        self.failure = .{
            .status = 403,
            .code = "banned",
            .message = "This account is suspended.",
            .ban = .{ .until = if (until == std.math.maxInt(i64)) null else until, .reason = reason },
        };
        return error.Api;
    }

    /// Parse the JSON body into `T`; unknown fields are ignored. 400 on anything malformed.
    pub fn json(self: *Req, comptime T: type) error{ Api, OutOfMemory }!T {
        return std.json.parseFromSliceLeaky(T, self.arena, self.body, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => self.fail(400, "bad_request", "The request body is not valid for this endpoint."),
        };
    }

    /// Value of a query-string parameter (no percent-decoding beyond '+' and %XX).
    pub fn param(self: *Req, name: []const u8) error{OutOfMemory}!?[]const u8 {
        var it = std.mem.splitScalar(u8, self.query, '&');
        while (it.next()) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            if (!std.mem.eql(u8, kv[0..eq], name)) continue;
            return try decodeComponent(self.arena, kv[eq + 1 ..]);
        }
        return null;
    }
};

fn decodeComponent(arena: Allocator, s: []const u8) error{OutOfMemory}![]const u8 {
    const out = try arena.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '+') {
            out[n] = ' ';
        } else if (s[i] == '%' and i + 2 < s.len and std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) != error.InvalidCharacter) {
            out[n] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch unreachable;
            i += 2;
        } else out[n] = s[i];
        n += 1;
    }
    return out[0..n];
}

test "query parameters decode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req: Req = undefined;
    req.arena = arena.allocator();
    req.query = "board=weekly&q=a+b%21&x";
    try std.testing.expectEqualStrings("weekly", (try req.param("board")).?);
    try std.testing.expectEqualStrings("a b!", (try req.param("q")).?);
    try std.testing.expect((try req.param("x")) == null);
    try std.testing.expect((try req.param("nope")) == null);
}

test "ctx creates the seed once and keeps it" {
    var ctx = try Ctx.init(std.testing.allocator, std.testing.io, ":memory:", .{});
    defer ctx.deinit();
    try std.testing.expectEqual(@as(?i64, @bitCast(ctx.seed)), try ctx.db.metaInt("server_seed"));
    ctx.clock_ms = 1234;
    try std.testing.expectEqual(@as(i64, 1234), ctx.now());
}
