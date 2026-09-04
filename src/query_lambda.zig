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
const cache_entry_count_max: usize = 1024;
const cache_ttl_ns: i96 = std.time.ns_per_s;
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

const OperationCache = struct {
    allocator: Allocator,
    entries: std.AutoHashMap(u128, CacheEntry),

    const Self = @This();

    fn init(cache: *Self, allocator: Allocator) void {
        cache.* = .{
            .allocator = allocator,
            .entries = std.AutoHashMap(u128, CacheEntry).init(allocator),
        };
        std.debug.assert(cache.entries.count() == 0);
    }

    fn deinit(cache: *Self) void {
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

const QueryAdapter = struct {
    context: *anyopaque,
    cache: *OperationCache,
    read_fn: *const fn (
        *anyopaque,
        Allocator,
        u128,
    ) anyerror!operation.Operation,

    fn init(pointer: anytype, cache: *OperationCache) QueryAdapter {
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
    const outcome = invocationOutcome(
        allocator,
        event,
        environment,
        query,
        authentication_now,
        monotonic_now_ns,
    );
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
    authentication_now: i64,
    monotonic_now_ns: i96,
) InvocationOutcome {
    const request = lambda.url.parseRequest(allocator, event) catch {
        return .internal_server_error;
    };
    defer request.deinit(allocator);
    var identity = lambda_auth.authenticate(
        allocator,
        &request,
        environment,
        authentication_now,
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
    return queryInvocationOutcome(
        allocator,
        identity.subject,
        &request,
        query,
        monotonic_now_ns,
    );
}

fn queryInvocationOutcome(
    allocator: Allocator,
    tenant: []const u8,
    request: *const lambda.url.Request,
    query: QueryAdapter,
    monotonic_now_ns: i96,
) InvocationOutcome {
    std.debug.assert(tenant.len > 0);
    std.debug.assert(tenant.len <= operation.tenant_size_max);

    const id = operationIDFromRawPath(request.raw_path) catch {
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
        .hash = [_]u8{0xab} ** 32,
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

test "authenticated GET returns exact SUBMITTED operation JSON and canonicalizes UUID" {
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
        "\\\"hash\\\":\\\"" ++ ("ab" ** 32) ++ "\\\"}\"}";
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
    const event = try testRequestEvent(.{
        .method = .GET,
        .token = token,
        .raw_path = "/00112233-4455-6677-8899-aabbccddeeff",
    });
    defer std.testing.allocator.free(event);
    var fake = FakeQuery{ .response = testOperation("lambda-test-user", .completed) };

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
        "\\\"state\\\":\\\"COMPLETED\\\",\\\"last_updated\\\":1700000123," ++
        "\\\"expires_at\\\":1700086523,\\\"result\\\":{" ++
        "\\\"type\\\":\\\"SUCCESS\\\",\\\"payload\\\":\\\"done\\\"}," ++
        "\\\"hash\\\":\\\"" ++ ("ab" ** 32) ++ "\\\"}\"}";
    try std.testing.expectEqualStrings(expected, response);

    var failure = testOperation("lambda-test-user", .completed);
    failure.state = .{ .completed = .{ .failure = .{ .string = "done" } } };
    fake.response = failure;
    const failure_response = handleInvocationForTest(
        std.testing.allocator,
        event,
        &environment,
        &fake,
        1000,
    );
    defer std.testing.allocator.free(failure_response);
    const expected_failure =
        "{\"statusCode\":200,\"headers\":{\"Content-Type\":\"application/json\"}," ++
        "\"body\":\"{\\\"id\\\":\\\"00112233-4455-6677-8899-aabbccddeeff\\\"," ++
        "\\\"tenant\\\":\\\"lambda-test-user\\\",\\\"name\\\":\\\"echo\\\"," ++
        "\\\"state\\\":\\\"COMPLETED\\\",\\\"last_updated\\\":1700000123," ++
        "\\\"expires_at\\\":1700086523,\\\"result\\\":{" ++
        "\\\"type\\\":\\\"FAILURE\\\",\\\"payload\\\":\\\"done\\\"}," ++
        "\\\"hash\\\":\\\"" ++ ("ab" ** 32) ++ "\\\"}\"}";
    try std.testing.expectEqualStrings(expected_failure, failure_response);
}

test "second lookup before one second uses cached response" {
    const token = try testToken(0x77);
    defer std.testing.allocator.free(token);
    var environment = try testEnvironment(0x77);
    defer environment.deinit();
    const event = try testQueryRequestEvent(token);
    defer std.testing.allocator.free(event);
    var fake = FakeQuery{ .response = testOperation("lambda-test-user", .submitted) };
    var cache: OperationCache = undefined;
    OperationCache.init(&cache, std.testing.allocator);
    defer cache.deinit();

    const first = handleInvocationWithCacheForTest(
        std.testing.allocator,
        event,
        &environment,
        &fake,
        &cache,
        1000,
        10,
    );
    defer std.testing.allocator.free(first);
    fake.response = testOperation("lambda-test-user", .completed);
    const second = handleInvocationWithCacheForTest(
        std.testing.allocator,
        event,
        &environment,
        &fake,
        &cache,
        1000,
        10 + cache_ttl_ns - 1,
    );
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, second, "SUBMITTED") != null);
    try std.testing.expectEqual(@as(u8, 1), fake.read_count);
    try std.testing.expectEqual(@as(u32, 1), cache.entries.count());
}

test "cache entry expires and is replaced at exactly one second" {
    const token = try testToken(0x78);
    defer std.testing.allocator.free(token);
    var environment = try testEnvironment(0x78);
    defer environment.deinit();
    const event = try testQueryRequestEvent(token);
    defer std.testing.allocator.free(event);
    var fake = FakeQuery{ .response = testOperation("lambda-test-user", .submitted) };
    var cache: OperationCache = undefined;
    OperationCache.init(&cache, std.testing.allocator);
    defer cache.deinit();

    const first = handleInvocationWithCacheForTest(
        std.testing.allocator,
        event,
        &environment,
        &fake,
        &cache,
        1000,
        0,
    );
    defer std.testing.allocator.free(first);
    fake.response = testOperation("lambda-test-user", .completed);
    const second = handleInvocationWithCacheForTest(
        std.testing.allocator,
        event,
        &environment,
        &fake,
        &cache,
        1000,
        cache_ttl_ns,
    );
    defer std.testing.allocator.free(second);

    try std.testing.expect(std.mem.indexOf(u8, first, "SUBMITTED") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "COMPLETED") != null);
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
    const foreign_event = try testQueryRequestEvent(foreign_token);
    defer std.testing.allocator.free(foreign_event);
    const owner_event = try testQueryRequestEvent(owner_token);
    defer std.testing.allocator.free(owner_event);
    var fake = FakeQuery{ .response = testOperation("owning-tenant", .submitted) };
    var cache: OperationCache = undefined;
    OperationCache.init(&cache, std.testing.allocator);
    defer cache.deinit();

    const foreign_response = handleInvocationWithCacheForTest(
        std.testing.allocator,
        foreign_event,
        &environment,
        &fake,
        &cache,
        1000,
        0,
    );
    defer std.testing.allocator.free(foreign_response);
    fake.read_error = error.AWSFailure;
    const owner_response = handleInvocationWithCacheForTest(
        std.testing.allocator,
        owner_event,
        &environment,
        &fake,
        &cache,
        1000,
        cache_ttl_ns - 1,
    );
    defer std.testing.allocator.free(owner_response);

    try std.testing.expect(std.mem.indexOf(u8, foreign_response, "statusCode\":404") != null);
    try expectNotContains(foreign_response, "owning-tenant");
    try std.testing.expect(std.mem.indexOf(u8, owner_response, "statusCode\":200") != null);
    try std.testing.expect(std.mem.indexOf(u8, owner_response, "owning-tenant") != null);
    try std.testing.expectEqual(@as(u8, 1), fake.read_count);
    try std.testing.expectEqual(@as(u32, 1), cache.entries.count());
}

test "missing operations are fetched on every request" {
    const token = try testToken(0x7a);
    defer std.testing.allocator.free(token);
    var environment = try testEnvironment(0x7a);
    defer environment.deinit();
    const event = try testQueryRequestEvent(token);
    defer std.testing.allocator.free(event);
    var fake = FakeQuery{ .read_error = error.OperationNotFound };
    var cache: OperationCache = undefined;
    OperationCache.init(&cache, std.testing.allocator);
    defer cache.deinit();

    for (0..2) |monotonic_now_ns| {
        const response = handleInvocationWithCacheForTest(
            std.testing.allocator,
            event,
            &environment,
            &fake,
            &cache,
            1000,
            @intCast(monotonic_now_ns),
        );
        defer std.testing.allocator.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "statusCode\":404") != null);
    }
    try std.testing.expectEqual(@as(u8, 2), fake.read_count);
    try std.testing.expectEqual(@as(u32, 0), cache.entries.count());
}

test "full fresh cache serves fetched record without caching it" {
    const token = try testToken(0x7b);
    defer std.testing.allocator.free(token);
    var environment = try testEnvironment(0x7b);
    defer environment.deinit();
    const event = try testQueryRequestEvent(token);
    defer std.testing.allocator.free(event);
    var fake = FakeQuery{ .response = testOperation("lambda-test-user", .submitted) };
    var cache: OperationCache = undefined;
    OperationCache.init(&cache, std.testing.allocator);
    defer cache.deinit();
    try fillTestCache(&cache, 0);
    const target_id = testOperation("lambda-test-user", .submitted).id;
    std.debug.assert(target_id >= cache_entry_count_max);

    for (0..2) |_| {
        const response = handleInvocationWithCacheForTest(
            std.testing.allocator,
            event,
            &environment,
            &fake,
            &cache,
            1000,
            cache_ttl_ns - 1,
        );
        defer std.testing.allocator.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "statusCode\":200") != null);
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
    const event = try testQueryRequestEvent(token);
    defer std.testing.allocator.free(event);
    var fake = FakeQuery{ .response = testOperation("lambda-test-user", .submitted) };
    var cache: OperationCache = undefined;
    OperationCache.init(&cache, std.testing.allocator);
    defer cache.deinit();
    try fillTestCache(&cache, 0);
    const target_id = testOperation("lambda-test-user", .submitted).id;
    std.debug.assert(target_id >= cache_entry_count_max);

    const first = handleInvocationWithCacheForTest(
        std.testing.allocator,
        event,
        &environment,
        &fake,
        &cache,
        1000,
        cache_ttl_ns,
    );
    defer std.testing.allocator.free(first);
    const second = handleInvocationWithCacheForTest(
        std.testing.allocator,
        event,
        &environment,
        &fake,
        &cache,
        1000,
        cache_ttl_ns,
    );
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expectEqual(@as(u8, 1), fake.read_count);
    try std.testing.expectEqual(@as(u32, 1), cache.entries.count());
    try std.testing.expect(cache.entries.contains(target_id));
}

test "cache allocation failures serve fetched response without caching" {
    const token = try testToken(0x7d);
    defer std.testing.allocator.free(token);
    var environment = try testEnvironment(0x7d);
    defer environment.deinit();
    const event = try testQueryRequestEvent(token);
    defer std.testing.allocator.free(event);

    for ([_]usize{ 0, 1, 2 }) |fail_index| {
        var failing_allocator = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var cache: OperationCache = undefined;
        OperationCache.init(&cache, failing_allocator.allocator());
        defer cache.deinit();
        var fake = FakeQuery{ .response = testOperation("lambda-test-user", .submitted) };

        const response = handleInvocationWithCacheForTest(
            std.testing.allocator,
            event,
            &environment,
            &fake,
            &cache,
            1000,
            0,
        );
        defer std.testing.allocator.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "statusCode\":200") != null);
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
    var foreign = FakeQuery{ .response = testOperation("another-tenant", .submitted) };

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
        .state = .submitted,
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

fn testQueryRequestEvent(token: []const u8) ![]u8 {
    return testRequestEvent(.{
        .method = .GET,
        .token = token,
        .raw_path = "/00112233-4455-6677-8899-aabbccddeeff",
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
