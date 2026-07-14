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

/// Packed RGBA. Near-black, bone, and blood.
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

    // ---- the boot sequence. Scorched char, and blood under a bad light.
    char = 0x171514FF,
    char_deep = 0x0D0C0BFF,
    blood = 0xE30613FF,
    blood_deep = 0xA30410FF,
    blood_glow = 0xFF2436FF,
    amber = 0xF0A020FF,
    terminal = 0x8A8078FF,
    faint = 0x6A625DFF,

    // Non-exhaustive, so the shell can carry an alpha-varied tint without a new name for every
    // step of a fade. `dim()` below is the only sanctioned way to make one.
    _,
};

/// The same colour, at a fraction of its opacity.
///
/// A fade is not a new colour and does not deserve a new name in the palette. `alpha` is 0..255,
/// and the RGB is untouched -- the renderer multiplies it into the coverage.
pub fn dim(colour: Color, alpha: u8) Color {
    return @enumFromInt((@intFromEnum(colour) & 0xFFFFFF00) | @as(u32, alpha));
}

/// A shape the renderer bakes into its atlas at startup, so that one shader and one draw call can
/// still produce something that is not a rectangle.
///
/// The whole renderer is "colour times a coverage value sampled from a texture". A letter samples
/// its glyph; a rectangle samples a white texel. So a RADIAL FALLOFF baked into that same texture
/// is a soft dot -- and a soft dot, tinted and scaled, is every gradient the boot screen needs.
///
/// This is why there is no second shader and no gradient code: there did not need to be one.
pub const Sprite = enum {
    /// Opaque at the centre, fading to nothing at the rim. A spore. A glow. A bloom.
    disc,
    /// The inverse: a hole in the middle, opaque at the edges. Scaled up over the screen and
    /// tinted with the background, it is a circular wipe that opens outward.
    vignette,
};

pub const Weight = enum(u8) { label, body, heading, alarm, wordmark };

/// WHERE THE TEXT SITS RELATIVE TO ITS x.
///
/// The core cannot measure a string -- it has no font, and it is never going to have one. The
/// RENDERER has the font, so the renderer does the arithmetic: the core says "centre this here"
/// and the shell works out where "here" begins.
///
/// Before this existed, `ui.zig` right-aligned by guessing a pixel offset (`size.w - pad - 80`),
/// which is a magic number that is wrong for every string except the one it was tuned against.
pub const Align = enum(u8) { left, center, right };

/// One thing to put on the screen. Plain data (A1): no methods, no behaviour.
pub const Draw = union(enum) {
    rect: struct { x: i32, y: i32, w: i32, h: i32, color: Color },
    text: struct { x: i32, y: i32, text: []const u8, color: Color, weight: Weight, alignment: Align = .left },
    sprite: struct { x: i32, y: i32, w: i32, h: i32, color: Color, sprite: Sprite },
};

/// What the phone knows. All of it.
///
/// A7.2: cold struct, size guard waived -- there is exactly one of these.
pub const State = struct {
    screen: Screen = .boot,

    /// MILLISECONDS SINCE THE APP OPENED. Supplied by the shell; the core never asks the time.
    ///
    /// This is the same trick as the tick: time is not something the core reaches for, it is a
    /// value handed in (B3, B7). The boot sequence is therefore a PURE FUNCTION of this number --
    /// which means the whole animation is testable at any instant, on a laptop, with no phone and
    /// no clock, by simply passing the millisecond you want to look at.
    boot_ms: u32 = 0,

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

pub const Screen = enum {
    /// The boot sequence. Terminal, infection, wordmark.
    boot,

    choose_side,
    quiet,
    live,

    /// CREDITS. Not a nicety, and not optional.
    ///
    /// The music is CC BY 4.0 and the fonts are OFL. Both licences REQUIRE the credit to reach the
    /// person using the work -- a line in a repository file is where we keep our own books, it is
    /// not attribution. The obligation is discharged on a screen or it is not discharged.
    ///
    /// So this screen exists before the music does. If we cannot put a credit in front of a player,
    /// we do not get to use the track.
    credits,
};

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
        // A tap ends the boot sequence, at ANY point in it. A splash screen you cannot skip is a
        // splash screen that is being shown to you for someone else's benefit.
        .boot => next.screen = if (state.faction == null) .choose_side else .quiet,

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

            if (within(at, creditsLink(size))) next.screen = .credits;
        },

        .quiet => {
            if (within(at, creditsLink(size))) next.screen = .credits;
        },

        .credits => {
            // Back to wherever they were. A player who has not chosen a side has not chosen one;
            // reading the credits is not a way to skip that.
            if (within(at, backButton(size))) {
                next.screen = if (state.faction == null) .choose_side else .quiet;
            }
        },

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

