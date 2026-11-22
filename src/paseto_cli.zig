const std = @import("std");
const paseto = @import("paseto");
const device_login = @import("paseto_device_login.zig");

const Allocator = std.mem.Allocator;
const Ed25519 = paseto.Ed25519;

const argument_count_max = 8;
const stdin_size_max = paseto.token_size_max;

comptime {
    std.debug.assert(stdin_size_max == 16 * 1024);
    std.debug.assert(argument_count_max < stdin_size_max);
}

const Command = union(enum) {
    help,
    keygen,
    issue: IssueOptions,
    verify,
    login_github,
};

const IssueOptions = struct {
    subject: []const u8,
    ttl_seconds: i64,
};

const CommandInput = struct {
    stdin: []const u8,
    now: i64,
};

const InputSource = union(enum) {
    process: std.Io,
    provided: CommandInput,
};

const Context = struct {
    allocator: Allocator,
    environment: *const std.process.Environ.Map,
    random: std.Random,
    input: InputSource,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    login_services: ?*const device_login.Services = null,
};

const CliError = error{
    InvalidInvocation,
    InvalidKeyConfiguration,
    InvalidToken,
    InternalFailure,
};

const usage =
    \\Usage:
    \\  paseto keygen
    \\  paseto issue --subject <sub> --ttl-seconds <seconds>
    \\  paseto verify
    \\  paseto login github
    \\
    \\Environment:
    \\  PASETO_PRIVATE_KEY  padded standard Base64 Ed25519 secret key for issue
    \\  PASETO_PUBLIC_KEY   padded standard Base64 Ed25519 public key for verify
    \\  OPERATIONS_API_URL  HTTPS Operations API origin for login github
    \\
;

pub fn main(init: std.process.Init) u8 {
    var stdout_buffer: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &stdout_buffer);
    var stderr_buffer: [1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &stderr_buffer);
    var stdout_file = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    var stderr_file = std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);

    var arguments_buffer: [argument_count_max][]const u8 = undefined;
    const arguments = collectArguments(
        init.minimal.args,
        &arguments_buffer,
    ) catch {
        return finish(&stdout_file.interface, &stderr_file.interface, 2, .invocation);
    };
    var random_source = std.Random.IoSource{ .io = init.io };
    var login_runtime = device_login.Runtime.init(init.gpa, init.io);
    defer login_runtime.client.deinit();
    const login_services = login_runtime.services();
    const context = Context{
        .allocator = init.gpa,
        .environment = init.environ_map,
        .random = random_source.interface(),
        .input = .{ .process = init.io },
        .stdout = &stdout_file.interface,
        .stderr = &stderr_file.interface,
        .login_services = &login_services,
    };
    const exit_code = runArguments(arguments, context);
    return finish(&stdout_file.interface, &stderr_file.interface, exit_code, null);
}

