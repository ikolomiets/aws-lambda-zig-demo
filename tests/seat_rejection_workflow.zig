const std = @import("std");
const dynamodb = @import("dynamodb");
const operation = @import("operation");
const operations = @import("operation_persistence");
const messages = @import("processor_message");
const seat = @import("seat_reservation");
const events = @import("seat_reservation_persistence");
const intake = @import("intake_lambda");
const query = @import("query_lambda");
const completion = @import("seat_reservation_completion_processor");
const submission = @import("seat_reservation_processor");
const Allocator = std.mem.Allocator;
const uuid = "00000000-0000-0000-0000-000000000001";
const request = "{\"id\":\"" ++ uuid ++ "\",\"name\":\"SeatReservation\",\"body\":{" ++
    "\"command\":\"reserve_seats\",\"event_id\":\"00000000-0000-0000-0000-000000000002\"," ++
    "\"class\":\"general\",\"quantity\":2}}";
const ack = "{\"batchItemFailures\":[]}";

const Sent = struct { queue: []const u8, body: []const u8 };
const Effects = struct {
    arena: Allocator,
    event: ?seat.Event = null,
    operation_item: ?[]const events.Attribute = null,
    sent: std.ArrayList(Sent) = .empty,
    diagnostics: std.ArrayList([]const u8) = .empty,
    send_error: ?anyerror = null,
    write_error: ?anyerror = null,
    read_error: ?anyerror = null,
    send_before_error: bool = false,
    commit_before_error: bool = false,
    log_error: bool = false,
    updates: usize = 0,

    fn init(arena: Allocator) !Effects {
        return .{ .arena = arena, .event = .{
            .tenant = "theatre",
            .event_id = 2,
            .ledger = 1001,
            .timeout_seconds = 60,
            .capacity_account_id = 11,
            .allocation_account_id = 12,
            .state = .creating,
            .classes = try arena.dupe(seat.EventClass, &.{.{
                .tag = try seat.Tag.init("general"),
                .total = 10,
                .tb_account_id = 13,
            }}),
        } };
    }

    pub fn create(
        self: *Effects,
        arena: Allocator,
        source: *const operation.Operation,
    ) !operation.Operation {
        const put = try operations.create_request(self.arena, "Operations", source);
        self.operation_item = put.item;
        return operations.decode_item(arena, put.item);
    }

    pub fn get(
        self: *Effects,
        arena: Allocator,
        input: dynamodb.GetItemInput,
    ) !?[]const events.Attribute {
        try std.testing.expect(input.consistent_read.?);
        if (self.read_error) |err| return err;
        if (std.mem.eql(u8, input.table_name, "Events")) {
            if (self.event) |*event| {
                const tenant = input.key[0].value.s.?;
                if (std.mem.eql(
                    u8,
                    tenant,
                    event.tenant,
                )) return try events.encode_item(arena, event);
            }
            return null;
        }
        return self.operation_item;
    }

    pub fn send(self: *Effects, _: Allocator, queue: []const u8, body: []const u8) !void {
        if (!self.send_before_error) if (self.send_error) |err| return err;
        try self.sent.append(self.arena, .{
            .queue = try self.arena.dupe(u8, queue),
            .body = try self.arena.dupe(u8, body),
        });
        if (self.send_error) |err| return err;
    }

    pub fn update(self: *Effects, _: Allocator, input: dynamodb.types.Update) !void {
        self.updates += 1;
        if (!self.commit_before_error) if (self.write_error) |err| return err;
        const item = self.operation_item orelse return error.ConditionConflict;
        const saved = try operations.decode_item(self.arena, item);
        const values = input.expression_attribute_values.?;
        try std.testing.expect(
            std.mem.indexOf(
                u8,
                input.condition_expression.?,
                "attribute_not_exists(#result)",
            ) != null,
        );
        try std.testing.expect(std.mem.indexOf(u8, input.condition_expression.?, "hash") == null);
        if (!std.mem.eql(u8, saved.tenant, attribute(values, ":tenant").s.?) or
            !std.mem.eql(u8, saved.name, attribute(values, ":name").s.?) or
            saved.id != try operation.uuidFromString(attribute(values, ":id").s.?) or
            saved.state != .submitted) return error.ConditionConflict;
        var updated = try self.arena.alloc(events.Attribute, item.len + 1);
        @memcpy(updated[0..item.len], item);
        for (updated[0..item.len]) |*field| {
            if (std.mem.eql(u8, field.key, "state")) field.value = attribute(values, ":completed");
            if (std.mem.eql(u8, field.key, "last_updated")) field.value = attribute(values, ":now");
            if (std.mem.eql(
                u8,
                field.key,
                "expires_at",
            )) field.value = attribute(values, ":expires_at");
        }
        updated[item.len] = .{ .key = "result", .value = attribute(values, ":result") };
        // The service owns bytes independently of the invocation request arena.
        for (updated) |*field| {
            switch (field.value) {
                .s => |text| field.value = .{ .s = try self.arena.dupe(u8, text.?) },
                .n => |text| field.value = .{ .n = try self.arena.dupe(u8, text.?) },
                else => unreachable,
            }
        }
        self.operation_item = updated;
        if (self.write_error) |err| return err;
    }

    pub fn read(self: *Effects, arena: Allocator, id: u128) !operation.Operation {
        const input = try operations.read_request(arena, "Operations", id);
        return operations.decode_item(
            arena,
            try self.get(arena, input) orelse return error.OperationNotFound,
        );
    }

    pub fn report(self: *Effects, diagnostic: []const u8) !void {
        if (self.log_error) return error.LogDeliveryFailed;
        try self.diagnostics.append(self.arena, try self.arena.dupe(u8, diagnostic));
    }
};

