//! SHELL (B1, B3). The Android host. THERE IS NO KOTLIN.
//!
//! With `android:hasCode="false"` in the manifest, the framework's `NativeActivity` loads this
//! library and calls `ANativeActivity_onCreate` below. No JVM class of ours is ever written, and
//! no Java is ever compiled. The OS gives us a window, an input queue, and a lifecycle; we give
//! it pixels.
//!
//! ============================================================================
//! THE ONE CONTRACT THAT MATTERS: THREADING
//!
//! The framework invokes EVERY callback on the process MAIN thread, which belongs to the OS.
//! Nothing heavy may run there -- block it and Android kills us.
//!
//! So all real work lives on ONE render thread that this file owns. It attaches the EGL surface,
//! drains input, runs the game, and draws. The callbacks do nothing but flip mutex-guarded state
//! and return immediately.
//!
//! The single ordering rule Android actually enforces: after `onNativeWindowDestroyed` returns,
//! the window is GONE and touching it is a use-after-free. So that callback BLOCKS until the
//! render thread has confirmed it has let go.
//!
//! ============================================================================
//! THE NDK ABI IS DECLARED HERE, AND ONLY HERE (D3)
//!
//! No NDK headers, no generated bindings, no dependency (F1). The handful of structs and
//! functions we actually use are declared locally, and they do not appear in any other module's
//! signatures. If Android changes, this file changes and nothing else does.
//!
//! ============================================================================
//! AND THE LINE THAT MATTERS MORE THAN ANY OTHER IN THIS FILE
//!
//! The GPS callback lives in `location.zig` (M.5). It receives a latitude and a longitude, calls
//! the quantizer, takes the u64, and DROPS THE FLOATS IN THE SAME FUNCTION. Not stored, not cached,
//! not logged, not put in a crash report.
//!
//! The server has no coordinate and structurally cannot leak one -- the build fails if a float
//! appears in the core. THE PHONE IS THEREFORE THE ONLY PLACE A COORDINATE EVER EXISTS, which makes
//! it the only place one can leak from. No guard can enforce this on the platform side. It is
//! discipline, and it lives in the header of location.zig so the next person reads it first.
//!
//! There is one JVM class now (`OutbreakService`), because Android has no native location API and a
//! backgrounded app needs a foreground service to keep the radio alive (M.6). It holds no
//! coordinate. It is the whole of the Java in this project.

const std = @import("std");
const ui = @import("ui.zig");
const quads = @import("render/quads.zig");
const gles = @import("render/gles.zig");
const text = @import("render/text.zig");
const atlas_mod = @import("render/atlas.zig");
const location = @import("location.zig");
const client = @import("client.zig");
const flags = @import("flags");

const Io = std.Io;

// ============================================================================ the NDK, locally

const ANativeWindow = opaque {};
const AInputQueue = opaque {};
const AInputEvent = opaque {};
const ALooper = opaque {};
const AAssetManager = opaque {};

const ANativeActivity = extern struct {
    callbacks: *ANativeActivityCallbacks,
    vm: ?*anyopaque,
    env: ?*anyopaque,
    class: ?*anyopaque,
    internalDataPath: [*:0]const u8,
    externalDataPath: [*:0]const u8,
    sdkVersion: i32,
    instance: ?*anyopaque,
    assetManager: ?*AAssetManager,
    obbPath: [*:0]const u8,
};

const ANativeActivityCallbacks = extern struct {
    onStart: ?*const fn (*ANativeActivity) callconv(.c) void,
    onResume: ?*const fn (*ANativeActivity) callconv(.c) void,
    onSaveInstanceState: ?*const fn (*ANativeActivity, *usize) callconv(.c) ?*anyopaque,
    onPause: ?*const fn (*ANativeActivity) callconv(.c) void,
    onStop: ?*const fn (*ANativeActivity) callconv(.c) void,
    onDestroy: ?*const fn (*ANativeActivity) callconv(.c) void,
    onWindowFocusChanged: ?*const fn (*ANativeActivity, i32) callconv(.c) void,
    onNativeWindowCreated: ?*const fn (*ANativeActivity, *ANativeWindow) callconv(.c) void,
    onNativeWindowResized: ?*const fn (*ANativeActivity, *ANativeWindow) callconv(.c) void,
    onNativeWindowRedrawNeeded: ?*const fn (*ANativeActivity, *ANativeWindow) callconv(.c) void,
    onNativeWindowDestroyed: ?*const fn (*ANativeActivity, *ANativeWindow) callconv(.c) void,
    onInputQueueCreated: ?*const fn (*ANativeActivity, *AInputQueue) callconv(.c) void,
    onInputQueueDestroyed: ?*const fn (*ANativeActivity, *AInputQueue) callconv(.c) void,
    onContentRectChanged: ?*const fn (*ANativeActivity, *const ARect) callconv(.c) void,
    onConfigurationChanged: ?*const fn (*ANativeActivity) callconv(.c) void,
    onLowMemory: ?*const fn (*ANativeActivity) callconv(.c) void,
};

const ARect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

extern fn ANativeWindow_getWidth(*ANativeWindow) i32;
extern fn ANativeWindow_getHeight(*ANativeWindow) i32;
extern fn ANativeWindow_setBuffersGeometry(*ANativeWindow, i32, i32, i32) i32;

