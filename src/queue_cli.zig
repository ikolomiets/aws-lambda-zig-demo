const std = @import("std");
const aws = @import("aws");
const operation = @import("operation");
const sqs_queue = @import("sqs_queue");

const Allocator = std.mem.Allocator;

const argument_count_max = 5;
const stdin_size_max = 8 * 1024;
const io_buffer_size = 4096;
const receive_loop_is_intentionally_unbounded = true;

comptime {
    std.debug.assert(stdin_size_max > operation.body_size_max);
    std.debug.assert(argument_count_max < stdin_size_max);
    std.debug.assert(receive_loop_is_intentionally_unbounded);
}

const Command = union(enum) {
    help,
    send: SendOptions,
    receive,
    check,
};

const Invocation = struct {
    queue_name: ?[]const u8,
    command: Command,
};

const SendOptions = struct {
    tenant: []const u8,
};

const Context = struct {
    allocator: Allocator,
    now: operation.UnixSeconds,
    stdin: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

const CliError = error{InvalidInvocation};

const usage =
    \\Usage:
    \\  sqs <queue-name> send --tenant <tenant>
    \\  sqs <queue-name> receive
    \\  sqs <queue-name> check
    \\
    \\Commands:
    \\  send     Read an Operation from stdin and enqueue it as SUBMITTED
    \\  receive  Long-poll, print, and delete messages until interrupted
    \\  check    Print all queue attributes as JSON
    \\
    \\Environment:
    \\  <queue-name>  URL of the selected SQS queue
    \\  AWS_*         Standard AWS credentials, region, profile, and endpoint
    \\
;

pub fn main(init: std.process.Init) u8 {
    var stdout_buffer: [io_buffer_size]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    var stderr_file = std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);

    var arguments_buffer: [argument_count_max][]const u8 = undefined;
    const arguments = collectArguments(init.minimal.args, &arguments_buffer) catch {
        return finish(&stdout_file.interface, &stderr_file.interface, 2, .invocation);
    };
    const invocation = parseCommand(arguments) catch {
        return finish(&stdout_file.interface, &stderr_file.interface, 2, .invocation);
    };
    const command = invocation.command;
    var stdin_buffer: [stdin_size_max + 1]u8 = undefined;
    const stdin = readCommandInput(init.io, command, &stdin_buffer) catch {
        return finish(&stdout_file.interface, &stderr_file.interface, 2, .validation);
    };
    const context = Context{
        .allocator = init.gpa,
        .now = unixSeconds(init.io),
        .stdin = stdin,
        .stdout = &stdout_file.interface,
        .stderr = &stderr_file.interface,
    };
    if (command == .help) {
        const code = runCommand(command, context, null);
        return finish(context.stdout, context.stderr, code, null);
    }
    std.debug.assert(invocation.queue_name != null);

    var config = aws.Config.load(init.gpa, init.io, init.environ_map, .{}) catch {
        return finish(context.stdout, context.stderr, 2, .configuration);
    };
    defer config.deinit();
    var queue: sqs_queue.Queue = undefined;
    sqs_queue.Queue.init(
        &queue,
        init.gpa,
        &config,
        init.environ_map,
        invocation.queue_name.?,
    ) catch {
        return finish(context.stdout, context.stderr, 2, .configuration);
    };
    defer queue.deinit();
    const backend = QueueInterface.init(&queue);
    const code = runCommand(command, context, backend);
    return finish(context.stdout, context.stderr, code, null);
}

const Failure = enum {
    invocation,
    validation,
    configuration,
    aws,
    response,
    internal,

    fn code(failure: Failure) u8 {
        return switch (failure) {
            .invocation,
            .validation,
            .configuration,
            .aws,
            .response,
            .internal,
            => 2,
        };
    }
};

fn finish(
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    exit_code: u8,
    failure: ?Failure,
) u8 {
    if (failure) |value| writeDiagnostic(stderr, value);
    stdout.flush() catch return 2;
    stderr.flush() catch return 2;
    return exit_code;
}

fn writeDiagnostic(stderr: *std.Io.Writer, failure: Failure) void {
    const message = switch (failure) {
        .invocation => "sqs: invalid invocation; use --help\n",
        .validation => "sqs: invalid operation input\n",
        .configuration => "sqs: missing or invalid configuration\n",
        .aws => "sqs: AWS request failed\n",
        .response => "sqs: invalid AWS response\n",
        .internal => "sqs: operation failed\n",
    };
    stderr.writeAll(message) catch {};
}

fn collectArguments(
    process_arguments: std.process.Args,
    buffer: *[argument_count_max][]const u8,
) CliError![]const []const u8 {
    var iterator = std.process.Args.Iterator.init(process_arguments);
    var count: usize = 0;
    while (iterator.next()) |argument| {
        if (count == buffer.len) return error.InvalidInvocation;
        buffer[count] = argument;
        count += 1;
    }
    if (count == 0) return error.InvalidInvocation;
    std.debug.assert(count > 0);
    std.debug.assert(count <= buffer.len);
    return buffer[0..count];
}

