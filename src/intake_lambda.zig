const std = @import("std");
const aws = @import("aws");
const lambda = @import("aws-lambda");
const lambda_auth = @import("lambda_auth");
const operation = @import("operation");
const operation_persistence = @import("operation_persistence");
const operation_queue = @import("operation_queue");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{
        .scope = .aws_sdk,
        .level = .debug,
    }},
};

const Allocator = std.mem.Allocator;

const bad_request_body = "Bad Request\n";
const conflict_body = "Conflict\n";
const content_type_json = "application/json";
const content_type_text = "text/plain; charset=utf-8";
const internal_server_error_body = "Internal Server Error\n";
const internal_server_error_response =
    "{\"statusCode\":500,\"headers\":{\"Content-Type\":\"" ++ content_type_text ++
    "\"},\"body\":\"Internal Server Error\\n\"}";
const method_not_allowed_body = "Method Not Allowed\n";
const operation_message_size_max = 8 * 1024;
const service_unavailable_body = "Service Unavailable\n";
const unauthorized_body = "Unauthorized\n";

comptime {
    std.debug.assert(operation_message_size_max > operation.body_size_max);
    std.debug.assert(lambda_auth.subject_size_max == operation.tenant_size_max);
}

var runtime_intake_adapter: ?IntakeAdapter = null;

pub fn main(init: std.process.Init) void {
    var resources: RuntimeResources = undefined;
    resources.init(init) catch |err| {
        std.log.err("Lambda initialization failed: {s}", .{@errorName(err)});
        return;
    };
    defer resources.deinit();

    installRuntimeIntakeAdapter(IntakeAdapter.init(&resources));
    defer uninstallRuntimeIntakeAdapter();
    lambda.handle(init, handler, .{});
}

fn handler(ctx: lambda.Context, event: []const u8) ![]const u8 {
    const intake = runtime_intake_adapter orelse {
        return error.PersistenceNotInitialized;
    };
    const now = std.Io.Clock.real.now(ctx.io).toSeconds();
    return handleInvocation(
        ctx.arena,
        event,
        @field(ctx, "_").kv,
        intake,
        now,
    );
}

const RuntimeResources = struct {
    config: aws.Config,
    persistence: operation_persistence.Persistence,
    queue: operation_queue.Queue,

    fn init(resources: *RuntimeResources, process_init: std.process.Init) !void {
        resources.config = aws.Config.load(
            process_init.gpa,
            process_init.io,
            process_init.environ_map,
            .{},
        ) catch return error.AWSConfigurationFailure;
        errdefer resources.config.deinit();

        operation_queue.Queue.init(
            &resources.queue,
            process_init.gpa,
            &resources.config,
            process_init.environ_map,
        ) catch return error.InvalidQueueConfiguration;
        errdefer resources.queue.deinit();
        operation_persistence.Persistence.init(
            &resources.persistence,
            process_init.gpa,
            &resources.config,
            process_init.environ_map,
        ) catch return error.PersistenceConfigurationFailure;
    }

    fn deinit(resources: *RuntimeResources) void {
        resources.persistence.deinit();
        resources.queue.deinit();
        resources.config.deinit();
        resources.* = undefined;
    }

    fn create(
        resources: *RuntimeResources,
        arena: Allocator,
        source: *const operation.Operation,
    ) !operation.Operation {
        return resources.persistence.create(arena, source);
    }

    fn send(
        resources: *RuntimeResources,
        arena: Allocator,
        message: []const u8,
    ) !void {
        std.debug.assert(message.len > 0);
        return resources.queue.send(arena, message);
    }
};

const IntakeAdapter = struct {
    context: *anyopaque,
    create_fn: *const fn (
        *anyopaque,
        Allocator,
        *const operation.Operation,
    ) anyerror!operation.Operation,
    send_fn: *const fn (
        *anyopaque,
        Allocator,
        []const u8,
    ) anyerror!void,

    fn init(pointer: anytype) IntakeAdapter {
        const Pointer = @TypeOf(pointer);
        const pointer_info = @typeInfo(Pointer);
        comptime std.debug.assert(pointer_info == .pointer);
        comptime std.debug.assert(pointer_info.pointer.size == .one);

        const Adapter = struct {
            fn create(
                context: *anyopaque,
                allocator: Allocator,
                source: *const operation.Operation,
            ) anyerror!operation.Operation {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.create(allocator, source);
            }

            fn send(
                context: *anyopaque,
                allocator: Allocator,
                message: []const u8,
            ) anyerror!void {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.send(allocator, message);
            }
        };
        return .{
            .context = pointer,
            .create_fn = Adapter.create,
            .send_fn = Adapter.send,
        };
    }

    fn create(
        intake: IntakeAdapter,
        allocator: Allocator,
        source: *const operation.Operation,
    ) !operation.Operation {
        return intake.create_fn(intake.context, allocator, source);
    }

    fn send(
        intake: IntakeAdapter,
        allocator: Allocator,
        message: []const u8,
    ) !void {
        return intake.send_fn(intake.context, allocator, message);
    }
};

fn installRuntimeIntakeAdapter(intake: IntakeAdapter) void {
    std.debug.assert(runtime_intake_adapter == null);
    runtime_intake_adapter = intake;
    std.debug.assert(runtime_intake_adapter != null);
}

fn uninstallRuntimeIntakeAdapter() void {
    std.debug.assert(runtime_intake_adapter != null);
    runtime_intake_adapter = null;
    std.debug.assert(runtime_intake_adapter == null);
}

fn handleInvocation(
    allocator: Allocator,
    event: []const u8,
    env: *const std.process.Environ.Map,
    intake: IntakeAdapter,
    now: i64,
) []const u8 {
    const outcome = invocationOutcome(allocator, event, env, intake, now);
    return encodeOutcome(allocator, outcome) catch internal_server_error_response;
}

