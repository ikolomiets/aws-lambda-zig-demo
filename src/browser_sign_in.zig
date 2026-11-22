//! GitHub browser sign-in from authorization through redemption.
const std = @import("std");
const http = @import("http");
const pending = @import("pending_sign_in");
const github = @import("github_identity");
const authentication = @import("authentication_support.zig");
const token_issuer = @import("token_issuer.zig");

const Allocator = std.mem.Allocator;
const Error = error{ BadRequest, InternalFailure };
const cookie_prefix = "__Host-operations-github-";
const cookie_suffix = "; Path=/; Secure; HttpOnly; SameSite=Lax";
const uri_size_max = 2048;
const state_size_max = 256;
const start_lifetime_ms = 600_000;
const redeem_lifetime_ms = 60_000;
pub const redeem_body_size_max = 4096;

pub const Route = enum { authorize, callback, redeem };

pub fn match_route(method: ?std.http.Method, path: []const u8) ?Route {
    if (method == .GET) {
        if (std.mem.eql(u8, path, "/auth/github/authorize")) return .authorize;
        if (std.mem.eql(u8, path, "/auth/github/callback")) return .callback;
    }
    if (method == .POST and std.mem.eql(u8, path, "/auth/github/redeem")) return .redeem;
    return null;
}

/// Handles a request classified by match_route.
pub fn handle(
    allocator: Allocator,
    route: Route,
    request: *const http.HttpRequest,
    config: *const authentication.Config,
    dependencies: *const authentication.Dependencies,
) authentication.AuthenticationError!http.HttpResponse {
    return switch (route) {
        .authorize => authorize(allocator, request, config, dependencies),
        .callback => handle_callback(allocator, request, config, dependencies),
        .redeem => redeem(allocator, request, config, dependencies),
    };
}

fn authorize(
    allocator: Allocator,
    request: *const http.HttpRequest,
    config: *const authentication.Config,
    dependencies: *const authentication.Dependencies,
) authentication.AuthenticationError!http.HttpResponse {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    if (!request.body_is_empty()) return error.BadRequest;
    const app = try read_authorize(arena, request.raw_query);
    try require_registration(arena, .{
        .allowlist_json = config.browser_redirect_uris,
        .redirect_uri = app.redirect_uri,
    });
    if (!valid_github_callback(config.github_oauth_callback_url)) {
        return error.InternalFailure;
    }
    const started_ms = dependencies.now_ms(dependencies.context);
    const state = try authentication.sign_in_code(dependencies);
    var binding = try authentication.sign_in_code(dependencies);
    defer std.crypto.secureZero(u8, &binding.hex);
    var verifier = try authentication.sign_in_code(dependencies);
    defer std.crypto.secureZero(u8, &verifier.hex);
    const key = pending.key_for(&state);
    const binding_key = pending.key_for(&binding);
    const challenge = pkce_challenge(&verifier.hex);
    const location = try github.authorize(arena, &.{
        .client_id = config.github_client_id,
        .redirect_uri = config.github_oauth_callback_url,
        .state = &state.hex,
        .challenge = &challenge,
    });
    var response = try redirect_response(allocator, location, .{
        .state = &state,
        .binding = &binding,
    });
    errdefer response.deinit();
    const store = &dependencies.store;
    try store.create(store.context, arena, &key, &.{
        .expires_at_ms = started_ms + start_lifetime_ms,
        .state = .{ .browser_pending = .{
            .redirect_uri = app.redirect_uri,
            .app_state = app.state,
            .app_challenge = app.challenge,
            .upstream_verifier = &verifier.hex,
            .browser_binding = &binding_key.digest,
        } },
    });
    return response;
}

