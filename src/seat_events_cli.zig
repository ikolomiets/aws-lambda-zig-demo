const std = @import("std");
const aws = @import("aws");
const seat = @import("seat_reservation");
const persistence = @import("seat_reservation_persistence");
const Allocator = std.mem.Allocator;

const argument_count_max = 6;
const argument_size_max = 4096;
const Command = union(enum) { help, create: seat.EventKey, read: seat.EventKey };
const PreparedCommand = union(enum) { help, create: seat.Event, read: seat.EventKey };
const usage =
    \\Usage:
    \\  events create --tenant <tenant> --event-id <uuid> < event.json
    \\  events read --tenant <tenant> --event-id <uuid>
    \\
    \\Create inserts complete validated creating metadata absent-only.
    \\It does not allocate a ledger, provision native resources, or finalize readiness.
    \\
    \\Environment:
    \\  EVENTS_TABLE_NAME  DynamoDB table containing Seat Events
    \\  AWS_*              Standard AWS credentials, Region, profile and endpoint
    \\
;

pub fn main(init: std.process.Init) u8 {
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    var stderr = std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
    const code = main_execute(init, &stdout.interface) catch |err| {
        return finish(&stdout.interface, &stderr.interface, report_error(&stderr.interface, err));
    };
    return finish(&stdout.interface, &stderr.interface, code);
}

fn main_execute(init: std.process.Init, stdout: *std.Io.Writer) !u8 {
    var buffer: [argument_count_max][]const u8 = undefined;
    var iterator = std.process.Args.Iterator.init(init.minimal.args);
    var count: usize = 0;
    while (iterator.next()) |argument| {
        if (count == buffer.len or argument.len > argument_size_max) return error.InvalidInvocation;
        buffer[count] = argument;
        count += 1;
    }
    const arguments = buffer[0..count];
    const command = try parse_command(arguments);
    if (command == .help) {
        try stdout.writeAll(usage);
        return 0;
    }
    const input_buffer = try init.gpa.create([seat.event_size_max + 1]u8);
    defer init.gpa.destroy(input_buffer);
    const input = if (command == .create) input: {
        var reader_buffer: [4096]u8 = undefined;
        var stdin = std.Io.File.stdin().readerStreaming(init.io, &reader_buffer);
        const size = try stdin.interface.readSliceShort(input_buffer);
        if (size > seat.event_size_max) return error.InputTooLarge;
        break :input input_buffer[0..size];
    } else "";
    // Reject invalid administrative metadata before AWS configuration/discovery.
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const prepared = try prepare_command(arena.allocator(), &command, input);
    var config = aws.Config.load(init.gpa, init.io, init.environ_map, .{}) catch {
        return error.InvalidConfiguration;
    };
    defer config.deinit();
    var store: persistence.Persistence = undefined;
    try store.init(init.gpa, &config, init.environ_map);
    defer store.deinit();
    try execute(arena.allocator(), &prepared, stdout, Backend.init(&store));
    return 0;
}

fn finish(stdout: *std.Io.Writer, stderr: *std.Io.Writer, code: u8) u8 {
    stdout.flush() catch return 2;
    stderr.flush() catch return 2;
    return code;
}

fn is_help(argument: []const u8) bool {
    return std.mem.eql(u8, argument, "--help") or std.mem.eql(u8, argument, "-h") or
        std.mem.eql(u8, argument, "help");
}

fn parse_command(arguments: []const []const u8) !Command {
    if (arguments.len < 2 or arguments.len > argument_count_max) return error.InvalidInvocation;
    for (arguments) |argument| if (argument.len > argument_size_max) return error.InvalidInvocation;
    if (is_help(arguments[1])) {
        if (arguments.len != 2) return error.InvalidInvocation;
        return .help;
    }
    const create = std.mem.eql(u8, arguments[1], "create");
    if (!create and !std.mem.eql(u8, arguments[1], "read")) return error.InvalidInvocation;
    if (arguments.len == 3 and is_help(arguments[2])) return .help;
    if (arguments.len != 6) return error.InvalidInvocation;
    var tenant: ?[]const u8 = null;
    var event_id: ?u128 = null;
    var index: usize = 2;
    while (index < arguments.len) : (index += 2) {
        if (std.mem.eql(u8, arguments[index], "--tenant")) {
            if (tenant != null) return error.InvalidInvocation;
            tenant = arguments[index + 1];
            seat.validate_key(&.{ .tenant = tenant.?, .event_id = 0 }) catch {
                return error.InvalidInvocation;
            };
        } else if (std.mem.eql(u8, arguments[index], "--event-id")) {
            if (event_id != null) return error.InvalidInvocation;
            event_id = seat.canonical_uuid(arguments[index + 1]) catch {
                return error.InvalidInvocation;
            };
        } else return error.InvalidInvocation;
    }
    const key: seat.EventKey = .{
        .tenant = tenant orelse return error.InvalidInvocation,
        .event_id = event_id orelse return error.InvalidInvocation,
    };
    return if (create) .{ .create = key } else .{ .read = key };
}