const InvocationOutcome = union(enum) {
    success: Success,
    bad_request,
    conflict,
    method_not_allowed,
    service_unavailable,
    unauthorized,
    internal_server_error,
};

const Success = struct {
    body: []const u8,
    content_type: []const u8,
};

fn invocationOutcome(
    allocator: Allocator,
    event: []const u8,
    env: *const std.process.Environ.Map,
    intake: IntakeAdapter,
    now: i64,
) InvocationOutcome {
    const request = lambda.url.parseRequest(allocator, event) catch {
        return .internal_server_error;
    };
    defer request.deinit(allocator);
    var identity = lambda_auth.authenticate(allocator, &request, env, now) catch |err| {
        return switch (err) {
            error.Unauthorized => .unauthorized,
            error.InternalFailure => .internal_server_error,
        };
    };
    defer identity.deinit();

    const method = request.request_context.http.method orelse {
        return .method_not_allowed;
    };
    if (method != .POST) return .method_not_allowed;
    return post_invocation_outcome(allocator, identity.subject, &request, intake, now);
}

fn post_invocation_outcome(
    allocator: Allocator,
    tenant: []const u8,
    request: *const lambda.url.Request,
    intake: IntakeAdapter,
    now: operation.UnixSeconds,
) InvocationOutcome {
    const input_json = request.body orelse return .bad_request;
    var operation_arena = std.heap.ArenaAllocator.init(allocator);
    defer operation_arena.deinit();
    const arena = operation_arena.allocator();
    const parsed = operation.parseInputJSON(
        arena,
        input_json,
        .{
            .tenant = tenant,
            .now = now,
        },
    ) catch |err| {
        return switch (err) {
            error.OutOfMemory => .internal_server_error,
            else => .bad_request,
        };
    };
    const created = intake.create(arena, &parsed) catch |err| {
        return switch (err) {
            error.OperationConflict => .conflict,
            else => .internal_server_error,
        };
    };
    if (created.state.? != .new) return operation_success_outcome(allocator, &created);

    var queued = created;
    queued.body = parsed.body;
    queued.result = null;
    const message = operation_message_body(arena, &queued) catch {
        return .internal_server_error;
    };
    intake.send(arena, message) catch |err| {
        if (err == error.OutOfMemory) return .internal_server_error;
        return .service_unavailable;
    };

    return operation_success_outcome(allocator, &created);
}

fn operation_message_body(
    allocator: Allocator,
    queued: *const operation.Operation,
) ![]const u8 {
    std.debug.assert(queued.body != null);
    std.debug.assert(queued.state == .new);

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try operation.writeOutputJSON(&output.writer, queued);
    if (output.written().len > operation_message_size_max) {
        return error.OperationMessageTooLarge;
    }
    std.debug.assert(output.written().len > 0);
    std.debug.assert(output.written().len <= operation_message_size_max);
    return output.toOwnedSlice();
}

fn operation_success_outcome(
    allocator: Allocator,
    persisted: *const operation.Operation,
) InvocationOutcome {
    const body = operation_output_body(allocator, persisted) catch {
        return .internal_server_error;
    };
    return .{ .success = .{
        .body = body,
        .content_type = content_type_json,
    } };
}

fn operation_output_body(
    allocator: Allocator,
    persisted: *const operation.Operation,
) ![]const u8 {
    std.debug.assert(persisted.body == null);
    std.debug.assert(persisted.state != null);
    std.debug.assert(persisted.last_updated != null);
    std.debug.assert(persisted.expires_at != null);

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try operation.writeOutputJSON(&output.writer, persisted);
    std.debug.assert(output.written().len > 0);
    return output.toOwnedSlice();
}

fn encodeOutcome(
    allocator: std.mem.Allocator,
    outcome: InvocationOutcome,
) ![]const u8 {
    return switch (outcome) {
        .success => |response| success: {
            defer allocator.free(response.body);
            break :success lambda.url.encodeResponse(allocator, .{
                .content_type = response.content_type,
                .body = .{ .textual = response.body },
            });
        },
        .bad_request => lambda.url.encodeResponse(allocator, .{
            .content_type = content_type_text,
            .status_code = .bad_request,
            .body = .{ .textual = bad_request_body },
        }),
        .conflict => lambda.url.encodeResponse(allocator, .{
            .content_type = content_type_text,
            .status_code = .conflict,
            .body = .{ .textual = conflict_body },
        }),
        .method_not_allowed => lambda.url.encodeResponse(allocator, .{
            .content_type = content_type_text,
            .status_code = .method_not_allowed,
            .headers = &.{
                .{ .key = "Allow", .value = "POST" },
            },
            .body = .{ .textual = method_not_allowed_body },
        }),
        .service_unavailable => lambda.url.encodeResponse(allocator, .{
            .content_type = content_type_text,
            .status_code = .service_unavailable,
            .body = .{ .textual = service_unavailable_body },
        }),
        .unauthorized => lambda.url.encodeResponse(allocator, .{
            .content_type = content_type_text,
            .status_code = .unauthorized,
            .headers = &.{
                .{ .key = "WWW-Authenticate", .value = "Bearer" },
            },
            .body = .{ .textual = unauthorized_body },
        }),
        .internal_server_error => lambda.url.encodeResponse(allocator, .{
            .content_type = content_type_text,
            .status_code = .internal_server_error,
            .body = .{ .textual = internal_server_error_body },
        }),
    };
}

