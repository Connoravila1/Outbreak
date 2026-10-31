//! Limited-time global events (DESIGN.md section 18): the calendar, what an event changes in the
//! systems that already exist, and the goal and reward maths. Pure: the definitions are in
//! data.zig, the clock comes in as an argument, nothing is stored here.
//!
//! The calendar is a function of the UTC week alone, so every server runs the same rotation with
//! no setup. Events stay Tuesday to Saturday 00:00; raids own the weekend and never overlap them.

const std = @import("std");
const data = @import("data.zig");
const war = @import("war.zig");
const daynight = @import("daynight.zig");

pub const Type = data.EventType;
const hour_ms: i64 = 60 * 60 * 1000;
const day_ms = war.day_ms;

pub const Occurrence = struct {
    type: Type,
    starts_at: i64,
    ends_at: i64,
    /// The swarm's archetype (an `data.Archetype` value) for the Horde event; 0 otherwise.
    param: u8 = 0,
};

/// A live event as the rules need it.
pub const Active = struct {
    type: Type,
    param: u8 = 0,

    pub fn def(self: Active) data.EventDef {
        return data.eventDef(self.type);
    }

    pub fn swarm(self: Active) ?data.Archetype {
        if (self.type != .horde) return null;
        return @enumFromInt(self.param);
    }
};

// --- The calendar --------------------------------------------------------------------------------

/// The first slot runs Tuesday 00:00 to Thursday 00:00, the second Thursday 12:00 to Saturday 00:00.
/// In the week of the first Monday of a month one big event replaces both: Wednesday 00:00 to
/// Saturday 00:00.
const slot_a = struct {
    const start = 1 * day_ms;
    const end = 3 * day_ms;
};
const slot_b = struct {
    const start = 3 * day_ms + 12 * hour_ms;
    const end = 5 * day_ms;
};
const monthly_slot = struct {
    const start = 2 * day_ms;
    const end = 5 * day_ms;
};

/// What each slot runs, by week mod 4. No week has the same type in both slots.
const slot_a_types = [4]Type{ .horde, .supply_run, .blood_moon, .echo_week };
const slot_b_types = [4]Type{ .last_light, .blood_moon, .last_light, .supply_run };
/// The swarm's kind, by (week / 4) mod 4.
pub const horde_kinds = [4]data.Archetype{ .runner, .bloater, .brute, .shambler };

/// Day of the month (1..31) of the Monday that starts `week`.
fn mondayDate(week: i64) u8 {
    const day: u64 = @intCast(@max(0, @divFloor(war.weekStart(week), day_ms)));
    const md = std.time.epoch.EpochDay{ .day = @intCast(day) };
    return md.calculateYearDay().calculateMonthDay().day_index + 1;
}

/// The week whose Monday falls on the 1st to 7th: once a month.
pub fn isMonthlyWeek(week: i64) bool {
    return mondayDate(week) <= 7;
}

fn slotParam(t: Type, week: i64) u8 {
    if (t != .horde) return 0;
    return @intFromEnum(horde_kinds[@intCast(@mod(@divFloor(week, 4), 4))]);
}

/// The events of one week, in order.
pub fn weekOccurrences(week: i64, out: *[2]Occurrence) []const Occurrence {
    const start = war.weekStart(week);
    if (isMonthlyWeek(week)) {
        out[0] = .{ .type = .day_zero, .starts_at = start + monthly_slot.start, .ends_at = start + monthly_slot.end };
        return out[0..1];
    }
    const a = slot_a_types[@intCast(@mod(week, 4))];
    const b = slot_b_types[@intCast(@mod(week, 4))];
    out[0] = .{ .type = a, .starts_at = start + slot_a.start, .ends_at = start + slot_a.end, .param = slotParam(a, week) };
    out[1] = .{ .type = b, .starts_at = start + slot_b.start, .ends_at = start + slot_b.end, .param = slotParam(b, week) };
    return out[0..2];
}

/// The scheduled event running at `now_ms`, if any.
pub fn occurrenceAt(now_ms: i64) ?Occurrence {
    var buf: [2]Occurrence = undefined;
    for (weekOccurrences(war.weekIndex(now_ms), &buf)) |o| {
        if (now_ms >= o.starts_at and now_ms < o.ends_at) return o;
    }
    return null;
}