extern fn ALooper_prepare(i32) ?*ALooper;
extern fn ALooper_pollOnce(i32, ?*i32, ?*i32, ?*?*anyopaque) i32;

const AConfiguration = opaque {};
extern fn AConfiguration_new() ?*AConfiguration;
extern fn AConfiguration_fromAssetManager(*AConfiguration, *AAssetManager) void;
extern fn AConfiguration_getDensity(*AConfiguration) i32;
extern fn AConfiguration_delete(*AConfiguration) void;

/// Android's baseline density. 160 dots per inch is 1 dp = 1 px, by definition, and every other
/// density is expressed as a multiple of it.
const baseline_density: i32 = 160;

/// The density Android reports when it does not know, and when it has not been set.
const density_unknown: i32 = 0;
const density_any: i32 = 0xfffe;
const density_none: i32 = 0xffff;

extern fn AInputQueue_attachLooper(*AInputQueue, *ALooper, i32, ?*anyopaque, ?*anyopaque) void;
extern fn AInputQueue_detachLooper(*AInputQueue) void;
extern fn AInputQueue_getEvent(*AInputQueue, *?*AInputEvent) i32;
extern fn AInputQueue_preDispatchEvent(*AInputQueue, *AInputEvent) i32;
extern fn AInputQueue_finishEvent(*AInputQueue, *AInputEvent, i32) void;

extern fn AInputEvent_getType(*const AInputEvent) i32;
extern fn AMotionEvent_getAction(*const AInputEvent) i32;
extern fn AMotionEvent_getX(*const AInputEvent, usize) f32;
extern fn AMotionEvent_getY(*const AInputEvent, usize) f32;

const input_event_type_motion: i32 = 2;
const motion_action_mask: i32 = 0xff;
const motion_action_up: i32 = 1;

// ============================================================================ EGL, locally

const EGLDisplay = ?*anyopaque;
const EGLSurface = ?*anyopaque;
const EGLContext = ?*anyopaque;
const EGLConfig = ?*anyopaque;

extern fn eglGetDisplay(?*anyopaque) EGLDisplay;
extern fn eglInitialize(EGLDisplay, ?*i32, ?*i32) u32;
extern fn eglChooseConfig(EGLDisplay, [*]const i32, [*]EGLConfig, i32, *i32) u32;
extern fn eglCreateWindowSurface(EGLDisplay, EGLConfig, *ANativeWindow, ?[*]const i32) EGLSurface;
extern fn eglCreateContext(EGLDisplay, EGLConfig, EGLContext, ?[*]const i32) EGLContext;
extern fn eglMakeCurrent(EGLDisplay, EGLSurface, EGLSurface, EGLContext) u32;
extern fn eglSwapBuffers(EGLDisplay, EGLSurface) u32;
extern fn eglDestroySurface(EGLDisplay, EGLSurface) u32;
extern fn eglDestroyContext(EGLDisplay, EGLContext) u32;
extern fn eglTerminate(EGLDisplay) u32;
extern fn eglGetConfigAttrib(EGLDisplay, EGLConfig, i32, *i32) u32;

const egl_default_display: ?*anyopaque = null;
const egl_no_context: EGLContext = null;
const egl_no_surface: EGLSurface = null;

const EGL_SURFACE_TYPE = 0x3033;
const EGL_WINDOW_BIT = 0x0004;
const EGL_RENDERABLE_TYPE = 0x3040;
const EGL_OPENGL_ES2_BIT = 0x0004;
const EGL_BLUE_SIZE = 0x3022;
const EGL_GREEN_SIZE = 0x3023;
const EGL_RED_SIZE = 0x3024;
const EGL_ALPHA_SIZE = 0x3021;
const EGL_DEPTH_SIZE = 0x3025;
const EGL_NONE = 0x3038;
const EGL_NATIVE_VISUAL_ID = 0x302E;
const EGL_CONTEXT_CLIENT_VERSION = 0x3098;

// ============================================================================ GLES2, locally

extern fn glClearColor(f32, f32, f32, f32) void;
extern fn glClear(u32) void;
extern fn glViewport(i32, i32, i32, i32) void;

const GL_COLOR_BUFFER_BIT: u32 = 0x00004000;

// ============================================================================ the host

/// Everything the two threads share. Every field is guarded by `mutex`.
///
/// A7.2: cold struct, size guard waived -- there is exactly one, and it is not in a hot loop.
const Host = struct {
    mutex: Io.Mutex = .init,

    /// The window, or null when we have none. Set by the OS thread, read by the render thread.
    window: ?*ANativeWindow = null,
    /// The render thread has let go of the window. `onNativeWindowDestroyed` waits on this.
    released: std.atomic.Value(bool) = .init(true),

    input: ?*AInputQueue = null,

    running: std.atomic.Value(bool) = .init(true),
    /// Visible. When false we do not draw at all -- and we do not burn battery pretending to.
    awake: std.atomic.Value(bool) = .init(false),

    /// THE GAME. The whole of what the phone knows (ui.zig).
    state: ui.State = .{},

    /// A touch that arrived and has not been folded into the state yet.
    pending_touch: ?ui.Touch = null,

    /// ============================================================================
    /// THE SAFE RECTANGLE. WHERE THE PHONE WILL ACTUALLY LET US DRAW.
    ///
    /// A modern phone is not a rectangle of pixels we own. There is a status bar at the top, a
    /// gesture bar at the bottom, and on this one a camera cutout that reserves 172 physical pixels
    /// before our first row. Draw from y=0 and the game's own name renders UNDERNEATH the clock.
    ///
    /// It is not a crash and no test can see it: the pixels are exactly where we asked for them.
    /// They are simply behind something.
    ///
    /// The framework tells us the usable region through `onContentRectChanged`. `ui.zig` is handed
    /// the SIZE of that region and never learns it has an origin -- the shell translates on the way
    /// out and translates back on the way in, exactly as it already does for density.
    ///
    /// Zeroed until the framework says otherwise, which means "the whole window" -- the right
    /// answer on a device with no insets at all.
    content: ARect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
};