const FakeIntake = struct {
    response: ?operation.Operation = null,
    create_error: ?anyerror = null,
    send_error: ?anyerror = null,
    create_count: u8 = 0,
    send_count: u8 = 0,
    last_id: u128 = 0,
    last_state: ?operation.State = null,
    last_updated: ?operation.UnixSeconds = null,
    last_expires_at: ?operation.UnixSeconds = null,
    last_hash: ?[32]u8 = null,
    last_tenant_buffer: [operation.tenant_size_max]u8 = undefined,
    last_tenant_len: u8 = 0,
    last_name_buffer: [operation.name_size_max]u8 = undefined,
    last_name_len: u8 = 0,
    last_body_buffer: [operation.body_size_max]u8 = undefined,
    last_body_len: u16 = 0,
    last_message_buffer: [operation_message_size_max]u8 = undefined,
    last_message_len: u16 = 0,

    fn create(
        fake: *FakeIntake,
        _: Allocator,
        source: *const operation.Operation,
    ) !operation.Operation {
        std.debug.assert(fake.create_count < 32);
        std.debug.assert(source.tenant.len <= fake.last_tenant_buffer.len);
        std.debug.assert(source.name.len <= fake.last_name_buffer.len);
        fake.create_count += 1;
        fake.last_id = source.id;
        fake.last_state = source.state;
        fake.last_updated = source.last_updated;
        fake.last_expires_at = source.expires_at;
        fake.last_hash = source.hash;
        fake.last_tenant_len = @intCast(source.tenant.len);
        @memcpy(fake.last_tenant_buffer[0..source.tenant.len], source.tenant);
        fake.last_name_len = @intCast(source.name.len);
        @memcpy(fake.last_name_buffer[0..source.name.len], source.name);
        const body = try operation.writeResultJSON(&fake.last_body_buffer, &source.body.?);
        fake.last_body_len = @intCast(body.len);

        if (fake.create_error) |err| return err;
        if (fake.response) |response| return response;
        var created = source.*;
        created.body = null;
        std.debug.assert(created.body == null);
        return created;
    }

    fn send(
        fake: *FakeIntake,
        _: Allocator,
        message: []const u8,
    ) !void {
        std.debug.assert(fake.send_count < 32);
        std.debug.assert(message.len <= fake.last_message_buffer.len);
        fake.send_count += 1;
        fake.last_message_len = @intCast(message.len);
        @memcpy(fake.last_message_buffer[0..message.len], message);
        if (fake.send_error) |err| return err;
    }

    fn lastName(fake: *const FakeIntake) []const u8 {
        return fake.last_name_buffer[0..fake.last_name_len];
    }

    fn lastTenant(fake: *const FakeIntake) []const u8 {
        return fake.last_tenant_buffer[0..fake.last_tenant_len];
    }

    fn lastBody(fake: *const FakeIntake) []const u8 {
        return fake.last_body_buffer[0..fake.last_body_len];
    }

    fn lastMessage(fake: *const FakeIntake) []const u8 {
        return fake.last_message_buffer[0..fake.last_message_len];
    }
};

