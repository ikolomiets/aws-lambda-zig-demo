const std = @import("std");
const http = @import("http");

const Allocator = std.mem.Allocator;
const access_token_size_max = 16 * 1024;
const client_id_size_max = 256;
const client_secret_size_max = 1024;
pub const device_code_size_max = 1024;
pub const authorization_code_size_max = 1024;
pub const device_verification_uri = "https://github.com/login/device";
pub const device_start_url = "https://github.com/login/device/code";
pub const oauth_token_url = "https://github.com/login/oauth/access_token";
pub const authorize_url = "https://github.com/login/oauth/authorize";

pub const response_size_max = 32 * 1024;

pub const Request = struct {
    method: std.http.Method,
    url: []const u8,
    headers: []const http.Header,
    body: []const u8,
};

/// The transport applies a deadline, disables redirects and caps the response body.
/// Request fields are borrowed for the call. The response body lives in the provided
/// invocation arena or in storage borrowed for the duration of the exchange.
pub const SendFn = *const fn (
    *anyopaque,
    Allocator,
    *const Request,
) TransportError!Response;

pub const Response = struct {
    status: std.http.Status,
    body: []const u8,
};

pub const TransportError = error{ Unavailable, OutOfMemory };
pub const Error = error{ Unauthorized, Unavailable, InternalFailure };

pub const AccessToken = struct {
    bytes: []const u8,

    pub fn parse(bytes: []const u8) error{Unauthorized}!AccessToken {
        if (bytes.len > access_token_size_max) return error.Unauthorized;
        const token = std.mem.trimEnd(u8, bytes, "=");
        if (token.len == 0) return error.Unauthorized;
        for (token) |byte| {
            if (std.ascii.isAlphanumeric(byte)) continue;
            if (std.mem.indexOfScalar(u8, "-._~+/", byte) == null) return error.Unauthorized;
        }
        return .{ .bytes = bytes };
    }
};

pub const Credentials = struct {
    client_id: []const u8,
    client_secret: []const u8,
    access_token: AccessToken,
};

pub const Authorization = struct {
    client_id: []const u8,
    redirect_uri: []const u8,
    state: []const u8,
    challenge: []const u8,
};

pub fn authorize(arena: Allocator, request: *const Authorization) Error![]const u8 {
    try validate_client_id(request.client_id);
    var buffer = std.Io.Writer.Allocating.init(arena);
    errdefer buffer.deinit();
    const writer = &buffer.writer;
    writer.print(authorize_url ++ "?client_id={s}&redirect_uri=", .{request.client_id}) catch
        return error.InternalFailure;
    std.Uri.Component.percentEncode(writer, request.redirect_uri, form_unreserved) catch
        return error.InternalFailure;
    writer.print("&scope=&state={s}&code_challenge={s}&code_challenge_method=S256", .{
        request.state, request.challenge,
    }) catch return error.InternalFailure;
    return buffer.written();
}

pub const DeviceGrant = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    interval: u32,
    expires_in: u32,
};

pub const DevicePoll = union(enum) {
    pending,
    slow_down: ?u32,
    denied,
    expired,
    approved: AccessToken,
};

pub fn start_device(
    arena: Allocator,
    client_id: []const u8,
    context: *anyopaque,
    send: SendFn,
) Error!DeviceGrant {
    try validate_client_id(client_id);
    const body = std.fmt.allocPrint(arena, "client_id={s}&scope=", .{client_id}) catch {
        return error.InternalFailure;
    };
    const response = try send_form(arena, context, send, device_start_url, body);
    if (response.status != .ok) return error.Unavailable;
    const grant = try parse_response(DeviceGrant, arena, response.body);
    if (grant.device_code.len == 0 or grant.device_code.len > device_code_size_max) {
        return error.Unavailable;
    }
    if (grant.user_code.len == 0 or grant.user_code.len > 32) return error.Unavailable;
    for (grant.user_code) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-') return error.Unavailable;
    }
    if (!std.mem.eql(u8, grant.verification_uri, device_verification_uri)) return error.Unavailable;
    if (grant.interval == 0 or grant.interval >= grant.expires_in) return error.Unavailable;
    return grant;
}

