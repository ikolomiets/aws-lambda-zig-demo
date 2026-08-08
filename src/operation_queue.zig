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

comptime {
    std.debug.assert(queue_url_size_max < message_size_max);
    std.debug.assert(receipt_handle_size_max < message_size_max);
    std.debug.assert(attribute_count_max > 1);
    std.debug.assert(receive_message_count_max == 1);
    std.debug.assert(receive_wait_time_seconds > 0);
    std.debug.assert(receive_wait_time_seconds <= 20);
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
        return send_with_client(&self.client, arena, self.queue_url, body);
    }

    /// Returns at most one message after polling for up to 20 seconds.
    pub fn receive(self: *Self, arena: Allocator) !?Message {
        return receive_with_client(&self.client, arena, self.queue_url);
    }

    pub fn delete(self: *Self, arena: Allocator, receipt_handle: []const u8) !void {
        return delete_with_client(&self.client, arena, self.queue_url, receipt_handle);
    }

    /// Returns every queue attribute, including attributes added by future SDK versions.
    pub fn get_attributes(self: *Self, arena: Allocator) ![]const Attribute {
        return get_attributes_with_client(&self.client, arena, self.queue_url);
    }
};

fn send_with_client(
    client: anytype,
    arena: Allocator,
    queue_url: []const u8,
    body: []const u8,
) !void {
    try validate_message_body(body);
    _ = client.sendMessage(arena, .{
        .message_body = body,
        .queue_url = queue_url,
    }, .{}) catch |err| return map_aws_error(err);
}

fn receive_with_client(
    client: anytype,
    arena: Allocator,
    queue_url: []const u8,
) !?Message {
    const output = client.receiveMessage(arena, .{
        .max_number_of_messages = receive_message_count_max,
        .queue_url = queue_url,
        .wait_time_seconds = receive_wait_time_seconds,
    }, .{}) catch |err| return map_aws_error(err);
    const messages = output.messages orelse return null;
    if (messages.len == 0) return null;
    if (messages.len != 1) return error.InvalidServiceResponse;
    return @as(?Message, try decode_message(messages[0]));
}

fn delete_with_client(
    client: anytype,
    arena: Allocator,
    queue_url: []const u8,
    receipt_handle: []const u8,
) !void {
    try validate_receipt_handle(receipt_handle);
    _ = client.deleteMessage(arena, .{
        .queue_url = queue_url,
        .receipt_handle = receipt_handle,
    }, .{}) catch |err| return map_aws_error(err);
}

