const std = @import("std");
const lambda = @import("aws_lambda");

const tigerbeetle_c_import_name = "tigerbeetle_c";
const tigerbeetle_import_name = "tigerbeetle";

fn add_tigerbeetle_c_module(
    b: *std.Build,
    tigerbeetle_c_artifacts: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const translated_c = b.addTranslateC(.{
        .root_source_file = tigerbeetle_c_artifacts.path("include/tb_client.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const module = translated_c.createModule();
    std.debug.assert(module.link_libc == true);
    module.addObjectFile(tigerbeetle_c_artifacts.path(tigerbeetle_archive_path(target.result)));
    module.linkSystemLibrary("m", .{ .needed = true, .use_pkg_config = .no });
    module.linkSystemLibrary("dl", .{ .needed = true, .use_pkg_config = .no });
    return module;
}

fn add_tigerbeetle_module(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tigerbeetle_c: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/tigerbeetle.zig"),
        // TigerBeetle completes packets from its native client thread.
        .single_threaded = false,
        .imports = &.{
            .{ .name = tigerbeetle_c_import_name, .module = tigerbeetle_c },
        },
    });
}

fn tigerbeetle_archive_path(target: std.Target) []const u8 {
    if (target.cpu.arch != .aarch64) {
        tigerbeetle_target_unsupported(target);
    }

    return switch (target.os.tag) {
        .macos => "lib/aarch64-macos/libtb_client.a",
        .linux => if (target.isGnuLibC())
            "lib/aarch64-linux-gnu.2.27/libtb_client.a"
        else
            tigerbeetle_target_unsupported(target),
        else => tigerbeetle_target_unsupported(target),
    };
}

fn tigerbeetle_target_unsupported(target: std.Target) noreturn {
    std.debug.panic(
        "unsupported TigerBeetle C target {s}-{s}-{s}; " ++
            "expected aarch64-macos or glibc aarch64-linux",
        .{ @tagName(target.cpu.arch), @tagName(target.os.tag), @tagName(target.abi) },
    );
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });
    // Propagate the project's preferred mode to dependencies for bare `--release` builds.
    if (b.release_mode == .any) {
        std.debug.assert(optimize == .ReleaseSafe);
        b.release_mode = .safe;
    }
    const tigerbeetle_c_artifacts = b.dependency("tigerbeetle_c_artifacts", .{});
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
    const lambda_auth = b.createModule(.{
        .target = lambda_target,
        .optimize = optimize,
        .root_source_file = b.path("src/lambda_auth.zig"),
        .imports = &.{
            .{ .name = "aws-lambda", .module = lambda_runtime },
            .{ .name = "paseto", .module = lambda_paseto },
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

    const intake_lambda_mod = b.createModule(.{
        .target = lambda_target,
        .optimize = optimize,
        .root_source_file = b.path("src/intake_lambda.zig"),
        .strip = true,
        .single_threaded = true,
        .imports = &.{
            .{ .name = "aws", .module = lambda_aws },
            .{ .name = "aws-lambda", .module = lambda_runtime },
            .{ .name = "lambda_auth", .module = lambda_auth },
            .{ .name = "operation", .module = lambda_operation },
            .{ .name = "operation_persistence", .module = lambda_operation_persistence },
            .{ .name = "operation_queue", .module = lambda_operation_queue },
        },
    });

    const intake_lambda_exe = b.addExecutable(.{
        .name = "intake-bootstrap",
        .root_module = intake_lambda_mod,
    });
    const install_intake_lambda = b.addInstallArtifact(intake_lambda_exe, .{
        .dest_dir = .{ .override = .{ .custom = "bin/intake" } },
        .dest_sub_path = "bootstrap",
    });
    b.getInstallStep().dependOn(&install_intake_lambda.step);

    const query_lambda_mod = b.createModule(.{
        .target = lambda_target,
        .optimize = optimize,
        .root_source_file = b.path("src/query_lambda.zig"),
        .strip = true,
        .single_threaded = true,
        .imports = &.{
            .{ .name = "aws", .module = lambda_aws },
            .{ .name = "aws-lambda", .module = lambda_runtime },
            .{ .name = "lambda_auth", .module = lambda_auth },
            .{ .name = "operation", .module = lambda_operation },
            .{ .name = "operation_persistence", .module = lambda_operation_persistence },
        },
    });
    const query_lambda_exe = b.addExecutable(.{
        .name = "query-bootstrap",
        .root_module = query_lambda_mod,
    });
    const install_query_lambda = b.addInstallArtifact(query_lambda_exe, .{
        .dest_dir = .{ .override = .{ .custom = "bin/query" } },
        .dest_sub_path = "bootstrap",
    });
    b.getInstallStep().dependOn(&install_query_lambda.step);

    const execution_lambda_mod = b.createModule(.{
        .target = lambda_target,
        .optimize = optimize,
        .root_source_file = b.path("src/execution_lambda.zig"),
        .strip = true,
        .single_threaded = true,
        .imports = &.{
            .{ .name = "aws", .module = lambda_aws },
            .{ .name = "aws-lambda", .module = lambda_runtime },
            .{ .name = "operation", .module = lambda_operation },
            .{ .name = "operation_persistence", .module = lambda_operation_persistence },
        },
    });
    const execution_lambda_exe = b.addExecutable(.{
        .name = "execution-bootstrap",
        .root_module = execution_lambda_mod,
    });
    const install_execution_lambda = b.addInstallArtifact(execution_lambda_exe, .{
        .dest_dir = .{ .override = .{ .custom = "bin/execution" } },
        .dest_sub_path = "bootstrap",
    });
    b.getInstallStep().dependOn(&install_execution_lambda.step);

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
    const test_runtime = b.dependency("aws_lambda", .{
        .target = b.graph.host,
    }).module("lambda");
    const host_lambda_auth = b.createModule(.{
        .target = b.graph.host,
        .optimize = .Debug,
        .root_source_file = b.path("src/lambda_auth.zig"),
        .imports = &.{
            .{ .name = "aws-lambda", .module = test_runtime },
            .{ .name = "paseto", .module = host_paseto },
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

    const persistence_cli_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = optimize,
        .root_source_file = b.path("src/persistence_cli.zig"),
        .imports = &.{
            .{ .name = "aws", .module = host_aws },
            .{ .name = "operation", .module = host_operation },
            .{ .name = "operation_persistence", .module = host_operation_persistence },
        },
    });
    const persistence_cli_exe = b.addExecutable(.{
        .name = "dynamodb",
        .root_module = persistence_cli_mod,
    });

    b.installArtifact(persistence_cli_exe);

    const queue_cli_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = optimize,
        .root_source_file = b.path("src/queue_cli.zig"),
        .imports = &.{
            .{ .name = "aws", .module = host_aws },
            .{ .name = "operation", .module = host_operation },
            .{ .name = "operation_queue", .module = host_operation_queue },
        },
    });
    const queue_cli_exe = b.addExecutable(.{
        .name = "sqs",
        .root_module = queue_cli_mod,
    });

    b.installArtifact(queue_cli_exe);

    const lambda_test_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .Debug,
        .root_source_file = b.path("src/intake_lambda.zig"),
        .imports = &.{
            .{ .name = "aws", .module = host_aws },
            .{ .name = "aws-lambda", .module = test_runtime },
            .{ .name = "lambda_auth", .module = host_lambda_auth },
            .{ .name = "operation", .module = host_operation },
            .{ .name = "operation_persistence", .module = host_operation_persistence },
            .{ .name = "operation_queue", .module = host_operation_queue },
        },
    });
    const lambda_tests = b.addTest(.{
        .root_module = lambda_test_mod,
    });
    const run_lambda_tests = b.addRunArtifact(lambda_tests);

    const query_test_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .Debug,
        .root_source_file = b.path("src/query_lambda.zig"),
        .imports = &.{
            .{ .name = "aws", .module = host_aws },
            .{ .name = "aws-lambda", .module = test_runtime },
            .{ .name = "lambda_auth", .module = host_lambda_auth },
            .{ .name = "operation", .module = host_operation },
            .{ .name = "operation_persistence", .module = host_operation_persistence },
        },
    });
    const query_tests = b.addTest(.{
        .root_module = query_test_mod,
    });
    const run_query_tests = b.addRunArtifact(query_tests);

    const execution_test_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .root_source_file = b.path("src/execution_lambda.zig"),
        .imports = &.{
            .{ .name = "aws", .module = host_aws },
            .{ .name = "aws-lambda", .module = test_runtime },
            .{ .name = "operation", .module = host_operation },
            .{ .name = "operation_persistence", .module = host_operation_persistence },
        },
    });
    const execution_tests = b.addTest(.{
        .root_module = execution_test_mod,
    });
    const run_execution_tests = b.addRunArtifact(execution_tests);

    const lambda_auth_tests = b.addTest(.{
        .root_module = host_lambda_auth,
    });
    const run_lambda_auth_tests = b.addRunArtifact(lambda_auth_tests);

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

    const persistence_cli_tests = b.addTest(.{
        .root_module = persistence_cli_mod,
    });
    const run_persistence_cli_tests = b.addRunArtifact(persistence_cli_tests);

    const queue_cli_tests = b.addTest(.{
        .root_module = queue_cli_mod,
    });
    const run_queue_cli_tests = b.addRunArtifact(queue_cli_tests);

    const tigerbeetle_c_host = add_tigerbeetle_c_module(
        b,
        tigerbeetle_c_artifacts,
        b.graph.host,
        .Debug,
    );
    const tigerbeetle_c_abi_macos_test_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .Debug,
        .root_source_file = b.path("src/tigerbeetle_c_abi_test.zig"),
        .imports = &.{
            .{ .name = tigerbeetle_c_import_name, .module = tigerbeetle_c_host },
        },
    });
    const tigerbeetle_c_abi_macos_test = b.addTest(.{
        .root_module = tigerbeetle_c_abi_macos_test_mod,
    });
    const run_tigerbeetle_c_abi_macos_test = b.addRunArtifact(
        tigerbeetle_c_abi_macos_test,
    );
    const tigerbeetle_c_abi_macos_step = b.step(
        "test-tigerbeetle-c-abi",
        "Run the TigerBeetle C ABI smoke test on Apple Silicon macOS",
    );
    tigerbeetle_c_abi_macos_step.dependOn(&run_tigerbeetle_c_abi_macos_test.step);

    const tigerbeetle_host = add_tigerbeetle_module(
        b,
        b.graph.host,
        .Debug,
        tigerbeetle_c_host,
    );
    const tigerbeetle_tests = b.addTest(.{
        .name = tigerbeetle_import_name,
        .root_module = tigerbeetle_host,
    });
    const run_tigerbeetle_tests = b.addRunArtifact(tigerbeetle_tests);
    const tigerbeetle_test_step = b.step(
        "test-tigerbeetle-wrapper",
        "Run the offline TigerBeetle Zig wrapper tests",
    );
    tigerbeetle_test_step.dependOn(&run_tigerbeetle_tests.step);

    const tigerbeetle_integration_test_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .Debug,
        .root_source_file = b.path("tests/tigerbeetle_integration.zig"),
        .imports = &.{
            .{ .name = tigerbeetle_import_name, .module = tigerbeetle_host },
            .{ .name = tigerbeetle_c_import_name, .module = tigerbeetle_c_host },
        },
    });
    const tigerbeetle_integration_tests = b.addTest(.{
        .name = "tigerbeetle-integration",
        .root_module = tigerbeetle_integration_test_mod,
    });
    const run_tigerbeetle_integration_tests = b.addRunArtifact(
        tigerbeetle_integration_tests,
    );
    const tigerbeetle_integration_test_step = b.step(
        "test-tigerbeetle",
        "Run live TigerBeetle integration tests against 127.0.0.1:3000",
    );
    tigerbeetle_integration_test_step.dependOn(
        &run_tigerbeetle_integration_tests.step,
    );

    const tigerbeetle_linux_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .gnu,
        .glibc_version = .{ .major = 2, .minor = 27, .patch = 0 },
    });
    const tigerbeetle_c_linux = add_tigerbeetle_c_module(
        b,
        tigerbeetle_c_artifacts,
        tigerbeetle_linux_target,
        .Debug,
    );
    const tigerbeetle_c_abi_linux_test_mod = b.createModule(.{
        .target = tigerbeetle_linux_target,
        .optimize = .Debug,
        .root_source_file = b.path("src/tigerbeetle_c_abi_test.zig"),
        .imports = &.{
            .{ .name = tigerbeetle_c_import_name, .module = tigerbeetle_c_linux },
        },
    });
    const tigerbeetle_c_abi_linux_test = b.addTest(.{
        .root_module = tigerbeetle_c_abi_linux_test_mod,
    });
    const tigerbeetle_c_abi_linux_output = b.addWriteFiles();
    _ = tigerbeetle_c_abi_linux_output.addCopyFile(
        tigerbeetle_c_abi_linux_test.getEmittedBin(),
        "tigerbeetle-c-abi-linux",
    );
    const tigerbeetle_c_abi_linux_step = b.step(
        "test-tigerbeetle-c-abi-linux",
        "Compile the TigerBeetle C ABI smoke test for glibc ARM64 Linux",
    );
    tigerbeetle_c_abi_linux_step.dependOn(&tigerbeetle_c_abi_linux_output.step);

    const tigerbeetle_linux = add_tigerbeetle_module(
        b,
        tigerbeetle_linux_target,
        .Debug,
        tigerbeetle_c_linux,
    );
    const tigerbeetle_linux_test = b.addTest(.{
        .name = tigerbeetle_import_name,
        .root_module = tigerbeetle_linux,
    });
    const tigerbeetle_linux_output = b.addWriteFiles();
    _ = tigerbeetle_linux_output.addCopyFile(
        tigerbeetle_linux_test.getEmittedBin(),
        "tigerbeetle-wrapper-linux",
    );
    const tigerbeetle_linux_step = b.step(
        "test-tigerbeetle-wrapper-linux",
        "Compile the TigerBeetle Zig wrapper tests for glibc ARM64 Linux",
    );
    tigerbeetle_linux_step.dependOn(&tigerbeetle_linux_output.step);

    const wireguard_discovery_test = b.addSystemCommand(&.{"bash"});
    wireguard_discovery_test.addFileArg(
        b.path("tests/deploy_wireguard_discovery_test.sh"),
    );

    const cleanup_lifecycle_test = b.addSystemCommand(&.{"bash"});
    cleanup_lifecycle_test.addFileArg(
        b.path("tests/deploy_cleanup_lifecycle_test.sh"),
    );

    const deploy_test_step = b.step(
        "test-deploy",
        "Run deployment helper regression tests",
    );
    deploy_test_step.dependOn(&wireguard_discovery_test.step);
    deploy_test_step.dependOn(&cleanup_lifecycle_test.step);

    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_lambda_auth_tests.step);
    test_step.dependOn(&run_query_tests.step);
    test_step.dependOn(&run_execution_tests.step);
    test_step.dependOn(&run_lambda_tests.step);
    test_step.dependOn(&run_operation_tests.step);
    test_step.dependOn(&run_operation_persistence_tests.step);
    test_step.dependOn(&run_operation_queue_tests.step);
    test_step.dependOn(&run_paseto_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_persistence_cli_tests.step);
    test_step.dependOn(&run_queue_cli_tests.step);
    test_step.dependOn(&run_tigerbeetle_tests.step);
    test_step.dependOn(deploy_test_step);
}
