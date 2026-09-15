const std = @import("std");
const operation = @import("operation");
const Allocator = std.mem.Allocator;

pub const body_size_max = 96 * 1024;
pub const queue_url_size_max = 2048;
pub const encoded_size_max = body_size_max + 6 * queue_url_size_max + 128;
comptime {
    std.debug.assert(body_size_max == 98304);
    std.debug.assert(queue_url_size_max > 0);
    std.debug.assert(encoded_size_max > body_size_max);
    std.debug.assert(encoded_size_max < 1024 * 1024);
}

pub const Message = struct {
    operation_id: u128,
    body: std.json.Value,
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
            !std.mem.eql(u8, key, "body") and
            !std.mem.eql(u8, key, "result_queue")) return error.UnknownField;
    }
    const id = value.object.get("operation_id") orelse return error.MissingField;
    if (id != .string) return error.InvalidUUID;
    const uuid = try operation.uuidFromString(id.string);
    var text: [operation.uuid_string_size]u8 = undefined;
    if (!std.mem.eql(u8, id.string, operation.uuidToString(uuid, &text))) {
        return error.InvalidUUID;
    }
    const body = value.object.get("body") orelse return error.MissingField;
    _ = try body_size(&body);
    var route: ?[]const u8 = null;
    if (value.object.get("result_queue")) |queue| {
        if (queue != .string) return error.InvalidResultQueue;
        try validate_route(queue.string);
        route = queue.string;
    }
    return .{ .operation_id = uuid, .body = body, .result_queue = route };
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

pub fn encode(arena: Allocator, message: *const Message) ![]const u8 {
    _ = try body_size(&message.body);
    var output = std.Io.Writer.Allocating.init(arena);
    errdefer output.deinit();
    var uuid: [operation.uuid_string_size]u8 = undefined;
    try output.writer.print("{{\"operation_id\":\"{s}\",\"body\":", .{
        operation.uuidToString(message.operation_id, &uuid),
    });
    try std.json.Stringify.value(message.body, .{}, &output.writer);
    try write_route(&output.writer, message.result_queue);
    try output.writer.writeByte('}');
    std.debug.assert(output.written().len <= encoded_size_max);
    return output.toOwnedSlice();
}

/// Frames trusted compact JSON from a processor without allocating another Value tree.
pub fn frame(buffer: []u8, id: u128, body: []const u8, route: ?[]const u8) ![]const u8 {
    if (body.len > body_size_max) return error.BodyTooLarge;
    std.debug.assert(body.len > 0);
    var writer = std.Io.Writer.fixed(buffer);
    var uuid: [operation.uuid_string_size]u8 = undefined;
    try writer.print("{{\"operation_id\":\"{s}\",\"body\":", .{operation.uuidToString(id, &uuid)});
    try writer.writeAll(body);
    try write_route(&writer, route);
    try writer.writeByte('}');
    return writer.buffered();
}

fn write_route(writer: *std.Io.Writer, route: ?[]const u8) !void {
    if (route) |queue| {
        try validate_route(queue);
        try writer.writeAll(",\"result_queue\":");
        try std.json.Stringify.value(queue, .{}, writer);
    }
}

test "internal bodies accept 96 KiB including above intake limit and reject larger bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const text = try allocator.alloc(u8, body_size_max - 2);
    @memset(text, 'x');
    const encoded = try encode(allocator, &.{ .operation_id = 1, .body = .{ .string = text } });
    const decoded = try decode(allocator, encoded);
    try std.testing.expectEqual(@as(usize, body_size_max - 2), decoded.body.string.len);
    try std.testing.expect(decoded.result_queue == null);
    const too_large = try allocator.alloc(u8, body_size_max - 1);
    @memset(too_large, 'x');
    try std.testing.expectError(error.BodyTooLarge, encode(allocator, &.{ .operation_id = 1, .body = .{ .string = too_large } }));
    const oversized = try std.fmt.allocPrint(allocator, "{{\"operation_id\":\"00000000-0000-0000-0000-000000000001\",\"body\":\"{s}\"}}", .{too_large});
    try std.testing.expectError(error.BodyTooLarge, decode(allocator, oversized));
}

test "messages reject ambiguous IDs duplicate keys invalid routes and legacy envelopes" {
    const cases = [_][]const u8{
        "{\"operation_id\":\"00000000-0000-0000-0000-000000000001\",\"body\":{},\"body\":true}",
        "{\"operation_id\":\"00000000-0000-0000-0000-000000000001\",\"body\":{\"a\":1,\"\\u0061\":2}}",
        "{\"operation_id\":\"00112233-4455-6677-8899-AABBCCDDEEFF\",\"body\":{}}",
        "{\"operation_id\":\"00000000-0000-0000-0000-000000000001\",\"body\":{},\"result_queue\":null}",
        "{\"operation_id\":\"00000000-0000-0000-0000-000000000001\",\"body\":{},\"result_queue\":\"\"}",
        "{\"operation_id\":\"00000000-0000-0000-0000-000000000001\",\"body\":{},\"tenant\":\"private\"}",
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

test "message round trips an internal route without Operation metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = "{\"operation_id\":\"00112233-4455-6677-8899-aabbccddeeff\",\"body\":{\"x\":1},\"result_queue\":\"https://sqs.example.invalid/next\"}";
    const message = try decode(arena.allocator(), input);
    try std.testing.expectEqualStrings("https://sqs.example.invalid/next", message.result_queue.?);
    try std.testing.expectEqualStrings(input, try encode(arena.allocator(), &message));
}
