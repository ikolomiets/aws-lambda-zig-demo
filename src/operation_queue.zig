const std = @import("std");
const aws = @import("aws");
const sqs = @import("sqs");

const Allocator = std.mem.Allocator;

const queue_url_size_max = 2048;
const message_size_max = 1024 * 1024;
const receipt_handle_size_max = 64 * 1024;
const attribute_count_max = 64;
const attribute_name_size_max = 256;
const attribute_value_size_max = 256 * 1024;
const receive_message_count_max: i32 = 1;
const receive_wait_time_seconds: i32 = 20;
const attribute_names_all = [_]sqs.types.QueueAttributeName{.all};

comptime {
    std.debug.assert(queue_url_size_max < message_size_max);
    std.debug.assert(receipt_handle_size_max < message_size_max);
    std.debug.assert(attribute_count_max > 1);
    std.debug.assert(receive_message_count_max == 1);
    std.debug.assert(receive_wait_time_seconds > 0);
    std.debug.assert(receive_wait_time_seconds <= 20);
    std.debug.assert(attribute_names_all.len == 1);
}

pub const Message = struct {
    body: []const u8,
    receipt_handle: []const u8,
};

pub const Attribute = struct {
    key: []const u8,
    value: []const u8,
};

/// Owns SQS configuration, requests, responses, and validation for the operations queue.
pub const Queue = struct {
    client: sqs.Client,
    queue_url: []const u8,

    const Self = @This();

    pub fn init(
        target: *Self,
        allocator: Allocator,
        aws_config: *aws.Config,
        environment: *const std.process.Environ.Map,
    ) !void {
        const queue_url = configured_queue_url(environment) catch {
            return error.InvalidConfiguration;
        };
        target.* = .{
            .client = sqs.Client.init(allocator, aws_config),
            .queue_url = queue_url,
        };
        std.debug.assert(target.client.config == aws_config);
        std.debug.assert(target.queue_url.len > 0);
        std.debug.assert(target.queue_url.len <= queue_url_size_max);
    }

    pub fn deinit(self: *Self) void {
        self.client.deinit();
        self.* = undefined;
    }

    pub fn send(self: *Self, arena: Allocator, body: []const u8) !void {
        const request = try send_request(self.queue_url, body);
        _ = self.client.sendMessage(arena, request, .{}) catch |err| {
            return map_aws_error(err);
        };
    }

    /// Returns at most one message after polling for up to 20 seconds.
    pub fn receive(self: *Self, arena: Allocator) !?Message {
        const request = receive_request(self.queue_url);
        const output = self.client.receiveMessage(arena, request, .{}) catch |err| {
            return map_aws_error(err);
        };
        return decode_receive_output(output);
    }

    pub fn delete(self: *Self, arena: Allocator, receipt_handle: []const u8) !void {
        const request = try delete_request(self.queue_url, receipt_handle);
        _ = self.client.deleteMessage(arena, request, .{}) catch |err| {
            return map_aws_error(err);
        };
    }

    /// Returns every queue attribute, including attributes added by future SDK versions.
    pub fn get_attributes(self: *Self, arena: Allocator) ![]const Attribute {
        const request = get_attributes_request(self.queue_url);
        const output = self.client.getQueueAttributes(arena, request, .{}) catch |err| {
            return map_aws_error(err);
        };
        return decode_attributes_output(arena, output);
    }
};

fn send_request(queue_url: []const u8, body: []const u8) !sqs.SendMessageInput {
    try validate_message_body(body);
    return .{
        .message_body = body,
        .queue_url = queue_url,
    };
}

fn receive_request(queue_url: []const u8) sqs.ReceiveMessageInput {
    return .{
        .max_number_of_messages = receive_message_count_max,
        .queue_url = queue_url,
        .wait_time_seconds = receive_wait_time_seconds,
    };
}

fn decode_receive_output(output: sqs.ReceiveMessageOutput) !?Message {
    const messages = output.messages orelse return null;
    if (messages.len == 0) return null;
    if (messages.len != 1) return error.InvalidServiceResponse;
    return @as(?Message, try decode_message(messages[0]));
}

fn delete_request(queue_url: []const u8, receipt_handle: []const u8) !sqs.DeleteMessageInput {
    try validate_receipt_handle(receipt_handle);
    return .{
        .queue_url = queue_url,
        .receipt_handle = receipt_handle,
    };
}

fn get_attributes_request(queue_url: []const u8) sqs.GetQueueAttributesInput {
    return .{
        .attribute_names = &attribute_names_all,
        .queue_url = queue_url,
    };
}

fn decode_attributes_output(
    arena: Allocator,
    output: sqs.GetQueueAttributesOutput,
) ![]const Attribute {
    const sdk_attributes = output.attributes orelse return &.{};
    try validate_attributes(sdk_attributes);
    if (sdk_attributes.len == 0) return &.{};

    const attributes = try arena.alloc(Attribute, sdk_attributes.len);
    for (sdk_attributes, attributes) |source, *target| {
        target.* = .{ .key = source.key, .value = source.value };
    }
    std.debug.assert(attributes.len == sdk_attributes.len);
    return attributes;
}