var host: Host = .{};
var render_thread: ?std.Thread = null;

/// THE RADIO. Holds the JVM handles the location callback needs, and nothing else.
///
/// It does NOT hold a location. It cannot: `location.zig` is the only file in the client permitted
/// to name a double-precision float at all, and the guard fails the build if a sixth file tries.
///
/// (Spelling that type out here would itself trip the guard, which scans raw text and does not read
/// prose. It has now caught three of my own comments ABOUT it. The bluntness is the feature.)
var radio: location.Radio = .{ .vm = null, .activity = null };

/// The entry point. The framework calls this and nothing else.
export fn ANativeActivity_onCreate(
    activity: *ANativeActivity,
    saved_state: ?*anyopaque,
    saved_state_size: usize,
) callconv(.c) void {
    _ = saved_state;
    _ = saved_state_size;

    activity.callbacks.* = .{
        .onStart = null,
        .onResume = onResume,
        .onSaveInstanceState = null,
        .onPause = onPause,
        .onStop = null,
        .onDestroy = onDestroy,
        .onWindowFocusChanged = null,
        .onNativeWindowCreated = onWindowCreated,
        .onNativeWindowResized = null,
        .onNativeWindowRedrawNeeded = null,
        .onNativeWindowDestroyed = onWindowDestroyed,
        .onInputQueueCreated = onInputQueueCreated,
        .onInputQueueDestroyed = onInputQueueDestroyed,
        .onContentRectChanged = onContentRectChanged,
        .onConfigurationChanged = null,
        .onLowMemory = null,
    };

    // BEFORE the render thread starts, so it is never read while being written. The UI is laid out
    // in dp; without this the game renders correctly at about a millimetre and a half tall.
    density_scale = scaleOf(activity);

    // The JVM, and the activity object the location calls hang off. `clazz` in the NDK's own
    // header; `class` here because `clazz` is not a word.
    radio = .{ .vm = activity.vm, .activity = activity.class };

    host.running.store(true, .release);
    render_thread = std.Thread.spawn(.{}, render, .{}) catch null;
}

// ---- the OS thread. These do nothing but flip state, and they return at once. ----

fn onWindowCreated(_: *ANativeActivity, window: *ANativeWindow) callconv(.c) void {
    var threaded: Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    host.mutex.lock(io) catch return;
    defer host.mutex.unlock(io);

    host.window = window;
    host.released.store(false, .release);
    host.awake.store(true, .release);
}

/// THE ONE ORDERING RULE ANDROID ENFORCES.
///
/// After this returns, the window is gone. If the render thread is still holding an EGL surface
/// on it, that is a use-after-free in the compositor. So we BLOCK here until the render thread
/// confirms it has let go.
///
/// This is the only place the OS thread is allowed to wait, and it is not optional.
fn onWindowDestroyed(_: *ANativeActivity, _: *ANativeWindow) callconv(.c) void {
    var threaded: Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    {
        host.mutex.lock(io) catch return;
        defer host.mutex.unlock(io);
        host.window = null;
        host.awake.store(false, .release);
    }

    // Wait until the render thread has torn its surface down. Bounded by one pass of its loop --
    // it sleeps at most `backgrounded_ms` and checks the window first thing on waking.
    //
    // This waits in millisecond SLEEPS. It used to spin on the thread-yield call, which is
    // `sched_yield` underneath and returns immediately -- so the wait burned the OS thread's core
    // for its whole duration. This is the one place the OS thread is permitted to block, and it
    // should block, not spin. The guard now fails the build on the spinning version.
    while (!host.released.load(.acquire)) {
        idle(io, 1);
    }
}

fn onInputQueueCreated(_: *ANativeActivity, queue: *AInputQueue) callconv(.c) void {
    var threaded: Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    host.mutex.lock(io) catch return;
    defer host.mutex.unlock(io);
    host.input = queue;
}

fn onInputQueueDestroyed(_: *ANativeActivity, _: *AInputQueue) callconv(.c) void {
    var threaded: Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    host.mutex.lock(io) catch return;
    defer host.mutex.unlock(io);
    host.input = null;
}

/// The framework has told us where we may draw. On this phone that is 172 physical pixels below
/// the top of the window, because there is a camera up there.
fn onContentRectChanged(_: *ANativeActivity, rect: *const ARect) callconv(.c) void {
    var threaded: Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    host.mutex.lock(io) catch return;
    defer host.mutex.unlock(io);

    host.content = rect.*;
}

