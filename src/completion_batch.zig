const std = @import("std");
const operation = @import("operation");

const Allocator = std.mem.Allocator;

pub const encoded_message_size_max = 1024 * 1024;

const message_prefix = "{\"results\":[";
const message_suffix = "]}";
const entry_prefix = "{\"operation_id\":\"";
const entry_middle = "\",\"result\":";
const entry_suffix = "}";

comptime {
    std.debug.assert(encoded_message_size_max == 1024 * 1024);
    std.debug.assert(encoded_message_size_max > operation.result_size_max);
    std.debug.assert(operation.uuid_string_size == 36);
    std.debug.assert(message_prefix.len > message_suffix.len);
    std.debug.assert(entry_prefix.len > entry_suffix.len);
}

pub const Entry = struct {
    operation_id: u128,
    result: operation.Completion,
};

pub const Batch = struct {
    results: []const Entry,
};

/// Preserves an exact validation error and only exposes an unambiguous canonical identity.
pub const InvalidEntry = struct {
    operation_id: ?u128,
    cause: anyerror,
};

pub const DecodedEntry = union(enum) {
    valid: Entry,
    invalid: InvalidEntry,
};

pub const DecodedBatch = struct {
    results: []const DecodedEntry,
};

const TopLevelFields = struct {
    results: ?[]const u8 = null,
};

const EntryFields = struct {
    operation_id: ?[]const u8 = null,
    result: ?[]const u8 = null,
};

/// Encodes one non-empty aggregate into arena-owned canonical JSON.
pub fn encode(arena: Allocator, batch: *const Batch) ![]const u8 {
    const encoded_size = try calculate_encoded_size(batch);
    std.debug.assert(encoded_size > message_prefix.len + message_suffix.len);
    std.debug.assert(encoded_size <= encoded_message_size_max);

    const output = try arena.alloc(u8, encoded_size);
    var writer: std.Io.Writer = .fixed(output);
    write_batch(&writer, batch) catch |err| {
        if (err == error.WriteFailed) {
            std.debug.assert(false);
            return error.MessageTooLarge;
        }
        return err;
    };
    const encoded = writer.buffered();
    std.debug.assert(encoded.len == encoded_size);
    return encoded;
}

/// Decodes one bounded aggregate into values owned by the invocation arena.
pub fn decode(arena: Allocator, input_json: []const u8) !DecodedBatch {
    if (input_json.len > encoded_message_size_max) return error.MessageTooLarge;

    const fields = try scan_top_level_fields(arena, input_json);
    const results_json = fields.results orelse return error.MissingField;
    const results = try decode_results(arena, results_json);
    std.debug.assert(results.len > 0);
    std.debug.assert(results.len <= input_json.len);
    return .{ .results = results };
}

fn calculate_encoded_size(batch: *const Batch) !usize {
    if (batch.results.len == 0) return error.EmptyResults;

    // Measure first so the invocation arena owns only the encoded bytes, not a maximum-size buffer.
    const entry_fixed_size = entry_prefix.len + operation.uuid_string_size +
        entry_middle.len + entry_suffix.len;
    var encoded_size = message_prefix.len + message_suffix.len;
    for (batch.results, 0..) |*entry, index| {
        var result_buffer: [operation.result_size_max]u8 = undefined;
        const result = try operation.writeCompletionJSON(&result_buffer, &entry.result);
        const separator_size: usize = if (index == 0) 0 else 1;
        const additional_size = std.math.add(
            usize,
            entry_fixed_size + separator_size,
            result.len,
        ) catch return error.MessageTooLarge;
        encoded_size = std.math.add(
            usize,
            encoded_size,
            additional_size,
        ) catch return error.MessageTooLarge;
        if (encoded_size > encoded_message_size_max) return error.MessageTooLarge;
        std.debug.assert(index < encoded_message_size_max);
    }
    std.debug.assert(encoded_size > message_prefix.len + message_suffix.len);
    std.debug.assert(encoded_size <= encoded_message_size_max);
    return encoded_size;
}

