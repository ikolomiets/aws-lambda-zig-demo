const std = @import("std");
const aws = @import("aws");
const dynamodb = @import("dynamodb");
const seat = @import("seat_reservation");
const operation = @import("operation");
const operations = @import("operation_persistence");
const Allocator = std.mem.Allocator;
pub const ReadyCache = @import("seat_event_cache.zig").ReadyCache;
pub const Attribute = aws.map.MapEntry(dynamodb.types.AttributeValue);

const event_fields = [_][]const u8{
    "tenant",
    "event_id",
    "ledger",
    "timeout_seconds",
    "capacity_account_id",
    "allocation_account_id",
    "state",
    "classes",
};
pub const create_condition = "attribute_not_exists(#tenant) AND attribute_not_exists(#event_id)";

pub const FinalizationOptions = struct {
    events_table: []const u8,
    operations_table: []const u8,
    now: operation.UnixSeconds,
};

/// There is no separate-write fallback. An uncertain transaction requires one coherent pair.
pub fn finalize_creation(
    arena: Allocator,
    options: *const FinalizationOptions,
    saved: *const seat.Event,
    result: *const operation.Completion,
    backend: anytype,
) !void {
    if (saved.state == .creating) {
        const terminal: seat.EventState = if (result.* == .success) .ready else .failed;
        const actions = try arena.alloc(dynamodb.types.TransactWriteItem, 2);
        actions[0] = .{ .update = try finalization_update(
            arena,
            options.events_table,
            saved,
            terminal,
        ) };
        actions[1] = .{ .update = try operations.seat_completion_update(
            arena,
            options.operations_table,
            &.{ .id = saved.event_id, .tenant = saved.tenant },
            result,
            options.now,
        ) };
        if (backend.transact_write(arena, .{ .transact_items = actions })) |_| {
            return;
        } else |_| {}
    }
    const event_read = try read_request(arena, options.events_table, &.{
        .tenant = saved.tenant,
        .event_id = saved.event_id,
    });
    const operation_read = try operations.read_request(
        arena,
        options.operations_table,
        saved.event_id,
    );
    const response = try backend.transact_get(arena, .{ .transact_items = &.{
        .{ .get = .{ .table_name = event_read.table_name, .key = event_read.key } },
        .{ .get = .{ .table_name = operation_read.table_name, .key = operation_read.key } },
    } });
    const records = response.responses orelse return error.InconsistentCreation;
    if (records.len != 2) return error.InconsistentCreation;
    const event = try decode_item(arena, records[0].item orelse return error.InconsistentCreation);
    const winner = try operations.decode_item(
        arena,
        records[1].item orelse return error.InconsistentCreation,
    );
    try validate_creation_pair(saved, &event, &winner);
}

fn validate_creation_pair(
    expected: *const seat.Event,
    event: *const seat.Event,
    winner: *const operation.Operation,
) !void {
    if (event.event_id != expected.event_id) return error.InconsistentCreation;
    if (!std.mem.eql(u8, event.tenant, expected.tenant)) return error.InconsistentCreation;
    if (event.ledger != expected.ledger) return error.InconsistentCreation;
    if (event.capacity_account_id != expected.capacity_account_id) {
        return error.InconsistentCreation;
    }
    if (event.allocation_account_id != expected.allocation_account_id) {
        return error.InconsistentCreation;
    }
    seat.validate_configuration(expected, event) catch return error.InconsistentCreation;
    for (event.classes, expected.classes) |stored, original| {
        if (stored.tb_account_id != original.tb_account_id) return error.InconsistentCreation;
    }
    if (winner.id != expected.event_id) return error.InconsistentCreation;
    if (!std.mem.eql(u8, winner.tenant, expected.tenant)) return error.InconsistentCreation;
    if (!std.mem.eql(u8, winner.name, "SeatReservation")) return error.InconsistentCreation;
    switch (winner.state) {
        .submitted => {
            if (event.state == .creating) return error.RetryFinalization;
            return error.InconsistentCreation;
        },
        .completed => |*result| {
            seat.validate_completion(result) catch return error.InconsistentCreation;
            switch (result.*) {
                .success => |payload| {
                    if (event.state != .ready) return error.InconsistentCreation;
                    seat.exact_fields(&payload, &.{"event_id"}) catch
                        return error.InconsistentCreation;
                    const text = try seat.string_value(try seat.required(&payload, "event_id"));
                    const id = seat.canonical_uuid(text) catch
                        return error.InconsistentCreation;
                    if (id != event.event_id) return error.InconsistentCreation;
                },
                .failure => |payload| {
                    if (event.state != .failed) return error.InconsistentCreation;
                    const code = try seat.string_value(try seat.required(&payload, "code"));
                    if (!std.mem.eql(u8, code, "operation_rejected")) {
                        return error.InconsistentCreation;
                    }
                },
            }
        },
    }
}

