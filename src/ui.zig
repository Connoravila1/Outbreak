//! CORE (B1, B2). The interface, as a pure function.
//!
//!     (what the server told us, what the player has touched) -> a list of things to draw
//!
//! No GPU. No Android. No clock. No allocation it was not handed. The shell rasterises the list
//! and nothing else -- which means the ENTIRE interface is testable on a laptop, today, with no
//! phone plugged in, exactly like the tick.
//!
//! It also means the interface has the same guarantee as everything else: IT CANNOT SHOW WHAT IT
//! WAS NOT TOLD, because it is not given anything else. There is no cell here, no coordinate, no
//! player list, no count. The screen renders a `Tell` and the player's own state, and those are
//! the only two things in the room.
//!
//! ============================================================================
//! INTEGER PIXELS, ON PURPOSE
//!
//! Every coordinate here is an i32 pixel. Not because floats are hard, but because the guard
//! forbids a float in a core file (B6) -- and it turns out that a pixel-snapped, bitmap-strike
//! renderer WANTS integer coordinates anyway. Text that lands on half a pixel is text that looks
//! blurry.
//!
//! The rule and the renderer wanted the same thing. Sub-pixel animation curves, if we ever need
//! them, belong in the shell where the GPU lives.
//!
//! ============================================================================
//! THE SENTENCES ARE THE PRODUCT
//!
//! This game is a readout of a war you cannot see. The words are not decoration on top of the
//! mechanics -- they ARE the mechanics, as the player experiences them.
//!
//! So the copy lives here, in the core, next to a test that asserts it never contains a number.

