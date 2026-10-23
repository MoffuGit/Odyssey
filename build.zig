const std = @import("std");
const Translator = @import("translate_c").Translator;
const MetallibStep = @import("build/MetalLibStep.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_filters = b.option(
        [][]const u8,
        "test-filter",
        "Filter for test. Only applies to Zig tests.",
    ) orelse &[0][]const u8{};

    const benchmark = b.option(bool, "enable-benchmark", "Benchmark flag") orelse false;

    const objc = b.dependency("zig_objc", .{
        .target = target,
        .optimize = optimize,
    });

    const macos = b.dependency("macos", .{
        .target = target,
        .optimize = optimize,
    });

    const rgfw = buildRgfw(b, target, optimize);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .off,
        .imports = &.{
            .{ .name = "objc", .module = objc.module("objc") },
            .{ .name = "macos", .module = macos.module("macos") },
            .{ .name = "rgfw", .module = rgfw },
        },
    });

    mod.linkFramework("Cocoa", .{});
    mod.linkFramework("CoreVideo", .{});
    mod.linkFramework("IOKit", .{});
    mod.linkFramework("Metal", .{});

    const test_options = b.addOptions();

    test_options.addOptionPathDirectory("chromium_path", b.path(ChromiumPath));
    test_options.addOption(bool, "benchmark", benchmark);

    mod.addOptions("test_options", test_options);

    const exe_tests = b.addTest(.{
        .root_module = mod,
        .filters = test_filters,
    });

    b.step("test", "Run tests").dependOn(&b.addRunArtifact(exe_tests).step);

    const metallib = MetallibStep.create(b, .{
        .name = "Odyssey",
        .sources = &.{b.path("src/render/metal/shader.metal")},
    });

    mod.addAnonymousImport("odyssey_metallib", .{
        .root_source_file = metallib.?.output,
    });

    const exe = b.addExecutable(.{
        .name = "odyssey",
        .root_module = mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(metallib.?.step);
    run_step.dependOn(&run_cmd.step);
}

fn buildRgfw(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const translate_c = b.dependency("translate_c", .{});
    const translator: Translator = .init(translate_c, .{
        .c_source_file = b.path("include/RGFW.h"),
        .target = target,
        .optimize = optimize,
    });

    const rgfw = translator.mod;

    rgfw.addCSourceFile(.{
        .file = b.path("include/RGFW.c"),
    });

    return rgfw;
}

const TestPath = "test";
const ChromiumPath = TestPath ++ "/chromium";
// const ChromiumUrl = "https://github.com/chromium/chromium.git";
//
// // pub fn cloneChromiumStep(b: *std.Build) *std.Build.Step {
// //     const step = b.allocator.create(std.Build.Step) catch @panic("OOM");
// //     step.* = std.Build.Step.init(.{
// //         .id = .custom,
// //         .name = "clone chromium",
// //         .owner = b,
// //         .makeFn = cloneChromiumMake,
// //     });
// //     return step;
// // }
// //
// // fn cloneChromiumMake(step: *std.Build.Step, opts: std.Build.Step.MakeOptions) anyerror!void {
// //     const b = step.owner;
// //     const io = b.graph.io;
// //     const dest = b.pathFromRoot(ChromiumPath);
// //     const git_dir = b.pathJoin(&.{ dest, ".git" });
// //
// //     if (std.Io.Dir.accessAbsolute(io, git_dir, .{})) |_| return else |_| {}
// //
// //     std.Io.Dir.cwd().createDirPath(io, b.pathFromRoot(TestPath)) catch |e|
// //         return step.fail("unable to create testdata dir: {s}", .{@errorName(e)});
// //
// //     var node = opts.progress_node.start("git clone chromium", 0);
// //     defer node.end();
// //
// //     var child = try std.process.spawn(io, .{
// //         .argv = &.{
// //             "git",                "clone",
// //             "--depth",            "1",
// //             "--filter=blob:none", ChromiumUrl,
// //             dest,
// //         },
// //         .stdin = .pipe,
// //         .stdout = .pipe,
// //         .stderr = .pipe,
// //     });
// //
// //     const term = child.wait(io) catch |e|
// //         return step.fail("failed to spawn git: {s}", .{@errorName(e)});
// //
// //     switch (term) {
// //         .exited => |code| if (code != 0)
// //             return step.fail("git clone exited with code {d}", .{code}),
// //         else => return step.fail("git clone terminated unexpectedly", .{}),
// //     }
// // }
