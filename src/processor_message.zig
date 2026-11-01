const std = @import("std");
const operation = @import("operation");
const Allocator = std.mem.Allocator;

pub const body_size_max = 96 * 1024;
pub const context_size_max = 4096;
pub const queue_url_size_max = 2048;
pub const encoded_size_max = 115328;
comptime {
    std.debug.assert(body_size_max == 98304);
    std.debug.assert(context_size_max == operation.body_size_max);
    std.debug.assert(queue_url_size_max > 0);
    std.debug.assert(encoded_size_max >= body_size_max + context_size_max +
        6 * operation.tenant_size_max + 6 * queue_url_size_max + 256);
    std.debug.assert(encoded_size_max < 1024 * 1024);
}

pub const Message = struct {
    operation_id: u128,
    tenant: []const u8,
    body: std.json.Value,
    context: std.json.Value,
    result_queue: ?[]const u8 = null,
};

pub const FrameOptions = struct {
    operation_id: u128,
    tenant: []const u8,
    context: std.json.Value,
    result_queue: ?[]const u8 = null,
};

/// Decodes a bounded envelope into values owned by the caller's arena.
pub fn decode(arena: Allocator, input: []const u8) !Message {
    if (input.len > encoded_size_max) return error.MessageTooLarge;
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, input, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .max_value_len = encoded_size_max,
    });
    if (value != .object) return error.InvalidMessage;
    for (value.object.keys()) |key| {
        if (!std.mem.eql(u8, key, "operation_id") and
            !std.mem.eql(u8, key, "tenant") and
            !std.mem.eql(u8, key, "body") and
            !std.mem.eql(u8, key, "context") and
            !std.mem.eql(u8, key, "result_queue")) return error.UnknownField;
    }
    const id = value.object.get("operation_id") orelse return error.MissingField;
    if (id != .string) return error.InvalidUUID;
    const uuid = try operation.uuidFromString(id.string);
    var text: [operation.uuid_string_size]u8 = undefined;
    if (!std.mem.eql(u8, id.string, operation.uuidToString(uuid, &text))) {
        return error.InvalidUUID;
    }
    const tenant = value.object.get("tenant") orelse return error.MissingField;
    if (tenant != .string) return error.InvalidTenant;
    try operation.validateTenant(tenant.string);
    const body = value.object.get("body") orelse return error.MissingField;
    _ = try body_size(&body);
    const context = value.object.get("context") orelse return error.MissingField;
    try validate_context(&context);
    var route: ?[]const u8 = null;
    if (value.object.get("result_queue")) |queue| {
        if (queue != .string) return error.InvalidResultQueue;
        try validate_route(queue.string);
        route = queue.string;
    }
    return .{
        .operation_id = uuid,
        .tenant = tenant.string,
        .body = body,
        .context = context,
        .result_queue = route,
    };
}

fn body_size(body: *const std.json.Value) !usize {
    var buffer: [256]u8 = undefined;
    var counter = std.Io.Writer.Discarding.init(&buffer);
    try std.json.Stringify.value(body.*, .{}, &counter.writer);
    const size = counter.fullCount();
    if (size > body_size_max) return error.BodyTooLarge;
    return @intCast(size);
}

fn validate_route(route: []const u8) !void {
    if (route.len == 0 or route.len > queue_url_size_max) return error.InvalidResultQueue;
    if (!std.unicode.utf8ValidateSlice(route)) return error.InvalidResultQueue;
    for (route) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidResultQueue;
}

fn validate_context(context: *const std.json.Value) !void {
    var buffer: [256]u8 = undefined;
    var counter = std.Io.Writer.Discarding.init(&buffer);
    try std.json.Stringify.value(context.*, .{}, &counter.writer);
    if (counter.fullCount() > context_size_max) return error.ContextTooLarge;
}

