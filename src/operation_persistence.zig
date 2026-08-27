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
const attribute_count_min = 7;
const attribute_count_max = 8;
const create_condition = "attribute_not_exists(id)";

comptime {
    std.debug.assert(id_size == 36);
    std.debug.assert(hash_size == 2 * 32);
    std.debug.assert(attribute_count_max == attribute_count_min + 1);
}

/// Stores and retrieves Operations using the repository's fixed DynamoDB item contract.
pub const Persistence = struct {
    client: dynamodb.Client,
    table_name: []const u8,

    const Self = @This();

    pub fn init(
        target: *Self,
        allocator: Allocator,
        aws_config: *aws.Config,
        environment: *const std.process.Environ.Map,
    ) !void {
        const table_name = configuredTableName(environment) catch {
            return error.InvalidConfiguration;
        };
        target.* = .{
            .client = dynamodb.Client.init(allocator, aws_config),
            .table_name = table_name,
        };
        std.debug.assert(table_name.len >= 3);
        std.debug.assert(table_name.len <= 255);
        std.debug.assert(target.client.config == aws_config);
    }

    pub fn deinit(self: *Self) void {
        self.client.deinit();
        self.* = undefined;
    }

    /// Creates an item or returns the matching existing item for an idempotent retry.
    pub fn create(
        self: *Self,
        arena: Allocator,
        source: *const operation.Operation,
    ) !operation.Operation {
        var persisted = persistentCopy(source);
        try validateCreation(&persisted);

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

    /// Completes a queued SUBMITTED Operation if its stored identity still matches.
    pub fn complete(
        self: *Self,
        arena: Allocator,
        queued: *const operation.Operation,
        completion: *const operation.Completion,
        now: operation.UnixSeconds,
    ) !void {
        var request: CompletionRequest = undefined;
        try completionRequestInit(&request, queued, completion, now);
        var diagnostic: dynamodb.ServiceError = undefined;
        _ = self.client.updateItem(arena, .{
            .condition_expression = completion_condition,
            .expression_attribute_names = &request.names,
            .expression_attribute_values = &request.values,
            .key = &request.key,
            .table_name = self.table_name,
            .update_expression = completion_update,
        }, .{ .diagnostic = &diagnostic }) catch |err| {
            return writeError(err, &diagnostic, error.OperationConflict);
        };
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
    names: [5]AttributeName,
    values: [12]Attribute,
    value_count: u8,
    condition_expression: []const u8,
    update_expression: []const u8,
};

const CompletionRequest = struct {
    id_buffer: [id_size]u8,
    hash_buffer: [hash_size]u8,
    timestamp_buffer: [32]u8,
    expires_at_buffer: [32]u8,
    result_buffer: [operation.result_size_max]u8,
    key: [1]Attribute,
    names: [5]AttributeName,
    values: [9]Attribute,
};

fn createRequestInit(request: *CreateRequest, source: *const operation.Operation) !void {
    const state = operation.statusToState(&source.status);
    const timestamp = timestampString(source.last_updated.?, &request.timestamp_buffer);
    const expires_at = timestampString(source.expires_at.?, &request.expires_at_buffer);
    request.hash_buffer = std.fmt.bytesToHex(source.hash.?, .lower);
    request.items = undefined;
    request.items[0] = stringAttribute("id", operation.uuidToString(source.id, &request.id_buffer));
    request.items[1] = stringAttribute("tenant", source.tenant);
    request.items[2] = stringAttribute("name", source.name);
    request.items[3] = stringAttribute("state", operation.stateToString(state));
    request.items[4] = numberAttribute("last_updated", timestamp);
    request.items[5] = numberAttribute("expires_at", expires_at);
    request.items[6] = stringAttribute("hash", &request.hash_buffer);
    request.item_count = attribute_count_min;
    if (operation.statusCompletion(&source.status)) |completion| {
        const result = try operation.writeCompletionJSON(&request.result_buffer, completion);
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
        .{ .key = "#tenant", .value = "tenant" },
    };
    request.values = undefined;
    request.value_count = 0;
    updateValue(request, ":id", .{ .s = id });
    updateValue(request, ":old_tenant", .{ .s = snapshot.tenant });
    updateValue(request, ":old_name", .{ .s = snapshot.name });
    updateValue(request, ":old_state", .{
        .s = operation.stateToString(operation.statusToState(&snapshot.status)),
    });
    updateValue(request, ":old_time", .{ .n = old_time });
    updateValue(request, ":old_expires_at", .{ .n = old_expires_at });
    updateValue(request, ":old_hash", .{ .s = &request.old_hash_buffer });
    updateValue(request, ":new_state", .{
        .s = operation.stateToString(operation.statusToState(&replacement.status)),
    });
    updateValue(request, ":new_time", .{ .n = new_time });
    updateValue(request, ":new_expires_at", .{ .n = new_expires_at });
    try updateRequestResult(request, snapshot, replacement);
}

fn updateRequestResult(
    request: *UpdateRequest,
    snapshot: *const operation.Operation,
    replacement: *const operation.Operation,
) !void {
    if (operation.statusCompletion(&snapshot.status)) |completion| {
        const serialized = try operation.writeCompletionJSON(
            &request.old_result_buffer,
            completion,
        );
        updateValue(request, ":old_result", .{ .s = serialized });
        request.condition_expression = condition_with_result;
    } else {
        request.condition_expression = condition_without_result;
    }
    if (operation.statusCompletion(&replacement.status)) |completion| {
        const serialized = try operation.writeCompletionJSON(
            &request.new_result_buffer,
            completion,
        );
        updateValue(request, ":new_result", .{ .s = serialized });
        request.update_expression = update_with_result;
    } else {
        request.update_expression = update_without_result;
    }
    std.debug.assert(request.value_count >= 10);
    std.debug.assert(request.value_count <= request.values.len);
}

fn completionRequestInit(
    request: *CompletionRequest,
    queued: *const operation.Operation,
    completion: *const operation.Completion,
    now: operation.UnixSeconds,
) !void {
    try validateCompletion(queued);
    const expires_at = try operation.expires_at_from_last_updated(now);
    const result = try operation.writeCompletionJSON(&request.result_buffer, completion);
    const id = operation.uuidToString(queued.id, &request.id_buffer);
    request.hash_buffer = std.fmt.bytesToHex(queued.hash.?, .lower);
    request.key = .{stringAttribute("id", id)};
    request.names = .{
        .{ .key = "#hash", .value = "hash" },
        .{ .key = "#name", .value = "name" },
        .{ .key = "#result", .value = "result" },
        .{ .key = "#state", .value = "state" },
        .{ .key = "#tenant", .value = "tenant" },
    };
    request.values = .{
        stringAttribute(":id", id),
        stringAttribute(":tenant", queued.tenant),
        stringAttribute(":name", queued.name),
        stringAttribute(":hash", &request.hash_buffer),
        stringAttribute(":submitted", operation.stateToString(.submitted)),
        stringAttribute(":completed", operation.stateToString(.completed)),
        numberAttribute(":now", timestampString(now, &request.timestamp_buffer)),
        numberAttribute(":expires_at", timestampString(
            expires_at,
            &request.expires_at_buffer,
        )),
        stringAttribute(":result", result),
    };
    std.debug.assert(request.key.len == 1);
    std.debug.assert(request.values.len == 9);
}

fn updateValue(request: *UpdateRequest, key: []const u8, value: AttributeValue) void {
    std.debug.assert(request.value_count < request.values.len);
    request.values[request.value_count] = .{ .key = key, .value = value };
    request.value_count += 1;
    std.debug.assert(request.value_count <= request.values.len);
}

const condition_without_result =
    "id = :id AND #tenant = :old_tenant AND #name = :old_name AND " ++
    "#state = :old_state AND " ++
    "last_updated = :old_time AND expires_at = :old_expires_at AND " ++
    "#hash = :old_hash AND attribute_not_exists(#result)";
const condition_with_result =
    "id = :id AND #tenant = :old_tenant AND #name = :old_name AND " ++
    "#state = :old_state AND " ++
    "last_updated = :old_time AND expires_at = :old_expires_at AND " ++
    "#hash = :old_hash AND #result = :old_result";
const update_without_result =
    "SET #state = :new_state, last_updated = :new_time, " ++
    "expires_at = :new_expires_at REMOVE #result";
const update_with_result =
    "SET #state = :new_state, last_updated = :new_time, " ++
    "expires_at = :new_expires_at, #result = :new_result";
const completion_condition =
    "id = :id AND #tenant = :tenant AND #name = :name AND " ++
    "#hash = :hash AND #state = :submitted AND attribute_not_exists(#result)";
const completion_update =
    "SET #state = :completed, #result = :result, " ++
    "last_updated = :now, expires_at = :expires_at";

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
    tenant: ?[]const u8 = null,
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
        } else if (std.mem.eql(u8, attribute.key, "tenant")) {
            if (fields.tenant != null) return error.InvalidItem;
            fields.tenant = try stringValue(attribute.value);
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
        const status: operation.Status = switch (state) {
            .submitted => status: {
                if (fields.result != null) return error.InvalidItem;
                break :status .submitted;
            },
            .completed => status: {
                const result_text = fields.result orelse return error.InvalidItem;
                break :status .{ .completed = try parseStoredCompletion(arena, result_text) };
            },
        };
        const name_text = fields.name orelse return error.InvalidItem;
        const tenant_text = fields.tenant orelse return error.InvalidItem;
        operation.validateTenant(tenant_text) catch return error.InvalidItem;
        return .{
            .id = id,
            .tenant = try arena.dupe(u8, tenant_text),
            .name = try arena.dupe(u8, name_text),
            .status = status,
            .last_updated = try timestampFromString(fields.last_updated orelse {
                return error.InvalidItem;
            }),
            .expires_at = try timestampFromString(fields.expires_at orelse {
                return error.InvalidItem;
            }),
            .hash = try hashFromString(fields.hash orelse return error.InvalidItem),
        };
    }
};

