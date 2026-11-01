const std = @import("std");
const aws = @import("aws");
const counter = @import("ledger_counter");
const Allocator = std.mem.Allocator;

const argument_count_max = 5;
const Invocation = struct { command: Command, id: ?[]const u8 = null };
const argument_size_max = 256;
const Command = enum { help, init, read, allocate };
const usage =
    \\Usage:
    \\  ledger-counter init
    \\  ledger-counter read
    \\  ledger-counter allocate
    \\
    \\Use --counter-id <id> before a command to select an independent sequence.
    \\Explicit first-time init stores 1000 absent-only and preserves existing state.
    \\Allocation returns the new high_water; first allocation is 1001. Gaps are permitted.
    \\No stdin is consumed. No reset, decrement, recycle, or delete command exists.
    \\
    \\Environment:
    \\  LEDGER_COUNTER_TABLE_NAME  Physical DynamoDB counter table
    \\  LEDGER_COUNTER_ID          Selected ID; defaults to global
    \\  AWS_*                      Standard credentials, Region, profile and endpoint
    \\
;

pub fn main(init: std.process.Init) u8 {
    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    var stderr = std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
    const code = main_execute(init, &stdout.interface) catch |err| {
        return finish(&stdout.interface, &stderr.interface, report_error(&stderr.interface, err));
    };
    return finish(&stdout.interface, &stderr.interface, code);
}

fn main_execute(init: std.process.Init, stdout: *std.Io.Writer) !u8 {
    var arguments_buffer: [argument_count_max][]const u8 = undefined;
    var iterator = std.process.Args.Iterator.init(init.minimal.args);
    var count: usize = 0;
    while (iterator.next()) |argument| {
        if (count == arguments_buffer.len or argument.len > argument_size_max) {
            return error.InvalidInvocation;
        }
        arguments_buffer[count] = argument;
        count += 1;
    }
    const invocation = try parse_command(arguments_buffer[0..count]);
    if (invocation.command == .help) {
        try stdout.writeAll(usage);
        return 0;
    }
    const id = try counter.select_id(&.{
        .explicit_id = invocation.id,
        .configured_id = init.environ_map.get("LEDGER_COUNTER_ID"),
    });
    const table = init.environ_map.get("LEDGER_COUNTER_TABLE_NAME") orelse
        return error.InvalidConfiguration;
    try counter.validate_table_name(table);
    var config = aws.Config.load(init.gpa, init.io, init.environ_map, .{
        .max_attempts = 1,
    }) catch return error.InvalidConfiguration;
    defer config.deinit();
    var store: counter.Counter = undefined;
    try store.init_with_id(init.gpa, &config, init.environ_map, id);
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    try execute(arena.allocator(), invocation.command, id, stdout, Backend.init(&store));
    return 0;
}

fn finish(stdout: *std.Io.Writer, stderr: *std.Io.Writer, code: u8) u8 {
    stdout.flush() catch {
        _ = report_error(stderr, error.OutputFailed);
        stderr.flush() catch {};
        return 2;
    };
    stderr.flush() catch return 2;
    return code;
}

fn is_help(argument: []const u8) bool {
    return std.mem.eql(u8, argument, "--help") or std.mem.eql(u8, argument, "-h") or
        std.mem.eql(u8, argument, "help");
}

fn parse_command(arguments: []const []const u8) !Invocation {
    if (arguments.len < 2 or arguments.len > argument_count_max) return error.InvalidInvocation;
    for (arguments) |argument| if (argument.len > argument_size_max) return error.InvalidInvocation;
    var index: usize = 1;
    var id: ?[]const u8 = null;
    if (std.mem.eql(u8, arguments[index], "--counter-id")) {
        if (arguments.len < 4) return error.InvalidInvocation;
        id = arguments[index + 1];
        counter.validate_id(id.?) catch return error.InvalidInvocation;
        index += 2;
    }
    if (index + 1 == arguments.len and is_help(arguments[index])) {
        return .{ .command = .help, .id = id };
    }
    const command = std.meta.stringToEnum(Command, arguments[index]) orelse
        return error.InvalidInvocation;
    if (command == .help) return error.InvalidInvocation;
    if (index + 2 == arguments.len and is_help(arguments[index + 1])) {
        return .{ .command = .help, .id = id };
    }
    if (index + 1 != arguments.len) return error.InvalidInvocation;
    return .{ .command = command, .id = id };
}

pub const Backend = struct {
    context: *anyopaque,
    invoke_fn: *const fn (*anyopaque, Allocator, Command, []const u8) anyerror!u32,

    pub fn init(pointer: anytype) Backend {
        const Pointer = @TypeOf(pointer);
        const Adapter = struct {
            fn invoke(
                context: *anyopaque,
                arena: Allocator,
                command: Command,
                id: []const u8,
            ) !u32 {
                const self: Pointer = @ptrCast(@alignCast(context));
                return switch (command) {
                    .init => self.setup_selected(arena, id),
                    .read => self.read_selected(arena, id),
                    .allocate => self.allocate_selected(arena, id),
                    .help => unreachable,
                };
            }
        };
        return .{ .context = pointer, .invoke_fn = Adapter.invoke };
    }
};

