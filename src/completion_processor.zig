const std = @import("std");
const aws = @import("aws");
const lambda = @import("aws-lambda");
const completion_batch = @import("completion_batch");
const operation = @import("operation");
const operation_persistence = @import("operation_persistence");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{
            .scope = .completion_processor,
            .level = .debug,
        },
        .{
            .scope = .aws_sdk,
            .level = .debug,
        },
    },
};

const Allocator = std.mem.Allocator;
const record_count_max = 1;
const log = std.log.scoped(.completion_processor);

comptime {
    std.debug.assert(record_count_max == 1);
    std.debug.assert(completion_batch.encoded_message_size_max > operation.result_size_max);
}

var runtime_completion_persistence: ?CompletionPersistence = null;

pub fn main(init: std.process.Init) void {
    var resources: RuntimeResources = undefined;
    resources.init(init) catch |err| {
        std.log.err("Lambda initialization failed: {s}", .{@errorName(err)});
        return;
    };
    defer resources.deinit();

    installRuntimeCompletionPersistence(CompletionPersistence.init(&resources));
    defer uninstallRuntimeCompletionPersistence();
    lambda.handle(init, handler, .{});
}

fn handler(ctx: lambda.Context, event: []const u8) ![]const u8 {
    const persistence = runtime_completion_persistence orelse {
        return error.PersistenceNotInitialized;
    };
    var clock: RuntimeClock = .{ .io = ctx.io };
    return handleInvocation(
        ctx.arena,
        event,
        persistence,
        Clock.init(&clock),
    );
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

    fn completeById(
        resources: *RuntimeResources,
        arena: Allocator,
        operation_id: u128,
        completion: *const operation.Completion,
        now: operation.UnixSeconds,
    ) !void {
        return resources.persistence.completeById(
            arena,
            operation_id,
            completion,
            now,
        );
    }
};

const CompletionPersistence = struct {
    context: *anyopaque,
    complete_by_id_fn: *const fn (
        *anyopaque,
        Allocator,
        u128,
        *const operation.Completion,
        operation.UnixSeconds,
    ) anyerror!void,

    fn init(pointer: anytype) CompletionPersistence {
        const Pointer = @TypeOf(pointer);
        const pointer_info = @typeInfo(Pointer);
        comptime std.debug.assert(pointer_info == .pointer);
        comptime std.debug.assert(pointer_info.pointer.size == .one);

        const Adapter = struct {
            fn completeById(
                context: *anyopaque,
                arena: Allocator,
                operation_id: u128,
                completion: *const operation.Completion,
                now: operation.UnixSeconds,
            ) anyerror!void {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.completeById(arena, operation_id, completion, now);
            }
        };
        return .{
            .context = pointer,
            .complete_by_id_fn = Adapter.completeById,
        };
    }

    fn completeById(
        persistence: CompletionPersistence,
        arena: Allocator,
        operation_id: u128,
        completion: *const operation.Completion,
        now: operation.UnixSeconds,
    ) !void {
        return persistence.complete_by_id_fn(
            persistence.context,
            arena,
            operation_id,
            completion,
            now,
        );
    }
};

const RuntimeClock = struct {
    io: std.Io,

    fn now(clock: *RuntimeClock) operation.UnixSeconds {
        return std.Io.Clock.real.now(clock.io).toSeconds();
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
        return .{ .context = pointer, .now_fn = Adapter.now };
    }

    fn now(clock: Clock) operation.UnixSeconds {
        return clock.now_fn(clock.context);
    }
};

fn installRuntimeCompletionPersistence(persistence: CompletionPersistence) void {
    std.debug.assert(runtime_completion_persistence == null);
    runtime_completion_persistence = persistence;
    std.debug.assert(runtime_completion_persistence != null);
}

fn uninstallRuntimeCompletionPersistence() void {
    std.debug.assert(runtime_completion_persistence != null);
    runtime_completion_persistence = null;
    std.debug.assert(runtime_completion_persistence == null);
}

const RecordOutcome = enum {
    acknowledged,
    retry,
};