/// Guard every immutable saved field. Each action owns its aliases and arena-backed values.
pub fn finalization_update(
    arena: Allocator,
    table: []const u8,
    source: *const seat.Event,
    terminal: seat.EventState,
) !dynamodb.types.Update {
    try validate_table_name(table);
    if (source.state != .creating) return error.InvalidCreationState;
    if (terminal == .creating) return error.InvalidTerminalState;
    const item = try encode_item(arena, source);
    const names = try arena.alloc(aws.map.StringMapEntry, event_fields.len);
    const values = try arena.alloc(Attribute, event_fields.len + 1);
    for (item, 0..) |attribute, index| {
        names[index] = .{
            .key = try std.fmt.allocPrint(arena, "#{s}", .{attribute.key}),
            .value = attribute.key,
        };
        values[index] = .{
            .key = try std.fmt.allocPrint(arena, ":{s}", .{attribute.key}),
            .value = attribute.value,
        };
    }
    values[item.len] = string_attribute(":terminal", @tagName(terminal));
    return .{
        .table_name = try arena.dupe(u8, table),
        .key = item[0..2],
        .expression_attribute_names = names,
        .expression_attribute_values = values,
        .condition_expression = "#tenant = :tenant AND #event_id = :event_id AND " ++
            "#ledger = :ledger AND #timeout_seconds = :timeout_seconds AND " ++
            "#capacity_account_id = :capacity_account_id AND " ++
            "#allocation_account_id = :allocation_account_id AND #classes = :classes AND " ++
            "#state = :state",
        .update_expression = "SET #state = :terminal",
        .return_values_on_condition_check_failure = .all_old,
    };
}

pub const Persistence = struct {
    client: dynamodb.Client,
    table_name: []const u8,

    pub fn init(
        target: *Persistence,
        allocator: Allocator,
        config: *aws.Config,
        environment: *const std.process.Environ.Map,
    ) !void {
        const table = environment.get("EVENTS_TABLE_NAME") orelse return error.InvalidConfiguration;
        try validate_table_name(table);
        target.* = .{ .client = dynamodb.Client.init(allocator, config), .table_name = table };
        std.debug.assert(target.client.config == config);
    }

    pub fn deinit(self: *Persistence) void {
        self.client.deinit();
        self.* = undefined;
    }

    pub fn create(self: *Persistence, arena: Allocator, source: *const seat.Event) !seat.Event {
        var backend: SDKBackend = .{ .client = &self.client };
        return insert(arena, self.table_name, source, &backend);
    }

    pub fn read(self: *Persistence, arena: Allocator, key: *const seat.EventKey) !seat.Event {
        var backend: SDKBackend = .{ .client = &self.client };
        return read_event(arena, self.table_name, key, &backend);
    }
};