const Failure = enum {
    invocation,
    key_configuration,
    token,
    internal,
    login_origin,
    login_denied,
    login_failed,
    login_expired,
    login_redirected,
    login_exchange,

    fn code(failure: Failure) u8 {
        return switch (failure) {
            .token,
            .login_denied,
            .login_failed,
            .login_expired,
            .login_redirected,
            .login_exchange,
            => 1,
            .invocation, .key_configuration, .internal, .login_origin => 2,
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
        .invocation => "paseto: invalid invocation; use --help\n",
        .key_configuration => "paseto: missing or invalid key configuration\n",
        .token => "paseto: token verification failed\n",
        .internal => "paseto: operation failed\n",
        .login_origin => "paseto: set OPERATIONS_API_URL to an HTTPS Operations API origin\n",
        .login_denied => "paseto: GitHub sign-in was denied\n",
        .login_failed => "paseto: Operations GitHub sign-in failed\n",
        .login_expired => "paseto: GitHub sign-in expired; run paseto login github again\n",
        .login_redirected => "paseto: Operations redirected the GitHub sign-in request\n",
        .login_exchange => "paseto: Operations could not complete GitHub sign-in (HTTP 500)\n",
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
        .verify => {},
        else => return "",
    }

    var reader_buffer: [4096]u8 = undefined;
    var stdin_file = std.Io.File.stdin().readerStreaming(io, &reader_buffer);
    const size = try stdin_file.interface.readSliceShort(buffer);
    if (size > stdin_size_max) return error.InputTooLarge;
    std.debug.assert(size <= stdin_size_max);
    std.debug.assert(size <= buffer.len);
    return buffer[0..size];
}

fn unixSeconds(io: std.Io) i64 {
    const timestamp = std.Io.Clock.real.now(io);
    const seconds = @divFloor(timestamp.nanoseconds, std.time.ns_per_s);
    const result = std.math.cast(i64, seconds) orelse {
        return if (seconds < 0) std.math.minInt(i64) else std.math.maxInt(i64);
    };
    std.debug.assert(result >= std.math.minInt(i64));
    std.debug.assert(result <= std.math.maxInt(i64));
    return result;
}

fn parseCommand(arguments: []const []const u8) CliError!Command {
    if (arguments.len < 2) return error.InvalidInvocation;
    if (arguments.len > argument_count_max) return error.InvalidInvocation;

    const name = arguments[1];
    if (isHelp(name)) {
        if (arguments.len != 2) return error.InvalidInvocation;
        return .help;
    }
    if (std.mem.eql(u8, name, "keygen")) return parseKeygen(arguments[2..]);
    if (std.mem.eql(u8, name, "issue")) return parseIssue(arguments[2..]);
    if (std.mem.eql(u8, name, "verify")) return parseVerify(arguments[2..]);
    if (std.mem.eql(u8, name, "login")) {
        if (arguments.len == 3 and isHelp(arguments[2])) return .help;
        if (arguments.len == 3 and std.mem.eql(u8, arguments[2], "github")) return .login_github;
    }
    return error.InvalidInvocation;
}

fn parseKeygen(arguments: []const []const u8) CliError!Command {
    if (arguments.len == 0) return .keygen;
    if (arguments.len == 1) {
        if (isHelp(arguments[0])) return .help;
    }
    return error.InvalidInvocation;
}

fn parseVerify(arguments: []const []const u8) CliError!Command {
    if (arguments.len == 0) return .verify;
    if (arguments.len == 1) {
        if (isHelp(arguments[0])) return .help;
    }
    return error.InvalidInvocation;
}

fn parseIssue(arguments: []const []const u8) CliError!Command {
    if (arguments.len == 1) {
        if (isHelp(arguments[0])) return .help;
    }
    if (arguments.len != 4) return error.InvalidInvocation;

    var subject: ?[]const u8 = null;
    var ttl_seconds: ?i64 = null;
    var index: usize = 0;
    while (index < arguments.len) : (index += 2) {
        const option = arguments[index];
        const value = arguments[index + 1];
        if (std.mem.eql(u8, option, "--subject")) {
            if (subject != null) return error.InvalidInvocation;
            subject = value;
        } else if (std.mem.eql(u8, option, "--ttl-seconds")) {
            if (ttl_seconds != null) return error.InvalidInvocation;
            ttl_seconds = parseTtl(value) catch return error.InvalidInvocation;
        } else {
            return error.InvalidInvocation;
        }
    }
    if (subject == null) return error.InvalidInvocation;
    if (ttl_seconds == null) return error.InvalidInvocation;
    paseto.validateSubject(subject.?) catch return error.InvalidInvocation;
    return .{ .issue = .{
        .subject = subject.?,
        .ttl_seconds = ttl_seconds.?,
    } };
}

fn parseTtl(value: []const u8) !i64 {
    const ttl = try std.fmt.parseInt(i64, value, 10);
    if (ttl <= 0) return error.InvalidTtl;
    std.debug.assert(ttl > 0);
    std.debug.assert(ttl <= std.math.maxInt(i64));
    return ttl;
}

fn isHelp(argument: []const u8) bool {
    if (std.mem.eql(u8, argument, "--help")) return true;
    if (std.mem.eql(u8, argument, "-h")) return true;
    return std.mem.eql(u8, argument, "help");
}

fn runCommand(command: Command, context: Context, input: *const CommandInput) u8 {
    executeCommand(command, context, input) catch |err| {
        const failure: Failure = switch (err) {
            error.InvalidInvocation => .invocation,
            error.InvalidKeyConfiguration => .key_configuration,
            error.InvalidToken => .token,
            error.InvalidOrigin => .login_origin,
            error.SignInDenied => .login_denied,
            error.SignInFailed => .login_failed,
            error.SignInExpired => .login_expired,
            error.SignInRedirected => .login_redirected,
            error.SignInExchange => .login_exchange,
            else => .internal,
        };
        writeDiagnostic(context.stderr, failure);
        return failure.code();
    };
    return 0;
}

fn runArguments(arguments: []const []const u8, context: Context) u8 {
    const command = parseCommand(arguments) catch {
        writeDiagnostic(context.stderr, .invocation);
        return 2;
    };
    var stdin_buffer: [stdin_size_max + 1]u8 = undefined;
    const input = switch (context.input) {
        .process => |io| process: {
            const stdin = readCommandInput(io, command, &stdin_buffer) catch |err| {
                const failure: Failure = if (err == error.InputTooLarge) .token else .internal;
                writeDiagnostic(context.stderr, failure);
                return failure.code();
            };
            break :process CommandInput{ .stdin = stdin, .now = unixSeconds(io) };
        },
        .provided => |input| input,
    };
    return runCommand(command, context, &input);
}

fn executeCommand(command: Command, context: Context, input: *const CommandInput) !void {
    switch (command) {
        .help => try context.stdout.writeAll(usage),
        .keygen => try keygen(context),
        .issue => |options| try issue(options, context, input.now),
        .verify => try verify(context, input),
        .login_github => {
            const origin = context.environment.get("OPERATIONS_API_URL") orelse {
                return error.InvalidOrigin;
            };
            const services = context.login_services orelse return error.InternalFailure;
            try device_login.run(context.allocator, services, origin, .{
                .stdout = context.stdout,
                .stderr = context.stderr,
            });
        },
    }
}

fn keygen(context: Context) !void {
    var key_pair: Ed25519.KeyPair = undefined;
    try paseto.generateKeyPair(context.random, &key_pair);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    var private_base64: [paseto.private_key_base64_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &private_base64);
    var public_base64: [paseto.public_key_base64_size]u8 = undefined;
    var key_id: [paseto.paserk_id_size]u8 = undefined;
    const private = paseto.encodePrivateKey(&key_pair.secret_key, &private_base64);
    const public = paseto.encodePublicKey(key_pair.public_key, &public_base64);
    const kid = paseto.paserkId(key_pair.public_key, &key_id);

    try context.stdout.print("PASETO_PRIVATE_KEY={s}\n", .{private});
    try context.stdout.print("PASETO_PUBLIC_KEY={s}\n", .{public});
    try context.stdout.print("PASETO_KEY_ID={s}\n", .{kid});
}

fn issue(options: IssueOptions, context: Context, now: i64) !void {
    const private_base64 = context.environment.get("PASETO_PRIVATE_KEY") orelse {
        return error.InvalidKeyConfiguration;
    };
    var secret_key = paseto.decodePrivateKey(private_base64) catch {
        return error.InvalidKeyConfiguration;
    };
    defer paseto.wipeSecretKey(&secret_key);

    const token = paseto.issue(
        context.allocator,
        context.random,
        &secret_key,
        .{
            .subject = options.subject,
            .now = now,
            .ttl_seconds = options.ttl_seconds,
        },
    ) catch |err| {
        return switch (err) {
            error.InvalidSubject, error.InvalidTtl => error.InvalidInvocation,
            error.InvalidKey => error.InvalidKeyConfiguration,
            error.InvalidToken, error.InternalFailure => error.InternalFailure,
        };
    };
    defer context.allocator.free(token);
    try context.stdout.print("{s}\n", .{token});
}

fn verify(context: Context, input: *const CommandInput) !void {
    const public_base64 = context.environment.get("PASETO_PUBLIC_KEY") orelse {
        return error.InvalidKeyConfiguration;
    };
    const public_key = paseto.decodePublicKey(public_base64) catch {
        return error.InvalidKeyConfiguration;
    };
    if (input.stdin.len > stdin_size_max) return error.InvalidToken;

    var claims = paseto.verify(
        context.allocator,
        input.stdin,
        public_key,
        input.now,
    ) catch |err| {
        return switch (err) {
            error.InvalidToken => error.InvalidToken,
            else => error.InternalFailure,
        };
    };
    defer claims.deinit();
    try paseto.writeClaims(context.stdout, &claims);
}

test "keygen writes padded Base64 keys with matching public material" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();

    const result = runForTest(&.{ "paseto", "keygen" }, "", &environment, 1000);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", result.stderr());

    var lines = std.mem.splitScalar(u8, result.stdout(), '\n');
    const private_line = lines.next().?;
    const public_line = lines.next().?;
    const kid_line = lines.next().?;
    try std.testing.expectEqualStrings("", lines.next().?);
    try std.testing.expect(lines.next() == null);

    const private_prefix = "PASETO_PRIVATE_KEY=";
    const public_prefix = "PASETO_PUBLIC_KEY=";
    const kid_prefix = "PASETO_KEY_ID=";
    try std.testing.expect(std.mem.startsWith(u8, private_line, private_prefix));
    try std.testing.expect(std.mem.startsWith(u8, public_line, public_prefix));
    try std.testing.expect(std.mem.startsWith(u8, kid_line, kid_prefix));

    var secret_key = try paseto.decodePrivateKey(private_line[private_prefix.len..]);
    defer paseto.wipeSecretKey(&secret_key);
    const public_key = try paseto.decodePublicKey(public_line[public_prefix.len..]);
    try std.testing.expectEqualSlices(
        u8,
        &secret_key.publicKeyBytes(),
        &public_key.toBytes(),
    );

    var expected_kid_buffer: [paseto.paserk_id_size]u8 = undefined;
    const expected_kid = paseto.paserkId(public_key, &expected_kid_buffer);
    try std.testing.expectEqualStrings(expected_kid, kid_line[kid_prefix.len..]);
}

