const std = @import("std");
const aws = @import("aws");
const lambda = @import("aws-lambda");
const operation = @import("operation");
const operation_persistence = @import("operation_persistence");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{
            .scope = .execution,
            .level = .debug,
        },
        .{
            .scope = .aws_sdk,
            .level = .debug,
        },
    },
};

const Allocator = std.mem.Allocator;
const record_count_max = 10;
const log = std.log.scoped(.execution);

comptime {
    std.debug.assert(record_count_max > 0);
    std.debug.assert(record_count_max <= 10);
}

var runtime_execution_adapter: ?ExecutionAdapter = null;

pub fn main(init: std.process.Init) void {
    var resources: RuntimeResources = undefined;
    resources.init(init) catch |err| {
        std.log.err("Lambda initialization failed: {s}", .{@errorName(err)});
        return;
    };
    defer resources.deinit();

    installRuntimeExecutionAdapter(ExecutionAdapter.init(&resources));
    defer uninstallRuntimeExecutionAdapter();
    lambda.handle(init, handler, .{});
}

fn handler(ctx: lambda.Context, event: []const u8) ![]const u8 {
    const execution = runtime_execution_adapter orelse {
        return error.PersistenceNotInitialized;
    };
    var clock: RealClock = .{ .io = ctx.io };
    return handleInvocation(ctx.arena, event, execution, Clock.init(&clock));
}

const RuntimeResources = struct {
    config: aws.Config,
    persistence: operation_persistence.Persistence,

    fn init(resources: *RuntimeResources, process_init: std.process.Init) !void {
        resources.config = aws.Config.load(
            process_init.gpa,
            process_init.io,
            process_init.environ_map,
            .{},
        ) catch return error.AWSConfigurationFailure;
        errdefer resources.config.deinit();

        operation_persistence.Persistence.init(
            &resources.persistence,
            process_init.gpa,
            &resources.config,
            process_init.environ_map,
        ) catch return error.PersistenceConfigurationFailure;
    }

    fn deinit(resources: *RuntimeResources) void {
        resources.persistence.deinit();
        resources.config.deinit();
        resources.* = undefined;
    }

    fn complete(
        resources: *RuntimeResources,
        arena: Allocator,
        submitted: *const operation.Operation,
        now: operation.UnixSeconds,
    ) !void {
        return resources.persistence.complete(arena, submitted, now);
    }
};

const ExecutionAdapter = struct {
    context: *anyopaque,
    complete_fn: *const fn (
        *anyopaque,
        Allocator,
        *const operation.Operation,
        operation.UnixSeconds,
    ) anyerror!void,

    fn init(pointer: anytype) ExecutionAdapter {
        const Pointer = @TypeOf(pointer);
        const pointer_info = @typeInfo(Pointer);
        comptime std.debug.assert(pointer_info == .pointer);
        comptime std.debug.assert(pointer_info.pointer.size == .one);

        const Adapter = struct {
            fn complete(
                context: *anyopaque,
                arena: Allocator,
                submitted: *const operation.Operation,
                now: operation.UnixSeconds,
            ) anyerror!void {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.complete(arena, submitted, now);
            }
        };
        return .{
            .context = pointer,
            .complete_fn = Adapter.complete,
        };
    }

    fn complete(
        execution: ExecutionAdapter,
        arena: Allocator,
        submitted: *const operation.Operation,
        now: operation.UnixSeconds,
    ) !void {
        return execution.complete_fn(execution.context, arena, submitted, now);
    }
};

const Clock = struct {
    context: *anyopaque,
    now_fn: *const fn (*anyopaque) operation.UnixSeconds,

    fn init(pointer: anytype) Clock {
        const Pointer = @TypeOf(pointer);
        const pointer_info = @typeInfo(Pointer);
        comptime std.debug.assert(pointer_info == .pointer);
        comptime std.debug.assert(pointer_info.pointer.size == .one);

        const Adapter = struct {
            fn now(context: *anyopaque) operation.UnixSeconds {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.now();
            }
        };
        return .{
            .context = pointer,
            .now_fn = Adapter.now,
        };
    }

    fn now(clock: Clock) operation.UnixSeconds {
        return clock.now_fn(clock.context);
    }
};

const RealClock = struct {
    io: std.Io,

    fn now(clock: *RealClock) operation.UnixSeconds {
        return std.Io.Clock.real.now(clock.io).toSeconds();
    }
};

fn installRuntimeExecutionAdapter(execution: ExecutionAdapter) void {
    std.debug.assert(runtime_execution_adapter == null);
    runtime_execution_adapter = execution;
    std.debug.assert(runtime_execution_adapter != null);
}