pub const Backend = struct {
    context: *anyopaque,
    create_fn: *const fn (*anyopaque, Allocator, *const seat.Event) anyerror!seat.Event,
    read_fn: *const fn (*anyopaque, Allocator, *const seat.EventKey) anyerror!seat.Event,

    pub fn init(pointer: anytype) Backend {
        const Pointer = @TypeOf(pointer);
        const Adapter = struct {
            fn create(context: *anyopaque, arena: Allocator, event: *const seat.Event) !seat.Event {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.create(arena, event);
            }
            fn read(context: *anyopaque, arena: Allocator, key: *const seat.EventKey) !seat.Event {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.read(arena, key);
            }
        };
        return .{ .context = pointer, .create_fn = Adapter.create, .read_fn = Adapter.read };
    }
};

/// Tests inject only the persistence effect; parsing and JSON output use the shared contracts.
pub fn run(
    allocator: Allocator,
    arguments: []const []const u8,
    input: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    backend: ?Backend,
) u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    run_in_arena(arena.allocator(), arguments, input, stdout, backend) catch |err| {
        return report_error(stderr, err);
    };
    return 0;
}

fn run_in_arena(
    arena: Allocator,
    arguments: []const []const u8,
    input: []const u8,
    stdout: *std.Io.Writer,
    backend_optional: ?Backend,
) !void {
    const command = try parse_command(arguments);
    const prepared = try prepare_command(arena, &command, input);
    try execute(arena, &prepared, stdout, backend_optional);
}

fn prepare_command(
    arena: Allocator,
    command: *const Command,
    input: []const u8,
) !PreparedCommand {
    if (input.len > seat.event_size_max) return error.InputTooLarge;
    return switch (command.*) {
        .help => {
            if (input.len != 0) return error.UnexpectedInput;
            return .help;
        },
        .read => |key| {
            if (input.len != 0) return error.UnexpectedInput;
            return .{ .read = key };
        },
        .create => |*key| .{ .create = try creation_input(arena, input, key) },
    };
}

fn execute(
    arena: Allocator,
    command: *const PreparedCommand,
    stdout: *std.Io.Writer,
    backend_optional: ?Backend,
) !void {
    if (command.* == .help) {
        try stdout.writeAll(usage);
        return;
    }
    const backend = backend_optional orelse return error.InvalidConfiguration;
    const key: seat.EventKey = switch (command.*) {
        .help => unreachable,
        .create => |*candidate| .{ .tenant = candidate.tenant, .event_id = candidate.event_id },
        .read => |key| key,
    };
    const event = switch (command.*) {
        .help => unreachable,
        .create => |*candidate| try backend.create_fn(backend.context, arena, candidate),
        .read => |*read_key| try backend.read_fn(backend.context, arena, read_key),
    };
    try seat.validate_event(&event);
    if (!std.mem.eql(u8, key.tenant, event.tenant) or key.event_id != event.event_id) {
        return error.InvalidItem;
    }
    const output = try seat.encode_event(arena, &event);
    try stdout.writeAll(output);
    try stdout.writeByte('\n');
}

fn creation_input(arena: Allocator, input: []const u8, key: *const seat.EventKey) !seat.Event {
    const event = try seat.decode_event(arena, input);
    if (event.state != .creating) return error.InvalidCreationState;
    if (!std.mem.eql(u8, key.tenant, event.tenant) or key.event_id != event.event_id) {
        return error.InvalidIdentity;
    }
    return event;
}