test "issue uses only the private key and verify uses only the public key" {
    var key_pair = testKeyPair(0x31);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    var issue_environment = std.process.Environ.Map.init(std.testing.allocator);
    defer issue_environment.deinit();
    try putPrivateKey(&issue_environment, &key_pair.secret_key);

    const issue_result = runForTest(
        &.{ "paseto", "issue", "--subject", "alice", "--ttl-seconds", "60" },
        "",
        &issue_environment,
        1000,
    );
    try std.testing.expectEqual(@as(u8, 0), issue_result.exit_code);
    try std.testing.expectEqualStrings("", issue_result.stderr());
    try std.testing.expect(std.mem.startsWith(u8, issue_result.stdout(), "v4.public."));
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, issue_result.stdout(), "\n"),
    );

    var verify_environment = std.process.Environ.Map.init(std.testing.allocator);
    defer verify_environment.deinit();
    try putPublicKey(&verify_environment, key_pair.public_key);
    const verify_result = runForTest(
        &.{ "paseto", "verify" },
        issue_result.stdout(),
        &verify_environment,
        1000,
    );
    try std.testing.expectEqual(@as(u8, 0), verify_result.exit_code);
    try std.testing.expectEqualStrings(
        "{\"sub\":\"alice\",\"exp\":1060}\n",
        verify_result.stdout(),
    );
    try std.testing.expectEqualStrings("", verify_result.stderr());

    const private_only_result = runForTest(
        &.{ "paseto", "verify" },
        issue_result.stdout(),
        &issue_environment,
        1000,
    );
    try std.testing.expectEqual(@as(u8, 2), private_only_result.exit_code);
    try std.testing.expectEqualStrings("", private_only_result.stdout());
    try std.testing.expectEqualStrings(
        "paseto: missing or invalid key configuration\n",
        private_only_result.stderr(),
    );
}

