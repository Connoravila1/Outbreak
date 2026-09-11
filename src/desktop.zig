//! SHELL (B1, B3). The desktop host.
//!
//! An SDL3 window and a DVUI frame loop around the pure interface in `ui.zig`: the core hands
//! back a list of things to draw, and the player's presses go in as plain integer pixels.
//! Iteration happens on a laptop, not a phone (CURRENT.md).
//!
//! F1 justification — DVUI is a sanctioned dependency, recorded here at the import site:
//! what it does is immediate-mode widgets, text, input, and rendering over SDL. We do not write
//! it ourselves because a GUI toolkit is precisely the thing the WebView was, badly; this file
//! replaces a browser engine with a Zig library. Cost to remove: delete the dep, this file, and
//! its guard.zig registration. The core never imports it (D7).

const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("sdl-backend");
const ui = @import("ui.zig");
const playtest = @import("playtest.zig");
const client = @import("client.zig");
const map = @import("map.zig");
const location = @import("location.zig");
const loadout = @import("loadout.zig");
const world = @import("world.zig");

const icon_png = @embedFile("icon_png");

// The phone's JNI shim does not exist on a laptop. The calls below are only reachable with
// radio.running set, which nothing on desktop ever sets; the exports exist for the linker.
export fn jnishim_attach(vm: ?*anyopaque) ?*anyopaque {
    _ = vm;
    return null;
}
export fn jnishim_detach(vm: ?*anyopaque) void {
    _ = vm;
}
export fn jnishim_combat_alert(env: ?*anyopaque, activity: ?*anyopaque, band: c_int) void {
    _ = env;
    _ = activity;
    _ = band;
}

var state: ui.State = .{};
var backend: SDLBackend = undefined;
var win: dvui.Window = undefined;
var fonts_ready = false;
var io: std.Io = undefined;
var environ_map: *const std.process.Environ.Map = undefined;

// ---- the server, or the stand-in for one
var radio: location.Radio = .{ .vm = null, .activity = null };
var client_started = false;
var demo_mode = false;
var fix_arg: ?[]const u8 = null;
var pt: playtest.State = .{};
var quiet_ms: u32 = 0;
var last_ms: u32 = 0;
var init_gpa: std.mem.Allocator = undefined;

// Scripted actions through the real `act` path -- `--faction=human` plays the whole ceremony
// headlessly: tap-to-enter, arm, hold-to-seal. It is how a screenshot reaches the live loop.
var faction_arg: ?world.Faction = null;
var boot_tapped = false;
var seal_pressed = false;

/// Desktop iteration aid: `--shot=path.png --ms=N` renders the frame at N milliseconds since
/// open into a PNG and exits. The whole animation is a pure function of the millisecond, so the
/// screenshot is the test (ui.zig, boot_ms).
var shot_path: ?[]const u8 = null;
var shot_ms: u32 = 12_000;
var shot_done = false;
var dump_ops = false;
var only_op: ?[]const u8 = null;

/// THE THEME the widgets wear: the machine's palette, our fonts, and no rounded corners -- the
/// interface is a salvaged instrument, not a consumer app. One theme object, and every widget
/// DVUI builds agrees with it.
fn outbreakTheme() dvui.Theme {
    const c = struct {
        fn f(colour: ui.Color) dvui.Color {
            return toColor(colour);
        }
    }.f;
    return .{
        .name = "outbreak",
        .dark = true,
        .focus = c(.human_glow),
        .fill = c(.void_black),
        .fill_hover = c(.ash),
        .fill_press = c(.clot),
        .text = c(.bone),
        .text_hover = c(.bone),
        .text_press = c(.bone),
        .border = c(.grave),
        .control = .{
            .fill = c(.carrion),
            .fill_hover = c(.ash),
            .fill_press = c(.clot),
            .text = c(.bone),
            .border = c(.grave),
        },
        .window = .{ .fill = c(.void_black), .text = c(.bone), .border = c(.grave) },
        .highlight = .{ .fill = c(.human_deep), .text = c(.bone) },
        .err = .{ .fill = c(.clot), .text = c(.bone) },
        .font_body = .find(.{ .family = "Inter", .size = 16 }),
        .font_heading = .find(.{ .family = "Oxanium SemiBold", .size = 15 }),
        .font_title = .find(.{ .family = "Oxanium Bold", .size = 24 }),
        .font_mono = .find(.{ .family = "Inter", .size = 14 }),
        .max_default_corner_radius = 0,
    };
}

/// The four procedural sprites, baked once at startup. Same coverage functions the GLES atlas
/// baked — recovered verbatim from git history (first-party code, no dependency).
var sprites: [@typeInfo(ui.Sprite).@"enum".fields.len]dvui.Texture = undefined;

/// THE MAP, cached. The quarantined module (map.zig) says which tiles cover the window for a
/// given pan and zoom; we hold their decoded, graded textures keyed by tile coordinate and load
/// on miss. The cache is per-cell: a new cell or a new zoom throws it away.
const map_max_tiles = 20;
const map_cache_max = 64;
var map_cell: u64 = 0;
var map_zoom: u5 = map.default_zoom;
var map_pan_x: i32 = 0;
var map_pan_y: i32 = 0;
var map_place: [map_max_tiles]map.Placement = undefined;
var map_count: usize = 0;
var map_loaded: [map_cache_max]struct { tile: map.Tile, tex: ?dvui.Texture } = undefined;
var map_loaded_n: usize = 0;

// A press on the map is a candidate drag until it moves far enough to be one; a press that never
// moved is a tap, and a tap is a ripple.
var map_drag: ?struct { x: f32, y: f32 } = null;
var map_drag_moved = false;

pub fn main(init: std.process.Init) !void {
    io = init.io;
    init_gpa = init.gpa;
    environ_map = init.environ_map;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--shot=")) shot_path = arg["--shot=".len..];
        if (std.mem.startsWith(u8, arg, "--ms=")) shot_ms = try std.fmt.parseInt(u32, arg["--ms=".len..], 10);
        if (std.mem.eql(u8, arg, "--dump")) dump_ops = true;
        if (std.mem.startsWith(u8, arg, "--only=")) only_op = arg["--only=".len..];
        if (std.mem.eql(u8, arg, "--demo")) demo_mode = true;
        if (std.mem.startsWith(u8, arg, "--fix=")) fix_arg = arg["--fix=".len..];
        if (std.mem.eql(u8, arg, "--faction=human")) faction_arg = .human;
        if (std.mem.eql(u8, arg, "--faction=zombie")) faction_arg = .zombie;
    }

    SDLBackend.enableSDLLogging();

    // A dev fix, fed through the real callback: the coordinate dies in `onLocation` exactly as it
    // does on the phone. What survives is a room the loopback server can resolve us into.
    if (fix_arg) |fix| feedFix(fix);
    // The demo needs a room to stand in for the map and the loopback alike; midtown is the dev
    // default. On the phone this call is the Android callback, and the cell is real.
    if (demo_mode and fix_arg == null) feedFix("40.7580,-73.9855");
    client.setInstallIdentity(try loadOrCreateIdentity());

    backend = try SDLBackend.initWindow(.{
        .io = init.io,
        .environ_map = init.environ_map,
        .allocator = init.gpa,
        .size = .{ .w = 430, .h = 860 },
        .min_size = .{ .w = 320, .h = 560 },
        .vsync = true,
        .title = "Outbreak",
        .icon = icon_png,
    });
    defer backend.deinit();

    win = try dvui.Window.init(@src(), init.gpa, backend.backend(), .{
        .theme = outbreakTheme(),
    });
    defer win.deinit();

    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();

    var interrupted = false;
    main_loop: while (true) {
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);
        _ = arena_state.reset(.{ .retain_with_limit = 1 << 20 });

        if (!fonts_ready) {
            try registerFonts();
            try bakeSprites();
            fonts_ready = true;
        }

        try backend.addAllEvents(&win);

        _ = SDLBackend.c.SDL_SetRenderDrawColor(backend.renderer, 8, 8, 10, 255);
        _ = SDLBackend.c.SDL_RenderClear(backend.renderer);

        if (!frame(arena_state.allocator())) break :main_loop;

        const end_micros = try win.end(.{});
        try backend.setCursor(win.cursorRequested());
        try backend.textInputRect(win.textInputRequested());
        try backend.renderPresent();

        if (shot_path != null and !shot_done and
            SDLBackend.c.SDL_GetTicks() >= shot_ms)
        {
            writeShot(shot_path.?);
            shot_done = true;
            break :main_loop;
        }

        interrupted = try backend.waitEventTimeout(win.waitTime(end_micros));
    }
}

