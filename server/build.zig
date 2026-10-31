const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The pure game logic. Everything else imports it as `@import("game")`.
    const game = b.addModule("game", .{
        .root_source_file = b.path("src/game/game.zig"),
        .target = target,
        .optimize = optimize,
    });

    // zig build test: every unit test in the game module.
    const game_tests = b.addTest(.{ .root_module = game });
    const run_game_tests = b.addRunArtifact(game_tests);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_game_tests.step);

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
    const sim_step = b.step("sim", "Run the balance simulator");
    sim_step.dependOn(&run_sim.step);

    // TODO(server agent): add the `outbreak-server` executable here (src/main.zig, http, api,
    // db) importing the "game" module, and compile the vendored SQLite amalgamation.
}
