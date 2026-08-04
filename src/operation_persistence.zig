const std = @import("std");
const aws = @import("aws");
const dynamodb = @import("dynamodb");
const operation = @import("operation");

const Allocator = std.mem.Allocator;
const AttributeValue = dynamodb.types.AttributeValue;
const Attribute = aws.map.MapEntry(AttributeValue);
const AttributeName = aws.map.StringMapEntry;

const id_size = 36;
const hash_size = 64;
const attribute_count_min = 6;
const attribute_count_max = 7;
const create_condition = "attribute_not_exists(id)";

comptime {
    std.debug.assert(id_size == 36);
    std.debug.assert(hash_size == 2 * 32);
    std.debug.assert(attribute_count_max == attribute_count_min + 1);
}

/// Stores and retrieves Operations using the repository's fixed DynamoDB item contract.
pub const Persistence = struct {
    client: *dynamodb.Client,
    table_name: []const u8,

    const Self = @This();

    pub fn init(client: *dynamodb.Client, table_name: []const u8) !Self {
        try validateTableName(table_name);
        std.debug.assert(table_name.len >= 3);
        std.debug.assert(table_name.len <= 255);
        return .{ .client = client, .table_name = table_name };
    }

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    /// Creates an item or returns the matching existing item for an idempotent retry.
    pub fn create(
        self: *Self,
        arena: Allocator,
        source: *const operation.Operation,
    ) !operation.Operation {
        var persisted = persistentCopy(source);
        try validateStored(&persisted);

        var request: CreateRequest = undefined;
        try createRequestInit(&request, &persisted);
        var diagnostic: dynamodb.ServiceError = undefined;
        _ = self.client.putItem(arena, .{
            .condition_expression = create_condition,
            .item = request.items[0..request.item_count],
            .return_values_on_condition_check_failure = .all_old,
            .table_name = self.table_name,
        }, .{ .diagnostic = &diagnostic }) catch |err| {
            return createError(arena, err, &diagnostic, &persisted);
        };
        return persisted;
    }

    /// Retrieves and validates an item using a strongly consistent read.
    pub fn read(
        self: *Self,
        arena: Allocator,
        id: u128,
    ) !operation.Operation {
        var request: ReadRequest = undefined;
        readRequestInit(&request, id);
        var diagnostic: dynamodb.ServiceError = undefined;
        const response = self.client.getItem(arena, .{
            .consistent_read = true,
            .key = &request.key,
            .table_name = self.table_name,
        }, .{ .diagnostic = &diagnostic }) catch |err| {
            return readError(err, &diagnostic);
        };
        const item = response.item orelse return error.OperationNotFound;
        return decodeItem(arena, item);
    }

    /// Replaces mutable state only if the stored item still matches the snapshot.
    pub fn update(
        self: *Self,
        arena: Allocator,
        snapshot: *const operation.Operation,
        replacement: *const operation.Operation,
    ) !operation.Operation {
        try validateUpdate(snapshot, replacement);
        var request: UpdateRequest = undefined;
        try updateRequestInit(&request, snapshot, replacement);
        var diagnostic: dynamodb.ServiceError = undefined;
        const response = self.client.updateItem(arena, .{
            .condition_expression = request.condition_expression,
            .expression_attribute_names = &request.names,
            .expression_attribute_values = request.values[0..request.value_count],
            .key = &request.key,
            .return_values = .all_new,
            .table_name = self.table_name,
            .update_expression = request.update_expression,
        }, .{ .diagnostic = &diagnostic }) catch |err| {
            return writeError(err, &diagnostic, error.OperationConflict);
        };
        const attributes = response.attributes orelse return error.InvalidItem;
        const updated = try decodeItem(arena, attributes);
        try validateUpdateResult(&updated, replacement);
        return updated;
    }
};

const CreateRequest = struct {
    id_buffer: [id_size]u8,
    hash_buffer: [hash_size]u8,
    timestamp_buffer: [32]u8,
    expires_at_buffer: [32]u8,
    result_buffer: [operation.result_size_max]u8,
    items: [attribute_count_max]Attribute,
    item_count: u8,
};

const ReadRequest = struct {
    id_buffer: [id_size]u8,
    key: [1]Attribute,
};

const UpdateRequest = struct {
    id_buffer: [id_size]u8,
    old_hash_buffer: [hash_size]u8,
    old_timestamp_buffer: [32]u8,
    new_timestamp_buffer: [32]u8,
    old_expires_at_buffer: [32]u8,
    new_expires_at_buffer: [32]u8,
    old_result_buffer: [operation.result_size_max]u8,
    new_result_buffer: [operation.result_size_max]u8,
    key: [1]Attribute,
    names: [4]AttributeName,
    values: [11]Attribute,
    value_count: u8,
    condition_expression: []const u8,
    update_expression: []const u8,
};

