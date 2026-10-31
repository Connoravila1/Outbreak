//! ID-token verification for Sign in with Google / Apple: JWT parsing, JWKS parsing, RS256
//! (RSASSA-PKCS1-v1_5 + SHA-256) signature checks via std's RSA, and claim checks. Pure: no
//! network, no clock, no database. Tokens are never logged.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const rsa = std.crypto.Certificate.rsa;
const b64 = std.base64.url_safe_no_pad;

pub const Error = error{
    Malformed,
    UnsupportedAlg,
    UnknownKey,
    BadSignature,
    Expired,
    NotYetValid,
    BadIssuer,
    BadAudience,
    BadNonce,
    OutOfMemory,
};

/// Clock leeway for `exp` and `iat`.
pub const leeway_s: i64 = 60;
pub const max_keys = 16;

/// One RSA public key from a JWKS (fixed storage; 4096-bit moduli fit).
pub const Key = struct {
    kid_buf: [64]u8 = undefined,
    kid_len: u8 = 0,
    n_buf: [512]u8 = undefined,
    n_len: u16 = 0,
    e_buf: [8]u8 = undefined,
    e_len: u8 = 0,

    pub fn kid(self: *const Key) []const u8 {
        return self.kid_buf[0..self.kid_len];
    }
    pub fn modulus(self: *const Key) []const u8 {
        return self.n_buf[0..self.n_len];
    }
    pub fn exponent(self: *const Key) []const u8 {
        return self.e_buf[0..self.e_len];
    }
};

pub const KeySet = struct {
    keys: [max_keys]Key = undefined,
    len: usize = 0,

    pub fn find(self: *const KeySet, kid: []const u8) ?*const Key {
        for (self.keys[0..self.len]) |*k| {
            if (std.mem.eql(u8, k.kid(), kid)) return k;
        }
        return null;
    }
};

fn decodeInto(arena: Allocator, text: []const u8) Error![]u8 {
    const n = b64.Decoder.calcSizeForSlice(text) catch return error.Malformed;
    const out = try arena.alloc(u8, n);
    b64.Decoder.decode(out, text) catch return error.Malformed;
    return out;
}

/// Parse a JWKS document, keeping the RSA keys (at most `max_keys`). Replaces `set`.
pub fn parseJwks(arena: Allocator, set: *KeySet, json_text: []const u8) Error!void {
    const Jwk = struct { kty: ?[]const u8 = null, kid: ?[]const u8 = null, n: ?[]const u8 = null, e: ?[]const u8 = null };
    const Doc = struct { keys: []const Jwk };
    const doc = std.json.parseFromSliceLeaky(Doc, arena, json_text, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Malformed,
    };
    var out = KeySet{};
    for (doc.keys) |k| {
        if (out.len == max_keys) break;
        if (!std.mem.eql(u8, k.kty orelse continue, "RSA")) continue;
        const kid = k.kid orelse continue;
        const n_raw = try decodeInto(arena, k.n orelse continue);
        const e_raw = try decodeInto(arena, k.e orelse continue);
        var n: []const u8 = n_raw;
        while (n.len > 1 and n[0] == 0) n = n[1..];
        var e: []const u8 = e_raw;
        while (e.len > 1 and e[0] == 0) e = e[1..];
        const slot = &out.keys[out.len];
        if (kid.len > slot.kid_buf.len or n.len > slot.n_buf.len or e.len > slot.e_buf.len or e.len == 0) continue;
        @memcpy(slot.kid_buf[0..kid.len], kid);
        slot.kid_len = @intCast(kid.len);
        @memcpy(slot.n_buf[0..n.len], n);
        slot.n_len = @intCast(n.len);
        @memcpy(slot.e_buf[0..e.len], e);
        slot.e_len = @intCast(e.len);
        out.len += 1;
    }
    set.* = out;
}

/// Claims we care about. `aud`, `exp` and `iat` vary in type between issuers, so they stay loose.
const Payload = struct {
    iss: ?[]const u8 = null,
    sub: ?[]const u8 = null,
    aud: ?std.json.Value = null,
    exp: ?std.json.Value = null,
    iat: ?std.json.Value = null,
    nonce: ?[]const u8 = null,
    email: ?[]const u8 = null,
};

pub const Parsed = struct {
    kid: []const u8,
    /// "header.payload" exactly as signed.
    signing_input: []const u8,
    signature: []const u8,
    payload: Payload,
};

