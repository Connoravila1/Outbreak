//! SHELL (B1). Glyphs: a codepoint and a size in, a coverage bitmap and an advance out.
//!
//! This is the only file that knows what a font is. It holds the two faces, it caches every
//! glyph it has ever rasterized, and it hands out plain data. `atlas.zig` packs that data into a
//! texture; `quads.zig` turns it into triangles; nothing else has heard of any of it.
//!
//! ============================================================================
//! THE DEPENDENCY (F1, F6)
//!
//! stb_truetype. Vendored, pinned, public domain, zero transitive dependencies. The written
//! justification is at the import site -- `vendor/stb_impl.c` -- as F1 requires, and F6 is
//! explicit that it does not inherit the map SDK's blessing.
//!
//! ZIG NEVER SEES A C HEADER. The shim's functions are declared below as `extern fn`, exactly as
//! `android.zig` declares the NDK and `gles.zig` declares GLES. The layout of `stbtt_fontinfo`
//! stays on the C side of the wall where it belongs (D3): we ask how big it is and hand back a
//! buffer of that size. We never need to know what is in it, and so it can never drift.
//!
//! ============================================================================
//! THE FONTS
//!
//! Inter, Regular and SemiBold. SIL Open Font License 1.1, (c) 2016 The Inter Project Authors;
//! the licence travels with the repository at `assets/Inter-LICENSE.txt`.
//!
//! Two faces, four styles. `ui.Weight` has four members -- label, body, heading, alarm -- but
//! they differ by SIZE and COLOUR, not by four distinct weights. Mapping them onto two faces is
//! not a compromise, it is what they already were.
//!
//! It also sidesteps a real landmine. The prior art keys its glyph cache with the weight shifted
//! into bit 63 of a u64, which holds exactly one bit. A four-member weight enum overflows that
//! shift: a panic in Debug, and in Release a silent aliasing of weights 2 and 3 onto 0 and 1 --
//! wrong glyphs, no error, on a phone. The key here is built from named bit ranges instead.

