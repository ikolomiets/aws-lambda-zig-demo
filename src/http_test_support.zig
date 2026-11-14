const std = @import("std");
const http = @import("http");

/// Owns test credentials; application request fields otherwise borrow the test's input.
pub const Request = struct {
    request: http.HttpRequest,

    pub const Options = struct {
        method: ?std.http.Method,
        path: ?[]const u8 = null,
        token: ?[]const u8 = null,
        header_name: []const u8 = "Authorization",
        scheme: []const u8 = "Bearer",
        body: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !Request {
        const headers = try allocator.alloc(http.Header, if (options.token != null) 1 else 0);
        errdefer allocator.free(headers);
        if (options.token) |token| {
            headers[0] = .{
                .key = options.header_name,
                .value = try std.fmt.allocPrint(allocator, "{s} {s}", .{ options.scheme, token }),
            };
        }
        return .{ .request = .{
            .method = options.method,
            .path = options.path,
            .headers = headers,
            .body = if (options.body) |bytes| .{ .bytes = bytes } else .empty,
        } };
    }

    pub fn deinit(fixture: *Request, allocator: std.mem.Allocator) void {
        for (fixture.request.headers) |header| allocator.free(header.value);
        allocator.free(fixture.request.headers);
        fixture.* = undefined;
    }
};

pub fn expect_response(expected: *const http.HttpResponse, actual: *const http.HttpResponse) !void {
    try std.testing.expectEqual(expected.status, actual.status);
    try std.testing.expectEqual(expected.headers.len, actual.headers.len);
    for (expected.headers, actual.headers) |expected_header, actual_header| {
        try std.testing.expectEqualStrings(expected_header.key, actual_header.key);
        try std.testing.expectEqualStrings(expected_header.value, actual_header.value);
    }
    try std.testing.expectEqualStrings(expected.body, actual.body);
}

pub fn expect_text_response(
    status: std.http.Status,
    body: []const u8,
    actual: *const http.HttpResponse,
) !void {
    try expect_response(&.{
        .status = status,
        .headers = &.{.{ .key = "Content-Type", .value = "text/plain; charset=utf-8" }},
        .body = body,
    }, actual);
}

/// Realistic payload 2.0 metadata; Function URL variants omit gateway routing metadata.
pub fn aws_event(allocator: std.mem.Allocator, options: struct {
    method: std.http.Method = .POST,
    path: []const u8 = "/operations",
    route: ?[]const u8 = "POST /operations",
    token: ?[]const u8 = null,
    body: ?[]const u8 = null,
    base64: bool = false,
    content_type: ?[]const u8 = null,
}) ![]u8 {
    const bearer = if (options.token) |token|
        try std.fmt.allocPrint(allocator, "Bearer {s}", .{token})
    else
        null;
    defer if (bearer) |value| allocator.free(value);
    return std.json.Stringify.valueAlloc(allocator, .{
        .version = "2.0",
        .routeKey = options.route orelse "$default",
        .rawPath = options.path,
        .rawQueryString = "id=ffffffff-ffff-ffff-ffff-ffffffffffff",
        .pathParameters = if (options.route != null)
            @as(?struct { id: []const u8 }, .{ .id = "ffffffff-ffff-ffff-ffff-ffffffffffff" })
        else
            null,
        .headers = .{
            .aUtHoRiZaTiOn = bearer orelse "",
            .@"content-type" = options.content_type,
        },
        .requestContext = .{
            .stage = "$default",
            .requestId = "request-id",
            .domainName = "example.execute-api.ca-central-1.amazonaws.com",
            .http = .{ .method = @tagName(options.method), .path = options.path },
        },
        .body = options.body,
        .isBase64Encoded = options.base64,
    }, .{ .emit_null_optional_fields = false });
}