/// The injected boundary replaces persistence only; command validation and output remain real.
pub fn run(
    allocator: Allocator,
    arguments: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    backend: ?Backend,
) u8 {
    return run_with_id(allocator, arguments, null, stdout, stderr, backend);
}

pub fn run_with_id(
    allocator: Allocator,
    arguments: []const []const u8,
    configured_id: ?[]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    backend: ?Backend,
) u8 {
    const invocation = parse_command(arguments) catch |err| return report_error(stderr, err);
    var id: []const u8 = counter.counter_id;
    if (invocation.command != .help) {
        id = counter.select_id(&.{
            .explicit_id = invocation.id,
            .configured_id = configured_id,
        }) catch |err| {
            return report_error(stderr, err);
        };
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    execute(
        arena.allocator(),
        invocation.command,
        id,
        stdout,
        backend,
    ) catch |err| return report_error(stderr, err);
    return 0;
}

fn execute(
    arena: Allocator,
    command: Command,
    id: []const u8,
    stdout: *std.Io.Writer,
    optional: ?Backend,
) !void {
    if (command == .help) {
        try stdout.writeAll(usage);
        return;
    }
    const backend = optional orelse return error.InvalidConfiguration;
    const high_water = try backend.invoke_fn(backend.context, arena, command, id);
    if (high_water < counter.initial_high_water) {
        return if (command == .allocate) error.AllocationUncertain else error.CounterCorrupt;
    }
    if (command == .allocate and high_water == counter.initial_high_water) {
        return error.AllocationUncertain;
    }
    std.debug.assert(high_water >= counter.initial_high_water);
    stdout.print("{{\"counter_id\":\"{s}\",\"high_water\":{d}}}\n", .{
        id, high_water,
    }) catch |err| {
        return if (command == .allocate) error.AllocationUncertain else err;
    };
}

fn report_error(stderr: *std.Io.Writer, err: anyerror) u8 {
    const message, const code: u8 = switch (err) {
        error.InvalidInvocation => .{ "invalid invocation; use --help", 2 },
        error.InvalidCounterId, error.InvalidConfiguration => .{
            "missing or invalid configuration", 2,
        },
        error.CounterMissing => .{ "counter missing; verify allocator binding and setup", 1 },
        error.CounterExhausted => .{ "ledger sequence exhausted", 1 },
        error.CounterCorrupt => .{ "stored counter is invalid", 2 },
        error.CounterContended => .{ "counter busy; retry allocation", 2 },
        error.CounterTransient => .{ "request throttled; retry command", 2 },
        error.InitializationUncertain => .{
            "setup uncertain; rerun explicit init to preserve state", 2,
        },
        error.AllocationUncertain => .{
            "allocation uncertain; value may be consumed; do not infer it from read", 2,
        },
        error.AWSFailure => .{ "AWS request failed", 2 },
        error.OutputFailed => .{ "output failed; a mutation may have succeeded", 2 },
        else => .{ "operation failed", 2 },
    };
    stderr.print("ledger-counter: {s}\n", .{message}) catch {};
    return code;
}

test "counter help requires neither credentials nor a backend" {
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    for ([_][]const []const u8{
        &.{ "ledger-counter", "--help" },
        &.{ "ledger-counter", "-h" },
        &.{ "ledger-counter", "help" },
        &.{ "ledger-counter", "init", "--help" },
        &.{ "ledger-counter", "read", "-h" },
        &.{ "ledger-counter", "allocate", "help" },
    }) |arguments| {
        stdout.clearRetainingCapacity();
        try std.testing.expectEqual(
            @as(u8, 0),
            run(std.testing.allocator, arguments, &stdout.writer, &stderr.writer, null),
        );
        try std.testing.expect(std.mem.startsWith(u8, stdout.written(), "Usage:\n"));
        try std.testing.expectEqualStrings("", stderr.written());
    }
}

const TestCounter = struct {
    high_water: u32 = 1000,
    selected_id: []const u8 = "global",
    failure: ?anyerror = null,
    calls: u8 = 0,

    pub fn setup_selected(self: *TestCounter, arena: Allocator, id: []const u8) !u32 {
        self.selected_id = id;
        return self.setup(arena);
    }
    pub fn read_selected(self: *TestCounter, arena: Allocator, id: []const u8) !u32 {
        self.selected_id = id;
        return self.read(arena);
    }
    pub fn allocate_selected(self: *TestCounter, arena: Allocator, id: []const u8) !u32 {
        self.selected_id = id;
        return self.allocate(arena);
    }
    pub fn setup(self: *TestCounter, arena: Allocator) !u32 {
        return self.read(arena);
    }
    pub fn read(self: *TestCounter, _: Allocator) !u32 {
        self.calls += 1;
        if (self.failure) |err| return err;
        return self.high_water;
    }
    pub fn allocate(self: *TestCounter, arena: Allocator) !u32 {
        _ = try self.read(arena);
        self.high_water += 1;
        return self.high_water;
    }
};

test "explicit and configured selection reaches persistence and JSON with bounded validation" {
    const cases = [_]struct {
        arguments: []const []const u8,
        configured_id: ?[]const u8,
        expected_id: []const u8,
    }{
        .{
            .arguments = &.{ "ledger-counter", "read" },
            .configured_id = null,
            .expected_id = "global",
        },
        .{
            .arguments = &.{ "ledger-counter", "read" },
            .configured_id = "configured",
            .expected_id = "configured",
        },
        .{
            .arguments = &.{ "ledger-counter", "--counter-id", "Alpha-1", "read" },
            .configured_id = "configured",
            .expected_id = "Alpha-1",
        },
        .{
            .arguments = &.{ "ledger-counter", "--counter-id", "global", "read" },
            .configured_id = "",
            .expected_id = "global",
        },
    };
    for (cases) |case| {
        var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer stdout.deinit();
        var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer stderr.deinit();
        var database: TestCounter = .{};
        try std.testing.expectEqual(@as(u8, 0), run_with_id(
            std.testing.allocator,
            case.arguments,
            case.configured_id,
            &stdout.writer,
            &stderr.writer,
            Backend.init(&database),
        ));
        try std.testing.expectEqualStrings(case.expected_id, database.selected_id);
        const expected = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"counter_id\":\"{s}\",\"high_water\":1000}}\n",
            .{case.expected_id},
        );
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, stdout.written());
        try std.testing.expectEqualStrings("", stderr.written());
    }
}

