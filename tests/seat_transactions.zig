const std = @import("std");
const aws = @import("aws");
const dynamodb = @import("dynamodb");
const operation = @import("operation");
const operations = @import("operation_persistence");
const seat = @import("seat_reservation");
const events = @import("seat_reservation_persistence");
const Allocator = std.mem.Allocator;

const Pair = struct { event: seat.Event, operation: operation.Operation };
const Harness = struct {
    arena: std.heap.ArenaAllocator,
    environment: std.process.Environ.Map,
    config: aws.Config,
    client: dynamodb.Client,
    events_table: []const u8,
    operations_table: []const u8,
    event: seat.Event,
    submitted: operation.Operation,

    fn init(self: *Harness, name: []const u8) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        const endpoint = std.mem.span(std.c.getenv("SEAT_TRANSACTION_ENDPOINT") orelse
            return error.MissingLocalEndpoint);
        const prefix = "http://127.0.0.1:";
        if (!std.mem.startsWith(u8, endpoint, prefix)) return error.InvalidLocalEndpoint;
        if (try std.fmt.parseInt(u16, endpoint[prefix.len..], 10) == 0) {
            return error.InvalidLocalEndpoint;
        }
        self.environment = std.process.Environ.Map.init(std.testing.allocator);
        errdefer self.environment.deinit();
        self.config = try aws.Config.load(std.testing.allocator, std.testing.io, &self.environment, .{
            .region = "ca-central-1",
            .endpoint_url = endpoint,
            .max_attempts = 1,
            .credentials = .{
                .static = .{ .access_key_id = "local", .secret_access_key = "local" },
            },
        });
        errdefer self.config.deinit();
        self.client = dynamodb.Client.initWithOptions(std.testing.allocator, &self.config, .{
            .max_attempts = 1,
            .max_response_size = 128 * 1024,
        });
        errdefer self.client.deinit();
        self.events_table = try std.fmt.allocPrint(arena, "Events{s}", .{name});
        self.operations_table = try std.fmt.allocPrint(arena, "Operations{s}", .{name});
        try self.create_tables();
        self.event = .{
            .tenant = "theatre",
            .event_id = 1,
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
        };
        self.submitted = try operation.parseInputJSON(arena, "{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"" ++
            "SeatReservation\",\"body\":{}}", .{ .tenant = "theatre", .now = 1000 });
        _ = try self.client.putItem(
            arena,
            try events.create_request(arena, self.events_table, &self.event),
            .{},
        );
        _ = try self.client.putItem(
            arena,
            try operations.create_request(arena, self.operations_table, &self.submitted),
            .{},
        );
    }

    fn deinit(self: *Harness) void {
        self.client.deinit();
        self.config.deinit();
        self.environment.deinit();
        self.arena.deinit();
    }

    fn create_tables(self: *Harness) !void {
        const arena = self.arena.allocator();
        _ = try self.client.createTable(arena, .{
            .table_name = self.events_table,
            .billing_mode = .pay_per_request,
            .attribute_definitions = &.{
                .{ .attribute_name = "tenant", .attribute_type = .s },
                .{ .attribute_name = "event_id", .attribute_type = .s },
            },
            .key_schema = &.{
                .{ .attribute_name = "tenant", .key_type = .hash },
                .{ .attribute_name = "event_id", .key_type = .range },
            },
        }, .{});
        _ = try self.client.createTable(arena, .{
            .table_name = self.operations_table,
            .billing_mode = .pay_per_request,
            .attribute_definitions = &.{.{ .attribute_name = "id", .attribute_type = .s }},
            .key_schema = &.{.{ .attribute_name = "id", .key_type = .hash }},
        }, .{});
    }

    fn actions(
        self: *Harness,
        arena: Allocator,
        source: *const seat.Event,
        tenant: []const u8,
        terminal: seat.EventState,
        result: *const operation.Completion,
    ) ![2]dynamodb.types.TransactWriteItem {
        return .{
            .{
                .update = try events.finalization_update(
                    arena,
                    self.events_table,
                    source,
                    terminal,
                ),
            },
            .{
                .update = try operations.seat_completion_update(
                    arena,
                    self.operations_table,
                    &.{ .id = 1, .tenant = tenant },
                    result,
                    1001,
                ),
            },
        };
    }

    fn read_pair(self: *Harness) !Pair {
        const arena = self.arena.allocator();
        const event_read = try events.read_request(
            arena,
            self.events_table,
            &.{ .tenant = "theatre", .event_id = 1 },
        );
        const operation_key = &.{
            operations_attribute("id", .{ .s = "00000000-0000-0000-0000-000000000001" }),
        };
        const response = try self.client.transactGetItems(arena, .{ .transact_items = &.{
            .{ .get = .{ .table_name = self.events_table, .key = event_read.key } },
            .{ .get = .{ .table_name = self.operations_table, .key = operation_key } },
        } }, .{});
        return decode_pair(arena, response);
    }
};