fn createRequestInit(request: *CreateRequest, source: *const operation.Operation) !void {
    const state = source.state.?;
    const timestamp = timestampString(source.last_updated.?, &request.timestamp_buffer);
    const expires_at = timestampString(source.expires_at.?, &request.expires_at_buffer);
    request.hash_buffer = std.fmt.bytesToHex(source.hash.?, .lower);
    request.items = undefined;
    request.items[0] = stringAttribute("id", operation.uuidToString(source.id, &request.id_buffer));
    request.items[1] = stringAttribute("name", source.name);
    request.items[2] = stringAttribute("state", operation.stateToString(state));
    request.items[3] = numberAttribute("last_updated", timestamp);
    request.items[4] = numberAttribute("expires_at", expires_at);
    request.items[5] = stringAttribute("hash", &request.hash_buffer);
    request.item_count = attribute_count_min;
    if (operation.stateIsTerminal(state)) {
        const result = try operation.writeResultJSON(&request.result_buffer, &source.result.?);
        request.items[request.item_count] = stringAttribute("result", result);
        request.item_count += 1;
    }
    std.debug.assert(request.item_count >= attribute_count_min);
    std.debug.assert(request.item_count <= attribute_count_max);
}

fn readRequestInit(request: *ReadRequest, id: u128) void {
    const id_string = operation.uuidToString(id, &request.id_buffer);
    request.key = .{stringAttribute("id", id_string)};
    std.debug.assert(request.key.len == 1);
    std.debug.assert(request.key[0].value.s.?.len == id_size);
}

fn updateRequestInit(
    request: *UpdateRequest,
    snapshot: *const operation.Operation,
    replacement: *const operation.Operation,
) !void {
    const id = operation.uuidToString(snapshot.id, &request.id_buffer);
    const old_time = timestampString(snapshot.last_updated.?, &request.old_timestamp_buffer);
    const new_time = timestampString(replacement.last_updated.?, &request.new_timestamp_buffer);
    const old_expires_at = timestampString(
        snapshot.expires_at.?,
        &request.old_expires_at_buffer,
    );
    const new_expires_at = timestampString(
        replacement.expires_at.?,
        &request.new_expires_at_buffer,
    );
    request.key = .{stringAttribute("id", id)};
    request.old_hash_buffer = std.fmt.bytesToHex(snapshot.hash.?, .lower);
    request.names = .{
        .{ .key = "#hash", .value = "hash" },
        .{ .key = "#name", .value = "name" },
        .{ .key = "#result", .value = "result" },
        .{ .key = "#state", .value = "state" },
    };
    request.values = undefined;
    request.value_count = 0;
    updateValue(request, ":id", .{ .s = id });
    updateValue(request, ":old_name", .{ .s = snapshot.name });
    updateValue(request, ":old_state", .{ .s = operation.stateToString(snapshot.state.?) });
    updateValue(request, ":old_time", .{ .n = old_time });
    updateValue(request, ":old_expires_at", .{ .n = old_expires_at });
    updateValue(request, ":old_hash", .{ .s = &request.old_hash_buffer });
    updateValue(request, ":new_state", .{ .s = operation.stateToString(replacement.state.?) });
    updateValue(request, ":new_time", .{ .n = new_time });
    updateValue(request, ":new_expires_at", .{ .n = new_expires_at });
    try updateRequestResult(request, snapshot, replacement);
}

fn updateRequestResult(
    request: *UpdateRequest,
    snapshot: *const operation.Operation,
    replacement: *const operation.Operation,
) !void {
    if (snapshot.result) |result| {
        const serialized = try operation.writeResultJSON(&request.old_result_buffer, &result);
        updateValue(request, ":old_result", .{ .s = serialized });
        request.condition_expression = condition_with_result;
    } else {
        request.condition_expression = condition_without_result;
    }
    if (replacement.result) |result| {
        const serialized = try operation.writeResultJSON(&request.new_result_buffer, &result);
        updateValue(request, ":new_result", .{ .s = serialized });
        request.update_expression = update_with_result;
    } else {
        request.update_expression = update_without_result;
    }
    std.debug.assert(request.value_count >= 9);
    std.debug.assert(request.value_count <= request.values.len);
}

fn updateValue(request: *UpdateRequest, key: []const u8, value: AttributeValue) void {
    std.debug.assert(request.value_count < request.values.len);
    request.values[request.value_count] = .{ .key = key, .value = value };
    request.value_count += 1;
    std.debug.assert(request.value_count <= request.values.len);
}