fn handleInvocationForTest(
    allocator: Allocator,
    event: []const u8,
    cfg: lambda.Context.ConfigMeta,
    req: lambda.Context.RequestMeta,
    env: *const std.process.Environ.Map,
    fake: *FakeIntake,
    now: i64,
) []const u8 {
    _ = cfg;
    _ = req;
    return handleInvocation(
        allocator,
        event,
        env,
        IntakeAdapter.init(fake),
        now,
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

test "authenticated POST persists and queues NEW then returns without its body" {
    const token = try lambda_auth.testing.issue_token(std.testing.allocator, .{
        .seed_byte = 0x42,
        .now = 1_700_000_000,
        .ttl_seconds = 60,
    });
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try lambda_auth.testing.put_public_key(&environment, 0x42);

    const inputs = [_][]const u8{
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"name\":\"echo\",\"body\":{\"message\":\"hello\",\"count\":2}}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"name\":\"echo\",\"body\":{\"message\":\"hello\",\"count\":2}," ++
            "\"state\":\"NEW\"}",
    };
    const expected =
        "{\"statusCode\":200,\"headers\":{\"Content-Type\":\"application/json\"}," ++
        "\"body\":\"{\\\"id\\\":\\\"00112233-4455-6677-8899-aabbccddeeff\\\"," ++
        "\\\"tenant\\\":\\\"lambda-test-user\\\",\\\"name\\\":\\\"echo\\\"," ++
        "\\\"state\\\":\\\"NEW\\\"," ++
        "\\\"last_updated\\\":1700000000," ++
        "\\\"expires_at\\\":1700086400," ++
        "\\\"hash\\\":\\\"471493bf210a9c6922a2f0870d05a655ba9f859bffecd57972ebfe39863b672c\\\"}\"}";
    const expected_message =
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
        "\"tenant\":\"lambda-test-user\",\"name\":\"echo\"," ++
        "\"body\":{\"message\":\"hello\",\"count\":2}," ++
        "\"state\":\"NEW\",\"last_updated\":1700000000," ++
        "\"expires_at\":1700086400," ++
        "\"hash\":\"471493bf210a9c6922a2f0870d05a655ba9f859bffecd57972ebfe39863b672c\"}";

    for (inputs) |input| {
        var fake: FakeIntake = .{};
        const event = try test_authorization_request_event(
            std.testing.allocator,
            .POST,
            "Authorization",
            "Bearer",
            token,
            input,
        );
        defer std.testing.allocator.free(event);
        const response = handleInvocationForTest(
            std.testing.allocator,
            event,
            .{},
            .{},
            &environment,
            &fake,
            1_700_000_000,
        );
        defer std.testing.allocator.free(response);

        try std.testing.expectEqualStrings(expected, response);
        try expectNotContains(response, "message");
        try expectNotContains(response, "count");
        try std.testing.expectEqual(@as(u8, 1), fake.create_count);
        try std.testing.expectEqual(
            operation.uuidFromString("00112233-4455-6677-8899-aabbccddeeff") catch unreachable,
            fake.last_id,
        );
        try std.testing.expectEqual(operation.State.new, fake.last_state.?);
        try std.testing.expectEqual(@as(i64, 1_700_000_000), fake.last_updated.?);
        try std.testing.expectEqual(@as(i64, 1_700_086_400), fake.last_expires_at.?);
        try std.testing.expectEqualStrings("lambda-test-user", fake.lastTenant());
        try std.testing.expectEqualStrings("echo", fake.lastName());
        try std.testing.expectEqualStrings(
            "{\"message\":\"hello\",\"count\":2}",
            fake.lastBody(),
        );
        try std.testing.expectEqualStrings(expected_message, fake.lastMessage());
        try std.testing.expectEqual(@as(u8, 1), fake.send_count);
        var expected_hash: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(
            &expected_hash,
            "471493bf210a9c6922a2f0870d05a655ba9f859bffecd57972ebfe39863b672c",
        );
        try std.testing.expectEqualSlices(u8, &expected_hash, &fake.last_hash.?);
    }
}

test "POST queues every JSON body variant as exact full Operation JSON" {
    const token = try lambda_auth.testing.issue_token(std.testing.allocator, .{
        .seed_byte = 0x51,
        .now = 1_700_000_000,
        .ttl_seconds = 60,
    });
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try lambda_auth.testing.put_public_key(&environment, 0x51);

    const bodies = [_][]const u8{ "null", "false", "42", "\"text\"", "[1]", "{\"a\":1}" };
    const messages = [_][]const u8{
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"lambda-test-user\",\"name\":\"variants\",\"body\":null," ++
            "\"state\":\"NEW\",\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400," ++
            "\"hash\":\"fd177e1082fafe25e8ae2bc301281fc4f4a5a0776ab241d35cf9ed91a46db3b3\"}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"lambda-test-user\",\"name\":\"variants\",\"body\":false," ++
            "\"state\":\"NEW\",\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400," ++
            "\"hash\":\"6e18221b306b6bfd8753e910d58beb8cf007da71923dc7b52011f107fbc51d1c\"}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"lambda-test-user\",\"name\":\"variants\",\"body\":42," ++
            "\"state\":\"NEW\",\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400," ++
            "\"hash\":\"d5ccd414185af1692c3678f3cde5756d3bb12a7cbfd0f39f797610b3fa7bd235\"}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"lambda-test-user\",\"name\":\"variants\",\"body\":\"text\"," ++
            "\"state\":\"NEW\",\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400," ++
            "\"hash\":\"576bfabb751a1c5df078d4d24cd5bd66c00cec5b765e898b7eb3743693a0c2bb\"}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"lambda-test-user\",\"name\":\"variants\",\"body\":[1]," ++
            "\"state\":\"NEW\",\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400," ++
            "\"hash\":\"9a2a3875c2b05917ae674a0d5b6f1bfc71d6dec7b3cb71059f9c21f60709cbc9\"}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"lambda-test-user\",\"name\":\"variants\",\"body\":{\"a\":1}," ++
            "\"state\":\"NEW\",\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400," ++
            "\"hash\":\"72773a3103040a8266d9052ef82f5119ea53608cc1aac4ae8844721705e292dd\"}",
    };

    for (bodies, messages) |body, expected_message| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
                "\"name\":\"variants\",\"body\":{s}}}",
            .{body},
        );
        defer std.testing.allocator.free(input);
        const event = try test_authorization_request_event(
            std.testing.allocator,
            .POST,
            "Authorization",
            "Bearer",
            token,
            input,
        );
        defer std.testing.allocator.free(event);
        var fake: FakeIntake = .{};
        const response = handleInvocationForTest(
            std.testing.allocator,
            event,
            .{},
            .{},
            &environment,
            &fake,
            1_700_000_000,
        );
        defer std.testing.allocator.free(response);

        try std.testing.expectEqualStrings(expected_message, fake.lastMessage());
        try expectContains(response, "\\\"state\\\":\\\"NEW\\\"");
        try expectNotContains(response, "\\\"body\\\":");
        try std.testing.expectEqual(@as(u8, 1), fake.send_count);
    }
}

test "POST derives tenant and hash from distinct bounded verified subjects" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try lambda_auth.testing.put_public_key(&environment, 0x49);
    const subjects = [_][]const u8{
        "a" ** lambda_auth.subject_size_max,
        "tenant-b",
    };
    const input =
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
        "\"name\":\"echo\",\"body\":null}";
    var hashes: [subjects.len][32]u8 = undefined;

    for (subjects, 0..) |subject, index| {
        const token = try lambda_auth.testing.issue_token(std.testing.allocator, .{
            .seed_byte = 0x49,
            .subject = subject,
            .now = 1000,
            .ttl_seconds = 60,
        });
        defer std.testing.allocator.free(token);
        const event = try test_authorization_request_event(
            std.testing.allocator,
            .POST,
            "Authorization",
            "Bearer",
            token,
            input,
        );
        defer std.testing.allocator.free(event);
        var fake: FakeIntake = .{};
        const response = handleInvocationForTest(
            std.testing.allocator,
            event,
            .{},
            .{},
            &environment,
            &fake,
            1000,
        );
        defer std.testing.allocator.free(response);

        try expectContains(response, subject);
        try std.testing.expectEqualStrings(subject, fake.lastTenant());
        hashes[index] = fake.last_hash.?;
    }
    try std.testing.expect(!std.mem.eql(u8, &hashes[0], &hashes[1]));
}