/// Plays the ceremony with the same calls a finger makes: `act` is what the widgets report, and
/// the seal completes on the clock inside `advance` -- the driver never pokes the state.
fn driveCeremony(ms: u32, size: ui.Size, side: world.Faction) void {
    switch (state.screen) {
        .boot => if (ms > 9600 and !boot_tapped) {
            boot_tapped = true;
            state = ui.act(state, .enter, size);
        },
        .choose_side => {
            if (state.sealed_ms != null) return;
            if (state.hovering == null) {
                // The futures rise on the reveal; an arm before that does nothing, so wait for it.
                if (ui.chooseReveal(state) >= 2600) {
                    state = ui.act(state, .{ .arm = if (side == .human) .human else .zombie }, size);
                }
                return;
            }
            // One hold_begin, then the clock does the work -- calling it again each frame would
            // restart the timer forever. The bar must have risen first, or the act is inert.
            if (state.holding_since == null and !seal_pressed and ui.chooseReveal(state) >= 3100) {
                state = ui.act(state, .hold_begin, size);
                if (state.holding_since != null) seal_pressed = true;
            }
        },
        // The briefing turns a page per tap; the driver reads one page every two seconds.
        .briefing => if (ms -| last_brief_tap > 2000) {
            last_brief_tap = ms;
            state = ui.act(state, .brief_next, size);
        },
        // A player looks around once: gear, then record, then back to the instrument. Scripted so
        // the whole shell is exercised headless -- and so a screenshot can land on either surface.
        // The instrument gets its own beat first: the tour leaves quiet only after a moment on it.
        .quiet => {
            if (quiet_since == 0) quiet_since = ms;
            if (ms -| quiet_since > 2500 and nav_leg == 0) {
                last_nav_tap = ms;
                nav_leg = 1;
                state = ui.act(state, .{ .nav = .gear }, size);
            } else if (ms -| last_nav_tap > 2500 and nav_leg == 3) {
                // One more look: the credits, then done touring.
                last_nav_tap = ms;
                nav_leg = 4;
                state = ui.act(state, .credits_open, size);
            }
        },
        .gear => {
            // Tap the first inventory row once -- the equip REQUEST travels the real intent path
            // even though, with only the starter stock owned, the answer is the same loadout.
            if (nav_leg == 1 and !inv_tapped) {
                inv_tapped = true;
                for (loadout.catalogue) |def| {
                    if (def.slot == .evidence or !loadout.owns(state.owned, def.id)) continue;
                    state = ui.act(state, .{ .equip = def.id }, size);
                    break;
                }
            } else if (ms -| last_nav_tap > 2500 and nav_leg == 1) {
                last_nav_tap = ms;
                nav_leg = 2;
                state = ui.act(state, .{ .nav = .record }, size);
            }
        },
        .record => if (ms -| last_nav_tap > 2500 and nav_leg == 2) {
            last_nav_tap = ms;
            nav_leg = 3;
            state = ui.act(state, .{ .nav = .quiet }, size);
        },
        .credits => if (ms -| last_nav_tap > 2500 and nav_leg == 4) {
            last_nav_tap = ms;
            nav_leg = 5;
            state = ui.act(state, .credits_back, size);
        },
        else => {},
    }
}

var last_brief_tap: u32 = 0;
var last_nav_tap: u32 = 0;
var quiet_since: u32 = 0;
var nav_leg: u8 = 0;
var inv_tapped = false;

/// The stand-in server: `playtest.zig` resolves the accelerated encounter on the frame clock and
/// each round lands as a `toldGame` -- the same fold a real response takes. Its figures never enter
/// progression; the point is a complete encounter on a laptop, in seconds.
fn drivePlaytest(dt: u32, faction: world.Faction) void {
    if (state.screen == .quiet) {
        quiet_ms += dt;
        if (quiet_ms > 2500 and playtest.canStartEquipped(pt, pt.equipped)) {
            pt = playtest.start(pt, state.kit);
        }
    } else {
        quiet_ms = 0;
    }

    const phase_before = pt.phase;
    const round_before = pt.round;
    pt = playtest.advance(pt, dt, faction);

    if (pt.phase == .resolving and pt.round != round_before) {
        state = ui.toldGame(state, pt.hp, 1, state.total_xp + pt.xp_earned, pt.last_damage, pt.momentum, .a_few, pt.kit, pt.damage_dealt, .none, pt.equipped, loadout.starter_owned, 6, loadout.no_item, false, .ambient);
    }
    if (pt.phase == .debrief and phase_before != .debrief) {
        state = ui.toldGame(state, pt.hp, 1, state.total_xp + pt.xp_earned, 0, pt.momentum, .a_few, pt.kit, pt.damage_dealt, pt.reward, pt.equipped, loadout.starter_owned, 6, pt.reward_item, true, .none);
    }

    // The debrief card was seen and tapped away; the driver returns to idle for the next one.
    if (state.encounter_finished and pt.phase == .debrief and state.screen == .quiet) {
        state = ui.acknowledgeEncounter(state);
    }
}

/// One dev fix through the real entry point: `location.devFix` parses and quantizes the
/// coordinate inside location.zig, the only file the coordinate is permitted to exist in (B6).
fn feedFix(spec: []const u8) void {
    location.devFix(spec);
}

/// Load the tile cache for the cell the player stands in. The quarantined map module owns the
/// geography (which tiles, where on screen); this function only does I/O: read the cached PNGs,
/// decode, grade to the palette, upload. A missing tile is a dark block, not an error -- the map
/// degrades to void, which is what the streets look like at night anyway.
/// A cell change or a zoom change retires every texture -- the tile set is different ground.
fn clearMapCache() void {
    for (map_loaded[0..map_loaded_n]) |e| {
        if (e.tex) |tex| SDLBackend.c.SDL_DestroyTexture(@ptrCast(@alignCast(tex.ptr)));
    }
    map_loaded_n = 0;
}

/// The decoded, graded texture for one tile -- loaded on first sight, cached forever after
/// (until the cell or zoom retires the set). A tile the cache does not have returns null and
/// the shell paints the gap as void.
fn ensureTile(tile: map.Tile) ?dvui.Texture {
    for (map_loaded[0..map_loaded_n]) |e| {
        if (e.tile.z == tile.z and e.tile.x == tile.x and e.tile.y == tile.y) return e.tex;
    }
    if (map_loaded_n >= map_cache_max) return null;

    const home = environ_map.get("HOME") orelse return null;
    var dir_buf: [256]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}/.cache/outbreak/tiles", .{home}) catch return null;
    var path_buf: [320]u8 = undefined;
    const path = map.tilePath(dir, tile, &path_buf);

    var tex: ?dvui.Texture = null;
    if (std.Io.Dir.cwd().openFile(io, path, .{})) |file| {
        defer file.close(io);
        if (file.stat(io)) |stat| {
            if (init_gpa.alloc(u8, @intCast(stat.size))) |bytes| {
                defer init_gpa.free(bytes);
                if (file.readPositionalAll(io, bytes, 0)) |_| {
                    var w: c_int = 0;
                    var h: c_int = 0;
                    var ch: c_int = 0;
                    if (dvui.c.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &ch, 4)) |decoded| {
                        defer dvui.c.stbi_image_free(decoded);
                        map.grade(decoded[0..@intCast(w * h * 4)]);
                        tex = uploadTexture(decoded, @intCast(w), @intCast(h)) catch null;
                    }
                } else |_| {}
            } else |_| {}
        } else |_| {}
    } else |_| {}

    map_loaded[map_loaded_n] = .{ .tile = tile, .tex = tex };
    map_loaded_n += 1;
    return tex;
}