fn report_error(stderr: *std.Io.Writer, err: anyerror) u8 {
    const message, const code: u8 = switch (err) {
        error.InvalidInvocation => .{ "invalid invocation; use --help", 2 },
        error.InvalidConfiguration => .{ "missing or invalid configuration", 2 },
        error.EventUnavailable => .{ "event unavailable", 1 },
        error.EventConflict => .{ "event configuration conflict", 1 },
        error.InsertionUncertain => .{ "insertion unresolved; retry with the same identity", 2 },
        error.AWSFailure => .{ "AWS request failed", 2 },
        error.InvalidItem => .{ "stored event is invalid", 2 },
        error.OutOfMemory, error.WriteFailed => .{ "operation failed", 2 },
        else => .{ "invalid event input", 2 },
    };
    stderr.print("events: {s}\n", .{message}) catch {};
    return code;
}

test "Events help requires neither credentials nor a backend" {
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    try std.testing.expectEqual(
        @as(u8, 0),
        run(
            std.testing.allocator,
            &.{ "events", "--help" },
            "",
            &stdout.writer,
            &stderr.writer,
            null,
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "EVENTS_TABLE_NAME") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.written().len);
}

const fixture_json =
    \\{"tenant":"tenant-a","event_id":"00000000-0000-0000-0000-000000000001","ledger":1001,"timeout_seconds":30,"capacity_account_id":"1","allocation_account_id":"2","state":"creating","classes":{"a":{"total":10,"tb_account_id":"3"}}}
;
const create_arguments = [_][]const u8{
    "events",
    "create",
    "--tenant",
    "tenant-a",
    "--event-id",
    "00000000-0000-0000-0000-000000000001",
};
const read_arguments = [_][]const u8{
    "events", "read", "--event-id", "00000000-0000-0000-0000-000000000001", "--tenant", "tenant-a",
};

const TestStore = struct {
    allocator: Allocator,
    item: ?[]const persistence.Attribute = null,
    fail: bool = false,
    lose_after_put: bool = false,

    pub fn create(self: *TestStore, arena: Allocator, event: *const seat.Event) !seat.Event {
        return persistence.insert(arena, "events-test", event, self);
    }
    pub fn read(self: *TestStore, arena: Allocator, key: *const seat.EventKey) !seat.Event {
        return persistence.read_event(arena, "events-test", key, self);
    }
    pub fn put(self: *TestStore, arena: Allocator, request: anytype) !void {
        if (self.fail) return error.AWSFailure;
        if (self.item != null) return error.InsertConflict;
        const event = try persistence.decode_item(arena, request.item);
        self.item = try persistence.encode_item(self.allocator, &event);
        if (self.lose_after_put) return error.AWSFailure;
    }
    pub fn get(
        self: *TestStore,
        arena: Allocator,
        request: anytype,
    ) !?[]const persistence.Attribute {
        if (self.fail) return error.AWSFailure;
        const item = self.item orelse return null;
        const event = try persistence.decode_item(arena, item);
        if (!std.mem.eql(u8, request.key[0].value.s.?, event.tenant)) return null;
        if (try seat.canonical_uuid(request.key[1].value.s.?) != event.event_id) return null;
        return item;
    }
};

test "Events create read retries and conflicts use shared persistence and JSON output" {
    var durable = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer durable.deinit();
    var store: TestStore = .{ .allocator = durable.allocator(), .lose_after_put = true };
    const backend = Backend.init(&store);
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    try std.testing.expectEqual(
        @as(u8, 0),
        run(
            std.testing.allocator,
            &create_arguments,
            fixture_json,
            &stdout.writer,
            &stderr.writer,
            backend,
        ),
    );
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    const created = try seat.decode_event(result_arena.allocator(), stdout.written());
    try std.testing.expectEqual(seat.EventState.creating, created.state);
    stdout.clearRetainingCapacity();
    try std.testing.expectEqual(
        @as(u8, 0),
        run(std.testing.allocator, &read_arguments, "", &stdout.writer, &stderr.writer, backend),
    );
    try std.testing.expectEqualStrings(fixture_json ++ "\n", stdout.written());
    stdout.clearRetainingCapacity();
    var loser = created;
    loser.ledger = 1002;
    loser.capacity_account_id = 4;
    const loser_json = try seat.encode_event(result_arena.allocator(), &loser);
    try std.testing.expectEqual(
        @as(u8, 0),
        run(
            std.testing.allocator,
            &create_arguments,
            loser_json,
            &stdout.writer,
            &stderr.writer,
            backend,
        ),
    );
    try std.testing.expectEqualStrings(fixture_json ++ "\n", stdout.written());
    stdout.clearRetainingCapacity();
    loser.timeout_seconds = 31;
    try std.testing.expectEqual(
        @as(u8, 1),
        run(
            std.testing.allocator,
            &create_arguments,
            try seat.encode_event(result_arena.allocator(), &loser),
            &stdout.writer,
            &stderr.writer,
            backend,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), stdout.written().len);
    try std.testing.expectEqualStrings("events: event configuration conflict\n", stderr.written());
}

