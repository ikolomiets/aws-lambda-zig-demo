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
const Allocator = std.mem.Allocator;

pub const Options = struct {
    operations_table: []const u8,
    events_table: []const u8 = "Events",
    now: operation.UnixSeconds,
    response_allocator: ?Allocator = null,
    ready_cache: ?*events.ReadyCache = null,
};
var runtime: ?*Runtime = null;

pub fn main(init: std.process.Init) void {
    var resources: Runtime = undefined;
    resources.init(init) catch |err| {
        std.log.err("Seat completion initialization failed: {s}", .{@errorName(err)});
        return;
    };
    defer resources.deinit();
    std.debug.assert(runtime == null);
    runtime = &resources;
    defer runtime = null;
    lambda.handle(init, handler, .{});
}

fn handler(context: lambda.Context, input: []const u8) ![]const u8 {
    const resources = runtime orelse return error.NotInitialized;
    return handle_invocation(context.arena, input, &.{
        .operations_table = resources.persistence.table_name,
        .events_table = resources.events_table,
        .now = std.Io.Clock.real.now(context.io).toSeconds(),
        .ready_cache = &resources.ready_cache,
    }, resources);
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

    pub fn get(
        self: *Runtime,
        arena: Allocator,
        request: dynamodb.GetItemInput,
    ) !?[]const aws.map.MapEntry(dynamodb.types.AttributeValue) {
        var diagnostic: dynamodb.ServiceError = undefined;
        const response = self.persistence.client.getItem(
            arena,
            request,
            .{ .diagnostic = &diagnostic },
        ) catch |err| {
            if (err == error.ServiceError) diagnostic.deinit();
            return error.AWSFailure;
        };
        return response.item;
    }

    pub fn update(self: *Runtime, arena: Allocator, request: dynamodb.types.Update) !void {
        var diagnostic: dynamodb.ServiceError = undefined;
        _ = self.persistence.client.updateItem(arena, .{
            .table_name = request.table_name,
            .key = request.key,
            .condition_expression = request.condition_expression,
            .expression_attribute_names = request.expression_attribute_names,
            .expression_attribute_values = request.expression_attribute_values,
            .update_expression = request.update_expression,
        }, .{ .diagnostic = &diagnostic }) catch |err| {
            if (err == error.ServiceError) diagnostic.deinit();
            return error.AWSFailure;
        };
    }

    pub fn report(_: *Runtime, diagnostic: []const u8) !void {
        std.log.err("{s}", .{diagnostic});
    }

    pub fn transact_write(
        self: *Runtime,
        arena: Allocator,
        request: dynamodb.TransactWriteItemsInput,
    ) !void {
        var diagnostic: dynamodb.ServiceError = undefined;
        _ = self.persistence.client.transactWriteItems(arena, request, .{
            .diagnostic = &diagnostic,
        }) catch |err| {
            if (err == error.ServiceError) diagnostic.deinit();
            return error.AWSFailure;
        };
    }

    pub fn transact_get(
        self: *Runtime,
        arena: Allocator,
        request: dynamodb.TransactGetItemsInput,
    ) !dynamodb.TransactGetItemsOutput {
        var diagnostic: dynamodb.ServiceError = undefined;
        return self.persistence.client.transactGetItems(arena, request, .{
            .diagnostic = &diagnostic,
        }) catch |err| {
            if (err == error.ServiceError) diagnostic.deinit();
            return error.AWSFailure;
        };
    }
};

pub fn handle_invocation(
    arena: Allocator,
    input: []const u8,
    options: *const Options,
    backend: anytype,
) ![]const u8 {
    const event = try submission.parse_event(arena, input);
    defer event.deinit(arena);
    const record = &event.records[0];
    const retry = process_record(
        arena,
        record.message_id,
        record.body,
        options,
        backend,
    ) catch true;
    return submission.encode_response(
        options.response_allocator orelse arena,
        record.message_id,
        retry,
    );
}

