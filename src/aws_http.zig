const std = @import("std");
const lambda = @import("aws-lambda");
const http = @import("http");

pub const internal_server_error_response =
    "{\"statusCode\":500,\"headers\":{\"Content-Type\":\"text/plain; charset=utf-8\"}," ++
    "\"body\":\"Internal Server Error\\n\"}";

/// Owns metadata and materialized body bytes until response encoding finishes.
/// The event is borrowed. Scanning validates JSON without copying its body string.
pub const Request = struct {
    arena: std.heap.ArenaAllocator,
    method: ?std.http.Method = null,
    path: ?[]const u8 = null,
    raw_query_json: ?[]const u8 = null,
    headers: []const http.Header = &.{},
    cookies_json: ?[]const u8 = null,
    body_json: ?[]const u8 = null,
    base64: bool = false,
    body_size_max: ?usize = null,

    pub fn parse(allocator: std.mem.Allocator, event: []const u8) !Request {
        var request: Request = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
        errdefer request.arena.deinit();
        const arena = request.arena.allocator();
        var fields = try ObjectFields.init(arena, event);
        defer fields.deinit();
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        while (try fields.next(arena)) |field| {
            const entry = try seen.getOrPut(arena, field.key);
            if (entry.found_existing) return error.InvalidEvent;
            if (std.mem.eql(u8, field.key, "version")) {
                const version = try parse_value([]const u8, arena, field.value);
                if (!std.mem.eql(u8, version, "2.0")) return error.InvalidEvent;
            } else if (std.mem.eql(u8, field.key, "rawPath")) {
                request.path = try parse_value(?[]const u8, arena, field.value);
            } else if (std.mem.eql(u8, field.key, "rawQueryString")) {
                request.raw_query_json = field.value;
            } else if (std.mem.eql(u8, field.key, "cookies")) {
                request.cookies_json = field.value;
            } else if (std.mem.eql(u8, field.key, "requestContext")) {
                const Context = struct { http: struct { method: ?[]const u8 = null } = .{} };
                const context = try parse_value(Context, arena, field.value);
                if (context.http.method) |method| {
                    request.method = std.meta.stringToEnum(std.http.Method, method);
                }
            } else if (std.mem.eql(u8, field.key, "headers")) {
                request.headers = try parse_headers(arena, field.value);
            } else if (std.mem.eql(u8, field.key, "body")) {
                if (!std.mem.eql(u8, field.value, "null")) {
                    if (field.value[0] != '"') return error.InvalidEvent;
                    request.body_json = field.value;
                }
            } else if (std.mem.eql(u8, field.key, "isBase64Encoded")) {
                request.base64 = try parse_value(bool, arena, field.value);
            }
        }
        return request;
    }

    pub fn deinit(request: *Request) void {
        request.arena.deinit();
        request.* = undefined;
    }

    pub fn application_request(request: *Request) http.HttpRequest {
        // The scanner retains the raw JSON string. A zero-byte body is represented by "".
        const is_empty = if (request.body_json) |json| std.mem.eql(u8, json, "\"\"") else true;
        return .{
            .method = request.method,
            .path = request.path,
            .headers = request.headers,
            .body = .{ .deferred = .{
                .context = request,
                .is_empty = is_empty,
                .read_fn = read_body,
            } },
        };
    }

    /// Only handlers that use navigation metadata materialize the raw query and cookies.
    pub fn navigation_request(request: *Request) !http.HttpRequest {
        var application = request.application_request();
        const arena = request.arena.allocator();
        // A JSON escape can use six bytes per decoded byte. Cookie arrays also have
        // delimiters and quotes, so leave space for that overhead before decoding.
        const encoded_size_max = 8 * http.navigation_size_max;
        if (request.raw_query_json) |json| {
            if (json.len > encoded_size_max) return error.ValueTooLong;
            application.raw_query = (try parse_value_bounded(
                ?[]const u8,
                arena,
                json,
                http.navigation_size_max,
            )) orelse "";
            if (application.raw_query.len > http.navigation_size_max) return error.ValueTooLong;
        }
        if (request.cookies_json) |json| {
            if (json.len > encoded_size_max) return error.ValueTooLong;
            application.cookies = (try parse_value_bounded(
                ?[]const []const u8,
                arena,
                json,
                http.navigation_size_max,
            )) orelse &.{};
        }
        return application;
    }

    fn read_body(context: *anyopaque, _: std.mem.Allocator) anyerror!?[]const u8 {
        const request: *Request = @ptrCast(@alignCast(context));
        const json = request.body_json orelse return null;
        // Transport storage has the same request lifetime, including on error paths.
        const arena = request.arena.allocator();
        const decoded_size_max = request.body_size_max orelse json.len;
        const encoded_size_max = if (request.base64)
            @divFloor(decoded_size_max +| 2, 3) *| 4
        else
            decoded_size_max;
        const bytes = try std.json.parseFromSliceLeaky([]const u8, arena, json, .{
            .allocate = .alloc_always,
            .max_value_len = @min(encoded_size_max, json.len),
        });
        if (!request.base64) return bytes;
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(bytes) catch return error.InvalidBodyEncoding;
        if (size > decoded_size_max) return error.ValueTooLong;
        const decoded = try arena.alloc(u8, size);
        decoder.decode(decoded, bytes) catch return error.InvalidBodyEncoding;
        return decoded;
    }
};

