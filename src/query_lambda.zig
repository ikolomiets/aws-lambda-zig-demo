const std = @import("std");
const lambda = @import("aws-lambda");
const lambda_auth = @import("lambda_auth");

const content_type_text = "text/plain; charset=utf-8";
const environment_count_max = 512;
const internal_server_error_body = "Internal Server Error\n";
const internal_server_error_response =
    "{\"statusCode\":500,\"headers\":{\"Content-Type\":\"" ++ content_type_text ++
    "\"},\"body\":\"Internal Server Error\\n\"}";
const method_not_allowed_body = "Method Not Allowed\n";
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
    config: lambda.Context.ConfigMeta,
    request_metadata: lambda.Context.RequestMeta,
    environment: *const std.process.Environ.Map,
    now: i64,
) []const u8 {
    const outcome = invocationOutcome(
        allocator,
        event,
        config,
        request_metadata,
        environment,
        now,
    );
    return encodeOutcome(allocator, outcome) catch internal_server_error_response;
}

const InvocationOutcome = union(enum) {
    success: []const u8,
    method_not_allowed,
    unauthorized,
    internal_server_error,
};

fn invocationOutcome(
    allocator: std.mem.Allocator,
    event: []const u8,
    config: lambda.Context.ConfigMeta,
    request_metadata: lambda.Context.RequestMeta,
    environment: *const std.process.Environ.Map,
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
    const body = get_handler_body(
        allocator,
        identity.subject,
        config,
        request_metadata,
        environment,
    ) catch return .internal_server_error;
    return .{ .success = body };
}

