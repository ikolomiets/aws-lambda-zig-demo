const std = @import("std");
const http = @import("http");
const paseto = @import("paseto");
const lambda_auth = @import("lambda_auth");
const github = @import("github_identity.zig");
const token_issuer = @import("token_issuer.zig");

const Allocator = std.mem.Allocator;

pub const Config = struct {
    github_client_id: []const u8,
    paseto_public_key: []const u8,
};

pub const Secret = enum { github_client_secret, paseto_signing_key };
pub const SecretError = error{ MissingSecret, InvalidSecret, Unavailable, OutOfMemory };

pub const Dependencies = struct {
    context: *anyopaque,
    random: std.Random,
    now_seconds_fn: *const fn (*anyopaque) i64,
    // The secret reader gives the invocation ownership of mutable secret bytes.
    read_secret_fn: *const fn (*anyopaque, Allocator, Secret) SecretError![]u8,
    check_token_fn: github.CheckTokenFn,
};

const ExchangeError = error{ BadRequest, Unauthorized, InternalFailure, Unavailable };
const json_headers: []const http.Header = &.{
    .{ .key = "Content-Type", .value = "application/json" },
    .{ .key = "Cache-Control", .value = "no-store" },
};
const unauthorized_headers = json_headers ++ [_]http.Header{
    .{ .key = "WWW-Authenticate", .value = "Bearer" },
};

pub fn handle_http(
    allocator: Allocator,
    request: *const http.HttpRequest,
    config: *const Config,
    dependencies: *const Dependencies,
) http.HttpResponse {
    if (request.method != .POST or
        !std.mem.eql(u8, request.path orelse "", "/auth/github/exchange"))
    {
        return error_response(.not_found, "not_found");
    }
    const exchange = exchange_github(allocator, request, config, dependencies) catch |err| {
        return switch (err) {
            error.BadRequest => error_response(.bad_request, "bad_request"),
            error.Unauthorized => error_response(.unauthorized, "unauthorized"),
            error.InternalFailure => error_response(.internal_server_error, "internal_error"),
            error.Unavailable => error_response(.service_unavailable, "service_unavailable"),
        };
    };
    return .{
        .status = .ok,
        .headers = json_headers,
        .body = exchange,
        .body_allocator = allocator,
    };
}

fn exchange_github(
    allocator: Allocator,
    request: *const http.HttpRequest,
    config: *const Config,
    dependencies: *const Dependencies,
) ExchangeError![]u8 {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const tenant = try resolve_github_tenant(arena, request.headers, config, dependencies);
    if (!request.body_is_empty()) return error.BadRequest;

    const signing_key = try read_secret(arena, dependencies, .paseto_signing_key);
    defer std.crypto.secureZero(u8, signing_key);
    return token_issuer.issue(allocator, dependencies.random, &.{
        .subject = tenant,
        .now_seconds = dependencies.now_seconds_fn(dependencies.context),
        .signing_key_base64 = signing_key,
        .public_key_base64 = config.paseto_public_key,
    });
}

fn resolve_github_tenant(
    arena: Allocator,
    headers: []const http.Header,
    config: *const Config,
    dependencies: *const Dependencies,
) github.Error![]const u8 {
    const bearer = lambda_auth.bearer_token(headers) catch return error.Unauthorized;
    // An Operations credential must stay with the Operations API.
    if (std.mem.startsWith(u8, bearer, "v4.public.")) return error.Unauthorized;
    const token = try github.AccessToken.parse(bearer);

    const client_secret = try read_secret(arena, dependencies, .github_client_secret);
    defer std.crypto.secureZero(u8, client_secret);
    return github.resolve_tenant(arena, &.{
        .client_id = config.github_client_id,
        .client_secret = client_secret,
        .access_token = token,
    }, dependencies.context, dependencies.check_token_fn);
}