/// RGBA pixels -> GPU texture, the same direct-SDL path bake() uses (backend.textureCreate goes
/// through a surface and flattens alpha).
fn uploadTexture(pixels: [*]const u8, w: u32, h: u32) !dvui.Texture {
    const c = SDLBackend.c;
    const tex = c.SDL_CreateTexture(backend.renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, @intCast(w), @intCast(h)) orelse return error.TextureCreate;
    errdefer c.SDL_DestroyTexture(tex);
    if (!c.SDL_UpdateTexture(tex, null, pixels, @intCast(w * 4))) return error.TextureUpdate;
    _ = c.SDL_SetTextureScaleMode(tex, c.SDL_SCALEMODE_LINEAR);
    const pma = c.SDL_ComposeCustomBlendMode(c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD, c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD);
    _ = c.SDL_SetTextureBlendMode(tex, pma);
    return .{ .ptr = tex, .width = w, .height = h, .format = .rgba_32 };
}

/// The graded tiles, drawn under the scene's marker and labels. Placements recompute every
/// frame -- it is the same handful of divides whether the map sits still or is being dragged --
/// and a tile the cache does not have is a gap in the world, painted as void.
fn drawMapLayer(size: ui.Size, s: f32) void {
    map_count = map.layout(@enumFromInt(map_cell), map_zoom, size.w, size.h, map_pan_x, map_pan_y, &map_place);
    for (map_place[0..map_count]) |pl| {
        const r: dvui.Rect.Physical = .{
            .x = @as(f32, @floatFromInt(pl.x)) * s,
            .y = @as(f32, @floatFromInt(pl.y)) * s,
            .w = @as(f32, @floatFromInt(pl.w)) * s,
            .h = @as(f32, @floatFromInt(pl.h)) * s,
        };
        if (ensureTile(pl.tile)) |tex| {
            dvui.renderTexture(tex, .{ .r = r, .s = s }, .{}) catch {};
        } else {
            var b = dvui.Path.Builder.init(dvui.currentWindow().arena());
            defer b.deinit();
            b.addRect(.{ .x = r.x, .y = r.y, .w = r.w, .h = r.h }, .{});
            b.build().fillConvex(.{ .color = .{ .r = 14, .g = 10, .b = 12 } });
        }
    }
}

/// A dev install identity, persisted under zig-out so a restart lands on the same account --
/// the same "anonymous per-install" shape the phone has, minus the phone.
fn loadOrCreateIdentity() ![client.identity_size]u8 {
    const path = "zig-out/desktop-identity";
    if (std.Io.Dir.cwd().openFile(io, path, .{})) |file| {
        defer file.close(io);
        var buf: [client.identity_size]u8 = undefined;
        const n = file.readPositionalAll(io, &buf, 0) catch 0;
        if (n == buf.len) return buf;
    } else |_| {}
    var identity: [client.identity_size]u8 = undefined;
    io.randomSecure(&identity) catch return error.EntropyUnavailable;
    if (std.Io.Dir.cwd().createFile(io, path, .{})) |file| {
        defer file.close(io);
        file.writePositionalAll(io, &identity, 0) catch {};
    } else |_| {}
    return identity;
}

/// Read back the presented frame -- what a player actually sees, not a re-render.
fn writeShot(path: []const u8) void {
    const c = SDLBackend.c;
    const surface = c.SDL_RenderReadPixels(backend.renderer, null) orelse {
        dvui.log.err("--shot: SDL_RenderReadPixels failed", .{});
        return;
    };
    defer c.SDL_DestroySurface(surface);
    const rgba = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_RGBA32) orelse surface;
    defer if (rgba != surface) c.SDL_DestroySurface(rgba);

    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        dvui.log.err("--shot could not create {s}: {any}", .{ path, err });
        return;
    };
    defer file.close(io);
    var buf: [8192]u8 = undefined;
    var w = file.writer(io, &buf);
    const surf: *c.SDL_Surface = @ptrCast(rgba);
    const pixels: [*]u8 = @ptrCast(surf.pixels);
    dvui.PNGEncoder.writeWithResolution(&w.interface, pixels[0..@intCast(surf.w * surf.h * 4)], @intCast(surf.w), @intCast(surf.h), 2835) catch |err| {
        dvui.log.err("--shot could not encode {s}: {any}", .{ path, err });
    };
    w.interface.flush() catch {};
}

fn registerFonts() !void {
    try dvui.addFont("Inter", @embedFile("font_body"), null);
    try dvui.addFont("Oxanium SemiBold", @embedFile("font_label"), null);
    try dvui.addFont("Oxanium Bold", @embedFile("font_heading"), null);
    try dvui.addFont("Oxanium ExtraBold", @embedFile("font_alarm"), null);
}

fn frame(arena: std.mem.Allocator) bool {
    const rs = win.rectScale();
    const s = rs.s;
    const size: ui.Size = .{
        .w = @intFromFloat(@round(rs.r.w / s)),
        .h = @intFromFloat(@round(rs.r.h / s)),
    };

    const ms: u32 = @intCast(SDLBackend.c.SDL_GetTicks());
    const dt = ms -| last_ms;
    last_ms = ms;
    state = ui.advance(state, ms);

    // The game moves before the screen does. A tell from the loopback server folds exactly as it
    // does on the phone; when no server is up, --demo lets the deterministic driver play its part.
    if (client.takeResponse()) |r| {
        state = ui.toldGame(state, r.hp, r.level, r.total_xp, r.damage, r.momentum, r.crowd, r.kit, r.salvage, r.reward, r.equipped, r.owned, r.capacity, r.item, r.discovered, r.source);
    }
    if (client.authoritativeFaction()) |server_side| {
        if (state.faction != server_side) state.faction = server_side;
    }

    if (faction_arg) |side| driveCeremony(ms, size, side);

    // A tap on GEAR wrote a request. The intent travels the real path: client.equipItem carries it
    // to the authority; in --demo the deterministic driver stands in for one and answers the same
    // way, through toldGame.
    if (state.equip_request != loadout.no_item) {
        const req = state.equip_request;
        state.equip_request = loadout.no_item;
        if (loadout.itemFromByte(req)) |item| {
            client.equipItem(item);
            if (demo_mode) pt = playtest.prepareEquipment(pt, client.selectedEquipment());
        }
    }

    if (state.faction) |faction| {
        if (!client_started) {
            client_started = true;
            _ = std.Thread.spawn(.{}, client.run, .{ init_gpa, faction, &radio }) catch {};
        }
        if (demo_mode) drivePlaytest(dt, faction);
    }

    // THE MAP. The cell the location layer holds is the one thing a map is allowed to be of;
    // when it changes, the tile set for the old cell is retired. Where a map is built, the
    // core's scene ops get a marker point to pulse on instead of a well to draw -- and the
    // marker slides with the pan, pinned to its ground.
    const cell_bits = location.read().cell;
    if (cell_bits != map_cell) {
        map_cell = cell_bits;
        map_pan_x = 0;
        map_pan_y = 0;
        clearMapCache();
    }
    if (map_cell != 0) {
        const mp = map.markerOnScreen(size.w, size.h, map_pan_x, map_pan_y);
        state.map_marker = .{ .x = mp.x, .y = mp.y };
    } else {
        state.map_marker = null;
    }

    // THE SCENE FIRST -- the bespoke painting (boot, the choosing, the map) underneath whatever
    // chrome the widgets draw. Then the widgets: structure, layout, and events the toolkit owns.
    if (state.map_marker != null and (state.screen == .quiet or state.screen == .live)) drawMapLayer(size, s);
    var out: std.ArrayList(ui.Draw) = .empty;
    ui.draw(state, size, .{}, &out, arena) catch return true;
    for (out.items) |op| drawOp(op, s);

    chrome(s, size, arena);

    // Scene-level input the widget layer does not own: the boot's tap-anywhere, the map's drag
    // and wheel-zoom, and a tap's ripple. Only events no widget claimed -- a drag that starts on
    // a button is not a pan, and a press that never moved is a tap, not a drag.
    const on_map = state.map_marker != null and (state.screen == .quiet or state.screen == .live);
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        switch (e.evt) {
            .mouse => |m| {
                const at: ui.Touch = .{
                    .x = @intFromFloat(@round(m.p.x / s)),
                    .y = @intFromFloat(@round(m.p.y / s)),
                };
                switch (m.action) {
                    .press => if (m.button == .left) switch (state.screen) {
                        .boot => state = ui.act(state, .enter, size),
                        .quiet, .live => if (on_map) {
                            map_drag = .{ .x = m.p.x, .y = m.p.y };
                            map_drag_moved = false;
                        } else if (state.screen == .quiet) {
                            state = ui.act(state, .{ .dial = at }, size);
                        },
                        else => {},
                    },
                    .motion => if (map_drag) |d| {
                        const dx = m.p.x - d.x;
                        const dy = m.p.y - d.y;
                        map_drag = .{ .x = m.p.x, .y = m.p.y };
                        // The map slides under the pointer -- drag right and the ground goes right.
                        map_pan_x -|= @intFromFloat(@round(dx / s));
                        map_pan_y -|= @intFromFloat(@round(dy / s));
                        if (@abs(map_pan_x) + @abs(map_pan_y) > 6) map_drag_moved = true;
                    },
                    .release => if (map_drag != null) {
                        if (!map_drag_moved and state.screen == .quiet) {
                            state = ui.act(state, .{ .dial = at }, size);
                        }
                        map_drag = null;
                    },
                    .wheel_y => |wy| if (on_map) {
                        // Scroll is zoom, like the map it imitates; pan scales to keep the same
                        // ground under the pointer.
                        if (wy > 0 and map_zoom < map.max_zoom) {
                            map_zoom += 1;
                            map_pan_x *= 2;
                            map_pan_y *= 2;
                            clearMapCache();
                        } else if (wy < 0 and map_zoom > map.min_zoom) {
                            map_zoom -= 1;
                            map_pan_x = @divTrunc(map_pan_x, 2);
                            map_pan_y = @divTrunc(map_pan_y, 2);
                            clearMapCache();
                        }
                    },
                    else => {},
                }
            },
            .window => |w| if (w.action == .close) return false,
            .app => |a| if (a.action == .quit) return false,
            else => {},
        }
    }

    // The instrument animates every frame; never let the loop sleep.
    dvui.refresh(null, @src(), null);
    return true;
}