/// Scheduled events that have not ended by `from_ms`, soonest first, up to `out.len`.
pub fn upcoming(from_ms: i64, out: []Occurrence) []const Occurrence {
    var n: usize = 0;
    var week = war.weekIndex(from_ms);
    while (n < out.len) : (week += 1) {
        var buf: [2]Occurrence = undefined;
        for (weekOccurrences(week, &buf)) |o| {
            if (o.ends_at <= from_ms or n == out.len) continue;
            out[n] = o;
            n += 1;
        }
    }
    return out[0..n];
}

/// Calendar year (UTC) of a moment: the monthly title is once a year.
pub fn yearOf(ms: i64) u16 {
    const day: u64 = @intCast(@max(0, @divFloor(ms, day_ms)));
    const ed = std.time.epoch.EpochDay{ .day = @intCast(day) };
    return ed.calculateYearDay().year;
}

// --- What an event changes in the world ---------------------------------------------------------

/// The world half, per spawn window: a pure function of (event, window start, cell longitude), so
/// every client near a place sees the same things and the server can recompute any id.
pub const SpawnMods = struct {
    /// Multiplier on the 8% elite chance and the 30% cache chance.
    elite_mult: f64 = 1.0,
    cache_mult: f64 = 1.0,
    /// The extra enemy slot's chance, when the event sets one.
    extra_chance: ?f64 = null,
    extra_open: bool = false,
    swarm: ?data.Archetype = null,
    swarm_share: f64 = 0,
    airdrop_extra: bool = false,
};

pub fn spawnMods(ev: ?Active, at_ms: i64, lon: f64) SpawnMods {
    const a = ev orelse return .{};
    const m = a.def().mods;
    if (m.night_only and !daynight.isNight(at_ms, lon)) return .{ .airdrop_extra = m.airdrop_extra };
    return .{
        .elite_mult = m.elite_chance_mult,
        .cache_mult = m.cache_chance_mult,
        .extra_chance = if (m.extra_slot_chance > 0) m.extra_slot_chance else null,
        .extra_open = m.extra_open,
        .swarm = if (m.swarm_share > 0) a.swarm() else null,
        .swarm_share = m.swarm_share,
        .airdrop_extra = m.airdrop_extra,
    };
}

/// The pay half, for something a player does at `now`: the event's multipliers, or all ones when
/// there is no event (or a night-only one in daylight).
pub fn rewardMods(ev: ?Active, night: bool) data.EventMods {
    const a = ev orelse return .{};
    const m = a.def().mods;
    if (m.night_only and !night) return .{};
    return m;
}

// --- Goals and rewards ---------------------------------------------------------------------------

/// What one action counts towards. Fill what applies.
pub const Credit = struct {
    pve_win: bool = false,
    elite: bool = false,
    archetype: ?data.Archetype = null,
    cache: bool = false,
    echo_win: bool = false,
    contact_win: bool = false,
    war_points: u32 = 0,
};

/// How much of `c` the event's goal counts.
pub fn credit(ev: Active, c: Credit) u32 {
    return switch (ev.def().goal) {
        .elites => @intFromBool(c.pve_win and c.elite),
        .caches => @intFromBool(c.cache),
        .archetype => @intFromBool(c.pve_win and c.archetype != null and c.archetype.? == ev.swarm()),
        .echo_wins => @intFromBool(c.echo_win),
        .war_points => c.war_points,
        .actions => @intFromBool(c.pve_win or c.cache or c.echo_win or c.contact_win),
    };
}

/// The global goal: `per_player` for each player active this week, never below the floor.
/// A server with one player asks for `min_target`; one with ten thousand asks for 10,000 times
/// the per-player share.
pub fn target(def: data.EventDef, active_players: u32) u32 {
    return @max(def.min_target, def.per_player * @max(1, active_players));
}

/// The same for one district, from the players active in it (no floor: one player there asks for one share).
pub fn districtTarget(def: data.EventDef, active_players: u32) u32 {
    return def.per_player * @max(1, active_players);
}

/// 0 (not enough to count) to 3, by personal contribution.
pub fn tier(def: data.EventDef, n: u32) u8 {
    var t: u8 = 0;
    for (def.tiers) |need| {
        if (n >= need) t += 1;
    }
    return t;
}

pub const Payout = struct {
    tier: u8 = 0,
    salvage: u32 = 0,
    cosmetic: bool = false,
    /// A Rare-or-better item.
    item: bool = false,
    title: bool = false,
};

