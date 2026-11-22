//! Browser sign-in tests through the authentication handler and Lambda Runtime API.
const std = @import("std");
const github = @import("github_identity");
const http = @import("http");
const paseto = @import("paseto");
const pending_sign_in = @import("pending_sign_in");
const authentication = @import("authentication_lambda.zig");
const testing = authentication.testing;

const Allocator = std.mem.Allocator;
const runtime_tests_enabled = @import("runtime_test_options").enabled;

const test_browser_callback = "https://app.example.test/callback";
const test_other_callback = "https://app.example.test/callback?from=other";
const test_browser_registrations =
    "[\"" ++ test_browser_callback ++ "\",\"" ++ test_other_callback ++ "\"]";
const test_oauth_callback = "https://operations.example.test/auth/github/callback";
const test_browser_token = "{\"access_token\":\"" ++ testing.provider_token ++
    "\",\"token_type\":\"bearer\",\"scope\":\"\"}";
const test_redeem_path = "/auth/github/redeem";
const test_app_verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
const test_app_challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
const test_authorize_fields = "&state=app-state&code_challenge=" ++ test_app_challenge ++
    "&code_challenge_method=S256";

test "GitHub browser authorize requires exact registration and sends separate S256 and state" {
    var store: BrowserTestStore = .init;
    defer store.arena.deinit();
    var services: BrowserServices = undefined;
    try services.init(&store);
    defer services.deinit();
    const allocator = std.testing.allocator;
    for ([_][]const u8{
        "https://app.example.test/callback/",          "https://app.example.test/other",
        "https://app.example.test.evil.test/callback", "http://app.example.test/callback",
    }) |redirect| {
        const query = try std.fmt.allocPrint(allocator, "redirect_uri={s}" ++
            test_authorize_fields, .{redirect});
        defer allocator.free(query);
        var response = services.invoke(&.{
            .method = .GET,
            .path = "/auth/github/authorize",
            .raw_query = query,
        });
        defer response.deinit();
        try std.testing.expectEqual(.bad_request, response.status);
        try std.testing.expectEqual(@as(usize, 0), response.cookies.len);
        try std.testing.expect(store.entries[0] == null);
    }
    var response = services.invoke(&test_browser_authorize);
    defer response.deinit();
    try std.testing.expectEqual(.found, response.status);
    const location = try testing.header(response.headers, "Location");
    const github_authorize = "https://github.com/login/oauth/authorize?";
    try std.testing.expect(std.mem.startsWith(u8, location, github_authorize));
    try std.testing.expectEqualStrings("", try test_url_field(location, "scope"));
    const challenge_method = try test_url_field(location, "code_challenge_method");
    try std.testing.expectEqualStrings("S256", challenge_method);
    const state = try test_url_field(location, "state");
    const challenge = try test_url_field(location, "code_challenge");
    try std.testing.expect(!std.mem.eql(u8, state, "app-state"));
    try std.testing.expect(!std.mem.eql(u8, challenge, test_app_challenge));
    try testing.expect_response_header(response.headers, "Cache-Control", "no-store");
    try std.testing.expectEqual(@as(usize, 1), response.cookies.len);
    const cookie = response.cookies[0];
    try std.testing.expect(std.mem.startsWith(u8, cookie, "__Host-operations-github-"));
    try std.testing.expect(std.mem.indexOf(u8, cookie, "Secure; HttpOnly; SameSite=Lax") != null);
    try std.testing.expect(store.entries[0] != null);
    try std.testing.expect(store.entries[1] == null);
    try std.testing.expectEqual(0, services.shared.github_checks);
    try std.testing.expectEqual(0, services.browser_exchanges);
    try std.testing.expectEqual(0, services.shared.device_starts);
    try std.testing.expectEqual(0, services.shared.device_polls);
}