fn readCommandInput(
    io: std.Io,
    command: Command,
    buffer: *[stdin_size_max + 1]u8,
) ![]const u8 {
    switch (command) {
        .send => {},
        .help, .receive, .check => return "",
    }

    var reader_buffer: [io_buffer_size]u8 = undefined;
    var stdin_file = std.Io.File.stdin().readerStreaming(io, &reader_buffer);
    const size = try stdin_file.interface.readSliceShort(buffer);
    if (size > stdin_size_max) return error.InputTooLarge;
    const input = buffer[0..size];
    try validateCommandInput(command, input);
    std.debug.assert(input.len <= stdin_size_max);
    std.debug.assert(input.len <= buffer.len);
    return input;
}

fn validateCommandInput(command: Command, input: []const u8) !void {
    if (input.len > stdin_size_max) return error.InputTooLarge;
    switch (command) {
        .send => {},
        .help, .receive, .check => std.debug.assert(input.len == 0),
    }
}

fn unixSeconds(io: std.Io) operation.UnixSeconds {
    const timestamp = std.Io.Clock.real.now(io);
    const seconds = @divFloor(timestamp.nanoseconds, std.time.ns_per_s);
    const result = std.math.cast(operation.UnixSeconds, seconds) orelse {
        return if (seconds < 0) std.math.minInt(i64) else std.math.maxInt(i64);
    };
    std.debug.assert(result >= std.math.minInt(operation.UnixSeconds));
    std.debug.assert(result <= std.math.maxInt(operation.UnixSeconds));
    return result;
}

fn parseCommand(arguments: []const []const u8) CliError!Invocation {
    if (arguments.len < 2) return error.InvalidInvocation;
    if (arguments.len > argument_count_max) return error.InvalidInvocation;

    const queue_name = arguments[1];
    if (isHelp(queue_name)) {
        if (arguments.len != 2) return error.InvalidInvocation;
        return .{ .queue_name = null, .command = .help };
    }
    try validateQueueName(queue_name);
    if (arguments.len < 3) return error.InvalidInvocation;

    const command_name = arguments[2];
    if (isHelp(command_name)) {
        if (arguments.len != 3) return error.InvalidInvocation;
        return .{ .queue_name = queue_name, .command = .help };
    }
    if (std.mem.eql(u8, command_name, "send")) {
        return .{ .queue_name = queue_name, .command = try parseSend(arguments[3..]) };
    }
    if (std.mem.eql(u8, command_name, "receive")) {
        return .{
            .queue_name = queue_name,
            .command = try parseNoOptions(arguments[3..], .receive),
        };
    }
    if (std.mem.eql(u8, command_name, "check")) {
        return .{
            .queue_name = queue_name,
            .command = try parseNoOptions(arguments[3..], .check),
        };
    }
    return error.InvalidInvocation;
}

fn validateQueueName(queue_name: []const u8) CliError!void {
    if (queue_name.len == 0) return error.InvalidInvocation;
    if (queue_name.len > sqs_queue.environment_variable_name_size_max) {
        return error.InvalidInvocation;
    }
    if (!std.ascii.isAlphabetic(queue_name[0])) return error.InvalidInvocation;
    for (queue_name[1..]) |character| {
        if (!std.ascii.isAlphanumeric(character)) return error.InvalidInvocation;
    }
    std.debug.assert(queue_name.len > 0);
    std.debug.assert(queue_name.len <= sqs_queue.environment_variable_name_size_max);
}

fn parseSend(arguments: []const []const u8) CliError!Command {
    if (arguments.len == 1) {
        if (isHelp(arguments[0])) return .help;
    }
    if (arguments.len != 2) return error.InvalidInvocation;
    if (!std.mem.eql(u8, arguments[0], "--tenant")) return error.InvalidInvocation;
    operation.validateTenant(arguments[1]) catch return error.InvalidInvocation;
    return .{ .send = .{ .tenant = arguments[1] } };
}

fn parseNoOptions(arguments: []const []const u8, command: Command) CliError!Command {
    std.debug.assert(command == .receive or command == .check);
    if (arguments.len == 0) return command;
    if (arguments.len == 1) {
        if (isHelp(arguments[0])) return .help;
    }
    return error.InvalidInvocation;
}

fn isHelp(argument: []const u8) bool {
    if (std.mem.eql(u8, argument, "--help")) return true;
    if (std.mem.eql(u8, argument, "-h")) return true;
    return std.mem.eql(u8, argument, "help");
}