const condition_without_result =
    "id = :id AND #name = :old_name AND #state = :old_state AND " ++
    "last_updated = :old_time AND expires_at = :old_expires_at AND " ++
    "#hash = :old_hash AND attribute_not_exists(#result)";
const condition_with_result =
    "id = :id AND #name = :old_name AND #state = :old_state AND " ++
    "last_updated = :old_time AND expires_at = :old_expires_at AND " ++
    "#hash = :old_hash AND #result = :old_result";
const update_without_result =
    "SET #state = :new_state, last_updated = :new_time, " ++
    "expires_at = :new_expires_at REMOVE #result";
const update_with_result =
    "SET #state = :new_state, last_updated = :new_time, " ++
    "expires_at = :new_expires_at, #result = :new_result";

fn decodeItem(arena: Allocator, item: []const Attribute) !operation.Operation {
    if (item.len < attribute_count_min) return error.InvalidItem;
    if (item.len > attribute_count_max) return error.InvalidItem;

    var fields: DecodedFields = .{};
    for (item) |attribute| try fields.set(attribute);
    const decoded = try fields.toOperation(arena);
    validateStored(&decoded) catch return error.InvalidItem;
    return decoded;
}

const DecodedFields = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    state: ?[]const u8 = null,
    last_updated: ?[]const u8 = null,
    expires_at: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    result: ?[]const u8 = null,

    fn set(fields: *DecodedFields, attribute: Attribute) !void {
        if (std.mem.eql(u8, attribute.key, "id")) {
            if (fields.id != null) return error.InvalidItem;
            fields.id = try stringValue(attribute.value);
        } else if (std.mem.eql(u8, attribute.key, "name")) {
            if (fields.name != null) return error.InvalidItem;
            fields.name = try stringValue(attribute.value);
        } else if (std.mem.eql(u8, attribute.key, "state")) {
            if (fields.state != null) return error.InvalidItem;
            fields.state = try stringValue(attribute.value);
        } else if (std.mem.eql(u8, attribute.key, "last_updated")) {
            if (fields.last_updated != null) return error.InvalidItem;
            fields.last_updated = try numberValue(attribute.value);
        } else if (std.mem.eql(u8, attribute.key, "expires_at")) {
            if (fields.expires_at != null) return error.InvalidItem;
            fields.expires_at = try numberValue(attribute.value);
        } else if (std.mem.eql(u8, attribute.key, "hash")) {
            if (fields.hash != null) return error.InvalidItem;
            fields.hash = try stringValue(attribute.value);
        } else if (std.mem.eql(u8, attribute.key, "result")) {
            if (fields.result != null) return error.InvalidItem;
            fields.result = try stringValue(attribute.value);
        } else {
            return error.InvalidItem;
        }
    }

    fn toOperation(fields: *const DecodedFields, arena: Allocator) !operation.Operation {
        const id_text = fields.id orelse return error.InvalidItem;
        const id = operation.uuidFromString(id_text) catch return error.InvalidItem;
        var id_buffer: [id_size]u8 = undefined;
        if (!std.mem.eql(u8, id_text, operation.uuidToString(id, &id_buffer))) {
            return error.InvalidItem;
        }
        const state_text = fields.state orelse return error.InvalidItem;
        const state = operation.stateFromString(state_text) catch return error.InvalidItem;
        const result = if (operation.stateIsTerminal(state)) result: {
            const result_text = fields.result orelse return error.InvalidItem;
            break :result try parseStoredResult(arena, result_text);
        } else result: {
            if (fields.result != null) return error.InvalidItem;
            break :result null;
        };
        const name_text = fields.name orelse return error.InvalidItem;
        return .{
            .id = id,
            .name = try arena.dupe(u8, name_text),
            .state = state,
            .last_updated = try timestampFromString(fields.last_updated orelse {
                return error.InvalidItem;
            }),
            .expires_at = try timestampFromString(fields.expires_at orelse {
                return error.InvalidItem;
            }),
            .result = result,
            .hash = try hashFromString(fields.hash orelse return error.InvalidItem),
        };
    }
};

fn parseStoredResult(arena: Allocator, result_text: []const u8) !std.json.Value {
    const result = operation.parseResultJSON(arena, result_text) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidItem,
        };
    };
    var canonical_buffer: [operation.result_size_max]u8 = undefined;
    const canonical = operation.writeResultJSON(&canonical_buffer, &result) catch {
        return error.InvalidItem;
    };
    if (!std.mem.eql(u8, result_text, canonical)) return error.InvalidItem;
    return result;
}