test "verify rejects a token that expires before stdin reaches EOF" {
    var key_pair = testKeyPair(0x22);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putPrivateKey(&environment, &key_pair.secret_key);
    try putPublicKey(&environment, key_pair.public_key);

    const started_seconds = 1000;
    const issue_result = runForTest(
        &.{ "paseto", "issue", "--subject", "alice", "--ttl-seconds", "1" },
        "",
        &environment,
        started_seconds,
    );
    try std.testing.expectEqual(@as(u8, 0), issue_result.exit_code);

    var stdin = ExpiringStdin{
        .remaining = issue_result.stdout(),
        .now_seconds = started_seconds,
        .eof_seconds = 1001,
    };
    const result = run_test(&.{ "paseto", "verify" }, &environment, .{ .process = stdin.io() }, .{});
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("", result.stdout());
    try std.testing.expectEqualStrings("paseto: token verification failed\n", result.stderr());
    try std.testing.expectEqual(@as(i64, 1001), stdin.now_seconds);
}

const ExpiringStdin = struct {
    remaining: []const u8,
    now_seconds: i64,
    eof_seconds: i64,

    const vtable: std.Io.VTable = fixture: {
        var table = std.Io.failing.vtable.*;
        table.operate = operate;
        table.now = now;
        break :fixture table;
    };

    fn io(stdin: *ExpiringStdin) std.Io {
        return .{ .userdata = stdin, .vtable = &vtable };
    }

    fn operate(context: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        const stdin: *ExpiringStdin = @ptrCast(@alignCast(context.?));
        const read = operation.file_read_streaming;
        std.debug.assert(read.file.handle == std.Io.File.stdin().handle);
        if (stdin.remaining.len == 0) {
            // The token is valid before the read begins and expired when stdin closes.
            stdin.now_seconds = stdin.eof_seconds;
            return .{ .file_read_streaming = error.EndOfStream };
        }
        const destination = read.data[0];
        std.debug.assert(destination.len > 0);
        const size = @min(destination.len, stdin.remaining.len);
        @memcpy(destination[0..size], stdin.remaining[0..size]);
        stdin.remaining = stdin.remaining[size..];
        return .{ .file_read_streaming = size };
    }

    fn now(context: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
        const stdin: *const ExpiringStdin = @ptrCast(@alignCast(context.?));
        std.debug.assert(clock == .real);
        return .{ .nanoseconds = @as(i96, stdin.now_seconds) * std.time.ns_per_s };
    }
};