fn parseStoredCompletion(
    arena: Allocator,
    result_text: []const u8,
) !operation.Completion {
    const completion = operation.parseCompletionJSON(arena, result_text) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidItem,
        };
    };
    var canonical_buffer: [operation.result_size_max]u8 = undefined;
    const canonical = operation.writeCompletionJSON(&canonical_buffer, &completion) catch {
        return error.InvalidItem;
    };
    if (!std.mem.eql(u8, result_text, canonical)) return error.InvalidItem;
    return completion;
}

fn persistentCopy(source: *const operation.Operation) operation.Operation {
    var persisted = source.*;
    persisted.body = null;
    return persisted;
}

fn validateStored(source: *const operation.Operation) !void {
    try operation.validatePersistent(source);
}

fn validateCreation(source: *const operation.Operation) !void {
    try validateStored(source);
    if (source.status != .submitted) return error.InvalidState;
}

fn validateCompletion(queued: *const operation.Operation) !void {
    if (queued.status != .submitted) return error.InvalidState;
    if (queued.body == null) return error.MissingBody;
    var persisted = queued.*;
    persisted.body = null;
    try validateStored(&persisted);
    std.debug.assert(persisted.status == .submitted);
}

fn validateUpdate(
    snapshot: *const operation.Operation,
    replacement: *const operation.Operation,
) !void {
    try validateStored(snapshot);
    try validateStored(replacement);
    if (snapshot.id != replacement.id) return error.ImmutableField;
    if (!std.mem.eql(u8, snapshot.tenant, replacement.tenant)) return error.ImmutableField;
    if (!std.mem.eql(u8, snapshot.name, replacement.name)) return error.ImmutableField;
    if (!std.mem.eql(u8, &snapshot.hash.?, &replacement.hash.?)) return error.ImmutableField;
    try operation.validateStatusTransition(&snapshot.status, &replacement.status);
    std.debug.assert(snapshot.body == null);
    std.debug.assert(replacement.body == null);
}