const QueueInterface = struct {
    context: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        send: *const fn (
            *anyopaque,
            Allocator,
            []const u8,
        ) anyerror!void,
        receive: *const fn (
            *anyopaque,
            Allocator,
        ) anyerror!?sqs_queue.Message,
        delete: *const fn (
            *anyopaque,
            Allocator,
            []const u8,
        ) anyerror!void,
        get_attributes: *const fn (
            *anyopaque,
            Allocator,
        ) anyerror![]const sqs_queue.Attribute,
    };

    fn init(pointer: anytype) QueueInterface {
        const Pointer = @TypeOf(pointer);
        const pointer_info = @typeInfo(Pointer);
        comptime std.debug.assert(pointer_info == .pointer);
        comptime std.debug.assert(pointer_info.pointer.size == .one);

        const Adapter = struct {
            fn send(
                context: *anyopaque,
                allocator: Allocator,
                body: []const u8,
            ) anyerror!void {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.send(allocator, body);
            }

            fn receive(
                context: *anyopaque,
                allocator: Allocator,
            ) anyerror!?sqs_queue.Message {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.receive(allocator);
            }

            fn delete(
                context: *anyopaque,
                allocator: Allocator,
                receipt_handle: []const u8,
            ) anyerror!void {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.delete(allocator, receipt_handle);
            }

            fn get_attributes(
                context: *anyopaque,
                allocator: Allocator,
            ) anyerror![]const sqs_queue.Attribute {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.get_attributes(allocator);
            }
        };
        return .{
            .context = pointer,
            .vtable = &.{
                .send = Adapter.send,
                .receive = Adapter.receive,
                .delete = Adapter.delete,
                .get_attributes = Adapter.get_attributes,
            },
        };
    }

    fn send(
        self: QueueInterface,
        allocator: Allocator,
        body: []const u8,
    ) !void {
        return self.vtable.send(self.context, allocator, body);
    }

    fn receive(
        self: QueueInterface,
        allocator: Allocator,
    ) !?sqs_queue.Message {
        return self.vtable.receive(self.context, allocator);
    }

    fn delete(
        self: QueueInterface,
        allocator: Allocator,
        receipt_handle: []const u8,
    ) !void {
        return self.vtable.delete(self.context, allocator, receipt_handle);
    }

    fn get_attributes(
        self: QueueInterface,
        allocator: Allocator,
    ) ![]const sqs_queue.Attribute {
        return self.vtable.get_attributes(self.context, allocator);
    }
};

fn runCommand(
    command: Command,
    context: Context,
    backend: ?QueueInterface,
) u8 {
    if (command == .receive) {
        const receive_backend = backend orelse {
            writeDiagnostic(context.stderr, .internal);
            return Failure.internal.code();
        };
        return executeReceiveLoop(context, receive_backend) catch |err| {
            const failure = classifyError(err);
            writeDiagnostic(context.stderr, failure);
            return failure.code();
        };
    }

    var arena = std.heap.ArenaAllocator.init(context.allocator);
    defer arena.deinit();
    const command_context = Context{
        .allocator = arena.allocator(),
        .now = context.now,
        .stdin = context.stdin,
        .stdout = context.stdout,
        .stderr = context.stderr,
    };
    executeCommand(command, command_context, backend) catch |err| {
        const failure = classifyError(err);
        writeDiagnostic(context.stderr, failure);
        return failure.code();
    };
    return 0;
}

fn classifyError(err: anyerror) Failure {
    return switch (err) {
        error.InvalidInvocation => .invocation,
        error.AWSFailure => .aws,
        error.InvalidServiceResponse => .response,
        error.InvalidJSON,
        error.MissingField,
        error.DuplicateField,
        error.ForbiddenField,
        error.UnknownField,
        error.InvalidUUID,
        error.InvalidTenant,
        error.InvalidName,
        error.InvalidState,
        error.BodyTooLarge,
        error.ResultTooLarge,
        error.MissingState,
        error.MissingLastUpdated,
        error.MissingExpiresAt,
        error.InvalidExpiresAt,
        error.MissingHash,
        error.MissingResult,
        error.UnexpectedBody,
        error.UnexpectedResult,
        error.InputTooLarge,
        error.InvalidMessage,
        error.InvalidReceiptHandle,
        => .validation,
        else => .internal,
    };
}

fn executeCommand(
    command: Command,
    context: Context,
    backend_optional: ?QueueInterface,
) !void {
    if (command == .help) {
        try context.stdout.writeAll(usage);
        return;
    }
    const backend = backend_optional orelse return error.InternalFailure;
    switch (command) {
        .help => unreachable,
        .send => |options| try executeSend(context, backend, options),
        .receive => unreachable,
        .check => try executeCheck(context, backend),
    }
}

fn executeSend(
    context: Context,
    backend: QueueInterface,
    options: SendOptions,
) !void {
    const parsed = try operation.parseInputJSON(context.allocator, context.stdin, .{
        .tenant = options.tenant,
        .now = context.now,
    });

    var serialized: std.Io.Writer.Allocating = .init(context.allocator);
    defer serialized.deinit();
    try operation.writeOutputJSON(&serialized.writer, &parsed);
    const message = serialized.written();
    std.debug.assert(parsed.state == .submitted);
    std.debug.assert(message.len > 0);

    try backend.send(context.allocator, message);
    try context.stdout.writeAll(message);
    try context.stdout.writeByte('\n');
}