const BrowserTestStore = struct {
    const Entry = struct { key: pending_sign_in.Key, grant: pending_sign_in.Grant };

    const init: BrowserTestStore = .{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
    };

    arena: std.heap.ArenaAllocator,
    mutex: std.Io.Mutex = .init,
    entries: [2]?Entry = @splat(null),
    redeem_gate: ?*testing.GrantFinishGate = null,

    fn interface(store: *BrowserTestStore) pending_sign_in.Store {
        return .{ .context = store, .create = create, .read = read, .change = change };
    }

    fn create(
        context: *anyopaque,
        _: Allocator,
        key: *const pending_sign_in.Key,
        grant: *const pending_sign_in.Grant,
    ) pending_sign_in.Error!void {
        const store: *BrowserTestStore = @ptrCast(@alignCast(context));
        store.mutex.lockUncancelable(std.testing.io);
        defer store.mutex.unlock(std.testing.io);
        if (store.lookup(key) != null) return error.Unavailable;
        const arena = store.arena.allocator();
        for (&store.entries) |*entry| {
            if (entry.* != null) continue;
            entry.* = .{ .key = key.*, .grant = .{
                .expires_at_ms = grant.expires_at_ms,
                .state = switch (grant.state) {
                    .browser_pending => |data| .{
                        .browser_pending = try copy_browser(arena, data),
                    },
                    .browser_approved => |data| .{
                        .browser_approved = try copy_browser(arena, data),
                    },
                    else => unreachable,
                },
            } };
            return;
        }
        return error.Unavailable;
    }

    fn copy_browser(arena: Allocator, data: anytype) pending_sign_in.Error!@TypeOf(data) {
        var copy = data;
        inline for (comptime std.meta.fieldNames(@TypeOf(data))) |field| {
            @field(copy, field) = arena.dupe(u8, @field(data, field)) catch
                return error.InternalFailure;
        }
        return copy;
    }

    fn read(
        context: *anyopaque,
        _: Allocator,
        key: *const pending_sign_in.Key,
    ) pending_sign_in.Error!?pending_sign_in.Grant {
        const store: *BrowserTestStore = @ptrCast(@alignCast(context));
        store.mutex.lockUncancelable(std.testing.io);
        defer store.mutex.unlock(std.testing.io);
        const entry = store.lookup(key) orelse return null;
        return entry.grant;
    }

    fn change(
        context: *anyopaque,
        _: Allocator,
        key: *const pending_sign_in.Key,
        update: *const pending_sign_in.Change,
    ) pending_sign_in.Error!bool {
        const store: *BrowserTestStore = @ptrCast(@alignCast(context));
        if (update.transition != .browser_finish) return false;
        const action = update.transition.browser_finish;
        if (action == .redeem) {
            if (store.redeem_gate) |gate| try gate.arrive(std.testing.io);
        }
        store.mutex.lockUncancelable(std.testing.io);
        defer store.mutex.unlock(std.testing.io);
        const entry = store.lookup(key) orelse return false;
        if (update.now_ms >= entry.grant.expires_at_ms) return false;
        const expected: std.meta.Tag(@FieldType(pending_sign_in.Grant, "state")) =
            if (action == .redeem) .browser_approved else .browser_pending;
        if (entry.grant.state != expected) return false;
        entry.grant.state = if (action == .deny) .denied else .consumed;
        return true;
    }

    fn lookup(store: *BrowserTestStore, key: *const pending_sign_in.Key) ?*Entry {
        for (&store.entries) |*slot| {
            if (slot.*) |*entry| {
                if (std.mem.eql(u8, &entry.key.digest, &key.digest)) return entry;
            }
        }
        return null;
    }
};

test "runtime integration: browser callback rejects conflicting payload and header cookies" {
    if (comptime !runtime_tests_enabled) return error.SkipZigTest;
    const runtime = @import("runtime_test_support");
    var fixture: runtime.Fixture = .{};
    defer fixture.deinit();
    var flow: BrowserTest = undefined;
    try flow.init();
    defer flow.deinit();
    var upstream = try BrowserRedirect.begin(&flow, &test_browser_authorize);
    defer upstream.response.deinit();

    const arena = fixture.allocator();
    const event = try std.json.Stringify.valueAlloc(arena, .{
        .version = "2.0",
        .routeKey = "GET /auth/github/callback",
        .rawPath = "/auth/github/callback",
        .requestContext = .{ .http = .{ .method = "GET" } },
        .rawQueryString = try upstream.callback_query(arena, "code=github-code"),
        .cookies = &.{upstream.cookie},
        .headers = .{ .Cookie = try upstream.conflicting_cookie(arena) },
    }, .{});
    const response = try flow.callback.run_runtime(&fixture, event);
    try std.testing.expectEqual(400, response.object.get("statusCode").?.integer);
    try std.testing.expectEqual(0, flow.callback.browser_exchanges);
    try std.testing.expectEqual(0, flow.callback.shared.github_checks);
    try std.testing.expect(flow.store.entries[0].?.grant.state == .browser_pending);
}

test "runtime integration: browser callback exchanges its independent PKCE through GitHub HTTP" {
    if (comptime !runtime_tests_enabled) return error.SkipZigTest;
    const runtime = @import("runtime_test_support");
    var start_fixture: runtime.Fixture = .{};
    defer start_fixture.deinit();
    var callback_fixture: runtime.Fixture = .{};
    defer callback_fixture.deinit();
    var redeem_fixture: runtime.Fixture = .{};
    defer redeem_fixture.deinit();
    var flow: BrowserTest = undefined;
    try flow.init();
    defer flow.deinit();

    var capture: testing.Diagnostics = .{};
    capture.start();
    defer capture.stop();

    const start = try std.json.Stringify.valueAlloc(start_fixture.allocator(), .{
        .version = "2.0",
        .rawPath = test_browser_authorize.path,
        .requestContext = .{ .http = .{ .method = "GET" } },
        .rawQueryString = test_browser_authorize.raw_query,
    }, .{});
    const authorization = try flow.start.run_runtime(&start_fixture, start);
    try std.testing.expectEqual(302, authorization.object.get("statusCode").?.integer);
    const upstream = flow.store.entries[0].?.grant.state.browser_pending.upstream_verifier;
    const code = try runtime_browser_callback(&callback_fixture, &flow.callback, &authorization);
    try runtime_browser_redemption(&redeem_fixture, &flow.redeem, code);
    try std.testing.expect(flow.store.entries[1].?.grant.state == .consumed);
    const location = authorization.object.get("headers").?.object.get("Location").?.string;
    try capture.expect_no_credentials(&.{
        testing.provider_token,
        testing.client_secret,
        "github+code&fixture",
        "github%2Bcode%26fixture",
        try test_url_field(location, "state"),
        upstream,
        code,
        test_app_verifier,
        "v4.public.",
    });
}