fn sqs_event(arena: Allocator, body: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, .{ .Records = &.{.{
        .messageId = "source-1",
        .receiptHandle = "receipt",
        .body = body,
        .attributes = std.json.Value{ .object = .empty },
        .messageAttributes = std.json.Value{ .object = .empty },
        .md5OfBody = "md5",
        .eventSource = "aws:sqs",
        .eventSourceARN = "arn",
        .awsRegion = "ca-central-1",
    }} }, .{});
}

test "authenticated SeatReservation intake publishes a creating Event rejection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var effects = try Effects.init(allocator);
    const accepted = try intake.test_support.submit(allocator, &.{
        .input = request,
        .subject = "theatre",
        .operation_name = "SeatReservation",
    }, &effects);
    try std.testing.expect(std.mem.indexOf(u8, accepted, "SUBMITTED") != null);
    const source = effects.sent.items[0];
    const incoming = try messages.decode(allocator, source.body);
    try std.testing.expectEqualStrings("theatre", incoming.tenant);
    try std.testing.expect(incoming.context == .null);
    const response = try submission.handle_invocation(allocator, try sqs_event(
        allocator,
        source.body,
    ), &.{
        .events_table = "Events",
        .completion_queue = "seat-completion",
    }, &effects);
    try std.testing.expectEqualStrings(ack, response);
    try std.testing.expectEqual(@as(usize, 2), effects.sent.items.len);
    try std.testing.expectEqualStrings("seat-completion", effects.sent.items[1].queue);
    const outgoing = try messages.decode(allocator, effects.sent.items[1].body);
    try std.testing.expectEqualStrings(
        "event_not_ready",
        outgoing.body.object.get("code").?.string,
    );
    try std.testing.expectEqualStrings(
        "reserve_seats",
        outgoing.context.object.get("command").?.string,
    );
    try std.testing.expect(outgoing.result_queue == null);
}

fn attribute(item: []const events.Attribute, key: []const u8) dynamodb.types.AttributeValue {
    for (item) |field| if (std.mem.eql(u8, field.key, key)) return field.value;
    unreachable;
}

