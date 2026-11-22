const std = @import("std");

pub const navigation_size_max = 8192;

pub const Header = struct {
    key: []const u8,
    value: []const u8,
};

/// Request fields and body bytes are borrowed for the duration of the handler call.
pub const HttpRequest = struct {
    method: ?std.http.Method = null,
    path: ?[]const u8 = null,
    raw_query: []const u8 = "",
    headers: []const Header = &.{},
    cookies: []const []const u8 = &.{},
    body: Body = .empty,

    pub const Body = union(enum) {
        empty,
        bytes: []const u8,
        deferred: struct {
            context: *anyopaque,
            // The transport can identify a zero-byte body without decoding it.
            // A malformed body encoding counts as nonempty.
            is_empty: bool,
            // Bytes remain valid through the handler call. Storage uses the supplied
            // allocator or the transport request owner; original bytes are preserved.
            read_fn: *const fn (*anyopaque, std.mem.Allocator) anyerror!?[]const u8,
        },
    };

    pub fn body_is_empty(request: *const HttpRequest) bool {
        return switch (request.body) {
            .empty => true,
            .bytes => |bytes| bytes.len == 0,
            .deferred => |reader| reader.is_empty,
        };
    }

    pub fn read_body(request: *const HttpRequest, arena: std.mem.Allocator) !?[]const u8 {
        return switch (request.body) {
            .empty => null,
            .bytes => |bytes| bytes,
            .deferred => |reader| reader.read_fn(reader.context, arena),
        };
    }
};

/// Headers are borrowed unless backed by headers_arena. An allocated body remains
/// owned until deinit, after encoding.
pub const HttpResponse = struct {
    status: std.http.Status,
    headers: []const Header,
    cookies: []const []const u8 = &.{},
    body: []const u8,
    body_allocator: ?std.mem.Allocator = null,
    headers_arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(response: *HttpResponse) void {
        if (response.body_allocator) |allocator| allocator.free(response.body);
        if (response.headers_arena) |*arena| arena.deinit();
        response.* = undefined;
    }
};
