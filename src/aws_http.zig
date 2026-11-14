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
    headers: []const http.Header = &.{},
    body_json: ?[]const u8 = null,
    base64: bool = false,

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
        return .{
            .method = request.method,
            .path = request.path,
            .headers = request.headers,
            .body = .{ .deferred = .{ .context = request, .read_fn = read_body } },
        };
    }

    fn read_body(context: *anyopaque, _: std.mem.Allocator) anyerror!?[]const u8 {
        const request: *Request = @ptrCast(@alignCast(context));
        const json = request.body_json orelse return null;
        // Transport storage has the same request lifetime, including on error paths.
        const arena = request.arena.allocator();
        const bytes = try parse_value([]const u8, arena, json);
        if (!request.base64) return bytes;
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(bytes) catch return error.InvalidBodyEncoding;
        const decoded = try arena.alloc(u8, size);
        decoder.decode(decoded, bytes) catch return error.InvalidBodyEncoding;
        return decoded;
    }
};

fn parse_value(comptime T: type, arena: std.mem.Allocator, json: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, json, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
        .max_value_len = json.len,
    });
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
        .body = .{ .textual = response.body },
    });
}