pub fn parse(arena: Allocator, token: []const u8) Error!Parsed {
    if (token.len > 8192) return error.Malformed;
    var it = std.mem.splitScalar(u8, token, '.');
    const h_text = it.next() orelse return error.Malformed;
    const p_text = it.next() orelse return error.Malformed;
    const s_text = it.next() orelse return error.Malformed;
    if (it.next() != null or h_text.len == 0 or p_text.len == 0 or s_text.len == 0) return error.Malformed;

    const Header = struct { alg: ?[]const u8 = null, kid: ?[]const u8 = null };
    const header = std.json.parseFromSliceLeaky(Header, arena, try decodeInto(arena, h_text), .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Malformed,
    };
    // Only RS256 is accepted: never "none", never a MAC keyed with a public key.
    if (!std.mem.eql(u8, header.alg orelse return error.Malformed, "RS256")) return error.UnsupportedAlg;
    const payload = std.json.parseFromSliceLeaky(Payload, arena, try decodeInto(arena, p_text), .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Malformed,
    };
    return .{
        .kid = header.kid orelse return error.Malformed,
        .signing_input = token[0 .. h_text.len + 1 + p_text.len],
        .signature = try decodeInto(arena, s_text),
        .payload = payload,
    };
}

pub fn verifySignature(parsed: Parsed, key: *const Key) Error!void {
    const pk = rsa.PublicKey.fromBytes(key.exponent(), key.modulus()) catch return error.BadSignature;
    switch (key.n_len) {
        inline 128, 256, 384, 512 => |len| {
            if (parsed.signature.len != len) return error.BadSignature;
            rsa.PKCS1v1_5Signature.verify(len, parsed.signature[0..len].*, parsed.signing_input, pk, Sha256) catch return error.BadSignature;
        },
        else => return error.BadSignature,
    }
}

fn seconds(v: ?std.json.Value) ?i64 {
    return switch (v orelse return null) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f) and @abs(f) < 1e15) @as(i64, @intFromFloat(f)) else null,
        else => null,
    };
}

pub const Spec = struct {
    issuers: []const []const u8,
    audiences: []const []const u8,
};

pub const Identity = struct { subject: []const u8, email: ?[]const u8 };

fn listed(list: []const []const u8, s: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, s)) return true;
    }
    return false;
}