fn runtime_browser_callback(
    fixture: *@import("runtime_test_support").Fixture,
    services: *BrowserServices,
    authorization: *const std.json.Value,
) ![]const u8 {
    const location = authorization.object.get("headers").?.object.get("Location").?.string;
    const upstream_state = try test_url_field(location, "state");
    const upstream_challenge = try test_url_field(location, "code_challenge");
    const set_cookie = authorization.object.get("cookies").?.array.items[0].string;
    const cookie = set_cookie[0..std.mem.indexOfScalar(u8, set_cookie, ';').?];

    const io = std.testing.io;
    const loopback: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var github_server = try loopback.listen(io, .{ .mode = .stream });
    defer github_server.deinit(io);
    const arena = fixture.allocator();
    services.browser_token_url = try std.fmt.allocPrint(
        arena,
        "http://{f}/login/oauth/access_token",
        .{github_server.socket.address},
    );
    services.shared.token_check_url = try std.fmt.allocPrint(
        arena,
        "http://{f}/applications/configured-client/token",
        .{github_server.socket.address},
    );
    var github_reply = try io.concurrent(reply_to_browser_callback, .{
        &github_server, io, upstream_challenge,
    });
    defer github_reply.cancel(io) catch {};
    const event = try std.json.Stringify.valueAlloc(arena, .{
        .version = "2.0",
        .rawPath = "/auth/github/callback",
        .requestContext = .{ .http = .{ .method = "GET" } },
        .rawQueryString = try std.fmt.allocPrint(
            arena,
            "code=github%2Bcode%26fixture&state={s}&provider_extension=ignored",
            .{upstream_state},
        ),
        .cookies = &.{cookie},
    }, .{});
    const response = try services.run_runtime(fixture, event);
    try std.testing.expectEqual(302, response.object.get("statusCode").?.integer);
    const headers = response.object.get("headers").?.object;
    try std.testing.expectEqualStrings("no-referrer", headers.get("Referrer-Policy").?.string);
    const app_location = headers.get("Location").?.string;
    try std.testing.expect(std.mem.startsWith(
        u8,
        app_location,
        test_browser_callback ++ "?code=",
    ));
    try std.testing.expectEqualStrings("app-state", try test_url_field(app_location, "state"));
    try std.testing.expect(std.mem.indexOf(u8, app_location, testing.provider_token) == null);
    try std.testing.expect(std.mem.indexOf(u8, app_location, upstream_state) == null);
    const cleared = response.object.get("cookies").?.array.items[0].string;
    try std.testing.expect(std.mem.indexOf(u8, cleared, "; Max-Age=0;") != null);
    try github_reply.await(io);
    return test_url_field(app_location, "code");
}

fn runtime_browser_redemption(
    fixture: *@import("runtime_test_support").Fixture,
    services: *BrowserServices,
    code: []const u8,
) !void {
    const redemption = try test_redeem(.{ .code = code });
    defer std.testing.allocator.free(redemption.body.bytes);
    const redeem_event = try std.json.Stringify.valueAlloc(fixture.allocator(), .{
        .version = "2.0",
        .rawPath = test_redeem_path,
        .requestContext = .{ .http = .{ .method = "POST" } },
        .body = redemption.body.bytes,
    }, .{});
    const result = try services.run_runtime(fixture, redeem_event);
    try std.testing.expectEqual(200, result.object.get("statusCode").?.integer);
    const result_headers = result.object.get("headers").?.object;
    try std.testing.expectEqualStrings("no-store", result_headers.get("Cache-Control").?.string);
    const fields = try std.json.parseFromSliceLeaky(
        testing.TokenResponse,
        fixture.allocator(),
        result.object.get("body").?.string,
        .{},
    );
    var claims = try paseto.verify(
        std.testing.allocator,
        fields.access_token,
        services.shared.key_pair.public_key,
        testing.now_seconds,
    );
    defer claims.deinit();
    try std.testing.expectEqualStrings("github:42", claims.sub);
}

fn reply_to_browser_callback(
    listener: *std.Io.net.Server,
    io: std.Io,
    challenge: []const u8,
) !void {
    for (0..2) |step| {
        const connection = try listener.accept(io);
        defer connection.close(io);
        var input: [4096]u8 = undefined;
        var output: [1024]u8 = undefined;
        var reader = connection.reader(io, &input);
        var writer = connection.writer(io, &output);
        var server: std.http.Server = .init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();
        try std.testing.expectEqual(.POST, request.head.method);
        try std.testing.expectEqualStrings(
            if (step == 0) "/login/oauth/access_token" else "/applications/configured-client/token",
            request.head.target,
        );
        try std.testing.expectEqualStrings(
            if (step == 0) "application/x-www-form-urlencoded" else "application/json",
            request.head.content_type.?,
        );
        try expect_browser_peer_headers(&request, step == 0);
        var buffer: [4096]u8 = undefined;
        const length = request.head.content_length orelse return error.MissingBody;
        if (length > buffer.len) return error.OversizedBody;
        const body_reader = try request.readerExpectContinue(&buffer);
        const body = try body_reader.take(@intCast(length));
        if (step == 0) {
            const prefix = "client_id=configured-client&client_secret=fixture-app-secret" ++
                "&code=github%2Bcode%26fixture" ++
                "&redirect_uri=https%3A%2F%2Foperations.example.test%2Fauth%2Fgithub%2Fcallback" ++
                "&code_verifier=";
            try std.testing.expect(std.mem.startsWith(u8, body, prefix));
            const verifier = body[prefix.len..];
            try std.testing.expect(!std.mem.eql(u8, test_app_verifier, verifier));
            var digest: [32]u8 = undefined;
            var encoded: [43]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
            try std.testing.expectEqualStrings(
                challenge,
                std.base64.url_safe_no_pad.Encoder.encode(&encoded, &digest),
            );
        } else {
            const expected = "{\"access_token\":\"" ++ testing.provider_token ++ "\"}";
            try std.testing.expectEqualStrings(expected, body);
        }
        try request.respond(if (step == 0) test_browser_token else testing.github_identity, .{
            .status = .ok,
            .keep_alive = false,
        });
    }
}