fn executeReceiveLoop(
    context: Context,
    backend: QueueInterface,
) !noreturn {
    std.debug.assert(receive_loop_is_intentionally_unbounded);
    while (receive_loop_is_intentionally_unbounded) {
        var poll_arena = std.heap.ArenaAllocator.init(context.allocator);
        defer poll_arena.deinit();
        const poll_context = Context{
            .allocator = poll_arena.allocator(),
            .now = context.now,
            .stdin = context.stdin,
            .stdout = context.stdout,
            .stderr = context.stderr,
        };
        try executeReceivePoll(poll_context, backend);
    }
}

fn executeReceivePoll(
    context: Context,
    backend: QueueInterface,
) !void {
    const message = try backend.receive(context.allocator);
    try processReceiveResponse(context, backend, message);
}

fn processReceiveResponse(
    context: Context,
    backend: QueueInterface,
    message_optional: ?sqs_queue.Message,
) !void {
    const message = message_optional orelse return;

    try context.stdout.writeAll(message.body);
    try context.stdout.writeByte('\n');
    try context.stdout.flush();
    try backend.delete(context.allocator, message.receipt_handle);
}

fn executeCheck(
    context: Context,
    backend: QueueInterface,
) !void {
    const attributes = try backend.get_attributes(context.allocator);
    var json: std.json.Stringify = .{
        .writer = context.stdout,
        .options = .{},
    };
    try json.beginObject();
    for (attributes) |attribute| {
        try json.objectField(attribute.key);
        try json.write(attribute.value);
    }
    try json.endObject();
    try context.stdout.writeByte('\n');
}

const test_input =
    "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
    "\"name\":\"echo\",\"body\":{\"message\":\"hello\",\"count\":2}}";
const test_tigerbeetle_queue_name = "TigerBeetleQueue";
const test_completion_queue_name = "CompletionQueue";

const FakeQueue = struct {
    message: ?sqs_queue.Message = null,
    receive_batches: []const ?sqs_queue.Message = &.{},
    attributes: []const sqs_queue.Attribute = &.{},
    send_error: ?anyerror = null,
    receive_error: ?anyerror = null,
    receive_error_after: ?u8 = null,
    delete_error: ?anyerror = null,
    check_error: ?anyerror = null,
    flushed_before_delete: ?*const bool = null,
    allocation_bytes_in_use: ?*const usize = null,
    allocation_size: usize = 0,
    allocation_released_before_poll: bool = true,
    send_count: u8 = 0,
    receive_count: u8 = 0,
    delete_count: u8 = 0,
    check_count: u8 = 0,
    sent_buffer: [stdin_size_max * 2]u8 = undefined,
    sent_size: usize = 0,
    receipt_buffer: [1024]u8 = undefined,
    receipt_size: usize = 0,

    fn send(
        fake: *FakeQueue,
        _: Allocator,
        body: []const u8,
    ) !void {
        fake.send_count += 1;
        if (fake.send_error) |err| return err;
        if (body.len > fake.sent_buffer.len) return error.TestBodyTooLarge;
        @memcpy(fake.sent_buffer[0..body.len], body);
        fake.sent_size = body.len;
    }

    fn receive(
        fake: *FakeQueue,
        allocator: Allocator,
    ) !?sqs_queue.Message {
        fake.receive_count += 1;
        if (fake.allocation_bytes_in_use) |bytes_in_use| {
            if (bytes_in_use.* != 0) fake.allocation_released_before_poll = false;
        }
        if (fake.receive_error_after) |poll_count| {
            if (fake.receive_count == poll_count) return error.TestTerminal;
        }
        if (fake.receive_error) |err| return err;
        if (fake.allocation_size > 0) {
            _ = try allocator.alloc(u8, fake.allocation_size);
        }
        if (fake.receive_count <= fake.receive_batches.len) {
            return fake.receive_batches[fake.receive_count - 1];
        }
        return fake.message;
    }

    fn delete(
        fake: *FakeQueue,
        _: Allocator,
        receipt_handle: []const u8,
    ) !void {
        fake.delete_count += 1;
        if (fake.flushed_before_delete) |flushed| {
            if (!flushed.*) return error.DeleteBeforeFlush;
        }
        if (fake.delete_error) |err| return err;
        if (receipt_handle.len > fake.receipt_buffer.len) return error.TestReceiptTooLarge;
        @memcpy(fake.receipt_buffer[0..receipt_handle.len], receipt_handle);
        fake.receipt_size = receipt_handle.len;
    }

    fn get_attributes(
        fake: *FakeQueue,
        _: Allocator,
    ) ![]const sqs_queue.Attribute {
        fake.check_count += 1;
        if (fake.check_error) |err| return err;
        return fake.attributes;
    }

    fn sent(fake: *const FakeQueue) []const u8 {
        return fake.sent_buffer[0..fake.sent_size];
    }

    fn receipt(fake: *const FakeQueue) []const u8 {
        return fake.receipt_buffer[0..fake.receipt_size];
    }
};