test "selected command and configuration validation precedes persistence effects" {
    const invalid = [_][]const []const u8{
        &.{ "ledger-counter", "--counter-id" },
        &.{ "ledger-counter", "--counter-id", "a" },
        &.{ "ledger-counter", "--counter-id", "", "read" },
        &.{ "ledger-counter", "--counter-id", "a/b", "init" },
        &.{ "ledger-counter", "--counter-id", "-a", "allocate" },
        &.{ "ledger-counter", "--counter-id", "a" ** 129, "read" },
        &.{ "ledger-counter", "--counter-id", "a", "--counter-id", "b", "read" },
        &.{ "ledger-counter", "--counter-id", "a", "read", "extra" },
        &.{ "ledger-counter", "read", "--counter-id", "a" },
    };
    for (invalid) |arguments| {
        var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer stdout.deinit();
        var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer stderr.deinit();
        var database: TestCounter = .{};
        try std.testing.expectEqual(@as(u8, 2), run(
            std.testing.allocator,
            arguments,
            &stdout.writer,
            &stderr.writer,
            Backend.init(&database),
        ));
        try std.testing.expectEqual(@as(u8, 0), database.calls);
        try std.testing.expectEqualStrings("", stdout.written());
        try std.testing.expectEqualStrings(
            "ledger-counter: invalid invocation; use --help\n",
            stderr.written(),
        );
    }
    for ([_][]const u8{ "", ".a", "a b", "é", "a" ** 129 }) |id| {
        var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer stdout.deinit();
        var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer stderr.deinit();
        var database: TestCounter = .{};
        try std.testing.expectEqual(@as(u8, 2), run_with_id(
            std.testing.allocator,
            &.{ "ledger-counter", "read" },
            id,
            &stdout.writer,
            &stderr.writer,
            Backend.init(&database),
        ));
        try std.testing.expectEqual(@as(u8, 0), database.calls);
        try std.testing.expectEqualStrings("", stdout.written());
        try std.testing.expectEqualStrings(
            "ledger-counter: missing or invalid configuration\n",
            stderr.written(),
        );
    }
}

test "all selected commands accept boundary IDs and help ignores environment configuration" {
    for ([_][]const u8{ "init", "read", "allocate" }) |command| {
        for ([_][]const u8{ "0", "a" ** 128 }) |id| {
            var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
            defer stdout.deinit();
            var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
            defer stderr.deinit();
            var database: TestCounter = .{};
            try std.testing.expectEqual(@as(u8, 0), run(
                std.testing.allocator,
                &.{ "ledger-counter", "--counter-id", id, command },
                &stdout.writer,
                &stderr.writer,
                Backend.init(&database),
            ));
            try std.testing.expectEqualStrings(id, database.selected_id);
            try std.testing.expectEqual(@as(u8, 1), database.calls);
        }
    }
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    try std.testing.expectEqual(@as(u8, 0), run_with_id(
        std.testing.allocator,
        &.{ "ledger-counter", "--counter-id", "selected", "init", "--help" },
        "",
        &stdout.writer,
        &stderr.writer,
        null,
    ));
    try std.testing.expect(std.mem.startsWith(u8, stdout.written(), "Usage:\n"));
    try std.testing.expectEqualStrings("", stderr.written());
}