fn persistentCopy(source: *const operation.Operation) operation.Operation {
    var persisted = source.*;
    persisted.body = null;
    if (persisted.state) |state| {
        if (!operation.stateIsTerminal(state)) persisted.result = null;
    }
    return persisted;
}

fn validateStored(source: *const operation.Operation) !void {
    try operation.validatePersistent(source);
    const state = source.state.?;
    if (!operation.stateIsTerminal(state)) {
        if (source.result != null) return error.UnexpectedResult;
    }
}

fn validateUpdate(
    snapshot: *const operation.Operation,
    replacement: *const operation.Operation,
) !void {
    try validateStored(snapshot);
    try validateStored(replacement);
    if (snapshot.id != replacement.id) return error.ImmutableField;
    if (!std.mem.eql(u8, snapshot.name, replacement.name)) return error.ImmutableField;
    if (!std.mem.eql(u8, &snapshot.hash.?, &replacement.hash.?)) return error.ImmutableField;
    std.debug.assert(snapshot.body == null);
    std.debug.assert(replacement.body == null);
}

fn validateUpdateResult(
    updated: *const operation.Operation,
    replacement: *const operation.Operation,
) !void {
    if (updated.id != replacement.id) return error.InvalidItem;
    if (!std.mem.eql(u8, updated.name, replacement.name)) return error.InvalidItem;
    if (!std.mem.eql(u8, &updated.hash.?, &replacement.hash.?)) return error.InvalidItem;
    if (updated.state != replacement.state) return error.InvalidItem;
    if (updated.last_updated != replacement.last_updated) return error.InvalidItem;
    if (updated.expires_at != replacement.expires_at) return error.InvalidItem;
    if (!try optionalValueEqual(updated.result, replacement.result)) return error.InvalidItem;
}

fn createError(
    arena: Allocator,
    err: anyerror,
    diagnostic: *dynamodb.ServiceError,
    submitted: *const operation.Operation,
) anyerror!operation.Operation {
    if (err != error.ServiceError) return error.AWSFailure;
    defer diagnostic.deinit();
    const failure = switch (diagnostic.kind) {
        .conditional_check_failed_exception => |value| value,
        else => return error.AWSFailure,
    };
    const item = failure.item orelse return error.InvalidItem;
    const existing = try decodeItem(arena, item);
    if (!std.mem.eql(u8, &existing.hash.?, &submitted.hash.?)) {
        return error.OperationConflict;
    }
    return existing;
}

fn writeError(err: anyerror, diagnostic: *dynamodb.ServiceError, outcome: anyerror) anyerror {
    if (err != error.ServiceError) return error.AWSFailure;
    defer diagnostic.deinit();
    if (std.meta.activeTag(diagnostic.kind) == .conditional_check_failed_exception) {
        return outcome;
    }
    return error.AWSFailure;
}

fn readError(err: anyerror, diagnostic: *dynamodb.ServiceError) anyerror {
    if (err != error.ServiceError) return error.AWSFailure;
    diagnostic.deinit();
    return error.AWSFailure;
}

pub fn validateTableName(table_name: []const u8) !void {
    if (table_name.len < 3) return error.InvalidTableName;
    if (table_name.len > 255) return error.InvalidTableName;
    for (table_name) |character| {
        if (std.ascii.isAlphanumeric(character)) continue;
        if (character == '_') continue;
        if (character == '-') continue;
        if (character == '.') continue;
        return error.InvalidTableName;
    }
}

fn stringAttribute(key: []const u8, value: []const u8) Attribute {
    std.debug.assert(key.len > 0);
    std.debug.assert(value.len > 0);
    return .{ .key = key, .value = .{ .s = value } };
}

fn numberAttribute(key: []const u8, value: []const u8) Attribute {
    std.debug.assert(key.len > 0);
    std.debug.assert(value.len > 0);
    return .{ .key = key, .value = .{ .n = value } };
}

fn stringValue(value: AttributeValue) ![]const u8 {
    return switch (value) {
        .s => |string| string orelse error.InvalidItem,
        else => error.InvalidItem,
    };
}

fn numberValue(value: AttributeValue) ![]const u8 {
    return switch (value) {
        .n => |number| number orelse error.InvalidItem,
        else => error.InvalidItem,
    };
}

fn timestampString(timestamp: operation.UnixSeconds, buffer: *[32]u8) []const u8 {
    const value = std.fmt.bufPrint(buffer, "{d}", .{timestamp}) catch unreachable;
    std.debug.assert(value.len > 0);
    std.debug.assert(value.len <= buffer.len);
    return value;
}

