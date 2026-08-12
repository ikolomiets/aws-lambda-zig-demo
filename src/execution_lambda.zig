const std = @import("std");
const lambda = @import("aws-lambda");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{
        .scope = .execution,
        .level = .debug,
    }},
};

const log = std.log.scoped(.execution);

pub fn main(init: std.process.Init) void {
    lambda.handle(init, handler, .{});
}

fn handler(ctx: lambda.Context, event: []const u8) ![]const u8 {
    return handleInvocation(ctx.arena, event);
}

fn handleInvocation(allocator: std.mem.Allocator, event: []const u8) ![]const u8 {
    const sqs_event = try lambda.sqs.parseEvent(allocator, event);
    defer sqs_event.deinit(allocator);

    for (sqs_event.records) |record| {
        log.debug("message_id={s} body={s}", .{ record.message_id, record.body });
    }

    return lambda.sqs.encodeResponse(allocator, .{});
}

test "multi-record SQS event returns an empty partial-batch response" {
    const event =
        \\{
        \\  "Records": [
        \\    {
        \\      "messageId": "message-1",
        \\      "receiptHandle": "receipt-1",
        \\      "body": "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"}",
        \\      "attributes": {},
        \\      "messageAttributes": {},
        \\      "eventSource": "aws:sqs",
        \\      "eventSourceARN": "arn:aws:sqs:ca-central-1:account-id:operations",
        \\      "awsRegion": "ca-central-1"
        \\    },
        \\    {
        \\      "messageId": "message-2",
        \\      "receiptHandle": "receipt-2",
        \\      "body": "{\"id\":\"ffeeddcc-bbaa-9988-7766-554433221100\"}",
        \\      "attributes": {},
        \\      "messageAttributes": {},
        \\      "eventSource": "aws:sqs",
        \\      "eventSourceARN": "arn:aws:sqs:ca-central-1:account-id:operations",
        \\      "awsRegion": "ca-central-1"
        \\    }
        \\  ]
        \\}
    ;

    const response = try handleInvocation(std.testing.allocator, event);
    defer std.testing.allocator.free(response);

    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
}

test "malformed events are rejected" {
    try std.testing.expectError(
        error.InvalidInput,
        handleInvocation(std.testing.allocator, "{}"),
    );
}

test "non-SQS events are rejected" {
    const event =
        \\{"Records":[{"messageId":"message-1","receiptHandle":"receipt-1",
        \\"body":"body","attributes":{},"messageAttributes":{},
        \\"eventSource":"aws:sns","eventSourceARN":"arn","awsRegion":"region"}]}
    ;

    try std.testing.expectError(
        error.UnexpectedEventSource,
        handleInvocation(std.testing.allocator, event),
    );
}

test "execution debug logging is enabled in ReleaseSafe" {
    comptime {
        if (std_options.log_level != .info) @compileError("unexpected default log level");
        if (std_options.log_scope_levels.len != 1) @compileError("unexpected log scope count");
        if (std_options.log_scope_levels[0].scope != .execution) {
            @compileError("unexpected log scope");
        }
        if (std_options.log_scope_levels[0].level != .debug) {
            @compileError("execution debug logging is disabled");
        }
    }
}