const std = @import("std");
const ui = @import("../ui.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const regular_ttf = @embedFile("font_regular");
const semibold_ttf = @embedFile("font_semibold");

// ---- the shim (vendor/stb_impl.c). No header, no @cImport, no bindings. ----

extern fn glyphshim_fontinfo_size() usize;
extern fn glyphshim_font_init(info: *anyopaque, ttf: [*]const u8) c_int;
extern fn glyphshim_scale_for_pixel_height(info: *const anyopaque, pixels: f32) f32;
extern fn glyphshim_find_glyph(info: *const anyopaque, codepoint: c_int) c_int;
extern fn glyphshim_glyph_hmetrics(info: *const anyopaque, glyph: c_int, advance: *c_int, left_bearing: *c_int) void;
extern fn glyphshim_font_vmetrics(info: *const anyopaque, ascent: *c_int, descent: *c_int, line_gap: *c_int) void;
extern fn glyphshim_glyph_bitmap(info: *const anyopaque, scale: f32, glyph: c_int, w: *c_int, h: *c_int, x0: *c_int, y0: *c_int) ?[*]u8;
extern fn glyphshim_free_bitmap(bitmap: [*]u8) void;

pub const Error = error{FontCorrupt} || Allocator.Error;

/// Which of the two faces, and at what size, a `ui.Weight` is drawn.
///
/// This is the entire type ramp of the game, in one table. `alarm` is `heading`'s size in a
/// different colour -- the colour is `ui.zig`'s business and it already decided.
pub const Style = struct {
    face: Face,
    px: u16,
};

pub const Face = enum(u1) { regular, semibold };

/// THE TYPE RAMP.
///
/// These sizes are matched to `ui.zig`'s line spacing (`line = 26`), which is where the layout
/// already committed. They are not a design; they are the sizes that fit the layout that exists.
pub fn styleOf(weight: ui.Weight) Style {
    return switch (weight) {
        .label => .{ .face = .semibold, .px = 13 },
        .body => .{ .face = .regular, .px = 17 },
        .heading => .{ .face = .semibold, .px = 22 },
        .alarm => .{ .face = .semibold, .px = 22 },
    };
}

/// One rasterized glyph, as plain data. The coverage bytes live in the engine's pool.
///
/// Blit at `(pen_x + bear_x, baseline_y + bear_y)`. `bear_y` is normally NEGATIVE: the bitmap's
/// top edge sits above the baseline, and y counts downward.
pub const Glyph = struct {
    /// Where the coverage bytes start in `Engine.pool`.
    offset: u32,
    w: u16,
    h: u16,
    advance: i16,
    bear_x: i16,
    bear_y: i16,
    _pad: u16 = 0,

    comptime {
        // Budget: 4 + 2+2 + 2+2+2 + 2 = 16 bytes, exact. One per distinct (face, size, codepoint)
        // in the game's copy -- a few hundred, held for the life of the process, and walked when
        // the atlas packs them. Raising this requires a recorded justification (A7.1).
        assert(@sizeOf(Glyph) == 16);
    }
};

/// The vertical metrics of a line, in pixels. Cold: computed per style, not per glyph.
///
/// A7.2: cold struct, size guard waived.
pub const Line = struct {
    ascent: i32,
    descent: i32,
    height: i32,
};

pub const Engine = struct {
    /// The two `stbtt_fontinfo`s, sized by the C side and owned by us (C4).
    faces: [2][]align(16) u8,

    /// Coverage bytes for every glyph ever rasterized, appended and never freed until deinit.
    ///
    /// APPEND-ONLY, ON PURPOSE. The game's copy is a few dozen fixed sentences; the set of glyphs
    /// it can ever need is small, bounded, and reached within seconds of the first live cell.
    /// An eviction policy would be a cache with a bug in it, guarding against a growth that
    /// cannot happen (G3).
    pool: std.ArrayList(u8),

    cache: std.AutoHashMapUnmanaged(u64, Glyph),
};

/// The cache key: face, size, and codepoint in named bit ranges.
///
/// NOT a shift into the top bit. The prior art put the weight in bit 63, which holds one bit and
/// silently aliases the moment a third weight exists. Codepoints reach 0x10FFFF (21 bits) and a
/// size fits in 16; there is room here for both, with the face beside them and nothing overlapping.
fn keyOf(face: Face, px: u16, codepoint: u21) u64 {
    return (@as(u64, @intFromEnum(face)) << 40) |
        (@as(u64, px) << 21) |
        @as(u64, codepoint);
}

/// SHELL. Parse the two faces. Everything else is lazy.
pub fn init(gpa: Allocator) Error!Engine {
    const size = glyphshim_fontinfo_size();

    const regular = try gpa.alignedAlloc(u8, .of(u128), size);
    errdefer gpa.free(regular);

    const semibold = try gpa.alignedAlloc(u8, .of(u128), size);
    errdefer gpa.free(semibold);

    if (glyphshim_font_init(regular.ptr, regular_ttf.ptr) == 0) return Error.FontCorrupt;
    if (glyphshim_font_init(semibold.ptr, semibold_ttf.ptr) == 0) return Error.FontCorrupt;

    return .{
        .faces = .{ regular, semibold },
        .pool = .empty,
        .cache = .empty,
    };
}

pub fn deinit(engine: *Engine, gpa: Allocator) void {
    gpa.free(engine.faces[0]);
    gpa.free(engine.faces[1]);
    engine.pool.deinit(gpa);
    engine.cache.deinit(gpa);
    engine.* = undefined;
}

fn faceOf(engine: *const Engine, face: Face) *const anyopaque {
    return @ptrCast(engine.faces[@intFromEnum(face)].ptr);
}

/// SHELL. The coverage bytes of one glyph. Rasterized on first sight, cached forever after.
///
/// THE RETURNED SLICE IS BORROWED AND SHORT-LIVED. It points into `engine.pool`, which is an
/// ArrayList that reallocates on the next cache miss. Consume it before calling this again --
/// `atlas.ensure` does exactly that, in the same expression.
pub fn glyph(engine: *Engine, gpa: Allocator, face: Face, px: u16, codepoint: u21) Error!struct { Glyph, []const u8 } {
    const key = keyOf(face, px, codepoint);

    if (engine.cache.get(key)) |cached| {
        return .{ cached, engine.pool.items[cached.offset..][0 .. @as(usize, cached.w) * cached.h] };
    }

    const info = faceOf(engine, face);
    const scale = glyphshim_scale_for_pixel_height(info, @floatFromInt(px));
    const index = glyphshim_find_glyph(info, codepoint);

    var advance_units: c_int = 0;
    var bearing_units: c_int = 0;
    glyphshim_glyph_hmetrics(info, index, &advance_units, &bearing_units);

    const advance_px: i16 = @intFromFloat(@round(@as(f32, @floatFromInt(advance_units)) * scale));

    var w: c_int = 0;
    var h: c_int = 0;
    var x0: c_int = 0;
    var y0: c_int = 0;
    const bitmap = glyphshim_glyph_bitmap(info, scale, index, &w, &h, &x0, &y0);

    // A space, a control character, a glyph the face does not have: it advances the pen and puts
    // no ink on the page. That is not an error, it is an empty result (E4).
    if (bitmap == null or w <= 0 or h <= 0) {
        const empty: Glyph = .{ .offset = 0, .w = 0, .h = 0, .advance = advance_px, .bear_x = 0, .bear_y = 0 };
        try engine.cache.put(gpa, key, empty);
        return .{ empty, &.{} };
    }

    const pixels = bitmap.?;
    defer glyphshim_free_bitmap(pixels);

    const count: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h));
    const offset: u32 = @intCast(engine.pool.items.len);
    try engine.pool.appendSlice(gpa, pixels[0..count]);

    const result: Glyph = .{
        .offset = offset,
        .w = @intCast(w),
        .h = @intCast(h),
        .advance = advance_px,
        .bear_x = @intCast(x0),
        .bear_y = @intCast(y0),
    };
    try engine.cache.put(gpa, key, result);

    return .{ result, engine.pool.items[offset..][0..count] };
}

