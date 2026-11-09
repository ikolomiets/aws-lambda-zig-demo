const std = @import("std");
const aws = @import("aws");
const dynamodb = @import("dynamodb");
const lambda = @import("aws-lambda");
const operation = @import("operation");
const operations = @import("operation_persistence");
const messages = @import("processor_message");
const seat = @import("seat_reservation");
const events = @import("seat_reservation_persistence");
const submission = @import("seat_reservation_processor");
const logging = @import("outcome_log");
const Allocator = std.mem.Allocator;
const test_support = @import("seat_test_support");
const runtime_tests_enabled = if (@import("builtin").is_test)
    @import("runtime_test_options").enabled
else
    false;

pub const Options = struct {
    logger: logging.Logger = .{},
    operations_table: []const u8,
    events_table: []const u8 = "Events",
    now: operation.UnixSeconds,
    response_allocator: ?Allocator = null,
    ready_cache: ?*events.ReadyCache = null,
};
var runtime: ?*const InvocationAdapter = null;

pub fn main(init: std.process.Init) void {
    var resources: Runtime = undefined;
    resources.init(init) catch |err| {
        var trace = logging.Context.init(.{}, .seat_completion);
        trace.finish(.ERROR, "initialization", "retry", @errorName(err));
        trace.emit();
        return;
    };
    defer resources.deinit();
    var adapter: InvocationAdapter = undefined;
    adapter.init(&resources, &.{
        .operations_table = resources.persistence.table_name,
        .events_table = resources.events_table,
        .now = 0, // Replaced by the handler's current invocation clock.
        .ready_cache = &resources.ready_cache,
    });
    install_runtime_adapter(&adapter);
    defer uninstall_runtime_adapter();
    lambda.handle(init, handler, .{});
}

fn handler(context: lambda.Context, input: []const u8) ![]const u8 {
    const adapter = runtime orelse return error.NotInitialized;
    var options = adapter.options;
    options.logger.request_id = context.request.id;
    options.now = std.Io.Clock.real.now(context.io).toSeconds();
    return adapter.invoke(adapter.backend, context.arena, input, &options);
}

// Erase only the backend type; every adapter runs the same invocation implementation.
const InvocationAdapter = struct {
    backend: *anyopaque,
    options: Options,
    invoke: *const fn (*anyopaque, Allocator, []const u8, *const Options) anyerror![]const u8,

    fn init(self: *InvocationAdapter, backend: anytype, options: *const Options) void {
        const Pointer = @TypeOf(backend);
        comptime std.debug.assert(@typeInfo(Pointer) == .pointer);
        comptime std.debug.assert(@typeInfo(Pointer).pointer.size == .one);
        const Bridge = struct {
            fn invoke(
                pointer: *anyopaque,
                arena: Allocator,
                input: []const u8,
                invocation_options: *const Options,
            ) anyerror![]const u8 {
                const typed_backend: Pointer = @ptrCast(@alignCast(pointer));
                return handle_invocation(arena, input, invocation_options, typed_backend);
            }
        };
        self.* = .{ .backend = backend, .options = options.*, .invoke = Bridge.invoke };
    }
};

fn install_runtime_adapter(adapter: *const InvocationAdapter) void {
    std.debug.assert(runtime == null);
    runtime = adapter;
    std.debug.assert(runtime != null);
}

fn uninstall_runtime_adapter() void {
    std.debug.assert(runtime != null);
    runtime = null;
    std.debug.assert(runtime == null);
}

const Runtime = struct {
    config: aws.Config,
    persistence: operations.Persistence,
    events_table: []const u8,
    ready_cache: events.ReadyCache,

    fn init(self: *Runtime, process_init: std.process.Init) !void {
        self.events_table = process_init.environ_map.get("EVENTS_TABLE_NAME") orelse
            return error.InvalidConfiguration;
        try events.validate_table_name(self.events_table);
        self.config = try aws.Config.load(
            process_init.gpa,
            process_init.io,
            process_init.environ_map,
            .{ .max_attempts = 1 },
        );
        errdefer self.config.deinit();
        try self.persistence.init(process_init.gpa, &self.config, process_init.environ_map);
        errdefer self.persistence.deinit();
        try self.ready_cache.init(process_init.gpa, events.ReadyCache.budget_bytes_max);
    }

    fn deinit(self: *Runtime) void {
        self.ready_cache.deinit();
        self.persistence.deinit();
        self.config.deinit();
    }
};