test "delayed rejection remains immutable and can be queried only by its authenticated owner" {
    var store_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer store_arena.deinit();
    const allocator = store_arena.allocator();
    var effects = try Effects.init(allocator);
    _ = try intake.test_support.submit(allocator, &.{
        .input = request,
        .subject = "theatre",
        .operation_name = "SeatReservation",
    }, &effects);
    _ = try submission.handle_invocation(allocator, try sqs_event(
        allocator,
        effects.sent.items[0].body,
    ), &.{
        .events_table = "Events",
        .completion_queue = "seat-completion",
    }, &effects);
    effects.event.?.state = .ready;
    const rejection = effects.sent.items[1].body;
    const response = try completion.handle_invocation(
        allocator,
        try sqs_event(allocator, rejection),
        &.{ .operations_table = "Operations", .now = 1001 },
        &effects,
    );
    try std.testing.expectEqualStrings(ack, response);
    const visible = try query.test_support.query_with_backend(allocator, 1, "theatre", &effects);
    try std.testing.expect(std.mem.indexOf(u8, visible, "event_not_ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "COMPLETED") != null);
    const foreign = try query.test_support.query_with_backend(allocator, 1, "foreign", &effects);
    try std.testing.expect(std.mem.indexOf(u8, foreign, "event_not_ready") == null);
    _ = try completion.handle_invocation(
        allocator,
        try sqs_event(allocator, rejection),
        &.{ .operations_table = "Operations", .now = 1002 },
        &effects,
    );
    const saved = try effects.read(allocator, 1);
    try std.testing.expectEqual(@as(?i64, 1001), saved.last_updated);
}

fn submitted_rejection(arena: Allocator, effects: *Effects, body: []const u8) ![]const u8 {
    const input = try std.fmt.allocPrint(
        arena,
        "{{\"id\":\"{s}\",\"name\":\"SeatReservation\",\"body\":{s}}}",
        .{ uuid, body },
    );
    _ = try intake.test_support.submit(arena, &.{
        .input = input,
        .subject = "theatre",
        .operation_name = "SeatReservation",
    }, effects);
    const response = try submission.handle_invocation(arena, try sqs_event(
        arena,
        effects.sent.items[0].body,
    ), &.{
        .events_table = "Events",
        .completion_queue = "seat-completion",
    }, effects);
    try std.testing.expectEqualStrings(ack, response);
    return effects.sent.items[1].body;
}

test "schema rejection preserves arbitrary invalid input as Context" {
    const invalid = [_][]const u8{
        "null",
        "[1,2]",
        "false",
        "42",
        "\"arbitrary\"",
        "{}",
        "{\"command\":\"reserve_seats\",\"event_id\":\"00000000-0000-" ++
            "0000-0000-000000000002\",\"class\":\"general\",\"quantity\":" ++
            "0}",
        "{\"command\":\"create_event\",\"classes\":{\"general\":1},\"" ++
            "timeout_seconds\":0}",
        "{\"command\":\"check_seats\",\"event_id\":\"bad\"}",
    };
    for (invalid) |body| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var effects = try Effects.init(allocator);
        // Schema errors win even when Event reads would fail.
        effects.read_error = error.TransientRead;
        const rejection = try submitted_rejection(allocator, &effects, body);
        effects.read_error = null;
        const message = try messages.decode(allocator, rejection);
        try std.testing.expectEqualStrings(
            "invalid_request",
            message.body.object.get("code").?.string,
        );
        _ = try completion.handle_invocation(
            allocator,
            try sqs_event(allocator, rejection),
            &.{ .operations_table = "Operations", .now = 1001 },
            &effects,
        );
        const visible = try query.test_support.query_with_backend(
            allocator,
            1,
            "theatre",
            &effects,
        );
        try std.testing.expect(std.mem.indexOf(u8, visible, "invalid_request") != null);
        try std.testing.expectEqual(seat.EventState.creating, effects.event.?.state);
        try std.testing.expectEqual(@as(usize, 2), effects.sent.items.len);
    }
}

test "Event ownership precedes readiness and class disclosure and transient reads retry" {
    for ([_]u8{ 0, 1, 2, 3, 4, 5 }) |scenario| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var effects = try Effects.init(allocator);
        switch (scenario) {
            0 => effects.event = null,
            1 => effects.event.?.tenant = "foreign",
            2 => effects.event.?.state = .creating,
            3 => effects.event.?.state = .failed,
            4 => effects.event.?.state = .ready,
            5 => effects.read_error = error.TransientRead,
            else => unreachable,
        }
        const source = try messages.encode(allocator, &.{
            .operation_id = 1,
            .tenant = "theatre",
            .context = .null,
            .body = try seat.parse_value(allocator, "{\"command\":\"reserve_seats\",\"event_id\":\"00000000-0000-" ++
                "0000-0000-000000000002\",\"class\":\"nonexistent\",\"quantit" ++
                "y\":1}", 4096),
        });
        const response = try submission.handle_invocation(
            allocator,
            try sqs_event(allocator, source),
            &.{ .events_table = "Events", .completion_queue = "seat-completion" },
            &effects,
        );
        if (scenario == 5) {
            try std.testing.expect(std.mem.indexOf(u8, response, "source-1") != null);
            try std.testing.expectEqual(@as(usize, 0), effects.sent.items.len);
        } else {
            try std.testing.expectEqualStrings(ack, response);
            const message = try messages.decode(allocator, effects.sent.items[0].body);
            const expected = [_][]const u8{
                "event_unavailable", "event_unavailable", "event_not_ready", "event_failed", "unknown_class",
            };
            try std.testing.expectEqualStrings(
                expected[scenario],
                message.body.object.get("code").?.string,
            );
        }
        try std.testing.expectEqual(@as(usize, 0), effects.updates);
    }
}

