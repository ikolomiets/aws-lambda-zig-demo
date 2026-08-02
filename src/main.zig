const std = @import("std");
const aws = @import("aws");
const dynamodb = @import("dynamodb");
const lambda = @import("aws-lambda");
const paseto = @import("paseto");

const authorization_header_count_max = 256;
const content_type = "text/plain; charset=utf-8";
const environment_count_max = 512;
const internal_server_error_body = "Internal Server Error\n";
const internal_server_error_response =
    "{\"statusCode\":500,\"headers\":{\"Content-Type\":\"" ++ content_type ++
    "\"},\"body\":\"Internal Server Error\\n\"}";
const redacted_value = "<redacted>";
const unauthorized_body = "Unauthorized\n";

pub fn main(init: std.process.Init) void {
    lambda.handle(init, handler, .{});
}

fn handler(ctx: lambda.Context, event: []const u8) ![]const u8 {
    const now = std.Io.Clock.real.now(ctx.io).toSeconds();
    return handleInvocation(
        ctx.arena,
        event,
        ctx.config,
        ctx.request,
        @field(ctx, "_").kv,
        now,
    );
}

fn handleInvocation(
    allocator: std.mem.Allocator,
    event: []const u8,
    cfg: lambda.Context.ConfigMeta,
    req: lambda.Context.RequestMeta,
    env: *const std.process.Environ.Map,
    now: i64,
) []const u8 {
    const outcome = invocationOutcome(allocator, event, cfg, req, env, now);
    return encodeOutcome(allocator, outcome) catch internal_server_error_response;
}

const InvocationOutcome = union(enum) {
    success: []const u8,
    unauthorized,
    internal_server_error,
};

