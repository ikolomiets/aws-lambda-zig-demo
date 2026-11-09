//! Seat test effects and runtime observations outlive invocation arena resets.
const std = @import("std");
const dynamodb = @import("dynamodb");
const operation = @import("operation");
const operations = @import("operation_persistence");
const messages = @import("processor_message");
const seat = @import("seat_reservation");
const events = @import("seat_reservation_persistence");
const logging = @import("outcome_log");
const runtime = @import("runtime_test_support");
const Allocator = std.mem.Allocator;
const capacity = 8;
pub const sqs_event = runtime.sqs_event;
pub const RuntimeEvent = runtime.Tester.Event;
pub const Phase = enum { submission, completion };

pub const EffectCounts = struct {
    event_reads: usize = 0,
    operation_reads: usize = 0,
    generated: usize = 0,
    send_attempts: usize = 0,
    published: usize = 0,
    update_attempts: usize = 0,
    completed: usize = 0,
    report_attempts: usize = 0,
    reports: usize = 0,
    allocations: usize = 0,
    insertions: usize = 0,
    transaction_writes: usize = 0,
    transaction_reads: usize = 0,
};

pub const Backend = struct {
    allocator: Allocator,
    event: seat.Event,
    effects: EffectCounts = .{},
    outputs: [capacity]struct { queue: []const u8, body: []const u8 } = undefined,
    writes: [capacity]struct {
        id: []const u8,
        tenant: []const u8,
        result: []const u8,
        now: operation.UnixSeconds,
    } = undefined,
    diagnostics: [capacity][]const u8 = undefined,
    operation_item: ?[]const events.Attribute = null,
    operation_id: u128 = 1,
    read_error: ?anyerror = null,
    fail_next_send: ?anyerror = null,
    fail_next_update: ?anyerror = null,
    transactions: ?struct {
        responses: []const dynamodb.types.ItemResponse,
        fail_next_write: ?anyerror = null,
        read_error: ?anyerror = null,
    } = null,

    pub fn expect_effects(self: *const Backend, expected: EffectCounts) !void {
        // Defaults check negative space: every unspecified effect must remain zero.
        try std.testing.expectEqualDeep(expected, self.effects);
    }

    pub fn get(
        self: *Backend,
        arena: Allocator,
        request: dynamodb.GetItemInput,
    ) !?[]const events.Attribute {
        try std.testing.expectEqual(true, request.consistent_read.?);
        if (std.mem.eql(u8, request.table_name, "Operations")) {
            const expected = try operations.read_request(arena, "Operations", self.operation_id);
            try std.testing.expectEqualDeep(expected.key, request.key);
            self.effects.operation_reads += 1;
            if (self.read_error) |err| return err;
            return self.operation_item;
        }
        try std.testing.expectEqualStrings("Events", request.table_name);
        const expected = try events.read_request(arena, "Events", &.{
            .tenant = self.event.tenant,
            .event_id = self.event.event_id,
        });
        try std.testing.expectEqualDeep(expected.key, request.key);
        self.effects.event_reads += 1;
        if (self.read_error) |err| return err;
        return try events.encode_item(arena, &self.event);
    }

    pub fn generate_id(self: *Backend) !u128 {
        std.debug.assert(self.effects.generated < capacity);
        self.effects.generated += 1;
        return 123 + self.effects.generated;
    }

    pub fn send(self: *Backend, _: Allocator, queue: []const u8, body: []const u8) !void {
        std.debug.assert(self.effects.send_attempts < capacity);
        self.effects.send_attempts += 1;
        if (self.fail_next_send) |err| {
            self.fail_next_send = null;
            return err;
        }
        std.debug.assert(self.effects.published < self.outputs.len);
        self.outputs[self.effects.published] = .{
            .queue = try self.allocator.dupe(u8, queue),
            .body = try self.allocator.dupe(u8, body),
        };
        self.effects.published += 1;
    }

    pub fn update(self: *Backend, _: Allocator, request: dynamodb.types.Update) !void {
        std.debug.assert(self.effects.update_attempts < capacity);
        self.effects.update_attempts += 1;
        try std.testing.expectEqualStrings("Operations", request.table_name);
        if (self.fail_next_update) |err| {
            self.fail_next_update = null;
            return err;
        }
        std.debug.assert(self.effects.completed < self.writes.len);
        const values = request.expression_attribute_values.?;
        self.writes[self.effects.completed] = .{
            .id = try self.allocator.dupe(u8, try attribute_text(request.key, "id")),
            .tenant = try self.allocator.dupe(u8, try attribute_text(values, ":tenant")),
            .result = try self.allocator.dupe(u8, try attribute_text(values, ":result")),
            .now = try std.fmt.parseInt(i64, try attribute_text(values, ":now"), 10),
        };
        self.effects.completed += 1;
    }

    pub fn report(self: *Backend, diagnostic: []const u8) !void {
        std.debug.assert(self.effects.report_attempts < capacity);
        self.effects.report_attempts += 1;
        std.debug.assert(self.effects.reports < self.diagnostics.len);
        self.diagnostics[self.effects.reports] = try self.allocator.dupe(u8, diagnostic);
        self.effects.reports += 1;
    }

    pub fn allocate(self: *Backend, _: Allocator) !u32 {
        self.effects.allocations += 1;
        return error.UnexpectedEffect;
    }

    pub fn put(self: *Backend, _: Allocator, _: dynamodb.PutItemInput) !void {
        self.effects.insertions += 1;
        return error.UnexpectedEffect;
    }

    pub fn transact_write(self: *Backend, _: Allocator, _: dynamodb.TransactWriteItemsInput) !void {
        self.effects.transaction_writes += 1;
        const transaction = self.transactions orelse return error.UnexpectedEffect;
        if (transaction.fail_next_write) |err| {
            self.transactions.?.fail_next_write = null;
            return err;
        }
    }

    pub fn transact_get(
        self: *Backend,
        _: Allocator,
        _: dynamodb.TransactGetItemsInput,
    ) !dynamodb.TransactGetItemsOutput {
        self.effects.transaction_reads += 1;
        const transaction = self.transactions orelse return error.UnexpectedEffect;
        if (transaction.read_error) |err| return err;
        return .{ .responses = transaction.responses };
    }
};