fn handleInvocation(
    allocator: Allocator,
    event: []const u8,
    persistence: CompletionPersistence,
    clock: Clock,
) ![]const u8 {
    const sqs_event = lambda.sqs.parseEvent(allocator, event) catch |err| {
        log.debug("stage=event_parse outcome=rejected error={s}", .{@errorName(err)});
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.MalformedSQSEvent;
    };
    defer sqs_event.deinit(allocator);
    if (sqs_event.records.len == 0) return error.EmptySQSEvent;
    if (sqs_event.records.len > record_count_max) return error.TooManyRecords;
    std.debug.assert(sqs_event.records.len == 1);

    const record = &sqs_event.records[0];
    log.debug("message_id={s} body_size={d}", .{ record.message_id, record.body.len });
    const outcome = processRecord(
        allocator,
        record.message_id,
        record.body,
        persistence,
        clock,
    );
    return encodeFailureResponse(
        allocator,
        record.message_id,
        outcome == .retry,
    );
}

fn processRecord(
    arena: Allocator,
    message_id: []const u8,
    body: []const u8,
    persistence: CompletionPersistence,
    clock: Clock,
) RecordOutcome {
    const batch = completion_batch.decode(arena, body) catch |err| {
        if (err == error.OutOfMemory) {
            log.debug("message_id={s} stage=decode outcome=retry error={s}", .{
                message_id,
                @errorName(err),
            });
            return .retry;
        }
        log.debug("message_id={s} stage=decode outcome=acknowledged_invalid error={s}", .{
            message_id,
            @errorName(err),
        });
        return .acknowledged;
    };
    std.debug.assert(batch.results.len > 0);
    std.debug.assert(batch.results.len <= body.len);

    for (batch.results) |decoded| {
        const entry = completionEntry(decoded) catch |err| {
            log.debug("message_id={s} stage=result outcome=acknowledged_invalid error={s}", .{
                message_id,
                @errorName(err),
            });
            continue;
        };
        if (persistCompletion(arena, message_id, &entry, persistence, clock) == .retry) {
            return .retry;
        }
    }
    return .acknowledged;
}

fn completionEntry(decoded: completion_batch.DecodedEntry) anyerror!completion_batch.Entry {
    return switch (decoded) {
        .valid => |entry| entry,
        .invalid => |invalid| {
            const operation_id = invalid.operation_id orelse return invalid.cause;
            return .{
                .operation_id = operation_id,
                .result = .{ .failure = .{ .string = @errorName(invalid.cause) } },
            };
        },
    };
}

fn persistCompletion(
    arena: Allocator,
    message_id: []const u8,
    entry: *const completion_batch.Entry,
    persistence: CompletionPersistence,
    clock: Clock,
) RecordOutcome {
    const now = clock.now();
    persistence.completeById(
        arena,
        entry.operation_id,
        &entry.result,
        now,
    ) catch |err| {
        if (err == error.OperationConflict) {
            log.debug("message_id={s} stage=persist outcome=acknowledged_conflict error={s}", .{
                message_id,
                @errorName(err),
            });
            return .acknowledged;
        }
        log.debug("message_id={s} stage=persist outcome=retry error={s}", .{
            message_id,
            @errorName(err),
        });
        return .retry;
    };
    log.debug("message_id={s} stage=persist outcome=succeeded", .{message_id});
    return .acknowledged;
}

fn encodeFailureResponse(
    allocator: Allocator,
    message_id: []const u8,
    retry: bool,
) ![]const u8 {
    const failure: [record_count_max]lambda.sqs.BatchItemFailure = .{.{
        .item_identifier = message_id,
    }};
    const failures = if (retry) failure[0..1] else failure[0..0];
    std.debug.assert(failures.len <= record_count_max);
    return lambda.sqs.encodeResponse(allocator, .{ .batch_item_failures = failures });
}

const test_call_count_max = 16;
const test_uuid = "00112233-4455-6677-8899-aabbccddeeff";
const test_uuid_2 = "ffeeddcc-bbaa-9988-7766-554433221100";

