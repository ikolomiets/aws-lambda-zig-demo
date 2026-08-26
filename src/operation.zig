const std = @import("std");

const Allocator = std.mem.Allocator;
const JSONValue = std.json.Value;

pub const UnixSeconds = i64;
pub const body_size_max = 4096;
pub const result_size_max = 4096;
pub const name_size_max = 64;
pub const tenant_size_max = 64;
pub const output_size_max = body_size_max + result_size_max + 2048;
pub const ttl_seconds: UnixSeconds = 24 * 60 * 60;
const uuid_string_size = 36;
const hash_string_size = 64;

comptime {
    std.debug.assert(body_size_max == result_size_max);
    std.debug.assert(output_size_max > body_size_max + result_size_max);
    std.debug.assert(ttl_seconds == 86_400);
    std.debug.assert(uuid_string_size == 36);
    std.debug.assert(hash_string_size == 2 * 32);
}

pub const State = enum {
    new,
    succeeded,
    failed,
};

/// Parses the uppercase representation shared by JSON and persistent storage.
pub fn stateFromString(value: []const u8) !State {
    if (std.mem.eql(u8, value, "NEW")) return .new;
    if (std.mem.eql(u8, value, "SUCCEEDED")) return .succeeded;
    if (std.mem.eql(u8, value, "FAILED")) return .failed;
    return error.InvalidState;
}

/// Returns the uppercase representation shared by JSON and persistent storage.
pub fn stateToString(state: State) []const u8 {
    return switch (state) {
        .new => "NEW",
        .succeeded => "SUCCEEDED",
        .failed => "FAILED",
    };
}

/// Reports whether the state requires a non-null result.
pub fn stateIsTerminal(state: State) bool {
    return switch (state) {
        .succeeded, .failed => true,
        .new => false,
    };
}

/// Validates a monotonic lifecycle transition, including same-state refreshes.
pub fn validateStateTransition(current: State, replacement: State) !void {
    switch (current) {
        .new => {},
        .succeeded => if (replacement != .succeeded) return error.InvalidTransition,
        .failed => if (replacement != .failed) return error.InvalidTransition,
    }
}

pub const Operation = struct {
    id: u128,
    tenant: []const u8,
    name: []const u8,
    body: ?JSONValue = null,
    state: ?State = null,
    /// Callers must update both timestamps together for every Operation update.
    last_updated: ?UnixSeconds = null,
    /// DynamoDB may delete this Operation after this Unix timestamp.
    expires_at: ?UnixSeconds = null,
    result: ?JSONValue = null,
    hash: ?[32]u8 = null,
};

const InputFields = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    body: ?[]const u8 = null,
    state: ?[]const u8 = null,
};

const OutputFields = struct {
    id: ?[]const u8 = null,
    tenant: ?[]const u8 = null,
    name: ?[]const u8 = null,
    body: ?[]const u8 = null,
    state: ?[]const u8 = null,
    last_updated: ?[]const u8 = null,
    expires_at: ?[]const u8 = null,
    result: ?[]const u8 = null,
    hash: ?[]const u8 = null,
};

/// Parses the input view into values owned by the lifetime arena.
pub fn parseInputJSON(
    arena: Allocator,
    input_json: []const u8,
    options: struct {
        tenant: []const u8,
        now: UnixSeconds,
    },
) !Operation {
    try validateTenant(options.tenant);
    const tenant = try arena.dupe(u8, options.tenant);
    const fields = try scanInputFields(arena, input_json);
    const id_json = fields.id orelse return error.MissingField;
    const name_json = fields.name orelse return error.MissingField;
    const body_json = fields.body orelse return error.MissingField;

    const id_string = try parseJSONString(arena, id_json);
    const id = try uuidFromString(id_string);
    const name = try parseJSONString(arena, name_json);
    try validateName(name);

    const state = if (fields.state) |state_json|
        try parseInputState(arena, state_json)
    else
        State.new;
    if (body_json.len > body_size_max) return error.BodyTooLarge;
    const body = try parseJSONValue(arena, body_json);
    const hash = try operationHash(tenant, name, &body);
    const expires_at = try expires_at_from_last_updated(options.now);

    return .{
        .id = id,
        .tenant = tenant,
        .name = name,
        .body = body,
        .state = state,
        .last_updated = options.now,
        .expires_at = expires_at,
        .hash = hash,
    };
}

/// Parses the complete output view into values owned by the lifetime arena.
pub fn parseOutputJSON(arena: Allocator, output_json: []const u8) !Operation {
    if (output_json.len > output_size_max) return error.OutputTooLarge;
    const fields = try scanOutputFields(arena, output_json);
    const id_text = try parseJSONString(arena, fields.id orelse return error.MissingField);
    const id = try uuidFromString(id_text);
    var id_buffer: [uuid_string_size]u8 = undefined;
    if (!std.mem.eql(u8, id_text, uuidToString(id, &id_buffer))) {
        return error.InvalidUUID;
    }
    const tenant = try parseJSONString(arena, fields.tenant orelse return error.MissingField);
    const name = try parseJSONString(arena, fields.name orelse return error.MissingField);
    const state_text = try parseJSONString(arena, fields.state orelse return error.MissingField);
    const hash_text = try parseJSONString(arena, fields.hash orelse return error.MissingField);

    const body = if (fields.body) |body_json| body: {
        if (body_json.len > body_size_max) return error.BodyTooLarge;
        break :body try parseJSONValue(arena, body_json);
    } else null;
    const result = if (fields.result) |result_json| result: {
        if (result_json.len > result_size_max) return error.ResultTooLarge;
        break :result try parseJSONValue(arena, result_json);
    } else null;
    const parsed: Operation = .{
        .id = id,
        .tenant = tenant,
        .name = name,
        .body = body,
        .state = try stateFromString(state_text),
        .last_updated = try parseJSONInteger(
            arena,
            fields.last_updated orelse return error.MissingField,
        ),
        .expires_at = try parseJSONInteger(
            arena,
            fields.expires_at orelse return error.MissingField,
        ),
        .result = result,
        .hash = try hashFromString(hash_text),
    };
    _ = try validateView(&parsed);
    return parsed;
}

/// Computes the fixed DynamoDB expiration timestamp for an Operation update.
pub fn expires_at_from_last_updated(last_updated: UnixSeconds) !UnixSeconds {
    const expires_at = std.math.add(
        UnixSeconds,
        last_updated,
        ttl_seconds,
    ) catch return error.InvalidExpiresAt;
    if (expires_at <= last_updated) return error.InvalidExpiresAt;
    std.debug.assert(expires_at > last_updated);
    std.debug.assert(expires_at - last_updated == ttl_seconds);
    return expires_at;
}