const reserve_body = "{\"command\":\"reserve_seats\",\"event_id\":\"00000000-0000-" ++
    "0000-0000-000000000002\",\"class\":\"general\",\"quantity\":" ++
    "2}";

test "uncertain publication and finalization survive invocation restarts" {
    var store = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer store.deinit();
    const allocator = store.allocator();
    var effects = try Effects.init(allocator);
    _ = try intake.test_support.submit(allocator, &.{
        .input = request,
        .subject = "theatre",
        .operation_name = "SeatReservation",
    }, &effects);
    const source = effects.sent.items[0].body;
    effects.send_before_error = true;
    effects.send_error = error.SendResponseLost;
    {
        var invocation = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer invocation.deinit();
        const arena = invocation.allocator();
        const response = try submission.handle_invocation(
            arena,
            try sqs_event(arena, source),
            &.{ .events_table = "Events", .completion_queue = "seat-completion" },
            &effects,
        );
        try std.testing.expect(std.mem.indexOf(u8, response, "source-1") != null);
    }
    effects.send_error = null;
    _ = try submission.handle_invocation(
        allocator,
        try sqs_event(allocator, source),
        &.{ .events_table = "Events", .completion_queue = "seat-completion" },
        &effects,
    );
    try std.testing.expectEqual(@as(usize, 3), effects.sent.items.len);
    try std.testing.expectEqualStrings(effects.sent.items[1].body, effects.sent.items[2].body);
    effects.write_error = error.WriteResponseLost;
    effects.commit_before_error = true;
    effects.read_error = error.ReadUncertain;
    {
        var invocation = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer invocation.deinit();
        const arena = invocation.allocator();
        const response = try completion.handle_invocation(
            arena,
            try sqs_event(arena, effects.sent.items[1].body),
            &.{ .operations_table = "Operations", .now = 1001 },
            &effects,
        );
        try std.testing.expect(std.mem.indexOf(u8, response, "source-1") != null);
    }
    effects.read_error = null;
    effects.write_error = null;
    const response = try completion.handle_invocation(
        allocator,
        try sqs_event(allocator, effects.sent.items[2].body),
        &.{ .operations_table = "Operations", .now = 1002 },
        &effects,
    );
    try std.testing.expectEqualStrings(ack, response);
    const saved = try effects.read(allocator, 1);
    try std.testing.expectEqual(@as(?i64, 1001), saved.last_updated);
    const visible = try query.test_support.query_with_backend(allocator, 1, "theatre", &effects);
    try std.testing.expect(std.mem.indexOf(u8, visible, "event_not_ready") != null);
}

test "unproven condition conflicts and transient writes remain retryable" {
    for ([_]anyerror{ error.ConditionConflict, error.TransientWrite }) |failure| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var effects = try Effects.init(allocator);
        const rejection = try submitted_rejection(allocator, &effects, reserve_body);
        effects.write_error = failure;
        const response = try completion.handle_invocation(
            allocator,
            try sqs_event(allocator, rejection),
            &.{ .operations_table = "Operations", .now = 1001 },
            &effects,
        );
        try std.testing.expect(std.mem.indexOf(u8, response, "source-1") != null);
        const saved = try effects.read(allocator, 1);
        try std.testing.expectEqual(operation.StateTag.submitted, operation.stateTag(&saved.state));
        try std.testing.expectEqual(@as(?i64, 1000), saved.last_updated);
    }
}

