const std = @import("std");
const builtin = @import("builtin");
const aws = @import("aws");
const lambda = @import("aws-lambda");
const aws_http = @import("aws_http");
const http = @import("http");
const paseto = @import("paseto");
const secretsmanager = @import("secretsmanager");
const lambda_auth = @import("lambda_auth");
const github = @import("github_identity");
const pending_sign_in = @import("pending_sign_in");
const token_issuer = @import("token_issuer.zig");
const authentication = @import("authentication_support.zig");
const browser = @import("browser_sign_in.zig");

const Allocator = std.mem.Allocator;
const runtime_tests_enabled = if (builtin.is_test)
    @import("runtime_test_options").enabled
else
    false;
const authentication_duration_ms_max = 10_000;
const response_margin_ms = 1_000;
const secret_response_size_max = 64 * 1024;
const poll_body_size_max = 1024;
const runtime_error_response =
    "{\"statusCode\":500,\"headers\":{\"Content-Type\":\"application/json\"," ++
    "\"Cache-Control\":\"no-store\"},\"body\":\"{\\\"error\\\":\\\"internal_error\\\"}\"}";

var runtime_test_dependencies: ?*const Dependencies = null;
var test_diagnostics: ?*TestDiagnostics = null;

pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .aws_sdk, .level = .warn }},
    .logFn = if (builtin.is_test) capture_test_log else std.log.defaultLog,
};

comptime {
    if (builtin.is_test) {
        _ = @import("authentication_browser_tests.zig");
        _ = @import("authentication_device_tests.zig");
    }
}

pub fn main(init: std.process.Init) void {
    lambda.handle(init, handler, .{});
}

fn handler(ctx: lambda.Context, event: []const u8) ![]const u8 {
    const config: Config = .{
        .github_client_id = ctx.env("GITHUB_CLIENT_ID") orelse "",
        .paseto_public_key = ctx.env("PASETO_PUBLIC_KEY") orelse "",
        .github_oauth_callback_url = ctx.env("GITHUB_OAUTH_CALLBACK_URL") orelse "",
        .browser_redirect_uris = ctx.env("GITHUB_BROWSER_REDIRECT_URIS") orelse "",
    };
    var input = aws_http.Request.parse(ctx.arena, event) catch {
        return runtime_error_response;
    };
    defer input.deinit();
    const route = browser.match_route(input.method, input.path orelse "");
    input.body_size_max = if (route == .redeem)
        browser.redeem_body_size_max
    else
        poll_body_size_max;
    const request = if (route != null) input.navigation_request() catch |err| {
        const response = authentication_error(if (err == error.OutOfMemory)
            error.InternalFailure
        else
            error.BadRequest);
        return aws_http.encode_response(ctx.arena, &response) catch runtime_error_response;
    } else input.application_request();
    var services: RuntimeServices = .{
        .allocator = ctx.arena,
        .io = ctx.io,
        .environment = @field(ctx, "_").kv,
    };
    defer services.deinit();
    var sign_in_store: pending_sign_in.RuntimeStore = .{
        .allocator = ctx.arena,
        .environment = services.environment,
        .config_context = &services,
        .load_config = RuntimeServices.aws_configuration,
    };
    defer sign_in_store.deinit();
    var random_source: std.Random.IoSource = .{ .io = ctx.io };
    const dependencies: Dependencies = if (builtin.is_test and runtime_test_dependencies != null)
        runtime_test_dependencies.?.*
    else
        .{
            .context = &services,
            .random = random_source.interface(),
            .now_ms = RuntimeServices.now,
            .sign_in_entropy_fn = RuntimeServices.sign_in_entropy,
            .read_secret_fn = RuntimeServices.read_secret,
            .send_github_fn = RuntimeServices.send_github,
            .store = sign_in_store.interface(),
        };
    var response = invoke_with_deadline(&ctx, &request, &config, &dependencies) catch
        error_response(.service_unavailable, "service_unavailable");
    defer response.deinit();
    return aws_http.encode_response(ctx.arena, &response) catch
        runtime_error_response;
}