fn invocationOutcome(
    allocator: std.mem.Allocator,
    event: []const u8,
    cfg: lambda.Context.ConfigMeta,
    req: lambda.Context.RequestMeta,
    env: *const std.process.Environ.Map,
    now: i64,
) InvocationOutcome {
    const request = lambda.url.parseRequest(allocator, event) catch {
        return .internal_server_error;
    };
    defer request.deinit(allocator);
    const token = bearerToken(&request) catch return .unauthorized;
    const public_key_encoded = env.get("PASETO_PUBLIC_KEY") orelse {
        return .internal_server_error;
    };
    const public_key = paseto.decodePublicKey(public_key_encoded) catch {
        return .internal_server_error;
    };
    var claims = paseto.verify(allocator, token, public_key, now) catch |err| {
        return switch (err) {
            error.InvalidToken => .unauthorized,
            else => .internal_server_error,
        };
    };
    defer claims.deinit();

    const body = handlerBody(allocator, claims.sub, cfg, req, env) catch {
        return .internal_server_error;
    };
    return .{ .success = body };
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

fn encodeOutcome(
    allocator: std.mem.Allocator,
    outcome: InvocationOutcome,
) ![]const u8 {
    return switch (outcome) {
        .success => |body| success: {
            defer allocator.free(body);
            break :success lambda.url.encodeResponse(allocator, .{
                .content_type = content_type,
                .body = .{ .textual = body },
            });
        },
        .unauthorized => lambda.url.encodeResponse(allocator, .{
            .content_type = content_type,
            .status_code = .unauthorized,
            .headers = &.{
                .{ .key = "WWW-Authenticate", .value = "Bearer" },
            },
            .body = .{ .textual = unauthorized_body },
        }),
        .internal_server_error => lambda.url.encodeResponse(allocator, .{
            .content_type = content_type,
            .status_code = .internal_server_error,
            .body = .{ .textual = internal_server_error_body },
        }),
    };
}

fn handlerBody(
    allocator: std.mem.Allocator,
    subject: []const u8,
    cfg: lambda.Context.ConfigMeta,
    req: lambda.Context.RequestMeta,
    env: *const std.process.Environ.Map,
) ![]const u8 {
    std.debug.assert(subject.len > 0);
    std.debug.assert(subject.len <= paseto.subject_size_max);

    var count_buffer: [1024]u8 = undefined;
    var counter: std.Io.Writer.Discarding = .init(&count_buffer);
    try handlerBodyWrite(&counter.writer, subject, cfg, req, env);

    const output_len = try writerCountToUsize(counter.fullCount());
    std.debug.assert(output_len > 0);

    const output = try allocator.alloc(u8, output_len);
    errdefer allocator.free(output);

    var writer: std.Io.Writer = .fixed(output);
    try handlerBodyWrite(&writer, subject, cfg, req, env);
    std.debug.assert(writer.buffered().len == output.len);

    return output;
}

fn handlerBodyWrite(
    writer: *std.Io.Writer,
    subject: []const u8,
    cfg: lambda.Context.ConfigMeta,
    req: lambda.Context.RequestMeta,
    env: *const std.process.Environ.Map,
) !void {
    std.debug.assert(subject.len > 0);
    std.debug.assert(subject.len <= paseto.subject_size_max);

    try writer.print("Hello, {s}!\n\n", .{subject});
    try configMetadataBodyWrite(writer, cfg);
    try writer.writeByte('\n');
    try requestMetadataBodyWrite(writer, req);
    try writer.writeByte('\n');
    try environmentBodyWrite(writer, env);
}

fn configMetadataBody(
    allocator: std.mem.Allocator,
    cfg: lambda.Context.ConfigMeta,
) ![]const u8 {
    var count_buffer: [1024]u8 = undefined;
    var counter: std.Io.Writer.Discarding = .init(&count_buffer);
    try configMetadataBodyWrite(&counter.writer, cfg);

    const body_len = try writerCountToUsize(counter.fullCount());
    std.debug.assert(body_len > 0);

    const body = try allocator.alloc(u8, body_len);
    errdefer allocator.free(body);

    var writer: std.Io.Writer = .fixed(body);
    try configMetadataBodyWrite(&writer, cfg);
    std.debug.assert(writer.buffered().len == body.len);

    return body;
}

fn configMetadataBodyWrite(
    writer: *std.Io.Writer,
    cfg: lambda.Context.ConfigMeta,
) !void {
    std.debug.assert(cfg.func_size > 0);

    try writer.writeAll("ConfigMeta\n");
    try writer.print("func_name={s}\n", .{cfg.func_name});
    try writer.print("func_version={s}\n", .{cfg.func_version});
    try writer.print("func_size={d}\n", .{cfg.func_size});
    try writer.print("func_init={s}\n", .{@tagName(cfg.func_init)});
    try writer.print("func_handler={s}\n", .{cfg.func_handler});
    try writer.print("aws_region={s}\n", .{cfg.aws_region});
    try writer.writeAll("aws_access_id=<redacted>\n");
    try writer.writeAll("aws_access_secret=<redacted>\n");
    try writer.writeAll("aws_session_token=<redacted>\n");
    try writer.print("log_group={s}\n", .{cfg.log_group});
    try writer.print("log_stream={s}\n", .{cfg.log_stream});
}

fn requestMetadataBody(
    allocator: std.mem.Allocator,
    req: lambda.Context.RequestMeta,
) ![]const u8 {
    var count_buffer: [512]u8 = undefined;
    var counter: std.Io.Writer.Discarding = .init(&count_buffer);
    try requestMetadataBodyWrite(&counter.writer, req);

    const body_len = try writerCountToUsize(counter.fullCount());
    std.debug.assert(body_len > 0);

    const body = try allocator.alloc(u8, body_len);
    errdefer allocator.free(body);

    var writer: std.Io.Writer = .fixed(body);
    try requestMetadataBodyWrite(&writer, req);
    std.debug.assert(writer.buffered().len == body.len);

    return body;
}

fn requestMetadataBodyWrite(
    writer: *std.Io.Writer,
    req: lambda.Context.RequestMeta,
) !void {
    try writer.writeAll("RequestMeta\n");
    try writer.print("id={s}\n", .{req.id});
    try writer.print("xray_trace={s}\n", .{req.xray_trace});
    try writer.print("invoked_arn={s}\n", .{req.invoked_arn});
    try writer.print("deadline_ms={d}\n", .{req.deadline_ms});
    try writer.print("client_context={s}\n", .{req.client_context});
    try writer.print("cognito_identity={s}\n", .{req.cognito_identity});
}

fn environmentBody(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
) ![]const u8 {
    var count_buffer: [1024]u8 = undefined;
    var counter: std.Io.Writer.Discarding = .init(&count_buffer);
    try environmentBodyWrite(&counter.writer, env);

    const body_len = try writerCountToUsize(counter.fullCount());
    std.debug.assert(body_len > 0);

    const body = try allocator.alloc(u8, body_len);
    errdefer allocator.free(body);

    var writer: std.Io.Writer = .fixed(body);
    try environmentBodyWrite(&writer, env);
    std.debug.assert(writer.buffered().len == body.len);

    return body;
}

fn environmentBodyWrite(
    writer: *std.Io.Writer,
    env: *const std.process.Environ.Map,
) !void {
    const environment_count = env.count();
    if (environment_count > environment_count_max) return error.EnvironmentTooLarge;
    std.debug.assert(environment_count <= environment_count_max);

    try writer.writeAll("Environment\n");

    var iterator = env.iterator();
    var entry_count: usize = 0;
    while (iterator.next()) |entry| : (entry_count += 1) {
        std.debug.assert(entry_count < environment_count);

        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        std.debug.assert(key.len > 0);

        try writer.print("{s}=", .{key});
        if (environmentKeySensitive(key)) {
            try writer.writeAll(redacted_value);
        } else {
            try writer.writeAll(value);
        }
        try writer.writeByte('\n');
    }

    std.debug.assert(entry_count == environment_count);
}

fn environmentKeySensitive(key: []const u8) bool {
    if (std.mem.eql(u8, key, "AWS_ACCESS_KEY")) return true;
    if (std.mem.eql(u8, key, "AWS_ACCESS_KEY_ID")) return true;
    if (std.mem.eql(u8, key, "AWS_SECRET_ACCESS_KEY")) return true;
    if (std.mem.eql(u8, key, "AWS_SESSION_TOKEN")) return true;
    if (std.mem.eql(u8, key, "PASETO_PRIVATE_KEY")) return true;

    return false;
}

fn writerCountToUsize(count: u64) !usize {
    return std.math.cast(usize, count) orelse return error.BodyTooLarge;
}

test "AWS SDK exposes runtime configuration and DynamoDB client types" {
    comptime {
        std.debug.assert(@TypeOf(aws.Config) == type);
        std.debug.assert(@TypeOf(dynamodb.Client) == type);
    }
}

test "config metadata body includes config fields" {
    const body = try configMetadataBody(std.testing.allocator, .{
        .func_name = "demo-function",
        .func_version = "$LATEST",
        .func_size = 256,
        .func_init = .provisioned,
        .func_handler = "bootstrap",
        .aws_region = "ca-central-1",
        .aws_access_id = "access-key-id",
        .aws_access_secret = "secret-key",
        .aws_session_token = "session-token",
        .log_group = "/aws/lambda/demo-function",
        .log_stream = "2026/07/01/[$LATEST]abcdef",
    });
    defer std.testing.allocator.free(body);

    try expectContains(body, "ConfigMeta");
    try expectContains(body, "func_name=demo-function");
    try expectContains(body, "func_version=$LATEST");
    try expectContains(body, "func_size=256");
    try expectContains(body, "func_init=provisioned");
    try expectContains(body, "func_handler=bootstrap");
    try expectContains(body, "aws_region=ca-central-1");
    try expectContains(body, "aws_access_id=<redacted>");
    try expectContains(body, "aws_access_secret=<redacted>");
    try expectContains(body, "aws_session_token=<redacted>");
    try expectContains(body, "log_group=/aws/lambda/demo-function");
    try expectContains(body, "log_stream=2026/07/01/[$LATEST]abcdef");
    try expectNotContains(body, "RequestMeta");
    try expectNotContains(body, "secret-key");
    try expectNotContains(body, "session-token");
}

test "request metadata body includes request fields" {
    const body = try requestMetadataBody(std.testing.allocator, .{
        .id = "request-id",
        .xray_trace = "trace-id",
        .invoked_arn = "arn:aws:lambda:ca-central-1:<account-id>:function:demo-function",
        .deadline_ms = 1782921600000,
        .client_context = "client-context",
        .cognito_identity = "cognito-identity",
    });
    defer std.testing.allocator.free(body);

    try expectContains(body, "RequestMeta");
    try expectContains(body, "id=request-id");
    try expectContains(body, "xray_trace=trace-id");
    try expectContains(
        body,
        "invoked_arn=arn:aws:lambda:ca-central-1:<account-id>:function:demo-function",
    );
    try expectContains(body, "deadline_ms=1782921600000");
    try expectContains(body, "client_context=client-context");
    try expectContains(body, "cognito_identity=cognito-identity");
    try expectNotContains(body, "ConfigMeta");
}

test "handler body includes config request and environment sections in order" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try env.put("CUSTOM_VALUE", "demo");

    const body = try handlerBody(std.testing.allocator, "example-user", .{
        .func_name = "demo-function",
        .func_version = "$LATEST",
        .func_size = 256,
        .func_init = .provisioned,
        .func_handler = "bootstrap",
        .aws_region = "ca-central-1",
        .aws_access_id = "access-key-id",
        .aws_access_secret = "secret-key",
        .aws_session_token = "session-token",
        .log_group = "/aws/lambda/demo-function",
        .log_stream = "2026/07/01/[$LATEST]abcdef",
    }, .{
        .id = "request-id",
        .xray_trace = "trace-id",
        .invoked_arn = "arn:aws:lambda:ca-central-1:<account-id>:function:demo-function",
        .deadline_ms = 1782921600000,
        .client_context = "client-context",
        .cognito_identity = "cognito-identity",
    }, &env);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.startsWith(
        u8,
        body,
        "Hello, example-user!\n\nConfigMeta\n",
    ));
    try expectBefore(body, "ConfigMeta\n", "\nRequestMeta\n");
    try expectBefore(body, "\nRequestMeta\n", "\nEnvironment\n");
    try expectContains(body, "func_name=demo-function\n");
    try expectContains(body, "id=request-id\n");
    try expectContains(body, "CUSTOM_VALUE=demo\n");
}

