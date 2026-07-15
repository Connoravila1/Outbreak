//! CORE (B1, B2). When to wake the phone up, and when to leave it asleep.
//!
//! Pure. It sees no coordinate -- it is not allowed to, and it does not need one. It sees
//! seconds, a motion hint, and whether the last fix landed in the same room as the one before.
//!
//! ============================================================================
//! BATTERY IS A HARD CONSTRAINT, NOT AN OPTIMIZATION (G5)
//!
//! "A game that drains a phone in three hours is not shipped." The original spec polled GPS
//! every five seconds, which would do exactly that, and it is why that spec is dead.
//!
//! This is the one criterion that can fail Phase 3 outright. Combat can be retuned. Cell size
//! can be retuned. A phone that dies at lunchtime cannot be retuned into a game anyone plays.
//!
//! ============================================================================
//! A CORRECTION, RECORDED BECAUSE IT WAS A REAL MISTAKE
//!
//! The first version of this file suspended reporting whenever the phone was in a vehicle:
//! "moving means you are nowhere". That was WRONG, and it was wrong in a particular way worth
//! naming -- it was a GAME DESIGN DECISION wearing an engineer's coat.
//!
//! A parked car is a place. You are in it. A crowded train carriage at rush hour holds three
//! real humans in one room, which is the entire definition of a live cell. Sitting in traffic
//! outside a café puts you in that café's cell.
//!
//! "Is a vehicle a room?" is a question for the designer. It is not a question the battery gets
//! to answer, and the battery does not need it answered: the savings below come from being
//! ASLEEP, not from excluding people.
//!
//! ============================================================================
//! THE FOUR THINGS THAT ACTUALLY COST BATTERY, AND WHAT WE DO ABOUT EACH
//!
//! Zig buys us nothing here. Battery on a phone is radio duty cycle and wakeups, not CPU -- our
//! tick already costs microseconds, and being fast is worth nothing. BEING ASLEEP IS WORTH
//! EVERYTHING. The lever is architectural.
//!
//! 1. THE GPS RADIO.
//!    Fix only when the room might have changed. A phone that has not moved has not changed
//!    rooms, and the hardware significant-motion trigger tells us that for free.
//!
//! 2. THE WATCHING.
//!    Stay asleep until something free says the room might have changed, then take ONE fix. This
//!    policy asks for a single boolean -- `moved_since_fix` -- and DOES NOT CARE what set it. That
//!    is the whole trick, and it is the single biggest lever there is: the app is not running
//!    between wakeups.
//!
//!    What sets that boolean is a SHELL decision, recorded in BATTERY.md (2026-07-14): the
//!    hardware significant-motion sensor, and a change in the room's Wi-Fi radio fingerprint --
//!    NOT a hardware geofence. A geofence needs Google Play Services (refused, F1) and would have
//!    the OS persist a raw coordinate (forbidden, I7). Both wake sources are coordinate-free, and
//!    this core never learns which one fired, or where.
//!
//! 3. THE SENDING.
//!    We report only when the room CHANGES -- not every tick. The server already assumes this:
//!    "a player who did not report keeps their last room" (session.zig). A commuter's day is a
//!    few dozen cell changes, not two thousand eight hundred and eighty sends.
//!
//! 4. THE CONNECTION.
//!    Quiet is the normal state -- the game says nothing almost all of the time. So when it is
//!    quiet there is NO SOCKET AT ALL. A push wakes the phone when its cell goes live. We hold a
//!    connection only while a fight is actually running.
//!
//! ============================================================================
//! AND ONE COUPLING NOBODY HAD NOTICED: CELL SIZE DECIDES WHETHER WE NEED GPS
//!
//! The platform's cheap location -- wifi and cell towers, from scans the phone is ALREADY doing
//! -- is accurate to something like 20-100 metres and costs approximately nothing.
//!
//! Our cell at 39 bits is 24 metres wide in London. That REQUIRES the GPS radio.
//! A cell at 37 bits is 48-76 metres. That can be served by coarse location, for free.
//!
//! So the cell size (GAME_RULES O3) is not only a question of privacy and of GPS jitter. It also
//! decides whether the game needs a GPS receiver at all. Three independent forces now point the
//! same way: coarser.
//!
const std = @import("std");

