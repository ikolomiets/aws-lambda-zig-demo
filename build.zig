const std = @import("std");
const lambda = @import("aws_lambda");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });
    const lambda_target = lambda.resolveTargetQuery(b, lambda.archOption(b));
    const lambda_runtime = b.dependency("aws_lambda", .{
        .target = lambda_target,
    }).module("lambda");

    const lambda_mod = b.createModule(.{
        .target = lambda_target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
        .strip = true,
        .single_threaded = true,
        .imports = &.{
            .{ .name = "aws-lambda", .module = lambda_runtime },
        },
    });

    const lambda_exe = b.addExecutable(.{
        .name = "bootstrap",
        .root_module = lambda_mod,
    });

    b.installArtifact(lambda_exe);

    const host_paseto = b.dependency("zig_paseto", .{
        .target = b.graph.host,
    }).module("zig-paseto");
    const cli_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = optimize,
        .root_source_file = b.path("src/paseto_cli.zig"),
        .imports = &.{
            .{ .name = "zig-paseto", .module = host_paseto },
        },
    });
    const cli_exe = b.addExecutable(.{
        .name = "paseto",
        .root_module = cli_mod,
    });

    b.installArtifact(cli_exe);

    const test_runtime = b.dependency("aws_lambda", .{
        .target = b.graph.host,
    }).module("lambda");
    const lambda_test_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .Debug,
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{ .name = "aws-lambda", .module = test_runtime },
        },
    });
    const lambda_tests = b.addTest(.{
        .root_module = lambda_test_mod,
    });
    const run_lambda_tests = b.addRunArtifact(lambda_tests);

    const cli_test_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .Debug,
        .root_source_file = b.path("src/paseto_cli.zig"),
        .imports = &.{
            .{ .name = "zig-paseto", .module = host_paseto },
        },
    });
    const cli_tests = b.addTest(.{
        .root_module = cli_test_mod,
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_lambda_tests.step);
    test_step.dependOn(&run_cli_tests.step);
}