const FakePersistence = struct {
    operation_ids: [test_call_count_max]u128 = undefined,
    completions: [test_call_count_max]operation.Completion = undefined,
    times: [test_call_count_max]operation.UnixSeconds = undefined,
    errors: [test_call_count_max]?anyerror = .{null} ** test_call_count_max,
    clock: ?*const FakeClock = null,
    call_count: u8 = 0,

    fn completeById(
        fake: *FakePersistence,
        arena: Allocator,
        operation_id: u128,
        completion: *const operation.Completion,
        now: operation.UnixSeconds,
    ) !void {
        _ = arena;
        std.debug.assert(fake.call_count < test_call_count_max);
        if (fake.clock) |clock| {
            std.debug.assert(clock.sample_count == fake.call_count + 1);
        }
        const index = fake.call_count;
        fake.operation_ids[index] = operation_id;
        fake.completions[index] = completion.*;
        fake.times[index] = now;
        fake.call_count += 1;
        if (fake.errors[index]) |err| return err;
    }
};

const FakeClock = struct {
    times: [test_call_count_max]operation.UnixSeconds = undefined,
    sample_count: u8 = 0,

    fn init(times: []const operation.UnixSeconds) FakeClock {
        std.debug.assert(times.len > 0);
        std.debug.assert(times.len <= test_call_count_max);
        var clock: FakeClock = .{};
        @memcpy(clock.times[0..times.len], times);
        return clock;
    }

    fn now(clock: *FakeClock) operation.UnixSeconds {
        std.debug.assert(clock.sample_count < test_call_count_max);
        const now_value = clock.times[clock.sample_count];
        clock.sample_count += 1;
        return now_value;
    }
};

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

fn expectCompletionJSON(
    expected: []const u8,
    completion: *const operation.Completion,
) !void {
    var buffer: [operation.result_size_max]u8 = undefined;
    try std.testing.expectEqualStrings(
        expected,
        try operation.writeCompletionJSON(&buffer, completion),
    );
}

test "success and failure entries use ID-only writes and sample time per update" {
    const body = "{\"results\":[" ++
        "{\"operation_id\":\"" ++ test_uuid ++ "\"," ++
        "\"result\":{\"type\":\"SUCCESS\",\"payload\":true}}," ++
        "{\"operation_id\":\"" ++ test_uuid_2 ++ "\"," ++
        "\"result\":{\"type\":\"FAILURE\",\"payload\":\"declined\"}}]}";
    const event = try testEvent(std.testing.allocator, &.{body});
    defer std.testing.allocator.free(event);
    var persistence: FakePersistence = .{};
    var clock = FakeClock.init(&.{ 1_700_000_001, 1_700_000_002 });
    persistence.clock = &clock;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const response = try handleInvocation(
        arena.allocator(),
        event,
        CompletionPersistence.init(&persistence),
        Clock.init(&clock),
    );
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
    try std.testing.expectEqual(@as(u8, 2), persistence.call_count);
    try std.testing.expectEqual(@as(u8, 2), clock.sample_count);
    try std.testing.expectEqual(
        try operation.uuidFromString(test_uuid),
        persistence.operation_ids[0],
    );
    try std.testing.expectEqual(
        try operation.uuidFromString(test_uuid_2),
        persistence.operation_ids[1],
    );
    try std.testing.expectEqual(@as(operation.UnixSeconds, 1_700_000_001), persistence.times[0]);
    try std.testing.expectEqual(@as(operation.UnixSeconds, 1_700_000_002), persistence.times[1]);
    try expectCompletionJSON(
        "{\"type\":\"SUCCESS\",\"payload\":true}",
        &persistence.completions[0],
    );
    try expectCompletionJSON(
        "{\"type\":\"FAILURE\",\"payload\":\"declined\"}",
        &persistence.completions[1],
    );
}