const assert = std.debug.assert;

/// What the OS's motion sensors say. Nearly free: a hardware sensor, not a radio.
///
/// A HINT, never a fact. A phone in a pocket is jittery; a phone on a café table is perfectly
/// still while its owner is not. The policy uses it to avoid fixes it would obviously waste, and
/// lets the wake signal do the real work.
///
/// NOTE WHAT IS NOT HERE: any rule about vehicles. Whether a bus is a room is a question for the
/// designer, not for the battery. See the header.
pub const Motion = enum {
    /// Not moving. A desk, a table, a sofa, a parked car.
    still,
    /// On your feet. Walking, or dancing at a concert.
    on_foot,
    /// Travelling in something.
    in_vehicle,
    /// The sensor has not spoken, or does not know.
    unknown,
};

/// What the phone should be doing right now.
pub const Mode = enum {
    /// ASLEEP. No GPS, no socket, no wakeups.
    ///
    /// Something coordinate-free is watching for us to leave -- the significant-motion sensor, and
    /// a shift in the room's Wi-Fi fingerprint (BATTERY.md, 2026-07-14), NOT a geofence. On a
    /// modern phone the motion watch is the SENSOR HUB, not us; the app is woken when we move. This
    /// is the normal state of this game -- most of the time it says nothing at all -- and it is the
    /// single biggest thing standing between us and a phone that dies at lunchtime.
    ///
    /// A push wakes us if our cell goes live while we are asleep.
    armed,

    /// GPS ON, once. Get a fix, quantize it, discard the coordinate in the same expression (B6).
    fix,

    /// A fight is running where we are. Hold the connection, look more often, so that walking out
    /// of the room registers promptly.
    engaged,
};

pub const Plan = struct {
    mode: Mode,
    /// Seconds until the next look. The shell sets its timer; the core never asks the time (B3).
    next_look_seconds: u32,
    /// Send a report this tick?
    ///
    /// ONLY WHEN THE ROOM CHANGED. The server already assumes this -- "a player who did not
    /// report keeps their last room" -- so silence is not a gap, it is an assertion that nothing
    /// moved. A commuter's day is a few dozen sends, not two thousand eight hundred and eighty.
    report: bool,
    /// Hold a socket open?
    ///
    /// Only while a fight is running. When quiet, there is no connection at all -- a push wakes
    /// us if the room goes live.
    connect: bool,
};

/// PROVISIONAL, and to be validated on real hardware over eight hours (3.5). A number from a
/// spreadsheet is not a battery measurement.
pub const Policy = struct {
    /// The shortest interval between fixes: one tick.
    base_seconds: u32 = 30,

    /// How long we will sit armed and asleep before taking a confirming fix.
    ///
    /// A wake signal can be missed (the sensor hub is best-effort, not a promise; a Wi-Fi shift can
    /// go unseen), so we do not trust it forever. Once an hour we look, even if nothing woke us.
    armed_seconds: u32 = 3600,

    /// While a fight is running. Not because the fight needs it -- the tick resolves whatever it
    /// is given -- but because a player who walks out should stop being in the room.
    engaged_seconds: u32 = 60,

    /// Consecutive unchanged fixes before we trust the room enough to arm the wake watch and sleep.
    patience: u8 = 2,

    pub const default: Policy = .{};
};