fn expect_browser_peer_headers(request: *std.http.Server.Request, exchange: bool) !void {
    var headers = request.iterateHeaders();
    var accepts: u8 = 0;
    var agents: u8 = 0;
    var authorization: ?[]const u8 = null;
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "Accept")) {
            try std.testing.expectEqualStrings(
                if (exchange) "application/json" else "application/vnd.github+json",
                header.value,
            );
            accepts += 1;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "User-Agent")) {
            try std.testing.expectEqualStrings("operations-api", header.value);
            agents += 1;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "Authorization")) {
            try std.testing.expect(authorization == null);
            authorization = header.value;
        }
    }
    try std.testing.expectEqual(1, accepts);
    try std.testing.expectEqual(1, agents);
    if (exchange) {
        try std.testing.expect(authorization == null);
        return;
    }
    const credentials = testing.client_id ++ ":" ++ testing.client_secret;
    const encoder = std.base64.standard.Encoder;
    var encoded: [encoder.calcSize(credentials.len)]u8 = undefined;
    var expected: ["Basic ".len + encoded.len]u8 = undefined;
    const basic = try std.fmt.bufPrint(&expected, "Basic {s}", .{
        encoder.encode(&encoded, credentials),
    });
    try std.testing.expectEqualStrings(basic, authorization orelse return error.MissingHeader);
}

fn test_url_field(url: []const u8, name: []const u8) ![]const u8 {
    const start = std.mem.indexOfScalar(u8, url, '?') orelse return error.MissingQuery;
    var pairs = std.mem.splitScalar(u8, url[start + 1 ..], '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..equals], name)) return pair[equals + 1 ..];
    }
    return error.MissingQueryField;
}

const BrowserServices = struct {
    shared: testing.Services,
    store: pending_sign_in.Store,
    now_offset_ms: i64 = 0,
    browser_exchanges: u8 = 0,
    browser_token_url: ?[]const u8 = null,
    browser_token_result: github.TransportError!github.Response = .{
        .status = .ok,
        .body = test_browser_token,
    },
    advance_after_browser_exchange_ms: i64 = 0,

    fn init(fixture: *BrowserServices, store: *BrowserTestStore) !void {
        fixture.* = .{ .shared = undefined, .store = store.interface() };
        try fixture.shared.init();
    }

    fn deinit(fixture: *BrowserServices) void {
        fixture.shared.deinit();
    }

    fn invoke(fixture: *BrowserServices, request: *const http.HttpRequest) http.HttpResponse {
        var config = fixture.shared.config();
        config.github_oauth_callback_url = test_oauth_callback;
        config.browser_redirect_uris = test_browser_registrations;
        return authentication.handle_http(
            std.testing.allocator,
            request,
            &config,
            &fixture.dependencies(),
        );
    }

    fn run_runtime(
        fixture: *BrowserServices,
        runtime: *@import("runtime_test_support").Fixture,
        event: []const u8,
    ) !std.json.Value {
        return testing.run_runtime(runtime, &fixture.dependencies(), .{
            .event = event,
            .public_key = &fixture.shared.public_key,
            .environment = &.{
                .{ .name = "GITHUB_OAUTH_CALLBACK_URL", .value = test_oauth_callback },
                .{ .name = "GITHUB_BROWSER_REDIRECT_URIS", .value = test_browser_registrations },
            },
        });
    }

    fn dependencies(fixture: *BrowserServices) authentication.Dependencies {
        // The shared callbacks keep the embedded fixture as their context.
        var result = fixture.shared.dependencies();
        result.store = fixture.store;
        result.now_ms = now;
        result.send_github_fn = send_github;
        return result;
    }

    fn now(context: *anyopaque) i64 {
        const shared: *testing.Services = @ptrCast(@alignCast(context));
        const fixture: *BrowserServices = @fieldParentPtr("shared", shared);
        return shared.now_seconds * 1000 + fixture.now_offset_ms;
    }

    fn send_github(
        context: *anyopaque,
        allocator: Allocator,
        request: *const github.Request,
    ) github.TransportError!github.Response {
        if (!std.mem.eql(u8, request.url, github.oauth_token_url)) {
            return testing.Services.send_github(context, allocator, request);
        }
        const shared: *testing.Services = @ptrCast(@alignCast(context));
        const fixture: *BrowserServices = @fieldParentPtr("shared", shared);
        fixture.browser_exchanges += 1;
        fixture.now_offset_ms += fixture.advance_after_browser_exchange_ms;
        if (fixture.browser_token_url) |url| {
            var local = request.*;
            local.url = url;
            return testing.fetch_github_http(std.testing.io, allocator, &local);
        }
        return fixture.browser_token_result;
    }
};

