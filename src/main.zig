const std = @import("std");
const lambda = @import("aws-lambda");

const environment_count_max = 512;
const redacted_value = "<redacted>";

pub fn main(init: std.process.Init) void {
    lambda.handle(init, handler, .{});
}

fn handler(ctx: lambda.Context, _: []const u8) ![]const u8 {
    const body = try handlerBody(
        ctx.arena,
        ctx.config,
        ctx.request,
        @field(ctx, "_").kv,
    );

    return lambda.url.encodeResponse(ctx.arena, .{
        .content_type = "text/plain; charset=utf-8",
        .body = .{ .textual = body },
    });
}

fn handlerBody(
    allocator: std.mem.Allocator,
    cfg: lambda.Context.ConfigMeta,
    req: lambda.Context.RequestMeta,
    env: *const std.process.Environ.Map,
) ![]const u8 {
    var count_buffer: [1024]u8 = undefined;
    var counter: std.Io.Writer.Discarding = .init(&count_buffer);
    try handlerBodyWrite(&counter.writer, cfg, req, env);

    const output_len = try writerCountToUsize(counter.fullCount());
    std.debug.assert(output_len > 0);

    const output = try allocator.alloc(u8, output_len);
    errdefer allocator.free(output);

    var writer: std.Io.Writer = .fixed(output);
    try handlerBodyWrite(&writer, cfg, req, env);
    std.debug.assert(writer.buffered().len == output.len);

    return output;
}

fn handlerBodyWrite(
    writer: *std.Io.Writer,
    cfg: lambda.Context.ConfigMeta,
    req: lambda.Context.RequestMeta,
    env: *const std.process.Environ.Map,
) !void {
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

    return false;
}

fn writerCountToUsize(count: u64) !usize {
    return std.math.cast(usize, count) orelse return error.BodyTooLarge;
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

    const body = try handlerBody(std.testing.allocator, .{
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

    const body = try handlerBody(allocator, .{
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

    const body = try environmentBody(std.testing.allocator, &env);
    defer std.testing.allocator.free(body);

    try expectContains(body, "Environment\n");
    try expectContains(body, "AWS_REGION=ca-central-1\n");
    try expectContains(body, "CUSTOM_VALUE=demo\n");
    try expectContains(body, "AWS_SECRET_ACCESS_KEY=<redacted>\n");
    try expectNotContains(body, "secret-value");
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