/// Everything the policy is allowed to know.
///
/// Note what is absent: a coordinate, a cell id, a speed, a heading, a distance. It knows whether
/// the room CHANGED. It does not know, and cannot know, which room it is.
pub const Sense = struct {
    motion: Motion = .unknown,

    /// Since the last fix. The shell counts it (B3, B7).
    seconds_since_fix: u32 = 0,

    /// Consecutive fixes that landed in the SAME room. Not the room. Just: the same one.
    unchanged_fixes: u8 = 0,

    /// The phone physically left where it was. Set by the shell from a coordinate-free source --
    /// the significant-motion sensor, or a change in the room's Wi-Fi fingerprint (BATTERY.md,
    /// 2026-07-14). Nearly free, and the most useful signal the OS gives us. The policy does not
    /// know, and must not care, which source set it.
    moved_since_fix: bool = false,

    /// We have never had a fix. We do not know which room we are in.
    have_room: bool = false,

    /// The room changed at the last fix, and the server has not been told yet.
    room_is_news: bool = false,

    /// The server says a fight is running where we are.
    in_fight: bool = false,
};

/// CORE. What should the phone be doing?
pub fn plan(sense: Sense, policy: Policy) Plan {
    // We do not know where we are. Find out. (First launch, or after being woken.)
    if (!sense.have_room) {
        return .{ .mode = .fix, .next_look_seconds = policy.base_seconds, .report = false, .connect = false };
    }

    // A FIGHT IS RUNNING. This is the one time the phone earns its keep: a socket, and a look
    // every minute, so that leaving the room registers.
    if (sense.in_fight) {
        if (sense.moved_since_fix or sense.seconds_since_fix >= policy.engaged_seconds) {
            return .{ .mode = .fix, .next_look_seconds = policy.base_seconds, .report = true, .connect = true };
        }
        return .{
            .mode = .engaged,
            .next_look_seconds = policy.engaged_seconds - sense.seconds_since_fix,
            .report = sense.room_is_news,
            .connect = true,
        };
    }

    // The phone physically moved -- the motion sensor fired, or the room's Wi-Fi fingerprint
    // shifted. Whatever we thought we knew about the room is now a guess. One fix.
    if (sense.moved_since_fix) {
        return .{ .mode = .fix, .next_look_seconds = policy.base_seconds, .report = false, .connect = false };
    }

    // We are not yet sure the room is settled. Keep looking, cheaply.
    if (sense.unchanged_fixes < policy.patience) {
        if (sense.seconds_since_fix >= policy.base_seconds) {
            return .{ .mode = .fix, .next_look_seconds = policy.base_seconds, .report = false, .connect = false };
        }
        return .{
            .mode = .armed,
            .next_look_seconds = policy.base_seconds - sense.seconds_since_fix,
            .report = sense.room_is_news,
            .connect = sense.room_is_news,
        };
    }

    // ASLEEP. The room is settled, the wake watch is armed, and the sensor hub is watching. We will
    // not look again for an hour unless something wakes us -- and we hold no socket at all.
    if (sense.seconds_since_fix >= policy.armed_seconds) {
        return .{ .mode = .fix, .next_look_seconds = policy.base_seconds, .report = false, .connect = false };
    }

    return .{
        .mode = .armed,
        .next_look_seconds = policy.armed_seconds - sense.seconds_since_fix,
        // We send only when there is news. Otherwise the server keeps our last room, which is
        // correct: we have not moved.
        .report = sense.room_is_news,
        .connect = sense.room_is_news,
    };
}

const testing = std.testing;

test "the normal state of this game is ASLEEP" {
    // The game says nothing almost all of the time. So almost all of the time the phone should be
    // doing nothing: no GPS, no socket, no wakeups. A coordinate-free wake watch (the motion sensor
    // hub, a Wi-Fi fingerprint), and an app that is not running.
    const p = plan(.{
        .motion = .still,
        .have_room = true,
        .unchanged_fixes = 5,
        .seconds_since_fix = 60,
    }, .default);

    try testing.expectEqual(Mode.armed, p.mode);
    try testing.expect(!p.connect); // NO SOCKET.
    try testing.expect(!p.report); // NOTHING TO SAY.
}