fn validateUpdateResult(
    updated: *const operation.Operation,
    replacement: *const operation.Operation,
) !void {
    if (updated.id != replacement.id) return error.InvalidItem;
    if (!std.mem.eql(u8, updated.tenant, replacement.tenant)) return error.InvalidItem;
    if (!std.mem.eql(u8, updated.name, replacement.name)) return error.InvalidItem;
    if (!std.mem.eql(u8, &updated.hash.?, &replacement.hash.?)) return error.InvalidItem;
    if (!try statusEqual(&updated.status, &replacement.status)) return error.InvalidItem;
    if (updated.last_updated != replacement.last_updated) return error.InvalidItem;
    if (updated.expires_at != replacement.expires_at) return error.InvalidItem;
}

fn createError(
    arena: Allocator,
    err: anyerror,
    diagnostic: *dynamodb.ServiceError,
    requested: *const operation.Operation,
) anyerror!operation.Operation {
    if (err != error.ServiceError) return error.AWSFailure;
    defer diagnostic.deinit();
    const failure = switch (diagnostic.kind) {
        .conditional_check_failed_exception => |value| value,
        else => return error.AWSFailure,
    };
    const item = failure.item orelse return error.InvalidItem;
    const existing = try decodeItem(arena, item);
    if (!std.mem.eql(u8, existing.tenant, requested.tenant)) {
        return error.OperationConflict;
    }
    if (!std.mem.eql(u8, &existing.hash.?, &requested.hash.?)) {
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

fn configuredTableName(environment: *const std.process.Environ.Map) ![]const u8 {
    const table_name = environment.get("OPERATIONS_TABLE_NAME") orelse {
        return error.InvalidConfiguration;
    };
    validateTableName(table_name) catch return error.InvalidConfiguration;
    std.debug.assert(table_name.len >= 3);
    std.debug.assert(table_name.len <= 255);
    return table_name;
}

fn validateTableName(table_name: []const u8) !void {
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

fn statusEqual(first: *const operation.Status, second: *const operation.Status) !bool {
    if (operation.statusToState(first) != operation.statusToState(second)) return false;
    if (operation.statusCompletion(first)) |first_completion| {
        const second_completion = operation.statusCompletion(second) orelse return false;
        var first_buffer: [operation.result_size_max]u8 = undefined;
        var second_buffer: [operation.result_size_max]u8 = undefined;
        const first_json = try operation.writeCompletionJSON(&first_buffer, first_completion);
        const second_json = try operation.writeCompletionJSON(&second_buffer, second_completion);
        return std.mem.eql(u8, first_json, second_json);
    }
    return operation.statusCompletion(second) == null;
}

const test_id = "00112233-4455-6677-8899-aabbccddeeff";
const test_hash = [_]u8{0xAB} ** 32;

fn testOperation(state: operation.State, completion: ?operation.Completion) operation.Operation {
    return .{
        .id = operation.uuidFromString(test_id) catch unreachable,
        .tenant = "tenant-a",
        .name = "echo",
        .status = switch (state) {
            .submitted => .submitted,
            .completed => .{ .completed = completion.? },
        },
        .last_updated = 1_700_000_000,
        .expires_at = 1_700_086_400,
        .hash = test_hash,
    };
}

fn testCompletion(arena: Allocator, input_json: []const u8) !operation.Completion {
    return operation.parseCompletionJSON(arena, input_json);
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

test "items round trip submitted and both completed outcomes without body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const completions = [_]?operation.Completion{
        null,
        .{ .success = .{ .bool = true } },
        .{ .failure = .{ .bool = false } },
    };
    for (completions) |completion| {
        const state: operation.State = if (completion == null) .submitted else .completed;
        var source = testOperation(state, completion);
        source.body = .{ .bool = true };
        const persisted = persistentCopy(&source);
        try validateStored(&persisted);
        var request: CreateRequest = undefined;
        try createRequestInit(&request, &persisted);
        const item = request.items[0..request.item_count];
        const decoded = try decodeItem(arena.allocator(), item);

        try std.testing.expectEqual(state, operation.statusToState(&decoded.status));
        try std.testing.expectEqualStrings(
            operation.stateToString(state),
            try stringValue(findAttribute(item, "state").?),
        );
        try std.testing.expectEqualStrings("tenant-a", decoded.tenant);
        try std.testing.expect(decoded.tenant.ptr != source.tenant.ptr);
        try std.testing.expect(findAttribute(item, "body") == null);
        try std.testing.expectEqual(
            operation.stateIsTerminal(state),
            operation.statusCompletion(&decoded.status) != null,
        );
        try std.testing.expectEqual(@as(usize, request.item_count), item.len);
    }
}

test "create request uses the exact item contract and returns a failed condition item" {
    const source = testOperation(.submitted, null);
    var request: CreateRequest = undefined;
    try createRequestInit(&request, &source);
    try std.testing.expectEqual(@as(u8, 7), request.item_count);
    try std.testing.expectEqualStrings("00112233-4455-6677-8899-aabbccddeeff", try stringValue(
        findAttribute(request.items[0..request.item_count], "id").?,
    ));
    try std.testing.expectEqualStrings("tenant-a", try stringValue(
        findAttribute(request.items[0..request.item_count], "tenant").?,
    ));
    const expected_keys = [_][]const u8{
        "id",
        "tenant",
        "name",
        "state",
        "last_updated",
        "expires_at",
        "hash",
    };
    for (request.items[0..request.item_count], expected_keys) |attribute, key| {
        try std.testing.expectEqualStrings(key, attribute.key);
    }
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

test "creation requires a SUBMITTED persistent Operation" {
    try validateCreation(&testOperation(.submitted, null));
    try std.testing.expectError(
        error.InvalidState,
        validateCreation(&testOperation(.completed, .{ .success = .{ .bool = true } })),
    );
}

test "persistent copy omits the private body without copying arena-owned Values" {
    var source = testOperation(.submitted, null);
    source.body = .{ .bool = true };
    const created = persistentCopy(&source);

    try std.testing.expect(created.body == null);
    try std.testing.expectEqual(source.id, created.id);
    try std.testing.expectEqualStrings(source.tenant, created.tenant);
    try std.testing.expect(try statusEqual(&source.status, &created.status));
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

test "decoder rejects missing and malformed tenant attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = testOperation(.submitted, null);
    var request: CreateRequest = undefined;
    try createRequestInit(&request, &source);
    const valid = request.items[0..request.item_count];
    const missing_tenant = [_]Attribute{
        valid[0],
        valid[2],
        valid[3],
        valid[4],
        valid[5],
        valid[6],
    };
    try std.testing.expectError(
        error.InvalidItem,
        decodeItem(arena.allocator(), &missing_tenant),
    );
    const invalid_values = [_]AttributeValue{
        .{ .n = "1" },
        .{ .s = "" },
        .{ .s = "a" ** (operation.tenant_size_max + 1) },
        .{ .s = &.{0xFF} },
    };
    for (invalid_values) |invalid| {
        var malformed = request.items;
        malformed[1].value = invalid;
        try std.testing.expectError(
            error.InvalidItem,
            decodeItem(arena.allocator(), malformed[0..7]),
        );
    }
}

test "decoder rejects duplicate unknown wrong and malformed attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = testOperation(.submitted, null);
    var request: CreateRequest = undefined;
    try createRequestInit(&request, &source);

    var duplicate = request.items;
    duplicate[7] = duplicate[0];
    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), &duplicate));
    var unknown = request.items;
    unknown[7] = stringAttribute("body", "null");
    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), &unknown));
    var malformed = request.items;
    malformed[0].value = .{ .s = "00112233-4455-6677-8899-AABBCCDDEEFF" };
    try std.testing.expectError(
        error.InvalidItem,
        decodeItem(arena.allocator(), malformed[0..7]),
    );
    malformed = request.items;
    for ([_][]const u8{
        "UNKNOWN",
        "submitted",
        "completed",
    }) |state| {
        malformed[3].value = .{ .s = state };
        try std.testing.expectError(
            error.InvalidItem,
            decodeItem(arena.allocator(), malformed[0..7]),
        );
    }
    malformed = request.items;
    malformed[4].value = .{ .n = "01700000000" };
    try std.testing.expectError(
        error.InvalidItem,
        decodeItem(arena.allocator(), malformed[0..7]),
    );
    malformed = request.items;
    malformed[5].value = .{ .s = "1700086400" };
    try std.testing.expectError(
        error.InvalidItem,
        decodeItem(arena.allocator(), malformed[0..7]),
    );
    malformed = request.items;
    malformed[5].value = .{ .n = "1700086401" };
    try std.testing.expectError(
        error.InvalidItem,
        decodeItem(arena.allocator(), malformed[0..7]),
    );
    malformed = request.items;
    malformed[6].value = .{ .s = "AB" ** 32 };
    try std.testing.expectError(
        error.InvalidItem,
        decodeItem(arena.allocator(), malformed[0..7]),
    );
    malformed = request.items;
    malformed[7] = stringAttribute("result", "null");
    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), &malformed));
}