test "handler body allocates final body once" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try env.put("CUSTOM_VALUE", "demo");

    var allocation_counter = AllocationCounter{
        .backing_allocator = std.testing.allocator,
    };
    const allocator = allocation_counter.allocator();

    const body = try handlerBody(allocator, "example-user", .{
        .func_name = "demo-function",
        .func_version = "$LATEST",
        .func_size = 256,
        .func_init = .provisioned,
        .func_handler = "bootstrap",
        .aws_region = "ca-central-1",
        .aws_access_id = "access-key-id",
        .aws_access_secret = "secret-key",
        .aws_session_token = "session-token",
        .log_group = "/aws/lambda/demo-function",
        .log_stream = "2026/07/01/[$LATEST]abcdef",
    }, .{
        .id = "request-id",
        .xray_trace = "trace-id",
        .invoked_arn = "arn:aws:lambda:ca-central-1:<account-id>:function:demo-function",
        .deadline_ms = 1782921600000,
        .client_context = "client-context",
        .cognito_identity = "cognito-identity",
    }, &env);
    var body_owned = true;
    defer if (body_owned) allocator.free(body);

    try std.testing.expectEqual(@as(usize, 1), allocation_counter.allocations);
    try std.testing.expectEqual(@as(usize, 0), allocation_counter.frees);
    try std.testing.expectEqual(@as(usize, 0), allocation_counter.remaps);
    try std.testing.expectEqual(@as(usize, 0), allocation_counter.resizes);

    allocator.free(body);
    body_owned = false;
    try std.testing.expectEqual(@as(usize, 1), allocation_counter.frees);
}

