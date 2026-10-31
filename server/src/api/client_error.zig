//! Crash and error reports from the app: POST /api/client-error. Anonymous by design: no player id
//! is stored, only what went wrong, where, and on which build. Text is cut to size and scrubbed of
//! anything that could be a position (see `scrub`) before it is kept. The table holds the newest
//! `cap_rows` reports; `outbreak-server admin errors` groups them.

const std = @import("std");
const ctx_mod = @import("../ctx.zig");

const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;
const Stringify = std.json.Stringify;
const Allocator = std.mem.Allocator;

pub const message_max = 500;
pub const stack_max = 4000;
pub const cap_rows = 5000;
/// Reports one request may carry (the client sends its queue in batches).
pub const batch_max = 10;

/// Rate limits, kept separate from the game budget: a player with a valid token gets a bucket of
/// their own, everyone else shares one.
const player_burst = 6.0;
const player_rate = 0.1;
const anon_burst = 30.0;
const anon_rate = 0.5;
const anon_key: i64 = -2;
fn playerKey(pid: i64) i64 {
    return -1000 - pid;
}

const Item = struct {
    message: []const u8 = "",
    stack: []const u8 = "",
    version: []const u8 = "",
    platform: []const u8 = "",
    screen: []const u8 = "",
};

/// A single report, or `{reports: [...]}` for a batch. The client's own `ts` is accepted and
/// ignored: phone clocks are wrong, the server stamps its own time.
const Body = struct {
    message: []const u8 = "",
    stack: []const u8 = "",
    version: []const u8 = "",
    platform: []const u8 = "",
    screen: []const u8 = "",
    reports: ?[]const Item = null,
};

/// Longest prefix of `s` that is at most `max` bytes and ends on a character boundary.
pub fn clipUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var cut = max;
    while (cut > 0 and (s[cut] & 0xC0) == 0x80) cut -= 1;
    return s[0..cut];
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isDelimiter(c: u8) bool {
    return std.ascii.isWhitespace(c) or std.mem.indexOfScalar(u8, "\"'()<>[]`", c) != null;
}

/// How many bytes at the end of `tok` are a ":line" or ":line:col" position.
fn lineColSuffix(tok: []const u8) usize {
    var end = tok.len;
    var parts: usize = 0;
    while (parts < 2) {
        var i = end;
        while (i > 0 and isDigit(tok[i - 1])) i -= 1;
        if (i == end or i == 0 or tok[i - 1] != ':') break;
        end = i - 1;
        parts += 1;
    }
    return tok.len - end;
}

/// Remove what could point at a place: query strings and fragments from URLs and paths (a stack
/// frame keeps its ":line:col"), and any decimal number with four or more fractional digits and
/// at most three whole digits (a latitude or longitude), which becomes "~".
pub fn scrub(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    // Pass 1: URLs and paths, token by token.
    var stripped: std.ArrayList(u8) = .empty;
    while (i < text.len) {
        if (isDelimiter(text[i])) {
            try stripped.append(arena, text[i]);
            i += 1;
            continue;
        }
        var j = i;
        while (j < text.len and !isDelimiter(text[j])) j += 1;
        const tok = text[i..j];
        const urlish = std.mem.indexOf(u8, tok, "://") != null or tok[0] == '/';
        const cut = if (urlish) std.mem.indexOfAny(u8, tok, "?#") else null;
        if (cut) |c| {
            try stripped.appendSlice(arena, tok[0..c]);
            try stripped.appendSlice(arena, tok[tok.len - lineColSuffix(tok) ..]);
        } else try stripped.appendSlice(arena, tok);
        i = j;
    }
    // Pass 2: coordinates.
    const s = stripped.items;
    i = 0;
    while (i < s.len) {
        const c = s[i];
        const boundary = i == 0 or !(isDigit(s[i - 1]) or s[i - 1] == '.' or std.ascii.isAlphabetic(s[i - 1]));
        if (boundary and (isDigit(c) or (c == '-' and i + 1 < s.len and isDigit(s[i + 1])))) {
            var j = i + @intFromBool(c == '-');
            const whole_start = j;
            while (j < s.len and isDigit(s[j])) j += 1;
            const whole = j - whole_start;
            if (whole <= 3 and j < s.len and s[j] == '.') {
                var k = j + 1;
                while (k < s.len and isDigit(s[k])) k += 1;
                if (k - (j + 1) >= 4) {
                    try out.append(arena, '~');
                    i = k;
                    continue;
                }
            }
        }
        try out.append(arena, c);
        i += 1;
    }
    return out.items;
}

/// The first line of a stack that looks like a frame ("at f (url:1:2)" or "f@url:1:2"); empty if none.
pub fn topFrame(stack: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, stack, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "at ") or std.mem.indexOfScalar(u8, line, '@') != null) return clipUtf8(line, 300);
    }
    return "";
}

