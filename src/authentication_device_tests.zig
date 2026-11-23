//! Device sign-in tests through the authentication handler and Lambda Runtime API.
const std = @import("std");
const github = @import("github_identity");
const http = @import("http");
const paseto = @import("paseto");
const pending_sign_in = @import("pending_sign_in");
const authentication = @import("authentication_lambda.zig");
const testing = authentication.testing;

const Allocator = std.mem.Allocator;
const runtime_tests_enabled = @import("runtime_test_options").enabled;

test "runtime integration: GitHub device start and poll issue credentials only once" {
    if (comptime !runtime_tests_enabled) return error.SkipZigTest;
    const runtime = @import("runtime_test_support");
    var fixture: runtime.Fixture = .{};
    defer fixture.deinit();
    var services: DeviceServices = undefined;
    var store: DeviceStore = .{};
    try services.init(&store);
    defer services.deinit();

    const io = std.testing.io;
    const loopback: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var github_server = try loopback.listen(io, .{ .mode = .stream });
    defer github_server.deinit(io);
    services.device_code_url = try std.fmt.allocPrint(
        fixture.allocator(),
        "http://{f}/login/device/code",
        .{github_server.socket.address},
    );
    var github_reply = try io.concurrent(reply_with_device_grant, .{ &github_server, io });
    defer github_reply.cancel(io) catch {};

    const response = try services.run_runtime(&fixture,
        \\{"version":"2.0","routeKey":"POST /auth/github/device/start",
        \\"rawPath":"/auth/github/device/start","requestContext":{"http":{"method":"POST"}},
        \\"body":"","isBase64Encoded":false}
    );
    try std.testing.expectEqual(200, response.object.get("statusCode").?.integer);
    try github_reply.await(io);
    try std.testing.expectEqualStrings(
        "no-store",
        response.object.get("headers").?.object.get("Cache-Control").?.string,
    );
    const approval = try std.json.parseFromSliceLeaky(
        TestApproval,
        fixture.allocator(),
        response.object.get("body").?.string,
        .{},
    );
    try std.testing.expect(approval.device_code.len > 0);
    try std.testing.expect(!std.mem.eql(u8, approval.device_code, test_github_device_code));
    try std.testing.expect(!std.mem.eql(u8, approval.device_code, approval.user_code));
    try std.testing.expectEqualStrings("WDJB-MJHT", approval.user_code);
    try std.testing.expectEqualStrings(
        "https://github.com/login/device",
        approval.verification_uri,
    );
    try std.testing.expectEqual(5, approval.interval);
    try std.testing.expectEqual(900, approval.expires_in);
    try check_runtime_device_poll(&store, approval.device_code);
}

fn check_runtime_device_poll(store: *DeviceStore, code: []const u8) !void {
    const runtime = @import("runtime_test_support");
    var poll: DeviceServices = undefined;
    try poll.init(store);
    defer poll.deinit();
    poll.shared.now_seconds += 5;
    poll.device_poll_result = test_approved_device_poll;

    var fixture: runtime.Fixture = .{};
    defer fixture.deinit();
    const allocator = fixture.allocator();
    const event = try std.json.Stringify.valueAlloc(allocator, .{
        .version = "2.0",
        .routeKey = "POST /auth/github/device/poll",
        .rawPath = "/auth/github/device/poll",
        .requestContext = .{ .http = .{ .method = "POST" } },
        .headers = .{ .origin = "https://app.example.test", .@"content-type" = "application/json" },
        .body = try std.json.Stringify.valueAlloc(allocator, .{ .device_code = code }, .{}),
    }, .{});
    const response = try poll.run_runtime(&fixture, event);
    try std.testing.expectEqual(200, response.object.get("statusCode").?.integer);
    const token = try std.json.parseFromSliceLeaky(
        testing.TokenResponse,
        allocator,
        response.object.get("body").?.string,
        .{},
    );
    var claims = try paseto.verify(
        allocator,
        token.access_token,
        poll.shared.key_pair.public_key,
        poll.shared.now_seconds,
    );
    defer claims.deinit();
    try std.testing.expectEqualStrings("github:42", claims.sub);

    var replay_fixture: runtime.Fixture = .{};
    defer replay_fixture.deinit();
    const replay = try poll.run_runtime(&replay_fixture, event);
    try std.testing.expectEqual(410, replay.object.get("statusCode").?.integer);
    try std.testing.expectEqual(1, poll.device_polls);
    try std.testing.expectEqual(1, poll.shared.signing_key_reads);
}

