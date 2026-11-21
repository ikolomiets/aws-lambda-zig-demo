const std = @import("std");
const paseto = @import("paseto");

const lifetime_seconds_default = 8 * 60 * 60;

pub const Options = struct {
    subject: []const u8,
    now_seconds: i64,
    signing_key_base64: []const u8,
    public_key_base64: []const u8,
};

pub fn issue(
    allocator: std.mem.Allocator,
    random: std.Random,
    options: *const Options,
) error{InternalFailure}![]u8 {
    var secret_key = paseto.decodePrivateKey(options.signing_key_base64) catch {
        return error.InternalFailure;
    };
    defer paseto.wipeSecretKey(&secret_key);
    const expected_key = paseto.decodePublicKey(options.public_key_base64) catch {
        return error.InternalFailure;
    };
    if (!std.mem.eql(u8, &expected_key.toBytes(), &secret_key.publicKeyBytes())) {
        return error.InternalFailure;
    }

    const token = paseto.issue(allocator, random, &secret_key, .{
        .subject = options.subject,
        .now = options.now_seconds,
        .ttl_seconds = lifetime_seconds_default,
    }) catch return error.InternalFailure;
    defer {
        std.crypto.secureZero(u8, token);
        allocator.free(token);
    }
    return std.json.Stringify.valueAlloc(allocator, .{
        .access_token = token,
        .token_type = "Bearer",
        .expires_in = @as(i64, lifetime_seconds_default),
    }, .{}) catch return error.InternalFailure;
}