test "Events invalid identity state schema and limits leave storage absent" {
    var durable = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer durable.deinit();
    var store: TestStore = .{ .allocator = durable.allocator() };
    const backend = Backend.init(&store);
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var event = try seat.decode_event(arena.allocator(), fixture_json);
    for ([_]seat.EventState{ .ready, .failed }) |state| {
        event.state = state;
        try std.testing.expectEqual(
            @as(u8, 2),
            run(
                std.testing.allocator,
                &create_arguments,
                try seat.encode_event(arena.allocator(), &event),
                &stdout.writer,
                &stderr.writer,
                backend,
            ),
        );
    }
    event.state = .creating;
    event.tenant = "tenant-b";
    try std.testing.expectEqual(
        @as(u8, 2),
        run(
            std.testing.allocator,
            &create_arguments,
            try seat.encode_event(arena.allocator(), &event),
            &stdout.writer,
            &stderr.writer,
            backend,
        ),
    );
    for ([_][]const u8{ "{}", "null", fixture_json ++ "{}", "x" ** 16385 }) |input| {
        try std.testing.expectEqual(
            @as(u8, 2),
            run(
                std.testing.allocator,
                &create_arguments,
                input,
                &stdout.writer,
                &stderr.writer,
                backend,
            ),
        );
    }
    try std.testing.expectEqual(@as(usize, 0), stdout.written().len);
    try std.testing.expectEqual(
        @as(u8, 1),
        run(std.testing.allocator, &read_arguments, "", &stdout.writer, &stderr.writer, backend),
    );
    var foreign = read_arguments;
    foreign[5] = "tenant-b";
    try std.testing.expectEqual(
        @as(u8, 1),
        run(std.testing.allocator, &foreign, "", &stdout.writer, &stderr.writer, backend),
    );
}

test "Events reports sanitized failures and rejects unbounded or unsupported invocations" {
    var durable = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer durable.deinit();
    var store: TestStore = .{ .allocator = durable.allocator(), .fail = true };
    const backend = Backend.init(&store);
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    try std.testing.expectEqual(
        @as(u8, 2),
        run(
            std.testing.allocator,
            &create_arguments,
            fixture_json,
            &stdout.writer,
            &stderr.writer,
            backend,
        ),
    );
    try std.testing.expectEqualStrings("events: AWS request failed\n", stderr.written());
    const cases = [_][]const []const u8{
        &.{
            "events",
            "delete-all",
        },
        &.{ "events", "reset" },
        &.{ "events", "update" },
        &.{ "events", "read" },
        &.{ "events", "--help", "x" },
        &.{
            "events",
            "read",
            "--tenant",
            "a",
            "--tenant",
            "b",
        },
        &.{
            "events",
            "read",
            "--tenant",
            "",
            "--event-id",
            "00000000-0000-0000-0000-000000000001",
        },
        &.{
            "events",
            "read",
            "--tenant",
            "x" ** 65,
            "--event-id",
            "00000000-0000-0000-0000-000000000001",
        },
        &.{
            "events",
            "read",
            "--tenant",
            "a",
            "--event-id",
            "00112233-4455-6677-8899-AABBCCDDEEFF",
        },
        &.{ "events", "x" ** 4097 },
    };
    for (cases) |arguments| {
        stderr.clearRetainingCapacity();
        try std.testing.expectEqual(
            @as(u8, 2),
            run(std.testing.allocator, arguments, "", &stdout.writer, &stderr.writer, backend),
        );
        try std.testing.expectEqualStrings(
            "events: invalid invocation; use --help\n",
            stderr.written(),
        );
    }
    try std.testing.expectEqual(@as(usize, 0), stdout.written().len);
}