test "environment body includes keys and redacts AWS credentials" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try env.put("AWS_REGION", "ca-central-1");
    try env.put("CUSTOM_VALUE", "demo");
    try env.put("AWS_SECRET_ACCESS_KEY", "secret-value");
    try env.put("PASETO_PRIVATE_KEY", "private-key-value");

    const body = try environmentBody(std.testing.allocator, &env);
    defer std.testing.allocator.free(body);

    try expectContains(body, "Environment\n");
    try expectContains(body, "AWS_REGION=ca-central-1\n");
    try expectContains(body, "CUSTOM_VALUE=demo\n");
    try expectContains(body, "AWS_SECRET_ACCESS_KEY=<redacted>\n");
    try expectContains(body, "PASETO_PRIVATE_KEY=<redacted>\n");
    try expectNotContains(body, "secret-value");
    try expectNotContains(body, "private-key-value");
}

test "valid credentials include subject greeting and accept case insensitive authorization" {
    var key_pair = testKeyPair(0x41);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    const token = try testToken(&key_pair, 1000, 60);
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putTestPublicKey(&environment, key_pair.public_key);

    const expected_body = try handlerBody(
        std.testing.allocator,
        "lambda-test-user",
        .{},
        .{},
        &environment,
    );
    defer std.testing.allocator.free(expected_body);
    const expected_response = try lambda.url.encodeResponse(std.testing.allocator, .{
        .content_type = content_type,
        .body = .{ .textual = expected_body },
    });
    defer std.testing.allocator.free(expected_response);

    const header_names = [_][]const u8{
        "Authorization",
        "authorization",
        "AUTHORIZATION",
    };
    const schemes = [_][]const u8{ "Bearer", "bearer", "bEaReR" };
    for (header_names) |header_name| {
        for (schemes) |scheme| {
            const event = try testAuthorizationEvent(
                std.testing.allocator,
                header_name,
                scheme,
                token,
            );
            defer std.testing.allocator.free(event);
            const response = handleInvocation(
                std.testing.allocator,
                event,
                .{},
                .{},
                &environment,
                1000,
            );
            defer std.testing.allocator.free(response);
            try std.testing.expectEqualStrings(expected_response, response);
            try expectContains(response, "Hello, lambda-test-user!");
        }
    }
}