test "verify accepts surrounding whitespace and writes canonical claims" {
    var key_pair = testKeyPair(0x23);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    var issue_environment = std.process.Environ.Map.init(std.testing.allocator);
    defer issue_environment.deinit();
    try putPrivateKey(&issue_environment, &key_pair.secret_key);
    const issue_result = runForTest(
        &.{ "paseto", "issue", "--ttl-seconds", "100", "--subject", "a" },
        "",
        &issue_environment,
        1000,
    );
    const input = try std.fmt.allocPrint(
        std.testing.allocator,
        " \t{s}\r\n",
        .{std.mem.trimEnd(u8, issue_result.stdout(), "\n")},
    );
    defer std.testing.allocator.free(input);

    var verify_environment = std.process.Environ.Map.init(std.testing.allocator);
    defer verify_environment.deinit();
    try putPublicKey(&verify_environment, key_pair.public_key);
    const result = runForTest(
        &.{ "paseto", "verify" },
        input,
        &verify_environment,
        1000,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("{\"sub\":\"a\",\"exp\":1100}\n", result.stdout());
    try std.testing.expectEqualStrings("", result.stderr());
}

test "subject validation enforces UTF-8 byte boundaries at the adapter" {
    var key_pair = testKeyPair(0x72);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putPrivateKey(&environment, &key_pair.secret_key);

    const valid_subjects = [_][]const u8{
        &@as([paseto.subject_size_max]u8, @splat('a')),
        std.mem.asBytes(&@as([paseto.subject_size_max / 2][2]u8, @splat("é".*))),
    };
    for (valid_subjects) |subject| {
        const result = runForTest(
            &.{ "paseto", "issue", "--subject", subject, "--ttl-seconds", "1" },
            "",
            &environment,
            1000,
        );
        try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    }

    const invalid_subjects = [_][]const u8{
        "",
        &@as([paseto.subject_size_max + 1]u8, @splat('a')),
        (std.mem.asBytes(&@as([paseto.subject_size_max / 2][2]u8, @splat("é".*)))) ++ "a",
        "\xff",
    };
    for (invalid_subjects) |subject| {
        const result = runForTest(
            &.{ "paseto", "issue", "--subject", subject, "--ttl-seconds", "1" },
            "",
            &environment,
            1000,
        );
        try std.testing.expectEqual(@as(u8, 2), result.exit_code);
        try std.testing.expectEqualStrings("", result.stdout());
    }
}

test "issue rejects non-positive malformed and overflowing TTL values" {
    var key_pair = testKeyPair(0x73);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putPrivateKey(&environment, &key_pair.secret_key);

    const invalid_ttls = [_][]const u8{ "0", "-1", "x", "9223372036854775808" };
    for (invalid_ttls) |ttl| {
        const result = runForTest(
            &.{ "paseto", "issue", "--subject", "a", "--ttl-seconds", ttl },
            "",
            &environment,
            1000,
        );
        try std.testing.expectEqual(@as(u8, 2), result.exit_code);
    }
    const overflow_result = runForTest(
        &.{
            "paseto",
            "issue",
            "--subject",
            "a",
            "--ttl-seconds",
            "9223372036854775807",
        },
        "",
        &environment,
        1,
    );
    try std.testing.expectEqual(@as(u8, 2), overflow_result.exit_code);
}

test "verify bounds stdin to 16 KiB" {
    var key_pair = testKeyPair(0x74);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putPublicKey(&environment, key_pair.public_key);

    const oversized = &@as([stdin_size_max + 1]u8, @splat('a'));
    const result = runForTest(&.{ "paseto", "verify" }, oversized, &environment, 1000);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("", result.stdout());
    try std.testing.expectEqualStrings(
        "paseto: token verification failed\n",
        result.stderr(),
    );
}

test "help parsing diagnostics exit codes and output streams are separated" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();

    const help_arguments = [_][]const []const u8{
        &.{ "paseto", "--help" },
        &.{ "paseto", "-h" },
        &.{ "paseto", "help" },
        &.{ "paseto", "keygen", "--help" },
        &.{ "paseto", "issue", "--help" },
        &.{ "paseto", "verify", "--help" },
    };
    for (help_arguments) |arguments| {
        const result = runForTest(arguments, "", &environment, 1000);
        try std.testing.expectEqual(@as(u8, 0), result.exit_code);
        try std.testing.expect(std.mem.startsWith(u8, result.stdout(), "Usage:\n"));
        try std.testing.expectEqualStrings("", result.stderr());
    }

    const invalid_arguments = [_][]const []const u8{
        &.{"paseto"},
        &.{ "paseto", "unknown" },
        &.{ "paseto", "keygen", "extra" },
        &.{ "paseto", "verify", "extra" },
        &.{ "paseto", "issue", "--subject", "a" },
        &.{
            "paseto",
            "issue",
            "--subject",
            "a",
            "--subject",
            "b",
        },
    };
    for (invalid_arguments) |arguments| {
        const result = runForTest(arguments, "", &environment, 1000);
        try std.testing.expectEqual(@as(u8, 2), result.exit_code);
        try std.testing.expectEqualStrings("", result.stdout());
        try std.testing.expectEqualStrings(
            "paseto: invalid invocation; use --help\n",
            result.stderr(),
        );
    }
}

test "configuration and token diagnostics do not echo sensitive inputs" {
    var invalid_environment = std.process.Environ.Map.init(std.testing.allocator);
    defer invalid_environment.deinit();
    const secret_marker = "private-key-secret-marker";
    try invalid_environment.put("PASETO_PRIVATE_KEY", secret_marker);
    const issue_result = runForTest(
        &.{ "paseto", "issue", "--subject", "a", "--ttl-seconds", "1" },
        "",
        &invalid_environment,
        1000,
    );
    try std.testing.expectEqual(@as(u8, 2), issue_result.exit_code);
    try std.testing.expect(std.mem.indexOf(
        u8,
        issue_result.stderr(),
        secret_marker,
    ) == null);
}