test "conditional conflicts are acknowledged and later entries continue" {
    const body = "{\"results\":[" ++
        "{\"operation_id\":\"" ++ test_uuid ++ "\"," ++
        "\"result\":{\"type\":\"SUCCESS\",\"payload\":true}}," ++
        "{\"operation_id\":\"" ++ test_uuid_2 ++ "\"," ++
        "\"result\":{\"type\":\"SUCCESS\",\"payload\":false}}]}";
    const event = try testEvent(std.testing.allocator, &.{body});
    defer std.testing.allocator.free(event);
    var persistence: FakePersistence = .{};
    persistence.errors[0] = error.OperationConflict;
    var clock = FakeClock.init(&.{ 11, 12 });
    persistence.clock = &clock;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const response = try handleInvocation(
        arena.allocator(),
        event,
        CompletionPersistence.init(&persistence),
        Clock.init(&clock),
    );
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
    try std.testing.expectEqual(@as(u8, 2), persistence.call_count);
    try std.testing.expectEqual(@as(u8, 2), clock.sample_count);
}

test "transient persistence and allocation failures retry the single record" {
    const body = "{\"results\":[{\"operation_id\":\"" ++ test_uuid ++
        "\",\"result\":{\"type\":\"SUCCESS\",\"payload\":true}}]}";
    const event = try testEvent(std.testing.allocator, &.{body});
    defer std.testing.allocator.free(event);
    const errors = [_]anyerror{ error.AWSFailure, error.OutOfMemory };
    for (errors) |expected_error| {
        var persistence: FakePersistence = .{};
        persistence.errors[0] = expected_error;
        var clock = FakeClock.init(&.{1});
        persistence.clock = &clock;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const response = try handleInvocation(
            arena.allocator(),
            event,
            CompletionPersistence.init(&persistence),
            Clock.init(&clock),
        );
        try std.testing.expectEqualStrings(
            "{\"batchItemFailures\":[{\"itemIdentifier\":\"message-0\"}]}",
            response,
        );
        try std.testing.expectEqual(@as(u8, 1), persistence.call_count);
        try std.testing.expectEqual(@as(u8, 1), clock.sample_count);
    }
}

test "earlier successful entries replay as conflicts after a later transient failure" {
    const body = "{\"results\":[" ++
        "{\"operation_id\":\"" ++ test_uuid ++ "\"," ++
        "\"result\":{\"type\":\"SUCCESS\",\"payload\":true}}," ++
        "{\"operation_id\":\"" ++ test_uuid_2 ++ "\"," ++
        "\"result\":{\"type\":\"SUCCESS\",\"payload\":false}}]}";
    const event = try testEvent(std.testing.allocator, &.{body});
    defer std.testing.allocator.free(event);
    var persistence: FakePersistence = .{};
    persistence.errors[1] = error.AWSFailure;
    persistence.errors[2] = error.OperationConflict;
    var clock = FakeClock.init(&.{ 21, 22, 31, 32 });
    persistence.clock = &clock;

    var first_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer first_arena.deinit();
    const first_response = try handleInvocation(
        first_arena.allocator(),
        event,
        CompletionPersistence.init(&persistence),
        Clock.init(&clock),
    );
    try std.testing.expectEqualStrings(
        "{\"batchItemFailures\":[{\"itemIdentifier\":\"message-0\"}]}",
        first_response,
    );

    var second_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer second_arena.deinit();
    const second_response = try handleInvocation(
        second_arena.allocator(),
        event,
        CompletionPersistence.init(&persistence),
        Clock.init(&clock),
    );
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", second_response);
    try std.testing.expectEqual(@as(u8, 4), persistence.call_count);
    try std.testing.expectEqual(@as(u8, 4), clock.sample_count);
    try std.testing.expectEqual(persistence.operation_ids[0], persistence.operation_ids[2]);
    try std.testing.expectEqual(persistence.operation_ids[1], persistence.operation_ids[3]);
    try std.testing.expectEqual(@as(operation.UnixSeconds, 32), persistence.times[3]);
}

test "identifiable malformed results persist the exact validation error and continue" {
    const body = "{\"results\":[" ++
        "{\"operation_id\":\"" ++ test_uuid ++ "\",\"result\":true}," ++
        "{\"operation_id\":\"" ++ test_uuid_2 ++ "\"," ++
        "\"result\":{\"type\":\"SUCCESS\",\"payload\":true}}]}";
    const event = try testEvent(std.testing.allocator, &.{body});
    defer std.testing.allocator.free(event);
    var persistence: FakePersistence = .{};
    var clock = FakeClock.init(&.{ 41, 42 });
    persistence.clock = &clock;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const response = try handleInvocation(
        arena.allocator(),
        event,
        CompletionPersistence.init(&persistence),
        Clock.init(&clock),
    );
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
    try std.testing.expectEqual(@as(u8, 2), persistence.call_count);
    try expectCompletionJSON(
        "{\"type\":\"FAILURE\",\"payload\":\"InvalidJSON\"}",
        &persistence.completions[0],
    );
}