test "matching NEW POST requeues and returns the stored snapshot" {
    const token = try lambda_auth.testing.issue_token(std.testing.allocator, .{
        .seed_byte = 0x52,
        .now = 1_700_000_500,
        .ttl_seconds = 60,
    });
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try lambda_auth.testing.put_public_key(&environment, 0x52);
    const input =
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
        "\"name\":\"echo\",\"body\":{\"message\":\"hello\",\"count\":2}}";
    const event = try test_authorization_request_event(
        std.testing.allocator,
        .POST,
        "Authorization",
        "Bearer",
        token,
        input,
    );
    defer std.testing.allocator.free(event);
    var expected_hash: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_hash,
        "471493bf210a9c6922a2f0870d05a655ba9f859bffecd57972ebfe39863b672c",
    );
    var fake = FakeIntake{ .response = .{
        .id = operation.uuidFromString(
            "00112233-4455-6677-8899-aabbccddeeff",
        ) catch unreachable,
        .tenant = "lambda-test-user",
        .name = "echo",
        .state = .new,
        .last_updated = 1_699_999_000,
        .expires_at = 1_700_085_400,
        .hash = expected_hash,
    } };

    const response = handleInvocationForTest(
        std.testing.allocator,
        event,
        .{},
        .{},
        &environment,
        &fake,
        1_700_000_500,
    );
    defer std.testing.allocator.free(response);

    try expectContains(response, "\\\"state\\\":\\\"NEW\\\"");
    try expectContains(response, "\\\"last_updated\\\":1699999000");
    try expectContains(response, "\\\"expires_at\\\":1700085400");
    try expectContains(fake.lastMessage(), "\"body\":{\"message\":\"hello\",\"count\":2}");
    try expectContains(fake.lastMessage(), "\"last_updated\":1699999000");
    try std.testing.expectEqual(@as(u8, 1), fake.send_count);
}

test "matching POST retry returns the latest stored persistent view" {
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    const token = try lambda_auth.testing.issue_token(std.testing.allocator, .{
        .seed_byte = 0x45,
        .now = 1_700_000_000,
        .ttl_seconds = 60,
    });
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try lambda_auth.testing.put_public_key(&environment, 0x45);

    var expected_hash: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_hash,
        "471493bf210a9c6922a2f0870d05a655ba9f859bffecd57972ebfe39863b672c",
    );
    var fake = FakeIntake{ .response = .{
        .id = operation.uuidFromString(
            "00112233-4455-6677-8899-aabbccddeeff",
        ) catch unreachable,
        .tenant = "lambda-test-user",
        .name = "echo",
        .state = .succeeded,
        .last_updated = 1_700_000_123,
        .expires_at = 1_700_086_523,
        .result = try operation.parseResultJSON(
            result_arena.allocator(),
            "{ \"message\" : \"done\" }",
        ),
        .hash = expected_hash,
    } };
    const input =
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
        "\"name\":\"echo\",\"body\":{\"message\":\"hello\",\"count\":2}}";
    const event = try test_authorization_request_event(
        std.testing.allocator,
        .POST,
        "Authorization",
        "Bearer",
        token,
        input,
    );
    defer std.testing.allocator.free(event);
    const response = handleInvocationForTest(
        std.testing.allocator,
        event,
        .{},
        .{},
        &environment,
        &fake,
        1_700_000_000,
    );
    defer std.testing.allocator.free(response);

    const expected =
        "{\"statusCode\":200,\"headers\":{\"Content-Type\":\"application/json\"}," ++
        "\"body\":\"{\\\"id\\\":\\\"00112233-4455-6677-8899-aabbccddeeff\\\"," ++
        "\\\"tenant\\\":\\\"lambda-test-user\\\",\\\"name\\\":\\\"echo\\\"," ++
        "\\\"state\\\":\\\"SUCCEEDED\\\"," ++
        "\\\"last_updated\\\":1700000123," ++
        "\\\"expires_at\\\":1700086523," ++
        "\\\"result\\\":{\\\"message\\\":\\\"done\\\"}," ++
        "\\\"hash\\\":\\\"471493bf210a9c6922a2f0870d05a655ba9f859bffecd57972ebfe39863b672c\\\"}\"}";
    try std.testing.expectEqualStrings(expected, response);
    try std.testing.expectEqual(@as(u8, 1), fake.create_count);
}

test "matching POST in every terminal state returns without enqueueing" {
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    const token = try lambda_auth.testing.issue_token(std.testing.allocator, .{
        .seed_byte = 0x53,
        .now = 1_700_000_000,
        .ttl_seconds = 60,
    });
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try lambda_auth.testing.put_public_key(&environment, 0x53);
    const input =
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
        "\"name\":\"echo\",\"body\":{\"message\":\"hello\",\"count\":2}}";
    const event = try test_authorization_request_event(
        std.testing.allocator,
        .POST,
        "Authorization",
        "Bearer",
        token,
        input,
    );
    defer std.testing.allocator.free(event);
    var expected_hash: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_hash,
        "471493bf210a9c6922a2f0870d05a655ba9f859bffecd57972ebfe39863b672c",
    );
    const states = [_]operation.State{ .succeeded, .failed };

    for (states) |state| {
        const result = try operation.parseResultJSON(
            result_arena.allocator(),
            "{\"done\":true}",
        );
        var fake = FakeIntake{ .response = .{
            .id = operation.uuidFromString(
                "00112233-4455-6677-8899-aabbccddeeff",
            ) catch unreachable,
            .tenant = "lambda-test-user",
            .name = "echo",
            .state = state,
            .last_updated = 1_700_000_123,
            .expires_at = 1_700_086_523,
            .result = result,
            .hash = expected_hash,
        } };
        const response = handleInvocationForTest(
            std.testing.allocator,
            event,
            .{},
            .{},
            &environment,
            &fake,
            1_700_000_000,
        );
        defer std.testing.allocator.free(response);
        const state_marker = try std.fmt.allocPrint(
            std.testing.allocator,
            "\\\"state\\\":\\\"{s}\\\"",
            .{operation.stateToString(state)},
        );
        defer std.testing.allocator.free(state_marker);

        try expectContains(response, state_marker);
        try std.testing.expectEqual(@as(u8, 1), fake.create_count);
        try std.testing.expectEqual(@as(u8, 0), fake.send_count);
    }
}