pub fn encode(arena: Allocator, message: *const Message) ![]const u8 {
    _ = try body_size(&message.body);
    try operation.validateTenant(message.tenant);
    try validate_context(&message.context);
    var output = std.Io.Writer.Allocating.init(arena);
    errdefer output.deinit();
    try write_header(&output.writer, &.{
        .operation_id = message.operation_id,
        .tenant = message.tenant,
        .context = message.context,
    });
    try std.json.Stringify.value(message.body, .{}, &output.writer);
    try write_route(&output.writer, message.result_queue);
    try output.writer.writeByte('}');
    std.debug.assert(output.written().len <= encoded_size_max);
    return output.toOwnedSlice();
}

/// Frames trusted compact JSON from a processor without allocating another Value tree.
pub fn frame(buffer: []u8, body: []const u8, options: *const FrameOptions) ![]const u8 {
    if (body.len > body_size_max) return error.BodyTooLarge;
    std.debug.assert(body.len > 0);
    try operation.validateTenant(options.tenant);
    try validate_context(&options.context);
    var writer = std.Io.Writer.fixed(buffer[0..@min(buffer.len, encoded_size_max)]);
    try write_header(&writer, options);
    try writer.writeAll(body);
    try write_route(&writer, options.result_queue);
    try writer.writeByte('}');
    std.debug.assert(writer.buffered().len <= encoded_size_max);
    return writer.buffered();
}

fn write_header(writer: *std.Io.Writer, options: *const FrameOptions) !void {
    var uuid: [operation.uuid_string_size]u8 = undefined;
    try writer.print("{{\"operation_id\":\"{s}\",\"tenant\":", .{
        operation.uuidToString(options.operation_id, &uuid),
    });
    try std.json.Stringify.value(options.tenant, .{}, writer);
    try writer.writeAll(",\"context\":");
    try std.json.Stringify.value(options.context, .{}, writer);
    try writer.writeAll(",\"body\":");
}

fn write_route(writer: *std.Io.Writer, route: ?[]const u8) !void {
    if (route) |queue| {
        try validate_route(queue);
        try writer.writeAll(",\"result_queue\":");
        try std.json.Stringify.value(queue, .{}, writer);
    }
}

test "Processor Messages require trusted tenant and explicit Context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const prefix = "{\"operation_id\":\"00000000-0000-0000-0000-000000000001\",\"body\":true";
    try std.testing.expectError(error.MissingField, decode(arena.allocator(), prefix ++ "}"));
    try std.testing.expectError(
        error.MissingField,
        decode(arena.allocator(), prefix ++ ",\"tenant\":\"tenant-a\"}"),
    );
    _ = try decode(arena.allocator(), prefix ++ ",\"tenant\":\"tenant-a\",\"context\":null}");
}

test "internal bodies accept 96 KiB including above intake limit and reject larger bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const text = try allocator.alloc(u8, body_size_max - 2);
    @memset(text, 'x');
    const encoded = try encode(allocator, &.{ .operation_id = 1, .tenant = "tenant-a", .context = .null, .body = .{ .string = text } });
    const decoded = try decode(allocator, encoded);
    try std.testing.expectEqual(@as(usize, body_size_max - 2), decoded.body.string.len);
    try std.testing.expect(decoded.result_queue == null);
    const too_large = try allocator.alloc(u8, body_size_max - 1);
    @memset(too_large, 'x');
    try std.testing.expectError(error.BodyTooLarge, encode(allocator, &.{ .operation_id = 1, .tenant = "tenant-a", .context = .null, .body = .{ .string = too_large } }));
    const oversized = try std.fmt.allocPrint(allocator, "{{\"operation_id\":\"00000000-0000-0000-0000-000000000001\",\"tenant\":\"tenant-a\",\"context\":null,\"body\":\"{s}\"}}", .{too_large});
    try std.testing.expectError(error.BodyTooLarge, decode(allocator, oversized));
}

