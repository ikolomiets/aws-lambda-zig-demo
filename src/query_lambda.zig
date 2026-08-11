const std = @import("std");
const aws = @import("aws");
const lambda = @import("aws-lambda");
const lambda_auth = @import("lambda_auth");
const operation = @import("operation");
const operation_persistence = @import("operation_persistence");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{
        .scope = .aws_sdk,
        .level = .debug,
    }},
};

const Allocator = std.mem.Allocator;

const bad_request_body = "Bad Request\n";
const content_type_json = "application/json";
const content_type_text = "text/plain; charset=utf-8";
const internal_server_error_body = "Internal Server Error\n";
const internal_server_error_response =
    "{\"statusCode\":500,\"headers\":{\"Content-Type\":\"" ++ content_type_text ++
    "\"},\"body\":\"Internal Server Error\\n\"}";
const method_not_allowed_body = "Method Not Allowed\n";
const not_found_body = "Not Found\n";
const service_unavailable_body = "Service Unavailable\n";
const unauthorized_body = "Unauthorized\n";

comptime {
    std.debug.assert(lambda_auth.subject_size_max == operation.tenant_size_max);
}

var runtime_query_adapter: ?QueryAdapter = null;

pub fn main(init: std.process.Init) void {
    var resources: RuntimeResources = undefined;
    resources.init(init) catch |err| {
        std.log.err("Lambda initialization failed: {s}", .{@errorName(err)});
        return;
    };
    defer resources.deinit();

    installRuntimeQueryAdapter(QueryAdapter.init(&resources));
    defer uninstallRuntimeQueryAdapter();
    lambda.handle(init, handler, .{});
}

fn handler(ctx: lambda.Context, event: []const u8) ![]const u8 {
    const query = runtime_query_adapter orelse {
        return error.PersistenceNotInitialized;
    };
    const now = std.Io.Clock.real.now(ctx.io).toSeconds();
    return handleInvocation(
        ctx.arena,
        event,
        @field(ctx, "_").kv,
        query,
        now,
    );
}

const RuntimeResources = struct {
    config: aws.Config,
    persistence: operation_persistence.Persistence,

    fn init(resources: *RuntimeResources, process_init: std.process.Init) !void {
        resources.config = aws.Config.load(
            process_init.gpa,
            process_init.io,
            process_init.environ_map,
            .{},
        ) catch return error.AWSConfigurationFailure;
        errdefer resources.config.deinit();

        operation_persistence.Persistence.init(
            &resources.persistence,
            process_init.gpa,
            &resources.config,
            process_init.environ_map,
        ) catch return error.PersistenceConfigurationFailure;
    }

    fn deinit(resources: *RuntimeResources) void {
        resources.persistence.deinit();
        resources.config.deinit();
        resources.* = undefined;
    }

    fn read(
        resources: *RuntimeResources,
        arena: Allocator,
        id: u128,
    ) !operation.Operation {
        return resources.persistence.read(arena, id);
    }
};

const QueryAdapter = struct {
    context: *anyopaque,
    read_fn: *const fn (
        *anyopaque,
        Allocator,
        u128,
    ) anyerror!operation.Operation,

    fn init(pointer: anytype) QueryAdapter {
        const Pointer = @TypeOf(pointer);
        const pointer_info = @typeInfo(Pointer);
        comptime std.debug.assert(pointer_info == .pointer);
        comptime std.debug.assert(pointer_info.pointer.size == .one);

        const Adapter = struct {
            fn read(
                context: *anyopaque,
                allocator: Allocator,
                id: u128,
            ) anyerror!operation.Operation {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.read(allocator, id);
            }
        };
        return .{
            .context = pointer,
            .read_fn = Adapter.read,
        };
    }

    fn read(
        query: QueryAdapter,
        allocator: Allocator,
        id: u128,
    ) !operation.Operation {
        return query.read_fn(query.context, allocator, id);
    }
};

fn installRuntimeQueryAdapter(query: QueryAdapter) void {
    std.debug.assert(runtime_query_adapter == null);
    runtime_query_adapter = query;
    std.debug.assert(runtime_query_adapter != null);
}

fn uninstallRuntimeQueryAdapter() void {
    std.debug.assert(runtime_query_adapter != null);
    runtime_query_adapter = null;
    std.debug.assert(runtime_query_adapter == null);
}

fn handleInvocation(
    allocator: Allocator,
    event: []const u8,
    environment: *const std.process.Environ.Map,
    query: QueryAdapter,
    now: i64,
) []const u8 {
    const outcome = invocationOutcome(allocator, event, environment, query, now);
    return encodeOutcome(allocator, outcome) catch internal_server_error_response;
}