/// Check the claims of a token whose signature has already been verified. `nonce` is the raw
/// value the client says it used; the token may carry it as is (Google) or as lowercase SHA-256
/// hex (Apple). Skipped when the client sent none.
pub fn checkClaims(p: Parsed, now_sec: i64, spec: Spec, nonce: ?[]const u8) Error!Identity {
    const c = p.payload;
    const exp = seconds(c.exp) orelse return error.Malformed;
    const iat = seconds(c.iat) orelse return error.Malformed;
    if (now_sec > exp + leeway_s) return error.Expired;
    if (iat > now_sec + leeway_s) return error.NotYetValid;
    if (!listed(spec.issuers, c.iss orelse return error.BadIssuer)) return error.BadIssuer;

    const aud = c.aud orelse return error.BadAudience;
    const aud_ok = switch (aud) {
        .string => |s| listed(spec.audiences, s),
        .array => |a| blk: {
            for (a.items) |item| {
                if (item == .string and listed(spec.audiences, item.string)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
    if (!aud_ok) return error.BadAudience;

    if (nonce) |raw| {
        const claim = c.nonce orelse return error.BadNonce;
        var digest: [32]u8 = undefined;
        Sha256.hash(raw, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, claim, raw) and !std.mem.eql(u8, claim, &hex)) return error.BadNonce;
    }

    const sub = c.sub orelse return error.Malformed;
    if (sub.len == 0 or sub.len > 255) return error.Malformed;
    return .{ .subject = sub, .email = if (c.email) |e| (if (e.len > 0 and e.len <= 254) e else null) else null };
}

/// Parse, find the key, verify the signature, then the claims.
pub fn verify(arena: Allocator, token: []const u8, keys: *const KeySet, now_sec: i64, spec: Spec, nonce: ?[]const u8) Error!Identity {
    const parsed = try parse(arena, token);
    const key = keys.find(parsed.kid) orelse return error.UnknownKey;
    try verifySignature(parsed, key);
    return checkClaims(parsed, now_sec, spec, nonce);
}

// --- Tests -------------------------------------------------------------------------------------------

const fx = @import("jwt_fixture.zig");
const testing = std.testing;

const google_spec = Spec{
    .issuers = &.{ "accounts.google.com", "https://accounts.google.com" },
    .audiences = &.{ fx.web_client_id, "android.apps.googleusercontent.com" },
};
const apple_spec = Spec{ .issuers = &.{"https://appleid.apple.com"}, .audiences = &.{ fx.apple_bundle, "com.outbreak.web" } };

fn check(token: []const u8, spec: Spec, nonce: ?[]const u8) Error!void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var set = KeySet{};
    try parseJwks(arena.allocator(), &set, fx.jwks);
    _ = try verify(arena.allocator(), token, &set, fx.now_sec, spec, nonce);
}

/// Like `check` but copies the subject and email out of the arena into caller buffers.
fn checkSubject(token: []const u8, spec: Spec, nonce: ?[]const u8, sub: *[64]u8, email: *?[]const u8, email_buf: *[64]u8) Error![]const u8 {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var set = KeySet{};
    try parseJwks(arena.allocator(), &set, fx.jwks);
    const id = try verify(arena.allocator(), token, &set, fx.now_sec, spec, nonce);
    @memcpy(sub[0..id.subject.len], id.subject);
    email.* = if (id.email) |e| blk: {
        @memcpy(email_buf[0..e.len], e);
        break :blk email_buf[0..e.len];
    } else null;
    return sub[0..id.subject.len];
}

test "jwks: parses the test key and ignores non-RSA entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var set = KeySet{};
    try parseJwks(arena.allocator(), &set, fx.jwks);
    try testing.expectEqual(@as(usize, 1), set.len);
    try testing.expectEqualStrings("test-key-1", set.keys[0].kid());
    try testing.expectEqual(@as(u16, 256), set.keys[0].n_len);
    try testing.expectEqual(@as(?*const Key, null), set.find("other"));

    try parseJwks(arena.allocator(), &set, "{\"keys\":[{\"kty\":\"EC\",\"kid\":\"x\"},{\"kty\":\"RSA\",\"kid\":\"y\"}]}");
    try testing.expectEqual(@as(usize, 0), set.len);
    try testing.expectError(error.Malformed, parseJwks(arena.allocator(), &set, "not json"));
}

test "a good Google token verifies, with either issuer spelling and array audiences" {
    var sub: [64]u8 = undefined;
    var email: ?[]const u8 = null;
    var eb: [64]u8 = undefined;
    try testing.expectEqualStrings("g-sub-1", try checkSubject(fx.google_1, google_spec, null, &sub, &email, &eb));
    try testing.expectEqualStrings("g-sub-1@example.com", email.?);
    _ = try checkSubject(fx.google_https_iss, google_spec, null, &sub, &email, &eb);
    _ = try checkSubject(fx.google_aud_array, google_spec, null, &sub, &email, &eb);
    // Leeway: 30 s past expiry is still fine.
    _ = try checkSubject(fx.google_just_expired, google_spec, null, &sub, &email, &eb);
}

test "bad tokens are refused for the right reason" {
    try testing.expectError(error.Expired, check(fx.google_expired, google_spec, null));
    try testing.expectError(error.BadAudience, check(fx.google_wrong_aud, google_spec, null));
    try testing.expectError(error.BadIssuer, check(fx.google_wrong_iss, google_spec, null));
    try testing.expectError(error.NotYetValid, check(fx.google_future_iat, google_spec, null));
    try testing.expectError(error.BadSignature, check(fx.google_bad_sig, google_spec, null));
    try testing.expectError(error.BadSignature, check(fx.google_tampered, google_spec, null));
    try testing.expectError(error.UnknownKey, check(fx.google_unknown_kid, google_spec, null));
    // A Google token is not an Apple token.
    try testing.expectError(error.BadIssuer, check(fx.google_1, apple_spec, null));
}

test "malformed tokens and the none algorithm are refused" {
    try testing.expectError(error.Malformed, check("", google_spec, null));
    try testing.expectError(error.Malformed, check("a.b", google_spec, null));
    try testing.expectError(error.Malformed, check("a.b.c.d", google_spec, null));
    try testing.expectError(error.Malformed, check("!!!.@@@.###", google_spec, null));
    // {"alg":"none","kid":"test-key-1"} . {"sub":"x"} . (empty signature is malformed, any is wrong alg)
    try testing.expectError(error.UnsupportedAlg, check("eyJhbGciOiJub25lIiwia2lkIjoidGVzdC1rZXktMSJ9.eyJzdWIiOiJ4In0.AAAA", google_spec, null));
    // HS256 with the right kid.
    try testing.expectError(error.UnsupportedAlg, check("eyJhbGciOiJIUzI1NiIsImtpZCI6InRlc3Qta2V5LTEifQ.eyJzdWIiOiJ4In0.AAAA", google_spec, null));
}

test "Apple nonce: raw value is hashed and compared; a wrong or missing claim fails" {
    var sub: [64]u8 = undefined;
    var email: ?[]const u8 = null;
    var eb: [64]u8 = undefined;
    try testing.expectEqualStrings("apple-sub-1", try checkSubject(fx.apple_1, apple_spec, fx.raw_nonce, &sub, &email, &eb));
    try testing.expectEqualStrings("relay@privaterelay.appleid.com", email.?);
    // Not checked when the client sent none.
    _ = try checkSubject(fx.apple_1, apple_spec, null, &sub, &email, &eb);
    try testing.expectError(error.BadNonce, check(fx.apple_1, apple_spec, "other-nonce"));
    // A token with no nonce claim cannot satisfy a client that sent one.
    try testing.expectError(error.BadNonce, check(fx.google_1, google_spec, "anything"));
    _ = try checkSubject(fx.apple_no_email, apple_spec, fx.raw_nonce, &sub, &email, &eb);
    try testing.expect(email == null);
}