fn write_batch(writer: *std.Io.Writer, batch: *const Batch) !void {
    std.debug.assert(batch.results.len > 0);
    try writer.writeAll(message_prefix);
    for (batch.results, 0..) |*entry, index| {
        if (index > 0) try writer.writeAll(",");

        var id_buffer: [operation.uuid_string_size]u8 = undefined;
        const operation_id = operation.uuidToString(entry.operation_id, &id_buffer);
        var result_buffer: [operation.result_size_max]u8 = undefined;
        const result = try operation.writeCompletionJSON(&result_buffer, &entry.result);

        try writer.writeAll(entry_prefix);
        try writer.writeAll(operation_id);
        try writer.writeAll(entry_middle);
        try writer.writeAll(result);
        try writer.writeAll(entry_suffix);
    }
    try writer.writeAll(message_suffix);
}

fn scan_top_level_fields(arena: Allocator, input_json: []const u8) !TopLevelFields {
    var scanner = std.json.Scanner.initCompleteInput(arena, input_json);
    defer scanner.deinit();

    const first = scanner.next() catch |err| return json_error(err);
    if (first != .object_begin) return error.InvalidJSON;

    var fields: TopLevelFields = .{};
    var field_count: u8 = 0;
    while (true) {
        const token = scanner.nextAllocMax(
            arena,
            .alloc_always,
            input_json.len,
        ) catch |err| return json_error(err);
        if (token == .object_end) break;
        const field_name = switch (token) {
            .allocated_string => |value| value,
            else => return error.InvalidJSON,
        };
        const value_start = try json_value_start(input_json, scanner.cursor);
        try scanner_skip_value(&scanner);
        const value_json = input_json[value_start..scanner.cursor];
        try set_top_level_field(&fields, field_name, value_json);
        field_count += 1;
        std.debug.assert(field_count <= 1);
    }
    const last = scanner.next() catch |err| return json_error(err);
    if (last != .end_of_document) return error.InvalidJSON;
    return fields;
}

fn decode_results(arena: Allocator, input_json: []const u8) ![]const DecodedEntry {
    var scanner = std.json.Scanner.initCompleteInput(arena, input_json);
    defer scanner.deinit();

    const first = scanner.next() catch |err| return json_error(err);
    if (first != .array_begin) return error.InvalidJSON;

    var results: std.ArrayList(DecodedEntry) = .empty;
    defer results.deinit(arena);
    while (true) {
        const token_type = scanner.peekNextTokenType() catch |err| return json_error(err);
        if (token_type == .array_end) {
            const array_end = scanner.next() catch |err| return json_error(err);
            std.debug.assert(array_end == .array_end);
            break;
        }
        if (token_type == .end_of_document) return error.InvalidJSON;

        const entry_start = try json_value_at_cursor(input_json, scanner.cursor);
        try scanner_skip_value(&scanner);
        const entry_json = input_json[entry_start..scanner.cursor];
        try results.append(arena, try decode_entry(arena, entry_json));
        std.debug.assert(results.items.len <= input_json.len);
    }
    const last = scanner.next() catch |err| return json_error(err);
    if (last != .end_of_document) return error.InvalidJSON;
    if (results.items.len == 0) return error.EmptyResults;
    return results.toOwnedSlice(arena);
}

fn decode_entry(arena: Allocator, input_json: []const u8) !DecodedEntry {
    const fields = scan_entry_fields(arena, input_json) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return invalid_entry(try trusted_operation_id(arena, input_json), err);
    };

    const operation_id_json = fields.operation_id orelse {
        return invalid_entry(null, error.MissingField);
    };
    const operation_id = parse_canonical_operation_id(arena, operation_id_json) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return invalid_entry(null, err);
    };
    const result_json = fields.result orelse {
        return invalid_entry(operation_id, error.MissingField);
    };
    const result = operation.parseCompletionJSON(arena, result_json) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return invalid_entry(operation_id, err);
    };
    return .{ .valid = .{ .operation_id = operation_id, .result = result } };
}