const SDKBackend = struct {
    client: *dynamodb.Client,

    fn put(self: *SDKBackend, arena: Allocator, request: dynamodb.PutItemInput) !void {
        var diagnostic: dynamodb.ServiceError = undefined;
        _ = self.client.putItem(arena, request, .{ .diagnostic = &diagnostic }) catch |err| {
            if (err == error.ServiceError) {
                defer diagnostic.deinit();
                if (std.meta.activeTag(diagnostic.kind) == .conditional_check_failed_exception) {
                    return error.InsertConflict;
                }
            }
            return error.AWSFailure;
        };
    }

    fn get(
        self: *SDKBackend,
        arena: Allocator,
        request: dynamodb.GetItemInput,
    ) !?[]const Attribute {
        var diagnostic: dynamodb.ServiceError = undefined;
        const response = self.client.getItem(
            arena,
            request,
            .{ .diagnostic = &diagnostic },
        ) catch |err| {
            if (err == error.ServiceError) diagnostic.deinit();
            return error.AWSFailure;
        };
        return response.item;
    }
};

/// An unsuccessful put never authorizes dispatch. Only a validated saved winner does.
/// A missing winner after uncertainty requires a retry; no later read can guess a native effect.
pub fn insert(
    arena: Allocator,
    table: []const u8,
    source: *const seat.Event,
    backend: anytype,
) !seat.Event {
    const request = try create_request(arena, table, source);
    backend.put(arena, request) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const winner = read_event(arena, table, &.{
            .tenant = source.tenant,
            .event_id = source.event_id,
        }, backend) catch |read_error| {
            if (read_error == error.EventUnavailable) return error.InsertionUncertain;
            return read_error;
        };
        try seat.validate_configuration(source, &winner);
        return winner;
    };
    return decode_item(arena, request.item);
}

pub fn read_event(
    arena: Allocator,
    table: []const u8,
    key: *const seat.EventKey,
    backend: anytype,
) !seat.Event {
    const request = try read_request(arena, table, key);
    const item = try backend.get(arena, request) orelse return error.EventUnavailable;
    const event = try decode_item(arena, item);
    if (!std.mem.eql(u8, event.tenant, key.tenant)) return error.InvalidItem;
    if (event.event_id != key.event_id) return error.InvalidItem;
    return event;
}

/// Each cache belongs to one process and one immutable Events table binding.
/// Creation and transactional pair reads remain authoritative and bypass this path.
pub fn read_cached_event(
    arena: Allocator,
    table: []const u8,
    key: *const seat.EventKey,
    cache: ?*ReadyCache,
    backend: anytype,
) !seat.Event {
    try validate_table_name(table);
    if (cache) |ready| {
        if (try ready.get(key)) |event| return event;
    }
    const event = try read_event(arena, table, key, backend);
    if (cache) |ready| try ready.put(&event);
    return event;
}

pub fn read_request(
    arena: Allocator,
    table: []const u8,
    key: *const seat.EventKey,
) !dynamodb.GetItemInput {
    try seat.validate_key(key);
    try validate_table_name(table);
    const attributes = try arena.alloc(Attribute, 2);
    attributes[0] = string_attribute("tenant", try arena.dupe(u8, key.tenant));
    attributes[1] = string_attribute("event_id", try seat.uuid_text(arena, key.event_id));
    return .{ .table_name = try arena.dupe(u8, table), .key = attributes, .consistent_read = true };
}

/// Every slice belongs to the request arena, including key text, class tags and nested Maps.
/// The caller can release its source metadata before invoking the SDK.
pub fn create_request(
    arena: Allocator,
    table: []const u8,
    source: *const seat.Event,
) !dynamodb.PutItemInput {
    try validate_table_name(table);
    if (source.state != .creating) return error.InvalidCreationState;
    const item = try encode_item(arena, source);
    const names = try arena.alloc(aws.map.StringMapEntry, 2);
    names[0] = .{ .key = "#tenant", .value = "tenant" };
    names[1] = .{ .key = "#event_id", .value = "event_id" };
    return .{
        .item = item,
        .table_name = try arena.dupe(u8, table),
        .condition_expression = create_condition,
        .expression_attribute_names = names,
    };
}