test "token diagnostics do not echo tokens or configured keys" {
    const secret_marker = "private-key-secret-marker";
    var key_pair = testKeyPair(0x75);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    var verify_environment = std.process.Environ.Map.init(std.testing.allocator);
    defer verify_environment.deinit();
    try putPublicKey(&verify_environment, key_pair.public_key);
    const token_marker = "token-secret-marker";
    const verify_result = runForTest(
        &.{ "paseto", "verify" },
        token_marker,
        &verify_environment,
        1000,
    );
    try std.testing.expectEqual(@as(u8, 1), verify_result.exit_code);
    try std.testing.expect(std.mem.indexOf(
        u8,
        verify_result.stderr(),
        token_marker,
    ) == null);

    try verify_environment.put("PASETO_PUBLIC_KEY", "invalid-public-key-marker");
    try verify_environment.put("PASETO_PRIVATE_KEY", secret_marker);
    const public_result = runForTest(
        &.{ "paseto", "verify" },
        token_marker,
        &verify_environment,
        1000,
    );
    try std.testing.expectEqual(@as(u8, 2), public_result.exit_code);
    try std.testing.expect(std.mem.indexOf(
        u8,
        public_result.stderr(),
        "invalid-public-key-marker",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        public_result.stderr(),
        secret_marker,
    ) == null);
}

const TestResult = struct {
    exit_code: u8,
    stdout_buffer: [32 * 1024]u8,
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

test "GitHub login presents browser approval and reports denial after the first interval" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("OPERATIONS_API_URL", "https://operations.example:8443/");

    var operations = TestOperations{ .polls = &.{
        .{
            .time_seconds = 5,
            .response = .{ .status = .forbidden, .body = "{\"error\":\"access_denied\"}" },
        },
    } };
    const result = run_login_for_test(&environment, &operations);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("", result.stdout());
    try std.testing.expectEqualStrings(
        test_approval_prompt ++ "paseto: GitHub sign-in was denied\n",
        result.stderr(),
    );
    try std.testing.expectEqual(@as(usize, 2), operations.requests);
}

test "GitHub login waits through pending approval and Retry-After and prints one signed token" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("OPERATIONS_API_URL", "https://operations.example:8443");

    var key_pair = testKeyPair(0x71);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    var random = std.Random.DefaultPrng.init(41);
    const allocator = std.testing.allocator;
    const token = try paseto.issue(allocator, random.random(), &key_pair.secret_key, .{
        .subject = "github:42",
        .now = 1020,
        .ttl_seconds = 28800,
    });
    defer allocator.free(token);
    const success = try std.json.Stringify.valueAlloc(allocator, .{
        .access_token = token,
        .token_type = "Bearer",
        .expires_in = 28800,
    }, .{});
    defer allocator.free(success);
    var operations = TestOperations{ .polls = &.{
        .{
            .time_seconds = 5,
            .response = .{
                .status = .accepted,
                .body = "{\"error\":\"authorization_pending\",\"interval\":7}",
            },
        },
        .{
            .time_seconds = 12,
            .response = .{ .status = .too_many_requests, .body = "", .retry_after_seconds = 8 },
        },
        .{ .time_seconds = 20, .response = .{ .status = .ok, .body = success } },
    } };
    const result = run_login_for_test(&environment, &operations);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings(test_approval_prompt, result.stderr());
    const expected_stdout = try std.fmt.allocPrint(allocator, "{s}\n", .{token});
    defer allocator.free(expected_stdout);
    try std.testing.expectEqualStrings(expected_stdout, result.stdout());
    try std.testing.expectEqual(@as(usize, 4), operations.requests);

    try putPublicKey(&environment, key_pair.public_key);
    const verified = runForTest(&.{ "paseto", "verify" }, result.stdout(), &environment, 1020);
    try std.testing.expectEqual(@as(u8, 0), verified.exit_code);
    try std.testing.expectEqualStrings(
        "{\"sub\":\"github:42\",\"exp\":29820}\n",
        verified.stdout(),
    );
    try std.testing.expectEqualStrings("", verified.stderr());
}

test "GitHub login stops at server expiry or before polling at the local deadline" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("OPERATIONS_API_URL", "https://operations.example:8443");
    const responses: []const device_login.Response = &.{
        .{ .status = .gone, .body = "{\"error\":\"expired_or_consumed\"}" },
        .{ .status = .too_many_requests, .body = "", .retry_after_seconds = 55 },
    };
    for (responses, [_]i96{ 5, 60 }) |response, elapsed_seconds| {
        var operations = TestOperations{ .polls = &.{
            .{ .time_seconds = 5, .response = response },
        } };
        const result = run_login_for_test(&environment, &operations);
        try std.testing.expectEqual(@as(u8, 1), result.exit_code);
        try std.testing.expectEqualStrings("", result.stdout());
        try std.testing.expectEqualStrings(
            test_approval_prompt ++ test_expiry_diagnostic,
            result.stderr(),
        );
        try std.testing.expectEqual(@as(usize, 2), operations.requests);
        try std.testing.expectEqual(elapsed_seconds * std.time.ns_per_s, operations.elapsed_ns);
    }
}