fn scan_entry_fields(arena: Allocator, input_json: []const u8) !EntryFields {
    var scanner = std.json.Scanner.initCompleteInput(arena, input_json);
    defer scanner.deinit();

    const first = scanner.next() catch |err| return json_error(err);
    if (first != .object_begin) return error.InvalidJSON;

    var fields: EntryFields = .{};
    var field_count: u8 = 0;
    while (true) {
        const token = scanner.nextAllocMax(
            arena,
            .alloc_always,
            input_json.len,
        ) catch |err| return json_error(err);
        if (token == .object_end) break;
        const field_name = switch (token) {
            .allocated_string => |value| value,
            else => return error.InvalidJSON,
        };
        const value_start = try json_value_start(input_json, scanner.cursor);
        try scanner_skip_value(&scanner);
        const value_json = input_json[value_start..scanner.cursor];
        try set_entry_field(&fields, field_name, value_json);
        field_count += 1;
        std.debug.assert(field_count <= 2);
    }
    const last = scanner.next() catch |err| return json_error(err);
    if (last != .end_of_document) return error.InvalidJSON;
    return fields;
}

fn trusted_operation_id(arena: Allocator, input_json: []const u8) !?u128 {
    // A second tolerant scan recovers identity without weakening strict entry validation.
    const operation_id_json = scan_unique_operation_id(arena, input_json) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return null;
    } orelse return null;
    return parse_canonical_operation_id(arena, operation_id_json) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return null;
    };
}

fn scan_unique_operation_id(arena: Allocator, input_json: []const u8) !?[]const u8 {
    var scanner = std.json.Scanner.initCompleteInput(arena, input_json);
    defer scanner.deinit();

    const first = scanner.next() catch |err| return json_error(err);
    if (first != .object_begin) return error.InvalidJSON;

    var operation_id_json: ?[]const u8 = null;
    var operation_id_count: usize = 0;
    var field_count: usize = 0;
    while (true) {
        const token = scanner.nextAllocMax(
            arena,
            .alloc_always,
            input_json.len,
        ) catch |err| return json_error(err);
        if (token == .object_end) break;
        const field_name = switch (token) {
            .allocated_string => |value| value,
            else => return error.InvalidJSON,
        };
        const value_start = try json_value_start(input_json, scanner.cursor);
        try scanner_skip_value(&scanner);
        if (std.mem.eql(u8, field_name, "operation_id")) {
            operation_id_count += 1;
            if (operation_id_count == 1) {
                operation_id_json = input_json[value_start..scanner.cursor];
            }
        }
        field_count += 1;
        std.debug.assert(field_count <= input_json.len);
    }
    const last = scanner.next() catch |err| return json_error(err);
    if (last != .end_of_document) return error.InvalidJSON;
    if (operation_id_count != 1) return null;
    return operation_id_json;
}

fn parse_canonical_operation_id(arena: Allocator, input_json: []const u8) !u128 {
    const id_text = std.json.parseFromSliceLeaky([]const u8, arena, input_json, .{
        .allocate = .alloc_always,
        .max_value_len = input_json.len,
    }) catch |err| return json_error(err);
    const operation_id = try operation.uuidFromString(id_text);
    var id_buffer: [operation.uuid_string_size]u8 = undefined;
    if (!std.mem.eql(u8, id_text, operation.uuidToString(operation_id, &id_buffer))) {
        return error.InvalidUUID;
    }
    return operation_id;
}

fn invalid_entry(operation_id: ?u128, cause: anyerror) DecodedEntry {
    std.debug.assert(cause != error.OutOfMemory);
    return .{ .invalid = .{ .operation_id = operation_id, .cause = cause } };
}

