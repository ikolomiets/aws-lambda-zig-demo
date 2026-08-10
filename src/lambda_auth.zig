const std = @import("std");
const lambda = @import("aws-lambda");
const paseto = @import("paseto");

const authorization_header_count_max = 256;

pub const Error = error{
    InternalFailure,
    Unauthorized,
};

pub fn authenticate(
    allocator: std.mem.Allocator,
    request: *const lambda.url.Request,
    environment: *const std.process.Environ.Map,
    now: i64,
) Error!paseto.Claims {
    const token = bearerToken(request) catch return error.Unauthorized;
    const public_key_encoded = environment.get("PASETO_PUBLIC_KEY") orelse {
        return error.InternalFailure;
    };
    const public_key = paseto.decodePublicKey(public_key_encoded) catch {
        return error.InternalFailure;
    };
    return paseto.verify(allocator, token, public_key, now) catch |err| {
        return switch (err) {
            error.InvalidToken => error.Unauthorized,
            else => error.InternalFailure,
        };
    };
}

fn bearerToken(request: *const lambda.url.Request) error{InvalidCredentials}![]const u8 {
    if (request.headers.len > authorization_header_count_max) {
        return error.InvalidCredentials;
    }

    var authorization: ?[]const u8 = null;
    for (request.headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.key, "Authorization")) continue;
        if (authorization != null) return error.InvalidCredentials;
        authorization = header.value;
    }
    const value = authorization orelse return error.InvalidCredentials;
    const scheme = "Bearer";
    if (value.len <= scheme.len) return error.InvalidCredentials;
    if (!std.ascii.eqlIgnoreCase(value[0..scheme.len], scheme)) {
        return error.InvalidCredentials;
    }

    var token_start = scheme.len;
    if (value[token_start] != ' ') return error.InvalidCredentials;
    while (token_start < value.len) : (token_start += 1) {
        if (value[token_start] != ' ') break;
    }
    if (token_start == value.len) return error.InvalidCredentials;
    const token = value[token_start..];
    if (token.len > paseto.token_size_max) return error.InvalidCredentials;
    if (std.mem.indexOfAny(u8, token, " \t\r\n") != null) {
        return error.InvalidCredentials;
    }
    std.debug.assert(token.len > 0);
    std.debug.assert(token.len <= paseto.token_size_max);
    return token;
}

test "valid bearer token authenticates its subject" {
    var key_pair = testKeyPair(0x41);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    const token = try testToken(&key_pair, 1000, 60);
    defer std.testing.allocator.free(token);

    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putTestPublicKey(&environment, key_pair.public_key);

    const event = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"headers\":{{\"Authorization\":\"Bearer {s}\"}}}}",
        .{token},
    );
    defer std.testing.allocator.free(event);
    const request = try lambda.url.parseRequest(std.testing.allocator, event);
    defer request.deinit(std.testing.allocator);

    var claims = try authenticate(
        std.testing.allocator,
        &request,
        &environment,
        1000,
    );
    defer claims.deinit();
    try std.testing.expectEqualStrings("lambda-test-user", claims.sub);
}

test "authorization header and bearer scheme are case insensitive" {
    var key_pair = testKeyPair(0x42);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    const token = try testToken(&key_pair, 1000, 60);
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putTestPublicKey(&environment, key_pair.public_key);
    const event = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"headers\":{{\"authorization\":\"bEaReR {s}\"}}}}",
        .{token},
    );
    defer std.testing.allocator.free(event);
    const request = try lambda.url.parseRequest(std.testing.allocator, event);
    defer request.deinit(std.testing.allocator);

    var claims = try authenticate(
        std.testing.allocator,
        &request,
        &environment,
        1000,
    );
    defer claims.deinit();
    try std.testing.expectEqualStrings("lambda-test-user", claims.sub);
}