test "missing and malformed credentials return a Bearer challenge" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    const missing_event =
        "{\"version\":\"2.0\",\"routeKey\":\"$default\",\"headers\":{}}";
    const missing_response = handleInvocation(
        std.testing.allocator,
        missing_event,
        .{},
        .{},
        &environment,
        1000,
    );
    defer std.testing.allocator.free(missing_response);
    try expectUnauthorized(missing_response);

    const malformed_values = [_][]const u8{
        "",
        "Bearer",
        "Bearer ",
        "Basic token",
        "Bearertoken",
        "Bearer token extra",
        "Bearer\\ttoken",
    };
    for (malformed_values) |value| {
        const event = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"headers\":{{\"Authorization\":\"{s}\"}}}}",
            .{value},
        );
        defer std.testing.allocator.free(event);
        const response = handleInvocation(
            std.testing.allocator,
            event,
            .{},
            .{},
            &environment,
            1000,
        );
        defer std.testing.allocator.free(response);
        try expectUnauthorized(response);
    }

    const duplicate_event =
        "{\"headers\":{\"Authorization\":\"Bearer one\"," ++
        "\"authorization\":\"Bearer two\"}}";
    const duplicate_response = handleInvocation(
        std.testing.allocator,
        duplicate_event,
        .{},
        .{},
        &environment,
        1000,
    );
    defer std.testing.allocator.free(duplicate_response);
    try expectUnauthorized(duplicate_response);
}

test "wrong and expired tokens return a sanitized unauthorized response" {
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

    const tokens = [_][]const u8{ wrong_token, expired_token };
    for (tokens) |token| {
        const event = try testAuthorizationEvent(
            std.testing.allocator,
            "Authorization",
            "Bearer",
            token,
        );
        defer std.testing.allocator.free(event);
        const response = handleInvocation(
            std.testing.allocator,
            event,
            .{},
            .{},
            &environment,
            1001,
        );
        defer std.testing.allocator.free(response);
        try expectUnauthorized(response);
        try expectNotContains(response, token);
    }
}

test "missing and invalid public key configuration return sanitized errors" {
    var key_pair = testKeyPair(0x61);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    const token = try testToken(&key_pair, 1000, 60);
    defer std.testing.allocator.free(token);
    const event = try testAuthorizationEvent(
        std.testing.allocator,
        "Authorization",
        "Bearer",
        token,
    );
    defer std.testing.allocator.free(event);

    var missing_environment = std.process.Environ.Map.init(std.testing.allocator);
    defer missing_environment.deinit();
    const missing_response = handleInvocation(
        std.testing.allocator,
        event,
        .{},
        .{},
        &missing_environment,
        1000,
    );
    defer std.testing.allocator.free(missing_response);
    try expectInternalServerError(missing_response);

    const key_marker = "invalid-public-key-marker";
    var invalid_environment = std.process.Environ.Map.init(std.testing.allocator);
    defer invalid_environment.deinit();
    try invalid_environment.put("PASETO_PUBLIC_KEY", key_marker);
    const invalid_response = handleInvocation(
        std.testing.allocator,
        event,
        .{},
        .{},
        &invalid_environment,
        1000,
    );
    defer std.testing.allocator.free(invalid_response);
    try expectInternalServerError(invalid_response);
    try expectNotContains(invalid_response, key_marker);
    try expectNotContains(invalid_response, token);
}