const std = @import("std");
const combat = @import("combat.zig");
const world_mod = @import("world.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Crowd = combat.Crowd;
const Faction = world_mod.Faction;
const Momentum = combat.Momentum;

/// Packed RGBA. The palette of the feel prototype: near-black, bone, and blood.
pub const Color = enum(u32) {
    void_black = 0x08080AFF,
    carrion = 0x101013FF,
    ash = 0x1C1C20FF,
    bone = 0xF0EFECFF,
    smoke = 0x8F8E8AFF,
    dust = 0x55554FFF,
    grave = 0x33332FFF,
    wound = 0xC8302FFF,
    clot = 0x4A1416FF,
    scab = 0x2A0D0EFF,
    serum = 0x7A5A5AFF,
    _,
};

pub const Weight = enum(u8) { label, body, heading, alarm };

/// One thing to put on the screen. Plain data (A1): no methods, no behaviour.
pub const Draw = union(enum) {
    rect: struct { x: i32, y: i32, w: i32, h: i32, color: Color },
    text: struct { x: i32, y: i32, text: []const u8, color: Color, weight: Weight },
};

/// What the phone knows. All of it.
///
/// A7.2: cold struct, size guard waived -- there is exactly one of these.
pub const State = struct {
    screen: Screen = .choose_side,

    /// Chosen once, permanently. Null until they choose.
    faction: ?Faction = null,
    /// Highlighted but not yet confirmed.
    hovering: ?Faction = null,

    /// The last thing the server said. Null before the first tick.
    hp: u16 = 100,
    level: u16 = 1,
    total_xp: u32 = 0,
    momentum: Momentum = .even,
    crowd: Crowd = .a_few,
    taking_damage: bool = false,

    /// Seconds until the next resolution. The shell counts it down; we only render it.
    seconds_to_tick: u8 = 30,

    /// The tells, oldest first. A ring: the screen holds what it holds and forgets the rest.
    tells: [max_tells][]const u8 = @splat(""),
    tell_count: u8 = 0,

    pub const max_tells = 8;
};

pub const Screen = enum { choose_side, quiet, live };

/// A touch, in pixels.
pub const Touch = struct { x: i32, y: i32 };

pub const Size = struct { w: i32, h: i32 };

// ============================================================================ the words

/// What the player is told about the size of what they have walked into.
///
/// A BAND. NEVER A NUMBER. There is a test below that asserts not one of these sentences
/// contains a digit, and it is not a stylistic test -- an exact count is how a player learns
/// WHO (I1, I5). The lowest band deliberately says nothing about quantity at all.
pub fn crowdSentence(crowd: Crowd) []const u8 {
    return switch (crowd) {
        .a_few => "You are not alone, and not among friends.",
        .dozens => "There are dozens of them in this room.",
        .scores => "You are badly outnumbered.",
        .hundreds => "You are surrounded by hundreds.",
        .thousands => "You are surrounded by thousands.",
    };
}

/// How the fight is going. Categorical, aggregate, and about the fight -- never about a person.
pub fn momentumSentence(momentum: Momentum, you: Faction) []const u8 {
    const winning_is_yours = switch (momentum) {
        .even => return "The fight is even.",
        .humans_edge, .humans_winning => you == .human,
        .zombies_edge, .zombies_winning => you == .zombie,
    };

    const decisive = switch (momentum) {
        .humans_winning, .zombies_winning => true,
        else => false,
    };

    if (winning_is_yours) {
        return if (decisive) "You are winning." else "You have the edge.";
    }
    return if (decisive) "You will not hold much longer." else "They have the edge.";
}

/// Your condition. A BAND, not a number.
///
/// The player is not told "62 hit points". They are told they are failing. A number invites
/// arithmetic; a word invites dread, and dread is the product.
pub fn conditionWord(hp: u16) []const u8 {
    if (hp == 0) return "Down";
    if (hp > 80) return "Whole";
    if (hp > 50) return "Holding";
    if (hp > 20) return "Failing";
    return "Barely";
}

// ============================================================================ input

/// CORE. The player touched the screen. Returns the new state.
///
/// Pure: same state, same touch, same result. No clock, no randomness, no I/O.
pub fn touch(state: State, at: Touch, size: Size) State {
    var next = state;

    switch (state.screen) {
        .choose_side => {
            const human = factionButton(size, .human);
            const zombie = factionButton(size, .zombie);
            const confirm = confirmButton(size);

            if (within(at, human)) next.hovering = .human;
            if (within(at, zombie)) next.hovering = .zombie;

            if (within(at, confirm)) {
                if (state.hovering) |chosen| {
                    // Chosen once. Permanently. There is no code path back to this screen.
                    next.faction = chosen;
                    next.screen = .quiet;
                }
            }
        },

        .quiet => {},

        .live => {
            if (within(at, leaveButton(size))) {
                // "Walk away." It changes nothing about the fight -- the tick resolves the world
                // whether you are looking at it or not (I4). It only stops you watching.
                next.screen = .quiet;
                next.tell_count = 0;
            }
        },
    }

    return next;
}

/// CORE. The server said something. Fold it into what we show.
///
/// This is the ONLY way the screen learns anything. There is no other input, no local
/// simulation, and no prediction -- the phone renders what it is told and computes nothing (H1).
pub fn told(state: State, hp: u16, level: u16, total_xp: u32, damage: u16, momentum: Momentum, crowd: Crowd) State {
    var next = state;

    next.hp = hp;
    next.level = level;
    next.total_xp = total_xp;
    next.momentum = momentum;
    next.crowd = crowd;
    next.taking_damage = damage > 0;
    next.seconds_to_tick = 30;

    // Nothing happened. A quiet cell, an empty field, a room whose fight is over -- the phone
    // cannot tell them apart, and neither can the player. That is the whole design (I3).
    if (damage == 0 and state.screen == .quiet) return next;

    if (damage > 0 and state.screen != .live) {
        next.screen = .live;
        next.tell_count = 0;
        next = push(next, crowdSentence(crowd));
    }

    if (state.screen == .live or next.screen == .live) {
        next = push(next, if (damage > 0) "You are taking damage." else "You are still standing.");
    }

    return next;
}

fn push(state: State, sentence: []const u8) State {
    var next = state;

    if (next.tell_count < State.max_tells) {
        next.tells[next.tell_count] = sentence;
        next.tell_count += 1;
        return next;
    }

    // The screen holds what it holds and forgets the oldest.
    var i: usize = 1;
    while (i < State.max_tells) : (i += 1) next.tells[i - 1] = next.tells[i];
    next.tells[State.max_tells - 1] = sentence;
    return next;
}

// ============================================================================ layout

const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

fn within(at: Touch, rect: Rect) bool {
    return at.x >= rect.x and at.x < rect.x + rect.w and
        at.y >= rect.y and at.y < rect.y + rect.h;
}

const pad: i32 = 22;
const line: i32 = 26;

fn factionButton(size: Size, faction: Faction) Rect {
    const h: i32 = 96;
    const y: i32 = @divTrunc(size.h, 3) + (if (faction == .zombie) h + 12 else 0);
    return .{ .x = pad, .y = y, .w = size.w - pad * 2, .h = h };
}

fn confirmButton(size: Size) Rect {
    return .{ .x = pad, .y = size.h - 120, .w = size.w - pad * 2, .h = 52 };
}

fn leaveButton(size: Size) Rect {
    return .{ .x = pad, .y = size.h - 60, .w = size.w - pad * 2, .h = 40 };
}

// ============================================================================ draw

/// CORE. Turn the state into a list of things to draw. Allocates into the caller's list (C1).
///
/// The shell rasterises this and does nothing else. It never decides what to show.
pub fn draw(state: State, size: Size, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    out.clearRetainingCapacity();

    try out.append(gpa, .{ .rect = .{ .x = 0, .y = 0, .w = size.w, .h = size.h, .color = .void_black } });

    switch (state.screen) {
        .choose_side => try drawChooseSide(state, size, out, gpa),
        .quiet => try drawQuiet(state, size, out, gpa),
        .live => try drawLive(state, size, out, gpa),
    }
}

fn drawChooseSide(state: State, size: Size, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    try out.append(gpa, .{ .text = .{ .x = pad, .y = 40, .text = "OUTBREAK", .color = .grave, .weight = .label } });

    try out.append(gpa, .{ .text = .{ .x = pad, .y = 110, .text = "Choose a side", .color = .bone, .weight = .heading } });
    try out.append(gpa, .{ .text = .{ .x = pad, .y = 110 + line, .text = "This choice is permanent.", .color = .dust, .weight = .body } });
    try out.append(gpa, .{ .text = .{ .x = pad, .y = 110 + line * 2, .text = "You will never be able to change it.", .color = .dust, .weight = .body } });

    const human = factionButton(size, .human);
    const zombie = factionButton(size, .zombie);

    try drawFaction(state, human, .human, "Human", "You hold. You are outnumbered and you know it.", out, gpa);
    try drawFaction(state, zombie, .zombie, "Zombie", "You persist. You were already here.", out, gpa);

    const confirm = confirmButton(size);
    const ready = state.hovering != null;
    try out.append(gpa, .{ .rect = .{ .x = confirm.x, .y = confirm.y, .w = confirm.w, .h = confirm.h, .color = if (ready) .scab else .carrion } });
    try out.append(gpa, .{ .text = .{ .x = confirm.x + 16, .y = confirm.y + 18, .text = "Confirm", .color = if (ready) .bone else .grave, .weight = .body } });

    try out.append(gpa, .{ .text = .{ .x = pad, .y = size.h - 50, .text = "No faction is stronger. Only different.", .color = .grave, .weight = .body } });
}

fn drawFaction(
    state: State,
    rect: Rect,
    faction: Faction,
    name: []const u8,
    blurb: []const u8,
    out: *std.ArrayList(Draw),
    gpa: Allocator,
) Allocator.Error!void {
    const chosen = state.hovering == faction;
    try out.append(gpa, .{ .rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .color = if (chosen) .clot else .carrion } });
    try out.append(gpa, .{ .text = .{ .x = rect.x + 16, .y = rect.y + 20, .text = name, .color = .bone, .weight = .heading } });
    try out.append(gpa, .{ .text = .{ .x = rect.x + 16, .y = rect.y + 52, .text = blurb, .color = if (faction == .zombie) .serum else .dust, .weight = .body } });
}