/// Parses a bounded, non-null terminal result into the lifetime arena.
pub fn parseResultJSON(arena: Allocator, input_json: []const u8) !JSONValue {
    if (input_json.len > result_size_max) return error.ResultTooLarge;
    const result = try parseJSONValue(arena, input_json);
    if (result == .null) return error.MissingResult;
    try validateResultSize(&result);
    return result;
}

/// Serializes a result compactly into the fixed persistence request buffer.
pub fn writeResultJSON(buffer: *[result_size_max]u8, result: *const JSONValue) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    std.json.Stringify.value(result.*, .{}, &writer) catch return error.ResultTooLarge;
    std.debug.assert(writer.buffered().len <= result_size_max);
    return writer.buffered();
}

/// Writes the Operation view while preserving body and result Values when present.
pub fn writeOutputJSON(
    writer: *std.Io.Writer,
    operation: *const Operation,
) !void {
    const result_present = try validateView(operation);
    const state = operation.state.?;
    const last_updated = operation.last_updated.?;
    const expires_at = operation.expires_at.?;
    const hash = operation.hash.?;
    var id_buffer: [uuid_string_size]u8 = undefined;
    const id = uuidToString(operation.id, &id_buffer);
    const hash_hex = std.fmt.bytesToHex(hash, .lower);

    var json: std.json.Stringify = .{
        .writer = writer,
        .options = .{},
    };
    try json.beginObject();
    try json.objectField("id");
    try json.write(id);
    try json.objectField("tenant");
    try json.write(operation.tenant);
    try json.objectField("name");
    try json.write(operation.name);
    if (operation.body) |body| {
        try json.objectField("body");
        try json.write(body);
    }
    try json.objectField("state");
    try json.write(stateToString(state));
    try json.objectField("last_updated");
    try json.write(last_updated);
    try json.objectField("expires_at");
    try json.write(expires_at);
    if (result_present) {
        try json.objectField("result");
        try json.write(operation.result.?);
    }
    try json.objectField("hash");
    try json.write(&hash_hex);
    try json.endObject();
}

/// Checks the invariants required before mapping an operation to a persistent entity.
pub fn validatePersistent(operation: *const Operation) !void {
    if (operation.body != null) return error.UnexpectedBody;
    _ = try validateView(operation);
}

/// Converts the canonical hyphenated UUID representation to its numeric representation.
pub fn uuidFromString(uuid: []const u8) !u128 {
    if (uuid.len != uuid_string_size) return error.InvalidUUID;

    var value: u128 = 0;
    var digit_count: u8 = 0;
    for (uuid, 0..) |character, index| {
        if (uuidHyphenIndex(index)) {
            if (character != '-') return error.InvalidUUID;
            continue;
        }
        const digit = std.fmt.charToDigit(character, 16) catch return error.InvalidUUID;
        value = (value << 4) | digit;
        digit_count += 1;
    }
    std.debug.assert(digit_count == 32);
    std.debug.assert(value <= std.math.maxInt(u128));
    return value;
}

/// Converts a numeric UUID to a lowercase canonical hyphenated representation.
pub fn uuidToString(id: u128, buffer: *[uuid_string_size]u8) []const u8 {
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &bytes, id, .big);
    const hex = std.fmt.bytesToHex(bytes, .lower);

    @memcpy(buffer[0..8], hex[0..8]);
    buffer[8] = '-';
    @memcpy(buffer[9..13], hex[8..12]);
    buffer[13] = '-';
    @memcpy(buffer[14..18], hex[12..16]);
    buffer[18] = '-';
    @memcpy(buffer[19..23], hex[16..20]);
    buffer[23] = '-';
    @memcpy(buffer[24..36], hex[20..32]);

    std.debug.assert(buffer.len == uuid_string_size);
    std.debug.assert(buffer[8] == '-');
    return buffer;
}

fn scanInputFields(arena: Allocator, input_json: []const u8) !InputFields {
    var scanner = std.json.Scanner.initCompleteInput(arena, input_json);
    defer scanner.deinit();

    const first = scanner.next() catch |err| return jsonError(err);
    if (first != .object_begin) return error.InvalidJSON;

    var fields: InputFields = .{};
    var field_count: u8 = 0;
    while (true) {
        const token = scanner.nextAllocMax(
            arena,
            .alloc_always,
            input_json.len,
        ) catch |err| return jsonError(err);
        if (token == .object_end) break;
        const field_name = switch (token) {
            .allocated_string => |value| value,
            else => return error.InvalidJSON,
        };
        const value_start = try jsonValueStart(input_json, scanner.cursor);
        try scannerSkipValue(&scanner);
        const value_json = input_json[value_start..scanner.cursor];
        try setInputField(&fields, field_name, value_json);
        field_count += 1;
        std.debug.assert(field_count <= 4);
    }
    const last = scanner.next() catch |err| return jsonError(err);
    if (last != .end_of_document) return error.InvalidJSON;
    return fields;
}

fn scanOutputFields(arena: Allocator, output_json: []const u8) !OutputFields {
    var scanner = std.json.Scanner.initCompleteInput(arena, output_json);
    defer scanner.deinit();

    const first = scanner.next() catch |err| return jsonError(err);
    if (first != .object_begin) return error.InvalidJSON;

    var fields: OutputFields = .{};
    var field_count: u8 = 0;
    while (true) {
        const token = scanner.nextAllocMax(
            arena,
            .alloc_always,
            output_json.len,
        ) catch |err| return jsonError(err);
        if (token == .object_end) break;
        const field_name = switch (token) {
            .allocated_string => |value| value,
            else => return error.InvalidJSON,
        };
        const value_start = try jsonValueStart(output_json, scanner.cursor);
        try scannerSkipValue(&scanner);
        const value_json = output_json[value_start..scanner.cursor];
        try setOutputField(&fields, field_name, value_json);
        field_count += 1;
        std.debug.assert(field_count <= 9);
    }
    const last = scanner.next() catch |err| return jsonError(err);
    if (last != .end_of_document) return error.InvalidJSON;
    return fields;
}

