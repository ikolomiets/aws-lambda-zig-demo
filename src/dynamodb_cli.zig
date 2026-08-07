const std = @import("std");
const aws = @import("aws");
const dynamodb = @import("dynamodb");
const operation = @import("operation");
const operation_persistence = @import("operation_persistence");

const Allocator = std.mem.Allocator;

const argument_count_max = 8;
const stdin_size_max = 8 * 1024;
const table_name_size_max = 255;

comptime {
    std.debug.assert(stdin_size_max > operation.body_size_max);
    std.debug.assert(stdin_size_max > operation.result_size_max);
    std.debug.assert(argument_count_max < stdin_size_max);
}

const Command = union(enum) {
    help,
    create: CreateOptions,
    read: u128,
    update: UpdateOptions,
};

const CreateOptions = struct {
    tenant: []const u8,
};

const UpdateOptions = struct {
    id: u128,
    state: operation.State,
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
    \\  dynamodb create --tenant <tenant>
    \\  dynamodb read --id <uuid>
    \\  dynamodb update --id <uuid> --state <state>
    \\
    \\States:
    \\  NEW | SUBMITTED | RUNNING | SUCCEEDED | FAILED
    \\
    \\Environment:
    \\  OPERATIONS_TABLE_NAME  DynamoDB table containing Operations
    \\  AWS_*                  Standard AWS credentials, region, profile, and endpoint
    \\
;

pub fn main(init: std.process.Init) u8 {
    var stdout_buffer: [stdin_size_max]u8 = undefined;
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
        const code = runCommand(command, context, null);
        return finish(context.stdout, context.stderr, code, null);
    }
    const table_name = configuredTableName(init.environ_map) catch {
        return finish(context.stdout, context.stderr, 2, .configuration);
    };

    var config = aws.Config.load(init.gpa, init.io, init.environ_map, .{}) catch {
        return finish(context.stdout, context.stderr, 2, .configuration);
    };
    defer config.deinit();
    var client = dynamodb.Client.init(init.gpa, &config);
    defer client.deinit();
    var persistence = operation_persistence.Persistence.init(&client, table_name) catch {
        return finish(context.stdout, context.stderr, 2, .configuration);
    };
    const backend = PersistenceInterface.init(&persistence);
    const code = runCommand(command, context, backend);
    return finish(context.stdout, context.stderr, code, null);
}

