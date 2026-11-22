const std = @import("std");
const aws = @import("aws");
const dynamodb = @import("dynamodb");
const github = @import("github_identity");

const Allocator = std.mem.Allocator;
const Attribute = aws.map.MapEntry(dynamodb.types.AttributeValue);

pub const Code = struct { hex: [64]u8 };
pub const Key = struct { digest: [64]u8 };
pub const pkce_challenge_size = 43;
pub const TerminalState = enum { denied, expired, consumed };
pub const BrowserFinish = enum { claim, deny, redeem };
pub const Error = error{ InternalFailure, Unavailable };

pub const Polling = struct {
    github_device_code: []const u8,
    next_poll_at_ms: i64,
    interval_seconds: u32,
};

pub const BrowserPending = struct {
    redirect_uri: []const u8,
    app_state: []const u8,
    app_challenge: []const u8,
    upstream_verifier: []const u8,
    browser_binding: []const u8,
};

pub const BrowserApproved = struct {
    redirect_uri: []const u8,
    app_challenge: []const u8,
    tenant: []const u8,
};

pub const Grant = struct {
    expires_at_ms: i64,
    state: union(enum) {
        pending: Polling,
        browser_pending: BrowserPending,
        browser_approved: BrowserApproved,
        denied,
        expired,
        consumed,
    },
};

pub const Store = struct {
    context: *anyopaque,
    create: *const fn (*anyopaque, Allocator, *const Key, *const Grant) Error!void,
    read: *const fn (*anyopaque, Allocator, *const Key) Error!?Grant,
    change: *const fn (*anyopaque, Allocator, *const Key, *const Change) Error!bool,
};

/// Binds the Pending Sign-in store on first use. The loaded config must outlive this store.
pub const RuntimeStore = struct {
    allocator: Allocator,
    environment: *const std.process.Environ.Map,
    config_context: *anyopaque,
    load_config: *const fn (*anyopaque) anyerror!*aws.Config,
    connection: ?Connection = null,

    const Connection = struct {
        table_name: []const u8,
        client: dynamodb.Client,
    };

    pub fn interface(runtime: *RuntimeStore) Store {
        return .{
            .context = runtime,
            .create = create_dynamo,
            .read = read_dynamo,
            .change = change_dynamo,
        };
    }

    pub fn deinit(runtime: *RuntimeStore) void {
        if (runtime.connection) |*connection| connection.client.deinit();
        runtime.connection = null;
    }

    fn connect(runtime: *RuntimeStore) Error!*Connection {
        if (runtime.connection == null) {
            const table_name = runtime.environment.get("PENDING_SIGN_IN_TABLE_NAME") orelse
                return error.InternalFailure;
            if (table_name.len < 3 or table_name.len > 255) return error.InternalFailure;
            const config = runtime.load_config(runtime.config_context) catch
                return error.InternalFailure;
            runtime.connection = .{
                .table_name = table_name,
                .client = dynamodb.Client.initWithOptions(
                    runtime.allocator,
                    config,
                    .{ .max_attempts = 1, .max_response_size = 8192 },
                ),
            };
        }
        return &runtime.connection.?;
    }
};

pub const Change = struct {
    now_ms: i64,
    transition: union(enum) {
        schedule: struct {
            expected_at_ms: i64,
            next_at_ms: i64,
            interval_seconds: u32,
        },
        finish: TerminalState,
        browser_finish: BrowserFinish,
    },
};

pub fn key_for(code: *const Code) Key {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&code.hex, &hash, .{});
    return .{ .digest = std.fmt.bytesToHex(hash, .lower) };
}

pub fn parse_code(text: []const u8) error{InvalidCode}!Code {
    var code: Code = undefined;
    if (text.len != code.hex.len) return error.InvalidCode;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return error.InvalidCode;
    }
    @memcpy(&code.hex, text);
    return code;
}

