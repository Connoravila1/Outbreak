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
const flags = @import("flags");
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

    // ---- THE COLD SIDE. The human instrument glows blue -- le Carre's chill, a machine holding a
    // line -- and the red infection keeps trying to take it. Zombie stays blood; only Human is cold.
    human = 0x5A93B0FF, // the faction blue
    human_glow = 0x86CDEAFF, // brighter, for the beat and the beam
    human_deep = 0x244C5CFF, // dim structure, the receding rings
    abyss = 0x0A1822FF, // the cold dark at the bottom of the well

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
    /// A soft annulus -- a thin bright ring with nothing inside or out. The sonar's range rings are
    /// this shape, scaled to each radius. A rectangle cannot be a circle, so a ring that reads as a
    /// ring has to come from the atlas, exactly as the disc does.
    ring,
    /// A RADAR SWEEP: a bright leading arm at angle zero with a glowing wake trailing behind it, and
    /// nothing ahead. Drawn with an `angle`, it is the scanning beam -- and because the SHELL rotates
    /// the quad (floats live there), it turns smoothly, not in the integer steps a core-drawn fan of
    /// dots was stuck with. The wake is baked in, so one draw is the whole sweep and its afterglow.
    beam,
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
    text: struct {
        x: i32,
        y: i32,
        text: []const u8,
        color: Color,
        weight: Weight,
        alignment: Align = .left,

        /// HOW FAR THROUGH ITS BURN-IN THIS STRING IS. 255 is "fully arrived", and is the default,
        /// so every other string in the game is unaffected.
        ///
        /// Below that, the RENDERER lights the letters one at a time, left to right, each igniting
        /// hot and cooling to its colour. The core cannot do this itself -- it cannot measure a
        /// string, so it does not know where the second letter begins. The renderer walks glyphs
        /// for a living, so the renderer stages the fire; the core only says how far along it is.
        burn: u8 = 255,
    },
    sprite: struct {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        color: Color,
        sprite: Sprite,

        /// ROTATION, as a 65536th of a turn. Zero (the default) is unrotated, so every existing
        /// sprite is unaffected and the renderer takes its fast axis-aligned path. The CORE only
        /// names the angle; the SHELL turns the quad, because rotation is trig and trig is floats,
        /// and floats do not live in a core file (B6). A `u16` is far finer than the eye can see, so
        /// a sweep driven by it turns smoothly rather than stepping the way a core-drawn fan did.
        angle: u16 = 0,
    },
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

    /// When the player tapped to leave the boot screen. Null until they do.
    ///
    /// The tap does not end the boot screen; it BEGINS THE ENDING OF IT. `advance` finishes the
    /// job once the animation has actually played.
    leaving_ms: ?u32 = null,

    /// MILLISECONDS SINCE THE APP OPENED -- the general clock, updated every frame, on every screen.
    ///
    /// `boot_ms` above is the same number, but it stops advancing the moment the boot screen is
    /// gone. The sonar is a living instrument on the screen a player stares at for the other 98% of
    /// the time, so it needs a clock that keeps ticking. Same trick as the tick and the boot
    /// sequence: the core never asks the time, it is handed this (B3, B7). Every animation driven by
    /// it is therefore a pure function of a single number, testable at any instant with no phone.
    now_ms: u32 = 0,

    /// Chosen once, permanently. Null until they choose.
    faction: ?Faction = null,
    /// Highlighted but not yet confirmed. On `choose_side`, the side being tried on -- ARMED, not
    /// sworn. It may be changed freely by tapping the other card, right up until the hold begins.
    hovering: ?Faction = null,

    /// THE VOW, IN PROGRESS. When the finger came down on HOLD TO COMMIT, or null if it is not being
    /// held. `advance` watches this: once the finger has been down for `hold_commit_ms`, the vow
    /// seals. A finger lifted before then (a `touch`) clears it -- release early and you are still
    /// free. This is the whole mechanism of the one moment the game will not let you take back by
    /// accident (OPENING §3).
    holding_since: ?u32 = null,

    /// WHEN THE VOW SEALED. Null until the hold completes. While set, the choosing floods with the
    /// chosen colour and `advance` hands over to the terminal after `seal_flood_ms`. It is the beat
    /// between the decision and the long watch -- the machine taking its side (OPENING §4).
    sealed_ms: ?u32 = null,

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

    /// RIPPLES THE PLAYER'S OWN FINGER LEFT ON THE DIAL. A small ring, oldest overwritten first.
    ///
    /// A ripple is decoration and nothing else: it is born where a finger touched and expands on the
    /// clock. It says nothing about anyone in the room -- it cannot, it is a function of the tap and
    /// the millisecond, and there is no count or bearing anywhere in it (I2, I3). It is here purely
    /// because a live instrument that answers a touch feels alive, and this one did not.
    ripples: [max_ripples]Ripple = @splat(.{}),
    ripple_head: u8 = 0,

    /// THE CAFE TEST, ON THE GLASS. Null in every build that is not the diagnostic one.
    ///
    /// It reports on THIS PHONE and nothing else: which room it thinks it is in, how wrong its own
    /// receiver believes it might be, and how many times the room has changed underneath it. Not
    /// one of those says anything about another person. There is no count of anyone, no direction
    /// to anyone, and no identity within a mile of it.
    ///
    /// It exists because O3 cannot be answered from a chair. See build.zig.
    diagnostic: ?Diagnostic = null,

    pub const max_tells = 8;
    pub const max_ripples = 4;
};

/// A ring expanding from where a finger touched the dial. `born_ms == 0` is an empty slot: it never
/// coincides with a real tap, because the first frame the app can be touched is well past zero.
pub const Ripple = struct { x: i32 = 0, y: i32 = 0, born_ms: u32 = 0 };

