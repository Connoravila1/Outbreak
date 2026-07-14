//! CORE (B1, B2). When to ask the phone where it is.
//!
//! Pure. It sees no coordinate -- it is not allowed to, and it does not need one. It sees
//! seconds, a motion hint, and whether the last fix landed in the same room as the one before.
//! From those it decides one thing: **turn the GPS on, or leave it off.**
//!
//! ============================================================================
//! BATTERY IS A HARD CONSTRAINT, NOT AN OPTIMIZATION (G5)
//!
//! "A game that drains a phone in three hours is not shipped." The original spec polled GPS
//! every five seconds, which would do exactly that, and it is the reason that spec is dead.
//!
//! This is the one criterion that can fail Phase 3 outright. Combat can be retuned. Cell size
//! can be retuned. A phone that dies at lunchtime cannot be retuned into a game anyone plays.
//!
//! ============================================================================
//! THE INSIGHT THAT MAKES THIS CHEAP
//!
//! **The game only cares where you are when you STOP.**
//!
//! An engagement needs you present across many ticks, with other people, in one room. Someone
//! walking past a café is not in the café. Someone on a bus is not in a room at all -- they are
//! in transit, and transit is not a place.
//!
//! So we do not track people. We notice when they SETTLE.
//!
//!   - Moving?          The GPS stays OFF, and we report NOWHERE. You are not in a room.
//!   - Just stopped?    One fix. Quantize it. That is your room.
//!   - Still stopped?   The GPS stays OFF. You have not moved; your room has not changed.
//!
//! A commuter's day is then a handful of fixes -- home, the platform, the office, the café, the
//! platform, home -- instead of seventeen thousand. The battery cost is not optimised down to
//! near-zero; it is near-zero because the game never wanted the data in the first place.
//!
//! This is the same discovery as the rest of the design, arriving again: the thing that makes it
//! SAFE (we do not follow you, we only see rooms) is the thing that makes it CHEAP.
//!
//! `nowhere` -- the cell id that is structurally impossible for a real room -- was built to stop
//! GPS-less players from being co-located in an imaginary room. It turns out to be exactly the
//! word for "I am on a bus."

const std = @import("std");

const assert = std.debug.assert;

/// What the OS's motion sensors say. Nearly free: it is a hardware sensor, not a radio.
///
/// This is a HINT, never a fact. A phone in a pocket is jittery; a phone on a café table is
/// perfectly still while its owner is not. The policy never trusts it alone -- it uses it to
/// avoid fixes it would obviously waste, and lets cell stability do the real work.
pub const Motion = enum {
    /// Not moving. A desk, a table, a sofa, a pocket that is sitting down.
    still,
    /// Walking, running, dancing at a concert. On your feet, but not travelling.
    on_foot,
    /// A car, a bus, a train. TRAVELLING. Not in a room.
    in_vehicle,
    /// The sensor has not spoken yet, or does not know.
    unknown,
};

pub const Mode = enum {
    /// GPS OFF. Report NOWHERE -- you are in transit, and transit is not a place.
    ///
    /// This is not a degradation. It is the correct answer: a person on a bus is not in a room
    /// with the other people on the bus, for the purposes of a game about settling somewhere.
    suspend_reporting,
    /// GPS OFF. Report the room we already know. You have not moved.
    passive,
    /// GPS ON, once. Get a fix, quantize it, discard the coordinate (B6).
    fix,
};

pub const Plan = struct {
    mode: Mode,
    /// Seconds until we should look again. The shell sets its timer to this.
    next_look_seconds: u32,
};

/// PROVISIONAL, and to be validated on real hardware over eight hours (3.5). A number from a
/// spreadsheet is not a battery measurement.
pub const Policy = struct {
    /// The shortest interval between fixes: one tick.
    base_seconds: u32 = 30,

    /// The longest. Fifteen minutes of not asking, for someone who has not moved.
    max_seconds: u32 = 900,

    /// While a fight is running we look a little more often, so that leaving a room registers
    /// promptly. Not because the fight needs it -- the tick resolves whatever it is given -- but
    /// because a player who walks out should stop being in the room.
    max_seconds_in_fight: u32 = 120,

    /// How many consecutive unchanged fixes before we start doubling the interval.
    patience: u8 = 2,

    /// In the background, with nothing happening, we can be lazier still.
    max_seconds_background: u32 = 1800,

    pub const default: Policy = .{};
};

/// Everything the policy is allowed to know. Note what is absent: a coordinate, a cell id, a
/// speed, a heading, a distance. It knows whether the room CHANGED, and nothing about the room.
pub const Sense = struct {
    motion: Motion = .unknown,

    /// Since the last fix. The shell counts it; the core never asks what time it is (B3, B7).
    seconds_since_fix: u32 = 0,

    /// Consecutive fixes that landed in the SAME room. Not the room. Just: the same one.
    unchanged_fixes: u8 = 0,

    /// The hardware significant-motion trigger fired: the phone has physically moved since the
    /// last fix. Nearly free, and the single most useful signal we get.
    moved_since_fix: bool = false,

    /// We have never had a fix. We do not know which room we are in.
    have_room: bool = false,

    /// The server says a fight is running where we are.
    in_fight: bool = false,

    /// The app is not on screen.
    background: bool = false,
};

