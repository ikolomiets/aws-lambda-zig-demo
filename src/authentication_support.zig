//! Configuration, dependencies, and helpers shared by authentication flows.
const std = @import("std");
const github = @import("github_identity");
const http = @import("http");
const pending_sign_in = @import("pending_sign_in");

const Allocator = std.mem.Allocator;
pub const sign_in_entropy_size = 32;

pub const Config = struct {
    github_client_id: []const u8,
    paseto_public_key: []const u8,
    github_oauth_callback_url: []const u8 = "",
    browser_redirect_uris: []const u8 = "",
};

pub const Secret = enum { github_client_secret, paseto_signing_key };
pub const SecretError = error{ MissingSecret, InvalidSecret, Unavailable, OutOfMemory };

pub const Dependencies = struct {
    context: *anyopaque,
    random: std.Random,
    now_ms: *const fn (*anyopaque) i64,
    sign_in_entropy_fn: *const fn (*anyopaque, *[sign_in_entropy_size]u8) error{Unavailable}!void,
    // The secret reader gives the invocation ownership of mutable secret bytes.
    read_secret_fn: *const fn (*anyopaque, Allocator, Secret) SecretError![]u8,
    send_github_fn: github.SendFn,
    store: pending_sign_in.Store,
};

pub const AuthenticationError = error{
    BadRequest,
    Unauthorized,
    InternalFailure,
    Unavailable,
    Denied,
    Gone,
};
pub const json_headers: []const http.Header = &.{
    .{ .key = "Content-Type", .value = "application/json" },
    .{ .key = "Cache-Control", .value = "no-store" },
};

pub fn json_response(allocator: Allocator, status: std.http.Status, body: []u8) http.HttpResponse {
    return .{
        .status = status,
        .headers = json_headers,
        .body = body,
        .body_allocator = allocator,
    };
}

pub fn sign_in_code(dependencies: *const Dependencies) AuthenticationError!pending_sign_in.Code {
    var random_bytes: [sign_in_entropy_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &random_bytes);
    try dependencies.sign_in_entropy_fn(dependencies.context, &random_bytes);
    return .{ .hex = std.fmt.bytesToHex(random_bytes, .lower) };
}

pub fn finish_grant(
    arena: Allocator,
    dependencies: *const Dependencies,
    key: *const pending_sign_in.Key,
    expires_at_ms: i64,
    transition: @FieldType(pending_sign_in.Change, "transition"),
) AuthenticationError!i64 {
    std.debug.assert(transition != .schedule);
    const store = &dependencies.store;
    const now_ms = dependencies.now_ms(dependencies.context);
    if (now_ms >= expires_at_ms) return error.Gone;
    if (!try store.change(store.context, arena, key, &.{
        .now_ms = now_ms,
        .transition = transition,
    })) return error.Gone;
    const finished_ms = dependencies.now_ms(dependencies.context);
    if (finished_ms >= expires_at_ms) return error.Gone;
    return finished_ms;
}

pub fn read_secret(
    arena: Allocator,
    dependencies: *const Dependencies,
    secret: Secret,
) error{ Unavailable, InternalFailure }![]u8 {
    const bytes = dependencies.read_secret_fn(dependencies.context, arena, secret);
    return bytes catch |err| switch (err) {
        error.Unavailable => error.Unavailable,
        error.MissingSecret, error.InvalidSecret, error.OutOfMemory => error.InternalFailure,
    };
}