const InvocationOutcome = union(enum) {
    success: []const u8,
    bad_request,
    method_not_allowed,
    not_found,
    service_unavailable,
    unauthorized,
    internal_server_error,
};

fn invocationOutcome(
    allocator: Allocator,
    event: []const u8,
    environment: *const std.process.Environ.Map,
    query: QueryAdapter,
    now: i64,
) InvocationOutcome {
    const request = lambda.url.parseRequest(allocator, event) catch {
        return .internal_server_error;
    };
    defer request.deinit(allocator);
    var identity = lambda_auth.authenticate(
        allocator,
        &request,
        environment,
        now,
    ) catch |err| {
        return switch (err) {
            error.Unauthorized => .unauthorized,
            error.InternalFailure => .internal_server_error,
        };
    };
    defer identity.deinit();

    const method = request.request_context.http.method orelse {
        return .method_not_allowed;
    };
    if (method != .GET) return .method_not_allowed;
    return queryInvocationOutcome(allocator, identity.subject, &request, query);
}

fn queryInvocationOutcome(
    allocator: Allocator,
    tenant: []const u8,
    request: *const lambda.url.Request,
    query: QueryAdapter,
) InvocationOutcome {
    std.debug.assert(tenant.len > 0);
    std.debug.assert(tenant.len <= operation.tenant_size_max);

    const id = operationIDFromRawPath(request.raw_path) catch {
        return .bad_request;
    };
    var operation_arena = std.heap.ArenaAllocator.init(allocator);
    defer operation_arena.deinit();
    const persisted = query.read(operation_arena.allocator(), id) catch |err| {
        return switch (err) {
            error.OperationNotFound => .not_found,
            error.AWSFailure => .service_unavailable,
            else => .internal_server_error,
        };
    };
    if (!std.mem.eql(u8, persisted.tenant, tenant)) return .not_found;

    const body = operationOutputBody(allocator, &persisted) catch {
        return .internal_server_error;
    };
    return .{ .success = body };
}

fn operationIDFromRawPath(raw_path: ?[]const u8) !u128 {
    const path = raw_path orelse return error.InvalidPath;
    if (path.len != 37) return error.InvalidPath;
    if (path[0] != '/') return error.InvalidPath;
    const id = operation.uuidFromString(path[1..]) catch return error.InvalidPath;
    std.debug.assert(path[1..].len == 36);
    return id;
}

fn operationOutputBody(
    allocator: Allocator,
    persisted: *const operation.Operation,
) ![]const u8 {
    try operation.validatePersistent(persisted);
    std.debug.assert(persisted.body == null);

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try operation.writeOutputJSON(&output.writer, persisted);
    std.debug.assert(output.written().len > 0);
    return output.toOwnedSlice();
}

fn encodeOutcome(
    allocator: Allocator,
    outcome: InvocationOutcome,
) ![]const u8 {
    return switch (outcome) {
        .success => |body| success: {
            defer allocator.free(body);
            break :success lambda.url.encodeResponse(allocator, .{
                .content_type = content_type_json,
                .body = .{ .textual = body },
            });
        },
        .bad_request => lambda.url.encodeResponse(allocator, .{
            .content_type = content_type_text,
            .status_code = .bad_request,
            .body = .{ .textual = bad_request_body },
        }),
        .method_not_allowed => lambda.url.encodeResponse(allocator, .{
            .content_type = content_type_text,
            .status_code = .method_not_allowed,
            .headers = &.{.{ .key = "Allow", .value = "GET" }},
            .body = .{ .textual = method_not_allowed_body },
        }),
        .not_found => lambda.url.encodeResponse(allocator, .{
            .content_type = content_type_text,
            .status_code = .not_found,
            .body = .{ .textual = not_found_body },
        }),
        .service_unavailable => lambda.url.encodeResponse(allocator, .{
            .content_type = content_type_text,
            .status_code = .service_unavailable,
            .body = .{ .textual = service_unavailable_body },
        }),
        .unauthorized => lambda.url.encodeResponse(allocator, .{
            .content_type = content_type_text,
            .status_code = .unauthorized,
            .headers = &.{.{ .key = "WWW-Authenticate", .value = "Bearer" }},
            .body = .{ .textual = unauthorized_body },
        }),
        .internal_server_error => lambda.url.encodeResponse(allocator, .{
            .content_type = content_type_text,
            .status_code = .internal_server_error,
            .body = .{ .textual = internal_server_error_body },
        }),
    };
}