fn drawQuiet(state: State, size: Size, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    try out.append(gpa, .{ .text = .{ .x = pad, .y = 40, .text = factionLabel(state.faction), .color = .dust, .weight = .label } });

    // The ring, and the word. This is what the game says almost all of the time, and it is the
    // most important screen in the product: NOTHING HERE.
    const mid_y = @divTrunc(size.h, 2);
    const ring: i32 = 96;
    try out.append(gpa, .{ .rect = .{ .x = @divTrunc(size.w - ring, 2), .y = mid_y - ring, .w = ring, .h = ring, .color = .ash } });
    try out.append(gpa, .{ .text = .{ .x = @divTrunc(size.w, 2) - 48, .y = mid_y + 24, .text = "Nothing here.", .color = .dust, .weight = .body } });

    try out.append(gpa, .{ .text = .{ .x = pad, .y = size.h - 140, .text = "CONDITION", .color = .grave, .weight = .label } });
    try out.append(gpa, .{ .text = .{ .x = size.w - pad - 80, .y = size.h - 140, .text = conditionWord(state.hp), .color = .smoke, .weight = .body } });

    try out.append(gpa, .{ .text = .{ .x = pad, .y = size.h - 110, .text = "LEVEL", .color = .grave, .weight = .label } });
}

fn drawLive(state: State, size: Size, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    try out.append(gpa, .{ .text = .{ .x = pad, .y = 40, .text = factionLabel(state.faction), .color = .serum, .weight = .label } });

    try out.append(gpa, .{ .text = .{ .x = pad, .y = 80, .text = "THIS CELL IS LIVE", .color = .wound, .weight = .alarm } });

    // The scale of it. A band, never a number.
    try out.append(gpa, .{ .text = .{ .x = pad, .y = 120, .text = crowdSentence(state.crowd), .color = .bone, .weight = .heading } });

    // Your condition, as a word. Never as a number.
    try out.append(gpa, .{ .rect = .{ .x = pad, .y = 190, .w = size.w - pad * 2, .h = 72, .color = .scab } });
    try out.append(gpa, .{ .text = .{ .x = pad + 14, .y = 206, .text = "CONDITION", .color = .serum, .weight = .label } });
    try out.append(gpa, .{ .text = .{ .x = size.w - pad - 90, .y = 206, .text = conditionWord(state.hp), .color = .bone, .weight = .body } });
    try out.append(gpa, .{ .text = .{ .x = pad + 14, .y = 236, .text = momentumSentence(state.momentum, state.faction orelse .human), .color = .serum, .weight = .body } });

    // What you know. The tells, seeping in.
    try out.append(gpa, .{ .text = .{ .x = pad, .y = 290, .text = "WHAT YOU KNOW", .color = .grave, .weight = .label } });

    var i: u8 = 0;
    while (i < state.tell_count) : (i += 1) {
        const y = 320 + @as(i32, i) * line;
        try out.append(gpa, .{ .rect = .{ .x = pad, .y = y, .w = 2, .h = 18, .color = .ash } });
        try out.append(gpa, .{ .text = .{ .x = pad + 14, .y = y, .text = state.tells[i], .color = .smoke, .weight = .body } });
    }

    const leave = leaveButton(size);
    try out.append(gpa, .{ .text = .{ .x = pad, .y = size.h - 100, .text = "There is nothing to do but stay.", .color = .grave, .weight = .body } });
    try out.append(gpa, .{ .text = .{ .x = leave.x, .y = leave.y, .text = "Walk away", .color = .grave, .weight = .body } });
}

