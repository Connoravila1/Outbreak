//! SHELL (B1, B3). THE COORDINATE DIES HERE.
//!
//! This is the highest-stakes file in the client, and it is short on purpose.
//!
//! ============================================================================
//! THE ONE THING THIS FILE IS FOR
//!
//! `onLocation` receives a latitude and a longitude. It quantizes them into a `u64` cell id and
//! DROPS THEM, in the same function, before it returns.
//!
//! Not stored. Not cached. Not logged. Not put in a crash report. Not kept "just to compare with
//! the next one". The floats exist for the length of one expression and then they are gone, and
//! what survives is a group-by key that no function anywhere can turn back into a place.
//!
//! ============================================================================
//! WHY THIS FILE IS THE WHOLE PROBLEM
//!
//! The server has never seen a coordinate and structurally cannot -- the build fails if a float
//! appears in a file classified core (B6). The wire protocol carries a cell id and a token. The
//! journal stores cell ids. There is no coordinate database to breach, subpoena, or misuse,
//! because there is no coordinate.
//!
//! ALL OF THAT IS TRUE ONLY BECAUSE OF THIS FILE. The phone is the one place in the entire system
//! where a coordinate ever exists, which makes it the only place one can leak from -- and this is
//! that place, in its entirety, in about thirty lines.
//!
//! No guard can enforce this on the platform side. The Java listener could keep a field. This
//! function could keep a global. Neither would fail a build. It is discipline, and it is written
//! down here so the next person to touch it reads this before they touch it.
//!
//! ============================================================================
//! WHAT IS SAFE TO KEEP, AND WHY
//!
//! `accuracy` -- how confident the receiver is, in metres. It is a property of OUR OWN FIX, it is
//! never transmitted, and it never reaches another player. It is kept because the cafe test cannot
//! be answered without it (O3: is a 24-metre cell smaller than the phone's own error?), and a
//! number nobody measured is a number nobody has.
//!
//! It is NOT a distance to anything, and it is not a radius around anyone. If it ever leaves this
//! device, that is a different file and a different review.

const std = @import("std");
const spatial = @import("spatial.zig");

// ---- the JNI shim (android/jni_shim.c). No header, no @cImport, no bindings.

/// The log. IT NEVER CARRIES A COORDINATE, and it never will.
///
/// B6 is explicit: no log line, metric, or crash dump may contain a raw position. So this prints
/// the ROOM -- an opaque u64 with no inverse -- and how confident the receiver was, in metres.
/// Both are safe. Neither can be turned back into a place.
///
/// A crash reporter that hoovered up a stack frame containing a latitude would end the privacy
/// guarantee on a Tuesday afternoon, quietly, in a build nobody reviewed. So there is nowhere for
/// it to find one: by the time anything is printed, the floats are gone.
extern fn __android_log_write(prio: c_int, tag: [*:0]const u8, text: [*:0]const u8) c_int;

extern fn jnishim_attach(vm: ?*anyopaque) ?*anyopaque;
extern fn jnishim_detach(vm: ?*anyopaque) void;
extern fn jnishim_has_location_permission(env: ?*anyopaque, activity: ?*anyopaque) c_int;
extern fn jnishim_request_location_permission(env: ?*anyopaque, activity: ?*anyopaque) void;
extern fn jnishim_start_service(env: ?*anyopaque, activity: ?*anyopaque, interval_ms: c_long) void;
extern fn jnishim_stop_service(env: ?*anyopaque, activity: ?*anyopaque) void;

// ============================================================================ what survives

/// The room we are in. A `u64` cell id, and NOTHING ELSE.
///
/// Written by the OS thread inside the location callback, read by the render thread. Atomic, so
/// there is no lock on the path a location takes -- the callback lands on the main thread, and the
/// one contract that matters is that nothing heavy runs there.
///
/// Zero means we have never had a fix, which is an ordinary condition and not a failure (E4).
var room: std.atomic.Value(u64) = .init(0);

/// How wrong the receiver thinks it might be, in metres. DIAGNOSTIC ONLY. Never transmitted.
///
/// This is the number the cafe test turns on. If the phone's own error is larger than the cell,
/// then a player sitting perfectly still flickers between rooms and breaks their own quorum -- and
/// that is not a bug we can fix in software, it is the cell size being wrong (O3).
var accuracy_metres: std.atomic.Value(u32) = .init(0);