fn handle_callback(
    allocator: Allocator,
    request: *const http.HttpRequest,
    config: *const authentication.Config,
    dependencies: *const authentication.Dependencies,
) authentication.AuthenticationError!http.HttpResponse {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    if (!request.body_is_empty()) return error.BadRequest;
    const callback = try read_callback(arena, request.raw_query);
    const binding = try read_browser_binding(request, &callback.state);
    const key = pending.key_for(&callback.state);
    const store = &dependencies.store;
    const grant = try store.read(store.context, arena, &key) orelse return error.BadRequest;
    if (dependencies.now_ms(dependencies.context) >= grant.expires_at_ms) return error.Gone;
    if (grant.state != .browser_pending) return error.Gone;
    const app = &grant.state.browser_pending;
    if (app.browser_binding.len != binding.digest.len) return error.InternalFailure;
    const saved_binding = app.browser_binding[0..binding.digest.len].*;
    if (!std.crypto.timing_safe.eql(@TypeOf(binding.digest), binding.digest, saved_binding)) {
        return error.BadRequest;
    }
    try require_registration(arena, .{
        .allowlist_json = config.browser_redirect_uris,
        .redirect_uri = app.redirect_uri,
    });
    const action: pending.BrowserFinish =
        if (callback.result == .denied) .deny else .claim;
    // GitHub's authorization code is single-use. Only one bound callback may send it upstream.
    _ = try authentication.finish_grant(arena, dependencies, &key, grant.expires_at_ms, .{
        .browser_finish = action,
    });
    return switch (callback.result) {
        .denied => redirect_response(
            allocator,
            try app_location(arena, app, .denied),
            .{ .state = &callback.state },
        ),
        .code => |code| complete_callback(allocator, arena, config, dependencies, &.{
            .state = &callback.state,
            .app = app,
            .code = code,
            .expires_at_ms = grant.expires_at_ms,
        }),
    };
}

const BrowserApproval = struct {
    state: *const pending.Code,
    app: *const pending.BrowserPending,
    code: []const u8,
    expires_at_ms: i64,
};

fn complete_callback(
    allocator: Allocator,
    arena: Allocator,
    config: *const authentication.Config,
    dependencies: *const authentication.Dependencies,
    approval: *const BrowserApproval,
) authentication.AuthenticationError!http.HttpResponse {
    if (!valid_github_callback(config.github_oauth_callback_url)) {
        return error.InternalFailure;
    }
    if (!valid_verifier(approval.app.upstream_verifier)) return error.InternalFailure;
    const client_secret = try authentication.read_secret(
        arena,
        dependencies,
        .github_client_secret,
    );
    defer std.crypto.secureZero(u8, client_secret);
    const provider_token = github.exchange_code(arena, &.{
        .client_id = config.github_client_id,
        .client_secret = client_secret,
        .code = approval.code,
        .redirect_uri = config.github_oauth_callback_url,
        .verifier = approval.app.upstream_verifier,
    }, dependencies.context, dependencies.send_github_fn) catch |err| switch (err) {
        error.Unauthorized => return error.BadRequest,
        else => |failure| return failure,
    };
    if (std.mem.startsWith(u8, provider_token.bytes, "v4.public.")) return error.Unavailable;
    const tenant = github.resolve_tenant(arena, &.{
        .client_id = config.github_client_id,
        .client_secret = client_secret,
        .access_token = provider_token,
    }, dependencies.context, dependencies.send_github_fn) catch |err| switch (err) {
        error.Unauthorized => return error.Unavailable,
        else => |failure| return failure,
    };
    const completed_ms = dependencies.now_ms(dependencies.context);
    if (completed_ms >= approval.expires_at_ms) return error.Gone;
    const expires_at_ms = @min(approval.expires_at_ms, completed_ms + redeem_lifetime_ms);
    var code = try authentication.sign_in_code(dependencies);
    defer std.crypto.secureZero(u8, &code.hex);
    const key = pending.key_for(&code);
    const location = try app_location(arena, approval.app, .{ .approved = &code });
    var response = try redirect_response(allocator, location, .{ .state = approval.state });
    errdefer response.deinit();
    const store = &dependencies.store;
    try store.create(store.context, arena, &key, &.{
        .expires_at_ms = expires_at_ms,
        .state = .{ .browser_approved = .{
            .redirect_uri = approval.app.redirect_uri,
            .app_challenge = approval.app.app_challenge,
            .tenant = tenant,
        } },
    });
    if (dependencies.now_ms(dependencies.context) >= expires_at_ms) return error.Gone;
    return response;
}