pub fn encode_item(arena: Allocator, source: *const seat.Event) ![]const Attribute {
    const event = try seat.clone_event(arena, source);
    const item = try arena.alloc(Attribute, event_fields.len);
    item[0] = string_attribute("tenant", event.tenant);
    item[1] = string_attribute("event_id", try seat.uuid_text(arena, event.event_id));
    item[2] = number_attribute("ledger", try decimal_text(arena, event.ledger));
    item[3] = number_attribute("timeout_seconds", try decimal_text(arena, event.timeout_seconds));
    item[4] = string_attribute(
        "capacity_account_id",
        try decimal_text(arena, event.capacity_account_id),
    );
    item[5] = string_attribute(
        "allocation_account_id",
        try decimal_text(arena, event.allocation_account_id),
    );
    item[6] = string_attribute("state", @tagName(event.state));
    const classes = try arena.alloc(Attribute, event.classes.len);
    for (event.classes, classes) |*class, *attribute| {
        const fields = try arena.alloc(Attribute, 2);
        fields[0] = number_attribute("total", try decimal_text(arena, class.total));
        fields[1] = string_attribute("tb_account_id", try decimal_text(arena, class.tb_account_id));
        attribute.* = .{ .key = class.tag.slice(), .value = .{ .m = fields } };
    }
    item[7] = .{ .key = "classes", .value = .{ .m = classes } };
    _ = try encoded_item_size(arena, item);
    return item;
}

/// Uses the pinned SDK's real uppercase AttributeValue/Map serializer.
pub fn encoded_item_size(arena: Allocator, item: []const Attribute) !usize {
    const encoded = try aws.json.jsonStringify(item, arena);
    defer arena.free(encoded);
    if (encoded.len > seat.item_size_max) return error.ItemTooLarge;
    return encoded.len;
}

pub fn decode_item(arena: Allocator, item: []const Attribute) !seat.Event {
    return decode_item_validated(arena, item) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidItem,
    };
}

fn decode_item_validated(arena: Allocator, item: []const Attribute) !seat.Event {
    try exact_attributes(item, &event_fields);
    const tenant = try string_value(try attribute_value(item, "tenant"));
    try seat.validate_key(&.{ .tenant = tenant, .event_id = 0 });
    const raw_classes = try map_value(try attribute_value(item, "classes"));
    if (raw_classes.len == 0 or raw_classes.len > seat.class_count_max) return error.InvalidItem;
    const classes = try arena.alloc(seat.EventClass, raw_classes.len);
    for (raw_classes, classes) |raw, *class| {
        const fields = try map_value(raw.value);
        try exact_attributes(fields, &.{ "total", "tb_account_id" });
        class.* = .{
            .tag = try seat.Tag.init(raw.key),
            .total = try number_value(try attribute_value(fields, "total")),
            .tb_account_id = try seat.native_id(try string_value(try attribute_value(
                fields,
                "tb_account_id",
            ))),
        };
    }
    std.mem.sort(seat.EventClass, classes, {}, event_class_less_than);
    const event: seat.Event = .{
        .tenant = try arena.dupe(u8, tenant),
        .event_id = try seat.canonical_uuid(try string_value(try attribute_value(
            item,
            "event_id",
        ))),
        .ledger = try number_value(try attribute_value(item, "ledger")),
        .timeout_seconds = try number_value(try attribute_value(item, "timeout_seconds")),
        .capacity_account_id = try seat.native_id(try string_value(try attribute_value(
            item,
            "capacity_account_id",
        ))),
        .allocation_account_id = try seat.native_id(try string_value(try attribute_value(
            item,
            "allocation_account_id",
        ))),
        .state = std.meta.stringToEnum(
            seat.EventState,
            try string_value(try attribute_value(item, "state")),
        ) orelse return error.InvalidItem,
        .classes = classes,
    };
    try seat.validate_event(&event);
    _ = try encoded_item_size(arena, item);
    return event;
}

fn exact_attributes(item: []const Attribute, names: []const []const u8) !void {
    if (item.len != names.len) return error.InvalidItem;
    for (names) |name| _ = try attribute_value(item, name);
}

fn attribute_value(item: []const Attribute, name: []const u8) !dynamodb.types.AttributeValue {
    var found: ?dynamodb.types.AttributeValue = null;
    for (item) |attribute| if (std.mem.eql(u8, attribute.key, name)) {
        if (found != null) return error.InvalidItem;
        found = attribute.value;
    };
    return found orelse error.InvalidItem;
}

