const std = @import("std");
const paseto = @import("zig-paseto");

const Ed25519 = paseto.Ed25519;
const Allocator = std.mem.Allocator;

const argument_count_max = 8;
const stdin_size_max = 16 * 1024;
const subject_size_max = 64;
const payload_size_max = 512;
const footer_size_max = 128;
const token_segment_size_max = payload_size_max + Ed25519.Signature.encoded_length;
const private_key_base64_size = std.base64.standard.Encoder.calcSize(
    Ed25519.SecretKey.encoded_length,
);
const public_key_base64_size = std.base64.standard.Encoder.calcSize(
    Ed25519.PublicKey.encoded_length,
);
const paserk_public_prefix = "k4.public.";
const paserk_id_prefix = "k4.pid.";
const paserk_public_data_size = std.base64.url_safe_no_pad.Encoder.calcSize(
    Ed25519.PublicKey.encoded_length,
);
const paserk_id_data_size = std.base64.url_safe_no_pad.Encoder.calcSize(33);
const paserk_id_size = paserk_id_prefix.len + paserk_id_data_size;
const ascii_whitespace = " \t\r\n\x0b\x0c";

comptime {
    std.debug.assert(private_key_base64_size == 88);
    std.debug.assert(public_key_base64_size == 44);
    std.debug.assert(paserk_public_data_size == 43);
    std.debug.assert(paserk_id_data_size == 44);
    std.debug.assert(paserk_id_size == 51);
    std.debug.assert(token_segment_size_max < stdin_size_max);
}

const Command = union(enum) {
    help,
    keygen,
    issue: IssueOptions,
    verify,
};

const IssueOptions = struct {
    subject: []const u8,
    ttl_seconds: i64,
};

