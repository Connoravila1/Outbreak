//! Landmarks: supply caches at real places the client reports from the map's own data. This module
//! holds the pure rules: keys, names, kinds, 4-hour windows, ids, report validation, and the
//! per-player opening limit. Where places are remembered is `live.zig`.

const std = @import("std");
const data = @import("data.zig");
const geo = @import("geo.zig");

pub const Kind = data.PlaceKind;

pub const window_ms: i64 = 4 * 60 * 60 * 1000;
/// Most places accepted in one location report.
pub const max_per_report = 40;
/// A reported place must lie within this distance of the player's accepted position.
pub const report_radius_m = 450.0;
pub const key_max = 32;
pub const name_max = 48;

/// At most this many landmark caches may be opened per player per window of `limit_window_ms`.
pub const limit_count = 6;
pub const limit_window_ms: i64 = 30 * 60 * 1000;

/// Places are remembered per geohash-6 area.
pub const area_precision = 6;

pub fn windowIndex(now_ms: i64) i64 {
    return @divFloor(now_ms, window_ms);
}

/// When the next window opens (a landmark opened now restocks then).
pub fn nextWindowAt(now_ms: i64) i64 {
    return (windowIndex(now_ms) + 1) * window_ms;
}

// --- Keys and names ---------------------------------------------------------------------------------

pub fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > key_max) return false;
    for (key) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    }
    return true;
}

pub const Name = struct {
    buf: [name_max]u8 = undefined,
    len: u8 = 0,

    pub fn str(self: *const Name) []const u8 {
        return self.buf[0..self.len];
    }
};

/// A display name from untrusted text: control characters and angle brackets dropped, runs of
/// white space collapsed, trimmed, cut to 48 bytes on a character boundary. Null when nothing is left.
pub fn sanitizeName(text: []const u8) ?Name {
    var out = Name{};
    var pending_space = false;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        const clen = std.unicode.utf8ByteSequenceLength(c) catch {
            i += 1;
            continue;
        };
        if (i + clen > text.len or !std.unicode.utf8ValidateSlice(text[i .. i + clen])) {
            i += 1;
            continue;
        }
        defer i += clen;
        if (clen == 1) {
            if (c == '<' or c == '>' or c == '"' or c == '\\' or c < 0x20 or c == 0x7f) {
                if (c == '\t' or c == '\n' or c == '\r') pending_space = true;
                continue;
            }
            if (c == ' ') {
                pending_space = true;
                continue;
            }
        } else if (clen == 2 and text[i] == 0xC2 and text[i + 1] < 0xA0) continue; // C1 controls
        const need = clen + @as(usize, if (pending_space and out.len > 0) 1 else 0);
        if (out.len + need > name_max) break;
        if (pending_space and out.len > 0) {
            out.buf[out.len] = ' ';
            out.len += 1;
        }
        pending_space = false;
        @memcpy(out.buf[out.len .. out.len + clen], text[i .. i + clen]);
        out.len += @intCast(clen);
    }
    return if (out.len == 0) null else out;
}

pub fn parseKind(text: []const u8) ?Kind {
    return std.meta.stringToEnum(Kind, text);
}

// --- Ids -------------------------------------------------------------------------------------------------

pub const Id = struct {
    buf: [2 + key_max + 1 + 20]u8 = undefined,
    len: u8 = 0,

    pub fn str(self: *const Id) []const u8 {
        return self.buf[0..self.len];
    }
};

/// "l.<key>.<window>"
pub fn formatId(key: []const u8, window: i64) Id {
    var id = Id{};
    const s = std.fmt.bufPrint(&id.buf, "l.{s}.{d}", .{ key, window }) catch unreachable;
    id.len = @intCast(s.len);
    return id;
}

pub const Parsed = struct { key: []const u8, window: i64 };

pub fn parseId(s: []const u8) ?Parsed {
    if (s.len < 5 or !std.mem.startsWith(u8, s, "l.")) return null;
    const dot = std.mem.lastIndexOfScalar(u8, s, '.') orelse return null;
    if (dot <= 2) return null;
    const key = s[2..dot];
    if (!validKey(key)) return null;
    const window = std.fmt.parseInt(i64, s[dot + 1 ..], 10) catch return null;
    return .{ .key = key, .window = window };
}