test "POST conflict returns only the static conflict response" {
    const token = try lambda_auth.testing.issue_token(std.testing.allocator, .{
        .seed_byte = 0x46,
        .now = 1000,
        .ttl_seconds = 60,
    });
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try lambda_auth.testing.put_public_key(&environment, 0x46);
    var fake = FakeIntake{ .create_error = error.OperationConflict };
    const event = try test_authorization_request_event(
        std.testing.allocator,
        .POST,
        "Authorization",
        "Bearer",
        token,
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"name\":\"conflict-marker\",\"body\":true}",
    );
    defer std.testing.allocator.free(event);
    const response = handleInvocationForTest(
        std.testing.allocator,
        event,
        .{},
        .{},
        &environment,
        &fake,
        1000,
    );
    defer std.testing.allocator.free(response);

    try expectConflict(response);
    try expectNotContains(response, "conflict-marker");
    try std.testing.expectEqual(@as(u8, 1), fake.create_count);
}

test "POST persistence failures return only the static internal error" {
    const token = try lambda_auth.testing.issue_token(std.testing.allocator, .{
        .seed_byte = 0x47,
        .now = 1000,
        .ttl_seconds = 60,
    });
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try lambda_auth.testing.put_public_key(&environment, 0x47);
    const event = try test_authorization_request_event(
        std.testing.allocator,
        .POST,
        "Authorization",
        "Bearer",
        token,
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"name\":\"failure-marker\",\"body\":true}",
    );
    defer std.testing.allocator.free(event);

    const failures = [_]anyerror{
        error.AWSFailure,
        error.InvalidItem,
        error.ConnectionFailed,
        error.OutOfMemory,
    };
    for (failures) |failure| {
        var fake = FakeIntake{ .create_error = failure };
        const response = handleInvocationForTest(
            std.testing.allocator,
            event,
            .{},
            .{},
            &environment,
            &fake,
            1000,
        );
        defer std.testing.allocator.free(response);

        try expectInternalServerError(response);
        try expectNotContains(response, "failure-marker");
        try std.testing.expectEqual(@as(u8, 1), fake.create_count);
    }
}

test "SQS failure leaves NEW unchanged and a matching POST can requeue" {
    const token = try lambda_auth.testing.issue_token(std.testing.allocator, .{
        .seed_byte = 0x50,
        .now = 1000,
        .ttl_seconds = 60,
    });
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try lambda_auth.testing.put_public_key(&environment, 0x50);
    const event = try test_authorization_request_event(
        std.testing.allocator,
        .POST,
        "Authorization",
        "Bearer",
        token,
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"name\":\"queue-failure-marker\",\"body\":true}",
    );
    defer std.testing.allocator.free(event);
    var fake = FakeIntake{ .send_error = error.AWSFailure };

    const failed = handleInvocationForTest(
        std.testing.allocator,
        event,
        .{},
        .{},
        &environment,
        &fake,
        1000,
    );
    defer std.testing.allocator.free(failed);
    try expectServiceUnavailable(failed);
    try expectNotContains(failed, "queue-failure-marker");
    try expectNotContains(failed, "AWSFailure");
    try std.testing.expectEqual(@as(u8, 1), fake.send_count);

    fake.send_error = null;
    const retried = handleInvocationForTest(
        std.testing.allocator,
        event,
        .{},
        .{},
        &environment,
        &fake,
        1001,
    );
    defer std.testing.allocator.free(retried);
    try expectContains(retried, "NEW");
    try std.testing.expectEqual(@as(u8, 2), fake.create_count);
    try std.testing.expectEqual(@as(u8, 2), fake.send_count);
}

test "warm invocations reuse one adapter without retaining request data" {
    const token = try lambda_auth.testing.issue_token(std.testing.allocator, .{
        .seed_byte = 0x48,
        .now = 1000,
        .ttl_seconds = 60,
    });
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try lambda_auth.testing.put_public_key(&environment, 0x48);
    var fake: FakeIntake = .{};
    const intake = IntakeAdapter.init(&fake);
    const inputs = [_][]const u8{
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"name\":\"first-operation\",\"body\":{\"value\":1}}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeef0\"," ++
            "\"name\":\"second-operation\",\"body\":{\"value\":2}}",
    };

    for (inputs, 0..) |input, index| {
        const event = try test_authorization_request_event(
            std.testing.allocator,
            .POST,
            "Authorization",
            "Bearer",
            token,
            input,
        );
        defer std.testing.allocator.free(event);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const response = handleInvocation(
            arena.allocator(),
            event,
            &environment,
            intake,
            1000 + @as(i64, @intCast(index)),
        );
        if (index == 0) {
            try expectContains(response, "first-operation");
            try expectNotContains(response, "second-operation");
        } else {
            try expectContains(response, "second-operation");
            try expectNotContains(response, "first-operation");
        }
    }
    try std.testing.expectEqual(@as(u8, 2), fake.create_count);
    try std.testing.expectEqualStrings("second-operation", fake.lastName());
    try std.testing.expectEqualStrings("{\"value\":2}", fake.lastBody());
}

