const std = @import("std");
const http = @import("http");

const Allocator = std.mem.Allocator;
const access_token_size_max = 16 * 1024;
const client_id_size_max = 256;
const client_secret_size_max = 1024;

pub const token_check_body_size_max = 32 * 1024;

pub const TokenCheckRequest = struct {
    method: std.http.Method,
    url: []const u8,
    headers: []const http.Header,
    body: []const u8,
};

/// The transport applies a deadline, disables redirects and caps the response body.
/// Request fields are borrowed for the call. The response body lives in the provided
/// invocation arena or in storage borrowed for the duration of the exchange.
pub const CheckTokenFn = *const fn (
    *anyopaque,
    Allocator,
    *const TokenCheckRequest,
) TransportError!TokenCheckResponse;

pub const TokenCheckResponse = struct {
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
    check_token: CheckTokenFn,
) Error![]const u8 {
    const response = try check(arena, credentials, context, check_token);
    switch (response.status) {
        .ok => {},
        .not_found => return error.Unauthorized,
        .unauthorized => return error.InternalFailure,
        // GitHub can use 403 or 429 for rate limiting and 422 for abuse throttling.
        else => return error.Unavailable,
    }
    if (response.body.len > token_check_body_size_max) return error.Unavailable;
    const identity = std.json.parseFromSliceLeaky(IdentityResponse, arena, response.body, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.InternalFailure,
        else => error.Unavailable,
    };
    if (!std.mem.eql(u8, identity.app.client_id, credentials.client_id)) {
        return error.Unauthorized;
    }
    std.debug.assert(identity.user.id.value > 0);
    return std.fmt.allocPrint(arena, "github:{d}", .{identity.user.id.value}) catch {
        return error.InternalFailure;
    };
}

fn check(
    arena: Allocator,
    credentials: *const Credentials,
    context: *anyopaque,
    check_token: CheckTokenFn,
) Error!TokenCheckResponse {
    std.debug.assert(credentials.access_token.bytes.len > 0);
    std.debug.assert(credentials.access_token.bytes.len <= access_token_size_max);
    const client_id = credentials.client_id;
    if (client_id.len == 0 or client_id.len > client_id_size_max) return error.InternalFailure;
    if (std.mem.eql(u8, client_id, ".") or std.mem.eql(u8, client_id, "..")) {
        return error.InternalFailure;
    }
    for (client_id) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        if (std.mem.indexOfScalar(u8, "-._", byte) == null) return error.InternalFailure;
    }
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
