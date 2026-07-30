const std = @import("std");
const implementation = @import("zig-paseto");

const Allocator = std.mem.Allocator;

pub const Ed25519 = implementation.Ed25519;
pub const subject_size_max = 64;
pub const payload_size_max = 512;
pub const footer_size_max = 128;
pub const token_size_max = 16 * 1024;
pub const token_segment_size_max = payload_size_max + Ed25519.Signature.encoded_length;
pub const private_key_base64_size = std.base64.standard.Encoder.calcSize(
    Ed25519.SecretKey.encoded_length,
);
pub const public_key_base64_size = std.base64.standard.Encoder.calcSize(
    Ed25519.PublicKey.encoded_length,
);
const paserk_public_prefix = "k4.public.";
const paserk_id_prefix = "k4.pid.";
const paserk_public_data_size = std.base64.url_safe_no_pad.Encoder.calcSize(
    Ed25519.PublicKey.encoded_length,
);
const paserk_id_data_size = std.base64.url_safe_no_pad.Encoder.calcSize(33);
pub const paserk_id_size = paserk_id_prefix.len + paserk_id_data_size;
const ascii_whitespace = " \t\r\n\x0b\x0c";

comptime {
    std.debug.assert(private_key_base64_size == 88);
    std.debug.assert(public_key_base64_size == 44);
    std.debug.assert(paserk_public_data_size == 43);
    std.debug.assert(paserk_id_data_size == 44);
    std.debug.assert(paserk_id_size == 51);
    std.debug.assert(token_segment_size_max < token_size_max);
}

pub const Error = error{
    InvalidKey,
    InvalidSubject,
    InvalidToken,
    InvalidTtl,
    InternalFailure,
};

pub const IssueOptions = struct {
    subject: []const u8,
    now: i64,
    ttl_seconds: i64,
};

pub const Claims = struct {
    sub: []u8,
    exp: i64,
    allocator: Allocator,

    pub fn deinit(claims: *Claims) void {
        std.debug.assert(claims.sub.len > 0);
        std.debug.assert(claims.sub.len <= subject_size_max);
        claims.allocator.free(claims.sub);
        claims.* = undefined;
    }
};