test "decoder enforces completion presence type canonical envelope and size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = testOperation(
        .completed,
        try testCompletion(
            arena.allocator(),
            "{\"type\":\"SUCCESS\",\"payload\":{\"ok\":true}}",
        ),
    );
    var request: CreateRequest = undefined;
    try createRequestInit(&request, &source);
    _ = try decodeItem(arena.allocator(), &request.items);

    const missing_tenant = [_]Attribute{
        request.items[0],
        request.items[2],
        request.items[3],
        request.items[4],
        request.items[5],
        request.items[6],
        request.items[7],
    };
    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), &missing_tenant));
    try std.testing.expectError(
        error.InvalidItem,
        decodeItem(arena.allocator(), request.items[0..7]),
    );
    var malformed = request.items;
    malformed[7].value = .{ .n = "1" };
    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), &malformed));
    malformed = request.items;
    malformed[7].value = .{ .s = "null" };
    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), &malformed));
    malformed = request.items;
    malformed[7].value = .{ .s = "{broken" };
    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), &malformed));
    malformed = request.items;
    malformed[7].value = .{ .s = "{\"type\":\"SUCCESS\", \"payload\":true}" };
    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), &malformed));
    malformed = request.items;
    malformed[7].value = .{ .s = "{\"type\":\"success\",\"payload\":true}" };
    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), &malformed));
    malformed = request.items;
    malformed[7].value = .{ .s = "{\"type\":\"SUCCESS\",\"payload\":true,\"extra\":1}" };
    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), &malformed));
    malformed = request.items;
    malformed[7].value = .{ .s = "{\"type\":\"SUCCESS\",\"payload\":null}" };
    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), &malformed));
    const oversized = "{\"type\":\"SUCCESS\",\"payload\":\"" ++
        ("a" ** (operation.result_size_max - 30)) ++ "\"}";
    malformed = request.items;
    malformed[7].value = .{ .s = oversized };
    try std.testing.expectError(error.InvalidItem, decodeItem(arena.allocator(), &malformed));
}