fn setOutputField(
    fields: *OutputFields,
    field_name: []const u8,
    value_json: []const u8,
) !void {
    if (std.mem.eql(u8, field_name, "id")) {
        if (fields.id != null) return error.DuplicateField;
        fields.id = value_json;
    } else if (std.mem.eql(u8, field_name, "tenant")) {
        if (fields.tenant != null) return error.DuplicateField;
        fields.tenant = value_json;
    } else if (std.mem.eql(u8, field_name, "name")) {
        if (fields.name != null) return error.DuplicateField;
        fields.name = value_json;
    } else if (std.mem.eql(u8, field_name, "body")) {
        if (fields.body != null) return error.DuplicateField;
        fields.body = value_json;
    } else if (std.mem.eql(u8, field_name, "state")) {
        if (fields.state != null) return error.DuplicateField;
        fields.state = value_json;
    } else if (std.mem.eql(u8, field_name, "last_updated")) {
        if (fields.last_updated != null) return error.DuplicateField;
        fields.last_updated = value_json;
    } else if (std.mem.eql(u8, field_name, "expires_at")) {
        if (fields.expires_at != null) return error.DuplicateField;
        fields.expires_at = value_json;
    } else if (std.mem.eql(u8, field_name, "result")) {
        if (fields.result != null) return error.DuplicateField;
        fields.result = value_json;
    } else if (std.mem.eql(u8, field_name, "hash")) {
        if (fields.hash != null) return error.DuplicateField;
        fields.hash = value_json;
    } else {
        return error.UnknownField;
    }
}

fn setInputField(
    fields: *InputFields,
    field_name: []const u8,
    value_json: []const u8,
) !void {
    if (std.mem.eql(u8, field_name, "id")) {
        if (fields.id != null) return error.DuplicateField;
        fields.id = value_json;
    } else if (std.mem.eql(u8, field_name, "name")) {
        if (fields.name != null) return error.DuplicateField;
        fields.name = value_json;
    } else if (std.mem.eql(u8, field_name, "body")) {
        if (fields.body != null) return error.DuplicateField;
        fields.body = value_json;
    } else if (std.mem.eql(u8, field_name, "state")) {
        if (fields.state != null) return error.DuplicateField;
        fields.state = value_json;
    } else if (std.mem.eql(u8, field_name, "tenant")) {
        return error.ForbiddenField;
    } else if (std.mem.eql(u8, field_name, "result")) {
        return error.ForbiddenField;
    } else if (std.mem.eql(u8, field_name, "hash")) {
        return error.ForbiddenField;
    } else if (std.mem.eql(u8, field_name, "last_updated")) {
        return error.ForbiddenField;
    } else if (std.mem.eql(u8, field_name, "expires_at")) {
        return error.ForbiddenField;
    } else {
        return error.UnknownField;
    }
}

fn jsonValueStart(input_json: []const u8, cursor_after_key: usize) !usize {
    // Inspect without advancing the scanner so that the original value bytes remain addressable.
    var cursor = cursor_after_key;
    while (cursor < input_json.len) : (cursor += 1) {
        if (!jsonWhitespace(input_json[cursor])) break;
    }
    if (cursor == input_json.len) return error.InvalidJSON;
    if (input_json[cursor] != ':') return error.InvalidJSON;
    cursor += 1;
    while (cursor < input_json.len) : (cursor += 1) {
        if (!jsonWhitespace(input_json[cursor])) break;
    }
    if (cursor == input_json.len) return error.InvalidJSON;
    return cursor;
}

fn scannerSkipValue(scanner: *std.json.Scanner) !void {
    const token_type = scanner.peekNextTokenType() catch |err| return jsonError(err);
    switch (token_type) {
        .object_end, .array_end, .end_of_document => return error.InvalidJSON,
        else => {},
    }
    scanner.skipValue() catch |err| return jsonError(err);
}

fn parseJSONString(arena: Allocator, json: []const u8) ![]const u8 {
    return std.json.parseFromSliceLeaky([]const u8, arena, json, .{
        .allocate = .alloc_always,
        .max_value_len = json.len,
    }) catch |err| return jsonError(err);
}

fn parseJSONInteger(arena: Allocator, json: []const u8) !UnixSeconds {
    return std.json.parseFromSliceLeaky(UnixSeconds, arena, json, .{
        .max_value_len = json.len,
    }) catch |err| return jsonError(err);
}

fn parseInputState(arena: Allocator, state_json: []const u8) !State {
    const state_string = try parseJSONString(arena, state_json);
    const state = try stateFromString(state_string);
    if (state != .new) return error.InvalidState;
    return state;
}

fn operationHash(tenant: []const u8, name: []const u8, body: *const JSONValue) ![32]u8 {
    var hash_buffer: [64]u8 = undefined;
    var hashing: std.Io.Writer.Hashing(std.crypto.hash.Blake3) = .init(&hash_buffer);
    try hashEnvelopeWrite(&hashing.writer, tenant, name, body);
    try hashing.writer.flush();
    var hash: [32]u8 = undefined;
    hashing.hasher.final(&hash);
    return hash;
}

fn hashEnvelopeWrite(
    writer: *std.Io.Writer,
    tenant: []const u8,
    name: []const u8,
    body: *const JSONValue,
) !void {
    var json: std.json.Stringify = .{
        .writer = writer,
        .options = .{},
    };
    try json.beginObject();
    try json.objectField("tenant");
    try json.write(tenant);
    try json.objectField("name");
    try json.write(name);
    try json.objectField("body");
    try json.write(body.*);
    try json.endObject();
}

fn parseJSONValue(arena: Allocator, json: []const u8) !JSONValue {
    return std.json.parseFromSliceLeaky(JSONValue, arena, json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .max_value_len = json.len,
        .parse_numbers = true,
    }) catch |err| return jsonError(err);
}

fn hashFromString(value: []const u8) ![32]u8 {
    if (value.len != hash_string_size) return error.InvalidHash;
    for (value) |character| {
        if (character >= '0' and character <= '9') continue;
        if (character >= 'a' and character <= 'f') continue;
        return error.InvalidHash;
    }
    var hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&hash, value) catch return error.InvalidHash;
    return hash;
}

fn validateView(operation: *const Operation) !bool {
    try validateTenant(operation.tenant);
    try validateName(operation.name);
    if (operation.body) |*body| try validateBodySize(body);
    const state = operation.state orelse return error.MissingState;
    const last_updated = operation.last_updated orelse return error.MissingLastUpdated;
    const expires_at = operation.expires_at orelse return error.MissingExpiresAt;
    const expected_expires_at = try expires_at_from_last_updated(last_updated);
    if (expires_at != expected_expires_at) return error.InvalidExpiresAt;
    if (operation.hash == null) return error.MissingHash;
    const result_present = operation.result != null;
    if (stateIsTerminal(state)) {
        if (!result_present) return error.MissingResult;
        if (operation.result.? == .null) return error.MissingResult;
    } else {
        if (operation.result) |result| {
            if (result != .null) return error.UnexpectedResult;
        }
    }
    if (operation.result) |*result| try validateResultSize(result);
    return result_present;
}