test "unidentifiable entries and malformed top-level messages acknowledge without writes" {
    const bodies = [_][]const u8{
        "{\"results\":[{\"operation_id\":\"not-a-uuid\",\"result\":true}]}",
        "{\"results\":true}",
        "{invalid",
    };
    for (bodies) |body| {
        const event = try testEvent(std.testing.allocator, &.{body});
        defer std.testing.allocator.free(event);
        var persistence: FakePersistence = .{};
        var clock = FakeClock.init(&.{1});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const response = try handleInvocation(
            arena.allocator(),
            event,
            CompletionPersistence.init(&persistence),
            Clock.init(&clock),
        );
        try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
        try std.testing.expectEqual(@as(u8, 0), persistence.call_count);
        try std.testing.expectEqual(@as(u8, 0), clock.sample_count);
    }
}

test "completion events require exactly one structurally valid SQS record" {
    const body = "{\"results\":[{\"operation_id\":\"" ++ test_uuid ++
        "\",\"result\":{\"type\":\"SUCCESS\",\"payload\":true}}]}";
    const empty_event = try testEvent(std.testing.allocator, &.{});
    defer std.testing.allocator.free(empty_event);
    const multiple_event = try testEvent(std.testing.allocator, &.{ body, body });
    defer std.testing.allocator.free(multiple_event);
    var persistence: FakePersistence = .{};
    var clock = FakeClock.init(&.{1});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.EmptySQSEvent,
        handleInvocation(
            arena.allocator(),
            empty_event,
            CompletionPersistence.init(&persistence),
            Clock.init(&clock),
        ),
    );
    try std.testing.expectError(
        error.TooManyRecords,
        handleInvocation(
            arena.allocator(),
            multiple_event,
            CompletionPersistence.init(&persistence),
            Clock.init(&clock),
        ),
    );
    try std.testing.expectError(
        error.MalformedSQSEvent,
        handleInvocation(
            arena.allocator(),
            "{}",
            CompletionPersistence.init(&persistence),
            Clock.init(&clock),
        ),
    );
    try std.testing.expectEqual(@as(u8, 0), persistence.call_count);
    try std.testing.expectEqual(@as(u8, 0), clock.sample_count);
}

test "completion decoding allocation failures retry before persistence" {
    var persistence: FakePersistence = .{};
    var clock = FakeClock.init(&.{1});
    const body = "{\"results\":[{\"operation_id\":\"" ++ test_uuid ++
        "\",\"result\":{\"type\":\"SUCCESS\",\"payload\":true}}]}";

    try std.testing.expectEqual(
        RecordOutcome.retry,
        processRecord(
            std.testing.failing_allocator,
            "message-0",
            body,
            CompletionPersistence.init(&persistence),
            Clock.init(&clock),
        ),
    );
    try std.testing.expectEqual(@as(u8, 0), persistence.call_count);
    try std.testing.expectEqual(@as(u8, 0), clock.sample_count);
}

test "completion handler tests run in ReleaseSafe" {
    const builtin = @import("builtin");
    try std.testing.expectEqual(std.builtin.OptimizeMode.ReleaseSafe, builtin.mode);
}

test "completion declares debug log scopes for ReleaseSafe" {
    try std.testing.expectEqual(@as(usize, 2), std_options.log_scope_levels.len);
    try std.testing.expect(std_options.log_scope_levels[0].scope == .completion_processor);
    try std.testing.expectEqual(.debug, std_options.log_scope_levels[0].level);
    try std.testing.expect(std_options.log_scope_levels[1].scope == .aws_sdk);
    try std.testing.expectEqual(.debug, std_options.log_scope_levels[1].level);
}
