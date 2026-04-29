const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zctxDep = b.dependency("zctx", .{});
    const zctxMod = zctxDep.module("zctx");

    const mod = b.addModule("zrate", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addImport("zctx", zctxMod);

    const lib = b.addLibrary(.{
        .name = "zrate",
        .root_module = mod,
        .linkage = .static,
    });

    const docs = lib.getEmittedDocs();
    const installDocs = b.addInstallDirectory(.{
        .source_dir = docs,
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docsStep = b.step("docs", "Generate API documentation");
    docsStep.dependOn(&installDocs.step);

    const modTests = b.addTest(.{
        .root_module = mod,
    });
    const runModTests = b.addRunArtifact(modTests);
    const testStep = b.step("test", "Run tests");
    testStep.dependOn(&runModTests.step);

    const exampleNames = [_][]const u8{ "basic", "reserve", "wait", "cancel", "dynamic" };

    for (&exampleNames) |name| {
        const srcPath = b.fmt("example/{s}.zig", .{name});
        const stepName = b.fmt("run-example-{s}", .{name});
        const stepDesc = b.fmt("Run example: {s}", .{name});

        const exeMod = b.createModule(.{
            .root_source_file = b.path(srcPath),
            .target = target,
            .optimize = optimize,
        });
        exeMod.addImport("zrate", mod);
        exeMod.addImport("zctx", zctxMod);

        const exe = b.addExecutable(.{
            .name = name,
            .root_module = exeMod,
        });

        const run = b.addRunArtifact(exe);
        const step = b.step(stepName, stepDesc);
        step.dependOn(&run.step);
    }
}