fn timestampFromString(value: []const u8) !operation.UnixSeconds {
    if (value.len == 0) return error.InvalidItem;
    const timestamp = std.fmt.parseInt(operation.UnixSeconds, value, 10) catch {
        return error.InvalidItem;
    };
    var buffer: [32]u8 = undefined;
    if (!std.mem.eql(u8, value, timestampString(timestamp, &buffer))) {
        return error.InvalidItem;
    }
    return timestamp;
}

fn hashFromString(value: []const u8) ![32]u8 {
    if (value.len != hash_size) return error.InvalidItem;
    for (value) |character| {
        if (character >= '0') {
            if (character <= '9') continue;
        }
        if (character >= 'a') {
            if (character <= 'f') continue;
        }
        return error.InvalidItem;
    }
    var hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&hash, value) catch return error.InvalidItem;
    return hash;
}

fn optionalValueEqual(first: ?std.json.Value, second: ?std.json.Value) !bool {
    if (first) |first_value| {
        const second_value = second orelse return false;
        var first_buffer: [operation.result_size_max]u8 = undefined;
        var second_buffer: [operation.result_size_max]u8 = undefined;
        const first_json = try operation.writeResultJSON(&first_buffer, &first_value);
        const second_json = try operation.writeResultJSON(&second_buffer, &second_value);
        return std.mem.eql(u8, first_json, second_json);
    }
    return second == null;
}

const test_id = "00112233-4455-6677-8899-aabbccddeeff";
const test_hash = [_]u8{0xAB} ** 32;

fn testOperation(state: operation.State, result: ?std.json.Value) operation.Operation {
    return .{
        .id = operation.uuidFromString(test_id) catch unreachable,
        .name = "echo",
        .state = state,
        .last_updated = 1_700_000_000,
        .expires_at = 1_700_086_400,
        .result = result,
        .hash = test_hash,
    };
}

fn testResult(arena: Allocator, input_json: []const u8) !std.json.Value {
    return operation.parseResultJSON(arena, input_json);
}

fn findAttribute(item: []const Attribute, key: []const u8) ?AttributeValue {
    for (item) |attribute| {
        if (std.mem.eql(u8, attribute.key, key)) return attribute.value;
    }
    return null;
}

fn findUpdateValue(request: *const UpdateRequest, key: []const u8) ?AttributeValue {
    return findAttribute(request.values[0..request.value_count], key);
}

test "items round trip every state without persisting body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const states = [_]operation.State{ .new, .submitted, .running, .succeeded, .failed };
    for (states) |state| {
        var source = testOperation(
            state,
            if (operation.stateIsTerminal(state)) .{ .bool = true } else null,
        );
        source.body = .{ .bool = true };
        const persisted = persistentCopy(&source);
        try validateStored(&persisted);
        var request: CreateRequest = undefined;
        try createRequestInit(&request, &persisted);
        const item = request.items[0..request.item_count];
        const decoded = try decodeItem(arena.allocator(), item);

        try std.testing.expectEqual(state, decoded.state.?);
        try std.testing.expect(findAttribute(item, "body") == null);
        try std.testing.expectEqual(operation.stateIsTerminal(state), decoded.result != null);
        try std.testing.expectEqual(@as(usize, request.item_count), item.len);
    }
}

test "create request uses the exact item contract and returns a failed condition item" {
    const source = testOperation(.new, null);
    var request: CreateRequest = undefined;
    try createRequestInit(&request, &source);
    try std.testing.expectEqual(@as(u8, 6), request.item_count);
    try std.testing.expectEqualStrings("00112233-4455-6677-8899-aabbccddeeff", try stringValue(
        findAttribute(request.items[0..request.item_count], "id").?,
    ));
    try std.testing.expectEqualStrings("1700000000", try numberValue(
        findAttribute(request.items[0..request.item_count], "last_updated").?,
    ));
    try std.testing.expectEqualStrings("1700086400", try numberValue(
        findAttribute(request.items[0..request.item_count], "expires_at").?,
    ));
    try std.testing.expectEqualStrings("attribute_not_exists(id)", create_condition);
    const input = dynamodb.PutItemInput{
        .condition_expression = create_condition,
        .item = request.items[0..request.item_count],
        .return_values_on_condition_check_failure = .all_old,
        .table_name = "operations",
    };
    try std.testing.expectEqual(
        dynamodb.types.ReturnValuesOnConditionCheckFailure.all_old,
        input.return_values_on_condition_check_failure.?,
    );
}