fn set_top_level_field(
    fields: *TopLevelFields,
    field_name: []const u8,
    value_json: []const u8,
) !void {
    if (!std.mem.eql(u8, field_name, "results")) return error.UnknownField;
    if (fields.results != null) return error.DuplicateField;
    fields.results = value_json;
}

fn set_entry_field(
    fields: *EntryFields,
    field_name: []const u8,
    value_json: []const u8,
) !void {
    if (std.mem.eql(u8, field_name, "operation_id")) {
        if (fields.operation_id != null) return error.DuplicateField;
        fields.operation_id = value_json;
    } else if (std.mem.eql(u8, field_name, "result")) {
        if (fields.result != null) return error.DuplicateField;
        fields.result = value_json;
    } else {
        return error.UnknownField;
    }
}

fn json_value_start(input_json: []const u8, cursor_after_key: usize) !usize {
    var cursor = cursor_after_key;
    while (cursor < input_json.len) : (cursor += 1) {
        if (!json_whitespace(input_json[cursor])) break;
    }
    if (cursor == input_json.len) return error.InvalidJSON;
    if (input_json[cursor] != ':') return error.InvalidJSON;
    return json_value_at_cursor(input_json, cursor + 1);
}

fn json_value_at_cursor(input_json: []const u8, cursor_start: usize) !usize {
    var cursor = cursor_start;
    while (cursor < input_json.len) : (cursor += 1) {
        if (!json_whitespace(input_json[cursor])) break;
    }
    if (cursor == input_json.len) return error.InvalidJSON;
    return cursor;
}

fn scanner_skip_value(scanner: *std.json.Scanner) !void {
    const token_type = scanner.peekNextTokenType() catch |err| return json_error(err);
    switch (token_type) {
        .object_end, .array_end, .end_of_document => return error.InvalidJSON,
        else => {},
    }
    scanner.skipValue() catch |err| return json_error(err);
}

fn json_whitespace(character: u8) bool {
    if (character == ' ') return true;
    if (character == '\t') return true;
    if (character == '\n') return true;
    return character == '\r';
}

fn json_error(err: anyerror) error{ OutOfMemory, InvalidJSON } {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJSON,
    };
}

const test_uuid = "00112233-4455-6677-8899-aabbccddeeff";
const test_uuid_2 = "ffeeddcc-bbaa-9988-7766-554433221100";

fn test_completion(arena: Allocator, input_json: []const u8) !operation.Completion {
    return operation.parseCompletionJSON(arena, input_json);
}

fn expect_valid_entry(
    decoded: DecodedEntry,
    expected_id: u128,
    expected_result_json: []const u8,
) !void {
    switch (decoded) {
        .invalid => return error.ExpectedValidEntry,
        .valid => |entry| {
            try std.testing.expectEqual(expected_id, entry.operation_id);
            var result_buffer: [operation.result_size_max]u8 = undefined;
            try std.testing.expectEqualStrings(
                expected_result_json,
                try operation.writeCompletionJSON(&result_buffer, &entry.result),
            );
        },
    }
}

fn expect_invalid_entry(
    decoded: DecodedEntry,
    expected_id: ?u128,
    expected_error: anyerror,
) !void {
    switch (decoded) {
        .valid => return error.ExpectedInvalidEntry,
        .invalid => |entry| {
            try std.testing.expectEqual(expected_id, entry.operation_id);
            try std.testing.expectEqual(expected_error, entry.cause);
        },
    }
}