fn attribute_text(attributes: []const events.Attribute, name: []const u8) ![]const u8 {
    for (attributes) |attribute| {
        if (std.mem.eql(u8, attribute.key, name)) {
            return switch (attribute.value) {
                .s, .n => |text| text orelse error.MissingTestValue,
                else => error.UnexpectedTestValue,
            };
        }
    }
    return error.MissingTestAttribute;
}

pub fn ready_event(arena: Allocator) !seat.Event {
    return seat.decode_event(arena,
        \\{"tenant":"tenant-a","event_id":"00000000-0000-0000-0000-000000000001",
        \\"ledger":1001,"timeout_seconds":30,"capacity_account_id":"1",
        \\"allocation_account_id":"2","state":"ready",
        \\"classes":{"a":{"total":10,"tb_account_id":"3"},"b":{"total":5,"tb_account_id":"4"}}}
    );
}

pub fn stored_operation(arena: Allocator, result_json: ?[]const u8) ![]const events.Attribute {
    const pending = try operation.parseInputJSON(arena,
        \\{"id":"00000000-0000-0000-0000-000000000001","name":"SeatReservation","body":null}
    , .{ .tenant = "tenant-a", .now = 1 });
    const request = try operations.create_request(arena, "Operations", &pending);
    if (result_json == null) return request.item;
    const items = try arena.alloc(events.Attribute, request.item.len + 1);
    @memcpy(items[0..request.item.len], request.item);
    for (items[0..request.item.len]) |*attribute| {
        if (std.mem.eql(u8, attribute.key, "state")) attribute.value = .{ .s = "COMPLETED" };
    }
    items[request.item.len] = .{ .key = "result", .value = .{ .s = result_json.? } };
    return items;
}

pub fn submission_message(arena: Allocator, id: u128, body: []const u8) ![]const u8 {
    return messages.encode(arena, &.{
        .operation_id = id,
        .tenant = "tenant-a",
        .body = try seat.parse_value(arena, body, messages.body_size_max),
        .context = .null,
    });
}

pub fn completion_message(arena: Allocator, id: u128) ![]const u8 {
    const command: seat.Command = .{ .confirm_seats = .{ .event_id = 1, .pending_id = 123 } };
    return messages.encode(arena, &.{
        .operation_id = id,
        .tenant = "tenant-a",
        .body = try seat.parse_value(arena,
            \\{"create_accounts":[],"create_transfers":[{"alias":"confirm","error_code":"created"}],
            \\"lookup_accounts":[]}
        , messages.body_size_max),
        .context = try seat.parse_value(
            arena,
            try seat.encode_context(arena, &command, null),
            messages.context_size_max,
        ),
    });
}