fn create_dynamo(
    context: *anyopaque,
    allocator: Allocator,
    key: *const Key,
    grant: *const Grant,
) Error!void {
    std.debug.assert(grant.expires_at_ms > 0);
    const runtime: *RuntimeStore = @ptrCast(@alignCast(context));
    const connection = try runtime.connect();
    const expires_at = try number(allocator, grant.expires_at_ms);
    const ttl = try number(allocator, std.math.divCeil(i64, grant.expires_at_ms, 1000) catch
        unreachable);
    var fields: [9]Attribute = undefined;
    fields[0..4].* = .{
        .{ .key = "id", .value = .{ .s = &key.digest } },
        .{ .key = "expires_at_ms", .value = expires_at },
        .{ .key = "expires_at", .value = ttl },
        .{ .key = "state", .value = .{ .s = @tagName(grant.state) } },
    };
    const field_count: usize = switch (grant.state) {
        .pending => |polling| count: {
            std.debug.assert(polling.interval_seconds > 0);
            std.debug.assert(polling.github_device_code.len > 0);
            std.debug.assert(polling.github_device_code.len <= github.device_code_size_max);
            std.debug.assert(grant.expires_at_ms > polling.next_poll_at_ms);
            const next_poll_at = try number(allocator, polling.next_poll_at_ms);
            const interval = try number(allocator, polling.interval_seconds);
            fields[4..7].* = .{
                .{ .key = "github_device_code", .value = .{ .s = polling.github_device_code } },
                .{ .key = "next_poll_at_ms", .value = next_poll_at },
                .{ .key = "interval_seconds", .value = interval },
            };
            break :count 7;
        },
        .browser_pending => |browser| count: {
            std.debug.assert(browser.redirect_uri.len > 0);
            std.debug.assert(browser.app_state.len > 0);
            std.debug.assert(browser.app_challenge.len == pkce_challenge_size);
            std.debug.assert(browser.upstream_verifier.len == @sizeOf(Code));
            std.debug.assert(browser.browser_binding.len == @sizeOf(Key));
            fields[4..9].* = .{
                .{ .key = "redirect_uri", .value = .{ .s = browser.redirect_uri } },
                .{ .key = "app_state", .value = .{ .s = browser.app_state } },
                .{ .key = "app_challenge", .value = .{ .s = browser.app_challenge } },
                .{ .key = "upstream_verifier", .value = .{ .s = browser.upstream_verifier } },
                .{ .key = "browser_binding", .value = .{ .s = browser.browser_binding } },
            };
            break :count 9;
        },
        .browser_approved => |browser| count: {
            std.debug.assert(browser.redirect_uri.len > 0);
            std.debug.assert(browser.app_challenge.len == pkce_challenge_size);
            std.debug.assert(browser.tenant.len > 0);
            fields[4..7].* = .{
                .{ .key = "redirect_uri", .value = .{ .s = browser.redirect_uri } },
                .{ .key = "app_challenge", .value = .{ .s = browser.app_challenge } },
                .{ .key = "tenant", .value = .{ .s = browser.tenant } },
            };
            break :count 7;
        },
        .denied, .expired, .consumed => unreachable,
    };
    _ = connection.client.putItem(allocator, .{
        .table_name = connection.table_name,
        .condition_expression = "attribute_not_exists(id)",
        .item = fields[0..field_count],
    }, .{}) catch return error.Unavailable;
}

fn read_dynamo(context: *anyopaque, arena: Allocator, key: *const Key) Error!?Grant {
    const runtime: *RuntimeStore = @ptrCast(@alignCast(context));
    const connection = try runtime.connect();
    const result = connection.client.getItem(arena, .{
        .table_name = connection.table_name,
        .key = &.{.{ .key = "id", .value = .{ .s = &key.digest } }},
        .consistent_read = true,
    }, .{}) catch return error.Unavailable;
    const item = result.item orelse return null;
    const State = @FieldType(Grant, "state");
    const state = std.meta.stringToEnum(std.meta.Tag(State), try get_string(item, "state")) orelse
        return error.InternalFailure;
    const expires_at_ms = try get_number(i64, item, "expires_at_ms");
    if (expires_at_ms <= 0) return error.InternalFailure;
    return .{
        .state = switch (state) {
            .pending => .{ .pending = try read_polling(item) },
            .browser_pending => .{ .browser_pending = .{
                .redirect_uri = try get_string(item, "redirect_uri"),
                .app_state = try get_string(item, "app_state"),
                .app_challenge = try get_fixed_string(item, "app_challenge", pkce_challenge_size),
                .upstream_verifier = try get_fixed_string(item, "upstream_verifier", @sizeOf(Code)),
                .browser_binding = try get_fixed_string(item, "browser_binding", @sizeOf(Key)),
            } },
            .browser_approved => .{ .browser_approved = .{
                .redirect_uri = try get_string(item, "redirect_uri"),
                .app_challenge = try get_fixed_string(item, "app_challenge", pkce_challenge_size),
                .tenant = try get_string(item, "tenant"),
            } },
            .denied => .denied,
            .expired => .expired,
            .consumed => .consumed,
        },
        .expires_at_ms = expires_at_ms,
    };
}

