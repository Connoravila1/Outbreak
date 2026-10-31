//! Sign-in provider configuration and the cached signing keys (JWKS) of Google and Apple.
//! The network fetch is a free function so callers can release the global lock around it.

const std = @import("std");
const jwt = @import("jwt.zig");

const Allocator = std.mem.Allocator;

pub const Provider = enum {
    google,
    apple,
    /// Dev servers only: the subject is taken on trust.
    dev,

    pub fn fromName(name: []const u8) ?Provider {
        return std.meta.stringToEnum(Provider, name);
    }
};

pub const default_google_jwks = "https://www.googleapis.com/oauth2/v3/certs";
pub const default_apple_jwks = "https://appleid.apple.com/auth/keys";
pub const apple_bundle_id = "com.outbreak.game";

pub const google_issuers = [_][]const u8{ "accounts.google.com", "https://accounts.google.com" };
pub const apple_issuers = [_][]const u8{"https://appleid.apple.com"};

/// Comes from flags/env; the slices must outlive the server.
pub const Config = struct {
    /// Web client ID first, then Android and iOS.
    google_client_ids: []const []const u8 = &.{},
    /// The iOS bundle id and the web Services ID.
    apple_audiences: []const []const u8 = &.{},
    google_jwks_url: []const u8 = default_google_jwks,
    apple_jwks_url: []const u8 = default_apple_jwks,

    /// The web client ID the browser needs (the first Google ID).
    pub fn googleWebClientId(self: Config) ?[]const u8 {
        return if (self.google_client_ids.len > 0) self.google_client_ids[0] else null;
    }

    /// The web Services ID: the first Apple audience that is not the app's bundle id.
    pub fn appleWebServiceId(self: Config) ?[]const u8 {
        for (self.apple_audiences) |a| {
            if (!std.mem.eql(u8, a, apple_bundle_id)) return a;
        }
        return null;
    }
};

const default_ttl_s: i64 = 3600;
/// Unknown `kid` or expired cache: refetch at most this often per provider.
const refetch_gap_ms: i64 = 30_000;

const Cache = struct {
    set: jwt.KeySet = .{},
    expires_at: i64 = 0,
    last_attempt: i64 = std.math.minInt(i64) / 2,
};

pub const Verifier = struct {
    config: Config = .{},
    /// Tests turn this off: keys are injected and the network is never touched.
    fetch_enabled: bool = true,
    google: Cache = .{},
    apple: Cache = .{},

    fn cache(self: *Verifier, p: Provider) *Cache {
        return switch (p) {
            .google => &self.google,
            .apple => &self.apple,
            .dev => unreachable,
        };
    }

    pub fn configured(self: *const Verifier, p: Provider) bool {
        return switch (p) {
            .google => self.config.google_client_ids.len > 0,
            .apple => self.config.apple_audiences.len > 0,
            .dev => true,
        };
    }

    pub fn spec(self: *const Verifier, p: Provider) jwt.Spec {
        return switch (p) {
            .google => .{ .issuers = &google_issuers, .audiences = self.config.google_client_ids },
            .apple => .{ .issuers = &apple_issuers, .audiences = self.config.apple_audiences },
            .dev => unreachable,
        };
    }

    pub fn url(self: *const Verifier, p: Provider) []const u8 {
        return if (p == .google) self.config.google_jwks_url else self.config.apple_jwks_url;
    }

    /// The cached key for `kid`, if the cache is still fresh.
    pub fn find(self: *Verifier, p: Provider, kid: []const u8, now_ms: i64) ?*const jwt.Key {
        const c = self.cache(p);
        if (now_ms >= c.expires_at) return null;
        return c.set.find(kid);
    }

    /// Whether a refetch is allowed now (and not rate limited). Records the attempt.
    pub fn takeFetchTurn(self: *Verifier, p: Provider, now_ms: i64) bool {
        if (!self.fetch_enabled) return false;
        const c = self.cache(p);
        if (now_ms - c.last_attempt < refetch_gap_ms) return false;
        c.last_attempt = now_ms;
        return true;
    }

    /// Replace the cached keys with a fetched JWKS document, valid for `ttl_s`.
    pub fn store(self: *Verifier, arena: Allocator, p: Provider, json_text: []const u8, ttl_s: i64, now_ms: i64) jwt.Error!void {
        const c = self.cache(p);
        try jwt.parseJwks(arena, &c.set, json_text);
        c.expires_at = now_ms + ttl_s * 1000;
    }

    /// Test hook: install keys that never expire.
    pub fn inject(self: *Verifier, arena: Allocator, p: Provider, json_text: []const u8) jwt.Error!void {
        try self.store(arena, p, json_text, std.math.maxInt(i32), 0);
    }
};