const RuntimeEffects = struct {
    resources: *Runtime,
    trace: *logging.Context,
    pub fn get(
        self: *RuntimeEffects,
        arena: Allocator,
        request: dynamodb.GetItemInput,
    ) !?[]const aws.map.MapEntry(dynamodb.types.AttributeValue) {
        self.trace.record.stage = if (std.mem.eql(u8, request.table_name, self.resources.persistence.table_name)) "winner_read" else "event_read";
        var diagnostic: dynamodb.ServiceError = undefined;
        const response = self.resources.persistence.client.getItem(
            arena,
            request,
            .{ .diagnostic = &diagnostic },
        ) catch |err| {
            self.trace.aws_error(err, &diagnostic);
            if (err == error.ServiceError) diagnostic.deinit();
            return error.AWSFailure;
        };
        return response.item;
    }

    pub fn update(self: *RuntimeEffects, arena: Allocator, request: dynamodb.types.Update) !void {
        self.trace.record.stage = "persist";
        var diagnostic: dynamodb.ServiceError = undefined;
        _ = self.resources.persistence.client.updateItem(arena, .{
            .table_name = request.table_name,
            .key = request.key,
            .condition_expression = request.condition_expression,
            .expression_attribute_names = request.expression_attribute_names,
            .expression_attribute_values = request.expression_attribute_values,
            .update_expression = request.update_expression,
        }, .{ .diagnostic = &diagnostic }) catch |err| {
            self.trace.aws_error(err, &diagnostic);
            if (err == error.ServiceError) diagnostic.deinit();
            return error.AWSFailure;
        };
    }

    pub fn report(_: *RuntimeEffects, diagnostic: []const u8) !void {
        std.log.err("{s}", .{diagnostic});
    }

    pub fn transact_write(
        self: *RuntimeEffects,
        arena: Allocator,
        request: dynamodb.TransactWriteItemsInput,
    ) !void {
        self.trace.record.stage = "creation_persist";
        var diagnostic: dynamodb.ServiceError = undefined;
        _ = self.resources.persistence.client.transactWriteItems(arena, request, .{
            .diagnostic = &diagnostic,
        }) catch |err| {
            self.trace.aws_error(err, &diagnostic);
            if (err == error.ServiceError) diagnostic.deinit();
            return error.AWSFailure;
        };
    }

    pub fn transact_get(
        self: *RuntimeEffects,
        arena: Allocator,
        request: dynamodb.TransactGetItemsInput,
    ) !dynamodb.TransactGetItemsOutput {
        self.trace.record.stage = "creation_winner_read";
        var diagnostic: dynamodb.ServiceError = undefined;
        const response = self.resources.persistence.client.transactGetItems(arena, request, .{
            .diagnostic = &diagnostic,
        }) catch |err| {
            self.trace.aws_error(err, &diagnostic);
            if (err == error.ServiceError) diagnostic.deinit();
            return error.AWSFailure;
        };
        self.trace.record.stage = "creation_finalize";
        return response;
    }
};

pub fn handle_invocation(
    arena: Allocator,
    input: []const u8,
    options: *const Options,
    backend: anytype,
) ![]const u8 {
    var trace = logging.Context.init(options.logger, .seat_completion);
    trace.record.stage = "event_parse";
    const event = submission.parse_event(arena, input) catch |err| {
        trace.record.reason = @errorName(err);
        trace.emit();
        return err;
    };
    defer event.deinit(arena);
    defer trace.emit();
    const record = &event.records[0];
    trace.record.sqs_message_id = record.message_id;
    const retry = if (comptime @TypeOf(backend) == *Runtime) scoped: {
        var effects: RuntimeEffects = .{ .resources = backend, .trace = &trace };
        break :scoped process_record(arena, record.message_id, record.body, options, &trace, &effects);
    } else process_record(arena, record.message_id, record.body, options, &trace, backend);
    const should_retry = retry catch |err| failed: {
        trace.finish(.ERROR, trace.record.stage, "retry", @errorName(err));
        break :failed true;
    };
    return submission.encode_response(options.response_allocator orelse arena, record.message_id, should_retry) catch |err| {
        trace.finish(.ERROR, "response_encode", "retry", @errorName(err));
        return err;
    };
}