/// Reports of one fault share a hash: the message with its digit runs folded (ids, counts, ports)
/// plus the top stack frame.
pub fn groupHash(message: []const u8, frame: []const u8) [16]u8 {
    var h = std.hash.Wyhash.init(0);
    var prev_digit = false;
    for (message) |c| {
        const d = isDigit(c);
        if (d and prev_digit) continue;
        h.update(&[_]u8{if (d) '#' else c});
        prev_digit = d;
    }
    h.update("\x00");
    h.update(frame);
    var out: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x:0>16}", .{h.final()}) catch unreachable;
    return out;
}

/// Trim, clip to `max` bytes and scrub; null when the result is empty or not text.
fn clean(arena: Allocator, s: []const u8, max: usize) Allocator.Error!?[]const u8 {
    const t = std.mem.trim(u8, clipUtf8(s, max), " \t\r\n");
    if (!std.unicode.utf8ValidateSlice(t)) return null;
    const out = try scrub(arena, t);
    return if (out.len == 0) null else out;
}

fn short(s: []const u8, max: usize) []const u8 {
    const t = std.mem.trim(u8, clipUtf8(s, max), " \t\r\n");
    return if (std.unicode.utf8ValidateSlice(t)) t else "";
}

/// POST /api/client-error {message, stack?, version?, platform?, screen?, ts?} or {reports: [...]}.
/// Answers {ok, stored}; a report with no message, or that is not text, is skipped.
pub fn submit(req: *Req, jw: *Stringify) HandlerError!void {
    const ctx = req.ctx;
    if (ctx.opts.limits) {
        const key = if (req.pid > 0) playerKey(req.pid) else anon_key;
        const ok = if (req.pid > 0) try ctx.live.allow(key, req.now, player_burst, player_rate) else try ctx.live.allow(key, req.now, anon_burst, anon_rate);
        if (!ok) return req.fail(429, "rate_limited", "Slow down.");
    }
    const body = try req.json(Body);
    const single = [_]Item{.{ .message = body.message, .stack = body.stack, .version = body.version, .platform = body.platform, .screen = body.screen }};
    const items: []const Item = if (body.reports) |r| r[0..@min(r.len, batch_max)] else &single;

    try req.begin();
    var stored: u32 = 0;
    for (items) |it| {
        const message = (try clean(req.arena, it.message, message_max)) orelse continue;
        const stack = (try clean(req.arena, it.stack, stack_max)) orelse "";
        const frame = topFrame(stack);
        const hash = groupHash(message, frame);
        try ctx.db.run(
            "INSERT INTO client_errors(at, hash, message, stack, frame, version, platform, screen) VALUES(?,?,?,?,?,?,?,?)",
            .{ req.now, @as([]const u8, &hash), message, stack, frame, short(it.version, 32), short(it.platform, 16), short(it.screen, 32) },
        );
        stored += 1;
    }
    if (stored > 0) try ctx.db.run("DELETE FROM client_errors WHERE id <= (SELECT MAX(id) FROM client_errors) - ?", .{@as(i64, cap_rows)});
    try jw.write(.{ .ok = true, .stored = stored });
}

test "scrub removes query strings and coordinates, keeps frames" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const t = std.testing;
    try t.expectEqualStrings(
        "at f (http://localhost:5192/src/app.tsx:12:5)",
        try scrub(a, "at f (http://localhost:5192/src/app.tsx?t=1730000:12:5)"),
    );
    try t.expectEqualStrings("POST /api/location failed", try scrub(a, "POST /api/location?lat=1&lon=2 failed"));
    try t.expectEqualStrings("bad fix ~, ~ here", try scrub(a, "bad fix 47.60970, -122.33310 here"));
    try t.expectEqualStrings("{\"lat\":~,\"lon\":~}", try scrub(a, "{\"lat\":40.7411234,\"lon\":-73.98971}"));
    // Not a position: short fractions, versions, big timestamps, "Unexpected token '?'".
    try t.expectEqualStrings("took 1.5s on 0.1.0 at 1730000000.12345", try scrub(a, "took 1.5s on 0.1.0 at 1730000000.12345"));
    try t.expectEqualStrings("Unexpected token '?'", try scrub(a, "Unexpected token '?'"));
}

test "top frame and group hash" {
    const t = std.testing;
    try t.expectEqualStrings("at b (x.js:1:2)", topFrame("Error: boom\n    at b (x.js:1:2)\n    at c (y.js:3:4)"));
    try t.expectEqualStrings("go@x.js:9:9", topFrame("go@x.js:9:9\nrun@x.js:1:1"));
    try t.expectEqualStrings("", topFrame("just text"));
    const a = groupHash("Row 12 missing", "at b (x.js:1:2)");
    const b = groupHash("Row 345 missing", "at b (x.js:1:2)");
    const c = groupHash("Row 12 missing", "at z (x.js:7:2)");
    try t.expectEqualSlices(u8, &a, &b);
    try t.expect(!std.mem.eql(u8, &a, &c));
}

test "clipUtf8 never splits a character" {
    try std.testing.expectEqualStrings("ab", clipUtf8("abé", 3));
    try std.testing.expectEqualStrings("abé", clipUtf8("abé", 4));
}