fn factionLabel(faction: ?Faction) []const u8 {
    const f = faction orelse return "";
    return switch (f) {
        .human => "HUMAN",
        .zombie => "ZOMBIE",
    };
}

const testing = std.testing;

test "NOT ONE SENTENCE IN THIS GAME CONTAINS A NUMBER" {
    // I1, I5, and the author's decision: the crowd is GENERIC, never a count.
    //
    // This is not a stylistic test. An exact number is how a player learns WHO -- watch it fall
    // from four to three as one specific person stands up and walks out of the café, and you have
    // named them. The band exists so there is nothing to watch move.
    //
    // A digit anywhere in this copy is a bug, and it would be a bug of the most dangerous kind:
    // one that looks like a UI improvement.
    for ([_]Crowd{ .a_few, .dozens, .scores, .hundreds, .thousands }) |crowd| {
        for (crowdSentence(crowd)) |char| {
            try testing.expect(!std.ascii.isDigit(char));
        }
    }

    for ([_]Momentum{ .even, .humans_edge, .zombies_edge, .humans_winning, .zombies_winning }) |momentum| {
        for (momentumSentence(momentum, .human)) |char| {
            try testing.expect(!std.ascii.isDigit(char));
        }
        for (momentumSentence(momentum, .zombie)) |char| {
            try testing.expect(!std.ascii.isDigit(char));
        }
    }

    // And your own condition is a word, not a number. A number invites arithmetic. A word invites
    // dread, and dread is the product.
    var hp: u16 = 0;
    while (hp <= 100) : (hp += 1) {
        for (conditionWord(hp)) |char| {
            try testing.expect(!std.ascii.isDigit(char));
        }
    }
}