fn redeem(
    allocator: Allocator,
    request: *const http.HttpRequest,
    config: *const authentication.Config,
    dependencies: *const authentication.Dependencies,
) authentication.AuthenticationError!http.HttpResponse {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const redemption = try read_redemption(arena, request);
    try require_registration(arena, .{
        .allowlist_json = config.browser_redirect_uris,
        .redirect_uri = redemption.redirect_uri,
    });
    const store = &dependencies.store;
    const grant = try store.read(store.context, arena, &redemption.key) orelse return error.Gone;
    if (dependencies.now_ms(dependencies.context) >= grant.expires_at_ms) return error.Gone;
    if (grant.state != .browser_approved) return error.Gone;
    const app = &grant.state.browser_approved;
    if (!std.mem.eql(u8, app.redirect_uri, redemption.redirect_uri)) return error.BadRequest;
    if (app.app_challenge.len != redemption.challenge.len) return error.InternalFailure;
    const saved_challenge = app.app_challenge[0..redemption.challenge.len].*;
    const matches = std.crypto.timing_safe.eql(
        @TypeOf(saved_challenge),
        redemption.challenge,
        saved_challenge,
    );
    if (!matches) {
        return error.BadRequest;
    }
    const signing_key = try authentication.read_secret(arena, dependencies, .paseto_signing_key);
    defer std.crypto.secureZero(u8, signing_key);
    const expires_at_ms = grant.expires_at_ms;
    const issued_at_ms = try authentication.finish_grant(
        arena,
        dependencies,
        &redemption.key,
        expires_at_ms,
        .{ .browser_finish = .redeem },
    );
    const body = try token_issuer.issue(allocator, dependencies.random, &.{
        .subject = app.tenant,
        .now_seconds = @divFloor(issued_at_ms, 1000),
        .signing_key_base64 = signing_key,
        .public_key_base64 = config.paseto_public_key,
    });
    return authentication.json_response(allocator, .ok, body);
}

const Registration = struct {
    redirect_uri: []const u8,
    state: []const u8,
    challenge: []const u8,
};

const Callback = struct {
    state: pending.Code,
    result: union(enum) { code: []const u8, denied },
};

const Redemption = struct {
    key: pending.Key,
    redirect_uri: []const u8,
    challenge: [pending.pkce_challenge_size]u8,
};

fn read_authorize(arena: Allocator, raw_query: []const u8) Error!Registration {
    const fields = try parse_query(struct {
        redirect_uri: ?[]const u8 = null,
        state: ?[]const u8 = null,
        code_challenge: ?[]const u8 = null,
        code_challenge_method: ?[]const u8 = null,
    }, arena, raw_query, .strict);
    const redirect_uri = fields.redirect_uri orelse return error.BadRequest;
    const state = fields.state orelse return error.BadRequest;
    const challenge = fields.code_challenge orelse return error.BadRequest;
    const method = fields.code_challenge_method orelse return error.BadRequest;
    if (!valid_https_uri(redirect_uri)) return error.BadRequest;
    if (state.len == 0 or state.len > state_size_max) return error.BadRequest;
    for (state) |byte| {
        if (byte < 0x20 or byte > 0x7e) return error.BadRequest;
    }
    if (!std.mem.eql(u8, method, "S256")) return error.BadRequest;
    if (challenge.len != pending.pkce_challenge_size) return error.BadRequest;
    var digest: [32]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(&digest, challenge) catch return error.BadRequest;
    return .{ .redirect_uri = redirect_uri, .state = state, .challenge = challenge };
}

fn require_registration(arena: Allocator, options: struct {
    allowlist_json: []const u8,
    redirect_uri: []const u8,
}) Error!void {
    if (options.allowlist_json.len == 0 or options.allowlist_json.len > 8192) {
        return error.InternalFailure;
    }
    const urls = std.json.parseFromSliceLeaky(
        []const []const u8,
        arena,
        options.allowlist_json,
        .{},
    ) catch return error.InternalFailure;
    if (urls.len == 0 or urls.len > 16) return error.InternalFailure;
    var found = false;
    for (urls) |url| {
        if (!valid_https_uri(url)) return error.InternalFailure;
        if (std.mem.indexOfScalar(u8, url, '?')) |index| {
            var pairs = std.mem.splitScalar(u8, url[index + 1 ..], '&');
            while (pairs.next()) |pair| {
                const end = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
                const name = decode(arena, pair[0..end]) catch return error.InternalFailure;
                for ([_][]const u8{ "code", "state", "error" }) |reserved| {
                    if (std.mem.eql(u8, name, reserved)) return error.InternalFailure;
                }
            }
        }
        if (std.mem.eql(u8, url, options.redirect_uri)) found = true;
    }
    if (!found) return error.BadRequest;
}

fn valid_github_callback(text: []const u8) bool {
    return valid_https_uri(text) and std.mem.indexOfScalar(u8, text, '?') == null;
}