test "messages reject ambiguous IDs duplicate keys invalid routes and legacy envelopes" {
    const cases = [_][]const u8{
        "{\"operation_id\":\"00000000-0000-0000-0000-000000000001\",\"tenant\":\"tenant-a\",\"context\":null,\"body\":{},\"body\":true}",
        "{\"operation_id\":\"00000000-0000-0000-0000-000000000001\",\"tenant\":\"tenant-a\",\"context\":null,\"body\":{\"a\":1,\"\\u0061\":2}}",
        "{\"operation_id\":\"00112233-4455-6677-8899-AABBCCDDEEFF\",\"tenant\":\"tenant-a\",\"context\":null,\"body\":{}}",
        "{\"operation_id\":\"00000000-0000-0000-0000-000000000001\",\"tenant\":\"tenant-a\",\"context\":null,\"body\":{},\"result_queue\":null}",
        "{\"operation_id\":\"00000000-0000-0000-0000-000000000001\",\"tenant\":\"tenant-a\",\"context\":null,\"body\":{},\"result_queue\":\"\"}",
        "{\"operation_id\":\"00000000-0000-0000-0000-000000000001\",\"tenant\":\"tenant-a\",\"context\":null,\"body\":{},\"name\":\"private\"}",
        "{\"results\":[{\"operation_id\":\"00000000-0000-0000-0000-000000000001\",\"result\":true}]}",
    };
    for (cases) |input| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        if (decode(arena.allocator(), input)) |_| return error.InvalidMessageAccepted else |err| {
            try std.testing.expect(err != error.OutOfMemory);
        }
    }
}

test "message round trips an internal route without lifecycle metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = "{\"operation_id\":\"00112233-4455-6677-8899-aabbccddeeff\",\"tenant\":\"tenant-a\",\"context\":null,\"body\":{\"x\":1},\"result_queue\":\"https://sqs.example.invalid/next\"}";
    const message = try decode(arena.allocator(), input);
    try std.testing.expectEqualStrings("https://sqs.example.invalid/next", message.result_queue.?);
    try std.testing.expectEqualStrings(input, try encode(arena.allocator(), &message));
}

// The decoded string uses both six-byte JSON escapes and literal bytes. Expected
// compact sizes are specified independently of the serializer under test.
fn test_escaped_text(allocator: Allocator, compact_size: usize) ![]const u8 {
    std.debug.assert(compact_size >= 2);
    const escaped_count = (compact_size - 2) / 6;
    const literal_count = (compact_size - 2) % 6;
    const text = try allocator.alloc(u8, escaped_count + literal_count);
    @memset(text[0..escaped_count], 0);
    @memset(text[escaped_count..], 'x');
    return text;
}

test "opaque Context values round trip through encoding and allocation-free framing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const buffer = try allocator.alloc(u8, encoded_size_max);
    for ([_][]const u8{ "null", "true", "42", "1.5", "\"é\\n\\\"\"", "[false,null]", "{\"seat\":\"a\"}" }) |json| {
        const context = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});
        const message: Message = .{
            .operation_id = std.math.maxInt(u128),
            .tenant = "é\"\\\n",
            .body = .{ .bool = true },
            .context = context,
            .result_queue = "https://sqs.example.invalid/\"\\é",
        };
        const encoded = try encode(allocator, &message);
        const framed = try frame(buffer, "true", &.{
            .operation_id = message.operation_id,
            .tenant = message.tenant,
            .context = message.context,
            .result_queue = message.result_queue,
        });
        try std.testing.expectEqualStrings(encoded, framed);
        const decoded = try decode(allocator, framed);
        try std.testing.expectEqualStrings(message.tenant, decoded.tenant);
        try std.testing.expectEqualStrings(message.result_queue.?, decoded.result_queue.?);
        try std.testing.expectEqualStrings(
            try std.json.Stringify.valueAlloc(allocator, context, .{}),
            try std.json.Stringify.valueAlloc(allocator, decoded.context, .{}),
        );
        try std.testing.expectError(
            error.WriteFailed,
            frame(buffer[0 .. framed.len - 1], "true", &.{
                .operation_id = message.operation_id,
                .tenant = message.tenant,
                .context = message.context,
                .result_queue = message.result_queue,
            }),
        );
    }
}