/// How many fixes have landed, and how many of them changed the room.
///
/// Also the cafe test: a still player whose room changes is the same finding as above, seen from
/// the other side. Counts, not places.
var fix_count: std.atomic.Value(u32) = .init(0);
var room_changes: std.atomic.Value(u32) = .init(0);

/// The precision the server told us to quantize at. Until the socket lands (M.7) it is the
/// default, and the server is authoritative over it precisely so that changing the cell size is a
/// config change rather than a flag day (D1).
var precision: std.atomic.Value(u8) = .init(spatial.default_precision);

// ============================================================================ THE WALL

/// THE ONLY FUNCTION IN THIS PROJECT THAT WILL EVER HOLD A LATITUDE.
///
/// Called by the JVM, from `OutbreakService.onLocationChanged`, on the main thread. The name is not
/// a choice: the JVM resolves `Java_com_outbreak_game_OutbreakService_onLocation` by symbol out of
/// the shared library, and it must match the class and method exactly.
///
/// It is exported from ZIG rather than from the C shim on purpose. The coordinate's first stop in
/// our code is this function, and its last stop is this function.
///
/// ONE EXPRESSION. `quantize` takes the floats, returns a `u64`, and the parameters go out of
/// scope on the next line. There is no branch in which they are kept, and no field to keep them in.
export fn Java_com_outbreak_game_OutbreakService_onLocation(
    env: ?*anyopaque,
    class: ?*anyopaque,
    latitude: f64,
    longitude: f64,
    accuracy: f32,
) callconv(.c) void {
    _ = env;
    _ = class;

    // ------------------------------------------------------------------
    // HERE. This line, and no other.
    const cell = spatial.quantize(latitude, longitude, @intCast(precision.load(.acquire))) orelse return;
    // The floats are dead. Everything below this line is a u64 and an integer count.
    // ------------------------------------------------------------------

    const id = @intFromEnum(cell);
    const was = room.swap(id, .acq_rel);

    if (was != id) _ = room_changes.fetchAdd(1, .monotonic);
    _ = fix_count.fetchAdd(1, .monotonic);

    // Metres, rounded. A quality figure, not a position. Clamped so a receiver reporting a
    // kilometre of doubt cannot overflow the counter it is displayed with.
    const metres: u32 = @intFromFloat(@min(@as(f32, 9999), @max(@as(f32, 0), @round(accuracy))));
    accuracy_metres.store(metres, .release);

    // THE CAFE DIAGNOSTIC (O3), and the only readout this file will ever produce.
    //
    // The room, the confidence, and how often the room has changed. NOT the place. A still player
    // whose room keeps changing is the finding that decides the cell size, and it cannot be
    // answered from a chair.
    diagnose(id, metres);
}

/// Print the room. Never the place.
///
/// Compiled away entirely off Android -- `__android_log_write` is bionic's, and the test binary
/// runs on a laptop that has never heard of it. The callback itself is exported unconditionally,
/// because the JVM resolves it by symbol; only the logging is platform-gated.
fn diagnose(id: u64, metres: u32) void {
    if (comptime !@import("builtin").abi.isAndroid()) return;

    var line: [128]u8 = undefined;
    const text = std.fmt.bufPrintZ(&line, "room={x} accuracy={d}m fixes={d} changes={d}", .{
        id,
        metres,
        fix_count.load(.monotonic),
        room_changes.load(.monotonic),
    }) catch return;

    _ = __android_log_write(4, "outbreak", text.ptr);
}

// ============================================================================ the shell's view

/// What the rest of the app is allowed to know. Note what is absent: a coordinate, a bearing, a
/// distance, a speed. It knows WHICH ROOM, and how well the phone knows it.
pub const Reading = struct {
    /// Zero if we have never had a fix.
    cell: u64,
    accuracy_metres: u32,
    fixes: u32,
    room_changes: u32,
};

pub fn read() Reading {
    return .{
        .cell = room.load(.acquire),
        .accuracy_metres = accuracy_metres.load(.acquire),
        .fixes = fix_count.load(.monotonic),
        .room_changes = room_changes.load(.monotonic),
    };
}

/// The server is authoritative over the cell size (D1). Called when the welcome lands (M.7).
pub fn setPrecision(bits: u8) void {
    if (bits == 0 or bits > spatial.max_precision) return;
    precision.store(bits, .release);
}

