const std = @import("std");
const aws = @import("aws");
const dynamodb = @import("dynamodb");
const lambda = @import("aws-lambda");
const operation = @import("operation");
const messages = @import("processor_message");
const seat = @import("seat_reservation");
const events = @import("seat_reservation_persistence");
const ledger_counter = @import("ledger_counter");
const sqs_queue = @import("sqs_queue");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    events_table: []const u8,
    completion_queue: []const u8,
    native_queue: []const u8 = "",
    response_allocator: ?Allocator = null,
};
pub const Stage = enum { submission, completion };
pub const diagnostic_size_max = 8192;
const preview_size_max = 512;
var runtime: ?*Runtime = null;

pub fn main(init: std.process.Init) void {
    var resources: Runtime = undefined;
    resources.init(init) catch |err| {
        std.log.err("Seat submission initialization failed: {s}", .{@errorName(err)});
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
        .events_table = resources.events.table_name,
        .completion_queue = resources.completion_queue,
        .native_queue = resources.native_queue,
    }, resources);
}

const Runtime = struct {
    config: aws.Config,
    events: events.Persistence,
    sender: sqs_queue.Sender,
    completion_queue: []const u8,
    native_queue: []const u8,
    counter: ledger_counter.Counter,
    io: std.Io,

    fn init(self: *Runtime, process_init: std.process.Init) !void {
        self.io = process_init.io;
        self.native_queue = try sqs_queue.configured_queue_url(
            process_init.environ_map,
            "TigerBeetleQueue",
        );
        self.completion_queue = try sqs_queue.configured_queue_url(
            process_init.environ_map,
            "SeatReservationCompletionQueue",
        );
        self.config = try aws.Config.load(
            process_init.gpa,
            process_init.io,
            process_init.environ_map,
            .{ .max_attempts = 1 },
        );
        errdefer self.config.deinit();
        try self.events.init(process_init.gpa, &self.config, process_init.environ_map);
        errdefer self.events.deinit();
        try self.counter.init(process_init.gpa, &self.config, process_init.environ_map);
        sqs_queue.Sender.init(&self.sender, process_init.gpa, &self.config);
    }

    fn deinit(self: *Runtime) void {
        self.sender.deinit();
        self.counter.deinit();
        self.events.deinit();
        self.config.deinit();
    }

    pub fn get(
        self: *Runtime,
        arena: Allocator,
        request: dynamodb.GetItemInput,
    ) !?[]const events.Attribute {
        var diagnostic: dynamodb.ServiceError = undefined;
        const response = self.events.client.getItem(
            arena,
            request,
            .{ .diagnostic = &diagnostic },
        ) catch |err| {
            if (err == error.ServiceError) diagnostic.deinit();
            return error.AWSFailure;
        };
        return response.item;
    }

    pub fn send(self: *Runtime, arena: Allocator, queue: []const u8, body: []const u8) !void {
        return self.sender.send(arena, queue, body);
    }

    pub fn allocate(self: *Runtime, arena: Allocator) !u32 {
        return self.counter.allocate(arena);
    }

    pub fn generate_id(self: *Runtime) !u128 {
        for (0..4) |_| {
            var bytes: [16]u8 = undefined;
            try std.Io.randomSecure(self.io, &bytes);
            const id = std.mem.readInt(u128, &bytes, .little);
            if (id > 0 and id <= seat.native_id_max) return id;
        }
        return error.IDGenerationFailed;
    }

    pub fn put(self: *Runtime, arena: Allocator, request: dynamodb.PutItemInput) !void {
        var diagnostic: dynamodb.ServiceError = undefined;
        _ = self.events.client.putItem(arena, request, .{ .diagnostic = &diagnostic }) catch |err| {
            if (err == error.ServiceError) diagnostic.deinit();
            return error.AWSFailure;
        };
    }

    pub fn report(_: *Runtime, diagnostic: []const u8) !void {
        std.log.err("{s}", .{diagnostic});
    }
};

/// Only external DynamoDB, SQS and diagnostic effects are supplied by the backend.
pub fn handle_invocation(
    arena: Allocator,
    input: []const u8,
    options: *const Options,
    backend: anytype,
) ![]const u8 {
    const event = try parse_event(arena, input);
    defer event.deinit(arena);
    const record = &event.records[0];
    const retry = process_record(
        arena,
        record.message_id,
        record.body,
        options,
        backend,
    ) catch true;
    return encode_response(options.response_allocator orelse arena, record.message_id, retry);
}

