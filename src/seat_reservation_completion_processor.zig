const std = @import("std");
const aws = @import("aws");
const dynamodb = @import("dynamodb");
const lambda = @import("aws-lambda");
const operation = @import("operation");
const operations = @import("operation_persistence");
const messages = @import("processor_message");
const seat = @import("seat_reservation");
const submission = @import("seat_reservation_processor");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    operations_table: []const u8,
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
        .now = std.Io.Clock.real.now(context.io).toSeconds(),
    }, resources);
}

const Runtime = struct {
    config: aws.Config,
    persistence: operations.Persistence,

    fn init(self: *Runtime, process_init: std.process.Init) !void {
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
    const code = seat.local_failure(&message.body) catch {
        submission.diagnose(
            arena,
            .completion,
            "InvalidLocalFailure",
            sqs_id,
            input,
            &message,
            backend,
        );
        return false;
    };
    const result_json = try seat.encode_result(arena, &.{ .failure = code });
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
        const valid_winner = read_winner(
            arena,
            options.operations_table,
            &message,
            backend,
        ) catch |err| {
            if (err == error.InvalidItem or err == error.InconsistentOperation) {
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
            }
            return true;
        };
        return !valid_winner;
    };
    return false;
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