fn validateBodySize(body: *const JSONValue) !void {
    var count_buffer: [256]u8 = undefined;
    var counter: std.Io.Writer.Discarding = .init(&count_buffer);
    try std.json.Stringify.value(body.*, .{}, &counter.writer);
    if (counter.fullCount() > body_size_max) return error.BodyTooLarge;
}

/// Validates server-owned tenant metadata at every ingress and storage boundary.
pub fn validateTenant(tenant: []const u8) !void {
    if (tenant.len == 0) return error.InvalidTenant;
    if (tenant.len > tenant_size_max) return error.InvalidTenant;
    if (!std.unicode.utf8ValidateSlice(tenant)) return error.InvalidTenant;
    std.debug.assert(tenant.len > 0);
    std.debug.assert(tenant.len <= tenant_size_max);
}

fn validateResultSize(result: *const JSONValue) !void {
    var count_buffer: [256]u8 = undefined;
    var counter: std.Io.Writer.Discarding = .init(&count_buffer);
    try std.json.Stringify.value(result.*, .{}, &counter.writer);
    if (counter.fullCount() > result_size_max) return error.ResultTooLarge;
}

fn validateName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidName;
    if (name.len > name_size_max) return error.InvalidName;
    if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidName;
    std.debug.assert(name.len > 0);
    std.debug.assert(name.len <= name_size_max);
}

fn uuidHyphenIndex(index: usize) bool {
    if (index == 8) return true;
    if (index == 13) return true;
    if (index == 18) return true;
    return index == 23;
}

fn jsonWhitespace(character: u8) bool {
    if (character == ' ') return true;
    if (character == '\t') return true;
    if (character == '\n') return true;
    return character == '\r';
}

fn jsonError(err: anyerror) error{ OutOfMemory, InvalidJSON } {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJSON,
    };
}

const test_uuid = "00112233-4455-6677-8899-aabbccddeeff";
const test_tenant = "tenant-a";
const test_now: UnixSeconds = 1_700_000_000;

fn parseTestInput(arena: Allocator, input_json: []const u8, now: UnixSeconds) !Operation {
    return parseInputJSON(arena, input_json, .{
        .tenant = test_tenant,
        .now = now,
    });
}

fn testInput(
    allocator: Allocator,
    name: []const u8,
    body: []const u8,
    state: ?[]const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"id\":\"");
    try output.writer.writeAll(test_uuid);
    try output.writer.writeAll("\",\"name\":");
    try std.json.Stringify.value(name, .{}, &output.writer);
    try output.writer.writeAll(",\"body\":");
    try output.writer.writeAll(body);
    if (state) |value| {
        try output.writer.writeAll(",\"state\":");
        try std.json.Stringify.value(value, .{}, &output.writer);
    }
    try output.writer.writeByte('}');
    std.debug.assert(output.written().len > body.len);
    std.debug.assert(output.written().len > name.len);
    return output.toOwnedSlice();
}

fn testOutput(operation: *const Operation) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer output.deinit();
    try writeOutputJSON(&output.writer, operation);
    std.debug.assert(output.written().len > operation.name.len);
    std.debug.assert(output.written().len > 0);
    return output.toOwnedSlice();
}

fn expectValueJSON(expected: []const u8, value: *const JSONValue) !void {
    var buffer: [result_size_max]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try writeResultJSON(&buffer, value));
}

test "persistent state parsing formatting and terminal classification are exhaustive" {
    const states = [_]State{
        .new,
        .succeeded,
        .failed,
    };
    const names = [_][]const u8{
        "NEW",
        "SUCCEEDED",
        "FAILED",
    };
    for (states, names, 0..) |state, name, index| {
        try std.testing.expectEqualStrings(name, stateToString(state));
        try std.testing.expectEqual(state, try stateFromString(name));
        try std.testing.expectEqual(index >= 1, stateIsTerminal(state));
    }

    try std.testing.expectError(error.InvalidState, stateFromString("new"));
    try std.testing.expectError(error.InvalidState, stateFromString("SUBMITTED"));
    try std.testing.expectError(error.InvalidState, stateFromString("RUNNING"));
    try std.testing.expectError(error.InvalidState, stateFromString("COMPLETED"));
    try std.testing.expectError(error.InvalidState, stateFromString(""));
}

test "all state transitions enforce the monotonic lifecycle" {
    const states = [_]State{ .new, .succeeded, .failed };
    for (states) |current| {
        for (states) |replacement| {
            const allowed = current == .new or current == replacement;
            if (allowed) {
                try validateStateTransition(current, replacement);
            } else {
                try std.testing.expectError(
                    error.InvalidTransition,
                    validateStateTransition(current, replacement),
                );
            }
        }
    }
}

test "UUID conversion is symmetric and output is lowercase" {
    const id = try uuidFromString("00112233-4455-6677-8899-AABBCCDDEEFF");
    var buffer: [uuid_string_size]u8 = undefined;
    try std.testing.expectEqualStrings(test_uuid, uuidToString(id, &buffer));
    try std.testing.expectEqual(id, try uuidFromString(uuidToString(id, &buffer)));

    try std.testing.expectError(error.InvalidUUID, uuidFromString("00112233"));
    try std.testing.expectError(
        error.InvalidUUID,
        uuidFromString("001122334455-6677-8899-aabbccddeeff"),
    );
    try std.testing.expectError(
        error.InvalidUUID,
        uuidFromString("00112233-4455-6677-8899-aabbccddeezz"),
    );
}

test "input parses an arena-owned body Value and defaults state" {
    const input = try testInput(
        std.testing.allocator,
        "echo",
        "{ \"message\" : \"hello\" }",
        null,
    );
    defer std.testing.allocator.free(input);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const operation = try parseTestInput(
        arena.allocator(),
        input,
        test_now,
    );
    try std.testing.expectEqualStrings(test_tenant, operation.tenant);
    try std.testing.expectEqualStrings("echo", operation.name);
    try expectValueJSON("{\"message\":\"hello\"}", &operation.body.?);
    try std.testing.expectEqual(State.new, operation.state.?);
    try std.testing.expectEqual(test_now, operation.last_updated.?);
    try std.testing.expectEqual(test_now + ttl_seconds, operation.expires_at.?);
    try std.testing.expect(operation.result == null);
    try std.testing.expect(operation.hash != null);
}