fn read_polling(item: []const Attribute) Error!Polling {
    const github_device_code = try get_string(item, "github_device_code");
    const interval_seconds = try get_number(u32, item, "interval_seconds");
    const next_poll_at_ms = try get_number(i64, item, "next_poll_at_ms");
    if (github_device_code.len == 0 or github_device_code.len > github.device_code_size_max) {
        return error.InternalFailure;
    }
    if (interval_seconds == 0 or next_poll_at_ms <= 0) return error.InternalFailure;
    return .{
        .github_device_code = github_device_code,
        .interval_seconds = interval_seconds,
        .next_poll_at_ms = next_poll_at_ms,
    };
}

fn change_dynamo(
    context: *anyopaque,
    arena: Allocator,
    key: *const Key,
    change: *const Change,
) Error!bool {
    const runtime: *RuntimeStore = @ptrCast(@alignCast(context));
    const connection = try runtime.connect();
    const pending_and_live = "#state = :pending AND expires_at_ms > :now";
    var values: [5]Attribute = undefined;
    values[0] = .{ .key = ":pending", .value = .{ .s = "pending" } };
    values[1] = .{ .key = ":now", .value = try number(arena, change.now_ms) };
    var request: dynamodb.UpdateItemInput = .{
        .table_name = connection.table_name,
        .key = &.{.{ .key = "id", .value = .{ .s = &key.digest } }},
        .expression_attribute_names = &.{.{ .key = "#state", .value = "state" }},
    };
    switch (change.transition) {
        .schedule => |schedule| {
            std.debug.assert(schedule.next_at_ms > change.now_ms);
            std.debug.assert(schedule.interval_seconds > 0);
            values[2] = .{
                .key = ":previous",
                .value = try number(arena, schedule.expected_at_ms),
            };
            values[3] = .{ .key = ":next", .value = try number(arena, schedule.next_at_ms) };
            values[4] = .{
                .key = ":interval",
                .value = try number(arena, schedule.interval_seconds),
            };
            request.expression_attribute_values = &values;
            request.condition_expression = pending_and_live ++ " AND next_poll_at_ms = :previous";
            request.update_expression = "SET next_poll_at_ms = :next, interval_seconds = :interval";
        },
        .finish => |state| {
            values[2] = .{ .key = ":terminal", .value = .{ .s = @tagName(state) } };
            request.expression_attribute_values = values[0..3];
            request.condition_expression = pending_and_live;
            request.update_expression = "SET #state = :terminal REMOVE github_device_code";
        },
        .browser_finish => |transition| {
            const expected = if (transition == .redeem) "browser_approved" else "browser_pending";
            values[0].value = .{ .s = expected };
            values[2] = .{
                .key = ":terminal",
                .value = .{ .s = if (transition == .deny) "denied" else "consumed" },
            };
            request.expression_attribute_values = values[0..3];
            request.condition_expression = pending_and_live;
            request.update_expression = if (transition == .redeem)
                "SET #state = :terminal REMOVE redirect_uri, app_challenge, tenant"
            else
                "SET #state = :terminal REMOVE redirect_uri, app_state, app_challenge, " ++
                    "upstream_verifier, browser_binding";
        },
    }
    var diagnostic: dynamodb.ServiceError = undefined;
    _ = connection.client.updateItem(arena, request, .{ .diagnostic = &diagnostic }) catch |err| {
        if (err != error.ServiceError) return error.Unavailable;
        defer diagnostic.deinit();
        return switch (diagnostic.kind) {
            .conditional_check_failed_exception => false,
            else => error.Unavailable,
        };
    };
    return true;
}