test "persistent copy omits the private body without copying arena-owned Values" {
    var source = testOperation(.new, null);
    source.body = .{ .bool = true };
    const created = persistentCopy(&source);

    try std.testing.expect(created.body == null);
    try std.testing.expectEqual(source.id, created.id);
    try std.testing.expectEqual(source.state, created.state);
    try std.testing.expectEqual(source.last_updated, created.last_updated);
    try std.testing.expectEqual(source.expires_at, created.expires_at);
    try std.testing.expectEqualSlices(u8, &source.hash.?, &created.hash.?);
}

test "read request is strongly consistent and keyed by canonical UUID" {
    var request: ReadRequest = undefined;
    readRequestInit(&request, operation.uuidFromString(test_id) catch unreachable);
    const input = dynamodb.GetItemInput{
        .consistent_read = true,
        .key = &request.key,
        .table_name = "operations",
    };
    try std.testing.expectEqual(true, input.consistent_read.?);
    try std.testing.expectEqualStrings(test_id, try stringValue(input.key[0].value));
}

test "decoder rejects missing duplicate unknown wrong and malformed attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = testOperation(.new, null);
    var request: CreateRequest = undefined;
    try createRequestInit(&request, &source);
    const valid = request.items[0..request.item_count];

    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), valid[0..5]));
    var duplicate = request.items;
    duplicate[6] = duplicate[0];
    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), &duplicate));
    var unknown = request.items;
    unknown[6] = stringAttribute("body", "null");
    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), &unknown));
    var wrong_type = request.items;
    wrong_type[1].value = .{ .n = "1" };
    try std.testing.expectError(
        error.InvalidItem,
        decodeItem(arena.allocator(), wrong_type[0..6]),
    );
    var malformed = request.items;
    malformed[0].value = .{ .s = "00112233-4455-6677-8899-AABBCCDDEEFF" };
    try std.testing.expectError(
        error.InvalidItem,
        decodeItem(arena.allocator(), malformed[0..6]),
    );
    malformed = request.items;
    malformed[2].value = .{ .s = "DONE" };
    try std.testing.expectError(
        error.InvalidItem,
        decodeItem(arena.allocator(), malformed[0..6]),
    );
    malformed = request.items;
    malformed[3].value = .{ .n = "01700000000" };
    try std.testing.expectError(
        error.InvalidItem,
        decodeItem(arena.allocator(), malformed[0..6]),
    );
    malformed = request.items;
    malformed[4].value = .{ .s = "1700086400" };
    try std.testing.expectError(
        error.InvalidItem,
        decodeItem(arena.allocator(), malformed[0..6]),
    );
    malformed = request.items;
    malformed[4].value = .{ .n = "1700086401" };
    try std.testing.expectError(
        error.InvalidItem,
        decodeItem(arena.allocator(), malformed[0..6]),
    );
    malformed = request.items;
    malformed[5].value = .{ .s = "AB" ** 32 };
    try std.testing.expectError(
        error.InvalidItem,
        decodeItem(arena.allocator(), malformed[0..6]),
    );
    malformed = request.items;
    malformed[6] = stringAttribute("result", "null");
    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), &malformed));
}

test "decoder enforces terminal result presence type canonical JSON and size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = testOperation(
        .succeeded,
        try testResult(arena.allocator(), "{\"ok\":true}"),
    );
    var request: CreateRequest = undefined;
    try createRequestInit(&request, &source);
    _ = try decodeItem(arena.allocator(), &request.items);

    const legacy = [_]Attribute{
        request.items[0],
        request.items[1],
        request.items[2],
        request.items[3],
        request.items[5],
        request.items[6],
    };
    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), &legacy));
    try std.testing.expectError(
        error.InvalidItem,
        decodeItem(arena.allocator(), request.items[0..6]),
    );
    var malformed = request.items;
    malformed[6].value = .{ .n = "1" };
    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), &malformed));
    malformed = request.items;
    malformed[6].value = .{ .s = "null" };
    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), &malformed));
    malformed = request.items;
    malformed[6].value = .{ .s = "{broken" };
    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), &malformed));
    malformed = request.items;
    malformed[6].value = .{ .s = "{\"ok\": true}" };
    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), &malformed));
    malformed = request.items;
    malformed[6].value = .{ .s = "{\"key\":1,\"key\":2}" };
    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), &malformed));
    const oversized = "\"" ++ ("a" ** (operation.result_size_max - 1)) ++ "\"";
    malformed = request.items;
    malformed[6].value = .{ .s = oversized };
    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), &malformed));
}