/// Recompute-and-check: the id must be for this very window, and well formed.
pub fn resolveId(s: []const u8, now_ms: i64) ?Parsed {
    const p = parseId(s) orelse return null;
    if (p.window != windowIndex(now_ms)) return null;
    return p;
}

// --- Report validation ---------------------------------------------------------------------------------

pub const Report = struct {
    key: []const u8,
    kind: []const u8,
    lat: f64,
    lon: f64,
    name: ?[]const u8 = null,
};

pub const Place = struct {
    key: [key_max]u8 = undefined,
    key_len: u8 = 0,
    kind: Kind = .diner,
    lat: f64 = 0,
    lon: f64 = 0,
    name: Name = .{},

    pub fn keyStr(self: *const Place) []const u8 {
        return self.key[0..self.key_len];
    }
};

/// A report that passes the loose checks, or null: key shape, a known kind, finite coordinates
/// within `report_radius_m` of the player's accepted position.
pub fn validate(r: Report, player_lat: f64, player_lon: f64) ?Place {
    if (!validKey(r.key)) return null;
    const kind = parseKind(r.kind) orelse return null;
    if (!(std.math.isFinite(r.lat) and std.math.isFinite(r.lon))) return null;
    if (r.lat < -90 or r.lat > 90 or r.lon < -180 or r.lon > 180) return null;
    if (geo.haversineM(player_lat, player_lon, r.lat, r.lon) > report_radius_m) return null;
    var p = Place{ .kind = kind, .lat = r.lat, .lon = r.lon };
    @memcpy(p.key[0..r.key.len], r.key);
    p.key_len = @intCast(r.key.len);
    if (r.name) |n| {
        if (sanitizeName(n)) |nm| p.name = nm;
    }
    return p;
}

// --- Opening limit ------------------------------------------------------------------------------------

/// The times of a player's most recent landmark openings, newest overwriting the oldest.
pub const Opens = struct {
    at: [limit_count]i64 = [_]i64{std.math.minInt(i64) / 2} ** limit_count,
    next: u8 = 0,

    /// When the player may open another, or null if they may now.
    pub fn blockedUntil(self: *const Opens, now_ms: i64) ?i64 {
        var oldest = self.at[0];
        for (self.at) |t| oldest = @min(oldest, t);
        const free_at = oldest + limit_window_ms;
        return if (free_at > now_ms) free_at else null;
    }

    pub fn record(self: *Opens, now_ms: i64) void {
        self.at[self.next] = now_ms;
        self.next = (self.next + 1) % limit_count;
    }
};

// --- Tests -----------------------------------------------------------------------------------------------

const testing = std.testing;

test "windows are four hours; ids round trip" {
    try testing.expectEqual(@as(i64, 0), windowIndex(0));
    try testing.expectEqual(@as(i64, 0), windowIndex(window_ms - 1));
    try testing.expectEqual(@as(i64, 1), windowIndex(window_ms));
    try testing.expectEqual(@as(i64, -1), windowIndex(-1));
    try testing.expectEqual(window_ms, nextWindowAt(5));
    try testing.expectEqual(2 * window_ms, nextWindowAt(window_ms));
    const id = formatId("n123456-ab_C", 98765);
    try testing.expectEqualStrings("l.n123456-ab_C.98765", id.str());
    const p = parseId(id.str()).?;
    try testing.expectEqualStrings("n123456-ab_C", p.key);
    try testing.expectEqual(@as(i64, 98765), p.window);
    for ([_][]const u8{ "", "l.", "l.a", "l..5", "l.a.b", "x.a.5", "l.a b.5", "l.a.5.6x", "e.dr5ru7k.1.0", "l.a/b.5", "l.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.5" }) |bad| {
        try testing.expect(parseId(bad) == null);
    }
}

test "an id is valid only in its own window" {
    const now: i64 = 10 * window_ms + 12345;
    const id = formatId("k1", windowIndex(now));
    try testing.expect(resolveId(id.str(), now) != null);
    try testing.expect(resolveId(id.str(), now + window_ms) == null);
    try testing.expect(resolveId(id.str(), now - window_ms) == null);
    // The last millisecond of the window still resolves; the next one does not.
    try testing.expect(resolveId(id.str(), 11 * window_ms - 1) != null);
    try testing.expect(resolveId(id.str(), 11 * window_ms) == null);
}

