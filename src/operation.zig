const std = @import("std");

const Allocator = std.mem.Allocator;

pub const UnixSeconds = i64;
pub const body_size_max = 4096;
pub const result_size_max = 4096;
pub const name_size_max = 64;
const hash_envelope_size_max = body_size_max + 1024;
const uuid_string_size = 36;

comptime {
    std.debug.assert(body_size_max == result_size_max);
    std.debug.assert(uuid_string_size == 36);
}

pub const State = enum {
    new,
    submitted,
    running,
    succeeded,
    failed,
};

/// Parses the uppercase representation shared by JSON and persistent storage.
pub fn stateFromString(value: []const u8) !State {
    if (std.mem.eql(u8, value, "NEW")) return .new;
    if (std.mem.eql(u8, value, "SUBMITTED")) return .submitted;
    if (std.mem.eql(u8, value, "RUNNING")) return .running;
    if (std.mem.eql(u8, value, "SUCCEEDED")) return .succeeded;
    if (std.mem.eql(u8, value, "FAILED")) return .failed;
    return error.InvalidState;
}

/// Returns the uppercase representation shared by JSON and persistent storage.
pub fn stateToString(state: State) []const u8 {
    return switch (state) {
        .new => "NEW",
        .submitted => "SUBMITTED",
        .running => "RUNNING",
        .succeeded => "SUCCEEDED",
        .failed => "FAILED",
    };
}

/// Reports whether the state requires a non-null serialized result.
pub fn stateIsTerminal(state: State) bool {
    return switch (state) {
        .succeeded, .failed => true,
        .new, .submitted, .running => false,
    };
}

pub const Operation = struct {
    id: u128,
    name: []const u8,
    body: ?[]const u8 = null,
    state: ?State = null,
    /// The caller must update this whenever state changes.
    last_updated: ?UnixSeconds = null,
    result: ?[]const u8 = null,
    hash: ?[32]u8 = null,
};

const InputFields = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    body: ?[]const u8 = null,
    state: ?[]const u8 = null,
};

/// Parses the input view into arena-owned slices and releases all normalization storage.
pub fn parseInputJSON(
    arena: Allocator,
    temporary_allocator: Allocator,
    input_json: []const u8,
    now: UnixSeconds,
) !Operation {
    var scratch = std.heap.ArenaAllocator.init(temporary_allocator);
    defer scratch.deinit();
    const temporary = scratch.allocator();

    const fields = try scanInputFields(temporary, input_json);
    const id_json = fields.id orelse return error.MissingField;
    const name_json = fields.name orelse return error.MissingField;
    const body_json = fields.body orelse return error.MissingField;

    var id_parsed = try parseJSONString(temporary, id_json);
    defer id_parsed.deinit();
    const id = try uuidFromString(id_parsed.value);

    var name_parsed = try parseJSONString(temporary, name_json);
    defer name_parsed.deinit();
    try validateName(name_parsed.value);

    const state = if (fields.state) |state_json|
        try parseInputState(temporary, state_json)
    else
        State.new;
    if (body_json.len > body_size_max) return error.BodyTooLarge;
    const hash = try operationHash(temporary, name_parsed.value, body_json);

    const name = try arena.dupe(u8, name_parsed.value);
    errdefer arena.free(name);
    const body = try arena.dupe(u8, body_json);
    errdefer arena.free(body);

    return .{
        .id = id,
        .name = name,
        .body = body,
        .state = state,
        .last_updated = now,
        .hash = hash,
    };
}

/// Writes the output view while embedding a terminal result as an already-validated JSON value.
pub fn writeOutputJSON(
    temporary_allocator: Allocator,
    writer: *std.Io.Writer,
    operation: *const Operation,
) !void {
    const result_present = try validateView(temporary_allocator, operation);
    const state = operation.state.?;
    const last_updated = operation.last_updated.?;
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
    try json.objectField("name");
    try json.write(operation.name);
    try json.objectField("state");
    try json.write(stateToString(state));
    try json.objectField("last_updated");
    try json.write(last_updated);
    if (result_present) {
        try json.objectField("result");
        try json.beginWriteRaw();
        try writer.writeAll(operation.result.?);
        json.endWriteRaw();
    }
    try json.objectField("hash");
    try json.write(&hash_hex);
    try json.endObject();
}