fn get_string(item: []const Attribute, key: []const u8) Error![]const u8 {
    return switch (try get_attribute(item, key)) {
        .s => |value| value orelse error.InternalFailure,
        else => error.InternalFailure,
    };
}

fn get_fixed_string(item: []const Attribute, key: []const u8, length: usize) Error![]const u8 {
    const value = try get_string(item, key);
    if (value.len != length) return error.InternalFailure;
    return value;
}

fn get_number(comptime T: type, item: []const Attribute, key: []const u8) Error!T {
    const raw = switch (try get_attribute(item, key)) {
        .n => |value| value orelse return error.InternalFailure,
        else => return error.InternalFailure,
    };
    return std.fmt.parseInt(T, raw, 10) catch error.InternalFailure;
}

fn get_attribute(item: []const Attribute, key: []const u8) Error!dynamodb.types.AttributeValue {
    for (item) |attribute| {
        if (std.mem.eql(u8, attribute.key, key)) return attribute.value;
    }
    return error.InternalFailure;
}

fn number(allocator: Allocator, value: i64) Error!dynamodb.types.AttributeValue {
    return .{ .n = std.fmt.allocPrint(allocator, "{d}", .{value}) catch
        return error.InternalFailure };
}

test "runtime integration: DynamoDB guards the Pending Sign-in schedule and consumption" {
    if (comptime !@import("runtime_test_options").enabled) return error.SkipZigTest;
    const io = std.testing.io;
    const loopback: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try loopback.listen(io, .{ .mode = .stream });
    defer listener.deinit(io);
    var peer = try io.concurrent(mock_dynamodb, .{ &listener, io });
    defer peer.cancel(io) catch {};

    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var environment = std.process.Environ.Map.init(arena);
    defer environment.deinit();
    try environment.put("AWS_ACCESS_KEY_ID", "fixture");
    try environment.put("AWS_SECRET_ACCESS_KEY", "fixture");
    try environment.put("AWS_EC2_METADATA_DISABLED", "true");
    try environment.put("AWS_CONFIG_FILE", "/dev/null");
    try environment.put("AWS_SHARED_CREDENTIALS_FILE", "/dev/null");
    try environment.put("PENDING_SIGN_IN_TABLE_NAME", "fixture-sign-ins");
    var config = try aws.Config.load(arena, io, &environment, .{
        .region = "ca-central-1",
        .endpoint_url = try std.fmt.allocPrint(arena, "http://{f}", .{listener.socket.address}),
        .max_attempts = 1,
    });
    defer config.deinit();
    const Fixture = struct {
        fn load_config(context: *anyopaque) anyerror!*aws.Config {
            return @ptrCast(@alignCast(context));
        }
    };
    var runtime: RuntimeStore = .{
        .allocator = arena,
        .environment = &environment,
        .config_context = &config,
        .load_config = Fixture.load_config,
    };
    defer runtime.deinit();
    const store = runtime.interface();
    const grant: Grant = .{
        .expires_at_ms = 1900001,
        .state = .{ .pending = .{
            .github_device_code = "fixture-upstream-code",
            .next_poll_at_ms = 1005000,
            .interval_seconds = 5,
        } },
    };
    try store.create(store.context, arena, &test_key, &grant);
    const loaded = (try store.read(store.context, arena, &test_key)).?;
    try std.testing.expectEqualDeep(grant, loaded);
    try std.testing.expect(try store.change(store.context, arena, &test_key, &.{
        .now_ms = 1005000,
        .transition = .{ .schedule = .{
            .expected_at_ms = loaded.state.pending.next_poll_at_ms,
            .next_at_ms = 1020000,
            .interval_seconds = 5,
        } },
    }));
    const finish: Change = .{ .now_ms = 1005001, .transition = .{ .finish = .consumed } };
    try std.testing.expect(try store.change(store.context, arena, &test_key, &finish));
    try std.testing.expect(!try store.change(store.context, arena, &test_key, &finish));
    try exercise_browser_dynamo(arena, &store);
    try peer.await(io);
}