const TestResult = struct {
    exit_code: u8,
    stdout_buffer: [stdin_size_max * 2]u8,
    stderr_buffer: [1024]u8,
    stdout_size: usize,
    stderr_size: usize,

    fn stdout(result: *const TestResult) []const u8 {
        return result.stdout_buffer[0..result.stdout_size];
    }

    fn stderr(result: *const TestResult) []const u8 {
        return result.stderr_buffer[0..result.stderr_size];
    }
};

fn runForTest(
    arguments: []const []const u8,
    stdin: []const u8,
    now: operation.UnixSeconds,
    fake: *FakeQueue,
) TestResult {
    var result: TestResult = undefined;
    var stdout: std.Io.Writer = .fixed(&result.stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&result.stderr_buffer);
    const invocation = parseCommand(arguments) catch {
        writeDiagnostic(&stderr, .invocation);
        return testResultFinish(&result, &stdout, &stderr, 2);
    };
    const command = invocation.command;
    const input = switch (command) {
        .send => stdin,
        .help, .receive, .check => "",
    };
    validateCommandInput(command, input) catch {
        writeDiagnostic(&stderr, .validation);
        return testResultFinish(&result, &stdout, &stderr, 2);
    };
    const backend = if (command == .help) null else QueueInterface.init(fake);
    const code = runCommand(command, .{
        .allocator = std.testing.allocator,
        .now = now,
        .stdin = input,
        .stdout = &stdout,
        .stderr = &stderr,
    }, backend);
    return testResultFinish(&result, &stdout, &stderr, code);
}

fn testResultFinish(
    result: *TestResult,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    code: u8,
) TestResult {
    result.exit_code = code;
    result.stdout_size = stdout.buffered().len;
    result.stderr_size = stderr.buffered().len;
    std.debug.assert(result.stdout_size <= result.stdout_buffer.len);
    std.debug.assert(result.stderr_size <= result.stderr_buffer.len);
    return result.*;
}

test "help works without AWS configuration and command parsing is bounded" {
    var fake: FakeQueue = .{};
    const help_arguments = [_][]const []const u8{
        &.{ "sqs", "--help" },
        &.{ "sqs", "-h" },
        &.{ "sqs", "help" },
        &.{ "sqs", test_tigerbeetle_queue_name, "--help" },
        &.{ "sqs", test_tigerbeetle_queue_name, "send", "--help" },
        &.{ "sqs", test_tigerbeetle_queue_name, "receive", "--help" },
        &.{ "sqs", test_completion_queue_name, "check", "--help" },
    };
    for (help_arguments) |arguments| {
        const result = runForTest(arguments, "", 0, &fake);
        try std.testing.expectEqual(@as(u8, 0), result.exit_code);
        try std.testing.expect(std.mem.startsWith(u8, result.stdout(), "Usage:\n"));
        try std.testing.expect(std.mem.indexOf(u8, result.stdout(), "until interrupted") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout(), "<queue-name>") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout(), "TigerBeetleQueue") == null);
        try std.testing.expectEqualStrings("", result.stderr());
    }

    const invalid_arguments = [_][]const []const u8{
        &.{"sqs"},
        &.{ "sqs", "unknown" },
        &.{ "sqs", test_tigerbeetle_queue_name, "unknown" },
        &.{ "sqs", test_tigerbeetle_queue_name, "receive", "extra" },
        &.{ "sqs", test_tigerbeetle_queue_name, "check", "extra" },
        &.{ "sqs", test_tigerbeetle_queue_name, "send", "--tenant", "tenant", "extra" },
    };
    for (invalid_arguments) |arguments| {
        const result = runForTest(arguments, "", 0, &fake);
        try std.testing.expectEqual(@as(u8, 2), result.exit_code);
        try std.testing.expectEqualStrings(
            "sqs: invalid invocation; use --help\n",
            result.stderr(),
        );
    }
}

test "commands require a valid explicit queue logical resource ID" {
    const queue_names = [_][]const u8{
        test_tigerbeetle_queue_name,
        test_completion_queue_name,
        "A",
        "A" ** sqs_queue.environment_variable_name_size_max,
    };
    for (queue_names) |queue_name| {
        const send = try parseCommand(&.{ "sqs", queue_name, "send", "--tenant", "tenant" });
        try std.testing.expectEqualStrings(queue_name, send.queue_name.?);
        try std.testing.expectEqualStrings("tenant", send.command.send.tenant);

        const receive = try parseCommand(&.{ "sqs", queue_name, "receive" });
        try std.testing.expectEqualStrings(queue_name, receive.queue_name.?);
        try std.testing.expect(receive.command == .receive);

        const check = try parseCommand(&.{ "sqs", queue_name, "check" });
        try std.testing.expectEqualStrings(queue_name, check.queue_name.?);
        try std.testing.expect(check.command == .check);
    }

    const invalid_queue_names = [_][]const u8{
        "",
        "1Queue",
        "Queue-Name",
        "Queue_Name",
        "A" ** (sqs_queue.environment_variable_name_size_max + 1),
    };
    for (invalid_queue_names) |queue_name| {
        try std.testing.expectError(
            error.InvalidInvocation,
            parseCommand(&.{ "sqs", queue_name, "check" }),
        );
    }
}