test "AWS payload adaptation bounds plain and base64 body allocation" {
    const http_test = @import("http_test_support");
    const allocator = std.testing.allocator;
    for ([_]struct { body: []const u8, base64: bool, allowed: bool }{
        .{ .body = "xx", .base64 = false, .allowed = true },
        .{ .body = "xxx", .base64 = false, .allowed = false },
        .{ .body = "eHg=", .base64 = true, .allowed = true },
        .{ .body = "eHh4", .base64 = true, .allowed = false },
        .{ .body = "eHh4eA==", .base64 = true, .allowed = false },
    }) |case| {
        const event = try http_test.aws_event(allocator, .{
            .body = case.body,
            .base64 = case.base64,
        });
        defer allocator.free(event);
        var adapted = try Request.parse(allocator, event);
        defer adapted.deinit();
        adapted.body_size_max = 2;
        const request = adapted.application_request();
        const body = request.read_body(allocator);
        if (case.allowed) {
            try std.testing.expectEqualStrings("xx", (try body).?);
        } else {
            try std.testing.expectError(error.ValueTooLong, body);
        }
    }
}

fn parse_value(comptime T: type, arena: std.mem.Allocator, json: []const u8) !T {
    return parse_value_bounded(T, arena, json, json.len);
}

fn parse_value_bounded(
    comptime T: type,
    arena: std.mem.Allocator,
    json: []const u8,
    size_max: usize,
) !T {
    return std.json.parseFromSliceLeaky(T, arena, json, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
        .max_value_len = size_max,
    });
}

test "AWS payload navigation is decoded only when requested and has a size limit" {
    const allocator = std.testing.allocator;
    const prefix = "fixture=";
    const value: [http.navigation_size_max + 1 - prefix.len]u8 = @splat('x');
    const oversized = prefix ++ &value;
    for ([_]struct {
        raw_query: ?[]const u8 = null,
        cookies: ?[]const []const u8 = null,
    }{
        .{ .raw_query = oversized },
        .{ .cookies = &.{oversized} },
    }) |fields| {
        const event = try std.json.Stringify.valueAlloc(allocator, .{
            .version = "2.0",
            .rawPath = "/operations",
            .rawQueryString = fields.raw_query,
            .cookies = fields.cookies,
        }, .{ .emit_null_optional_fields = false });
        defer allocator.free(event);
        var request = try Request.parse(allocator, event);
        defer request.deinit();
        const application = request.application_request();
        try std.testing.expectEqualStrings("/operations", application.path.?);
        try std.testing.expectEqualStrings("", application.raw_query);
        try std.testing.expectEqual(0, application.cookies.len);
        try std.testing.expectError(error.ValueTooLong, request.navigation_request());
    }
}