/// CORE. Turn the GPS on, or leave it off.
pub fn plan(sense: Sense, policy: Policy) Plan {
    // TRAVELLING. The radio stays off and we report nowhere.
    //
    // This is the biggest battery win in the entire design, and it costs the game nothing --
    // a person on a bus is not in a room. It is also the right ANSWER, not merely a cheap one:
    // without it, a commuter's phone would report the cell of every café the bus drove past.
    if (sense.motion == .in_vehicle) {
        return .{ .mode = .suspend_reporting, .next_look_seconds = policy.base_seconds };
    }

    // We do not know where we are. Find out. (First launch, or after a long suspension.)
    if (!sense.have_room) {
        return .{ .mode = .fix, .next_look_seconds = policy.base_seconds };
    }

    // The phone physically moved. Whatever we thought we knew about the room is now a guess.
    if (sense.moved_since_fix) {
        return .{ .mode = .fix, .next_look_seconds = policy.base_seconds };
    }

    const interval = intervalFor(sense, policy);

    if (sense.seconds_since_fix >= interval) {
        return .{ .mode = .fix, .next_look_seconds = policy.base_seconds };
    }

    // Nothing has moved and nothing has expired. The room is the room.
    return .{
        .mode = .passive,
        .next_look_seconds = interval - sense.seconds_since_fix,
    };
}

/// How long we are willing to go without looking.
///
/// Exponential backoff on a room that will not change. A person at a desk produces one fix, then
/// one a minute later, then two, then four... up to the ceiling. Someone who has been sitting in
/// an office for three hours is costing us one fix every fifteen minutes.
fn intervalFor(sense: Sense, policy: Policy) u32 {
    const ceiling = if (sense.in_fight)
        policy.max_seconds_in_fight
    else if (sense.background)
        policy.max_seconds_background
    else
        policy.max_seconds;

    if (sense.unchanged_fixes < policy.patience) return policy.base_seconds;

    // Double per unchanged fix past our patience, bounded. `shift` is capped so it cannot
    // overflow, and the result is clamped anyway.
    const steps: u6 = @intCast(@min(@as(u32, sense.unchanged_fixes - policy.patience) + 1, 20));
    const scaled: u64 = @as(u64, policy.base_seconds) << steps;

    return @intCast(@min(scaled, @as(u64, ceiling)));
}

/// CORE. What the phone should report this tick, given the plan and what it knows.
///
/// Returns `false` when the phone should report NOWHERE -- it is travelling, or it has never had
/// a fix. Reporting a stale room while walking away from it would leave you fighting in a café
/// you left ten minutes ago, and earning XP for it.
pub fn shouldReportRoom(mode: Mode, have_room: bool) bool {
    return switch (mode) {
        .suspend_reporting => false,
        .passive, .fix => have_room,
    };
}

const testing = std.testing;

test "a person on a bus costs nothing and is nowhere" {
    // The biggest battery win in the design, and it is also simply true: you are not in a room
    // with the other people on the bus.
    const p = plan(.{ .motion = .in_vehicle, .have_room = true, .seconds_since_fix = 10_000 }, .default);

    try testing.expectEqual(Mode.suspend_reporting, p.mode);
    try testing.expect(!shouldReportRoom(p.mode, true));
}

test "a person at a desk backs off to almost nothing" {
    const policy: Policy = .default;

    // They have been sitting still, in the same room, for a long time.
    var sense: Sense = .{
        .motion = .still,
        .have_room = true,
        .unchanged_fixes = 12,
        .seconds_since_fix = 0,
    };

    const p = plan(sense, policy);
    try testing.expectEqual(Mode.passive, p.mode);

    // We will not look again for a quarter of an hour.
    try testing.expectEqual(policy.max_seconds, p.next_look_seconds);

    // And when the interval finally expires, exactly one fix.
    sense.seconds_since_fix = policy.max_seconds;
    try testing.expectEqual(Mode.fix, plan(sense, policy).mode);
}

test "moving the phone wakes it immediately" {
    // The significant-motion trigger is a hardware sensor. It is nearly free and it is the single
    // most useful thing the OS gives us: it means we never have to poll to discover movement.
    const p = plan(.{
        .motion = .still,
        .have_room = true,
        .unchanged_fixes = 20, // deeply backed off
        .seconds_since_fix = 5,
        .moved_since_fix = true,
    }, .default);

    try testing.expectEqual(Mode.fix, p.mode);
}

test "a fight keeps us honest" {
    // Not because the fight needs a fresh fix -- the tick resolves whatever it is given -- but
    // because a player who walks out of the room should stop being in it.
    const policy: Policy = .default;

    const fighting: Sense = .{
        .motion = .still,
        .have_room = true,
        .unchanged_fixes = 30,
        .in_fight = true,
    };

    try testing.expectEqual(policy.max_seconds_in_fight, plan(fighting, policy).next_look_seconds);
    try testing.expect(policy.max_seconds_in_fight < policy.max_seconds);
}