fn invoke_with_deadline(
    ctx: *const lambda.Context,
    request: *const http.HttpRequest,
    config: *const Config,
    dependencies: *const Dependencies,
) !http.HttpResponse {
    const now_ms = std.Io.Clock.real.now(ctx.io).toMilliseconds();
    const remaining_ms = @as(i96, ctx.request.deadline_ms) - now_ms - response_margin_ms;
    if (remaining_ms <= 0) return error.AuthenticationDeadline;
    const duration_ms: i64 = @intCast(@min(remaining_ms, authentication_duration_ms_max));
    const Result = union(enum) { response: http.HttpResponse, deadline: std.Io.Cancelable!void };
    var results: [2]Result = undefined;
    var select: std.Io.Select(Result) = .init(ctx.io, &results);
    // The worker uses only invocation-owned memory. Join before the arena resets.
    defer select.cancelDiscard();
    try select.concurrent(.deadline, std.Io.sleep, .{
        ctx.io, .fromMilliseconds(duration_ms), .awake,
    });
    try select.concurrent(.response, handle_http, .{ ctx.arena, request, config, dependencies });
    return switch (try select.await()) {
        .response => |response| response,
        .deadline => error.AuthenticationDeadline,
    };
}

const RuntimeServices = struct {
    allocator: Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    aws_config: ?aws.Config = null,

    fn deinit(services: *RuntimeServices) void {
        if (services.aws_config) |*config| config.deinit();
    }

    fn now(context: *anyopaque) i64 {
        const services: *RuntimeServices = @ptrCast(@alignCast(context));
        return @intCast(std.Io.Clock.real.now(services.io).toMilliseconds());
    }

    fn sign_in_entropy(
        context: *anyopaque,
        bytes: *[authentication.sign_in_entropy_size]u8,
    ) error{Unavailable}!void {
        const services: *RuntimeServices = @ptrCast(@alignCast(context));
        services.io.randomSecure(bytes) catch return error.Unavailable;
    }

    fn aws_configuration(context: *anyopaque) anyerror!*aws.Config {
        const services: *RuntimeServices = @ptrCast(@alignCast(context));
        if (services.aws_config == null) {
            services.aws_config = try aws.Config.load(
                services.allocator,
                services.io,
                services.environment,
                .{ .max_attempts = 1 },
            );
        }
        return &services.aws_config.?;
    }

    fn read_secret(context: *anyopaque, allocator: Allocator, secret: Secret) SecretError![]u8 {
        const services: *RuntimeServices = @ptrCast(@alignCast(context));
        const arn = services.environment.get(switch (secret) {
            .github_client_secret => "GITHUB_CLIENT_SECRET_ARN",
            .paseto_signing_key => "PASETO_SIGNING_KEY_SECRET_ARN",
        }) orelse return error.MissingSecret;
        if (arn.len == 0) return error.MissingSecret;
        const config = aws_configuration(context) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSecret,
        };
        var client = secretsmanager.Client.initWithOptions(allocator, config, .{
            .max_attempts = 1,
            .max_response_size = secret_response_size_max,
        });
        defer client.deinit();
        var diagnostic: secretsmanager.ServiceError = undefined;
        const result = client.getSecretValue(allocator, .{ .secret_id = arn }, .{
            .diagnostic = &diagnostic,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ServiceError => {
                defer diagnostic.deinit();
                return secret_service_error(diagnostic.kind);
            },
            else => return error.Unavailable,
        };
        const value = result.secret_string orelse return error.InvalidSecret;
        // The pinned SDK allocates parsed strings in the supplied arena.
        return @constCast(value);
    }

    fn send_github(
        context: *anyopaque,
        allocator: Allocator,
        request: *const github.Request,
    ) github.TransportError!github.Response {
        const services: *RuntimeServices = @ptrCast(@alignCast(context));
        return fetch_github(services.io, allocator, request);
    }
};