fn decode_message(source: sqs.types.Message) !Message {
    const body = source.body orelse return error.InvalidServiceResponse;
    const receipt_handle = source.receipt_handle orelse {
        return error.InvalidServiceResponse;
    };
    validate_message_body(body) catch return error.InvalidServiceResponse;
    validate_receipt_handle(receipt_handle) catch return error.InvalidServiceResponse;
    return .{ .body = body, .receipt_handle = receipt_handle };
}

fn validate_message_body(body: []const u8) !void {
    if (body.len == 0) return error.InvalidMessage;
    if (body.len > message_size_max) return error.InvalidMessage;
    std.debug.assert(body.len > 0);
    std.debug.assert(body.len <= message_size_max);
}

fn validate_receipt_handle(receipt_handle: []const u8) !void {
    if (receipt_handle.len == 0) return error.InvalidReceiptHandle;
    if (receipt_handle.len > receipt_handle_size_max) return error.InvalidReceiptHandle;
    std.debug.assert(receipt_handle.len > 0);
    std.debug.assert(receipt_handle.len <= receipt_handle_size_max);
}

fn validate_attributes(attributes: []const aws.map.StringMapEntry) !void {
    if (attributes.len > attribute_count_max) return error.InvalidServiceResponse;
    for (attributes) |attribute| {
        if (attribute.key.len == 0) return error.InvalidServiceResponse;
        if (attribute.key.len > attribute_name_size_max) return error.InvalidServiceResponse;
        if (attribute.value.len > attribute_value_size_max) {
            return error.InvalidServiceResponse;
        }
        if (!std.unicode.utf8ValidateSlice(attribute.key)) return error.InvalidServiceResponse;
        if (!std.unicode.utf8ValidateSlice(attribute.value)) return error.InvalidServiceResponse;
    }
    std.debug.assert(attributes.len <= attribute_count_max);
}

fn configured_queue_url(environment: *const std.process.Environ.Map) ![]const u8 {
    const queue_url = environment.get("OPERATIONS_QUEUE_URL") orelse {
        return error.InvalidConfiguration;
    };
    if (queue_url.len == 0) return error.InvalidConfiguration;
    if (queue_url.len > queue_url_size_max) return error.InvalidConfiguration;
    std.debug.assert(queue_url.len > 0);
    std.debug.assert(queue_url.len <= queue_url_size_max);
    return queue_url;
}

fn map_aws_error(err: anyerror) error{ OutOfMemory, AWSFailure } {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return error.AWSFailure;
}

const test_queue_url = "https://sqs.example.invalid/operations";

test "initialization requires a nonempty bounded queue URL" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var config: aws.Config = undefined;
    var queue: Queue = undefined;

    try std.testing.expectError(
        error.InvalidConfiguration,
        Queue.init(&queue, std.testing.allocator, &config, &environment),
    );
    const invalid_urls = [_][]const u8{
        "",
        "a" ** (queue_url_size_max + 1),
    };
    for (invalid_urls) |queue_url| {
        try environment.put("OPERATIONS_QUEUE_URL", queue_url);
        try std.testing.expectError(
            error.InvalidConfiguration,
            Queue.init(&queue, std.testing.allocator, &config, &environment),
        );
    }
}

test "initialization retains valid queue configuration and shared AWS configuration" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("OPERATIONS_QUEUE_URL", test_queue_url);
    var config: aws.Config = undefined;
    var queue: Queue = undefined;
    try Queue.init(&queue, std.testing.allocator, &config, &environment);
    defer queue.deinit();

    try std.testing.expect(queue.client.config == &config);
    try std.testing.expectEqualStrings(test_queue_url, queue.queue_url);
}

test "requests use the configured URL and fixed queue contracts" {
    const send = try send_request(test_queue_url, "queued-operation");
    const receive = receive_request(test_queue_url);
    const delete = try delete_request(test_queue_url, "receipt");
    const attributes = get_attributes_request(test_queue_url);

    try std.testing.expectEqualStrings(test_queue_url, send.queue_url);
    try std.testing.expectEqualStrings("queued-operation", send.message_body);
    try std.testing.expectEqualStrings(test_queue_url, receive.queue_url);
    try std.testing.expectEqual(receive_message_count_max, receive.max_number_of_messages.?);
    try std.testing.expectEqual(receive_wait_time_seconds, receive.wait_time_seconds.?);
    try std.testing.expectEqualStrings(test_queue_url, delete.queue_url);
    try std.testing.expectEqualStrings("receipt", delete.receipt_handle);
    try std.testing.expectEqualStrings(test_queue_url, attributes.queue_url);
    try std.testing.expectEqual(@as(usize, 1), attributes.attribute_names.?.len);
    try std.testing.expectEqual(sqs.types.QueueAttributeName.all, attributes.attribute_names.?[0]);
}