const test_github_device_code = "private-github-device-fixture";
const test_device_grant =
    \\{"device_code":"private-github-device-fixture","user_code":"WDJB-MJHT",
    \\"verification_uri":"https://github.com/login/device","interval":5,"expires_in":900}
;
const test_device_start: http.HttpRequest = .{
    .method = .POST,
    .path = "/auth/github/device/start",
};
const TestApproval = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    interval: u32,
    expires_in: u32,
};

fn reply_with_device_grant(listener: *std.Io.net.Server, io: std.Io) !void {
    const connection = try listener.accept(io);
    defer connection.close(io);
    var input_buffer: [4096]u8 = undefined;
    var output_buffer: [1024]u8 = undefined;
    var reader = connection.reader(io, &input_buffer);
    var writer = connection.writer(io, &output_buffer);
    var server: std.http.Server = .init(&reader.interface, &writer.interface);
    var request = try server.receiveHead();
    try std.testing.expectEqual(.POST, request.head.method);
    try std.testing.expectEqualStrings("/login/device/code", request.head.target);
    try std.testing.expectEqualStrings(
        "application/x-www-form-urlencoded",
        request.head.content_type.?,
    );
    var headers = request.iterateHeaders();
    var accept: ?[]const u8 = null;
    var user_agent: ?[]const u8 = null;
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "Accept")) accept = header.value;
        if (std.ascii.eqlIgnoreCase(header.name, "User-Agent")) user_agent = header.value;
        try std.testing.expect(!std.ascii.eqlIgnoreCase(header.name, "Authorization"));
    }
    try std.testing.expectEqualStrings(
        "application/json",
        accept orelse return error.MissingAccept,
    );
    try std.testing.expectEqualStrings(
        "operations-api",
        user_agent orelse return error.MissingAgent,
    );
    const expected_body = "client_id=configured-client&scope=";
    try std.testing.expectEqual(expected_body.len, request.head.content_length.?);
    var body_buffer: [expected_body.len]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&body_buffer);
    try std.testing.expectEqualStrings(expected_body, try body_reader.take(expected_body.len));
    try request.respond(test_device_grant, .{ .status = .ok, .keep_alive = false });
}

test "GitHub device poll waits while authorization is pending" {
    var flow: DeviceTest = undefined;
    try flow.init();
    defer flow.deinit();

    flow.poll.shared.now_seconds += 4;
    try flow.expect_retry("1");
    try std.testing.expectEqual(0, flow.poll.device_polls);

    flow.poll.shared.now_seconds += 1;
    try flow.expect_result(.accepted, "{\"error\":\"authorization_pending\",\"interval\":5}");
    try std.testing.expectEqual(1, flow.poll.device_polls);
    try flow.expect_retry("5");
    try std.testing.expectEqual(1, flow.poll.device_polls);
}

test "GitHub slowdown persists the longer interval for later invocations" {
    var flow: DeviceTest = undefined;
    try flow.init();
    defer flow.deinit();

    flow.poll.shared.now_seconds += 5;
    flow.poll.device_poll_result = .{
        .status = .bad_request,
        .body = "{\"error\":\"slow_down\",\"interval\":12}",
    };
    try flow.expect_retry("12");

    flow.poll.shared.now_seconds += 11;
    try flow.expect_retry("1");
    try std.testing.expectEqual(1, flow.poll.device_polls);

    flow.poll.shared.now_seconds += 1;
    flow.poll.device_poll_result = .{
        .status = .ok,
        .body = "{\"error\":\"authorization_pending\"}",
    };
    try flow.expect_result(.accepted, "{\"error\":\"authorization_pending\",\"interval\":12}");
    try std.testing.expectEqual(2, flow.poll.device_polls);
}

