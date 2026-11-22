const std = @import("std");
const device_login = @import("device_login");

const poll_body = "{\"device_code\":\"private-code-fixture\"}";
const start_path = "/auth/github/device/start";
const poll_path = "/auth/github/device/poll";
const approval_body =
    \\{"device_code":"private-code-fixture","user_code":"WDJB-MJHT",
    \\"verification_uri":"https://github.com/login/device","interval":5,"expires_in":60}
;

test "Operations HTTP client preserves POST origin and handles Retry-After and redirects" {
    const io = std.testing.io;
    const loopback: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try loopback.listen(io, .{ .mode = .stream });
    defer listener.deinit(io);
    const host = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{listener.socket.address});
    defer std.testing.allocator.free(host);
    var peer = try io.concurrent(serve_operations, .{ io, &listener, host });
    defer peer.cancel(io) catch {};
    var runtime = device_login.Runtime.init(std.testing.allocator, io);
    defer runtime.client.deinit();
    const services = runtime.services();
    var buffer: [4096]u8 = undefined;
    // The CLI tests cover HTTPS origin validation. The loopback peer checks the
    // same production HTTP request and redirect handling without a TLS certificate.
    var uri: std.Uri = .{
        .scheme = "http",
        .host = .{ .raw = "127.0.0.1" },
        .port = listener.socket.address.getPort(),
        .path = .{ .raw = start_path },
    };
    const deadline_ns = services.now(services.context) + 5 * std.time.ns_per_s;
    const start = try services.post(services.context, &uri, "", &buffer, deadline_ns);
    try std.testing.expectEqual(.ok, start.status);
    try std.testing.expectEqualStrings(approval_body, start.body);
    uri.path = .{ .raw = poll_path };
    const slow_down = try services.post(services.context, &uri, poll_body, &buffer, deadline_ns);
    try std.testing.expectEqual(.too_many_requests, slow_down.status);
    try std.testing.expectEqual(@as(?u32, 17), slow_down.retry_after_seconds);
    const redirect = try services.post(services.context, &uri, poll_body, &buffer, deadline_ns);
    try std.testing.expectEqual(.temporary_redirect, redirect.status);
    try peer.await(io);
}

test "Operations HTTP client cancels a request when the peer stalls past its deadline" {
    const io = std.testing.io;
    const loopback: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try loopback.listen(io, .{ .mode = .stream });
    defer listener.deinit(io);
    var peer = try io.concurrent(stall, .{ io, &listener });
    defer peer.cancel(io) catch {};
    var runtime = device_login.Runtime.init(std.testing.allocator, io);
    defer runtime.client.deinit();
    const services = runtime.services();
    var buffer: [4096]u8 = undefined;
    const uri: std.Uri = .{
        .scheme = "http",
        .host = .{ .raw = "127.0.0.1" },
        .port = listener.socket.address.getPort(),
        .path = .{ .raw = poll_path },
    };
    const deadline_ns = services.now(services.context) + 250 * std.time.ns_per_ms;
    try std.testing.expectError(
        error.RequestTimeout,
        services.post(services.context, &uri, poll_body, &buffer, deadline_ns),
    );
}

fn stall(io: std.Io, listener: *std.Io.net.Server) !void {
    const connection = try listener.accept(io);
    defer connection.close(io);
    try io.sleep(.fromSeconds(5), .boot);
}

fn serve_operations(io: std.Io, listener: *std.Io.net.Server, host: []const u8) !void {
    try respond(
        io,
        listener,
        host,
        .{ .path = start_path, .request_body = "", .response_body = approval_body },
        .{ .keep_alive = false },
    );
    try respond(io, listener, host, .{
        .path = poll_path,
        .request_body = poll_body,
        .response_body = "{\"error\":\"slow_down\"}",
    }, .{
        .status = .too_many_requests,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "Retry-After", .value = "17" }},
    });
    try respond(io, listener, host, .{ .path = poll_path, .request_body = poll_body }, .{
        .status = .temporary_redirect,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "Location", .value = "https://127.0.0.1:1/redirected" }},
    });
}

const Exchange = struct {
    path: []const u8,
    request_body: []const u8,
    response_body: []const u8 = "",
};

fn respond(
    io: std.Io,
    listener: *std.Io.net.Server,
    host: []const u8,
    exchange: Exchange,
    options: std.http.Server.Request.RespondOptions,
) !void {
    const connection = try listener.accept(io);
    defer connection.close(io);
    var input_buffer: [4096]u8 = undefined;
    var output_buffer: [1024]u8 = undefined;
    var reader = connection.reader(io, &input_buffer);
    var writer = connection.writer(io, &output_buffer);
    var server: std.http.Server = .init(&reader.interface, &writer.interface);
    var request = try server.receiveHead();
    try std.testing.expectEqual(.POST, request.head.method);
    try std.testing.expectEqualStrings(exchange.path, request.head.target);
    try std.testing.expectEqual(exchange.request_body.len, request.head.content_length orelse
        return error.MissingContentLength);
    var headers = request.iterateHeaders();
    var host_seen = false;
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "host")) {
            try std.testing.expectEqualStrings(host, header.value);
            host_seen = true;
        }
        try std.testing.expect(!std.ascii.eqlIgnoreCase(header.name, "authorization"));
    }
    try std.testing.expect(host_seen);
    if (exchange.request_body.len > 0) {
        try std.testing.expectEqualStrings("application/json", request.head.content_type orelse
            return error.MissingContentType);
        var body_buffer: [poll_body.len]u8 = undefined;
        const body_reader = try request.readerExpectContinue(&body_buffer);
        try std.testing.expectEqualStrings(
            exchange.request_body,
            try body_reader.take(exchange.request_body.len),
        );
    }
    try request.respond(exchange.response_body, options);
}