fn read_secret(
    arena: Allocator,
    dependencies: *const Dependencies,
    secret: Secret,
) error{ Unavailable, InternalFailure }![]u8 {
    const bytes = dependencies.read_secret_fn(dependencies.context, arena, secret);
    return bytes catch |err| switch (err) {
        error.Unavailable => error.Unavailable,
        error.MissingSecret, error.InvalidSecret, error.OutOfMemory => error.InternalFailure,
    };
}

fn error_response(status: std.http.Status, comptime code: []const u8) http.HttpResponse {
    return .{
        .status = status,
        .headers = if (status == .unauthorized) unauthorized_headers else json_headers,
        .body = "{\"error\":\"" ++ code ++ "\"}",
    };
}

const test_now_seconds = 1_700_000_000;
const test_provider_token = "gho_fixture";
const test_client_id = "configured-client";
const test_client_secret = "fixture-app-secret";
const test_github_identity =
    \\{"id":7,"app":{"client_id":"configured-client"},"user":{"id":42,"login":"octocat"}}
;
const test_exchange: http.HttpRequest = .{
    .method = .POST,
    .path = "/auth/github/exchange",
    .headers = &.{.{ .key = "Authorization", .value = "Bearer " ++ test_provider_token }},
};

test "direct GitHub exchange issues exactly eight hours of access for github:42" {
    var fixture: TestServices = undefined;
    try fixture.init();
    defer fixture.deinit();
    var response = fixture.invoke(&test_exchange);
    defer response.deinit();

    try std.testing.expectEqual(.ok, response.status);
    try expect_header(response.headers, "Cache-Control", "no-store");
    try expect_header(response.headers, "Content-Type", "application/json");
    const fields = try read_issued_token(&response);
    defer fields.deinit();
    try std.testing.expectEqualStrings("Bearer", fields.value.token_type);
    try std.testing.expectEqual(28800, fields.value.expires_in);

    var claims = try paseto.verify(
        std.testing.allocator,
        fields.value.access_token,
        fixture.key_pair.public_key,
        test_now_seconds + 28799,
    );
    defer claims.deinit();
    try std.testing.expectEqualStrings("github:42", claims.sub);
    try std.testing.expectEqual(test_now_seconds + 28800, claims.exp);
    try std.testing.expectError(error.InvalidToken, paseto.verify(
        std.testing.allocator,
        fields.value.access_token,
        fixture.key_pair.public_key,
        test_now_seconds + 28800,
    ));
}

test "direct GitHub exchange rejects a token issued to another OAuth App" {
    var fixture: TestServices = undefined;
    try fixture.init();
    defer fixture.deinit();
    fixture.github_result = .{
        .status = .ok,
        .body =
        \\{"app":{"client_id":"other-client"},"user":{"id":42}}
        ,
    };

    try expect_exchange_error(&fixture, &test_exchange, .unauthorized);
    try std.testing.expectEqual(1, fixture.github_checks);
    try std.testing.expectEqual(0, fixture.signing_key_reads);
}

test "direct GitHub exchange keeps the precise account ID across login and grant changes" {
    var fixture: TestServices = undefined;
    try fixture.init();
    defer fixture.deinit();

    const identities = [_][]const u8{
        \\{"id":7,"app":{"client_id":"configured-client"},
        \\"user":{"id":18446744073709551615,"login":"old-name"}}
        ,
        \\{"id":8,"app":{"client_id":"configured-client"},
        \\"user":{"id":18446744073709551615,"login":"new-name"}}
        ,
    };
    for (identities) |identity| {
        fixture.github_result = .{ .status = .ok, .body = identity };
        var response = fixture.invoke(&test_exchange);
        defer response.deinit();
        const fields = try read_issued_token(&response);
        defer fields.deinit();
        var claims = try paseto.verify(
            std.testing.allocator,
            fields.value.access_token,
            fixture.key_pair.public_key,
            test_now_seconds,
        );
        defer claims.deinit();
        try std.testing.expectEqualStrings("github:18446744073709551615", claims.sub);
    }
}