const BrowserTest = struct {
    store: BrowserTestStore,
    start: BrowserServices,
    callback: BrowserServices,
    redeem: BrowserServices,

    fn init(flow: *BrowserTest) !void {
        flow.store = .init;
        try flow.start.init(&flow.store);
        errdefer flow.start.deinit();
        try flow.callback.init(&flow.store);
        errdefer flow.callback.deinit();
        try flow.redeem.init(&flow.store);
        flow.callback.shared.random = .init(43);
        flow.redeem.shared.random = .init(44);
    }

    fn deinit(flow: *BrowserTest) void {
        flow.redeem.deinit();
        flow.callback.deinit();
        flow.start.deinit();
        flow.store.arena.deinit();
    }
};

const test_browser_authorize: http.HttpRequest = .{
    .method = .GET,
    .path = "/auth/github/authorize",
    .raw_query = "redirect_uri=https%3A%2F%2Fapp.example.test%2Fcallback" ++ test_authorize_fields,
};

const BrowserRedirect = struct {
    response: http.HttpResponse,
    state: []const u8,
    cookie: []const u8,

    fn begin(flow: *BrowserTest, request: *const http.HttpRequest) !BrowserRedirect {
        var response = flow.start.invoke(request);
        errdefer response.deinit();
        try std.testing.expectEqual(.found, response.status);
        const location = try testing.header(response.headers, "Location");
        const state = try test_url_field(location, "state");
        try std.testing.expectEqual(@as(usize, 1), response.cookies.len);
        const set_cookie = response.cookies[0];
        const end = std.mem.indexOfScalar(u8, set_cookie, ';') orelse return error.BadCookie;
        try std.testing.expect(end > 0);
        return .{ .response = response, .state = state, .cookie = set_cookie[0..end] };
    }

    fn callback(
        redirect: *const BrowserRedirect,
        flow: *BrowserTest,
        outcome: []const u8,
    ) !http.HttpResponse {
        const allocator = std.testing.allocator;
        const query = try redirect.callback_query(allocator, outcome);
        defer allocator.free(query);
        return flow.callback.invoke(&.{
            .method = .GET,
            .path = "/auth/github/callback",
            .raw_query = query,
            .cookies = &.{redirect.cookie},
        });
    }

    fn callback_query(
        redirect: *const BrowserRedirect,
        allocator: Allocator,
        outcome: []const u8,
    ) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}&state={s}", .{ outcome, redirect.state });
    }

    fn conflicting_cookie(redirect: *const BrowserRedirect, allocator: Allocator) ![]u8 {
        const conflict = try allocator.dupe(u8, redirect.cookie);
        conflict[conflict.len - 1] = if (conflict[conflict.len - 1] == '0') '1' else '0';
        return conflict;
    }
};

fn test_redeem(fields: struct {
    code: []const u8,
    redirect_uri: []const u8 = test_browser_callback,
    code_verifier: []const u8 = test_app_verifier,
}) !http.HttpRequest {
    return .{
        .method = .POST,
        .path = test_redeem_path,
        .body = .{ .bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, fields, .{}) },
    };
}

fn expect_browser_failure(response: *const http.HttpResponse, status: std.http.Status) !void {
    try std.testing.expectEqual(status, response.status);
    try testing.expect_response_header(response.headers, "Cache-Control", "no-store");
    try std.testing.expectError(error.MissingHeader, testing.header(response.headers, "Location"));
    const body = switch (status) {
        .bad_request => "{\"error\":\"bad_request\"}",
        .gone => "{\"error\":\"expired_or_consumed\"}",
        .internal_server_error => "{\"error\":\"internal_error\"}",
        .service_unavailable => "{\"error\":\"service_unavailable\"}",
        else => unreachable,
    };
    try std.testing.expectEqualStrings(body, response.body);
}