test "completion envelopes round trip through canonical DynamoDB strings" {
    const inputs = [_][]const u8{
        "{\"type\":\"SUCCESS\",\"payload\":true}",
        "{\"type\":\"FAILURE\",\"payload\":42}",
        "{\"type\":\"SUCCESS\",\"payload\":\"text\"}",
        "{\"type\":\"FAILURE\",\"payload\":[true,42]}",
        "{\"type\":\"SUCCESS\",\"payload\":{\"second\":2,\"first\":1}}",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (inputs) |canonical| {
        const source = testOperation(
            .completed,
            try testCompletion(arena.allocator(), canonical),
        );
        var request: CreateRequest = undefined;
        try createRequestInit(&request, &source);
        try std.testing.expectEqualStrings(canonical, try stringValue(
            findAttribute(request.items[0..request.item_count], "result").?,
        ));
        const decoded = try decodeItem(arena.allocator(), request.items[0..request.item_count]);
        try std.testing.expectEqual(operation.State.completed, operation.statusToState(
            &decoded.status,
        ));
        var result_buffer: [operation.result_size_max]u8 = undefined;
        try std.testing.expectEqualStrings(
            canonical,
            try operation.writeCompletionJSON(
                &result_buffer,
                operation.statusCompletion(&decoded.status).?,
            ),
        );
    }
}

test "updates snapshot every stored field and return all new attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snapshot = testOperation(.submitted, null);
    var replacement = snapshot;
    replacement.status = .{ .completed = try testCompletion(
        arena.allocator(),
        "{\"type\":\"SUCCESS\",\"payload\":{\"ok\":true}}",
    ) };
    replacement.last_updated.? += 1;
    replacement.expires_at.? += 1;
    try validateUpdate(&snapshot, &replacement);
    var request: UpdateRequest = undefined;
    try updateRequestInit(&request, &snapshot, &replacement);

    try std.testing.expectEqualStrings(condition_without_result, request.condition_expression);
    try std.testing.expectEqualStrings(update_with_result, request.update_expression);
    try std.testing.expectEqualStrings("tenant-a", try stringValue(
        findUpdateValue(&request, ":old_tenant").?,
    ));
    try std.testing.expect(std.mem.indexOf(
        u8,
        request.condition_expression,
        "#tenant = :old_tenant",
    ) != null);
    try std.testing.expectEqualStrings("SUBMITTED", try stringValue(
        findUpdateValue(&request, ":old_state").?,
    ));
    try std.testing.expectEqualStrings("COMPLETED", try stringValue(
        findUpdateValue(&request, ":new_state").?,
    ));
    try std.testing.expectEqualStrings("1700086400", try numberValue(
        findUpdateValue(&request, ":old_expires_at").?,
    ));
    try std.testing.expectEqualStrings("1700086401", try numberValue(
        findUpdateValue(&request, ":new_expires_at").?,
    ));
    try std.testing.expectEqualStrings(
        "{\"type\":\"SUCCESS\",\"payload\":{\"ok\":true}}",
        try stringValue(
            findUpdateValue(&request, ":new_result").?,
        ),
    );
    const input = dynamodb.UpdateItemInput{
        .expression_attribute_names = &request.names,
        .expression_attribute_values = request.values[0..request.value_count],
        .key = &request.key,
        .return_values = .all_new,
        .table_name = "operations",
    };
    try std.testing.expectEqual(dynamodb.types.ReturnValue.all_new, input.return_values.?);
}