pub fn poll_device(
    arena: Allocator,
    client_id: []const u8,
    device_code: []const u8,
    context: *anyopaque,
    send: SendFn,
) Error!DevicePoll {
    try validate_client_id(client_id);
    std.debug.assert(device_code.len > 0);
    std.debug.assert(device_code.len <= device_code_size_max);
    var encoded_buffer: [3 * device_code_size_max]u8 = undefined;
    var encoded: std.Io.Writer = .fixed(&encoded_buffer);
    std.Uri.Component.percentEncode(&encoded, device_code, form_unreserved) catch unreachable;
    defer std.crypto.secureZero(u8, encoded.buffered());
    const body = std.fmt.allocPrint(
        arena,
        "client_id={s}&device_code={s}" ++
            "&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code",
        .{ client_id, encoded.buffered() },
    ) catch return error.InternalFailure;
    defer std.crypto.secureZero(u8, body);

    const response = try send_form(arena, context, send, oauth_token_url, body);
    switch (response.status) {
        .ok, .bad_request, .forbidden, .too_many_requests => {},
        else => return error.Unavailable,
    }
    const fields = try parse_response(struct {
        @"error": ?[]const u8 = null,
        interval: ?u32 = null,
        access_token: ?[]const u8 = null,
        token_type: ?[]const u8 = null,
    }, arena, response.body);
    if (fields.@"error") |failure| {
        if (fields.access_token != null) return error.Unavailable;
        return switch (std.meta.stringToEnum(enum {
            authorization_pending,
            slow_down,
            access_denied,
            expired_token,
            token_expired,
            incorrect_device_code,
            incorrect_client_credentials,
            device_flow_disabled,
            unsupported_grant_type,
        }, failure) orelse return error.Unavailable) {
            .authorization_pending => .pending,
            .slow_down => .{ .slow_down = fields.interval },
            .access_denied => .denied,
            .expired_token, .token_expired => .expired,
            // Another invocation may already be verifying a token from the same code.
            .incorrect_device_code => error.Unavailable,
            .incorrect_client_credentials,
            .device_flow_disabled,
            .unsupported_grant_type,
            => error.InternalFailure,
        };
    }
    if (response.status != .ok) return error.Unavailable;
    const token_type = fields.token_type orelse return error.Unavailable;
    if (!std.ascii.eqlIgnoreCase(token_type, "bearer")) return error.Unavailable;
    const token = AccessToken.parse(fields.access_token orelse return error.Unavailable) catch {
        return error.Unavailable;
    };
    return .{ .approved = token };
}

fn form_unreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~", byte) != null;
}

fn send_form(
    arena: Allocator,
    context: *anyopaque,
    send: SendFn,
    url: []const u8,
    body: []const u8,
) Error!Response {
    return send(context, arena, &.{
        .method = .POST,
        .url = url,
        .headers = &.{
            .{ .key = "Accept", .value = "application/json" },
            .{ .key = "Content-Type", .value = "application/x-www-form-urlencoded" },
            .{ .key = "User-Agent", .value = "operations-api" },
        },
        .body = body,
    }) catch |err| switch (err) {
        error.Unavailable => return error.Unavailable,
        error.OutOfMemory => return error.InternalFailure,
    };
}

pub const CodeExchange = struct {
    client_id: []const u8,
    client_secret: []const u8,
    code: []const u8,
    redirect_uri: []const u8,
    verifier: []const u8,
};

pub fn exchange_code(
    arena: Allocator,
    exchange: *const CodeExchange,
    context: *anyopaque,
    send: SendFn,
) Error!AccessToken {
    try validate_client_id(exchange.client_id);
    if (exchange.client_secret.len == 0 or exchange.client_secret.len > client_secret_size_max) {
        return error.InternalFailure;
    }
    std.debug.assert(exchange.code.len > 0);
    std.debug.assert(exchange.code.len <= authorization_code_size_max);
    var buffer = std.Io.Writer.Allocating.init(arena);
    defer buffer.deinit();
    defer std.crypto.secureZero(u8, buffer.written());
    const writer = &buffer.writer;
    writer.print("client_id={s}", .{exchange.client_id}) catch return error.InternalFailure;
    for ([_]http.Header{
        .{ .key = "client_secret", .value = exchange.client_secret },
        .{ .key = "code", .value = exchange.code },
        .{ .key = "redirect_uri", .value = exchange.redirect_uri },
        .{ .key = "code_verifier", .value = exchange.verifier },
    }) |field| {
        writer.print("&{s}=", .{field.key}) catch return error.InternalFailure;
        std.Uri.Component.percentEncode(writer, field.value, form_unreserved) catch
            return error.InternalFailure;
    }
    const response = try send_form(arena, context, send, oauth_token_url, buffer.written());
    switch (response.status) {
        .ok, .bad_request => {},
        .unauthorized => return error.InternalFailure,
        else => return error.Unavailable,
    }
    const fields = try parse_response(struct {
        @"error": ?[]const u8 = null,
        access_token: ?[]const u8 = null,
        token_type: ?[]const u8 = null,
    }, arena, response.body);
    if (fields.@"error") |failure| {
        if (fields.access_token != null) return error.Unavailable;
        if (std.mem.eql(u8, failure, "bad_verification_code")) return error.Unauthorized;
        if (std.mem.eql(u8, failure, "incorrect_client_credentials") or
            std.mem.eql(u8, failure, "redirect_uri_mismatch"))
        {
            return error.InternalFailure;
        }
        return error.Unavailable;
    }
    if (response.status != .ok) return error.Unavailable;
    if (!std.ascii.eqlIgnoreCase(fields.token_type orelse return error.Unavailable, "bearer")) {
        return error.Unavailable;
    }
    return AccessToken.parse(fields.access_token orelse return error.Unavailable) catch
        error.Unavailable;
}