/// SHELL. How far the pen moves for one codepoint. No ink, no atlas, no allocation.
pub fn advance(engine: *const Engine, face: Face, px: u16, codepoint: u21) i16 {
    const info = faceOf(engine, face);
    const scale = glyphshim_scale_for_pixel_height(info, @floatFromInt(px));
    const index = glyphshim_find_glyph(info, codepoint);

    var advance_units: c_int = 0;
    var bearing_units: c_int = 0;
    glyphshim_glyph_hmetrics(info, index, &advance_units, &bearing_units);

    return @intFromFloat(@round(@as(f32, @floatFromInt(advance_units)) * scale));
}

/// SHELL. How wide a string is, in pixels. Pure measurement; draws nothing.
///
/// There is NO KERNING and no shaping. Advances are per-glyph and independent. For Latin UI copy
/// at these sizes that is invisible, and the alternative is a shaping engine, which is a second
/// dependency and an order of magnitude more code than the game (G3).
pub fn measure(engine: *const Engine, face: Face, px: u16, string: []const u8) i32 {
    var total: i32 = 0;
    var it = codepoints(string);
    while (it.next()) |codepoint| total += advance(engine, face, px, codepoint);
    return total;
}

/// SHELL. The vertical metrics of a line at one style.
pub fn lineOf(engine: *const Engine, face: Face, px: u16) Line {
    const info = faceOf(engine, face);
    const scale = glyphshim_scale_for_pixel_height(info, @floatFromInt(px));

    var ascent_units: c_int = 0;
    var descent_units: c_int = 0;
    var gap_units: c_int = 0;
    glyphshim_font_vmetrics(info, &ascent_units, &descent_units, &gap_units);

    const ascent: i32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(ascent_units)) * scale));
    const descent: i32 = @intFromFloat(@floor(@as(f32, @floatFromInt(descent_units)) * scale));
    const gap: i32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(gap_units)) * scale));

    return .{ .ascent = ascent, .descent = descent, .height = ascent - descent + gap };
}

