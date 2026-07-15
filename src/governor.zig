//! SHELL (B1, B3). The thing that governs the GPS radio by the pure policy in `gps.zig`.
//!
//! ============================================================================
//! WHAT THIS IS, AND WHY IT IS SEPARATE FROM `gps.zig`
//!
//! `gps.zig` is the POLICY: a pure function `plan(Sense, Policy) -> Plan`. Given whether the room
//! changed, how long since the last fix, and whether a fight is running, it says what the phone
//! should be doing -- fix, sleep, or hold a socket. It is pure, it is tested, and it sees no clock
//! and no coordinate.
//!
//! It has one gap: SOMETHING has to build the `Sense` from live signals, call `plan`, and act on
//! the answer -- turn the radio on and off, count the seconds, remember that a fix has landed. That
//! something touches the clock and the radio, so it is SHELL, and it is here.
//!
//! This file is the whole of the wiring between the policy and the hardware. It is deliberately a
//! thin adapter around one pure method (`step`) so that the interesting part -- "GPS sleeps once
//! the room settles, and wakes when the phone moves" -- can be tested on a laptop, with synthetic
//! readings, without a phone in the loop.
//!
//! ============================================================================
//! IT HOLDS NO COORDINATE, AND CANNOT (B6)
//!
//! Everything this file works in is a COUNT, a number of SECONDS, or a room id compared ONLY for
//! EQUALITY -- "am I in a room I was just in?" It never treats the room id as a place: no arithmetic
//! on it, no distance, no direction, only `==`. That is the same operation the whole game is built
//! on (group-by-cell) and the same thing `location.zig` does to count changes. No coordinate-shaped
//! float lives in this file; the guard pins that out textually, and `plan` on the other side is core
//! and could not accept one.
//!
//! ============================================================================
//! THE WAKE SIGNAL IS COORDINATE-FREE (BATTERY.md, 2026-07-14)
//!
//! `moved` is set by the shell from a wake that carries no location: the significant-motion sensor,
//! or (later, pending a ruleset ruling) a change in the room's Wi-Fi fingerprint. This governor
//! does not know or care which fired -- it only knows the phone left where it was, which is exactly
//! the one bit `plan` asked for. A hardware geofence was rejected: it needs Google Play Services
//! (F1) and would have the OS persist a raw coordinate (I7).

const std = @import("std");
const gps = @import("gps.zig");
const location = @import("location.zig");

/// What the shell should do until it must think again. Every field is a decision, not a place.
pub const Action = struct {
    /// Should the GPS radio be delivering fixes right now? `false` is the normal, cheap state:
    /// the room is settled, and we wait for a wake.
    gps_on: bool,

    /// Should the client send a report this cycle? True only when the room is news (it changed and
    /// the server has not been told). COMPUTED here; the wiring to the client socket is a later
    /// step (Lever 3), so today the client still reports every tick and this is advisory.
    report: bool,

    /// Should a socket be held open? True only while a fight is running. COMPUTED here; acting on
    /// it (dropping the socket when quiet) needs the push that wakes it back up (M.8), so today the
    /// client holds its socket regardless and this is advisory.
    connect: bool,

    /// How long the shell may sleep before it must build a `Sense` and think again. A motion wake
    /// may cut it short -- that is the point of the sensor.
    sleep_seconds: u32,
};