fn process_record(
    arena: Allocator,
    sqs_id: []const u8,
    input: []const u8,
    options: *const Options,
    trace: *logging.Context,
    backend: anytype,
) anyerror!bool {
    trace.record.stage = "envelope_decode";
    const message = messages.decode(arena, input) catch |err| {
        if (err == error.OutOfMemory) return err;
        trace.finish(.ERROR, trace.record.stage, "acknowledged_invalid", @errorName(err));
        submission.diagnose(arena, .completion, @errorName(err), sqs_id, input, null, backend);
        return false;
    };
    trace.identify(message.operation_id);
    trace.record.command = logging.recognized_command(&message.context);
    if (message.result_queue != null) {
        trace.finish(.ERROR, "envelope_validate", "acknowledged_invalid", "ResultQueueOverride");
        submission.diagnose(
            arena,
            .completion,
            "ResultQueueOverride",
            sqs_id,
            input,
            &message,
            backend,
        );
        return false;
    }
    trace.record.stage = "finalization";
    const outcome = if (message.body == .object and message.body.object.contains("code"))
        complete_local(arena, &message, options, trace, backend)
    else
        complete_native(arena, &message, options, trace, backend);
    const summary = outcome catch |err| {
        switch (err) {
            error.InvalidNativeEvidence,
            error.InconsistentCreation,
            error.InvalidItem,
            error.EventConflict,
            error.InvalidLocalFailure,
            error.InconsistentOperation,
            => {
                trace.finish(.ERROR, trace.record.stage, "acknowledged_invalid", @errorName(err));
                submission.diagnose(
                    arena,
                    .completion,
                    @errorName(err),
                    sqs_id,
                    input,
                    &message,
                    backend,
                );
                return false;
            },
            else => return err,
        }
    };
    trace.record.result_type = logging.result_type(&summary.result);
    if (summary.result == .failure and summary.result.failure == .object) {
        if (summary.result.failure.object.get("code")) |code| {
            if (code == .string) trace.record.failure_code = code.string;
        }
    }
    trace.finish(.INFO, "finalization", if (summary.winner) "winner_observed" else "finalized", null);
    return false;
}

fn complete_local(
    arena: Allocator,
    message: *const messages.Message,
    options: *const Options,
    trace: *logging.Context,
    backend: anytype,
) !events.Finalization {
    trace.record.stage = "local_validate";
    const code = seat.local_failure(&message.body) catch return error.InvalidLocalFailure;
    trace.record.stage = "result_encode";
    const result_json = try seat.encode_result(arena, &.{ .failure = code });
    return finalize_operation(arena, message, result_json, options, trace, backend);
}

fn finalize_operation(
    arena: Allocator,
    message: *const messages.Message,
    result_json: []const u8,
    options: *const Options,
    trace: *logging.Context,
    backend: anytype,
) !events.Finalization {
    trace.record.stage = "finalization_encode";
    const result = try operation.parseCompletionJSON(arena, result_json);
    const update = try operations.seat_completion_update(
        arena,
        options.operations_table,
        &.{ .id = message.operation_id, .tenant = message.tenant },
        &result,
        options.now,
    );
    trace.record.stage = "persist";
    backend.update(arena, update) catch {
        // A failed condition or lost response proves nothing without authoritative readback.
        return .{ .winner = true, .result = try read_winner(arena, options.operations_table, message, trace, backend) };
    };
    return .{ .winner = false, .result = result };
}

fn complete_native(
    arena: Allocator,
    message: *const messages.Message,
    options: *const Options,
    trace: *logging.Context,
    backend: anytype,
) !events.Finalization {
    trace.record.stage = "context_decode";
    const context_json = try seat.encode_bounded(arena, message.context, messages.context_size_max);
    const context = seat.decode_context(arena, context_json) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidNativeEvidence;
    };
    if (context.command != .create_event) {
        return complete_ready(arena, message, &context, options, trace, backend);
    }
    trace.record.stage = "event_read";
    const saved = events.read_event(arena, options.events_table, &.{
        .tenant = message.tenant,
        .event_id = message.operation_id,
    }, backend) catch |err| {
        if (err == error.EventUnavailable) return error.InconsistentCreation;
        return err;
    };
    trace.record.stage = "event_validate";
    try seat.validate_configuration(&context.command.create_event, &saved);
    trace.record.stage = "evidence_validate";
    const projected = seat.creation_result(arena, &message.body, &saved) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidNativeEvidence;
    };
    trace.record.stage = "result_encode";
    const result_json = try seat.encode_result(arena, &projected);
    const result = try operation.parseCompletionJSON(arena, result_json);
    trace.record.stage = "creation_finalize";
    return events.finalize_creation(arena, &.{
        .events_table = options.events_table,
        .operations_table = options.operations_table,
        .now = options.now,
    }, &saved, &result, backend);
}