const FakeQuery = struct {
    response: ?operation.Operation = null,
    read_error: ?anyerror = null,
    read_count: u8 = 0,
    last_id: u128 = 0,

    fn read(
        fake: *FakeQuery,
        _: Allocator,
        id: u128,
    ) !operation.Operation {
        std.debug.assert(fake.read_count < 32);
        fake.read_count += 1;
        fake.last_id = id;
        if (fake.read_error) |err| return err;
        return fake.response orelse error.OperationNotFound;
    }
};

fn handleInvocationForTest(
    allocator: Allocator,
    event: []const u8,
    environment: *const std.process.Environ.Map,
    fake: *FakeQuery,
    now: i64,
) []const u8 {
    return handleInvocation(
        allocator,
        event,
        environment,
        QueryAdapter.init(fake),
        now,
    );
}

fn testOperation(tenant: []const u8, state: operation.State) operation.Operation {
    return .{
        .id = operation.uuidFromString(
            "00112233-4455-6677-8899-aabbccddeeff",
        ) catch unreachable,
        .tenant = tenant,
        .name = "echo",
        .state = state,
        .last_updated = 1_700_000_123,
        .expires_at = 1_700_086_523,
        .result = if (operation.stateIsTerminal(state)) .{ .string = "done" } else null,
        .hash = [_]u8{0xab} ** 32,
    };
}

test "AWS SDK exposes the runtime configuration type" {
    comptime {
        std.debug.assert(@TypeOf(aws.Config) == type);
    }
}

test "AWS SDK debug logging is enabled" {
    try std.testing.expectEqual(std.log.default_level, std_options.log_level);
    try std.testing.expectEqual(@as(usize, 1), std_options.log_scope_levels.len);
    try std.testing.expect(std_options.log_scope_levels[0].scope == .aws_sdk);
    try std.testing.expectEqual(
        std.log.Level.debug,
        std_options.log_scope_levels[0].level,
    );
    try std.testing.expect(std.log.logEnabled(.debug, .aws_sdk));
}

test "authenticated GET returns exact pending operation JSON and canonicalizes UUID" {
    const token = try testToken(0x71);
    defer std.testing.allocator.free(token);
    var environment = try testEnvironment(0x71);
    defer environment.deinit();
    const event = try testRequestEvent(.{
        .method = .GET,
        .token = token,
        .raw_path = "/00112233-4455-6677-8899-AABBCCDDEEFF",
        .raw_query = "id=ffffffff-ffff-ffff-ffff-ffffffffffff",
        .body = "ffffffff-ffff-ffff-ffff-ffffffffffff",
    });
    defer std.testing.allocator.free(event);
    var fake = FakeQuery{ .response = testOperation("lambda-test-user", .running) };

    const response = handleInvocationForTest(
        std.testing.allocator,
        event,
        &environment,
        &fake,
        1000,
    );
    defer std.testing.allocator.free(response);

    const expected =
        "{\"statusCode\":200,\"headers\":{\"Content-Type\":\"application/json\"}," ++
        "\"body\":\"{\\\"id\\\":\\\"00112233-4455-6677-8899-aabbccddeeff\\\"," ++
        "\\\"tenant\\\":\\\"lambda-test-user\\\",\\\"name\\\":\\\"echo\\\"," ++
        "\\\"state\\\":\\\"RUNNING\\\",\\\"last_updated\\\":1700000123," ++
        "\\\"expires_at\\\":1700086523," ++
        "\\\"hash\\\":\\\"" ++ ("ab" ** 32) ++ "\\\"}\"}";
    try std.testing.expectEqualStrings(expected, response);
    try std.testing.expectEqual(
        operation.uuidFromString("00112233-4455-6677-8899-aabbccddeeff") catch unreachable,
        fake.last_id,
    );
    try std.testing.expectEqual(@as(u8, 1), fake.read_count);
}

test "authenticated GET returns exact terminal operation JSON with result" {
    const token = try testToken(0x72);
    defer std.testing.allocator.free(token);
    var environment = try testEnvironment(0x72);
    defer environment.deinit();
    const event = try testRequestEvent(.{
        .method = .GET,
        .token = token,
        .raw_path = "/00112233-4455-6677-8899-aabbccddeeff",
    });
    defer std.testing.allocator.free(event);
    var fake = FakeQuery{ .response = testOperation("lambda-test-user", .succeeded) };

    const response = handleInvocationForTest(
        std.testing.allocator,
        event,
        &environment,
        &fake,
        1000,
    );
    defer std.testing.allocator.free(response);

    const expected =
        "{\"statusCode\":200,\"headers\":{\"Content-Type\":\"application/json\"}," ++
        "\"body\":\"{\\\"id\\\":\\\"00112233-4455-6677-8899-aabbccddeeff\\\"," ++
        "\\\"tenant\\\":\\\"lambda-test-user\\\",\\\"name\\\":\\\"echo\\\"," ++
        "\\\"state\\\":\\\"SUCCEEDED\\\",\\\"last_updated\\\":1700000123," ++
        "\\\"expires_at\\\":1700086523,\\\"result\\\":\\\"done\\\"," ++
        "\\\"hash\\\":\\\"" ++ ("ab" ** 32) ++ "\\\"}\"}";
    try std.testing.expectEqualStrings(expected, response);
}

