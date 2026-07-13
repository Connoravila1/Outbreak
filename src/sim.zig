//! SHELL (B1, B3). The simulation driver: the only impure thing in Phase 0.
//!
//! It owns the clock, the allocator, and stdout. It makes every decision the core is
//! forbidden to make -- what time it is, what the seed is, when to stop -- and hands the
//! core plain values (B5, B7).
//!
//! It exists to answer the Phase 0 exit criterion, which is falsifiable and is the only
//! thing that matters here:
//!
//!   > Ten thousand synthetic players run through a simulated week, any tick replays
//!   > deterministically from (world, seed, index), and the leak detector reports zero.
//!
//! IT PRINTS NUMBERS. It does not draw anything. The named trap of this phase is building a
//! visualiser "just to see it" -- three weeks spent, nothing learned that a histogram would
//! not have shown. If you want to see the simulation, read the histogram.

const std = @import("std");
const city = @import("city.zig");
const combat = @import("combat.zig");
const spatial = @import("spatial.zig");
const tick_mod = @import("tick.zig");
const world_mod = @import("world.zig");

const World = world_mod.World;

comptime {
    _ = @import("guard.zig");
}

const seed: u64 = 0x0117_B4EA_C000_0001;

/// What we learned from a run. Not what it looked like.
const Stats = struct {
    ticks: u64 = 0,
    checksum: u64 = 0,

    total_damage: u64 = 0,
    total_xp: u64 = 0,

    live_cells_total: u64 = 0,
    live_presences_total: u64 = 0,
    max_live_cells: u32 = 0,

    /// Player-ticks spent in a live cell, by hour of day. The question the whole phase
    /// exists to answer: does a real person's day ever go live, and when?
    live_by_hour: [24]u64 = @splat(0),
    presences_by_hour: [24]u64 = @splat(0),

    /// Player-ticks actually IN A FIGHT -- an engagement, in a live cell, with hostiles.
    fighting_total: u64 = 0,
    fighting_by_hour: [24]u64 = @splat(0),

    /// Engagements STARTED. A fight is an event, so the number that describes a player's day
    /// is how many events it contains -- not what fraction of it was spent at war.
    engagements_started: u64 = 0,
    engaged_cells_total: u64 = 0,
    /// Fights a player actually entered, counted on the rising edge.
    fights_entered: u64 = 0,

    /// The scale of what people walked into, in bands. No exact count leaves the core.
    crowd_bands: [5]u64 = @splat(0),

    tick_ns_total: u64 = 0,
    tick_ns_max: u64 = 0,
};

fn run(gpa: std.mem.Allocator, io: std.Io, params: city.Params, ticks: u64, measure: bool) !Stats {
    var world: World = .empty;
    defer world_mod.deinit(&world, gpa);

    try city.populate(&world, gpa, params, seed);

    var stats: Stats = .{};

    // A fight a player was actually IN, counted at the moment they entered one.
    //
    // The obvious shortcut -- fighting player-ticks divided by the engagement length -- was
    // correct until engagements started scaling with the crowd (O5), and then it silently
    // counted one four-hour concert as forty-eight separate fights. Count the rising edge.
    const was_fighting = try gpa.alloc(bool, params.population);
    defer gpa.free(was_fighting);
    @memset(was_fighting, false);

    const is_fighting = try gpa.alloc(bool, params.population);
    defer gpa.free(is_fighting);

    var i: u64 = 0;
    while (i < ticks) : (i += 1) {
        // The shell moves the city. Where people are is an input to the core, never a
        // decision the core makes.
        city.advance(&world, params, seed, i);

        const started = if (measure) std.Io.Timestamp.now(io, .awake) else undefined;

        const result = try tick_mod.tick(&world, gpa, seed, i, .default);
        defer gpa.free(result.tells);

        if (measure) {
            const ended = std.Io.Timestamp.now(io, .awake);
            const elapsed: u64 = @intCast(ended.nanoseconds - started.nanoseconds);
            stats.tick_ns_total += elapsed;
            stats.tick_ns_max = @max(stats.tick_ns_max, elapsed);
        }

        const hour: usize = @intCast((i % params.ticks_per_day) * 24 / params.ticks_per_day);
        @memset(is_fighting, false);

        stats.ticks += 1;
        stats.live_cells_total += result.live_cells;
        stats.live_presences_total += result.live_presences;
        stats.max_live_cells = @max(stats.max_live_cells, result.live_cells);
        stats.live_by_hour[hour] += result.live_presences;
        stats.presences_by_hour[hour] += params.population;
        stats.engaged_cells_total += result.engaged_cells;
        stats.engagements_started += result.engagements_started;

        for (result.tells) |t| {
            stats.total_damage += t.damage;
            stats.total_xp += t.xp;
            if (t.xp > 0) {
                stats.fighting_total += 1;
                stats.fighting_by_hour[hour] += 1;
            }
            stats.crowd_bands[@intFromEnum(t.crowd)] += 1;

            const who: usize = @intFromEnum(t.player);
            is_fighting[who] = true;
            if (!was_fighting[who]) stats.fights_entered += 1;
            // The replay checksum. If one bit of one fight differs, this differs.
            stats.checksum = stats.checksum *% 31 +%
                @as(u64, @intFromEnum(t.player)) +%
                @as(u64, t.damage) *% 7 +%
                @as(u64, t.hp) *% 13 +%
                @as(u64, t.xp) *% 17 +%
                @as(u64, @intFromEnum(t.momentum));
        }

        @memcpy(was_fighting, is_fighting);
    }

    return stats;
}