const Context = struct {
    allocator: Allocator,
    environment: *const std.process.Environ.Map,
    now: i64,
    random: std.Random,
    stdin: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

const Claims = struct {
    sub: []const u8,
    exp: i64,
};

const ParsedClaims = struct {
    sub: []const u8,
    exp: NumericDate,
};

const NumericDate = struct {
    value: i64,

    pub fn jsonParse(
        _: Allocator,
        source: anytype,
        _: std.json.ParseOptions,
    ) !NumericDate {
        const token = try source.next();
        const number = switch (token) {
            .number => |value| value,
            else => return error.UnexpectedToken,
        };
        if (!std.json.isNumberFormattedLikeAnInteger(number)) {
            return error.UnexpectedToken;
        }

        const value = std.fmt.parseInt(i64, number, 10) catch |err| {
            return switch (err) {
                error.InvalidCharacter => error.UnexpectedToken,
                error.Overflow => error.Overflow,
            };
        };
        return .{ .value = value };
    }
};

const Footer = struct {
    kid: []const u8,
};

const TokenParts = struct {
    signed: []const u8,
    footer: []const u8,
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
    \\
    \\Environment:
    \\  PASETO_PRIVATE_KEY  padded standard Base64 Ed25519 secret key for issue
    \\  PASETO_PUBLIC_KEY   padded standard Base64 Ed25519 public key for verify
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
    const command = parseCommand(arguments) catch {
        return finish(&stdout_file.interface, &stderr_file.interface, 2, .invocation);
    };

    var stdin_buffer: [stdin_size_max + 1]u8 = undefined;
    const stdin = readCommandInput(init.io, command, &stdin_buffer) catch |err| {
        const failure: Failure = if (err == error.InputTooLarge) .token else .internal;
        return finish(&stdout_file.interface, &stderr_file.interface, failure.code(), failure);
    };
    var random_source = std.Random.IoSource{ .io = init.io };
    const context = Context{
        .allocator = init.gpa,
        .environment = init.environ_map,
        .now = unixSeconds(init.io),
        .random = random_source.interface(),
        .stdin = stdin,
        .stdout = &stdout_file.interface,
        .stderr = &stderr_file.interface,
    };
    const exit_code = runCommand(command, context);
    return finish(&stdout_file.interface, &stderr_file.interface, exit_code, null);
}

const Failure = enum {
    invocation,
    key_configuration,
    token,
    internal,

    fn code(failure: Failure) u8 {
        return switch (failure) {
            .token => 1,
            .invocation, .key_configuration, .internal => 2,
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
    try validateSubject(subject.?);
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

fn runCommand(command: Command, context: Context) u8 {
    executeCommand(command, context) catch |err| {
        const failure: Failure = switch (err) {
            error.InvalidInvocation => .invocation,
            error.InvalidKeyConfiguration => .key_configuration,
            error.InvalidToken => .token,
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
    return runCommand(command, context);
}

fn executeCommand(command: Command, context: Context) !void {
    switch (command) {
        .help => try context.stdout.writeAll(usage),
        .keygen => try keygen(context),
        .issue => |options| try issue(options, context),
        .verify => try verify(context),
    }
}

fn keygen(context: Context) !void {
    var key_pair = try generateKeyPair(context.random);
    defer wipeSecretKey(&key_pair.secret_key);
    var private_base64: [private_key_base64_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &private_base64);
    var public_base64: [public_key_base64_size]u8 = undefined;
    var key_id: [paserk_id_size]u8 = undefined;
    const private = encodePrivateKey(key_pair.secret_key, &private_base64);
    const public = encodePublicKey(key_pair.public_key, &public_base64);
    const kid = paserkId(key_pair.public_key, &key_id);

    try context.stdout.print("PASETO_PRIVATE_KEY={s}\n", .{private});
    try context.stdout.print("PASETO_PUBLIC_KEY={s}\n", .{public});
    try context.stdout.print("PASETO_KEY_ID={s}\n", .{kid});
}

fn generateKeyPair(random: std.Random) CliError!Ed25519.KeyPair {
    const attempt_count_max = 8;
    var attempt: u8 = 0;
    while (attempt < attempt_count_max) : (attempt += 1) {
        var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
        defer std.crypto.secureZero(u8, &seed);
        random.bytes(&seed);
        const key_pair = Ed25519.KeyPair.generateDeterministic(seed) catch continue;
        std.debug.assert(key_pair.secret_key.toBytes().len == 64);
        std.debug.assert(key_pair.public_key.toBytes().len == 32);
        return key_pair;
    }
    return error.InternalFailure;
}

fn issue(options: IssueOptions, context: Context) !void {
    try validateSubject(options.subject);
    const expiration = std.math.add(
        i64,
        context.now,
        options.ttl_seconds,
    ) catch return error.InvalidInvocation;
    if (expiration <= context.now) return error.InvalidInvocation;

    const private_base64 = context.environment.get("PASETO_PRIVATE_KEY") orelse {
        return error.InvalidKeyConfiguration;
    };
    var secret_key = decodePrivateKey(private_base64) catch {
        return error.InvalidKeyConfiguration;
    };
    defer wipeSecretKey(&secret_key);
    const public_key = try publicKeyFromSecret(secret_key);
    var key_id: [paserk_id_size]u8 = undefined;
    const kid = paserkId(public_key, &key_id);

    var payload_buffer: [payload_size_max]u8 = undefined;
    const payload = try encodeClaims(.{
        .sub = options.subject,
        .exp = expiration,
    }, &payload_buffer);
    var footer_buffer: [footer_size_max]u8 = undefined;
    const footer = try encodeFooter(kid, &footer_buffer);

    const encoder = paseto.v4_public.V4Public.init(context.allocator);
    const signed = encoder.encode(
        context.random,
        payload,
        secret_key,
        footer,
        "",
    ) catch return error.InternalFailure;
    defer context.allocator.free(signed);

    try writeToken(context.stdout, signed, footer);
}

fn verify(context: Context) !void {
    const public_base64 = context.environment.get("PASETO_PUBLIC_KEY") orelse {
        return error.InvalidKeyConfiguration;
    };
    const public_key = decodePublicKey(public_base64) catch {
        return error.InvalidKeyConfiguration;
    };
    if (context.stdin.len > stdin_size_max) return error.InvalidToken;

    const token = std.mem.trim(u8, context.stdin, ascii_whitespace);
    if (token.len == 0) return error.InvalidToken;
    var signed_buffer: [stdin_size_max]u8 = undefined;
    var footer_buffer: [stdin_size_max]u8 = undefined;
    var canonical_buffer: [stdin_size_max]u8 = undefined;
    const parts = parseTokenInto(
        token,
        &signed_buffer,
        &footer_buffer,
        &canonical_buffer,
    ) catch return error.InvalidToken;

    const encoder = paseto.v4_public.V4Public.init(context.allocator);
    const payload = encoder.decode(
        parts.signed,
        public_key,
        parts.footer,
        "",
    ) catch return error.InvalidToken;
    defer context.allocator.free(payload);

    try verifyFooter(context.allocator, parts.footer, public_key);
    try verifyClaimsWrite(context.allocator, payload, context.now, context.stdout);
}

fn validateSubject(subject: []const u8) CliError!void {
    if (subject.len == 0) return error.InvalidInvocation;
    if (subject.len > subject_size_max) return error.InvalidInvocation;
    if (!std.unicode.utf8ValidateSlice(subject)) return error.InvalidInvocation;
    std.debug.assert(subject.len > 0);
    std.debug.assert(subject.len <= subject_size_max);
}

fn encodeClaims(claims: Claims, buffer: *[payload_size_max]u8) ![]const u8 {
    std.debug.assert(claims.sub.len > 0);
    std.debug.assert(claims.sub.len <= subject_size_max);
    var writer: std.Io.Writer = .fixed(buffer);
    try std.json.Stringify.value(claims, .{}, &writer);
    const payload = writer.buffered();
    std.debug.assert(payload.len > 0);
    std.debug.assert(payload.len <= buffer.len);
    return payload;
}

fn encodeFooter(kid: []const u8, buffer: *[footer_size_max]u8) ![]const u8 {
    std.debug.assert(kid.len == paserk_id_size);
    std.debug.assert(std.mem.startsWith(u8, kid, paserk_id_prefix));
    var writer: std.Io.Writer = .fixed(buffer);
    try std.json.Stringify.value(Footer{ .kid = kid }, .{}, &writer);
    const footer = writer.buffered();
    std.debug.assert(footer.len > kid.len);
    std.debug.assert(footer.len <= buffer.len);
    return footer;
}

fn writeToken(
    writer: *std.Io.Writer,
    signed: []const u8,
    footer: []const u8,
) !void {
    if (signed.len > token_segment_size_max) return error.InternalFailure;
    if (footer.len > footer_size_max) return error.InternalFailure;
    var signed_base64_buffer: [
        std.base64.url_safe_no_pad.Encoder.calcSize(
            token_segment_size_max,
        )
    ]u8 = undefined;
    var footer_base64_buffer: [
        std.base64.url_safe_no_pad.Encoder.calcSize(
            footer_size_max,
        )
    ]u8 = undefined;
    const signed_base64 = std.base64.url_safe_no_pad.Encoder.encode(
        &signed_base64_buffer,
        signed,
    );
    const footer_base64 = std.base64.url_safe_no_pad.Encoder.encode(
        &footer_base64_buffer,
        footer,
    );
    try writer.print("v4.public.{s}.{s}\n", .{ signed_base64, footer_base64 });
}

fn parseTokenInto(
    token: []const u8,
    signed_buffer: *[stdin_size_max]u8,
    footer_buffer: *[stdin_size_max]u8,
    canonical_buffer: *[stdin_size_max]u8,
) CliError!TokenParts {
    var iterator = std.mem.splitScalar(u8, token, '.');
    const version = iterator.next() orelse return error.InvalidToken;
    const purpose = iterator.next() orelse return error.InvalidToken;
    const signed_base64 = iterator.next() orelse return error.InvalidToken;
    const footer_base64 = iterator.next() orelse return error.InvalidToken;
    if (iterator.next() != null) return error.InvalidToken;
    if (!std.mem.eql(u8, version, "v4")) return error.InvalidToken;
    if (!std.mem.eql(u8, purpose, "public")) return error.InvalidToken;
    if (signed_base64.len == 0) return error.InvalidToken;
    if (footer_base64.len == 0) return error.InvalidToken;

    const signed = decodeBase64Url(
        signed_base64,
        signed_buffer,
        canonical_buffer,
    ) catch return error.InvalidToken;
    const footer = decodeBase64Url(
        footer_base64,
        footer_buffer,
        canonical_buffer,
    ) catch return error.InvalidToken;
    if (signed.len < Ed25519.Signature.encoded_length) return error.InvalidToken;
    std.debug.assert(signed.len <= signed_buffer.len);
    std.debug.assert(footer.len <= footer_buffer.len);
    return .{ .signed = signed, .footer = footer };
}

fn decodeBase64Url(
    input: []const u8,
    output: []u8,
    canonical: []u8,
) ![]const u8 {
    if (input.len == 0) return error.InvalidBase64;
    if (input.len > canonical.len) return error.InvalidBase64;
    const size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(input) catch {
        return error.InvalidBase64;
    };
    if (size > output.len) return error.InvalidBase64;
    std.base64.url_safe_no_pad.Decoder.decode(output[0..size], input) catch {
        return error.InvalidBase64;
    };
    const encoded = std.base64.url_safe_no_pad.Encoder.encode(
        canonical[0..input.len],
        output[0..size],
    );
    if (!std.mem.eql(u8, input, encoded)) return error.InvalidBase64;
    std.debug.assert(size <= output.len);
    std.debug.assert(encoded.len == input.len);
    return output[0..size];
}

fn verifyFooter(
    allocator: Allocator,
    footer_json: []const u8,
    public_key: Ed25519.PublicKey,
) CliError!void {
    var parsed = std.json.parseFromSlice(Footer, allocator, footer_json, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .max_value_len = footer_size_max,
        .allocate = .alloc_if_needed,
    }) catch return error.InvalidToken;
    defer parsed.deinit();

    var expected_buffer: [paserk_id_size]u8 = undefined;
    const expected = paserkId(public_key, &expected_buffer);
    if (!std.mem.eql(u8, parsed.value.kid, expected)) return error.InvalidToken;
    std.debug.assert(parsed.value.kid.len == paserk_id_size);
    std.debug.assert(std.mem.startsWith(u8, parsed.value.kid, paserk_id_prefix));
}

fn verifyClaimsWrite(
    allocator: Allocator,
    payload_json: []const u8,
    now: i64,
    writer: *std.Io.Writer,
) !void {
    var parsed = std.json.parseFromSlice(ParsedClaims, allocator, payload_json, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .max_value_len = stdin_size_max,
        .allocate = .alloc_if_needed,
    }) catch return error.InvalidToken;
    defer parsed.deinit();

    validateSubject(parsed.value.sub) catch return error.InvalidToken;
    if (now >= parsed.value.exp.value) return error.InvalidToken;
    const claims = Claims{
        .sub = parsed.value.sub,
        .exp = parsed.value.exp.value,
    };
    try std.json.Stringify.value(claims, .{}, writer);
    try writer.writeByte('\n');
}

fn encodePrivateKey(
    secret_key: Ed25519.SecretKey,
    buffer: *[private_key_base64_size]u8,
) []const u8 {
    var bytes = secret_key.toBytes();
    defer std.crypto.secureZero(u8, &bytes);
    const encoded = std.base64.standard.Encoder.encode(buffer, &bytes);
    std.debug.assert(encoded.len == private_key_base64_size);
    std.debug.assert(encoded.len == buffer.len);
    return encoded;
}

fn encodePublicKey(
    public_key: Ed25519.PublicKey,
    buffer: *[public_key_base64_size]u8,
) []const u8 {
    const bytes = public_key.toBytes();
    const encoded = std.base64.standard.Encoder.encode(buffer, &bytes);
    std.debug.assert(encoded.len == public_key_base64_size);
    std.debug.assert(encoded.len == buffer.len);
    return encoded;
}

fn decodePrivateKey(encoded: []const u8) !Ed25519.SecretKey {
    if (encoded.len != private_key_base64_size) return error.InvalidKey;
    var bytes: [Ed25519.SecretKey.encoded_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &bytes);
    std.base64.standard.Decoder.decode(&bytes, encoded) catch return error.InvalidKey;
    var canonical_buffer: [private_key_base64_size]u8 = undefined;
    const canonical = std.base64.standard.Encoder.encode(&canonical_buffer, &bytes);
    if (!std.mem.eql(u8, encoded, canonical)) return error.InvalidKey;

    var recomputed = Ed25519.KeyPair.generateDeterministic(
        bytes[0..Ed25519.KeyPair.seed_length].*,
    ) catch return error.InvalidKey;
    defer wipeSecretKey(&recomputed.secret_key);
    if (!std.mem.eql(
        u8,
        &recomputed.public_key.toBytes(),
        bytes[Ed25519.KeyPair.seed_length..],
    )) return error.InvalidKey;
    std.debug.assert(bytes.len == Ed25519.SecretKey.encoded_length);
    std.debug.assert(canonical.len == encoded.len);
    return Ed25519.SecretKey.fromBytes(bytes);
}

fn decodePublicKey(encoded: []const u8) !Ed25519.PublicKey {
    if (encoded.len != public_key_base64_size) return error.InvalidKey;
    var bytes: [Ed25519.PublicKey.encoded_length]u8 = undefined;
    std.base64.standard.Decoder.decode(&bytes, encoded) catch return error.InvalidKey;
    var canonical_buffer: [public_key_base64_size]u8 = undefined;
    const canonical = std.base64.standard.Encoder.encode(&canonical_buffer, &bytes);
    if (!std.mem.eql(u8, encoded, canonical)) return error.InvalidKey;
    std.debug.assert(bytes.len == Ed25519.PublicKey.encoded_length);
    std.debug.assert(canonical.len == encoded.len);
    return Ed25519.PublicKey.fromBytes(bytes);
}

fn publicKeyFromSecret(secret_key: Ed25519.SecretKey) CliError!Ed25519.PublicKey {
    var key_pair = Ed25519.KeyPair.fromSecretKey(secret_key) catch {
        return error.InvalidKeyConfiguration;
    };
    defer wipeSecretKey(&key_pair.secret_key);
    const public_bytes = secret_key.publicKeyBytes();
    if (!std.mem.eql(u8, &public_bytes, &key_pair.public_key.toBytes())) {
        return error.InvalidKeyConfiguration;
    }
    std.debug.assert(public_bytes.len == Ed25519.PublicKey.encoded_length);
    std.debug.assert(key_pair.secret_key.toBytes().len == Ed25519.SecretKey.encoded_length);
    return key_pair.public_key;
}

fn wipeSecretKey(secret_key: *Ed25519.SecretKey) void {
    std.debug.assert(secret_key.bytes.len == Ed25519.SecretKey.encoded_length);
    std.debug.assert(@sizeOf(Ed25519.SecretKey) == Ed25519.SecretKey.encoded_length);
    std.crypto.secureZero(u8, &secret_key.bytes);
}

fn paserkId(
    public_key: Ed25519.PublicKey,
    output: *[paserk_id_size]u8,
) []const u8 {
    var public_paserk: [paserk_public_prefix.len + paserk_public_data_size]u8 = undefined;
    @memcpy(public_paserk[0..paserk_public_prefix.len], paserk_public_prefix);
    const public_bytes = public_key.toBytes();
    _ = std.base64.url_safe_no_pad.Encoder.encode(
        public_paserk[paserk_public_prefix.len..],
        &public_bytes,
    );

    const Blake2b264 = std.crypto.hash.blake2.Blake2b(264);
    var hash = Blake2b264.init(.{});
    hash.update(paserk_id_prefix);
    hash.update(&public_paserk);
    var digest: [Blake2b264.digest_length]u8 = undefined;
    hash.final(&digest);

    @memcpy(output[0..paserk_id_prefix.len], paserk_id_prefix);
    _ = std.base64.url_safe_no_pad.Encoder.encode(
        output[paserk_id_prefix.len..],
        &digest,
    );
    std.debug.assert(output.len == paserk_id_size);
    std.debug.assert(std.mem.startsWith(u8, output, paserk_id_prefix));
    return output;
}

test "PASETO V4.local encodes and decodes message footer and implicit assertion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var encoder = paseto.V4Local.init(allocator);
    defer encoder.deinit();
    try encoder.withMessage(paseto_message);
    try encoder.withFooter(paseto_footer);
    try encoder.withImplicit(paseto_implicit);

    var random = std.Random.DefaultPrng.init(0x4c4f43414c);
    const token = try encoder.encode(random.random(), paseto_key);
    defer allocator.free(token);
    try std.testing.expect(std.mem.startsWith(u8, token, paseto_prefix));

    var decoder = paseto.V4Local.init(allocator);
    defer decoder.deinit();
    try decoder.withImplicit(paseto_implicit);
    try decoder.decode(token, paseto_key);
    try std.testing.expectEqualStrings(paseto_message, decoder.message);
    try std.testing.expectEqualStrings(paseto_footer, decoder.footer);
    try std.testing.expectEqualStrings(paseto_implicit, decoder.implicit);
}

test "PASETO V4.local rejects undersized and oversized symmetric keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var encoder = paseto.V4Local.init(allocator);
    defer encoder.deinit();
    var random = std.Random.DefaultPrng.init(0x4b455953);
    try std.testing.expectError(
        error.PasetoInvalidKeySize,
        encoder.encode(random.random(), paseto_key[0 .. paseto_key.len - 1]),
    );
    try std.testing.expectError(
        error.PasetoInvalidKeySize,
        encoder.encode(random.random(), paseto_key ++ "x"),
    );
}

test "PASETO V4.local rejects an authenticated token mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var encoder = paseto.V4Local.init(allocator);
    defer encoder.deinit();
    try encoder.withMessage(paseto_message);
    try encoder.withFooter(paseto_footer);
    try encoder.withImplicit(paseto_implicit);

    var random = std.Random.DefaultPrng.init(0x4d5554415445);
    const token = try encoder.encode(random.random(), paseto_key);
    defer allocator.free(token);
    const mutated_token = try allocator.dupe(u8, token);
    defer allocator.free(mutated_token);
    std.debug.assert(mutated_token.len > paseto_prefix.len);
    mutated_token[paseto_prefix.len] =
        if (mutated_token[paseto_prefix.len] == 'A') 'B' else 'A';

    var decoder = paseto.V4Local.init(allocator);
    defer decoder.deinit();
    try decoder.withImplicit(paseto_implicit);
    try std.testing.expectError(
        error.PasetoInvalidPreAuthenticationHeader,
        decoder.decode(mutated_token, paseto_key),
    );
}

test "PASETO V4.local rejects the wrong implicit assertion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var encoder = paseto.V4Local.init(allocator);
    defer encoder.deinit();
    try encoder.withMessage(paseto_message);
    try encoder.withFooter(paseto_footer);
    try encoder.withImplicit(paseto_implicit);

    var random = std.Random.DefaultPrng.init(0x494d504c49434954);
    const token = try encoder.encode(random.random(), paseto_key);
    defer allocator.free(token);

    var decoder = paseto.V4Local.init(allocator);
    defer decoder.deinit();
    try decoder.withImplicit("tenant=other");
    try std.testing.expectError(
        error.PasetoInvalidPreAuthenticationHeader,
        decoder.decode(token, paseto_key),
    );
}