test "the fight reads the same to both sides" {
    // Momentum is about the FIGHT, not about a faction. A human losing and a zombie losing must
    // read identically -- otherwise the sentence has told you something about who is in the room.
    try testing.expectEqualStrings(
        momentumSentence(.humans_winning, .human),
        momentumSentence(.zombies_winning, .zombie),
    );
    try testing.expectEqualStrings(
        momentumSentence(.humans_winning, .zombie),
        momentumSentence(.zombies_winning, .human),
    );
    try testing.expectEqualStrings("The fight is even.", momentumSentence(.even, .human));
}

test "choosing a side is permanent" {
    const size: Size = .{ .w = 380, .h = 760 };

    var state: State = .{};
    try testing.expectEqual(Screen.choose_side, state.screen);

    // Tapping a card highlights it. It does not commit.
    const human = factionButton(size, .human);
    state = touch(state, .{ .x = human.x + 10, .y = human.y + 10 }, size);
    try testing.expectEqual(Faction.human, state.hovering.?);
    try testing.expectEqual(@as(?Faction, null), state.faction);

    // Confirm commits.
    const confirm = confirmButton(size);
    state = touch(state, .{ .x = confirm.x + 10, .y = confirm.y + 10 }, size);
    try testing.expectEqual(Faction.human, state.faction.?);
    try testing.expectEqual(Screen.quiet, state.screen);

    // And there is no way back. Touching anything on the quiet screen does not return you.
    state = touch(state, .{ .x = 10, .y = 10 }, size);
    try testing.expectEqual(Screen.quiet, state.screen);
    try testing.expectEqual(Faction.human, state.faction.?);
}

test "a quiet tick shows nothing, and shows it forever" {
    // The most important screen in the product, and the one that is on almost all the time.
    var state: State = .{ .screen = .quiet, .faction = .human };

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        state = told(state, 100, 1, 0, 0, .even, .a_few);
        try testing.expectEqual(Screen.quiet, state.screen);
        try testing.expectEqual(@as(u8, 0), state.tell_count);
    }
}

test "damage wakes the screen, and the first thing it says is the scale of it" {
    var state: State = .{ .screen = .quiet, .faction = .human };

    state = told(state, 88, 3, 400, 12, .zombies_winning, .hundreds);

    try testing.expectEqual(Screen.live, state.screen);
    try testing.expect(state.taking_damage);
    try testing.expectEqualStrings(crowdSentence(.hundreds), state.tells[0]);
    try testing.expectEqualStrings("You are taking damage.", state.tells[1]);
}

test "walking away changes nothing about the fight" {
    // I4. The tick resolves the world whether you are looking at it or not. "Walk away" closes a
    // screen; it does not end an engagement, and it confers no advantage of any kind.
    const size: Size = .{ .w = 380, .h = 760 };

    var state: State = .{ .screen = .quiet, .faction = .human };
    state = told(state, 60, 1, 0, 10, .zombies_winning, .a_few);
    try testing.expectEqual(Screen.live, state.screen);

    const leave = leaveButton(size);
    state = touch(state, .{ .x = leave.x + 4, .y = leave.y + 4 }, size);

    try testing.expectEqual(Screen.quiet, state.screen);

    // The damage still lands. The server does not care that you closed the screen.
    state = told(state, 40, 1, 0, 20, .zombies_winning, .a_few);
    try testing.expectEqual(@as(u16, 40), state.hp);
}

test "the tells are a ring: the screen holds what it holds" {
    var state: State = .{ .screen = .live, .faction = .human };

    var i: usize = 0;
    while (i < State.max_tells * 3) : (i += 1) {
        state = told(state, 50, 1, 0, 5, .even, .a_few);
    }

    try testing.expectEqual(State.max_tells, state.tell_count);
}

test "the draw list says nothing the state did not" {
    const gpa = testing.allocator;
    const size: Size = .{ .w = 380, .h = 760 };

    var out: std.ArrayList(Draw) = .empty;
    defer out.deinit(gpa);

    const state: State = .{ .screen = .quiet, .faction = .zombie };
    try draw(state, size, &out, gpa);

    // Every string on the screen came from the state or from the copy above. There is no cell in
    // this list, no coordinate, no count, and no name -- because there is none in the state.
    var found_nothing_here = false;
    for (out.items) |item| switch (item) {
        .text => |t| {
            if (std.mem.eql(u8, t.text, "Nothing here.")) found_nothing_here = true;
            for (t.text) |char| try testing.expect(!std.ascii.isDigit(char));
        },
        .rect => {},
    };

    try testing.expect(found_nothing_here);
}