fn valid_https_uri(text: []const u8) bool {
    const prefix = "https://";
    if (text.len < prefix.len or text.len > uri_size_max) return false;
    if (!std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix)) return false;
    for (text) |byte| {
        if (byte <= 0x20 or byte >= 0x7f or byte == '\\') return false;
    }
    const uri = std.Uri.parse(text) catch return false;
    const host = uri.host orelse return false;
    if (host.isEmpty() or uri.user != null or uri.password != null or uri.fragment != null) {
        return false;
    }
    // WHATWG browsers apply additional parsing to special-scheme hosts.
    // Canonical ASCII hosts keep registered and browser-parsed authorities aligned.
    for (host.percent_encoded) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, ".-[]:", byte) == null) {
            return false;
        }
    }
    return true;
}

fn pkce_challenge(verifier: []const u8) [pending.pkce_challenge_size]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    var encoded: [pending.pkce_challenge_size]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &digest);
    return encoded;
}

fn read_callback(arena: Allocator, raw_query: []const u8) Error!Callback {
    const fields = try parse_query(struct {
        state: ?[]const u8 = null,
        code: ?[]const u8 = null,
        @"error": ?[]const u8 = null,
    }, arena, raw_query, .ignore_extensions);
    const state = try read_code(fields.state orelse return error.BadRequest);
    if (fields.code) |code| {
        if (fields.@"error" != null or code.len == 0 or
            code.len > github.authorization_code_size_max)
        {
            return error.BadRequest;
        }
        for (code) |byte| {
            if (byte <= 0x20 or byte >= 0x7f) return error.BadRequest;
        }
        return .{ .state = state, .result = .{ .code = code } };
    }
    const failure = fields.@"error" orelse return error.BadRequest;
    if (!std.mem.eql(u8, failure, "access_denied")) return error.BadRequest;
    return .{ .state = state, .result = .denied };
}

fn read_browser_binding(
    request: *const http.HttpRequest,
    state: *const pending.Code,
) Error!pending.Key {
    var name: [cookie_prefix.len + @sizeOf(pending.Code)]u8 = undefined;
    @memcpy(name[0..cookie_prefix.len], cookie_prefix);
    @memcpy(name[cookie_prefix.len..], &state.hex);
    var found: ?pending.Code = null;
    defer if (found) |*binding| std.crypto.secureZero(u8, &binding.hex);
    var budget: usize = http.navigation_size_max;
    for (request.cookies) |field| {
        try find_binding(field, &name, &found, &budget);
    }
    for (request.headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.key, "Cookie")) continue;
        try find_binding(header.value, &name, &found, &budget);
    }
    return pending.key_for(&(found orelse return error.BadRequest));
}

fn find_binding(
    field: []const u8,
    name: []const u8,
    found: *?pending.Code,
    budget: *usize,
) Error!void {
    if (field.len >= budget.*) return error.BadRequest;
    budget.* -= field.len + 1;
    var pairs = std.mem.splitAny(u8, field, ";,");
    while (pairs.next()) |part| {
        const pair = std.mem.trim(u8, part, " \t");
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..equals], name)) continue;
        if (found.* != null) return error.BadRequest;
        found.* = try read_code(pair[equals + 1 ..]);
    }
}

fn read_redemption(arena: Allocator, request: *const http.HttpRequest) Error!Redemption {
    if (request.raw_query.len != 0) return error.BadRequest;
    const body = (request.read_body(arena) catch |err| switch (err) {
        error.OutOfMemory => return error.InternalFailure,
        else => return error.BadRequest,
    }) orelse return error.BadRequest;
    if (body.len > redeem_body_size_max) return error.BadRequest;
    const fields = std.json.parseFromSliceLeaky(struct {
        code: []const u8,
        redirect_uri: []const u8,
        code_verifier: []const u8,
    }, arena, body, .{
        .ignore_unknown_fields = false,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.InternalFailure,
        else => return error.BadRequest,
    };
    var code = try read_code(fields.code);
    defer std.crypto.secureZero(u8, &code.hex);
    if (!valid_verifier(fields.code_verifier)) return error.BadRequest;
    return .{
        .key = pending.key_for(&code),
        .redirect_uri = fields.redirect_uri,
        .challenge = pkce_challenge(fields.code_verifier),
    };
}

fn valid_verifier(verifier: []const u8) bool {
    if (verifier.len < 43 or verifier.len > 128) return false;
    for (verifier) |byte| {
        if (!unreserved(byte)) return false;
    }
    return true;
}

fn read_code(text: []const u8) Error!pending.Code {
    return pending.parse_code(text) catch error.BadRequest;
}

fn unreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~", byte) != null;
}

