const std = @import("std");

/// Fails the build if a source file exists that `src/guard.zig` has never heard of.
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
                \\Every unit of logic is core or shell. There is no third category and no
                \\unclassified code. A file missing from src/guard.zig is a file the coordinate
                \\wall, the purity check, and the geometry ban DO NOT APPLY TO.
                \\
                \\Add it to `core` or to `shell` in src/guard.zig. If you cannot decide, it is shell.
                \\
            , .{entry.path});
        }
    }
}

/// The four faces. Two typefaces, and the split is a design decision, not an accident:
///
///   * INTER carries the PROSE -- the sentences a player actually reads. It is a face designed to
///     disappear, and the words are the product.
///   * OXANIUM carries the CHROME and the SHOUTING -- labels, headings, and the alarm. It is a
///     squared display face, and it is the game's voice rather than its speech.
///
/// Both are SIL OFL 1.1 and both licences travel with them, in `assets/fonts/`, as the OFL
/// requires. See ATTRIBUTIONS.md.
fn addFonts(b: *std.Build, mod: *std.Build.Module) void {
    mod.addImport("font_body", b.createModule(.{ .root_source_file = b.path("assets/fonts/Inter-Regular.ttf") }));
    mod.addImport("font_label", b.createModule(.{ .root_source_file = b.path("assets/fonts/Oxanium-SemiBold.ttf") }));
    mod.addImport("font_heading", b.createModule(.{ .root_source_file = b.path("assets/fonts/Oxanium-Bold.ttf") }));
    mod.addImport("font_alarm", b.createModule(.{ .root_source_file = b.path("assets/fonts/Oxanium-ExtraBold.ttf") }));
}

