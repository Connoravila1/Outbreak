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
//! The GPS callback (M.5, not yet written) receives a latitude and a longitude. It must call
//! `ffi.outbreak_quantize`, take the u64, and DROP THE FLOATS IN THE SAME FUNCTION.
//!
//! Not store them. Not cache them. Not log them. Not put them in a crash report.
//!
//! The server has no coordinate and structurally cannot leak one -- the build fails if a float
//! appears in the core. THE PHONE IS THEREFORE THE ONLY PLACE A COORDINATE EVER EXISTS, which
//! makes it the only place one can leak from. There is no guard that can enforce this for us on
//! the platform side. It is discipline, and it is written here so that the next person to touch
//! the location handler reads it before they touch it.

const std = @import("std");
const ui = @import("ui.zig");

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
};

var host: Host = .{};
var render_thread: ?std.Thread = null;

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
        .onContentRectChanged = null,
        .onConfigurationChanged = null,
        .onLowMemory = null,
    };

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

    // Spin until the render thread has torn its surface down. It checks every frame, so this is
    // bounded by one frame.
    while (!host.released.load(.acquire)) {
        std.Thread.yield() catch {};
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

fn onPause(_: *ANativeActivity) callconv(.c) void {
    // Not visible. We stop drawing entirely -- a game that renders to a screen nobody is looking
    // at is a game that drains a battery for nothing (G5).
    host.awake.store(false, .release);
}

fn onResume(_: *ANativeActivity) callconv(.c) void {
    host.awake.store(true, .release);
}

fn onDestroy(_: *ANativeActivity) callconv(.c) void {
    host.running.store(false, .release);
    if (render_thread) |thread| {
        thread.join();
        render_thread = null;
    }
}

// ---- the render thread. It owns EGL, and it owns the game. ----

const Surface = struct {
    display: EGLDisplay = null,
    surface: EGLSurface = null,
    context: EGLContext = null,
    width: i32 = 0,
    height: i32 = 0,
};

fn render() void {
    var threaded: Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = std.heap.smp_allocator;

    var draws: std.ArrayList(ui.Draw) = .empty;
    defer draws.deinit(gpa);

    var surface: Surface = .{};
    defer tearDown(&surface);

    _ = ALooper_prepare(0);

    while (host.running.load(.acquire)) {
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

            std.Thread.yield() catch {};
            continue;
        }

        if (surface.display == null) {
            surface = standUp(window.?) orelse {
                std.Thread.yield() catch {};
                continue;
            };
        }

        drainInput(queue, io);

        // ---- fold the touch into the game. The UI is pure; this is the only place it moves.
        {
            host.mutex.lock(io) catch break;
            defer host.mutex.unlock(io);

            if (host.pending_touch) |at| {
                host.state = ui.touch(host.state, at, .{ .w = surface.width, .h = surface.height });
                host.pending_touch = null;
            }
        }

        if (!host.awake.load(.acquire)) {
            // Not visible. Do not draw. Do not spin. Sleep and cost nothing (G5).
            std.Thread.yield() catch {};
            continue;
        }

        // ---- draw. The core decides WHAT; this thread decides nothing.
        const state = blk: {
            host.mutex.lock(io) catch break;
            defer host.mutex.unlock(io);
            break :blk host.state;
        };

        ui.draw(state, .{ .w = surface.width, .h = surface.height }, &draws, gpa) catch continue;

        present(&surface, draws.items);
    }
}

/// M.1: the loop, the surface, and a black screen.
///
/// M.2 replaces this with a real renderer -- a batched quad pass for the rects, then a glyph pass
/// for the text. The `Draw` list it consumes is ALREADY what the core emits, and it is already
/// tested. This function is the only thing standing between that list and a screen.
fn present(surface: *Surface, draws: []const ui.Draw) void {
    glViewport(0, 0, surface.width, surface.height);

    // The first draw command is always the background (ui.draw emits it first). Until the quad
    // renderer lands, we honour that one and no more -- which puts the right black on the screen
    // and proves the whole chain: OS -> host -> core -> pixels.
    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;

    if (draws.len > 0) {
        switch (draws[0]) {
            .rect => |rect| {
                const rgba = @intFromEnum(rect.color);
                r = @as(f32, @floatFromInt((rgba >> 24) & 0xFF)) / 255.0;
                g = @as(f32, @floatFromInt((rgba >> 16) & 0xFF)) / 255.0;
                b = @as(f32, @floatFromInt((rgba >> 8) & 0xFF)) / 255.0;
            },
            .text => {},
        }
    }

    glClearColor(r, g, b, 1.0);
    glClear(GL_COLOR_BUFFER_BIT);

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
    };
}

fn tearDown(surface: *Surface) void {
    if (surface.display == null) return;

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