const test_key: Key = .{ .digest = @splat('a') };

fn exercise_browser_dynamo(arena: Allocator, store: *const Store) !void {
    const pending: Grant = .{
        .expires_at_ms = 1900001,
        .state = .{ .browser_pending = .{
            .redirect_uri = "https://app.example.test/callback",
            .app_state = "fixture-app-state",
            .app_challenge = test_challenge,
            .upstream_verifier = &test_verifier,
            .browser_binding = &test_binding,
        } },
    };
    const approved: Grant = .{
        .expires_at_ms = 1065001,
        .state = .{ .browser_approved = .{
            .redirect_uri = "https://app.example.test/callback",
            .app_challenge = test_challenge,
            .tenant = "github:42",
        } },
    };
    try store.create(store.context, arena, &test_browser_key, &pending);
    const loaded_pending = (try store.read(store.context, arena, &test_browser_key)).?;
    try std.testing.expectEqualDeep(pending, loaded_pending);
    const claim: Change = .{ .now_ms = 1005001, .transition = .{ .browser_finish = .claim } };
    try std.testing.expect(try store.change(store.context, arena, &test_browser_key, &claim));
    const deny: Change = .{ .now_ms = 1005001, .transition = .{ .browser_finish = .deny } };
    try std.testing.expect(try store.change(store.context, arena, &test_denial_key, &deny));
    try store.create(store.context, arena, &test_redeem_key, &approved);
    const loaded_approved = (try store.read(store.context, arena, &test_redeem_key)).?;
    try std.testing.expectEqualDeep(approved, loaded_approved);
    const redeem: Change = .{ .now_ms = 1005001, .transition = .{ .browser_finish = .redeem } };
    try std.testing.expect(try store.change(store.context, arena, &test_redeem_key, &redeem));
    try std.testing.expect(!try store.change(store.context, arena, &test_redeem_key, &redeem));
}

const test_browser_key: Key = .{ .digest = @splat('b') };
const test_denial_key: Key = .{ .digest = @splat('c') };
const test_redeem_key: Key = .{ .digest = @splat('d') };
const test_challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
const test_verifier: [64]u8 = @splat('e');
const test_binding: [64]u8 = @splat('f');

const AwsStep = enum {
    create,
    read,
    schedule,
    consume,
    conflict,
    browser_create,
    browser_read,
    browser_claim,
    browser_deny,
    redeem_create,
    redeem_read,
    redeem_consume,
    redeem_conflict,
};

fn mock_dynamodb(listener: *std.Io.net.Server, io: std.Io) !void {
    for (std.enums.values(AwsStep)) |step| {
        const connection = try listener.accept(io);
        defer connection.close(io);
        try mock_aws_command(connection, io, step);
    }
}

fn mock_aws_command(connection: std.Io.net.Stream, io: std.Io, step: AwsStep) !void {
    var input: [4096]u8 = undefined;
    var output: [1024]u8 = undefined;
    var reader = connection.reader(io, &input);
    var writer = connection.writer(io, &output);
    var server: std.http.Server = .init(&reader.interface, &writer.interface);
    var request = try server.receiveHead();
    try std.testing.expectEqual(.POST, request.head.method);
    try std.testing.expectEqualStrings("/", request.head.target);
    var headers = request.iterateHeaders();
    var operation: ?[]const u8 = null;
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-amz-target")) operation = header.value;
    }
    try std.testing.expectEqualStrings(switch (step) {
        .create, .browser_create, .redeem_create => "DynamoDB_20120810.PutItem",
        .read, .browser_read, .redeem_read => "DynamoDB_20120810.GetItem",
        else => "DynamoDB_20120810.UpdateItem",
    }, operation orelse return error.MissingOperation);
    var body_buffer: [4096]u8 = undefined;
    const length = request.head.content_length orelse return error.MissingRequestBody;
    if (length > body_buffer.len) return error.OversizedRequestBody;
    const body_reader = try request.readerExpectContinue(&body_buffer);
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        try body_reader.take(@intCast(length)),
        .{},
    );
    defer parsed.deinit();
    try expect_aws_body(&parsed.value, step);

    const body = switch (step) {
        .read => "{\"Item\":" ++ test_item ++ "}",
        .browser_read => "{\"Item\":" ++ test_browser_item ++ "}",
        .redeem_read => "{\"Item\":" ++ test_approved_item ++ "}",
        .conflict, .redeem_conflict => "{\"__type\":\"ConditionalCheckFailedException\"," ++
            "\"message\":\"fixture-upstream-code\"}",
        else => "{}",
    };
    try request.respond(body, .{
        .status = if (step == .conflict or step == .redeem_conflict) .bad_request else .ok,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/x-amz-json-1.0" }},
    });
}