test "internal failures return only the static sanitized response" {
    const event_marker = "malformed-event-marker";
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    const malformed_response = handleInvocation(
        std.testing.allocator,
        "{\"headers\":" ++ event_marker,
        .{},
        .{},
        &environment,
        1000,
    );
    defer std.testing.allocator.free(malformed_response);
    try expectInternalServerError(malformed_response);
    try expectNotContains(malformed_response, event_marker);

    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    const allocation_response = handleInvocation(
        failing_allocator.allocator(),
        "{}",
        .{},
        .{},
        &environment,
        1000,
    );
    try std.testing.expectEqualStrings(
        internal_server_error_response,
        allocation_response,
    );
}

fn testAuthorizationEvent(
    allocator: std.mem.Allocator,
    header_name: []const u8,
    scheme: []const u8,
    token: []const u8,
) ![]u8 {
    std.debug.assert(header_name.len > 0);
    std.debug.assert(scheme.len > 0);
    std.debug.assert(token.len > 0);
    return std.fmt.allocPrint(
        allocator,
        "{{\"version\":\"2.0\",\"routeKey\":\"$default\"," ++
            "\"headers\":{{\"{s}\":\"{s} {s}\"}}}}",
        .{ header_name, scheme, token },
    );
}

fn testKeyPair(seed_byte: u8) paseto.Ed25519.KeyPair {
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

fn testToken(
    key_pair: *const paseto.Ed25519.KeyPair,
    now: i64,
    ttl_seconds: i64,
) ![]u8 {
    std.debug.assert(ttl_seconds > 0);
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
    const encoded = paseto.encodePublicKey(public_key, &buffer);
    try environment.put("PASETO_PUBLIC_KEY", encoded);
    std.debug.assert(environment.get("PASETO_PUBLIC_KEY") != null);
    std.debug.assert(encoded.len == paseto.public_key_base64_size);
}

fn expectUnauthorized(response: []const u8) !void {
    try std.testing.expectEqualStrings(
        "{\"statusCode\":401,\"headers\":{\"Content-Type\":\"" ++ content_type ++
            "\",\"WWW-Authenticate\":\"Bearer\"},\"body\":\"Unauthorized\\n\"}",
        response,
    );
}

fn expectInternalServerError(response: []const u8) !void {
    try std.testing.expectEqualStrings(internal_server_error_response, response);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

fn expectBefore(haystack: []const u8, first: []const u8, second: []const u8) !void {
    const first_index = std.mem.indexOf(u8, haystack, first);
    const second_index = std.mem.indexOf(u8, haystack, second);

    try std.testing.expect(first_index != null);
    try std.testing.expect(second_index != null);
    try std.testing.expect(first_index.? < second_index.?);
}

const AllocationCounter = struct {
    backing_allocator: std.mem.Allocator,
    allocations: usize = 0,
    frees: usize = 0,
    remaps: usize = 0,
    resizes: usize = 0,

    fn allocator(counter: *AllocationCounter) std.mem.Allocator {
        return .{
            .ptr = counter,
            .vtable = &vtable,
        };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const counter: *AllocationCounter = @ptrCast(@alignCast(ctx));
        const result = counter.backing_allocator.rawAlloc(len, alignment, ret_addr);
        if (result != null) counter.allocations += 1;
        return result;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const counter: *AllocationCounter = @ptrCast(@alignCast(ctx));
        const result = counter.backing_allocator.rawResize(
            memory,
            alignment,
            new_len,
            ret_addr,
        );
        if (result) counter.resizes += 1;
        return result;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const counter: *AllocationCounter = @ptrCast(@alignCast(ctx));
        const result = counter.backing_allocator.rawRemap(
            memory,
            alignment,
            new_len,
            ret_addr,
        );
        if (result != null) counter.remaps += 1;
        return result;
    }

    fn free(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const counter: *AllocationCounter = @ptrCast(@alignCast(ctx));
        counter.frees += 1;
        counter.backing_allocator.rawFree(memory, alignment, ret_addr);
    }
};
