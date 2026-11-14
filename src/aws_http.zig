const std = @import("std");
const lambda = @import("aws-lambda");
const http = @import("http");

pub const internal_server_error_response =
    "{\"statusCode\":500,\"headers\":{\"Content-Type\":\"text/plain; charset=utf-8\"}," ++
    "\"body\":\"Internal Server Error\\n\"}";

/// Owns provider parsing and application headers through the handler call.
/// The pinned parser still copies body strings and accepts only Function URL routes.
pub const Request = struct {
    provider: lambda.url.Request,
    headers: []http.Header,

    pub fn parse(allocator: std.mem.Allocator, event: []const u8) !Request {
        const provider = try lambda.url.parseRequest(allocator, event);
        errdefer provider.deinit(allocator);
        const headers = try allocator.alloc(http.Header, provider.headers.len);
        for (provider.headers, headers) |source, *target| {
            target.* = .{ .key = source.key, .value = source.value };
        }
        return .{ .provider = provider, .headers = headers };
    }

    pub fn deinit(request: *Request, allocator: std.mem.Allocator) void {
        allocator.free(request.headers);
        request.provider.deinit(allocator);
        request.* = undefined;
    }

    pub fn application_request(request: *const Request) http.HttpRequest {
        return .{
            .method = request.provider.request_context.http.method,
            .path = request.provider.raw_path,
            .headers = request.headers,
            .body = if (request.provider.body) |bytes| .{ .bytes = bytes } else .empty,
        };
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