fn string_value(value: dynamodb.types.AttributeValue) ![]const u8 {
    if (value != .s) return error.InvalidItem;
    return value.s orelse error.InvalidItem;
}

fn number_value(value: dynamodb.types.AttributeValue) !u32 {
    if (value != .n) return error.InvalidItem;
    const text = value.n orelse return error.InvalidItem;
    if (text.len == 0 or text.len > 10) return error.InvalidItem;
    if (text[0] == '0') return error.InvalidItem;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidItem;
    return std.fmt.parseInt(u32, text, 10) catch error.InvalidItem;
}

fn map_value(value: dynamodb.types.AttributeValue) ![]const Attribute {
    if (value != .m) return error.InvalidItem;
    return value.m orelse error.InvalidItem;
}

fn string_attribute(key: []const u8, text: []const u8) Attribute {
    return .{ .key = key, .value = .{ .s = text } };
}

fn number_attribute(key: []const u8, text: []const u8) Attribute {
    return .{ .key = key, .value = .{ .n = text } };
}

fn decimal_text(arena: Allocator, value: anytype) ![]const u8 {
    return std.fmt.allocPrint(arena, "{d}", .{value});
}

fn event_class_less_than(_: void, left: seat.EventClass, right: seat.EventClass) bool {
    return std.mem.order(u8, left.tag.slice(), right.tag.slice()) == .lt;
}

pub fn validate_table_name(table: []const u8) !void {
    if (table.len < 3 or table.len > 255) return error.InvalidConfiguration;
    for (table) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.') continue;
        return error.InvalidConfiguration;
    }
}

test {
    _ = @import("seat_event_cache.zig");
}

test "typed Event items preserve String keys native IDs and numeric configuration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const event = try seat.decode_event(arena.allocator(),
        \\{"tenant":"tenant-a","event_id":"00000000-0000-0000-0000-000000000001","ledger":1001,"timeout_seconds":30,"capacity_account_id":"1","allocation_account_id":"2","state":"creating","classes":{"a":{"total":10,"tb_account_id":"340282366920938463463374607431768211454"}}}
    );
    const request = try create_request(arena.allocator(), "events-test", &event);
    try std.testing.expectEqualStrings(
        "attribute_not_exists(#tenant) AND attribute_not_exists(#event_id)",
        request.condition_expression.?,
    );
    const encoded = try aws.json.jsonStringify(request.item, arena.allocator());
    const value = try seat.parse_value(arena.allocator(), encoded, seat.item_size_max);
    try std.testing.expectEqualStrings(
        "tenant-a",
        value.object.get("tenant").?.object.get("S").?.string,
    );
    try std.testing.expectEqualStrings(
        "1001",
        value.object.get("ledger").?.object.get("N").?.string,
    );
    const decoded = try decode_item(arena.allocator(), request.item);
    try std.testing.expectEqual(seat.native_id_max, decoded.classes[0].tb_account_id);
}

const fixture_json =
    \\{"tenant":"tenant-a","event_id":"00000000-0000-0000-0000-000000000001","ledger":1001,"timeout_seconds":30,"capacity_account_id":"1","allocation_account_id":"2","state":"creating","classes":{"a":{"total":10,"tb_account_id":"3"}}}
;