// ============================================================================ the widget layer
//
// Structure comes from the toolkit: boxes pack, scrollers scroll, buttons report. The core's job
// is only WHAT shows -- the copy, the state, the scene. What the widgets report back are meanings
// (`ui.act`), not pixels.

/// A widget-space rect from core geometry. `size` units are already natural units.
fn nat(x: i32, y: i32, w: i32, h: i32) dvui.Rect {
    return .{ .x = @floatFromInt(x), .y = @floatFromInt(y), .w = @floatFromInt(w), .h = @floatFromInt(h) };
}

fn natRect(r: ui.Rect) dvui.Rect {
    return nat(r.x, r.y, r.w, r.h);
}

/// An invisible region laid over a scene-painted control: the widget owns the tap, the scene owns
/// the pixels, and `ui.factionButton`/`ui.confirmButton` hand both the same rectangle so neither
/// can drift.
fn hitRegion(src: std.builtin.SourceLocation, r: ui.Rect) bool {
    var bx = dvui.box(src, .{}, .{ .rect = natRect(r), .background = false });
    defer bx.deinit();
    return dvui.clicked(bx.data(), .{});
}

/// The same, for the vow: true while the finger stays down on it.
fn holdRegion(src: std.builtin.SourceLocation, r: ui.Rect) bool {
    var bx = dvui.box(src, .{}, .{ .rect = natRect(r), .background = false });
    defer bx.deinit();
    _ = dvui.clicked(bx.data(), .{}); // processes the press/release that owns the capture
    return dvui.captured(bx.data().id);
}

// ─── THE DESIGN ───
// Glass over the field: every surface is a rounded slab of near-opaque dark with a real shadow
// and a whisper of border, floating over the live map. Controls are filled, not outlined; icons
// are glyphs, not words. This is the vocabulary the whole chrome layer speaks.

/// A card: the basic floating surface.
fn cardOpts() dvui.Options {
    return .{
        .expand = .horizontal,
        .padding = .{ .x = 16, .y = 14, .w = 16, .h = 14 },
        .background = true,
        .color_fill = toColor(ui.dim(.char_deep, 235)),
        .border = .all(1),
        .color_border = toColor(ui.dim(.bone, 22)),
        .corner_radius = .all(14),
        .box_shadow = .{ .color = .black, .offset = .{ .x = 0, .y = 5 }, .fade = 16, .alpha = 0.5 },
    };
}

/// A pill: fully rounded, used for the status capsule and the nav segments' home.
fn pillOpts() dvui.Options {
    return .{
        .padding = .{ .x = 14, .y = 8, .w = 14, .h = 8 },
        .background = true,
        .color_fill = toColor(ui.dim(.char_deep, 238)),
        .border = .all(1),
        .color_border = toColor(ui.dim(.bone, 22)),
        .corner_radius = .all(1000),
        .box_shadow = .{ .color = .black, .offset = .{ .x = 0, .y = 3 }, .fade = 10, .alpha = 0.45 },
    };
}

/// A glyph from the bundled Entypo set.
fn iconW(src: std.builtin.SourceLocation, bytes: []const u8, color: ui.Color, opts: dvui.Options) void {
    var o = opts;
    o.color_text = toColor(color);
    dvui.icon(src, "glyph", bytes, .{}, o);
}

fn labelW(src: std.builtin.SourceLocation, str: []const u8, weight: ui.Weight, color: ui.Color, opts: dvui.Options) void {
    var o = opts;
    o.font = fontFor(weight);
    o.color_text = toColor(color);
    // Our labels carry no padding of their own -- the layout supplies the spacing, and padding
    // shrinks the text's room inside its own rect, which is how lines get ellipsized.
    if (o.padding == null) o.padding = .{};
    dvui.labelNoFmt(src, str, .{}, o);
}

fn chrome(s: f32, size: ui.Size, arena: std.mem.Allocator) void {
    _ = s;
    const on_map = state.map_marker != null;
    switch (state.screen) {
        .choose_side => chooseChrome(size),
        .briefing => briefingChrome(size),
        .quiet => {
            if (on_map) {
                statusPill();
                quietSheet(size);
            } else {
                creditsTop(size);
            }
            navBar(size);
        },
        .gear => {
            gearScreen(size, arena);
            navBar(size);
        },
        .record => {
            recordScreen(size, arena);
            navBar(size);
        },
        .credits => creditsScreen(size),
        .live => if (on_map) {
            statusPill();
            liveBanner(size);
            liveSheet(size);
        } else {
            liveChrome(size);
        },
        .boot => {},
    }
}

/// THE CHOOSING, as input: two invisible regions over the painted futures, the vow region over the
/// painted bar, and the credit top-right. The paint is the scene's; the meaning is the widgets'.
fn chooseChrome(size: ui.Size) void {
    if (hitRegion(@src(), ui.factionButton(size, .human))) state = ui.act(state, .{ .arm = .human }, size);
    if (hitRegion(@src(), ui.factionButton(size, .zombie))) state = ui.act(state, .{ .arm = .zombie }, size);

    // The region reports its OWN edges -- a press it captured begins the hold, the release it saw
    // ends it. Never infer release from the state alone, or a hold begun another way (the scripted
    // driver, the touch path on the phone) would be cancelled by a finger that was never down.
    const held = holdRegion(@src(), ui.confirmButton(size));
    if (held and !vow_held) {
        vow_held = true;
        state = ui.act(state, .hold_begin, size);
    } else if (!held and vow_held) {
        vow_held = false;
        state = ui.act(state, .hold_release, size);
    }

    creditsTop(size);
}

