//! Standalone reproducer for HostName.connect exhausting its async worker budget.
//! Only lookup and socket operations are simulated; scheduling uses Io.Threaded.
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const assert = std.debug.assert;

comptime {
    if (@import("builtin").single_threaded) {
        @compileError("the reproducer requires -fno-single-threaded");
    }
}

test "HostName.connect with zero async workers" {
    try reproduce(.nothing);
}

test "HostName.connect with one async worker" {
    try reproduce(.limited(1));
}

test "HostName.connect with two async workers (control)" {
    try reproduce(.limited(2));
}

fn reproduce(async_limit: Io.Limit) !void {
    var fixture: ConnectFixture = undefined;
    fixture.init(async_limit);
    defer fixture.threaded.deinit();
    const io = fixture.io();

    const host = try net.HostName.init("dual.test");
    {
        const stream = try host.connect(io, 8080, .{ .mode = .stream });
        defer stream.close(io);
        try std.testing.expectEqualDeep(
            net.IpAddress{ .ip4 = .loopback(8080) },
            stream.socket.address,
        );
    }
    try std.testing.expectEqual(1, fixture.closed_streams.load(.acquire));

    // HostName.connect must finish without waiting for the pending address to time out.
    // Cancellation may prevent that task from starting at all.
    switch (fixture.pending_state.load(.acquire)) {
        .not_started, .canceled => {},
        .pending => return error.PendingConnectionNotCanceled,
        .expired => return error.HostNameConnectStalled,
    }
}

const ConnectFixture = struct {
    threaded: Io.Threaded,
    vtable: Io.VTable,
    pending_state: std.atomic.Value(PendingState) = .init(.not_started),
    closed_streams: std.atomic.Value(usize) = .init(0),

    const PendingState = enum(u8) { not_started, pending, canceled, expired };
    const pending_wait_ms = 1_000;

    fn init(fixture: *ConnectFixture, async_limit: Io.Limit) void {
        fixture.* = .{
            .threaded = .init(std.testing.allocator, .{
                .async_limit = async_limit,
                .concurrent_limit = .unlimited,
            }),
            .vtable = undefined,
        };
        fixture.vtable = fixture.threaded.io().vtable.*;
        fixture.vtable.netLookup = net_lookup;
        fixture.vtable.netConnectIp = net_connect_ip;
        fixture.vtable.netClose = net_close;
    }

    fn io(fixture: *ConnectFixture) Io {
        // Unchanged vtable functions must still receive the real backend.
        return .{ .userdata = &fixture.threaded, .vtable = &fixture.vtable };
    }

    fn from_userdata(userdata: ?*anyopaque) *ConnectFixture {
        const threaded: *Io.Threaded = @ptrCast(@alignCast(userdata));
        return @fieldParentPtr("threaded", threaded);
    }

    fn net_lookup(
        userdata: ?*anyopaque,
        host: net.HostName,
        resolved: *Io.Queue(net.HostName.LookupResult),
        options: net.HostName.LookupOptions,
    ) net.HostName.LookupError!void {
        const fixture = from_userdata(userdata);
        const fixture_io = fixture.io();
        defer resolved.close(fixture_io);
        assert(std.mem.eql(u8, host.bytes, "dual.test"));

        const results = [_]net.HostName.LookupResult{
            .{ .address = .{ .ip4 = .{
                .bytes = .{ 192, 0, 2, 1 },
                .port = options.port,
            } } },
            .{ .address = .{ .ip4 = .loopback(options.port) } },
            .{ .canonical_name = host },
        };
        resolved.putAll(fixture_io, &results) catch |err| switch (err) {
            error.Canceled => |e| return e,
            error.Closed => unreachable,
        };
    }

    fn net_connect_ip(
        userdata: ?*anyopaque,
        address: *const net.IpAddress,
        options: net.IpAddress.ConnectOptions,
    ) net.IpAddress.ConnectError!net.Socket {
        const fixture = from_userdata(userdata);
        assert(options.mode == .stream);
        assert(address.* == .ip4);

        if (address.ip4.bytes[0] == 192) {
            fixture.pending_state.store(.pending, .release);
            // A finite injected wait makes stock Zig fail instead of hanging.
            // This does not use the unimplemented POSIX ConnectOptions.timeout.
            fixture.io().sleep(.fromMilliseconds(pending_wait_ms), .awake) catch |err| {
                fixture.pending_state.store(.canceled, .release);
                return err;
            };
            fixture.pending_state.store(.expired, .release);
            return error.Timeout;
        }
        assert(std.mem.eql(u8, &address.ip4.bytes, &.{ 127, 0, 0, 1 }));
        return .{
            .handle = switch (@typeInfo(net.Socket.Handle)) {
                .pointer => @ptrCast(fixture),
                .int => 42,
                else => @compileError("unsupported socket handle type"),
            },
            .address = address.*,
        };
    }

    fn net_close(userdata: ?*anyopaque, sockets: []const net.Socket) void {
        const fixture = from_userdata(userdata);
        assert(sockets.len == 1);
        _ = fixture.closed_streams.fetchAdd(sockets.len, .release);
    }
};