// Only DynamoDB effects are faked. Durable typed items outlive every request arena.
const TestDatabase = struct {
    allocator: Allocator,
    items: [4]?[]const Attribute = @splat(null),
    lose_before_put: bool = false,
    lose_after_put: bool = false,
    fail_get: bool = false,

    pub fn put(self: *TestDatabase, arena: Allocator, request: dynamodb.PutItemInput) !void {
        try std.testing.expectEqualStrings(create_condition, request.condition_expression.?);
        try std.testing.expectEqualStrings("tenant", request.expression_attribute_names.?[0].value);
        try std.testing.expectEqualStrings(
            "event_id",
            request.expression_attribute_names.?[1].value,
        );
        const candidate = try decode_item(arena, request.item);
        if (self.lose_before_put) return error.AWSFailure;
        for (self.items) |slot| if (slot) |item| {
            const saved = try decode_item(arena, item);
            if (std.mem.eql(
                u8,
                saved.tenant,
                candidate.tenant,
            ) and saved.event_id == candidate.event_id) {
                return error.InsertConflict;
            }
        };
        for (&self.items) |*slot| if (slot.* == null) {
            slot.* = try encode_item(self.allocator, &candidate);
            if (self.lose_after_put) return error.AWSFailure;
            return;
        };
        return error.TestDatabaseFull;
    }

    pub fn get(
        self: *TestDatabase,
        arena: Allocator,
        request: dynamodb.GetItemInput,
    ) !?[]const Attribute {
        try std.testing.expectEqual(true, request.consistent_read.?);
        try exact_attributes(request.key, &.{ "tenant", "event_id" });
        if (self.fail_get) return error.AWSFailure;
        const tenant = try string_value(try attribute_value(request.key, "tenant"));
        const id = try seat.canonical_uuid(try string_value(try attribute_value(
            request.key,
            "event_id",
        )));
        for (self.items) |slot| if (slot) |item| {
            const saved = try decode_item(arena, item);
            if (std.mem.eql(u8, saved.tenant, tenant) and saved.event_id == id) return item;
        };
        return null;
    }
};

test "tenant-scoped insertion returns the saved winner and rejects configuration conflicts" {
    var durable = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer durable.deinit();
    var db: TestDatabase = .{ .allocator = durable.allocator() };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const first = try seat.decode_event(allocator, fixture_json);
    _ = try insert(allocator, "events-test", &first, &db);
    var losing = try seat.clone_event(allocator, &first);
    losing.ledger = 1002;
    losing.capacity_account_id = 4;
    losing.allocation_account_id = 5;
    const classes = try allocator.dupe(seat.EventClass, losing.classes);
    classes[0].tb_account_id = 6;
    losing.classes = classes;
    const winner = try insert(allocator, "events-test", &losing, &db);
    try std.testing.expectEqual(@as(u32, 1001), winner.ledger);
    try std.testing.expectEqual(@as(u128, 1), winner.capacity_account_id);
    try std.testing.expectEqual(@as(u128, 3), winner.classes[0].tb_account_id);
    classes[0].total = 11;
    try std.testing.expectError(
        error.EventConflict,
        insert(allocator, "events-test", &losing, &db),
    );
    const saved = try read_event(
        allocator,
        "events-test",
        &.{ .tenant = "tenant-a", .event_id = 1 },
        &db,
    );
    try std.testing.expectEqual(@as(u32, 10), saved.classes[0].total);
    try std.testing.expectError(
        error.EventUnavailable,
        read_event(allocator, "events-test", &.{ .tenant = "tenant-b", .event_id = 1 }, &db),
    );
    var another_tenant = first;
    another_tenant.tenant = "tenant-b";
    _ = try insert(allocator, "events-test", &another_tenant, &db);
    const foreign_key = try read_event(
        allocator,
        "events-test",
        &.{ .tenant = "tenant-b", .event_id = 1 },
        &db,
    );
    try std.testing.expectEqualStrings("tenant-b", foreign_key.tenant);
}

test "lost insertion responses require authoritative winner resolution across request restarts" {
    var durable = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer durable.deinit();
    var db: TestDatabase = .{
        .allocator = durable.allocator(),
        .lose_after_put = true,
        .fail_get = true,
    };
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const candidate = try seat.decode_event(arena.allocator(), fixture_json);
        try std.testing.expectError(
            error.AWSFailure,
            insert(arena.allocator(), "events-test", &candidate, &db),
        );
    }
    db.fail_get = false;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var retry = try seat.decode_event(arena.allocator(), fixture_json);
    retry.ledger = 1003;
    retry.capacity_account_id = 4;
    const winner = try insert(arena.allocator(), "events-test", &retry, &db);
    try std.testing.expectEqual(@as(u32, 1001), winner.ledger);
    try std.testing.expectEqual(@as(u128, 1), winner.capacity_account_id);
    var before: TestDatabase = .{ .allocator = durable.allocator(), .lose_before_put = true };
    try std.testing.expectError(
        error.InsertionUncertain,
        insert(arena.allocator(), "events-test", &retry, &before),
    );
    try std.testing.expectError(
        error.EventUnavailable,
        read_event(
            arena.allocator(),
            "events-test",
            &.{ .tenant = "tenant-a", .event_id = 1 },
            &before,
        ),
    );
    var resolved: TestDatabase = .{ .allocator = durable.allocator(), .lose_after_put = true };
    const after = try insert(arena.allocator(), "events-test", &retry, &resolved);
    try std.testing.expectEqual(@as(u32, 1003), after.ledger);
}

