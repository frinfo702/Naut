const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    // Pin the macOS deployment target so the static library links into
    // the app without "built for newer macOS" warnings. Matches
    // macos/Package.swift.
    const target = b.standardTargetOptions(.{
        .default_target = if (builtin.os.tag == .macos) .{
            .os_tag = .macos,
            .os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } },
        } else .{},
    });
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option([]const []const u8, "test-filter", "Only run tests matching this filter") orelse &.{};
    const emit_macos_app = b.option(bool, "emit-macos-app", "Build the macOS app bundle") orelse
        (builtin.os.tag == .macos);

    // The Zig package other projects depend on: b.dependency("naut", ...)
    // then .module("naut").
    const mod = b.addModule("naut", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // libnaut.a with the C API, for Swift and anyone else with a C FFI.
    const lib = b.addLibrary(.{
        .name = "naut",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    // The consumer links with a C toolchain that doesn't know about Zig's
    // runtime, so the static library must carry it.
    lib.bundle_compiler_rt = true;
    lib.bundle_ubsan_rt = true;
    lib.installHeader(b.path("include/naut.h"), "naut.h");
    b.installArtifact(lib);

    const tests = b.addTest(.{ .root_module = mod, .filters = test_filters });
    tests.root_module.link_libc = true;
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    if (!emit_macos_app) return;

    // Package the library as an xcframework the Swift package can depend
    // on as a binary target. xcodebuild refuses to overwrite, hence rm.
    const xcframework = b.addSystemCommand(&.{
        "sh", "-c",
        \\rm -rf "$2" && xcodebuild -create-xcframework -library "$0" -headers "$1" -output "$2" >/dev/null
    });
    xcframework.addFileArg(lib.getEmittedBin());
    xcframework.addDirectoryArg(b.path("include"));
    xcframework.addArg("macos/CNaut.xcframework");
    xcframework.setCwd(b.path("."));
    xcframework.has_side_effects = true;

    const swift_config = if (optimize == .debug) "debug" else "release";
    const swift = b.addSystemCommand(&.{ "swift", "build", "-c", swift_config, "--package-path", "macos" });
    swift.setCwd(b.path("."));
    swift.has_side_effects = true;
    swift.step.dependOn(&xcframework.step);

    // A SwiftPM executable is not an app; wrap it in a minimal bundle so
    // it gets a Dock icon, menu bar and its own preferences domain.
    const bin = b.fmt("macos/.build/{s}/Naut", .{swift_config});
    const install_bin = b.addInstallFile(b.path(bin), "Naut.app/Contents/MacOS/Naut");
    install_bin.step.dependOn(&swift.step);
    const install_plist = b.addInstallFile(b.path("macos/Info.plist"), "Naut.app/Contents/Info.plist");
    b.getInstallStep().dependOn(&install_bin.step);
    b.getInstallStep().dependOn(&install_plist.step);

    // ponytail: assumes the default zig-out prefix.
    const run = b.addSystemCommand(&.{ "open", "zig-out/Naut.app" });
    run.setCwd(b.path("."));
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Build and open the macOS app").dependOn(&run.step);
}