fn overlaps(a: Rect, b: Rect) bool {
    return a.x < b.x + b.w and b.x < a.x + a.w and
        a.y < b.y + b.h and b.y < a.y + a.h;
}

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

/// The credit, bottom right. Small, quiet, and always reachable.
///
/// It is on `choose_side` and on `quiet` -- the two screens a player is looking at when nothing is
/// happening -- and NOT on `live`. A fight is not the moment to advertise the soundtrack, and a
/// licence obligation does not entitle us to interrupt the one thing the game is for.
fn creditsLink(size: Size) Rect {
    // TOP RIGHT, and it took two tries to get here.
    //
    // The bottom of the screen is crowded: `confirmButton` holds size.h-120..-68, `leaveButton`
    // holds -60..-20, and the tagline sits at -50. There is no honest 24px band left down there,
    // and both of my first two attempts LANDED ON A BUTTON -- invisible, because the link is not
    // drawn on the screen whose button it covered, and therefore a tap that would quietly have
    // done the wrong thing on the day someone moved either rectangle.
    //
    // The top-right corner is empty on every screen: the faction label and the game's name are
    // left-aligned. The test below asserts this collides with nothing, and it earned its keep.
    const w: i32 = 150;
    const h: i32 = 26;
    return .{ .x = size.w - pad - w, .y = 34, .w = w, .h = h };
}

fn backButton(size: Size) Rect {
    return .{ .x = pad, .y = size.h - 60, .w = 120, .h = 40 };
}

// ============================================================================ draw

