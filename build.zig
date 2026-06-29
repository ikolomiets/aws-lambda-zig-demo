const std = @import("std");
const lambda = @import("aws_lambda");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseFast,
    });
    const target = lambda.resolveTargetQuery(b, lambda.archOption(b));
    const runtime = b.dependency("aws_lambda", .{}).module("lambda");

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
        .strip = true,
        .single_threaded = true,
        .imports = &.{
            .{ .name = "aws-lambda", .module = runtime },
        },
    });

    const exe = b.addExecutable(.{
        .name = "bootstrap",
        .root_module = mod,
    });

    b.installArtifact(exe);
}
