const std = @import("std");
const MetallibStep = @import("build/MetalLibStep.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const clone_chromium = cloneChromiumStep(b);

    const exe_tests = b.addTest(.{
        .root_module = rootModule(
            b,
            target,
            optimize,
            "src/test.zig",
        ),
        .filters = b.args orelse &.{},
    });
    exe_tests.step.dependOn(clone_chromium);
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(exe_tests).step);

    const root_module = rootModule(b, target, optimize, "src/main.zig");

    const metallib = MetallibStep.create(b, .{
        .name = "Odyssey",
        .sources = &.{b.path("src/render/metal/shader.metal")},
    });

    root_module.addAnonymousImport("odyssey_metallib", .{
        .root_source_file = metallib.?.output,
    });

    const exe = b.addExecutable(.{
        .name = "odyssey",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(metallib.?.step);
    run_step.dependOn(&run_cmd.step);
}

fn buildRgfw(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const translate_c = b.addTranslateC(.{
        .optimize = optimize,
        .target = target,
        .root_source_file = b.path("lib/RGFW.h"),
    });

    const rgfw = translate_c.createModule();

    rgfw.addCSourceFile(.{
        .file = b.path("lib/RGFW.c"),
    });

    return rgfw;
}

fn rootModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root_source: []const u8,
) *std.Build.Module {
    const objc = b.dependency("zig_objc", .{
        .target = target,
        .optimize = optimize,
    });

    const zlob = b.dependency("zlob", .{
        .target = target,
        .optimize = optimize,
    });

    const macos = b.dependency("macos", .{
        .target = target,
        .optimize = optimize,
    });

    const rgfw = buildRgfw(b, target, optimize);

    const mod = b.createModule(.{
        .root_source_file = b.path(root_source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .off,
        .imports = &.{
            .{ .name = "zlob", .module = zlob.module("zlob_core") },
            .{ .name = "objc", .module = objc.module("objc") },
            .{ .name = "macos", .module = macos.module("macos") },
            .{ .name = "rgfw", .module = rgfw },
        },
    });

    mod.linkFramework("Cocoa", .{});
    mod.linkFramework("CoreVideo", .{});
    mod.linkFramework("IOKit", .{});
    mod.linkFramework("Metal", .{});

    addTestOptions(mod, b);

    return mod;
}

const TestPath = "test";
const ChromiumPath = TestPath ++ "/chromium";
const ChromiumUrl = "https://github.com/chromium/chromium.git";

pub fn cloneChromiumStep(b: *std.Build) *std.Build.Step {
    const step = b.allocator.create(std.Build.Step) catch @panic("OOM");
    step.* = std.Build.Step.init(.{
        .id = .custom,
        .name = "clone chromium",
        .owner = b,
        .makeFn = cloneChromiumMake,
    });
    return step;
}

pub fn addTestOptions(mod: *std.Build.Module, b: *std.Build) void {
    const test_options = b.addOptions();
    test_options.addOption([]const u8, "chromium_path", b.pathFromRoot(ChromiumPath));
    test_options.addOption(bool, "benchmark", for (b.args orelse &.{}) |arg| {
        if (std.mem.indexOf(u8, arg, "benchmark") != null) break true;
    } else false);

    mod.addOptions("test_options", test_options);
}

fn cloneChromiumMake(step: *std.Build.Step, opts: std.Build.Step.MakeOptions) anyerror!void {
    const b = step.owner;
    const io = b.graph.io;
    const dest = b.pathFromRoot(ChromiumPath);
    const git_dir = b.pathJoin(&.{ dest, ".git" });

    if (std.Io.Dir.accessAbsolute(io, git_dir, .{})) |_| return else |_| {}

    std.Io.Dir.cwd().createDirPath(io, b.pathFromRoot(TestPath)) catch |e|
        return step.fail("unable to create testdata dir: {s}", .{@errorName(e)});

    var node = opts.progress_node.start("git clone chromium", 0);
    defer node.end();

    var child = try std.process.spawn(io, .{
        .argv = &.{
            "git",                "clone",
            "--depth",            "1",
            "--filter=blob:none", ChromiumUrl,
            dest,
        },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    const term = child.wait(io) catch |e|
        return step.fail("failed to spawn git: {s}", .{@errorName(e)});

    switch (term) {
        .exited => |code| if (code != 0)
            return step.fail("git clone exited with code {d}", .{code}),
        else => return step.fail("git clone terminated unexpectedly", .{}),
    }
}