var vow_held = false;

/// The credit, top-right -- a real clickable label, small and quiet, where the machine's name is.
fn creditsTop(size: ui.Size) void {
    var top = dvui.box(@src(), .{ .dir = .horizontal }, .{ .rect = nat(size.w - 172, 36, 150, 26), .background = false });
    defer top.deinit();
    if (dvui.labelClick(@src(), "Music: Tim Beek", .{}, .{}, .{
        .font = fontFor(.label),
        .color_text = toColor(.grave),
        .gravity_x = 1.0,
        .padding = .{},
    })) {
        state = ui.act(state, .credits_open, size);
    }
}

/// THE STATUS CAPSULE -- a floating glass pill carrying the faction mark, top-left. The map is
/// the screen; this is the only chrome that floats over it permanently.
fn statusPill() void {
    var pill = dvui.box(@src(), .{ .dir = .horizontal }, pillOpts().override(.{
        .rect = nat(12, 34, 132, 38),
        .gravity_y = 0.5,
    }));
    defer pill.deinit();
    const acc = ui.factionGlow(state.faction);
    iconW(@src(), dvui.entypo.location_pin, acc, .{ .min_size_content = .{ .h = 16 } });
    labelW(@src(), ui.factionLabel(state.faction), .label, .bone, .{ .margin = .{ .x = 8 } });
}

/// THE TAB BAR -- a segmented control floating over the map's lower edge: one glass pill, three
/// segments, the active one filled in the faction's colour. The toolkit owns hover and press.
fn navBar(size: ui.Size) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, pillOpts().override(.{
        .rect = nat(14, size.h - ui.nav_h - 6, size.w - 28, ui.nav_h - 10),
        .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
        .name = "nav",
    }));
    defer bar.deinit();

    const acc = ui.factionGlow(state.faction);
    const tabs = [_]struct { name: []const u8, scr: ui.Screen }{
        .{ .name = "HERE", .scr = .quiet },
        .{ .name = "GEAR", .scr = .gear },
        .{ .name = "RECORD", .scr = .record },
    };
    for (tabs, 0..) |t, i| {
        const active = state.screen == t.scr;
        if (dvui.button(@src(), t.name, .{}, .{
            .id_extra = i,
            // .both splits the pill into thirds; a non-edge gravity would turn the child into an
            // overlay and stack all three on top of each other.
            .expand = .both,
            .font = fontFor(.label),
            .color_text = if (active) toColor(.bone) else toColor(.dust),
            .color_text_hover = toColor(.bone),
            .color_fill = if (active) toColor(ui.dim(acc, 110)) else toColor(ui.dim(.char_deep, 0)),
            .color_fill_hover = toColor(ui.dim(acc, 60)),
            .color_fill_press = toColor(acc),
            .color_text_press = toColor(.void_black),
            .corner_radius = .all(1000),
        })) {
            state = ui.act(state, .{ .nav = t.scr }, size);
        }
    }
}

/// THE SHEET, quiet -- the reading floats over the map's lower edge, handle on top like the map
/// apps it sits beside. Top corners rounded; the bottom runs to the nav pill.
fn quietSheet(size: ui.Size) void {
    const sy = size.h - ui.nav_h - 190;
    var sheet = dvui.box(@src(), .{ .dir = .vertical }, .{
        .rect = nat(0, sy, size.w, 190),
        .padding = .{ .x = 22, .y = 10, .w = 22, .h = 16 },
        .background = true,
        .color_fill = toColor(ui.dim(.char_deep, 246)),
        .border = .all(1),
        .color_border = toColor(ui.dim(.bone, 20)),
        // {x=topleft, y=topright, w=botright, h=botleft} -- a sheet rounds only its top edge.
        .corner_radius = .{ .x = 20, .y = 20, .w = 0, .h = 0 },
        .box_shadow = .{ .color = .black, .offset = .{ .x = 0, .y = -4 }, .fade = 18, .alpha = 0.55 },
        .name = "sheet",
    });
    defer sheet.deinit();

    // The handle.
    var handle = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = 44, .h = 5 },
        .gravity_x = 0.5,
        .margin = .{ .y = 4 },
        .background = true,
        .color_fill = toColor(.ash),
        .corner_radius = .all(1000),
    });
    handle.deinit();

    const acc = ui.factionBright(state.faction);
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 10 }, .background = false });
    labelW(@src(), "QUIET", .heading, acc, .{});
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    // The condition, as a chip.
    var chip = dvui.box(@src(), .{}, .{
        .background = true,
        .color_fill = toColor(ui.dim(acc, 46)),
        .border = .all(1),
        .color_border = toColor(ui.dim(acc, 90)),
        .corner_radius = .all(1000),
        .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
    });
    labelW(@src(), ui.conditionWord(state.hp), .label, .bone, .{});
    chip.deinit();
    row.deinit();

    labelW(@src(), "The room is quiet.", .body, .smoke, .{ .margin = .{ .y = 6 } });
    labelW(@src(), "It won't stay that way.", .body, .grave, .{ .margin = .{ .y = 2 } });
}

/// THE BANNER, live -- the alarm card at the top of the map.
fn liveBanner(size: ui.Size) void {
    var card = dvui.box(@src(), .{ .dir = .vertical }, cardOpts().override(.{
        .rect = nat(10, 84, size.w - 20, 164),
        .color_fill = toColor(ui.dim(.char_deep, 240)),
        .color_border = toColor(ui.dim(.wound, 90)),
    }));
    defer card.deinit();

    var head = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
    iconW(@src(), dvui.entypo.warning, .wound, .{ .min_size_content = .{ .h = 20 } });
    labelW(@src(), "THIS CELL IS LIVE", .alarm, .wound, .{ .margin = .{ .x = 10 } });
    head.deinit();

    var crowd = std.mem.splitSequence(u8, ui.crowdSentence(state.crowd), ", ");
    const first = crowd.next().?;
    if (crowd.next()) |rest| {
        const joined = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s},", .{first}) catch first;
        labelW(@src(), joined, .body, .bone, .{ .margin = .{ .y = 10 } });
        labelW(@src(), rest, .body, .bone, .{});
    } else {
        labelW(@src(), first, .body, .bone, .{ .margin = .{ .y = 10 } });
    }
    labelW(@src(), ui.momentumSentence(state.momentum, state.faction orelse .human), .label, .serum, .{ .margin = .{ .y = 12 }, .gravity_x = 1.0 });
}