/// What contribution `n` earns at the end. `goal_met`: the global goal, or the goal of a district
/// the player contributed in, was reached. A missed goal still pays half the salvage.
pub fn payout(def: data.EventDef, n: u32, goal_met: bool) Payout {
    const t = tier(def, n);
    if (t == 0) return .{};
    const base: f32 = @floatFromInt(def.salvage[t - 1]);
    return .{
        .tier = t,
        .salvage = if (goal_met) def.salvage[t - 1] else @intFromFloat(@round(base * data.event_consolation)),
        .cosmetic = goal_met and t >= 2,
        .item = goal_met and t >= 3,
        .title = goal_met and t >= 3 and def.title != null,
    };
}

// --- Tests ---------------------------------------------------------------------------------------

const testing = std.testing;

/// Monday 2026-10-26 00:00 UTC (week 2923 or so); not a first-Monday week.
const monday_oct26: i64 = 1_793_448_000_000 - 5 * day_ms - 12 * hour_ms;
/// Monday 2026-11-02 00:00 UTC: the first Monday of November.
const monday_nov2: i64 = monday_oct26 + war.week_ms;

test "the calendar anchors are the Mondays they say" {
    try testing.expectEqual(monday_oct26, war.weekStart(war.weekIndex(monday_oct26)));
    try testing.expectEqual(@as(u8, 26), mondayDate(war.weekIndex(monday_oct26)));
    try testing.expectEqual(@as(u8, 2), mondayDate(war.weekIndex(monday_nov2)));
}

test "a monthly week comes once a month, on the first Monday" {
    // Walk four years of weeks: exactly one monthly week per calendar month, and its Monday is the 1st..7th.
    var week = war.weekIndex(monday_oct26);
    var monthly: u32 = 0;
    const end = week + 52 * 4;
    while (week < end) : (week += 1) {
        if (isMonthlyWeek(week)) {
            monthly += 1;
            try testing.expect(mondayDate(week) <= 7);
            try testing.expect(!isMonthlyWeek(week + 1));
        }
    }
    try testing.expectEqual(@as(u32, 48), monthly);
}

test "weeks have one or two events, never in conflict with the weekend raids" {
    var week: i64 = war.weekIndex(monday_oct26);
    const end = week + 200;
    while (week < end) : (week += 1) {
        var buf: [2]Occurrence = undefined;
        const occ = weekOccurrences(week, &buf);
        try testing.expect(occ.len == 1 or occ.len == 2);
        const start = war.weekStart(week);
        for (occ, 0..) |o, i| {
            // Tuesday to Saturday 00:00 only: Saturday and Sunday belong to the raids.
            try testing.expect(o.starts_at >= start + day_ms);
            try testing.expect(o.ends_at <= start + 5 * day_ms);
            try testing.expect(o.ends_at > o.starts_at);
            if (i > 0) {
                try testing.expect(o.starts_at >= occ[i - 1].ends_at);
                try testing.expect(o.type != occ[i - 1].type);
            }
            try testing.expectEqual(data.eventDef(o.type).monthly, occ.len == 1);
        }
    }
}

test "occurrenceAt finds the live event and nothing on the weekend" {
    // 2026-10-26 is not a monthly week: slot A starts Tuesday 00:00.
    const week = war.weekIndex(monday_oct26);
    var buf: [2]Occurrence = undefined;
    const occ = weekOccurrences(week, &buf);
    try testing.expectEqual(@as(usize, 2), occ.len);
    try testing.expect(occurrenceAt(monday_oct26 + 12 * hour_ms) == null);
    try testing.expectEqual(occ[0].type, occurrenceAt(monday_oct26 + day_ms).?.type);
    try testing.expect(occurrenceAt(monday_oct26 + day_ms - 1) == null);
    try testing.expect(occurrenceAt(occ[0].ends_at) == null);
    try testing.expectEqual(occ[1].type, occurrenceAt(occ[1].starts_at).?.type);
    try testing.expect(occurrenceAt(occ[1].ends_at) == null);
    try testing.expect(occurrenceAt(monday_oct26 + 5 * day_ms + hour_ms) == null);
    try testing.expect(occurrenceAt(monday_oct26 + 6 * day_ms) == null);
    // The first Monday of November runs the monthly event Wednesday to Saturday.
    const m = occurrenceAt(monday_nov2 + 2 * day_ms).?;
    try testing.expectEqual(Type.day_zero, m.type);
    try testing.expect(occurrenceAt(monday_nov2 + 2 * day_ms - 1) == null);
    try testing.expect(occurrenceAt(monday_nov2 + 5 * day_ms) == null);
}