test "input copies validated tenant metadata into the Operation arena" {
    const input = try testInput(std.testing.allocator, "echo", "null", null);
    defer std.testing.allocator.free(input);
    var tenant = [_]u8{ 't', 'e', 'n', 'a', 'n', 't' };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed = try parseInputJSON(arena.allocator(), input, .{
        .tenant = &tenant,
        .now = test_now,
    });
    tenant[0] = 'X';
    try std.testing.expectEqualStrings("tenant", parsed.tenant);
    try std.testing.expectEqualStrings("Xenant", &tenant);
}

test "tenant validation enforces UTF-8 byte boundaries" {
    const valid = [_][]const u8{
        "a",
        "a" ** tenant_size_max,
        "é" ** (tenant_size_max / 2),
    };
    for (valid) |tenant| try validateTenant(tenant);

    const invalid = [_][]const u8{
        "",
        "a" ** (tenant_size_max + 1),
        ("é" ** (tenant_size_max / 2)) ++ "a",
        &.{0xFF},
    };
    for (invalid) |tenant| {
        try std.testing.expectError(error.InvalidTenant, validateTenant(tenant));
    }
}

test "body accepts exactly 4096 serialized bytes" {
    var body: [body_size_max]u8 = undefined;
    body[0] = '"';
    @memset(body[1 .. body.len - 1], 'a');
    body[body.len - 1] = '"';
    const input = try testInput(std.testing.allocator, "boundary", &body, null);
    defer std.testing.allocator.free(input);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const operation = try parseTestInput(
        arena.allocator(),
        input,
        test_now,
    );
    try std.testing.expect(operation.body.? == .string);
    try std.testing.expectEqual(@as(usize, body_size_max - 2), operation.body.?.string.len);
}

test "body rejects more than 4096 serialized bytes and invalid JSON" {
    var body: [body_size_max + 1]u8 = undefined;
    body[0] = '"';
    @memset(body[1 .. body.len - 1], 'a');
    body[body.len - 1] = '"';
    const oversized = try testInput(std.testing.allocator, "boundary", &body, null);
    defer std.testing.allocator.free(oversized);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.BodyTooLarge,
        parseTestInput(arena.allocator(), oversized, test_now),
    );
    try std.testing.expectError(
        error.InvalidJSON,
        parseTestInput(
            arena.allocator(),
            "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\",\"name\":\"x\",\"body\":[}",
            test_now,
        ),
    );
}

test "normalized hash matches the documented BLAKE3-256 digest" {
    const input = try testInput(
        std.testing.allocator,
        "echo",
        "{\"message\":\"hello\",\"count\":2}",
        null,
    );
    defer std.testing.allocator.free(input);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const operation = try parseTestInput(
        arena.allocator(),
        input,
        test_now,
    );
    var expected_buffer: [32]u8 = undefined;
    const expected = std.fmt.hexToBytes(
        &expected_buffer,
        "d271e3bd560113d2b82e42dfc46be33fb90b43d7f4b12114f3da4888eae445d4",
    ) catch unreachable;

    try std.testing.expectEqualSlices(u8, expected, &operation.hash.?);
}

test "hash normalizes whitespace and equivalent string escapes" {
    const compact = try testInput(
        std.testing.allocator,
        "echo",
        "{\"message\":\"hello\",\"items\":[1,2]}",
        null,
    );
    defer std.testing.allocator.free(compact);
    const spaced = try testInput(
        std.testing.allocator,
        "echo",
        "{ \"message\" : \"he\\u006clo\", \"items\" : [ 1, 2 ] }",
        null,
    );
    defer std.testing.allocator.free(spaced);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const first = try parseTestInput(
        arena.allocator(),
        compact,
        test_now,
    );
    const second = try parseTestInput(
        arena.allocator(),
        spaced,
        test_now,
    );
    try std.testing.expectEqualSlices(u8, &first.hash.?, &second.hash.?);
    try expectValueJSON("{\"message\":\"hello\",\"items\":[1,2]}", &first.body.?);
    try expectValueJSON("{\"message\":\"hello\",\"items\":[1,2]}", &second.body.?);
}

test "hash includes the operation name and preserves object key order" {
    const first_input = try testInput(
        std.testing.allocator,
        "first",
        "{\"a\":1,\"b\":2}",
        null,
    );
    defer std.testing.allocator.free(first_input);
    const second_input = try testInput(
        std.testing.allocator,
        "second",
        "{\"a\":1,\"b\":2}",
        null,
    );
    defer std.testing.allocator.free(second_input);
    const reordered_input = try testInput(
        std.testing.allocator,
        "first",
        "{\"b\":2,\"a\":1}",
        null,
    );
    defer std.testing.allocator.free(reordered_input);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const first = try parseTestInput(
        arena.allocator(),
        first_input,
        test_now,
    );
    const second = try parseTestInput(
        arena.allocator(),
        second_input,
        test_now,
    );
    const reordered = try parseTestInput(
        arena.allocator(),
        reordered_input,
        test_now,
    );
    const other_tenant = try parseInputJSON(arena.allocator(), first_input, .{
        .tenant = "tenant-b",
        .now = test_now,
    });
    try std.testing.expect(!std.mem.eql(u8, &first.hash.?, &second.hash.?));
    try std.testing.expect(!std.mem.eql(u8, &first.hash.?, &reordered.hash.?));
    try std.testing.expect(!std.mem.eql(u8, &first.hash.?, &other_tenant.hash.?));
}

test "input accepts only omitted state or explicit NEW" {
    const explicit = try testInput(std.testing.allocator, "echo", "null", "NEW");
    defer std.testing.allocator.free(explicit);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const operation = try parseTestInput(
        arena.allocator(),
        explicit,
        test_now,
    );
    try std.testing.expectEqual(State.new, operation.state.?);
    for ([_][]const u8{ "SUBMITTED", "RUNNING", "SUCCEEDED", "FAILED" }) |state| {
        const later = try testInput(std.testing.allocator, "echo", "null", state);
        defer std.testing.allocator.free(later);
        try std.testing.expectError(
            error.InvalidState,
            parseTestInput(arena.allocator(), later, test_now),
        );
    }
}