/// THE SHEET, live -- what you know, and the way out.
fn liveSheet(size: ui.Size) void {
    const sy = size.h - 268;
    var sheet = dvui.box(@src(), .{ .dir = .vertical }, .{
        .rect = nat(0, sy, size.w, 268),
        .padding = .{ .x = 22, .y = 10, .w = 22, .h = 26 },
        .background = true,
        .color_fill = toColor(ui.dim(.char_deep, 246)),
        .border = .all(1),
        .color_border = toColor(ui.dim(.bone, 20)),
        .corner_radius = .{ .x = 20, .y = 20, .w = 0, .h = 0 },
        .box_shadow = .{ .color = .black, .offset = .{ .x = 0, .y = -4 }, .fade = 18, .alpha = 0.55 },
        .name = "sheet_live",
    });
    defer sheet.deinit();

    var handle = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = 44, .h = 5 },
        .gravity_x = 0.5,
        .margin = .{ .y = 4 },
        .background = true,
        .color_fill = toColor(.ash),
        .corner_radius = .all(1000),
    });
    handle.deinit();

    labelW(@src(), "WHAT YOU KNOW", .label, .grave, .{ .margin = .{ .y = 8 } });
    var i: u8 = 0;
    while (i < state.tell_count) : (i += 1) {
        var parts = std.mem.splitSequence(u8, state.tells[i], ", ");
        const head_s = parts.next().?;
        labelW(@src(), head_s, .label, .smoke, .{ .margin = .{ .y = 2 }, .id_extra = i });
        if (parts.next()) |rest| {
            labelW(@src(), rest, .label, .smoke, .{ .margin = .{ .y = 0 }, .id_extra = i + 100 });
        }
    }

    _ = dvui.spacer(@src(), .{ .expand = .vertical });
    if (dvui.button(@src(), "WALK AWAY", .{}, .{
        .expand = .horizontal,
        .font = fontFor(.label),
        .padding = .{ .y = 14 },
        .margin = .{ .y = 6 },
        .color_fill = toColor(ui.dim(.ash, 90)),
        .color_fill_hover = toColor(.ash),
        .color_fill_press = toColor(.wound),
        .color_text = toColor(.bone),
        .border = .all(1),
        .color_border = toColor(.ash),
        .corner_radius = .all(12),
    })) {
        state = ui.act(state, .leave_live, size);
    }
}

/// THE BRIEFING -- the three pages the machine hands you on the way out of the flood.
fn briefingChrome(size: ui.Size) void {
    const faction = state.faction;
    const page = ui.briefing_pages[@min(state.brief_page, ui.briefing_pages.len - 1)];

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{
        .rect = nat(0, 0, size.w, size.h),
        .padding = .{ .x = 18, .y = 40, .w = 18, .h = 40 },
        .background = false,
    });
    defer outer.deinit();

    var head = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    labelW(@src(), "FIELD BRIEFING", .label, .grave, .{});
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    labelW(@src(), ui.factionLabel(faction), .label, ui.factionGlow(faction), .{});
    head.deinit();

    _ = dvui.spacer(@src(), .{ .expand = .vertical });

    // The page itself, as a card the machine hands you.
    var card = dvui.box(@src(), .{ .dir = .vertical }, cardOpts());
    {
        var lw: dvui.LabelWidget = undefined;
        lw.initNoFmt(@src(), page.head, .{}, .{
            .font = fontFor(.heading).withSize(19),
            .color_text = toColor(ui.factionBright(faction)),
            .margin = .{ .y = 8 },
        });
        lw.draw();
        lw.deinit();
    }
    for (page.lines, 0..) |l, i| {
        labelW(@src(), l, .body, .smoke, .{ .margin = .{ .y = 3 }, .id_extra = i });
    }
    card.deinit();

    _ = dvui.spacer(@src(), .{ .expand = .vertical });

    // Where you are in it -- dots now, not hairlines.
    var ticks = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_x = 0.5, .margin = .{ .y = 14 } });
    var i: u8 = 0;
    while (i < ui.briefing_pages.len) : (i += 1) {
        var dot = dvui.box(@src(), .{}, .{
            .id_extra = i,
            .min_size_content = .{ .w = if (i == state.brief_page) 22 else 8, .h = 8 },
            .background = true,
            .color_fill = toColor(if (i == state.brief_page) ui.factionGlow(faction) else .ash),
            .corner_radius = .all(1000),
            .margin = .{ .x = 4 },
        });
        dot.deinit();
    }
    ticks.deinit();

    const last = state.brief_page == ui.briefing_pages.len - 1;
    if (dvui.button(@src(), if (last) "TO THE FIELD" else "CONTINUE", .{}, .{
        .expand = .horizontal,
        .font = fontFor(.label),
        .padding = .{ .y = 16 },
        .color_fill = toColor(ui.factionDeep(faction)),
        .color_fill_hover = toColor(ui.factionGlow(faction)),
        .color_fill_press = toColor(ui.factionBright(faction)),
        .color_text = toColor(.bone),
        .color_text_press = toColor(.void_black),
        .corner_radius = .all(12),
        .box_shadow = .{ .color = .black, .offset = .{ .x = 0, .y = 3 }, .fade = 10, .alpha = 0.4 },
    })) {
        state = ui.act(state, .brief_next, size);
    }
}

/// GEAR -- what you carry, and what you could carry instead. A scrollable manifest of real rows.
fn gearScreen(size: ui.Size, arena: std.mem.Allocator) void {
    const faction = state.faction;
    const acc = ui.factionGlow(faction);

    var page = dvui.box(@src(), .{ .dir = .vertical }, .{
        .rect = nat(0, 0, size.w, size.h - ui.nav_h),
        .padding = .{ .x = 22, .y = 40, .w = 22, .h = 10 },
        .background = false,
    });
    defer page.deinit();

    var head = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    labelW(@src(), ui.factionLabel(faction), .label, .smoke, .{});
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    labelW(@src(), "GEAR", .label, .dust, .{});
    head.deinit();

    labelW(@src(), "CARRIED", .label, .dust, .{ .margin = .{ .y = 18 } });
    _ = dvui.separator(@src(), .{ .expand = .horizontal, .color_fill = toColor(.grave) });

    const slots = [_]struct { label: []const u8, id: loadout.ItemId }{
        .{ .label = "WEAPON", .id = state.equipped.weapon },
        .{ .label = "ARMOR", .id = state.equipped.armor },
        .{ .label = "UTILITY", .id = state.equipped.utility },
    };
    const slot_glyph = [_][]const u8{ dvui.entypo.hair_cross, dvui.entypo.shield, dvui.entypo.radio };
    for (slots, 0..) |slot, i| {
        const def = loadout.definition(slot.id);
        var row = dvui.box(@src(), .{ .dir = .horizontal }, cardOpts().override(.{ .id_extra = i, .margin = .{ .y = 5 } }));
        iconW(@src(), slot_glyph[i], ui.dim(acc, 200), .{ .min_size_content = .{ .h = 20 } });
        labelW(@src(), slot.label, .label, .grave, .{ .min_size_content = .{ .w = 70 }, .margin = .{ .x = 12 } });
        var mid = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false });
        labelW(@src(), def.name, .body, .bone, .{});
        const st = std.fmt.allocPrint(arena, "ATK {d}  DEF {d}  INI {d}", .{ def.attack, def.defense, def.initiative }) catch "";
        labelW(@src(), st, .label, ui.dim(acc, 200), .{ .margin = .{ .y = 2 } });
        mid.deinit();
        row.deinit();
    }

    var inv_head = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 16 } });
    labelW(@src(), "INVENTORY", .label, .dust, .{});
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    const cap = std.fmt.allocPrint(arena, "{d} / {d}", .{ loadout.equipmentCount(state.owned), state.inventory_capacity }) catch "";
    labelW(@src(), cap, .label, .grave, .{});
    inv_head.deinit();
    _ = dvui.separator(@src(), .{ .expand = .horizontal, .color_fill = toColor(.grave) });

    // The stock, scrollable. A row is a button -- a tap asks to carry it.
    var scroller = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroller.deinit();

    for (loadout.catalogue, 0..) |def, i| {
        if (def.slot == .evidence or !loadout.owns(state.owned, def.id)) continue;
        const carried = (def.slot == .weapon and state.equipped.weapon == def.id) or
            (def.slot == .armor and state.equipped.armor == def.id) or
            (def.slot == .utility and state.equipped.utility == def.id);

        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{}, .{
            .id_extra = i,
            .expand = .horizontal,
            .margin = .{ .y = 5 },
            .padding = .{ .x = 14, .y = 12, .w = 14, .h = 12 },
            .color_fill = toColor(ui.dim(.char_deep, 235)),
            .color_fill_hover = toColor(.ash),
            .color_fill_press = toColor(ui.factionDeep(faction)),
            .border = .all(1),
            .color_border = toColor(ui.dim(.bone, 22)),
            .corner_radius = .all(14),
            .box_shadow = .{ .color = .black, .offset = .{ .x = 0, .y = 4 }, .fade = 12, .alpha = 0.4 },
        });
        defer bw.deinit();
        bw.processEvents();
        bw.drawBackground();
        const clicked = bw.clicked();

        var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .background = false });
        var namerow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false });
        iconW(@src(), switch (def.slot) {
            .weapon => dvui.entypo.hair_cross,
            .armor => dvui.entypo.shield,
            .utility => dvui.entypo.radio,
            .evidence => dvui.entypo.tag,
        }, ui.dim(acc, 160), .{ .min_size_content = .{ .h = 15 }, .margin = .{ .w = 8 } });
        labelW(@src(), def.name, .body, if (carried) .bone else ui.rarityColor(def.rarity), .{});
        if (carried) {
            labelW(@src(), "· CARRIED", .label, acc, .{ .margin = .{ .x = 10 } });
        }
        namerow.deinit();
        const det = std.fmt.allocPrint(arena, "{s} · {s} · ATK {d} DEF {d} INI {d}", .{ ui.slotLabel(def.slot), ui.rarityLabel(def.rarity), def.attack, def.defense, def.initiative }) catch "";
        labelW(@src(), det, .label, .grave, .{});
        col.deinit();
        if (clicked) state = ui.act(state, .{ .equip = def.id }, size);
    }
}