/// What the phone knows about ITS OWN sense of place. Never about anyone else's.
pub const Diagnostic = struct {
    /// The room. An opaque u64 with no inverse -- a group-by key, not a compressed coordinate (A9).
    room: u64,

    /// How wrong the receiver thinks it might be, in metres.
    ///
    /// THIS IS THE NUMBER O3 TURNS ON. If it is larger than the cell, then a player sitting
    /// perfectly still flickers between rooms and breaks their own quorum -- and that is not a bug
    /// we can code around, it is the cell size being wrong.
    accuracy_metres: u32,

    fixes: u32,

    /// How many fixes landed in a DIFFERENT room. Sitting still, this should stay at zero. If it
    /// climbs while you are not moving, you are watching O3 fail in real time.
    room_changes: u32,
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

/// WHAT THE PHONE HAS TAKEN, around the outside of `Size`. In dp.
///
/// `Size` is the SAFE area -- the rectangle the layout is allowed to put a button in, because
/// anything outside it renders under the clock or under the gesture bar.
///
/// But DECORATION IS NOT LAYOUT. Scanlines and a spore field that stop at the safe boundary leave
/// a flat, texture-less band at the top and bottom of the phone, and that band reads as a black
/// bar whether or not the colour behind it is right. The CRT has to reach the glass.
///
/// So the core is told how much was taken, and it may deliberately draw INTO it: coordinates from
/// `-insets.top` to `size.h + insets.bottom` are legal, and only for things a player never has to
/// touch or read.
pub const Insets = struct {
    top: i32 = 0,
    bottom: i32 = 0,
    left: i32 = 0,
    right: i32 = 0,

    /// The full surface, in the core's own coordinates -- origin at the top-left of the PHONE
    /// rather than of the safe area.
    fn bleedTop(in: Insets) i32 {
        return -in.top;
    }
    fn bleedLeft(in: Insets) i32 {
        return -in.left;
    }
    fn bleedWidth(in: Insets, size: Size) i32 {
        return in.left + size.w + in.right;
    }
    fn bleedHeight(in: Insets, size: Size) i32 {
        return in.top + size.h + in.bottom;
    }
};

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

/// THE COLOUR BEHIND EVERYTHING, INCLUDING THE PARTS WE ARE NOT ALLOWED TO DRAW IN.
///
/// The status bar and the gesture bar sit OUTSIDE the safe area, and the safe area is the only
/// place the layout may put anything. Left alone, those strips show whatever was beneath us --
/// which is black, and which reads as two bars bracketing the app.
///
/// So the shell clears the ENTIRE surface to this colour first, and then draws the inset content
/// on top. The background is edge to edge; only the content is inset. That is what "full bleed"
/// means and it is the difference between an app and an app in a letterbox.
pub fn background(state: State) Color {
    return switch (state.screen) {
        .boot => .char_deep,
        else => .void_black,
    };
}

/// How long the app takes to get out of its own way once the player taps.
const boot_exit_ms: u32 = 420;

/// CORE. Move time forward. Pure: the shell hands in the clock, exactly as it does for the tick.
///
/// This exists because an ANIMATION HAS TO FINISH. `touch` cannot both start the exit and end it
/// -- the player taps once, and the four hundred milliseconds that follow are not touches. So the
/// shell calls this every frame and the state machine advances itself.
/// THE CEREMONY, IN MILLISECONDS.
///
/// `hold_commit_ms` is the length of the vow -- how long the thumb stays down while the machine
/// binds you. 1.2s is the paper value (OPENING §7); it is tuned on the device, not in a test. Too
/// short is not a ceremony; too long is tedious.
///
/// `seal_flood_ms` is the beat AFTER the seal -- the colour flooding the terminal before the
/// choosing dissolves into the long watch. The handover, not the decision.
const hold_commit_ms: u32 = 1200;
const seal_flood_ms: u32 = 900;

pub fn advance(state: State, ms: u32) State {
    var next = state;

    // THE GENERAL CLOCK, always. Everything animated -- the sonar's sweep, its drifting motes, the
    // breathing pip -- reads this and nothing else. It is set on every screen so the instrument
    // keeps living when the boot sequence is long gone.
    next.now_ms = ms;

    if (state.screen == .boot) {
        next.boot_ms = ms;

        if (state.leaving_ms) |began| {
            if (ms -| began >= boot_exit_ms) {
                next.screen = if (state.faction == null) .choose_side else .quiet;
                next.leaving_ms = null;
            }
        }
    }

    if (state.screen == .choose_side) {
        if (state.sealed_ms) |sealed| {
            // THE HANDOVER. The vow is sworn; the flood plays, then the choosing dissolves into the
            // terminal, now permanently in the sworn colour. The one path off this screen, forward.
            if (ms -| sealed >= seal_flood_ms) {
                next.screen = .quiet;
                next.sealed_ms = null;
            }
        } else if (state.holding_since) |began| {
            // THE SEAL. A thumb held on HOLD TO COMMIT for the whole ceremony. Time is a parameter,
            // so this completes purely as a function of the millisecond -- testable with no finger
            // and no clock. `hovering` is the armed side; the seal makes it the sworn one.
            if (ms -| began >= hold_commit_ms) {
                if (state.hovering) |sworn| {
                    // Set once, here, forever. The null -> set edge is also what the phone persists
                    // (android.zig): the vow is written to disk the instant it is taken.
                    next.faction = sworn;
                    next.sealed_ms = ms;
                    next.holding_since = null;
                }
            }
        }
    }

    return next;
}

// ============================================================================ input

/// CORE. The player touched the screen. Returns the new state.
///
/// Pure: same state, same touch, same result. No clock, no randomness, no I/O.
pub fn touch(state: State, at: Touch, size: Size) State {
    var next = state;

    switch (state.screen) {
        // THE TAP DOES NOT WORK UNTIL THE SEQUENCE HAS FINISHED.
        //
        // "Tap to enter" is an invitation, and it is not extended until the screen has actually
        // said everything it has to say. A tap landing mid-terminal would cut the game off in the
        // middle of introducing itself -- and the player has not been asked for anything yet, so
        // there is nothing for them to be impatient about.
        //
        // Once it IS offered, the tap begins the ending rather than jumping: the screen takes four
        // hundred milliseconds to get out of the way, and `advance` finishes the job.
        .boot => if (afterWake(state.boot_ms) >= boot_settle_end and state.leaving_ms == null) {
            next.leaving_ms = state.boot_ms;
        },

        .choose_side => {
            // THE VOW IS SEALING, OR SEALED. The choosing is locked: no tap changes it, and there is
            // no back button on this screen -- the HOLD was the "are you sure" (OPENING §3). This is
            // the one-way door, stated in code.
            if (state.sealed_ms != null) return next;

            // A RELEASE CANCELS AN INCOMPLETE HOLD. The thumb lifted before the ceremony finished, so
            // the vow was not taken and you are still free. (A completed hold seals in `advance`,
            // before this release arrives, and is caught by the lock above.)
            if (state.holding_since != null) {
                next.holding_since = null;
                return next;
            }

            // ARM a side by tapping its card. Reversible -- tap the other to change your mind, right
            // up to the hold. No default, no pre-selection: the terminal waits (OPENING §2).
            if (within(at, factionButton(size, .human))) next.hovering = .human;
            if (within(at, factionButton(size, .zombie))) next.hovering = .zombie;

            if (within(at, creditsLink(size))) next.screen = .credits;
        },

        .quiet => {
            if (within(at, creditsLink(size))) {
                next.screen = .credits;
            } else {
                // A tap on the dial leaves a ripple. This is SCREEN-pixel geometry -- "did the
                // finger land inside the circle drawn on the glass" -- integer, no float, and
                // nothing to do with a cell. A9 forbids geometry on `CellId`, which has no
                // coordinate to measure; a drawn circle on a touchscreen is not that.
                const g = sonarGeometry(size);
                const dx = at.x - g.cx;
                const dy = at.y - g.cy;
                if (dx * dx + dy * dy <= g.r * g.r) {
                    next.ripples[next.ripple_head % State.max_ripples] = .{ .x = at.x, .y = at.y, .born_ms = state.now_ms };
                    next.ripple_head +%= 1;
                }
            }
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

/// CORE. The player put a finger DOWN. Returns the new state.
///
/// The companion to `touch`, which is the finger coming UP (a tap). Almost every screen cares only
/// about the tap; the ONE thing that needs the press is the vow, where the machine measures how long
/// the thumb stays down before it binds you (OPENING §3). Pure: same state, same press, same result.
pub fn press(state: State, at: Touch, size: Size) State {
    var next = state;

    if (state.screen == .choose_side) {
        // Begin the ceremony ONLY when a side is armed and the thumb comes down on HOLD TO COMMIT.
        // No armed side, no hold: a permanent choice is never begun by a stray press on nothing
        // (OPENING §2). Already sealing, or already holding? Then this press is not the start of one.
        if (state.sealed_ms == null and state.holding_since == null) {
            if (state.hovering != null and within(at, confirmButton(size))) {
                next.holding_since = state.now_ms;
            }
        }
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
pub fn draw(state: State, size: Size, insets: Insets, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    out.clearRetainingCapacity();

    // FULL BLEED. Not the safe area -- the whole phone. A background that stops at the inset is
    // the letterbox we were trying to get rid of.
    try out.append(gpa, .{ .rect = .{
        .x = insets.bleedLeft(),
        .y = insets.bleedTop(),
        .w = insets.bleedWidth(size),
        .h = insets.bleedHeight(size),
        .color = .void_black,
    } });

    switch (state.screen) {
        .boot => try drawBoot(state, size, insets, out, gpa),
        .choose_side => try drawChooseSide(state, size, out, gpa),
        .quiet => try drawQuiet(state, size, out, gpa),
        .live => try drawLive(state, size, out, gpa),
        .credits => try drawCredits(size, out, gpa),
    }
}

/// The record the machine stamps when the vow seals. ASCII only -- the atlas bakes the game's copy,
/// and a stray glyph it never saw renders as a hole.
fn sealLine(faction: ?Faction) []const u8 {
    return switch (faction orelse return "ALLEGIANCE SEALED / IRREVERSIBLE") {
        .human => "ALLEGIANCE SEALED / HUMAN / IRREVERSIBLE",
        .zombie => "ALLEGIANCE SEALED / ZOMBIE / IRREVERSIBLE",
    };
}

fn drawChooseSide(state: State, size: Size, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    // THIS IS A FIRST, FUNCTIONAL PASS of the choosing in the terminal's voice (OPENING §2-4). The
    // machine copy, the two leaning previews, and a HOLD TO COMMIT bar that fills as the thumb holds
    // are here so the vow can be FELT on the device; the cinematic flood, the whole-screen lean, and
    // the coloured live previews iterate on the phone with the user.
    try out.append(gpa, .{ .text = .{ .x = pad, .y = 40, .text = "OUTBREAK", .color = .grave, .weight = .label } });

    // THE MACHINE'S VOICE. Contamination detected; it cannot proceed until it classifies the
    // operator. Cold, procedural, and the weight is entirely in what it withholds.
    try out.append(gpa, .{ .text = .{ .x = pad, .y = 104, .text = "OPERATOR UNCLASSIFIED", .color = .wound, .weight = .heading } });
    try out.append(gpa, .{ .text = .{ .x = pad, .y = 104 + line, .text = "DECLARE ALLEGIANCE.", .color = .bone, .weight = .body } });
    try out.append(gpa, .{ .text = .{ .x = pad, .y = 104 + line * 2, .text = "THIS RECORD IS PERMANENT AND CANNOT BE AMENDED.", .color = .dust, .weight = .body } });

    try drawFaction(state, factionButton(size, .human), .human, "HUMAN", "You hold. You are outnumbered, and you know it.", out, gpa);
    try drawFaction(state, factionButton(size, .zombie), .zombie, "ZOMBIE", "You persist. You were already here.", out, gpa);

    // THE COMMIT, IN THREE STATES -- inert (nothing armed), holding (the fill grows on the clock),
    // sealed (the colour has taken the bar). All pure functions of holding_since / sealed_ms.
    const confirm = confirmButton(size);
    if (state.sealed_ms != null) {
        const glow = factionGlow(state.faction);
        try out.append(gpa, .{ .rect = .{ .x = confirm.x, .y = confirm.y, .w = confirm.w, .h = confirm.h, .color = glow } });
        try out.append(gpa, .{ .text = .{ .x = confirm.x + 14, .y = confirm.y + 18, .text = sealLine(state.faction), .color = .void_black, .weight = .label } });
    } else if (state.hovering) |armed| {
        try out.append(gpa, .{ .rect = .{ .x = confirm.x, .y = confirm.y, .w = confirm.w, .h = confirm.h, .color = .scab } });
        if (state.holding_since) |began| {
            // Elapsed, clamped before the multiply so a long-lived clock cannot overflow the u32.
            const elapsed = @min(state.now_ms -| began, hold_commit_ms);
            const fill_w = @divTrunc(confirm.w * @as(i32, @intCast(elapsed * 100 / hold_commit_ms)), 100);
            if (fill_w > 0) try out.append(gpa, .{ .rect = .{ .x = confirm.x, .y = confirm.y, .w = fill_w, .h = confirm.h, .color = factionGlow(armed) } });
        }
        try out.append(gpa, .{ .text = .{ .x = confirm.x + 16, .y = confirm.y + 18, .text = "HOLD TO COMMIT", .color = .bone, .weight = .body } });
    } else {
        try out.append(gpa, .{ .rect = .{ .x = confirm.x, .y = confirm.y, .w = confirm.w, .h = confirm.h, .color = .carrion } });
        try out.append(gpa, .{ .text = .{ .x = confirm.x + 16, .y = confirm.y + 18, .text = "SELECT A SIDE", .color = .grave, .weight = .body } });
    }

    // The dread line, quiet and true -- the choice is who you are, not which wins. Yielded to the
    // seal record once the vow is taken.
    if (state.sealed_ms == null) {
        try out.append(gpa, .{ .text = .{ .x = pad, .y = size.h - 50, .text = "No faction is stronger. Only different.", .color = .grave, .weight = .body } });
    }

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
    // Armed leans the card into its faction's colour -- a first taste of the two lives before the
    // vow (OPENING §2). A rough lean (fill + name glow); the living previews iterate on the device.
    const armed = state.hovering == faction;
    const fill: Color = if (armed) factionDeep(faction) else .carrion;
    const name_color: Color = if (armed) factionBright(faction) else .bone;
    try out.append(gpa, .{ .rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .color = fill } });
    try out.append(gpa, .{ .text = .{ .x = rect.x + 16, .y = rect.y + 20, .text = name, .color = name_color, .weight = .heading } });
    try out.append(gpa, .{ .text = .{ .x = rect.x + 16, .y = rect.y + 52, .text = blurb, .color = if (faction == .zombie) .serum else .dust, .weight = .body } });
}

// ============================================================================ the sonar
//
// THE HERO OF THE CENTRAL SCREEN, and the answer to the hardest problem in this genre: how do you
// make WAITING fun? The idle screen is what a player stares at ~98% of the time, and "Nothing
// here." was an absence to apologise for. The sonar is a living instrument to rest the eye on --
// a slow sweep, range rings, motes drifting in the fog, a pulse at the centre like a held breath.
//
// It is dressed as submarine sonar, and it is deliberately NOT one. A real sonar paints a contact
// at a bearing, and a bearing is the first step to a name (I1, I2). So we keep the instrument and
// cut the wire to reality: the motes are pure DECORATION, a function of the clock and nothing
// else. They are not people. Nothing on this dial is read from the room, no count, no direction.
// When the cell goes live the dial BLOOMS -- a diffuse red haze, never a blip at a bearing -- which
// says "something is HERE" and never "there, that way." Diffuse presence, never position, exactly
// the game's own feeling. (EXPERIENCE_DESIGN §2.)
//
// EVERY COORDINATE HERE IS AN INTEGER, and there is no trig function in sight, because this is a
// core file and a core file holds no float (B6). Rotation comes from a hand-written fixed-point
// sine table -- plain integer data, the way the whole core is plain data. The renderer draws only
// axis-aligned quads and cannot spin one, so the sweep is a fan of dots placed by that table, and
// a ring is a shape baked into the atlas. The constraint and the aesthetic agreed, again.

/// Fixed-point sine, Q12: one full turn in 256 steps, each value sin(θ)·4096 rounded. Cosine is the
/// same table read a quarter-turn (64 steps) ahead. Generated once and pasted as data -- there is
/// no `@sin` in a core file, and a float would not survive the guard if there were (B6).
const sonar_one: i32 = 4096;
const sonar_sin = [256]i32{
    0,     101,   201,   301,   401,   501,   601,   700,
    799,   897,   995,   1092,  1189,  1285,  1380,  1474,
    1567,  1660,  1751,  1842,  1931,  2019,  2106,  2191,
    2276,  2359,  2440,  2520,  2598,  2675,  2751,  2824,
    2896,  2967,  3035,  3102,  3166,  3229,  3290,  3349,
    3406,  3461,  3513,  3564,  3612,  3659,  3703,  3745,
    3784,  3822,  3857,  3889,  3920,  3948,  3973,  3996,
    4017,  4036,  4052,  4065,  4076,  4085,  4091,  4095,
    4096,  4095,  4091,  4085,  4076,  4065,  4052,  4036,
    4017,  3996,  3973,  3948,  3920,  3889,  3857,  3822,
    3784,  3745,  3703,  3659,  3612,  3564,  3513,  3461,
    3406,  3349,  3290,  3229,  3166,  3102,  3035,  2967,
    2896,  2824,  2751,  2675,  2598,  2520,  2440,  2359,
    2276,  2191,  2106,  2019,  1931,  1842,  1751,  1660,
    1567,  1474,  1380,  1285,  1189,  1092,  995,   897,
    799,   700,   601,   501,   401,   301,   201,   101,
    0,     -101,  -201,  -301,  -401,  -501,  -601,  -700,
    -799,  -897,  -995,  -1092, -1189, -1285, -1380, -1474,
    -1567, -1660, -1751, -1842, -1931, -2019, -2106, -2191,
    -2276, -2359, -2440, -2520, -2598, -2675, -2751, -2824,
    -2896, -2967, -3035, -3102, -3166, -3229, -3290, -3349,
    -3406, -3461, -3513, -3564, -3612, -3659, -3703, -3745,
    -3784, -3822, -3857, -3889, -3920, -3948, -3973, -3996,
    -4017, -4036, -4052, -4065, -4076, -4085, -4091, -4095,
    -4096, -4095, -4091, -4085, -4076, -4065, -4052, -4036,
    -4017, -3996, -3973, -3948, -3920, -3889, -3857, -3822,
    -3784, -3745, -3703, -3659, -3612, -3564, -3513, -3461,
    -3406, -3349, -3290, -3229, -3166, -3102, -3035, -2967,
    -2896, -2824, -2751, -2675, -2598, -2520, -2440, -2359,
    -2276, -2191, -2106, -2019, -1931, -1842, -1751, -1660,
    -1567, -1474, -1380, -1285, -1189, -1092, -995,  -897,
    -799,  -700,  -601,  -501,  -401,  -301,  -201,  -101,
};

fn sinQ12(a: u8) i32 {
    return sonar_sin[a];
}
fn cosQ12(a: u8) i32 {
    return sonar_sin[a +% 64];
}

/// A point on the dial: `a` is a 256th of a turn, `r` a radius in the core's integer pixels.
fn polarX(cx: i32, r: i32, a: u8) i32 {
    return cx + @divTrunc(r * cosQ12(a), sonar_one);
}
fn polarY(cy: i32, r: i32, a: u8) i32 {
    return cy + @divTrunc(r * sinQ12(a), sonar_one);
}

/// A drifting speck of light on the dial. It is NOT a person and NOT a place -- it is decoration,
/// seeded once and moved by the clock, so the field is alive without ever reading the room (I2, I3).
const Mote = struct { angle: u8, r_permille: i32, size: i32, bob_period: u32, bob_phase: u32 };
const sonar_motes = [_]Mote{
    .{ .angle = 165, .r_permille = 454, .size = 2, .bob_period = 2797, .bob_phase = 5332 },
    .{ .angle = 37, .r_permille = 848, .size = 1, .bob_period = 4987, .bob_phase = 2995 },
    .{ .angle = 29, .r_permille = 819, .size = 1, .bob_period = 2952, .bob_phase = 307 },
    .{ .angle = 222, .r_permille = 728, .size = 1, .bob_period = 2971, .bob_phase = 1971 },
    .{ .angle = 217, .r_permille = 360, .size = 3, .bob_period = 3514, .bob_phase = 1014 },
    .{ .angle = 31, .r_permille = 890, .size = 3, .bob_period = 2803, .bob_phase = 3249 },
    .{ .angle = 113, .r_permille = 347, .size = 3, .bob_period = 3786, .bob_phase = 1090 },
    .{ .angle = 214, .r_permille = 447, .size = 3, .bob_period = 4938, .bob_phase = 964 },
    .{ .angle = 157, .r_permille = 873, .size = 1, .bob_period = 4982, .bob_phase = 844 },
    .{ .angle = 96, .r_permille = 681, .size = 1, .bob_period = 2857, .bob_phase = 4487 },
    .{ .angle = 30, .r_permille = 510, .size = 2, .bob_period = 4777, .bob_phase = 5573 },
    .{ .angle = 218, .r_permille = 621, .size = 2, .bob_period = 4456, .bob_phase = 4796 },
    .{ .angle = 185, .r_permille = 606, .size = 1, .bob_period = 3599, .bob_phase = 1472 },
    .{ .angle = 41, .r_permille = 888, .size = 2, .bob_period = 4627, .bob_phase = 4302 },
    .{ .angle = 175, .r_permille = 759, .size = 2, .bob_period = 2899, .bob_phase = 4988 },
    .{ .angle = 60, .r_permille = 824, .size = 2, .bob_period = 4001, .bob_phase = 1351 },
};

/// How long the sweep takes to come round, as milliseconds per 256th of a turn. Quiet is slow and
/// unhurried; live quickens it, the way a pulse quickens.
const sweep_step_quiet_ms: u32 = 27; // ~7s a revolution
const sweep_step_live_ms: u32 = 14; // ~3.5s

/// INFECTION VEINS. Tendrils that snake out from the centre and breathe -- the boot screen's blood,
/// reaching into the dial. Each entry is a base angle; the tendril wobbles as it reaches the rim,
/// so it reads as something organic growing rather than a spoke. Decoration on the clock, like the
/// rest -- it is drawn from a table and a millisecond, and never from the room.
const sonar_veins = [_]u8{ 12, 46, 84, 120, 150, 184, 214, 240 };

/// How long a tap's ripple lives, in milliseconds. It expands to most of the dial and fades out.
const ripple_life_ms: u32 = 950;

/// The console rectangle and the scope's centre and radius for a given screen. ONE definition,
/// shared by the layout that draws the terminal and the touch handler that answers a tap -- so a
/// ripple is always born where the flesh actually is, and the two can never drift.
const SonarGeom = struct { cx: i32, cy: i32, r: i32, con_y: i32, con_h: i32 };
fn sonarGeometry(size: Size) SonarGeom {
    const cmd_h: i32 = 44;
    const disp_y: i32 = 22 + cmd_h + 8;
    const con_y: i32 = disp_y + 30 + 10;
    const con_h: i32 = size.h - con_y - 148;
    const cx = @divTrunc(size.w, 2);
    const cy = con_y + @divTrunc(con_h, 2) + 8;
    const r = @min(@divTrunc(size.w * 36, 100), @divTrunc(con_h * 38, 100));
    return .{ .cx = cx, .cy = cy, .r = r, .con_y = con_y, .con_h = con_h };
}

/// A soft dot of the disc sprite, centred on a point.
fn softDot(out: *std.ArrayList(Draw), gpa: Allocator, x: i32, y: i32, radius: i32, color: Color) Allocator.Error!void {
    try out.append(gpa, .{ .sprite = .{ .x = x - radius, .y = y - radius, .w = radius * 2, .h = radius * 2, .color = color, .sprite = .disc } });
}

/// A ring sprite, centred, at a given radius.
fn softRing(out: *std.ArrayList(Draw), gpa: Allocator, x: i32, y: i32, radius: i32, color: Color) Allocator.Error!void {
    if (radius <= 0) return;
    try out.append(gpa, .{ .sprite = .{ .x = x - radius, .y = y - radius, .w = radius * 2, .h = radius * 2, .color = color, .sprite = .ring } });
}

// ============================================================================ the descent
//
// The central screen is a WELL, and it BREATHES. It is not a radar with a sweeping arm any more --
// a sweep steps around in discrete angles and reads as choppy, and it was never the feeling we
// wanted. This is the abyss of the outbreak with a pulse in it: rings falling inward like a throat,
// a heart at the bottom, embers drifting in the dark, and every last thing on the glass rising and
// falling on ONE heartbeat. Slow and resting when the room is quiet; racing when it goes live.
//
// COLOUR IS WHO YOU ARE. The human instrument glows cold blue -- and the red infection is always in
// it, in the fog and creeping at the rim, trying to take the machine. Zombie is red through and
// through. When the cell goes live the red floods everything, a colour war on your own screen.
//
// It is smooth because the motion is RADIAL -- rings growing and shrinking, glows swelling, embers
// drifting -- all of which move a few pixels a frame at sixty frames a second. Nothing steps around
// a circle. The core stays integer (B6); the smoothness is in the size of the step, not a float.

/// THE FACTION GLOW. Blue for the human holding a line, blood for the zombie. Null before a side is
/// chosen reads as the zombie red -- the app's own colour.
fn factionGlow(faction: ?Faction) Color {
    return if (faction == .human) .human else .wound;
}
fn factionBright(faction: ?Faction) Color {
    return if (faction == .human) .human_glow else .blood_glow;
}
fn factionDeep(faction: ?Faction) Color {
    return if (faction == .human) .human_deep else .blood_deep;
}

/// THE HEARTBEAT, 0..255, over `period` ms. Not a sine and not a triangle: a systole spike that
/// falls, a smaller diastole echo, then rest at a low baseline. The whole screen breathes on this
/// one number -- the core glow, the pulse rings, the embers, the EKG. Integer, like everything here.
fn heartbeat(ms: u32, period: u32) u8 {
    const frac = (ms % period) * 1000 / period; // 0..999 through one beat
    if (frac < 55) return @intCast(40 + frac * 215 / 55); //   lub: rise to 255
    if (frac < 150) return @intCast(255 - (frac - 55) * 175 / 95); //   fall to ~80
    if (frac < 230) return @intCast(80 + (frac - 150) * 85 / 80); //  dub: rise to ~165
    if (frac < 380) return @intCast(165 - (frac - 230) * 125 / 150); //  fall to ~40
    return 40; // rest
}

/// A drifting ember in the void. `near` ones are bigger and wander further, for a parallax depth --
/// decoration on the clock, filling the dark so it reads as a place, not an empty screen.
const Ember = struct { x: i32, y: i32, size: i32, near: bool, period: u32, phase: u32 };
const embers = [_]Ember{
    .{ .x = 713, .y = 64, .size = 2, .near = true, .period = 9268, .phase = 3223 },
    .{ .x = 375, .y = 561, .size = 1, .near = false, .period = 10277, .phase = 882 },
    .{ .x = 286, .y = 441, .size = 1, .near = false, .period = 7763, .phase = 2666 },
    .{ .x = 938, .y = 338, .size = 1, .near = false, .period = 9303, .phase = 579 },
    .{ .x = 962, .y = 227, .size = 1, .near = false, .period = 12366, .phase = 603 },
    .{ .x = 842, .y = 120, .size = 2, .near = true, .period = 12933, .phase = 3244 },
    .{ .x = 470, .y = 694, .size = 1, .near = false, .period = 14229, .phase = 1298 },
    .{ .x = 830, .y = 672, .size = 2, .near = true, .period = 14933, .phase = 4723 },
    .{ .x = 768, .y = 130, .size = 1, .near = true, .period = 8269, .phase = 1103 },
    .{ .x = 661, .y = 525, .size = 1, .near = false, .period = 13505, .phase = 56 },
    .{ .x = 485, .y = 947, .size = 2, .near = false, .period = 14522, .phase = 3933 },
    .{ .x = 864, .y = 532, .size = 2, .near = true, .period = 14879, .phase = 1503 },
    .{ .x = 931, .y = 22, .size = 1, .near = true, .period = 13634, .phase = 3085 },
    .{ .x = 482, .y = 136, .size = 3, .near = false, .period = 10307, .phase = 1051 },
    .{ .x = 507, .y = 310, .size = 2, .near = false, .period = 8802, .phase = 3776 },
    .{ .x = 469, .y = 328, .size = 1, .near = false, .period = 6742, .phase = 633 },
    .{ .x = 234, .y = 338, .size = 3, .near = false, .period = 12891, .phase = 829 },
    .{ .x = 494, .y = 88, .size = 2, .near = false, .period = 6264, .phase = 1435 },
    .{ .x = 467, .y = 684, .size = 1, .near = true, .period = 8070, .phase = 1401 },
    .{ .x = 460, .y = 312, .size = 2, .near = false, .period = 9322, .phase = 5081 },
    .{ .x = 500, .y = 919, .size = 3, .near = false, .period = 13026, .phase = 5312 },
    .{ .x = 669, .y = 176, .size = 1, .near = false, .period = 10747, .phase = 5218 },
    .{ .x = 971, .y = 60, .size = 2, .near = false, .period = 11842, .phase = 2072 },
    .{ .x = 235, .y = 290, .size = 2, .near = true, .period = 6402, .phase = 2301 },
};

/// CORE. The sonar, a pure function of the clock and ONE bit: is this cell live?
///
/// `live` is the only thing this instrument learns about the world outside the phone, and it is a
/// single bit -- the very same bit the game already shows as "THIS CELL IS LIVE." It never reads
/// the crowd, a count, a direction, or anything that could resolve toward who or where. Everything
/// else you see moving is the clock.
/// THE SCOPE inside the console: infected flesh under a rotating scan. The whole thing is integer
/// (B6); the one thing that must be smooth -- the sweep -- is a single baked `beam` sprite the SHELL
/// turns by an angle the core hands it, so it rotates without stepping. `live` is the only bit it
/// learns of the world outside (I3); everything else moving is the clock.
fn drawScope(state: State, cx: i32, cy: i32, r: i32, live: bool, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    const t = state.now_ms;
    const faction = state.faction;
    const beat: i32 = heartbeat(t, if (live) 560 else 1150);
    const glow: Color = if (live) .blood_glow else factionGlow(faction);
    const bright: Color = if (live) .blood_glow else factionBright(faction);

    // FLESH -- a dark bloody membrane the scan looks through, breathing on the beat.
    try softDot(out, gpa, cx, cy, r, dim(if (live) .clot else .scab, 220));
    try softDot(out, gpa, cx, cy, @divTrunc(r * 7, 10), dim(.blood_deep, @intCast(28 + @divTrunc(beat, 8))));

    // VEINS -- engorged tendrils reaching in from the rim, throbbing on the beat.
    for (sonar_veins, 0..) |base, vi| {
        var k: i32 = 2;
        while (k <= 14) : (k += 1) {
            const rr = @divTrunc(r * k, 14);
            const seed: u8 = @intCast((@as(u32, @intCast(k)) * 9 + @as(u32, @intCast(vi)) * 20) & 255);
            const wob: i32 = @divTrunc(sinQ12(seed) * 12, sonar_one);
            const ang = base +% @as(u8, @truncate(@as(u32, @bitCast(wob))));
            const fade: u8 = @intCast(@max(0, (28 + @divTrunc(beat, 5)) - k * 2));
            try softDot(out, gpa, polarX(cx, rr, ang), polarY(cy, rr, ang), 1, dim(.blood_deep, fade));
        }
    }

    // RANGE RINGS.
    var i: i32 = 1;
    while (i <= 3) : (i += 1) {
        try softRing(out, gpa, cx, cy, @divTrunc(r * i, 3), dim(glow, @intCast(@max(24, 92 - i * 20))));
    }

    // THE SWEEP -- one baked beam, turned by the shell at an angle the core hands it. A `u16` is far
    // finer than the eye, so it sweeps smoothly rather than stepping the way a fan of dots did.
    const angle: u16 = @truncate(t *% (if (live) @as(u32, 24) else 13));
    try out.append(gpa, .{ .sprite = .{ .x = cx - r, .y = cy - r, .w = r * 2, .h = r * 2, .color = dim(glow, if (live) 155 else 115), .sprite = .beam, .angle = angle } });

    // THE HEART -- a wet beating wound at the centre, always red; it pumps the veins.
    try softDot(out, gpa, cx, cy, @divTrunc(r * (24 + @divTrunc(beat, 7)), 100), dim(.wound, @intCast(40 + @divTrunc(beat, 3))));
    try softDot(out, gpa, cx, cy, 3 + @divTrunc(beat, 90), dim(.blood_glow, @intCast(150 + @divTrunc(beat * 105, 255))));

    // LIVE bloom -- the whole scope floods red and pounds with the racing beat.
    if (live) try softDot(out, gpa, cx, cy, r, dim(.blood, @intCast(45 + @divTrunc(beat, 3))));

    // THE RIPPLES the finger left -- a pulse you sent into the flesh, expanding and fading.
    for (state.ripples) |rp| {
        if (rp.born_ms == 0) continue;
        const age = t -| rp.born_ms;
        if (age >= ripple_life_ms) continue;
        const age_i: i32 = @intCast(age);
        const grow = @divTrunc(age_i * @divTrunc(r * 8, 10), @as(i32, @intCast(ripple_life_ms)));
        if (grow < 4) continue;
        const a: u8 = @intCast(@max(0, 210 - @divTrunc(age_i * 210, @as(i32, @intCast(ripple_life_ms)))));
        try softRing(out, gpa, rp.x, rp.y, grow, dim(bright, a));
    }
}

/// A framed console panel: dark fill, a hairline border in the faction's dim, and corner brackets.
/// This is the chrome that makes the screen read as a salvaged instrument, not text on black.
fn panel(out: *std.ArrayList(Draw), gpa: Allocator, x: i32, y: i32, w: i32, h: i32, edge: Color, accent: Color) Allocator.Error!void {
    try out.append(gpa, .{ .rect = .{ .x = x, .y = y, .w = w, .h = h, .color = .carrion } });
    try out.append(gpa, .{ .rect = .{ .x = x, .y = y, .w = w, .h = 1, .color = edge } });
    try out.append(gpa, .{ .rect = .{ .x = x, .y = y + h - 1, .w = w, .h = 1, .color = edge } });
    try out.append(gpa, .{ .rect = .{ .x = x, .y = y, .w = 1, .h = h, .color = edge } });
    try out.append(gpa, .{ .rect = .{ .x = x + w - 1, .y = y, .w = 1, .h = h, .color = edge } });
    const b: i32 = 8;
    try out.append(gpa, .{ .rect = .{ .x = x, .y = y, .w = b, .h = 2, .color = accent } });
    try out.append(gpa, .{ .rect = .{ .x = x, .y = y, .w = 2, .h = b, .color = accent } });
    try out.append(gpa, .{ .rect = .{ .x = x + w - b, .y = y + h - 2, .w = b, .h = 2, .color = accent } });
    try out.append(gpa, .{ .rect = .{ .x = x + w - 2, .y = y + h - b, .w = 2, .h = b, .color = accent } });
}

/// The war dispatch -- GLOBAL, never local (I3). No numbers yet: the counts that would make it
/// specific ("14,000 souls at war") need a field on the wire that does not exist, and the phone does
/// not invent data (H1). Mood only, until that slice lands.
fn dispatchLine(ms: u32) []const u8 {
    return switch ((ms / 5000) % 3) {
        0 => "THE INFECTION IS SPREADING",
        1 => "THE LINE IS MOVING TONIGHT",
        else => "IT GETS LOUD AFTER DARK",
    };
}

fn drawQuiet(state: State, size: Size, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    const t = state.now_ms;
    const faction = state.faction;
    const acc = factionGlow(faction);
    const edge = factionDeep(faction);

    // 1. THE COMMAND BAR -- who you are, on the left; the licence credit rides its right side.
    const cmd_h: i32 = 44;
    try panel(out, gpa, pad, 22, size.w - pad * 2, cmd_h, edge, dim(acc, 180));
    try out.append(gpa, .{ .text = .{ .x = pad + 12, .y = 37, .text = factionLabel(faction), .color = acc, .weight = .label } });

    // 2. THE DISPATCH -- the global war, mood only for now (no invented numbers, H1).
    const disp_y: i32 = 22 + cmd_h + 8;
    try panel(out, gpa, pad, disp_y, size.w - pad * 2, 30, .clot, dim(.wound, 160));
    try out.append(gpa, .{ .text = .{ .x = pad + 12, .y = disp_y + 10, .text = "FRONT", .color = .wound, .weight = .label } });
    try out.append(gpa, .{ .text = .{ .x = pad + 62, .y = disp_y + 10, .text = dispatchLine(t), .color = .serum, .weight = .label } });

    // 3. THE SCOPE CONSOLE -- the hero. Geometry is shared with the touch handler, so a tap ripples
    // where the flesh is drawn.
    const g = sonarGeometry(size);
    const con_y = g.con_y;
    const con_h = g.con_h;
    const cx = g.cx;
    const cy = g.cy;
    const r = g.r;
    try panel(out, gpa, pad, con_y, size.w - pad * 2, con_h, edge, dim(acc, 180));
    try out.append(gpa, .{ .text = .{ .x = pad + 12, .y = con_y + 11, .text = "FIELD SCAN", .color = .dust, .weight = .label } });
    try out.append(gpa, .{ .text = .{ .x = size.w - pad - 12, .y = con_y + 11, .text = "SCANNING", .color = acc, .weight = .label, .alignment = .right } });

    try drawScope(state, cx, cy, r, false, out, gpa);

    // The reading, centred. "QUIET" is shown identically for an empty field, a sub-quorum cell, and a
    // quiet one above quorum -- the whole of I3 on the glass: the phone is told nothing that could
    // tell the three apart.
    try out.append(gpa, .{ .text = .{ .x = cx, .y = cy - 9, .text = "QUIET", .color = .bone, .weight = .label, .alignment = .center } });

    // 4. THE VITALS -- both real, both number-free: your CONDITION (a word) and the binary THREAT.
    const vit_y: i32 = con_y + con_h + 8;
    const gap: i32 = 8;
    const half = @divTrunc(size.w - pad * 2 - gap, 2);
    try panel(out, gpa, pad, vit_y, half, 46, edge, dim(acc, 150));
    try out.append(gpa, .{ .text = .{ .x = pad + 11, .y = vit_y + 9, .text = "CONDITION", .color = .dust, .weight = .label } });
    try out.append(gpa, .{ .text = .{ .x = pad + 11, .y = vit_y + 25, .text = conditionWord(state.hp), .color = .bone, .weight = .body } });
    const rx = pad + half + gap;
    try panel(out, gpa, rx, vit_y, half, 46, edge, dim(acc, 150));
    try out.append(gpa, .{ .text = .{ .x = rx + 11, .y = vit_y + 9, .text = "THREAT", .color = .dust, .weight = .label } });
    try out.append(gpa, .{ .text = .{ .x = rx + 11, .y = vit_y + 25, .text = "QUIET", .color = .smoke, .weight = .body } });

    // 5. THE FOOTER -- the human voice. Mood, never occupancy (I3): only that the quiet is temporary.
    try out.append(gpa, .{ .text = .{ .x = cx, .y = size.h - 72, .text = "The room is quiet.", .color = .smoke, .weight = .body, .alignment = .center } });
    try out.append(gpa, .{ .text = .{ .x = cx, .y = size.h - 48, .text = "It won't stay that way.", .color = .grave, .weight = .body, .alignment = .center } });

    try drawCreditsLink(size, out, gpa);
    try drawDiagnostic(state, size, out, gpa);
}

/// The diagnostic readout's text, formatted into these each frame. See the long note in
/// `drawDiagnostic` for why they cannot be local buffers. Diagnostic builds only.
var diag_left: [64]u8 = undefined;
var diag_right: [64]u8 = undefined;

/// THE CAFE READOUT. Present only in a diagnostic build (`-Ddiagnostic=true`).
///
/// Sit still. Watch `drift`. If it climbs while you are not moving, the room is smaller than the
/// phone's own error, and a still player is breaking their own quorum by existing. That is O3, and
/// it is the most consequential unvalidated number in the project.
fn drawDiagnostic(state: State, size: Size, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    // COMPTIME-GATED, not just runtime-gated. In a shipping build this whole function -- format
    // strings and all -- is never analysed, so `strings` on the shipped library finds no trace of
    // it. Guarding only on the null field would leave the readout's text sitting in every binary,
    // dormant, which for a rule this sensitive is not tight enough.
    if (comptime !flags.diagnostic) return;

    const d = state.diagnostic orelse return;

    // HIGH ON THE SCREEN, and unmistakable. The first version put it at the very bottom, in the
    // band the credits and the gesture bar already crowd, where it was invisible against the dark.
    // A diagnostic you cannot find is not a diagnostic. This one sits under the top label, in
    // amber, so there is no question whether the build is the diagnostic one.
    const y: i32 = 100;

    // Before the first fix the room is zero. Say so in words, rather than showing `room 0` and
    // leaving the tester to wonder whether zero is a real room (it is not -- every real cell
    // carries a sentinel bit).
    if (d.fixes == 0) {
        try out.append(gpa, .{ .text = .{
            .x = pad,
            .y = y,
            .text = "GPS: waiting for a fix",
            .color = .amber,
            .weight = .label,
        } });
        return;
    }

    // ============================================================================
    // THE BUFFERS ARE MODULE-LEVEL, AND THAT IS THE FIX FOR A REAL BUG.
    //
    // A `Draw.text` holds a SLICE -- a pointer -- into the string it names. The draw list is not
    // rendered here; it is rendered later, in present(), after this function has returned and its
    // stack is gone. So a string formatted into a LOCAL buffer is a dangling pointer by the time
    // anything reads it, and the renderer walks freed stack: mostly missing glyphs, the occasional
    // stray `?`. That is exactly the garbage that showed up on the phone.
    //
    // Every other string in the game is a static literal, so this rule was invisible until the
    // diagnostic became the first code to format one. These buffers outlive the frame -- they are
    // overwritten next frame and read within this one -- so the slices into them stay valid until
    // present() has consumed them. Single render thread, so no lock; diagnostic-only, so this
    // mutable state does not exist in a shipping build at all.
    const room = std.fmt.bufPrint(&diag_left, "room {x}", .{d.room}) catch return;
    try out.append(gpa, .{ .text = .{ .x = pad, .y = y, .text = room, .color = .amber, .weight = .label } });

    const stats = std.fmt.bufPrint(&diag_right, "acc {d}m  fix {d}  drift {d}", .{
        d.accuracy_metres,
        d.fixes,
        d.room_changes,
    }) catch return;

    try out.append(gpa, .{ .text = .{
        .x = size.w - pad,
        .y = y,
        .text = stats,
        // Drift turns the whole line red. That is O3 failing, and it should be impossible to miss.
        .color = if (d.room_changes > 0) .wound else .amber,
        .weight = .label,
        .alignment = .right,
    } });
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
/// ============================================================================
/// THE HOLD, AND THEN THE HIT.
///
/// Containment fails. And then the screen MAKES YOU WAIT.
///
/// The bar sits full. The verdict lands -- CONTAINMENT FAILED -- and blinks at you, three times,
/// while nothing else happens. It is a beat of dead air with a full bar in it, and dead air after a
/// completed task is not a pause, it is a THREAT. Something has finished, and it has not told you
/// what happens next.
///
/// Then it does. Bam.
///
/// The first version of this was a smooth seven-hundred-millisecond cross-fade, and it was wrong
/// for a reason worth writing down: a cross-fade is POLITE. It eases you from one state to another
/// so that you barely notice the change, which is exactly what you want for a settings panel and
/// exactly what you do not want here. The title should not arrive gently. It should land.
const boot_hold_ms: u32 = 780;

/// The hit itself. Short and hard -- this is a strike, not a transition.
const boot_hit_ms: u32 = 240;

/// How long the terminal takes to give way to the field. Short: it is a cut softened, not a
/// dissolve.
const boot_blend_ms: u32 = 320;

const boot_infection_end = boot_terminal_ms + boot_infection_ms;
const boot_hold_end = boot_infection_end + boot_hold_ms;

/// When the title has fully arrived and the screen is at rest.
const boot_settle_end = boot_hold_end + boot_hit_ms;

/// The line the terminal is on, and how far into that line we are.
const boot_line_ms: u32 = boot_terminal_ms / boot_lines.len;

/// ============================================================================
/// THE WAKE. Before anything happens, something has to be ON.
///
/// The sequence used to begin mid-thought: the app opened and a terminal was already typing, which
/// is not a beginning, it is a jump cut into one. There was no moment of the screen coming alive.
///
/// So: black. Then the scanlines rise out of it -- the tube warming, and nothing else -- and it
/// holds there for a beat, empty and humming, before the first line is typed.
///
/// The pause is the point. It is the breath before the sentence.
const boot_fade_ms: u32 = 340;

/// The beat the warm tube sits silent for, before the first character. NOT `boot_hold_ms` -- that
/// is the hold at the END of the sequence, and two things called "the hold" in one file is how you
/// get a blink where you wanted a threat.
const boot_wake_hold_ms: u32 = 260;
const boot_wake_ms = boot_fade_ms + boot_wake_hold_ms;

/// The sequence's own clock, which starts once the screen is awake.
///
/// Everything downstream -- the terminal, the infection, the settle -- is written against this
/// rather than against the app's clock, so the wake could be lengthened, shortened or removed
/// without a single phase boundary moving.
fn afterWake(ms: u32) u32 {
    return ms -| boot_wake_ms;
}

/// ============================================================================
/// A CLEAN RAMP.
///
/// Not linear. A bar advancing at a constant rate is a clock with a paint job -- it reads as an
/// animation playing rather than as anything actually happening.
///
/// And not the stuttering thing I tried before it, either. A bar that sprints, stalls, lurches and
/// hangs at ninety-seven percent is a JOKE ABOUT loading bars: knowing, cheap, funny exactly once.
/// This screen is not trying to be funny. It is trying to be ominous, and a gag undercuts that
/// harder than a straight line ever would.
///
/// So: smoothstep. It eases out of nothing, gathers pace through the middle, and SETTLES into place
/// rather than slamming into it. One curve, no gimmicks, and it never stops moving.
///
///     p = 3t^2 - 2t^3
///
/// Elapsed percent in, progress percent out. Integer arithmetic throughout, because the core has no
/// floats (B6) -- at t=100 the terms are three million and two million, nowhere near an i32.
fn loading(elapsed: i32) i32 {
    // Explicitly i32. `@min(100, ...)` knows its own bound, so Zig will happily narrow this to a
    // u7 -- and then `3 * t * t * 100` reaches three million inside a seven-bit type.
    const t: i32 = @min(100, @max(0, elapsed));
    return @divTrunc(3 * t * t * 100 - 2 * t * t * t, 10_000);
}

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

/// A signed triangle wave, -amp..+amp. Integer only: the core has no floats and does not need any.
///
/// This is what makes the spores DRIFT. Each one is given its own period and its own phase offset,
/// so the field wanders rather than marching -- and because it is a pure function of the clock, the
/// motion is identical on every device and costs nothing to store.
fn wander(ms: u32, period: u32, amp: i32, phase: u32) i32 {
    const quarter = period / 4;
    const t = (ms + phase) % period;

    if (t < quarter) return @divTrunc(amp * @as(i32, @intCast(t)), @as(i32, @intCast(quarter)));
    if (t < 3 * quarter) return amp - @divTrunc(2 * amp * @as(i32, @intCast(t - quarter)), @as(i32, @intCast(2 * quarter)));
    return -amp + @divTrunc(amp * @as(i32, @intCast(t - 3 * quarter)), @as(i32, @intCast(quarter)));
}

/// A triangle wave, 0..255, integer only. The core has no floats and does not need them for this.
fn pulse(ms: u32, period: u32, low: u32, high: u32) u8 {
    const half = period / 2;
    const phase = ms % period;
    const rising = phase < half;
    const t = if (rising) phase else half - (phase - half);
    return @intCast(low + (high - low) * t / half);
}

fn drawBoot(state: State, size: Size, insets: Insets, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    const raw = state.boot_ms;

    // THE SEQUENCE'S OWN CLOCK. Zero until the screen is awake, so nothing below has to know the
    // wake exists.
    const ms = afterWake(raw);

    // Scorched char, not the game's usual near-black. The boot screen is a different room -- and
    // it reaches the glass, edge to edge.
    try out.append(gpa, .{ .rect = .{
        .x = insets.bleedLeft(),
        .y = insets.bleedTop(),
        .w = insets.bleedWidth(size),
        .h = insets.bleedHeight(size),
        .color = .char_deep,
    } });

    // ============================================================================
    // NOTHING IN HERE CUTS. Every phase overlaps the next and fades into it.
    //
    // The terminal does not vanish the instant the field arrives -- it lingers for a third of a
    // second, dimming, while the spores come up underneath it. And containment does not simply stop
    // failing: the bar fades out across the settle while the tagline rises through it.
    //
    // Each of these was a hard cut, and each read as the app blinking rather than the screen
    // changing. A transition is not decoration; without one, two good frames next to each other
    // still look broken.

    // The terminal, fading out into the field.
    if (ms < boot_terminal_ms + boot_blend_ms) {
        const leaving = ms -| boot_terminal_ms;
        const fade: u8 = @intCast(255 - @min(@as(u32, 255), leaving * 255 / boot_blend_ms));
        try drawBootTerminal(ms, size, fade, out, gpa);
    }

    // The field, rising through it.
    if (ms >= boot_terminal_ms) {
        const arrived = ms - boot_terminal_ms;
        const rise: u8 = @intCast(@min(@as(u32, 255), arrived * 255 / boot_blend_ms));

        try drawSpores(ms, size, insets, rise, out, gpa);
        try drawWordmark(ms, size, out, gpa);
        try drawInfection(ms, size, out, gpa);
        try drawBootTail(ms, size, out, gpa);
    }

    // THE TUBE WARMING. The scanlines rise out of black over a third of a second, and for a beat
    // after that they are the only thing on the screen.
    const woken: u8 = @intCast(@min(@as(u32, 255), raw * 255 / boot_fade_ms));
    try drawScanlines(size, insets, woken, out, gpa);

    // THE WAY OUT. The player tapped, and the infection finishes what it started: the dark closes
    // in from the edges, the wordmark flares, and the screen is taken. Four hundred milliseconds.
    if (state.leaving_ms) |began| {
        // `raw`, NOT `ms`. THIS IS THE BUG THE WAKE INTRODUCED.
        //
        // `leaving_ms` is stamped by `touch` from the app's clock. `ms` is the SEQUENCE's clock,
        // which starts later. Subtracting an app-clock instant from a sequence-clock one saturates
        // to zero on every frame, so the exit animation drew its first frame forever and the screen
        // appeared to cut straight to the next one.
        //
        // The screen still CHANGED on time -- `advance` compares app-clock to app-clock and was
        // never wrong -- so the only symptom was that a transition everyone had seen simply
        // stopped existing. No test caught it: they all asserted the state machine, and none of
        // them asserted that the exit had anything to look at.
        const since = raw -| began;
        const t: i32 = @intCast(@min(@as(u32, 100), since * 100 / boot_exit_ms));

        // A FLARE, AND THEN THE DARK. No collapsing vignette -- that was the same mistake as the
        // infection wipe, and it looked like a black rectangle eating the title.
        //
        // The screen flares and then goes out. Brightest halfway through, gone by the end.
        const flare: u8 = @intCast(if (t < 50) @as(u32, @intCast(t)) * 90 / 50 else @as(u32, @intCast(100 - t)) * 90 / 50);
        const bloom = size.w * 2;
        try out.append(gpa, .{ .sprite = .{
            .x = @divTrunc(size.w, 2) - @divTrunc(bloom, 2),
            .y = @divTrunc(size.h, 2) - @divTrunc(bloom, 2),
            .w = bloom,
            .h = bloom,
            .color = dim(.blood, flare),
            .sprite = .disc,
        } });

        // Then the last of it goes to black, so the next screen arrives out of nothing rather than
        // being revealed behind a half-faded splash.
        const close: u8 = @intCast(if (t > 60) (@as(u32, @intCast(t)) - 60) * 255 / 40 else 0);
        if (close > 0) {
            try out.append(gpa, .{ .rect = .{
                .x = insets.bleedLeft(),
                .y = insets.bleedTop(),
                .w = insets.bleedWidth(size),
                .h = insets.bleedHeight(size),
                .color = dim(.void_black, close),
            } });
        }
    }
}

/// How long one character takes to appear. A terminal TYPES; it does not paste.
const type_ms: u32 = 13;

fn drawBootTerminal(ms: u32, size: Size, alpha: u8, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    var typing: usize = boot_lines.len; // which line is still being typed, if any

    for (boot_lines, 0..) |l, i| {
        const began = @as(u32, @intCast(i)) * boot_line_ms;
        if (ms < began) {
            typing = @min(typing, i);
            break;
        }

        // HOW MUCH OF THIS LINE HAS BEEN TYPED. A slice of the string, not the whole of it -- the
        // text appears a character at a time, which is the entire difference between a terminal
        // and a label.
        const chars = (ms - began) / type_ms;
        const done = chars >= l.text.len;
        const upto = @min(l.text.len, chars);

        const y: i32 = 90 + @as(i32, @intCast(i)) * 30;

        if (upto > 0) {
            try out.append(gpa, .{ .text = .{ .x = 26, .y = y, .text = l.text[0..upto], .color = dim(.terminal, alpha), .weight = .label } });
        }

        // The verdict lands only once the line has finished saying what it is verdicting.
        if (done) {
            try out.append(gpa, .{ .text = .{
                .x = size.w - 26,
                .y = y,
                .text = l.status,
                .color = if (l.bad) dim(.amber, alpha) else dim(.blood, alpha),
                .weight = .label,
                .alignment = .right,
            } });
        } else {
            typing = i;
        }
    }

    // The cursor sits at the end of whatever is currently being typed, and on the next line down
    // once everything is. A hard on/off, not a fade -- a terminal cursor does not breathe.
    if ((ms / 500) % 2 == 0) {
        const row = @min(typing, boot_lines.len);
        const y: i32 = 90 + @as(i32, @intCast(row)) * 30;

        if (row >= boot_lines.len) {
            try out.append(gpa, .{ .text = .{ .x = 26, .y = y, .text = ">", .color = dim(.terminal, alpha), .weight = .label } });
            try out.append(gpa, .{ .rect = .{ .x = 44, .y = y + 3, .w = 8, .h = 14, .color = dim(.blood, alpha) } });
        }
    }
}

/// The spore fields: a band at the top, and the same band mirrored at the bottom.
fn drawSpores(ms: u32, size: Size, insets: Insets, alpha: u8, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    // MEASURED AGAINST THE PHONE, NOT THE SAFE AREA. A spore field that stops short of the glass
    // makes the top of the screen look cropped, whatever colour is behind it.
    const full_top = insets.bleedTop();
    const full_w = insets.bleedWidth(size);
    const full_h = insets.bleedHeight(size);
    const full_left = insets.bleedLeft();

    const band = @divTrunc(full_h * 34, 100);

    for (spores, 0..) |s, i| {
        const n: u32 = @intCast(i);

        // THEY WANDER. Each spore gets its own period and its own phase, so the field drifts
        // instead of marching in step. Slow -- these are spores in still air, not flies.
        const drift_x = wander(ms, 7000 + n * 900, 10, n * 613);
        const drift_y = wander(ms, 9000 + n * 700, 7, n * 971);

        const x = full_left + @divTrunc(full_w * s.fx, 1000) + drift_x;
        const y = full_top + @divTrunc(band * s.fy, 1000) + drift_y;
        const colour: Color = if (s.hot) dim(.blood_glow, alpha) else dim(.blood_deep, alpha);

        // Top band, starting at the top of the PHONE.
        try out.append(gpa, .{ .sprite = .{ .x = x - s.r, .y = y - s.r, .w = s.r * 2, .h = s.r * 2, .color = colour, .sprite = .disc } });
        // And mirrored at the bottom of the phone, drifting the other way so the two fields do not
        // read as one field reflected.
        const mirrored_y = full_top + full_h - (y - full_top);
        try out.append(gpa, .{ .sprite = .{ .x = x - drift_x * 2 - s.r, .y = mirrored_y - s.r, .w = s.r * 2, .h = s.r * 2, .color = colour, .sprite = .disc } });
    }

    // The two soft blooms that make it a field rather than a scatter of dots.
    const bloom = @divTrunc(full_w * 7, 10);
    try out.append(gpa, .{ .sprite = .{
        .x = full_left + @divTrunc(full_w * 3, 10) - @divTrunc(bloom, 2),
        .y = full_top + @divTrunc(band * 3, 10) - @divTrunc(bloom, 2),
        .w = bloom,
        .h = bloom,
        .color = dim(.blood, @intCast(@as(u32, 26) * alpha / 255)),
        .sprite = .disc,
    } });
    try out.append(gpa, .{ .sprite = .{
        .x = full_left + @divTrunc(full_w * 7, 10) - @divTrunc(bloom, 2),
        .y = full_top + full_h - @divTrunc(band * 6, 10) - @divTrunc(bloom, 2),
        .w = bloom,
        .h = bloom,
        .color = dim(.blood, @intCast(@as(u32, 20) * alpha / 255)),
        .sprite = .disc,
    } });
}

/// OUTBREAK. Stencilled, bloomed, and -- for four hundred milliseconds -- broken.
fn drawWordmark(ms: u32, size: Size, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    const mid_x = @divTrunc(size.w, 2);
    const mid_y = @divTrunc(size.h, 2);

    // HIGHER THAN CENTRE. Optically centred rather than mathematically: a heavy wordmark sitting on
    // the exact middle line reads as low, and there is a tagline hanging beneath it.
    const top = mid_y - 130;

    // THERE IS NO GLITCH HERE ANY MORE.
    //
    // I had two off-register copies of the wordmark -- one red, one cold blue -- juddering for four
    // hundred milliseconds. It is a stock effect, it reads as a broken television rather than a
    // broken world, and the blue belongs to no part of this game's palette. The letters catching
    // fire is the drama. Nothing needs to shake.

    // THE LETTERS BURN IN, ONE AT A TIME, IN LOCKSTEP WITH THE BAR.
    //
    // Not a curtain and not a fade. Each letter ignites on its own -- hot, then cooling to red --
    // fifty milliseconds after the one before it. The left-to-right feel is a CONSEQUENCE of the
    // stagger, not a wipe passing over the word.
    // IN LOCKSTEP WITH THE BAR -- which means the same uneven curve. The letters catch in bursts,
    // stall while the bar stalls, and land together with it. They are one event, not two.
    const into = ms -| boot_terminal_ms;
    const elapsed: i32 = @intCast(@min(@as(u32, 100), into * 100 / boot_infection_ms));
    const burn: u8 = @intCast(@divTrunc(loading(elapsed) * 255, 100));

    try out.append(gpa, .{ .text = .{
        .x = mid_x,
        .y = top,
        .text = "OUTBREAK",
        .color = .blood,
        .weight = .wordmark,
        .alignment = .center,
        .burn = burn,
    } });

    // THE STENCIL BREAKS. The mock does this with a repeating-linear-gradient: 14px clear, 2px of
    // background, over and over. So do we -- except ours are literal rectangles of background
    // colour painted back over the letters, which is what that gradient was always describing.
    var x: i32 = mid_x - @divTrunc(size.w, 2);
    while (x < mid_x + @divTrunc(size.w, 2)) : (x += 18) {
        try out.append(gpa, .{ .rect = .{ .x = x, .y = top - 8, .w = 2, .h = 84, .color = dim(.char_deep, 140) } });
    }

    // ============================================================================
    // THE BLOOM GOES ON LAST, AND THAT ORDER IS THE WHOLE FIX.
    //
    // Painted BEHIND the letters, the curtain that hides the unrevealed half also punches a
    // hard-edged rectangle out of the glow -- a black box, sitting in the middle of the screen,
    // with corners. It was the first thing you saw.
    //
    // Painted LAST, the glow lies over everything: the letters, the curtain, and the seam between
    // them. It is a soft radial disc, so it has no edges of its own to give the game away, and the
    // curtain becomes invisible. The word simply arrives out of the light.
    //
    // It is the GLOW that pulses when idle, not the letters. Scaling the type would re-rasterize
    // every glyph and rebuild the atlas sixty times a second; scaling a disc is one quad.
    // A HEARTBEAT, not a shimmer. The first version breathed so gently you had to be told it was
    // moving. It swells hard and falls back -- the light behind the word going in and out, on the
    // slow rhythm of something large and unwell.
    // THE HIT. The hold ends, the bar is gone in a single frame, and the light behind the word
    // DETONATES -- once, hard -- then falls back into its heartbeat.
    //
    // This is the bam. It is timed to the end of the hold, not to the end of the bar: the bar
    // finishing is the setup, and the silence after it is the wind-up. The strike lands here.
    const striking = ms >= boot_hold_end and ms < boot_settle_end;
    const flare: u32 = if (striking)
        210 - @min(@as(u32, 210), (ms - boot_hold_end) * 210 / boot_hit_ms)
    else
        0;

    const idle = ms >= boot_settle_end;
    const breath: i32 = if (idle) wander(ms - boot_settle_end, 2400, 130, 0) else 0;
    const beat: u8 = @intCast(@min(@as(u32, 255), flare +
        @as(u32, if (idle) pulse(ms - boot_settle_end, 2400, 26, 165) else 60)));

    const glow = @divTrunc(size.w * 9, 10) + breath + @as(i32, @intCast(flare));
    try out.append(gpa, .{ .sprite = .{
        .x = mid_x - @divTrunc(glow, 2),
        .y = mid_y - @divTrunc(glow, 2) - 96,
        .w = glow,
        .h = glow,
        .color = dim(.blood, beat),
        .sprite = .disc,
    } });
}

/// The infection: the bar fills, and the dark closes in around the wordmark.
fn drawInfection(ms: u32, size: Size, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    // AND THEN, ON THE HIT, IT IS SIMPLY GONE. One frame. No fade.
    //
    // This is the ONE deliberate cut in the whole sequence, and it is deliberate precisely because
    // everything else blends: a hard edge only reads as a strike if the things around it do not
    // have hard edges. A fade here would be the sequence apologising for its own ending.
    if (ms >= boot_hold_end) return;

    const into = ms - boot_terminal_ms;
    const elapsed: i32 = @intCast(@min(@as(u32, 100), into * 100 / boot_infection_ms));
    const percent = loading(elapsed);

    // THE HOLD. The bar is full, and the verdict blinks at you while nothing happens.
    const holding = ms >= boot_infection_end;
    const held = ms -| boot_infection_end;

    // Three blinks across the hold. Hard on, hard off -- this is a warning light, not a breath.
    const blink_period = boot_hold_ms / 3;
    const lit = !holding or (held % blink_period) < (blink_period * 2 / 3);
    const alpha: u8 = if (lit) 255 else 40;

    // THERE IS NO VIGNETTE HERE ANY MORE, AND ITS ABSENCE IS THE POINT.
    //
    // I read the mock's radius backwards and shipped a dark disc that CLOSED over the wordmark --
    // a black rectangle shrinking onto the title, which is exactly as bad as it sounds. The
    // infection is not something that hides the word. The infection IS the word arriving.
    //
    // The reveal lives in `drawWordmark`, in lockstep with the bar below.

    const left: i32 = 38;
    const right: i32 = size.w - 38;
    // Well clear of the bottom. It sat 74dp up, which on a phone is jammed against the gesture bar.
    const bar_y = size.h - 210;

    // FAILING, and then FAILED. The tense changes the moment the bar lands, and that one word is
    // the whole difference between a process and a verdict.
    try out.append(gpa, .{ .text = .{
        .x = left,
        .y = bar_y - 18,
        .text = if (holding) "C O N T A I N M E N T   F A I L E D" else "C O N T A I N M E N T   F A I L I N G",
        .color = if (holding) dim(.blood_glow, alpha) else dim(.faint, alpha),
        .weight = .label,
    } });

    try out.append(gpa, .{ .rect = .{ .x = left, .y = bar_y, .w = right - left, .h = 3, .color = .char } });
    try out.append(gpa, .{ .rect = .{
        .x = left,
        .y = bar_y,
        .w = @divTrunc((right - left) * percent, 100),
        .h = 3,
        .color = dim(.blood_glow, alpha),
    } });
}

/// The tagline, and the invitation.
fn drawBootTail(ms: u32, size: Size, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    const mid_x = @divTrunc(size.w, 2);

    // SATURATING. This function runs from `boot_infection_end`, but the tagline is timed from
    // `boot_settle_end` -- which is 420ms LATER. A plain subtraction underflows a u32 for every one
    // of those 420 milliseconds, and this library ships ReleaseSafe, so it does not wrap quietly:
    // it panics, on the phone, four seconds into the first thing a player ever sees.
    //
    // It shipped. The tests sampled instants either side of the window and stepped clean over it.
    // The test below now walks every millisecond, because a boot sequence that is a pure function
    // of one integer has no excuse for being sampled.
    // IT ARRIVES ON THE HIT. Not before -- during the hold there is a full bar, a blinking verdict
    // and nothing else, and that emptiness is the tension. The tagline lands with the strike.
    const rising = ms -| boot_hold_end;
    const fade: u8 = @intCast(@min(@as(u32, 255), rising * 255 / boot_hit_ms));

    // And the invitation waits until the screen has finished becoming itself.
    const since = ms -| boot_settle_end;

    try out.append(gpa, .{ .text = .{
        .x = mid_x,
        .y = @divTrunc(size.h, 2) - 44,
        .text = "H U M A N I T Y ' S   L A S T   S T A N D",
        .color = dim(.faint, fade),
        .weight = .label,
        .alignment = .center,
    } });

    // Breathing, not blinking. It is an invitation, not an alarm.
    if (since > 300) {
        try out.append(gpa, .{ .text = .{
            .x = mid_x,
            .y = size.h - 120,
            .text = "T A P   T O   E N T E R",
            .color = dim(.terminal, pulse(since, 1600, 90, 255)),
            .weight = .label,
            .alignment = .center,
        } });
    }
}

/// The CRT. Six percent white, every third row. It costs a few hundred rectangles and it is what
/// makes the whole thing feel like it is being displayed rather than drawn.
fn drawScanlines(size: Size, insets: Insets, alpha: u8, out: *std.ArrayList(Draw), gpa: Allocator) Allocator.Error!void {
    // THE CRT REACHES THE GLASS. Scanlines that stop at the safe area leave a flat band top and
    // bottom, and a flat band is a black bar with extra steps -- it looks cropped even when the
    // colour behind it is exactly right.
    const top = insets.bleedTop();
    const bottom = top + insets.bleedHeight(size);

    var y: i32 = top;
    while (y < bottom) : (y += 3) {
        try out.append(gpa, .{ .rect = .{
            .x = insets.bleedLeft(),
            .y = y,
            .w = insets.bleedWidth(size),
            .h = 1,
            .color = dim(.bone, @intCast(@as(u32, 15) * alpha / 255)),
        } });
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

test "the vow: arm, hold to commit, seal, and it cannot be taken back" {
    const size: Size = .{ .w = 380, .h = 760 };
    const human = factionButton(size, .human);
    const confirm = confirmButton(size);

    var state: State = .{ .screen = .choose_side, .now_ms = 1000 };
    try testing.expectEqual(Screen.choose_side, state.screen);

    // Tapping a card ARMS it. It does not commit -- there is no faction yet.
    state = touch(state, .{ .x = human.x + 10, .y = human.y + 10 }, size);
    try testing.expectEqual(Faction.human, state.hovering.?);
    try testing.expectEqual(@as(?Faction, null), state.faction);

    // Pressing HOLD TO COMMIT begins the ceremony. It does not finish it.
    state = press(state, .{ .x = confirm.x + 10, .y = confirm.y + 10 }, size);
    try testing.expect(state.holding_since != null);
    try testing.expectEqual(@as(?Faction, null), state.faction);

    // Held ALMOST the whole ceremony: still nothing. One millisecond short is not a vow.
    state = advance(state, 1000 + hold_commit_ms - 1);
    try testing.expectEqual(@as(?Faction, null), state.faction);

    // Held the whole ceremony: the seal. The side is sworn, and the choosing FLOODS before it hands
    // over -- the screen is still `choose_side` for the flood beat, not yet the terminal.
    state = advance(state, 1000 + hold_commit_ms);
    try testing.expectEqual(Faction.human, state.faction.?);
    try testing.expect(state.sealed_ms != null);
    try testing.expectEqual(Screen.choose_side, state.screen);

    // The flood plays out; the choosing dissolves into the terminal.
    state = advance(state, 1000 + hold_commit_ms + seal_flood_ms);
    try testing.expectEqual(Screen.quiet, state.screen);
    try testing.expectEqual(Faction.human, state.faction.?);

    // And there is no way back. Nothing returns you, and nothing changes the side.
    state = touch(state, .{ .x = 10, .y = 10 }, size);
    try testing.expectEqual(Screen.quiet, state.screen);
    try testing.expectEqual(Faction.human, state.faction.?);
}

test "the vow: releasing early leaves you free" {
    const size: Size = .{ .w = 380, .h = 760 };
    const zombie = factionButton(size, .zombie);
    const confirm = confirmButton(size);

    var state: State = .{ .screen = .choose_side, .now_ms = 500 };
    state = touch(state, .{ .x = zombie.x + 10, .y = zombie.y + 10 }, size); // arm
    state = press(state, .{ .x = confirm.x + 10, .y = confirm.y + 10 }, size); // begin the hold
    try testing.expect(state.holding_since != null);

    // Lift the thumb before the ceremony finishes: the release cancels it.
    state = touch(state, .{ .x = confirm.x + 10, .y = confirm.y + 10 }, size);
    try testing.expectEqual(@as(?u32, null), state.holding_since);

    // Time passes, and nothing seals -- the hold was let go. Still armed, still free.
    state = advance(state, 500 + hold_commit_ms * 3);
    try testing.expectEqual(@as(?Faction, null), state.faction);
    try testing.expectEqual(Screen.choose_side, state.screen);
    try testing.expectEqual(Faction.zombie, state.hovering.?);
}

test "the vow: no side armed, a press commits to nothing" {
    const size: Size = .{ .w = 380, .h = 760 };
    const confirm = confirmButton(size);

    // No default, no pre-selection: a press on HOLD TO COMMIT with nothing armed begins no hold, so
    // the terminal waits forever and no side is ever sworn by accident (OPENING §2, the gravity).
    var state: State = .{ .screen = .choose_side, .now_ms = 0 };
    state = press(state, .{ .x = confirm.x + 10, .y = confirm.y + 10 }, size);
    try testing.expectEqual(@as(?u32, null), state.holding_since);

    state = advance(state, hold_commit_ms * 5);
    try testing.expectEqual(@as(?Faction, null), state.faction);
    try testing.expectEqual(Screen.choose_side, state.screen);
}

test "a restored faction skips the choice and wakes into the terminal" {
    // FACTION PERSISTENCE (O5). The phone seeds the side chosen on a previous launch into the
    // initial state before the boot sequence runs (android.zig, loadFaction). THIS is the guarantee
    // that makes persisting it worth anything: a boot that already knows its side flows straight to
    // the terminal and is never offered the choice again. Break it -- send a returning player back
    // to choose_side -- and the durable vow is pointless, a promise the screen forgets on sight.
    const restored: State = .{ .screen = .boot, .faction = .zombie, .leaving_ms = 0 };
    const woken = advance(restored, boot_exit_ms);
    try testing.expectEqual(Screen.quiet, woken.screen);
    try testing.expectEqual(Faction.zombie, woken.faction.?);

    // The mirror, the same code path's other branch: no side yet still leads to the choice, so a
    // genuine first launch is unaffected.
    const fresh: State = .{ .screen = .boot, .faction = null, .leaving_ms = 0 };
    try testing.expectEqual(Screen.choose_side, advance(fresh, boot_exit_ms).screen);
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
    try draw(state, size, .{}, &out, gpa);

    // Every string on the screen came from the state or from the copy above. There is no cell in
    // this list, no coordinate, no count, and no name -- because there is none in the state. And
    // NOT ONE DIGIT: a number on the quiet screen is the single most dangerous thing it could show,
    // because a count is how a player learns who (I3, I5). The sonar is drawn without one.
    var found_reading = false;
    for (out.items) |item| switch (item) {
        .text => |t| {
            if (std.mem.eql(u8, t.text, "QUIET")) found_reading = true;
            for (t.text) |char| try testing.expect(!std.ascii.isDigit(char));
        },
        .rect, .sprite => {},
    };

    try testing.expect(found_reading);
}

test "THE SONAR READS NOTHING FROM THE ROOM: the quiet dial is identical whatever the crowd" {
    // I2, I3, I5, at the instrument. The sonar is a mood dial driven by the clock and one bit --
    // is this cell live? On the quiet screen there is no live bit, and the crowd is a value the
    // dial is not allowed to see. So the ENTIRE draw list -- every sprite, every mote, every dot of
    // the sweep -- must be byte-identical whether the room holds a few or thousands. If a single
    // mote ever drifted with the crowd, this fails, which is exactly what it is here to do.
    const gpa = testing.allocator;
    const size: Size = .{ .w = 412, .h = 900 };

    var few: std.ArrayList(Draw) = .empty;
    defer few.deinit(gpa);
    var many: std.ArrayList(Draw) = .empty;
    defer many.deinit(gpa);

    // A frozen instant, so the clock is not the variable -- only the crowd is. `told` with no
    // damage keeps the screen quiet but stashes the crowd band in the state, which is the whole
    // point: the crowd is IN the state and the sonar still must not read it.
    const base: State = .{ .screen = .quiet, .faction = .zombie, .now_ms = 4321 };
    try draw(told(base, 100, 1, 0, 0, .even, .a_few), size, .{}, &few, gpa);
    try draw(told(base, 100, 1, 0, 0, .even, .thousands), size, .{}, &many, gpa);

    try testing.expectEqual(few.items.len, many.items.len);
    for (few.items, many.items) |a, b| {
        try testing.expect(std.meta.eql(a, b));
    }
    // And it actually drew the instrument, not an empty list -- a vacuous pass would be worse than
    // a failure, because it would look like proof.
    try testing.expect(few.items.len > 50);
}

test "THE SONAR IS A PURE FUNCTION OF THE CLOCK: the same millisecond draws the same dial" {
    // The same guarantee the tick and the boot sequence have (B7, B8). Ask for millisecond 9000
    // twice and get byte-identical frames; ask for a different one and get a different frame,
    // because a still sonar is a dead app.
    const gpa = testing.allocator;
    const size: Size = .{ .w = 412, .h = 900 };

    var a: std.ArrayList(Draw) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(Draw) = .empty;
    defer b.deinit(gpa);
    var c: std.ArrayList(Draw) = .empty;
    defer c.deinit(gpa);

    const at = struct {
        fn frame(ms: u32, out: *std.ArrayList(Draw), sz: Size, g: Allocator) !void {
            try draw(.{ .screen = .quiet, .faction = .human, .now_ms = ms }, sz, .{}, out, g);
        }
    }.frame;

    try at(9000, &a, size, gpa);
    try at(9000, &b, size, gpa);
    try at(9600, &c, size, gpa);

    // Same instant, same frame.
    try testing.expectEqual(a.items.len, b.items.len);
    for (a.items, b.items) |x, y| try testing.expect(std.meta.eql(x, y));

    // A later instant has moved the sweep and the motes, so something differs.
    var differs = false;
    if (a.items.len != c.items.len) {
        differs = true;
    } else {
        for (a.items, c.items) |x, y| {
            if (!std.meta.eql(x, y)) differs = true;
        }
    }
    try testing.expect(differs);
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
    try draw(.{ .screen = .credits, .faction = .human }, size, .{}, &out, gpa);

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
    // WITH REAL INSETS, not zero. The bleed arithmetic -- negative origins, mirrored bands, a
    // scanline loop that starts above the top of the screen -- only exists when the phone has taken
    // something, so testing at zero would test the one case that cannot go wrong.
    const real: Insets = .{ .top = 57, .bottom = 32, .left = 0, .right = 0 };

    for ([_]Size{ .{ .w = 360, .h = 800 }, .{ .w = 1080, .h = 2400 } }) |size| {
        var ms: u32 = 0;
        while (ms < boot_wake_ms + boot_settle_end + 4000) : (ms += 1) {
            try draw(.{ .screen = .boot, .boot_ms = ms }, size, real, &out, gpa);
            try testing.expect(out.items.len > 0);
        }

        // AND EVERY MILLISECOND OF THE EXIT, from every instant it could have been started at.
        // The last crash was an underflow in a phase boundary, and the exit adds four more.
        var began: u32 = 0;
        while (began < boot_wake_ms + boot_settle_end + 2000) : (began += 37) {
            var t: u32 = 0;
            while (t < boot_exit_ms + 200) : (t += 1) {
                const state: State = .{ .screen = .boot, .boot_ms = began + t, .leaving_ms = began };
                try draw(state, size, real, &out, gpa);
                _ = advance(state, began + t);
            }
        }
    }

    // The exit finishes. A screen that begins leaving and never leaves is a hang.
    const leaving: State = .{ .screen = .boot, .boot_ms = 5000, .leaving_ms = 5000 };
    try testing.expectEqual(Screen.boot, advance(leaving, 5000 + boot_exit_ms - 1).screen);
    try testing.expectEqual(Screen.choose_side, advance(leaving, 5000 + boot_exit_ms).screen);

    // A tap at 900ms is a tap DURING the terminal boot, and the invitation has not been extended
    // yet. It does nothing -- the game is still introducing itself.
    const too_early = touch(.{ .screen = .boot, .boot_ms = boot_wake_ms + 900 }, .{ .x = 10, .y = 10 }, .{ .w = 360, .h = 800 });
    try testing.expectEqual(Screen.boot, too_early.screen);
    try testing.expectEqual(@as(?u32, null), too_early.leaving_ms);

    // Once the sequence has finished, it begins the exit rather than jumping.
    const offered = boot_wake_ms + boot_settle_end + 10;
    const tapped = touch(.{ .screen = .boot, .boot_ms = offered }, .{ .x = 10, .y = 10 }, .{ .w = 360, .h = 800 });
    try testing.expectEqual(Screen.boot, tapped.screen);
    try testing.expectEqual(@as(?u32, offered), tapped.leaving_ms);
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
    try draw(.{ .screen = .boot, .boot_ms = boot_wake_ms + 300 }, size, .{}, &out, gpa);
    try testing.expect(!wordmarkAt(out.items));

    // THE TERMINAL TYPES. At 300ms the first line is a PREFIX of itself -- a few characters in --
    // and the last line has not been reached at all. A test that looked for the whole string would
    // be asserting that the terminal pastes.
    var partial_first = false;
    var saw_last_line = false;
    for (out.items) |item| switch (item) {
        .text => |t| {
            if (t.text.len > 0 and t.text.len < boot_lines[0].text.len and
                std.mem.startsWith(u8, boot_lines[0].text, t.text)) partial_first = true;
            if (std.mem.startsWith(u8, boot_lines[4].text, t.text) and t.text.len > 2) saw_last_line = true;
        },
        else => {},
    };
    try testing.expect(partial_first);
    try testing.expect(!saw_last_line);

    // And by the end of its slot, the line is complete and its verdict has landed.
    try draw(.{ .screen = .boot, .boot_ms = boot_wake_ms + boot_line_ms - 1 }, size, .{}, &out, gpa);
    var complete_first = false;
    for (out.items) |item| switch (item) {
        .text => |t| if (std.mem.eql(u8, t.text, boot_lines[0].text)) {
            complete_first = true;
        },
        else => {},
    };
    try testing.expect(complete_first);

    // LATE IN THE TERMINAL: every line is up, including the one that is not OK.
    try draw(.{ .screen = .boot, .boot_ms = boot_wake_ms + boot_terminal_ms - 1 }, size, .{}, &out, gpa);
    var saw_contamination = false;
    for (out.items) |item| switch (item) {
        .text => |t| if (std.mem.eql(u8, t.text, boot_lines[3].text)) {
            saw_contamination = true;
        },
        else => {},
    };
    try testing.expect(saw_contamination);

    // THE WORDMARK IS NOT ON THE TERMINAL SCREEN AT ALL.
    try draw(.{ .screen = .boot, .boot_ms = boot_wake_ms + boot_terminal_ms - 1 }, size, .{}, &out, gpa);
    try testing.expect(!wordmarkAt(out.items));

    // AND FROM THE FIRST MILLISECOND OF THE INFECTION IT IS THERE -- but barely lit. The letters
    // BURN IN one at a time, in lockstep with the bar, and the string carries how far through that
    // fire it is. The renderer stages the stagger, because only the renderer knows where the second
    // letter begins.
    const burnAt = struct {
        fn at(list: []const Draw) u8 {
            for (list) |item| switch (item) {
                .text => |t| if (t.weight == .wordmark) return t.burn,
                else => {},
            };
            return 255;
        }
    }.at;

    try draw(.{ .screen = .boot, .boot_ms = boot_wake_ms + boot_terminal_ms + 20 }, size, .{}, &out, gpa);
    try testing.expect(wordmarkAt(out.items));
    const early = burnAt(out.items);

    try draw(.{ .screen = .boot, .boot_ms = boot_wake_ms + boot_terminal_ms + @divTrunc(boot_infection_ms, 2) }, size, .{}, &out, gpa);
    const midway = burnAt(out.items);

    // The fire spreads. If it does not, the word is popping in rather than igniting.
    try testing.expect(early < midway);

    // And by the end of the infection it has fully caught: every letter is lit, at its own colour.
    try draw(.{ .screen = .boot, .boot_ms = boot_wake_ms + boot_infection_end }, size, .{}, &out, gpa);
    try testing.expect(wordmarkAt(out.items));
    try testing.expectEqual(@as(u8, 255), burnAt(out.items));

    // AT REST: the wordmark is up, the invitation is pulsing, and nothing is still loading.
    try draw(.{ .screen = .boot, .boot_ms = boot_wake_ms + boot_settle_end + 1200 }, size, .{}, &out, gpa);
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
    try draw(.{ .screen = .boot, .boot_ms = boot_wake_ms + 2400 }, size, .{}, &out, gpa);
    try draw(.{ .screen = .boot, .boot_ms = boot_wake_ms + 2400 }, size, .{}, &again, gpa);
    try testing.expectEqual(out.items.len, again.items.len);

    // AND IT IS SKIPPABLE. A splash screen you cannot escape is being shown for someone else's
    // benefit, not the player's.
    //
    // But a tap BEGINS the exit; it does not jump. The four hundred milliseconds after it are not
    // touches, so `advance` is what finishes the job -- and that is the whole reason `advance`
    // exists rather than the ending being done inside `touch`.
    // THE TAP DOES NOT WORK UNTIL THE SEQUENCE HAS FINISHED. "Tap to enter" is an invitation, and
    // it is not extended until the screen has said everything it has to say.
    const too_soon = touch(.{ .screen = .boot, .boot_ms = boot_wake_ms + 200 }, .{ .x = 100, .y = 100 }, size);
    try testing.expectEqual(@as(?u32, null), too_soon.leaving_ms);
    try testing.expectEqual(Screen.boot, advance(too_soon, 900).screen);

    const mid_infection = touch(.{ .screen = .boot, .boot_ms = boot_wake_ms + boot_infection_end - 1 }, .{ .x = 100, .y = 100 }, size);
    try testing.expectEqual(@as(?u32, null), mid_infection.leaving_ms);

    // Once it IS offered, the tap begins the ending -- it does not jump. The four hundred
    // milliseconds after it are not touches, which is why `advance` exists at all.
    const ready = boot_wake_ms + boot_settle_end + 500;
    const tapped = touch(.{ .screen = .boot, .boot_ms = ready }, .{ .x = 100, .y = 100 }, size);
    try testing.expectEqual(Screen.boot, tapped.screen);
    try testing.expectEqual(@as(?u32, ready), tapped.leaving_ms);
    try testing.expectEqual(Screen.choose_side, advance(tapped, ready + boot_exit_ms).screen);

    // A returning player, who has already chosen, lands back in the quiet.
    const returning = touch(.{ .screen = .boot, .boot_ms = ready, .faction = .human }, .{ .x = 100, .y = 100 }, size);
    try testing.expectEqual(Screen.quiet, advance(returning, ready + boot_exit_ms).screen);

    // Tapping twice does not restart the exit. The player is already leaving.
    const twice = touch(tapped, .{ .x = 50, .y = 50 }, size);
    try testing.expectEqual(@as(?u32, ready), twice.leaving_ms);
}

test "THE LOADING BAR DOES NOT MOVE AT A CONSTANT SPEED" {
    // A bar that advances evenly reads as a progress ANIMATION -- decoration with a number attached.
    // A real one sprints, stalls on something it will not name, lurches, crawls, and hangs at
    // ninety-seven. It reads as work being done, because work is uneven.
    //
    // This test is what stops someone "tidying" the curve back into a straight line.

    // It starts at nothing and finishes at everything. A bar that never reaches 100 is a bug you
    // find in a screenshot on the internet.
    try testing.expectEqual(@as(i32, 0), loading(0));
    try testing.expectEqual(@as(i32, 100), loading(100));

    // It never goes backwards. A bar that retreats is worse than no bar.
    var t: i32 = 1;
    while (t <= 100) : (t += 1) {
        try testing.expect(loading(t) >= loading(t - 1));
    }

    // IT IS NOT A STRAIGHT LINE. If progress equals elapsed all the way along, the curve has been
    // flattened and the bar has become a clock with a paint job.
    var uneven = false;
    t = 1;
    while (t < 100) : (t += 1) {
        if (loading(t) != t) uneven = true;
    }
    try testing.expect(uneven);

    // IT EASES IN. Behind a straight line for the first half -- it is getting up to speed, not
    // starting at full tilt.
    try testing.expect(loading(25) < 25);
    try testing.expect(loading(10) < 10);

    // IT SETTLES. Ahead of a straight line for the second half, so it arrives rather than slamming.
    try testing.expect(loading(75) > 75);
    try testing.expect(loading(90) > 90);

    // It crosses the middle at the middle: the curve is symmetric, so the ramp up and the settle
    // are the same shape.
    try testing.expectEqual(@as(i32, 50), loading(50));

    // AND IT DOES NOT STALL IN THE MIDDLE. This is what rules out the stuttering version -- no
    // pauses, no hang at ninety-seven, no gag. Through the body of the ramp every step is a real
    // step.
    //
    // NOT at the extremes, and that is the ease rather than a stall: a curve that leaves zero
    // gently spends its first couple of percent below half a point of progress, so in whole
    // percent it has not visibly moved yet. That is the whole idea of easing in. Asserting
    // otherwise would be asserting that it does not ease.
    // It makes real ground across every stretch of the ramp.
    t = 25;
    while (t <= 80) : (t += 5) {
        try testing.expect(loading(t) > loading(t - 5));
    }

    // AND IT NEVER SITS STILL. This is the assertion that actually rules out the stuttering
    // version, whose stalls were sixteen percent of the runtime wide -- you could watch the bar
    // stop and wait.
    //
    // Measured across the BODY of the ramp, because the ends are supposed to be flat: leaving zero
    // gently means the first few percent of time gain less than half a point of progress, and in
    // whole percent the bar has not visibly moved yet. That is the ease. A test that forbade it
    // would be a test that forbade easing, which is the thing we are here to do.
    //
    // Through the middle, the longest a whole-percent reading repeats is one -- a rounding
    // artifact, not a pause.
    var run: i32 = 0;
    var longest: i32 = 0;
    t = 11;
    while (t <= 90) : (t += 1) {
        if (loading(t) == loading(t - 1)) {
            run += 1;
            longest = @max(longest, run);
        } else {
            run = 0;
        }
    }
    try testing.expect(longest <= 1);

    // Out of range is clamped rather than exploding. The shell is not always careful.
    try testing.expectEqual(@as(i32, 0), loading(-50));
    try testing.expectEqual(@as(i32, 100), loading(500));
}

test "NOTHING IN THE BOOT SEQUENCE CUTS" {
    // THE BUG THIS EXISTS TO PREVENT IS NOT A CRASH. It is the screen BLIPPING.
    //
    // Every phase used to end by vanishing. The terminal disappeared the instant the field arrived.
    // The bar disappeared the instant it filled. Two perfectly good frames, next to each other,
    // still look broken if nothing carries you from one to the other.
    //
    // So each phase must OVERLAP the next. This test asserts the overlaps exist -- which is the
    // closest a test can get to "it does not look like the app blinked".
    const gpa = testing.allocator;
    const size: Size = .{ .w = 360, .h = 800 };

    var out: std.ArrayList(Draw) = .empty;
    defer out.deinit(gpa);

    const has = struct {
        /// VISIBLE, not merely present. A draw command with an alpha of zero is in the list and on
        /// nobody's screen -- and a test that cannot tell those apart will happily pass a blank
        /// phone. (This one did, for one commit, until it was pointed at the hold.)
        fn text(list: []const Draw, needle: []const u8) bool {
            for (list) |item| switch (item) {
                .text => |t| if (std.mem.indexOf(u8, t.text, needle) != null and
                    (@intFromEnum(t.color) & 0xFF) > 8) return true,
                else => {},
            };
            return false;
        }
        fn sprite(list: []const Draw) bool {
            for (list) |item| switch (item) {
                .sprite => return true,
                else => {},
            };
            return false;
        }
    };

    // THE TERMINAL OVERLAPS THE FIELD. Just after the infection starts, the last terminal line is
    // still on screen, dimming, while the spores come up underneath it.
    try draw(.{ .screen = .boot, .boot_ms = boot_wake_ms + boot_terminal_ms + 40 }, size, .{}, &out, gpa);
    try testing.expect(has.text(out.items, "PERIMETER")); // still there
    try testing.expect(has.sprite(out.items)); // and the field is already rising

    // ...and it is gone once the blend is over. A lingering terminal is its own bug.
    try draw(.{ .screen = .boot, .boot_ms = boot_wake_ms + boot_terminal_ms + boot_blend_ms + 50 }, size, .{}, &out, gpa);
    try testing.expect(!has.text(out.items, "PERIMETER"));

    // THE HOLD IS EMPTY, AND THAT IS THE TENSION. Containment has FAILED -- the verdict is up, the
    // bar is full -- and there is nothing else. No tagline yet. The screen is making you wait.
    try draw(.{ .screen = .boot, .boot_ms = boot_wake_ms + boot_infection_end + 60 }, size, .{}, &out, gpa);
    try testing.expect(has.text(out.items, "F A I L E D")); // the tense has changed
    try testing.expect(!has.text(out.items, "F A I L I N G"));
    try testing.expect(!has.text(out.items, "L A S T   S T A N D")); // and nothing has arrived yet

    // THEN THE HIT. The bar is gone in one frame -- the single deliberate cut in the sequence --
    // and the title lands. A fade here would be the sequence apologising for its own ending.
    try draw(.{ .screen = .boot, .boot_ms = boot_wake_ms + boot_hold_end + boot_hit_ms }, size, .{}, &out, gpa);
    try testing.expect(!has.text(out.items, "C O N T A I N M E N T"));
    try testing.expect(has.text(out.items, "L A S T   S T A N D"));

    // The invitation waits for the screen to finish becoming itself, and only then arrives.
    try testing.expect(!has.text(out.items, "T A P"));
    try draw(.{ .screen = .boot, .boot_ms = boot_wake_ms + boot_settle_end + 900 }, size, .{}, &out, gpa);
    try testing.expect(has.text(out.items, "T A P"));
}

test "THE SCREEN WAKES BEFORE IT SPEAKS" {
    // The sequence used to begin mid-thought: the app opened and a terminal was already typing,
    // which is not a beginning, it is a jump cut into one.
    //
    // Now there is black, then the tube warms -- the scanlines rise out of nothing -- and it holds
    // there for a beat, empty and humming, before the first character is typed. The pause is the
    // point; it is the breath before the sentence.
    const gpa = testing.allocator;
    const size: Size = .{ .w = 360, .h = 800 };

    var out: std.ArrayList(Draw) = .empty;
    defer out.deinit(gpa);

    const anyText = struct {
        fn go(list: []const Draw) bool {
            for (list) |item| switch (item) {
                .text => return true,
                else => {},
            };
            return false;
        }
    }.go;

    // The scanline alpha, as the tube warms. It is the faintest thing on the screen, so it is
    // measured rather than eyeballed.
    const scanline = struct {
        fn alpha(list: []const Draw) u32 {
            for (list) |item| switch (item) {
                // The scanlines are the full-width, one-pixel-high rows of bone.
                .rect => |r| if (r.h == 1 and r.w > 100) return @intFromEnum(r.color) & 0xFF,
                else => {},
            };
            return 0;
        }
    }.alpha;

    // AT THE VERY FIRST MILLISECOND: black. Not a word on the screen, and the tube barely lit.
    try draw(.{ .screen = .boot, .boot_ms = 0 }, size, .{}, &out, gpa);
    try testing.expect(!anyText(out.items));
    try testing.expectEqual(@as(u32, 0), scanline(out.items));

    // PART WAY THROUGH THE FADE: the lines are coming up, and there is still nothing to read.
    try draw(.{ .screen = .boot, .boot_ms = boot_fade_ms / 2 }, size, .{}, &out, gpa);
    const half = scanline(out.items);
    try testing.expect(half > 0);
    try testing.expect(!anyText(out.items));

    // AND THE HOLD: fully warm, and STILL silent. This beat is the whole reason the wake exists --
    // without it the fade would run straight into the first line and the screen would never be
    // simply on.
    try draw(.{ .screen = .boot, .boot_ms = boot_wake_ms - 1 }, size, .{}, &out, gpa);
    try testing.expect(scanline(out.items) > half);
    try testing.expect(!anyText(out.items));

    // THEN IT SPEAKS. The first character of the first line, and not before.
    try draw(.{ .screen = .boot, .boot_ms = boot_wake_ms + 40 }, size, .{}, &out, gpa);
    try testing.expect(anyText(out.items));

    // And a tap during the wake does nothing. There is not yet anything to skip.
    const early = touch(.{ .screen = .boot, .boot_ms = 100 }, .{ .x = 10, .y = 10 }, size);
    try testing.expectEqual(@as(?u32, null), early.leaving_ms);
}

test "THE WAY OUT IS ANIMATED, AND THE CLOCKS DO NOT DISAGREE" {
    // THIS TEST EXISTS BECAUSE THE EXIT SILENTLY STOPPED EXISTING.
    //
    // `leaving_ms` is stamped from the APP's clock. When the wake was added, `drawBoot` began
    // running on the SEQUENCE's clock, which starts later. Subtracting one from the other saturated
    // to zero on every frame, so the exit drew its opening frame forever and the screen appeared to
    // cut straight to the next one.
    //
    // The state machine was never wrong -- `advance` compares app-clock to app-clock, and the
    // screen still changed exactly on time. Every test passed. The only symptom was that a
    // transition everyone had seen simply was not there any more, and it took a human looking at a
    // phone to notice.
    //
    // So: assert the exit has something to LOOK at, and that it gets darker as it goes.
    const gpa = testing.allocator;
    const size: Size = .{ .w = 360, .h = 800 };

    var out: std.ArrayList(Draw) = .empty;
    defer out.deinit(gpa);

    // The blackout that carries you into the next screen. It is the last thing drawn, so it is the
    // last full-bleed rect in the list.
    const blackout = struct {
        /// The blackout is the SECOND full-bleed black rectangle. The first is the background,
        /// which is also full-bleed and also black and is always there at full alpha -- so a
        /// detector that just takes the last match reports 255 on a frame with no blackout at all,
        /// and the test then asserts that the screen gets LIGHTER as it fades out.
        ///
        /// That is what happened. The bug was in the test, not the code, and it is exactly the kind
        /// of thing that would have been "fixed" by loosening the assertion.
        fn alpha(list: []const Draw) u32 {
            var matches: u32 = 0;
            var last: u32 = 0;
            for (list) |item| switch (item) {
                .rect => |r| if (r.w >= 360 and r.h >= 800 and
                    (@intFromEnum(r.color) >> 8) == (@intFromEnum(Color.void_black) >> 8))
                {
                    matches += 1;
                    last = @intFromEnum(r.color) & 0xFF;
                },
                else => {},
            };
            return if (matches >= 2) last else 0;
        }
    }.alpha;

    const tapped_at = boot_wake_ms + boot_settle_end + 300;

    // Straight after the tap, the screen has not gone dark yet -- it flares first.
    try draw(.{ .screen = .boot, .boot_ms = tapped_at + 20, .leaving_ms = tapped_at }, size, .{}, &out, gpa);
    const early = blackout(out.items);

    // By the end of the exit it is very nearly black, so the next screen arrives out of nothing
    // rather than being revealed behind a half-faded splash.
    try draw(.{ .screen = .boot, .boot_ms = tapped_at + boot_exit_ms - 1, .leaving_ms = tapped_at }, size, .{}, &out, gpa);
    const late = blackout(out.items);

    try testing.expect(late > early);
    try testing.expect(late > 200);

    // AND THE ANIMATION ACTUALLY ADVANCES. This is the assertion that fails if the two clocks ever
    // disagree again: with `since` stuck at zero, every frame of the exit is identical and this is
    // the line that catches it.
    try testing.expect(early < 60);
}

test "THE DIAGNOSTIC READOUT IS ABSENT BY DEFAULT AND ONLY SPEAKS OF THIS PHONE" {
    // Two things this pins. First: with no diagnostic, the readout is not drawn -- the flag
    // defaults off and the field defaults null, so a shipping build cannot show it by accident.
    //
    // Second, and the one that matters: everything it CAN show is about this device's own sense of
    // where it is. There is no count of other people, no direction to anyone, no identity. A
    // diagnostic that leaked one of those would be an I-rule violation wearing a debugging coat.
    const gpa = testing.allocator;
    const size: Size = .{ .w = 360, .h = 800 };

    var out: std.ArrayList(Draw) = .empty;
    defer out.deinit(gpa);

    // No diagnostic -> the readout is not drawn. The readout is the string "room {hex}", so it is
    // detected by a text that STARTS WITH "room " -- not by the word "room" appearing anywhere, or
    // the dread copy "The room is quiet." would trip a diagnostic detector by writing plain English.
    try draw(.{ .screen = .quiet, .faction = .human }, size, .{}, &out, gpa);
    for (out.items) |item| switch (item) {
        .text => |t| try testing.expect(!std.mem.startsWith(u8, t.text, "room ")),
        else => {},
    };

    // With a diagnostic set, the readout appears ONLY in a diagnostic build. This test binary is
    // not one -- the flag defaults off -- so the readout stays absent even with the field set, and
    // that is the property that matters: the gate is comptime, so a shipping build cannot draw the
    // readout no matter what the state says.
    const with: State = .{
        .screen = .quiet,
        .faction = .human,
        .diagnostic = .{ .room = 0xBEEF, .accuracy_metres = 8, .fixes = 3, .room_changes = 0 },
    };
    try draw(with, size, .{}, &out, gpa);

    var saw_room = false;
    for (out.items) |item| switch (item) {
        .text => |t| if (std.mem.startsWith(u8, t.text, "room ")) {
            saw_room = true;
        },
        else => {},
    };
    try testing.expectEqual(flags.diagnostic, saw_room);
}