test "the rotation covers every weekly type and the swarm changes kind" {
    var seen = std.EnumSet(Type).initEmpty();
    var kinds = std.EnumSet(data.Archetype).initEmpty();
    var week: i64 = 0;
    while (week < 64) : (week += 1) {
        var buf: [2]Occurrence = undefined;
        for (weekOccurrences(week, &buf)) |o| {
            seen.insert(o.type);
            if (o.type == .horde) kinds.insert(@enumFromInt(o.param));
        }
    }
    try testing.expectEqual(@as(usize, data.events.len), seen.count());
    try testing.expectEqual(@as(usize, 4), kinds.count());
    // Same week, same answer: every server runs the same rotation.
    var a: [2]Occurrence = undefined;
    var b: [2]Occurrence = undefined;
    try testing.expectEqualDeep(weekOccurrences(2923, &a), weekOccurrences(2923, &b));
}

test "upcoming lists the next events in order" {
    var buf: [5]Occurrence = undefined;
    const list = upcoming(monday_oct26 + day_ms + hour_ms, &buf);
    try testing.expectEqual(@as(usize, 5), list.len);
    // The one already running comes first.
    try testing.expect(list[0].starts_at <= monday_oct26 + day_ms + hour_ms);
    for (list[1..], 0..) |o, i| try testing.expect(o.starts_at >= list[i].ends_at);
}

test "the year of a moment" {
    try testing.expectEqual(@as(u16, 2026), yearOf(monday_oct26));
    try testing.expectEqual(@as(u16, 2027), yearOf(monday_oct26 + 70 * day_ms));
}

test "blood moon changes spawns only where it is night" {
    const bm: Active = .{ .type = .blood_moon };
    // 02:00 UTC at Greenwich is night; 12:00 is day.
    const night = spawnMods(bm, 2 * hour_ms, 0);
    try testing.expectEqual(@as(f64, 3.0), night.elite_mult);
    try testing.expect(night.extra_open and std.math.approxEqAbs(f64, night.extra_chance.?, 0.40, 1e-6));
    const day = spawnMods(bm, 12 * hour_ms, 0);
    try testing.expectEqual(@as(f64, 1.0), day.elite_mult);
    try testing.expect(!day.extra_open and day.extra_chance == null);
    // No event: nothing changes.
    try testing.expectEqualDeep(SpawnMods{}, spawnMods(null, 2 * hour_ms, 0));
    // Rewards follow the same rule.
    try testing.expectEqual(@as(f32, 1.5), rewardMods(bm, true).elite_xp);
    try testing.expectEqual(@as(f32, 1.0), rewardMods(bm, false).elite_xp);
}

test "each event changes what it says it changes" {
    const sr = spawnMods(.{ .type = .supply_run }, 0, 0);
    try testing.expect(sr.airdrop_extra and sr.cache_mult > 1.6 and sr.cache_mult < 1.7);
    try testing.expectEqual(@as(f32, 1.5), rewardMods(.{ .type = .supply_run }, false).cache_salvage);
    const hz = spawnMods(.{ .type = .horde, .param = @intFromEnum(data.Archetype.runner) }, 0, 0);
    try testing.expectEqual(@as(?data.Archetype, .runner), hz.swarm);
    try testing.expectApproxEqAbs(@as(f64, 0.6), hz.swarm_share, 1e-6);
    const ew = rewardMods(.{ .type = .echo_week }, false);
    try testing.expect(ew.echo_xp == 1.5 and ew.echo_salvage == 2.0 and ew.echo_item > 2);
    const ll = rewardMods(.{ .type = .last_light }, false);
    try testing.expect(ll.war_points == 2.0 and ll.zombie_heal_on_win > 0 and ll.human_heal_chance > 0);
    const dz = spawnMods(.{ .type = .day_zero }, 0, 0);
    try testing.expect(dz.elite_mult == 1.5 and dz.extra_open and std.math.approxEqAbs(f64, dz.cache_mult, 1.3, 1e-6));
}