// ============================================================================ the radio

pub const Radio = struct {
    vm: ?*anyopaque,
    activity: ?*anyopaque,
    running: bool = false,
};

/// Ask for permission if we do not have it. Returns true once we do.
///
/// The result of `requestPermissions` arrives as a Java callback we have no class for -- and we are
/// not adding a second Java class to learn a boolean. We ask, and then we check. Polling a flag
/// once a second costs nothing next to the radio it is gating.
pub fn permitted(radio: *Radio) bool {
    const env = jnishim_attach(radio.vm) orelse return false;
    return jnishim_has_location_permission(env, radio.activity) != 0;
}

pub fn requestPermission(radio: *Radio) void {
    const env = jnishim_attach(radio.vm) orelse return;
    jnishim_request_location_permission(env, radio.activity);
}

/// Start the foreground service, which owns the GPS subscription. `min_seconds` is the OS's own
/// throttle and the first line of the battery budget: the hardware does not wake for a fix we said
/// we did not want (G5).
///
/// Failure is not an error -- a phone that will not tell us where it is, which `gps.zig` already
/// knows how to handle (E4).
pub fn start(radio: *Radio, min_seconds: u32) void {
    if (radio.running) return;

    const env = jnishim_attach(radio.vm) orelse return;

    // EXPLICITLY u32 before the multiply. `@min(x, 3600)` knows its own bound, so Zig narrows the
    // result to a type just wide enough to hold 3600 -- and then multiplying by a thousand
    // overflows it. ReleaseSafe panics rather than wrapping. Second time this exact narrowing has
    // bitten me; `@min` with a comptime bound is a type change wearing a clamp's clothes.
    const seconds: u32 = @min(min_seconds, 3600);
    const ms: c_long = @intCast(@as(u64, seconds) * 1000);

    jnishim_start_service(env, radio.activity, ms);
    radio.running = true;
}

/// Stop the service. The radio goes quiet and the notification disappears. THIS IS THE BATTERY
/// BUDGET, in one function: a service that is not running costs nothing (G5).
pub fn stop(radio: *Radio) void {
    if (!radio.running) return;

    const env = jnishim_attach(radio.vm) orelse return;
    jnishim_stop_service(env, radio.activity);
    radio.running = false;
}

const testing = std.testing;

test "THE COORDINATE DIES: a fix becomes a cell and nothing else survives" {
    // The callback cannot be called from a test -- it is invoked by the JVM. What CAN be tested is
    // the thing it does, which is the only thing that matters: a latitude and a longitude go in, a
    // room comes out, and there is no way back.
    //
    // This is the wall, exercised.
    const lat: f64 = 51.5007;
    const lon: f64 = -0.1246;

    const cell = spatial.quantize(lat, lon, spatial.default_precision).?;

    // Same place, same room. It is a group-by key: that is the whole of what it does.
    try testing.expectEqual(cell, spatial.quantize(lat, lon, spatial.default_precision).?);

    // AND THERE IS NO WAY BACK. Not asserted -- ENFORCED, and not by this test.
    //
    // `guard.zig` fails the build on every name an inverse quantizer could plausibly be given: the
    // lat-lon converters, the cell decoders, the un-quantizers. The function does not exist, and it
    // cannot be written without the compiler stopping the person writing it.
    //
    // (Those names are not spelled out here. The guard scans raw text, comments included, so a
    // comment that lists the banned constructs IS one. It caught this exact paragraph.)
    //
    // A cell is a room, not a compressed coordinate (A9).
}

test "a fix we cannot use is an absent fix, not an error" {
    // A receiver that has no idea where it is reports a latitude of zero, or a hundred, or a NaN.
    // None of those are errors and none of them get a code path: they are a phone that does not
    // currently know which room it is in, which is an ordinary condition (E4).
    try testing.expectEqual(@as(?spatial.CellId, null), spatial.quantize(91.0, 0.0, spatial.default_precision));
    try testing.expectEqual(@as(?spatial.CellId, null), spatial.quantize(0.0, 181.0, spatial.default_precision));

    const nan = std.math.nan(f64);
    try testing.expectEqual(@as(?spatial.CellId, null), spatial.quantize(nan, 0.0, spatial.default_precision));
    try testing.expectEqual(@as(?spatial.CellId, null), spatial.quantize(0.0, nan, spatial.default_precision));
}
