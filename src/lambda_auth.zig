const std = @import("std");
const lambda = @import("aws-lambda");
const paseto = @import("paseto");

const authorization_header_count_max = 256;

pub const subject_size_max = paseto.subject_size_max;

pub const Error = error{
    InternalFailure,
    Unauthorized,
};

/// Owns the authenticated identity for the lifetime of a Lambda invocation.
pub const Identity = struct {
    subject: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(identity: *Identity) void {
        std.debug.assert(identity.subject.len > 0);
        std.debug.assert(identity.subject.len <= subject_size_max);
        identity.allocator.free(identity.subject);
        identity.* = undefined;
    }
};

pub fn authenticate(
    allocator: std.mem.Allocator,
    request: *const lambda.url.Request,
    environment: *const std.process.Environ.Map,
    now: i64,
) Error!Identity {
    const token = bearerToken(request) catch return error.Unauthorized;
    const public_key_encoded = environment.get("PASETO_PUBLIC_KEY") orelse {
        return error.InternalFailure;
    };
    const public_key = paseto.decodePublicKey(public_key_encoded) catch {
        return error.InternalFailure;
    };
    const claims = paseto.verify(allocator, token, public_key, now) catch |err| {
        return switch (err) {
            error.InvalidToken => error.Unauthorized,
            else => error.InternalFailure,
        };
    };
    std.debug.assert(claims.sub.len > 0);
    std.debug.assert(claims.sub.len <= subject_size_max);
    std.debug.assert(claims.exp > now);
    // Identity assumes ownership of the verified subject and its allocator.
    return .{
        .subject = claims.sub,
        .allocator = claims.allocator,
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
    const token = try testing.issue_token(std.testing.allocator, .{
        .seed_byte = 0x41,
        .now = 1000,
        .ttl_seconds = 60,
    });
    defer std.testing.allocator.free(token);

    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try testing.put_public_key(&environment, 0x41);

    const event = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"headers\":{{\"Authorization\":\"Bearer {s}\"}}}}",
        .{token},
    );
    defer std.testing.allocator.free(event);
    const request = try lambda.url.parseRequest(std.testing.allocator, event);
    defer request.deinit(std.testing.allocator);

    var identity = try authenticate(
        std.testing.allocator,
        &request,
        &environment,
        1000,
    );
    defer identity.deinit();
    try std.testing.expectEqualStrings("lambda-test-user", identity.subject);
}

test "authorization header and bearer scheme are case insensitive" {
    const token = try testing.issue_token(std.testing.allocator, .{
        .seed_byte = 0x42,
        .now = 1000,
        .ttl_seconds = 60,
    });
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try testing.put_public_key(&environment, 0x42);
    const event = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"headers\":{{\"authorization\":\"bEaReR {s}\"}}}}",
        .{token},
    );
    defer std.testing.allocator.free(event);
    const request = try lambda.url.parseRequest(std.testing.allocator, event);
    defer request.deinit(std.testing.allocator);

    var identity = try authenticate(
        std.testing.allocator,
        &request,
        &environment,
        1000,
    );
    defer identity.deinit();
    try std.testing.expectEqualStrings("lambda-test-user", identity.subject);
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
    const wrong_token = try testing.issue_token(std.testing.allocator, .{
        .seed_byte = 0x52,
        .now = 1000,
        .ttl_seconds = 60,
    });
    defer std.testing.allocator.free(wrong_token);
    const expired_token = try testing.issue_token(std.testing.allocator, .{
        .seed_byte = 0x51,
        .now = 1000,
        .ttl_seconds = 1,
    });
    defer std.testing.allocator.free(expired_token);

    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try testing.put_public_key(&environment, 0x51);

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
    const token = try testing.issue_token(std.testing.allocator, .{
        .seed_byte = 0x61,
        .now = 1000,
        .ttl_seconds = 60,
    });
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

pub const testing = struct {
    pub const TokenOptions = struct {
        seed_byte: u8,
        subject: []const u8 = "lambda-test-user",
        now: i64,
        ttl_seconds: i64,
    };

    pub fn issue_token(
        allocator: std.mem.Allocator,
        options: TokenOptions,
    ) ![]u8 {
        var key_pair = test_key_pair(options.seed_byte);
        defer paseto.wipeSecretKey(&key_pair.secret_key);
        var random = std.Random.DefaultPrng.init(0x4c414d4244415554);
        return paseto.issue(
            allocator,
            random.random(),
            &key_pair.secret_key,
            .{
                .subject = options.subject,
                .now = options.now,
                .ttl_seconds = options.ttl_seconds,
            },
        );
    }

    pub fn put_public_key(
        environment: *std.process.Environ.Map,
        seed_byte: u8,
    ) !void {
        var key_pair = test_key_pair(seed_byte);
        defer paseto.wipeSecretKey(&key_pair.secret_key);
        var buffer: [paseto.public_key_base64_size]u8 = undefined;
        const encoded = paseto.encodePublicKey(key_pair.public_key, &buffer);
        try environment.put("PASETO_PUBLIC_KEY", encoded);
        std.debug.assert(environment.get("PASETO_PUBLIC_KEY") != null);
        std.debug.assert(encoded.len == paseto.public_key_base64_size);
    }

    fn test_key_pair(seed_byte: u8) paseto.Ed25519.KeyPair {
        const seed = [_]u8{seed_byte} ** paseto.Ed25519.KeyPair.seed_length;
        const key_pair = paseto.Ed25519.KeyPair.generateDeterministic(seed) catch unreachable;
        std.debug.assert(
            key_pair.secret_key.toBytes().len == paseto.Ed25519.SecretKey.encoded_length,
        );
        std.debug.assert(
            key_pair.public_key.toBytes().len == paseto.Ed25519.PublicKey.encoded_length,
        );
        return key_pair;
    }
};