/// The governor's own state, evolved across `step` calls. Counts, seconds, and a couple of room ids
/// kept ONLY to compare for equality (never as places) -- no coordinate, no float. See the header.
///
/// A7.2: COLD struct, size guard waived. There is exactly one governor per phone and it is never
/// walked in a hot loop -- it is a singleton controller, not a column in a collection. Same for
/// `Action`, which is a transient return value. Neither carries a size budget worth guarding.
pub const Governor = struct {
    policy: gps.Policy = .default,

    /// `location.Reading.fixes` as of the last step. A change means a fresh fix has landed.
    seen_fixes: u32 = 0,

    /// The room id at the previous fix, and the one before that. Kept ONLY to spot a BOUNCE -- a
    /// "change" that lands us right back where we were two fixes ago, which indoors is GPS jitter
    /// across a cell boundary while standing still (O3), not a move. Compared for equality; never
    /// used as a place.
    last_cell: u64 = 0,
    prev_cell: u64 = 0,

    /// Consecutive fixes without a real move -- the phone standing still, jitter allowed for. This
    /// is `Sense.unchanged_fixes`: the policy waits for `patience` of these before it sleeps the
    /// radio. A bounce (flicker) does NOT reset it; a genuine progression to a new room does.
    unchanged: u8 = 0,

    /// Seconds since the last fix. The shell counts it (B3); the core never asks the time.
    seconds_since_fix: u32 = 0,

    /// We have had at least one fix and so know which room we are in.
    have_room: bool = false,

    /// The room changed at the last fix and the client has not been told yet. Set on a change,
    /// cleared by `reported()` when the shell has actually sent it.
    news: bool = false,

    /// A wake has fired since the last fix -- the phone physically moved. Set by `step`'s
    /// `moved_wake` argument, cleared by the next fix (which answers "where am I now").
    moved: bool = false,

    /// PURE. Fold one observation into the state and decide what to do next.
    ///
    ///   reading         -- the latest from `location.read()`: room id (ignored as a place) + counts.
    ///   elapsed_seconds -- wall-clock since the previous `step`, measured by the shell's clock.
    ///   moved_wake      -- a coordinate-free wake fired since the previous `step` (motion / Wi-Fi).
    ///   in_fight        -- the server's last tell says a fight is running where we are.
    ///
    /// No I/O, no clock, no allocation. Everything impure is the caller's; this is the decision, and
    /// it is where the test suite can reach.
    pub fn step(
        self: *Governor,
        reading: location.Reading,
        elapsed_seconds: u32,
        moved_wake: bool,
        in_fight: bool,
    ) Action {
        if (moved_wake) self.moved = true;

        // A fresh fix has landed iff the fix counter moved.
        if (reading.fixes != self.seen_fixes) {
            const cell = reading.cell;
            const changed = cell != self.last_cell;

            // THE FLICKER RULE (O3). Indoors a still phone's fix jitters across a cell boundary, so
            // the room "changes" without anyone moving. A change that lands us back in the cell we
            // were in TWO fixes ago is that jitter -- a bounce, not a move -- and it must not keep
            // the radio awake, or a stationary phone never sleeps and the battery win never lands. A
            // genuine move progresses to new cells and does not bounce. (If the motion sensor fires,
            // it keeps GPS on independently via `moved_since_fix`, so a fast walk the bounce test
            // cannot see is still covered.)
            const bounce = changed and cell == self.prev_cell;
            const real_move = changed and !bounce;

            if (real_move) {
                self.unchanged = 0; // genuinely somewhere new -- stay awake, and it's worth telling
                self.news = true;
            } else {
                self.unchanged +|= 1; // same room, or a bounce -- converge toward sleep
            }

            self.prev_cell = self.last_cell;
            self.last_cell = cell;
            self.seen_fixes = reading.fixes;
            self.seconds_since_fix = 0;
            self.have_room = true;
            self.moved = false; // the fix is the answer to "did I move"; the question is closed.
        } else {
            self.seconds_since_fix +|= elapsed_seconds;
        }

        const sense: gps.Sense = .{
            .have_room = self.have_room,
            .unchanged_fixes = self.unchanged,
            .seconds_since_fix = self.seconds_since_fix,
            .moved_since_fix = self.moved,
            .room_is_news = self.news,
            .in_fight = in_fight,
        };

        const p = gps.plan(sense, self.policy);

        return .{
            // `.armed` is the one mode with the radio off. `.fix` and `.engaged` both want a fix.
            .gps_on = p.mode != .armed,
            .report = p.report,
            .connect = p.connect,
            .sleep_seconds = p.next_look_seconds,
        };
    }

    /// The shell sent a report. The room is no longer news.
    ///
    /// Kept separate from `step` because "did the room change" is something the governor learns, but
    /// "the server has been told" is something only the shell that owns the socket knows.
    pub fn reported(self: *Governor) void {
        self.news = false;
    }
};

// ============================================================================ tests

const testing = std.testing;

/// A synthetic reading. `cell` is the room id -- the governor compares it for equality only, and
/// the tests use distinct ids (0xA, 0xB, ...) to stand for distinct rooms.
fn sample(fixes: u32, cell: u64) location.Reading {
    return .{ .cell = cell, .accuracy_metres = 10, .fixes = fixes, .room_changes = 0 };
}

test "from a cold start the radio comes on to find the room" {
    // No fix yet: we do not know which room we are in, so the only thing to do is look.
    var g: Governor = .{};
    const a = g.step(sample(0, 0), 0, false, false);
    try testing.expect(a.gps_on);
}

test "once the room settles, the radio sleeps" {
    // The heart of the battery win. A phone sitting still takes a couple of confirming fixes and
    // then turns the GPS OFF -- and stays off, because nothing is moving.
    var g: Governor = .{};
    _ = g.step(sample(1, 0xA), 30, false, false); // arrive in room A
    _ = g.step(sample(2, 0xA), 30, false, false); // same room -> unchanged climbs
    const settled = g.step(sample(3, 0xA), 30, false, false); // unchanged >= patience -> sleep
    try testing.expect(!settled.gps_on); // ASLEEP. No GPS.

    // And it STAYS asleep as long as nothing wakes it and the hour is not up.
    const still_asleep = g.step(sample(3, 0xA), 60, false, false);
    try testing.expect(!still_asleep.gps_on);
}