test "valid readback acknowledges lost writes and preserves a different winner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var effects = try Effects.init(allocator);
    const rejection = try submitted_rejection(allocator, &effects, reserve_body);
    effects.write_error = error.WriteResponseLost;
    effects.commit_before_error = true;
    const response = try completion.handle_invocation(
        allocator,
        try sqs_event(allocator, rejection),
        &.{ .operations_table = "Operations", .now = 1001 },
        &effects,
    );
    try std.testing.expectEqualStrings(ack, response);
    effects.write_error = null;
    var duplicate = try messages.decode(allocator, rejection);
    duplicate.body = try seat.parse_value(allocator, "{\"code\":\"invalid_request\"}", 4096);
    const output = try messages.encode(allocator, &duplicate);
    try std.testing.expectEqualStrings(
        ack,
        try completion.handle_invocation(
            allocator,
            try sqs_event(allocator, output),
            &.{ .operations_table = "Operations", .now = 1002 },
            &effects,
        ),
    );
    const saved = try effects.read(allocator, 1);
    try std.testing.expectEqualStrings(
        "event_not_ready",
        saved.state.completed.failure.object.get("code").?.string,
    );
    try std.testing.expectEqual(@as(?i64, 1001), saved.last_updated);
}

test "response encoding failure after publication or commit leaves replay protected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var effects = try Effects.init(allocator);
    const rejection = try submitted_rejection(allocator, &effects, reserve_body);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, submission.handle_invocation(allocator, try sqs_event(
        allocator,
        effects.sent.items[0].body,
    ), &.{
        .events_table = "Events",
        .completion_queue = "seat-completion",
        .response_allocator = failing.allocator(),
    }, &effects));
    try std.testing.expectEqual(@as(usize, 3), effects.sent.items.len);
    try std.testing.expectError(error.OutOfMemory, completion.handle_invocation(allocator, try sqs_event(
        allocator,
        rejection,
    ), &.{
        .operations_table = "Operations",
        .now = 1001,
        .response_allocator = failing.allocator(),
    }, &effects));
    try std.testing.expectEqualStrings(
        ack,
        try completion.handle_invocation(
            allocator,
            try sqs_event(allocator, rejection),
            &.{ .operations_table = "Operations", .now = 1002 },
            &effects,
        ),
    );
    const saved = try effects.read(allocator, 1);
    try std.testing.expectEqual(@as(?i64, 1001), saved.last_updated);
}

test "malformed envelopes and route overrides diagnose without effects" {
    const prefix = "{\"operation_id\":\"" ++ uuid ++ "\",\"tenant\":\"theatre\",";
    const invalid = [_][]const u8{
        "not-json",
        "{}",
        "[]",
        prefix ++ "\"body\":{}}",
        prefix ++ "\"body\":{},\"context\":null,\"extra\":1}",
        prefix ++ "\"body\":{},\"context\":null,\"result_queue\":\"override\"}",
        prefix ++ "\"body\":{},\"context\":null,\"tenant\":\"duplicate\"}",
        prefix ++ "\"body\":{},\"context\":null,\"operation_id\":\"invalid\"}",
    };
    for (invalid) |body| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var effects = try Effects.init(allocator);
        const input = try sqs_event(allocator, body);
        try std.testing.expectEqualStrings(
            ack,
            try submission.handle_invocation(
                allocator,
                input,
                &.{ .events_table = "Events", .completion_queue = "seat-completion" },
                &effects,
            ),
        );
        try std.testing.expectEqualStrings(
            ack,
            try completion.handle_invocation(
                allocator,
                input,
                &.{ .operations_table = "Operations", .now = 1001 },
                &effects,
            ),
        );
        try std.testing.expectEqual(@as(usize, 0), effects.sent.items.len);
        try std.testing.expectEqual(@as(usize, 0), effects.updates);
        try std.testing.expectEqual(@as(usize, 2), effects.diagnostics.items.len);
        for (effects.diagnostics.items) |diagnostic| {
            try std.testing.expect(diagnostic.len <= 8192);
            const parsed = try seat.parse_value(allocator, diagnostic, 8192);
            try std.testing.expectEqualStrings("ERROR", parsed.object.get("level").?.string);
            try std.testing.expectEqualStrings("source-1", parsed.object.get("sqs_id").?.string);
            try std.testing.expectEqual(
                @as(i64, @intCast(body.len)),
                parsed.object.get("body_length").?.integer,
            );
            try std.testing.expect(!parsed.object.get("truncated").?.bool);
        }
    }
}