test "send and delete requests reject empty and oversized values" {
    try std.testing.expectError(
        error.InvalidMessage,
        send_request(test_queue_url, ""),
    );
    const oversized_message = try std.testing.allocator.alloc(u8, message_size_max + 1);
    defer std.testing.allocator.free(oversized_message);
    try std.testing.expectError(
        error.InvalidMessage,
        send_request(test_queue_url, oversized_message),
    );
    try std.testing.expectError(
        error.InvalidReceiptHandle,
        delete_request(test_queue_url, ""),
    );
    const oversized_receipt = try std.testing.allocator.alloc(u8, receipt_handle_size_max + 1);
    defer std.testing.allocator.free(oversized_receipt);
    try std.testing.expectError(
        error.InvalidReceiptHandle,
        delete_request(test_queue_url, oversized_receipt),
    );
}

test "receive accepts empty and one valid arbitrary-byte message" {
    try std.testing.expect((try decode_receive_output(.{})) == null);
    try std.testing.expect((try decode_receive_output(.{ .messages = &.{} })) == null);

    const body = [_]u8{ 0x00, 0xFF, '\n' };
    const messages = [_]sqs.types.Message{.{
        .body = &body,
        .receipt_handle = "receipt",
    }};
    const message = (try decode_receive_output(.{ .messages = &messages })).?;
    try std.testing.expectEqualSlices(u8, &body, message.body);
    try std.testing.expectEqualStrings("receipt", message.receipt_handle);
}

test "receive rejects multiple messages and missing empty or oversized fields" {
    const valid: sqs.types.Message = .{ .body = "body", .receipt_handle = "receipt" };
    const invalid_responses = [_][]const sqs.types.Message{
        &.{ valid, valid },
        &.{.{ .receipt_handle = "receipt" }},
        &.{.{ .body = "body" }},
        &.{.{ .body = "", .receipt_handle = "receipt" }},
        &.{.{ .body = "body", .receipt_handle = "" }},
    };
    for (invalid_responses) |messages| {
        try std.testing.expectError(
            error.InvalidServiceResponse,
            decode_receive_output(.{ .messages = messages }),
        );
    }

    const oversized_body = try std.testing.allocator.alloc(u8, message_size_max + 1);
    defer std.testing.allocator.free(oversized_body);
    const body_message = [_]sqs.types.Message{.{
        .body = oversized_body,
        .receipt_handle = "receipt",
    }};
    try std.testing.expectError(
        error.InvalidServiceResponse,
        decode_receive_output(.{ .messages = &body_message }),
    );

    const oversized_receipt = try std.testing.allocator.alloc(u8, receipt_handle_size_max + 1);
    defer std.testing.allocator.free(oversized_receipt);
    const receipt_message = [_]sqs.types.Message{.{
        .body = "body",
        .receipt_handle = oversized_receipt,
    }};
    try std.testing.expectError(
        error.InvalidServiceResponse,
        decode_receive_output(.{ .messages = &receipt_message }),
    );
}

test "attributes preserve all entries and reject malformed service data" {
    try std.testing.expectEqual(
        @as(usize, 0),
        (try decode_attributes_output(std.testing.allocator, .{})).len,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        (try decode_attributes_output(std.testing.allocator, .{ .attributes = &.{} })).len,
    );
    const valid = [_]aws.map.StringMapEntry{
        .{ .key = "Known", .value = "value" },
        .{ .key = "Future-Attribute", .value = "é" },
    };
    const attributes = try decode_attributes_output(
        std.testing.allocator,
        .{ .attributes = &valid },
    );
    defer std.testing.allocator.free(attributes);
    try std.testing.expectEqual(@as(usize, 2), attributes.len);
    try std.testing.expectEqualStrings("Known", attributes[0].key);
    try std.testing.expectEqualStrings("value", attributes[0].value);
    try std.testing.expectEqualStrings("Future-Attribute", attributes[1].key);
    try std.testing.expectEqualStrings("é", attributes[1].value);

    const entry: aws.map.StringMapEntry = .{ .key = "key", .value = "value" };
    const too_many = [_]aws.map.StringMapEntry{entry} ** (attribute_count_max + 1);
    const invalid = [_][]const aws.map.StringMapEntry{
        &too_many,
        &.{.{ .key = "", .value = "value" }},
        &.{.{ .key = "k" ** (attribute_name_size_max + 1), .value = "value" }},
        &.{.{ .key = "key", .value = "v" ** (attribute_value_size_max + 1) }},
        &.{.{ .key = &.{0xFF}, .value = "value" }},
        &.{.{ .key = "key", .value = &.{0xFF} }},
    };
    for (invalid) |sdk_attributes| {
        try std.testing.expectError(
            error.InvalidServiceResponse,
            decode_attributes_output(
                std.testing.allocator,
                .{ .attributes = sdk_attributes },
            ),
        );
    }
}

test "SDK and conversion allocation errors preserve only OutOfMemory" {
    try std.testing.expectEqual(error.OutOfMemory, map_aws_error(error.OutOfMemory));
    try std.testing.expectEqual(error.AWSFailure, map_aws_error(error.ConnectionFailed));
    const sdk_attributes = [_]aws.map.StringMapEntry{.{ .key = "key", .value = "value" }};
    try std.testing.expectError(
        error.OutOfMemory,
        decode_attributes_output(
            std.testing.failing_allocator,
            .{ .attributes = &sdk_attributes },
        ),
    );
}