fn process_record(
    arena: Allocator,
    sqs_id: []const u8,
    input: []const u8,
    options: *const Options,
    backend: anytype,
) !bool {
    const message = messages.decode(arena, input) catch |err| {
        if (err == error.OutOfMemory) return true;
        submission.diagnose(arena, .completion, @errorName(err), sqs_id, input, null, backend);
        return false;
    };
    if (message.result_queue != null) {
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
    const outcome = if (message.body == .object and message.body.object.contains("code"))
        complete_local(arena, &message, options, backend)
    else
        complete_native(arena, &message, options, backend);
    outcome catch |err| {
        switch (err) {
            error.InvalidNativeEvidence,
            error.InconsistentCreation,
            error.InvalidItem,
            error.EventConflict,
            error.InvalidLocalFailure,
            error.InconsistentOperation,
            => {
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
            else => return true,
        }
    };
    return false;
}

fn complete_local(
    arena: Allocator,
    message: *const messages.Message,
    options: *const Options,
    backend: anytype,
) !void {
    const code = seat.local_failure(&message.body) catch return error.InvalidLocalFailure;
    const result_json = try seat.encode_result(arena, &.{ .failure = code });
    try finalize_operation(arena, message, result_json, options, backend);
}

fn finalize_operation(
    arena: Allocator,
    message: *const messages.Message,
    result_json: []const u8,
    options: *const Options,
    backend: anytype,
) !void {
    const result = try operation.parseCompletionJSON(arena, result_json);
    const update = try operations.seat_completion_update(
        arena,
        options.operations_table,
        &.{ .id = message.operation_id, .tenant = message.tenant },
        &result,
        options.now,
    );
    backend.update(arena, update) catch {
        // A failed condition or lost response proves nothing without authoritative readback.
        if (!try read_winner(arena, options.operations_table, message, backend)) {
            return error.RetryFinalization;
        }
    };
}

fn complete_native(
    arena: Allocator,
    message: *const messages.Message,
    options: *const Options,
    backend: anytype,
) !void {
    const context_json = try seat.encode_bounded(arena, message.context, messages.context_size_max);
    const context = seat.decode_context(arena, context_json) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidNativeEvidence;
    };
    if (context.command != .create_event) {
        return complete_ready(arena, message, &context, options, backend);
    }
    const saved = events.read_event(arena, options.events_table, &.{
        .tenant = message.tenant,
        .event_id = message.operation_id,
    }, backend) catch |err| {
        if (err == error.EventUnavailable) return error.InconsistentCreation;
        return err;
    };
    try seat.validate_configuration(&context.command.create_event, &saved);
    const projected = seat.creation_result(arena, &message.body, &saved) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidNativeEvidence;
    };
    const result_json = try seat.encode_result(arena, &projected);
    const result = try operation.parseCompletionJSON(arena, result_json);
    try events.finalize_creation(arena, &.{
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
    backend: anytype,
) !void {
    const event_id = switch (context.command) {
        .reserve_seats => |reserve| reserve.event_id,
        .confirm_seats => |confirm| confirm.event_id,
        .check_seats => |id| id,
        else => unreachable,
    };
    const saved = events.read_cached_event(arena, options.events_table, &.{
        .tenant = message.tenant,
        .event_id = event_id,
    }, options.ready_cache, backend) catch |err| {
        if (err == error.EventUnavailable) return error.InvalidNativeEvidence;
        return err;
    };
    const projected = (switch (context.command) {
        .reserve_seats => seat.reservation_result(&message.body, &saved, context),
        .confirm_seats => seat.confirmation_result(&message.body, &saved, context),
        .check_seats => seat.availability_result(arena, &message.body, &saved),
        else => unreachable,
    }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidNativeEvidence;
    };
    const result_json = try seat.encode_result(arena, &projected);
    try finalize_operation(arena, message, result_json, options, backend);
}

fn read_winner(
    arena: Allocator,
    table: []const u8,
    message: *const messages.Message,
    backend: anytype,
) !bool {
    const request = try operations.read_request(arena, table, message.operation_id);
    const item = try backend.get(arena, request) orelse return error.InconsistentOperation;
    const saved = try operations.decode_item(arena, item);
    if (saved.id != message.operation_id) return error.InconsistentOperation;
    if (!std.mem.eql(u8, saved.tenant, message.tenant)) return error.InconsistentOperation;
    if (!std.mem.eql(u8, saved.name, "SeatReservation")) return error.InconsistentOperation;
    switch (saved.state) {
        .submitted => return false,
        .completed => |*result| seat.validate_completion(result) catch
            return error.InconsistentOperation,
    }
    return true;
}

// Replace only external effects while exercising both processors' real codecs and adapters.
const ConfirmationTestBackend = struct {
    event: seat.Event,
    output: ?[]const u8 = null,
    queue: ?[]const u8 = null,
    result: ?[]const u8 = null,
    reads: usize = 0,
    generated: usize = 0,
    reports: usize = 0,

    pub fn get(
        self: *ConfirmationTestBackend,
        arena: Allocator,
        request: dynamodb.GetItemInput,
    ) !?[]const aws.map.MapEntry(dynamodb.types.AttributeValue) {
        try std.testing.expectEqualStrings("Events", request.table_name);
        try std.testing.expectEqual(true, request.consistent_read.?);
        const expected = try events.read_request(arena, "Events", &.{
            .tenant = self.event.tenant,
            .event_id = self.event.event_id,
        });
        try std.testing.expectEqualDeep(expected.key, request.key);
        self.reads += 1;
        return try events.encode_item(arena, &self.event);
    }

    pub fn generate_id(self: *ConfirmationTestBackend) !u128 {
        self.generated += 1;
        return 124;
    }

    pub fn send(
        self: *ConfirmationTestBackend,
        arena: Allocator,
        queue: []const u8,
        body: []const u8,
    ) !void {
        try std.testing.expect(self.output == null);
        self.queue = try arena.dupe(u8, queue);
        self.output = try arena.dupe(u8, body);
    }

    pub fn update(
        self: *ConfirmationTestBackend,
        _: Allocator,
        request: dynamodb.types.Update,
    ) !void {
        try std.testing.expectEqualStrings("Operations", request.table_name);
        try std.testing.expect(self.result == null);
        for (request.expression_attribute_values.?) |entry| {
            if (std.mem.eql(u8, entry.key, ":result")) self.result = entry.value.s.?;
        }
        try std.testing.expect(self.result != null);
    }

    pub fn report(self: *ConfirmationTestBackend, _: []const u8) !void {
        self.reports += 1;
    }

    pub fn allocate(_: *ConfirmationTestBackend, _: Allocator) !u32 {
        return error.UnexpectedEffect;
    }

    pub fn put(_: *ConfirmationTestBackend, _: Allocator, _: dynamodb.PutItemInput) !void {
        return error.UnexpectedEffect;
    }

    pub fn transact_write(
        _: *ConfirmationTestBackend,
        _: Allocator,
        _: dynamodb.TransactWriteItemsInput,
    ) !void {
        return error.UnexpectedEffect;
    }

    pub fn transact_get(
        _: *ConfirmationTestBackend,
        _: Allocator,
        _: dynamodb.TransactGetItemsInput,
    ) !dynamodb.TransactGetItemsOutput {
        return error.UnexpectedEffect;
    }
};

fn confirmation_test_event(arena: Allocator) !seat.Event {
    return seat.decode_event(arena,
        \\{"tenant":"tenant-a","event_id":"00000000-0000-0000-0000-000000000001","ledger":1001,"timeout_seconds":30,"capacity_account_id":"1","allocation_account_id":"2","state":"ready","classes":{"a":{"total":10,"tb_account_id":"3"},"b":{"total":5,"tb_account_id":"4"}}}
    );
}

fn confirmation_test_invocation(arena: Allocator, message: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, .{
        .Records = &.{.{
            .messageId = "confirmation",
            .receiptHandle = "receipt",
            .body = message,
            .attributes = std.json.Value{ .object = .empty },
            .messageAttributes = std.json.Value{ .object = .empty },
            .md5OfBody = "md5",
            .eventSource = "aws:sqs",
            .eventSourceARN = "arn",
            .awsRegion = "ca-central-1",
        }},
    }, .{});
}

fn submit_test_confirmation(arena: Allocator, body: []const u8, backend: anytype) !messages.Message {
    const input = try messages.encode(arena, &.{
        .operation_id = 5,
        .tenant = "tenant-a",
        .body = try seat.parse_value(arena, body, messages.body_size_max),
        .context = .null,
    });
    const response = try submission.handle_invocation(
        arena,
        try confirmation_test_invocation(arena, input),
        &.{ .events_table = "Events", .native_queue = "native", .completion_queue = "completion" },
        backend,
    );
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
    return messages.decode(arena, backend.output orelse return error.MissingDispatch);
}

test "class-free confirmation flows through submission native evidence and completion" {
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
        var backend: ConfirmationTestBackend = .{ .event = try confirmation_test_event(arena) };
        const dispatched = try submit_test_confirmation(arena,
            \\{"command":"confirm_seats","event_id":"00000000-0000-0000-0000-000000000001","pending_id":"340282366920938463463374607431768211454"}
        , &backend);
        try std.testing.expectEqualStrings("native", backend.queue.?);
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
        const response = try handle_invocation(
            arena,
            try confirmation_test_invocation(arena, completion),
            &.{ .operations_table = "Operations", .events_table = "Events", .now = 1 },
            &backend,
        );
        try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
        if (case.inconsistent) {
            try std.testing.expect(backend.result == null);
        } else {
            const expected: seat.Result = if (case.failure) |failure|
                .{ .failure = failure }
            else
                .{ .success = .{ .confirm_seats = context.command.confirm_seats } };
            try std.testing.expectEqualStrings(try seat.encode_result(arena, &expected), backend.result.?);
        }
        try std.testing.expectEqual(@as(usize, 2), backend.reads);
        try std.testing.expectEqual(@as(usize, 1), backend.generated);
        try std.testing.expectEqual(@as(usize, @intFromBool(case.inconsistent)), backend.reports);
    }
}

test "confirmation rejects the retired class field without reading metadata or generating IDs" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var backend: ConfirmationTestBackend = .{ .event = try confirmation_test_event(arena) };
    const dispatched = try submit_test_confirmation(arena,
        \\{"command":"confirm_seats","event_id":"00000000-0000-0000-0000-000000000001","class":"a","pending_id":"123"}
    , &backend);
    try std.testing.expectEqualStrings("completion", backend.queue.?);
    try std.testing.expectEqual(seat.FailureCode.invalid_request, try seat.local_failure(&dispatched.body));
    try std.testing.expectEqual(@as(usize, 0), backend.reads);
    try std.testing.expectEqual(@as(usize, 0), backend.generated);
}