test "request and decoded storage survives release of source arenas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const source = try seat.decode_event(source_arena.allocator(), fixture_json);
    const request = try create_request(arena.allocator(), "events-test", &source);
    source_arena.deinit();
    const encoded = try aws.json.jsonStringify(request, arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, encoded, "tenant-a") != null);
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const item = try encode_item(
        result_arena.allocator(),
        &try decode_item(arena.allocator(), request.item),
    );
    const decoded = try decode_item(arena.allocator(), item);
    result_arena.deinit();
    try std.testing.expectEqualStrings("tenant-a", decoded.tenant);
    try std.testing.expectEqualStrings("a", decoded.classes[0].tag.slice());
    try std.testing.expectEqual(@as(u128, 3), decoded.classes[0].tb_account_id);
}

test "malformed stored records and invalid creation states cannot authorize an insert or read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const event = try seat.decode_event(allocator, fixture_json);
    const item = try encode_item(allocator, &event);
    try std.testing.expectError(error.InvalidItem, decode_item(allocator, item[0..7]));
    for ([_]Attribute{
        .{ .key = "unexpected", .value = .{ .s = "x" } },
        .{ .key = "tenant", .value = .{ .s = "" } },
        .{ .key = "tenant", .value = .{ .n = "1" } },
        .{ .key = "tenant", .value = .{ .s = null } },
    }) |replacement| {
        const malformed = try allocator.dupe(Attribute, item);
        malformed[0] = replacement;
        try std.testing.expectError(error.InvalidItem, decode_item(allocator, malformed));
    }
    for ([_][]const u8{ "0", "01", "1.0", "1e0", "4294967296", "-1", "" }) |text| {
        const malformed = try allocator.dupe(Attribute, item);
        malformed[2].value = .{ .n = text };
        try std.testing.expectError(error.InvalidItem, decode_item(allocator, malformed));
    }
    const duplicate = try allocator.dupe(Attribute, item);
    duplicate[1] = duplicate[0];
    try std.testing.expectError(error.InvalidItem, decode_item(allocator, duplicate));
    const account_conflict = try allocator.dupe(Attribute, item);
    account_conflict[5].value = .{ .s = "1" };
    try std.testing.expectError(error.InvalidItem, decode_item(allocator, account_conflict));
    const invalid_id = try allocator.dupe(Attribute, item);
    invalid_id[4].value = .{ .s = "340282366920938463463374607431768211455" };
    try std.testing.expectError(error.InvalidItem, decode_item(allocator, invalid_id));
    const invalid_state = try allocator.dupe(Attribute, item);
    invalid_state[6].value = .{ .s = "other" };
    try std.testing.expectError(error.InvalidItem, decode_item(allocator, invalid_state));
    for ([_]seat.EventState{ .ready, .failed }) |state| {
        var existing = event;
        existing.state = state;
        try std.testing.expectError(
            error.InvalidCreationState,
            create_request(allocator, "events-test", &existing),
        );
        const persisted = try decode_item(allocator, try encode_item(allocator, &existing));
        try std.testing.expectEqual(state, persisted.state);
    }
}