test "send requires one valid bounded tenant and bounded Operation input" {
    const valid = [_][]const u8{
        "a",
        "a" ** operation.tenant_size_max,
        "é" ** (operation.tenant_size_max / 2),
    };
    for (valid) |tenant| {
        const invocation = try parseCommand(
            &.{ "sqs", test_tigerbeetle_queue_name, "send", "--tenant", tenant },
        );
        try std.testing.expectEqualStrings(tenant, invocation.command.send.tenant);
    }
    const invalid = [_][]const u8{
        "",
        "a" ** (operation.tenant_size_max + 1),
        ("é" ** (operation.tenant_size_max / 2)) ++ "a",
        &.{0xFF},
    };
    for (invalid) |tenant| {
        try std.testing.expectError(
            error.InvalidInvocation,
            parseCommand(
                &.{ "sqs", test_tigerbeetle_queue_name, "send", "--tenant", tenant },
            ),
        );
    }

    var fake: FakeQueue = .{};
    const oversized = "a" ** (stdin_size_max + 1);
    const result = runForTest(
        &.{ "sqs", test_tigerbeetle_queue_name, "send", "--tenant", "tenant-a" },
        oversized,
        0,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 2), result.exit_code);
    try std.testing.expectEqual(@as(u8, 0), fake.send_count);
}

test "send queues and prints the same canonical SUBMITTED Operation" {
    const expected =
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
        "\"tenant\":\"tenant-a\",\"name\":\"echo\"," ++
        "\"body\":{\"message\":\"hello\",\"count\":2}," ++
        "\"state\":\"SUBMITTED\",\"last_updated\":1700000000," ++
        "\"expires_at\":1700086400," ++
        "\"hash\":\"d271e3bd560113d2b82e42dfc46be33" ++
        "fb90b43d7f4b12114f3da4888eae445d4\"}";
    const inputs = [_][]const u8{
        test_input,
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"name\":\"echo\",\"body\":{\"message\":\"hello\",\"count\":2}," ++
            "\"state\":\"SUBMITTED\"}",
    };
    var expected_message: ?[]u8 = null;
    defer if (expected_message) |message| std.testing.allocator.free(message);
    for (inputs) |input| {
        var fake: FakeQueue = .{};
        const result = runForTest(
            &.{ "sqs", test_tigerbeetle_queue_name, "send", "--tenant", "tenant-a" },
            input,
            1_700_000_000,
            &fake,
        );
        try std.testing.expectEqual(@as(u8, 0), result.exit_code);
        try std.testing.expectEqual(@as(u8, 1), fake.send_count);
        try std.testing.expectEqualStrings(fake.sent(), result.stdout()[0..fake.sent_size]);
        try std.testing.expectEqual(@as(u8, '\n'), result.stdout()[fake.sent_size]);
        try std.testing.expectEqual(fake.sent_size + 1, result.stdout().len);
        try std.testing.expectEqualStrings(expected, fake.sent());
        if (expected_message) |message| {
            try std.testing.expectEqualStrings(message, fake.sent());
        } else {
            expected_message = try std.testing.allocator.dupe(u8, fake.sent());
        }
    }
}

test "send validates through Operation and reports AWS failures without output" {
    var fake: FakeQueue = .{};
    const invalid = runForTest(
        &.{ "sqs", test_tigerbeetle_queue_name, "send", "--tenant", "tenant-a" },
        "null",
        0,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 2), invalid.exit_code);
    try std.testing.expectEqualStrings("sqs: invalid operation input\n", invalid.stderr());
    try std.testing.expectEqual(@as(u8, 0), fake.send_count);

    for ([_][]const u8{ "UNKNOWN", "submitted", "completed", "COMPLETED" }) |state| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
                "\"name\":\"echo\",\"body\":true,\"state\":\"{s}\"}}",
            .{state},
        );
        defer std.testing.allocator.free(input);
        const invalid_state = runForTest(
            &.{ "sqs", test_tigerbeetle_queue_name, "send", "--tenant", "tenant-a" },
            input,
            0,
            &fake,
        );
        try std.testing.expectEqual(@as(u8, 2), invalid_state.exit_code);
    }
    try std.testing.expectEqual(@as(u8, 0), fake.send_count);

    fake.send_error = error.AWSFailure;
    const failed = runForTest(
        &.{ "sqs", test_tigerbeetle_queue_name, "send", "--tenant", "tenant-a" },
        test_input,
        1_700_000_000,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 2), failed.exit_code);
    try std.testing.expectEqualStrings("", failed.stdout());
    try std.testing.expectEqualStrings("sqs: AWS request failed\n", failed.stderr());
}