const Failure = enum {
    invocation,
    validation,
    configuration,
    missing,
    conflict,
    aws,
    internal,

    fn code(failure: Failure) u8 {
        return switch (failure) {
            .missing, .conflict => 1,
            .invocation, .validation, .configuration, .aws, .internal => 2,
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
        .invocation => "dynamodb: invalid invocation; use --help\n",
        .validation => "dynamodb: invalid operation input\n",
        .configuration => "dynamodb: missing or invalid configuration\n",
        .missing => "dynamodb: operation not found\n",
        .conflict => "dynamodb: operation conflict\n",
        .aws => "dynamodb: AWS request failed\n",
        .internal => "dynamodb: operation failed\n",
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
        .create, .update => {},
        .help, .read => return "",
    }

    var reader_buffer: [4096]u8 = undefined;
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
        .create => {},
        .update => |options| {
            if (operation.stateIsTerminal(options.state)) {
                if (input.len > operation.result_size_max) return error.InputTooLarge;
            } else {
                if (input.len != 0) return error.UnexpectedInput;
            }
        },
        .help, .read => std.debug.assert(input.len == 0),
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

fn configuredTableName(environment: *const std.process.Environ.Map) ![]const u8 {
    const table_name = environment.get("OPERATIONS_TABLE_NAME") orelse {
        return error.InvalidConfiguration;
    };
    if (table_name.len == 0) return error.InvalidConfiguration;
    if (table_name.len > table_name_size_max) return error.InvalidConfiguration;
    std.debug.assert(table_name.len > 0);
    std.debug.assert(table_name.len <= table_name_size_max);
    return table_name;
}

fn parseCommand(arguments: []const []const u8) CliError!Command {
    if (arguments.len < 2) return error.InvalidInvocation;
    if (arguments.len > argument_count_max) return error.InvalidInvocation;

    const name = arguments[1];
    if (isHelp(name)) {
        if (arguments.len != 2) return error.InvalidInvocation;
        return .help;
    }
    if (std.mem.eql(u8, name, "create")) return parseCreate(arguments[2..]);
    if (std.mem.eql(u8, name, "read")) return parseRead(arguments[2..]);
    if (std.mem.eql(u8, name, "update")) return parseUpdate(arguments[2..]);
    return error.InvalidInvocation;
}

fn parseCreate(arguments: []const []const u8) CliError!Command {
    if (arguments.len == 1) {
        if (isHelp(arguments[0])) return .help;
    }
    if (arguments.len != 2) return error.InvalidInvocation;
    if (!std.mem.eql(u8, arguments[0], "--tenant")) return error.InvalidInvocation;
    operation.validateTenant(arguments[1]) catch return error.InvalidInvocation;
    return .{ .create = .{ .tenant = arguments[1] } };
}

fn parseRead(arguments: []const []const u8) CliError!Command {
    if (arguments.len == 1) {
        if (isHelp(arguments[0])) return .help;
    }
    if (arguments.len != 2) return error.InvalidInvocation;
    if (!std.mem.eql(u8, arguments[0], "--id")) return error.InvalidInvocation;
    const id = operation.uuidFromString(arguments[1]) catch return error.InvalidInvocation;
    return .{ .read = id };
}

fn parseUpdate(arguments: []const []const u8) CliError!Command {
    if (arguments.len == 1) {
        if (isHelp(arguments[0])) return .help;
    }
    if (arguments.len != 4) return error.InvalidInvocation;

    var id: ?u128 = null;
    var state: ?operation.State = null;
    var index: usize = 0;
    while (index < arguments.len) : (index += 2) {
        const option = arguments[index];
        const value = arguments[index + 1];
        if (std.mem.eql(u8, option, "--id")) {
            if (id != null) return error.InvalidInvocation;
            id = operation.uuidFromString(value) catch return error.InvalidInvocation;
        } else if (std.mem.eql(u8, option, "--state")) {
            if (state != null) return error.InvalidInvocation;
            state = operation.stateFromString(value) catch return error.InvalidInvocation;
        } else {
            return error.InvalidInvocation;
        }
    }
    return .{ .update = .{
        .id = id orelse return error.InvalidInvocation,
        .state = state orelse return error.InvalidInvocation,
    } };
}

fn isHelp(argument: []const u8) bool {
    if (std.mem.eql(u8, argument, "--help")) return true;
    if (std.mem.eql(u8, argument, "-h")) return true;
    return std.mem.eql(u8, argument, "help");
}

const PersistenceInterface = struct {
    context: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        create: *const fn (
            *anyopaque,
            Allocator,
            *const operation.Operation,
        ) anyerror!operation.Operation,
        read: *const fn (*anyopaque, Allocator, u128) anyerror!operation.Operation,
        update: *const fn (
            *anyopaque,
            Allocator,
            *const operation.Operation,
            *const operation.Operation,
        ) anyerror!operation.Operation,
    };

    fn init(pointer: anytype) PersistenceInterface {
        const Pointer = @TypeOf(pointer);
        const pointer_info = @typeInfo(Pointer);
        comptime std.debug.assert(pointer_info == .pointer);
        comptime std.debug.assert(pointer_info.pointer.size == .one);

        const Adapter = struct {
            fn create(
                context: *anyopaque,
                allocator: Allocator,
                source: *const operation.Operation,
            ) anyerror!operation.Operation {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.create(allocator, source);
            }

            fn read(
                context: *anyopaque,
                allocator: Allocator,
                id: u128,
            ) anyerror!operation.Operation {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.read(allocator, id);
            }

            fn update(
                context: *anyopaque,
                allocator: Allocator,
                snapshot: *const operation.Operation,
                replacement: *const operation.Operation,
            ) anyerror!operation.Operation {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.update(allocator, snapshot, replacement);
            }
        };
        return .{
            .context = pointer,
            .vtable = &.{
                .create = Adapter.create,
                .read = Adapter.read,
                .update = Adapter.update,
            },
        };
    }

    fn create(
        self: PersistenceInterface,
        allocator: Allocator,
        source: *const operation.Operation,
    ) !operation.Operation {
        return self.vtable.create(self.context, allocator, source);
    }

    fn read(
        self: PersistenceInterface,
        allocator: Allocator,
        id: u128,
    ) !operation.Operation {
        return self.vtable.read(self.context, allocator, id);
    }

    fn update(
        self: PersistenceInterface,
        allocator: Allocator,
        snapshot: *const operation.Operation,
        replacement: *const operation.Operation,
    ) !operation.Operation {
        return self.vtable.update(
            self.context,
            allocator,
            snapshot,
            replacement,
        );
    }
};

fn runCommand(command: Command, context: Context, backend: ?PersistenceInterface) u8 {
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
        error.OperationNotFound => .missing,
        error.OperationConflict => .conflict,
        error.AWSFailure, error.InvalidItem => .aws,
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
        error.UnexpectedInput,
        error.InputTooLarge,
        => .validation,
        else => .internal,
    };
}