test "real typed-item serializer admits exactly 32 KiB and rejects one extra byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // An artificial String isolates the encoding gate; unknown Event fields remain invalid.
    const allocator = arena.allocator();
    const text = try allocator.alloc(u8, 32768 - 13);
    @memset(text, 'x');
    const exact = [_]Attribute{string_attribute("x", text[0 .. text.len - 1])};
    try std.testing.expectEqual(@as(usize, 32768), try encoded_item_size(allocator, &exact));
    const over = [_]Attribute{string_attribute("x", text)};
    try std.testing.expectError(error.ItemTooLarge, encoded_item_size(allocator, &over));
}

test "31 maximum escaped classes fit logical metadata and the pinned SDK typed item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var classes: [31]seat.EventClass = undefined;
    for (&classes, 0..) |*class, index| {
        var bytes: [54]u8 = @splat('"');
        bytes[0] = @intCast('A' + index);
        class.* = .{
            .tag = try seat.Tag.init(&bytes),
            .total = std.math.maxInt(u32),
            .tb_account_id = seat.native_id_max - index - 2,
        };
    }
    const event: seat.Event = .{
        .tenant = "\x00" ** 64,
        .event_id = std.math.maxInt(u128),
        .ledger = std.math.maxInt(u32),
        .timeout_seconds = std.math.maxInt(u32),
        .capacity_account_id = seat.native_id_max,
        .allocation_account_id = seat.native_id_max - 1,
        .classes = &classes,
        .state = .creating,
    };
    const logical = try seat.encode_event(allocator, &event);
    try std.testing.expect(logical.len < 16384);
    const request = try create_request(allocator, "events-test", &event);
    const size = try encoded_item_size(allocator, request.item);
    try std.testing.expect(size < 32768);
    const decoded = try decode_item(allocator, request.item);
    try std.testing.expectEqual(@as(usize, 31), decoded.classes.len);
    try std.testing.expectEqual(seat.native_id_max, decoded.capacity_account_id);
    try std.testing.expectEqual(@as(u64, 133_143_986_145), try seat.total_supply(&decoded));
    // The logical cap is small enough that no accepted Event can reach the typed-item cap.
    const wire = try aws.json.jsonStringify(request.item, allocator);
    try std.testing.expect(std.mem.indexOf(
        u8,
        wire,
        "\"S\":\"340282366920938463463374607431768211454\"",
    ) != null);
}

test "class Maps reject duplicate tags unexpected fields wrong totals and repeated native IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const event = try seat.decode_event(allocator, fixture_json);
    const item = try encode_item(allocator, &event);
    const original_class = item[7].value.m.?[0];
    const duplicate_classes = [_]Attribute{ original_class, original_class };
    const malformed = try allocator.dupe(Attribute, item);
    malformed[7].value = .{ .m = &duplicate_classes };
    try std.testing.expectError(error.InvalidItem, decode_item(allocator, malformed));
    const fields = try allocator.dupe(Attribute, original_class.value.m.?);
    const classes = try allocator.dupe(Attribute, item[7].value.m.?);
    classes[0].value = .{ .m = fields };
    malformed[7].value = .{ .m = classes };
    fields[1].value = .{ .s = "2" };
    try std.testing.expectError(error.InvalidItem, decode_item(allocator, malformed));
    fields[1].value = .{ .s = "3" };
    for ([_]Attribute{
        .{ .key = "total", .value = .{ .s = "10" } },
        .{ .key = "extra", .value = .{ .n = "10" } },
        .{ .key = "total", .value = .{ .n = "0" } },
        .{ .key = "tb_account_id", .value = .{ .n = "10" } },
    }) |replacement| {
        fields[0] = replacement;
        try std.testing.expectError(error.InvalidItem, decode_item(allocator, malformed));
    }
    fields[0] = original_class.value.m.?[0];
    classes[0].key = "capacity";
    try std.testing.expectError(error.InvalidItem, decode_item(allocator, malformed));
    classes[0].key = "\xc2\x85";
    try std.testing.expectError(error.InvalidItem, decode_item(allocator, malformed));
    const too_many = try allocator.alloc(Attribute, 32);
    @memset(too_many, original_class);
    malformed[7].value = .{ .m = too_many };
    try std.testing.expectError(error.InvalidItem, decode_item(allocator, malformed));
}