test "GitHub login rejects a poll response arriving at the grant deadline" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("OPERATIONS_API_URL", "https://operations.example:8443");
    var operations = TestOperations{ .polls = &.{.{
        .time_seconds = 5,
        .response_delay_seconds = 55,
        .response = .{ .status = .ok, .body = "{}" },
    }} };
    const result = run_login_for_test(&environment, &operations);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("", result.stdout());
    try std.testing.expectEqualStrings(
        test_approval_prompt ++ test_expiry_diagnostic,
        result.stderr(),
    );
    try std.testing.expectEqual(@as(usize, 2), operations.requests);
}

test "GitHub login backs off on gateway throttles and 503 and reports only the exchange status" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("OPERATIONS_API_URL", "https://operations.example:8443");
    var operations = TestOperations{ .polls = &.{
        .{ .time_seconds = 5, .response = .{ .status = .too_many_requests, .body = "" } },
        .{ .time_seconds = 15, .response = .{ .status = .service_unavailable, .body = "" } },
        .{
            .time_seconds = 35,
            .response = .{ .status = .internal_server_error, .body =
            \\{"error":"internal_error","message":"private-poll-code bearer-token signing-key"}
            },
        },
    } };
    const result = run_login_for_test(&environment, &operations);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("", result.stdout());
    try std.testing.expectEqualStrings(
        test_approval_prompt ++ "paseto: Operations could not complete GitHub sign-in (HTTP 500)\n",
        result.stderr(),
    );
    try std.testing.expectEqual(@as(usize, 4), operations.requests);
}

test "GitHub login keeps a poll redirect and malformed credential out of the output" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("OPERATIONS_API_URL", "https://operations.example:8443");
    const responses: []const device_login.Response = &.{
        .{ .status = .temporary_redirect, .body = "https://other.example/private-poll-code" },
        .{ .status = .ok, .body =
        \\{"access_token":"v4.public.fake\nBearer secret","token_type":"Bearer","expires_in":28800}
        },
        .{
            .status = .ok,
            .body = "{\"access_token\":\"v4.public." ++ @as([90]u8, @splat('A')) ++
                "\",\"token_type\":\"Bearer\",\"expires_in\":28800}",
        },
    };
    const diagnostics = [_][]const u8{
        "paseto: Operations redirected the GitHub sign-in request\n",
        "paseto: Operations GitHub sign-in failed\n",
        "paseto: Operations GitHub sign-in failed\n",
    };
    for (responses, diagnostics) |response, diagnostic| {
        var operations = TestOperations{ .polls = &.{
            .{ .time_seconds = 5, .response = response },
        } };
        const result = run_login_for_test(&environment, &operations);
        try std.testing.expectEqual(@as(u8, 1), result.exit_code);
        try std.testing.expectEqualStrings("", result.stdout());
        const expected = try std.mem.concat(std.testing.allocator, u8, &.{
            test_approval_prompt, diagnostic,
        });
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, result.stderr());
        try std.testing.expectEqual(@as(usize, 2), operations.requests);
    }
}

test "GitHub login rejects invalid Operations origins before making a request" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    const origins: []const ?[]const u8 = &.{
        null,
        "",
        "http://operations.example:8443",
        "https://user:credential@operations.example",
        "https://operations.example/route",
        "https://operations.example?credential",
        "https://operations.example/#credential",
        "https:operations.example",
        "https://operations.example:+8443",
        "https://operations.example:8_443",
        "https://operations.example\n",
    };
    for (origins) |origin| {
        if (origin) |value| try environment.put("OPERATIONS_API_URL", value);
        var operations = TestOperations{ .polls = &.{} };
        const result = run_login_for_test(&environment, &operations);
        try std.testing.expectEqual(@as(u8, 2), result.exit_code);
        try std.testing.expectEqualStrings("", result.stdout());
        try std.testing.expectEqualStrings(
            "paseto: set OPERATIONS_API_URL to an HTTPS Operations API origin\n",
            result.stderr(),
        );
        try std.testing.expectEqual(@as(usize, 0), operations.requests);
    }
}

fn run_login_for_test(
    environment: *const std.process.Environ.Map,
    operations: *TestOperations,
) TestResult {
    const services = operations.services();
    return run_test(
        &.{ "paseto", "login", "github" },
        environment,
        .{ .provided = .{ .stdin = "", .now = 1000 } },
        .{ .login_services = &services },
    );
}

const test_approval_prompt =
    "Open https://github.com/login/device in your browser and enter code WDJB-MJHT.\n";
const test_expiry_diagnostic =
    "paseto: GitHub sign-in expired; run paseto login github again\n";