test "GitHub device denial is terminal across invocations" {
    var flow: DeviceTest = undefined;
    try flow.init();
    defer flow.deinit();

    flow.poll.shared.now_seconds += 5;
    flow.poll.device_poll_result = .{ .status = .ok, .body = "{\"error\":\"access_denied\"}" };
    try flow.expect_result(.forbidden, "{\"error\":\"access_denied\"}");
    flow.poll.shared.now_seconds += 10;
    try flow.expect_result(.forbidden, "{\"error\":\"access_denied\"}");
    try std.testing.expectEqual(1, flow.poll.device_polls);
    try std.testing.expectEqual(0, flow.poll.shared.signing_key_reads);
}

test "GitHub device grant expires while the Pending Sign-in is still stored" {
    var flow: DeviceTest = undefined;
    try flow.init();
    defer flow.deinit();

    flow.poll.shared.now_seconds += 900;
    flow.poll.device_poll_result = test_approved_device_poll;
    try flow.expect_result(.gone, "{\"error\":\"expired_or_consumed\"}");
    try std.testing.expect(flow.store.grant.?.state == .pending);
    try std.testing.expectEqual(0, flow.poll.device_polls);
    try std.testing.expectEqual(0, flow.poll.shared.signing_key_reads);
}

test "GitHub-reported device expiry stays terminal on immediate replay" {
    var flow: DeviceTest = undefined;
    try flow.init();
    defer flow.deinit();

    flow.poll.shared.now_seconds += 5;
    flow.poll.device_poll_result = .{ .status = .ok, .body = "{\"error\":\"expired_token\"}" };
    try flow.expect_result(.gone, "{\"error\":\"expired_or_consumed\"}");
    try flow.expect_result(.gone, "{\"error\":\"expired_or_consumed\"}");
    try std.testing.expect(flow.store.grant.?.state == .expired);
    try std.testing.expectEqual(1, flow.poll.device_polls);
}

test "an approval received at the device expiry cannot issue a PASETO" {
    var flow: DeviceTest = undefined;
    try flow.init();
    defer flow.deinit();

    flow.poll.shared.now_seconds += 899;
    flow.poll.advance_after_poll_seconds = 1;
    flow.poll.device_poll_result = test_approved_device_poll;
    try flow.expect_result(.gone, "{\"error\":\"expired_or_consumed\"}");
    try std.testing.expectEqual(1, flow.poll.device_polls);
    try std.testing.expectEqual(0, flow.poll.shared.signing_key_reads);
}

test "only one of two approved GitHub polls consumes the grant and issues credentials" {
    const io = std.testing.io;
    var flow: DeviceTest = undefined;
    try flow.init();
    defer flow.deinit();
    const request = flow.request();
    var gate: testing.GrantFinishGate = .{};
    flow.store.finish_gate = &gate;
    defer flow.store.finish_gate = null;

    var capture: testing.Diagnostics = .{};
    capture.start();
    defer capture.stop();

    flow.poll.shared.now_seconds += 5;
    flow.poll.device_poll_result = test_approved_device_poll;
    var first = try io.concurrent(DeviceServices.invoke, .{ &flow.poll, &request });
    defer {
        var response = first.cancel(io);
        response.deinit();
    }
    try gate.first_arrived.waitTimeout(io, testing.GrantFinishGate.timeout);

    var contender: DeviceServices = undefined;
    try contender.init(&flow.store);
    defer contender.deinit();
    contender.shared.now_seconds += 10;
    contender.device_poll_result = test_approved_device_poll;
    var second = try io.concurrent(DeviceServices.invoke, .{ &contender, &request });
    defer {
        var response = second.cancel(io);
        response.deinit();
    }

    const responses = [_]http.HttpResponse{ first.await(io), second.await(io) };
    try std.testing.expectEqual(2, gate.arrivals.load(.monotonic));
    try std.testing.expectEqual(1, flow.poll.shared.github_checks);
    try std.testing.expectEqual(1, contender.shared.github_checks);
    try expect_one_device_credential(&flow, &contender, &responses, &capture);

    flow.poll.shared.now_seconds += 20;
    try flow.expect_result(.gone, "{\"error\":\"expired_or_consumed\"}");
    try std.testing.expectEqual(1, flow.poll.device_polls);
}