pub fn parse_event(arena: Allocator, input: []const u8) !lambda.sqs.Event {
    const event = try lambda.sqs.parseEvent(arena, input);
    errdefer event.deinit(arena);
    if (event.records.len == 0) return error.EmptySQSEvent;
    if (event.records.len != 1) return error.TooManyRecords;
    std.debug.assert(event.records.len == 1);
    return event;
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
        diagnose(arena, .submission, @errorName(err), sqs_id, input, null, backend);
        return false;
    };
    if (message.result_queue != null or message.context != .null) {
        diagnose(arena, .submission, "InvalidSubmissionEnvelope", sqs_id, input, &message, backend);
        return false;
    }
    const decision = admission(arena, &message, options, backend) catch |err| {
        if (err == error.InvalidItem) {
            diagnose(arena, .submission, "InvalidEventMetadata", sqs_id, input, &message, backend);
            return false;
        }
        return true;
    };
    const rejection = switch (decision) {
        .rejected => |code| code,
        .accepted => |*accepted| {
            const dispatch = switch (accepted.command) {
                .create_event => create_event(arena, &message, &accepted.command, options, backend),
                .check_seats => dispatch_native(
                    arena,
                    &message,
                    &accepted.command,
                    &accepted.event.?,
                    options,
                    backend,
                ),
                else => return true,
            };
            dispatch catch |err| {
                if (err == error.InvalidItem or err == error.EventConflict) {
                    diagnose(arena, .submission, @errorName(err), sqs_id, input, &message, backend);
                    return false;
                }
                return true;
            };
            return false;
        },
    };
    var body: std.json.ObjectMap = .empty;
    try body.put(arena, "code", .{ .string = @tagName(rejection) });
    const output = messages.encode(arena, &.{
        .operation_id = message.operation_id,
        .tenant = message.tenant,
        .body = .{ .object = body },
        .context = message.body,
    }) catch |err| {
        if (err == error.OutOfMemory) return true;
        diagnose(arena, .submission, @errorName(err), sqs_id, input, &message, backend);
        return false;
    };
    try backend.send(arena, options.completion_queue, output);
    return false;
}

fn create_event(
    arena: Allocator,
    message: *const messages.Message,
    command: *const seat.Command,
    options: *const Options,
    backend: anytype,
) !void {
    std.debug.assert(command.* == .create_event);
    var saved = events.read_event(arena, options.events_table, &.{
        .tenant = message.tenant,
        .event_id = message.operation_id,
    }, backend) catch |err| switch (err) {
        error.EventUnavailable => try insert_event(
            arena,
            message,
            &command.create_event,
            options,
            backend,
        ),
        else => return err,
    };
    try seat.validate_configuration(&command.create_event, &saved);
    // Permanent terminal Events never restart native initialization.
    if (saved.state != .creating) return;
    try dispatch_native(arena, message, command, &saved, options, backend);
}

fn dispatch_native(
    arena: Allocator,
    message: *const messages.Message,
    command: *const seat.Command,
    saved: *const seat.Event,
    options: *const Options,
    backend: anytype,
) !void {
    const body = try seat.encode_native_body(arena, &.{
        .command = command,
        .event = saved,
        .attempt_id = 0,
    });
    const context = try seat.encode_context(arena, command, null);
    const output = try messages.encode(arena, &.{
        .operation_id = message.operation_id,
        .tenant = message.tenant,
        .body = try seat.parse_value(arena, body, messages.body_size_max),
        .context = try seat.parse_value(arena, context, messages.context_size_max),
        .result_queue = options.completion_queue,
    });
    try backend.send(arena, options.native_queue, output);
}

fn insert_event(
    arena: Allocator,
    message: *const messages.Message,
    create: *const seat.CreateEvent,
    options: *const Options,
    backend: anytype,
) !seat.Event {
    const ledger = try backend.allocate(arena);
    const capacity = try backend.generate_id();
    const allocation = try backend.generate_id();
    const classes = try arena.alloc(seat.EventClass, create.classes.len);
    for (create.classes, classes) |source, *target| target.* = .{
        .tag = source.tag,
        .total = source.total,
        .tb_account_id = try backend.generate_id(),
    };
    const candidate: seat.Event = .{
        .tenant = message.tenant,
        .event_id = message.operation_id,
        .ledger = ledger,
        .capacity_account_id = capacity,
        .allocation_account_id = allocation,
        .classes = classes,
        .timeout_seconds = create.timeout_seconds,
        .state = .creating,
    };
    return events.insert(arena, options.events_table, &candidate, backend);
}

const Admission = union(enum) {
    rejected: seat.FailureCode,
    accepted: struct { command: seat.Command, event: ?seat.Event },
};