pub fn main() !void {
    // The leak detector is not a testing convenience. It is half the exit criterion.
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const check = debug_allocator.deinit();
        if (check == .leak) {
            std.debug.print("\nLEAK DETECTED. The exit criterion is not met.\n", .{});
            std.process.exit(1);
        }
    }
    const gpa = debug_allocator.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const params: city.Params = .default;
    const ticks_in_a_week = params.ticks_per_day * 7;

    std.debug.print(
        \\
        \\OUTBREAK -- PHASE 0 EXIT CRITERION
        \\
        \\  population      {d}
        \\  quorum (k)      {d}
        \\  cell precision  {d} bits
        \\  tick            30s
        \\  simulated       7 days ({d} ticks)
        \\
        \\
    , .{ params.population, spatial.quorum, spatial.default_precision, ticks_in_a_week });

    const first = try run(gpa, io, params, ticks_in_a_week, true);

    // THE REPLAY. Same world, same seed, same indices, run again from nothing.
    std.debug.print("  replaying the week from (world, seed, index)...\n\n", .{});
    const second = try run(gpa, io, params, ticks_in_a_week, false);

    const deterministic = first.checksum == second.checksum;

    const player_ticks = first.ticks * params.population;
    const live_pct = percent(first.live_presences_total, player_ticks);
    const mean_us = @as(f64, @floatFromInt(first.tick_ns_total)) /
        @as(f64, @floatFromInt(first.ticks)) / 1000.0;
    const max_us = @as(f64, @floatFromInt(first.tick_ns_max)) / 1000.0;

    // The tick has thirty seconds of wall clock to do its work (G3).
    const budget_used = (mean_us / 1000.0) / 30_000.0 * 100.0;

    std.debug.print(
        \\  TICK COST (G1, G3)
        \\    mean            {d:.1} us
        \\    max             {d:.1} us
        \\    budget (30s)    {d:.6}% used
        \\
        \\  THE WORLD
        \\    live cells/tick {d:.1} mean, {d} peak
        \\    player-ticks    {d} total
        \\    live            {d} ({d:.2}% of a player's week)
        \\    damage dealt    {d}
        \\    XP awarded      {d}
        \\
        \\  DETERMINISM (B8)
        \\    checksum        0x{X:0>16}
        \\    replay          0x{X:0>16}
        \\    identical       {s}
        \\
        \\
    , .{
        mean_us,
        max_us,
        budget_used,
        @as(f64, @floatFromInt(first.live_cells_total)) / @as(f64, @floatFromInt(first.ticks)),
        first.max_live_cells,
        player_ticks,
        first.live_presences_total,
        live_pct,
        first.total_damage,
        first.total_xp,
        first.checksum,
        second.checksum,
        if (deterministic) "YES" else "NO -- THE TICK IS NOT DETERMINISTIC",
    });

    // The histogram. This is the visualiser, and it is twenty-four lines of text.
    std.debug.print("  A PLAYER'S DAY -- % of players in a live cell, by hour\n\n", .{});

    var peak: u64 = 1;
    for (first.live_by_hour) |v| peak = @max(peak, v);

    for (first.live_by_hour, first.presences_by_hour, 0..) |live, total, hour| {
        const pct = percent(live, total);
        const bar_len: usize = @intFromFloat(@round(pct / 100.0 * 50.0 * (100.0 / @max(1.0, peakPct(first)))));

        var bar: [64]u8 = @splat('#');
        std.debug.print("    {d:0>2}:00  {d:>6.2}%  {s}\n", .{ hour, pct, bar[0..@min(bar_len, 60)] });
    }

    std.debug.print("\n", .{});

    std.debug.print("\n  IN A FIGHT -- % of players with a hostile in their cell, by hour\n\n", .{});
    for (first.fighting_by_hour, first.presences_by_hour, 0..) |fighting, total, hour| {
        const pct = percent(fighting, total);
        const bar_len: usize = @intFromFloat(@round(pct / 100.0 * 60.0));
        var bar: [64]u8 = @splat('#');
        std.debug.print("    {d:0>2}:00  {d:>6.2}%  {s}\n", .{ hour, pct, bar[0..@min(bar_len, 60)] });
    }

    const days: f64 = 7.0;
    const pop: f64 = @floatFromInt(params.population);

    std.debug.print(
        \\
        \\  A FIGHT IS AN EVENT, NOT A CLIMATE
        \\    rooms that fought {d} over the week
        \\    fights per player {d:.2} a day
        \\    time at war       {d:.1}% of a player's week
        \\
        \\  THE SCALE OF IT -- what people walked into (bands; no count leaves the core)
        \\    a few             {d}
        \\    dozens            {d}
        \\    scores            {d}
        \\    hundreds          {d}
        \\    thousands         {d}
        \\
        \\
    , .{
        first.engagements_started,
        @as(f64, @floatFromInt(first.fights_entered)) / pop / days,
        percent(first.fighting_total, player_ticks),
        first.crowd_bands[0],
        first.crowd_bands[1],
        first.crowd_bands[2],
        first.crowd_bands[3],
        first.crowd_bands[4],
    });

    // HOW MUCH OF THAT IS THE GAME, AND HOW MUCH IS MY MODEL?
    //
    // "6000 home cells for 10000 players" was an arbitrary number I chose. If the answer
    // above moves a lot when that number moves, then the answer is about the model and not
    // about the game, and reporting it as a finding would be dishonest.
    std.debug.print("  SENSITIVITY -- one simulated day, varying only home density\n\n", .{});
    std.debug.print("    {s:>12}  {s:>12}  {s:>10}  {s:>10}\n", .{ "home cells", "players/home", "live", "fighting" });

    for ([_]u64{ 3000, 6000, 12000, 25000, 60000 }) |homes| {
        var swept: city.Params = .default;
        swept.homes = homes;

        const day = try run(gpa, io, swept, swept.ticks_per_day, false);
        const day_player_ticks = day.ticks * swept.population;

        std.debug.print("    {d:>12}  {d:>12.2}  {d:>9.1}%  {d:>9.1}%\n", .{
            homes,
            @as(f64, @floatFromInt(swept.population)) / @as(f64, @floatFromInt(homes)),
            percent(day.live_presences_total, day_player_ticks),
            percent(day.fighting_total, day_player_ticks),
        });
    }

    std.debug.print("\n", .{});

    if (!deterministic) {
        std.debug.print("  EXIT CRITERION NOT MET: replay diverged.\n\n", .{});
        std.process.exit(1);
    }

    std.debug.print("  Deterministic. Leak check runs at exit.\n\n", .{});
}

fn percent(part: u64, whole: u64) f64 {
    if (whole == 0) return 0;
    return @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(whole)) * 100.0;
}

fn peakPct(stats: Stats) f64 {
    var best: f64 = 0;
    for (stats.live_by_hour, stats.presences_by_hour) |live, total| {
        best = @max(best, percent(live, total));
    }
    return best;
}