fn complete_ready(
    arena: Allocator,
    message: *const messages.Message,
    context: *const seat.Context,
    options: *const Options,
    trace: *logging.Context,
    backend: anytype,
) !events.Finalization {
    const event_id = switch (context.command) {
        .reserve_seats => |reserve| reserve.event_id,
        .confirm_seats => |confirm| confirm.event_id,
        .check_seats => |id| id,
        else => unreachable,
    };
    trace.record.stage = "event_read";
    const saved = events.read_cached_event(arena, options.events_table, &.{
        .tenant = message.tenant,
        .event_id = event_id,
    }, options.ready_cache, backend) catch |err| {
        if (err == error.EventUnavailable) return error.InvalidNativeEvidence;
        return err;
    };
    trace.record.stage = "evidence_validate";
    const projected = (switch (context.command) {
        .reserve_seats => seat.reservation_result(&message.body, &saved, context),
        .confirm_seats => seat.confirmation_result(&message.body, &saved, context),
        .check_seats => seat.availability_result(arena, &message.body, &saved),
        else => unreachable,
    }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidNativeEvidence;
    };
    trace.record.stage = "result_encode";
    const result_json = try seat.encode_result(arena, &projected);
    return finalize_operation(arena, message, result_json, options, trace, backend);
}

fn read_winner(
    arena: Allocator,
    table: []const u8,
    message: *const messages.Message,
    trace: *logging.Context,
    backend: anytype,
) !operation.Completion {
    trace.record.stage = "winner_read";
    const request = try operations.read_request(arena, table, message.operation_id);
    const item = try backend.get(arena, request) orelse return error.InconsistentOperation;
    trace.record.stage = "winner_validate";
    const saved = try operations.decode_item(arena, item);
    if (saved.id != message.operation_id) return error.InconsistentOperation;
    if (!std.mem.eql(u8, saved.tenant, message.tenant)) return error.InconsistentOperation;
    if (!std.mem.eql(u8, saved.name, "SeatReservation")) return error.InconsistentOperation;
    switch (saved.state) {
        .submitted => return error.RetryFinalization,
        .completed => |*result| seat.validate_completion(result) catch
            return error.InconsistentOperation,
    }
    return saved.state.completed;
}

// Replace only external effects while exercising both processors' real codecs and adapters.
fn submit_test_confirmation(arena: Allocator, body: []const u8, backend: anytype) !messages.Message {
    const input = try test_support.submission_message(arena, 5, body);
    const response = try submission.handle_invocation(
        arena,
        try test_support.sqs_event(arena, "confirmation", input),
        &.{ .events_table = "Events", .native_queue = "native", .completion_queue = "completion" },
        backend,
    );
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
    try std.testing.expectEqual(@as(usize, 1), backend.effects.published);
    return messages.decode(arena, backend.outputs[0].body);
}