test "direct GitHub exchange treats unusable identity data as a retryable failure" {
    var fixture: TestServices = undefined;
    try fixture.init();
    defer fixture.deinit();

    const prefix =
        \\{"app":{"client_id":"configured-client"},"user":
    ;
    const invalid_identities = [_][]const u8{
        "invalid-json",
        "{}",
        "{\"user\":{\"id\":42}}",
        prefix ++ "null}",
        prefix ++ "{}}",
        prefix ++ "{\"id\":0}}",
        prefix ++ "{\"id\":-1}}",
        prefix ++ "{\"id\":42.5}}",
        prefix ++ "{\"id\":\"42\"}}",
        prefix ++ "{\"id\":18446744073709551616}}",
        prefix ++ "{\"id\":42,\"id\":1}}",
    };
    for (invalid_identities) |identity| {
        fixture.github_result = .{ .status = .ok, .body = identity };
        try expect_exchange_error(&fixture, &test_exchange, .service_unavailable);
    }
    try std.testing.expectEqual(invalid_identities.len, fixture.github_checks);
    try std.testing.expectEqual(0, fixture.signing_key_reads);
}

test "direct GitHub exchange requires one well-formed Bearer credential" {
    var fixture: TestServices = undefined;
    try fixture.init();
    defer fixture.deinit();
    var request = test_exchange;

    const header_cases = [_][]const http.Header{
        &.{},
        &.{.{ .key = "Authorization", .value = "Basic Zm9v" }},
        &.{.{ .key = "Authorization", .value = "Bearer " }},
        &.{.{ .key = "Authorization", .value = "Bearer gho_one,gho_two" }},
        &.{.{ .key = "Authorization", .value = "Bearer gho_one, Bearer gho_two" }},
        &.{.{ .key = "Authorization", .value = "Bearer gho_one\r\n" }},
        &.{
            .{ .key = "Authorization", .value = "Bearer gho_one" },
            .{ .key = "authorization", .value = "Bearer gho_two" },
        },
    };
    for (header_cases) |headers| {
        request.headers = headers;
        try expect_exchange_error(&fixture, &request, .unauthorized);
    }
    try std.testing.expectEqual(0, fixture.app_secret_reads);
    try std.testing.expectEqual(0, fixture.github_checks);
    try std.testing.expectEqual(0, fixture.signing_key_reads);
}

test "GitHub rejects a personal access token submitted for direct exchange" {
    var fixture: TestServices = undefined;
    try fixture.init();
    defer fixture.deinit();
    fixture.expected_provider_token = "ghp_fixture";
    fixture.github_result = .{ .status = .not_found, .body = "github-private-error" };
    var request = test_exchange;
    request.headers = &.{.{ .key = "authorization", .value = "bEaReR ghp_fixture" }};

    try expect_exchange_error(&fixture, &request, .unauthorized);
    try std.testing.expectEqual(1, fixture.github_checks);
    try std.testing.expectEqual(0, fixture.signing_key_reads);
}

test "direct GitHub exchange rejects authenticated bodies including tenant and lifetime overrides" {
    var fixture: TestServices = undefined;
    try fixture.init();
    defer fixture.deinit();
    var request = test_exchange;
    request.body = .{ .bytes = "{\"tenant\":\"other\",\"ttl\":999999}" };
    try expect_exchange_error(&fixture, &request, .bad_request);
    request.body = .{ .bytes = " " };
    try expect_exchange_error(&fixture, &request, .bad_request);
    request.body = .{ .bytes = "" };
    var response = fixture.invoke(&request);
    defer response.deinit();
    try std.testing.expectEqual(.ok, response.status);
    try std.testing.expectEqual(3, fixture.github_checks);
    try std.testing.expectEqual(1, fixture.signing_key_reads);
}

test "direct GitHub exchange decides whether a deferred body is empty without reading it" {
    const Body = struct {
        fn read(_: *anyopaque, _: Allocator) anyerror!?[]const u8 {
            unreachable;
        }
    };
    var marker: u8 = 0;
    var fixture: TestServices = undefined;
    try fixture.init();
    defer fixture.deinit();
    var request = test_exchange;
    request.body = .{ .deferred = .{
        .context = &marker,
        .is_empty = false,
        .read_fn = Body.read,
    } };
    try expect_exchange_error(&fixture, &request, .bad_request);
    request.body.deferred.is_empty = true;
    var response = fixture.invoke(&request);
    defer response.deinit();
    try std.testing.expectEqual(.ok, response.status);
}

test "unknown authentication methods providers and actions bypass issuance" {
    var fixture: TestServices = undefined;
    try fixture.init();
    defer fixture.deinit();
    var request = test_exchange;

    request.method = .GET;
    try expect_exchange_error(&fixture, &request, .not_found);
    request.method = .POST;
    for ([_][]const u8{
        "/auth/unknown/exchange",
        "/auth/github/renew",
        "/auth/github/exchange/extra",
        "/auth/github/exchange/",
    }) |path| {
        request.path = path;
        try expect_exchange_error(&fixture, &request, .not_found);
    }
    try std.testing.expectEqual(0, fixture.app_secret_reads);
    try std.testing.expectEqual(0, fixture.github_checks);
    try std.testing.expectEqual(0, fixture.signing_key_reads);
}

test "direct GitHub exchange sanitizes provider and secret service failures" {
    var fixture: TestServices = undefined;
    try fixture.init();
    defer fixture.deinit();

    fixture.github_result = error.Unavailable;
    try expect_exchange_error(&fixture, &test_exchange, .service_unavailable);
    for ([_]std.http.Status{ .forbidden, .too_many_requests, .bad_gateway }) |status| {
        fixture.github_result = .{ .status = status, .body = "github-private-error" };
        try expect_exchange_error(&fixture, &test_exchange, .service_unavailable);
    }
    fixture.github_result = .{ .status = .unauthorized, .body = "github-private-error" };
    try expect_exchange_error(&fixture, &test_exchange, .internal_server_error);
    fixture.app_secret = error.Unavailable;
    try expect_exchange_error(&fixture, &test_exchange, .service_unavailable);
    fixture.app_secret = error.MissingSecret;
    try expect_exchange_error(&fixture, &test_exchange, .internal_server_error);
    try std.testing.expectEqual(0, fixture.signing_key_reads);
}

test "direct GitHub exchange sanitizes missing malformed and mismatched signing keys" {
    var fixture: TestServices = undefined;
    try fixture.init();
    defer fixture.deinit();

    fixture.signing_key = error.Unavailable;
    try expect_exchange_error(&fixture, &test_exchange, .service_unavailable);
    fixture.signing_key = error.MissingSecret;
    try expect_exchange_error(&fixture, &test_exchange, .internal_server_error);
    fixture.signing_key = "corrupted-private-key";
    try expect_exchange_error(&fixture, &test_exchange, .internal_server_error);

    fixture.signing_key = &fixture.private_key;
    @memset(&fixture.public_key, '?');
    try expect_exchange_error(&fixture, &test_exchange, .internal_server_error);
    var other_key = try paseto.Ed25519.KeyPair.generateDeterministic(@splat(0x43));
    defer paseto.wipeSecretKey(&other_key.secret_key);
    _ = paseto.encodePublicKey(other_key.public_key, &fixture.public_key);
    try expect_exchange_error(&fixture, &test_exchange, .internal_server_error);
}

test "warm direct exchanges check GitHub again and leave issued PASETO expiry fixed" {
    var fixture: TestServices = undefined;
    try fixture.init();
    defer fixture.deinit();
    var first = fixture.invoke(&test_exchange);
    defer first.deinit();
    const first_fields = try read_issued_token(&first);
    defer first_fields.deinit();

    fixture.now_seconds += 60;
    var second = fixture.invoke(&test_exchange);
    defer second.deinit();
    const second_fields = try read_issued_token(&second);
    defer second_fields.deinit();
    var second_claims = try paseto.verify(
        std.testing.allocator,
        second_fields.value.access_token,
        fixture.key_pair.public_key,
        fixture.now_seconds,
    );
    defer second_claims.deinit();
    try std.testing.expectEqualStrings("github:42", second_claims.sub);
    try std.testing.expectEqual(test_now_seconds + 60 + 28800, second_claims.exp);

    fixture.github_result = .{ .status = .not_found, .body = "github-private-error" };
    try expect_exchange_error(&fixture, &test_exchange, .unauthorized);
    try std.testing.expectEqual(3, fixture.github_checks);
    try std.testing.expectEqual(2, fixture.signing_key_reads);
    var first_claims = try paseto.verify(
        std.testing.allocator,
        first_fields.value.access_token,
        fixture.key_pair.public_key,
        test_now_seconds + 28799,
    );
    defer first_claims.deinit();
    try std.testing.expectEqual(test_now_seconds + 28800, first_claims.exp);
}

test "a valid or expired Operations PASETO cannot authorize another exchange" {
    var fixture: TestServices = undefined;
    try fixture.init();
    defer fixture.deinit();
    var issued = fixture.invoke(&test_exchange);
    defer issued.deinit();
    const fields = try read_issued_token(&issued);
    defer fields.deinit();
    const authorization = try std.fmt.allocPrint(
        std.testing.allocator,
        "Bearer {s}",
        .{fields.value.access_token},
    );
    defer std.testing.allocator.free(authorization);
    var request = test_exchange;
    request.headers = &.{.{ .key = "Authorization", .value = authorization }};

    try expect_exchange_error(&fixture, &request, .unauthorized);
    fixture.now_seconds += 28800;
    try expect_exchange_error(&fixture, &request, .unauthorized);
    try std.testing.expectEqual(1, fixture.app_secret_reads);
    try std.testing.expectEqual(1, fixture.github_checks);
    try std.testing.expectEqual(1, fixture.signing_key_reads);
}

const IssuedToken = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in: i64,
};