fn get_attributes_with_client(
    client: anytype,
    arena: Allocator,
    queue_url: []const u8,
) ![]const Attribute {
    const all = [_]sqs.types.QueueAttributeName{.all};
    const output = client.getQueueAttributes(arena, .{
        .attribute_names = &all,
        .queue_url = queue_url,
    }, .{}) catch |err| return map_aws_error(err);
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

const FakeSQSClient = struct {
    messages: ?[]const sqs.types.Message = null,
    attributes: ?[]const aws.map.StringMapEntry = null,
    request_error: ?anyerror = null,
    send_count: u8 = 0,
    receive_count: u8 = 0,
    delete_count: u8 = 0,
    attributes_count: u8 = 0,
    sent_body: []const u8 = "",
    sent_queue_url: []const u8 = "",
    receive_queue_url: []const u8 = "",
    receive_message_count_max: ?i32 = null,
    receive_wait_time_seconds: ?i32 = null,
    delete_queue_url: []const u8 = "",
    deleted_receipt_handle: []const u8 = "",
    attributes_queue_url: []const u8 = "",
    requested_all_attributes: bool = false,

    fn sendMessage(
        fake: *FakeSQSClient,
        _: Allocator,
        input: sqs.SendMessageInput,
        _: sqs.CallOptions,
    ) !void {
        fake.send_count += 1;
        fake.sent_body = input.message_body;
        fake.sent_queue_url = input.queue_url;
        if (fake.request_error) |err| return err;
    }

    fn receiveMessage(
        fake: *FakeSQSClient,
        _: Allocator,
        input: sqs.ReceiveMessageInput,
        _: sqs.CallOptions,
    ) !sqs.ReceiveMessageOutput {
        fake.receive_count += 1;
        fake.receive_queue_url = input.queue_url;
        fake.receive_message_count_max = input.max_number_of_messages;
        fake.receive_wait_time_seconds = input.wait_time_seconds;
        if (fake.request_error) |err| return err;
        return .{ .messages = fake.messages };
    }

    fn deleteMessage(
        fake: *FakeSQSClient,
        _: Allocator,
        input: sqs.DeleteMessageInput,
        _: sqs.CallOptions,
    ) !void {
        fake.delete_count += 1;
        fake.delete_queue_url = input.queue_url;
        fake.deleted_receipt_handle = input.receipt_handle;
        if (fake.request_error) |err| return err;
    }

    fn getQueueAttributes(
        fake: *FakeSQSClient,
        _: Allocator,
        input: sqs.GetQueueAttributesInput,
        _: sqs.CallOptions,
    ) !sqs.GetQueueAttributesOutput {
        fake.attributes_count += 1;
        fake.attributes_queue_url = input.queue_url;
        if (input.attribute_names) |names| {
            fake.requested_all_attributes = names.len == 1 and names[0] == .all;
        }
        if (fake.request_error) |err| return err;
        return .{ .attributes = fake.attributes };
    }
};

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
    const sdk_messages = [_]sqs.types.Message{.{
        .body = "body",
        .receipt_handle = "receipt",
    }};
    const sdk_attributes = [_]aws.map.StringMapEntry{
        .{ .key = "ApproximateNumberOfMessages", .value = "1" },
    };
    var fake: FakeSQSClient = .{
        .messages = &sdk_messages,
        .attributes = &sdk_attributes,
    };

    try send_with_client(&fake, std.testing.allocator, test_queue_url, "submitted-operation");
    const message = (try receive_with_client(
        &fake,
        std.testing.allocator,
        test_queue_url,
    )).?;
    try delete_with_client(&fake, std.testing.allocator, test_queue_url, message.receipt_handle);
    const attributes = try get_attributes_with_client(
        &fake,
        std.testing.allocator,
        test_queue_url,
    );
    defer std.testing.allocator.free(attributes);

    try std.testing.expectEqual(@as(u8, 1), fake.send_count);
    try std.testing.expectEqualStrings(test_queue_url, fake.sent_queue_url);
    try std.testing.expectEqualStrings("submitted-operation", fake.sent_body);
    try std.testing.expectEqual(@as(u8, 1), fake.receive_count);
    try std.testing.expectEqualStrings(test_queue_url, fake.receive_queue_url);
    try std.testing.expectEqual(receive_message_count_max, fake.receive_message_count_max.?);
    try std.testing.expectEqual(receive_wait_time_seconds, fake.receive_wait_time_seconds.?);
    try std.testing.expectEqualStrings("body", message.body);
    try std.testing.expectEqual(@as(u8, 1), fake.delete_count);
    try std.testing.expectEqualStrings(test_queue_url, fake.delete_queue_url);
    try std.testing.expectEqualStrings("receipt", fake.deleted_receipt_handle);
    try std.testing.expectEqual(@as(u8, 1), fake.attributes_count);
    try std.testing.expectEqualStrings(test_queue_url, fake.attributes_queue_url);
    try std.testing.expect(fake.requested_all_attributes);
    try std.testing.expectEqualStrings("ApproximateNumberOfMessages", attributes[0].key);
    try std.testing.expectEqualStrings("1", attributes[0].value);
}

test "send and delete reject empty and oversized values before requesting AWS" {
    var fake: FakeSQSClient = .{};
    try std.testing.expectError(
        error.InvalidMessage,
        send_with_client(&fake, std.testing.allocator, test_queue_url, ""),
    );
    const oversized_message = try std.testing.allocator.alloc(u8, message_size_max + 1);
    defer std.testing.allocator.free(oversized_message);
    try std.testing.expectError(
        error.InvalidMessage,
        send_with_client(&fake, std.testing.allocator, test_queue_url, oversized_message),
    );
    try std.testing.expectError(
        error.InvalidReceiptHandle,
        delete_with_client(&fake, std.testing.allocator, test_queue_url, ""),
    );
    const oversized_receipt = try std.testing.allocator.alloc(u8, receipt_handle_size_max + 1);
    defer std.testing.allocator.free(oversized_receipt);
    try std.testing.expectError(
        error.InvalidReceiptHandle,
        delete_with_client(&fake, std.testing.allocator, test_queue_url, oversized_receipt),
    );
    try std.testing.expectEqual(@as(u8, 0), fake.send_count);
    try std.testing.expectEqual(@as(u8, 0), fake.delete_count);
}

