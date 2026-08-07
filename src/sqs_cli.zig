const std = @import("std");
const aws = @import("aws");
const operation = @import("operation");
const sqs = @import("sqs");

const Allocator = std.mem.Allocator;

const argument_count_max = 4;
const stdin_size_max = 8 * 1024;
const queue_url_size_max = 2048;
const message_size_max = 1024 * 1024;
const receipt_handle_size_max = 64 * 1024;
const attribute_count_max = 64;
const attribute_name_size_max = 256;
const attribute_value_size_max = 256 * 1024;
const io_buffer_size = 4096;

comptime {
    std.debug.assert(stdin_size_max > operation.body_size_max);
    std.debug.assert(argument_count_max < stdin_size_max);
    std.debug.assert(queue_url_size_max < message_size_max);
    std.debug.assert(attribute_count_max > 1);
}

const Command = union(enum) {
    help,
    send: SendOptions,
    receive,
    check,
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
    \\  sqs send --tenant <tenant>
    \\  sqs receive
    \\  sqs check
    \\
    \\Commands:
    \\  send     Read an Operation from stdin and enqueue it as SUBMITTED
    \\  receive  Print and delete at most one immediately available message
    \\  check    Print all queue attributes as JSON
    \\
    \\Environment:
    \\  OPERATIONS_QUEUE_URL  URL of the SQS operations queue
    \\  AWS_*                 Standard AWS credentials, region, profile, and endpoint
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
    const command = parseCommand(arguments) catch {
        return finish(&stdout_file.interface, &stderr_file.interface, 2, .invocation);
    };
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
        const code = runCommand(command, context, null, null);
        return finish(context.stdout, context.stderr, code, null);
    }
    const queue_url = configuredQueueURL(init.environ_map) catch {
        return finish(context.stdout, context.stderr, 2, .configuration);
    };

    var config = aws.Config.load(init.gpa, init.io, init.environ_map, .{}) catch {
        return finish(context.stdout, context.stderr, 2, .configuration);
    };
    defer config.deinit();
    var client = sqs.Client.init(init.gpa, &config);
    defer client.deinit();
    var sdk_queue = SDKQueue{ .client = &client };
    const backend = SQSInterface.init(&sdk_queue);
    const code = runCommand(command, context, queue_url, backend);
    return finish(context.stdout, context.stderr, code, null);
}