test "completion batch encodes exact canonical JSON and round trips" {
    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena.deinit();
    const success_json = "{\"type\":\"SUCCESS\",\"payload\":{\"ok\":true}}";
    const id = try operation.uuidFromString(test_uuid);
    const entries = [_]Entry{.{
        .operation_id = id,
        .result = try test_completion(source_arena.allocator(), success_json),
    }};
    var encoded_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer encoded_arena.deinit();

    const encoded = try encode(encoded_arena.allocator(), &.{ .results = &entries });
    try std.testing.expectEqualStrings(
        "{\"results\":[{\"operation_id\":\"" ++ test_uuid ++
            "\",\"result\":" ++ success_json ++ "}]}",
        encoded,
    );

    var decoded_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer decoded_arena.deinit();
    const decoded = try decode(decoded_arena.allocator(), encoded);
    try std.testing.expectEqual(@as(usize, 1), decoded.results.len);
    try expect_valid_entry(decoded.results[0], id, success_json);
}

test "completion batch supports one or many success and failure results" {
    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena.deinit();
    const success_json = "{\"type\":\"SUCCESS\",\"payload\":true}";
    const failure_json = "{\"type\":\"FAILURE\",\"payload\":\"rejected\"}";
    const first_id = try operation.uuidFromString(test_uuid);
    const second_id = try operation.uuidFromString(test_uuid_2);
    const entries = [_]Entry{
        .{
            .operation_id = first_id,
            .result = try test_completion(source_arena.allocator(), success_json),
        },
        .{
            .operation_id = second_id,
            .result = try test_completion(source_arena.allocator(), failure_json),
        },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const single = try encode(arena.allocator(), &.{ .results = entries[0..1] });
    const multiple = try encode(arena.allocator(), &.{ .results = &entries });
    try std.testing.expect(single.len < multiple.len);
    const decoded = try decode(arena.allocator(), multiple);
    try std.testing.expectEqual(@as(usize, 2), decoded.results.len);
    try expect_valid_entry(decoded.results[0], first_id, success_json);
    try expect_valid_entry(decoded.results[1], second_id, failure_json);
}

test "completion batch emits canonical UUIDs and rejects non-canonical IDs" {
    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena.deinit();
    const id = try operation.uuidFromString("00112233-4455-6677-8899-AABBCCDDEEFF");
    const entries = [_]Entry{.{
        .operation_id = id,
        .result = try test_completion(
            source_arena.allocator(),
            "{\"type\":\"SUCCESS\",\"payload\":true}",
        ),
    }};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const encoded = try encode(arena.allocator(), &.{ .results = &entries });
    try std.testing.expect(std.mem.indexOf(u8, encoded, test_uuid) != null);

    const invalid_ids = [_][]const u8{
        "00112233",
        "00112233-4455-6677-8899-aabbccddeezz",
        "00112233-4455-6677-8899-AABBCCDDEEFF",
    };
    for (invalid_ids) |invalid_id| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"results\":[{{\"operation_id\":\"{s}\",\"result\":" ++
                "{{\"type\":\"SUCCESS\",\"payload\":true}}}}]}}",
            .{invalid_id},
        );
        defer std.testing.allocator.free(input);
        const decoded = try decode(arena.allocator(), input);
        try expect_invalid_entry(decoded.results[0], null, error.InvalidUUID);
    }
}

test "completion batch rejects empty result arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.EmptyResults,
        encode(arena.allocator(), &.{ .results = &.{} }),
    );
    try std.testing.expectError(
        error.EmptyResults,
        decode(arena.allocator(), "{\"results\":[]}"),
    );
}