fn executeCommand(
    command: Command,
    context: Context,
    backend_optional: ?PersistenceInterface,
) !void {
    if (command == .help) {
        try context.stdout.writeAll(usage);
        return;
    }
    const backend = backend_optional orelse return error.InternalFailure;
    switch (command) {
        .help => unreachable,
        .create => |options| try executeCreate(context, backend, options),
        .read => |id| try executeRead(context, backend, id),
        .update => |options| try executeUpdate(context, backend, options),
    }
}

fn executeCreate(
    context: Context,
    backend: PersistenceInterface,
    options: CreateOptions,
) !void {
    const parsed = try operation.parseInputJSON(
        context.allocator,
        context.stdin,
        .{
            .tenant = options.tenant,
            .now = context.now,
        },
    );
    const created = try backend.create(context.allocator, &parsed);
    try operation.validatePersistent(&created);
    try writeOperation(context, &created);
}

fn executeRead(context: Context, backend: PersistenceInterface, id: u128) !void {
    const stored = try backend.read(context.allocator, id);
    try operation.validatePersistent(&stored);
    try writeOperation(context, &stored);
}

fn executeUpdate(
    context: Context,
    backend: PersistenceInterface,
    options: UpdateOptions,
) !void {
    const snapshot = try backend.read(context.allocator, options.id);
    try operation.validatePersistent(&snapshot);
    var replacement = snapshot;
    replacement.state = options.state;
    replacement.last_updated = context.now;
    replacement.expires_at = try operation.expires_at_from_last_updated(context.now);
    replacement.result = if (operation.stateIsTerminal(options.state))
        try operation.parseResultJSON(context.allocator, context.stdin)
    else
        null;
    try operation.validatePersistent(&replacement);
    const updated = try backend.update(
        context.allocator,
        &snapshot,
        &replacement,
    );
    try operation.validatePersistent(&updated);
    try writeOperation(context, &updated);
}

fn writeOperation(context: Context, source: *const operation.Operation) !void {
    try operation.writeOutputJSON(context.stdout, source);
    try context.stdout.writeByte('\n');
}

const test_id = "00112233-4455-6677-8899-aabbccddeeff";
const test_hash = [_]u8{0xAB} ** 32;

const FakePersistence = struct {
    stored: operation.Operation = .{
        .id = operation.uuidFromString(test_id) catch unreachable,
        .tenant = "tenant-a",
        .name = "echo",
        .state = .running,
        .last_updated = 1_700_000_000,
        .expires_at = 1_700_086_400,
        .hash = test_hash,
    },
    create_error: ?anyerror = null,
    read_error: ?anyerror = null,
    update_error: ?anyerror = null,
    create_count: u8 = 0,
    read_count: u8 = 0,
    update_count: u8 = 0,
    last_id: u128 = 0,
    last_state: ?operation.State = null,
    create_last_updated: ?operation.UnixSeconds = null,
    create_tenant_buffer: [operation.tenant_size_max]u8 = undefined,
    create_tenant_len: u8 = 0,

    fn create(
        fake: *FakePersistence,
        _: Allocator,
        source: *const operation.Operation,
    ) !operation.Operation {
        fake.create_count += 1;
        fake.last_id = source.id;
        fake.last_state = source.state;
        fake.create_tenant_len = @intCast(source.tenant.len);
        @memcpy(fake.create_tenant_buffer[0..source.tenant.len], source.tenant);
        if (fake.create_error) |err| return err;
        var created = source.*;
        created.body = null;
        if (fake.create_last_updated) |last_updated| {
            created.last_updated = last_updated;
            created.expires_at = try operation.expires_at_from_last_updated(last_updated);
        }
        return created;
    }

    fn createTenant(fake: *const FakePersistence) []const u8 {
        return fake.create_tenant_buffer[0..fake.create_tenant_len];
    }

    fn read(
        fake: *FakePersistence,
        _: Allocator,
        id: u128,
    ) !operation.Operation {
        fake.read_count += 1;
        fake.last_id = id;
        if (fake.read_error) |err| return err;
        return fake.stored;
    }

    fn update(
        fake: *FakePersistence,
        _: Allocator,
        _: *const operation.Operation,
        replacement: *const operation.Operation,
    ) !operation.Operation {
        fake.update_count += 1;
        fake.last_state = replacement.state;
        if (fake.update_error) |err| return err;
        return replacement.*;
    }
};