fn fetch_github(
    io: std.Io,
    allocator: Allocator,
    request: *const github.Request,
) github.TransportError!github.Response {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    const headers = try allocator.alloc(std.http.Header, request.headers.len);
    defer allocator.free(headers);
    for (request.headers, headers) |source, *target| {
        target.* = .{ .name = source.key, .value = source.value };
    }
    const buffer = try allocator.alloc(u8, github.response_size_max);
    var response: std.Io.Writer = .fixed(buffer);
    const result = client.fetch(.{
        .location = .{ .url = request.url },
        .method = request.method,
        .payload = request.body,
        // Zig 0.17 writes extra_headers. Disable redirects for this credential-bearing request.
        .extra_headers = headers,
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{ .accept_encoding = .{ .override = "identity" }, .user_agent = .omit },
        .response_writer = &response,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unavailable,
    };
    return .{ .status = result.status, .body = response.buffered() };
}

fn secret_service_error(kind: secretsmanager.ServiceError.Kind) SecretError {
    return switch (kind) {
        .resource_not_found_exception => error.MissingSecret,
        .decryption_failure,
        .invalid_parameter_exception,
        .invalid_request_exception,
        => error.InvalidSecret,
        .unknown => |failure| classify_unknown_secret_error(failure.http_status, failure.code),
        else => error.Unavailable,
    };
}

fn classify_unknown_secret_error(status: u16, code: []const u8) SecretError {
    if (status == 401 or status == 403) return error.InvalidSecret;
    if (std.mem.eql(u8, code, "AccessDeniedException")) return error.InvalidSecret;
    return error.Unavailable;
}

pub const Config = authentication.Config;
pub const Secret = authentication.Secret;
pub const SecretError = authentication.SecretError;
pub const Dependencies = authentication.Dependencies;
const AuthenticationError = authentication.AuthenticationError;

const unauthorized_headers = authentication.json_headers ++ [_]http.Header{
    .{ .key = "WWW-Authenticate", .value = "Bearer" },
};

pub fn handle_http(
    allocator: Allocator,
    request: *const http.HttpRequest,
    config: *const Config,
    dependencies: *const Dependencies,
) http.HttpResponse {
    const path = request.path orelse return error_response(.not_found, "not_found");
    if (browser.match_route(request.method, path)) |route| {
        return browser.handle(allocator, route, request, config, dependencies) catch |err|
            authentication_error(err);
    }
    if (request.method != .POST) return error_response(.not_found, "not_found");
    if (std.mem.eql(u8, path, "/auth/github/exchange")) {
        const body = exchange_github(allocator, request, config, dependencies) catch |err|
            return authentication_error(err);
        return authentication.json_response(allocator, .ok, body);
    }
    if (std.mem.eql(u8, path, "/auth/github/device/start")) {
        const body = start_github_device(allocator, request, config, dependencies) catch |err|
            return authentication_error(err);
        return authentication.json_response(allocator, .ok, body);
    }
    if (std.mem.eql(u8, path, "/auth/github/device/poll")) {
        return poll_github_device(allocator, request, config, dependencies) catch |err|
            authentication_error(err);
    }
    return error_response(.not_found, "not_found");
}

fn authentication_error(err: AuthenticationError) http.HttpResponse {
    return switch (err) {
        error.BadRequest => error_response(.bad_request, "bad_request"),
        error.Unauthorized => error_response(.unauthorized, "unauthorized"),
        error.InternalFailure => error_response(.internal_server_error, "internal_error"),
        error.Unavailable => error_response(.service_unavailable, "service_unavailable"),
        error.Denied => error_response(.forbidden, "access_denied"),
        error.Gone => error_response(.gone, "expired_or_consumed"),
    };
}

fn start_github_device(
    allocator: Allocator,
    request: *const http.HttpRequest,
    config: *const Config,
    dependencies: *const Dependencies,
) AuthenticationError![]u8 {
    if (!request.body_is_empty()) return error.BadRequest;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var code = try authentication.sign_in_code(dependencies);
    defer std.crypto.secureZero(u8, &code.hex);
    const key = pending_sign_in.key_for(&code);

    const started_ms = dependencies.now_ms(dependencies.context);
    const grant = try github.start_device(
        arena,
        config.github_client_id,
        dependencies.context,
        dependencies.send_github_fn,
    );
    const expires_at_ms = started_ms + @as(i64, grant.expires_in) * 1000;
    const next_poll_at_ms = dependencies.now_ms(dependencies.context) +
        @as(i64, grant.interval) * 1000;
    if (next_poll_at_ms >= expires_at_ms) return error.Unavailable;
    try dependencies.store.create(dependencies.store.context, arena, &key, &.{
        .expires_at_ms = expires_at_ms,
        .state = .{ .pending = .{
            .github_device_code = grant.device_code,
            .next_poll_at_ms = next_poll_at_ms,
            .interval_seconds = grant.interval,
        } },
    });
    const remaining_ms = expires_at_ms - dependencies.now_ms(dependencies.context);
    if (remaining_ms < @as(i64, grant.interval) * 1000) return error.Unavailable;
    return std.json.Stringify.valueAlloc(allocator, .{
        .device_code = &code.hex,
        .user_code = grant.user_code,
        .verification_uri = grant.verification_uri,
        .interval = grant.interval,
        .expires_in = @divFloor(remaining_ms, 1000),
    }, .{}) catch return error.InternalFailure;
}

const PollReservation = struct {
    expires_at_ms: i64,
    polling: pending_sign_in.Polling,
    until_ms: i64,
};

fn poll_github_device(
    allocator: Allocator,
    request: *const http.HttpRequest,
    config: *const Config,
    dependencies: *const Dependencies,
) AuthenticationError!http.HttpResponse {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const key = try poll_key(arena, request);
    const reservation = switch (try reserve_poll(arena, &key, dependencies)) {
        .reserved => |reservation| reservation,
        .retry_after => |seconds| return retry_response(allocator, seconds),
    };
    const reply = github.poll_device(
        arena,
        config.github_client_id,
        reservation.polling.github_device_code,
        dependencies.context,
        dependencies.send_github_fn,
    );
    if (dependencies.now_ms(dependencies.context) >= reservation.expires_at_ms) return error.Gone;
    const interval = reservation.polling.interval_seconds;
    switch (try reply) {
        .expired => {
            _ = try authentication.finish_grant(
                arena,
                dependencies,
                &key,
                reservation.expires_at_ms,
                .{ .finish = .expired },
            );
            return error.Gone;
        },
        .denied => {
            _ = try authentication.finish_grant(
                arena,
                dependencies,
                &key,
                reservation.expires_at_ms,
                .{ .finish = .denied },
            );
            return error.Denied;
        },
        .pending => {
            try reschedule_poll(arena, dependencies, &key, &reservation, interval);
            const body = std.json.Stringify.valueAlloc(allocator, .{
                .@"error" = "authorization_pending",
                .interval = interval,
            }, .{}) catch return error.InternalFailure;
            return authentication.json_response(allocator, .accepted, body);
        },
        .slow_down => |provider_interval| {
            const delay = @max(interval +| 5, provider_interval orelse 0);
            try reschedule_poll(arena, dependencies, &key, &reservation, delay);
            return retry_response(allocator, delay);
        },
        .approved => |token| {
            try reschedule_poll(arena, dependencies, &key, &reservation, interval);
            return finish_approved_poll(
                allocator,
                arena,
                config,
                dependencies,
                &key,
                reservation.expires_at_ms,
                &token,
            );
        },
    }
}

fn reschedule_poll(
    arena: Allocator,
    dependencies: *const Dependencies,
    key: *const pending_sign_in.Key,
    reservation: *const PollReservation,
    interval_seconds: u32,
) AuthenticationError!void {
    const now_ms = dependencies.now_ms(dependencies.context);
    const store = &dependencies.store;
    const changed = try store.change(store.context, arena, key, &.{
        .now_ms = now_ms,
        .transition = .{ .schedule = .{
            .expected_at_ms = reservation.until_ms,
            .next_at_ms = now_ms + @as(i64, interval_seconds) * 1000,
            .interval_seconds = interval_seconds,
        } },
    });
    if (!changed) return error.Gone;
    if (dependencies.now_ms(dependencies.context) >= reservation.expires_at_ms) return error.Gone;
}

fn poll_key(
    arena: Allocator,
    request: *const http.HttpRequest,
) AuthenticationError!pending_sign_in.Key {
    const body = (request.read_body(arena) catch |err| switch (err) {
        error.OutOfMemory => return error.InternalFailure,
        else => return error.BadRequest,
    }) orelse return error.BadRequest;
    if (body.len > poll_body_size_max) return error.BadRequest;
    const fields = std.json.parseFromSliceLeaky(
        struct { device_code: []const u8 },
        arena,
        body,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.InternalFailure,
        else => return error.BadRequest,
    };
    var code = pending_sign_in.parse_code(fields.device_code) catch return error.BadRequest;
    defer std.crypto.secureZero(u8, &code.hex);
    return pending_sign_in.key_for(&code);
}

fn reserve_poll(
    arena: Allocator,
    key: *const pending_sign_in.Key,
    dependencies: *const Dependencies,
) AuthenticationError!union(enum) { reserved: PollReservation, retry_after: i64 } {
    const store = &dependencies.store;
    // A second read lets contention report the winner's updated schedule or terminal state.
    for (0..2) |_| {
        const grant = try store.read(store.context, arena, key) orelse return error.Gone;
        const now_ms = dependencies.now_ms(dependencies.context);
        if (now_ms >= grant.expires_at_ms) return error.Gone;
        const polling = switch (grant.state) {
            .consumed, .expired, .browser_pending, .browser_approved => return error.Gone,
            .denied => return error.Denied,
            .pending => |polling| polling,
        };
        if (now_ms < polling.next_poll_at_ms) {
            const delay = std.math.divCeil(i64, polling.next_poll_at_ms - now_ms, 1000) catch
                unreachable;
            return .{ .retry_after = delay };
        }
        // Prevent overlapping GitHub polls until the invocation deadline and the next
        // provider interval have passed. A received reply can shorten this reservation.
        const until_ms = now_ms + authentication_duration_ms_max +
            @as(i64, polling.interval_seconds) * 1000;
        if (try store.change(store.context, arena, key, &.{
            .now_ms = now_ms,
            .transition = .{ .schedule = .{
                .expected_at_ms = polling.next_poll_at_ms,
                .next_at_ms = until_ms,
                .interval_seconds = polling.interval_seconds,
            } },
        })) return .{ .reserved = .{
            .polling = polling,
            .expires_at_ms = grant.expires_at_ms,
            .until_ms = until_ms,
        } };
    }
    return error.Unavailable;
}

fn finish_approved_poll(
    allocator: Allocator,
    arena: Allocator,
    config: *const Config,
    dependencies: *const Dependencies,
    key: *const pending_sign_in.Key,
    expires_at_ms: i64,
    token: *const github.AccessToken,
) AuthenticationError!http.HttpResponse {
    const verified_tenant = verify_github_token(arena, config, dependencies, token);
    const tenant = verified_tenant catch |err| switch (err) {
        error.Unauthorized => return error.Unavailable,
        else => |failure| return failure,
    };
    const signing_key = try authentication.read_secret(arena, dependencies, .paseto_signing_key);
    defer std.crypto.secureZero(u8, signing_key);
    const issued_at_ms = try authentication.finish_grant(arena, dependencies, key, expires_at_ms, .{
        .finish = .consumed,
    });
    const body = try token_issuer.issue(allocator, dependencies.random, &.{
        .subject = tenant,
        .now_seconds = @divFloor(issued_at_ms, 1000),
        .signing_key_base64 = signing_key,
        .public_key_base64 = config.paseto_public_key,
    });
    return authentication.json_response(allocator, .ok, body);
}

fn retry_response(allocator: Allocator, seconds: i64) AuthenticationError!http.HttpResponse {
    std.debug.assert(seconds > 0);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const value = std.fmt.allocPrint(arena.allocator(), "{d}", .{seconds}) catch
        return error.InternalFailure;
    const headers = arena.allocator().dupe(
        http.Header,
        authentication.json_headers ++ [_]http.Header{.{ .key = "Retry-After", .value = value }},
    ) catch return error.InternalFailure;
    return .{
        .status = .too_many_requests,
        .headers = headers,
        .headers_arena = arena,
        .body = "{\"error\":\"slow_down\"}",
    };
}

fn exchange_github(
    allocator: Allocator,
    request: *const http.HttpRequest,
    config: *const Config,
    dependencies: *const Dependencies,
) AuthenticationError![]u8 {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const bearer = lambda_auth.bearer_token(request.headers) catch return error.Unauthorized;
    const token = try github.AccessToken.parse(bearer);
    const tenant = try verify_github_token(arena, config, dependencies, &token);
    if (!request.body_is_empty()) return error.BadRequest;

    const signing_key = try authentication.read_secret(arena, dependencies, .paseto_signing_key);
    defer std.crypto.secureZero(u8, signing_key);
    return token_issuer.issue(allocator, dependencies.random, &.{
        .subject = tenant,
        .now_seconds = @divFloor(dependencies.now_ms(dependencies.context), 1000),
        .signing_key_base64 = signing_key,
        .public_key_base64 = config.paseto_public_key,
    });
}

fn verify_github_token(
    arena: Allocator,
    config: *const Config,
    dependencies: *const Dependencies,
    token: *const github.AccessToken,
) github.Error![]const u8 {
    // An Operations credential must stay with the Operations API.
    if (std.mem.startsWith(u8, token.bytes, "v4.public.")) return error.Unauthorized;

    const client_secret = try authentication.read_secret(
        arena,
        dependencies,
        .github_client_secret,
    );
    defer std.crypto.secureZero(u8, client_secret);
    return github.resolve_tenant(arena, &.{
        .client_id = config.github_client_id,
        .client_secret = client_secret,
        .access_token = token.*,
    }, dependencies.context, dependencies.send_github_fn);
}

fn error_response(status: std.http.Status, comptime code: []const u8) http.HttpResponse {
    return .{
        .status = status,
        .headers = if (status == .unauthorized)
            unauthorized_headers
        else
            authentication.json_headers,
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

pub const testing = if (builtin.is_test) struct {
    pub const Services = TestServices;
    pub const Diagnostics = TestDiagnostics;
    pub const GrantFinishGate = FinishGate;
    pub const TokenResponse = IssuedToken;

    pub const now_seconds = test_now_seconds;
    pub const client_id = test_client_id;
    pub const client_secret = test_client_secret;
    pub const provider_token = test_provider_token;
    pub const github_identity = test_github_identity;

    pub const header = test_header;
    pub const expect_response_header = expect_header;
    pub const issued_token = read_issued_token;
    pub const run_runtime = run_runtime_with_dependencies;
    pub const fetch_github_http = fetch_github;
} else void;
fn test_header(headers: []const http.Header, name: []const u8) error{MissingHeader}![]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.key, name)) return header.value;
    }
    return error.MissingHeader;
}
const test_exchange: http.HttpRequest = .{
    .method = .POST,
    .path = "/auth/github/exchange",
    .headers = &.{.{ .key = "Authorization", .value = "Bearer " ++ test_provider_token }},
};