fn expect_one_device_credential(
    flow: *const DeviceTest,
    contender: *const DeviceServices,
    responses: *const [2]http.HttpResponse,
    capture: *const testing.Diagnostics,
) !void {
    const winner: usize = if (responses[0].status == .ok) 0 else 1;
    const loser = winner ^ 1;
    try std.testing.expectEqual(.ok, responses[winner].status);
    try std.testing.expectEqual(.gone, responses[loser].status);
    try std.testing.expectEqualStrings(
        "{\"error\":\"expired_or_consumed\"}",
        responses[loser].body,
    );
    try testing.expect_response_header(responses[winner].headers, "Cache-Control", "no-store");
    const issued = try testing.issued_token(&responses[winner]);
    defer issued.deinit();
    try std.testing.expectEqualStrings("Bearer", issued.value.token_type);
    try std.testing.expectEqual(28800, issued.value.expires_in);
    const issued_at = if (winner == 0)
        flow.poll.shared.now_seconds
    else
        contender.shared.now_seconds;
    const expires_at = issued_at + 28800;
    var claims = try paseto.verify(
        std.testing.allocator,
        issued.value.access_token,
        flow.poll.shared.key_pair.public_key,
        expires_at - 1,
    );
    defer claims.deinit();
    try std.testing.expectEqualStrings("github:42", claims.sub);
    try std.testing.expectEqual(expires_at, claims.exp);
    try std.testing.expectError(error.InvalidToken, paseto.verify(
        std.testing.allocator,
        issued.value.access_token,
        flow.poll.shared.key_pair.public_key,
        expires_at,
    ));
    try capture.expect_no_credentials(&.{
        flow.approval.value.device_code,
        test_github_device_code,
        testing.provider_token,
        testing.client_secret,
        issued.value.access_token,
    });
}

test "GitHub and caller credentials stay out of device failure diagnostics" {
    var flow: DeviceTest = undefined;
    try flow.init();
    defer flow.deinit();
    var capture: testing.Diagnostics = .{};
    capture.start();
    defer capture.stop();

    flow.poll.shared.now_seconds += 5;
    flow.poll.device_poll_result = test_approved_device_poll;
    flow.poll.shared.github_result = .{
        .status = .ok,
        .body = "{\"app\":{\"client_id\":\"other-client\"},\"user\":{\"id\":42}," ++
            "\"message\":\"" ++ testing.provider_token ++ " " ++ test_github_device_code ++ "\"}",
    };
    try flow.expect_result(.service_unavailable, "{\"error\":\"service_unavailable\"}");
    try std.testing.expectEqual(1, flow.poll.shared.github_checks);
    try std.testing.expectEqual(0, flow.poll.shared.signing_key_reads);
    try capture.expect_no_credentials(&.{
        flow.approval.value.device_code,
        test_github_device_code,
        testing.provider_token,
        testing.client_secret,
    });
}

test "GitHub device routes reject extra inputs before contacting GitHub" {
    var flow: DeviceTest = undefined;
    try flow.init();
    defer flow.deinit();

    var invalid_start = test_device_start;
    invalid_start.body = .{ .bytes = "{}" };
    var start_response = flow.poll.invoke(&invalid_start);
    defer start_response.deinit();
    try std.testing.expectEqual(.bad_request, start_response.status);

    for ([_][]const u8{
        "",
        "{}",
        "{\"device_code\":\"invalid\"}",
        "{\"device_code\":\"invalid\",\"device_code\":\"duplicate\"}",
        "{\"device_code\":\"invalid\",\"tenant\":\"github:19\"}",
    }) |body| {
        var response = flow.poll.invoke(&test_device_poll(body));
        defer response.deinit();
        try std.testing.expectEqual(.bad_request, response.status);
        try std.testing.expectEqualStrings("{\"error\":\"bad_request\"}", response.body);
    }
    try std.testing.expectEqual(0, flow.poll.device_starts);
    try std.testing.expectEqual(0, flow.poll.device_polls);
}

const test_approved_device_poll: github.Response = .{
    .status = .ok,
    .body = "{\"access_token\":\"" ++ testing.provider_token ++ "\",\"token_type\":\"bearer\"}",
};