test "input rejects spoofed output fields duplicates and unknown fields" {
    const prefix =
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
        "\"name\":\"echo\",\"body\":null";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.ForbiddenField,
        parseTestInput(
            arena.allocator(),
            prefix ++ ",\"tenant\":\"spoofed\"}",
            test_now,
        ),
    );
    try std.testing.expectError(
        error.ForbiddenField,
        parseTestInput(
            arena.allocator(),
            prefix ++ ",\"hash\":\"spoofed\"}",
            test_now,
        ),
    );
    try std.testing.expectError(
        error.ForbiddenField,
        parseTestInput(
            arena.allocator(),
            prefix ++ ",\"result\":null}",
            test_now,
        ),
    );
    try std.testing.expectError(
        error.ForbiddenField,
        parseTestInput(
            arena.allocator(),
            prefix ++ ",\"last_updated\":0}",
            test_now,
        ),
    );
    try std.testing.expectError(
        error.ForbiddenField,
        parseTestInput(
            arena.allocator(),
            prefix ++ ",\"expires_at\":0}",
            test_now,
        ),
    );
    try std.testing.expectError(
        error.UnknownField,
        parseTestInput(
            arena.allocator(),
            prefix ++ ",\"extra\":true}",
            test_now,
        ),
    );
    try std.testing.expectError(
        error.DuplicateField,
        parseTestInput(
            arena.allocator(),
            prefix ++ ",\"name\":\"again\"}",
            test_now,
        ),
    );
}

test "input requires id name and body and validates name bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const missing_body =
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\",\"name\":\"echo\"}";
    try std.testing.expectError(
        error.MissingField,
        parseTestInput(arena.allocator(), missing_body, test_now),
    );
    const empty = try testInput(std.testing.allocator, "", "null", null);
    defer std.testing.allocator.free(empty);
    try std.testing.expectError(
        error.InvalidName,
        parseTestInput(arena.allocator(), empty, test_now),
    );
    const long_name = [_]u8{'a'} ** (name_size_max + 1);
    const long = try testInput(std.testing.allocator, &long_name, "null", null);
    defer std.testing.allocator.free(long);
    try std.testing.expectError(
        error.InvalidName,
        parseTestInput(arena.allocator(), long, test_now),
    );

    const maximum_name = [_]u8{'a'} ** name_size_max;
    const maximum = try testInput(std.testing.allocator, &maximum_name, "null", null);
    defer std.testing.allocator.free(maximum);
    const operation = try parseTestInput(
        arena.allocator(),
        maximum,
        test_now,
    );
    try std.testing.expectEqual(@as(usize, name_size_max), operation.name.len);
}

fn testParseAllocationFailures(allocator: Allocator) !void {
    const input =
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
        "\"name\":\"echo\",\"body\":{\"message\":\"hello\"}}";
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const operation = try parseTestInput(arena.allocator(), input, test_now);
    std.debug.assert(operation.name.len > 0);
    std.debug.assert(operation.body.? == .object);
}

test "input parsing cleans up every allocation failure path" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testParseAllocationFailures,
        .{},
    );
}

test "input rejects expiration timestamp overflow" {
    const input = try testInput(std.testing.allocator, "echo", "null", null);
    defer std.testing.allocator.free(input);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.InvalidExpiresAt,
        parseTestInput(arena.allocator(), input, std.math.maxInt(UnixSeconds)),
    );
}

test "persistent validation enforces view and terminal result invariants" {
    const hash = [_]u8{0xAB} ** 32;
    var operation = Operation{
        .id = try uuidFromString(test_uuid),
        .tenant = test_tenant,
        .name = "echo",
        .state = .new,
        .last_updated = test_now,
        .expires_at = test_now + ttl_seconds,
        .hash = hash,
    };
    try validatePersistent(&operation);
    operation.result = .null;
    try validatePersistent(&operation);
    operation.result = .{ .bool = true };
    try std.testing.expectError(
        error.UnexpectedResult,
        validatePersistent(&operation),
    );
    operation.state = .succeeded;
    operation.last_updated = test_now + 2;
    operation.expires_at = test_now + 2 + ttl_seconds;
    try validatePersistent(&operation);
    operation.result = .null;
    try std.testing.expectError(
        error.MissingResult,
        validatePersistent(&operation),
    );
}

test "result accepts exactly 4096 compact bytes" {
    const maximum = "a" ** (result_size_max - 2);
    var operation = Operation{
        .id = try uuidFromString(test_uuid),
        .tenant = test_tenant,
        .name = "echo",
        .state = .failed,
        .last_updated = test_now,
        .expires_at = test_now + ttl_seconds,
        .result = .{ .string = maximum },
        .hash = [_]u8{0} ** 32,
    };
    try validatePersistent(&operation);

    operation.result = .{ .string = "a" ** (result_size_max - 1) };
    try std.testing.expectError(
        error.ResultTooLarge,
        validatePersistent(&operation),
    );
}

test "terminal result ingress accepts exactly 4096 bytes and rejects more" {
    const maximum = "\"" ++ ("a" ** (result_size_max - 2)) ++ "\"";
    const oversized = "\"" ++ ("a" ** (result_size_max - 1)) ++ "\"";
    comptime std.debug.assert(maximum.len == result_size_max);
    comptime std.debug.assert(oversized.len == result_size_max + 1);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parseResultJSON(arena.allocator(), maximum);
    try std.testing.expect(result == .string);
    try std.testing.expectEqual(@as(usize, result_size_max - 2), result.string.len);
    try std.testing.expectError(
        error.ResultTooLarge,
        parseResultJSON(arena.allocator(), oversized),
    );
}