test "PASERK k4.pid matches the official public key example" {
    const public_paserk_data = "cHFyc3R1dnd4eXp7fH1-f4CBgoOEhYaHiImKi4yNjo8";
    var public_bytes: [Ed25519.PublicKey.encoded_length]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&public_bytes, public_paserk_data);
    const public_key = try Ed25519.PublicKey.fromBytes(public_bytes);
    var buffer: [paserk_id_size]u8 = undefined;
    const actual = paserkId(public_key, &buffer);
    try std.testing.expectEqualStrings(
        "k4.pid.9ShR3xc8-qVJ_di0tc9nx0IDIqbatdeM2mqLFBJsKRHs",
        actual,
    );
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

    const private_encoded = private_line[private_prefix.len..];
    const public_encoded = public_line[public_prefix.len..];
    const secret_key = try decodePrivateKey(private_encoded);
    const public_key = try decodePublicKey(public_encoded);
    try std.testing.expectEqualSlices(
        u8,
        &secret_key.publicKeyBytes(),
        &public_key.toBytes(),
    );

    var expected_kid_buffer: [paserk_id_size]u8 = undefined;
    const expected_kid = paserkId(public_key, &expected_kid_buffer);
    try std.testing.expectEqualStrings(expected_kid, kid_line[kid_prefix.len..]);
}

