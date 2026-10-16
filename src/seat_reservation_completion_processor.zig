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
    }, resources);
}

const Runtime = struct {
    config: aws.Config,
    persistence: operations.Persistence,
    events_table: []const u8,

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
    }

    fn deinit(self: *Runtime) void {
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
    if (context.command == .reserve_seats or context.command == .check_seats) {
        return complete_ready(arena, message, &context, options, backend);
    }
    if (context.command != .create_event) return error.InvalidNativeEvidence;
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
        .check_seats => |id| id,
        else => unreachable,
    };
    const saved = events.read_event(arena, options.events_table, &.{
        .tenant = message.tenant,
        .event_id = event_id,
    }, backend) catch |err| {
        if (err == error.EventUnavailable) return error.InvalidNativeEvidence;
        return err;
    };
    const projected = (switch (context.command) {
        .reserve_seats => seat.reservation_result(&message.body, &saved, context),
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