/// A UTF-8 walker that cannot fail.
///
/// Malformed bytes are SKIPPED, not reported. The strings here are compile-time literals from
/// `ui.zig` and are valid by construction -- but a decoder that can return an error is a decoder
/// whose error someone has to handle on a render thread, and there is nothing useful to do with
/// it. Define the error out of existence (E4).
pub fn codepoints(string: []const u8) Utf8 {
    return .{ .bytes = string };
}

pub const Utf8 = struct {
    bytes: []const u8,
    i: usize = 0,

    pub fn next(it: *Utf8) ?u21 {
        while (it.i < it.bytes.len) {
            const length = std.unicode.utf8ByteSequenceLength(it.bytes[it.i]) catch {
                it.i += 1;
                continue;
            };
            if (it.i + length > it.bytes.len) return null;

            const decoded = std.unicode.utf8Decode(it.bytes[it.i..][0..length]) catch {
                it.i += 1;
                continue;
            };
            it.i += length;
            return decoded;
        }
        return null;
    }
};

const testing = std.testing;

test "the faces parse, and every character the game can say has a glyph" {
    const gpa = testing.allocator;

    var engine = try init(gpa);
    defer deinit(&engine, gpa);

    // Every string ui.zig can put on the screen, walked. If any of them contains a character
    // Inter cannot draw, it renders as a box, and it renders as a box in a cafe, in front of a
    // player, on the day we find out.
    const every_sentence = [_][]const u8{
        "OUTBREAK",          "Choose a side",
        "This choice is permanent.",
        "You will never be able to change it.",
        "Human",             "Zombie",
        "Confirm",           "Nothing here.",
        "CONDITION",         "LEVEL",
        "THIS CELL IS LIVE", "WHAT YOU KNOW",
        "Walk away",         "There is nothing to do but stay.",
        "You are not alone, and not among friends.",
        "You are surrounded by thousands.",
        "You will not hold much longer.",
        "The fight is even.",
        "Whole",             "Holding",
        "Failing",           "Barely",
        "Down",
    };

    for (every_sentence) |sentence| {
        var it = codepoints(sentence);
        while (it.next()) |codepoint| {
            // A zero index means the face has neither the glyph nor U+FFFD -- nothing to draw at
            // all. Space is allowed to have no ink, but it must still be a real glyph.
            const index = glyphshim_find_glyph(faceOf(&engine, .regular), codepoint);
            try testing.expect(index != 0);
        }
    }
}

test "a glyph has ink, an advance, and sits above the baseline" {
    const gpa = testing.allocator;

    var engine = try init(gpa);
    defer deinit(&engine, gpa);

    const g, const coverage = try glyph(&engine, gpa, .regular, 17, 'H');

    try testing.expect(g.w > 0 and g.h > 0);
    try testing.expectEqual(@as(usize, @as(usize, g.w) * g.h), coverage.len);
    try testing.expect(g.advance > 0);

    // bear_y is the top of the bitmap relative to the baseline, y DOWN. A capital H sits entirely
    // above the baseline, so its top edge is negative. Getting this sign wrong draws every line of
    // text one line-height below where it belongs, and it looks like a layout bug for a week.
    try testing.expect(g.bear_y < 0);

    // Anti-aliased, which is the entire reason for the dependency: an edge pixel that is neither
    // 0 nor 255. If this ever comes back 1-bit, the coverage path is broken.
    var partial = false;
    for (coverage) |c| {
        if (c != 0 and c != 255) partial = true;
    }
    try testing.expect(partial);
}