/// ASKING, AND THEN LOOKING.
///
/// The result of `requestPermissions` arrives as a Java callback we have no class for -- and we are
/// not adding a SECOND Java class to learn a boolean. So we ask once, and the render thread checks
/// until the answer changes. Polling a flag is nothing next to the radio it is gating.
fn armLocation() void {
    if (location.permitted(&radio)) {
        if (comptime flags.diagnostic) {
            // THE CAFE TEST WANTS FLICKER, FAST. At the production interval you would sit still for
            // ten minutes to collect twenty samples -- a fine way to save a battery and a terrible
            // way to find out whether a stationary phone holds its room. So the diagnostic build
            // fixes as fast as the GPS will give it, every second, and drift shows up in seconds.
            //
            // Exactly why it is a diagnostic build and never a shipping one: one fix a second is the
            // battery bug the production interval exists to prevent.
            location.start(&radio, 1);
        } else {
            // The floor of the battery budget: the hardware does not wake for a fix we told it we
            // did not want (G5). `gps.zig` owns the real policy; this is its minimum.
            location.start(&radio, 30);
        }
        return;
    }

    location.requestPermission(&radio);
}

fn onPause(_: *ANativeActivity) callconv(.c) void {
    // Not visible. We stop drawing entirely -- a game that renders to a screen nobody is looking
    // at is a game that drains a battery for nothing (G5).
    host.awake.store(false, .release);
}

fn onResume(_: *ANativeActivity) callconv(.c) void {
    host.awake.store(true, .release);

    // AND THIS IS WHY WE DO NOT NEED A SECOND JAVA CLASS.
    //
    // The permission dialog pauses us and its dismissal resumes us. So the answer to "did they say
    // yes?" arrives here, for free, on the callback Android was going to send anyway -- no
    // listener, no onRequestPermissionsResult, no polling loop.
    //
    // It also covers the case that matters more: a player who granted permission in Settings after
    // refusing it once. They come back to the app, we resume, and the radio arms itself.
    armLocation();
}

fn onDestroy(_: *ANativeActivity) callconv(.c) void {
    // THE RADIO GOES OFF FIRST. A location callback firing into a torn-down process is a crash,
    // and a radio left on after the app is gone is the battery bug that gets you uninstalled.
    location.stop(&radio);

    host.running.store(false, .release);
    if (render_thread) |thread| {
        thread.join();
        render_thread = null;
    }
}

// ---- the render thread. It owns EGL, and it owns the game. ----

/// ============================================================================
/// THE UI IS LAID OUT IN DP. THE SCREEN IS PAINTED IN PIXELS. THIS IS THE ONLY PLACE THAT KNOWS.
///
/// `ui.zig` places things at `pad = 22`, `line = 26`, body text at 17. Those are DENSITY-
/// INDEPENDENT PIXELS -- the unit Android defines as one pixel at 160dpi. On a modern phone at
/// ~440dpi they are not pixels at all: taken literally, seventeen physical pixels of body text is
/// about a millimetre and a half tall, which renders perfectly and cannot be read.
///
/// The fix does NOT belong in `ui.zig`. The interface is pure, integer, and has never heard of a
/// phone, and that is worth more than the convenience of scaling it there. So the shell does what
/// the shell is for: it converts.
///
///   * `ui.draw` and `ui.touch` are handed a size in DP -- physical pixels divided by scale.
///   * A touch is divided by scale on the way in.
///   * The renderer multiplies by scale on the way out, and rasterizes glyphs at the physical
///     size, so the type is sharp rather than a scaled-up blur.
///
/// The core never learns the density. Nothing in `ui.zig` changed to make this work.
fn scaleOf(activity: *ANativeActivity) f32 {
    const assets = activity.assetManager orelse return 1.0;
    const config = AConfiguration_new() orelse return 1.0;
    defer AConfiguration_delete(config);

    AConfiguration_fromAssetManager(config, assets);
    const density = AConfiguration_getDensity(config);

    // Android has three ways of saying "no idea", and a phone that reports any of them is a phone
    // we draw at 1:1 rather than one we crash on.
    if (density == density_unknown or density == density_any or density == density_none) return 1.0;
    if (density <= 0) return 1.0;

    const scale = @as(f32, @floatFromInt(density)) / @as(f32, @floatFromInt(baseline_density));

    // A sanity clamp, not a guess. Real phones land between 1.0 (mdpi) and 4.0 (xxxhdpi); anything
    // outside that is a lying or broken configuration, and drawing the UI at 40x would be worse
    // than drawing it small.
    return @min(@max(scale, 1.0), 4.0);
}

/// The density scale, read once when the activity is created and never again.
///
/// A phone's density does not change while the app is running. A FOLDABLE's can -- and when that
/// day comes, `onConfigurationChanged` is the callback that re-reads this, and the surface is
/// recreated anyway. It is a single f32 written once before the render thread starts and only read
/// after, so it needs no lock.
var density_scale: f32 = 1.0;

/// Physical pixels -> dp. The direction things come IN: a touch, a surface size.
fn toDp(physical: i32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(physical)) / density_scale));
}

/// EXTRA ROOM AT THE BOTTOM, BEYOND WHAT THE SYSTEM ASKS FOR.
///
/// The gesture bar is a thin line and the framework reserves exactly enough for it. That is the
/// right answer for a keyboard and the wrong one for a game: text that stops one pixel above the
/// bar you swipe with feels like it is about to fall off the phone. This is breathing room, and it
/// is a judgement, not a measurement.
const bottom_breathing_room_dp: i32 = 16;