fn parse_headers(arena: std.mem.Allocator, json: []const u8) ![]const http.Header {
    var fields = try ObjectFields.init(arena, json);
    defer fields.deinit();
    var headers: std.ArrayList(http.Header) = .empty;
    while (try fields.next(arena)) |field| {
        // Keep every spelling, including duplicate keys, for ambiguous credential rejection.
        try headers.append(arena, .{
            .key = field.key,
            .value = try parse_value([]const u8, arena, field.value),
        });
    }
    return headers.toOwnedSlice(arena);
}

/// Iterates raw values, with work and scanner storage bounded by the supplied event.
/// Body strings are scanned for JSON validity but never accumulated here.
const ObjectFields = struct {
    scanner: std.json.Scanner,
    json: []const u8,

    fn init(arena: std.mem.Allocator, json: []const u8) !ObjectFields {
        var scanner = std.json.Scanner.initCompleteInput(arena, json);
        errdefer scanner.deinit();
        if (try scanner.next() != .object_begin) return error.InvalidEvent;
        return .{ .scanner = scanner, .json = json };
    }

    fn deinit(fields: *ObjectFields) void {
        fields.scanner.deinit();
    }

    const Field = struct { key: []const u8, value: []const u8 };

    fn next(fields: *ObjectFields, arena: std.mem.Allocator) !?Field {
        const token = try fields.scanner.nextAllocMax(arena, .alloc_always, fields.json.len);
        if (token == .object_end) {
            if (try fields.scanner.next() != .end_of_document) return error.InvalidEvent;
            return null;
        }
        const key = switch (token) {
            .allocated_string => |key| key,
            else => return error.InvalidEvent,
        };
        const rest = std.mem.trimStart(u8, fields.json[fields.scanner.cursor..], " \t\r\n");
        if (rest.len == 0 or rest[0] != ':') return error.InvalidEvent;
        const value = std.mem.trimStart(u8, rest[1..], " \t\r\n");
        const start = fields.json.len - value.len;
        switch (try fields.scanner.peekNextTokenType()) {
            .object_end, .array_end, .end_of_document => return error.InvalidEvent,
            else => {},
        }
        try fields.scanner.skipValue();
        std.debug.assert(start < fields.scanner.cursor);
        std.debug.assert(fields.scanner.cursor <= fields.json.len);
        return .{ .key = key, .value = fields.json[start..fields.scanner.cursor] };
    }
};

/// Borrows response data; the entry point releases it only after encoding completes.
pub fn encode_response(
    allocator: std.mem.Allocator,
    response: *const http.HttpResponse,
) ![]const u8 {
    const ProviderHeader = std.meta.Elem(@FieldType(lambda.url.Response, "headers"));
    const headers = try allocator.alloc(ProviderHeader, response.headers.len);
    defer allocator.free(headers);
    for (response.headers, headers) |source, *target| {
        target.* = .{ .key = source.key, .value = source.value };
    }
    return lambda.url.encodeResponse(allocator, .{
        .status_code = response.status,
        .headers = headers,
        .cookies = response.cookies,
        .body = .{ .textual = response.body },
    });
}

test "AWS payload adaptation identifies empty bodies without decoding them" {
    const http_test = @import("http_test_support");
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        body: ?[]const u8,
        base64: bool = false,
        is_empty: bool,
    }{
        .{ .body = null, .is_empty = true },
        .{ .body = "", .is_empty = true },
        .{ .body = "", .base64 = true, .is_empty = true },
        .{ .body = "\n", .is_empty = false },
        .{ .body = "Cg==", .base64 = true, .is_empty = false },
        .{ .body = "!", .base64 = true, .is_empty = false },
    };
    for (cases) |case| {
        const event = try http_test.aws_event(allocator, .{
            .body = case.body,
            .base64 = case.base64,
        });
        defer allocator.free(event);
        var adapted = try Request.parse(allocator, event);
        defer adapted.deinit();
        const request = adapted.application_request();
        try std.testing.expectEqual(case.is_empty, request.body_is_empty());
    }
}