test "a space has no ink but still moves the pen" {
    const gpa = testing.allocator;

    var engine = try init(gpa);
    defer deinit(&engine, gpa);

    const g, const coverage = try glyph(&engine, gpa, .regular, 17, ' ');

    try testing.expectEqual(@as(u16, 0), g.w);
    try testing.expectEqual(@as(usize, 0), coverage.len);
    try testing.expect(g.advance > 0); // it is a space, not a nothing
}

test "the cache returns the same glyph, and the key does not alias across faces or sizes" {
    const gpa = testing.allocator;

    var engine = try init(gpa);
    defer deinit(&engine, gpa);

    const first, _ = try glyph(&engine, gpa, .regular, 17, 'A');
    const again, _ = try glyph(&engine, gpa, .regular, 17, 'A');
    try testing.expectEqual(first.offset, again.offset);
    try testing.expectEqual(@as(u32, 1), engine.cache.count());

    // THE ALIASING BUG THIS EXISTS TO PREVENT. Same codepoint, same size, different face -- and
    // the same codepoint, same face, different size. Each must be a DIFFERENT cached glyph. The
    // prior art shifts the face into bit 63 of the key; widen its weight enum past one bit and
    // these collide silently, drawing the wrong glyph with no error anywhere.
    _ = try glyph(&engine, gpa, .semibold, 17, 'A');
    _ = try glyph(&engine, gpa, .regular, 22, 'A');
    try testing.expectEqual(@as(u32, 3), engine.cache.count());

    // And the keys themselves are distinct, which is the property underneath.
    try testing.expect(keyOf(.regular, 17, 'A') != keyOf(.semibold, 17, 'A'));
    try testing.expect(keyOf(.regular, 17, 'A') != keyOf(.regular, 22, 'A'));
    try testing.expect(keyOf(.regular, 17, 'A') != keyOf(.regular, 17, 'B'));

    // The widest codepoint and the largest size must not overflow into each other's bits.
    try testing.expect(keyOf(.semibold, 65535, 0x10FFFF) != keyOf(.regular, 65535, 0x10FFFF));
}

test "measure is the sum of the advances, and an empty string is zero" {
    const gpa = testing.allocator;

    var engine = try init(gpa);
    defer deinit(&engine, gpa);

    try testing.expectEqual(@as(i32, 0), measure(&engine, .regular, 17, ""));

    const h = advance(&engine, .regular, 17, 'H');
    const i = advance(&engine, .regular, 17, 'i');
    try testing.expectEqual(h + i, measure(&engine, .regular, 17, "Hi"));

    // Proportional, not monospace -- which is the other reason for the dependency. An 'i' is
    // narrower than an 'H'. If these are ever equal, we are drawing a monospace font by accident.
    try testing.expect(i < h);

    // A bigger size is a wider string. Obvious, and it catches a scale factor that is not applied.
    try testing.expect(measure(&engine, .regular, 22, "Hi") > measure(&engine, .regular, 17, "Hi"));
}

test "a line has positive height and an ascent above the baseline" {
    const gpa = testing.allocator;

    var engine = try init(gpa);
    defer deinit(&engine, gpa);

    const line = lineOf(&engine, .regular, 17);
    try testing.expect(line.ascent > 0);
    try testing.expect(line.descent < 0); // below the baseline, y down
    try testing.expect(line.height > line.ascent);
}

test "malformed utf-8 is skipped, not fatal" {
    // The strings are literals today. They will not always be -- and a decoder that can fail is a
    // failure someone has to handle on the render thread, where there is nothing useful to do.
    var it = codepoints(&[_]u8{ 'a', 0xFF, 0xC0, 'b' });
    try testing.expectEqual(@as(u21, 'a'), it.next().?);
    try testing.expectEqual(@as(u21, 'b'), it.next().?);
    try testing.expectEqual(@as(?u21, null), it.next());
}