const test_exchange_event =
    \\{"version":"2.0","routeKey":"POST /auth/github/exchange","rawPath":"/auth/github/exchange",
    \\"requestContext":{"http":{"method":"POST"}},"isBase64Encoded":false,
    \\"headers":{"authorization":"Bearer
++ " " ++ test_provider_token ++ "\"}}";

test "runtime integration: GitHub exchange rejects a token for another OAuth App" {
    if (comptime !runtime_tests_enabled) return error.SkipZigTest;
    const runtime = @import("runtime_test_support");
    var fixture: runtime.Fixture = .{};
    defer fixture.deinit();
    var services: TestServices = undefined;
    try services.init();
    defer services.deinit();
    const io = std.testing.io;
    const loopback: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var github_server = try loopback.listen(io, .{ .mode = .stream });
    defer github_server.deinit(io);
    services.token_check_url = try std.fmt.allocPrint(
        fixture.allocator(),
        "http://{f}/applications/configured-client/token",
        .{github_server.socket.address},
    );
    var github_reply = try io.concurrent(reply_with_other_app, .{ &github_server, io });
    defer github_reply.cancel(io) catch {};
    const response = try run_runtime_authentication(&fixture, &services, test_exchange_event);
    try std.testing.expectEqual(401, response.object.get("statusCode").?.integer);
    try std.testing.expectEqualStrings(
        "Bearer",
        response.object.get("headers").?.object.get("WWW-Authenticate").?.string,
    );
    try std.testing.expectEqual(1, services.github_checks);
    try std.testing.expectEqual(0, services.signing_key_reads);
    try github_reply.await(io);
}

fn reply_with_other_app(listener: *std.Io.net.Server, io: std.Io) !void {
    const connection = try listener.accept(io);
    defer connection.close(io);
    var input_buffer: [4096]u8 = undefined;
    var output_buffer: [1024]u8 = undefined;
    var reader = connection.reader(io, &input_buffer);
    var writer = connection.writer(io, &output_buffer);
    var server: std.http.Server = .init(&reader.interface, &writer.interface);
    var request = try server.receiveHead();
    try std.testing.expectEqual(.POST, request.head.method);
    try std.testing.expectEqualStrings("/applications/configured-client/token", request.head.target);
    try std.testing.expectEqualStrings("application/json", request.head.content_type.?);
    var headers = request.iterateHeaders();
    var user_agents: u8 = 0;
    var has_api_version = false;
    var has_basic_authorization = false;
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "User-Agent")) {
            try std.testing.expectEqualStrings("operations-api", header.value);
            user_agents += 1;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "X-GitHub-Api-Version")) {
            has_api_version = header.value.len > 0;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "Authorization")) {
            has_basic_authorization = std.mem.startsWith(u8, header.value, "Basic ");
        }
    }
    try std.testing.expectEqual(1, user_agents);
    try std.testing.expect(has_api_version);
    try std.testing.expect(has_basic_authorization);
    const expected_body = "{\"access_token\":\"" ++ test_provider_token ++ "\"}";
    try std.testing.expectEqual(expected_body.len, request.head.content_length.?);
    var body_buffer: [expected_body.len]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&body_buffer);
    try std.testing.expectEqualStrings(expected_body, try body_reader.take(expected_body.len));
    try request.respond(
        \\{"app":{"client_id":"other-client"},"user":{"id":42}}
    ,
        .{ .status = .ok, .keep_alive = false },
    );
}