/// RECORD -- what the war has done to you, and what it left behind.
fn recordScreen(size: ui.Size, arena: std.mem.Allocator) void {
    const faction = state.faction;
    const acc = ui.factionGlow(faction);

    var page = dvui.box(@src(), .{ .dir = .vertical }, .{
        .rect = nat(0, 0, size.w, size.h - ui.nav_h),
        .padding = .{ .x = 22, .y = 40, .w = 22, .h = 10 },
        .background = false,
    });
    defer page.deinit();

    var head = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    labelW(@src(), ui.factionLabel(faction), .label, .smoke, .{});
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    labelW(@src(), "RECORD", .label, .dust, .{});
    head.deinit();

    labelW(@src(), "THE WAR, AS WRITTEN.", .heading, .bone, .{ .margin = .{ .y = 22 } });

    const card = cardOpts();

    var stats = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 8 }, .background = false });
    var left = dvui.box(@src(), .{ .dir = .vertical }, card.override(.{ .margin = .{ .w = 4 } }));
    labelW(@src(), "STANDING", .label, acc, .{});
    const lvl = std.fmt.allocPrint(arena, "LVL {d} · {d} XP", .{ state.level, state.total_xp }) catch "";
    labelW(@src(), lvl, .body, .bone, .{});
    left.deinit();
    var right = dvui.box(@src(), .{ .dir = .vertical }, card.override(.{ .margin = .{ .x = 4 } }));
    labelW(@src(), "CONDITION", .label, .grave, .{});
    labelW(@src(), ui.conditionWord(state.hp), .body, .bone, .{});
    right.deinit();
    stats.deinit();

    labelW(@src(), "LAST CONTACT", .label, .dust, .{ .margin = .{ .y = 14 } });
    var contact = dvui.box(@src(), .{ .dir = .vertical }, card);
    if (state.encounter_xp > 0 or state.last_reward != .none) {
        const src = if (state.encounter_source == .players) "the other side" else "the field";
        const line1 = std.fmt.allocPrint(arena, "Contact with {s}.", .{src}) catch "";
        const line2 = std.fmt.allocPrint(arena, "+{d} XP · {s}", .{ state.encounter_xp, ui.rewardLabel(state.last_reward) }) catch "";
        labelW(@src(), line1, .body, .bone, .{});
        labelW(@src(), line2, .body, .serum, .{ .margin = .{ .y = 4 } });
    } else {
        labelW(@src(), "Nothing has found you yet.", .body, .smoke, .{});
        labelW(@src(), "Stay where it can find you.", .body, .grave, .{ .margin = .{ .y = 4 } });
    }
    contact.deinit();

    labelW(@src(), "RECOVERED", .label, .dust, .{ .margin = .{ .y = 14 } });
    var shown: u8 = 0;
    for (loadout.catalogue, 0..) |def, i| {
        if (def.slot != .evidence or !loadout.owns(state.owned, def.id)) continue;
        var row = dvui.box(@src(), .{ .dir = .horizontal }, card.override(.{ .id_extra = i, .margin = .{ .y = 4 } }));
        labelW(@src(), def.name, .body, ui.rarityColor(def.rarity), .{});
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (state.last_item == @intFromEnum(def.id) and state.item_discovered) {
            labelW(@src(), "NEW", .label, acc, .{});
        }
        row.deinit();
        shown += 1;
    }
    if (shown == 0) {
        var empty = dvui.box(@src(), .{ .dir = .vertical }, card);
        labelW(@src(), "Nothing recovered yet.", .body, .grave, .{});
        empty.deinit();
    }
}

/// THE CREDITS, as widgets -- the licences require the names to reach the person using the work.
fn creditsScreen(size: ui.Size) void {
    var page = dvui.box(@src(), .{ .dir = .vertical }, .{
        .rect = nat(0, 0, size.w, size.h),
        .padding = .{ .x = 22, .y = 40, .w = 22, .h = 40 },
        .background = false,
    });
    defer page.deinit();

    labelW(@src(), "CREDITS", .label, .dust, .{ .margin = .{ .y = 20 } });

    labelW(@src(), ui.credits.music_head, .heading, .bone, .{ .margin = .{ .y = 12 } });
    labelW(@src(), ui.credits.music_title, .body, .smoke, .{});
    labelW(@src(), ui.credits.music_author, .body, .bone, .{});
    labelW(@src(), ui.credits.music_site, .body, .dust, .{});
    labelW(@src(), ui.credits.music_licence, .body, .dust, .{});
    labelW(@src(), ui.credits.music_modified, .body, .dust, .{});

    labelW(@src(), ui.credits.type_head, .heading, .bone, .{ .margin = .{ .y = 28 } });
    labelW(@src(), ui.credits.font_oxanium, .body, .smoke, .{});
    labelW(@src(), ui.credits.font_inter, .body, .smoke, .{});
    labelW(@src(), ui.credits.font_licence, .body, .dust, .{});

    _ = dvui.spacer(@src(), .{ .expand = .vertical });
    if (dvui.button(@src(), "BACK", .{}, .{
        .expand = .horizontal,
        .font = fontFor(.label),
        .padding = .{ .y = 16 },
        .color_fill = toColor(.carrion),
        .color_fill_hover = toColor(.ash),
        .color_text = toColor(.bone),
        .corner_radius = .all(0),
    })) {
        state = ui.act(state, .credits_back, size);
    }
}

/// LIVE gets one control: the way out. The fight resolves whether you watch or not.
fn liveChrome(size: ui.Size) void {
    var foot = dvui.box(@src(), .{ .dir = .horizontal }, .{ .rect = nat(22, size.h - 64, 160, 44), .background = false });
    defer foot.deinit();
    if (dvui.button(@src(), "WALK AWAY", .{}, .{
        .expand = .both,
        .font = fontFor(.label),
        .gravity_x = 0.5, .gravity_y = 0.5,
        .color_fill = toColor(.void_black),
        .color_fill_hover = toColor(.clot),
        .color_text = toColor(.smoke),
        .color_text_hover = toColor(.bone),
        .corner_radius = .all(0),
        .border = .all(1),
        .color_border = toColor(.grave),
    })) {
        state = ui.act(state, .leave_live, size);
    }
}