test "receive accepts empty and one valid arbitrary-byte message" {
    var fake: FakeSQSClient = .{};
    try std.testing.expect((try receive_with_client(
        &fake,
        std.testing.allocator,
        test_queue_url,
    )) == null);
    fake.messages = &.{};
    try std.testing.expect((try receive_with_client(
        &fake,
        std.testing.allocator,
        test_queue_url,
    )) == null);

    const body = [_]u8{ 0x00, 0xFF, '\n' };
    const messages = [_]sqs.types.Message{.{
        .body = &body,
        .receipt_handle = "receipt",
    }};
    fake.messages = &messages;
    const message = (try receive_with_client(
        &fake,
        std.testing.allocator,
        test_queue_url,
    )).?;
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
        var fake: FakeSQSClient = .{ .messages = messages };
        try std.testing.expectError(
            error.InvalidServiceResponse,
            receive_with_client(&fake, std.testing.allocator, test_queue_url),
        );
    }

    const oversized_body = try std.testing.allocator.alloc(u8, message_size_max + 1);
    defer std.testing.allocator.free(oversized_body);
    const body_message = [_]sqs.types.Message{.{
        .body = oversized_body,
        .receipt_handle = "receipt",
    }};
    var body_fake: FakeSQSClient = .{ .messages = &body_message };
    try std.testing.expectError(
        error.InvalidServiceResponse,
        receive_with_client(&body_fake, std.testing.allocator, test_queue_url),
    );

    const oversized_receipt = try std.testing.allocator.alloc(u8, receipt_handle_size_max + 1);
    defer std.testing.allocator.free(oversized_receipt);
    const receipt_message = [_]sqs.types.Message{.{
        .body = "body",
        .receipt_handle = oversized_receipt,
    }};
    var receipt_fake: FakeSQSClient = .{ .messages = &receipt_message };
    try std.testing.expectError(
        error.InvalidServiceResponse,
        receive_with_client(&receipt_fake, std.testing.allocator, test_queue_url),
    );
}

test "attributes preserve all entries and reject malformed service data" {
    const valid = [_]aws.map.StringMapEntry{
        .{ .key = "Known", .value = "value" },
        .{ .key = "Future-Attribute", .value = "é" },
    };
    var fake: FakeSQSClient = .{ .attributes = &valid };
    const attributes = try get_attributes_with_client(
        &fake,
        std.testing.allocator,
        test_queue_url,
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
        var invalid_fake: FakeSQSClient = .{ .attributes = sdk_attributes };
        try std.testing.expectError(
            error.InvalidServiceResponse,
            get_attributes_with_client(
                &invalid_fake,
                std.testing.allocator,
                test_queue_url,
            ),
        );
    }
}

test "SDK and conversion allocation errors preserve only OutOfMemory" {
    const operations = [_]enum { send, receive, delete, attributes }{
        .send,
        .receive,
        .delete,
        .attributes,
    };
    const failures = [_]anyerror{ error.OutOfMemory, error.ConnectionFailed };
    for (failures) |sdk_error| {
        for (operations) |sdk_operation| {
            var fake: FakeSQSClient = .{ .request_error = sdk_error };
            const expected = if (sdk_error == error.OutOfMemory)
                error.OutOfMemory
            else
                error.AWSFailure;
            const actual = switch (sdk_operation) {
                .send => send_with_client(
                    &fake,
                    std.testing.allocator,
                    test_queue_url,
                    "body",
                ),
                .receive => receive_result: {
                    _ = receive_with_client(
                        &fake,
                        std.testing.allocator,
                        test_queue_url,
                    ) catch |err| break :receive_result err;
                    return error.ExpectedFailure;
                },
                .delete => delete_with_client(
                    &fake,
                    std.testing.allocator,
                    test_queue_url,
                    "receipt",
                ),
                .attributes => attributes_result: {
                    _ = get_attributes_with_client(
                        &fake,
                        std.testing.allocator,
                        test_queue_url,
                    ) catch |err| break :attributes_result err;
                    return error.ExpectedFailure;
                },
            };
            try std.testing.expectError(expected, actual);
        }
    }

    const sdk_attributes = [_]aws.map.StringMapEntry{.{ .key = "key", .value = "value" }};
    var allocation_fake: FakeSQSClient = .{ .attributes = &sdk_attributes };
    try std.testing.expectError(
        error.OutOfMemory,
        get_attributes_with_client(
            &allocation_fake,
            std.testing.failing_allocator,
            test_queue_url,
        ),
    );
}