test "confirmation flows through submission native evidence and completion" {
    const cases = [_]struct {
        status: []const u8,
        failure: ?seat.FailureCode = null,
        alias: []const u8 = "confirm",
        inconsistent: bool = false,
    }{
        .{ .status = "created" },
        .{ .status = "exists" },
        .{ .status = "pending_transfer_already_posted" },
        .{ .status = "pending_transfer_expired", .failure = .reservation_expired },
        .{ .status = "pending_transfer_not_found", .failure = .invalid_reservation },
        .{ .status = "pending_transfer_not_pending", .failure = .invalid_reservation },
        .{ .status = "pending_transfer_has_different_credit_account_id", .failure = .invalid_reservation },
        .{ .status = "pending_transfer_has_different_ledger", .failure = .invalid_reservation },
        .{ .status = "pending_transfer_has_different_code", .failure = .invalid_reservation },
        .{ .status = "pending_transfer_already_voided", .failure = .operation_rejected },
        .{ .status = "id_already_failed", .failure = .operation_rejected },
        .{ .status = "created", .alias = "confirm-a", .inconsistent = true },
        .{ .status = "unknown", .inconsistent = true },
    };
    for (cases) |case| {
        var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer storage.deinit();
        const arena = storage.allocator();
        var backend: test_support.Backend = .{ .allocator = arena, .event = try test_support.ready_event(arena) };
        const dispatched = try submit_test_confirmation(arena,
            \\{"command":"confirm_seats","event_id":"00000000-0000-0000-0000-000000000001","pending_id":"340282366920938463463374607431768211454"}
        , &backend);
        try std.testing.expectEqualStrings("native", backend.outputs[0].queue);
        try std.testing.expectEqualStrings("completion", dispatched.result_queue.?);
        const context_json = try seat.encode_bounded(arena, dispatched.context, messages.context_size_max);
        const context = try seat.decode_context(arena, context_json);
        try std.testing.expectEqual(seat.native_id_max, context.command.confirm_seats.pending_id);
        const transfer = dispatched.body.object.get("create_transfers").?.array.items[0];
        try std.testing.expectEqualStrings("confirm", transfer.object.get("alias").?.string);
        try std.testing.expectEqualStrings("0", transfer.object.get("debit_account_id").?.string);
        const body = try std.json.Stringify.valueAlloc(arena, .{
            .create_accounts = [_]std.json.Value{},
            .create_transfers = &.{.{ .alias = case.alias, .error_code = case.status }},
            .lookup_accounts = [_]std.json.Value{},
        }, .{});
        const completion = try messages.encode(arena, &.{
            .operation_id = dispatched.operation_id,
            .tenant = dispatched.tenant,
            .context = dispatched.context,
            .body = try seat.parse_value(arena, body, messages.body_size_max),
        });
        var observer = logging.TestObserver.init(arena);
        observer.fail = true;
        const response = try handle_invocation(
            arena,
            try test_support.sqs_event(arena, "confirmation", completion),
            &.{ .operations_table = "Operations", .events_table = "Events", .now = 1, .logger = observer.logger() },
            &backend,
        );
        try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
        try std.testing.expectEqual(@as(usize, 1), observer.records.items.len);
        const record = observer.records.items[0];
        try std.testing.expectEqualStrings("confirm_seats", record.command.?);
        try std.testing.expectEqualStrings(if (case.inconsistent) "acknowledged_invalid" else "finalized", record.outcome);
        if (case.inconsistent) {
            try std.testing.expectEqualStrings("evidence_validate", record.stage);
            try std.testing.expect(record.result_type == null);
            try std.testing.expectEqual(@as(usize, 0), backend.effects.completed);
        } else {
            const expected: seat.Result = if (case.failure) |failure|
                .{ .failure = failure }
            else
                .{ .success = .{ .confirm_seats = context.command.confirm_seats } };
            try std.testing.expectEqualStrings(if (case.failure != null) "FAILURE" else "SUCCESS", record.result_type.?);
            try std.testing.expectEqual(@as(usize, 1), backend.effects.completed);
            try std.testing.expectEqualStrings(try seat.encode_result(arena, &expected), backend.writes[0].result);
        }
        const inconsistent = @intFromBool(case.inconsistent);
        try backend.expect_effects(.{
            .event_reads = 2,
            .generated = 1,
            .send_attempts = 1,
            .published = 1,
            .update_attempts = 1 - inconsistent,
            .completed = 1 - inconsistent,
            .report_attempts = inconsistent,
            .reports = inconsistent,
        });
    }
}

test "confirmation schema rejects unknown fields before metadata reads or ID generation" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var backend: test_support.Backend = .{ .allocator = arena, .event = try test_support.ready_event(arena) };
    const dispatched = try submit_test_confirmation(arena,
        \\{"command":"confirm_seats","event_id":"00000000-0000-0000-0000-000000000001","extra":true,"pending_id":"123"}
    , &backend);
    try std.testing.expectEqualStrings("completion", backend.outputs[0].queue);
    try std.testing.expectEqual(seat.FailureCode.invalid_request, try seat.local_failure(&dispatched.body));
    try backend.expect_effects(.{ .send_attempts = 1, .published = 1 });
}