fn drawOp(op: ui.Draw, s: f32) void {
    if (only_op) |only| if (!std.mem.eql(u8, @tagName(op), only)) return;
    if (dump_ops) switch (op) {
        .rect => |r| std.debug.print("  rect {d},{d} {d}x{d} #{x:0>8}\n", .{ r.x, r.y, r.w, r.h, @intFromEnum(r.color) }),
        .text => |t| std.debug.print("  text {d},{d} burn={d} #{x:0>8} \"{s}\"\n", .{ t.x, t.y, t.burn, @intFromEnum(t.color), t.text }),
        .sprite => |sp| std.debug.print("  sprite {s} {d},{d} {d}x{d} a={d} #{x:0>8}\n", .{ @tagName(sp.sprite), sp.x, sp.y, sp.w, sp.h, sp.angle, @intFromEnum(sp.color) }),
    };
    switch (op) {
        .rect => |r| {
            var b = dvui.Path.Builder.init(dvui.currentWindow().arena());
            defer b.deinit();
            b.addRect(.{
                .x = @as(f32, @floatFromInt(r.x)) * s,
                .y = @as(f32, @floatFromInt(r.y)) * s,
                .w = @as(f32, @floatFromInt(r.w)) * s,
                .h = @as(f32, @floatFromInt(r.h)) * s,
            }, .{});
            b.build().fillConvex(.{ .color = toColor(r.color) });
        },
        .sprite => |sp| {
            dvui.renderTexture(sprites[@intFromEnum(sp.sprite)], .{
                .r = .{
                    .x = @as(f32, @floatFromInt(sp.x)) * s,
                    .y = @as(f32, @floatFromInt(sp.y)) * s,
                    .w = @as(f32, @floatFromInt(sp.w)) * s,
                    .h = @as(f32, @floatFromInt(sp.h)) * s,
                },
                .s = s,
            }, .{
                .rotation = @as(f32, @floatFromInt(sp.angle)) * (std.math.tau / 65536.0),
                .colormod = toColor(sp.color),
            }) catch {};
        },
        .text => |t| drawText(t, s),
    }
}

fn drawText(t: anytype, s: f32) void {
    const font = fontFor(t.weight);
    const measured = font.textSize(t.text);

    var x: f32 = @as(f32, @floatFromInt(t.x)) * s;
    switch (t.alignment) {
        .left => {},
        .center => x -= measured.w * s / 2.0,
        .right => x -= measured.w * s,
    }

    // Burn-in: the core cannot measure a string, so it says how far through arriving the line is
    // and we clip at that fraction of the measured width. Hot-edge glow is polish for later.
    const clip_w = measured.w * s * @as(f32, @floatFromInt(t.burn)) / 255.0;
    const clip = dvui.Rect.Physical{ .x = 0, .y = 0, .w = x + clip_w, .h = win.rectScale().r.h };

    dvui.renderText(.{
        .font = font,
        .text = t.text,
        .rs = .{ .r = clip, .s = s },
        .p = .{ .x = x, .y = @as(f32, @floatFromInt(t.y)) * s },
        .color = toColor(t.color),
    }) catch {};
}

fn fontFor(weight: ui.Weight) dvui.Font {
    return switch (weight) {
        .label => dvui.Font.find(.{ .family = "Oxanium SemiBold", .size = 13 }),
        .body => dvui.Font.find(.{ .family = "Inter", .size = 17 }),
        .heading => dvui.Font.find(.{ .family = "Oxanium Bold", .size = 22 }),
        .alarm => dvui.Font.find(.{ .family = "Oxanium ExtraBold", .size = 22 }),
        .wordmark => dvui.Font.find(.{ .family = "Oxanium ExtraBold", .size = 64 }),
    };
}

/// ui.Color packs RGBA into a u32, R in the top byte.
fn toColor(c: ui.Color) dvui.Color {
    const v = @intFromEnum(c);
    return .{
        .r = @intCast((v >> 24) & 0xff),
        .g = @intCast((v >> 16) & 0xff),
        .b = @intCast((v >> 8) & 0xff),
        .a = @intCast(v & 0xff),
    };
}

fn bakeSprites() !void {
    sprites[@intFromEnum(ui.Sprite.disc)] = try bake(64, discCoverage);
    sprites[@intFromEnum(ui.Sprite.vignette)] = try bake(128, vignetteCoverage);
    sprites[@intFromEnum(ui.Sprite.ring)] = try bake(128, annulusCoverage);
    sprites[@intFromEnum(ui.Sprite.beam)] = try bake(128, beamCoverage);
}

fn bake(dim: u32, comptime coverage: fn (f32, f32) u8) !dvui.Texture {
    var pixels: [128 * 128 * 4]u8 = undefined;
    const half: f32 = @as(f32, @floatFromInt(dim)) / 2.0;
    var row: u32 = 0;
    while (row < dim) : (row += 1) {
        var col: u32 = 0;
        while (col < dim) : (col += 1) {
            const dx = (@as(f32, @floatFromInt(col)) + 0.5 - half) / half;
            const dy = (@as(f32, @floatFromInt(row)) + 0.5 - half) / half;
            const a = coverage(dx, dy);
            const i = (row * dim + col) * 4;
            // Premultiplied: DVUI blends PMA, so the coverage lives in all four channels.
            pixels[i] = a;
            pixels[i + 1] = a;
            pixels[i + 2] = a;
            pixels[i + 3] = a;
        }
    }
    // Not backend.textureCreate: that route goes through SDL_CreateTextureFromSurface, which
    // flattens alpha and turns every sprite's transparent rim into an opaque square.
    const c = SDLBackend.c;
    const tex = c.SDL_CreateTexture(backend.renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, @intCast(dim), @intCast(dim)) orelse {
        dvui.log.err("sprite bake: SDL_CreateTexture failed: {s}", .{c.SDL_GetError()});
        return error.TextureCreate;
    };
    errdefer c.SDL_DestroyTexture(tex);
    if (!c.SDL_UpdateTexture(tex, null, &pixels, @intCast(dim * 4)))
        dvui.log.err("sprite bake: SDL_UpdateTexture failed: {s}", .{c.SDL_GetError()});
    _ = c.SDL_SetTextureScaleMode(tex, c.SDL_SCALEMODE_LINEAR);
    const pma = c.SDL_ComposeCustomBlendMode(c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD, c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD);
    if (!c.SDL_SetTextureBlendMode(tex, pma))
        dvui.log.err("sprite bake: SDL_SetTextureBlendMode failed: {s}", .{c.SDL_GetError()});
    return dvui.Texture{ .ptr = tex, .width = dim, .height = dim, .format = .rgba_32 };
}

// The four coverage functions, recovered verbatim from the deleted render/atlas.zig.

fn discCoverage(dx: f32, dy: f32) u8 {
    const r = @sqrt(dx * dx + dy * dy);
    if (r >= 1.0) return 0;
    const t = 1.0 - r;
    const smooth = t * t * (3.0 - 2.0 * t);
    return @intFromFloat(@round(smooth * 255.0));
}

fn vignetteCoverage(dx: f32, dy: f32) u8 {
    const r = @sqrt(dx * dx + dy * dy);
    if (r >= 1.0) return 255;
    const smooth = r * r * (3.0 - 2.0 * r);
    return @intFromFloat(@round(smooth * 255.0));
}

fn annulusCoverage(dx: f32, dy: f32) u8 {
    const r = @sqrt(dx * dx + dy * dy);
    const r0: f32 = 0.92;
    const half_w: f32 = 0.09;
    const d = @abs(r - r0);
    if (d >= half_w) return 0;
    const t = 1.0 - d / half_w;
    const smooth = t * t * (3.0 - 2.0 * t);
    return @intFromFloat(@round(smooth * 255.0));
}

fn beamCoverage(dx: f32, dy: f32) u8 {
    const r = @sqrt(dx * dx + dy * dy);
    if (r >= 1.0 or r < 0.06) return 0;

    const ang = std.math.atan2(dy, dx); // -pi .. pi
    const lead: f32 = 0.05;
    const wake: f32 = 2.1;
    if (ang > lead or ang < -wake) return 0;

    const along = if (ang >= 0.0) 1.0 else 1.0 - (-ang) / wake;
    const glow = along * along * along;
    const radial = if (r > 0.94) (1.0 - r) / 0.06 else 0.35 + 0.65 * r;

    return @intFromFloat(@max(0.0, @min(255.0, glow * radial * 255.0)));
}