const ClaimsJson = struct {
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

pub fn generateKeyPair(
    random: std.Random,
    key_pair: *Ed25519.KeyPair,
) Error!void {
    const attempt_count_max = 8;
    var attempt: u8 = 0;
    while (attempt < attempt_count_max) : (attempt += 1) {
        var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
        defer std.crypto.secureZero(u8, &seed);
        random.bytes(&seed);
        key_pair.* = Ed25519.KeyPair.generateDeterministic(seed) catch continue;
        std.debug.assert(key_pair.secret_key.toBytes().len == 64);
        std.debug.assert(key_pair.public_key.toBytes().len == 32);
        return;
    }
    return error.InternalFailure;
}

pub fn issue(
    allocator: Allocator,
    random: std.Random,
    secret_key: *const Ed25519.SecretKey,
    options: IssueOptions,
) Error![]u8 {
    try validateSubject(options.subject);
    if (options.ttl_seconds <= 0) return error.InvalidTtl;
    const expiration = std.math.add(
        i64,
        options.now,
        options.ttl_seconds,
    ) catch return error.InvalidTtl;
    if (expiration <= options.now) return error.InvalidTtl;

    const public_key = try publicKeyFromSecret(secret_key);
    var key_id: [paserk_id_size]u8 = undefined;
    const kid = paserkId(public_key, &key_id);
    var payload_buffer: [payload_size_max]u8 = undefined;
    const payload = encodeClaims(.{
        .sub = options.subject,
        .exp = expiration,
    }, &payload_buffer) catch return error.InternalFailure;
    var footer_buffer: [footer_size_max]u8 = undefined;
    const footer = encodeFooter(kid, &footer_buffer) catch return error.InternalFailure;

    const encoder = implementation.v4_public.V4Public.init(allocator);
    const signed = encoder.encode(
        random,
        payload,
        secret_key.*,
        footer,
        "",
    ) catch return error.InternalFailure;
    defer allocator.free(signed);

    return encodeToken(allocator, signed, footer);
}

pub fn verify(
    allocator: Allocator,
    token_input: []const u8,
    public_key: Ed25519.PublicKey,
    now: i64,
) Error!Claims {
    if (token_input.len > token_size_max) return error.InvalidToken;
    const token = std.mem.trim(u8, token_input, ascii_whitespace);
    if (token.len == 0) return error.InvalidToken;

    var signed_buffer: [token_segment_size_max]u8 = undefined;
    var footer_buffer: [footer_size_max]u8 = undefined;
    var canonical_buffer: [token_size_max]u8 = undefined;
    const parts = try parseTokenInto(
        token,
        &signed_buffer,
        &footer_buffer,
        &canonical_buffer,
    );

    const encoder = implementation.v4_public.V4Public.init(allocator);
    const payload = encoder.decode(
        parts.signed,
        public_key,
        parts.footer,
        "",
    ) catch |err| return operationError(err);
    defer allocator.free(payload);

    try verifyFooter(allocator, parts.footer, public_key);
    return verifyClaims(allocator, payload, now);
}

pub fn writeClaims(writer: *std.Io.Writer, claims: *const Claims) !void {
    std.debug.assert(claims.sub.len > 0);
    std.debug.assert(claims.sub.len <= subject_size_max);
    try std.json.Stringify.value(ClaimsJson{
        .sub = claims.sub,
        .exp = claims.exp,
    }, .{}, writer);
    try writer.writeByte('\n');
}

pub fn validateSubject(subject: []const u8) Error!void {
    if (subject.len == 0) return error.InvalidSubject;
    if (subject.len > subject_size_max) return error.InvalidSubject;
    if (!std.unicode.utf8ValidateSlice(subject)) return error.InvalidSubject;
    std.debug.assert(subject.len > 0);
    std.debug.assert(subject.len <= subject_size_max);
}

pub fn encodePrivateKey(
    secret_key: *const Ed25519.SecretKey,
    buffer: *[private_key_base64_size]u8,
) []const u8 {
    var bytes = secret_key.toBytes();
    defer std.crypto.secureZero(u8, &bytes);
    const encoded = std.base64.standard.Encoder.encode(buffer, &bytes);
    std.debug.assert(encoded.len == private_key_base64_size);
    std.debug.assert(encoded.len == buffer.len);
    return encoded;
}

pub fn encodePublicKey(
    public_key: Ed25519.PublicKey,
    buffer: *[public_key_base64_size]u8,
) []const u8 {
    const bytes = public_key.toBytes();
    const encoded = std.base64.standard.Encoder.encode(buffer, &bytes);
    std.debug.assert(encoded.len == public_key_base64_size);
    std.debug.assert(encoded.len == buffer.len);
    return encoded;
}

pub fn decodePrivateKey(encoded: []const u8) Error!Ed25519.SecretKey {
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

pub fn decodePublicKey(encoded: []const u8) Error!Ed25519.PublicKey {
    if (encoded.len != public_key_base64_size) return error.InvalidKey;
    var bytes: [Ed25519.PublicKey.encoded_length]u8 = undefined;
    std.base64.standard.Decoder.decode(&bytes, encoded) catch return error.InvalidKey;
    var canonical_buffer: [public_key_base64_size]u8 = undefined;
    const canonical = std.base64.standard.Encoder.encode(&canonical_buffer, &bytes);
    if (!std.mem.eql(u8, encoded, canonical)) return error.InvalidKey;
    std.debug.assert(bytes.len == Ed25519.PublicKey.encoded_length);
    std.debug.assert(canonical.len == encoded.len);
    return Ed25519.PublicKey.fromBytes(bytes) catch return error.InvalidKey;
}

pub fn publicKeyFromSecret(
    secret_key: *const Ed25519.SecretKey,
) Error!Ed25519.PublicKey {
    var key_pair = Ed25519.KeyPair.fromSecretKey(secret_key.*) catch {
        return error.InvalidKey;
    };
    defer wipeSecretKey(&key_pair.secret_key);
    const public_bytes = secret_key.publicKeyBytes();
    if (!std.mem.eql(u8, &public_bytes, &key_pair.public_key.toBytes())) {
        return error.InvalidKey;
    }
    std.debug.assert(public_bytes.len == Ed25519.PublicKey.encoded_length);
    std.debug.assert(key_pair.secret_key.toBytes().len == Ed25519.SecretKey.encoded_length);
    return key_pair.public_key;
}

pub fn wipeSecretKey(secret_key: *Ed25519.SecretKey) void {
    std.debug.assert(secret_key.bytes.len == Ed25519.SecretKey.encoded_length);
    std.debug.assert(@sizeOf(Ed25519.SecretKey) == Ed25519.SecretKey.encoded_length);
    std.crypto.secureZero(u8, &secret_key.bytes);
}

pub fn paserkId(
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

fn encodeClaims(
    claims: ClaimsJson,
    buffer: *[payload_size_max]u8,
) ![]const u8 {
    std.debug.assert(claims.sub.len > 0);
    std.debug.assert(claims.sub.len <= subject_size_max);
    var writer: std.Io.Writer = .fixed(buffer);
    try std.json.Stringify.value(claims, .{}, &writer);
    const payload = writer.buffered();
    std.debug.assert(payload.len > 0);
    std.debug.assert(payload.len <= buffer.len);
    return payload;
}

fn encodeFooter(
    kid: []const u8,
    buffer: *[footer_size_max]u8,
) ![]const u8 {
    std.debug.assert(kid.len == paserk_id_size);
    std.debug.assert(std.mem.startsWith(u8, kid, paserk_id_prefix));
    var writer: std.Io.Writer = .fixed(buffer);
    try std.json.Stringify.value(Footer{ .kid = kid }, .{}, &writer);
    const footer = writer.buffered();
    std.debug.assert(footer.len > kid.len);
    std.debug.assert(footer.len <= buffer.len);
    return footer;
}

fn encodeToken(
    allocator: Allocator,
    signed: []const u8,
    footer: []const u8,
) Error![]u8 {
    if (signed.len > token_segment_size_max) return error.InternalFailure;
    if (footer.len > footer_size_max) return error.InternalFailure;
    const signed_size = std.base64.url_safe_no_pad.Encoder.calcSize(signed.len);
    const footer_size = std.base64.url_safe_no_pad.Encoder.calcSize(footer.len);
    const token_size = "v4.public.".len + signed_size + 1 + footer_size;
    if (token_size > token_size_max) return error.InternalFailure;

    const token = allocator.alloc(u8, token_size) catch return error.InternalFailure;
    errdefer allocator.free(token);
    const prefix = "v4.public.";
    @memcpy(token[0..prefix.len], prefix);
    const signed_start = prefix.len;
    const signed_end = signed_start + signed_size;
    _ = std.base64.url_safe_no_pad.Encoder.encode(
        token[signed_start..signed_end],
        signed,
    );
    token[signed_end] = '.';
    const footer_start = signed_end + 1;
    _ = std.base64.url_safe_no_pad.Encoder.encode(token[footer_start..], footer);
    std.debug.assert(footer_start + footer_size == token.len);
    return token;
}

fn parseTokenInto(
    token: []const u8,
    signed_buffer: *[token_segment_size_max]u8,
    footer_buffer: *[footer_size_max]u8,
    canonical_buffer: *[token_size_max]u8,
) Error!TokenParts {
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
) Error!void {
    var parsed = std.json.parseFromSlice(Footer, allocator, footer_json, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .max_value_len = footer_size_max,
        .allocate = .alloc_if_needed,
    }) catch |err| return operationError(err);
    defer parsed.deinit();

    var expected_buffer: [paserk_id_size]u8 = undefined;
    const expected = paserkId(public_key, &expected_buffer);
    if (!std.mem.eql(u8, parsed.value.kid, expected)) return error.InvalidToken;
    std.debug.assert(parsed.value.kid.len == paserk_id_size);
    std.debug.assert(std.mem.startsWith(u8, parsed.value.kid, paserk_id_prefix));
}

fn verifyClaims(
    allocator: Allocator,
    payload_json: []const u8,
    now: i64,
) Error!Claims {
    if (payload_json.len > payload_size_max) return error.InvalidToken;
    var parsed = std.json.parseFromSlice(ParsedClaims, allocator, payload_json, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .max_value_len = payload_size_max,
        .allocate = .alloc_if_needed,
    }) catch |err| return operationError(err);
    defer parsed.deinit();

    validateSubject(parsed.value.sub) catch return error.InvalidToken;
    if (now >= parsed.value.exp.value) return error.InvalidToken;
    const subject = allocator.dupe(u8, parsed.value.sub) catch {
        return error.InternalFailure;
    };
    std.debug.assert(subject.len > 0);
    std.debug.assert(subject.len <= subject_size_max);
    return .{
        .sub = subject,
        .exp = parsed.value.exp.value,
        .allocator = allocator,
    };
}

fn operationError(err: anyerror) Error {
    if (err == error.OutOfMemory) return error.InternalFailure;
    return error.InvalidToken;
}

test "key generation encoding decoding and wiping preserve matching material" {
    var random = std.Random.DefaultPrng.init(0x4b455947454e);
    var key_pair: Ed25519.KeyPair = undefined;
    try generateKeyPair(random.random(), &key_pair);
    defer wipeSecretKey(&key_pair.secret_key);

    var private_buffer: [private_key_base64_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &private_buffer);
    var public_buffer: [public_key_base64_size]u8 = undefined;
    const private_encoded = encodePrivateKey(&key_pair.secret_key, &private_buffer);
    const public_encoded = encodePublicKey(key_pair.public_key, &public_buffer);
    var secret_key = try decodePrivateKey(private_encoded);
    defer wipeSecretKey(&secret_key);
    const public_key = try decodePublicKey(public_encoded);

    try std.testing.expectEqualSlices(
        u8,
        &secret_key.publicKeyBytes(),
        &public_key.toBytes(),
    );
    wipeSecretKey(&secret_key);
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0} ** Ed25519.SecretKey.encoded_length),
        &secret_key.bytes,
    );
}