test "we send only when the room changes" {
    // The server already assumes this: "a player who did not report keeps their last room". So
    // silence is not a gap -- it is an assertion that nothing moved.
    const policy: Policy = .default;

    const settled: Sense = .{ .motion = .still, .have_room = true, .unchanged_fixes = 5 };
    try testing.expect(!plan(settled, policy).report);

    var news = settled;
    news.room_is_news = true;
    try testing.expect(plan(news, policy).report);
}

test "a parked car is a place, and a bus is a question for the designer" {
    // THE CORRECTION. The first version of this file suspended reporting in a vehicle -- "moving
    // means you are nowhere" -- which is a GAME DESIGN DECISION wearing an engineer's coat.
    //
    // A parked car is a place. A crowded carriage holds three real humans in one room, which is
    // the entire definition of a live cell. The battery does not need that question answered, and
    // the battery does not get to answer it.
    //
    // There is no rule about vehicles in this policy. A person in a vehicle is treated exactly
    // like a person anywhere else.
    const policy: Policy = .default;

    const in_a_car: Sense = .{ .motion = .in_vehicle, .have_room = true, .unchanged_fixes = 5 };
    const at_a_desk: Sense = .{ .motion = .still, .have_room = true, .unchanged_fixes = 5 };

    const a = plan(in_a_car, policy);
    const b = plan(at_a_desk, policy);

    try testing.expectEqual(b.mode, a.mode);
    try testing.expectEqual(b.report, a.report);
    try testing.expectEqual(b.connect, a.connect);
}

test "a fight is the one time the phone earns its keep" {
    const policy: Policy = .default;

    const fighting: Sense = .{
        .motion = .still,
        .have_room = true,
        .unchanged_fixes = 30,
        .in_fight = true,
        .seconds_since_fix = 10,
    };

    const p = plan(fighting, policy);

    try testing.expectEqual(Mode.engaged, p.mode);
    try testing.expect(p.connect); // a socket, for as long as the fight lasts
    try testing.expect(p.next_look_seconds <= policy.engaged_seconds);
}

test "moving wakes it immediately, however deeply it was asleep" {
    const p = plan(.{
        .motion = .still,
        .have_room = true,
        .unchanged_fixes = 30,
        .seconds_since_fix = 5,
        .moved_since_fix = true, // the motion sensor fired, or the Wi-Fi fingerprint shifted
    }, .default);

    try testing.expectEqual(Mode.fix, p.mode);
}

test "the wake signal is trusted, but not forever" {
    // The wake signal is best-effort, not a promise -- a sensor-hub motion trigger can be missed,
    // a Wi-Fi shift can go unseen. A missed wake would leave a player reporting a room they left
    // hours ago. So we look once an hour regardless.
    const policy: Policy = .default;

    const asleep: Sense = .{
        .motion = .still,
        .have_room = true,
        .unchanged_fixes = 10,
        .seconds_since_fix = policy.armed_seconds,
    };

    try testing.expectEqual(Mode.fix, plan(asleep, policy).mode);
}