fn admission(
    arena: Allocator,
    message: *const messages.Message,
    options: *const Options,
    backend: anytype,
) !Admission {
    _ = seat.bounded_size(message.body, operation.body_size_max) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .rejected = .invalid_request };
    };
    const command = seat.command_from_value(arena, &message.body) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .rejected = .invalid_request };
    };
    const event_id: ?u128 = switch (command) {
        .create_event => null,
        .reserve_seats => |reserve| reserve.event_id,
        .confirm_seats => |confirm| confirm.event_id,
        .check_seats => |id| id,
    };
    var saved: ?seat.Event = null;
    if (event_id) |id| {
        saved = events.read_event(
            arena,
            options.events_table,
            &.{ .tenant = message.tenant, .event_id = id },
            backend,
        ) catch |err| {
            if (err == error.EventUnavailable) return .{ .rejected = .event_unavailable };
            return err;
        };
    }
    _ = seat.admit(arena, &command, if (saved) |*event| event else null, &.{
        .operation_id = message.operation_id,
        .tenant = message.tenant,
        .result_queue = options.completion_queue,
    }) catch |err| return switch (err) {
        error.EventUnavailable => .{ .rejected = .event_unavailable },
        error.EventNotReady => .{ .rejected = .event_not_ready },
        error.EventFailed => .{ .rejected = .event_failed },
        error.UnknownClass => .{ .rejected = .unknown_class },
        error.OutOfMemory => err,
        else => .{ .rejected = .invalid_request },
    };
    return .{ .accepted = .{ .command = command, .event = saved } };
}

pub fn encode_response(arena: Allocator, sqs_id: []const u8, retry: bool) ![]const u8 {
    const Failure = struct { itemIdentifier: []const u8 };
    const failures = [_]Failure{.{ .itemIdentifier = sqs_id }};
    return std.json.Stringify.valueAlloc(arena, .{
        .batchItemFailures = if (retry) failures[0..] else failures[0..0],
    }, .{});
}

/// No allocation or log delivery is required to acknowledge a diagnosed message.
pub fn diagnose(
    arena: Allocator,
    stage: Stage,
    reason: []const u8,
    sqs_id: []const u8,
    input: []const u8,
    message: ?*const messages.Message,
    backend: anytype,
) void {
    var buffer: [diagnostic_size_max]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var preview_buffer: [preview_size_max * 4]u8 = undefined;
    var sqs_buffer: [128 * 4]u8 = undefined;
    var uuid_buffer: [operation.uuid_string_size]u8 = undefined;
    var tenant: ?[]const u8 = null;
    var operation_id: ?[]const u8 = null;
    if (message) |valid| {
        operation_id = operation.uuidToString(valid.operation_id, &uuid_buffer);
        tenant = valid.tenant;
    } else if (input.len <= messages.encoded_size_max) {
        // A usable correlation can survive missing Context or an invalid Body contract.
        if (seat.parse_value(arena, input, messages.encoded_size_max)) |value| {
            if (value == .object) {
                if (value.object.get("operation_id")) |id| {
                    if (id == .string) {
                        if (seat.canonical_uuid(id.string)) |parsed| {
                            operation_id = operation.uuidToString(parsed, &uuid_buffer);
                        } else |_| {}
                    }
                }
                if (value.object.get("tenant")) |candidate| {
                    if (candidate == .string) {
                        if (operation.validateTenant(candidate.string)) |_| {
                            tenant = candidate.string;
                        } else |_| {}
                    }
                }
            }
        } else |_| {}
    }
    std.json.Stringify.value(.{
        .level = "ERROR",
        .stage = @tagName(stage),
        .reason = reason,
        .sqs_id = escaped_bytes(sqs_id[0..@min(sqs_id.len, 128)], &sqs_buffer),
        .operation_id = operation_id,
        .tenant = tenant,
        .body_length = input.len,
        .preview = escaped_bytes(input[0..@min(input.len, preview_size_max)], &preview_buffer),
        .truncated = input.len > preview_size_max,
    }, .{}, &writer) catch return;
    std.debug.assert(writer.end <= diagnostic_size_max);
    backend.report(writer.buffered()) catch {};
}

fn escaped_bytes(input: []const u8, output: []u8) []const u8 {
    std.debug.assert(output.len >= input.len * 4);
    const hex = "0123456789abcdef";
    var count: usize = 0;
    for (input) |byte| {
        if (byte >= 0x20 and byte <= 0x7e) {
            output[count] = byte;
            count += 1;
        } else {
            output[count..][0..4].* = .{ '\\', 'x', hex[byte >> 4], hex[byte & 15] };
            count += 4;
        }
    }
    return output[0..count];
}