const test_item =
    "{\"id\":{\"S\":\"" ++ test_key.digest ++ "\"},\"state\":{\"S\":\"pending\"}," ++
    "\"github_device_code\":{\"S\":\"fixture-upstream-code\"}," ++
    "\"expires_at_ms\":{\"N\":\"1900001\"},\"expires_at\":{\"N\":\"1901\"}," ++
    "\"next_poll_at_ms\":{\"N\":\"1005000\"},\"interval_seconds\":{\"N\":\"5\"}}";

const test_browser_item =
    "{\"id\":{\"S\":\"" ++ test_browser_key.digest ++ "\"}," ++
    "\"state\":{\"S\":\"browser_pending\"}," ++
    "\"expires_at_ms\":{\"N\":\"1900001\"},\"expires_at\":{\"N\":\"1901\"}," ++
    "\"redirect_uri\":{\"S\":\"https://app.example.test/callback\"}," ++
    "\"app_state\":{\"S\":\"fixture-app-state\"}," ++
    "\"app_challenge\":{\"S\":\"" ++ test_challenge ++ "\"}," ++
    "\"upstream_verifier\":{\"S\":\"" ++ test_verifier ++ "\"}," ++
    "\"browser_binding\":{\"S\":\"" ++ test_binding ++ "\"}}";

const test_approved_item =
    "{\"id\":{\"S\":\"" ++ test_redeem_key.digest ++ "\"}," ++
    "\"state\":{\"S\":\"browser_approved\"}," ++
    "\"expires_at_ms\":{\"N\":\"1065001\"},\"expires_at\":{\"N\":\"1066\"}," ++
    "\"redirect_uri\":{\"S\":\"https://app.example.test/callback\"}," ++
    "\"app_challenge\":{\"S\":\"" ++ test_challenge ++ "\"},\"tenant\":{\"S\":\"github:42\"}}";

fn required(value: *const std.json.Value, key: []const u8) !std.json.Value {
    if (value.* != .object) return error.ExpectedObject;
    return value.object.get(key) orelse error.MissingField;
}

fn expect_aws_body(command: *const std.json.Value, step: AwsStep) !void {
    const table = try required(command, "TableName");
    try std.testing.expectEqualStrings("fixture-sign-ins", table.string);
    const expected_item: ?[]const u8 = switch (step) {
        .create => test_item,
        .browser_create => test_browser_item,
        .redeem_create => test_approved_item,
        else => null,
    };
    const key = try required(command, if (expected_item != null) "Item" else "Key");
    const row_id = try required(&key, "id");
    const digest = switch (step) {
        .browser_create, .browser_read, .browser_claim => &test_browser_key.digest,
        .browser_deny => &test_denial_key.digest,
        .redeem_create, .redeem_read, .redeem_consume, .redeem_conflict => &test_redeem_key.digest,
        else => &test_key.digest,
    };
    try std.testing.expectEqualStrings(digest, (try required(&row_id, "S")).string);
    switch (step) {
        .create, .browser_create, .redeem_create => {
            const parsed = try std.json.parseFromSlice(
                std.json.Value,
                std.testing.allocator,
                expected_item.?,
                .{},
            );
            defer parsed.deinit();
            try std.testing.expectEqual(parsed.value.object.count(), key.object.count());
            for (parsed.value.object.keys(), parsed.value.object.values()) |name, expected| {
                const actual = try required(&key, name);
                const attribute_type = expected.object.keys()[0];
                try std.testing.expectEqualStrings(
                    (try required(&expected, attribute_type)).string,
                    (try required(&actual, attribute_type)).string,
                );
            }
            try std.testing.expectEqualStrings(
                "attribute_not_exists(id)",
                (try required(command, "ConditionExpression")).string,
            );
        },
        .read, .browser_read, .redeem_read => {
            try std.testing.expect((try required(command, "ConsistentRead")).bool);
        },
        .schedule, .consume, .conflict => try expect_aws_transition(command, step),
        .browser_claim, .browser_deny, .redeem_consume, .redeem_conflict => {
            try expect_browser_aws_transition(command, step);
        },
    }
}