/// The rectangle the phone will actually let us draw in, in physical pixels.
///
/// Zeroed content means the framework has not told us yet, which means "all of it".
fn safeArea(surface: *const Surface) ARect {
    const content = blk: {
        const c = host.content;
        if (c.right > c.left and c.bottom > c.top) break :blk c;
        break :blk ARect{ .left = 0, .top = 0, .right = surface.width, .bottom = surface.height };
    };

    const breathing: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(bottom_breathing_room_dp)) * density_scale));

    return .{
        .left = content.left,
        .top = content.top,
        .right = @min(content.right, surface.width),
        .bottom = @max(content.top, @min(content.bottom, surface.height) - breathing),
    };
}

/// The safe area, in the units `ui.zig` lays out in. It is handed a SIZE and never learns it has
/// an origin -- the shell translates on the way out and back on the way in.
fn sizeInDp(surface: *const Surface) ui.Size {
    const safe = safeArea(surface);
    return .{
        .w = toDp(safe.right - safe.left),
        .h = toDp(safe.bottom - safe.top),
    };
}

/// WHAT THE PHONE TOOK, so the core can deliberately draw back into it.
///
/// The layout stays inside the safe area -- it must, or a button ends up under the gesture bar.
/// But DECORATION IS NOT LAYOUT: scanlines and a spore field that stop at the safe boundary leave a
/// flat band top and bottom, and a flat band is a black bar with extra steps. The CRT has to reach
/// the glass. So the core is told how much was taken and is trusted to bleed into it.
fn insetsInDp(surface: *const Surface) ui.Insets {
    const safe = safeArea(surface);
    return .{
        .top = toDp(safe.top),
        .bottom = toDp(surface.height - safe.bottom),
        .left = toDp(safe.left),
        .right = toDp(surface.width - safe.right),
    };
}

const Surface = struct {
    display: EGLDisplay = null,
    surface: EGLSurface = null,
    context: EGLContext = null,
    width: i32 = 0,
    height: i32 = 0,

    /// The GLES program, once the context is current. Null if the GPU refused to compile a
    /// fifteen-line shader -- in which case we run the game and draw nothing, rather than crash on
    /// a phone. A missing renderer is an absent renderer, not an error to unwind (E2, E4).
    renderer: ?gles.Renderer = null,
};

// ---- how long the render thread sleeps when it has nothing to do (G5) ----
//
// These are not frame rates. Nothing is being drawn at any of them; they are how often the thread
// wakes to ASK whether anything has changed. Every one of them is a sleep in the kernel, not a
// spin, and the difference between those two words is the difference between a phone that lasts a
// day and a phone that is warm in your pocket by lunchtime.

/// Visible, in the player's hand, but the screen is already correct. Wakes often enough that a tap
/// feels instant; a touch is picked up within one of these and the frame follows immediately.
const idle_awake_ms: i64 = 16;

/// Backgrounded. THE STATE THE GAME IS IN ALMOST ALL OF THE TIME, and the one that decides whether
/// the battery budget is met. There is nothing to draw and nothing to poll -- the GPS and the
/// socket do not live on this thread (M.6, M.7) -- so this could be far longer still. It is 250ms
/// because `onNativeWindowDestroyed` blocks the OS thread until this loop notices, and the OS kills
/// an app whose main thread stops answering. Four wakeups a second, each of them microseconds, is
/// a rounding error against the budget; a pegged core is not.
const backgrounded_ms: i64 = 250;

/// No window: either the OS has taken it, or EGL would not come up. Short, for the same reason --
/// the OS thread may be blocked waiting for us to let go.
const no_window_ms: i64 = 20;

/// Sleep. Actually sleep -- in the kernel, off the CPU, until the clock says otherwise.
///
/// `Clock.awake` stops counting while the phone is suspended, which is the behaviour we want: a
/// suspended phone must not be woken up merely to be told to go back to sleep.
///
/// A cancelled sleep is not an error worth a code path. The loop condition is re-read immediately
/// afterwards, so the worst a failure can do is spin one iteration early (E4).
fn idle(io: Io, milliseconds: i64) void {
    io.sleep(Io.Duration.fromMilliseconds(milliseconds), .awake) catch {};
}

