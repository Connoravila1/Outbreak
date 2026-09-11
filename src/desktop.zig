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

pub fn main(init: std.process.Init) !void {
    io = init.io;
    init_gpa = init.gpa;
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
        .quiet => if (ms -| last_nav_tap > 2500 and nav_leg == 0) {
            last_nav_tap = ms;
            nav_leg = 1;
            state = ui.act(state, .{ .nav = .gear }, size);
        } else if (ms -| last_nav_tap > 2500 and nav_leg == 3) {
            // One more look: the credits, then done touring.
            last_nav_tap = ms;
            nav_leg = 4;
            state = ui.act(state, .credits_open, size);
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

    // THE SCENE FIRST -- the bespoke painting (boot, the choosing, the well) underneath whatever
    // chrome the widgets draw. Then the widgets: structure, layout, and events the toolkit owns.
    var out: std.ArrayList(ui.Draw) = .empty;
    ui.draw(state, size, .{}, &out, arena) catch return true;
    for (out.items) |op| drawOp(op, s);

    chrome(s, size, arena);

    // Scene-level input the widget layer does not own: the boot's tap-anywhere and the dial's
    // ripple. Only events no widget claimed -- a tap on a button is not also a tap on the dial.
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        switch (e.evt) {
            .mouse => |m| {
                const at: ui.Touch = .{
                    .x = @intFromFloat(@round(m.p.x / s)),
                    .y = @intFromFloat(@round(m.p.y / s)),
                };
                if (m.action == .press and m.button == .left) switch (state.screen) {
                    .boot => state = ui.act(state, .enter, size),
                    .quiet => state = ui.act(state, .{ .dial = at }, size),
                    else => {},
                };
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
    switch (state.screen) {
        .choose_side => chooseChrome(size),
        .briefing => briefingChrome(size),
        .quiet => {
            creditsTop(size);
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
        .live => liveChrome(size),
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

/// THE TAB BAR -- three real buttons on a hairline-edged strip. The toolkit owns the hover, the
/// press, the thirds.
fn navBar(size: ui.Size) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .rect = nat(0, size.h - ui.nav_h, size.w, ui.nav_h),
        .background = true,
        .color_fill = toColor(.char_deep),
        .padding = .{},
        .name = "nav",
    });
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
            // .both splits the bar into thirds; a non-edge gravity would turn the child into an
            // overlay and stack all three on top of each other.
            .expand = .both,
            .font = fontFor(.label),
            .color_text = if (active) toColor(.bone) else toColor(.dust),
            .color_fill = toColor(.char_deep),
            .color_fill_hover = toColor(.ash),
            .color_fill_press = toColor(acc),
            .color_text_press = toColor(.void_black),
            .corner_radius = .all(0),
        })) {
            state = ui.act(state, .{ .nav = t.scr }, size);
        }
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
        labelW(@src(), l, .body, .smoke, .{ .margin = .{ .y = 2 }, .id_extra = i });
    }

    _ = dvui.spacer(@src(), .{ .expand = .vertical });

    // Where you are in it -- a hairline of ticks.
    var ticks = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_x = 0.5, .margin = .{ .y = 10 } });
    var i: u8 = 0;
    while (i < ui.briefing_pages.len) : (i += 1) {
        _ = dvui.separator(@src(), .{
            .id_extra = i,
            .min_size_content = .{ .w = 40, .h = 2 },
            .color_fill = toColor(if (i == state.brief_page) ui.factionGlow(faction) else .grave),
            .margin = .{ .x = 4 },
        });
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
        .corner_radius = .all(0),
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
    for (slots, 0..) |slot, i| {
        const def = loadout.definition(slot.id);
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .horizontal, .padding = .{ .y = 10 } });
        labelW(@src(), slot.label, .label, .grave, .{ .min_size_content = .{ .w = 76 } });
        var mid = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
        labelW(@src(), def.name, .body, .bone, .{});
        const st = std.fmt.allocPrint(arena, "ATK {d}  DEF {d}  INI {d}", .{ def.attack, def.defense, def.initiative }) catch "";
        labelW(@src(), st, .label, ui.dim(acc, 200), .{});
        mid.deinit();
        row.deinit();
        _ = dvui.separator(@src(), .{ .id_extra = i, .expand = .horizontal, .color_fill = toColor(.ash) });
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
            .padding = .{ .y = 10 },
            .color_fill = toColor(.void_black),
            .color_fill_hover = toColor(.ash),
            .color_fill_press = toColor(ui.factionDeep(faction)),
            .corner_radius = .all(0),
        });
        defer bw.deinit();
        bw.processEvents();
        bw.drawBackground();
        const clicked = bw.clicked();

        var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .background = false });
        var namerow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false });
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

    var stats = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 8 } });
    var left = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false });
    labelW(@src(), "STANDING", .label, acc, .{});
    const lvl = std.fmt.allocPrint(arena, "LVL {d} · {d} XP", .{ state.level, state.total_xp }) catch "";
    labelW(@src(), lvl, .body, .bone, .{});
    left.deinit();
    var right = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false });
    labelW(@src(), "CONDITION", .label, .grave, .{});
    labelW(@src(), ui.conditionWord(state.hp), .body, .bone, .{});
    right.deinit();
    stats.deinit();

    _ = dvui.separator(@src(), .{ .expand = .horizontal, .color_fill = toColor(.grave), .margin = .{ .y = 14 } });
    labelW(@src(), "LAST CONTACT", .label, .dust, .{});
    if (state.encounter_xp > 0 or state.last_reward != .none) {
        const src = if (state.encounter_source == .players) "the other side" else "the field";
        const line1 = std.fmt.allocPrint(arena, "Contact with {s}.", .{src}) catch "";
        const line2 = std.fmt.allocPrint(arena, "+{d} XP · {s}", .{ state.encounter_xp, ui.rewardLabel(state.last_reward) }) catch "";
        labelW(@src(), line1, .body, .bone, .{ .margin = .{ .y = 8 } });
        labelW(@src(), line2, .body, .serum, .{});
    } else {
        labelW(@src(), "Nothing has found you yet.", .body, .smoke, .{ .margin = .{ .y = 8 } });
        labelW(@src(), "Stay where it can find you.", .body, .grave, .{});
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal, .color_fill = toColor(.grave), .margin = .{ .y = 14 } });
    labelW(@src(), "RECOVERED", .label, .dust, .{});
    var shown: u8 = 0;
    for (loadout.catalogue, 0..) |def, i| {
        if (def.slot != .evidence or !loadout.owns(state.owned, def.id)) continue;
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .horizontal, .padding = .{ .y = 6 } });
        labelW(@src(), def.name, .body, ui.rarityColor(def.rarity), .{});
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (state.last_item == @intFromEnum(def.id) and state.item_discovered) {
            labelW(@src(), "NEW", .label, acc, .{});
        }
        row.deinit();
        shown += 1;
    }
    if (shown == 0) {
        labelW(@src(), "Nothing recovered yet.", .body, .grave, .{ .margin = .{ .y = 8 } });
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