test "missing malformed duplicate and oversized bearer credentials are unauthorized" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();

    const events = [_][]const u8{
        "{\"headers\":{}}",
        "{\"headers\":{\"Authorization\":\"\"}}",
        "{\"headers\":{\"Authorization\":\"Bearer\"}}",
        "{\"headers\":{\"Authorization\":\"Bearer \"}}",
        "{\"headers\":{\"Authorization\":\"Basic token\"}}",
        "{\"headers\":{\"Authorization\":\"Bearertoken\"}}",
        "{\"headers\":{\"Authorization\":\"Bearer token extra\"}}",
        "{\"headers\":{\"Authorization\":\"Bearer\\ttoken\"}}",
        "{\"headers\":{\"Authorization\":\"Bearer one\"," ++
            "\"authorization\":\"Bearer two\"}}",
    };
    for (events) |event| {
        const request = try lambda.url.parseRequest(std.testing.allocator, event);
        defer request.deinit(std.testing.allocator);
        try std.testing.expectError(
            error.Unauthorized,
            authenticate(std.testing.allocator, &request, &environment, 1000),
        );
    }

    const oversized_token = try std.testing.allocator.alloc(
        u8,
        paseto.token_size_max + 1,
    );
    defer std.testing.allocator.free(oversized_token);
    @memset(oversized_token, 'a');
    const oversized_event = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"headers\":{{\"Authorization\":\"Bearer {s}\"}}}}",
        .{oversized_token},
    );
    defer std.testing.allocator.free(oversized_event);
    const oversized_request = try lambda.url.parseRequest(
        std.testing.allocator,
        oversized_event,
    );
    defer oversized_request.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.Unauthorized,
        authenticate(
            std.testing.allocator,
            &oversized_request,
            &environment,
            1000,
        ),
    );
}

test "expired and wrongly signed tokens are unauthorized" {
    var key_pair = testKeyPair(0x51);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    var wrong_key_pair = testKeyPair(0x52);
    defer paseto.wipeSecretKey(&wrong_key_pair.secret_key);
    const wrong_token = try testToken(&wrong_key_pair, 1000, 60);
    defer std.testing.allocator.free(wrong_token);
    const expired_token = try testToken(&key_pair, 1000, 1);
    defer std.testing.allocator.free(expired_token);

    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putTestPublicKey(&environment, key_pair.public_key);

    for ([_][]const u8{ wrong_token, expired_token }) |token| {
        const event = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"headers\":{{\"Authorization\":\"Bearer {s}\"}}}}",
            .{token},
        );
        defer std.testing.allocator.free(event);
        const request = try lambda.url.parseRequest(std.testing.allocator, event);
        defer request.deinit(std.testing.allocator);
        try std.testing.expectError(
            error.Unauthorized,
            authenticate(std.testing.allocator, &request, &environment, 1001),
        );
    }
}

test "missing and invalid public key configuration are internal failures" {
    var key_pair = testKeyPair(0x61);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    const token = try testToken(&key_pair, 1000, 60);
    defer std.testing.allocator.free(token);
    const event = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"headers\":{{\"Authorization\":\"Bearer {s}\"}}}}",
        .{token},
    );
    defer std.testing.allocator.free(event);
    const request = try lambda.url.parseRequest(std.testing.allocator, event);
    defer request.deinit(std.testing.allocator);

    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try std.testing.expectError(
        error.InternalFailure,
        authenticate(std.testing.allocator, &request, &environment, 1000),
    );
    try environment.put("PASETO_PUBLIC_KEY", "invalid-public-key-marker");
    try std.testing.expectError(
        error.InternalFailure,
        authenticate(std.testing.allocator, &request, &environment, 1000),
    );
}

fn testKeyPair(seed_byte: u8) paseto.Ed25519.KeyPair {
    const seed = [_]u8{seed_byte} ** paseto.Ed25519.KeyPair.seed_length;
    return paseto.Ed25519.KeyPair.generateDeterministic(seed) catch unreachable;
}

fn testToken(
    key_pair: *const paseto.Ed25519.KeyPair,
    now: i64,
    ttl_seconds: i64,
) ![]u8 {
    var random = std.Random.DefaultPrng.init(0x4c414d4244415554);
    return paseto.issue(
        std.testing.allocator,
        random.random(),
        &key_pair.secret_key,
        .{
            .subject = "lambda-test-user",
            .now = now,
            .ttl_seconds = ttl_seconds,
        },
    );
}

fn putTestPublicKey(
    environment: *std.process.Environ.Map,
    public_key: paseto.Ed25519.PublicKey,
) !void {
    var buffer: [paseto.public_key_base64_size]u8 = undefined;
    try environment.put("PASETO_PUBLIC_KEY", paseto.encodePublicKey(public_key, &buffer));
}