const TestResult = struct {
    exit_code: u8,
    stdout_buffer: [stdin_size_max]u8,
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
    fake: *FakePersistence,
) TestResult {
    var result: TestResult = undefined;
    var stdout: std.Io.Writer = .fixed(&result.stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&result.stderr_buffer);
    const command = parseCommand(arguments) catch {
        writeDiagnostic(&stderr, .invocation);
        return testResultFinish(&result, &stdout, &stderr, 2);
    };
    const input = switch (command) {
        .create, .update => stdin,
        .help, .read => "",
    };
    validateCommandInput(command, input) catch {
        writeDiagnostic(&stderr, .validation);
        return testResultFinish(&result, &stdout, &stderr, 2);
    };
    if (command != .help) {
        _ = configuredTableName(environment) catch {
            writeDiagnostic(&stderr, .configuration);
            return testResultFinish(&result, &stdout, &stderr, 2);
        };
    }
    const backend = if (command == .help) null else PersistenceInterface.init(fake);
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

fn testEnvironment() !std.process.Environ.Map {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    errdefer environment.deinit();
    try environment.put("OPERATIONS_TABLE_NAME", "operations");
    std.debug.assert(environment.get("OPERATIONS_TABLE_NAME") != null);
    return environment;
}

test "help works without AWS configuration and invocation is bounded" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var fake: FakePersistence = .{};
    const help_arguments = [_][]const []const u8{
        &.{ "dynamodb", "--help" },
        &.{ "dynamodb", "-h" },
        &.{ "dynamodb", "help" },
        &.{ "dynamodb", "create", "--help" },
        &.{ "dynamodb", "read", "--help" },
        &.{ "dynamodb", "update", "--help" },
    };
    for (help_arguments) |arguments| {
        const result = runForTest(arguments, "", &environment, 0, &fake);
        try std.testing.expectEqual(@as(u8, 0), result.exit_code);
        try std.testing.expect(std.mem.startsWith(u8, result.stdout(), "Usage:\n"));
        try std.testing.expectEqualStrings("", result.stderr());
    }

    const invalid = runForTest(&.{"dynamodb"}, "", &environment, 0, &fake);
    try std.testing.expectEqual(@as(u8, 2), invalid.exit_code);
    try std.testing.expectEqualStrings("", invalid.stdout());
    const excessive = runForTest(
        &.{ "dynamodb", "read", "--id", test_id, "a", "b", "c", "d", "e" },
        "",
        &environment,
        0,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 2), excessive.exit_code);
}

test "create requires one valid bounded tenant flag" {
    const valid = [_][]const u8{
        "a",
        "a" ** operation.tenant_size_max,
        "é" ** (operation.tenant_size_max / 2),
    };
    for (valid) |tenant| {
        const command = try parseCommand(&.{ "dynamodb", "create", "--tenant", tenant });
        try std.testing.expectEqualStrings(tenant, command.create.tenant);
    }

    const invalid = [_][]const u8{
        "",
        "a" ** (operation.tenant_size_max + 1),
        ("é" ** (operation.tenant_size_max / 2)) ++ "a",
        &.{0xFF},
    };
    try std.testing.expectError(
        error.InvalidInvocation,
        parseCommand(&.{ "dynamodb", "create" }),
    );
    for (invalid) |tenant| {
        try std.testing.expectError(
            error.InvalidInvocation,
            parseCommand(&.{ "dynamodb", "create", "--tenant", tenant }),
        );
    }
}

test "configuration is required before persistence dispatch" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var fake: FakePersistence = .{};
    const missing = runForTest(
        &.{ "dynamodb", "read", "--id", test_id },
        "",
        &environment,
        0,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 2), missing.exit_code);
    try std.testing.expectEqualStrings(
        "dynamodb: missing or invalid configuration\n",
        missing.stderr(),
    );
    try std.testing.expectEqual(@as(u8, 0), fake.read_count);

    try environment.put("OPERATIONS_TABLE_NAME", "");
    const empty = runForTest(
        &.{ "dynamodb", "read", "--id", test_id },
        "",
        &environment,
        0,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 2), empty.exit_code);
    try std.testing.expectEqual(@as(u8, 0), fake.read_count);
}