fn uninstallRuntimeExecutionAdapter() void {
    std.debug.assert(runtime_execution_adapter != null);
    runtime_execution_adapter = null;
    std.debug.assert(runtime_execution_adapter == null);
}

fn handleInvocation(
    allocator: Allocator,
    event: []const u8,
    execution: ExecutionAdapter,
    clock: Clock,
) ![]const u8 {
    const sqs_event = try lambda.sqs.parseEvent(allocator, event);
    defer sqs_event.deinit(allocator);

    for (sqs_event.records) |record| {
        log.debug("message_id={s} body={s}", .{ record.message_id, record.body });
        processRecord(allocator, record.message_id, record.body, execution, clock);
    }

    return lambda.sqs.encodeResponse(allocator, .{});
}

fn processRecord(
    arena: Allocator,
    message_id: []const u8,
    body: []const u8,
    execution: ExecutionAdapter,
    clock: Clock,
) void {
    const submitted = operation.parseOutputJSON(arena, body) catch |err| {
        log.debug("message_id={s} update=skipped_invalid error={s}", .{
            message_id,
            @errorName(err),
        });
        return;
    };
    validateQueuedOperation(&submitted) catch |err| {
        log.debug("message_id={s} update=skipped_invalid error={s}", .{
            message_id,
            @errorName(err),
        });
        return;
    };

    const now = clock.now();
    execution.complete(arena, &submitted, now) catch |err| {
        log.debug("message_id={s} update=failed error={s}", .{
            message_id,
            @errorName(err),
        });
        return;
    };
    log.debug("message_id={s} update=succeeded", .{message_id});
}

fn validateQueuedOperation(submitted: *const operation.Operation) !void {
    if (submitted.state != .submitted) return error.InvalidState;
    if (submitted.body == null) return error.MissingBody;
    if (submitted.result != null) return error.UnexpectedResult;
    std.debug.assert(submitted.hash != null);
    std.debug.assert(submitted.last_updated != null);
    std.debug.assert(submitted.expires_at != null);
}

const FakeExecution = struct {
    complete_count: u8 = 0,
    timestamps: [record_count_max]operation.UnixSeconds = undefined,
    errors: [record_count_max]?anyerror = .{null} ** record_count_max,

    fn complete(
        fake: *FakeExecution,
        arena: Allocator,
        submitted: *const operation.Operation,
        now: operation.UnixSeconds,
    ) !void {
        _ = arena;
        std.debug.assert(fake.complete_count < record_count_max);
        std.debug.assert(submitted.state == .submitted);
        std.debug.assert(submitted.body != null);
        std.debug.assert(submitted.result == null);
        const index = fake.complete_count;
        fake.timestamps[index] = now;
        fake.complete_count += 1;
        if (fake.errors[index]) |err| return err;
    }
};

const FakeClock = struct {
    values: [record_count_max]operation.UnixSeconds = undefined,
    count: u8 = 0,

    fn now(clock: *FakeClock) operation.UnixSeconds {
        std.debug.assert(clock.count < record_count_max);
        const value = clock.values[clock.count];
        clock.count += 1;
        return value;
    }
};

fn testMessage(allocator: Allocator, id: u128) ![]u8 {
    const submitted: operation.Operation = .{
        .id = id,
        .tenant = "tenant-a",
        .name = "echo",
        .body = .{ .bool = true },
        .state = .submitted,
        .last_updated = 1_700_000_000,
        .expires_at = 1_700_086_400,
        .hash = [_]u8{0xAB} ** 32,
    };
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try operation.writeOutputJSON(&output.writer, &submitted);
    return output.toOwnedSlice();
}

