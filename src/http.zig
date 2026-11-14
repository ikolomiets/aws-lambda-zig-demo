const std = @import("std");

pub const Header = struct {
    key: []const u8,
    value: []const u8,
};

/// Request fields and body bytes are borrowed for the duration of the handler call.
pub const HttpRequest = struct {
    method: ?std.http.Method = null,
    path: ?[]const u8 = null,
    headers: []const Header = &.{},
    body: Body = .empty,

    pub const Body = union(enum) {
        empty,
        bytes: []const u8,
        deferred: struct {
            context: *anyopaque,
            // The caller owns returned bytes through the handler call. Any allocation
            // uses the supplied request arena; the accessor preserves original bytes.
            read_fn: *const fn (*anyopaque, std.mem.Allocator) anyerror!?[]const u8,
        },
    };

    pub fn read_body(request: *const HttpRequest, arena: std.mem.Allocator) !?[]const u8 {
        return switch (request.body) {
            .empty => null,
            .bytes => |bytes| bytes,
            .deferred => |reader| reader.read_fn(reader.context, arena),
        };
    }
};

/// Headers are borrowed. An allocated body remains owned until deinit, after encoding.
pub const HttpResponse = struct {
    status: std.http.Status,
    headers: []const Header,
    body: []const u8,
    body_allocator: ?std.mem.Allocator = null,

    pub fn deinit(response: *HttpResponse) void {
        if (response.body_allocator) |allocator| allocator.free(response.body);
        response.* = undefined;
    }
};