const TestServices = struct {
    key_pair: paseto.Ed25519.KeyPair,
    private_key: [paseto.private_key_base64_size]u8,
    public_key: [paseto.public_key_base64_size]u8,
    random: std.Random.DefaultPrng,
    now_seconds: i64,
    github_result: github.TransportError!github.TokenCheckResponse,
    app_secret: SecretError![]const u8,
    signing_key: SecretError![]const u8,
    expected_provider_token: []const u8,
    app_secret_reads: u8,
    signing_key_reads: u8,
    github_checks: u8,

    fn init(fixture: *TestServices) !void {
        fixture.key_pair = try paseto.Ed25519.KeyPair.generateDeterministic(@splat(0x42));
        _ = paseto.encodePrivateKey(&fixture.key_pair.secret_key, &fixture.private_key);
        _ = paseto.encodePublicKey(fixture.key_pair.public_key, &fixture.public_key);
        fixture.random = .init(42);
        fixture.now_seconds = test_now_seconds;
        fixture.github_result = .{ .status = .ok, .body = test_github_identity };
        fixture.app_secret = test_client_secret;
        fixture.signing_key = &fixture.private_key;
        fixture.expected_provider_token = test_provider_token;
        fixture.app_secret_reads = 0;
        fixture.signing_key_reads = 0;
        fixture.github_checks = 0;
    }

    fn deinit(fixture: *TestServices) void {
        paseto.wipeSecretKey(&fixture.key_pair.secret_key);
        std.crypto.secureZero(u8, &fixture.private_key);
    }

    fn invoke(fixture: *TestServices, request: *const http.HttpRequest) http.HttpResponse {
        return handle_http(std.testing.allocator, request, &.{
            .github_client_id = test_client_id,
            .paseto_public_key = &fixture.public_key,
        }, &.{
            .context = fixture,
            .random = fixture.random.random(),
            .now_seconds_fn = now,
            .read_secret_fn = TestServices.read_secret,
            .check_token_fn = check_token,
        });
    }

    fn now(context: *anyopaque) i64 {
        const fixture: *TestServices = @ptrCast(@alignCast(context));
        return fixture.now_seconds;
    }

    fn read_secret(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        secret: Secret,
    ) SecretError![]u8 {
        const fixture: *TestServices = @ptrCast(@alignCast(context));
        return allocator.dupe(u8, switch (secret) {
            .github_client_secret => bytes: {
                fixture.app_secret_reads += 1;
                break :bytes try fixture.app_secret;
            },
            .paseto_signing_key => bytes: {
                fixture.signing_key_reads += 1;
                break :bytes try fixture.signing_key;
            },
        });
    }

    fn check_token(
        context: *anyopaque,
        allocator: Allocator,
        request: *const github.TokenCheckRequest,
    ) github.TransportError!github.TokenCheckResponse {
        const fixture: *TestServices = @ptrCast(@alignCast(context));
        std.testing.expectEqual(.POST, request.method) catch unreachable;
        std.testing.expectEqualStrings(
            "https://api.github.com/applications/configured-client/token",
            request.url,
        ) catch unreachable;
        try expect_token_check_request(allocator, request, fixture.expected_provider_token);
        fixture.github_checks += 1;
        return fixture.github_result;
    }
};

