//! The weekly war: point values, week boundaries (Monday 00:00 UTC) and districts.

const std = @import("std");
const geo = @import("geo.zig");

pub const day_ms: i64 = 24 * 60 * 60 * 1000;
pub const week_ms: i64 = 7 * day_ms;
pub const district_precision = 4;

pub const Action = enum { pve_win, pve_elite, cache, echo_win, pvp_win, stronghold_hour };

pub fn points(action: Action) u32 {
    return switch (action) {
        .pve_win => 1,
        .pve_elite => 3,
        .cache => 1,
        .echo_win => 3,
        .pvp_win => 10,
        .stronghold_hour => 2,
    };
}

pub const raid_points_full_share = 50;

/// Raid damage is worth up to 50 points, in proportion to the share of the boss's HP you dealt.
pub fn raidPoints(damage_share: f32) u32 {
    const s = std.math.clamp(damage_share, 0.0, 1.0);
    return @intFromFloat(@round(s * raid_points_full_share));
}

pub fn dayIndex(now_ms: i64) i64 {
    return @divFloor(now_ms, day_ms);
}

/// Unix day 0 (1970-01-01) was a Thursday, so Mondays fall on days 4, 11, 18, ...
const monday_offset_days = 4;

pub fn weekIndex(now_ms: i64) i64 {
    return @divFloor(dayIndex(now_ms) - monday_offset_days, 7);
}

/// Start of week `index` (a Monday 00:00 UTC), in unix milliseconds.
pub fn weekStart(index: i64) i64 {
    return (index * 7 + monday_offset_days) * day_ms;
}

/// When the week containing `now_ms` ends, which is also the next reset.
pub fn weekEnd(now_ms: i64) i64 {
    return weekStart(weekIndex(now_ms) + 1);
}

/// The geohash-4 district containing a point (about 39 km x 20 km).
pub fn districtId(lat: f64, lon: f64) geo.Geohash {
    return geo.encode(lat, lon, district_precision);
}

test "point values" {
    try std.testing.expectEqual(@as(u32, 1), points(.pve_win));
    try std.testing.expectEqual(@as(u32, 3), points(.pve_elite));
    try std.testing.expectEqual(@as(u32, 1), points(.cache));
    try std.testing.expectEqual(@as(u32, 3), points(.echo_win));
    try std.testing.expectEqual(@as(u32, 10), points(.pvp_win));
    try std.testing.expectEqual(@as(u32, 2), points(.stronghold_hour));
    try std.testing.expectEqual(@as(u32, 25), raidPoints(0.5));
    try std.testing.expectEqual(@as(u32, 50), raidPoints(3.0));
    try std.testing.expectEqual(@as(u32, 0), raidPoints(-1));
}

test "weeks start on Monday 00:00 UTC" {
    // 2025-01-06 00:00:00 UTC was a Monday.
    const monday: i64 = 1_736_121_600_000;
    try std.testing.expectEqual(@as(i64, 2870), weekIndex(monday));
    try std.testing.expectEqual(monday, weekStart(2870));
    try std.testing.expectEqual(@as(i64, 2869), weekIndex(monday - 1));
    try std.testing.expectEqual(@as(i64, 2870), weekIndex(monday + week_ms - 1));
    try std.testing.expectEqual(@as(i64, 2871), weekIndex(monday + week_ms));
    try std.testing.expectEqual(monday + week_ms, weekEnd(monday + 3 * day_ms));
    // Saturday 2026-10-31 12:00 UTC falls in the week that began Monday 2026-10-26.
    try std.testing.expectEqual(@as(i64, 1_793_448_000_000 - 5 * day_ms - 12 * 3600 * 1000), weekStart(weekIndex(1_793_448_000_000)));
    // Week zero starts on the first Monday after the epoch; the epoch itself is week -1.
    try std.testing.expectEqual(@as(i64, -1), weekIndex(0));
    try std.testing.expectEqual(@as(i64, 4 * day_ms), weekStart(0));
}

test "districts are geohash-4" {
    const d = districtId(40.7484, -73.9857);
    try std.testing.expectEqual(@as(u8, 4), d.len);
    try std.testing.expectEqualStrings("dr5r", d.str());
    try std.testing.expect(d.eql(&districtId(40.75, -73.98)));
}
