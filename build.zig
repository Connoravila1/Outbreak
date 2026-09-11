const std = @import("std");

/// B1, enforced: every src/ file must be registered core or shell in src/guard.zig.
/// An unregistered file is an unguarded file — the audit found the geohash test vectors
/// unregistered, meaning the coordinate wall had never applied to the one file holding a
/// latitude. See POSTMORTEM_2026-07-13.md.
fn checkEveryFileIsClassified(b: *std.Build) void {
    const io = b.graph.io;
    const root = b.build_root.handle;

    const guard = root.readFileAlloc(io, "src/guard.zig", b.allocator, .limited(1 << 20)) catch |err| {
        std.debug.panic("B1: cannot read src/guard.zig to verify classification: {s}", .{@errorName(err)});
    };

    var src = root.openDir(io, "src", .{ .iterate = true }) catch |err| {
        std.debug.panic("B1: cannot open src/ to verify classification: {s}", .{@errorName(err)});
    };
    defer src.close(io);

    var walker = src.walk(b.allocator) catch @panic("B1: out of memory");
    defer walker.deinit();

    while (walker.next(io) catch @panic("B1: walk failed")) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, "guard.zig")) continue; // the guard does not guard itself

        const needle = b.fmt("@embedFile(\"{s}\")", .{entry.path});

        if (std.mem.indexOf(u8, guard, needle) == null) {
            std.debug.panic(
                \\
                \\B1 VIOLATION: src/{s} is not classified.
                \\
                \\Every unit of logic is core or shell; a file missing from src/guard.zig is a file
                \\the coordinate wall, the purity check, and the geometry ban do not apply to.
                \\Add it to `core` or to `shell` in src/guard.zig. If you cannot decide, it is shell.
                \\
            , .{entry.path});
        }
    }
}

/// Inter carries prose; Oxanium carries chrome and alarms. Both SIL OFL 1.1 — licences travel
/// with the fonts in assets/fonts/. See ATTRIBUTIONS.md.
fn addFonts(b: *std.Build, mod: *std.Build.Module) void {
    mod.addImport("font_body", b.createModule(.{ .root_source_file = b.path("assets/fonts/Inter-Regular.ttf") }));
    mod.addImport("font_label", b.createModule(.{ .root_source_file = b.path("assets/fonts/Oxanium-SemiBold.ttf") }));
    mod.addImport("font_heading", b.createModule(.{ .root_source_file = b.path("assets/fonts/Oxanium-Bold.ttf") }));
    mod.addImport("font_alarm", b.createModule(.{ .root_source_file = b.path("assets/fonts/Oxanium-ExtraBold.ttf") }));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The diagnostic build shows your own cell id and receiver error on screen — needed for the
    // cafe test (O3), which cannot be answered from a chair. It must never reach a player, so it
    // is a flag the compiler records, not a comment promising removal.
    const diagnostic = b.option(bool, "diagnostic", "Show the GPS readout on screen (O3, the cafe test)") orelse false;

    const flags = b.addOptions();
    flags.addOption(bool, "diagnostic", diagnostic);

    checkEveryFileIsClassified(b);

    const mod = b.addModule("outbreak", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    addFonts(b, mod);
    mod.addOptions("flags", flags);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run the test suite under a leak-detecting allocator");
    test_step.dependOn(&run_tests.step);

    // Anything facing untrusted input ships ReleaseSafe: the bounds/overflow checks turn a
    // memory-corruption exploit into a clean crash. `sim` is the one exception — no network, no
    // hostile input, and it exists to produce honest perf numbers (G1) ReleaseSafe would distort.
    // It is a dev tool and is never shipped.
    //
    //     zig build sim -Doptimize=ReleaseFast
    const sim = b.addExecutable(.{
        .name = "sim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sim.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_sim = b.addRunArtifact(sim);
    const sim_step = b.step("sim", "Run the synthetic city for a simulated week");
    sim_step.dependOn(&run_sim.step);

    //     zig build server                       # 127.0.0.1:7777, 30s tick
    //     zig build run-server -- --tick=3       # faster tick for a live test
    const server = b.addExecutable(.{
        .name = "outbreak-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    const install_server = b.addInstallArtifact(server, .{});
    const server_step = b.step("server", "Build the server binary");
    server_step.dependOn(&install_server.step);

    const run_server = b.addRunArtifact(server);
    if (b.args) |args| run_server.addArgs(args);
    const run_server_step = b.step("run-server", "Build and run the server");
    run_server_step.dependOn(&run_server.step);

    // The pure core cross-compiled for the phone ABI — ReleaseSafe, since it parses bytes off a
    // network inside a JVM where a panic is a corrupted runtime, not a debuggable crash.
    const android_step = b.step("android", "Build the core as a static library for Android");

    for ([_][]const u8{ "aarch64-linux-android", "x86_64-linux-android" }) |triple| {
        const query = std.Build.parseTargetQuery(.{ .arch_os_abi = triple }) catch |err| {
            std.debug.panic("bad android target {s}: {s}", .{ triple, @errorName(err) });
        };

        const lib = b.addLibrary(.{
            .name = b.fmt("outbreak-{s}", .{triple}),
            .linkage = .static,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/ffi.zig"),
                .target = b.resolveTargetQuery(query),
                .optimize = .ReleaseSafe,
            }),
        });

        const install = b.addInstallArtifact(lib, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("android/{s}", .{triple}) } },
        });
        android_step.dependOn(&install.step);

        // When the DVUI/SDL phone host lands (CURRENT.md), compile it here as an OBJECT again —
        // fully type-checked, comptime guards fired, NDK symbols unresolved. A host compiled by
        // nothing is worse than a red build: proven by appending garbage to android.zig and
        // watching every step pass.
    }

    // `zig build so` is suspended: it produced liboutbreak.so from the removed NativeActivity host
    // (src/android.zig). The SDL host owns its .so build when it lands. The natives the Java
    // service calls (OutbreakService.onLocation, the motion interrupt) are exported from
    // location.zig and get re-exported by the new host's root. Same shape when it returns: NDK
    // passed via -Dndk=..., never discovered; ReleaseSafe; bionic via explicit libc conf.

    // Compiling fires every comptime guard: the size guards (A7) and src/guard.zig.
    // `zig build` must fail on either.
    b.default_step.dependOn(&tests.step);
}