test "counter commands print bounded JSON and reject invalid invocations before effects" {
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var store: TestCounter = .{};
    for ([_][]const u8{ "init", "read", "allocate" }) |command| {
        stdout.clearRetainingCapacity();
        const code = run(
            std.testing.allocator,
            &.{ "ledger-counter", command },
            &stdout.writer,
            &stderr.writer,
            Backend.init(&store),
        );
        try std.testing.expectEqual(@as(u8, 0), code);
        const expected = if (std.mem.eql(u8, command, "allocate"))
            "{\"counter_id\":\"global\",\"high_water\":1001}\n"
        else
            "{\"counter_id\":\"global\",\"high_water\":1000}\n";
        try std.testing.expectEqualStrings(expected, stdout.written());
        try std.testing.expectEqualStrings("", stderr.written());
    }
    const calls = store.calls;
    const invalid = [_][]const []const u8{
        &.{"ledger-counter"},
        &.{ "ledger-counter", "reset" },
        &.{ "ledger-counter", "delete-all" },
        &.{ "ledger-counter", "read", "extra" },
        &.{ "ledger-counter", "read", "--cluster-id", "1" },
        &.{ "ledger-counter", "a" ** (argument_size_max + 1) },
        &.{ "ledger-counter", "help", "extra" },
    };
    for (invalid) |arguments| {
        stdout.clearRetainingCapacity();
        stderr.clearRetainingCapacity();
        try std.testing.expectEqual(
            @as(u8, 2),
            run(
                std.testing.allocator,
                arguments,
                &stdout.writer,
                &stderr.writer,
                Backend.init(&store),
            ),
        );
        try std.testing.expectEqualStrings("", stdout.written());
        try std.testing.expectEqualStrings(
            "ledger-counter: invalid invocation; use --help\n",
            stderr.written(),
        );
    }
    try std.testing.expectEqual(calls, store.calls);
}

test "counter operating errors have stable exits and sanitized diagnostics" {
    const cases = [_]struct { failure: anyerror, code: u8, message: []const u8 }{
        .{
            .failure = error.CounterMissing,
            .code = 1,
            .message = "counter missing; verify allocator binding and setup",
        },
        .{ .failure = error.CounterExhausted, .code = 1, .message = "ledger sequence exhausted" },
        .{ .failure = error.CounterCorrupt, .code = 2, .message = "stored counter is invalid" },
        .{
            .failure = error.CounterContended,
            .code = 2,
            .message = "counter busy; retry allocation",
        },
        .{
            .failure = error.CounterTransient,
            .code = 2,
            .message = "request throttled; retry command",
        },
        .{
            .failure = error.InitializationUncertain,
            .code = 2,
            .message = "setup uncertain; rerun explicit init to preserve state",
        },
        .{
            .failure = error.AllocationUncertain,
            .code = 2,
            .message = "allocation uncertain; value may be consumed; do not infer it from read",
        },
        .{ .failure = error.AWSFailure, .code = 2, .message = "AWS request failed" },
        .{ .failure = error.private_credentials_marker, .code = 2, .message = "operation failed" },
    };
    for (cases) |case| {
        var stdout_buffer: [128]u8 = undefined;
        var stderr_buffer: [256]u8 = undefined;
        var stdout = std.Io.Writer.fixed(&stdout_buffer);
        var stderr = std.Io.Writer.fixed(&stderr_buffer);
        var store: TestCounter = .{ .failure = case.failure };
        try std.testing.expectEqual(
            case.code,
            run(
                std.testing.allocator,
                &.{ "ledger-counter", "read" },
                &stdout,
                &stderr,
                Backend.init(&store),
            ),
        );
        try std.testing.expectEqualStrings("", stdout.buffered());
        const expected = try std.fmt.allocPrint(
            std.testing.allocator,
            "ledger-counter: {s}\n",
            .{case.message},
        );
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, stderr.buffered());
    }
    var stdout_buffer: [1]u8 = undefined;
    var stderr_buffer: [256]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_buffer);
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    var store: TestCounter = .{};
    try std.testing.expectEqual(
        @as(u8, 2),
        run(
            std.testing.allocator,
            &.{ "ledger-counter", "allocate" },
            &stdout,
            &stderr,
            Backend.init(&store),
        ),
    );
    try std.testing.expectEqual(@as(u32, 1001), store.high_water);
}