test "authenticated POST rejects missing and invalid operation JSON" {
    const token = try lambda_auth.testing.issue_token(std.testing.allocator, .{
        .seed_byte = 0x43,
        .now = 1000,
        .ttl_seconds = 60,
    });
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try lambda_auth.testing.put_public_key(&environment, 0x43);
    var fake: FakeIntake = .{};

    const invalid_inputs = [_]?[]const u8{
        null,
        "{invalid-json-marker",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\",\"name\":\"echo\"}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"spoofed\",\"name\":\"echo\",\"body\":null}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"name\":\"echo\",\"body\":null,\"state\":\"SUBMITTED\"}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"name\":\"echo\",\"body\":null,\"state\":\"RUNNING\"}",
    };
    for (invalid_inputs) |input| {
        const event = try test_authorization_request_event(
            std.testing.allocator,
            .POST,
            "Authorization",
            "Bearer",
            token,
            input,
        );
        defer std.testing.allocator.free(event);
        const response = handleInvocationForTest(
            std.testing.allocator,
            event,
            .{},
            .{},
            &environment,
            &fake,
            1000,
        );
        defer std.testing.allocator.free(response);

        try expectBadRequest(response);
        try expectNotContains(response, "invalid-json-marker");
        try expectNotContains(response, "SUBMITTED");
        try expectNotContains(response, "RUNNING");
    }
    try std.testing.expectEqual(@as(u8, 0), fake.create_count);
}

test "authentication precedes method routing" {
    const token = try lambda_auth.testing.issue_token(std.testing.allocator, .{
        .seed_byte = 0x44,
        .now = 1000,
        .ttl_seconds = 60,
    });
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try lambda_auth.testing.put_public_key(&environment, 0x44);
    var fake: FakeIntake = .{};

    const unsupported_event = try test_authorization_request_event(
        std.testing.allocator,
        .GET,
        "Authorization",
        "Bearer",
        token,
        null,
    );
    defer std.testing.allocator.free(unsupported_event);
    const unsupported_response = handleInvocationForTest(
        std.testing.allocator,
        unsupported_event,
        .{},
        .{},
        &environment,
        &fake,
        1000,
    );
    defer std.testing.allocator.free(unsupported_response);
    try expectMethodNotAllowed(unsupported_response);

    const missing_method_event = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"headers\":{{\"Authorization\":\"Bearer {s}\"}}}}",
        .{token},
    );
    defer std.testing.allocator.free(missing_method_event);
    const missing_method_response = handleInvocationForTest(
        std.testing.allocator,
        missing_method_event,
        .{},
        .{},
        &environment,
        &fake,
        1000,
    );
    defer std.testing.allocator.free(missing_method_response);
    try expectMethodNotAllowed(missing_method_response);

    const unauthenticated_events = [_][]const u8{
        "{\"requestContext\":{\"http\":{\"method\":\"POST\"}}}",
        "{\"requestContext\":{\"http\":{\"method\":\"PUT\"}}}",
    };
    for (unauthenticated_events) |event| {
        const response = handleInvocationForTest(
            std.testing.allocator,
            event,
            .{},
            .{},
            &environment,
            &fake,
            1000,
        );
        defer std.testing.allocator.free(response);
        try expectUnauthorized(response);
    }
    try std.testing.expectEqual(@as(u8, 0), fake.create_count);
}

test "missing and malformed credentials return a Bearer challenge" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var fake: FakeIntake = .{};
    const missing_event =
        "{\"version\":\"2.0\",\"routeKey\":\"$default\",\"headers\":{}}";
    const missing_response = handleInvocationForTest(
        std.testing.allocator,
        missing_event,
        .{},
        .{},
        &environment,
        &fake,
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
        const response = handleInvocationForTest(
            std.testing.allocator,
            event,
            .{},
            .{},
            &environment,
            &fake,
            1000,
        );
        defer std.testing.allocator.free(response);
        try expectUnauthorized(response);
    }

    const duplicate_event =
        "{\"headers\":{\"Authorization\":\"Bearer one\"," ++
        "\"authorization\":\"Bearer two\"}}";
    const duplicate_response = handleInvocationForTest(
        std.testing.allocator,
        duplicate_event,
        .{},
        .{},
        &environment,
        &fake,
        1000,
    );
    defer std.testing.allocator.free(duplicate_response);
    try expectUnauthorized(duplicate_response);
    try std.testing.expectEqual(@as(u8, 0), fake.create_count);
}