test "runtime integration: GitHub exchange posts a verifiable tenant PASETO" {
    if (comptime !runtime_tests_enabled) return error.SkipZigTest;
    const runtime = @import("runtime_test_support");
    var fixture: runtime.Fixture = .{};
    defer fixture.deinit();
    var services: TestServices = undefined;
    try services.init();
    defer services.deinit();

    const response = try run_runtime_authentication(&fixture, &services, test_exchange_event);
    try std.testing.expectEqual(200, response.object.get("statusCode").?.integer);
    try std.testing.expectEqualStrings(
        "no-store",
        response.object.get("headers").?.object.get("Cache-Control").?.string,
    );
    const fields = try std.json.parseFromSliceLeaky(
        IssuedToken,
        fixture.allocator(),
        response.object.get("body").?.string,
        .{},
    );
    var claims = try paseto.verify(
        std.testing.allocator,
        fields.access_token,
        services.key_pair.public_key,
        test_now_seconds,
    );
    defer claims.deinit();
    try std.testing.expectEqualStrings("github:42", claims.sub);
    try std.testing.expectEqual(test_now_seconds + 28800, claims.exp);
}

test "runtime integration: GitHub authentication fallback is no-store" {
    if (comptime !runtime_tests_enabled) return error.SkipZigTest;
    const runtime = @import("runtime_test_support");
    var fixture: runtime.Fixture = .{};
    defer fixture.deinit();
    var services: TestServices = undefined;
    try services.init();
    defer services.deinit();
    const response = try run_runtime_authentication(&fixture, &services, "{");
    try std.testing.expectEqual(500, response.object.get("statusCode").?.integer);
    try std.testing.expectEqualStrings(
        "no-store",
        response.object.get("headers").?.object.get("Cache-Control").?.string,
    );
    try std.testing.expectEqualStrings(
        "{\"error\":\"internal_error\"}",
        response.object.get("body").?.string,
    );
}