const IdentityResponse = struct {
    app: struct { client_id: []const u8 },
    user: struct { id: AccountId },
};

const AccountId = struct {
    value: u64,

    pub fn jsonParse(_: Allocator, source: anytype, _: std.json.ParseOptions) !AccountId {
        const number = switch (try source.next()) {
            .number => |value| value,
            else => return error.UnexpectedToken,
        };
        for (number) |byte| {
            if (!std.ascii.isDigit(byte)) return error.UnexpectedToken;
        }
        const value = try std.fmt.parseInt(u64, number, 10);
        if (value == 0) return error.UnexpectedToken;
        return .{ .value = value };
    }
};

pub fn resolve_tenant(
    arena: Allocator,
    credentials: *const Credentials,
    context: *anyopaque,
    check_token: SendFn,
) Error![]const u8 {
    const response = try check(arena, credentials, context, check_token);
    switch (response.status) {
        .ok => {},
        .not_found => return error.Unauthorized,
        .unauthorized => return error.InternalFailure,
        // GitHub can use 403 or 429 for rate limiting and 422 for abuse throttling.
        else => return error.Unavailable,
    }
    const identity = try parse_response(IdentityResponse, arena, response.body);
    if (!std.mem.eql(u8, identity.app.client_id, credentials.client_id)) {
        return error.Unauthorized;
    }
    std.debug.assert(identity.user.id.value > 0);
    return std.fmt.allocPrint(arena, "github:{d}", .{identity.user.id.value}) catch {
        return error.InternalFailure;
    };
}

fn parse_response(comptime Value: type, arena: Allocator, body: []const u8) Error!Value {
    if (body.len > response_size_max) return error.Unavailable;
    return std.json.parseFromSliceLeaky(Value, arena, body, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.InternalFailure,
        else => error.Unavailable,
    };
}

fn validate_client_id(client_id: []const u8) error{InternalFailure}!void {
    if (client_id.len == 0 or client_id.len > client_id_size_max) return error.InternalFailure;
    if (std.mem.eql(u8, client_id, ".") or std.mem.eql(u8, client_id, "..")) {
        return error.InternalFailure;
    }
    for (client_id) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        if (std.mem.indexOfScalar(u8, "-._", byte) == null) return error.InternalFailure;
    }
}

fn check(
    arena: Allocator,
    credentials: *const Credentials,
    context: *anyopaque,
    check_token: SendFn,
) Error!Response {
    std.debug.assert(credentials.access_token.bytes.len > 0);
    std.debug.assert(credentials.access_token.bytes.len <= access_token_size_max);
    const client_id = credentials.client_id;
    try validate_client_id(client_id);
    const client_secret = credentials.client_secret;
    if (client_secret.len == 0 or client_secret.len > client_secret_size_max) {
        return error.InternalFailure;
    }
    const url = std.fmt.allocPrint(
        arena,
        "https://api.github.com/applications/{s}/token",
        .{client_id},
    ) catch return error.InternalFailure;

    var basic_buffer: [client_id_size_max + 1 + client_secret_size_max]u8 = undefined;
    const basic = std.fmt.bufPrint(&basic_buffer, "{s}:{s}", .{ client_id, client_secret }) catch {
        unreachable;
    };
    defer std.crypto.secureZero(u8, basic);
    const encoder = std.base64.standard.Encoder;
    var authorization_buffer: ["Basic ".len + encoder.calcSize(basic_buffer.len)]u8 = undefined;
    @memcpy(authorization_buffer[0.."Basic ".len], "Basic ");
    const encoded = encoder.encode(authorization_buffer["Basic ".len..], basic);
    const authorization = authorization_buffer[0 .. "Basic ".len + encoded.len];
    defer std.crypto.secureZero(u8, authorization);

    const body = std.json.Stringify.valueAlloc(arena, .{
        .access_token = credentials.access_token.bytes,
    }, .{}) catch return error.InternalFailure;
    defer std.crypto.secureZero(u8, body);

    return check_token(context, arena, &.{
        .method = .POST,
        .url = url,
        .headers = &.{
            .{ .key = "Authorization", .value = authorization },
            .{ .key = "Accept", .value = "application/vnd.github+json" },
            .{ .key = "Content-Type", .value = "application/json" },
            .{ .key = "User-Agent", .value = "operations-api" },
            .{ .key = "X-GitHub-Api-Version", .value = "2026-03-10" },
        },
        .body = body,
    }) catch |err| switch (err) {
        error.Unavailable => error.Unavailable,
        error.OutOfMemory => error.InternalFailure,
    };
}
