const std = @import("std");
const aws = @import("aws");
const lambda = @import("aws-lambda");
const http = @import("http");
const http_test = if (@import("builtin").is_test) @import("http_test_support") else void;
const aws_http = @import("aws_http");
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
const runtime_tests_enabled = if (@import("builtin").is_test)
    @import("runtime_test_options").enabled
else
    false;

const bad_request_body = "Bad Request\n";
const cache_entry_count_max: usize = 1024;
const cache_ttl_ns: i96 = std.time.ns_per_s;
const content_type_json = "application/json";
const content_type_text = "text/plain; charset=utf-8";
const internal_server_error_body = "Internal Server Error\n";
const internal_server_error_response = aws_http.internal_server_error_response;
const method_not_allowed_body = "Method Not Allowed\n";
const not_found_body = "Not Found\n";
const service_unavailable_body = "Service Unavailable\n";
const unauthorized_body = "Unauthorized\n";

comptime {
    std.debug.assert(cache_entry_count_max > 0);
    std.debug.assert(cache_entry_count_max <= std.math.maxInt(u32));
    std.debug.assert(cache_ttl_ns > 0);
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

    installRuntimeQueryAdapter(QueryAdapter.init(&resources, &resources.cache));
    defer uninstallRuntimeQueryAdapter();
    lambda.handle(init, handler, .{});
}

fn handler(ctx: lambda.Context, event: []const u8) ![]const u8 {
    const query = runtime_query_adapter orelse {
        return error.PersistenceNotInitialized;
    };
    const authentication_now = std.Io.Clock.real.now(ctx.io).toSeconds();
    const monotonic_now_ns = std.Io.Clock.awake.now(ctx.io).toNanoseconds();
    return handleInvocation(
        ctx.arena,
        event,
        @field(ctx, "_").kv,
        query,
        authentication_now,
        monotonic_now_ns,
    );
}

const CacheEntry = struct {
    tenant: []u8,
    body: []u8,
    inserted_at_ns: i96,
};

pub const OperationCache = struct {
    allocator: Allocator,
    entries: std.AutoHashMap(u128, CacheEntry),

    const Self = @This();

    pub fn init(cache: *Self, allocator: Allocator) void {
        cache.* = .{
            .allocator = allocator,
            .entries = std.AutoHashMap(u128, CacheEntry).init(allocator),
        };
        std.debug.assert(cache.entries.count() == 0);
    }

    pub fn deinit(cache: *Self) void {
        var iterator = cache.entries.valueIterator();
        var entry_count: usize = 0;
        while (iterator.next()) |entry| {
            std.debug.assert(entry_count < cache_entry_count_max);
            entry_count += 1;
            cache.allocator.free(entry.tenant);
            cache.allocator.free(entry.body);
        }
        std.debug.assert(entry_count == cache.entries.count());
        cache.entries.deinit();
        cache.* = undefined;
    }

    fn getFresh(cache: *Self, id: u128, now_ns: i96) ?*const CacheEntry {
        std.debug.assert(cache.entries.count() <= cache_entry_count_max);
        const entry = cache.entries.getPtr(id) orelse return null;
        if (entryIsFresh(entry, now_ns)) return entry;

        cache.remove(id);
        std.debug.assert(!cache.entries.contains(id));
        return null;
    }

    fn insert(
        cache: *Self,
        id: u128,
        options: struct {
            tenant: []const u8,
            body: []const u8,
            inserted_at_ns: i96,
        },
    ) Allocator.Error!bool {
        std.debug.assert(options.tenant.len > 0);
        std.debug.assert(options.tenant.len <= operation.tenant_size_max);
        std.debug.assert(options.body.len > 0);
        std.debug.assert(cache.entries.count() <= cache_entry_count_max);
        std.debug.assert(!cache.entries.contains(id));

        if (cache.entries.count() == cache_entry_count_max) {
            cache.removeExpired(options.inserted_at_ns);
            if (cache.entries.count() == cache_entry_count_max) return false;
        }
        std.debug.assert(cache.entries.count() < cache_entry_count_max);

        const tenant = try cache.allocator.dupe(u8, options.tenant);
        errdefer cache.allocator.free(tenant);
        const body = try cache.allocator.dupe(u8, options.body);
        errdefer cache.allocator.free(body);
        try cache.entries.putNoClobber(id, .{
            .tenant = tenant,
            .body = body,
            .inserted_at_ns = options.inserted_at_ns,
        });
        std.debug.assert(cache.entries.contains(id));
        std.debug.assert(cache.entries.count() <= cache_entry_count_max);
        return true;
    }

    fn removeExpired(cache: *Self, now_ns: i96) void {
        var expired_ids: [cache_entry_count_max]u128 = undefined;
        var expired_count: usize = 0;
        var scanned_count: usize = 0;
        var iterator = cache.entries.iterator();
        while (iterator.next()) |entry| {
            std.debug.assert(scanned_count < cache_entry_count_max);
            scanned_count += 1;
            if (entryIsFresh(entry.value_ptr, now_ns)) continue;
            std.debug.assert(expired_count < expired_ids.len);
            expired_ids[expired_count] = entry.key_ptr.*;
            expired_count += 1;
        }
        std.debug.assert(scanned_count == cache.entries.count());

        for (expired_ids[0..expired_count]) |id| cache.remove(id);
        std.debug.assert(cache.entries.count() + expired_count == scanned_count);
    }

    fn remove(cache: *Self, id: u128) void {
        const removed = cache.entries.fetchRemove(id) orelse unreachable;
        cache.allocator.free(removed.value.tenant);
        cache.allocator.free(removed.value.body);
        std.debug.assert(cache.entries.count() < cache_entry_count_max);
    }
};

