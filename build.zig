const std = @import("std");
const lambda = @import("aws_lambda");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });
    // Propagate the project's preferred mode to dependencies for bare `--release` builds.
    if (b.release_mode == .any) {
        std.debug.assert(optimize == .ReleaseSafe);
        b.release_mode = .safe;
    }
    const lambda_target = lambda.resolveTargetQuery(b, lambda.archOption(b));
    const lambda_aws_sdk = b.dependency("aws_sdk", .{
        .target = lambda_target,
        .optimize = optimize,
    });
    const lambda_aws = lambda_aws_sdk.module("aws");
    const lambda_dynamodb = lambda_aws_sdk.module("dynamodb");
    const lambda_sqs = lambda_aws_sdk.module("sqs");
    const lambda_runtime = b.dependency("aws_lambda", .{
        .target = lambda_target,
    }).module("lambda");
    const lambda_paseto_implementation = b.dependency("zig_paseto", .{
        .target = lambda_target,
    }).module("zig-paseto");
    const lambda_paseto = b.createModule(.{
        .target = lambda_target,
        .optimize = optimize,
        .root_source_file = b.path("src/paseto.zig"),
        .imports = &.{
            .{ .name = "zig-paseto", .module = lambda_paseto_implementation },
        },
    });
    const lambda_operation = b.createModule(.{
        .target = lambda_target,
        .optimize = optimize,
        .root_source_file = b.path("src/operation.zig"),
    });
    const lambda_operation_persistence = b.createModule(.{
        .target = lambda_target,
        .optimize = optimize,
        .root_source_file = b.path("src/operation_persistence.zig"),
        .imports = &.{
            .{ .name = "aws", .module = lambda_aws },
            .{ .name = "dynamodb", .module = lambda_dynamodb },
            .{ .name = "operation", .module = lambda_operation },
        },
    });
    const lambda_operation_queue = b.createModule(.{
        .target = lambda_target,
        .optimize = optimize,
        .root_source_file = b.path("src/operation_queue.zig"),
        .imports = &.{
            .{ .name = "aws", .module = lambda_aws },
            .{ .name = "sqs", .module = lambda_sqs },
        },
    });

    const lambda_mod = b.createModule(.{
        .target = lambda_target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
        .strip = true,
        .single_threaded = true,
        .imports = &.{
            .{ .name = "aws", .module = lambda_aws },
            .{ .name = "aws-lambda", .module = lambda_runtime },
            .{ .name = "operation", .module = lambda_operation },
            .{ .name = "operation_persistence", .module = lambda_operation_persistence },
            .{ .name = "operation_queue", .module = lambda_operation_queue },
            .{ .name = "paseto", .module = lambda_paseto },
        },
    });

    const lambda_exe = b.addExecutable(.{
        .name = "bootstrap",
        .root_module = lambda_mod,
    });

    b.installArtifact(lambda_exe);

    const host_aws_sdk = b.dependency("aws_sdk", .{
        .target = b.graph.host,
        .optimize = optimize,
    });
    const host_aws = host_aws_sdk.module("aws");
    const host_dynamodb = host_aws_sdk.module("dynamodb");
    const host_sqs = host_aws_sdk.module("sqs");
    const host_operation = b.createModule(.{
        .target = b.graph.host,
        .optimize = optimize,
        .root_source_file = b.path("src/operation.zig"),
    });
    const host_operation_persistence = b.createModule(.{
        .target = b.graph.host,
        .optimize = optimize,
        .root_source_file = b.path("src/operation_persistence.zig"),
        .imports = &.{
            .{ .name = "aws", .module = host_aws },
            .{ .name = "dynamodb", .module = host_dynamodb },
            .{ .name = "operation", .module = host_operation },
        },
    });
    const host_operation_queue = b.createModule(.{
        .target = b.graph.host,
        .optimize = optimize,
        .root_source_file = b.path("src/operation_queue.zig"),
        .imports = &.{
            .{ .name = "aws", .module = host_aws },
            .{ .name = "sqs", .module = host_sqs },
        },
    });
    const host_paseto_implementation = b.dependency("zig_paseto", .{
        .target = b.graph.host,
    }).module("zig-paseto");
    const host_paseto = b.createModule(.{
        .target = b.graph.host,
        .optimize = optimize,
        .root_source_file = b.path("src/paseto.zig"),
        .imports = &.{
            .{ .name = "zig-paseto", .module = host_paseto_implementation },
        },
    });
    const cli_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = optimize,
        .root_source_file = b.path("src/paseto_cli.zig"),
        .imports = &.{
            .{ .name = "paseto", .module = host_paseto },
        },
    });
    const cli_exe = b.addExecutable(.{
        .name = "paseto",
        .root_module = cli_mod,
    });

    b.installArtifact(cli_exe);

    const dynamodb_cli_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = optimize,
        .root_source_file = b.path("src/dynamodb_cli.zig"),
        .imports = &.{
            .{ .name = "aws", .module = host_aws },
            .{ .name = "operation", .module = host_operation },
            .{ .name = "operation_persistence", .module = host_operation_persistence },
        },
    });
    const dynamodb_cli_exe = b.addExecutable(.{
        .name = "dynamodb",
        .root_module = dynamodb_cli_mod,
    });

    b.installArtifact(dynamodb_cli_exe);

    const sqs_cli_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = optimize,
        .root_source_file = b.path("src/sqs_cli.zig"),
        .imports = &.{
            .{ .name = "aws", .module = host_aws },
            .{ .name = "operation", .module = host_operation },
            .{ .name = "operation_queue", .module = host_operation_queue },
        },
    });
    const sqs_cli_exe = b.addExecutable(.{
        .name = "sqs",
        .root_module = sqs_cli_mod,
    });

    b.installArtifact(sqs_cli_exe);

    const test_runtime = b.dependency("aws_lambda", .{
        .target = b.graph.host,
    }).module("lambda");
    const lambda_test_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .Debug,
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{ .name = "aws", .module = host_aws },
            .{ .name = "aws-lambda", .module = test_runtime },
            .{ .name = "operation", .module = host_operation },
            .{ .name = "operation_persistence", .module = host_operation_persistence },
            .{ .name = "operation_queue", .module = host_operation_queue },
            .{ .name = "paseto", .module = host_paseto },
        },
    });
    const lambda_tests = b.addTest(.{
        .root_module = lambda_test_mod,
    });
    const run_lambda_tests = b.addRunArtifact(lambda_tests);

    const operation_tests = b.addTest(.{
        .root_module = host_operation,
    });
    const run_operation_tests = b.addRunArtifact(operation_tests);

    const operation_persistence_tests = b.addTest(.{
        .root_module = host_operation_persistence,
    });
    const run_operation_persistence_tests = b.addRunArtifact(operation_persistence_tests);

    const operation_queue_tests = b.addTest(.{
        .root_module = host_operation_queue,
    });
    const run_operation_queue_tests = b.addRunArtifact(operation_queue_tests);

    const paseto_test_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .Debug,
        .root_source_file = b.path("src/paseto.zig"),
        .imports = &.{
            .{ .name = "zig-paseto", .module = host_paseto_implementation },
        },
    });
    const paseto_tests = b.addTest(.{
        .root_module = paseto_test_mod,
    });
    const run_paseto_tests = b.addRunArtifact(paseto_tests);

    const cli_test_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .Debug,
        .root_source_file = b.path("src/paseto_cli.zig"),
        .imports = &.{
            .{ .name = "paseto", .module = paseto_test_mod },
        },
    });
    const cli_tests = b.addTest(.{
        .root_module = cli_test_mod,
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    const dynamodb_cli_tests = b.addTest(.{
        .root_module = dynamodb_cli_mod,
    });
    const run_dynamodb_cli_tests = b.addRunArtifact(dynamodb_cli_tests);

    const sqs_cli_tests = b.addTest(.{
        .root_module = sqs_cli_mod,
    });
    const run_sqs_cli_tests = b.addRunArtifact(sqs_cli_tests);

    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_lambda_tests.step);
    test_step.dependOn(&run_operation_tests.step);
    test_step.dependOn(&run_operation_persistence_tests.step);
    test_step.dependOn(&run_operation_queue_tests.step);
    test_step.dependOn(&run_paseto_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_dynamodb_cli_tests.step);
    test_step.dependOn(&run_sqs_cli_tests.step);
}