/// Compile stb_truetype and link it in. NATIVE TARGETS ONLY.
///
/// Zig does not ship bionic's headers, so `#include <math.h>` cannot resolve when cross-compiling
/// C to Android without the NDK's sysroot -- and making the NDK a prerequisite of `zig build` on
/// every machine, forever, in order to TYPE-CHECK a phone file is a bad trade.
///
/// It is not needed there anyway. `src/text.zig` declares the shim's functions as `extern fn` and
/// never includes a header, exactly as `android.zig` declares the NDK and `gles.zig` declares
/// GLES. The Android host compiles as an OBJECT with those symbols unresolved; the APK's own
/// build compiles this same C file against the NDK and resolves them at link time.
///
/// So the C is compiled here, natively, where the tests run -- which is also where the glyph
/// rasterizer is actually exercised.
fn addStb(b: *std.Build, mod: *std.Build.Module) void {
    mod.addIncludePath(b.path("vendor"));
    mod.addCSourceFile(.{
        .file = b.path("vendor/stb_impl.c"),
        // stb leans on aliasing tricks the UB sanitizer objects to. This is upstream's own
        // recommended posture, and the alternative is patching a vendored file we want to keep
        // byte-identical to the release we pinned.
        .flags = &.{"-fno-sanitize=undefined"},
    });
    mod.link_libc = true;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ============================================================================
    // B1, ENFORCED: EVERY UNIT IS CLASSIFIED. NO THIRD CATEGORY. NOTHING UNCLASSIFIED.
    //
    // The comptime guard in src/guard.zig can only check the files it has been TOLD about. It
    // cannot notice a file nobody registered -- and an unregistered file is an unguarded file:
    // the coordinate wall, the purity check, and the geometry ban simply do not apply to it.
    //
    // The ruleset audit found exactly that: `spatial/geohash_vectors_test.zig` -- the one test
    // file that holds real latitudes and longitudes -- had never been registered, so the wall
    // built to keep coordinates out had never been pointed at it.
    //
    // B1 was itself sitting in the "human" bucket, enforced by nobody. It is not any more:
    // build.zig runs with filesystem access, so it walks src/ and fails the build if any source
    // file is missing from the guard's registry.
    //
    // A rule enforced by memory is a rule already broken. See POSTMORTEM_2026-07-13.md.
    // ============================================================================
    checkEveryFileIsClassified(b);

    const mod = b.addModule("outbreak", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    addFonts(b, mod);
    addStb(b, mod);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run the test suite under a leak-detecting allocator");
    test_step.dependOn(&run_tests.step);

    // ============================================================================
    // BUILD MODE IS A SECURITY DECISION (SECURITY.md, Phase 0 bedrock).
    //
    // Anything that will ever face untrusted input ships ReleaseSafe, never ReleaseFast.
    // Zig's safe modes keep integer-overflow, bounds, and unreachable checks live at runtime,
    // and those checks are what turn a memory-corruption exploit into a clean crash.
    //
    // `sim` is the ONE exception and it is allowed to be: it faces no network, parses nothing
    // hostile, and exists to produce honest performance numbers (G1) -- which ReleaseSafe would
    // distort. It is a development tool and is never shipped.
    //
    // When the server binary lands, it is ReleaseSafe. This comment is here so that decision is
    // made on purpose rather than inherited from whatever the last person typed.
    // ============================================================================

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

    // ============================================================================
    // THE ANDROID STATIC LIBRARY (3.1).
    //
    // The pure core, cross-compiled for a phone. This is the payoff the roadmap promised: "the
    // most portable code that exists" -- no allocations it was not handed, no I/O, no lifetimes.
    // It cross-compiles because there is nothing in it to be platform-specific about.
    //
    // ReleaseSafe, NOT ReleaseFast. This library parses bytes that came off a network from a
    // server the phone cannot verify, and it runs inside a JVM where a panic is not a crash we
    // can debug but a corrupted runtime. The overflow and bounds checks stay live.
    // ============================================================================
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
                // A library that parses hostile bytes inside a JVM ships with its safety checks
                // on. A panic across an FFI boundary is undefined behaviour, and a bounds check
                // is what turns a memory-corruption exploit into a clean abort.
                .optimize = .ReleaseSafe,
            }),
        });

        const install = b.addInstallArtifact(lib, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("android/{s}", .{triple}) } },
        });
        android_step.dependOn(&install.step);

        // ============================================================================
        // THE HOST IS COMPILED. THIS IS NOT OPTIONAL, AND IT WAS NOT HAPPENING.
        //
        // The library above is rooted at `ffi.zig`. It contains the ten C ABI functions and
        // NOTHING ELSE -- `android.zig` is not reachable from it, and `root.zig` does not import
        // it either. So the Android host -- the render loop, the EGL bring-up, the lifecycle
        // callbacks, the renderer, every line of it -- WAS COMPILED BY NOTHING.
        //
        // It was not "written but not yet run on a device." It had never been through a compiler
        // at all. `zig build android` went green while saying nothing whatsoever about it, which
        // is worse than a red build: a green one that checks nothing also supplies confidence.
        // Proven by appending garbage to the file and watching every build step pass.
        //
        // An OBJECT, not a library: the host's `extern fn`s (EGL, GLES, the NDK) are resolved by
        // the APK's linker against the device's own system libraries, which do not exist here.
        // An object file does not need them resolved -- but it is fully type-checked, fully code
        // generated, and it fires every comptime guard in the file. That is the whole point.
        // ============================================================================
        const host_mod = b.createModule(.{
            .root_source_file = b.path("src/android.zig"),
            .target = b.resolveTargetQuery(query),
            .optimize = .ReleaseSafe,
        });
        // Fonts, but NOT the C. See `addStb`: the host is type-checked here and linked by the
        // APK, which compiles the same shim against the NDK.
        addFonts(b, host_mod);

        const host = b.addObject(.{
            .name = b.fmt("host-{s}", .{triple}),
            .root_module = host_mod,
        });

        android_step.dependOn(&host.step);

        // And it is checked by the DEFAULT build too, so a broken host fails `zig build` on the
        // machine of whoever broke it, in the second they break it -- not months later, in a cafe.
        b.default_step.dependOn(&host.step);
    }

    // ============================================================================
    // THE SHARED LIBRARY THE PHONE ACTUALLY LOADS.
    //
    //     zig build so -Dndk=$HOME/Android/Sdk/ndk/26.3.11579264
    //
    // Everything above this point is compiled but never LINKED -- the host object leaves EGL,
    // GLES and the NDK unresolved on purpose, because a laptop has none of them. This is where
    // they get resolved, against the NDK's own stubs, and it is the first time anything in this
    // project becomes a thing a phone can run.
    //
    // The NDK is passed in rather than discovered. A build that hunts around the filesystem for a
    // toolchain is a build that behaves differently on two machines, and `zig build` and
    // `zig build test` must never need it at all -- which is the whole reason the host is
    // type-checked as an object.
    // ============================================================================
    if (b.option([]const u8, "ndk", "Path to the Android NDK (only needed for `zig build so`)")) |ndk| {
        const so_step = b.step("so", "Link liboutbreak.so for the phone (needs -Dndk=...)");

        const abi = "aarch64-linux-android";
        const api = "24"; // minSdkVersion in android/AndroidManifest.xml. Keep them in step.

        const prebuilt = b.fmt("{s}/toolchains/llvm/prebuilt/linux-x86_64", .{ndk});
        const sysroot = b.fmt("{s}/sysroot", .{prebuilt});

        const query = std.Build.parseTargetQuery(.{ .arch_os_abi = abi }) catch |err| {
            std.debug.panic("bad android target: {s}", .{@errorName(err)});
        };

        const so_mod = b.createModule(.{
            .root_source_file = b.path("src/android.zig"),
            .target = b.resolveTargetQuery(query),
            // ReleaseSafe. This library will one day parse bytes off a network from a server the
            // phone cannot verify, and the overflow and bounds checks are what turn a memory
            // corruption bug into a clean abort. It is also the mode the battery number must be
            // measured in, or the number means nothing.
            .optimize = .ReleaseSafe,
        });

        addFonts(b, so_mod);

        // The stb shim, compiled for the PHONE this time -- which is why the NDK is needed at all.
        // Zig does not ship bionic's headers, so `#include <math.h>` only resolves here.
        so_mod.addIncludePath(b.path("vendor"));
        so_mod.addCSourceFile(.{
            .file = b.path("vendor/stb_impl.c"),
            .flags = &.{"-fno-sanitize=undefined"},
        });

        // THE JNI SHIM. Same reason, same shape: `jni.h` only exists in the NDK, so the JNI
        // function table stays on the C side of the wall and Zig declares flat `extern fn`s.
        //
        // Note what is NOT compiled here: the location callback. `Java_com_outbreak_game_Fix_
        // onLocation` is exported from `src/location.zig`, and the JVM resolves it by symbol out
        // of this library. The coordinate's first stop in our code is Zig, not C.
        so_mod.addCSourceFile(.{
            .file = b.path("android/jni_shim.c"),
            .flags = &.{},
        });
        so_mod.link_libc = true;
        so_mod.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sysroot}) });
        so_mod.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include/{s}", .{ sysroot, abi }) });
        so_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib/{s}/{s}", .{ sysroot, abi, api }) });

        // The four the host actually reaches for: the NDK (lifecycle, input, looper, density),
        // EGL (the surface), GLES2 (the pixels), and the log. Nothing else.
        so_mod.linkSystemLibrary("android", .{});
        so_mod.linkSystemLibrary("EGL", .{});
        so_mod.linkSystemLibrary("GLESv2", .{});
        so_mod.linkSystemLibrary("log", .{});

        // `outbreak` -> `liboutbreak.so`, which is what `android.app.lib_name` names in the
        // manifest. That string is the only link between the manifest and the code.
        const so = b.addLibrary(.{
            .name = "outbreak",
            .linkage = .dynamic,
            .root_module = so_mod,
        });

        // ZIG MUST NOT PROVIDE LIBC HERE. Android's libc is bionic, it lives in the NDK, and it is
        // already on the phone. `link_libc = true` otherwise asks Zig to supply one, and Zig quite
        // correctly answers that it cannot supply bionic.
        //
        // So we hand it the NDK's paths instead: bionic's headers, and the versioned stub
        // directory for our minimum API level. The API level is not cosmetic -- it is which
        // bionic symbols the linker will admit exist.
        const libc_conf = b.addWriteFiles().add("android-libc.conf", b.fmt(
            \\include_dir={s}/usr/include
            \\sys_include_dir={s}/usr/include
            \\crt_dir={s}/usr/lib/{s}/{s}
            \\msvc_lib_dir=
            \\kernel32_lib_dir=
            \\gcc_dir=
            \\
        , .{ sysroot, sysroot, sysroot, abi, api }));
        so.setLibCFile(libc_conf);

        const install_so = b.addInstallArtifact(so, .{
            .dest_dir = .{ .override = .{ .custom = "apk/lib/arm64-v8a" } },
        });
        so_step.dependOn(&install_so.step);
    }

    // Compiling is enough to fire every comptime guard: the size guards (A7) and the
    // forbidden-construct guard (src/guard.zig). `zig build` must fail on either.
    b.default_step.dependOn(&tests.step);
}