test "browser redemption checks the verifier and registered URI and issues one PASETO" {
    var flow: BrowserTest = undefined;
    try flow.init();
    defer flow.deinit();
    var upstream = try BrowserRedirect.begin(&flow, &test_browser_authorize);
    defer upstream.response.deinit();
    var approved = try upstream.callback(&flow, "code=github-code");
    defer approved.deinit();
    try std.testing.expectEqual(.found, approved.status);
    const location = try testing.header(approved.headers, "Location");
    const code = try test_url_field(location, "code");
    try std.testing.expect(!std.mem.eql(u8, upstream.state, code));
    try std.testing.expectEqualStrings("app-state", try test_url_field(location, "state"));
    try std.testing.expect(flow.store.entries[0].?.grant.state == .consumed);
    try std.testing.expect(flow.store.entries[1].?.grant.state == .browser_approved);
    try std.testing.expectEqual(1, flow.callback.shared.github_checks);
    try std.testing.expectEqual(0, flow.callback.shared.signing_key_reads);
    var callback_replay = try upstream.callback(&flow, "code=github-code");
    defer callback_replay.deinit();
    try expect_browser_failure(&callback_replay, .gone);
    try std.testing.expectEqual(1, flow.callback.browser_exchanges);
    try std.testing.expectEqual(1, flow.callback.shared.github_checks);

    const wrong_verifier: [43]u8 = @splat('a');
    for ([_]struct { redirect: []const u8, verifier: []const u8 }{
        .{ .redirect = test_other_callback, .verifier = test_app_verifier },
        .{ .redirect = test_browser_callback, .verifier = &wrong_verifier },
    }) |mismatch| {
        const request = try test_redeem(.{
            .code = code,
            .redirect_uri = mismatch.redirect,
            .code_verifier = mismatch.verifier,
        });
        defer std.testing.allocator.free(request.body.bytes);
        var failed = flow.redeem.invoke(&request);
        defer failed.deinit();
        try expect_browser_failure(&failed, .bad_request);
        try std.testing.expect(flow.store.entries[1].?.grant.state == .browser_approved);
        try std.testing.expectEqual(0, flow.redeem.shared.signing_key_reads);
    }

    const request = try test_redeem(.{ .code = code });
    defer std.testing.allocator.free(request.body.bytes);
    flow.redeem.now_offset_ms = 17_004;
    var response = flow.redeem.invoke(&request);
    defer response.deinit();
    try expect_browser_paseto(&response, &flow.redeem);
    try std.testing.expect(flow.store.entries[1].?.grant.state == .consumed);
    var replay = flow.redeem.invoke(&request);
    defer replay.deinit();
    try expect_browser_failure(&replay, .gone);
    try std.testing.expectEqual(0, flow.redeem.shared.github_checks);
    try std.testing.expectEqual(1, flow.redeem.shared.signing_key_reads);
}

fn expect_browser_paseto(
    response: *const http.HttpResponse,
    services: *const BrowserServices,
) !void {
    try std.testing.expectEqual(.ok, response.status);
    try testing.expect_response_header(response.headers, "Cache-Control", "no-store");
    const fields = try testing.issued_token(response);
    defer fields.deinit();
    try std.testing.expectEqualStrings("Bearer", fields.value.token_type);
    try std.testing.expectEqual(28800, fields.value.expires_in);
    const issued = services.shared.now_seconds + @divFloor(services.now_offset_ms, 1000);
    const expires = issued + 28800;
    var claims = try paseto.verify(
        std.testing.allocator,
        fields.value.access_token,
        services.shared.key_pair.public_key,
        expires - 1,
    );
    defer claims.deinit();
    try std.testing.expectEqualStrings("github:42", claims.sub);
    try std.testing.expectEqual(expires, claims.exp);
    try std.testing.expectError(error.InvalidToken, paseto.verify(
        std.testing.allocator,
        fields.value.access_token,
        services.shared.key_pair.public_key,
        expires,
    ));
}

test "invalid browser binding ends locally and the bound browser can return a terminal denial" {
    var flow: BrowserTest = undefined;
    try flow.init();
    defer flow.deinit();
    var authorize = test_browser_authorize;
    authorize.raw_query = "redirect_uri=https%3A%2F%2Fapp.example.test%2Fcallback%3Ffrom%3Dother" ++
        "&state=app%20state%2B%26&code_challenge=" ++ test_app_challenge ++
        "&code_challenge_method=S256";
    var upstream = try BrowserRedirect.begin(&flow, &authorize);
    defer upstream.response.deinit();
    try expect_invalid_browser_callbacks(&flow, &upstream, "error=access_denied");
    try expect_invalid_browser_callbacks(&flow, &upstream, "code=github-code");
    try std.testing.expectEqual(0, flow.callback.shared.app_secret_reads);
    try std.testing.expectEqual(0, flow.callback.browser_exchanges);
    try std.testing.expectEqual(0, flow.callback.shared.github_checks);
    var response = try upstream.callback(&flow, "error=access_denied&error_description=fixture");
    defer response.deinit();
    try std.testing.expectEqual(.found, response.status);
    try std.testing.expectEqualStrings(
        test_other_callback ++ "&error=access_denied&state=app%20state%2B%26",
        try testing.header(response.headers, "Location"),
    );
    try std.testing.expect(flow.store.entries[0].?.grant.state == .denied);
    try std.testing.expect(flow.store.entries[1] == null);
    var replay = try upstream.callback(&flow, "code=github-code");
    defer replay.deinit();
    try expect_browser_failure(&replay, .gone);
    try std.testing.expectEqual(0, flow.callback.browser_exchanges);
    try std.testing.expectEqual(0, flow.callback.shared.github_checks);
}