test "private and public key decoding rejects malformed configuration" {
    var key_pair = testKeyPair(0x42);
    defer wipeSecretKey(&key_pair.secret_key);
    var private_buffer: [private_key_base64_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &private_buffer);
    var public_buffer: [public_key_base64_size]u8 = undefined;
    const private_encoded = encodePrivateKey(&key_pair.secret_key, &private_buffer);
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
    defer std.crypto.secureZero(u8, &mismatched_bytes);
    mismatched_bytes[mismatched_bytes.len - 1] ^= 1;
    _ = std.base64.standard.Encoder.encode(&private_buffer, &mismatched_bytes);
    try std.testing.expectError(error.InvalidKey, decodePrivateKey(&private_buffer));
}

test "v4.public issuance and verification return validated claims" {
    var key_pair = testKeyPair(0x31);
    defer wipeSecretKey(&key_pair.secret_key);
    var random = std.Random.DefaultPrng.init(0x4953535545);
    const token = try issue(
        std.testing.allocator,
        random.random(),
        &key_pair.secret_key,
        .{
            .subject = "alice",
            .now = 1000,
            .ttl_seconds = 60,
        },
    );
    defer std.testing.allocator.free(token);
    try std.testing.expect(std.mem.startsWith(u8, token, "v4.public."));

    var claims = try verify(
        std.testing.allocator,
        token,
        key_pair.public_key,
        1000,
    );
    defer claims.deinit();
    try std.testing.expectEqualStrings("alice", claims.sub);
    try std.testing.expectEqual(@as(i64, 1060), claims.exp);
}

