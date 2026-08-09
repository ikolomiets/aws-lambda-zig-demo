const std = @import("std");
const aws = @import("aws");
const lambda = @import("aws-lambda");
const operation = @import("operation");
const operation_persistence = @import("operation_persistence");
const operation_queue = @import("operation_queue");
const paseto = @import("paseto");

const Allocator = std.mem.Allocator;

const authorization_header_count_max = 256;
const bad_request_body = "Bad Request\n";
const conflict_body = "Conflict\n";
const content_type_json = "application/json";
const content_type_text = "text/plain; charset=utf-8";
const environment_count_max = 512;
const internal_server_error_body = "Internal Server Error\n";
const internal_server_error_response =
    "{\"statusCode\":500,\"headers\":{\"Content-Type\":\"" ++ content_type_text ++
    "\"},\"body\":\"Internal Server Error\\n\"}";
const method_not_allowed_body = "Method Not Allowed\n";
const operation_message_size_max = 8 * 1024;
const redacted_value = "<redacted>";
const service_unavailable_body = "Service Unavailable\n";
const unauthorized_body = "Unauthorized\n";

comptime {
    std.debug.assert(operation_message_size_max > operation.body_size_max);
    std.debug.assert(paseto.subject_size_max == operation.tenant_size_max);
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
        ctx.config,
        ctx.request,
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

    fn read(
        resources: *RuntimeResources,
        arena: Allocator,
        id: u128,
    ) !operation.Operation {
        return resources.persistence.read(arena, id);
    }

    fn update(
        resources: *RuntimeResources,
        arena: Allocator,
        snapshot: *const operation.Operation,
        replacement: *const operation.Operation,
    ) !operation.Operation {
        return resources.persistence.update(arena, snapshot, replacement);
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
    read_fn: *const fn (
        *anyopaque,
        Allocator,
        u128,
    ) anyerror!operation.Operation,
    update_fn: *const fn (
        *anyopaque,
        Allocator,
        *const operation.Operation,
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

            fn read(
                context: *anyopaque,
                allocator: Allocator,
                id: u128,
            ) anyerror!operation.Operation {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.read(allocator, id);
            }

            fn update(
                context: *anyopaque,
                allocator: Allocator,
                snapshot: *const operation.Operation,
                replacement: *const operation.Operation,
            ) anyerror!operation.Operation {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.update(allocator, snapshot, replacement);
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
            .read_fn = Adapter.read,
            .update_fn = Adapter.update,
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

    fn read(
        intake: IntakeAdapter,
        allocator: Allocator,
        id: u128,
    ) !operation.Operation {
        return intake.read_fn(intake.context, allocator, id);
    }

    fn update(
        intake: IntakeAdapter,
        allocator: Allocator,
        snapshot: *const operation.Operation,
        replacement: *const operation.Operation,
    ) !operation.Operation {
        return intake.update_fn(
            intake.context,
            allocator,
            snapshot,
            replacement,
        );
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
    cfg: lambda.Context.ConfigMeta,
    req: lambda.Context.RequestMeta,
    env: *const std.process.Environ.Map,
    intake: IntakeAdapter,
    now: i64,
) []const u8 {
    const outcome = invocationOutcome(allocator, event, cfg, req, env, intake, now);
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
    cfg: lambda.Context.ConfigMeta,
    req: lambda.Context.RequestMeta,
    env: *const std.process.Environ.Map,
    intake: IntakeAdapter,
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

    const method = request.request_context.http.method orelse {
        return .method_not_allowed;
    };
    return switch (method) {
        .GET => get_invocation_outcome(allocator, claims.sub, cfg, req, env),
        .POST => post_invocation_outcome(allocator, claims.sub, &request, intake, now),
        else => .method_not_allowed,
    };
}

fn get_invocation_outcome(
    allocator: std.mem.Allocator,
    subject: []const u8,
    cfg: lambda.Context.ConfigMeta,
    req: lambda.Context.RequestMeta,
    env: *const std.process.Environ.Map,
) InvocationOutcome {
    const body = get_handler_body(allocator, subject, cfg, req, env) catch {
        return .internal_server_error;
    };
    return .{ .success = .{
        .body = body,
        .content_type = content_type_text,
    } };
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

    var submitted = created;
    submitted.body = parsed.body;
    submitted.state = .submitted;
    submitted.last_updated = now;
    submitted.expires_at = operation.expires_at_from_last_updated(now) catch {
        return .internal_server_error;
    };
    submitted.result = null;
    const message = operation_message_body(arena, &submitted) catch {
        return .internal_server_error;
    };
    intake.send(arena, message) catch |err| {
        if (err == error.OutOfMemory) return .internal_server_error;
        return .service_unavailable;
    };

    var replacement = submitted;
    replacement.body = null;
    const updated = intake.update(arena, &created, &replacement) catch |err| {
        if (err != error.OperationConflict) return .internal_server_error;
        return reconcile_update_conflict(allocator, arena, intake, &created);
    };
    return operation_success_outcome(allocator, &updated);
}

fn reconcile_update_conflict(
    allocator: Allocator,
    arena: Allocator,
    intake: IntakeAdapter,
    submitted_snapshot: *const operation.Operation,
) InvocationOutcome {
    const current = intake.read(arena, submitted_snapshot.id) catch {
        return .internal_server_error;
    };
    if (!operation_identity_matches(&current, submitted_snapshot)) return .conflict;
    if (current.state.? == .new) return .conflict;
    return operation_success_outcome(allocator, &current);
}

fn operation_identity_matches(
    left: *const operation.Operation,
    right: *const operation.Operation,
) bool {
    if (left.id != right.id) return false;
    if (!std.mem.eql(u8, left.tenant, right.tenant)) return false;
    if (!std.mem.eql(u8, left.name, right.name)) return false;
    if (!std.mem.eql(u8, &left.hash.?, &right.hash.?)) return false;
    return true;
}

fn operation_message_body(
    allocator: Allocator,
    submitted: *const operation.Operation,
) ![]const u8 {
    std.debug.assert(submitted.body != null);
    std.debug.assert(submitted.state == .submitted);

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try operation.writeOutputJSON(&output.writer, submitted);
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
                .{ .key = "Allow", .value = "GET, POST" },
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

fn get_handler_body(
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
    try get_handler_body_write(&counter.writer, subject, cfg, req, env);

    const output_len = try writerCountToUsize(counter.fullCount());
    std.debug.assert(output_len > 0);

    const output = try allocator.alloc(u8, output_len);
    errdefer allocator.free(output);

    var writer: std.Io.Writer = .fixed(output);
    try get_handler_body_write(&writer, subject, cfg, req, env);
    std.debug.assert(writer.buffered().len == output.len);

    return output;
}

fn get_handler_body_write(
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

const FakeIntake = struct {
    response: ?operation.Operation = null,
    read_response: ?operation.Operation = null,
    update_response: ?operation.Operation = null,
    create_error: ?anyerror = null,
    read_error: ?anyerror = null,
    update_error: ?anyerror = null,
    send_error: ?anyerror = null,
    create_count: u8 = 0,
    read_count: u8 = 0,
    update_count: u8 = 0,
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
    last_read_id: u128 = 0,
    last_snapshot_state: ?operation.State = null,
    last_update_state: ?operation.State = null,
    last_update_time: ?operation.UnixSeconds = null,
    last_update_expires_at: ?operation.UnixSeconds = null,
    last_update_body_present: bool = false,

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

    fn read(
        fake: *FakeIntake,
        _: Allocator,
        id: u128,
    ) !operation.Operation {
        std.debug.assert(fake.read_count < 32);
        fake.read_count += 1;
        fake.last_read_id = id;
        if (fake.read_error) |err| return err;
        return fake.read_response orelse error.OperationNotFound;
    }

    fn update(
        fake: *FakeIntake,
        _: Allocator,
        snapshot: *const operation.Operation,
        replacement: *const operation.Operation,
    ) !operation.Operation {
        std.debug.assert(fake.update_count < 32);
        fake.update_count += 1;
        fake.last_snapshot_state = snapshot.state;
        fake.last_update_state = replacement.state;
        fake.last_update_time = replacement.last_updated;
        fake.last_update_expires_at = replacement.expires_at;
        fake.last_update_body_present = replacement.body != null;
        if (fake.update_error) |err| return err;
        if (fake.update_response) |response| return response;
        return replacement.*;
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
    return handleInvocation(
        allocator,
        event,
        cfg,
        req,
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

    const body = try get_handler_body(std.testing.allocator, "example-user", .{
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

    const body = try get_handler_body(allocator, "example-user", .{
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
    var fake: FakeIntake = .{};

    const expected_body = try get_handler_body(
        std.testing.allocator,
        "lambda-test-user",
        .{},
        .{},
        &environment,
    );
    defer std.testing.allocator.free(expected_body);
    const expected_response = try lambda.url.encodeResponse(std.testing.allocator, .{
        .content_type = content_type_text,
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
            try std.testing.expectEqualStrings(expected_response, response);
            try expectContains(response, "Hello, lambda-test-user!");
        }
    }
    try std.testing.expectEqual(@as(u8, 0), fake.create_count);
}

test "authenticated POST submits a new operation and returns it without its body" {
    var key_pair = testKeyPair(0x42);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    const token = try testToken(&key_pair, 1_700_000_000, 60);
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putTestPublicKey(&environment, key_pair.public_key);

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
        "\\\"state\\\":\\\"SUBMITTED\\\"," ++
        "\\\"last_updated\\\":1700000000," ++
        "\\\"expires_at\\\":1700086400," ++
        "\\\"hash\\\":\\\"471493bf210a9c6922a2f0870d05a655ba9f859bffecd57972ebfe39863b672c\\\"}\"}";
    const expected_message =
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
        "\"tenant\":\"lambda-test-user\",\"name\":\"echo\"," ++
        "\"body\":{\"message\":\"hello\",\"count\":2}," ++
        "\"state\":\"SUBMITTED\",\"last_updated\":1700000000," ++
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
        try std.testing.expectEqual(@as(u8, 1), fake.update_count);
        try std.testing.expectEqual(operation.State.new, fake.last_snapshot_state.?);
        try std.testing.expectEqual(operation.State.submitted, fake.last_update_state.?);
        try std.testing.expectEqual(@as(i64, 1_700_000_000), fake.last_update_time.?);
        try std.testing.expectEqual(@as(i64, 1_700_086_400), fake.last_update_expires_at.?);
        try std.testing.expect(!fake.last_update_body_present);
        var expected_hash: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(
            &expected_hash,
            "471493bf210a9c6922a2f0870d05a655ba9f859bffecd57972ebfe39863b672c",
        );
        try std.testing.expectEqualSlices(u8, &expected_hash, &fake.last_hash.?);
    }
}

test "POST queues every JSON body variant as exact full Operation JSON" {
    var key_pair = testKeyPair(0x51);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    const token = try testToken(&key_pair, 1_700_000_000, 60);
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putTestPublicKey(&environment, key_pair.public_key);

    const bodies = [_][]const u8{ "null", "false", "42", "\"text\"", "[1]", "{\"a\":1}" };
    const messages = [_][]const u8{
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"lambda-test-user\",\"name\":\"variants\",\"body\":null," ++
            "\"state\":\"SUBMITTED\",\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400," ++
            "\"hash\":\"fd177e1082fafe25e8ae2bc301281fc4f4a5a0776ab241d35cf9ed91a46db3b3\"}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"lambda-test-user\",\"name\":\"variants\",\"body\":false," ++
            "\"state\":\"SUBMITTED\",\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400," ++
            "\"hash\":\"6e18221b306b6bfd8753e910d58beb8cf007da71923dc7b52011f107fbc51d1c\"}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"lambda-test-user\",\"name\":\"variants\",\"body\":42," ++
            "\"state\":\"SUBMITTED\",\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400," ++
            "\"hash\":\"d5ccd414185af1692c3678f3cde5756d3bb12a7cbfd0f39f797610b3fa7bd235\"}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"lambda-test-user\",\"name\":\"variants\",\"body\":\"text\"," ++
            "\"state\":\"SUBMITTED\",\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400," ++
            "\"hash\":\"576bfabb751a1c5df078d4d24cd5bd66c00cec5b765e898b7eb3743693a0c2bb\"}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"lambda-test-user\",\"name\":\"variants\",\"body\":[1]," ++
            "\"state\":\"SUBMITTED\",\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400," ++
            "\"hash\":\"9a2a3875c2b05917ae674a0d5b6f1bfc71d6dec7b3cb71059f9c21f60709cbc9\"}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"lambda-test-user\",\"name\":\"variants\",\"body\":{\"a\":1}," ++
            "\"state\":\"SUBMITTED\",\"last_updated\":1700000000," ++
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
        try expectContains(response, "\\\"state\\\":\\\"SUBMITTED\\\"");
        try expectNotContains(response, "\\\"body\\\":");
        try std.testing.expectEqual(@as(u8, 1), fake.send_count);
        try std.testing.expectEqual(@as(u8, 1), fake.update_count);
        try std.testing.expect(!fake.last_update_body_present);
    }
}

test "POST derives tenant and hash from distinct bounded verified subjects" {
    var key_pair = testKeyPair(0x49);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putTestPublicKey(&environment, key_pair.public_key);
    const subjects = [_][]const u8{
        "a" ** paseto.subject_size_max,
        "tenant-b",
    };
    const input =
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
        "\"name\":\"echo\",\"body\":null}";
    var hashes: [subjects.len][32]u8 = undefined;

    for (subjects, 0..) |subject, index| {
        const token = try testTokenForSubject(&key_pair, subject, 1000, 60);
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

test "matching NEW POST retries submission with the invocation timestamp" {
    var key_pair = testKeyPair(0x52);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    const token = try testToken(&key_pair, 1_700_000_500, 60);
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putTestPublicKey(&environment, key_pair.public_key);
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

    try expectContains(response, "\\\"state\\\":\\\"SUBMITTED\\\"");
    try expectContains(response, "\\\"last_updated\\\":1700000500");
    try expectContains(response, "\\\"expires_at\\\":1700086900");
    try expectContains(fake.lastMessage(), "\"body\":{\"message\":\"hello\",\"count\":2}");
    try expectContains(fake.lastMessage(), "\"last_updated\":1700000500");
    try std.testing.expectEqual(operation.State.new, fake.last_snapshot_state.?);
    try std.testing.expectEqual(operation.State.submitted, fake.last_update_state.?);
    try std.testing.expectEqual(@as(u8, 1), fake.send_count);
    try std.testing.expectEqual(@as(u8, 1), fake.update_count);
}

test "matching POST retry returns the latest stored persistent view" {
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    var key_pair = testKeyPair(0x45);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    const token = try testToken(&key_pair, 1_700_000_000, 60);
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putTestPublicKey(&environment, key_pair.public_key);

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

test "matching POST in every later state returns without another submission" {
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    var key_pair = testKeyPair(0x53);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    const token = try testToken(&key_pair, 1_700_000_000, 60);
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putTestPublicKey(&environment, key_pair.public_key);
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
    const states = [_]operation.State{ .submitted, .running, .succeeded, .failed };

    for (states) |state| {
        const result = if (operation.stateIsTerminal(state))
            try operation.parseResultJSON(result_arena.allocator(), "{\"done\":true}")
        else
            null;
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
        try std.testing.expectEqual(@as(u8, 0), fake.update_count);
        try std.testing.expectEqual(@as(u8, 0), fake.read_count);
    }
}

test "POST conflict returns only the static conflict response" {
    var key_pair = testKeyPair(0x46);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    const token = try testToken(&key_pair, 1000, 60);
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putTestPublicKey(&environment, key_pair.public_key);
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
    var key_pair = testKeyPair(0x47);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    const token = try testToken(&key_pair, 1000, 60);
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putTestPublicKey(&environment, key_pair.public_key);
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

test "SQS failure leaves NEW unchanged and a matching POST can retry submission" {
    var key_pair = testKeyPair(0x50);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    const token = try testToken(&key_pair, 1000, 60);
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putTestPublicKey(&environment, key_pair.public_key);
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
    try std.testing.expectEqual(@as(u8, 0), fake.update_count);

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
    try expectContains(retried, "SUBMITTED");
    try std.testing.expectEqual(@as(u8, 2), fake.create_count);
    try std.testing.expectEqual(@as(u8, 2), fake.send_count);
    try std.testing.expectEqual(@as(u8, 1), fake.update_count);
}

test "persistence update failure after send returns only the static internal error" {
    var key_pair = testKeyPair(0x54);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    const token = try testToken(&key_pair, 1000, 60);
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putTestPublicKey(&environment, key_pair.public_key);
    const event = try test_authorization_request_event(
        std.testing.allocator,
        .POST,
        "Authorization",
        "Bearer",
        token,
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"name\":\"update-failure-marker\",\"body\":{\"secret\":\"marker\"}}",
    );
    defer std.testing.allocator.free(event);
    var fake = FakeIntake{ .update_error = error.AWSFailure };

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
    try expectNotContains(response, "update-failure-marker");
    try expectNotContains(response, "AWSFailure");
    try std.testing.expectEqual(@as(u8, 1), fake.send_count);
    try std.testing.expectEqual(@as(u8, 1), fake.update_count);
    try std.testing.expectEqual(@as(u8, 0), fake.read_count);
    try expectContains(fake.lastMessage(), "\"state\":\"SUBMITTED\"");
}

test "concurrent submitted update conflict reconciles with a consistent read" {
    var key_pair = testKeyPair(0x55);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    const token = try testToken(&key_pair, 1000, 60);
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putTestPublicKey(&environment, key_pair.public_key);
    const event = try test_authorization_request_event(
        std.testing.allocator,
        .POST,
        "Authorization",
        "Bearer",
        token,
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"name\":\"echo\",\"body\":{\"message\":\"hello\",\"count\":2}}",
    );
    defer std.testing.allocator.free(event);
    var expected_hash: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_hash,
        "471493bf210a9c6922a2f0870d05a655ba9f859bffecd57972ebfe39863b672c",
    );
    var fake = FakeIntake{
        .update_error = error.OperationConflict,
        .read_response = .{
            .id = operation.uuidFromString(
                "00112233-4455-6677-8899-aabbccddeeff",
            ) catch unreachable,
            .tenant = "lambda-test-user",
            .name = "echo",
            .state = .submitted,
            .last_updated = 1001,
            .expires_at = 87_401,
            .hash = expected_hash,
        },
    };

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

    try expectContains(response, "\\\"state\\\":\\\"SUBMITTED\\\"");
    try expectContains(response, "\\\"last_updated\\\":1001");
    try expectContains(response, "\\\"expires_at\\\":87401");
    try std.testing.expectEqual(@as(u8, 1), fake.send_count);
    try std.testing.expectEqual(@as(u8, 1), fake.update_count);
    try std.testing.expectEqual(@as(u8, 1), fake.read_count);
    try std.testing.expectEqual(fake.last_id, fake.last_read_id);
}

test "unreconciled conditional update conflicts remain sanitized" {
    var key_pair = testKeyPair(0x56);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    const token = try testToken(&key_pair, 1000, 60);
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putTestPublicKey(&environment, key_pair.public_key);
    const event = try test_authorization_request_event(
        std.testing.allocator,
        .POST,
        "Authorization",
        "Bearer",
        token,
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"name\":\"reconcile-marker\",\"body\":true}",
    );
    defer std.testing.allocator.free(event);
    var fake = FakeIntake{
        .update_error = error.OperationConflict,
        .read_response = .{
            .id = operation.uuidFromString(
                "00112233-4455-6677-8899-aabbccddeeff",
            ) catch unreachable,
            .tenant = "lambda-test-user",
            .name = "reconcile-marker",
            .state = .new,
            .last_updated = 1001,
            .expires_at = 87_401,
            .hash = [_]u8{0xAB} ** 32,
        },
    };

    const conflict = handleInvocationForTest(
        std.testing.allocator,
        event,
        .{},
        .{},
        &environment,
        &fake,
        1000,
    );
    defer std.testing.allocator.free(conflict);
    try expectConflict(conflict);
    try expectNotContains(conflict, "reconcile-marker");

    fake.read_response.?.hash = fake.last_hash;
    const still_new = handleInvocationForTest(
        std.testing.allocator,
        event,
        .{},
        .{},
        &environment,
        &fake,
        1000,
    );
    defer std.testing.allocator.free(still_new);
    try expectConflict(still_new);
    try expectNotContains(still_new, "reconcile-marker");

    fake.read_error = error.AWSFailure;
    const failed_read = handleInvocationForTest(
        std.testing.allocator,
        event,
        .{},
        .{},
        &environment,
        &fake,
        1000,
    );
    defer std.testing.allocator.free(failed_read);
    try expectInternalServerError(failed_read);
    try expectNotContains(failed_read, "AWSFailure");
}

test "warm invocations reuse one adapter without retaining request data" {
    var key_pair = testKeyPair(0x48);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    const token = try testToken(&key_pair, 1000, 60);
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putTestPublicKey(&environment, key_pair.public_key);
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
            .{},
            .{},
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
    var key_pair = testKeyPair(0x43);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    const token = try testToken(&key_pair, 1000, 60);
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putTestPublicKey(&environment, key_pair.public_key);
    var fake: FakeIntake = .{};

    const invalid_inputs = [_]?[]const u8{
        null,
        "{invalid-json-marker",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\",\"name\":\"echo\"}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"spoofed\",\"name\":\"echo\",\"body\":null}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"name\":\"echo\",\"body\":null,\"state\":\"SUBMITTED\"}",
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
    }
    try std.testing.expectEqual(@as(u8, 0), fake.create_count);
}

test "authentication precedes method routing" {
    var key_pair = testKeyPair(0x44);
    defer paseto.wipeSecretKey(&key_pair.secret_key);
    const token = try testToken(&key_pair, 1000, 60);
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try putTestPublicKey(&environment, key_pair.public_key);
    var fake: FakeIntake = .{};

    const unsupported_event = try test_authorization_request_event(
        std.testing.allocator,
        .PUT,
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
    return testTokenForSubject(key_pair, "lambda-test-user", now, ttl_seconds);
}

fn testTokenForSubject(
    key_pair: *const paseto.Ed25519.KeyPair,
    subject: []const u8,
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
            .subject = subject,
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
            "\",\"Allow\":\"GET, POST\"},\"body\":\"Method Not Allowed\\n\"}",
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