fn expect_invalid_browser_callbacks(
    flow: *BrowserTest,
    upstream: *const BrowserRedirect,
    outcome: []const u8,
) !void {
    const allocator = std.testing.allocator;
    const query = try std.fmt.allocPrint(allocator, "{s}&state={s}", .{ outcome, upstream.state });
    defer allocator.free(query);
    const duplicate = try std.fmt.allocPrint(allocator, "{s}&state={s}", .{
        query, upstream.state,
    });
    defer allocator.free(duplicate);
    const unknown_state = try std.fmt.allocPrint(allocator, "{s}&state={s}", .{
        outcome, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    });
    defer allocator.free(unknown_state);
    const wrong = try allocator.dupe(u8, upstream.cookie);
    defer allocator.free(wrong);
    wrong[wrong.len - 1] = if (wrong[wrong.len - 1] == '0') '1' else '0';
    for ([_]http.HttpRequest{
        .{ .raw_query = query },
        .{ .raw_query = query, .cookies = &.{wrong} },
        .{ .raw_query = query, .cookies = &.{ upstream.cookie, upstream.cookie } },
        .{ .raw_query = duplicate, .cookies = &.{upstream.cookie} },
        .{ .raw_query = outcome, .cookies = &.{upstream.cookie} },
        .{ .raw_query = unknown_state, .cookies = &.{upstream.cookie} },
    }) |invalid| {
        var request = invalid;
        request.method = .GET;
        request.path = "/auth/github/callback";
        var failed = flow.callback.invoke(&request);
        defer failed.deinit();
        try expect_browser_failure(&failed, .bad_request);
        try std.testing.expect(flow.store.entries[0].?.grant.state == .browser_pending);
    }
}

test "a failed GitHub exchange spends the callback and hides provider details" {
    const ProviderCase = struct {
        response: github.TransportError!github.Response = .{
            .status = .ok,
            .body = test_browser_token,
        },
        identity: []const u8 = testing.github_identity,
        status: std.http.Status,
        checks: u8 = 0,
    };
    for ([_]ProviderCase{
        .{ .response = error.Unavailable, .status = .service_unavailable },
        .{
            .response = .{ .status = .too_many_requests, .body = testing.provider_token },
            .status = .service_unavailable,
        },
        .{
            .response = .{ .status = .ok, .body = "{\"error\":\"bad_verification_code\"}" },
            .status = .bad_request,
        },
        .{
            .response = .{ .status = .ok, .body = "{\"error\":\"incorrect_client_credentials\"}" },
            .status = .internal_server_error,
        },
        .{
            .identity = "{\"app\":{\"client_id\":\"other\"},\"user\":{\"id\":42}}",
            .status = .service_unavailable,
            .checks = 1,
        },
        .{
            .identity = "{\"app\":{\"client_id\":\"configured-client\"},\"user\":{\"id\":0}}",
            .status = .service_unavailable,
            .checks = 1,
        },
    }) |case| {
        var flow: BrowserTest = undefined;
        try flow.init();
        defer flow.deinit();
        flow.callback.browser_token_result = case.response;
        flow.callback.shared.github_result = .{ .status = .ok, .body = case.identity };
        var upstream = try BrowserRedirect.begin(&flow, &test_browser_authorize);
        defer upstream.response.deinit();
        var capture: testing.Diagnostics = .{};
        capture.start();
        defer capture.stop();
        var failed = try upstream.callback(&flow, "code=github-secret-code");
        defer failed.deinit();
        try expect_browser_failure(&failed, case.status);
        try std.testing.expect(flow.store.entries[0].?.grant.state == .consumed);
        try std.testing.expect(flow.store.entries[1] == null);
        var replay = try upstream.callback(&flow, "code=github-secret-code");
        defer replay.deinit();
        try expect_browser_failure(&replay, .gone);
        try std.testing.expectEqual(1, flow.callback.browser_exchanges);
        try std.testing.expectEqual(case.checks, flow.callback.shared.github_checks);
        try std.testing.expectEqual(0, flow.callback.shared.signing_key_reads);
        const credentials: []const []const u8 = &.{
            testing.provider_token, testing.client_secret, "github-secret-code", upstream.state,
        };
        for (credentials) |private| {
            try std.testing.expect(std.mem.indexOf(u8, failed.body, private) == null);
        }
        try capture.expect_no_credentials(credentials);
    }
}