fn render() void {
    var threaded: Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = std.heap.smp_allocator;

    var draws: std.ArrayList(ui.Draw) = .empty;
    defer draws.deinit(gpa);

    // The vertex buffer, reused for the life of the thread. `quads.build` clears it and refills it
    // every frame, so after a few frames it never allocates again -- and a renderer that stops
    // allocating is a renderer that stops waking the allocator sixty times a second (G5, C3).
    var verts: std.ArrayList(quads.Vertex) = .empty;
    defer verts.deinit(gpa);

    // THE FONT AND THE ATLAS OUTLIVE THE SURFACE, DELIBERATELY.
    //
    // Android destroys and recreates the EGL surface freely -- a rotation, a lock screen, a task
    // switch. The GL program and the texture die with it, but the RASTERIZED GLYPHS do not: they
    // are plain bytes in our own memory, and re-parsing two TTFs and re-rasterizing every letter of
    // the alphabet on every rotation would be work done purely to throw away (G5).
    //
    // On re-attach, `atlas.dirty` is set and the bitmap is simply uploaded to the new texture.
    var engine = text.init(gpa) catch {
        // The font did not parse. There is nothing to do about it and nothing to draw. The game
        // still ticks and still reports its cell -- it just cannot speak (E2).
        return;
    };
    defer text.deinit(&engine, gpa);

    var atlas = atlas_mod.init(gpa) catch return;
    defer atlas_mod.deinit(&atlas, gpa);

    var surface: Surface = .{};
    defer tearDown(&surface);

    // The client socket, started once the player has chosen a side (M.7). It runs on its own thread
    // -- a blocking socket cannot share the render thread -- and reports the room while it lives.
    var client_thread: ?std.Thread = null;
    defer if (client_thread) |t| {
        client.stop();
        t.join();
    };

    _ = ALooper_prepare(0);

    // WHEN THE APP OPENED. The boot sequence is a pure function of the milliseconds since this
    // instant -- the core never asks the time, it is handed a number (B3, B7).
    //
    // `.awake` rather than `.real`: a monotonic clock that cannot be dragged backwards by NTP, and
    // that stops counting while the phone is suspended. A boot animation should not jump because a
    // time server corrected the clock halfway through it.
    const opened_at = Io.Timestamp.now(io, .awake);

    // ---- THE SCREEN IS REDRAWN WHEN IT CHANGES, AND NEVER OTHERWISE.
    //
    // The tick is thirty seconds wide and the screen is a still image between ticks. Redrawing it
    // at sixty frames a second would put roughly EIGHTEEN HUNDRED identical frames on the glass
    // between one piece of news and the next, and every one of them costs a vertex upload, a draw
    // call, and a buffer swap on a battery that has to last eight hours (G5).
    //
    // So: draw when something changed. `dirty` starts true because the first frame always must be.
    var dirty = true;

    while (host.running.load(.acquire)) {
        // ---- THE GAME MOVES BEFORE THE SCREEN DOES.
        //
        // Connecting, and folding a tell from the server, happen at the TOP of the loop -- before
        // the window is even looked at -- because neither needs a window and the game must not stop
        // being played just because the screen is off.
        //
        // This was a bug: the fold used to live below the `window == null` check, so a fight that
        // started while the screen was dark was never folded, and the phone came back from black
        // still saying "Nothing here." while your hit points had quietly halved. You are meant to
        // know when you are under attack. The state advances whether or not anyone is looking; the
        // screen, when it wakes, shows where the game actually is.
        {
            host.mutex.lock(io) catch break;
            defer host.mutex.unlock(io);

            // Once a side is chosen, connect. The client needs the faction for its Hello, and there
            // is nothing to report before the player is in the game.
            if (client_thread == null) {
                if (host.state.faction) |faction| {
                    client_thread = std.Thread.spawn(.{}, client.run, .{ gpa, faction }) catch null;
                }
            }

            // A TELL FROM THE SERVER, folded exactly as a local `told` would be -- the phone renders
            // what it is told and computes nothing (H1). Marks the screen dirty so a WAKING phone
            // repaints to the true state.
            if (client.takeResponse()) |r| {
                host.state = ui.told(host.state, r.hp, r.level, r.total_xp, r.damage, r.momentum, r.crowd);
                dirty = true;
            }
        }

        // ---- has the window come or gone?
        var window: ?*ANativeWindow = null;
        var queue: ?*AInputQueue = null;
        {
            host.mutex.lock(io) catch break;
            defer host.mutex.unlock(io);
            window = host.window;
            queue = host.input;
        }

        if (window == null) {
            // The OS took the window away. Let go of EGL and TELL THE OS THREAD WE HAVE, because
            // it is blocked waiting for exactly this.
            if (surface.display != null) tearDown(&surface);
            host.released.store(true, .release);

            // Short, because `onNativeWindowDestroyed` is blocking the OS thread until we get
            // here, and the OS kills an app whose main thread stops answering.
            idle(io, no_window_ms);
            continue;
        }

        if (surface.display == null) {
            surface = standUp(window.?) orelse {
                idle(io, no_window_ms);
                continue;
            };

            // A new surface is a new framebuffer, with nothing in it.
            dirty = true;

            // AND A NEW TEXTURE, WITH NOTHING IN IT EITHER. The glyphs survive a re-attach --
            // they are our own bytes -- but the GL texture holding them died with the old context.
            // Without this line the atlas is never re-uploaded, every glyph samples an empty
            // texture, and the game comes back from a rotation with every word invisible.
            atlas.dirty = true;
        }

        drainInput(queue, io);

        // ---- fold the touch into the game. The UI is pure; this is the only place it moves.
        {
            host.mutex.lock(io) catch break;
            defer host.mutex.unlock(io);

            if (host.pending_touch) |at| {
                // The touch arrived in PHYSICAL pixels; the UI thinks in dp. Divide here, or a tap
                // on the Confirm button lands three times too far down the screen and the game
                // appears not to respond to touch at all.
                // Back into the safe area's own coordinates, then into dp. The UI placed that
                // button relative to a rectangle whose origin it has never been told about.
                const safe = safeArea(&surface);
                const in_dp: ui.Touch = .{
                    .x = toDp(at.x - safe.left),
                    .y = toDp(at.y - safe.top),
                };
                host.state = ui.touch(host.state, in_dp, sizeInDp(&surface));
                host.pending_touch = null;

                // The state moved. That is the ONLY thing that makes the screen stale.
                //
                // M.7 WIRES THE SOCKET, AND A REPLY FROM THE SERVER IS THE OTHER THING THAT MOVES
                // IT. Whatever folds a `Tell` into `host.state` must set this too, or the news
                // will arrive and the screen will not show it.
                dirty = true;
            }
        }

        if (!host.awake.load(.acquire)) {
            // Not visible. Do not draw, and DO NOT SPIN.
            //
            // This line used to be the thread-yield call, under a comment promising it did not
            // burn battery. That call is `sched_yield`: it gives up the timeslice and returns
            // IMMEDIATELY. It is a busy-wait. This thread pegged a core, flat out, for the whole
            // time the app was backgrounded -- which for an ambient game is nearly always.
            //
            // The comment asserted the property. Nothing enforced it. See POSTMORTEM_2026-07-13.
            // Something enforces it now: the guard fails the build if that call comes back.
            idle(io, backgrounded_ms);
            continue;
        }

        if (!dirty) {
            // Visible, and nothing has changed. Poll for a touch and go back to sleep. The phone
            // is in the player's hand here, so this wakes often enough to feel instant -- and it
            // is still a sleep, not a spin.
            idle(io, idle_awake_ms);
            continue;
        }

        // ---- draw. The core decides WHAT; this thread decides nothing.
        const state = blk: {
            host.mutex.lock(io) catch break;
            defer host.mutex.unlock(io);

            // The clock, handed to the core as a plain number. This is the ONLY place the boot
            // animation gets its time, and the core cannot reach for it (B3).
            //
            // `advance` is what lets an animation FINISH. A tap begins the exit; the four hundred
            // milliseconds that follow are not touches, so the state machine moves itself.
            const now = Io.Timestamp.now(io, .awake);
            const elapsed = now.nanoseconds - opened_at.nanoseconds;
            const ms: u32 = @intCast(@divTrunc(@max(0, elapsed), std.time.ns_per_ms));
            host.state = ui.advance(host.state, ms);

            // THE CAFE READOUT. Compiled out entirely unless this is a diagnostic build -- and the
            // default is off, so it cannot ship by accident. See build.zig.
            if (comptime flags.diagnostic) {
                const fix = location.read();
                host.state.diagnostic = .{
                    .room = fix.cell,
                    .accuracy_metres = fix.accuracy_metres,
                    .fixes = fix.fixes,
                    .room_changes = fix.room_changes,
                };

                // The readout changes when a fix lands, and a screen that does not redraw is a
                // screen that shows a stale number for thirty seconds.
                dirty = true;
            }

            break :blk host.state;
        };

        // IN DP. The interface has never heard of a phone and does not start now.
        ui.draw(state, sizeInDp(&surface), insetsInDp(&surface), &draws, gpa) catch continue;

        present(&surface, draws.items, state, &engine, &atlas, &verts, gpa);

        // THE BOOT SEQUENCE IS THE ONE THING IN THIS GAME THAT ANIMATES, so it is the one thing
        // that redraws without being asked. It lasts about four seconds, once, at startup.
        //
        // Everything else in the game is a still image between thirty-second ticks, and it is not
        // redrawn until something changes. That is the difference between an animation and a
        // battery leak, and it is why this line is a condition rather than a `true` (G5).
        dirty = state.screen == .boot;
    }
}