test "receive continues through empty polls and prints and deletes messages in order" {
    const first: sqs_queue.Message = .{
        .body = "first",
        .receipt_handle = "receipt-1",
    };
    const second: sqs_queue.Message = .{
        .body = "second\nline",
        .receipt_handle = "receipt-2",
    };
    const batches = [_]?sqs_queue.Message{ null, first, null, second };
    var fake: FakeQueue = .{
        .receive_batches = &batches,
        .receive_error_after = batches.len + 1,
    };
    const result = runForTest(
        &.{ "sqs", test_tigerbeetle_queue_name, "receive" },
        "",
        0,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 2), result.exit_code);
    try std.testing.expectEqualStrings("first\nsecond\nline\n", result.stdout());
    try std.testing.expectEqualStrings("sqs: operation failed\n", result.stderr());
    try std.testing.expectEqual(@as(u8, batches.len + 1), fake.receive_count);
    try std.testing.expectEqual(@as(u8, 2), fake.delete_count);
    try std.testing.expectEqualStrings("receipt-2", fake.receipt());
}

test "receive releases every poll arena before polling again" {
    const DebugAllocator = std.heap.DebugAllocator(.{
        .enable_memory_limit = true,
        .stack_trace_frames = 0,
    });
    var debug_allocator: DebugAllocator = .{};
    defer std.debug.assert(debug_allocator.deinit() == .ok);

    var fake: FakeQueue = .{
        .receive_error_after = 4,
        .allocation_bytes_in_use = &debug_allocator.total_requested_bytes,
        .allocation_size = 1024,
    };
    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const exit_code = runCommand(.receive, .{
        .allocator = debug_allocator.allocator(),
        .now = 0,
        .stdin = "",
        .stdout = &stdout,
        .stderr = &stderr,
    }, QueueInterface.init(&fake));

    try std.testing.expectEqual(@as(u8, 2), exit_code);
    try std.testing.expectEqual(@as(u8, 4), fake.receive_count);
    try std.testing.expect(fake.allocation_released_before_poll);
    try std.testing.expectEqual(@as(usize, 0), debug_allocator.total_requested_bytes);
}

test "receive writes arbitrary bytes and deletes with the receipt handle" {
    const body = [_]u8{ 'n', 'o', 't', ' ', 'J', 'S', 'O', 'N', '\n', 0x00, 0xFF };
    const message: sqs_queue.Message = .{
        .body = &body,
        .receipt_handle = "receipt-1",
    };
    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    var fake: FakeQueue = .{ .message = message };
    try processReceiveResponse(.{
        .allocator = std.testing.allocator,
        .now = 0,
        .stdin = "",
        .stdout = &stdout,
        .stderr = &stderr,
    }, QueueInterface.init(&fake), message);
    try std.testing.expectEqualSlices(u8, &body, stdout.buffered()[0..body.len]);
    try std.testing.expectEqual(@as(u8, '\n'), stdout.buffered()[body.len]);
    try std.testing.expectEqual(body.len + 1, stdout.buffered().len);
    try std.testing.expectEqualStrings("", stderr.buffered());
    try std.testing.expectEqual(@as(u8, 1), fake.delete_count);
    try std.testing.expectEqualStrings("receipt-1", fake.receipt());
}

const TrackingWriter = struct {
    writer: std.Io.Writer,
    buffer: [1024]u8 = undefined,
    output_size: usize = 0,
    flushed: bool = false,
    fail_flush: bool = false,

    fn init(tracking: *TrackingWriter, fail_flush: bool) void {
        tracking.* = .{
            .writer = .{
                .vtable = &.{
                    .drain = std.Io.Writer.fixedDrain,
                    .flush = flush,
                },
                .buffer = &tracking.buffer,
            },
            .fail_flush = fail_flush,
        };
    }

    fn flush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const tracking: *TrackingWriter = @alignCast(@fieldParentPtr("writer", writer));
        if (tracking.fail_flush) return error.WriteFailed;
        tracking.output_size = writer.end;
        tracking.flushed = true;
        writer.end = 0;
    }

    fn output(tracking: *const TrackingWriter) []const u8 {
        return tracking.buffer[0..tracking.output_size];
    }
};