const DeviceTest = struct {
    store: DeviceStore,
    approval: std.json.Parsed(TestApproval),
    poll: DeviceServices,
    body: []const u8,

    fn init(flow: *DeviceTest) !void {
        flow.store = .{};
        var start: DeviceServices = undefined;
        try start.init(&flow.store);
        defer start.deinit();
        flow.approval = try begin_test_sign_in(&start);
        errdefer flow.approval.deinit();

        try flow.poll.init(&flow.store);
        errdefer flow.poll.deinit();
        flow.body = try std.json.Stringify.valueAlloc(std.testing.allocator, .{
            .device_code = flow.approval.value.device_code,
        }, .{});
    }

    fn deinit(flow: *DeviceTest) void {
        std.testing.allocator.free(flow.body);
        flow.poll.deinit();
        flow.approval.deinit();
    }

    fn request(flow: *const DeviceTest) http.HttpRequest {
        return test_device_poll(flow.body);
    }

    fn expect_retry(flow: *DeviceTest, seconds: []const u8) !void {
        var response = flow.poll.invoke(&flow.request());
        defer response.deinit();
        try std.testing.expectEqual(.too_many_requests, response.status);
        try testing.expect_response_header(response.headers, "Cache-Control", "no-store");
        try testing.expect_response_header(response.headers, "Retry-After", seconds);
        try std.testing.expectEqualStrings("{\"error\":\"slow_down\"}", response.body);
    }

    fn expect_result(flow: *DeviceTest, status: std.http.Status, body: []const u8) !void {
        var response = flow.poll.invoke(&flow.request());
        defer response.deinit();
        try std.testing.expectEqual(status, response.status);
        try testing.expect_response_header(response.headers, "Cache-Control", "no-store");
        try std.testing.expectEqualStrings(body, response.body);
    }
};

fn begin_test_sign_in(services: *DeviceServices) !std.json.Parsed(TestApproval) {
    var response = services.invoke(&test_device_start);
    defer response.deinit();
    try std.testing.expectEqual(.ok, response.status);
    return std.json.parseFromSlice(TestApproval, std.testing.allocator, response.body, .{
        .allocate = .alloc_always,
    });
}

fn test_device_poll(body: []const u8) http.HttpRequest {
    return .{ .method = .POST, .path = "/auth/github/device/poll", .body = .{ .bytes = body } };
}

const DeviceServices = struct {
    shared: testing.Services,
    store: pending_sign_in.Store,
    device_code_url: ?[]const u8 = null,
    device_poll_result: github.TransportError!github.Response = .{
        .status = .ok,
        .body = "{\"error\":\"authorization_pending\"}",
    },
    device_starts: u8 = 0,
    device_polls: u8 = 0,
    advance_after_poll_seconds: i64 = 0,

    fn init(fixture: *DeviceServices, store: *DeviceStore) !void {
        fixture.* = .{ .shared = undefined, .store = store.interface() };
        try fixture.shared.init();
    }

    fn deinit(fixture: *DeviceServices) void {
        fixture.shared.deinit();
    }

    fn invoke(fixture: *DeviceServices, request: *const http.HttpRequest) http.HttpResponse {
        return authentication.handle_http(
            std.testing.allocator,
            request,
            &fixture.shared.config(),
            &fixture.dependencies(),
        );
    }

    fn run_runtime(
        fixture: *DeviceServices,
        runtime: *@import("runtime_test_support").Fixture,
        event: []const u8,
    ) !std.json.Value {
        return testing.run_runtime(runtime, &fixture.dependencies(), .{
            .event = event,
            .public_key = &fixture.shared.public_key,
        });
    }

    fn dependencies(fixture: *DeviceServices) authentication.Dependencies {
        // Keep the shared fixture as the context for its clock, entropy, and secrets.
        var result = fixture.shared.dependencies();
        result.store = fixture.store;
        result.send_github_fn = send_github;
        return result;
    }

    fn send_github(
        context: *anyopaque,
        allocator: Allocator,
        request: *const github.Request,
    ) github.TransportError!github.Response {
        const shared: *testing.Services = @ptrCast(@alignCast(context));
        const fixture: *DeviceServices = @fieldParentPtr("shared", shared);
        if (std.mem.eql(u8, request.url, github.device_start_url)) {
            fixture.device_starts += 1;
            if (fixture.device_code_url) |url| {
                var local_request = request.*;
                local_request.url = url;
                return testing.fetch_github_http(std.testing.io, allocator, &local_request);
            }
            return .{ .status = .ok, .body = test_device_grant };
        }
        if (std.mem.eql(u8, request.url, github.oauth_token_url)) {
            expect_device_poll_request(request) catch unreachable;
            fixture.device_polls += 1;
            fixture.shared.now_seconds += fixture.advance_after_poll_seconds;
            return fixture.device_poll_result;
        }
        return testing.Services.send_github(context, allocator, request);
    }
};