fn entryIsFresh(entry: *const CacheEntry, now_ns: i96) bool {
    std.debug.assert(now_ns >= entry.inserted_at_ns);
    return now_ns - entry.inserted_at_ns < cache_ttl_ns;
}

const RuntimeResources = struct {
    config: aws.Config,
    persistence: operation_persistence.Persistence,
    cache: OperationCache,

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

        OperationCache.init(&resources.cache, process_init.gpa);
    }

    fn deinit(resources: *RuntimeResources) void {
        resources.cache.deinit();
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

pub const QueryAdapter = struct {
    context: *anyopaque,
    cache: *OperationCache,
    read_fn: *const fn (
        *anyopaque,
        Allocator,
        u128,
    ) anyerror!operation.Operation,

    pub fn init(pointer: anytype, cache: *OperationCache) QueryAdapter {
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
            .cache = cache,
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
    authentication_now: i64,
    monotonic_now_ns: i96,
) []const u8 {
    var transport = aws_http.Request.parse(allocator, event) catch {
        const response = response_from_outcome(allocator, .internal_server_error);
        return aws_http.encode_response(allocator, &response) catch internal_server_error_response;
    };
    defer transport.deinit();
    const request = transport.application_request();
    var response = handle_http(
        allocator,
        &request,
        environment,
        query,
        authentication_now,
        monotonic_now_ns,
    );
    defer response.deinit();
    return aws_http.encode_response(allocator, &response) catch internal_server_error_response;
}

pub fn handle_http(
    allocator: Allocator,
    request: *const http.HttpRequest,
    environment: *const std.process.Environ.Map,
    query: QueryAdapter,
    authentication_now: i64,
    monotonic_now_ns: i96,
) http.HttpResponse {
    return response_from_outcome(allocator, invocationOutcome(
        allocator,
        request,
        environment,
        query,
        authentication_now,
        monotonic_now_ns,
    ));
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
    request: *const http.HttpRequest,
    environment: *const std.process.Environ.Map,
    query: QueryAdapter,
    authentication_now: i64,
    monotonic_now_ns: i96,
) InvocationOutcome {
    var identity = lambda_auth.authenticate(
        allocator,
        request.headers,
        environment,
        authentication_now,
    ) catch |err| {
        return switch (err) {
            error.Unauthorized => .unauthorized,
            error.InternalFailure => .internal_server_error,
        };
    };
    defer identity.deinit();

    const method = request.method orelse {
        return .method_not_allowed;
    };
    if (method != .GET) return .method_not_allowed;
    return queryInvocationOutcome(
        allocator,
        identity.subject,
        request,
        query,
        monotonic_now_ns,
    );
}

fn queryInvocationOutcome(
    allocator: Allocator,
    tenant: []const u8,
    request: *const http.HttpRequest,
    query: QueryAdapter,
    monotonic_now_ns: i96,
) InvocationOutcome {
    std.debug.assert(tenant.len > 0);
    std.debug.assert(tenant.len <= operation.tenant_size_max);

    const id = operationIDFromRawPath(request.path) catch {
        return .bad_request;
    };
    if (query.cache.getFresh(id, monotonic_now_ns)) |cached| {
        if (!std.mem.eql(u8, cached.tenant, tenant)) return .not_found;
        const body = allocator.dupe(u8, cached.body) catch {
            return .internal_server_error;
        };
        return .{ .success = body };
    }

    var operation_arena = std.heap.ArenaAllocator.init(allocator);
    defer operation_arena.deinit();
    const persisted = query.read(operation_arena.allocator(), id) catch |err| {
        return switch (err) {
            error.OperationNotFound => .not_found,
            error.AWSFailure => .service_unavailable,
            else => .internal_server_error,
        };
    };
    const body = operationOutputBody(allocator, &persisted) catch {
        return .internal_server_error;
    };
    _ = query.cache.insert(id, .{
        .tenant = persisted.tenant,
        .body = body,
        .inserted_at_ns = monotonic_now_ns,
    }) catch false;
    if (!std.mem.eql(u8, persisted.tenant, tenant)) {
        allocator.free(body);
        return .not_found;
    }
    return .{ .success = body };
}

fn operationIDFromRawPath(raw_path: ?[]const u8) !u128 {
    const path = raw_path orelse return error.InvalidPath;
    const prefix = "/operations/";
    if (path.len != prefix.len + operation.uuid_string_size) return error.InvalidPath;
    if (!std.mem.startsWith(u8, path, prefix)) return error.InvalidPath;
    const id = operation.uuidFromString(path[prefix.len..]) catch return error.InvalidPath;
    std.debug.assert(path[prefix.len..].len == operation.uuid_string_size);
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

fn response_from_outcome(allocator: Allocator, outcome: InvocationOutcome) http.HttpResponse {
    return switch (outcome) {
        .success => |success| .{
            .status = .ok,
            .headers = &.{.{ .key = "Content-Type", .value = content_type_json }},
            .body = success,
            .body_allocator = allocator,
        },
        .bad_request => .{
            .status = .bad_request,
            .headers = &.{.{ .key = "Content-Type", .value = content_type_text }},
            .body = bad_request_body,
        },
        .method_not_allowed => .{
            .status = .method_not_allowed,
            .headers = &.{
                .{ .key = "Content-Type", .value = content_type_text },
                .{ .key = "Allow", .value = "GET" },
            },
            .body = method_not_allowed_body,
        },
        .service_unavailable => .{
            .status = .service_unavailable,
            .headers = &.{.{ .key = "Content-Type", .value = content_type_text }},
            .body = service_unavailable_body,
        },
        .unauthorized => .{
            .status = .unauthorized,
            .headers = &.{
                .{ .key = "Content-Type", .value = content_type_text },
                .{ .key = "WWW-Authenticate", .value = "Bearer" },
            },
            .body = unauthorized_body,
        },
        .internal_server_error => .{
            .status = .internal_server_error,
            .headers = &.{.{ .key = "Content-Type", .value = content_type_text }},
            .body = internal_server_error_body,
        },
        .not_found => .{
            .status = .not_found,
            .headers = &.{.{ .key = "Content-Type", .value = content_type_text }},
            .body = not_found_body,
        },
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

fn handle_http_for_test(
    allocator: Allocator,
    request: *const http.HttpRequest,
    environment: *const std.process.Environ.Map,
    fake: *FakeQuery,
    now: i64,
) http.HttpResponse {
    var cache: OperationCache = undefined;
    OperationCache.init(&cache, std.testing.allocator);
    defer cache.deinit();
    return handle_http(allocator, request, environment, QueryAdapter.init(fake, &cache), now, 0);
}

fn handleInvocationForTest(
    allocator: Allocator,
    event: []const u8,
    environment: *const std.process.Environ.Map,
    fake: *FakeQuery,
    now: i64,
) []const u8 {
    var cache: OperationCache = undefined;
    OperationCache.init(&cache, std.testing.allocator);
    defer cache.deinit();

    return handleInvocationWithCacheForTest(
        allocator,
        event,
        environment,
        fake,
        &cache,
        now,
        0,
    );
}

fn handleInvocationWithCacheForTest(
    allocator: Allocator,
    event: []const u8,
    environment: *const std.process.Environ.Map,
    fake: *FakeQuery,
    cache: *OperationCache,
    authentication_now: i64,
    monotonic_now_ns: i96,
) []const u8 {
    return handleInvocation(
        allocator,
        event,
        environment,
        QueryAdapter.init(fake, cache),
        authentication_now,
        monotonic_now_ns,
    );
}

fn testOperation(tenant: []const u8, state_tag: operation.StateTag) operation.Operation {
    return .{
        .id = operation.uuidFromString(
            "00112233-4455-6677-8899-aabbccddeeff",
        ) catch unreachable,
        .tenant = tenant,
        .name = "echo",
        .state = switch (state_tag) {
            .submitted => .submitted,
            .completed => .{ .completed = .{ .success = .{ .string = "done" } } },
        },
        .last_updated = 1_700_000_123,
        .expires_at = 1_700_086_523,
        .hash = @as([32]u8, @splat(0xab)),
    };
}

fn fillTestCache(cache: *OperationCache, inserted_at_ns: i96) !void {
    for (0..cache_entry_count_max) |index| {
        const inserted = try cache.insert(@intCast(index), .{
            .tenant = "cache-fill-tenant",
            .body = "{}",
            .inserted_at_ns = inserted_at_ns,
        });
        try std.testing.expect(inserted);
    }
    try std.testing.expectEqual(
        @as(u32, cache_entry_count_max),
        cache.entries.count(),
    );
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

test "HTTP querying ignores bodies and checks tenant and expiry on warm cache reads" {
    const Body = struct {
        fn read(_: *anyopaque, _: Allocator) anyerror!?[]const u8 {
            return error.BodyMustNotBeRead;
        }
    };
    const tenant = "github:42";
    var marker: u8 = 0;
    var request: http.HttpRequest = .{
        .method = .GET,
        .path = "/operations/00112233-4455-6677-8899-AABBCCDDEEFF",
        .body = .{ .deferred = .{ .context = &marker, .is_empty = false, .read_fn = Body.read } },
    };
    var environment = try testEnvironment(0x71);
    defer environment.deinit();
    var fake = FakeQuery{ .response = testOperation(tenant, .submitted) };
    var cache: OperationCache = undefined;
    OperationCache.init(&cache, std.testing.allocator);
    defer cache.deinit();
    const query = QueryAdapter.init(&fake, &cache);
    var unauthorized = handle_http(std.testing.allocator, &request, &environment, query, 1000, 0);
    defer unauthorized.deinit();
    try std.testing.expectEqual(.unauthorized, unauthorized.status);
    const cases = [_]struct { subject: []const u8, now: i64, status: std.http.Status }{
        .{ .subject = tenant, .now = 1000, .status = .ok },
        // The foreign subjects exercise full equality by sharing a prefix or suffix.
        .{ .subject = "github:43", .now = 1000, .status = .not_found },
        .{ .subject = "other:42", .now = 1000, .status = .not_found },
        .{ .subject = tenant, .now = 1059, .status = .ok },
        .{ .subject = tenant, .now = 1060, .status = .unauthorized },
    };
    for (cases) |case| {
        const token = try testTokenForSubject(0x71, case.subject);
        defer std.testing.allocator.free(token);
        const bearer = try std.fmt.allocPrint(std.testing.allocator, "Bearer {s}", .{token});
        defer std.testing.allocator.free(bearer);
        request.headers = &.{.{ .key = "Authorization", .value = bearer }};
        var response = handle_http(
            std.testing.allocator,
            &request,
            &environment,
            query,
            case.now,
            0,
        );
        defer response.deinit();
        try std.testing.expectEqual(case.status, response.status);
        switch (case.status) {
            .not_found => try std.testing.expectEqualStrings(not_found_body, response.body),
            .unauthorized => try std.testing.expectEqualStrings(unauthorized_body, response.body),
            .ok => {
                try std.testing.expect(std.mem.indexOf(
                    u8,
                    response.body,
                    "\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"",
                ) != null);
                try std.testing.expect(std.mem.indexOf(
                    u8,
                    response.body,
                    "\"tenant\":\"" ++ tenant ++ "\"",
                ) != null);
            },
            else => unreachable,
        }
    }
    try std.testing.expectEqual(@as(u8, 1), fake.read_count);
}

test "authenticated GET returns exact SUBMITTED operation JSON and canonicalizes UUID" {
    const token = try testToken(0x71);
    defer std.testing.allocator.free(token);
    var environment = try testEnvironment(0x71);
    defer environment.deinit();
    const event = try testRequestEvent(.{
        .method = .GET,
        .token = token,
        .raw_path = "/operations/00112233-4455-6677-8899-AABBCCDDEEFF",
        .raw_query = "id=ffffffff-ffff-ffff-ffff-ffffffffffff",
        .body = "ffffffff-ffff-ffff-ffff-ffffffffffff",
    });
    defer std.testing.allocator.free(event);
    var fake = FakeQuery{ .response = testOperation("lambda-test-user", .submitted) };

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
        "\\\"state\\\":\\\"SUBMITTED\\\",\\\"last_updated\\\":1700000123," ++
        "\\\"expires_at\\\":1700086523," ++
        "\\\"hash\\\":\\\"" ++ (std.mem.asBytes(&@as([32][2]u8, @splat("ab".*)))) ++ "\\\"}\"}";
    try std.testing.expectEqualStrings(expected, response);
    try std.testing.expectEqual(
        operation.uuidFromString("00112233-4455-6677-8899-aabbccddeeff") catch unreachable,
        fake.last_id,
    );
    try std.testing.expectEqual(@as(u8, 1), fake.read_count);
}

test "authenticated GET returns exact completed success and failure envelopes" {
    const token = try testToken(0x72);
    defer std.testing.allocator.free(token);
    var environment = try testEnvironment(0x72);
    defer environment.deinit();
    var fixture = try http_test.Request.init(std.testing.allocator, .{
        .method = .GET,
        .token = token,
        .path = "/operations/00112233-4455-6677-8899-aabbccddeeff",
    });
    defer fixture.deinit(std.testing.allocator);
    var fake = FakeQuery{ .response = testOperation("lambda-test-user", .completed) };

    var response = handle_http_for_test(
        std.testing.allocator,
        &fixture.request,
        &environment,
        &fake,
        1000,
    );
    defer response.deinit();

    const expected = http.HttpResponse{
        .status = .ok,
        .headers = &.{.{ .key = "Content-Type", .value = "application/json" }},
        .body = "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\",\"tenant\":\"" ++
            "lambda-test-user\",\"name\":\"echo\",\"state\":\"COMPLETED\",\"la" ++
            "st_updated\":1700000123,\"expires_at\":1700086523,\"result\"" ++
            ":{\"type\":\"SUCCESS\",\"payload\":\"done\"},\"hash\":\"ababababab" ++
            "ababababababababababababababababababababababababababab\"" ++
            "}",
    };
    try http_test.expect_response(&expected, &response);

    var failure = testOperation("lambda-test-user", .completed);
    failure.state = .{ .completed = .{ .failure = .{ .string = "done" } } };
    fake.response = failure;
    var failure_response = handle_http_for_test(
        std.testing.allocator,
        &fixture.request,
        &environment,
        &fake,
        1000,
    );
    defer failure_response.deinit();
    const expected_failure = http.HttpResponse{
        .status = .ok,
        .headers = &.{.{ .key = "Content-Type", .value = "application/json" }},
        .body = "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\",\"tenant\":\"" ++
            "lambda-test-user\",\"name\":\"echo\",\"state\":\"COMPLETED\",\"la" ++
            "st_updated\":1700000123,\"expires_at\":1700086523,\"result\"" ++
            ":{\"type\":\"FAILURE\",\"payload\":\"done\"},\"hash\":\"ababababab" ++
            "ababababababababababababababababababababababababababab\"" ++
            "}",
    };
    try http_test.expect_response(&expected_failure, &failure_response);
}

test "second lookup before one second uses cached response" {
    const token = try testToken(0x77);
    defer std.testing.allocator.free(token);
    var environment = try testEnvironment(0x77);
    defer environment.deinit();
    var fixture = try http_test.Request.init(std.testing.allocator, .{
        .method = .GET,
        .token = token,
        .path = "/operations/00112233-4455-6677-8899-aabbccddeeff",
    });
    defer fixture.deinit(std.testing.allocator);
    var fake = FakeQuery{ .response = testOperation("lambda-test-user", .submitted) };
    var cache: OperationCache = undefined;
    OperationCache.init(&cache, std.testing.allocator);
    defer cache.deinit();

    var first = handle_http(
        std.testing.allocator,
        &fixture.request,
        &environment,
        QueryAdapter.init(&fake, &cache),
        1000,
        10,
    );
    defer first.deinit();
    fake.response = testOperation("lambda-test-user", .completed);
    var second = handle_http(
        std.testing.allocator,
        &fixture.request,
        &environment,
        QueryAdapter.init(&fake, &cache),
        1000,
        10 + cache_ttl_ns - 1,
    );
    defer second.deinit();

    try http_test.expect_response(&first, &second);
    try std.testing.expect(std.mem.indexOf(u8, second.body, "SUBMITTED") != null);
    try std.testing.expectEqual(@as(u8, 1), fake.read_count);
    try std.testing.expectEqual(@as(u32, 1), cache.entries.count());
}

test "cache entry expires and is replaced at exactly one second" {
    const token = try testToken(0x78);
    defer std.testing.allocator.free(token);
    var environment = try testEnvironment(0x78);
    defer environment.deinit();
    var fixture = try http_test.Request.init(std.testing.allocator, .{
        .method = .GET,
        .token = token,
        .path = "/operations/00112233-4455-6677-8899-aabbccddeeff",
    });
    defer fixture.deinit(std.testing.allocator);
    var fake = FakeQuery{ .response = testOperation("lambda-test-user", .submitted) };
    var cache: OperationCache = undefined;
    OperationCache.init(&cache, std.testing.allocator);
    defer cache.deinit();

    var first = handle_http(
        std.testing.allocator,
        &fixture.request,
        &environment,
        QueryAdapter.init(&fake, &cache),
        1000,
        0,
    );
    defer first.deinit();
    fake.response = testOperation("lambda-test-user", .completed);
    var second = handle_http(
        std.testing.allocator,
        &fixture.request,
        &environment,
        QueryAdapter.init(&fake, &cache),
        1000,
        cache_ttl_ns,
    );
    defer second.deinit();

    try std.testing.expect(std.mem.indexOf(u8, first.body, "SUBMITTED") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body, "COMPLETED") != null);
    try std.testing.expectEqual(@as(u8, 2), fake.read_count);
    try std.testing.expectEqual(@as(u32, 1), cache.entries.count());
}

test "foreign request populates ID-only cache for owning tenant" {
    const foreign_token = try testToken(0x79);
    defer std.testing.allocator.free(foreign_token);
    const owner_token = try testTokenForSubject(0x79, "owning-tenant");
    defer std.testing.allocator.free(owner_token);
    var environment = try testEnvironment(0x79);
    defer environment.deinit();
    var foreign_fixture = try http_test.Request.init(std.testing.allocator, .{
        .method = .GET,
        .token = foreign_token,
        .path = "/operations/00112233-4455-6677-8899-aabbccddeeff",
    });
    defer foreign_fixture.deinit(std.testing.allocator);
    var owner_fixture = try http_test.Request.init(std.testing.allocator, .{
        .method = .GET,
        .token = owner_token,
        .path = "/operations/00112233-4455-6677-8899-aabbccddeeff",
    });
    defer owner_fixture.deinit(std.testing.allocator);
    var fake = FakeQuery{ .response = testOperation("owning-tenant", .submitted) };
    var cache: OperationCache = undefined;
    OperationCache.init(&cache, std.testing.allocator);
    defer cache.deinit();

    var foreign_response = handle_http(
        std.testing.allocator,
        &foreign_fixture.request,
        &environment,
        QueryAdapter.init(&fake, &cache),
        1000,
        0,
    );
    defer foreign_response.deinit();
    fake.read_error = error.AWSFailure;
    var owner_response = handle_http(
        std.testing.allocator,
        &owner_fixture.request,
        &environment,
        QueryAdapter.init(&fake, &cache),
        1000,
        cache_ttl_ns - 1,
    );
    defer owner_response.deinit();

    try std.testing.expectEqual(std.http.Status.not_found, foreign_response.status);
    try expectNotContains(foreign_response.body, "owning-tenant");
    try std.testing.expectEqual(std.http.Status.ok, owner_response.status);
    try std.testing.expect(std.mem.indexOf(u8, owner_response.body, "owning-tenant") != null);
    try std.testing.expectEqual(@as(u8, 1), fake.read_count);
    try std.testing.expectEqual(@as(u32, 1), cache.entries.count());
}

test "missing operations are fetched on every request" {
    const token = try testToken(0x7a);
    defer std.testing.allocator.free(token);
    var environment = try testEnvironment(0x7a);
    defer environment.deinit();
    var fixture = try http_test.Request.init(std.testing.allocator, .{
        .method = .GET,
        .token = token,
        .path = "/operations/00112233-4455-6677-8899-aabbccddeeff",
    });
    defer fixture.deinit(std.testing.allocator);
    var fake = FakeQuery{ .read_error = error.OperationNotFound };
    var cache: OperationCache = undefined;
    OperationCache.init(&cache, std.testing.allocator);
    defer cache.deinit();

    for (0..2) |monotonic_now_ns| {
        var response = handle_http(
            std.testing.allocator,
            &fixture.request,
            &environment,
            QueryAdapter.init(&fake, &cache),
            1000,
            @intCast(monotonic_now_ns),
        );
        defer response.deinit();
        try std.testing.expectEqual(std.http.Status.not_found, response.status);
    }
    try std.testing.expectEqual(@as(u8, 2), fake.read_count);
    try std.testing.expectEqual(@as(u32, 0), cache.entries.count());
}

test "full fresh cache serves fetched record without caching it" {
    const token = try testToken(0x7b);
    defer std.testing.allocator.free(token);
    var environment = try testEnvironment(0x7b);
    defer environment.deinit();
    var fixture = try http_test.Request.init(std.testing.allocator, .{
        .method = .GET,
        .token = token,
        .path = "/operations/00112233-4455-6677-8899-aabbccddeeff",
    });
    defer fixture.deinit(std.testing.allocator);
    var fake = FakeQuery{ .response = testOperation("lambda-test-user", .submitted) };
    var cache: OperationCache = undefined;
    OperationCache.init(&cache, std.testing.allocator);
    defer cache.deinit();
    try fillTestCache(&cache, 0);
    const target_id = testOperation("lambda-test-user", .submitted).id;
    std.debug.assert(target_id >= cache_entry_count_max);

    for (0..2) |_| {
        var response = handle_http(
            std.testing.allocator,
            &fixture.request,
            &environment,
            QueryAdapter.init(&fake, &cache),
            1000,
            cache_ttl_ns - 1,
        );
        defer response.deinit();
        try std.testing.expectEqual(std.http.Status.ok, response.status);
        try std.testing.expectEqual(
            @as(u32, cache_entry_count_max),
            cache.entries.count(),
        );
        try std.testing.expect(!cache.entries.contains(target_id));
    }
    try std.testing.expectEqual(@as(u8, 2), fake.read_count);
}

test "full cache removes all expired entries before admitting fetched record" {
    const token = try testToken(0x7c);
    defer std.testing.allocator.free(token);
    var environment = try testEnvironment(0x7c);
    defer environment.deinit();
    var fixture = try http_test.Request.init(std.testing.allocator, .{
        .method = .GET,
        .token = token,
        .path = "/operations/00112233-4455-6677-8899-aabbccddeeff",
    });
    defer fixture.deinit(std.testing.allocator);
    var fake = FakeQuery{ .response = testOperation("lambda-test-user", .submitted) };
    var cache: OperationCache = undefined;
    OperationCache.init(&cache, std.testing.allocator);
    defer cache.deinit();
    try fillTestCache(&cache, 0);
    const target_id = testOperation("lambda-test-user", .submitted).id;
    std.debug.assert(target_id >= cache_entry_count_max);

    var first = handle_http(
        std.testing.allocator,
        &fixture.request,
        &environment,
        QueryAdapter.init(&fake, &cache),
        1000,
        cache_ttl_ns,
    );
    defer first.deinit();
    var second = handle_http(
        std.testing.allocator,
        &fixture.request,
        &environment,
        QueryAdapter.init(&fake, &cache),
        1000,
        cache_ttl_ns,
    );
    defer second.deinit();

    try http_test.expect_response(&first, &second);
    try std.testing.expectEqual(@as(u8, 1), fake.read_count);
    try std.testing.expectEqual(@as(u32, 1), cache.entries.count());
    try std.testing.expect(cache.entries.contains(target_id));
}

test "cache allocation failures serve fetched response without caching" {
    const token = try testToken(0x7d);
    defer std.testing.allocator.free(token);
    var environment = try testEnvironment(0x7d);
    defer environment.deinit();
    var fixture = try http_test.Request.init(std.testing.allocator, .{
        .method = .GET,
        .token = token,
        .path = "/operations/00112233-4455-6677-8899-aabbccddeeff",
    });
    defer fixture.deinit(std.testing.allocator);

    for ([_]usize{ 0, 1, 2 }) |fail_index| {
        var failing_allocator = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var cache: OperationCache = undefined;
        OperationCache.init(&cache, failing_allocator.allocator());
        defer cache.deinit();
        var fake = FakeQuery{ .response = testOperation("lambda-test-user", .submitted) };

        var response = handle_http(
            std.testing.allocator,
            &fixture.request,
            &environment,
            QueryAdapter.init(&fake, &cache),
            1000,
            0,
        );
        defer response.deinit();
        try std.testing.expectEqual(std.http.Status.ok, response.status);
        try std.testing.expectEqual(@as(u8, 1), fake.read_count);
        try std.testing.expectEqual(@as(u32, 0), cache.entries.count());
    }
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
        "/00112233-4455-6677-8899-aabbccddeeff",
        "/operations",
        "/operations/00112233-4455-6677-8899-aabbccddeefg",
        "/operations/nested/00112233-4455-6677-8899-aabbccddeeff",
        "/operations/00112233-4455-6677-8899-aabbccddeeff/",
        "/operations/00112233-4455-6677-8899-aabbccddeeff/extra",
        "/operations/00112233-4455-6677-8899-aabbccddee%66f",
    };

    for (paths) |path| {
        var fixture = try http_test.Request.init(std.testing.allocator, .{
            .method = .GET,
            .token = token,
            .path = path,
        });
        defer fixture.deinit(std.testing.allocator);
        var fake: FakeQuery = .{};
        var response = handle_http_for_test(
            std.testing.allocator,
            &fixture.request,
            &environment,
            &fake,
            1000,
        );
        defer response.deinit();

        try http_test.expect_response(&http.HttpResponse{
            .status = .bad_request,
            .headers = &.{.{ .key = "Content-Type", .value = "text/plain; charset=utf-8" }},
            .body = "Bad Request\n",
        }, &response);
        try std.testing.expectEqual(@as(u8, 0), fake.read_count);
    }
}

test "missing and cross-tenant operations return identical static not found response" {
    const token = try testToken(0x74);
    defer std.testing.allocator.free(token);
    var environment = try testEnvironment(0x74);
    defer environment.deinit();
    var fixture = try http_test.Request.init(std.testing.allocator, .{
        .method = .GET,
        .token = token,
        .path = "/operations/00112233-4455-6677-8899-aabbccddeeff",
    });
    defer fixture.deinit(std.testing.allocator);
    var missing = FakeQuery{ .read_error = error.OperationNotFound };
    var foreign = FakeQuery{ .response = testOperation("another-tenant", .submitted) };

    var missing_response = handle_http_for_test(
        std.testing.allocator,
        &fixture.request,
        &environment,
        &missing,
        1000,
    );
    defer missing_response.deinit();
    var foreign_response = handle_http_for_test(
        std.testing.allocator,
        &fixture.request,
        &environment,
        &foreign,
        1000,
    );
    defer foreign_response.deinit();

    const expected = http.HttpResponse{
        .status = .not_found,
        .headers = &.{.{ .key = "Content-Type", .value = "text/plain; charset=utf-8" }},
        .body = "Not Found\n",
    };
    try http_test.expect_response(&expected, &missing_response);
    try http_test.expect_response(&expected, &foreign_response);
    try expectNotContains(foreign_response.body, "another-tenant");
    try expectNotContains(foreign_response.body, "echo");
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
        .raw_path = "/operations/00112233-4455-6677-8899-aabbccddeeff",
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
        .raw_path = "/operations/00112233-4455-6677-8899-aabbccddeeff",
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
        .raw_path = "/operations/00112233-4455-6677-8899-aabbccddeeff",
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
        .state = .submitted,
        .last_updated = 1000,
        .expires_at = 1001,
        .hash = @as([32]u8, @splat(0)),
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

fn testQueryRequestEvent(token: []const u8) ![]u8 {
    return testRequestEvent(.{
        .method = .GET,
        .token = token,
        .raw_path = "/operations/00112233-4455-6677-8899-aabbccddeeff",
    });
}

fn testToken(seed_byte: u8) ![]u8 {
    return testTokenForSubject(seed_byte, "lambda-test-user");
}

fn testTokenForSubject(seed_byte: u8, subject: []const u8) ![]u8 {
    return lambda_auth.testing.issue_token(std.testing.allocator, .{
        .seed_byte = seed_byte,
        .subject = subject,
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

test "authenticated query preserves full 96 KiB Result inside HTTP metadata framing" {
    const token = try testToken(0x72);
    defer std.testing.allocator.free(token);
    var environment = try testEnvironment(0x72);
    defer environment.deinit();
    const event = try testRequestEvent(.{
        .method = .GET,
        .token = token,
        .raw_path = "/operations/00112233-4455-6677-8899-aabbccddeeff",
    });
    defer std.testing.allocator.free(event);
    var stored = testOperation("lambda-test-user", .completed);
    const payload = &@as([98304 - 31]u8, @splat('a'));
    stored.state = .{ .completed = .{ .success = .{ .string = payload } } };
    var fake: FakeQuery = .{ .response = stored };
    const response = handleInvocationForTest(std.testing.allocator, event, &environment, &fake, 1000);
    defer std.testing.allocator.free(response);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const outer = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), response, .{});
    try std.testing.expectEqual(@as(i64, 200), outer.object.get("statusCode").?.integer);
    const body = outer.object.get("body").?.string;
    try std.testing.expect(body.len > 98304);
    const decoded = try operation.parseOutputJSON(arena.allocator(), body);
    try std.testing.expectEqualStrings(payload, decoded.state.completed.success.string);
    try std.testing.expectEqualStrings("lambda-test-user", decoded.tenant);
}

/// Runs the authenticated query handler with a local persistence response and an empty cache.
pub const test_support = if (@import("builtin").is_test) struct {
    pub fn query_with_backend(
        allocator: Allocator,
        id: u128,
        subject: []const u8,
        backend: anytype,
    ) ![]const u8 {
        const token = try testTokenForSubject(0x72, subject);
        defer std.testing.allocator.free(token);
        var environment = try testEnvironment(0x72);
        defer environment.deinit();
        var uuid: [operation.uuid_string_size]u8 = undefined;
        const path = try std.fmt.allocPrint(
            allocator,
            "/operations/{s}",
            .{operation.uuidToString(id, &uuid)},
        );
        defer allocator.free(path);
        const event = try testRequestEvent(.{ .method = .GET, .token = token, .raw_path = path });
        defer std.testing.allocator.free(event);
        var cache: OperationCache = undefined;
        OperationCache.init(&cache, allocator);
        defer cache.deinit();
        return handleInvocation(allocator, event, &environment, QueryAdapter.init(backend, &cache), 1000, 0);
    }

    pub fn query(allocator: Allocator, stored: *const operation.Operation) ![]const u8 {
        const token = try testTokenForSubject(0x72, stored.tenant);
        defer std.testing.allocator.free(token);
        var environment = try testEnvironment(0x72);
        defer environment.deinit();
        var uuid: [operation.uuid_string_size]u8 = undefined;
        const path = try std.fmt.allocPrint(
            allocator,
            "/operations/{s}",
            .{operation.uuidToString(stored.id, &uuid)},
        );
        defer allocator.free(path);
        const event = try testRequestEvent(.{ .method = .GET, .token = token, .raw_path = path });
        defer std.testing.allocator.free(event);
        var fake: FakeQuery = .{ .response = stored.* };
        return handleInvocationForTest(allocator, event, &environment, &fake, 1000);
    }
} else struct {};

test "runtime integration: warm query preserves cache and refreshes invocation metadata" {
    if (comptime !runtime_tests_enabled) return error.SkipZigTest;
    const runtime = @import("runtime_test_support");
    var fixture: runtime.Fixture = .{};
    defer fixture.deinit();
    const allocator = fixture.allocator();
    const token = try lambda_auth.testing.issue_token(allocator, .{
        .seed_byte = 0x71,
        .now = std.Io.Clock.real.now(std.testing.io).toSeconds(),
        .ttl_seconds = 300,
    });
    const event = try http_test.aws_event(allocator, .{
        .method = .GET,
        .route = "GET /operations/{id}",
        .path = "/operations/00112233-4455-6677-8899-aabbccddeeff",
        .token = token,
        .body = "!",
        .base64 = true,
    });
    const function_url_event = try testQueryRequestEvent(token);
    defer std.testing.allocator.free(function_url_event);
    const foreign_token = try lambda_auth.testing.issue_token(allocator, .{
        .seed_byte = 0x71,
        .subject = "foreign-tenant",
        .now = std.Io.Clock.real.now(std.testing.io).toSeconds(),
        .ttl_seconds = 300,
    });
    const foreign = try http_test.aws_event(allocator, .{
        .method = .GET,
        .route = "GET /operations/{id}",
        .path = "/operations/00112233-4455-6677-8899-aabbccddeeff",
        .token = foreign_token,
    });
    const unauthorized = try http_test.aws_event(allocator, .{
        .method = .GET,
        .route = "GET /operations/{id}",
        .path = "/operations/00112233-4455-6677-8899-aabbccddeeff",
    });
    try fixture.init(&.{
        .{
            .request_id = "query-1",
            .payload = event,
            .invocation_id = "attempt-1",
            .xray_trace = "trace-1",
            .invoked_arn = "function-1",
            .deadline_ms = 1001,
        },
        .{
            .request_id = "query-2",
            .payload = function_url_event,
            .invocation_id = "",
            .xray_trace = "trace-2",
            .invoked_arn = "function-2",
            .deadline_ms = 1002,
        },
        .{
            .request_id = "query-3",
            .payload = event,
            .invocation_id = "attempt-3",
            .xray_trace = "",
            .invoked_arn = "function-3",
            .deadline_ms = 1003,
        },
        .{ .request_id = "query-unauthorized", .payload = unauthorized },
        .{ .request_id = "query-foreign", .payload = foreign },
        .{ .request_id = "query-malformed", .payload = "{" },
        .{ .request_id = "query-recovered", .payload = event },
    });
    try lambda_auth.testing.put_public_key(&fixture.tester.env_map, 0x71);
    var cache: OperationCache = undefined;
    OperationCache.init(&cache, std.testing.allocator);
    defer cache.deinit();
    var fake: FakeQuery = .{ .response = testOperation("lambda-test-user", .submitted) };
    installRuntimeQueryAdapter(QueryAdapter.init(&fake, &cache));
    defer uninstallRuntimeQueryAdapter();

    try fixture.run_handler(.{ .awake_ns = 1000 }, handler);
    try std.testing.expectEqual(@as(u8, 1), fake.read_count);
    try std.testing.expectEqual(@as(u32, 1), cache.entries.count());
    for ([_][]const u8{ "query-1", "query-2", "query-3" }, 0..) |id, index| {
        const path = try std.fmt.allocPrint(
            allocator,
            "/2018-06-01/runtime/invocation/{s}/response",
            .{id},
        );
        try fixture.tester.expectPath(index, path);
        const output = try runtime.http_body(allocator, &fixture.tester, index, 200);
        try std.testing.expectEqualStrings("SUBMITTED", output.object.get("state").?.string);
        try std.testing.expectEqualStrings(
            "lambda-test-user",
            output.object.get("tenant").?.string,
        );
        try std.testing.expectEqualStrings(
            "00112233-4455-6677-8899-aabbccddeeff",
            output.object.get("id").?.string,
        );
        try fixture.tester.expectBody(index, (try fixture.tester.post(0)).body);
    }
    for ([_]u16{ 401, 404, 500, 200 }, 3..) |status, index| {
        const envelope = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            (try fixture.tester.post(index)).body,
            .{},
        );
        defer envelope.deinit();
        try std.testing.expectEqual(
            @as(i64, status),
            envelope.value.object.get("statusCode").?.integer,
        );
    }
}

test "named HTTP API and Function URL queries ignore encoded bodies and metadata ID fallbacks" {
    const allocator = std.testing.allocator;
    const token = try testToken(0x72);
    defer allocator.free(token);
    var environment = try testEnvironment(0x72);
    defer environment.deinit();
    for ([_]?[]const u8{ "GET /operations/{id}", null }) |route| {
        for ([_][]const u8{
            "/operations/00112233-4455-6677-8899-AABBCCDDEEFF", "/operations/missing",
        }) |path| {
            const event = try http_test.aws_event(allocator, .{
                .method = .GET,
                .route = route,
                .path = path,
                .token = token,
                .body = "!malformed-base64",
                .base64 = true,
            });
            defer allocator.free(event);
            var fake: FakeQuery = .{ .response = testOperation("lambda-test-user", .submitted) };
            const response = handleInvocationForTest(allocator, event, &environment, &fake, 1000);
            defer allocator.free(response);
            const outer = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
            defer outer.deinit();
            const valid = std.mem.endsWith(u8, path, "AABBCCDDEEFF");
            try std.testing.expectEqual(
                @as(i64, if (valid) 200 else 400),
                outer.value.object.get("statusCode").?.integer,
            );
            try std.testing.expectEqual(@as(u8, if (valid) 1 else 0), fake.read_count);
        }
    }
}