test "terminal result Values round trip through canonical DynamoDB strings" {
    const inputs = [_][]const u8{
        "true",
        "42",
        "\"text\"",
        "[true, 42]",
        "{\"second\":2,\"first\":1}",
    };
    const expected = [_][]const u8{
        "true",
        "42",
        "\"text\"",
        "[true,42]",
        "{\"second\":2,\"first\":1}",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (inputs, expected) |input, canonical| {
        const source = testOperation(
            .succeeded,
            try testResult(arena.allocator(), input),
        );
        var request: CreateRequest = undefined;
        try createRequestInit(&request, &source);
        try std.testing.expectEqualStrings(canonical, try stringValue(
            findAttribute(request.items[0..request.item_count], "result").?,
        ));
        const decoded = try decodeItem(arena.allocator(), request.items[0..request.item_count]);
        var result_buffer: [operation.result_size_max]u8 = undefined;
        try std.testing.expectEqualStrings(
            canonical,
            try operation.writeResultJSON(&result_buffer, &decoded.result.?),
        );
    }
}

test "updates snapshot every stored field and return all new attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snapshot = testOperation(.running, null);
    var replacement = snapshot;
    replacement.state = .succeeded;
    replacement.last_updated.? += 1;
    replacement.expires_at.? += 1;
    replacement.result = try testResult(arena.allocator(), "{\"ok\":true}");
    try validateUpdate(&snapshot, &replacement);
    var request: UpdateRequest = undefined;
    try updateRequestInit(&request, &snapshot, &replacement);

    try std.testing.expectEqualStrings(condition_without_result, request.condition_expression);
    try std.testing.expectEqualStrings(update_with_result, request.update_expression);
    try std.testing.expectEqualStrings("RUNNING", try stringValue(
        findUpdateValue(&request, ":old_state").?,
    ));
    try std.testing.expectEqualStrings("SUCCEEDED", try stringValue(
        findUpdateValue(&request, ":new_state").?,
    ));
    try std.testing.expectEqualStrings("1700086400", try numberValue(
        findUpdateValue(&request, ":old_expires_at").?,
    ));
    try std.testing.expectEqualStrings("1700086401", try numberValue(
        findUpdateValue(&request, ":new_expires_at").?,
    ));
    try std.testing.expectEqualStrings("{\"ok\":true}", try stringValue(
        findUpdateValue(&request, ":new_result").?,
    ));
    const input = dynamodb.UpdateItemInput{
        .expression_attribute_names = &request.names,
        .expression_attribute_values = request.values[0..request.value_count],
        .key = &request.key,
        .return_values = .all_new,
        .table_name = "operations",
    };
    try std.testing.expectEqual(dynamodb.types.ReturnValue.all_new, input.return_values.?);
}

test "updates remove replace and preserve result across arbitrary state changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const targets = [_]operation.State{ .new, .submitted, .running, .succeeded, .failed };
    for (targets) |target| {
        const snapshot = testOperation(
            .failed,
            try testResult(arena.allocator(), "{\"old\":true}"),
        );
        var replacement = snapshot;
        replacement.state = target;
        replacement.last_updated.? += 1;
        replacement.expires_at.? += 1;
        replacement.result = if (operation.stateIsTerminal(target))
            try testResult(arena.allocator(), "{\"new\":true}")
        else
            null;
        try validateUpdate(&snapshot, &replacement);
        var request: UpdateRequest = undefined;
        try updateRequestInit(&request, &snapshot, &replacement);
        try std.testing.expectEqualStrings(condition_with_result, request.condition_expression);
        if (operation.stateIsTerminal(target)) {
            try std.testing.expectEqualStrings(update_with_result, request.update_expression);
        } else {
            try std.testing.expectEqualStrings(update_without_result, request.update_expression);
        }
    }
}

test "updates allow same state and reject immutable replacements" {
    const snapshot = testOperation(.submitted, null);
    var replacement = snapshot;
    replacement.last_updated.? += 1;
    replacement.expires_at.? += 1;
    try validateUpdate(&snapshot, &replacement);

    replacement.id += 1;
    try std.testing.expectError(
        error.ImmutableField,
        validateUpdate(&snapshot, &replacement),
    );
    replacement = snapshot;
    replacement.name = "different";
    try std.testing.expectError(
        error.ImmutableField,
        validateUpdate(&snapshot, &replacement),
    );
    replacement = snapshot;
    replacement.hash.?[0] ^= 1;
    try std.testing.expectError(
        error.ImmutableField,
        validateUpdate(&snapshot, &replacement),
    );
}

test "update result requires the replacement expiration" {
    const replacement = testOperation(.running, null);
    var updated = replacement;
    try validateUpdateResult(&updated, &replacement);

    updated.expires_at.? += 1;
    try std.testing.expectError(
        error.InvalidItem,
        validateUpdateResult(&updated, &replacement),
    );
}

