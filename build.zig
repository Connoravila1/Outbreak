const std = @import("std");

// Phase 0: the game is a test suite. There is no executable, no server, and no
// network. `zig build test` is the whole product.
//
// Two things this script must guarantee:
//   1. Tests run under a leak-detecting allocator. A leak fails the build (C6).
//      std.testing.allocator is a DebugAllocator; the default test runner fails
//      the test when it reports a leak. Nothing else is needed, and nothing else
//      may replace it.
//   2. `zig build` fails on a size-guard regression (A7) or a forbidden construct.
//      Both are comptime assertions, so the default step only has to *compile* the
//      module for them to fire.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("outbreak", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run the test suite under a leak-detecting allocator");
    test_step.dependOn(&run_tests.step);

    // The Phase 0 exit criterion, as a program you can run: ten thousand synthetic players
    // through a simulated week, replayed, under a leak-detecting allocator.
    //
    // It prints numbers. It is not a visualiser, and it never will be -- that is the named
    // trap of this phase. Run it in ReleaseFast if you want the tick cost to mean anything:
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

    // Compiling is enough to fire every comptime guard: the size guards (A7) and the
    // forbidden-construct guard (src/guard.zig). `zig build` must fail on either.
    b.default_step.dependOn(&tests.step);
}