const TestOperations = struct {
    const Poll = struct {
        time_seconds: i96,
        response: device_login.Response,
        response_delay_seconds: i96 = 0,
    };

    polls: []const Poll,
    requests: usize = 0,
    elapsed_ns: i96 = 0,

    fn services(operations: *TestOperations) device_login.Services {
        return .{ .context = operations, .post = post, .now = now, .sleep = sleep };
    }

    fn post(
        context: *anyopaque,
        uri: *const std.Uri,
        body: []const u8,
        _: []u8,
        deadline_ns: i96,
    ) !device_login.Response {
        const operations: *TestOperations = @ptrCast(@alignCast(context));
        try std.testing.expectEqualStrings("https", uri.scheme);
        try std.testing.expectEqualStrings("operations.example", uri.host.?.percent_encoded);
        try std.testing.expectEqual(@as(?u16, 8443), uri.port);
        try std.testing.expect(uri.query == null);
        try std.testing.expect(uri.fragment == null);
        const request_index = operations.requests;
        operations.requests += 1;
        if (request_index == 0) {
            try std.testing.expectEqual(30 * std.time.ns_per_s, deadline_ns);
            try std.testing.expectEqualStrings("/auth/github/device/start", uri.path.raw);
            try std.testing.expectEqualStrings("", body);
            return .{ .status = .ok, .body =
            \\{"device_code":"private-poll-code","user_code":"WDJB-MJHT",
            \\"verification_uri":"https://github.com/login/device","interval":5,"expires_in":60}
            };
        }
        try std.testing.expectEqualStrings("/auth/github/device/poll", uri.path.raw);
        try std.testing.expectEqualStrings("{\"device_code\":\"private-poll-code\"}", body);
        try std.testing.expect(request_index <= operations.polls.len);
        const poll = operations.polls[request_index - 1];
        try std.testing.expectEqual(poll.time_seconds * std.time.ns_per_s, operations.elapsed_ns);
        const deadline_seconds = @min(poll.time_seconds + 30, 60);
        try std.testing.expectEqual(deadline_seconds * std.time.ns_per_s, deadline_ns);
        operations.elapsed_ns += poll.response_delay_seconds * std.time.ns_per_s;
        return poll.response;
    }

    fn now(context: *anyopaque) i96 {
        const operations: *TestOperations = @ptrCast(@alignCast(context));
        return operations.elapsed_ns;
    }

    fn sleep(context: *anyopaque, duration: std.Io.Duration) !void {
        const operations: *TestOperations = @ptrCast(@alignCast(context));
        operations.elapsed_ns += duration.nanoseconds;
    }
};

fn runForTest(
    arguments: []const []const u8,
    stdin: []const u8,
    environment: *const std.process.Environ.Map,
    now: i64,
) TestResult {
    return run_test(arguments, environment, .{ .provided = .{ .stdin = stdin, .now = now } }, .{});
}

fn run_test(
    arguments: []const []const u8,
    environment: *const std.process.Environ.Map,
    input: InputSource,
    options: struct { login_services: ?*const device_login.Services = null },
) TestResult {
    var result: TestResult = undefined;
    var stdout: std.Io.Writer = .fixed(&result.stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&result.stderr_buffer);
    var random = std.Random.DefaultPrng.init(0x5445535453454544);
    result.exit_code = runArguments(arguments, .{
        .allocator = std.testing.allocator,
        .environment = environment,
        .random = random.random(),
        .input = input,
        .stdout = &stdout,
        .stderr = &stderr,
        .login_services = options.login_services,
    });
    result.stdout_size = stdout.buffered().len;
    result.stderr_size = stderr.buffered().len;
    std.debug.assert(result.stdout_size <= result.stdout_buffer.len);
    std.debug.assert(result.stderr_size <= result.stderr_buffer.len);
    return result;
}

fn testKeyPair(seed_byte: u8) Ed25519.KeyPair {
    const seed = @as([Ed25519.KeyPair.seed_length]u8, @splat(seed_byte));
    const key_pair = Ed25519.KeyPair.generateDeterministic(seed) catch unreachable;
    std.debug.assert(key_pair.secret_key.toBytes().len == Ed25519.SecretKey.encoded_length);
    std.debug.assert(key_pair.public_key.toBytes().len == Ed25519.PublicKey.encoded_length);
    return key_pair;
}

fn putPrivateKey(
    environment: *std.process.Environ.Map,
    secret_key: *const Ed25519.SecretKey,
) !void {
    var buffer: [paseto.private_key_base64_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    const encoded = paseto.encodePrivateKey(secret_key, &buffer);
    try environment.put("PASETO_PRIVATE_KEY", encoded);
    std.debug.assert(environment.get("PASETO_PRIVATE_KEY") != null);
    std.debug.assert(environment.get("PASETO_PUBLIC_KEY") == null);
}

fn putPublicKey(
    environment: *std.process.Environ.Map,
    public_key: Ed25519.PublicKey,
) !void {
    var buffer: [paseto.public_key_base64_size]u8 = undefined;
    const encoded = paseto.encodePublicKey(public_key, &buffer);
    try environment.put("PASETO_PUBLIC_KEY", encoded);
    std.debug.assert(environment.get("PASETO_PUBLIC_KEY") != null);
    std.debug.assert(encoded.len == paseto.public_key_base64_size);
}