test "seat finalization summaries describe authoritative winners and retain retries" {
    const success = "{\"type\":\"SUCCESS\",\"payload\":{\"event_id\":\"00000000-0000-0000-0000-000000000001\",\"reservation_id\":\"123\"}}";
    const failure = "{\"type\":\"FAILURE\",\"payload\":{\"code\":\"event_not_ready\"}}";
    const invalid = "{\"type\":\"SUCCESS\",\"payload\":{\"event_id\":\"00000000-0000-0000-0000-000000000001\",\"class\":\"a\",\"reservation_id\":\"123\"}}";
    const cases = [_]struct { stored: ?[]const u8 = null, write_error: ?anyerror = error.AWSFailure, read_error: ?anyerror = null, outcome: []const u8, result_type: ?[]const u8 = null, code: ?[]const u8 = null }{
        .{ .write_error = null, .outcome = "finalized", .result_type = "FAILURE", .code = "invalid_request" },
        .{ .stored = success, .outcome = "winner_observed", .result_type = "SUCCESS" },
        .{ .stored = failure, .outcome = "winner_observed", .result_type = "FAILURE", .code = "event_not_ready" },
        .{ .outcome = "retry" },
        .{ .read_error = error.AWSFailure, .outcome = "retry" },
        .{ .stored = invalid, .outcome = "acknowledged_invalid" },
    };
    for (cases) |case| {
        var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer storage.deinit();
        const arena = storage.allocator();
        var observer = logging.TestObserver.init(arena);
        observer.fail = true;
        var backend: test_support.Backend = .{
            .allocator = arena,
            .event = try test_support.ready_event(arena),
            .operation_item = try test_support.stored_operation(arena, case.stored),
            .read_error = case.read_error,
            .fail_next_update = case.write_error,
        };
        const input = try messages.encode(arena, &.{
            .operation_id = 1,
            .tenant = "tenant-a",
            .body = try seat.parse_value(arena, "{\"code\":\"invalid_request\"}", messages.body_size_max),
            .context = .null,
        });
        const event = try test_support.sqs_event(arena, "confirmation", input);
        const response = try handle_invocation(arena, event, &.{
            .operations_table = "Operations",
            .now = 2,
            .logger = observer.logger(),
        }, &backend);
        const parsed = try std.json.parseFromSlice(std.json.Value, arena, response, .{});
        try std.testing.expectEqual(@as(usize, @intFromBool(std.mem.eql(u8, case.outcome, "retry"))), parsed.value.object.get("batchItemFailures").?.array.items.len);
        try std.testing.expectEqual(@as(usize, 1), observer.records.items.len);
        const record = observer.records.items[0];
        try std.testing.expectEqualStrings(case.outcome, record.outcome);
        try std.testing.expectEqualDeep(case.result_type, record.result_type);
        try std.testing.expectEqualDeep(case.code, record.failure_code);
        if (std.mem.eql(u8, case.outcome, "retry")) {
            try std.testing.expectEqualStrings(if (case.read_error != null) "winner_read" else "winner_validate", record.stage);
        }
        try backend.expect_effects(.{
            .update_attempts = 1,
            .completed = @intFromBool(case.write_error == null),
            .operation_reads = @intFromBool(case.write_error != null),
            .report_attempts = @intFromBool(std.mem.eql(u8, case.outcome, "acknowledged_invalid")),
            .reports = @intFromBool(std.mem.eql(u8, case.outcome, "acknowledged_invalid")),
        });
    }
}

test "confirmation schema errors log safe reasons and public codes only after publication" {
    const bodies = [_][]const u8{
        "{\"command\":\"confirm_seats\",\"event_id\":\"00000000-0000-0000-0000-000000000001\"}",
        "{\"command\":\"confirm_seats\",\"event_id\":\"00000000-0000-0000-0000-000000000001\",\"pending_id\":1}",
        "{\"command\":\"confirm_seats\",\"event_id\":\"00000000-0000-0000-0000-000000000001\",\"pending_id\":\"1\",\"extra\":true}",
    };
    for (bodies) |body| {
        for ([_]bool{ false, true }) |fail_send| {
            var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer storage.deinit();
            const arena = storage.allocator();
            var observer = logging.TestObserver.init(arena);
            var backend: test_support.Backend = .{
                .allocator = arena,
                .event = try test_support.ready_event(arena),
                .fail_next_send = if (fail_send) error.SendFailed else null,
            };
            const input = try messages.encode(arena, &.{
                .operation_id = 1,
                .tenant = "tenant-a",
                .body = try seat.parse_value(arena, body, messages.body_size_max),
                .context = .null,
            });
            const event = try test_support.sqs_event(arena, "confirmation", input);
            _ = try submission.handle_invocation(arena, event, &.{
                .events_table = "Events",
                .completion_queue = "completion",
                .native_queue = "native",
                .logger = observer.logger(),
            }, &backend);
            const record = observer.records.items[0];
            try std.testing.expectEqualStrings(if (fail_send) "retry" else "rejected", record.outcome);
            try std.testing.expectEqualStrings("invalid_request", record.failure_code.?);
            try std.testing.expect(record.reason != null);
            try std.testing.expectEqualStrings("rejection_publish", record.stage);
            try backend.expect_effects(.{
                .send_attempts = 1,
                .published = @intFromBool(!fail_send),
            });
        }
    }
}