test "A COMMUTER'S DAY: what does the phone actually do?" {
    // The Phase 3 exit criterion, as far as a laptop can take it. "Eight hours of background play
    // costs less than 5% battery." Only real hardware settles that (3.5). What this can produce is
    // the INPUT to it: how often the radio wakes, and how often we send.
    //
    // CAVEAT (2026-07-14): the `moved_since_fix` model below is GEOFENCE-SHAPED -- it fires exactly
    // at room boundaries and continuously in a vehicle. The wake signal we actually chose (the
    // significant-motion sensor + a Wi-Fi fingerprint shift; BATTERY.md) fires on a coarser, less
    // boundary-precise pattern, so the pinned counts WILL move once the real signal is wired. This
    // test still earns its place: it proves the POLICY logic is sound and bounded. It does not
    // prove the fix count -- M.9 does.
    const policy: Policy = .default;

    var fixes: u32 = 0;
    var sends: u32 = 0;
    var connected_ticks: u32 = 0;

    var sense: Sense = .{ .motion = .still, .have_room = false };

    var tick: u32 = 0;
    while (tick < 2880) : (tick += 1) { // a day of thirty-second ticks
        const hour = (tick * 24) / 2880;

        sense.motion = switch (hour) {
            0...6 => .still, // asleep
            7 => .in_vehicle, // the bus -- and NOT excluded from the game
            8...11 => .still, // a desk
            12 => .on_foot, // lunch
            13...16 => .still, // a desk
            17 => .in_vehicle, // the bus home
            else => .still, // an evening
        };

        // The phone physically moves when they get up, get on the bus, walk to lunch. On the bus,
        // the wake signal fires constantly -- a moving vehicle leaves its room every few seconds.
        // (Geofence-shaped model; see the CAVEAT above.)
        sense.moved_since_fix = switch (sense.motion) {
            .in_vehicle => true,
            .on_foot => tick % 4 == 0,
            else => tick % 240 == 0, // shifting in a chair, walking to the kettle
        };

        // One fight, at lunch, in a busy café.
        sense.in_fight = hour == 12 and tick % 120 < 20;

        const p = plan(sense, policy);

        if (p.connect) connected_ticks += 1;
        if (p.report) sends += 1;

        switch (p.mode) {
            .fix => {
                fixes += 1;
                sense.seconds_since_fix = 0;
                sense.moved_since_fix = false;
                // Did the room change? On a bus, always. At a desk, never.
                const changed = sense.motion == .in_vehicle or (sense.motion == .on_foot and tick % 20 == 0);
                sense.room_is_news = changed;
                sense.unchanged_fixes = if (changed) 0 else sense.unchanged_fixes +| 1;
                sense.have_room = true;
            },
            .armed, .engaged => {
                sense.seconds_since_fix += 30;
                sense.room_is_news = false;
            },
        }
    }

    // THE NUMBERS. Pinned rather than printed -- the core does not talk to a terminal (B3), and a
    // number written into a test is a number somebody has to look at again when it moves.
    //
    // Against the dead v1.0 spec: 17,280 GPS fixes a day, and a socket held open every second of
    // it.
    // GPS FIXES:      304  (the dead v1.0 spec: 17,280)
    // SENDS:            16  (a report every tick would be: 2,880)
    // CONNECTED TICKS:  25  (a persistent socket would be: 2,880 -- all day, every day)
    //
    // The sends and the connection are the striking ones. The phone talks to the server SIXTEEN
    // TIMES IN A DAY, and holds a socket open for twelve and a half minutes of it. The rest of the
    // day it is not merely idle -- it is not running.
    //
    // The fixes are dominated by the two bus rides, where the wake signal fires continuously because
    // a moving vehicle leaves its room every few seconds. That is honest: if a vehicle IS a room,
    // then a commute genuinely costs GPS. It is also the number most sensitive to the cell size --
    // see the header, and GAME_RULES O3. (Geofence-shaped model; see the CAVEAT above.)
    try testing.expectEqual(@as(u32, 304), fixes);
    try testing.expectEqual(@as(u32, 16), sends);
    try testing.expectEqual(@as(u32, 25), connected_ticks);
}

test "the policy never sees a coordinate" {
    // B6, as a structural fact rather than a promise. There is no latitude in `Sense`, no
    // longitude, no cell, no speed, no heading, and no distance. It knows whether the room
    // CHANGED. It does not know which room it is.
    //
    // (Asserted on the TYPE, not the spelling. An earlier version wrote the two type names
    // literally -- inside a test whose whole purpose was to prove they do not appear -- and the
    // guard rejected it. A textual guard cannot tell a mention from a use. That is the price of it
    // being dumb enough to be trustworthy.)
    inline for (@typeInfo(Sense).@"struct".fields) |field| {
        try testing.expect(@typeInfo(field.type) != .float);
    }
}