fn operations_attribute(key: []const u8, value: dynamodb.types.AttributeValue) events.Attribute {
    return .{ .key = key, .value = value };
}

fn decode_pair(arena: Allocator, response: dynamodb.TransactGetItemsOutput) !Pair {
    const records = response.responses orelse return error.MissingReadback;
    if (records.len != 2) return error.InvalidReadback;
    return .{
        .event = try events.decode_item(arena, records[0].item orelse return error.MissingEvent),
        .operation = try operations.decode_item(
            arena,
            records[1].item orelse return error.MissingOperation,
        ),
    };
}

fn success(arena: Allocator) !operation.Completion {
    return operation.parseCompletionJSON(arena, "{\"type\":\"SUCCESS\",\"payload\":{\"event_id\":\"00000000-0" ++
        "000-0000-0000-000000000001\"}}");
}

fn expect_unchanged(harness: *Harness) !void {
    const pair = try harness.read_pair();
    try std.testing.expectEqual(seat.EventState.creating, pair.event.state);
    try std.testing.expectEqual(
        operation.StateTag.submitted,
        operation.stateTag(&pair.operation.state),
    );
    try std.testing.expectEqual(@as(?i64, 1000), pair.operation.last_updated);
    try std.testing.expectEqual(@as(?i64, 87400), pair.operation.expires_at);
}

test "SDK transaction commits Event readiness and Operation Result together" {
    var harness: Harness = undefined;
    try harness.init("Commit");
    defer harness.deinit();
    const arena = harness.arena.allocator();
    const result = try success(arena);
    const actions = try harness.actions(arena, &harness.event, "theatre", .ready, &result);
    _ = try harness.client.transactWriteItems(arena, .{ .transact_items = &actions }, .{});
    const pair = try harness.read_pair();
    try std.testing.expectEqual(seat.EventState.ready, pair.event.state);
    try seat.validate_configuration(@as(*const seat.Event, &harness.event), &pair.event);
    try std.testing.expectEqualDeep(harness.submitted.hash, pair.operation.hash);
    try std.testing.expectEqualStrings("theatre", pair.operation.tenant);
    try std.testing.expectEqualStrings("SeatReservation", pair.operation.name);
    try std.testing.expectEqual(
        operation.StateTag.completed,
        operation.stateTag(&pair.operation.state),
    );
    try std.testing.expectEqual(@as(?i64, 1001), pair.operation.last_updated);
    try std.testing.expectEqual(@as(?i64, 87401), pair.operation.expires_at);
    const saved_result = try std.json.Stringify.valueAlloc(
        arena,
        pair.operation.state.completed,
        .{},
    );
    try std.testing.expectEqualStrings("{\"type\":\"SUCCESS\",\"payload\":{\"event_id\":\"00000000-0" ++
        "000-0000-0000-000000000001\"}}", saved_result);
}

