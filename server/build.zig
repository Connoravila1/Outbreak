const std = @import("std");

const sqlite_flags = [_][]const u8{
    "-DSQLITE_THREADSAFE=1",
    "-DSQLITE_DQS=0",
    "-DSQLITE_OMIT_LOAD_EXTENSION",
    "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
};

/// The pure game logic. Everything else imports it as `@import("game")`.
fn gameModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/game/game.zig"),
        .target = target,
        .optimize = optimize,
    });
}

/// The server library: db, api, tick, http, with SQLite compiled in. Imported as `@import("server")`.
fn serverModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, game: *std.Build.Module) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "game", .module = game }},
    });
    mod.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = &sqlite_flags });
    return mod;
}

fn serverExe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const game = gameModule(b, target, optimize);
    const server = serverModule(b, target, optimize, game);
    return b.addExecutable(.{
        .name = "outbreak-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "game", .module = game },
                .{ .name = "server", .module = server },
            },
        }),
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const game = gameModule(b, target, optimize);
    const server = serverModule(b, target, optimize, game);

    // zig build: the server binary. zig build run -- --dev
    const exe = serverExe(b, target, optimize);
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the server (pass flags after --)").dependOn(&run.step);

    // zig build test: the game core and the server modules.
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = game })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = server })).step);

    // zig build sim: the balance simulator. Always built optimized; it runs many fights.
    const sim = b.addExecutable(.{
        .name = "sim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sim.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "game", .module = game }},
        }),
    });
    const run_sim = b.addRunArtifact(sim);
    if (b.args) |args| run_sim.addArgs(args);
    b.step("sim", "Run the balance simulator").dependOn(&run_sim.step);

    // zig build dist: static release binaries in zig-out/dist/<arch>/outbreak-server.
    const dist = b.step("dist", "Build static release binaries (x86_64 and aarch64 Linux, musl)");
    const dist_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    };
    for (dist_targets) |query| {
        const t = b.resolveTargetQuery(query);
        const bin = serverExe(b, t, .ReleaseSafe);
        const install = b.addInstallArtifact(bin, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("dist/{s}", .{@tagName(query.cpu_arch.?)}) } },
        });
        dist.dependOn(&install.step);
    }
}