test "terminal result parsing owns and normalizes every JSON Value variant" {
    const inputs = [_][]const u8{
        "true",
        "42",
        "\"hello\"",
        "[true, 42]",
        "{\"first\":1,\"second\":2}",
    };
    const expected = [_][]const u8{
        "true",
        "42",
        "\"hello\"",
        "[true,42]",
        "{\"first\":1,\"second\":2}",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (inputs, expected) |input, canonical| {
        const result = try parseResultJSON(arena.allocator(), input);
        try expectValueJSON(canonical, &result);
    }
    try std.testing.expectError(
        error.MissingResult,
        parseResultJSON(arena.allocator(), "null"),
    );
    try std.testing.expectError(
        error.InvalidJSON,
        parseResultJSON(arena.allocator(), "{\"key\":1,\"key\":2}"),
    );
    try std.testing.expectError(
        error.InvalidJSON,
        parseResultJSON(arena.allocator(), "{broken"),
    );
}

test "body parses every JSON Value variant and rejects duplicate object keys" {
    const bodies = [_][]const u8{ "null", "false", "42", "\"text\"", "[1]", "{\"a\":1}" };
    const tags = [_]std.meta.Tag(JSONValue){ .null, .bool, .integer, .string, .array, .object };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (bodies, tags) |body, tag| {
        const input = try testInput(std.testing.allocator, "variants", body, null);
        defer std.testing.allocator.free(input);
        const parsed = try parseTestInput(arena.allocator(), input, test_now);
        try std.testing.expectEqual(tag, std.meta.activeTag(parsed.body.?));
    }
    const duplicate = try testInput(
        std.testing.allocator,
        "variants",
        "{\"a\":1,\"a\":2}",
        null,
    );
    defer std.testing.allocator.free(duplicate);
    try std.testing.expectError(
        error.InvalidJSON,
        parseTestInput(arena.allocator(), duplicate, test_now),
    );
}

test "persistent view rejects body and requires state timestamps and hash" {
    var operation = Operation{
        .id = try uuidFromString(test_uuid),
        .tenant = test_tenant,
        .name = "echo",
        .body = .null,
        .state = .new,
        .last_updated = test_now,
        .expires_at = test_now + ttl_seconds,
        .hash = [_]u8{0} ** 32,
    };
    try std.testing.expectError(
        error.UnexpectedBody,
        validatePersistent(&operation),
    );
    operation.body = null;
    operation.tenant = "";
    try std.testing.expectError(
        error.InvalidTenant,
        validatePersistent(&operation),
    );
    operation.tenant = test_tenant;
    operation.state = null;
    try std.testing.expectError(
        error.MissingState,
        validatePersistent(&operation),
    );
    operation.state = .new;
    operation.last_updated = null;
    try std.testing.expectError(
        error.MissingLastUpdated,
        validatePersistent(&operation),
    );
    operation.last_updated = test_now;
    operation.expires_at = null;
    try std.testing.expectError(
        error.MissingExpiresAt,
        validatePersistent(&operation),
    );
    operation.expires_at = test_now + ttl_seconds + 1;
    try std.testing.expectError(
        error.InvalidExpiresAt,
        validatePersistent(&operation),
    );
    operation.expires_at = test_now + ttl_seconds;
    operation.hash = null;
    try std.testing.expectError(
        error.MissingHash,
        validatePersistent(&operation),
    );
}

test "output preserves scalar body and terminal result as raw JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const operation = Operation{
        .id = try uuidFromString(test_uuid),
        .tenant = test_tenant,
        .name = "echo",
        .body = .{ .bool = true },
        .state = .succeeded,
        .last_updated = test_now,
        .expires_at = test_now + ttl_seconds,
        .result = try parseResultJSON(arena.allocator(), "{\"ok\":true}"),
        .hash = [_]u8{0xAB} ** 32,
    };
    var output_buffer: [512]u8 = undefined;
    var output: std.Io.Writer = .fixed(&output_buffer);
    try writeOutputJSON(&output, &operation);
    try std.testing.expectEqualStrings(
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"tenant-a\",\"name\":\"echo\"," ++
            "\"body\":true," ++
            "\"state\":\"SUCCEEDED\"," ++
            "\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400," ++
            "\"result\":{\"ok\":true}," ++
            "\"hash\":\"abababababababababababababababab" ++
            "abababababababababababababababab\"}",
        output.buffered(),
    );

    var invalid = operation;
    invalid.last_updated = null;
    try std.testing.expectError(error.MissingLastUpdated, writeOutputJSON(&output, &invalid));
}

test "output distinguishes object explicit-null and absent bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var operation = Operation{
        .id = try uuidFromString(test_uuid),
        .tenant = test_tenant,
        .name = "echo",
        .body = try parseJSONValue(arena.allocator(), "{\"message\":\"hello\"}"),
        .state = .new,
        .last_updated = test_now + 1,
        .expires_at = test_now + 1 + ttl_seconds,
        .hash = [_]u8{0xAB} ** 32,
    };
    const object_output = try testOutput(&operation);
    defer std.testing.allocator.free(object_output);
    try std.testing.expect(std.mem.indexOf(
        u8,
        object_output,
        "\"body\":{\"message\":\"hello\"},\"state\"",
    ) != null);

    operation.body = .null;
    const null_output = try testOutput(&operation);
    defer std.testing.allocator.free(null_output);
    try std.testing.expect(std.mem.indexOf(u8, null_output, "\"body\":null,\"state\"") != null);

    operation.body = null;
    const absent_output = try testOutput(&operation);
    defer std.testing.allocator.free(absent_output);
    try std.testing.expectEqualStrings(
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"tenant-a\",\"name\":\"echo\"," ++
            "\"state\":\"NEW\",\"last_updated\":1700000001," ++
            "\"expires_at\":1700086401," ++
            "\"hash\":\"abababababababababababababababab" ++
            "abababababababababababababababab\"}",
        absent_output,
    );
}

test "every valid output shape round trips through the output parser" {
    var value_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer value_arena.deinit();
    const bodies = [_]?JSONValue{
        null,
        .null,
        try parseJSONValue(value_arena.allocator(), "{\"message\":\"hello\"}"),
    };
    const states = [_]State{ .new, .succeeded, .failed };
    for (states) |state| {
        for (bodies) |body| {
            const result: ?JSONValue = if (stateIsTerminal(state))
                try parseResultJSON(value_arena.allocator(), "{\"success\":true}")
            else
                null;
            const source: Operation = .{
                .id = try uuidFromString(test_uuid),
                .tenant = test_tenant,
                .name = "echo",
                .body = body,
                .state = state,
                .last_updated = test_now,
                .expires_at = test_now + ttl_seconds,
                .result = result,
                .hash = [_]u8{0xAB} ** 32,
            };
            const serialized = try testOutput(&source);
            defer std.testing.allocator.free(serialized);
            var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer parse_arena.deinit();
            const parsed = try parseOutputJSON(parse_arena.allocator(), serialized);
            const round_trip = try testOutput(&parsed);
            defer std.testing.allocator.free(round_trip);
            try std.testing.expectEqualStrings(serialized, round_trip);
        }
    }

    const explicit_null_result = Operation{
        .id = try uuidFromString(test_uuid),
        .tenant = test_tenant,
        .name = "echo",
        .state = .new,
        .last_updated = test_now,
        .expires_at = test_now + ttl_seconds,
        .result = .null,
        .hash = [_]u8{0xAB} ** 32,
    };
    const serialized = try testOutput(&explicit_null_result);
    defer std.testing.allocator.free(serialized);
    const parsed = try parseOutputJSON(value_arena.allocator(), serialized);
    try std.testing.expect(parsed.result.? == .null);
}

test "output parser preserves strings and JSON Values in its arena" {
    const serialized = try std.testing.allocator.dupe(
        u8,
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"tenant-a\",\"name\":\"echo\"," ++
            "\"body\":{\"message\":\"hello\"},\"state\":\"SUCCEEDED\"," ++
            "\"last_updated\":1700000000,\"expires_at\":1700086400," ++
            "\"result\":{\"success\":true},\"hash\":\"" ++ ("ab" ** 32) ++ "\"}",
    );
    defer std.testing.allocator.free(serialized);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parseOutputJSON(arena.allocator(), serialized);
    @memset(serialized, 'x');

    try std.testing.expectEqualStrings("tenant-a", parsed.tenant);
    try std.testing.expectEqualStrings("echo", parsed.name);
    try expectValueJSON("{\"message\":\"hello\"}", &parsed.body.?);
    try expectValueJSON("{\"success\":true}", &parsed.result.?);
}