test "completion condition matches queued identity without timestamp conditions" {
    var queued = testOperation(.submitted, null);
    queued.body = .{ .bool = true };
    const completion: operation.Completion = .{ .success = .{ .bool = true } };
    var request: CompletionRequest = undefined;
    try completionRequestInit(&request, &queued, &completion, 1_800_000_000);

    try std.testing.expectEqualStrings(
        "id = :id AND #tenant = :tenant AND #name = :name AND " ++
            "#hash = :hash AND #state = :submitted AND attribute_not_exists(#result)",
        completion_condition,
    );
    try std.testing.expect(std.mem.indexOf(u8, completion_condition, "#state") != null);
    try std.testing.expect(std.mem.indexOf(u8, completion_condition, "last_updated") == null);
    try std.testing.expect(std.mem.indexOf(u8, completion_condition, "expires_at") == null);
    try std.testing.expectEqualStrings(test_id, try stringValue(request.key[0].value));
    try std.testing.expectEqualStrings(test_id, try stringValue(
        findAttribute(&request.values, ":id").?,
    ));
    try std.testing.expectEqualStrings("tenant-a", try stringValue(
        findAttribute(&request.values, ":tenant").?,
    ));
    try std.testing.expectEqualStrings("echo", try stringValue(
        findAttribute(&request.values, ":name").?,
    ));
    try std.testing.expectEqualStrings("SUBMITTED", try stringValue(
        findAttribute(&request.values, ":submitted").?,
    ));
    try std.testing.expectEqualStrings("ab" ** 32, try stringValue(
        findAttribute(&request.values, ":hash").?,
    ));
}