test "creation finalization returns the coherent winner even when the proposal differs" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var saved = try test_support.ready_event(arena);
    const winner = saved;
    saved.state = .creating;
    var backend: test_support.Backend = .{
        .allocator = arena,
        .event = saved,
        .transactions = .{
            .responses = &.{
                .{ .item = try events.encode_item(arena, &winner) },
                .{ .item = try test_support.stored_operation(arena, "{\"type\":\"SUCCESS\",\"payload\":{\"event_id\":\"00000000-0000-0000-0000-000000000001\"}}") },
            },
            .fail_next_write = error.AWSFailure,
        },
    };
    const proposal = try operation.parseCompletionJSON(arena, "{\"type\":\"FAILURE\",\"payload\":{\"code\":\"operation_rejected\"}}");
    const options: events.FinalizationOptions = .{ .events_table = "Events", .operations_table = "Operations", .now = 2 };
    const observed = try events.finalize_creation(arena, &options, &saved, &proposal, &backend);
    try std.testing.expect(observed.winner);
    try std.testing.expect(observed.result == .success);
    const written = try events.finalize_creation(arena, &options, &saved, &proposal, &backend);
    try std.testing.expect(!written.winner);
    try std.testing.expect(written.result == .failure);
    try backend.expect_effects(.{ .transaction_writes = 2, .transaction_reads = 1 });
}

fn run_runtime_test(
    fixture: *test_support.RuntimeFixture,
    script: []const test_support.RuntimeEvent,
) !void {
    var adapter: InvocationAdapter = undefined;
    adapter.init(&fixture.backend, &.{
        .logger = fixture.observer.logger(),
        .events_table = "Events",
        .operations_table = "Operations",
        .now = -1, // The real handler must supply the invocation timestamp.
        .ready_cache = &fixture.cache,
    });
    install_runtime_adapter(&adapter);
    defer uninstall_runtime_adapter();
    try fixture.run(script, handler);
}

test "runtime integration: seat completion reuses ready metadata across warm invocations" {
    if (comptime !runtime_tests_enabled) return error.SkipZigTest;
    var fixture: test_support.RuntimeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const script = try fixture.warm_events(.completion);
    try run_runtime_test(&fixture, &script);
    try fixture.expect_warm();
    try fixture.backend.expect_effects(.{ .event_reads = 1, .update_attempts = 3, .completed = 3 });
}

test "runtime integration: seat completion retries an uncertain write then acknowledges" {
    if (comptime !runtime_tests_enabled) return error.SkipZigTest;
    var fixture: test_support.RuntimeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const script = try fixture.retry_events(.completion);
    fixture.backend.fail_next_update = error.AWSFailure;
    // Authoritative SUBMITTED readback keeps the uncertain first write retryable.
    fixture.backend.operation_item = try test_support.stored_operation(fixture.backend.allocator, null);
    try run_runtime_test(&fixture, &script);
    try fixture.expect_retry("finalized");
    try fixture.backend.expect_effects(.{ .event_reads = 1, .operation_reads = 1, .update_attempts = 2, .completed = 1 });
}

test "runtime integration: seat completion reports malformed SQS input and recovers" {
    if (comptime !runtime_tests_enabled) return error.SkipZigTest;
    var fixture: test_support.RuntimeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const script = try fixture.recovery_events(.completion);
    try run_runtime_test(&fixture, &script);
    try fixture.expect_recovery();
    try fixture.backend.expect_effects(.{ .event_reads = 1, .update_attempts = 1, .completed = 1 });
}
