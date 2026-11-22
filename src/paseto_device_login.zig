const std = @import("std");
const paseto = @import("paseto");

const Allocator = std.mem.Allocator;
const response_size_max = 2 * paseto.token_size_max;
const poll_body_size_max = 1024;
const backoff_seconds_max = 60;
const request_seconds_max = 30;
const start_path = "/auth/github/device/start";
const poll_path = "/auth/github/device/poll";

pub const Services = struct {
    context: *anyopaque,
    post: *const fn (
        context: *anyopaque,
        uri: *const std.Uri,
        payload: []const u8,
        buffer: []u8,
        deadline_ns: i96,
    ) anyerror!Response,
    now: *const fn (*anyopaque) i96,
    sleep: *const fn (*anyopaque, std.Io.Duration) anyerror!void,
};

pub const Response = struct {
    status: std.http.Status,
    body: []const u8,
    retry_after_seconds: ?u32 = null,
};

const Approval = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    interval: u32,
    expires_in: u32,
};

const Pending = struct {
    @"error": []const u8,
    interval: u32,
};

const Credential = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in: u32,
};

const Output = struct {
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

const PollSchedule = struct {
    deadline_ns: i96,
    interval_seconds: u32,
};

pub fn run(
    allocator: Allocator,
    services: *const Services,
    origin_text: []const u8,
    output: Output,
) !void {
    var uri = try parse_origin(origin_text);
    var response_buffer: [response_size_max]u8 = undefined;
    defer std.crypto.secureZero(u8, &response_buffer);
    var poll_body_buffer: [poll_body_size_max]u8 = undefined;
    defer std.crypto.secureZero(u8, &poll_body_buffer);
    var poll_body: std.Io.Writer = .fixed(&poll_body_buffer);
    uri.path = .{ .raw = start_path };
    const schedule = try start(allocator, services, &uri, &response_buffer, .{
        .poll_body = &poll_body,
        .stderr = output.stderr,
    });
    uri.path = .{ .raw = poll_path };
    var interval_seconds = schedule.interval_seconds;
    var delay_seconds = interval_seconds;
    while (true) {
        // Positive delays and the grant deadline bound the number of requests.
        std.debug.assert(delay_seconds >= interval_seconds);
        try wait_for_poll(services, schedule.deadline_ns, delay_seconds);
        const poll = try post(
            services,
            &uri,
            poll_body.buffered(),
            &response_buffer,
            .{ .grant_deadline_ns = schedule.deadline_ns },
        );
        switch (poll.status) {
            .ok => return write_credential(allocator, poll.body, output.stdout),
            .accepted => {
                interval_seconds = try pending_interval(allocator, poll.body);
                delay_seconds = interval_seconds;
            },
            .too_many_requests => {
                delay_seconds = if (poll.retry_after_seconds) |seconds|
                    @max(interval_seconds, seconds)
                else
                    backoff(delay_seconds);
            },
            .service_unavailable => delay_seconds = backoff(delay_seconds),
            .forbidden => return error.SignInDenied,
            .gone => return error.SignInExpired,
            else => return response_error(poll.status),
        }
    }
}

fn start(
    allocator: Allocator,
    services: *const Services,
    uri: *const std.Uri,
    response_buffer: []u8,
    writers: struct { poll_body: *std.Io.Writer, stderr: *std.Io.Writer },
) !PollSchedule {
    const response = try post(services, uri, "", response_buffer, .{});
    defer std.crypto.secureZero(u8, response_buffer);
    if (response.status != .ok) return response_error(response.status);
    const started_ns = services.now(services.context);
    const approval = std.json.parseFromSlice(Approval, allocator, response.body, .{
        .ignore_unknown_fields = true,
    }) catch return error.SignInFailed;
    defer approval.deinit();
    const fields = &approval.value;
    if (fields.interval == 0 or fields.expires_in == 0) return error.SignInFailed;
    if (fields.device_code.len == 0) return error.SignInFailed;
    if (!valid_prompt(fields)) return error.SignInFailed;
    std.json.Stringify.value(.{ .device_code = fields.device_code }, .{}, writers.poll_body) catch {
        return error.SignInFailed;
    };
    try writers.stderr.print("Open {s} in your browser and enter code {s}.\n", .{
        fields.verification_uri,
        fields.user_code,
    });
    try writers.stderr.flush();
    return .{
        .deadline_ns = started_ns + @as(i96, fields.expires_in) * std.time.ns_per_s,
        .interval_seconds = fields.interval,
    };
}

fn wait_for_poll(services: *const Services, deadline_ns: i96, delay_seconds: u32) !void {
    std.debug.assert(delay_seconds > 0);
    const now_ns = services.now(services.context);
    if (now_ns >= deadline_ns) return error.SignInExpired;
    const delay = std.Io.Duration.fromSeconds(delay_seconds);
    const sleep_ns = @min(delay.nanoseconds, deadline_ns - now_ns);
    try services.sleep(services.context, .{ .nanoseconds = sleep_ns });
    if (services.now(services.context) >= deadline_ns) return error.SignInExpired;
}

fn backoff(delay_seconds: u32) u32 {
    // A server-specified Retry-After can already exceed the local backoff cap.
    if (delay_seconds >= backoff_seconds_max) return delay_seconds;
    return @min(delay_seconds * 2, backoff_seconds_max);
}

fn pending_interval(allocator: Allocator, body: []const u8) !u32 {
    const pending = std.json.parseFromSlice(Pending, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.SignInFailed;
    defer pending.deinit();
    if (!std.mem.eql(u8, pending.value.@"error", "authorization_pending")) {
        return error.SignInFailed;
    }
    if (pending.value.interval == 0) return error.SignInFailed;
    return pending.value.interval;
}

fn write_credential(allocator: Allocator, body: []const u8, stdout: *std.Io.Writer) !void {
    const credential = std.json.parseFromSlice(Credential, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.SignInFailed;
    defer credential.deinit();
    if (!std.mem.eql(u8, credential.value.token_type, "Bearer")) return error.SignInFailed;
    if (credential.value.expires_in == 0) return error.SignInFailed;
    const token = credential.value.access_token;
    paseto.validate_token_format(token) catch return error.SignInFailed;
    try stdout.print("{s}\n", .{token});
}

fn response_error(status: std.http.Status) error{ SignInFailed, SignInRedirected, SignInExchange } {
    if (status.class() == .redirect) return error.SignInRedirected;
    if (status == .internal_server_error) return error.SignInExchange;
    return error.SignInFailed;
}

fn parse_origin(text: []const u8) !std.Uri {
    var uri = std.Uri.parse(text) catch return error.InvalidOrigin;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InvalidOrigin;
    if (uri.user != null or uri.password != null) return error.InvalidOrigin;
    if (uri.query != null or uri.fragment != null) return error.InvalidOrigin;
    const path = uri.path.percent_encoded;
    if (path.len != 0 and !std.mem.eql(u8, path, "/")) return error.InvalidOrigin;
    const host = uri.host orelse return error.InvalidOrigin;
    std.Io.net.HostName.validate(host.percent_encoded) catch return error.InvalidOrigin;
    if (uri.port) |port| {
        if (port == 0) return error.InvalidOrigin;
        const authority = text["https://".len .. text.len - path.len];
        const port_separator = host.percent_encoded.len;
        std.debug.assert(authority[port_separator] == ':');
        for (authority[port_separator + 1 ..]) |byte| {
            if (!std.ascii.isDigit(byte)) return error.InvalidOrigin;
        }
    }
    uri.scheme = "https";
    return uri;
}

fn valid_prompt(approval: *const Approval) bool {
    if (approval.user_code.len == 0 or approval.user_code.len > 32) return false;
    if (approval.verification_uri.len > 512) return false;
    if (std.mem.find(u8, approval.verification_uri, approval.device_code) != null) return false;
    if (std.mem.find(u8, approval.user_code, approval.device_code) != null) return false;
    for (approval.user_code) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-') return false;
    }
    for (approval.verification_uri) |byte| {
        if (byte <= ' ' or byte >= 127) return false;
    }
    const uri = std.Uri.parse(approval.verification_uri) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return false;
    if (uri.user != null or uri.password != null) return false;
    const host = uri.host orelse return false;
    std.Io.net.HostName.validate(host.percent_encoded) catch return false;
    return true;
}

fn post(
    services: *const Services,
    uri: *const std.Uri,
    body: []const u8,
    buffer: []u8,
    options: struct { grant_deadline_ns: ?i96 = null },
) !Response {
    const now_ns = services.now(services.context);
    const timeout_ns = now_ns + request_seconds_max * std.time.ns_per_s;
    const deadline_ns = @min(timeout_ns, options.grant_deadline_ns orelse timeout_ns);
    if (now_ns >= deadline_ns) return error.SignInExpired;
    const response = services.post(services.context, uri, body, buffer, deadline_ns);
    const finished_ns = services.now(services.context);
    if (options.grant_deadline_ns) |grant_deadline| {
        if (finished_ns >= grant_deadline) return error.SignInExpired;
    }
    if (finished_ns >= deadline_ns) return error.SignInFailed;
    return response catch return error.SignInFailed;
}

pub const Runtime = struct {
    client: std.http.Client,

    pub fn init(allocator: Allocator, io: std.Io) Runtime {
        return .{ .client = .{ .allocator = allocator, .io = io } };
    }

    pub fn services(runtime: *Runtime) Services {
        return .{ .context = runtime, .post = post_http, .now = now, .sleep = sleep };
    }

    fn now(context: *anyopaque) i96 {
        const runtime: *Runtime = @ptrCast(@alignCast(context));
        return std.Io.Clock.boot.now(runtime.client.io).nanoseconds;
    }

    fn sleep(context: *anyopaque, duration: std.Io.Duration) !void {
        const runtime: *Runtime = @ptrCast(@alignCast(context));
        try runtime.client.io.sleep(duration, .boot);
    }

    fn post_http(
        context: *anyopaque,
        uri: *const std.Uri,
        payload: []const u8,
        buffer: []u8,
        deadline_ns: i96,
    ) !Response {
        const runtime: *Runtime = @ptrCast(@alignCast(context));
        const io = runtime.client.io;
        const Result = union(enum) { response: anyerror!Response, timeout: std.Io.Cancelable!void };
        var results: [2]Result = undefined;
        var select: std.Io.Select(Result) = .init(io, &results);
        // Join the request worker before the caller reuses its buffers or client.
        defer select.cancelDiscard();
        const timeout: std.Io.Timeout = .{ .deadline = .{
            .clock = .boot,
            .raw = .{ .nanoseconds = deadline_ns },
        } };
        try select.concurrent(.timeout, std.Io.Timeout.sleep, .{ timeout, io });
        try select.concurrent(.response, send_http, .{ runtime, uri, payload, buffer });
        return switch (try select.await()) {
            .response => |response| response,
            .timeout => |timer| result: {
                try timer;
                break :result error.RequestTimeout;
            },
        };
    }

    fn send_http(
        runtime: *Runtime,
        uri: *const std.Uri,
        payload: []const u8,
        buffer: []u8,
    ) !Response {
        const json_headers: []const std.http.Header = &.{
            .{ .name = "Content-Type", .value = "application/json" },
        };
        var request = try runtime.client.request(.POST, uri.*, .{
            .redirect_behavior = .unhandled,
            .extra_headers = if (payload.len > 0) json_headers else &.{},
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
            .keep_alive = false,
        });
        defer request.deinit();
        request.transfer_encoding = .{ .content_length = payload.len };
        var body_writer = try request.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(payload);
        try body_writer.end();
        try request.connection.?.flush();
        var response = try request.receiveHead(&.{});
        const status = response.head.status;
        if (status == .too_many_requests) {
            return .{
                .status = status,
                .body = "",
                .retry_after_seconds = retry_after(&response.head),
            };
        }
        if (status != .ok and status != .accepted) return .{ .status = status, .body = "" };
        if (response.head.content_encoding != .identity) return error.InvalidResponse;
        var body: std.Io.Writer = .fixed(buffer);
        var transfer_buffer: [64]u8 = undefined;
        _ = try response.reader(&transfer_buffer).streamRemaining(&body);
        return .{ .status = status, .body = body.buffered() };
    }
};

fn retry_after(head: *const std.http.Client.Response.Head) ?u32 {
    var headers = head.iterateHeaders();
    var seconds: ?u32 = null;
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "Retry-After")) continue;
        const value = std.mem.trim(u8, header.value, " \t");
        if (value.len == 0) continue;
        var parsed: u32 = 0;
        for (value) |byte| {
            if (!std.ascii.isDigit(byte)) break;
            parsed = (parsed *| 10) +| (byte - '0');
        } else {
            seconds = @max(seconds orelse 0, parsed);
        }
    }
    return seconds;
}