test "browser deadlines are exclusive while Pending Sign-in rows remain stored" {
    const DeadlineCase = struct {
        callback_ms: i64,
        exchange_ms: i64 = 0,
        redeem_ms: ?i64,
        allowed: bool = false,
    };
    for ([_]DeadlineCase{
        .{ .callback_ms = 600_000, .redeem_ms = null },
        .{ .callback_ms = 599_999, .exchange_ms = 1, .redeem_ms = null },
        .{ .callback_ms = 599_999, .redeem_ms = 599_999, .allowed = true },
        .{ .callback_ms = 599_999, .redeem_ms = 600_000 },
        .{ .callback_ms = 12_345, .exchange_ms = 500, .redeem_ms = 72_844, .allowed = true },
        .{ .callback_ms = 12_345, .exchange_ms = 500, .redeem_ms = 72_845 },
    }) |case| {
        var flow: BrowserTest = undefined;
        try flow.init();
        defer flow.deinit();
        var upstream = try BrowserRedirect.begin(&flow, &test_browser_authorize);
        defer upstream.response.deinit();
        flow.callback.now_offset_ms = case.callback_ms;
        flow.callback.advance_after_browser_exchange_ms = case.exchange_ms;
        var approved = try upstream.callback(&flow, "code=github-code");
        defer approved.deinit();
        if (case.redeem_ms) |redeem_ms| {
            try std.testing.expectEqual(.found, approved.status);
            const expected_expiry = @min(600_000, case.callback_ms + case.exchange_ms + 60_000);
            try std.testing.expectEqual(
                testing.now_seconds * 1000 + expected_expiry,
                flow.store.entries[1].?.grant.expires_at_ms,
            );
            const location = try testing.header(approved.headers, "Location");
            const code = try test_url_field(location, "code");
            const request = try test_redeem(.{ .code = code });
            defer std.testing.allocator.free(request.body.bytes);
            flow.redeem.now_offset_ms = redeem_ms;
            var response = flow.redeem.invoke(&request);
            defer response.deinit();
            if (case.allowed) {
                try expect_browser_paseto(&response, &flow.redeem);
                try std.testing.expect(flow.store.entries[1].?.grant.state == .consumed);
            } else {
                try expect_browser_failure(&response, .gone);
                try std.testing.expect(flow.store.entries[1].?.grant.state == .browser_approved);
                try std.testing.expectEqual(0, flow.redeem.shared.signing_key_reads);
            }
            var replay = flow.redeem.invoke(&request);
            defer replay.deinit();
            try expect_browser_failure(&replay, .gone);
        } else {
            try expect_browser_failure(&approved, .gone);
            try std.testing.expect(flow.store.entries[1] == null);
            const state = flow.store.entries[0].?.grant.state;
            if (case.exchange_ms == 0) {
                try std.testing.expect(state == .browser_pending);
                try std.testing.expectEqual(0, flow.callback.browser_exchanges);
            } else {
                try std.testing.expect(state == .consumed);
                try std.testing.expectEqual(1, flow.callback.browser_exchanges);
            }
            const exchanges = flow.callback.browser_exchanges;
            const checks = flow.callback.shared.github_checks;
            var replay = try upstream.callback(&flow, "code=github-code");
            defer replay.deinit();
            try expect_browser_failure(&replay, .gone);
            try std.testing.expectEqual(exchanges, flow.callback.browser_exchanges);
            try std.testing.expectEqual(checks, flow.callback.shared.github_checks);
        }
    }
}

test "only one concurrent browser redemption can consume the approved grant" {
    var flow: BrowserTest = undefined;
    try flow.init();
    defer flow.deinit();
    var upstream = try BrowserRedirect.begin(&flow, &test_browser_authorize);
    defer upstream.response.deinit();
    var approved = try upstream.callback(&flow, "code=github-code");
    defer approved.deinit();
    try std.testing.expectEqual(.found, approved.status);
    const code = try test_url_field(try testing.header(approved.headers, "Location"), "code");
    const request = try test_redeem(.{ .code = code });
    defer std.testing.allocator.free(request.body.bytes);

    const io = std.testing.io;
    var gate: testing.GrantFinishGate = .{};
    flow.store.redeem_gate = &gate;
    defer flow.store.redeem_gate = null;
    var contender: BrowserServices = undefined;
    try contender.init(&flow.store);
    defer contender.deinit();
    var first = try io.concurrent(BrowserServices.invoke, .{ &flow.redeem, &request });
    defer {
        var response = first.cancel(io);
        response.deinit();
    }
    try gate.first_arrived.waitTimeout(io, testing.GrantFinishGate.timeout);
    var second = try io.concurrent(BrowserServices.invoke, .{ &contender, &request });
    defer {
        var response = second.cancel(io);
        response.deinit();
    }
    const responses = [_]http.HttpResponse{ first.await(io), second.await(io) };
    try std.testing.expectEqual(2, gate.arrivals.load(.monotonic));
    const winner: usize = if (responses[0].status == .ok) 0 else 1;
    try expect_browser_paseto(&responses[winner], if (winner == 0) &flow.redeem else &contender);
    try expect_browser_failure(&responses[winner ^ 1], .gone);
    try std.testing.expect(flow.store.entries[1].?.grant.state == .consumed);
    var replay = flow.redeem.invoke(&request);
    defer replay.deinit();
    try expect_browser_failure(&replay, .gone);
}

test "a code-bearing callback rejects an ambiguous cookie binding before contacting GitHub" {
    var flow: BrowserTest = undefined;
    try flow.init();
    defer flow.deinit();
    var upstream = try BrowserRedirect.begin(&flow, &test_browser_authorize);
    defer upstream.response.deinit();
    const allocator = std.testing.allocator;
    const query = try upstream.callback_query(allocator, "code=github-code");
    defer allocator.free(query);
    const conflict = try upstream.conflicting_cookie(allocator);
    defer allocator.free(conflict);
    var request: http.HttpRequest = .{
        .method = .GET,
        .path = "/auth/github/callback",
        .raw_query = query,
        .cookies = &.{upstream.cookie},
        .headers = &.{.{ .key = "Cookie", .value = conflict }},
    };
    var failed = flow.callback.invoke(&request);
    defer failed.deinit();
    try expect_browser_failure(&failed, .bad_request);
    try std.testing.expectEqual(0, flow.callback.browser_exchanges);
    try std.testing.expectEqual(0, flow.callback.shared.github_checks);
    try std.testing.expect(flow.store.entries[0].?.grant.state == .browser_pending);
    request.cookies = &.{};
    request.headers = &.{.{ .key = "Cookie", .value = upstream.cookie }};
    var approved = flow.callback.invoke(&request);
    defer approved.deinit();
    try std.testing.expectEqual(.found, approved.status);
    try std.testing.expectEqual(1, flow.callback.browser_exchanges);
    try std.testing.expectEqual(1, flow.callback.shared.github_checks);
}