test "completion batch enforces the exact encoded message boundary" {
    const result_overhead = "{\"type\":\"SUCCESS\",\"payload\":\"".len + "\"}".len;
    const entry_count = 252;
    const maximum_payload_size = operation.result_size_max - result_overhead;
    const entry_fixed_size = entry_prefix.len + operation.uuid_string_size +
        entry_middle.len + entry_suffix.len;
    const message_fixed_size = message_prefix.len + message_suffix.len +
        entry_count * entry_fixed_size + (entry_count - 1);
    const results_size = encoded_message_size_max - message_fixed_size;
    const final_result_size = results_size -
        (entry_count - 1) * operation.result_size_max;
    const final_payload_size = final_result_size - result_overhead;
    comptime {
        std.debug.assert(result_overhead == 31);
        std.debug.assert(message_fixed_size < encoded_message_size_max);
        std.debug.assert(final_result_size < operation.result_size_max);
        std.debug.assert(final_result_size > result_overhead);
        std.debug.assert(final_payload_size > 0);
    }

    const maximum_result: operation.Completion = .{
        .success = .{ .string = "a" ** maximum_payload_size },
    };
    const final_result: operation.Completion = .{
        .success = .{ .string = "b" ** final_payload_size },
    };
    const over_limit_result: operation.Completion = .{
        .success = .{ .string = "b" ** (final_payload_size + 1) },
    };
    const id = try operation.uuidFromString(test_uuid);
    var entries: [entry_count]Entry = undefined;
    for (&entries) |*entry| {
        entry.* = .{ .operation_id = id, .result = maximum_result };
    }
    entries[entry_count - 1].result = final_result;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const encoded = try encode(arena.allocator(), &.{ .results = &entries });
    try std.testing.expectEqual(encoded_message_size_max, encoded.len);
    const decoded = try decode(arena.allocator(), encoded);
    try std.testing.expectEqual(entry_count, decoded.results.len);

    entries[entry_count - 1].result = over_limit_result;
    try std.testing.expectError(
        error.MessageTooLarge,
        encode(arena.allocator(), &.{ .results = &entries }),
    );

    const oversized = try std.testing.allocator.alloc(u8, encoded_message_size_max + 1);
    defer std.testing.allocator.free(oversized);
    try std.testing.expectError(
        error.MessageTooLarge,
        decode(arena.allocator(), oversized),
    );
}

test "completion batch preserves the completion result-size error" {
    const oversized_result_json = "{\"type\":\"SUCCESS\",\"payload\":\"" ++
        ("a" ** (operation.result_size_max - 30)) ++ "\"}";
    comptime std.debug.assert(oversized_result_json.len == operation.result_size_max + 1);
    const oversized_result: operation.Completion = .{
        .success = .{ .string = "a" ** (operation.result_size_max - 30) },
    };
    const id = try operation.uuidFromString(test_uuid);
    const entry: Entry = .{ .operation_id = id, .result = oversized_result };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.ResultTooLarge,
        encode(arena.allocator(), &.{ .results = &.{entry} }),
    );
    const input = "{\"results\":[{\"operation_id\":\"" ++ test_uuid ++
        "\",\"result\":" ++ oversized_result_json ++ "}]}";
    const decoded = try decode(arena.allocator(), input);
    try expect_invalid_entry(decoded.results[0], id, error.ResultTooLarge);
}

test "completion batch rejects malformed top-level fields exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { input: []const u8, expected: anyerror }{
        .{ .input = "{}", .expected = error.MissingField },
        .{ .input = "[]", .expected = error.InvalidJSON },
        .{ .input = "{\"unknown\":[]}", .expected = error.UnknownField },
        .{
            .input = "{\"results\":[],\"results\":[]}",
            .expected = error.DuplicateField,
        },
        .{ .input = "{\"results\":true}", .expected = error.InvalidJSON },
        .{ .input = "{\"results\":[}", .expected = error.InvalidJSON },
    };
    for (cases) |case| {
        try std.testing.expectError(case.expected, decode(arena.allocator(), case.input));
    }
}