test "missing malformed nested and trailing paths do not read persistence" {
    const token = try testToken(0x73);
    defer std.testing.allocator.free(token);
    var environment = try testEnvironment(0x73);
    defer environment.deinit();
    const paths = [_]?[]const u8{
        null,
        "",
        "/",
        "00112233-4455-6677-8899-aabbccddeeff",
        "/00112233-4455-6677-8899-aabbccddeefg",
        "/nested/00112233-4455-6677-8899-aabbccddeeff",
        "/00112233-4455-6677-8899-aabbccddeeff/",
    };

    for (paths) |path| {
        const event = try testRequestEvent(.{
            .method = .GET,
            .token = token,
            .raw_path = path,
        });
        defer std.testing.allocator.free(event);
        var fake: FakeQuery = .{};
        const response = handleInvocationForTest(
            std.testing.allocator,
            event,
            &environment,
            &fake,
            1000,
        );
        defer std.testing.allocator.free(response);

        try std.testing.expectEqualStrings(
            "{\"statusCode\":400,\"headers\":{\"Content-Type\":\"" ++
                content_type_text ++ "\"},\"body\":\"Bad Request\\n\"}",
            response,
        );
        try std.testing.expectEqual(@as(u8, 0), fake.read_count);
    }
}

test "missing and cross-tenant operations return identical static not found response" {
    const token = try testToken(0x74);
    defer std.testing.allocator.free(token);
    var environment = try testEnvironment(0x74);
    defer environment.deinit();
    const event = try testRequestEvent(.{
        .method = .GET,
        .token = token,
        .raw_path = "/00112233-4455-6677-8899-aabbccddeeff",
    });
    defer std.testing.allocator.free(event);
    var missing = FakeQuery{ .read_error = error.OperationNotFound };
    var foreign = FakeQuery{ .response = testOperation("another-tenant", .running) };

    const missing_response = handleInvocationForTest(
        std.testing.allocator,
        event,
        &environment,
        &missing,
        1000,
    );
    defer std.testing.allocator.free(missing_response);
    const foreign_response = handleInvocationForTest(
        std.testing.allocator,
        event,
        &environment,
        &foreign,
        1000,
    );
    defer std.testing.allocator.free(foreign_response);

    const expected = "{\"statusCode\":404,\"headers\":{\"Content-Type\":\"" ++
        content_type_text ++ "\"},\"body\":\"Not Found\\n\"}";
    try std.testing.expectEqualStrings(expected, missing_response);
    try std.testing.expectEqualStrings(expected, foreign_response);
    try expectNotContains(foreign_response, "another-tenant");
    try expectNotContains(foreign_response, "echo");
    try std.testing.expectEqual(@as(u8, 1), missing.read_count);
    try std.testing.expectEqual(@as(u8, 1), foreign.read_count);
}

test "AWS read failure returns service unavailable and other failures are sanitized" {
    const token = try testToken(0x75);
    defer std.testing.allocator.free(token);
    var environment = try testEnvironment(0x75);
    defer environment.deinit();
    const event = try testRequestEvent(.{
        .method = .GET,
        .token = token,
        .raw_path = "/00112233-4455-6677-8899-aabbccddeeff",
    });
    defer std.testing.allocator.free(event);
    const failures = [_]anyerror{
        error.AWSFailure,
        error.InvalidItem,
        error.OutOfMemory,
        error.UnexpectedPersistenceFailure,
    };

    for (failures) |failure| {
        var fake = FakeQuery{ .read_error = failure };
        const response = handleInvocationForTest(
            std.testing.allocator,
            event,
            &environment,
            &fake,
            1000,
        );
        defer std.testing.allocator.free(response);
        const expected = if (failure == error.AWSFailure)
            "{\"statusCode\":503,\"headers\":{\"Content-Type\":\"" ++
                content_type_text ++ "\"},\"body\":\"Service Unavailable\\n\"}"
        else
            internal_server_error_response;
        try std.testing.expectEqualStrings(expected, response);
        try expectNotContains(response, @errorName(failure));
    }
}