const Failure = enum {
    invocation,
    validation,
    configuration,
    empty,
    aws,
    response,
    internal,

    fn code(failure: Failure) u8 {
        return switch (failure) {
            .empty => 1,
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
        .empty => "sqs: queue is empty\n",
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

fn configuredQueueURL(environment: *const std.process.Environ.Map) ![]const u8 {
    const queue_url = environment.get("OPERATIONS_QUEUE_URL") orelse {
        return error.InvalidConfiguration;
    };
    if (queue_url.len == 0) return error.InvalidConfiguration;
    if (queue_url.len > queue_url_size_max) return error.InvalidConfiguration;
    std.debug.assert(queue_url.len > 0);
    std.debug.assert(queue_url.len <= queue_url_size_max);
    return queue_url;
}

fn parseCommand(arguments: []const []const u8) CliError!Command {
    if (arguments.len < 2) return error.InvalidInvocation;
    if (arguments.len > argument_count_max) return error.InvalidInvocation;

    const name = arguments[1];
    if (isHelp(name)) {
        if (arguments.len != 2) return error.InvalidInvocation;
        return .help;
    }
    if (std.mem.eql(u8, name, "send")) return parseSend(arguments[2..]);
    if (std.mem.eql(u8, name, "receive")) return parseNoOptions(arguments[2..], .receive);
    if (std.mem.eql(u8, name, "check")) return parseNoOptions(arguments[2..], .check);
    return error.InvalidInvocation;
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

const SQSInterface = struct {
    context: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        send_message: *const fn (
            *anyopaque,
            Allocator,
            []const u8,
            []const u8,
        ) anyerror!void,
        receive_message: *const fn (
            *anyopaque,
            Allocator,
            []const u8,
        ) anyerror![]const sqs.types.Message,
        delete_message: *const fn (
            *anyopaque,
            Allocator,
            []const u8,
            []const u8,
        ) anyerror!void,
        get_attributes: *const fn (
            *anyopaque,
            Allocator,
            []const u8,
        ) anyerror![]const aws.map.StringMapEntry,
    };

    fn init(pointer: anytype) SQSInterface {
        const Pointer = @TypeOf(pointer);
        const pointer_info = @typeInfo(Pointer);
        comptime std.debug.assert(pointer_info == .pointer);
        comptime std.debug.assert(pointer_info.pointer.size == .one);

        const Adapter = struct {
            fn sendMessage(
                context: *anyopaque,
                allocator: Allocator,
                queue_url: []const u8,
                body: []const u8,
            ) anyerror!void {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.sendMessage(allocator, queue_url, body);
            }

            fn receiveMessage(
                context: *anyopaque,
                allocator: Allocator,
                queue_url: []const u8,
            ) anyerror![]const sqs.types.Message {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.receiveMessage(allocator, queue_url);
            }

            fn deleteMessage(
                context: *anyopaque,
                allocator: Allocator,
                queue_url: []const u8,
                receipt_handle: []const u8,
            ) anyerror!void {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.deleteMessage(allocator, queue_url, receipt_handle);
            }

            fn getAttributes(
                context: *anyopaque,
                allocator: Allocator,
                queue_url: []const u8,
            ) anyerror![]const aws.map.StringMapEntry {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.getAttributes(allocator, queue_url);
            }
        };
        return .{
            .context = pointer,
            .vtable = &.{
                .send_message = Adapter.sendMessage,
                .receive_message = Adapter.receiveMessage,
                .delete_message = Adapter.deleteMessage,
                .get_attributes = Adapter.getAttributes,
            },
        };
    }

    fn sendMessage(
        self: SQSInterface,
        allocator: Allocator,
        queue_url: []const u8,
        body: []const u8,
    ) !void {
        return self.vtable.send_message(self.context, allocator, queue_url, body);
    }

    fn receiveMessage(
        self: SQSInterface,
        allocator: Allocator,
        queue_url: []const u8,
    ) ![]const sqs.types.Message {
        return self.vtable.receive_message(self.context, allocator, queue_url);
    }

    fn deleteMessage(
        self: SQSInterface,
        allocator: Allocator,
        queue_url: []const u8,
        receipt_handle: []const u8,
    ) !void {
        return self.vtable.delete_message(
            self.context,
            allocator,
            queue_url,
            receipt_handle,
        );
    }

    fn getAttributes(
        self: SQSInterface,
        allocator: Allocator,
        queue_url: []const u8,
    ) ![]const aws.map.StringMapEntry {
        return self.vtable.get_attributes(self.context, allocator, queue_url);
    }
};

const SDKQueue = struct {
    client: *sqs.Client,

    fn sendMessage(
        self: *SDKQueue,
        allocator: Allocator,
        queue_url: []const u8,
        body: []const u8,
    ) !void {
        _ = self.client.sendMessage(allocator, .{
            .message_body = body,
            .queue_url = queue_url,
        }, .{}) catch |err| return mapAWSError(err);
    }

    fn receiveMessage(
        self: *SDKQueue,
        allocator: Allocator,
        queue_url: []const u8,
    ) ![]const sqs.types.Message {
        const output = self.client.receiveMessage(allocator, .{
            .max_number_of_messages = 1,
            .queue_url = queue_url,
            .wait_time_seconds = 0,
        }, .{}) catch |err| return mapAWSError(err);
        return output.messages orelse &.{};
    }

    fn deleteMessage(
        self: *SDKQueue,
        allocator: Allocator,
        queue_url: []const u8,
        receipt_handle: []const u8,
    ) !void {
        _ = self.client.deleteMessage(allocator, .{
            .queue_url = queue_url,
            .receipt_handle = receipt_handle,
        }, .{}) catch |err| return mapAWSError(err);
    }

    fn getAttributes(
        self: *SDKQueue,
        allocator: Allocator,
        queue_url: []const u8,
    ) ![]const aws.map.StringMapEntry {
        const all = [_]sqs.types.QueueAttributeName{.all};
        const output = self.client.getQueueAttributes(allocator, .{
            .attribute_names = &all,
            .queue_url = queue_url,
        }, .{}) catch |err| return mapAWSError(err);
        return output.attributes orelse &.{};
    }
};

fn mapAWSError(err: anyerror) error{ OutOfMemory, AWSFailure } {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return error.AWSFailure;
}

fn runCommand(
    command: Command,
    context: Context,
    queue_url: ?[]const u8,
    backend: ?SQSInterface,
) u8 {
    var arena = std.heap.ArenaAllocator.init(context.allocator);
    defer arena.deinit();
    const command_context = Context{
        .allocator = arena.allocator(),
        .now = context.now,
        .stdin = context.stdin,
        .stdout = context.stdout,
        .stderr = context.stderr,
    };
    executeCommand(command, command_context, queue_url, backend) catch |err| {
        const failure = classifyError(err);
        writeDiagnostic(context.stderr, failure);
        return failure.code();
    };
    return 0;
}

fn classifyError(err: anyerror) Failure {
    return switch (err) {
        error.InvalidInvocation => .invocation,
        error.QueueEmpty => .empty,
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
        error.MessageTooLarge,
        => .validation,
        else => .internal,
    };
}

fn executeCommand(
    command: Command,
    context: Context,
    queue_url_optional: ?[]const u8,
    backend_optional: ?SQSInterface,
) !void {
    if (command == .help) {
        try context.stdout.writeAll(usage);
        return;
    }
    const queue_url = queue_url_optional orelse return error.InternalFailure;
    const backend = backend_optional orelse return error.InternalFailure;
    switch (command) {
        .help => unreachable,
        .send => |options| try executeSend(context, backend, queue_url, options),
        .receive => try executeReceive(context, backend, queue_url),
        .check => try executeCheck(context, backend, queue_url),
    }
}

fn executeSend(
    context: Context,
    backend: SQSInterface,
    queue_url: []const u8,
    options: SendOptions,
) !void {
    var parsed = try operation.parseInputJSON(context.allocator, context.stdin, .{
        .tenant = options.tenant,
        .now = context.now,
    });
    parsed.state = .submitted;

    var serialized: std.Io.Writer.Allocating = .init(context.allocator);
    defer serialized.deinit();
    try operation.writeOutputJSON(&serialized.writer, &parsed);
    const message = serialized.written();
    if (message.len == 0) return error.MessageTooLarge;
    if (message.len > message_size_max) return error.MessageTooLarge;
    std.debug.assert(parsed.state == .submitted);
    std.debug.assert(message.len > 0);

    try backend.sendMessage(context.allocator, queue_url, message);
    try context.stdout.writeAll(message);
    try context.stdout.writeByte('\n');
}

fn executeReceive(
    context: Context,
    backend: SQSInterface,
    queue_url: []const u8,
) !void {
    const messages = try backend.receiveMessage(context.allocator, queue_url);
    if (messages.len == 0) return error.QueueEmpty;
    if (messages.len != 1) return error.InvalidServiceResponse;
    const body = messages[0].body orelse return error.InvalidServiceResponse;
    const receipt_handle = messages[0].receipt_handle orelse {
        return error.InvalidServiceResponse;
    };
    if (body.len > message_size_max) return error.InvalidServiceResponse;
    if (receipt_handle.len > receipt_handle_size_max) return error.InvalidServiceResponse;
    std.debug.assert(messages.len == 1);
    std.debug.assert(body.len <= message_size_max);
    std.debug.assert(receipt_handle.len <= receipt_handle_size_max);

    try context.stdout.writeAll(body);
    try context.stdout.flush();
    try backend.deleteMessage(context.allocator, queue_url, receipt_handle);
}

fn executeCheck(
    context: Context,
    backend: SQSInterface,
    queue_url: []const u8,
) !void {
    const attributes = try backend.getAttributes(context.allocator, queue_url);
    try validateAttributes(attributes);
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

fn validateAttributes(attributes: []const aws.map.StringMapEntry) !void {
    if (attributes.len > attribute_count_max) return error.InvalidServiceResponse;
    for (attributes) |attribute| {
        if (attribute.key.len == 0) return error.InvalidServiceResponse;
        if (attribute.key.len > attribute_name_size_max) return error.InvalidServiceResponse;
        if (attribute.value.len > attribute_value_size_max) {
            return error.InvalidServiceResponse;
        }
        if (!std.unicode.utf8ValidateSlice(attribute.key)) return error.InvalidServiceResponse;
        if (!std.unicode.utf8ValidateSlice(attribute.value)) return error.InvalidServiceResponse;
    }
    std.debug.assert(attributes.len <= attribute_count_max);
}

const test_queue_url = "https://sqs.example.invalid/operations";
const test_input =
    "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
    "\"name\":\"echo\",\"body\":{\"message\":\"hello\",\"count\":2}}";

const FakeSQS = struct {
    messages: []const sqs.types.Message = &.{},
    attributes: []const aws.map.StringMapEntry = &.{},
    send_error: ?anyerror = null,
    receive_error: ?anyerror = null,
    delete_error: ?anyerror = null,
    check_error: ?anyerror = null,
    flushed_before_delete: ?*const bool = null,
    send_count: u8 = 0,
    receive_count: u8 = 0,
    delete_count: u8 = 0,
    check_count: u8 = 0,
    sent_buffer: [stdin_size_max * 2]u8 = undefined,
    sent_size: usize = 0,
    receipt_buffer: [1024]u8 = undefined,
    receipt_size: usize = 0,

    fn sendMessage(
        fake: *FakeSQS,
        _: Allocator,
        queue_url: []const u8,
        body: []const u8,
    ) !void {
        fake.send_count += 1;
        if (!std.mem.eql(u8, queue_url, test_queue_url)) return error.WrongQueue;
        if (fake.send_error) |err| return err;
        if (body.len > fake.sent_buffer.len) return error.TestBodyTooLarge;
        @memcpy(fake.sent_buffer[0..body.len], body);
        fake.sent_size = body.len;
    }

    fn receiveMessage(
        fake: *FakeSQS,
        _: Allocator,
        queue_url: []const u8,
    ) ![]const sqs.types.Message {
        fake.receive_count += 1;
        if (!std.mem.eql(u8, queue_url, test_queue_url)) return error.WrongQueue;
        if (fake.receive_error) |err| return err;
        return fake.messages;
    }

    fn deleteMessage(
        fake: *FakeSQS,
        _: Allocator,
        queue_url: []const u8,
        receipt_handle: []const u8,
    ) !void {
        fake.delete_count += 1;
        if (!std.mem.eql(u8, queue_url, test_queue_url)) return error.WrongQueue;
        if (fake.flushed_before_delete) |flushed| {
            if (!flushed.*) return error.DeleteBeforeFlush;
        }
        if (fake.delete_error) |err| return err;
        if (receipt_handle.len > fake.receipt_buffer.len) return error.TestReceiptTooLarge;
        @memcpy(fake.receipt_buffer[0..receipt_handle.len], receipt_handle);
        fake.receipt_size = receipt_handle.len;
    }

    fn getAttributes(
        fake: *FakeSQS,
        _: Allocator,
        queue_url: []const u8,
    ) ![]const aws.map.StringMapEntry {
        fake.check_count += 1;
        if (!std.mem.eql(u8, queue_url, test_queue_url)) return error.WrongQueue;
        if (fake.check_error) |err| return err;
        return fake.attributes;
    }

    fn sent(fake: *const FakeSQS) []const u8 {
        return fake.sent_buffer[0..fake.sent_size];
    }

    fn receipt(fake: *const FakeSQS) []const u8 {
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
    environment: *const std.process.Environ.Map,
    now: operation.UnixSeconds,
    fake: *FakeSQS,
) TestResult {
    var result: TestResult = undefined;
    var stdout: std.Io.Writer = .fixed(&result.stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&result.stderr_buffer);
    const command = parseCommand(arguments) catch {
        writeDiagnostic(&stderr, .invocation);
        return testResultFinish(&result, &stdout, &stderr, 2);
    };
    const input = switch (command) {
        .send => stdin,
        .help, .receive, .check => "",
    };
    validateCommandInput(command, input) catch {
        writeDiagnostic(&stderr, .validation);
        return testResultFinish(&result, &stdout, &stderr, 2);
    };
    const queue_url = if (command == .help) null else configuredQueueURL(environment) catch {
        writeDiagnostic(&stderr, .configuration);
        return testResultFinish(&result, &stdout, &stderr, 2);
    };
    const backend = if (command == .help) null else SQSInterface.init(fake);
    const code = runCommand(command, .{
        .allocator = std.testing.allocator,
        .now = now,
        .stdin = input,
        .stdout = &stdout,
        .stderr = &stderr,
    }, queue_url, backend);
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

fn testEnvironment() !std.process.Environ.Map {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    errdefer environment.deinit();
    try environment.put("OPERATIONS_QUEUE_URL", test_queue_url);
    std.debug.assert(environment.get("OPERATIONS_QUEUE_URL") != null);
    return environment;
}

test "help works without AWS configuration and command parsing is bounded" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var fake: FakeSQS = .{};
    const help_arguments = [_][]const []const u8{
        &.{ "sqs", "--help" },
        &.{ "sqs", "-h" },
        &.{ "sqs", "help" },
        &.{ "sqs", "send", "--help" },
        &.{ "sqs", "receive", "--help" },
        &.{ "sqs", "check", "--help" },
    };
    for (help_arguments) |arguments| {
        const result = runForTest(arguments, "", &environment, 0, &fake);
        try std.testing.expectEqual(@as(u8, 0), result.exit_code);
        try std.testing.expect(std.mem.startsWith(u8, result.stdout(), "Usage:\n"));
        try std.testing.expectEqualStrings("", result.stderr());
    }

    const invalid_arguments = [_][]const []const u8{
        &.{"sqs"},
        &.{ "sqs", "unknown" },
        &.{ "sqs", "receive", "extra" },
        &.{ "sqs", "check", "extra" },
        &.{ "sqs", "send", "--tenant", "tenant", "extra" },
    };
    for (invalid_arguments) |arguments| {
        const result = runForTest(arguments, "", &environment, 0, &fake);
        try std.testing.expectEqual(@as(u8, 2), result.exit_code);
        try std.testing.expectEqualStrings(
            "sqs: invalid invocation; use --help\n",
            result.stderr(),
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
        const command = try parseCommand(&.{ "sqs", "send", "--tenant", tenant });
        try std.testing.expectEqualStrings(tenant, command.send.tenant);
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
            parseCommand(&.{ "sqs", "send", "--tenant", tenant }),
        );
    }

    var environment = try testEnvironment();
    defer environment.deinit();
    var fake: FakeSQS = .{};
    const oversized = "a" ** (stdin_size_max + 1);
    const result = runForTest(
        &.{ "sqs", "send", "--tenant", "tenant-a" },
        oversized,
        &environment,
        0,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 2), result.exit_code);
    try std.testing.expectEqual(@as(u8, 0), fake.send_count);
}

test "configuration is required and the queue URL is bounded" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var fake: FakeSQS = .{};
    const arguments = &.{ "sqs", "receive" };
    const missing = runForTest(arguments, "", &environment, 0, &fake);
    try std.testing.expectEqual(@as(u8, 2), missing.exit_code);
    try std.testing.expectEqualStrings(
        "sqs: missing or invalid configuration\n",
        missing.stderr(),
    );
    try std.testing.expectEqual(@as(u8, 0), fake.receive_count);

    try environment.put("OPERATIONS_QUEUE_URL", "");
    const empty = runForTest(arguments, "", &environment, 0, &fake);
    try std.testing.expectEqual(@as(u8, 2), empty.exit_code);
    try environment.put("OPERATIONS_QUEUE_URL", "a" ** (queue_url_size_max + 1));
    const large = runForTest(arguments, "", &environment, 0, &fake);
    try std.testing.expectEqual(@as(u8, 2), large.exit_code);
    try std.testing.expectEqual(@as(u8, 0), fake.receive_count);
}

test "send queues and prints the same canonical SUBMITTED Operation" {
    var environment = try testEnvironment();
    defer environment.deinit();
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
            "\"state\":\"NEW\"}",
    };
    var expected_message: ?[]u8 = null;
    defer if (expected_message) |message| std.testing.allocator.free(message);
    for (inputs) |input| {
        var fake: FakeSQS = .{};
        const result = runForTest(
            &.{ "sqs", "send", "--tenant", "tenant-a" },
            input,
            &environment,
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
    var environment = try testEnvironment();
    defer environment.deinit();
    var fake: FakeSQS = .{};
    const invalid = runForTest(
        &.{ "sqs", "send", "--tenant", "tenant-a" },
        "null",
        &environment,
        0,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 2), invalid.exit_code);
    try std.testing.expectEqualStrings("sqs: invalid operation input\n", invalid.stderr());
    try std.testing.expectEqual(@as(u8, 0), fake.send_count);

    fake.send_error = error.AWSFailure;
    const failed = runForTest(
        &.{ "sqs", "send", "--tenant", "tenant-a" },
        test_input,
        &environment,
        1_700_000_000,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 2), failed.exit_code);
    try std.testing.expectEqualStrings("", failed.stdout());
    try std.testing.expectEqualStrings("sqs: AWS request failed\n", failed.stderr());
}

test "receive reports an empty queue with exit code one" {
    var environment = try testEnvironment();
    defer environment.deinit();
    var fake: FakeSQS = .{};
    const result = runForTest(&.{ "sqs", "receive" }, "", &environment, 0, &fake);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("", result.stdout());
    try std.testing.expectEqualStrings("sqs: queue is empty\n", result.stderr());
    try std.testing.expectEqual(@as(u8, 1), fake.receive_count);
    try std.testing.expectEqual(@as(u8, 0), fake.delete_count);
}

test "receive writes arbitrary bytes and deletes with the receipt handle" {
    var environment = try testEnvironment();
    defer environment.deinit();
    const body = "not JSON\nwith bytes: \\x00 is text";
    const messages = [_]sqs.types.Message{.{
        .body = body,
        .receipt_handle = "receipt-1",
    }};
    var fake: FakeSQS = .{ .messages = &messages };
    const result = runForTest(&.{ "sqs", "receive" }, "", &environment, 0, &fake);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings(body, result.stdout());
    try std.testing.expectEqualStrings("", result.stderr());
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
    const messages = [_]sqs.types.Message{.{
        .body = "raw-body",
        .receipt_handle = "receipt-2",
    }};
    var stderr_buffer: [1024]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var success_writer: TrackingWriter = undefined;
    success_writer.init(false);
    var success_fake: FakeSQS = .{
        .messages = &messages,
        .flushed_before_delete = &success_writer.flushed,
    };
    const success_code = runCommand(.receive, .{
        .allocator = std.testing.allocator,
        .now = 0,
        .stdin = "",
        .stdout = &success_writer.writer,
        .stderr = &stderr,
    }, test_queue_url, SQSInterface.init(&success_fake));
    try std.testing.expectEqual(@as(u8, 0), success_code);
    try std.testing.expect(success_writer.flushed);
    try std.testing.expectEqualStrings("raw-body", success_writer.output());
    try std.testing.expectEqual(@as(u8, 1), success_fake.delete_count);

    var failure_writer: TrackingWriter = undefined;
    failure_writer.init(true);
    var failure_fake: FakeSQS = .{ .messages = &messages };
    const failure_code = runCommand(.receive, .{
        .allocator = std.testing.allocator,
        .now = 0,
        .stdin = "",
        .stdout = &failure_writer.writer,
        .stderr = &stderr,
    }, test_queue_url, SQSInterface.init(&failure_fake));
    try std.testing.expectEqual(@as(u8, 2), failure_code);
    try std.testing.expect(!failure_writer.flushed);
    try std.testing.expectEqual(@as(u8, 0), failure_fake.delete_count);
}

test "receive rejects invalid responses and reports receive and delete failures" {
    var environment = try testEnvironment();
    defer environment.deinit();
    const invalid_messages = [_][]const sqs.types.Message{
        &.{.{ .receipt_handle = "receipt" }},
        &.{.{ .body = "body" }},
        &.{ .{ .body = "one", .receipt_handle = "1" }, .{
            .body = "two",
            .receipt_handle = "2",
        } },
    };
    for (invalid_messages) |messages| {
        var fake: FakeSQS = .{ .messages = messages };
        const result = runForTest(&.{ "sqs", "receive" }, "", &environment, 0, &fake);
        try std.testing.expectEqual(@as(u8, 2), result.exit_code);
        try std.testing.expectEqualStrings("sqs: invalid AWS response\n", result.stderr());
        try std.testing.expectEqual(@as(u8, 0), fake.delete_count);
    }

    var receive_fake: FakeSQS = .{ .receive_error = error.AWSFailure };
    const receive_failed = runForTest(
        &.{ "sqs", "receive" },
        "",
        &environment,
        0,
        &receive_fake,
    );
    try std.testing.expectEqual(@as(u8, 2), receive_failed.exit_code);
    try std.testing.expectEqualStrings("sqs: AWS request failed\n", receive_failed.stderr());

    const message = [_]sqs.types.Message{.{
        .body = "already-output",
        .receipt_handle = "receipt",
    }};
    var delete_fake: FakeSQS = .{
        .messages = &message,
        .delete_error = error.AWSFailure,
    };
    const delete_failed = runForTest(
        &.{ "sqs", "receive" },
        "",
        &environment,
        0,
        &delete_fake,
    );
    try std.testing.expectEqual(@as(u8, 2), delete_failed.exit_code);
    try std.testing.expectEqualStrings("already-output", delete_failed.stdout());
    try std.testing.expectEqualStrings("sqs: AWS request failed\n", delete_failed.stderr());
}

test "check writes every known and unknown attribute as escaped JSON" {
    var environment = try testEnvironment();
    defer environment.deinit();
    const attributes = [_]aws.map.StringMapEntry{
        .{ .key = "ApproximateNumberOfMessages", .value = "3" },
        .{ .key = "Future\"Attribute", .value = "line\nvalue\\suffix" },
    };
    var fake: FakeSQS = .{ .attributes = &attributes };
    const result = runForTest(&.{ "sqs", "check" }, "", &environment, 0, &fake);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings(
        "{\"ApproximateNumberOfMessages\":\"3\"," ++
            "\"Future\\\"Attribute\":\"line\\nvalue\\\\suffix\"}\n",
        result.stdout(),
    );
    try std.testing.expectEqualStrings("", result.stderr());
    try std.testing.expectEqual(@as(u8, 1), fake.check_count);

    fake.attributes = &.{};
    const empty = runForTest(&.{ "sqs", "check" }, "", &environment, 0, &fake);
    try std.testing.expectEqualStrings("{}\n", empty.stdout());
}

test "check bounds and validates all returned attribute strings" {
    const entry: aws.map.StringMapEntry = .{ .key = "key", .value = "value" };
    const too_many = [_]aws.map.StringMapEntry{entry} ** (attribute_count_max + 1);
    try std.testing.expectError(
        error.InvalidServiceResponse,
        validateAttributes(&too_many),
    );
    try std.testing.expectError(
        error.InvalidServiceResponse,
        validateAttributes(&.{.{ .key = "", .value = "value" }}),
    );
    try std.testing.expectError(
        error.InvalidServiceResponse,
        validateAttributes(&.{.{
            .key = "k" ** (attribute_name_size_max + 1),
            .value = "value",
        }}),
    );
    try std.testing.expectError(
        error.InvalidServiceResponse,
        validateAttributes(&.{.{
            .key = "key",
            .value = "v" ** (attribute_value_size_max + 1),
        }}),
    );
    try std.testing.expectError(
        error.InvalidServiceResponse,
        validateAttributes(&.{.{ .key = &.{0xFF}, .value = "value" }}),
    );
    try std.testing.expectError(
        error.InvalidServiceResponse,
        validateAttributes(&.{.{ .key = "key", .value = &.{0xFF} }}),
    );
}

test "AWS and internal diagnostics do not echo queue or message data" {
    var environment = try testEnvironment();
    defer environment.deinit();
    const body_marker = "private-message-marker";
    const messages = [_]sqs.types.Message{.{
        .body = body_marker,
        .receipt_handle = "private-receipt-marker",
    }};
    var fake: FakeSQS = .{
        .messages = &messages,
        .delete_error = error.UnexpectedPrivateFailure,
    };
    const result = runForTest(&.{ "sqs", "receive" }, "", &environment, 0, &fake);
    try std.testing.expectEqual(@as(u8, 2), result.exit_code);
    try std.testing.expectEqualStrings("sqs: operation failed\n", result.stderr());
    try std.testing.expect(std.mem.indexOf(u8, result.stderr(), test_queue_url) == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr(), body_marker) == null);
}