test "a phone that has never had a fix reports nowhere, not a guess" {
    const p = plan(.{ .have_room = false }, .default);

    try testing.expectEqual(Mode.fix, p.mode);
    try testing.expect(!shouldReportRoom(p.mode, false));
}

test "A COMMUTER'S DAY: how many times does the GPS actually turn on?" {
    // THE PHASE 3 EXIT CRITERION, IN A TEST. "Eight hours of background play costs less than 5%
    // battery." That number comes from real hardware (3.5) and this test cannot produce it -- but
    // it CAN produce the input to it: how many times the radio is switched on in a day.
    //
    // If this number is in the thousands, the phase is already dead and no amount of measurement
    // will save it. If it is in the dozens, the measurement is worth taking.
    const policy: Policy = .default;

    var fixes: u32 = 0;
    var sense: Sense = .{ .motion = .still, .have_room = false };

    // A day, one tick at a time. 2,880 ticks of thirty seconds.
    var tick: u32 = 0;
    while (tick < 2880) : (tick += 1) {
        const hour = (tick * 24) / 2880;

        // A plausible day: asleep, a commute, a desk, a lunch, a desk, a commute, an evening.
        sense.motion = switch (hour) {
            0...6 => .still, // asleep
            7 => .in_vehicle, // the bus
            8...11 => .still, // a desk
            12 => .on_foot, // lunch, walking to it
            13...16 => .still, // a desk
            17 => .in_vehicle, // the bus home
            else => .still, // an evening on the sofa
        };

        // The phone physically moves when they get up, and at the boundaries of the day.
        sense.moved_since_fix = (tick % 2880) == 0 or
            (sense.motion == .on_foot and tick % 20 == 0);

        const p = plan(sense, policy);

        switch (p.mode) {
            .fix => {
                fixes += 1;
                sense.seconds_since_fix = 0;
                sense.moved_since_fix = false;
                sense.have_room = true;
                // In a real day the room mostly does not change: a desk is a desk.
                sense.unchanged_fixes +|= 1;
            },
            .passive => sense.seconds_since_fix += 30,
            .suspend_reporting => {
                sense.seconds_since_fix += 30;
                // Off the bus, we will need a fresh fix -- the room is certainly different.
                sense.unchanged_fixes = 0;
            },
        }
    }

    // A whole day, and the radio switched on this many times.
    //
    // The dead v1.0 spec polled every five seconds: 17,280 fixes a day. That is the number that
    // drains a phone by lunchtime, and it is why that spec is dead.
    //
    // Asserted exactly rather than printed, because the core does not talk to a terminal (B3) --
    // and because a number written down in a test is a number somebody has to look at again when
    // it changes.
    try testing.expectEqual(@as(u32, 101), fixes);

    // ONE HUNDRED AND ONE. Against SEVENTEEN THOUSAND TWO HUNDRED AND EIGHTY.
    //
    // A 171x reduction, and note where it came from: not from optimising the polling loop, but
    // from the game never wanting the data. We do not follow people. We notice when they settle.
    // The thing that makes it safe is the thing that makes it cheap, again.
    //
    // WHAT THIS PROVES, AND WHAT IT DOES NOT.
    //
    // It proves the GPS radio is no longer the problem. A warm fix costs a second or two of
    // receiver time; a hundred of them is a few minutes of radio across a whole day, which is
    // noise against a phone battery.
    //
    // It does NOT prove the phase passes. Two costs remain, and one of them is probably now the
    // BIGGER one:
    //
    //   1. THE PERSISTENT CONNECTION. A report every thirty seconds is 2,880 sends a day. Each
    //      one wakes the radio. This is what every chat app on earth does, so it is a solved
    //      problem -- but it is now plausibly a larger draw than the GPS, and it must be measured,
    //      not assumed.
    //
    //   2. THE FOREGROUND SERVICE. Staying alive in the background has a floor cost that has
    //      nothing to do with us.
    //
    // Only a real phone, over eight real hours, settles it (3.5, G5). This test exists to say
    // whether that measurement is WORTH TAKING. At seventeen thousand fixes it would not have
    // been: the phase would already be over.
}

test "the policy never sees a coordinate" {
    // B6, as a structural fact rather than a promise. Look at `Sense`: there is no latitude in
    // it, no longitude, no cell, no speed, no heading, and no distance. It knows whether the room
    // CHANGED. It does not know, and cannot know, which room it is.
    //
    // The guard already forbids a float in this file. This test is here so a human reads the
    // reason: a policy that knew where you were would be a policy that could leak where you were.
    //
    // (Asserted on the TYPE, not the spelling. An earlier version wrote the two type names
    // literally -- inside a test whose entire purpose was to prove they do not appear -- and the
    // guard rejected it. A textual guard cannot tell a mention from a use. That is the price of it
    // being dumb enough to be trustworthy, and it is a price worth paying.)
    inline for (@typeInfo(Sense).@"struct".fields) |field| {
        try testing.expect(@typeInfo(field.type) != .float);
    }
}