test "authentication and method checks happen before persistence" {
    const token = try testToken(0x76);
    defer std.testing.allocator.free(token);
    var environment = try testEnvironment(0x76);
    defer environment.deinit();
    var fake: FakeQuery = .{};
    const unauthorized_event = try testRequestEvent(.{
        .method = .GET,
        .raw_path = "/00112233-4455-6677-8899-aabbccddeeff",
    });
    defer std.testing.allocator.free(unauthorized_event);
    const unauthorized_response = handleInvocationForTest(
        std.testing.allocator,
        unauthorized_event,
        &environment,
        &fake,
        1000,
    );
    defer std.testing.allocator.free(unauthorized_response);
    try std.testing.expectEqualStrings(
        "{\"statusCode\":401,\"headers\":{\"Content-Type\":\"" ++
            content_type_text ++
            "\",\"WWW-Authenticate\":\"Bearer\"},\"body\":\"Unauthorized\\n\"}",
        unauthorized_response,
    );

    const post_event = try testRequestEvent(.{
        .method = .POST,
        .token = token,
        .raw_path = "/00112233-4455-6677-8899-aabbccddeeff",
    });
    defer std.testing.allocator.free(post_event);
    const post_response = handleInvocationForTest(
        std.testing.allocator,
        post_event,
        &environment,
        &fake,
        1000,
    );
    defer std.testing.allocator.free(post_response);
    try std.testing.expectEqualStrings(
        "{\"statusCode\":405,\"headers\":{\"Content-Type\":\"" ++
            content_type_text ++
            "\",\"Allow\":\"GET\"},\"body\":\"Method Not Allowed\\n\"}",
        post_response,
    );
    try std.testing.expectEqual(@as(u8, 0), fake.read_count);
}

test "malformed stored output and allocation failures remain sanitized" {
    const invalid = operation.Operation{
        .id = 0,
        .tenant = "lambda-test-user",
        .name = "encoding-failure-marker",
        .state = .running,
        .last_updated = 1000,
        .expires_at = 1001,
        .hash = [_]u8{0} ** 32,
    };
    const outcome = operationOutputBody(std.testing.allocator, &invalid);
    try std.testing.expectError(error.InvalidExpiresAt, outcome);

    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var fake: FakeQuery = .{};
    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    const response = handleInvocationForTest(
        failing_allocator.allocator(),
        "{}",
        &environment,
        &fake,
        1000,
    );
    try std.testing.expectEqualStrings(internal_server_error_response, response);
    try expectNotContains(response, "encoding-failure-marker");
    try std.testing.expectEqual(@as(u8, 0), fake.read_count);
}

const TestRequestOptions = struct {
    method: std.http.Method,
    token: ?[]const u8 = null,
    raw_path: ?[]const u8 = null,
    raw_query: ?[]const u8 = null,
    body: ?[]const u8 = null,
};

fn testRequestEvent(options: TestRequestOptions) ![]u8 {
    var event: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer event.deinit();
    try event.writer.writeAll("{\"version\":\"2.0\",\"routeKey\":\"$default\"");
    if (options.raw_path) |path| {
        try event.writer.writeAll(",\"rawPath\":");
        try std.json.Stringify.encodeJsonString(path, .{}, &event.writer);
    }
    if (options.raw_query) |query| {
        try event.writer.writeAll(",\"rawQueryString\":");
        try std.json.Stringify.encodeJsonString(query, .{}, &event.writer);
    }
    if (options.token) |token| {
        try event.writer.writeAll(",\"headers\":{\"Authorization\":\"Bearer ");
        try event.writer.writeAll(token);
        try event.writer.writeAll("\"}");
    }
    try event.writer.writeAll(",\"requestContext\":{\"http\":{\"method\":");
    try std.json.Stringify.encodeJsonString(@tagName(options.method), .{}, &event.writer);
    try event.writer.writeAll("}}");
    if (options.body) |body| {
        try event.writer.writeAll(",\"body\":");
        try std.json.Stringify.encodeJsonString(body, .{}, &event.writer);
    }
    try event.writer.writeByte('}');
    return event.toOwnedSlice();
}

fn testToken(seed_byte: u8) ![]u8 {
    return lambda_auth.testing.issue_token(std.testing.allocator, .{
        .seed_byte = seed_byte,
        .now = 1000,
        .ttl_seconds = 60,
    });
}

fn testEnvironment(seed_byte: u8) !std.process.Environ.Map {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    errdefer environment.deinit();
    try lambda_auth.testing.put_public_key(&environment, seed_byte);
    return environment;
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}