test "completion persists exact result envelopes and record timestamps without returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var queued = testOperation(.submitted, null);
    queued.body = .{ .bool = true };
    const envelopes = [_][]const u8{
        "{\"type\":\"SUCCESS\",\"payload\":{" ++
            "\"transfer_id\":\"00112233-4455-6677-8899-aabbccddeeff\"}}",
        "{\"type\":\"FAILURE\",\"payload\":{\"stage\":\"ACCOUNT\",\"status\":19}}",
        "{\"type\":\"FAILURE\",\"payload\":{\"stage\":\"TRANSFER\",\"status\":22}}",
    };
    for (envelopes) |envelope| {
        const completion = try testCompletion(arena.allocator(), envelope);
        var request: CompletionRequest = undefined;
        try completionRequestInit(&request, &queued, &completion, 1_800_000_123);

        try std.testing.expectEqualStrings("SUBMITTED", try stringValue(
            findAttribute(&request.values, ":submitted").?,
        ));
        try std.testing.expectEqualStrings("COMPLETED", try stringValue(
            findAttribute(&request.values, ":completed").?,
        ));
        try std.testing.expectEqualStrings(envelope, try stringValue(
            findAttribute(&request.values, ":result").?,
        ));
        try std.testing.expectEqualStrings("1800000123", try numberValue(
            findAttribute(&request.values, ":now").?,
        ));
        try std.testing.expectEqualStrings("1800086523", try numberValue(
            findAttribute(&request.values, ":expires_at").?,
        ));

        const input = dynamodb.UpdateItemInput{
            .condition_expression = completion_condition,
            .expression_attribute_names = &request.names,
            .expression_attribute_values = &request.values,
            .key = &request.key,
            .table_name = "operations",
            .update_expression = completion_update,
        };
        try std.testing.expectEqualStrings(completion_condition, input.condition_expression.?);
        try std.testing.expectEqualStrings(completion_update, input.update_expression.?);
        try std.testing.expect(input.return_values == null);
        try std.testing.expect(input.return_values_on_condition_check_failure == null);
    }
}

test "completion request enforces the full 4096 byte envelope boundary" {
    var queued = testOperation(.submitted, null);
    queued.body = .{ .bool = true };
    const maximum: operation.Completion = .{
        .success = .{ .string = "a" ** (operation.result_size_max - 31) },
    };
    var request: CompletionRequest = undefined;
    try completionRequestInit(&request, &queued, &maximum, 1_800_000_123);
    try std.testing.expectEqual(
        @as(usize, operation.result_size_max),
        (try stringValue(findAttribute(&request.values, ":result").?)).len,
    );

    const oversized: operation.Completion = .{
        .success = .{ .string = "a" ** (operation.result_size_max - 30) },
    };
    try std.testing.expectError(
        error.ResultTooLarge,
        completionRequestInit(&request, &queued, &oversized, 1_800_000_123),
    );
}

test "completion accepts only queued SUBMITTED operations with body" {
    var queued = testOperation(.submitted, null);
    queued.body = .null;
    try validateCompletion(&queued);

    queued.status = .{ .completed = .{ .success = .{ .bool = true } } };
    try std.testing.expectError(error.InvalidState, validateCompletion(&queued));
    queued.status = .{ .completed = .{ .failure = .{ .bool = false } } };
    try std.testing.expectError(error.InvalidState, validateCompletion(&queued));
    queued = testOperation(.submitted, null);
    try std.testing.expectError(error.MissingBody, validateCompletion(&queued));
}

test "updates enforce every status transition" {
    const statuses = [_]operation.Status{
        .submitted,
        .{ .completed = .{ .success = .{ .bool = true } } },
        .{ .completed = .{ .failure = .{ .bool = false } } },
    };
    for (statuses) |current| {
        for (statuses) |target| {
            var snapshot = testOperation(.submitted, null);
            snapshot.status = current;
            var replacement = snapshot;
            replacement.status = target;
            replacement.last_updated.? += 1;
            replacement.expires_at.? += 1;
            const allowed = current == .submitted;
            if (allowed) {
                try validateUpdate(&snapshot, &replacement);
            } else {
                try std.testing.expectError(
                    error.InvalidTransition,
                    validateUpdate(&snapshot, &replacement),
                );
            }
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
    replacement.tenant = "tenant-b";
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
    const replacement = testOperation(.submitted, null);
    var updated = replacement;
    try validateUpdateResult(&updated, &replacement);

    updated.expires_at.? += 1;
    try std.testing.expectError(
        error.InvalidItem,
        validateUpdateResult(&updated, &replacement),
    );
    updated = replacement;
    updated.tenant = "tenant-b";
    try std.testing.expectError(
        error.InvalidItem,
        validateUpdateResult(&updated, &replacement),
    );
}

test "update result requires exact completion outcome and canonical payload" {
    const replacement = testOperation(.completed, .{ .success = .{ .bool = true } });
    var updated = replacement;
    try validateUpdateResult(&updated, &replacement);

    updated.status = testOperation(.completed, .{ .failure = .{ .bool = true } }).status;
    try std.testing.expectError(
        error.InvalidItem,
        validateUpdateResult(&updated, &replacement),
    );
    updated.status = testOperation(.completed, .{ .success = .{ .bool = false } }).status;
    try std.testing.expectError(
        error.InvalidItem,
        validateUpdateResult(&updated, &replacement),
    );
}

test "matching create retry returns the stored Operation in every state" {
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    const requested = testOperation(.submitted, null);
    const completions = [_]?operation.Completion{
        null,
        .{ .success = .{ .bool = true } },
        .{ .failure = .{ .bool = false } },
    };
    for (completions) |completion| {
        var existing = testOperation(
            if (completion == null) .submitted else .completed,
            completion,
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
            &requested,
        );
        try std.testing.expect(try statusEqual(&existing.status, &created.status));
        try std.testing.expectEqual(existing.last_updated, created.last_updated);
        try std.testing.expectEqual(existing.expires_at, created.expires_at);
        try std.testing.expectEqualStrings("echo", created.name);
        try std.testing.expect(created.body == null);
    }
}

test "create retry conflicts on a hash mismatch in every state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const requested = testOperation(.submitted, null);
    const completions = [_]?operation.Completion{
        null,
        .{ .success = .{ .bool = true } },
        .{ .failure = .{ .bool = false } },
    };
    for (completions) |completion| {
        var existing = testOperation(
            if (completion == null) .submitted else .completed,
            completion,
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
            &requested,
        ));
    }
}