test "v4.public verification accepts whitespace and rejects expired tokens" {
    var key_pair = testKeyPair(0x23);
    defer wipeSecretKey(&key_pair.secret_key);
    var random = std.Random.DefaultPrng.init(0x5748495445);
    const token = try issue(
        std.testing.allocator,
        random.random(),
        &key_pair.secret_key,
        .{
            .subject = "a",
            .now = 1000,
            .ttl_seconds = 100,
        },
    );
    defer std.testing.allocator.free(token);
    const whitespace_token = try std.fmt.allocPrint(
        std.testing.allocator,
        " \t{s}\r\n",
        .{token},
    );
    defer std.testing.allocator.free(whitespace_token);

    var claims = try verify(
        std.testing.allocator,
        whitespace_token,
        key_pair.public_key,
        1099,
    );
    claims.deinit();
    try std.testing.expectError(
        error.InvalidToken,
        verify(std.testing.allocator, token, key_pair.public_key, 1100),
    );
}

test "v4.public verification rejects wrong keys signatures and token structures" {
    var key_pair = testKeyPair(0x11);
    defer wipeSecretKey(&key_pair.secret_key);
    var wrong_key_pair = testKeyPair(0x12);
    defer wipeSecretKey(&wrong_key_pair.secret_key);
    const token = try testIssue(&key_pair, "a", 1000, 100);
    defer std.testing.allocator.free(token);

    try std.testing.expectError(
        error.InvalidToken,
        verify(std.testing.allocator, token, wrong_key_pair.public_key, 1000),
    );
    const mutated = try std.testing.allocator.dupe(u8, token);
    defer std.testing.allocator.free(mutated);
    const mutation_index = "v4.public.".len;
    mutated[mutation_index] = if (mutated[mutation_index] == 'A') 'B' else 'A';
    try std.testing.expectError(
        error.InvalidToken,
        verify(std.testing.allocator, mutated, key_pair.public_key, 1000),
    );

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
    for (malformed) |value| {
        try std.testing.expectError(
            error.InvalidToken,
            verify(std.testing.allocator, value, key_pair.public_key, 1000),
        );
    }
}