test "wrong and expired tokens return a sanitized unauthorized response" {
    const wrong_token = try lambda_auth.testing.issue_token(std.testing.allocator, .{
        .seed_byte = 0x52,
        .now = 1000,
        .ttl_seconds = 60,
    });
    defer std.testing.allocator.free(wrong_token);
    const expired_token = try lambda_auth.testing.issue_token(std.testing.allocator, .{
        .seed_byte = 0x51,
        .now = 1000,
        .ttl_seconds = 1,
    });
    defer std.testing.allocator.free(expired_token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try lambda_auth.testing.put_public_key(&environment, 0x51);
    var fake: FakeIntake = .{};

    const tokens = [_][]const u8{ wrong_token, expired_token };
    for (tokens) |token| {
        const event = try testAuthorizationEvent(
            std.testing.allocator,
            "Authorization",
            "Bearer",
            token,
        );
        defer std.testing.allocator.free(event);
        const response = handleInvocationForTest(
            std.testing.allocator,
            event,
            .{},
            .{},
            &environment,
            &fake,
            1001,
        );
        defer std.testing.allocator.free(response);
        try expectUnauthorized(response);
        try expectNotContains(response, token);
    }
    try std.testing.expectEqual(@as(u8, 0), fake.create_count);
}

test "missing and invalid public key configuration return sanitized errors" {
    const token = try lambda_auth.testing.issue_token(std.testing.allocator, .{
        .seed_byte = 0x61,
        .now = 1000,
        .ttl_seconds = 60,
    });
    defer std.testing.allocator.free(token);
    const event = try testAuthorizationEvent(
        std.testing.allocator,
        "Authorization",
        "Bearer",
        token,
    );
    defer std.testing.allocator.free(event);
    var fake: FakeIntake = .{};

    var missing_environment = std.process.Environ.Map.init(std.testing.allocator);
    defer missing_environment.deinit();
    const missing_response = handleInvocationForTest(
        std.testing.allocator,
        event,
        .{},
        .{},
        &missing_environment,
        &fake,
        1000,
    );
    defer std.testing.allocator.free(missing_response);
    try expectInternalServerError(missing_response);

    const key_marker = "invalid-public-key-marker";
    var invalid_environment = std.process.Environ.Map.init(std.testing.allocator);
    defer invalid_environment.deinit();
    try invalid_environment.put("PASETO_PUBLIC_KEY", key_marker);
    const invalid_response = handleInvocationForTest(
        std.testing.allocator,
        event,
        .{},
        .{},
        &invalid_environment,
        &fake,
        1000,
    );
    defer std.testing.allocator.free(invalid_response);
    try expectInternalServerError(invalid_response);
    try expectNotContains(invalid_response, key_marker);
    try expectNotContains(invalid_response, token);
    try std.testing.expectEqual(@as(u8, 0), fake.create_count);
}

test "internal failures return only the static sanitized response" {
    const event_marker = "malformed-event-marker";
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var fake: FakeIntake = .{};
    const malformed_response = handleInvocationForTest(
        std.testing.allocator,
        "{\"headers\":" ++ event_marker,
        .{},
        .{},
        &environment,
        &fake,
        1000,
    );
    defer std.testing.allocator.free(malformed_response);
    try expectInternalServerError(malformed_response);
    try expectNotContains(malformed_response, event_marker);

    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    const allocation_response = handleInvocationForTest(
        failing_allocator.allocator(),
        "{}",
        .{},
        .{},
        &environment,
        &fake,
        1000,
    );
    try std.testing.expectEqualStrings(
        internal_server_error_response,
        allocation_response,
    );
    try std.testing.expectEqual(@as(u8, 0), fake.create_count);
}

fn testAuthorizationEvent(
    allocator: std.mem.Allocator,
    header_name: []const u8,
    scheme: []const u8,
    token: []const u8,
) ![]u8 {
    return test_authorization_request_event(
        allocator,
        .GET,
        header_name,
        scheme,
        token,
        null,
    );
}

fn test_authorization_request_event(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    header_name: []const u8,
    scheme: []const u8,
    token: []const u8,
    body: ?[]const u8,
) ![]u8 {
    std.debug.assert(header_name.len > 0);
    std.debug.assert(scheme.len > 0);
    std.debug.assert(token.len > 0);

    var event: std.Io.Writer.Allocating = .init(allocator);
    errdefer event.deinit();
    try event.writer.writeAll("{\"version\":\"2.0\",\"routeKey\":\"$default\",");
    try event.writer.writeAll("\"headers\":{");
    try std.json.Stringify.encodeJsonString(header_name, .{}, &event.writer);
    try event.writer.writeByte(':');
    try event.writer.writeByte('"');
    try event.writer.writeAll(scheme);
    try event.writer.writeByte(' ');
    try event.writer.writeAll(token);
    try event.writer.writeByte('"');
    try event.writer.writeAll("},\"requestContext\":{\"http\":{\"method\":");
    try std.json.Stringify.encodeJsonString(@tagName(method), .{}, &event.writer);
    try event.writer.writeAll("}}");
    if (body) |value| {
        try event.writer.writeAll(",\"body\":");
        try std.json.Stringify.encodeJsonString(value, .{}, &event.writer);
    }
    try event.writer.writeByte('}');
    std.debug.assert(event.written().len > token.len);
    std.debug.assert(event.written().len > header_name.len);
    return event.toOwnedSlice();
}

fn expectUnauthorized(response: []const u8) !void {
    try std.testing.expectEqualStrings(
        "{\"statusCode\":401,\"headers\":{\"Content-Type\":\"" ++ content_type_text ++
            "\",\"WWW-Authenticate\":\"Bearer\"},\"body\":\"Unauthorized\\n\"}",
        response,
    );
}

fn expectBadRequest(response: []const u8) !void {
    try std.testing.expectEqualStrings(
        "{\"statusCode\":400,\"headers\":{\"Content-Type\":\"" ++ content_type_text ++
            "\"},\"body\":\"Bad Request\\n\"}",
        response,
    );
}

fn expectConflict(response: []const u8) !void {
    try std.testing.expectEqualStrings(
        "{\"statusCode\":409,\"headers\":{\"Content-Type\":\"" ++ content_type_text ++
            "\"},\"body\":\"Conflict\\n\"}",
        response,
    );
}

fn expectMethodNotAllowed(response: []const u8) !void {
    try std.testing.expectEqualStrings(
        "{\"statusCode\":405,\"headers\":{\"Content-Type\":\"" ++ content_type_text ++
            "\",\"Allow\":\"POST\"},\"body\":\"Method Not Allowed\\n\"}",
        response,
    );
}

fn expectInternalServerError(response: []const u8) !void {
    try std.testing.expectEqualStrings(internal_server_error_response, response);
}

fn expectServiceUnavailable(response: []const u8) !void {
    try std.testing.expectEqualStrings(
        "{\"statusCode\":503,\"headers\":{\"Content-Type\":\"" ++ content_type_text ++
            "\"},\"body\":\"Service Unavailable\\n\"}",
        response,
    );
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}