test "a STILL phone whose room jitters still sleeps -- the flicker fix" {
    // O3: indoors the fix bounces across a cell boundary while you sit perfectly still. The old rule
    // -- "settle after N identical fixes" -- never got them, so the radio never slept. Now a change
    // that bounces back to a recent cell is recognised as jitter, and the phone sleeps anyway.
    var g: Governor = .{};
    _ = g.step(sample(1, 0xA), 30, false, false); // arrive in A
    _ = g.step(sample(2, 0xA), 30, false, false);
    // now the fix jitters A/B/A/B with NO motion (we are not moving; the sensor never fires)
    _ = g.step(sample(3, 0xB), 30, false, false); // first excursion looks like a move
    _ = g.step(sample(4, 0xA), 30, false, false); // bounce back to A -> jitter, not a move
    _ = g.step(sample(5, 0xB), 30, false, false); // bounce -> jitter
    const settled = g.step(sample(6, 0xA), 30, false, false); // bounce -> settles despite the flicker
    try testing.expect(!settled.gps_on);
}

test "a WALK keeps the radio on -- never sleeps mid-transit" {
    // The guard against the flicker fix over-reaching: progression through NEW cells must not be
    // mistaken for jitter. Each fix is a fresh room and none bounces back, so we never settle.
    var g: Governor = .{};
    _ = g.step(sample(1, 0xA), 30, false, false);
    _ = g.step(sample(2, 0xA), 30, false, false); // settled briefly in A
    _ = g.step(sample(3, 0xB), 30, false, false); // walking: B
    _ = g.step(sample(4, 0xC), 30, false, false); // C
    const walking = g.step(sample(5, 0xD), 30, false, false); // D -- still moving
    try testing.expect(walking.gps_on); // stays on through the walk
}

test "a motion wake turns the radio back on, however deeply it slept" {
    var g: Governor = .{};
    _ = g.step(sample(1, 0xA), 30, false, false);
    _ = g.step(sample(2, 0xA), 30, false, false);
    _ = g.step(sample(3, 0xA), 30, false, false); // asleep now

    // The phone physically moved -- the motion sensor fired, or the Wi-Fi fingerprint shifted.
    const woken = g.step(sample(3, 0xA), 5, true, false);
    try testing.expect(woken.gps_on);
}

test "the wake is trusted, but not forever: an hour asleep forces a look" {
    // A wake can be missed (the sensor hub is best-effort). So even with nothing waking us, once an
    // hour we take a confirming fix -- otherwise a missed wake strands us in a room we have left.
    var g: Governor = .{};
    _ = g.step(sample(1, 0xA), 30, false, false);
    _ = g.step(sample(2, 0xA), 30, false, false);
    _ = g.step(sample(3, 0xA), 30, false, false); // asleep

    // No new fix, but a full `armed_seconds` has gone by.
    const forced = g.step(sample(3, 0xA), g.policy.armed_seconds, false, false);
    try testing.expect(forced.gps_on);
}

test "a fight keeps the radio on and asks for a socket" {
    var g: Governor = .{};
    // Settle first, so we are otherwise asleep.
    _ = g.step(sample(1, 0xA), 30, false, false);
    _ = g.step(sample(2, 0xA), 30, false, false);
    _ = g.step(sample(3, 0xA), 30, false, false);

    const fighting = g.step(sample(3, 0xA), 30, false, true);
    try testing.expect(fighting.gps_on); // a fight looks often, so leaving the room registers.
    try testing.expect(fighting.connect); // and holds a socket while it lasts.
}

test "a report is news only until it is sent" {
    var g: Governor = .{};
    // Settle into a room, then genuinely move to a new one.
    _ = g.step(sample(1, 0xA), 30, false, false);
    _ = g.step(sample(2, 0xA), 30, false, false);
    _ = g.step(sample(3, 0xA), 30, false, false); // settled in A

    const changed = g.step(sample(4, 0xB), 30, false, false); // a real move to B
    try testing.expect(changed.report); // the server has not been told; it is news.

    g.reported(); // the shell sent it.
    // Settle again so the policy is in its quiet branch, and confirm there is nothing more to say.
    _ = g.step(sample(5, 0xB), 30, false, false);
    const quiet = g.step(sample(6, 0xB), 30, false, false);
    try testing.expect(!quiet.report);
}

test "the governor never holds a coordinate" {
    // B6, as a structural fact. Neither the state it keeps nor the action it returns has a float in
    // it: a place, a distance, a speed, a bearing -- none of them have a type here to live in.
    // (Asserted on the TYPES, not the spelling, so this test is not itself a coordinate bearer.)
    inline for (@typeInfo(Governor).@"struct".fields) |field| {
        try testing.expect(@typeInfo(field.type) != .float);
    }
    inline for (@typeInfo(Action).@"struct".fields) |field| {
        try testing.expect(@typeInfo(field.type) != .float);
    }
}