fn run_runtime_authentication(
    fixture: *@import("runtime_test_support").Fixture,
    services: *TestServices,
    event: []const u8,
) !std.json.Value {
    return run_runtime_with_dependencies(fixture, &services.dependencies(), .{
        .event = event,
        .public_key = &services.public_key,
    });
}

fn run_runtime_with_dependencies(
    fixture: *@import("runtime_test_support").Fixture,
    dependencies: *const Dependencies,
    options: struct {
        event: []const u8,
        public_key: []const u8,
        environment: []const struct { name: []const u8, value: []const u8 } = &.{},
    },
) !std.json.Value {
    const now_ms: u64 = @intCast(std.Io.Clock.real.now(std.testing.io).toMilliseconds());
    const script = [_]@import("runtime_test_support").Tester.Event{.{
        .request_id = "exchange",
        .deadline_ms = now_ms + 30_000,
        .payload = options.event,
    }};
    try fixture.init(&script);
    try fixture.tester.env_map.put("GITHUB_CLIENT_ID", test_client_id);
    try fixture.tester.env_map.put("PASETO_PUBLIC_KEY", options.public_key);
    for (options.environment) |variable| {
        try fixture.tester.env_map.put(variable.name, variable.value);
    }
    std.debug.assert(runtime_test_dependencies == null);
    runtime_test_dependencies = dependencies;
    defer runtime_test_dependencies = null;

    main(fixture.tester.processInit());
    try fixture.tester.expectPostCount(1);
    try fixture.tester.expectPath(0, "/2018-06-01/runtime/invocation/exchange/response");
    return std.json.parseFromSliceLeaky(
        std.json.Value,
        fixture.allocator(),
        (try fixture.tester.post(0)).body,
        .{},
    );
}