/// Checks the invariants required before mapping an operation to a persistent entity.
pub fn validatePersistent(
    temporary_allocator: Allocator,
    operation: *const Operation,
) !void {
    if (operation.body != null) return error.UnexpectedBody;
    _ = try validateView(temporary_allocator, operation);
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

fn scanInputFields(temporary: Allocator, input_json: []const u8) !InputFields {
    var scanner = std.json.Scanner.initCompleteInput(temporary, input_json);
    defer scanner.deinit();

    const first = scanner.next() catch |err| return jsonError(err);
    if (first != .object_begin) return error.InvalidJSON;

    var fields: InputFields = .{};
    var field_count: u8 = 0;
    while (true) {
        const token = scanner.nextAllocMax(
            temporary,
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
    } else if (std.mem.eql(u8, field_name, "result")) {
        return error.ForbiddenField;
    } else if (std.mem.eql(u8, field_name, "hash")) {
        return error.ForbiddenField;
    } else if (std.mem.eql(u8, field_name, "last_updated")) {
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

fn parseJSONString(temporary: Allocator, json: []const u8) !std.json.Parsed([]const u8) {
    return std.json.parseFromSlice([]const u8, temporary, json, .{
        .allocate = .alloc_always,
        .max_value_len = json.len,
    }) catch |err| return jsonError(err);
}

fn parseInputState(temporary: Allocator, state_json: []const u8) !State {
    var parsed = try parseJSONString(temporary, state_json);
    defer parsed.deinit();
    const state = try stateFromString(parsed.value);
    if (state != .new) return error.InvalidState;
    return state;
}

fn operationHash(
    temporary: Allocator,
    name: []const u8,
    body_json: []const u8,
) ![32]u8 {
    var body = try parseJSONValue(temporary, body_json);
    defer body.deinit();

    var count_buffer: [256]u8 = undefined;
    var counter: std.Io.Writer.Discarding = .init(&count_buffer);
    hashEnvelopeWrite(&counter.writer, name, body.value) catch unreachable;
    const envelope_size = std.math.cast(usize, counter.fullCount()) orelse {
        return error.InvalidJSON;
    };
    if (envelope_size > hash_envelope_size_max) return error.InvalidJSON;

    const envelope = try temporary.alloc(u8, envelope_size);
    defer temporary.free(envelope);
    var writer: std.Io.Writer = .fixed(envelope);
    hashEnvelopeWrite(&writer, name, body.value) catch unreachable;
    std.debug.assert(writer.buffered().len == envelope.len);

    var hash: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(envelope, &hash, .{});
    return hash;
}

fn hashEnvelopeWrite(
    writer: *std.Io.Writer,
    name: []const u8,
    body: std.json.Value,
) !void {
    var json: std.json.Stringify = .{
        .writer = writer,
        .options = .{},
    };
    try json.beginObject();
    try json.objectField("name");
    try json.write(name);
    try json.objectField("body");
    try json.write(body);
    try json.endObject();
}

fn parseJSONValue(temporary: Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, temporary, json, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = json.len,
        .parse_numbers = true,
    }) catch |err| return jsonError(err);
}

fn validateView(temporary: Allocator, operation: *const Operation) !bool {
    try validateName(operation.name);
    const state = operation.state orelse return error.MissingState;
    if (operation.last_updated == null) return error.MissingLastUpdated;
    if (operation.hash == null) return error.MissingHash;
    const result_present = try serializedResultPresent(temporary, operation.result);
    if (stateIsTerminal(state)) {
        if (!result_present) return error.MissingResult;
    } else {
        if (result_present) return error.UnexpectedResult;
    }
    return result_present;
}

fn serializedResultPresent(temporary: Allocator, result_optional: ?[]const u8) !bool {
    const result = result_optional orelse return false;
    if (result.len > result_size_max) return error.ResultTooLarge;
    var parsed = try parseJSONValue(temporary, result);
    defer parsed.deinit();
    return parsed.value != .null;
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
const test_now: UnixSeconds = 1_700_000_000;

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
    try writeOutputJSON(std.testing.allocator, &output.writer, operation);
    std.debug.assert(output.written().len > operation.name.len);
    std.debug.assert(output.written().len > 0);
    return output.toOwnedSlice();
}

test "persistent state parsing formatting and terminal classification are exhaustive" {
    const states = [_]State{
        .new,
        .submitted,
        .running,
        .succeeded,
        .failed,
    };
    const names = [_][]const u8{
        "NEW",
        "SUBMITTED",
        "RUNNING",
        "SUCCEEDED",
        "FAILED",
    };
    for (states, names, 0..) |state, name, index| {
        try std.testing.expectEqualStrings(name, stateToString(state));
        try std.testing.expectEqual(state, try stateFromString(name));
        try std.testing.expectEqual(index >= 3, stateIsTerminal(state));
    }

    try std.testing.expectError(error.InvalidState, stateFromString("new"));
    try std.testing.expectError(error.InvalidState, stateFromString("COMPLETED"));
    try std.testing.expectError(error.InvalidState, stateFromString(""));
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

test "input preserves serialized body and defaults state" {
    const input = try testInput(
        std.testing.allocator,
        "echo",
        "{ \"message\" : \"hello\" }",
        null,
    );
    defer std.testing.allocator.free(input);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const operation = try parseInputJSON(
        arena.allocator(),
        std.testing.allocator,
        input,
        test_now,
    );
    try std.testing.expectEqualStrings("echo", operation.name);
    try std.testing.expectEqualStrings("{ \"message\" : \"hello\" }", operation.body.?);
    try std.testing.expectEqual(State.new, operation.state.?);
    try std.testing.expectEqual(test_now, operation.last_updated.?);
    try std.testing.expect(operation.result == null);
    try std.testing.expect(operation.hash != null);
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

    const operation = try parseInputJSON(
        arena.allocator(),
        std.testing.allocator,
        input,
        test_now,
    );
    try std.testing.expectEqual(@as(usize, body_size_max), operation.body.?.len);
    try std.testing.expectEqualSlices(u8, &body, operation.body.?);
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
        parseInputJSON(arena.allocator(), std.testing.allocator, oversized, test_now),
    );
    try std.testing.expectError(
        error.InvalidJSON,
        parseInputJSON(
            arena.allocator(),
            std.testing.allocator,
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
    const operation = try parseInputJSON(
        arena.allocator(),
        std.testing.allocator,
        input,
        test_now,
    );
    var expected_buffer: [32]u8 = undefined;
    const expected = std.fmt.hexToBytes(
        &expected_buffer,
        "ab9a059eb68c36bddaffb5bdd23aa7177c3a97dc34f9af54eb06f1c488ac3662",
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

    const first = try parseInputJSON(
        arena.allocator(),
        std.testing.allocator,
        compact,
        test_now,
    );
    const second = try parseInputJSON(
        arena.allocator(),
        std.testing.allocator,
        spaced,
        test_now,
    );
    try std.testing.expectEqualSlices(u8, &first.hash.?, &second.hash.?);
    try std.testing.expect(!std.mem.eql(u8, first.body.?, second.body.?));
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

    const first = try parseInputJSON(
        arena.allocator(),
        std.testing.allocator,
        first_input,
        test_now,
    );
    const second = try parseInputJSON(
        arena.allocator(),
        std.testing.allocator,
        second_input,
        test_now,
    );
    const reordered = try parseInputJSON(
        arena.allocator(),
        std.testing.allocator,
        reordered_input,
        test_now,
    );
    try std.testing.expect(!std.mem.eql(u8, &first.hash.?, &second.hash.?));
    try std.testing.expect(!std.mem.eql(u8, &first.hash.?, &reordered.hash.?));
}

test "input accepts only omitted state or explicit NEW" {
    const explicit = try testInput(std.testing.allocator, "echo", "null", "NEW");
    defer std.testing.allocator.free(explicit);
    const later = try testInput(std.testing.allocator, "echo", "null", "SUBMITTED");
    defer std.testing.allocator.free(later);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const operation = try parseInputJSON(
        arena.allocator(),
        std.testing.allocator,
        explicit,
        test_now,
    );
    try std.testing.expectEqual(State.new, operation.state.?);
    try std.testing.expectError(
        error.InvalidState,
        parseInputJSON(arena.allocator(), std.testing.allocator, later, test_now),
    );
}

test "input rejects spoofed output fields duplicates and unknown fields" {
    const prefix =
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
        "\"name\":\"echo\",\"body\":null";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.ForbiddenField,
        parseInputJSON(
            arena.allocator(),
            std.testing.allocator,
            prefix ++ ",\"hash\":\"spoofed\"}",
            test_now,
        ),
    );
    try std.testing.expectError(
        error.ForbiddenField,
        parseInputJSON(
            arena.allocator(),
            std.testing.allocator,
            prefix ++ ",\"result\":null}",
            test_now,
        ),
    );
    try std.testing.expectError(
        error.ForbiddenField,
        parseInputJSON(
            arena.allocator(),
            std.testing.allocator,
            prefix ++ ",\"last_updated\":0}",
            test_now,
        ),
    );
    try std.testing.expectError(
        error.UnknownField,
        parseInputJSON(
            arena.allocator(),
            std.testing.allocator,
            prefix ++ ",\"extra\":true}",
            test_now,
        ),
    );
    try std.testing.expectError(
        error.DuplicateField,
        parseInputJSON(
            arena.allocator(),
            std.testing.allocator,
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
        parseInputJSON(arena.allocator(), std.testing.allocator, missing_body, test_now),
    );
    const empty = try testInput(std.testing.allocator, "", "null", null);
    defer std.testing.allocator.free(empty);
    try std.testing.expectError(
        error.InvalidName,
        parseInputJSON(arena.allocator(), std.testing.allocator, empty, test_now),
    );
    const long_name = [_]u8{'a'} ** (name_size_max + 1);
    const long = try testInput(std.testing.allocator, &long_name, "null", null);
    defer std.testing.allocator.free(long);
    try std.testing.expectError(
        error.InvalidName,
        parseInputJSON(arena.allocator(), std.testing.allocator, long, test_now),
    );

    const maximum_name = [_]u8{'a'} ** name_size_max;
    const maximum = try testInput(std.testing.allocator, &maximum_name, "null", null);
    defer std.testing.allocator.free(maximum);
    const operation = try parseInputJSON(
        arena.allocator(),
        std.testing.allocator,
        maximum,
        test_now,
    );
    try std.testing.expectEqual(@as(usize, name_size_max), operation.name.len);
}

fn testParseAllocationFailures(allocator: Allocator) !void {
    const input =
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
        "\"name\":\"echo\",\"body\":{\"message\":\"hello\"}}";
    const operation = try parseInputJSON(allocator, allocator, input, test_now);
    defer allocator.free(operation.name);
    defer allocator.free(operation.body.?);
    std.debug.assert(operation.name.len > 0);
    std.debug.assert(operation.body.?.len > 0);
}

test "input parsing cleans up every allocation failure path" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testParseAllocationFailures,
        .{},
    );
}

test "persistent validation enforces view and terminal result invariants" {
    const hash = [_]u8{0xAB} ** 32;
    var operation = Operation{
        .id = try uuidFromString(test_uuid),
        .name = "echo",
        .state = .new,
        .last_updated = test_now,
        .hash = hash,
    };
    try validatePersistent(std.testing.allocator, &operation);
    operation.state = .submitted;
    operation.last_updated = test_now + 1;
    try validatePersistent(std.testing.allocator, &operation);
    operation.result = "null";
    try validatePersistent(std.testing.allocator, &operation);
    operation.result = "true";
    try std.testing.expectError(
        error.UnexpectedResult,
        validatePersistent(std.testing.allocator, &operation),
    );
    operation.state = .succeeded;
    operation.last_updated = test_now + 2;
    try validatePersistent(std.testing.allocator, &operation);
    operation.result = "null";
    try std.testing.expectError(
        error.MissingResult,
        validatePersistent(std.testing.allocator, &operation),
    );
    operation.result = "{broken";
    try std.testing.expectError(
        error.InvalidJSON,
        validatePersistent(std.testing.allocator, &operation),
    );
}

test "result accepts exactly 4096 serialized bytes" {
    var result: [result_size_max]u8 = undefined;
    result[0] = '"';
    @memset(result[1 .. result.len - 1], 'a');
    result[result.len - 1] = '"';
    var operation = Operation{
        .id = try uuidFromString(test_uuid),
        .name = "echo",
        .state = .failed,
        .last_updated = test_now,
        .result = &result,
        .hash = [_]u8{0} ** 32,
    };
    try validatePersistent(std.testing.allocator, &operation);

    var oversized: [result_size_max + 1]u8 = undefined;
    oversized[0] = '"';
    @memset(oversized[1 .. oversized.len - 1], 'a');
    oversized[oversized.len - 1] = '"';
    operation.result = &oversized;
    try std.testing.expectError(
        error.ResultTooLarge,
        validatePersistent(std.testing.allocator, &operation),
    );
}

test "persistent view rejects body and requires state timestamp and hash" {
    var operation = Operation{
        .id = try uuidFromString(test_uuid),
        .name = "echo",
        .body = "null",
        .state = .new,
        .last_updated = test_now,
        .hash = [_]u8{0} ** 32,
    };
    try std.testing.expectError(
        error.UnexpectedBody,
        validatePersistent(std.testing.allocator, &operation),
    );
    operation.body = null;
    operation.state = null;
    try std.testing.expectError(
        error.MissingState,
        validatePersistent(std.testing.allocator, &operation),
    );
    operation.state = .new;
    operation.last_updated = null;
    try std.testing.expectError(
        error.MissingLastUpdated,
        validatePersistent(std.testing.allocator, &operation),
    );
    operation.last_updated = test_now;
    operation.hash = null;
    try std.testing.expectError(
        error.MissingHash,
        validatePersistent(std.testing.allocator, &operation),
    );
}

test "output omits body and emits terminal result as raw JSON" {
    var operation = Operation{
        .id = try uuidFromString(test_uuid),
        .name = "echo",
        .body = "{\"private\":true}",
        .state = .succeeded,
        .last_updated = test_now,
        .result = "{\"ok\":true}",
        .hash = [_]u8{0xAB} ** 32,
    };
    const output = try testOutput(&operation);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"name\":\"echo\",\"state\":\"SUCCEEDED\"," ++
            "\"last_updated\":1700000000," ++
            "\"result\":{\"ok\":true}," ++
            "\"hash\":\"abababababababababababababababab" ++
            "abababababababababababababababab\"}",
        output,
    );
    try std.testing.expect(std.mem.indexOf(u8, output, "body") == null);

    operation.state = .submitted;
    operation.last_updated = test_now + 1;
    operation.result = null;
    const pending_output = try testOutput(&operation);
    defer std.testing.allocator.free(pending_output);
    try std.testing.expect(std.mem.indexOf(u8, pending_output, "SUBMITTED") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending_output, "1700000001") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending_output, "result") == null);
    try std.testing.expect(std.mem.indexOf(u8, pending_output, "body") == null);

    operation.last_updated = null;
    try std.testing.expectError(error.MissingLastUpdated, testOutput(&operation));
}