test "mixed local native and unknown failure Bodies are not public business rejections" {
    const invalid = [_][]const u8{
        "{\"code\":\"event_failed\",\"create_accounts\":[],\"create_t" ++
            "ransfers\":[],\"lookup_accounts\":[]}",
        "{\"create_accounts\":[],\"create_transfers\":[],\"lookup_accounts\":[]}",
        "{\"code\":\"unknown\"}",
        "{\"code\":\"insufficient_seats\"}",
        "null",
    };
    for (invalid) |body| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var effects = try Effects.init(allocator);
        const source = try messages.encode(allocator, &.{
            .operation_id = 1,
            .tenant = "theatre",
            .context = .null,
            .body = try seat.parse_value(allocator, body, 4096),
        });
        try std.testing.expectEqualStrings(
            ack,
            try completion.handle_invocation(
                allocator,
                try sqs_event(allocator, source),
                &.{ .operations_table = "Operations", .now = 1001 },
                &effects,
            ),
        );
        try std.testing.expectEqual(@as(usize, 0), effects.updates);
        try std.testing.expectEqual(@as(usize, 1), effects.diagnostics.items.len);
    }
}

test "diagnostics escape bytes and truncate without requiring log delivery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var effects = try Effects.init(allocator);
    const large = try allocator.alloc(u8, messages.encoded_size_max + 1);
    @memset(large, '\n');
    @memcpy(large[0..6], "\"\\\x00\xff\n\r");
    submission.diagnose(
        allocator,
        .submission,
        "MalformedEnvelope",
        "source-1",
        large,
        null,
        &effects,
    );
    const diagnostic = effects.diagnostics.items[0];
    try std.testing.expect(diagnostic.len <= 8192);
    const parsed = try seat.parse_value(allocator, diagnostic, 8192);
    try std.testing.expect(parsed.object.get("truncated").?.bool);
    try std.testing.expectEqual(
        @as(i64, @intCast(large.len)),
        parsed.object.get("body_length").?.integer,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, parsed.object.get("preview").?.string, "\\xff") != null,
    );
    effects.log_error = true;
    try std.testing.expectEqualStrings(
        ack,
        try completion.handle_invocation(
            allocator,
            try sqs_event(allocator, "bad-envelope"),
            &.{ .operations_table = "Operations", .now = 1001 },
            &effects,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), effects.updates);
}

test "conflicting identity and malformed terminal readback diagnose without mutation" {
    for ([_][]const u8{ "tenant", "name", "id", "state" }) |field_name| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var effects = try Effects.init(allocator);
        const rejection = try submitted_rejection(allocator, &effects, reserve_body);
        const item = try allocator.dupe(events.Attribute, effects.operation_item.?);
        for (item) |*field| {
            if (!std.mem.eql(u8, field.key, field_name)) continue;
            const value: []const u8 = if (std.mem.eql(
                u8,
                field_name,
                "state",
            )) "COMPLETED" else if (std.mem.eql(
                u8,
                field_name,
                "id",
            )) "00000000-0000-0000-0000-000000000099" else "foreign";
            field.value = .{ .s = value };
        }
        effects.operation_item = item;
        const response = try completion.handle_invocation(
            allocator,
            try sqs_event(allocator, rejection),
            &.{ .operations_table = "Operations", .now = 1001 },
            &effects,
        );
        try std.testing.expectEqualStrings(ack, response);
        try std.testing.expectEqual(@as(usize, 1), effects.diagnostics.items.len);
        try std.testing.expectEqualDeep(item, effects.operation_item.?);
    }
}

test "seat invocation adapters reject empty and multiple SQS records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var effects = try Effects.init(allocator);
    const empty = "{\"Records\":[]}";
    try std.testing.expectError(
        error.EmptySQSEvent,
        submission.handle_invocation(
            allocator,
            empty,
            &.{ .events_table = "Events", .completion_queue = "seat-completion" },
            &effects,
        ),
    );
    try std.testing.expectError(
        error.EmptySQSEvent,
        completion.handle_invocation(
            allocator,
            empty,
            &.{ .operations_table = "Operations", .now = 1001 },
            &effects,
        ),
    );
    const single = try seat.parse_value(allocator, try sqs_event(allocator, "{}"), 4096);
    const record = single.object.get("Records").?.array.items[0];
    const multiple = try std.json.Stringify.valueAlloc(
        allocator,
        .{ .Records = &.{ record, record } },
        .{},
    );
    try std.testing.expectError(
        error.TooManyRecords,
        submission.handle_invocation(
            allocator,
            multiple,
            &.{ .events_table = "Events", .completion_queue = "seat-completion" },
            &effects,
        ),
    );
    try std.testing.expectError(
        error.TooManyRecords,
        completion.handle_invocation(
            allocator,
            multiple,
            &.{ .operations_table = "Operations", .now = 1001 },
            &effects,
        ),
    );
}