test "output parser requires all owned fields and rejects extra fields" {
    const hash = "ab" ** 32;
    const missing = [_][]const u8{
        "{\"tenant\":\"tenant-a\",\"name\":\"echo\",\"state\":\"NEW\"," ++
            "\"last_updated\":1700000000,\"expires_at\":1700086400,\"hash\":\"" ++ hash ++ "\"}",
        "{\"id\":\"" ++ test_uuid ++ "\",\"name\":\"echo\",\"state\":\"NEW\"," ++
            "\"last_updated\":1700000000,\"expires_at\":1700086400,\"hash\":\"" ++ hash ++ "\"}",
        "{\"id\":\"" ++ test_uuid ++ "\",\"tenant\":\"tenant-a\",\"state\":\"NEW\"," ++
            "\"last_updated\":1700000000,\"expires_at\":1700086400,\"hash\":\"" ++ hash ++ "\"}",
        "{\"id\":\"" ++ test_uuid ++ "\",\"tenant\":\"tenant-a\",\"name\":\"echo\"," ++
            "\"last_updated\":1700000000,\"expires_at\":1700086400,\"hash\":\"" ++ hash ++ "\"}",
        "{\"id\":\"" ++ test_uuid ++ "\",\"tenant\":\"tenant-a\",\"name\":\"echo\"," ++
            "\"state\":\"NEW\",\"expires_at\":1700086400,\"hash\":\"" ++ hash ++ "\"}",
        "{\"id\":\"" ++ test_uuid ++ "\",\"tenant\":\"tenant-a\",\"name\":\"echo\"," ++
            "\"state\":\"NEW\",\"last_updated\":1700000000,\"hash\":\"" ++ hash ++ "\"}",
        "{\"id\":\"" ++ test_uuid ++ "\",\"tenant\":\"tenant-a\",\"name\":\"echo\"," ++
            "\"state\":\"NEW\",\"last_updated\":1700000000,\"expires_at\":1700086400}",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (missing) |input| {
        try std.testing.expectError(error.MissingField, parseOutputJSON(arena.allocator(), input));
    }

    const prefix =
        "{\"id\":\"" ++ test_uuid ++ "\",\"tenant\":\"tenant-a\",\"name\":\"echo\"," ++
        "\"state\":\"NEW\",\"last_updated\":1700000000," ++
        "\"expires_at\":1700086400,\"hash\":\"" ++ hash ++ "\"";
    try std.testing.expectError(
        error.DuplicateField,
        parseOutputJSON(arena.allocator(), prefix ++ ",\"name\":\"again\"}"),
    );
    try std.testing.expectError(
        error.UnknownField,
        parseOutputJSON(arena.allocator(), prefix ++ ",\"extra\":true}"),
    );
    try std.testing.expectError(
        error.InvalidJSON,
        parseOutputJSON(arena.allocator(), prefix ++ ",\"body\":[}"),
    );
}

test "output parser rejects oversized and invariant-breaking fields" {
    const prefix =
        "{\"id\":\"" ++ test_uuid ++ "\",\"tenant\":\"tenant-a\",\"name\":\"echo\",";
    const suffix =
        ",\"last_updated\":1700000000,\"expires_at\":1700086400," ++
        "\"hash\":\"" ++ ("ab" ** 32) ++ "\"}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.InvalidTenant,
        parseOutputJSON(
            arena.allocator(),
            "{\"id\":\"" ++ test_uuid ++ "\",\"tenant\":\"" ++
                ("a" ** (tenant_size_max + 1)) ++ "\",\"name\":\"echo\"," ++
                "\"state\":\"NEW\"" ++ suffix,
        ),
    );
    try std.testing.expectError(
        error.InvalidName,
        parseOutputJSON(
            arena.allocator(),
            "{\"id\":\"" ++ test_uuid ++ "\",\"tenant\":\"tenant-a\",\"name\":\"" ++
                ("a" ** (name_size_max + 1)) ++ "\",\"state\":\"NEW\"" ++ suffix,
        ),
    );
    try std.testing.expectError(
        error.BodyTooLarge,
        parseOutputJSON(
            arena.allocator(),
            prefix ++ "\"body\":\"" ++ ("a" ** (body_size_max - 1)) ++
                "\",\"state\":\"NEW\"" ++ suffix,
        ),
    );
    try std.testing.expectError(
        error.ResultTooLarge,
        parseOutputJSON(
            arena.allocator(),
            prefix ++ "\"state\":\"SUCCEEDED\",\"result\":\"" ++
                ("a" ** (result_size_max - 1)) ++ "\"" ++ suffix,
        ),
    );
    try std.testing.expectError(
        error.OutputTooLarge,
        parseOutputJSON(arena.allocator(), " " ** (output_size_max + 1)),
    );
    try std.testing.expectError(
        error.UnexpectedResult,
        parseOutputJSON(
            arena.allocator(),
            prefix ++ "\"state\":\"NEW\",\"result\":true" ++ suffix,
        ),
    );
    try std.testing.expectError(
        error.MissingResult,
        parseOutputJSON(arena.allocator(), prefix ++ "\"state\":\"SUCCEEDED\"" ++ suffix),
    );
    try std.testing.expectError(
        error.InvalidExpiresAt,
        parseOutputJSON(
            arena.allocator(),
            prefix ++ "\"state\":\"NEW\"" ++
                ",\"last_updated\":1700000000,\"expires_at\":1700086401," ++
                "\"hash\":\"" ++ ("ab" ** 32) ++ "\"}",
        ),
    );
    try std.testing.expectError(
        error.InvalidHash,
        parseOutputJSON(
            arena.allocator(),
            prefix ++ "\"state\":\"NEW\"," ++
                "\"last_updated\":1700000000,\"expires_at\":1700086400," ++
                "\"hash\":\"" ++ ("AB" ** 32) ++ "\"}",
        ),
    );
}

test "expiration calculation rejects timestamp overflow" {
    try std.testing.expectEqual(
        test_now + ttl_seconds,
        try expires_at_from_last_updated(test_now),
    );
    try std.testing.expectError(
        error.InvalidExpiresAt,
        expires_at_from_last_updated(std.math.maxInt(UnixSeconds)),
    );
}