fn encodeOutcome(
    allocator: std.mem.Allocator,
    outcome: InvocationOutcome,
) ![]const u8 {
    return switch (outcome) {
        .success => |body| success: {
            defer allocator.free(body);
            break :success lambda.url.encodeResponse(allocator, .{
                .content_type = content_type_text,
                .body = .{ .textual = body },
            });
        },
        .method_not_allowed => lambda.url.encodeResponse(allocator, .{
            .content_type = content_type_text,
            .status_code = .method_not_allowed,
            .headers = &.{.{ .key = "Allow", .value = "GET" }},
            .body = .{ .textual = method_not_allowed_body },
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

fn get_handler_body(
    allocator: std.mem.Allocator,
    subject: []const u8,
    config: lambda.Context.ConfigMeta,
    request_metadata: lambda.Context.RequestMeta,
    environment: *const std.process.Environ.Map,
) ![]const u8 {
    std.debug.assert(subject.len > 0);
    std.debug.assert(subject.len <= lambda_auth.subject_size_max);

    var count_buffer: [1024]u8 = undefined;
    var counter: std.Io.Writer.Discarding = .init(&count_buffer);
    try get_handler_body_write(
        &counter.writer,
        subject,
        config,
        request_metadata,
        environment,
    );

    const output_len = try writerCountToUsize(counter.fullCount());
    std.debug.assert(output_len > 0);
    const output = try allocator.alloc(u8, output_len);
    errdefer allocator.free(output);

    var writer: std.Io.Writer = .fixed(output);
    try get_handler_body_write(
        &writer,
        subject,
        config,
        request_metadata,
        environment,
    );
    std.debug.assert(writer.buffered().len == output.len);
    return output;
}

fn get_handler_body_write(
    writer: *std.Io.Writer,
    subject: []const u8,
    config: lambda.Context.ConfigMeta,
    request_metadata: lambda.Context.RequestMeta,
    environment: *const std.process.Environ.Map,
) !void {
    std.debug.assert(subject.len > 0);
    std.debug.assert(subject.len <= lambda_auth.subject_size_max);

    try writer.print("Hello, {s}!\n\n", .{subject});
    try configMetadataBodyWrite(writer, config);
    try writer.writeByte('\n');
    try requestMetadataBodyWrite(writer, request_metadata);
    try writer.writeByte('\n');
    try environmentBodyWrite(writer, environment);
}

fn configMetadataBodyWrite(
    writer: *std.Io.Writer,
    config: lambda.Context.ConfigMeta,
) !void {
    std.debug.assert(config.func_size > 0);

    try writer.writeAll("ConfigMeta\n");
    try writer.print("func_name={s}\n", .{config.func_name});
    try writer.print("func_version={s}\n", .{config.func_version});
    try writer.print("func_size={d}\n", .{config.func_size});
    try writer.print("func_init={s}\n", .{@tagName(config.func_init)});
    try writer.print("func_handler={s}\n", .{config.func_handler});
    try writer.print("aws_region={s}\n", .{config.aws_region});
    try writer.writeAll("aws_access_id=<redacted>\n");
    try writer.writeAll("aws_access_secret=<redacted>\n");
    try writer.writeAll("aws_session_token=<redacted>\n");
    try writer.print("log_group={s}\n", .{config.log_group});
    try writer.print("log_stream={s}\n", .{config.log_stream});
}

fn requestMetadataBodyWrite(
    writer: *std.Io.Writer,
    request_metadata: lambda.Context.RequestMeta,
) !void {
    try writer.writeAll("RequestMeta\n");
    try writer.print("id={s}\n", .{request_metadata.id});
    try writer.print("xray_trace={s}\n", .{request_metadata.xray_trace});
    try writer.print("invoked_arn={s}\n", .{request_metadata.invoked_arn});
    try writer.print("deadline_ms={d}\n", .{request_metadata.deadline_ms});
    try writer.print("client_context={s}\n", .{request_metadata.client_context});
    try writer.print("cognito_identity={s}\n", .{request_metadata.cognito_identity});
}

fn environmentBodyWrite(
    writer: *std.Io.Writer,
    environment: *const std.process.Environ.Map,
) !void {
    const environment_count = environment.count();
    if (environment_count > environment_count_max) return error.EnvironmentTooLarge;
    std.debug.assert(environment_count <= environment_count_max);
    try writer.writeAll("Environment\n");

    var iterator = environment.iterator();
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

test "authenticated GET returns environment details for the token subject" {
    const token = try lambda_auth.testing.issue_token(std.testing.allocator, .{
        .seed_byte = 0x71,
        .now = 1000,
        .ttl_seconds = 60,
    });
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try lambda_auth.testing.put_public_key(&environment, 0x71);
    try environment.put("CUSTOM_VALUE", "query-demo");
    const event = try testAuthorizationEvent(std.testing.allocator, .GET, token, null);
    defer std.testing.allocator.free(event);

    const response = handleInvocation(
        std.testing.allocator,
        event,
        .{},
        .{},
        &environment,
        1000,
    );
    defer if (response.ptr != internal_server_error_response.ptr) {
        std.testing.allocator.free(response);
    };

    try expectContains(response, "Hello, lambda-test-user!");
    try expectContains(response, "CUSTOM_VALUE=query-demo");
}

test "query body includes metadata in order and redacts credentials" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("OPERATIONS_TABLE_NAME", "operations-table");
    try environment.put("OPERATIONS_QUEUE_URL", "https://sqs.example/operations");
    try environment.put("AWS_SECRET_ACCESS_KEY", "secret-value");
    try environment.put("PASETO_PRIVATE_KEY", "private-key-value");

    const body = try get_handler_body(std.testing.allocator, "example-user", .{
        .func_name = "query-function",
        .func_version = "$LATEST",
        .func_size = 128,
        .func_init = .on_demand,
        .func_handler = "bootstrap",
        .aws_region = "ca-central-1",
        .aws_access_id = "access-key-id",
        .aws_access_secret = "secret-key",
        .aws_session_token = "session-token",
        .log_group = "/aws/lambda/query-function",
        .log_stream = "2026/08/10/[$LATEST]abcdef",
    }, .{
        .id = "request-id",
        .xray_trace = "trace-id",
        .invoked_arn = "arn:aws:lambda:ca-central-1:<account-id>:function:query-function",
        .deadline_ms = 1_786_339_200_000,
        .client_context = "client-context",
        .cognito_identity = "cognito-identity",
    }, &environment);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.startsWith(
        u8,
        body,
        "Hello, example-user!\n\nConfigMeta\n",
    ));
    try expectBefore(body, "ConfigMeta\n", "\nRequestMeta\n");
    try expectBefore(body, "\nRequestMeta\n", "\nEnvironment\n");
    try expectContains(body, "func_name=query-function\n");
    try expectContains(body, "id=request-id\n");
    try expectContains(body, "OPERATIONS_TABLE_NAME=operations-table\n");
    try expectContains(body, "OPERATIONS_QUEUE_URL=https://sqs.example/operations\n");
    try expectContains(body, "AWS_SECRET_ACCESS_KEY=<redacted>\n");
    try expectContains(body, "PASETO_PRIVATE_KEY=<redacted>\n");
    try expectNotContains(body, "access-key-id");
    try expectNotContains(body, "secret-key");
    try expectNotContains(body, "session-token");
    try expectNotContains(body, "secret-value");
    try expectNotContains(body, "private-key-value");
}

test "query body allocates its final body once" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("CUSTOM_VALUE", "demo");
    var allocation_counter = AllocationCounter{
        .backing_allocator = std.testing.allocator,
    };
    const allocator = allocation_counter.allocator();

    const body = try get_handler_body(
        allocator,
        "example-user",
        .{},
        .{},
        &environment,
    );
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

test "query authenticates before routing and allows only GET" {
    const token = try lambda_auth.testing.issue_token(std.testing.allocator, .{
        .seed_byte = 0x72,
        .now = 1000,
        .ttl_seconds = 60,
    });
    defer std.testing.allocator.free(token);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try lambda_auth.testing.put_public_key(&environment, 0x72);

    const post_event = try testAuthorizationEvent(
        std.testing.allocator,
        .POST,
        token,
        "ignored",
    );
    defer std.testing.allocator.free(post_event);
    const post_response = handleInvocation(
        std.testing.allocator,
        post_event,
        .{},
        .{},
        &environment,
        1000,
    );
    defer std.testing.allocator.free(post_response);
    try std.testing.expectEqualStrings(
        "{\"statusCode\":405,\"headers\":{\"Content-Type\":\"" ++
            content_type_text ++
            "\",\"Allow\":\"GET\"},\"body\":\"Method Not Allowed\\n\"}",
        post_response,
    );

    const unauthenticated_response = handleInvocation(
        std.testing.allocator,
        "{\"requestContext\":{\"http\":{\"method\":\"POST\"}}}",
        .{},
        .{},
        &environment,
        1000,
    );
    defer std.testing.allocator.free(unauthenticated_response);
    try std.testing.expectEqualStrings(
        "{\"statusCode\":401,\"headers\":{\"Content-Type\":\"" ++
            content_type_text ++
            "\",\"WWW-Authenticate\":\"Bearer\"},\"body\":\"Unauthorized\\n\"}",
        unauthenticated_response,
    );
}

test "query failures return only sanitized static responses" {
    const event_marker = "malformed-query-event-marker";
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
    try std.testing.expectEqualStrings(internal_server_error_response, malformed_response);
    try expectNotContains(malformed_response, event_marker);

    const token = try lambda_auth.testing.issue_token(std.testing.allocator, .{
        .seed_byte = 0x73,
        .now = 1000,
        .ttl_seconds = 60,
    });
    defer std.testing.allocator.free(token);
    const event = try testAuthorizationEvent(std.testing.allocator, .GET, token, null);
    defer std.testing.allocator.free(event);
    const configuration_response = handleInvocation(
        std.testing.allocator,
        event,
        .{},
        .{},
        &environment,
        1000,
    );
    defer std.testing.allocator.free(configuration_response);
    try std.testing.expectEqualStrings(
        internal_server_error_response,
        configuration_response,
    );
    try expectNotContains(configuration_response, token);

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
    method: std.http.Method,
    token: []const u8,
    body: ?[]const u8,
) ![]u8 {
    var event: std.Io.Writer.Allocating = .init(allocator);
    errdefer event.deinit();
    try event.writer.print(
        "{{\"headers\":{{\"Authorization\":\"Bearer {s}\"}}," ++
            "\"requestContext\":{{\"http\":{{\"method\":\"{s}\"}}}}",
        .{ token, @tagName(method) },
    );
    if (body) |value| {
        try event.writer.writeAll(",\"body\":");
        try std.json.Stringify.encodeJsonString(value, .{}, &event.writer);
    }
    try event.writer.writeByte('}');
    return event.toOwnedSlice();
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
        return .{ .ptr = counter, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(
        context: *anyopaque,
        length: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const counter: *AllocationCounter = @ptrCast(@alignCast(context));
        const result = counter.backing_allocator.rawAlloc(
            length,
            alignment,
            return_address,
        );
        if (result != null) counter.allocations += 1;
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_length: usize,
        return_address: usize,
    ) bool {
        const counter: *AllocationCounter = @ptrCast(@alignCast(context));
        const result = counter.backing_allocator.rawResize(
            memory,
            alignment,
            new_length,
            return_address,
        );
        if (result) counter.resizes += 1;
        return result;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_length: usize,
        return_address: usize,
    ) ?[*]u8 {
        const counter: *AllocationCounter = @ptrCast(@alignCast(context));
        const result = counter.backing_allocator.rawRemap(
            memory,
            alignment,
            new_length,
            return_address,
        );
        if (result != null) counter.remaps += 1;
        return result;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const counter: *AllocationCounter = @ptrCast(@alignCast(context));
        counter.frees += 1;
        counter.backing_allocator.rawFree(memory, alignment, return_address);
    }
};