test "Context admission counts compact escaped JSON at exactly 4096 bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const buffer = try allocator.alloc(u8, encoded_size_max);
    for ([_]usize{ 4096, 4097 }) |size| {
        const context: std.json.Value = .{ .string = try test_escaped_text(allocator, size) };
        try std.testing.expectEqual(
            size,
            (try std.json.Stringify.valueAlloc(allocator, context, .{})).len,
        );
        const raw = try std.json.Stringify.valueAlloc(allocator, .{
            .operation_id = "00000000-0000-0000-0000-000000000001",
            .tenant = "tenant-a",
            .body = true,
            .context = context,
        }, .{});
        const message: Message = .{
            .operation_id = 1,
            .tenant = "tenant-a",
            .body = .{ .bool = true },
            .context = context,
        };
        const options: FrameOptions = .{
            .operation_id = 1,
            .tenant = "tenant-a",
            .context = context,
        };
        if (size == 4096) {
            _ = try decode(allocator, raw);
            try std.testing.expectEqualStrings(
                try encode(allocator, &message),
                try frame(buffer, "true", &options),
            );
        } else {
            try std.testing.expectError(error.ContextTooLarge, decode(allocator, raw));
            try std.testing.expectError(error.ContextTooLarge, encode(allocator, &message));
            try std.testing.expectError(error.ContextTooLarge, frame(buffer, "true", &options));
        }
    }
}

test "trusted tenant and route enforce decoded UTF-8 byte bounds on every codec entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const buffer = try allocator.alloc(u8, encoded_size_max);
    const cases = [_]struct { tenant: []const u8, route: ?[]const u8, failure: ?anyerror }{
        .{ .tenant = "a", .route = null, .failure = null },
        .{ .tenant = "é" ** 32, .route = "\"" ** 2048, .failure = null },
        .{ .tenant = "", .route = null, .failure = error.InvalidTenant },
        .{ .tenant = "é" ** 32 ++ "a", .route = null, .failure = error.InvalidTenant },
        .{ .tenant = "\xff", .route = null, .failure = error.InvalidTenant },
        .{ .tenant = "a", .route = "", .failure = error.InvalidResultQueue },
        .{ .tenant = "a", .route = "é" ** 1024 ++ "a", .failure = error.InvalidResultQueue },
        .{ .tenant = "a", .route = "\xff", .failure = error.InvalidResultQueue },
        .{ .tenant = "a", .route = "a\n", .failure = error.InvalidResultQueue },
        .{ .tenant = "a", .route = "a\x7f", .failure = error.InvalidResultQueue },
    };
    for (cases) |case| {
        const message: Message = .{
            .operation_id = 0,
            .tenant = case.tenant,
            .body = .null,
            .context = .null,
            .result_queue = case.route,
        };
        const options: FrameOptions = .{
            .operation_id = 0,
            .tenant = case.tenant,
            .context = .null,
            .result_queue = case.route,
        };
        if (case.failure) |failure| {
            try std.testing.expectError(failure, encode(allocator, &message));
            try std.testing.expectError(failure, frame(buffer, "null", &options));
        } else {
            const encoded = try encode(allocator, &message);
            const decoded = try decode(allocator, encoded);
            try std.testing.expectEqualStrings(case.tenant, decoded.tenant);
            try std.testing.expectEqualStrings(encoded, try frame(buffer, "null", &options));
        }
    }
}