fn parse_query(
    comptime Fields: type,
    arena: Allocator,
    raw_query: []const u8,
    comptime mode: enum { strict, ignore_extensions },
) Error!Fields {
    if (raw_query.len == 0 or raw_query.len > http.navigation_size_max) return error.BadRequest;
    var result: Fields = .{};
    var pairs = std.mem.splitScalar(u8, raw_query, '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const name = try decode(arena, pair[0..equals]);
        var matched = false;
        inline for (comptime std.meta.fieldNames(Fields)) |field| {
            if (std.mem.eql(u8, name, field)) {
                const value = &@field(result, field);
                if (value.* != null) return error.BadRequest;
                value.* = if (equals == pair.len) "" else try decode(arena, pair[equals + 1 ..]);
                matched = true;
            }
        }
        if (mode == .strict and !matched) return error.BadRequest;
    }
    return result;
}

fn decode(arena: Allocator, bytes: []const u8) Error![]const u8 {
    const output = arena.alloc(u8, bytes.len) catch return error.InternalFailure;
    var index: usize = 0;
    var length: usize = 0;
    while (index < bytes.len) : (index += 1) {
        output[length] = switch (bytes[index]) {
            '%' => decoded: {
                if (bytes.len - index < 3) return error.BadRequest;
                const hi = std.fmt.charToDigit(bytes[index + 1], 16) catch return error.BadRequest;
                const lo = std.fmt.charToDigit(bytes[index + 2], 16) catch return error.BadRequest;
                index += 2;
                break :decoded hi * 16 + lo;
            },
            '+' => ' ',
            else => bytes[index],
        };
        length += 1;
    }
    return output[0..length];
}

fn redirect_response(
    allocator: Allocator,
    location: []const u8,
    cookie: struct {
        state: *const pending.Code,
        // Omitting the binding clears the cookie for this state.
        binding: ?*const pending.Code = null,
    },
) Error!http.HttpResponse {
    var owned = std.heap.ArenaAllocator.init(allocator);
    errdefer owned.deinit();
    const arena = owned.allocator();
    const location_owned = arena.dupe(u8, location) catch return error.InternalFailure;
    const headers = arena.dupe(http.Header, &.{
        .{ .key = "Cache-Control", .value = "no-store" },
        .{ .key = "Referrer-Policy", .value = "no-referrer" },
        .{ .key = "Location", .value = location_owned },
    }) catch return error.InternalFailure;
    const cookies = arena.alloc([]const u8, 1) catch return error.InternalFailure;
    const cookie_format = cookie_prefix ++ "{s}={s}; Max-Age={d}" ++ cookie_suffix;
    const max_age: u32 = if (cookie.binding != null) @divExact(start_lifetime_ms, 1000) else 0;
    cookies[0] = std.fmt.allocPrint(arena, cookie_format, .{
        &cookie.state.hex, if (cookie.binding) |value| &value.hex else "", max_age,
    }) catch return error.InternalFailure;
    return .{
        .status = .found,
        .headers = headers,
        .cookies = cookies,
        .body = "",
        .headers_arena = owned,
    };
}

fn app_location(
    arena: Allocator,
    app: *const pending.BrowserPending,
    outcome: union(enum) { approved: *const pending.Code, denied },
) Error![]const u8 {
    var buffer = std.Io.Writer.Allocating.init(arena);
    errdefer buffer.deinit();
    const writer = &buffer.writer;
    writer.writeAll(app.redirect_uri) catch return error.InternalFailure;
    const has_query = std.mem.indexOfScalar(u8, app.redirect_uri, '?') != null;
    writer.writeByte(if (has_query) '&' else '?') catch return error.InternalFailure;
    (switch (outcome) {
        .approved => |value| writer.print("code={s}", .{&value.hex}),
        .denied => writer.writeAll("error=access_denied"),
    }) catch return error.InternalFailure;
    writer.writeAll("&state=") catch return error.InternalFailure;
    std.Uri.Component.percentEncode(writer, app.app_state, unreserved) catch
        return error.InternalFailure;
    return buffer.written();
}