test "v4.public verification rejects invalid footers" {
    var key_pair = testKeyPair(0x52);
    defer wipeSecretKey(&key_pair.secret_key);
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
            &key_pair,
            "{\"sub\":\"a\",\"exp\":1100}",
            footer,
        );
        defer std.testing.allocator.free(token);
        try std.testing.expectError(
            error.InvalidToken,
            verify(std.testing.allocator, token, key_pair.public_key, 1000),
        );
    }
}

test "v4.public verification rejects invalid claims" {
    var key_pair = testKeyPair(0x62);
    defer wipeSecretKey(&key_pair.secret_key);
    var footer_buffer: [footer_size_max]u8 = undefined;
    const footer = testFooter(key_pair.public_key, &footer_buffer);
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
        "{\"sub\":\"" ++ ("a" ** 65) ++ "\",\"exp\":1100}",
        "{\"sub\":\"" ++ (("é" ** 32) ++ "a") ++ "\",\"exp\":1100}",
    };
    for (invalid_payloads) |payload| {
        const token = try signTestToken(&key_pair, payload, footer);
        defer std.testing.allocator.free(token);
        try std.testing.expectError(
            error.InvalidToken,
            verify(std.testing.allocator, token, key_pair.public_key, 1000),
        );
    }
}

test "subject TTL and token bounds are enforced" {
    const valid_subjects = [_][]const u8{
        "a" ** subject_size_max,
        "é" ** (subject_size_max / 2),
    };
    for (valid_subjects) |subject| try validateSubject(subject);
    const invalid_subjects = [_][]const u8{
        "",
        "a" ** (subject_size_max + 1),
        ("é" ** (subject_size_max / 2)) ++ "a",
        "\xff",
    };
    for (invalid_subjects) |subject| {
        try std.testing.expectError(error.InvalidSubject, validateSubject(subject));
    }

    var key_pair = testKeyPair(0x74);
    defer wipeSecretKey(&key_pair.secret_key);
    var random = std.Random.DefaultPrng.init(0x424f554e4453);
    try std.testing.expectError(
        error.InvalidTtl,
        issue(
            std.testing.allocator,
            random.random(),
            &key_pair.secret_key,
            .{ .subject = "a", .now = 1, .ttl_seconds = 0 },
        ),
    );
    try std.testing.expectError(
        error.InvalidTtl,
        issue(
            std.testing.allocator,
            random.random(),
            &key_pair.secret_key,
            .{
                .subject = "a",
                .now = 1,
                .ttl_seconds = std.math.maxInt(i64),
            },
        ),
    );
    try std.testing.expectError(
        error.InvalidToken,
        verify(
            std.testing.allocator,
            "a" ** (token_size_max + 1),
            key_pair.public_key,
            1000,
        ),
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

test "PASETO V4.local dependency compatibility" {
    const key = "0123456789abcdef0123456789abcdef";
    const message = "zig-paseto compatibility";
    const footer = "kid=integration-test";
    const implicit = "tenant=aws-lambda-zig-demo";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var encoder = implementation.V4Local.init(allocator);
    defer encoder.deinit();
    try encoder.withMessage(message);
    try encoder.withFooter(footer);
    try encoder.withImplicit(implicit);

    var random = std.Random.DefaultPrng.init(0x4c4f43414c);
    const token = try encoder.encode(random.random(), key);
    defer allocator.free(token);
    try std.testing.expect(std.mem.startsWith(u8, token, "v4.local."));

    var decoder = implementation.V4Local.init(allocator);
    defer decoder.deinit();
    try decoder.withImplicit(implicit);
    try decoder.decode(token, key);
    try std.testing.expectEqualStrings(message, decoder.message);
    try std.testing.expectEqualStrings(footer, decoder.footer);
    try std.testing.expectEqualStrings(implicit, decoder.implicit);
}

test "PASETO V4.local rejects invalid key sizes" {
    const key = "0123456789abcdef0123456789abcdef";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var encoder = implementation.V4Local.init(allocator);
    defer encoder.deinit();
    var random = std.Random.DefaultPrng.init(0x4b455953);
    try std.testing.expectError(
        error.PasetoInvalidKeySize,
        encoder.encode(random.random(), key[0 .. key.len - 1]),
    );
    try std.testing.expectError(
        error.PasetoInvalidKeySize,
        encoder.encode(random.random(), key ++ "x"),
    );
}

test "PASETO V4.local rejects authenticated mutations" {
    const key = "0123456789abcdef0123456789abcdef";
    const implicit = "tenant=aws-lambda-zig-demo";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var encoder = implementation.V4Local.init(allocator);
    defer encoder.deinit();
    try encoder.withMessage("zig-paseto compatibility");
    try encoder.withImplicit(implicit);
    var random = std.Random.DefaultPrng.init(0x4d5554415445);
    const token = try encoder.encode(random.random(), key);
    defer allocator.free(token);
    const mutated = try allocator.dupe(u8, token);
    defer allocator.free(mutated);
    mutated["v4.local.".len] = if (mutated["v4.local.".len] == 'A') 'B' else 'A';

    var decoder = implementation.V4Local.init(allocator);
    defer decoder.deinit();
    try decoder.withImplicit(implicit);
    try std.testing.expectError(
        error.PasetoInvalidPreAuthenticationHeader,
        decoder.decode(mutated, key),
    );
}

test "PASETO V4.local rejects the wrong implicit assertion" {
    const key = "0123456789abcdef0123456789abcdef";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var encoder = implementation.V4Local.init(allocator);
    defer encoder.deinit();
    try encoder.withMessage("zig-paseto compatibility");
    try encoder.withImplicit("tenant=aws-lambda-zig-demo");
    var random = std.Random.DefaultPrng.init(0x494d504c49434954);
    const token = try encoder.encode(random.random(), key);
    defer allocator.free(token);

    var decoder = implementation.V4Local.init(allocator);
    defer decoder.deinit();
    try decoder.withImplicit("tenant=other");
    try std.testing.expectError(
        error.PasetoInvalidPreAuthenticationHeader,
        decoder.decode(token, key),
    );
}

fn testKeyPair(seed_byte: u8) Ed25519.KeyPair {
    const seed = [_]u8{seed_byte} ** Ed25519.KeyPair.seed_length;
    const key_pair = Ed25519.KeyPair.generateDeterministic(seed) catch unreachable;
    std.debug.assert(key_pair.secret_key.toBytes().len == Ed25519.SecretKey.encoded_length);
    std.debug.assert(key_pair.public_key.toBytes().len == Ed25519.PublicKey.encoded_length);
    return key_pair;
}

fn testIssue(
    key_pair: *const Ed25519.KeyPair,
    subject: []const u8,
    now: i64,
    ttl_seconds: i64,
) ![]u8 {
    var random = std.Random.DefaultPrng.init(0x5445535449535355);
    return issue(
        std.testing.allocator,
        random.random(),
        &key_pair.secret_key,
        .{
            .subject = subject,
            .now = now,
            .ttl_seconds = ttl_seconds,
        },
    );
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
    key_pair: *const Ed25519.KeyPair,
    payload: []const u8,
    footer: []const u8,
) ![]u8 {
    var random = std.Random.DefaultPrng.init(0x5349474e54455354);
    const encoder = implementation.v4_public.V4Public.init(std.testing.allocator);
    const signed = try encoder.encode(
        random.random(),
        payload,
        key_pair.secret_key,
        footer,
        "",
    );
    defer std.testing.allocator.free(signed);
    return encodeToken(std.testing.allocator, signed, footer);
}