fn expect_token_check_request(
    allocator: Allocator,
    request: *const github.TokenCheckRequest,
    expected_token: []const u8,
) error{OutOfMemory}!void {
    const Payload = struct { access_token: []const u8 };
    const payload = std.json.parseFromSliceLeaky(
        Payload,
        allocator,
        request.body,
        .{},
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        unreachable;
    };
    std.testing.expectEqualStrings(expected_token, payload.access_token) catch unreachable;
    const basic = std.base64.standard.Encoder;
    const credentials = test_client_id ++ ":" ++ test_client_secret;
    var encoded: [basic.calcSize(credentials.len)]u8 = undefined;
    const authorization = try std.fmt.allocPrint(
        allocator,
        "Basic {s}",
        .{basic.encode(&encoded, credentials)},
    );
    expect_header(request.headers, "Authorization", authorization) catch unreachable;
    expect_header(request.headers, "Accept", "application/vnd.github+json") catch unreachable;
    expect_header(request.headers, "Content-Type", "application/json") catch unreachable;
}

fn read_issued_token(response: *const http.HttpResponse) !std.json.Parsed(IssuedToken) {
    try std.testing.expectEqual(.ok, response.status);
    return std.json.parseFromSlice(IssuedToken, std.testing.allocator, response.body, .{});
}

fn expect_exchange_error(
    fixture: *TestServices,
    request: *const http.HttpRequest,
    status: std.http.Status,
) !void {
    var response = fixture.invoke(request);
    defer response.deinit();
    try std.testing.expectEqual(status, response.status);
    const expected = switch (status) {
        .bad_request => "bad_request",
        .unauthorized => "unauthorized",
        .not_found => "not_found",
        .service_unavailable => "service_unavailable",
        .internal_server_error => "internal_error",
        else => unreachable,
    };
    const ErrorBody = struct { @"error": []const u8 };
    const fields = try std.json.parseFromSlice(
        ErrorBody,
        std.testing.allocator,
        response.body,
        .{},
    );
    defer fields.deinit();
    try std.testing.expectEqualStrings(expected, fields.value.@"error");
    try expect_header(response.headers, "Cache-Control", "no-store");
    if (status == .unauthorized) {
        try expect_header(response.headers, "WWW-Authenticate", "Bearer");
    }
}

fn expect_header(headers: []const http.Header, name: []const u8, value: []const u8) !void {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.key, name)) {
            return std.testing.expectEqualStrings(value, header.value);
        }
    }
    return error.TestExpectedHeader;
}