const FinishGate = struct {
    pub const timeout: std.Io.Timeout = .{ .duration = .{
        .clock = .awake,
        .raw = .fromSeconds(5),
    } };
    arrivals: std.atomic.Value(u8) = .init(0),
    first_arrived: std.Io.Event = .unset,
    both_arrived: std.Io.Event = .unset,

    pub fn arrive(gate: *FinishGate, io: std.Io) pending_sign_in.Error!void {
        const previous = gate.arrivals.fetchAdd(1, .monotonic);
        std.debug.assert(previous < 2);
        if (previous == 0) {
            gate.first_arrived.set(io);
            gate.both_arrived.waitTimeout(io, timeout) catch return error.Unavailable;
        } else {
            gate.both_arrived.set(io);
        }
    }
};

const TestDiagnostics = struct {
    mutex: std.Io.Mutex = .init,
    bytes: [4096]u8 = undefined,
    len: usize = 0,
    overflow: bool = false,

    pub fn start(capture: *TestDiagnostics) void {
        std.debug.assert(test_diagnostics == null);
        test_diagnostics = capture;
    }

    pub fn stop(capture: *TestDiagnostics) void {
        std.debug.assert(test_diagnostics == capture);
        test_diagnostics = null;
    }

    pub fn expect_no_credentials(
        capture: *const TestDiagnostics,
        credentials: []const []const u8,
    ) !void {
        try std.testing.expect(!capture.overflow);
        const diagnostics = capture.bytes[0..capture.len];
        for (credentials) |credential| {
            try std.testing.expect(std.mem.indexOf(u8, diagnostics, credential) == null);
        }
    }
};