test "create retry conflicts when a global UUID belongs to another tenant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const requested = testOperation(.submitted, null);
    var existing = requested;
    existing.tenant = "tenant-b";
    var request: CreateRequest = undefined;
    try createRequestInit(&request, &existing);
    var diagnostic = dynamodb.ServiceError{ .kind = .{ .conditional_check_failed_exception = .{
        .item = request.items[0..request.item_count],
    } } };

    try std.testing.expectError(error.OperationConflict, createError(
        arena.allocator(),
        error.ServiceError,
        &diagnostic,
        &requested,
    ));
}

test "create failure requires a valid returned item and preserves AWS failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const requested = testOperation(.submitted, null);
    var missing = dynamodb.ServiceError{
        .kind = .{ .conditional_check_failed_exception = .{} },
    };
    try std.testing.expectError(error.InvalidItem, createError(
        arena.allocator(),
        error.ServiceError,
        &missing,
        &requested,
    ));

    var request: CreateRequest = undefined;
    try createRequestInit(&request, &requested);
    var malformed = dynamodb.ServiceError{
        .kind = .{ .conditional_check_failed_exception = .{
            .item = request.items[0..4],
        } },
    };
    try std.testing.expectError(error.InvalidItem, createError(
        arena.allocator(),
        error.ServiceError,
        &malformed,
        &requested,
    ));

    var unrelated = dynamodb.ServiceError{
        .kind = .{ .unknown = .{ .http_status = 500 } },
    };
    try std.testing.expectError(error.AWSFailure, createError(
        arena.allocator(),
        error.ServiceError,
        &unrelated,
        &requested,
    ));
    var unused: dynamodb.ServiceError = undefined;
    try std.testing.expectError(error.AWSFailure, createError(
        arena.allocator(),
        error.ConnectionFailed,
        &unused,
        &requested,
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

test "initialization requires table configuration" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var config: aws.Config = undefined;
    var persistence: Persistence = undefined;

    try std.testing.expectError(
        error.InvalidConfiguration,
        Persistence.init(
            &persistence,
            std.testing.allocator,
            &config,
            &environment,
        ),
    );
}

test "initialization rejects malformed and oversized table configuration" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var config: aws.Config = undefined;
    var persistence: Persistence = undefined;
    const invalid_names = [_][]const u8{
        "",
        "ab",
        "operations/table",
        "operations table",
        "a" ** 256,
    };

    for (invalid_names) |table_name| {
        try environment.put("OPERATIONS_TABLE_NAME", table_name);
        try std.testing.expectError(
            error.InvalidConfiguration,
            Persistence.init(
                &persistence,
                std.testing.allocator,
                &config,
                &environment,
            ),
        );
    }
}

test "initialization retains valid table configuration and shared AWS configuration" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var config: aws.Config = undefined;
    const valid_names = [_][]const u8{
        "abc",
        "operations-table.1",
        "a" ** 255,
    };

    for (valid_names) |table_name| {
        try environment.put("OPERATIONS_TABLE_NAME", table_name);
        var persistence: Persistence = undefined;
        try Persistence.init(
            &persistence,
            std.testing.allocator,
            &config,
            &environment,
        );
        defer persistence.deinit();

        try std.testing.expect(persistence.client.config == &config);
        try std.testing.expectEqualStrings(table_name, persistence.table_name);
    }
}