const DeviceStore = struct {
    mutex: std.Io.Mutex = .init,
    key: pending_sign_in.Key = undefined,
    github_code: [github.device_code_size_max]u8 = undefined,
    grant: ?pending_sign_in.Grant = null,
    finish_gate: ?*testing.GrantFinishGate = null,

    fn interface(store: *DeviceStore) pending_sign_in.Store {
        return .{
            .context = store,
            .create = create_grant,
            .read = read_grant,
            .change = change_grant,
        };
    }

    fn create_grant(
        context: *anyopaque,
        _: Allocator,
        key: *const pending_sign_in.Key,
        grant: *const pending_sign_in.Grant,
    ) pending_sign_in.Error!void {
        const store: *DeviceStore = @ptrCast(@alignCast(context));
        store.mutex.lockUncancelable(std.testing.io);
        defer store.mutex.unlock(std.testing.io);
        if (store.grant != null) return error.Unavailable;
        store.key = key.*;
        const upstream_code = grant.state.pending.github_device_code;
        @memcpy(store.github_code[0..upstream_code.len], upstream_code);
        store.grant = grant.*;
        store.grant.?.state.pending.github_device_code = store.github_code[0..upstream_code.len];
    }

    fn read_grant(
        context: *anyopaque,
        arena: Allocator,
        key: *const pending_sign_in.Key,
    ) pending_sign_in.Error!?pending_sign_in.Grant {
        const store: *DeviceStore = @ptrCast(@alignCast(context));
        store.mutex.lockUncancelable(std.testing.io);
        defer store.mutex.unlock(std.testing.io);
        var grant = store.lookup(key) orelse return null;
        if (grant.state == .pending) {
            const pending = &grant.state.pending;
            pending.github_device_code = arena.dupe(u8, pending.github_device_code) catch
                return error.InternalFailure;
        }
        return grant;
    }

    fn change_grant(
        context: *anyopaque,
        _: Allocator,
        key: *const pending_sign_in.Key,
        change: *const pending_sign_in.Change,
    ) pending_sign_in.Error!bool {
        const store: *DeviceStore = @ptrCast(@alignCast(context));
        if (change.transition == .finish and change.transition.finish == .consumed) {
            if (store.finish_gate) |gate| try gate.arrive(std.testing.io);
        }
        store.mutex.lockUncancelable(std.testing.io);
        defer store.mutex.unlock(std.testing.io);
        const grant = store.lookup(key) orelse return false;
        if (grant.state != .pending or grant.expires_at_ms <= change.now_ms) return false;
        switch (change.transition) {
            .schedule => |schedule| {
                if (grant.state.pending.next_poll_at_ms != schedule.expected_at_ms) return false;
                store.grant.?.state.pending.next_poll_at_ms = schedule.next_at_ms;
                store.grant.?.state.pending.interval_seconds = schedule.interval_seconds;
            },
            .finish => |state| {
                store.grant.?.state = switch (state) {
                    .denied => .denied,
                    .expired => .expired,
                    .consumed => .consumed,
                };
            },
            .browser_finish => return false,
        }
        return true;
    }

    fn lookup(
        store: *const DeviceStore,
        key: *const pending_sign_in.Key,
    ) ?pending_sign_in.Grant {
        const grant = store.grant orelse return null;
        if (!std.mem.eql(u8, &store.key.digest, &key.digest)) return null;
        return grant;
    }
};

fn expect_device_poll_request(request: *const github.Request) !void {
    try std.testing.expectEqual(.POST, request.method);
    try testing.expect_response_header(request.headers, "Accept", "application/json");
    try testing.expect_response_header(
        request.headers,
        "Content-Type",
        "application/x-www-form-urlencoded",
    );
    try testing.expect_response_header(request.headers, "User-Agent", "operations-api");
    try std.testing.expectEqual(3, request.headers.len);
    try std.testing.expectEqualStrings(
        "client_id=configured-client&device_code=" ++ test_github_device_code ++
            "&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code",
        request.body,
    );
}