pub const RuntimeFixture = struct {
    seen: runtime.Observations = .{},
    cache: events.ReadyCache,
    observer: logging.TestObserver,
    backend: Backend,
    tester: runtime.Tester = undefined,
    tester_initialized: bool = false,

    pub fn init(self: *RuntimeFixture) !void {
        self.* = .{ .cache = undefined, .observer = undefined, .backend = undefined };
        errdefer self.seen.deinit();
        const arena = self.seen.arena.allocator();
        self.backend = .{ .allocator = arena, .event = try ready_event(arena) };
        self.observer = .init(arena);
        try self.cache.init(std.testing.allocator, events.ReadyCache.budget_bytes_max);
    }

    pub fn deinit(self: *RuntimeFixture) void {
        if (self.tester_initialized) self.tester.deinit();
        self.cache.deinit();
        self.seen.deinit();
        self.* = undefined;
    }

    pub fn run(
        self: *RuntimeFixture,
        script: []const RuntimeEvent,
        comptime handler: anytype,
    ) !void {
        std.debug.assert(!self.tester_initialized);
        try self.tester.init(std.testing.allocator, script);
        self.tester_initialized = true;
        const before = std.Io.Clock.real.now(std.testing.io).toSeconds();
        runtime.run(&self.tester, &self.seen, .{}, handler);
        const after = std.Io.Clock.real.now(std.testing.io).toSeconds();
        try runtime.expect_protocol(&self.tester, &self.seen);
        try std.testing.expectEqual(script.len, self.observer.records.items.len);
        for (script, self.observer.records.items) |event, record| {
            try std.testing.expectEqualStrings(event.request_id, record.lambda_request_id.?);
        }
        for (self.backend.writes[0..self.backend.effects.completed]) |write| {
            try std.testing.expect(write.now >= before);
            try std.testing.expect(write.now <= after);
        }
    }

    fn input(self: *RuntimeFixture, phase: Phase, id: u128) ![]const u8 {
        const arena = self.backend.allocator;
        const message = switch (phase) {
            .submission => try submission_message(arena, id,
                \\{"command":"confirm_seats","event_id":"00000000-0000-0000-0000-000000000001",
                \\"pending_id":"123"}
            ),
            .completion => try completion_message(arena, id),
        };
        return sqs_event(arena, "seat-message", message);
    }

    pub fn warm_events(self: *RuntimeFixture, phase: Phase) ![3]RuntimeEvent {
        var script: [3]RuntimeEvent = undefined;
        const arena = self.backend.allocator;
        for (&script, 0..) |*event, index| {
            event.* = .{
                .request_id = try std.fmt.allocPrint(arena, "seat-{s}-{d}", .{
                    @tagName(phase), index,
                }),
                .payload = try self.input(phase, index + 1),
                .invocation_id = if (index == 1) "" else try std.fmt.allocPrint(
                    arena,
                    "attempt-{d}",
                    .{index},
                ),
                .xray_trace = if (index == 2) "" else try std.fmt.allocPrint(
                    arena,
                    "trace-{d}",
                    .{index},
                ),
                .invoked_arn = try std.fmt.allocPrint(arena, "seat-function-{s}-{d}", .{
                    @tagName(phase), index,
                }),
                .deadline_ms = 1001 + @as(u64, @intCast(index)),
            };
        }
        return script;
    }

    pub fn retry_events(self: *RuntimeFixture, phase: Phase) ![2]RuntimeEvent {
        const payload = try self.input(phase, 1);
        return .{
            .{ .request_id = "seat-effect-failed", .payload = payload },
            .{ .request_id = "seat-effect-retry", .payload = payload },
        };
    }

    pub fn recovery_events(self: *RuntimeFixture, phase: Phase) ![2]RuntimeEvent {
        return .{
            .{ .request_id = "seat-bad", .payload = "{" },
            .{ .request_id = "seat-good", .payload = try self.input(phase, 1) },
        };
    }

    fn expect_path(self: *RuntimeFixture, index: usize, suffix: []const u8) !void {
        const path = try std.fmt.allocPrint(
            self.backend.allocator,
            "/2018-06-01/runtime/invocation/{s}/{s}",
            .{ self.tester.script[index].request_id, suffix },
        );
        try self.tester.expectPath(index, path);
    }

    pub fn expect_response(self: *RuntimeFixture, index: usize, body: []const u8) !void {
        try self.expect_path(index, "response");
        try self.tester.expectBody(index, body);
    }

    pub fn expect_warm(self: *RuntimeFixture) !void {
        try std.testing.expectEqual(@as(usize, 1), self.cache.count);
        for (0..3) |index| try self.expect_response(index, "{\"batchItemFailures\":[]}");
    }

    pub fn expect_retry(self: *RuntimeFixture, outcome: []const u8) !void {
        try self.expect_response(
            0,
            "{\"batchItemFailures\":[{\"itemIdentifier\":\"seat-message\"}]}",
        );
        try self.expect_response(1, "{\"batchItemFailures\":[]}");
        try std.testing.expectEqualStrings("retry", self.observer.records.items[0].outcome);
        try std.testing.expectEqualStrings(outcome, self.observer.records.items[1].outcome);
    }

    pub fn expect_recovery(self: *RuntimeFixture) !void {
        try self.expect_path(0, "error");
        const failure = try self.tester.post(0);
        const error_type = "Handler.UnexpectedEndOfInput";
        try std.testing.expectEqualStrings(
            error_type,
            failure.header("Lambda-Runtime-Function-Error-Type").?,
        );
        const report = try std.json.parseFromSliceLeaky(
            std.json.Value,
            self.backend.allocator,
            failure.body,
            .{},
        );
        try std.testing.expectEqualStrings(error_type, report.object.get("errorType").?.string);
        try self.expect_response(1, "{\"batchItemFailures\":[]}");
    }
};