fn expect_browser_aws_transition(command: *const std.json.Value, step: AwsStep) !void {
    const redeem = step == .redeem_consume or step == .redeem_conflict;
    const names = try required(command, "ExpressionAttributeNames");
    const values = try required(command, "ExpressionAttributeValues");
    const pending = try required(&values, ":pending");
    const now = try required(&values, ":now");
    const terminal = try required(&values, ":terminal");
    try std.testing.expectEqualStrings("state", (try required(&names, "#state")).string);
    try std.testing.expectEqualStrings(
        if (redeem) "browser_approved" else "browser_pending",
        (try required(&pending, "S")).string,
    );
    try std.testing.expectEqualStrings("1005001", (try required(&now, "N")).string);
    try std.testing.expectEqualStrings(
        if (step == .browser_deny) "denied" else "consumed",
        (try required(&terminal, "S")).string,
    );
    try std.testing.expectEqualStrings(
        "#state = :pending AND expires_at_ms > :now",
        (try required(command, "ConditionExpression")).string,
    );
    const clear_approved = "SET #state = :terminal REMOVE redirect_uri, app_challenge, tenant";
    const clear_pending = "SET #state = :terminal REMOVE redirect_uri, app_state, " ++
        "app_challenge, upstream_verifier, browser_binding";
    const update = if (redeem) clear_approved else clear_pending;
    try std.testing.expectEqualStrings(update, (try required(command, "UpdateExpression")).string);
}

fn expect_aws_transition(command: *const std.json.Value, step: AwsStep) !void {
    const names = try required(command, "ExpressionAttributeNames");
    const values = try required(command, "ExpressionAttributeValues");
    const pending = try required(&values, ":pending");
    const now = try required(&values, ":now");
    try std.testing.expectEqualStrings("state", (try required(&names, "#state")).string);
    try std.testing.expectEqualStrings("pending", (try required(&pending, "S")).string);
    if (step == .schedule) {
        const previous = try required(&values, ":previous");
        const next = try required(&values, ":next");
        const interval = try required(&values, ":interval");
        try std.testing.expectEqualStrings("1005000", (try required(&now, "N")).string);
        try std.testing.expectEqualStrings("1005000", (try required(&previous, "N")).string);
        try std.testing.expectEqualStrings("1020000", (try required(&next, "N")).string);
        try std.testing.expectEqualStrings("5", (try required(&interval, "N")).string);
        try std.testing.expectEqualStrings(
            "#state = :pending AND expires_at_ms > :now AND next_poll_at_ms = :previous",
            (try required(command, "ConditionExpression")).string,
        );
        try std.testing.expectEqualStrings(
            "SET next_poll_at_ms = :next, interval_seconds = :interval",
            (try required(command, "UpdateExpression")).string,
        );
    } else {
        const terminal = try required(&values, ":terminal");
        try std.testing.expectEqualStrings("1005001", (try required(&now, "N")).string);
        try std.testing.expectEqualStrings("consumed", (try required(&terminal, "S")).string);
        try std.testing.expectEqualStrings(
            "#state = :pending AND expires_at_ms > :now",
            (try required(command, "ConditionExpression")).string,
        );
        try std.testing.expectEqualStrings(
            "SET #state = :terminal REMOVE github_device_code",
            (try required(command, "UpdateExpression")).string,
        );
    }
}
