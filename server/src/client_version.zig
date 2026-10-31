//! Client versions for the forced-update gate: "1.2.3" (a leading "v" and a "-beta" or "+build"
//! suffix are tolerated; missing minor and patch count as 0).

const std = @import("std");

pub const Version = struct {
    major: u32,
    minor: u32 = 0,
    patch: u32 = 0,

    pub fn order(a: Version, b: Version) std.math.Order {
        const x = [3]u32{ a.major, a.minor, a.patch };
        const y = [3]u32{ b.major, b.minor, b.patch };
        return std.mem.order(u32, &x, &y);
    }
};

/// Null when `text` is not a version at all.
pub fn parse(text: []const u8) ?Version {
    var s = std.mem.trim(u8, text, " \t");
    if (s.len > 0 and (s[0] == 'v' or s[0] == 'V')) s = s[1..];
    if (std.mem.indexOfAny(u8, s, "-+")) |i| s = s[0..i];
    if (s.len == 0) return null;
    var parts = [3]u32{ 0, 0, 0 };
    var it = std.mem.splitScalar(u8, s, '.');
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (n == 3) return null;
        parts[n] = std.fmt.parseInt(u32, part, 10) catch return null;
    }
    return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
}

test "versions parse and compare" {
    const t = std.testing;
    const v = parse("1.2.3").?;
    try t.expectEqual(@as(u32, 2), v.minor);
    try t.expectEqual(std.math.Order.lt, parse("0.1.0").?.order(parse("0.2.0").?));
    try t.expectEqual(std.math.Order.lt, parse("0.9.9").?.order(parse("0.10.0").?));
    try t.expectEqual(std.math.Order.eq, parse("v1.2").?.order(parse("1.2.0-beta+7").?));
    try t.expectEqual(std.math.Order.gt, parse("2").?.order(parse("1.99.99").?));
    try t.expect(parse("") == null);
    try t.expect(parse("abc") == null);
    try t.expect(parse("1.2.3.4") == null);
    try t.expect(parse("1..2") == null);
    try t.expect(parse("-1.0.0") == null);
}