fn capture_test_log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const capture = test_diagnostics orelse return std.log.defaultLog(level, scope, format, args);
    const io = std.testing.io;
    capture.mutex.lockUncancelable(io);
    defer capture.mutex.unlock(io);
    const message = std.fmt.bufPrint(capture.bytes[capture.len..], format ++ "\n", args) catch {
        capture.overflow = true;
        return;
    };
    capture.len += message.len;
}

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
    github_result: github.TransportError!github.Response,
    app_secret: SecretError![]const u8,
    signing_key: SecretError![]const u8,
    expected_provider_token: []const u8,
    app_secret_reads: u8,
    signing_key_reads: u8,
    github_checks: u8,
    token_check_url: ?[]const u8,

    pub fn init(fixture: *TestServices) !void {
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
        fixture.token_check_url = null;
    }

    pub fn deinit(fixture: *TestServices) void {
        paseto.wipeSecretKey(&fixture.key_pair.secret_key);
        std.crypto.secureZero(u8, &fixture.private_key);
    }

    pub fn config(fixture: *const TestServices) Config {
        return .{
            .github_client_id = test_client_id,
            .paseto_public_key = &fixture.public_key,
        };
    }

    fn invoke(fixture: *TestServices, request: *const http.HttpRequest) http.HttpResponse {
        return handle_http(
            std.testing.allocator,
            request,
            &fixture.config(),
            &fixture.dependencies(),
        );
    }

    pub fn dependencies(fixture: *TestServices) Dependencies {
        return .{
            .context = fixture,
            .random = fixture.random.random(),
            .now_ms = now,
            .sign_in_entropy_fn = sign_in_entropy,
            .read_secret_fn = TestServices.read_secret,
            .send_github_fn = send_github,
            .store = .{
                .context = fixture,
                .create = unavailable_store_create,
                .read = unavailable_store_read,
                .change = unavailable_store_change,
            },
        };
    }

    fn now(context: *anyopaque) i64 {
        const fixture: *TestServices = @ptrCast(@alignCast(context));
        return fixture.now_seconds * 1000;
    }

    fn sign_in_entropy(
        context: *anyopaque,
        bytes: *[authentication.sign_in_entropy_size]u8,
    ) error{Unavailable}!void {
        const fixture: *TestServices = @ptrCast(@alignCast(context));
        fixture.random.random().bytes(bytes);
    }

    fn unavailable_store_create(
        _: *anyopaque,
        _: Allocator,
        _: *const pending_sign_in.Key,
        _: *const pending_sign_in.Grant,
    ) pending_sign_in.Error!void {
        return error.Unavailable;
    }

    fn unavailable_store_read(
        _: *anyopaque,
        _: Allocator,
        _: *const pending_sign_in.Key,
    ) pending_sign_in.Error!?pending_sign_in.Grant {
        return error.Unavailable;
    }

    fn unavailable_store_change(
        _: *anyopaque,
        _: Allocator,
        _: *const pending_sign_in.Key,
        _: *const pending_sign_in.Change,
    ) pending_sign_in.Error!bool {
        return error.Unavailable;
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

    pub fn send_github(
        context: *anyopaque,
        allocator: Allocator,
        request: *const github.Request,
    ) github.TransportError!github.Response {
        const fixture: *TestServices = @ptrCast(@alignCast(context));
        std.testing.expectEqual(.POST, request.method) catch unreachable;
        std.testing.expectEqualStrings(
            "https://api.github.com/applications/configured-client/token",
            request.url,
        ) catch unreachable;
        try expect_token_check_request(allocator, request, fixture.expected_provider_token);
        fixture.github_checks += 1;
        if (fixture.token_check_url) |url| {
            var local_request = request.*;
            local_request.url = url;
            return fetch_github(std.testing.io, allocator, &local_request);
        }
        return fixture.github_result;
    }
};

fn expect_token_check_request(
    allocator: Allocator,
    request: *const github.Request,
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
    const actual = test_header(headers, name) catch return error.TestExpectedHeader;
    return std.testing.expectEqualStrings(value, actual);
}