test "create parses stdin dispatches once and writes canonical JSON" {
    var environment = try testEnvironment();
    defer environment.deinit();
    var fake: FakePersistence = .{};
    const input =
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
        "\"name\":\"echo\",\"body\":{\"message\":\"hello\",\"count\":2}}";
    const result = runForTest(
        &.{ "dynamodb", "create", "--tenant", "tenant-a" },
        input,
        &environment,
        1_700_000_000,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqual(@as(u8, 1), fake.create_count);
    try std.testing.expectEqual(operation.State.new, fake.last_state.?);
    try std.testing.expectEqualStrings("tenant-a", fake.createTenant());
    try std.testing.expectEqualStrings(
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"tenant-a\",\"name\":\"echo\"," ++
            "\"state\":\"NEW\",\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400," ++
            "\"hash\":\"d271e3bd560113d2b82e42dfc46be33" ++
            "fb90b43d7f4b12114f3da4888eae445d4\"}\n",
        result.stdout(),
    );
    try std.testing.expectEqualStrings("", result.stderr());
}

test "matching create retry writes the authoritative stored timestamp" {
    var environment = try testEnvironment();
    defer environment.deinit();
    var fake: FakePersistence = .{ .create_last_updated = 1_700_000_000 };
    const input =
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
        "\"name\":\"echo\",\"body\":{\"message\":\"hello\",\"count\":2}}";
    const result = runForTest(
        &.{ "dynamodb", "create", "--tenant", "tenant-a" },
        input,
        &environment,
        1_700_000_010,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.stdout(),
        "\"last_updated\":1700000000",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.stdout(),
        "\"expires_at\":1700086400",
    ) != null);
    try std.testing.expectEqualStrings("", result.stderr());
}

test "create bounds stdin and reports conflict and invalid input outcomes" {
    var environment = try testEnvironment();
    defer environment.deinit();
    var fake: FakePersistence = .{};
    const oversized = "a" ** (stdin_size_max + 1);
    const large = runForTest(
        &.{ "dynamodb", "create", "--tenant", "tenant-a" },
        oversized,
        &environment,
        0,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 2), large.exit_code);
    try std.testing.expectEqual(@as(u8, 0), fake.create_count);

    const invalid = runForTest(
        &.{ "dynamodb", "create", "--tenant", "tenant-a" },
        "null",
        &environment,
        0,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 2), invalid.exit_code);
    try std.testing.expectEqualStrings("dynamodb: invalid operation input\n", invalid.stderr());

    const spoofed = runForTest(
        &.{ "dynamodb", "create", "--tenant", "tenant-a" },
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"spoofed\",\"name\":\"echo\",\"body\":null}",
        &environment,
        0,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 2), spoofed.exit_code);
    try std.testing.expectEqual(@as(u8, 0), fake.create_count);

    fake.create_error = error.OperationConflict;
    const conflict = runForTest(
        &.{ "dynamodb", "create", "--tenant", "tenant-a" },
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"name\":\"echo\",\"body\":null}",
        &environment,
        1,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 1), conflict.exit_code);
    try std.testing.expectEqualStrings("dynamodb: operation conflict\n", conflict.stderr());
}

test "read validates UUID and writes a canonical strongly modeled item" {
    var environment = try testEnvironment();
    defer environment.deinit();
    var fake: FakePersistence = .{};
    const result = runForTest(
        &.{ "dynamodb", "read", "--id", "00112233-4455-6677-8899-AABBCCDDEEFF" },
        "ignored",
        &environment,
        0,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqual(@as(u8, 1), fake.read_count);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout(), test_id) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.stdout(),
        "\"tenant\":\"tenant-a\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout(), "\"state\":\"RUNNING\"") != null);

    const invalid = runForTest(
        &.{ "dynamodb", "read", "--id", "not-a-uuid" },
        "",
        &environment,
        0,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 2), invalid.exit_code);
}

test "read reports missing and AWS failures with stable exit codes" {
    var environment = try testEnvironment();
    defer environment.deinit();
    var fake: FakePersistence = .{ .read_error = error.OperationNotFound };
    const missing = runForTest(
        &.{ "dynamodb", "read", "--id", test_id },
        "",
        &environment,
        0,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 1), missing.exit_code);
    try std.testing.expectEqualStrings("dynamodb: operation not found\n", missing.stderr());

    fake.read_error = error.AWSFailure;
    const failed = runForTest(
        &.{ "dynamodb", "read", "--id", test_id },
        "",
        &environment,
        0,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 2), failed.exit_code);
    try std.testing.expectEqualStrings("dynamodb: AWS request failed\n", failed.stderr());
}