test "private and public key decoding rejects malformed configuration" {
    const key_pair = testKeyPair(0x42);
    var private_buffer: [private_key_base64_size]u8 = undefined;
    var public_buffer: [public_key_base64_size]u8 = undefined;
    const private_encoded = encodePrivateKey(key_pair.secret_key, &private_buffer);
    const public_encoded = encodePublicKey(key_pair.public_key, &public_buffer);

    try std.testing.expectError(
        error.InvalidKey,
        decodePrivateKey(private_encoded[0 .. private_encoded.len - 1]),
    );
    try std.testing.expectError(
        error.InvalidKey,
        decodePublicKey(public_encoded[0 .. public_encoded.len - 1]),
    );
    private_buffer[0] = '!';
    public_buffer[0] = '!';
    try std.testing.expectError(error.InvalidKey, decodePrivateKey(&private_buffer));
    try std.testing.expectError(error.InvalidKey, decodePublicKey(&public_buffer));

    var mismatched_bytes = key_pair.secret_key.toBytes();
    mismatched_bytes[mismatched_bytes.len - 1] ^= 1;
    _ = std.base64.standard.Encoder.encode(&private_buffer, &mismatched_bytes);
    try std.testing.expectError(error.InvalidKey, decodePrivateKey(&private_buffer));
}