test "receive flushes output before delete and does not delete after output failure" {
    const message: sqs_queue.Message = .{
        .body = "raw-body",
        .receipt_handle = "receipt-2",
    };
    var stderr_buffer: [1024]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var success_writer: TrackingWriter = undefined;
    success_writer.init(false);
    var success_fake: FakeQueue = .{
        .message = message,
        .flushed_before_delete = &success_writer.flushed,
    };
    try processReceiveResponse(.{
        .allocator = std.testing.allocator,
        .now = 0,
        .stdin = "",
        .stdout = &success_writer.writer,
        .stderr = &stderr,
    }, QueueInterface.init(&success_fake), message);
    try std.testing.expect(success_writer.flushed);
    try std.testing.expectEqualStrings("raw-body\n", success_writer.output());
    try std.testing.expectEqual(@as(u8, 1), success_fake.delete_count);

    var failure_writer: TrackingWriter = undefined;
    failure_writer.init(true);
    var failure_fake: FakeQueue = .{ .message = message };
    const failure_code = runCommand(.receive, .{
        .allocator = std.testing.allocator,
        .now = 0,
        .stdin = "",
        .stdout = &failure_writer.writer,
        .stderr = &stderr,
    }, QueueInterface.init(&failure_fake));
    try std.testing.expectEqual(@as(u8, 2), failure_code);
    try std.testing.expect(!failure_writer.flushed);
    try std.testing.expectEqual(@as(u8, 0), failure_fake.delete_count);
    try std.testing.expectEqual(@as(u8, 1), failure_fake.receive_count);
    try std.testing.expectEqualStrings("sqs: operation failed\n", stderr.buffered());
}

test "receive reports invalid service, AWS, and delete failures" {
    var response_fake: FakeQueue = .{ .receive_error = error.InvalidServiceResponse };
    const response_failed = runForTest(
        &.{ "sqs", test_tigerbeetle_queue_name, "receive" },
        "",
        0,
        &response_fake,
    );
    try std.testing.expectEqual(@as(u8, 2), response_failed.exit_code);
    try std.testing.expectEqualStrings("sqs: invalid AWS response\n", response_failed.stderr());
    try std.testing.expectEqual(@as(u8, 0), response_fake.delete_count);

    var receive_fake: FakeQueue = .{ .receive_error = error.AWSFailure };
    const receive_failed = runForTest(
        &.{ "sqs", test_tigerbeetle_queue_name, "receive" },
        "",
        0,
        &receive_fake,
    );
    try std.testing.expectEqual(@as(u8, 2), receive_failed.exit_code);
    try std.testing.expectEqualStrings("sqs: AWS request failed\n", receive_failed.stderr());
    try std.testing.expectEqual(@as(u8, 1), receive_fake.receive_count);

    const message: sqs_queue.Message = .{
        .body = "already-output",
        .receipt_handle = "receipt",
    };
    var delete_fake: FakeQueue = .{
        .message = message,
        .delete_error = error.AWSFailure,
    };
    const delete_failed = runForTest(
        &.{ "sqs", test_tigerbeetle_queue_name, "receive" },
        "",
        0,
        &delete_fake,
    );
    try std.testing.expectEqual(@as(u8, 2), delete_failed.exit_code);
    try std.testing.expectEqualStrings("already-output\n", delete_failed.stdout());
    try std.testing.expectEqualStrings("sqs: AWS request failed\n", delete_failed.stderr());
    try std.testing.expectEqual(@as(u8, 1), delete_fake.receive_count);
    try std.testing.expectEqual(@as(u8, 1), delete_fake.delete_count);
}

test "check writes every known and unknown attribute as escaped JSON" {
    const attributes = [_]sqs_queue.Attribute{
        .{ .key = "ApproximateNumberOfMessages", .value = "3" },
        .{ .key = "Future\"Attribute", .value = "line\nvalue\\suffix" },
    };
    var fake: FakeQueue = .{ .attributes = &attributes };
    const result = runForTest(
        &.{ "sqs", test_tigerbeetle_queue_name, "check" },
        "",
        0,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings(
        "{\"ApproximateNumberOfMessages\":\"3\"," ++
            "\"Future\\\"Attribute\":\"line\\nvalue\\\\suffix\"}\n",
        result.stdout(),
    );
    try std.testing.expectEqualStrings("", result.stderr());
    try std.testing.expectEqual(@as(u8, 1), fake.check_count);

    fake.attributes = &.{};
    const empty = runForTest(
        &.{ "sqs", test_completion_queue_name, "check" },
        "",
        0,
        &fake,
    );
    try std.testing.expectEqualStrings("{}\n", empty.stdout());
}

test "AWS and internal diagnostics do not echo message data" {
    const body_marker = "private-message-marker";
    const message: sqs_queue.Message = .{
        .body = body_marker,
        .receipt_handle = "private-receipt-marker",
    };
    var fake: FakeQueue = .{
        .message = message,
        .delete_error = error.UnexpectedPrivateFailure,
    };
    const result = runForTest(
        &.{ "sqs", test_tigerbeetle_queue_name, "receive" },
        "",
        0,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 2), result.exit_code);
    try std.testing.expectEqualStrings("sqs: operation failed\n", result.stderr());
    try std.testing.expect(std.mem.indexOf(u8, result.stderr(), body_marker) == null);
    try std.testing.expect(
        std.mem.indexOf(u8, result.stderr(), message.receipt_handle) == null,
    );
}