test "names are sanitized" {
    try testing.expectEqualStrings("Walgreens", sanitizeName("  Walgreens ").?.str());
    try testing.expectEqualStrings("A B C", sanitizeName("A\t\tB\n C").?.str());
    try testing.expectEqualStrings("scriptalert(1)/script", sanitizeName("<script>alert(1)</script>").?.str());
    try testing.expectEqualStrings("Café Léon", sanitizeName("Café   Léon").?.str());
    try testing.expectEqualStrings("ab", sanitizeName("a\x00\x07b").?.str());
    try testing.expect(sanitizeName("") == null);
    try testing.expect(sanitizeName("   \n ") == null);
    try testing.expect(sanitizeName("<>") == null);
    // Cut to 48 bytes, never in the middle of a character.
    const long = "x" ** 60;
    try testing.expectEqual(@as(usize, 48), sanitizeName(long).?.str().len);
    const accents = "é" ** 40; // 80 bytes
    const cut = sanitizeName(accents).?.str();
    try testing.expectEqual(@as(usize, 48), cut.len);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
    // Invalid UTF-8 is dropped, not passed on.
    const dirty = sanitizeName("a\xff\xfeb").?.str();
    try testing.expectEqualStrings("ab", dirty);
    try testing.expect(std.unicode.utf8ValidateSlice(dirty));
}

test "report validation: key, kind, range, names" {
    const lat = 40.7484;
    const lon = -73.9857;
    const good = Report{ .key = "n42", .kind = "pharmacy", .lat = lat + 0.002, .lon = lon, .name = "Duane Reade" };
    const p = validate(good, lat, lon).?;
    try testing.expectEqualStrings("n42", p.keyStr());
    try testing.expectEqual(Kind.pharmacy, p.kind);
    try testing.expectEqualStrings("Duane Reade", p.name.str());
    // Every kind is accepted; sanctuaries and unknown words are not kinds at all.
    inline for (@typeInfo(Kind).@"enum".fields) |f| {
        var r = good;
        r.kind = f.name;
        try testing.expect(validate(r, lat, lon) != null);
    }
    for ([_][]const u8{ "hospital", "school", "kindergarten", "college", "university", "place_of_worship", "", "Pharmacy" }) |k| {
        var r = good;
        r.kind = k;
        try testing.expect(validate(r, lat, lon) == null);
    }
    // 450 m is the limit: 0.004 deg of latitude is about 445 m, 0.0042 about 467 m.
    var near = good;
    near.lat = lat + 0.004;
    try testing.expect(validate(near, lat, lon) != null);
    near.lat = lat + 0.0042;
    try testing.expect(validate(near, lat, lon) == null);
    var bad = good;
    bad.key = "";
    try testing.expect(validate(bad, lat, lon) == null);
    bad.key = "a.b";
    try testing.expect(validate(bad, lat, lon) == null);
    bad.key = "k" ** 33;
    try testing.expect(validate(bad, lat, lon) == null);
    bad = good;
    bad.lat = std.math.nan(f64);
    try testing.expect(validate(bad, lat, lon) == null);
    bad.lat = 95;
    try testing.expect(validate(bad, lat, lon) == null);
    // A name that sanitizes to nothing leaves the place unnamed, not rejected.
    bad = good;
    bad.name = "<>";
    try testing.expect(validate(bad, lat, lon).?.name.len == 0);
    bad.name = null;
    try testing.expect(validate(bad, lat, lon).?.name.len == 0);
}

test "the opening limit: six per half hour" {
    var o = Opens{};
    const t0: i64 = 1_000_000;
    for (0..limit_count) |i| {
        try testing.expect(o.blockedUntil(t0 + @as(i64, @intCast(i)) * 1000) == null);
        o.record(t0 + @as(i64, @intCast(i)) * 1000);
    }
    // The seventh is refused until the first one is 30 minutes old.
    try testing.expectEqual(t0 + limit_window_ms, o.blockedUntil(t0 + 10_000).?);
    try testing.expectEqual(t0 + limit_window_ms, o.blockedUntil(t0 + limit_window_ms - 1).?);
    try testing.expect(o.blockedUntil(t0 + limit_window_ms) == null);
    // Opening then frees the next slot half an hour after the second.
    o.record(t0 + limit_window_ms);
    try testing.expectEqual(t0 + 1000 + limit_window_ms, o.blockedUntil(t0 + limit_window_ms + 1).?);
}