test "issue uses only the private key and verify uses only the public key" {
    const key_pair = testKeyPair(0x31);
    var issue_environment = std.process.Environ.Map.init(std.testing.allocator);
    defer issue_environment.deinit();
    try putPrivateKey(&issue_environment, key_pair.secret_key);

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

test "verify accepts surrounding whitespace and writes canonical claims" {
    const key_pair = testKeyPair(0x23);
    var footer_buffer: [footer_size_max]u8 = undefined;
    const footer = testFooter(key_pair.public_key, &footer_buffer);
    const token = try signTestToken(
        std.testing.allocator,
        key_pair.secret_key,
        "{\"exp\":1100,\"sub\":\"a\"}",
        footer,
    );
    defer std.testing.allocator.free(token);
    const input = try std.fmt.allocPrint(std.testing.allocator, " \t{s}\r\n", .{token});
    defer std.testing.allocator.free(input);

    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putPublicKey(&environment, key_pair.public_key);
    const result = runForTest(&.{ "paseto", "verify" }, input, &environment, 1000);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("{\"sub\":\"a\",\"exp\":1100}\n", result.stdout());
    try std.testing.expectEqualStrings("", result.stderr());
}

test "verify rejects wrong keys altered signatures and malformed structures" {
    const key_pair = testKeyPair(0x11);
    const wrong_key_pair = testKeyPair(0x12);
    var footer_buffer: [footer_size_max]u8 = undefined;
    const footer = testFooter(key_pair.public_key, &footer_buffer);
    const token = try signTestToken(
        std.testing.allocator,
        key_pair.secret_key,
        "{\"sub\":\"a\",\"exp\":1100}",
        footer,
    );
    defer std.testing.allocator.free(token);

    var wrong_environment = std.process.Environ.Map.init(std.testing.allocator);
    defer wrong_environment.deinit();
    try putPublicKey(&wrong_environment, wrong_key_pair.public_key);
    try expectTokenFailure(token, &wrong_environment, 1000);

    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putPublicKey(&environment, key_pair.public_key);
    const mutated = try std.testing.allocator.dupe(u8, token);
    defer std.testing.allocator.free(mutated);
    const mutation_index = "v4.public.".len;
    mutated[mutation_index] = if (mutated[mutation_index] == 'A') 'B' else 'A';
    try expectTokenFailure(mutated, &environment, 1000);

    const malformed = [_][]const u8{
        "",
        "v4.public.abc",
        "v4.public..abc",
        "v4.public.abc.",
        "v4.public.abc.def.extra",
        "v3.public.abc.def",
        "v4.local.abc.def",
        "v4.public.!.Zg",
        "v4.public.Zg.!",
        "first second",
    };
    for (malformed) |value| try expectTokenFailure(value, &environment, 1000);
}

test "verify rejects malformed missing incorrect and extra footer fields" {
    const key_pair = testKeyPair(0x52);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putPublicKey(&environment, key_pair.public_key);

    const footers = [_][]const u8{
        "{}",
        "{\"kid\":\"wrong\"}",
        "{\"kid\":1}",
        "{\"kid\":\"a\",\"kid\":\"b\"}",
        "{\"kid\":\"a\",\"extra\":true}",
        "not-json",
    };
    for (footers) |footer| {
        const token = try signTestToken(
            std.testing.allocator,
            key_pair.secret_key,
            "{\"sub\":\"a\",\"exp\":1100}",
            footer,
        );
        defer std.testing.allocator.free(token);
        try expectTokenFailure(token, &environment, 1000);
    }
}

test "verify rejects missing duplicate extra incorrectly typed and expired claims" {
    const key_pair = testKeyPair(0x62);
    var footer_buffer: [footer_size_max]u8 = undefined;
    const footer = testFooter(key_pair.public_key, &footer_buffer);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putPublicKey(&environment, key_pair.public_key);

    const invalid_payloads = [_][]const u8{
        "{}",
        "{\"exp\":1100}",
        "{\"sub\":\"a\"}",
        "{\"sub\":\"a\",\"sub\":\"b\",\"exp\":1100}",
        "{\"sub\":\"a\",\"exp\":1100,\"exp\":1200}",
        "{\"sub\":\"a\",\"exp\":1100,\"extra\":true}",
        "{\"sub\":1,\"exp\":1100}",
        "{\"sub\":\"a\",\"exp\":\"1100\"}",
        "{\"sub\":\"a\",\"exp\":1100.0}",
        "{\"sub\":\"a\",\"exp\":null}",
        "{\"sub\":\"\",\"exp\":1100}",
        "{\"sub\":\"a\",\"exp\":1000}",
        "{\"sub\":\"a\",\"exp\":999}",
        "{\"sub\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"exp\":1100}",
        "{\"sub\":\"ééééééééééééééééééééééééééééééééa\",\"exp\":1100}",
    };
    for (invalid_payloads) |payload| {
        const token = try signTestToken(
            std.testing.allocator,
            key_pair.secret_key,
            payload,
            footer,
        );
        defer std.testing.allocator.free(token);
        try expectTokenFailure(token, &environment, 1000);
    }
}

test "subject validation enforces UTF-8 byte boundaries" {
    const key_pair = testKeyPair(0x72);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putPrivateKey(&environment, key_pair.secret_key);

    const ascii_64 = "a" ** 64;
    const utf8_64 = "é" ** 32;
    const ascii_result = runForTest(
        &.{ "paseto", "issue", "--subject", ascii_64, "--ttl-seconds", "1" },
        "",
        &environment,
        1000,
    );
    try std.testing.expectEqual(@as(u8, 0), ascii_result.exit_code);
    const utf8_result = runForTest(
        &.{ "paseto", "issue", "--ttl-seconds", "1", "--subject", utf8_64 },
        "",
        &environment,
        1000,
    );
    try std.testing.expectEqual(@as(u8, 0), utf8_result.exit_code);

    var verify_environment = std.process.Environ.Map.init(std.testing.allocator);
    defer verify_environment.deinit();
    try putPublicKey(&verify_environment, key_pair.public_key);
    const ascii_verify = runForTest(
        &.{ "paseto", "verify" },
        ascii_result.stdout(),
        &verify_environment,
        1000,
    );
    try std.testing.expectEqual(@as(u8, 0), ascii_verify.exit_code);
    const utf8_verify = runForTest(
        &.{ "paseto", "verify" },
        utf8_result.stdout(),
        &verify_environment,
        1000,
    );
    try std.testing.expectEqual(@as(u8, 0), utf8_verify.exit_code);

    const invalid_subjects = [_][]const u8{
        "",
        "a" ** 65,
        ("é" ** 32) ++ "a",
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
    const key_pair = testKeyPair(0x73);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putPrivateKey(&environment, key_pair.secret_key);

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
    const key_pair = testKeyPair(0x74);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putPublicKey(&environment, key_pair.public_key);

    const oversized = "a" ** (stdin_size_max + 1);
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

    const key_pair = testKeyPair(0x75);
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

fn runForTest(
    arguments: []const []const u8,
    stdin: []const u8,
    environment: *const std.process.Environ.Map,
    now: i64,
) TestResult {
    var result: TestResult = undefined;
    var stdout: std.Io.Writer = .fixed(&result.stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&result.stderr_buffer);
    var prng = std.Random.DefaultPrng.init(0x5445535453454544);
    result.exit_code = runArguments(arguments, .{
        .allocator = std.testing.allocator,
        .environment = environment,
        .now = now,
        .random = prng.random(),
        .stdin = stdin,
        .stdout = &stdout,
        .stderr = &stderr,
    });
    result.stdout_size = stdout.buffered().len;
    result.stderr_size = stderr.buffered().len;
    std.debug.assert(result.stdout_size <= result.stdout_buffer.len);
    std.debug.assert(result.stderr_size <= result.stderr_buffer.len);
    return result;
}

fn testKeyPair(seed_byte: u8) Ed25519.KeyPair {
    const seed = [_]u8{seed_byte} ** Ed25519.KeyPair.seed_length;
    const key_pair = Ed25519.KeyPair.generateDeterministic(seed) catch unreachable;
    std.debug.assert(key_pair.secret_key.toBytes().len == Ed25519.SecretKey.encoded_length);
    std.debug.assert(key_pair.public_key.toBytes().len == Ed25519.PublicKey.encoded_length);
    return key_pair;
}

fn putPrivateKey(
    environment: *std.process.Environ.Map,
    secret_key: Ed25519.SecretKey,
) !void {
    var buffer: [private_key_base64_size]u8 = undefined;
    const encoded = encodePrivateKey(secret_key, &buffer);
    try environment.put("PASETO_PRIVATE_KEY", encoded);
    std.debug.assert(environment.get("PASETO_PRIVATE_KEY") != null);
    std.debug.assert(environment.get("PASETO_PUBLIC_KEY") == null);
}

fn putPublicKey(
    environment: *std.process.Environ.Map,
    public_key: Ed25519.PublicKey,
) !void {
    var buffer: [public_key_base64_size]u8 = undefined;
    const encoded = encodePublicKey(public_key, &buffer);
    try environment.put("PASETO_PUBLIC_KEY", encoded);
    std.debug.assert(environment.get("PASETO_PUBLIC_KEY") != null);
    std.debug.assert(encoded.len == public_key_base64_size);
}

fn testFooter(
    public_key: Ed25519.PublicKey,
    buffer: *[footer_size_max]u8,
) []const u8 {
    var kid_buffer: [paserk_id_size]u8 = undefined;
    const kid = paserkId(public_key, &kid_buffer);
    const footer = encodeFooter(kid, buffer) catch unreachable;
    std.debug.assert(footer.len > kid.len);
    std.debug.assert(footer.len <= footer_size_max);
    return footer;
}

fn signTestToken(
    allocator: Allocator,
    secret_key: Ed25519.SecretKey,
    payload: []const u8,
    footer: []const u8,
) ![]u8 {
    var prng = std.Random.DefaultPrng.init(0x5349474e54455354);
    const encoder = paseto.v4_public.V4Public.init(allocator);
    const signed = try encoder.encode(
        prng.random(),
        payload,
        secret_key,
        footer,
        "",
    );
    defer allocator.free(signed);

    var token_buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&token_buffer);
    try writeToken(&writer, signed, footer);
    const token = std.mem.trimEnd(u8, writer.buffered(), "\n");
    std.debug.assert(token.len > "v4.public.".len);
    std.debug.assert(token.len < token_buffer.len);
    return allocator.dupe(u8, token);
}

fn expectTokenFailure(
    token: []const u8,
    environment: *const std.process.Environ.Map,
    now: i64,
) !void {
    const result = runForTest(&.{ "paseto", "verify" }, token, environment, now);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("", result.stdout());
    try std.testing.expectEqualStrings(
        "paseto: token verification failed\n",
        result.stderr(),
    );
}

const paseto_prefix = "v4.local.";
const paseto_key = "0123456789abcdef0123456789abcdef";
const paseto_message = "zig-paseto compatibility";
const paseto_footer = "kid=integration-test";
const paseto_implicit = "tenant=aws-lambda-zig-demo";