test "completion batch classifies malformed entry fields by ID trust" {
    const id = try operation.uuidFromString(test_uuid);
    const valid_result = "{\"type\":\"SUCCESS\",\"payload\":true}";
    const cases = [_]struct {
        entry: []const u8,
        expected_id: ?u128,
        expected: anyerror,
    }{
        .{ .entry = "true", .expected_id = null, .expected = error.InvalidJSON },
        .{
            .entry = "{\"result\":" ++ valid_result ++ "}",
            .expected_id = null,
            .expected = error.MissingField,
        },
        .{
            .entry = "{\"operation_id\":true,\"result\":" ++ valid_result ++ "}",
            .expected_id = null,
            .expected = error.InvalidJSON,
        },
        .{
            .entry = "{\"operation_id\":\"" ++ test_uuid ++ "\"}",
            .expected_id = id,
            .expected = error.MissingField,
        },
        .{
            .entry = "{\"operation_id\":\"" ++ test_uuid ++
                "\",\"result\":" ++ valid_result ++ ",\"extra\":true}",
            .expected_id = id,
            .expected = error.UnknownField,
        },
        .{
            .entry = "{\"operation_id\":\"" ++ test_uuid ++
                "\",\"result\":" ++ valid_result ++ ",\"result\":" ++
                valid_result ++ "}",
            .expected_id = id,
            .expected = error.DuplicateField,
        },
        .{
            .entry = "{\"operation_id\":\"" ++ test_uuid ++
                "\",\"operation_id\":\"" ++ test_uuid_2 ++
                "\",\"result\":" ++ valid_result ++ "}",
            .expected_id = null,
            .expected = error.DuplicateField,
        },
        .{
            .entry = "{\"operation_id\":\"" ++ test_uuid ++
                "\",\"result\":{\"type\":\"UNKNOWN\",\"payload\":true}}",
            .expected_id = id,
            .expected = error.InvalidCompletionType,
        },
        .{
            .entry = "{\"operation_id\":\"" ++ test_uuid ++
                "\",\"result\":false}",
            .expected_id = id,
            .expected = error.InvalidJSON,
        },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (cases) |case| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"results\":[{s}]}}",
            .{case.entry},
        );
        defer std.testing.allocator.free(input);
        const decoded = try decode(arena.allocator(), input);
        try expect_invalid_entry(decoded.results[0], case.expected_id, case.expected);
    }
}

test "completion batch owns decoded completion values in the arena" {
    const source = "{\"results\":[{\"operation_id\":\"" ++ test_uuid ++
        "\",\"result\":{\"type\":\"FAILURE\",\"payload\":{\"key\":[\"value\"]}}}]}";
    const input = try std.testing.allocator.dupe(u8, source);
    defer std.testing.allocator.free(input);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const decoded = try decode(arena.allocator(), input);
    @memset(input, 'x');
    const entry = switch (decoded.results[0]) {
        .valid => |value| value,
        .invalid => return error.ExpectedValidEntry,
    };
    const encoded = try encode(arena.allocator(), &.{ .results = &.{entry} });
    try std.testing.expectEqualStrings(source, encoded);
}

fn test_decode_allocation_failures(allocator: Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decoded = try decode(
        arena.allocator(),
        "{\"results\":[{\"operation_id\":\"" ++ test_uuid ++
            "\",\"result\":{\"type\":\"SUCCESS\",\"payload\":{\"key\":[\"value\"]}}}]}",
    );
    std.debug.assert(decoded.results.len == 1);
    std.debug.assert(decoded.results[0] == .valid);

    const invalid = try decode(
        arena.allocator(),
        "{\"results\":[{\"operation_id\":\"" ++ test_uuid ++
            "\",\"result\":true,\"unknown\":false}]}",
    );
    std.debug.assert(invalid.results.len == 1);
    std.debug.assert(invalid.results[0] == .invalid);
    std.debug.assert(invalid.results[0].invalid.operation_id != null);
}

fn test_encode_allocation_failures(allocator: Allocator) !void {
    const entry: Entry = .{
        .operation_id = try operation.uuidFromString(test_uuid),
        .result = .{ .success = .{ .string = "value" } },
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const encoded = try encode(arena.allocator(), &.{ .results = &.{entry} });
    std.debug.assert(encoded.len > 0);
    std.debug.assert(encoded.len <= encoded_message_size_max);
}

test "completion batch cleans up every allocation failure path" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        test_decode_allocation_failures,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        test_encode_allocation_failures,
        .{},
    );
}
