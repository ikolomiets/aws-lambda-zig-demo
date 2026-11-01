const std = @import("std");
const aws = @import("aws");
const lambda = @import("aws-lambda");
const processor_message = @import("processor_message");
const operation = @import("operation");
const logging = @import("outcome_log");
const operation_persistence = @import("operation_persistence");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{
            .scope = .tiger_beetle_completion_processor,
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

comptime {
    std.debug.assert(record_count_max == 1);
    std.debug.assert(processor_message.encoded_size_max > operation.result_size_max);
}

var runtime_completion_persistence: ?CompletionPersistence = null;

pub fn main(init: std.process.Init) void {
    var resources: RuntimeResources = undefined;
    resources.init(init) catch |err| {
        var trace = logging.Context.init(.{}, .tigerbeetle_completion);
        trace.finish(.ERROR, "initialization", "retry", @errorName(err));
        trace.emit();
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
    return handle_invocation_observed(
        ctx.arena,
        event,
        persistence,
        Clock.init(&clock),
        .{ .request_id = ctx.request.id },
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

    fn complete_by_id_observed(
        resources: *RuntimeResources,
        arena: Allocator,
        operation_id: u128,
        completion: *const operation.Completion,
        now: operation.UnixSeconds,
        trace: *const logging.Context,
    ) !void {
        return resources.persistence.complete_by_id_observed(
            arena,
            operation_id,
            completion,
            now,
            trace,
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
        *const logging.Context,
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
                trace: *const logging.Context,
            ) anyerror!void {
                const self: Pointer = @ptrCast(@alignCast(context));
                if (@hasDecl(pointer_info.pointer.child, "complete_by_id_observed")) {
                    return self.complete_by_id_observed(arena, operation_id, completion, now, trace);
                }
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
        trace: *const logging.Context,
    ) !void {
        return persistence.complete_by_id_fn(
            persistence.context,
            arena,
            operation_id,
            completion,
            now,
            trace,
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
    return handle_invocation_observed(allocator, event, persistence, clock, .{});
}

fn handle_invocation_observed(
    allocator: Allocator,
    event: []const u8,
    persistence: CompletionPersistence,
    clock: Clock,
    logger: logging.Logger,
) ![]const u8 {
    var trace = logging.Context.init(logger, .tigerbeetle_completion);
    trace.record.stage = "event_parse";
    const sqs_event = lambda.sqs.parseEvent(allocator, event) catch |err| {
        trace.finish(.ERROR, "event_parse", "retry", @errorName(err));
        trace.emit();
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.MalformedSQSEvent;
    };
    defer sqs_event.deinit(allocator);
    defer trace.emit();
    if (sqs_event.records.len == 0) {
        trace.record.reason = "EmptySQSEvent";
        return error.EmptySQSEvent;
    }
    if (sqs_event.records.len > record_count_max) {
        trace.record.reason = "TooManyRecords";
        return error.TooManyRecords;
    }
    std.debug.assert(sqs_event.records.len == 1);
    const record = &sqs_event.records[0];
    trace.record.sqs_message_id = record.message_id;
    const outcome = process_record_observed(allocator, record.body, persistence, clock, &trace);
    const response = encodeFailureResponse(allocator, record.message_id, outcome == .retry) catch |err| {
        trace.finish(.ERROR, "response_encode", "retry", @errorName(err));
        return err;
    };
    return response;
}

fn processRecord(
    arena: Allocator,
    message_id: []const u8,
    body: []const u8,
    persistence: CompletionPersistence,
    clock: Clock,
) RecordOutcome {
    var trace = logging.Context.init(.{}, .tigerbeetle_completion);
    trace.record.sqs_message_id = message_id;
    defer trace.emit();
    return process_record_observed(arena, body, persistence, clock, &trace);
}

fn process_record_observed(
    arena: Allocator,
    body: []const u8,
    persistence: CompletionPersistence,
    clock: Clock,
    trace: *logging.Context,
) RecordOutcome {
    trace.record.stage = "envelope_decode";
    const message = processor_message.decode(arena, body) catch |err| {
        trace.finish(.ERROR, "envelope_decode", if (err == error.OutOfMemory) "retry" else "acknowledged_invalid", @errorName(err));
        return if (err == error.OutOfMemory) .retry else .acknowledged;
    };
    trace.identify(message.operation_id);
    trace.record.command = logging.recognized_command(&message.context);
    const result = interpret_result(&message.body) catch |err| {
        if (err == error.OutOfMemory) {
            trace.finish(.ERROR, "result_interpret", "retry", @errorName(err));
            return .retry;
        }
        trace.record.reason = @errorName(err);
        const invalid: Entry = .{
            .operation_id = message.operation_id,
            .result = .{ .failure = .{ .string = @errorName(err) } },
        };
        return persistCompletion(arena, &invalid, persistence, clock, trace);
    };
    const entry: Entry = .{ .operation_id = message.operation_id, .result = result };
    return persistCompletion(arena, &entry, persistence, clock, trace);
}

const Entry = struct {
    operation_id: u128,
    result: operation.Completion,
};

// The final processor owns terminal interpretation, including first-member replay success.
fn interpret_result(body: *const std.json.Value) !operation.Completion {
    if (body.* != .object) return error.InvalidTigerBeetleResult;
    for (body.object.keys()) |key| {
        if (!std.mem.eql(u8, key, "create_accounts") and
            !std.mem.eql(u8, key, "create_transfers") and
            !std.mem.eql(u8, key, "lookup_accounts") and
            !std.mem.eql(u8, key, "error")) return error.InvalidTigerBeetleResult;
    }
    var success = !body.object.contains("error");
    var count: usize = 0;
    for ([_][]const u8{ "create_accounts", "create_transfers", "lookup_accounts" }, 0..) |family, index| {
        const list = body.object.get(family) orelse return error.InvalidTigerBeetleResult;
        if (list != .array) return error.InvalidTigerBeetleResult;
        count += list.array.items.len;
        if (index < 2) {
            if (!try creation_success(list.array.items)) success = false;
        } else {
            for (list.array.items) |entry| {
                if (entry == .null) {
                    success = false;
                    continue;
                }
                if (entry != .object) return error.InvalidTigerBeetleResult;
                const code = entry.object.get("error_code") orelse return error.InvalidTigerBeetleResult;
                if (code != .null) return error.InvalidTigerBeetleResult;
                if (entry.object.get("account")) |account| {
                    if (account != .object or entry.object.contains("message")) return error.InvalidTigerBeetleResult;
                } else {
                    const message = entry.object.get("message") orelse return error.InvalidTigerBeetleResult;
                    if (message != .string) return error.InvalidTigerBeetleResult;
                    success = false;
                }
            }
        }
    }
    if (count == 0 and success) return error.InvalidTigerBeetleResult;
    const result: operation.Completion = if (success) .{ .success = body.* } else .{ .failure = body.* };
    _ = try operation.completionEncodedSize(&result);
    return result;
}

fn creation_success(entries: []const std.json.Value) !bool {
    if (entries.len == 0) return true;
    var created: usize = 0;
    var decisive: ?usize = null;
    var replay = false;
    var diagnostic = false;
    for (entries, 0..) |entry, index| {
        if (entry == .null) {
            diagnostic = true;
            continue;
        }
        if (entry != .object) return error.InvalidTigerBeetleResult;
        const code = entry.object.get("error_code") orelse return error.InvalidTigerBeetleResult;
        if (code == .null) {
            const message = entry.object.get("message") orelse return error.InvalidTigerBeetleResult;
            if (message != .string) return error.InvalidTigerBeetleResult;
            diagnostic = true;
            continue;
        }
        if (code != .string) return error.InvalidTigerBeetleResult;
        if (std.mem.eql(u8, code.string, "created")) {
            created += 1;
        } else if (!std.mem.eql(u8, code.string, "linked_event_failed")) {
            if (decisive != null) return error.InvalidTigerBeetleResult;
            decisive = index;
            replay = index == 0 and std.mem.eql(u8, code.string, "exists");
        }
    }
    if (diagnostic) return false;
    if (created == entries.len) return true;
    if (created != 0 or decisive == null) return error.InvalidTigerBeetleResult;
    return replay;
}

fn persistCompletion(
    arena: Allocator,
    entry: *const Entry,
    persistence: CompletionPersistence,
    clock: Clock,
    trace: *logging.Context,
) RecordOutcome {
    trace.record.stage = "persist";
    const now = clock.now();
    persistence.completeById(arena, entry.operation_id, &entry.result, now, trace) catch |err| {
        if (err == error.OperationConflict) {
            trace.finish(.INFO, "persist", "acknowledged_conflict", @errorName(err));
            return .acknowledged;
        }
        trace.finish(.ERROR, "persist", "retry", @errorName(err));
        return .retry;
    };
    trace.record.result_type = logging.result_type(&entry.result);
    trace.finish(.INFO, "persist", "finalized", trace.record.reason);
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

test "completion derives success and failure from native bodies and preserves details" {
    const cases = [_]struct { body: []const u8, success: bool }{
        .{ .body = "{\"create_accounts\":[{\"error_code\":\"created\"}],\"create_transfers\":[],\"lookup_accounts\":[]}", .success = true },
        .{ .body = "{\"create_accounts\":[{\"error_code\":\"exists\"},{\"error_code\":\"linked_event_failed\"}],\"create_transfers\":[],\"lookup_accounts\":[]}", .success = true },
        .{ .body = "{\"create_accounts\":[],\"create_transfers\":[],\"lookup_accounts\":[{\"error_code\":null,\"message\":\"Account was not found.\"}]}", .success = false },
        .{ .body = "{\"create_accounts\":[],\"create_transfers\":[{\"error_code\":\"exists\"},{\"error_code\":\"linked_event_failed\"}],\"lookup_accounts\":[]}", .success = true },
        .{ .body = "{\"create_accounts\":[],\"create_transfers\":[{\"error_code\":\"pending_transfer_has_different_amount\"}],\"lookup_accounts\":[]}", .success = false },
        .{ .body = "{\"create_accounts\":[],\"create_transfers\":[{\"error_code\":\"pending_transfer_already_posted\"}],\"lookup_accounts\":[]}", .success = false },
        .{ .body = "{\"create_accounts\":[],\"create_transfers\":[{\"error_code\":\"pending_transfer_already_voided\"}],\"lookup_accounts\":[]}", .success = false },
        .{ .body = "{\"create_accounts\":[],\"create_transfers\":[{\"error_code\":\"pending_transfer_expired\"}],\"lookup_accounts\":[]}", .success = false },
        .{ .body = "{\"create_accounts\":[{\"error_code\":\"linked_event_failed\"},{\"error_code\":\"exists\"}],\"create_transfers\":[],\"lookup_accounts\":[]}", .success = false },
        .{ .body = "{\"create_accounts\":[],\"create_transfers\":[],\"lookup_accounts\":[],\"error\":{\"message\":\"Invalid Body.\"}}", .success = false },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const input = try std.fmt.allocPrint(arena.allocator(), "{{\"operation_id\":\"" ++ test_uuid ++ "\",\"tenant\":\"tenant-a\",\"context\":null,\"body\":{s}}}", .{case.body});
        var store: FakePersistence = .{};
        const response = try test_support.invoke(arena.allocator(), input, &store);
        try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
        try std.testing.expectEqual(@as(u8, 1), store.call_count);
        try std.testing.expectEqual(case.success, store.completions[0] == .success);
        const value = switch (store.completions[0]) {
            .success, .failure => |body| body,
        };
        const actual = try std.json.Stringify.valueAlloc(arena.allocator(), value, .{});
        try std.testing.expectEqualStrings(case.body, actual);
    }
}

/// Cross-component tests enter the same SQS/codec/persistence boundary as the runtime.
pub const test_support = if (@import("builtin").is_test) struct {
    pub const interpret = interpret_result;
    pub fn invoke(allocator: Allocator, message: []const u8, store: anytype) ![]const u8 {
        var clock = FakeClock.init(&([_]operation.UnixSeconds{1_800_000_000} ** 10));
        return handleInvocation(allocator, try testEvent(allocator, &.{message}), CompletionPersistence.init(store), Clock.init(&clock));
    }
} else struct {};

test "completion retries transient writes acknowledges conflicts and never writes malformed envelopes" {
    const input = "{\"operation_id\":\"" ++ test_uuid ++ "\",\"tenant\":\"tenant-a\",\"context\":null,\"body\":{\"create_accounts\":[{\"error_code\":\"created\"}],\"create_transfers\":[],\"lookup_accounts\":[]}}";
    for ([_]?anyerror{ null, error.OperationConflict, error.AWSFailure, error.OutOfMemory }) |failure| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var store: FakePersistence = .{};
        store.errors[0] = failure;
        const response = try test_support.invoke(arena.allocator(), input, &store);
        const retry = if (failure) |err| err == error.AWSFailure or err == error.OutOfMemory else false;
        try std.testing.expectEqualStrings(if (retry)
            "{\"batchItemFailures\":[{\"itemIdentifier\":\"message-0\"}]}"
        else
            "{\"batchItemFailures\":[]}", response);
        try std.testing.expectEqual(@as(u8, 1), store.call_count);
        try std.testing.expectEqual(try operation.uuidFromString(test_uuid), store.operation_ids[0]);
        try std.testing.expectEqual(@as(i64, 1_800_000_000), store.times[0]);
    }
    for ([_][]const u8{ "{}", "{\"operation_id\":\"bad\",\"tenant\":\"tenant-a\",\"context\":null,\"body\":true}", "{\"results\":[]}" }) |invalid| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var store: FakePersistence = .{};
        try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", try test_support.invoke(arena.allocator(), invalid, &store));
        try std.testing.expectEqual(@as(u8, 0), store.call_count);
    }
}

test "valid identity with invalid native body persists diagnostic and decode allocation failure retries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = "{\"operation_id\":\"" ++ test_uuid ++ "\",\"tenant\":\"tenant-a\",\"context\":null,\"body\":true}";
    var store: FakePersistence = .{};
    _ = try test_support.invoke(arena.allocator(), input, &store);
    try std.testing.expectEqualStrings("InvalidTigerBeetleResult", store.completions[0].failure.string);
    var clock = FakeClock.init(&.{1});
    const outcome = processRecord(std.testing.failing_allocator, "source", input, CompletionPersistence.init(&store), Clock.init(&clock));
    try std.testing.expect(outcome == .retry);
    try std.testing.expectEqual(@as(u8, 1), store.call_count);
    try std.testing.expectEqual(@as(u8, 0), clock.sample_count);
}

test "completion requires exactly one SQS record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store: FakePersistence = .{};
    var clock = FakeClock.init(&.{1});
    const persistence = CompletionPersistence.init(&store);
    try std.testing.expectError(error.EmptySQSEvent, handleInvocation(arena.allocator(), try testEvent(arena.allocator(), &.{}), persistence, Clock.init(&clock)));
    try std.testing.expectError(error.TooManyRecords, handleInvocation(arena.allocator(), try testEvent(arena.allocator(), &.{ "{}", "{}" }), persistence, Clock.init(&clock)));
    try std.testing.expectError(error.MalformedSQSEvent, handleInvocation(arena.allocator(), "{}", persistence, Clock.init(&clock)));
}

test "completion summary reports durable Results, unknown conflicts and retries" {
    const cases = [_]struct { body: []const u8, failure: ?anyerror = null, outcome: []const u8, result_type: ?[]const u8 }{
        .{ .body = "{\"create_accounts\":[{\"error_code\":\"created\"}],\"create_transfers\":[],\"lookup_accounts\":[]}", .outcome = "finalized", .result_type = "SUCCESS" },
        .{ .body = "{\"create_accounts\":[],\"create_transfers\":[],\"lookup_accounts\":[null]}", .outcome = "finalized", .result_type = "FAILURE" },
        .{ .body = "true", .outcome = "finalized", .result_type = "FAILURE" },
        .{ .body = "true", .failure = error.OperationConflict, .outcome = "acknowledged_conflict", .result_type = null },
        .{ .body = "true", .failure = error.AWSFailure, .outcome = "retry", .result_type = null },
    };
    for (cases) |case| {
        var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer storage.deinit();
        const arena = storage.allocator();
        var observer = logging.TestObserver.init(arena);
        observer.fail = true;
        var store: FakePersistence = .{};
        store.errors[0] = case.failure;
        var clock = FakeClock.init(&.{1});
        const payload = try std.json.parseFromSlice(std.json.Value, arena, case.body, .{});
        const input = try processor_message.encode(arena, &.{ .operation_id = 1, .tenant = "tenant-a", .body = payload.value, .context = .null });
        const response = try handle_invocation_observed(arena, try testEvent(arena, &.{input}), CompletionPersistence.init(&store), Clock.init(&clock), observer.logger());
        const parsed = try std.json.parseFromSlice(std.json.Value, arena, response, .{});
        try std.testing.expectEqual(@as(usize, @intFromBool(if (case.failure) |err| err == error.AWSFailure else false)), parsed.value.object.get("batchItemFailures").?.array.items.len);
        try std.testing.expectEqual(@as(usize, 1), observer.records.items.len);
        const record = observer.records.items[0];
        try std.testing.expectEqualStrings(case.outcome, record.outcome);
        try std.testing.expectEqualDeep(case.result_type, record.result_type);
        try std.testing.expectEqual(@as(u8, 1), store.call_count);
    }
}

test "invalid completion envelopes log an error without claiming or persisting a Result" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var observer = logging.TestObserver.init(arena);
    var store: FakePersistence = .{};
    var clock = FakeClock.init(&.{1});
    const response = try handle_invocation_observed(arena, try testEvent(arena, &.{"invalid"}), CompletionPersistence.init(&store), Clock.init(&clock), observer.logger());
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
    try std.testing.expectEqual(@as(u8, 0), store.call_count);
    try std.testing.expectEqual(@as(usize, 1), observer.records.items.len);
    const record = observer.records.items[0];
    try std.testing.expectEqualStrings("acknowledged_invalid", record.outcome);
    try std.testing.expectEqualStrings("envelope_decode", record.stage);
    try std.testing.expectEqual(logging.Level.ERROR, record.level);
    try std.testing.expect(record.result_type == null);
}