test "matching create retry returns the stored Operation in every state" {
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    const submitted = testOperation(.new, null);
    const states = [_]operation.State{ .new, .submitted, .running, .succeeded, .failed };
    for (states) |state| {
        var existing = testOperation(
            state,
            if (operation.stateIsTerminal(state)) .{ .bool = true } else null,
        );
        existing.last_updated.? -= 10;
        existing.expires_at.? -= 10;
        var diagnostic_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        existing.name = try diagnostic_arena.allocator().dupe(u8, "echo");
        var request: CreateRequest = undefined;
        try createRequestInit(&request, &existing);
        var diagnostic = dynamodb.ServiceError{
            .arena = diagnostic_arena,
            .kind = .{ .conditional_check_failed_exception = .{
                .item = request.items[0..request.item_count],
            } },
        };

        const created = try createError(
            result_arena.allocator(),
            error.ServiceError,
            &diagnostic,
            &submitted,
        );
        try std.testing.expectEqual(existing.state, created.state);
        try std.testing.expectEqual(existing.last_updated, created.last_updated);
        try std.testing.expectEqual(existing.expires_at, created.expires_at);
        try std.testing.expect(try optionalValueEqual(existing.result, created.result));
        try std.testing.expectEqualStrings("echo", created.name);
        try std.testing.expect(created.body == null);
    }
}

test "create retry conflicts on a hash mismatch in every state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const submitted = testOperation(.new, null);
    const states = [_]operation.State{ .new, .submitted, .running, .succeeded, .failed };
    for (states) |state| {
        var existing = testOperation(
            state,
            if (operation.stateIsTerminal(state)) .{ .bool = true } else null,
        );
        existing.hash.?[0] ^= 1;
        var request: CreateRequest = undefined;
        try createRequestInit(&request, &existing);
        var diagnostic = dynamodb.ServiceError{ .kind = .{ .conditional_check_failed_exception = .{
            .item = request.items[0..request.item_count],
        } } };
        try std.testing.expectError(error.OperationConflict, createError(
            arena.allocator(),
            error.ServiceError,
            &diagnostic,
            &submitted,
        ));
    }
}

test "create failure requires a valid returned item and preserves AWS failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const submitted = testOperation(.new, null);
    var missing = dynamodb.ServiceError{
        .kind = .{ .conditional_check_failed_exception = .{} },
    };
    try std.testing.expectError(error.InvalidItem, createError(
        arena.allocator(),
        error.ServiceError,
        &missing,
        &submitted,
    ));

    var request: CreateRequest = undefined;
    try createRequestInit(&request, &submitted);
    var malformed = dynamodb.ServiceError{
        .kind = .{ .conditional_check_failed_exception = .{
            .item = request.items[0..4],
        } },
    };
    try std.testing.expectError(error.InvalidItem, createError(
        arena.allocator(),
        error.ServiceError,
        &malformed,
        &submitted,
    ));

    var unrelated = dynamodb.ServiceError{
        .kind = .{ .unknown = .{ .http_status = 500 } },
    };
    try std.testing.expectError(error.AWSFailure, createError(
        arena.allocator(),
        error.ServiceError,
        &unrelated,
        &submitted,
    ));
    var unused: dynamodb.ServiceError = undefined;
    try std.testing.expectError(error.AWSFailure, createError(
        arena.allocator(),
        error.ConnectionFailed,
        &unused,
        &submitted,
    ));
}

test "conditional update failures map to concurrent outcomes" {
    var update_diagnostic = dynamodb.ServiceError{
        .kind = .{ .conditional_check_failed_exception = .{} },
    };
    try std.testing.expectEqual(
        error.OperationConflict,
        writeError(error.ServiceError, &update_diagnostic, error.OperationConflict),
    );

    var aws_diagnostic = dynamodb.ServiceError{
        .kind = .{ .unknown = .{ .http_status = 500 } },
    };
    try std.testing.expectEqual(
        error.AWSFailure,
        writeError(error.ServiceError, &aws_diagnostic, error.OperationConflict),
    );
}

test "table name validation bounds configuration" {
    try validateTableName("operations-table.1");
    try std.testing.expectError(error.InvalidTableName, validateTableName(""));
    try std.testing.expectError(error.InvalidTableName, validateTableName("ab"));
    try std.testing.expectError(error.InvalidTableName, validateTableName("operations/table"));
    try std.testing.expectError(error.InvalidTableName, validateTableName("a" ** 256));
}