test "goals count the right actions" {
    const elites: Active = .{ .type = .blood_moon };
    try testing.expectEqual(@as(u32, 1), credit(elites, .{ .pve_win = true, .elite = true }));
    try testing.expectEqual(@as(u32, 0), credit(elites, .{ .pve_win = true }));
    const caches: Active = .{ .type = .supply_run };
    try testing.expectEqual(@as(u32, 1), credit(caches, .{ .cache = true }));
    try testing.expectEqual(@as(u32, 0), credit(caches, .{ .pve_win = true }));
    const swarm: Active = .{ .type = .horde, .param = @intFromEnum(data.Archetype.brute) };
    try testing.expectEqual(@as(u32, 1), credit(swarm, .{ .pve_win = true, .archetype = .brute }));
    try testing.expectEqual(@as(u32, 0), credit(swarm, .{ .pve_win = true, .archetype = .runner }));
    try testing.expectEqual(@as(u32, 0), credit(swarm, .{ .archetype = .brute }));
    try testing.expectEqual(@as(u32, 1), credit(.{ .type = .echo_week }, .{ .echo_win = true }));
    try testing.expectEqual(@as(u32, 7), credit(.{ .type = .last_light }, .{ .war_points = 7 }));
    try testing.expectEqual(@as(u32, 1), credit(.{ .type = .day_zero }, .{ .contact_win = true }));
    try testing.expectEqual(@as(u32, 0), credit(.{ .type = .day_zero }, .{ .war_points = 5 }));
}

test "goals scale with the players active this week and keep a floor" {
    const d = data.eventDef(.horde);
    // One player (or none) asks for the floor.
    try testing.expectEqual(@as(u32, 50), target(d, 0));
    try testing.expectEqual(@as(u32, 50), target(d, 1));
    // From two players the per-player share takes over; 125 players reach the headline 5,000.
    try testing.expectEqual(@as(u32, 80), target(d, 2));
    try testing.expectEqual(@as(u32, 5000), target(d, 125));
    try testing.expectEqual(@as(u32, 400_000), target(d, 10_000));
    try testing.expectEqual(@as(u32, 40), districtTarget(d, 0));
    try testing.expectEqual(@as(u32, 400), districtTarget(d, 10));
    // Every floor is within a solo player's reach: the 48 h of a weekly event at an hour or two a day.
    for (data.events) |e| {
        try testing.expect(e.min_target >= e.per_player and e.min_target <= 2 * e.per_player + e.per_player / 2 + 50);
        // The first tier is within a casual player's reach, the last is a real effort.
        try testing.expect(e.tiers[0] < e.tiers[1] and e.tiers[1] < e.tiers[2]);
    }
}

test "tiers and payouts" {
    const d = data.eventDef(.supply_run);
    try testing.expectEqual(@as(u8, 0), tier(d, 5));
    try testing.expectEqual(@as(u8, 1), tier(d, 6));
    try testing.expectEqual(@as(u8, 2), tier(d, 20));
    try testing.expectEqual(@as(u8, 3), tier(d, 500));
    try testing.expectEqualDeep(Payout{}, payout(d, 5, true));
    const met = payout(d, 25, true);
    try testing.expectEqual(@as(u32, 700), met.salvage);
    try testing.expect(met.cosmetic and !met.item and !met.title);
    const missed = payout(d, 25, false);
    try testing.expectEqual(@as(u32, 350), missed.salvage);
    try testing.expect(!missed.cosmetic and !missed.item);
    const top = payout(d, 60, true);
    try testing.expect(top.item and top.cosmetic and !top.title);
    // Only the monthly event carries a title.
    try testing.expect(payout(data.eventDef(.day_zero), 300, true).title);
    try testing.expect(!payout(data.eventDef(.day_zero), 300, false).title);
    try testing.expectEqual(@as(u32, 3000), payout(data.eventDef(.day_zero), 300, true).salvage);
}

test "event table is consistent" {
    for (data.events, 0..) |e, i| {
        try testing.expectEqual(i, @intFromEnum(e.id));
        try testing.expect(e.name.human.len > 0 and e.name.zombie.len > 0 and e.blurb.human.len > 0 and e.blurb.zombie.len > 0);
        try testing.expect(e.salvage[0] < e.salvage[1] and e.salvage[1] < e.salvage[2]);
        try testing.expectEqual(e.monthly, e.title != null);
        try testing.expectEqual(e.goal == .archetype, e.mods.swarm_share > 0);
    }
}