test "decoded metadata rejects missing fields wrong types unknown and duplicate decoded keys" {
    const prefix = "{\"operation_id\":\"00000000-0000-0000-0000-000000000001\",\"body\":null,";
    const invalid = [_][]const u8{
        "{\"tenant\":\"a\",\"body\":null,\"context\":null}",
        "{\"operation_id\":\"00000000-0000-0000-0000-000000000001\",\"tenant\":\"a\",\"context\":null}",
        prefix ++ "\"context\":null}",
        prefix ++ "\"tenant\":null,\"context\":null}",
        prefix ++ "\"tenant\":42,\"context\":null}",
        prefix ++ "\"tenant\":\"\",\"context\":null}",
        prefix ++ "\"tenant\":\"" ++ "a" ** 65 ++ "\",\"context\":null}",
        prefix ++ "\"tenant\":\"a\",\"context\":null,\"\\u0074enant\":\"b\"}",
        prefix ++ "\"tenant\":\"a\",\"context\":null,\"\\u0063ontext\":null}",
        prefix ++ "\"tenant\":\"a\",\"context\":{\"a\":1,\"\\u0061\":2}}",
        prefix ++ "\"tenant\":\"a\",\"context\":null,\"hash\":null}",
        prefix ++ "\"tenant\":\"a\",\"context\":null,\"result_queue\":\"a\\u0000\"}",
        prefix ++ "\"tenant\":\"a\",\"context\":null,\"result_queue\":\"" ++ "a" ** 2049 ++ "\"}",
        prefix ++ "\"tenant\":\"a\",\"context\":null,\"result_queue\":\"a\",\"result_\\u0071ueue\":\"b\"}",
    };
    for (invalid) |input| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        if (decode(arena.allocator(), input)) |_| return error.InvalidMessageAccepted else |err| {
            try std.testing.expect(err != error.OutOfMemory);
        }
    }
}

test "maximum escaped components fit the envelope and raw input has an independent bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const body: std.json.Value = .{ .string = try test_escaped_text(allocator, 98304) };
    const context: std.json.Value = .{ .string = try test_escaped_text(allocator, 4096) };
    const message: Message = .{ .operation_id = std.math.maxInt(u128), .tenant = "\x00" ** 64, .body = body, .context = context, .result_queue = "\"" ** 2048 };
    const encoded = try encode(allocator, &message);
    // The envelope ceiling reserves six bytes per route byte, conservatively:
    // valid routes exclude the controls that need six-byte JSON escaping.
    try std.testing.expect(encoded.len < 115328);
    const buffer = try allocator.alloc(u8, 115329);
    const body_json = try std.json.Stringify.valueAlloc(allocator, body, .{});
    try std.testing.expectEqual(@as(usize, 98304), body_json.len);
    const framed = try frame(buffer, body_json, &.{
        .operation_id = message.operation_id,
        .tenant = message.tenant,
        .context = context,
        .result_queue = message.result_queue,
    });
    try std.testing.expectEqualStrings(encoded, framed);
    const decoded = try decode(allocator, framed);
    try std.testing.expectEqualStrings(message.tenant, decoded.tenant);
    try std.testing.expectEqualStrings(context.string, decoded.context.string);
    const oversized_body: std.json.Value = .{ .string = try test_escaped_text(allocator, 98305) };
    const raw = try std.json.Stringify.valueAlloc(allocator, .{
        .operation_id = "00000000-0000-0000-0000-000000000001",
        .tenant = "a",
        .body = oversized_body,
        .context = @as(std.json.Value, .null),
    }, .{});
    try std.testing.expectError(error.BodyTooLarge, decode(allocator, raw));
    try std.testing.expectError(error.BodyTooLarge, frame(
        buffer,
        try std.json.Stringify.valueAlloc(allocator, oversized_body, .{}),
        &.{ .operation_id = 1, .tenant = "a", .context = .null },
    ));
    const padded = try allocator.alloc(u8, 115329);
    @memcpy(padded[0..encoded.len], encoded);
    @memset(padded[encoded.len..], ' ');
    _ = try decode(allocator, padded[0..115328]);
    try std.testing.expectError(error.MessageTooLarge, decode(allocator, padded));
}
