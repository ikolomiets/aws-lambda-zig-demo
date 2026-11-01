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
const logging = @import("outcome_log");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    logger: logging.Logger = .{},
    events_table: []const u8,
    completion_queue: []const u8,
    native_queue: []const u8 = "",
    response_allocator: ?Allocator = null,
    ready_cache: ?*events.ReadyCache = null,
};
pub const Stage = enum { submission, completion };
pub const diagnostic_size_max = 8192;
const preview_size_max = 512;
var runtime: ?*Runtime = null;

pub fn main(init: std.process.Init) void {
    var resources: Runtime = undefined;
    resources.init(init) catch |err| {
        var trace = logging.Context.init(.{}, .seat_submission);
        trace.finish(.ERROR, "initialization", "retry", @errorName(err));
        trace.emit();
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
        .logger = .{ .request_id = context.request.id },
        .events_table = resources.events.table_name,
        .completion_queue = resources.completion_queue,
        .native_queue = resources.native_queue,
        .ready_cache = &resources.ready_cache,
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
    ready_cache: events.ReadyCache,

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
        errdefer self.counter.deinit();
        try self.ready_cache.init(process_init.gpa, events.ReadyCache.budget_bytes_max);
        sqs_queue.Sender.init(&self.sender, process_init.gpa, &self.config);
    }

    fn deinit(self: *Runtime) void {
        self.ready_cache.deinit();
        self.sender.deinit();
        self.counter.deinit();
        self.events.deinit();
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
    ) !?[]const events.Attribute {
        self.trace.record.stage = "event_read";
        var diagnostic: dynamodb.ServiceError = undefined;
        const response = self.resources.events.client.getItem(
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

    pub fn send(self: *RuntimeEffects, arena: Allocator, queue: []const u8, body: []const u8) !void {
        self.trace.record.stage = if (std.mem.eql(u8, queue, self.resources.native_queue)) "native_publish" else "rejection_publish";
        return self.resources.sender.send_observed(arena, queue, body, self.trace);
    }

    pub fn allocate(self: *RuntimeEffects, arena: Allocator) !u32 {
        self.trace.record.stage = "ledger_allocate";
        return self.resources.counter.allocate_observed(arena, self.trace);
    }

    pub fn generate_id(self: *RuntimeEffects) !u128 {
        self.trace.record.stage = "id_generate";
        for (0..4) |_| {
            var bytes: [16]u8 = undefined;
            try std.Io.randomSecure(self.resources.io, &bytes);
            const id = std.mem.readInt(u128, &bytes, .little);
            if (id > 0 and id <= seat.native_id_max) return id;
        }
        return error.IDGenerationFailed;
    }

    pub fn put(self: *RuntimeEffects, arena: Allocator, request: dynamodb.PutItemInput) !void {
        self.trace.record.stage = "event_insert";
        var diagnostic: dynamodb.ServiceError = undefined;
        _ = self.resources.events.client.putItem(arena, request, .{ .diagnostic = &diagnostic }) catch |err| {
            self.trace.aws_error(err, &diagnostic);
            if (err == error.ServiceError) diagnostic.deinit();
            return error.AWSFailure;
        };
    }

    pub fn report(_: *RuntimeEffects, diagnostic: []const u8) !void {
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
    var trace = logging.Context.init(options.logger, .seat_submission);
    trace.record.stage = "event_parse";
    const event = parse_event(arena, input) catch |err| {
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
    return encode_response(options.response_allocator orelse arena, record.message_id, should_retry) catch |err| {
        trace.finish(.ERROR, "response_encode", "retry", @errorName(err));
        return err;
    };
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
    trace: *logging.Context,
    backend: anytype,
) anyerror!bool {
    trace.record.stage = "envelope_decode";
    const message = messages.decode(arena, input) catch |err| {
        if (err == error.OutOfMemory) return err;
        trace.finish(.ERROR, trace.record.stage, "acknowledged_invalid", @errorName(err));
        diagnose(arena, .submission, @errorName(err), sqs_id, input, null, backend);
        return false;
    };
    trace.identify(message.operation_id);
    trace.record.command = logging.recognized_command(&message.body);
    if (message.result_queue != null or message.context != .null) {
        trace.finish(.ERROR, "envelope_validate", "acknowledged_invalid", "InvalidSubmissionEnvelope");
        diagnose(arena, .submission, "InvalidSubmissionEnvelope", sqs_id, input, &message, backend);
        return false;
    }
    trace.record.stage = "admission";
    const decision = admission(arena, &message, options, trace, backend) catch |err| {
        if (err == error.InvalidItem) {
            trace.finish(.ERROR, trace.record.stage, "acknowledged_invalid", @errorName(err));
            diagnose(arena, .submission, "InvalidEventMetadata", sqs_id, input, &message, backend);
            return false;
        }
        return err;
    };
    const rejection = switch (decision) {
        .rejected => |code| code,
        .accepted => |*accepted| {
            trace.record.stage = "dispatch";
            const dispatch = switch (accepted.command) {
                .create_event => create_event(arena, &message, &accepted.command, options, trace, backend),
                .reserve_seats, .confirm_seats, .check_seats => dispatch_native(
                    arena,
                    &message,
                    &accepted.command,
                    &accepted.event.?,
                    options,
                    trace,
                    backend,
                ),
            };
            const published = dispatch catch |err| {
                if (err == error.InvalidItem or err == error.EventConflict) {
                    trace.finish(.ERROR, trace.record.stage, "acknowledged_invalid", @errorName(err));
                    diagnose(arena, .submission, @errorName(err), sqs_id, input, &message, backend);
                    return false;
                }
                return err;
            };
            trace.finish(.INFO, if (published) "native_publish" else "event_terminal", "dispatched", if (published) null else "EventAlreadyTerminal");
            return false;
        },
    };
    trace.record.failure_code = @tagName(rejection.code);
    trace.record.reason = rejection.reason;
    trace.record.stage = "rejection_encode";
    var body: std.json.ObjectMap = .empty;
    try body.put(arena, "code", .{ .string = @tagName(rejection.code) });
    const output = messages.encode(arena, &.{
        .operation_id = message.operation_id,
        .tenant = message.tenant,
        .body = .{ .object = body },
        .context = message.body,
    }) catch |err| {
        if (err == error.OutOfMemory) return err;
        trace.finish(.ERROR, trace.record.stage, "acknowledged_invalid", @errorName(err));
        diagnose(arena, .submission, @errorName(err), sqs_id, input, &message, backend);
        return false;
    };
    trace.record.stage = "rejection_publish";
    try backend.send(arena, options.completion_queue, output);
    trace.finish(.WARN, "rejection_publish", "rejected", rejection.reason);
    return false;
}

fn create_event(
    arena: Allocator,
    message: *const messages.Message,
    command: *const seat.Command,
    options: *const Options,
    trace: *logging.Context,
    backend: anytype,
) !bool {
    std.debug.assert(command.* == .create_event);
    trace.record.stage = "event_read";
    var saved = events.read_event(arena, options.events_table, &.{
        .tenant = message.tenant,
        .event_id = message.operation_id,
    }, backend) catch |err| switch (err) {
        error.EventUnavailable => try insert_event(
            arena,
            message,
            &command.create_event,
            options,
            trace,
            backend,
        ),
        else => return err,
    };
    trace.record.stage = "event_validate";
    try seat.validate_configuration(&command.create_event, &saved);
    // Permanent terminal Events never restart native initialization.
    if (saved.state != .creating) return false;
    return dispatch_native(arena, message, command, &saved, options, trace, backend);
}

fn dispatch_native(
    arena: Allocator,
    message: *const messages.Message,
    command: *const seat.Command,
    saved: *const seat.Event,
    options: *const Options,
    trace: *logging.Context,
    backend: anytype,
) !bool {
    trace.record.stage = "id_generate";
    const attempt_id = switch (command.*) {
        .reserve_seats, .confirm_seats => try backend.generate_id(),
        .create_event, .check_seats => 0,
    };
    trace.record.stage = "native_encode";
    const body = try seat.encode_native_body(arena, &.{
        .command = command,
        .event = saved,
        .attempt_id = attempt_id,
    });
    trace.record.stage = "context_encode";
    const context = try seat.encode_context(
        arena,
        command,
        if (command.* == .reserve_seats) attempt_id else null,
    );
    trace.record.stage = "message_encode";
    const output = try messages.encode(arena, &.{
        .operation_id = message.operation_id,
        .tenant = message.tenant,
        .body = try seat.parse_value(arena, body, messages.body_size_max),
        .context = try seat.parse_value(arena, context, messages.context_size_max),
        .result_queue = options.completion_queue,
    });
    trace.record.stage = "native_publish";
    try backend.send(arena, options.native_queue, output);
    return true;
}

fn insert_event(
    arena: Allocator,
    message: *const messages.Message,
    create: *const seat.CreateEvent,
    options: *const Options,
    trace: *logging.Context,
    backend: anytype,
) !seat.Event {
    trace.record.stage = "ledger_allocate";
    const ledger = try backend.allocate(arena);
    trace.record.stage = "id_generate";
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
    trace.record.stage = "event_insert";
    return events.insert(arena, options.events_table, &candidate, backend);
}

const Admission = union(enum) {
    rejected: struct { code: seat.FailureCode, reason: []const u8 },
    accepted: struct { command: seat.Command, event: ?seat.Event },
};

fn admission(
    arena: Allocator,
    message: *const messages.Message,
    options: *const Options,
    trace: *logging.Context,
    backend: anytype,
) !Admission {
    trace.record.stage = "schema_validate";
    _ = seat.bounded_size(message.body, operation.body_size_max) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .rejected = .{ .code = .invalid_request, .reason = @errorName(err) } };
    };
    const command = seat.command_from_value(arena, &message.body) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .rejected = .{ .code = .invalid_request, .reason = @errorName(err) } };
    };
    const event_id: ?u128 = switch (command) {
        .create_event => null,
        .reserve_seats => |reserve| reserve.event_id,
        .confirm_seats => |confirm| confirm.event_id,
        .check_seats => |id| id,
    };
    var saved: ?seat.Event = null;
    if (event_id) |id| {
        trace.record.stage = "event_read";
        saved = events.read_cached_event(
            arena,
            options.events_table,
            &.{ .tenant = message.tenant, .event_id = id },
            options.ready_cache,
            backend,
        ) catch |err| {
            if (err == error.EventUnavailable) return .{ .rejected = .{ .code = .event_unavailable, .reason = @errorName(err) } };
            return err;
        };
    }
    trace.record.stage = "admission";
    _ = seat.admit(arena, &command, if (saved) |*event| event else null, &.{
        .operation_id = message.operation_id,
        .tenant = message.tenant,
        .result_queue = options.completion_queue,
    }) catch |err| return switch (err) {
        error.EventUnavailable => .{ .rejected = .{ .code = .event_unavailable, .reason = @errorName(err) } },
        error.EventNotReady => .{ .rejected = .{ .code = .event_not_ready, .reason = @errorName(err) } },
        error.EventFailed => .{ .rejected = .{ .code = .event_failed, .reason = @errorName(err) } },
        error.UnknownClass => .{ .rejected = .{ .code = .unknown_class, .reason = @errorName(err) } },
        error.OutOfMemory => err,
        else => .{ .rejected = .{ .code = .invalid_request, .reason = @errorName(err) } },
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