// --- Fetch ---------------------------------------------------------------------------------------------

pub const Fetched = struct { body: []u8, ttl_s: i64 };

pub const FetchError = error{ FetchFailed, OutOfMemory };

/// `max-age` from a Cache-Control value, clamped to 60 s .. 24 h; an hour when absent.
pub fn maxAge(cache_control: ?[]const u8) i64 {
    const cc = cache_control orelse return default_ttl_s;
    const key = "max-age=";
    const at = std.mem.indexOf(u8, cc, key) orelse return default_ttl_s;
    var rest = cc[at + key.len ..];
    var n: usize = 0;
    while (n < rest.len and std.ascii.isDigit(rest[n])) n += 1;
    rest = rest[0..n];
    const v = std.fmt.parseInt(i64, rest, 10) catch return default_ttl_s;
    return std.math.clamp(v, 60, 24 * 3600);
}

/// TLS handshakes need far more stack than the 512 KiB connection threads have, so the fetch runs
/// on a thread of its own.
const fetch_stack_bytes = 8 * 1024 * 1024;

const Job = struct {
    gpa: Allocator,
    io: std.Io,
    url: []const u8,
    result: FetchError!Fetched = error.FetchFailed,

    fn run(self: *Job) void {
        self.result = fetchHere(self.gpa, self.io, self.url);
    }
};

/// GET the JWKS. Blocking; call without the global lock. The body is allocated from `gpa`.
pub fn fetchJwks(gpa: Allocator, io: std.Io, url_text: []const u8) FetchError!Fetched {
    var job = Job{ .gpa = gpa, .io = io, .url = url_text };
    const t = std.Thread.spawn(.{ .stack_size = fetch_stack_bytes }, Job.run, .{&job}) catch return error.FetchFailed;
    t.join();
    return job.result;
}

fn fetchHere(gpa: Allocator, io: std.Io, url_text: []const u8) FetchError!Fetched {
    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();
    const uri = std.Uri.parse(url_text) catch return error.FetchFailed;
    var req = client.request(.GET, uri, .{
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    }) catch return error.FetchFailed;
    defer req.deinit();
    req.sendBodiless() catch return error.FetchFailed;
    var response = req.receiveHead(&.{}) catch return error.FetchFailed;
    if (response.head.status != .ok) return error.FetchFailed;

    var ttl: i64 = default_ttl_s;
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "cache-control")) ttl = maxAge(h.value);
    }
    var transfer: [256]u8 = undefined;
    const reader = response.reader(&transfer);
    const body = reader.allocRemaining(gpa, .limited(64 * 1024)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.FetchFailed,
    };
    return .{ .body = body, .ttl_s = ttl };
}

test "max-age parsing" {
    try std.testing.expectEqual(@as(i64, 19845), maxAge("public, max-age=19845, must-revalidate, no-transform"));
    try std.testing.expectEqual(@as(i64, 3600), maxAge(null));
    try std.testing.expectEqual(@as(i64, 3600), maxAge("no-store"));
    try std.testing.expectEqual(@as(i64, 60), maxAge("max-age=1"));
    try std.testing.expectEqual(@as(i64, 86400), maxAge("max-age=99999999"));
}

test "config picks the web identifiers" {
    const c = Config{ .google_client_ids = &.{ "web", "android" }, .apple_audiences = &.{ apple_bundle_id, "com.outbreak.web" } };
    try std.testing.expectEqualStrings("web", c.googleWebClientId().?);
    try std.testing.expectEqualStrings("com.outbreak.web", c.appleWebServiceId().?);
    const empty = Config{};
    try std.testing.expect(empty.googleWebClientId() == null and empty.appleWebServiceId() == null);
}

test "cache serves injected keys and rate limits refetches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var v = Verifier{};
    try std.testing.expect(!v.configured(.google));
    try v.inject(arena.allocator(), .google, @import("jwt_fixture.zig").jwks);
    try std.testing.expect(v.find(.google, "test-key-1", 5) != null);
    try std.testing.expect(v.find(.google, "nope", 5) == null);
    try std.testing.expect(v.find(.apple, "test-key-1", 5) == null);
    try std.testing.expect(v.takeFetchTurn(.apple, 1000));
    try std.testing.expect(!v.takeFetchTurn(.apple, 2000));
    try std.testing.expect(v.takeFetchTurn(.apple, 1000 + refetch_gap_ms));
    v.fetch_enabled = false;
    try std.testing.expect(!v.takeFetchTurn(.google, 1_000_000));
}