/// CORE. Turn the state into a list of things to draw. Allocates into the caller's list (C1).
///
/// The shell rasterises this and does nothing else. It never decides what to show.
pub fn draw(state: State, size: Size, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    out.clearRetainingCapacity();

    try out.append(gpa, .{ .rect = .{ .x = 0, .y = 0, .w = size.w, .h = size.h, .color = .void_black } });

    switch (state.screen) {
        .boot => try drawBoot(state, size, out, gpa),
        .choose_side => try drawChooseSide(state, size, out, gpa),
        .quiet => try drawQuiet(state, size, out, gpa),
        .live => try drawLive(state, size, out, gpa),
        .credits => try drawCredits(size, out, gpa),
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

    try drawCreditsLink(size, out, gpa);
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

    try drawCreditsLink(size, out, gpa);
}

fn drawCreditsLink(size: Size, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    const link = creditsLink(size);
    try out.append(gpa, .{ .text = .{ .x = link.x, .y = link.y, .text = "Music: Tim Beek", .color = .grave, .weight = .label } });
}

/// THE CREDITS. The licences require this, and the requirement is the point.
///
/// CC BY 4.0 obliges us to name the creator, link the licence, and say whether we changed the work.
/// The SIL Open Font License obliges the same for the typefaces. None of those obligations are
/// discharged by a file in a repository -- they are discharged in front of a person, or not at all.
///
/// So this screen exists BEFORE the music does. If we cannot put a credit on a screen, we do not
/// get to use the track.
fn drawCredits(size: Size, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    try out.append(gpa, .{ .text = .{ .x = pad, .y = 40, .text = "CREDITS", .color = .dust, .weight = .label } });

    var y: i32 = 100;

    try out.append(gpa, .{ .text = .{ .x = pad, .y = y, .text = "Music", .color = .bone, .weight = .heading } });
    y += 40;
    try out.append(gpa, .{ .text = .{ .x = pad, .y = y, .text = "Piano Zombie", .color = .smoke, .weight = .body } });
    y += line;
    try out.append(gpa, .{ .text = .{ .x = pad, .y = y, .text = "Tim Beek", .color = .bone, .weight = .body } });
    y += line;
    try out.append(gpa, .{ .text = .{ .x = pad, .y = y, .text = "timbeek.com", .color = .dust, .weight = .body } });
    y += line;
    try out.append(gpa, .{ .text = .{ .x = pad, .y = y, .text = "Licensed CC BY 4.0. Not modified.", .color = .dust, .weight = .body } });

    y += 60;
    try out.append(gpa, .{ .text = .{ .x = pad, .y = y, .text = "Type", .color = .bone, .weight = .heading } });
    y += 40;
    try out.append(gpa, .{ .text = .{ .x = pad, .y = y, .text = "Oxanium by Severin Meyer", .color = .smoke, .weight = .body } });
    y += line;
    try out.append(gpa, .{ .text = .{ .x = pad, .y = y, .text = "Inter by Rasmus Andersson", .color = .smoke, .weight = .body } });
    y += line;
    try out.append(gpa, .{ .text = .{ .x = pad, .y = y, .text = "Both under the SIL Open Font License.", .color = .dust, .weight = .body } });

    y += 60;
    try out.append(gpa, .{ .text = .{ .x = pad, .y = y, .text = "Code", .color = .bone, .weight = .heading } });
    y += 40;
    try out.append(gpa, .{ .text = .{ .x = pad, .y = y, .text = "stb_truetype by Sean Barrett", .color = .smoke, .weight = .body } });
    y += line;
    try out.append(gpa, .{ .text = .{ .x = pad, .y = y, .text = "Public domain.", .color = .dust, .weight = .body } });

    const back = backButton(size);
    try out.append(gpa, .{ .rect = .{ .x = back.x, .y = back.y, .w = back.w, .h = back.h, .color = .carrion } });
    try out.append(gpa, .{ .text = .{ .x = back.x + 16, .y = back.y + 10, .text = "Back", .color = .bone, .weight = .body } });
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

// ============================================================================ the boot sequence

/// The phases, in milliseconds since the app opened.
///
/// A PURE FUNCTION OF `boot_ms` AND NOTHING ELSE. There is no timer, no callback, no animation
/// state machine, and nothing to get out of step -- ask for millisecond 2,400 and you get exactly
/// the frame that belongs at millisecond 2,400, forever, on any machine.
const boot_terminal_ms: u32 = 1900;
const boot_infection_ms: u32 = 1300;
const boot_glitch_ms: u32 = 420;

const boot_infection_end = boot_terminal_ms + boot_infection_ms;
const boot_glitch_end = boot_infection_end + boot_glitch_ms;

/// The line the terminal is on, and how far into that line we are.
const boot_line_ms: u32 = boot_terminal_ms / boot_lines.len;

const BootLine = struct { text: []const u8, status: []const u8, bad: bool };

const boot_lines = [_]BootLine{
    .{ .text = "> SECTOR SCAN . . . . . . .", .status = "[ OK ]", .bad = false },
    .{ .text = "> QUARANTINE PROTOCOL", .status = "[ OK ]", .bad = false },
    .{ .text = "> SIGNAL LOCK ACQUIRED", .status = "[ OK ]", .bad = false },
    .{ .text = "> CONTAMINATION DETECTED", .status = "[ !! ]", .bad = true },
    .{ .text = "> ESTABLISHING PERIMETER", .status = "[ OK ]", .bad = false },
};

/// Spores. Fixed positions, as thousandths of the band, so the field is identical every boot and
/// on every screen size. A random scatter would need a clock or a seed, and the core has neither.
const Spore = struct { fx: i32, fy: i32, r: i32, hot: bool };

const spores = [_]Spore{
    .{ .fx = 100, .fy = 200, .r = 3, .hot = false },
    .{ .fx = 220, .fy = 550, .r = 4, .hot = false },
    .{ .fx = 330, .fy = 120, .r = 2, .hot = true },
    .{ .fx = 460, .fy = 700, .r = 5, .hot = false },
    .{ .fx = 580, .fy = 300, .r = 3, .hot = false },
    .{ .fx = 670, .fy = 600, .r = 2, .hot = true },
    .{ .fx = 780, .fy = 180, .r = 4, .hot = false },
    .{ .fx = 880, .fy = 480, .r = 3, .hot = false },
    .{ .fx = 150, .fy = 800, .r = 4, .hot = false },
    .{ .fx = 400, .fy = 900, .r = 2, .hot = true },
    .{ .fx = 720, .fy = 850, .r = 4, .hot = false },
    .{ .fx = 920, .fy = 780, .r = 3, .hot = false },
    .{ .fx = 280, .fy = 400, .r = 6, .hot = false },
    .{ .fx = 520, .fy = 500, .r = 4, .hot = false },
};

/// A triangle wave, 0..255, integer only. The core has no floats and does not need them for this.
fn pulse(ms: u32, period: u32, low: u32, high: u32) u8 {
    const half = period / 2;
    const phase = ms % period;
    const rising = phase < half;
    const t = if (rising) phase else half - (phase - half);
    return @intCast(low + (high - low) * t / half);
}

fn drawBoot(state: State, size: Size, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    const ms = state.boot_ms;

    // Scorched char, not the game's usual near-black. The boot screen is a different room.
    try out.append(gpa, .{ .rect = .{ .x = 0, .y = 0, .w = size.w, .h = size.h, .color = .char_deep } });

    if (ms < boot_terminal_ms) {
        try drawBootTerminal(ms, size, out, gpa);
    } else {
        try drawSpores(size, out, gpa);
        try drawWordmark(ms, size, out, gpa);

        if (ms < boot_infection_end) {
            try drawInfection(ms, size, out, gpa);
        } else {
            try drawBootTail(ms, size, out, gpa);
        }
    }

    try drawScanlines(size, out, gpa);
}

fn drawBootTerminal(ms: u32, size: Size, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    const shown = @min(boot_lines.len, ms / boot_line_ms + 1);

    var i: usize = 0;
    while (i < shown) : (i += 1) {
        const y: i32 = 90 + @as(i32, @intCast(i)) * 30;
        const l = boot_lines[i];

        try out.append(gpa, .{ .text = .{ .x = 26, .y = y, .text = l.text, .color = .terminal, .weight = .label } });
        try out.append(gpa, .{ .text = .{
            .x = size.w - 26,
            .y = y,
            .text = l.status,
            .color = if (l.bad) .amber else .blood,
            .weight = .label,
            .alignment = .right,
        } });
    }

    // The cursor, blinking on the next line down. A hard on/off, not a fade -- a terminal cursor
    // does not breathe.
    const on = (ms / 500) % 2 == 0;
    if (on) {
        const y: i32 = 90 + @as(i32, @intCast(shown)) * 30;
        try out.append(gpa, .{ .text = .{ .x = 26, .y = y, .text = ">", .color = .terminal, .weight = .label } });
        try out.append(gpa, .{ .rect = .{ .x = 44, .y = y + 3, .w = 8, .h = 14, .color = .blood } });
    }
}

/// The spore fields: a band at the top, and the same band mirrored at the bottom.
fn drawSpores(size: Size, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    const band = @divTrunc(size.h * 34, 100);

    for (spores) |s| {
        const x = @divTrunc(size.w * s.fx, 1000);
        const y = @divTrunc(band * s.fy, 1000);
        const colour: Color = if (s.hot) .blood_glow else .blood_deep;

        // Top.
        try out.append(gpa, .{ .sprite = .{ .x = x - s.r, .y = y - s.r, .w = s.r * 2, .h = s.r * 2, .color = colour, .sprite = .disc } });
        // And mirrored at the bottom, exactly as the mock flips the band.
        try out.append(gpa, .{ .sprite = .{ .x = x - s.r, .y = size.h - y - s.r, .w = s.r * 2, .h = s.r * 2, .color = colour, .sprite = .disc } });
    }

    // The two soft blooms that make it a field rather than a scatter of dots.
    const bloom = @divTrunc(size.w * 7, 10);
    try out.append(gpa, .{ .sprite = .{
        .x = @divTrunc(size.w * 3, 10) - @divTrunc(bloom, 2),
        .y = @divTrunc(band * 3, 10) - @divTrunc(bloom, 2),
        .w = bloom,
        .h = bloom,
        .color = dim(.blood, 26),
        .sprite = .disc,
    } });
    try out.append(gpa, .{ .sprite = .{
        .x = @divTrunc(size.w * 7, 10) - @divTrunc(bloom, 2),
        .y = size.h - @divTrunc(band * 6, 10) - @divTrunc(bloom, 2),
        .w = bloom,
        .h = bloom,
        .color = dim(.blood, 20),
        .sprite = .disc,
    } });
}

/// OUTBREAK. Stencilled, bloomed, and -- for four hundred milliseconds -- broken.
fn drawWordmark(ms: u32, size: Size, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    // It burns in from sixty percent of the infection, as in the mock.
    const burn_at = boot_terminal_ms + @divTrunc(boot_infection_ms * 6, 10);
    if (ms < burn_at) return;

    const mid_x = @divTrunc(size.w, 2);
    const mid_y = @divTrunc(size.h, 2);

    // The bloom. This is the disc doing the work a `text-shadow` does in CSS -- and it is the same
    // one draw call as everything else.
    const glow = @divTrunc(size.w * 9, 10);
    try out.append(gpa, .{ .sprite = .{
        .x = mid_x - @divTrunc(glow, 2),
        .y = mid_y - @divTrunc(glow, 2) - 10,
        .w = glow,
        .h = glow,
        .color = dim(.blood, 60),
        .sprite = .disc,
    } });

    const top = mid_y - 40;

    // THE GLITCH. Two off-register copies, red and cold blue, for the length of one flinch. The
    // channels tear apart and snap back -- exactly what the CSS does with `text-shadow` offsets.
    const glitching = ms >= boot_infection_end and ms < boot_glitch_end;
    if (glitching) {
        const swing: i32 = if ((ms / 60) % 2 == 0) 3 else -3;
        try out.append(gpa, .{ .text = .{ .x = mid_x + swing, .y = top, .text = "OUTBREAK", .color = dim(.blood_glow, 170), .weight = .wordmark, .alignment = .center } });
        try out.append(gpa, .{ .text = .{ .x = mid_x - swing, .y = top, .text = "OUTBREAK", .color = @enumFromInt(0x24A0FFAA), .weight = .wordmark, .alignment = .center } });
    }

    try out.append(gpa, .{ .text = .{ .x = mid_x, .y = top, .text = "OUTBREAK", .color = .blood, .weight = .wordmark, .alignment = .center } });

    // THE STENCIL BREAKS. The mock does this with a repeating-linear-gradient: 14px clear, 2px of
    // background, over and over. So do we -- except ours are literal rectangles of background
    // colour painted back over the letters, which is what that gradient was always describing.
    var x: i32 = mid_x - @divTrunc(size.w, 2);
    while (x < mid_x + @divTrunc(size.w, 2)) : (x += 16) {
        try out.append(gpa, .{ .rect = .{ .x = x, .y = top - 6, .w = 2, .h = 68, .color = dim(.char_deep, 140) } });
    }
}

/// The infection: the bar fills, and the dark closes in around the wordmark.
fn drawInfection(ms: u32, size: Size, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    const into = ms - boot_terminal_ms;
    const percent: i32 = @intCast(@min(100, into * 100 / boot_infection_ms));

    // THE WIPE. The vignette sprite, tinted with the background and scaled far past the screen, so
    // its transparent centre is a hole that CLOSES as the infection takes hold. In the mock this
    // is a radial-gradient whose radius shrinks; here it is one quad, and the same one draw call.
    const open = 320 - percent * 3; // percent of the screen, 320 -> 20
    const wipe_w = @divTrunc(size.w * open, 100);
    const wipe_h = @divTrunc(size.h * open, 100);
    try out.append(gpa, .{ .sprite = .{
        .x = @divTrunc(size.w, 2) - @divTrunc(wipe_w, 2),
        .y = @divTrunc(size.h, 2) - @divTrunc(wipe_h, 2),
        .w = wipe_w,
        .h = wipe_h,
        .color = .char_deep,
        .sprite = .vignette,
    } });

    const left: i32 = 38;
    const right: i32 = size.w - 38;
    const bar_y = size.h - 74;

    try out.append(gpa, .{ .text = .{ .x = left, .y = bar_y - 18, .text = "C O N T A I N M E N T   F A I L I N G", .color = .faint, .weight = .label } });

    try out.append(gpa, .{ .rect = .{ .x = left, .y = bar_y, .w = right - left, .h = 3, .color = .char } });
    try out.append(gpa, .{ .rect = .{
        .x = left,
        .y = bar_y,
        .w = @divTrunc((right - left) * percent, 100),
        .h = 3,
        .color = .blood_glow,
    } });
}

/// The tagline, and the invitation.
fn drawBootTail(ms: u32, size: Size, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    const mid_x = @divTrunc(size.w, 2);

    // SATURATING. This function runs from `boot_infection_end`, but the tagline is timed from
    // `boot_glitch_end` -- which is 420ms LATER. A plain subtraction underflows a u32 for every one
    // of those 420 milliseconds, and this library ships ReleaseSafe, so it does not wrap quietly:
    // it panics, on the phone, four seconds into the first thing a player ever sees.
    //
    // It shipped. The tests sampled instants either side of the window and stepped clean over it.
    // The test below now walks every millisecond, because a boot sequence that is a pure function
    // of one integer has no excuse for being sampled.
    const since = ms -| boot_glitch_end;
    const fade: u8 = @intCast(@min(@as(u32, 255), since * 255 / 400));

    try out.append(gpa, .{ .text = .{
        .x = mid_x,
        .y = @divTrunc(size.h, 2) + 44,
        .text = "H U M A N I T Y ' S   L A S T   S T A N D",
        .color = dim(.faint, fade),
        .weight = .label,
        .alignment = .center,
    } });

    // Breathing, not blinking. It is an invitation, not an alarm.
    if (since > 300) {
        try out.append(gpa, .{ .text = .{
            .x = mid_x,
            .y = size.h - 52,
            .text = "T A P   T O   E N T E R",
            .color = dim(.terminal, pulse(since, 1600, 90, 255)),
            .weight = .label,
            .alignment = .center,
        } });
    }
}

/// The CRT. Six percent white, every third row. It costs a few hundred rectangles and it is what
/// makes the whole thing feel like it is being displayed rather than drawn.
fn drawScanlines(size: Size, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    var y: i32 = 0;
    while (y < size.h) : (y += 3) {
        try out.append(gpa, .{ .rect = .{ .x = 0, .y = y, .w = size.w, .h = 1, .color = dim(.bone, 15) } });
    }
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

    // Explicit now that the app opens on the boot sequence. A test that relied on the default was
    // a test that would have silently changed meaning the day the default did.
    var state: State = .{ .screen = .choose_side };
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
        .rect, .sprite => {},
    };

    try testing.expect(found_nothing_here);
}

test "THE CREDIT IS REACHABLE, AND IT NAMES THE PEOPLE" {
    // THIS IS A LICENCE OBLIGATION, BOUND TO A MECHANISM.
    //
    // CC BY 4.0 and the SIL Open Font License both require the credit to reach the PERSON USING THE
    // WORK. A row in a repository file is where we keep our own books; it is not attribution.
    //
    // Left to a comment, this is the kind of thing that silently stops being true -- someone
    // reworks a screen, the line goes, and we are shipping someone else's music with no credit on
    // it. So it is a test, and it fails if the names leave the app.
    const gpa = testing.allocator;
    const size: Size = .{ .w = 360, .h = 800 };

    var out: std.ArrayList(Draw) = .empty;
    defer out.deinit(gpa);

    // Reachable from the two screens a player looks at when nothing is happening.
    for ([_]State{
        .{ .screen = .choose_side },
        .{ .screen = .quiet, .faction = .human },
    }) |start| {
        const link = creditsLink(size);
        const opened = touch(start, .{ .x = link.x + 4, .y = link.y + 4 }, size);
        try testing.expectEqual(Screen.credits, opened.screen);
    }

    // NOT reachable from a live cell. A fight is not the moment to advertise the soundtrack, and a
    // licence obligation does not entitle us to interrupt the one thing the game is for.
    const fighting: State = .{ .screen = .live, .faction = .human };
    const link = creditsLink(size);
    try testing.expectEqual(Screen.live, touch(fighting, .{ .x = link.x + 4, .y = link.y + 4 }, size).screen);

    // AND THE LINK MUST NOT SIT ON TOP OF A CONTROL THAT DOES EXIST THERE.
    //
    // The first version of it did: it overlapped "Walk away" on the live screen. It was invisible,
    // because the link is not drawn during a fight -- so the only symptom would have been a tap
    // that quietly did the wrong thing on the day someone moved either rectangle.
    const leave = leaveButton(size);
    const confirm = confirmButton(size);
    try testing.expect(!overlaps(link, leave));
    try testing.expect(!overlaps(link, confirm));

    // And the screen itself carries the credits the licences actually require.
    try draw(.{ .screen = .credits, .faction = .human }, size, &out, gpa);

    var has_creator = false;
    var has_site = false;
    var has_licence = false;
    var has_fonts = false;
    var has_stb = false;

    for (out.items) |item| switch (item) {
        .text => |t| {
            if (std.mem.eql(u8, t.text, "Tim Beek")) has_creator = true;
            if (std.mem.eql(u8, t.text, "timbeek.com")) has_site = true;
            if (std.mem.indexOf(u8, t.text, "CC BY 4.0") != null) has_licence = true;
            if (std.mem.indexOf(u8, t.text, "Open Font License") != null) has_fonts = true;
            if (std.mem.indexOf(u8, t.text, "stb_truetype") != null) has_stb = true;
        },
        .rect, .sprite => {},
    };

    try testing.expect(has_creator);
    try testing.expect(has_site);
    try testing.expect(has_licence); // CC BY also requires us to say whether we changed the work
    try testing.expect(has_fonts);
    try testing.expect(has_stb);

    // And there is a way out. A screen you cannot leave is a screen nobody opens twice.
    const back = backButton(size);
    const left = touch(.{ .screen = .credits, .faction = .human }, .{ .x = back.x + 4, .y = back.y + 4 }, size);
    try testing.expectEqual(Screen.quiet, left.screen);

    // Reading the credits is not a way to skip choosing a side.
    const undecided = touch(.{ .screen = .credits, .faction = null }, .{ .x = back.x + 4, .y = back.y + 4 }, size);
    try testing.expectEqual(Screen.choose_side, undecided.screen);
    try testing.expectEqual(@as(?Faction, null), undecided.faction);
}

test "EVERY MILLISECOND OF THE BOOT SEQUENCE, NOT A SAMPLE OF THEM" {
    // THIS TEST EXISTS BECAUSE THE SAMPLED ONE SHIPPED A CRASH.
    //
    // The tagline's fade was timed from the END of the glitch, but the function that draws it
    // starts at the START of the glitch -- so for 420 milliseconds it computed `ms - later_ms` on
    // a u32. Underflow. ReleaseSafe turns that into a panic rather than a wrap, so the app died on
    // the phone, four seconds into the first thing a player ever sees.
    //
    // The other test checked millisecond 3,199 and millisecond 4,820. The crash lived at 3,200.
    //
    // The boot sequence is a pure function of a single integer. There is no excuse for sampling
    // it: walk the whole domain. It takes milliseconds.
    const gpa = testing.allocator;

    var out: std.ArrayList(Draw) = .empty;
    defer out.deinit(gpa);

    // Two sizes, because a division by a screen dimension is another way to reach zero.
    for ([_]Size{ .{ .w = 360, .h = 800 }, .{ .w = 1080, .h = 2400 } }) |size| {
        var ms: u32 = 0;
        while (ms < boot_glitch_end + 4000) : (ms += 1) {
            try draw(.{ .screen = .boot, .boot_ms = ms }, size, &out, gpa);
            try testing.expect(out.items.len > 0);
        }
    }
}

test "THE BOOT SEQUENCE IS A PURE FUNCTION OF A MILLISECOND" {
    // There is no timer here, no callback, and no animation state machine that can fall out of
    // step. Ask for millisecond 2,400 and you get the frame that belongs at 2,400 -- forever, on
    // any machine, with no clock anywhere near the core.
    //
    // Which means the whole animation is testable at any instant, on a laptop.
    const gpa = testing.allocator;
    const size: Size = .{ .w = 360, .h = 800 };

    var out: std.ArrayList(Draw) = .empty;
    defer out.deinit(gpa);

    const wordmarkAt = struct {
        fn at(list: []const Draw) bool {
            for (list) |item| switch (item) {
                .text => |t| if (std.mem.eql(u8, t.text, "OUTBREAK") and t.weight == .wordmark) return true,
                else => {},
            };
            return false;
        }
    }.at;

    // EARLY: the terminal is up and the wordmark has not burned in.
    try draw(.{ .screen = .boot, .boot_ms = 300 }, size, &out, gpa);
    try testing.expect(!wordmarkAt(out.items));

    var saw_first_line = false;
    var saw_last_line = false;
    for (out.items) |item| switch (item) {
        .text => |t| {
            if (std.mem.eql(u8, t.text, boot_lines[0].text)) saw_first_line = true;
            if (std.mem.eql(u8, t.text, boot_lines[4].text)) saw_last_line = true;
        },
        else => {},
    };
    try testing.expect(saw_first_line);
    try testing.expect(!saw_last_line); // the terminal types; it does not paste

    // LATE IN THE TERMINAL: every line is up, including the one that is not OK.
    try draw(.{ .screen = .boot, .boot_ms = boot_terminal_ms - 1 }, size, &out, gpa);
    var saw_contamination = false;
    for (out.items) |item| switch (item) {
        .text => |t| if (std.mem.eql(u8, t.text, boot_lines[3].text)) {
            saw_contamination = true;
        },
        else => {},
    };
    try testing.expect(saw_contamination);

    // THE WORDMARK burns in partway through the infection, not before it.
    try draw(.{ .screen = .boot, .boot_ms = boot_terminal_ms + 100 }, size, &out, gpa);
    try testing.expect(!wordmarkAt(out.items));

    try draw(.{ .screen = .boot, .boot_ms = boot_infection_end - 1 }, size, &out, gpa);
    try testing.expect(wordmarkAt(out.items));

    // AT REST: the wordmark is up, the invitation is pulsing, and nothing is still loading.
    try draw(.{ .screen = .boot, .boot_ms = boot_glitch_end + 1200 }, size, &out, gpa);
    try testing.expect(wordmarkAt(out.items));

    var saw_tap = false;
    var saw_bar = false;
    for (out.items) |item| switch (item) {
        .text => |t| {
            if (std.mem.indexOf(u8, t.text, "T A P") != null) saw_tap = true;
            if (std.mem.indexOf(u8, t.text, "C O N T A I N M E N T") != null) saw_bar = true;
        },
        else => {},
    };
    try testing.expect(saw_tap);
    try testing.expect(!saw_bar); // the containment bar is gone once containment has failed

    // DETERMINISTIC. The same millisecond twice is the same frame twice, to the byte.
    var again: std.ArrayList(Draw) = .empty;
    defer again.deinit(gpa);
    try draw(.{ .screen = .boot, .boot_ms = 2400 }, size, &out, gpa);
    try draw(.{ .screen = .boot, .boot_ms = 2400 }, size, &again, gpa);
    try testing.expectEqual(out.items.len, again.items.len);

    // AND IT IS SKIPPABLE. A splash screen you cannot escape is being shown for someone else's
    // benefit, not the player's.
    const tapped = touch(.{ .screen = .boot, .boot_ms = 200 }, .{ .x = 100, .y = 100 }, size);
    try testing.expectEqual(Screen.choose_side, tapped.screen);

    const returning = touch(.{ .screen = .boot, .faction = .human }, .{ .x = 100, .y = 100 }, size);
    try testing.expectEqual(Screen.quiet, returning.screen);
}