test "update accepts every target including jumps same state and terminal removal" {
    var environment = try testEnvironment();
    defer environment.deinit();
    const targets = [_]operation.State{ .new, .submitted, .running, .succeeded, .failed };
    for (targets) |state| {
        var fake: FakePersistence = .{};
        fake.stored.state = .failed;
        fake.stored.result = .{ .bool = true };
        const input = if (operation.stateIsTerminal(state)) "{ \"new\" : true }" else "";
        const result = runForTest(
            &.{ "dynamodb", "update", "--state", operation.stateToString(state), "--id", test_id },
            input,
            &environment,
            1_700_000_001,
            &fake,
        );
        try std.testing.expectEqual(@as(u8, 0), result.exit_code);
        try std.testing.expectEqual(@as(u8, 1), fake.read_count);
        try std.testing.expectEqual(@as(u8, 1), fake.update_count);
        try std.testing.expectEqual(state, fake.last_state.?);
        try std.testing.expect(std.mem.indexOf(
            u8,
            result.stdout(),
            "\"tenant\":\"tenant-a\"",
        ) != null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            result.stdout(),
            "\"expires_at\":1700086401",
        ) != null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            result.stdout(),
            operation.stateToString(state),
        ) != null);
        try std.testing.expectEqual(operation.stateIsTerminal(state), std.mem.indexOf(
            u8,
            result.stdout(),
            "\"result\"",
        ) != null);
        if (operation.stateIsTerminal(state)) {
            try std.testing.expect(std.mem.indexOf(
                u8,
                result.stdout(),
                "\"result\":{\"new\":true}",
            ) != null);
        }
    }
}

test "update rejects nonempty pending input and null invalid or oversized terminal results" {
    var environment = try testEnvironment();
    defer environment.deinit();
    var fake: FakePersistence = .{};
    const pending = runForTest(
        &.{ "dynamodb", "update", "--id", test_id, "--state", "RUNNING" },
        " ",
        &environment,
        0,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 2), pending.exit_code);
    try std.testing.expectEqual(@as(u8, 0), fake.read_count);

    const invalid_results = [_][]const u8{ "", "null", "{broken" };
    for (invalid_results) |input| {
        const result = runForTest(
            &.{ "dynamodb", "update", "--id", test_id, "--state", "SUCCEEDED" },
            input,
            &environment,
            0,
            &fake,
        );
        try std.testing.expectEqual(@as(u8, 2), result.exit_code);
    }
    const oversized = "\"" ++ ("a" ** (operation.result_size_max - 1)) ++ "\"";
    const large = runForTest(
        &.{ "dynamodb", "update", "--id", test_id, "--state", "FAILED" },
        oversized,
        &environment,
        0,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 2), large.exit_code);
    try std.testing.expectEqual(@as(u8, 0), fake.update_count);
}

test "update accepts a terminal result at the exact serialized size bound" {
    var environment = try testEnvironment();
    defer environment.deinit();
    var fake: FakePersistence = .{};
    const maximum = "\"" ++ ("a" ** (operation.result_size_max - 2)) ++ "\"";
    comptime std.debug.assert(maximum.len == operation.result_size_max);
    const result = runForTest(
        &.{ "dynamodb", "update", "--id", test_id, "--state", "FAILED" },
        maximum,
        &environment,
        1_700_000_001,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqual(@as(u8, 1), fake.update_count);
    try std.testing.expect(result.stdout().len > operation.result_size_max);
}

test "update conflict is generic and diagnostics do not echo input or configuration" {
    var environment = try testEnvironment();
    defer environment.deinit();
    const table_marker = "operations-private-marker";
    try environment.put("OPERATIONS_TABLE_NAME", table_marker);
    var fake: FakePersistence = .{ .update_error = error.OperationConflict };
    const result_marker = "result-private-marker";
    const result = runForTest(
        &.{ "dynamodb", "update", "--id", test_id, "--state", "FAILED" },
        "\"result-private-marker\"",
        &environment,
        0,
        &fake,
    );
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings(
        "dynamodb: operation conflict\n",
        result.stderr(),
    );
    try std.testing.expect(std.mem.indexOf(u8, result.stderr(), table_marker) == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr(), result_marker) == null);
}