// Diagnostics must outlive the temporary request and its HTTP response.
fn expect_cancellation(
    harness: *Harness,
    event: *const seat.Event,
    tenant: []const u8,
    failed_index: usize,
) !void {
    var diagnostic: dynamodb.ServiceError = undefined;
    {
        var request_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer request_arena.deinit();
        const arena = request_arena.allocator();
        const result = try success(arena);
        const actions = try harness.actions(arena, event, tenant, .ready, &result);
        try std.testing.expectError(
            error.ServiceError,
            harness.client.transactWriteItems(
                arena,
                .{ .transact_items = &actions },
                .{ .diagnostic = &diagnostic },
            ),
        );
    }
    defer diagnostic.deinit();
    try std.testing.expectEqual(
        .transaction_canceled_exception,
        std.meta.activeTag(diagnostic.kind),
    );
    const reasons = diagnostic.kind.transaction_canceled_exception.cancellation_reasons orelse
        return error.MissingCancellationReasons;
    try std.testing.expectEqual(@as(usize, 2), reasons.len);
    try std.testing.expectEqualStrings("ConditionalCheckFailed", reasons[failed_index].code.?);
    try std.testing.expectEqualStrings("None", reasons[1 - failed_index].code.?);
}

test "SDK Event condition cancellation leaves both records unchanged" {
    var harness: Harness = undefined;
    try harness.init("EventReject");
    defer harness.deinit();
    var mismatched = harness.event;
    mismatched.timeout_seconds = 61;
    try expect_cancellation(&harness, &mismatched, "theatre", 0);
    try expect_unchanged(&harness);
}

test "SDK Operation identity cancellation leaves Event and Operation unchanged" {
    var harness: Harness = undefined;
    try harness.init("OperationReject");
    defer harness.deinit();
    try expect_cancellation(&harness, &harness.event, "foreign", 1);
    try expect_unchanged(&harness);
}

test "SDK failed Event variant commits and replay preserves the terminal pair" {
    var harness: Harness = undefined;
    try harness.init("FailedReplay");
    defer harness.deinit();
    const arena = harness.arena.allocator();
    const failure = try operation.parseCompletionJSON(
        arena,
        "{\"type\":\"FAILURE\",\"payload\":{\"code\":\"operation_rejected\"}}",
    );
    const actions = try harness.actions(arena, &harness.event, "theatre", .failed, &failure);
    _ = try harness.client.transactWriteItems(arena, .{ .transact_items = &actions }, .{});
    var diagnostic: dynamodb.ServiceError = undefined;
    try std.testing.expectError(
        error.ServiceError,
        harness.client.transactWriteItems(
            arena,
            .{ .transact_items = &actions },
            .{ .diagnostic = &diagnostic },
        ),
    );
    defer diagnostic.deinit();
    try std.testing.expectEqual(
        .transaction_canceled_exception,
        std.meta.activeTag(diagnostic.kind),
    );
    const pair = try harness.read_pair();
    try std.testing.expectEqual(seat.EventState.failed, pair.event.state);
    const saved_result = try std.json.Stringify.valueAlloc(
        arena,
        pair.operation.state.completed,
        .{},
    );
    try std.testing.expectEqualStrings(
        "{\"type\":\"FAILURE\",\"payload\":{\"code\":\"operation_rejected\"}}",
        saved_result,
    );
    try std.testing.expectEqual(@as(?i64, 1001), pair.operation.last_updated);
}

test "simulated empty missing and malformed readbacks cannot prove a transaction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const empty = try aws.json.parseJsonObject(dynamodb.TransactGetItemsOutput, "{}", allocator);
    try std.testing.expectError(error.MissingReadback, decode_pair(allocator, empty));
    const missing = try aws.json.parseJsonObject(
        dynamodb.TransactGetItemsOutput,
        "{\"Responses\":[{},{}]}",
        allocator,
    );
    try std.testing.expectError(error.MissingEvent, decode_pair(allocator, missing));
    if (aws.json.parseJsonObject(dynamodb.TransactGetItemsOutput, "{", allocator)) |_| {
        return error.AcceptedMalformedResponse;
    } else |_| {}
}