/// M.3: the screen. Rectangles and words, in one pass.
///
/// The host decides NOTHING here. `ui.zig` said what to draw, `text.zig` rasterized the letters,
/// `atlas.zig` packed them, `quads.zig` turned all of it into triangles, and this function hands
/// them to the GPU. There is no layout, no colour, and no game logic in this file -- and if that
/// ever stops being true, the interface has leaked into the shell and the phone has begun
/// computing things it is not permitted to compute (H1).
fn present(
    surface: *Surface,
    draws: []const ui.Draw,
    state_for_background: ui.State,
    engine: *text.Engine,
    atlas: *atlas_mod.Atlas,
    verts: *std.ArrayList(quads.Vertex),
    gpa: std.mem.Allocator,
) void {
    glViewport(0, 0, surface.width, surface.height);

    // ============================================================================
    // FULL BLEED. THE BACKGROUND COVERS THE WHOLE PHONE; ONLY THE CONTENT IS INSET.
    //
    // The layout is confined to the safe area -- it must be, or the game's name renders under the
    // clock. But the BACKGROUND is not layout. Clear only the safe area and the strips behind the
    // status bar and the gesture bar keep whatever was under us, which is black, and the app sits
    // in a letterbox with a bar top and bottom.
    //
    // So the entire surface is cleared to the colour the core says is behind everything, and the
    // inset content is drawn on top of it. Edge to edge.
    const behind = ui.background(state_for_background);
    const packed_rgba = @intFromEnum(behind);
    glClearColor(
        @as(f32, @floatFromInt((packed_rgba >> 24) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((packed_rgba >> 16) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((packed_rgba >> 8) & 0xFF)) / 255.0,
        1.0,
    );
    glClear(GL_COLOR_BUFFER_BIT);

    const renderer = if (surface.renderer) |*r| r else {
        // No program. Draw nothing, swap a black frame, keep running. A phone that cannot compile
        // the shader still ticks, still reports its cell, and still plays the game -- it just
        // cannot show it. That is a degradation, not a crash (E2).
        _ = eglSwapBuffers(surface.display, surface.surface);
        return;
    };

    // A failed allocation, or a full atlas, is a DROPPED FRAME -- not a dead process. The next
    // frame tries again with the capacity this one already reserved (E2, E5 in spirit: nothing a
    // renderer does may take the game down).
    // The draw list is in dp. `scale` turns it back into the pixels this surface actually has --
    // and rasterizes the glyphs at the physical size, so the type is sharp rather than a blur
    // magnified from a smaller one.
    const safe = safeArea(surface);

    quads.build(draws, engine, atlas, density_scale, .{
        .x = @floatFromInt(safe.left),
        .y = @floatFromInt(safe.top),
    }, verts, gpa) catch {
        _ = eglSwapBuffers(surface.display, surface.surface);
        return;
    };

    // `quads.build` rasterizes any glyph the game has not drawn before, so the atlas may have
    // changed in the line above. Upload it BEFORE the draw that samples it -- and only when it
    // actually changed, which after the first few frames of a screen is never.
    if (atlas.dirty) {
        gles.upload(renderer, atlas.coverage, atlas.dim);
        atlas.dirty = false;
    }

    gles.draw(renderer, verts.items, surface.width, surface.height);

    _ = eglSwapBuffers(surface.display, surface.surface);
}

fn standUp(window: *ANativeWindow) ?Surface {
    const display = eglGetDisplay(egl_default_display);
    if (display == null) return null;
    if (eglInitialize(display, null, null) == 0) return null;

    const attribs = [_]i32{
        EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_BLUE_SIZE,       8,
        EGL_GREEN_SIZE,      8,
        EGL_RED_SIZE,        8,
        EGL_ALPHA_SIZE,      8,
        EGL_DEPTH_SIZE,      0,
        EGL_NONE,
    };

    var config: EGLConfig = null;
    var config_count: i32 = 0;
    if (eglChooseConfig(display, &attribs, @ptrCast(&config), 1, &config_count) == 0) return null;
    if (config_count < 1) return null;

    var visual: i32 = 0;
    _ = eglGetConfigAttrib(display, config, EGL_NATIVE_VISUAL_ID, &visual);
    _ = ANativeWindow_setBuffersGeometry(window, 0, 0, visual);

    const surface = eglCreateWindowSurface(display, config, window, null);
    if (surface == null) return null;

    const context_attribs = [_]i32{ EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    const context = eglCreateContext(display, config, egl_no_context, &context_attribs);
    if (context == null) return null;

    if (eglMakeCurrent(display, surface, surface, context) == 0) return null;

    return .{
        .display = display,
        .surface = surface,
        .context = context,
        .width = ANativeWindow_getWidth(window),
        .height = ANativeWindow_getHeight(window),

        // AFTER `eglMakeCurrent`, and not one line before it. Every GL call needs a current
        // context; compiling a shader without one silently produces nothing and the screen stays
        // black. Android destroys and recreates surfaces freely, so this runs on every re-attach
        // and the old program dies with the old context (C5).
        .renderer = gles.init(),
    };
}

fn tearDown(surface: *Surface) void {
    if (surface.display == null) return;

    // The program and the buffer belong to the context. Free them while it is still current --
    // after `eglDestroyContext` there is nothing left to free them from.
    if (surface.renderer) |*renderer| gles.deinit(renderer);

    _ = eglMakeCurrent(surface.display, egl_no_surface, egl_no_surface, egl_no_context);
    if (surface.context != null) _ = eglDestroyContext(surface.display, surface.context);
    if (surface.surface != null) _ = eglDestroySurface(surface.display, surface.surface);
    _ = eglTerminate(surface.display);

    surface.* = .{};
}

/// Touches. The only thing the player can say to this game with their hands.
fn drainInput(queue: ?*AInputQueue, io: Io) void {
    const q = queue orelse return;

    var event: ?*AInputEvent = null;
    while (AInputQueue_getEvent(q, &event) >= 0) {
        const e = event orelse continue;

        if (AInputQueue_preDispatchEvent(q, e) != 0) continue;

        var handled: i32 = 0;

        if (AInputEvent_getType(e) == input_event_type_motion) {
            const action = AMotionEvent_getAction(e) & motion_action_mask;

            // A tap is a RELEASE, not a press. It is the only gesture this game has.
            if (action == motion_action_up) {
                // The floats die here. They are screen pixels, not a place on Earth -- but the
                // core is integer-only, and a pixel that lands on a half is a pixel that looks
                // blurry (ui.zig).
                const x: i32 = @intFromFloat(AMotionEvent_getX(e, 0));
                const y: i32 = @intFromFloat(AMotionEvent_getY(e, 0));

                host.mutex.lock(io) catch {
                    AInputQueue_finishEvent(q, e, 0);
                    continue;
                };
                host.pending_touch = .{ .x = x, .y = y };
                host.mutex.unlock(io);

                handled = 1;
            }
        }

        AInputQueue_finishEvent(q, e, handled);
    }
}