fn testEvent(allocator: Allocator, bodies: []const []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"Records\":[");
    for (bodies, 0..) |body, index| {
        if (index > 0) try output.writer.writeByte(',');
        try output.writer.print(
            "{{\"messageId\":\"message-{d}\",\"receiptHandle\":\"receipt-{d}\",\"body\":",
            .{ index, index },
        );
        try std.json.Stringify.value(body, .{}, &output.writer);
        try output.writer.writeAll(
            ",\"attributes\":{},\"messageAttributes\":{}," ++
                "\"eventSource\":\"aws:sqs\",\"eventSourceARN\":\"arn\"," ++
                "\"awsRegion\":\"ca-central-1\"}",
        );
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

test "valid records receive independently sampled completion timestamps" {
    const first = try testMessage(std.testing.allocator, 1);
    defer std.testing.allocator.free(first);
    const second = try testMessage(std.testing.allocator, 2);
    defer std.testing.allocator.free(second);
    const event = try testEvent(std.testing.allocator, &.{ first, second });
    defer std.testing.allocator.free(event);
    var fake: FakeExecution = .{};
    var clock: FakeClock = .{};
    clock.values[0] = 1_800_000_001;
    clock.values[1] = 1_800_000_002;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const response = try handleInvocation(
        arena.allocator(),
        event,
        ExecutionAdapter.init(&fake),
        Clock.init(&clock),
    );
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
    try std.testing.expectEqual(@as(u8, 2), fake.complete_count);
    try std.testing.expectEqual(@as(u8, 2), clock.count);
    try std.testing.expectEqual(@as(operation.UnixSeconds, 1_800_000_001), fake.timestamps[0]);
    try std.testing.expectEqual(@as(operation.UnixSeconds, 1_800_000_002), fake.timestamps[1]);
}

test "mixed record outcomes are processed once and acknowledged" {
    const success = try testMessage(std.testing.allocator, 1);
    defer std.testing.allocator.free(success);
    const conflict = try testMessage(std.testing.allocator, 2);
    defer std.testing.allocator.free(conflict);
    const service_failure = try testMessage(std.testing.allocator, 3);
    defer std.testing.allocator.free(service_failure);
    const bodies = [_][]const u8{ success, "{invalid", conflict, service_failure };
    const event = try testEvent(std.testing.allocator, &bodies);
    defer std.testing.allocator.free(event);
    var fake: FakeExecution = .{};
    fake.errors[1] = error.OperationConflict;
    fake.errors[2] = error.AWSFailure;
    var clock: FakeClock = .{};
    clock.values[0] = 1_800_000_001;
    clock.values[1] = 1_800_000_002;
    clock.values[2] = 1_800_000_003;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const response = try handleInvocation(
        arena.allocator(),
        event,
        ExecutionAdapter.init(&fake),
        Clock.init(&clock),
    );
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
    try std.testing.expectEqual(@as(u8, 3), fake.complete_count);
    try std.testing.expectEqual(@as(u8, 3), clock.count);
}

test "non-submitted bodyless and result-bearing operations are skipped" {
    const hash = "ab" ** 32;
    const records = [_][]const u8{
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"tenant-a\",\"name\":\"echo\",\"body\":true," ++
            "\"state\":\"RUNNING\",\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400,\"hash\":\"" ++ hash ++ "\"}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"tenant-a\",\"name\":\"echo\"," ++
            "\"state\":\"SUBMITTED\",\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400,\"hash\":\"" ++ hash ++ "\"}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"tenant-a\",\"name\":\"echo\",\"body\":true," ++
            "\"state\":\"SUBMITTED\",\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400,\"result\":null,\"hash\":\"" ++ hash ++ "\"}",
    };
    const event = try testEvent(std.testing.allocator, &records);
    defer std.testing.allocator.free(event);
    var fake: FakeExecution = .{};
    var clock: FakeClock = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const response = try handleInvocation(
        arena.allocator(),
        event,
        ExecutionAdapter.init(&fake),
        Clock.init(&clock),
    );
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
    try std.testing.expectEqual(@as(u8, 0), fake.complete_count);
    try std.testing.expectEqual(@as(u8, 0), clock.count);
}

test "malformed and non-SQS top-level events are rejected" {
    var fake: FakeExecution = .{};
    var clock: FakeClock = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.InvalidInput,
        handleInvocation(
            arena.allocator(),
            "{}",
            ExecutionAdapter.init(&fake),
            Clock.init(&clock),
        ),
    );

    const event =
        \\{"Records":[{"messageId":"message-1","receiptHandle":"receipt-1",
        \\"body":"body","attributes":{},"messageAttributes":{},
        \\"eventSource":"aws:sns","eventSourceARN":"arn","awsRegion":"region"}]}
    ;
    try std.testing.expectError(
        error.UnexpectedEventSource,
        handleInvocation(
            arena.allocator(),
            event,
            ExecutionAdapter.init(&fake),
            Clock.init(&clock),
        ),
    );
}

test "execution and AWS SDK debug logging are enabled in ReleaseSafe" {
    comptime {
        if (std_options.log_level != .info) @compileError("unexpected default log level");
        if (std_options.log_scope_levels.len != 2) @compileError("unexpected log scope count");
        if (std_options.log_scope_levels[0].scope != .execution) {
            @compileError("unexpected execution log scope");
        }
        if (std_options.log_scope_levels[0].level != .debug) {
            @compileError("execution debug logging is disabled");
        }
        if (std_options.log_scope_levels[1].scope != .aws_sdk) {
            @compileError("unexpected AWS SDK log scope");
        }
        if (std_options.log_scope_levels[1].level != .debug) {
            @compileError("AWS SDK debug logging is disabled");
        }
    }
}
