//! Test-owned observations survive the runtime's invocation arena resets.
const std = @import("std");
const lambda = @import("aws-lambda");
pub const Tester = lambda.Tester;

pub const Observations = struct {
    arena: std.heap.ArenaAllocator = .init(std.testing.allocator),
    entries: [8]Entry = undefined,
    count: usize = 0,

    const Entry = struct {
        request_id: []const u8,
        request_trace: []const u8,
        environment_trace: []const u8,
        invoked_arn: []const u8,
        deadline_ms: u64,
    };

    pub fn deinit(self: *Observations) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn capture(self: *Observations, ctx: lambda.Context) !void {
        std.debug.assert(self.count < self.entries.len);
        const allocator = self.arena.allocator();
        self.entries[self.count] = .{
            .request_id = try allocator.dupe(u8, ctx.request.id),
            .request_trace = try allocator.dupe(u8, ctx.request.xray_trace),
            .environment_trace = try allocator.dupe(u8, ctx.env("_X_AMZN_TRACE_ID") orelse ""),
            .invoked_arn = try allocator.dupe(u8, ctx.request.invoked_arn),
            .deadline_ms = ctx.request.deadline_ms,
        };
        self.count += 1;
    }
};

/// Observe metadata at the real private handler boundary without production hooks.
pub fn run(
    tester: *Tester,
    seen: *Observations,
    options: struct { awake_ns: ?i96 = null },
    comptime application_handler: anytype,
) void {
    const Runner = struct {
        var observations: ?*Observations = null;
        var awake_ns: ?i96 = null;
        var original_now: @FieldType(std.Io.VTable, "now") = undefined;

        fn invoke(ctx: lambda.Context, event: []const u8) ![]const u8 {
            try observations.?.capture(ctx);
            if (awake_ns == null) return application_handler(ctx, event);
            // Freeze only the handler's cache clock; runtime I/O and token
            // authentication still use their real clocks.
            var vtable = ctx.io.vtable.*;
            original_now = vtable.now;
            vtable.now = now;
            var fixed_ctx = ctx;
            fixed_ctx.io.vtable = &vtable;
            return application_handler(fixed_ctx, event);
        }

        fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
            if (clock == .awake) return .{ .nanoseconds = awake_ns.? };
            return original_now(userdata, clock);
        }
    };
    std.debug.assert(Runner.observations == null);
    std.debug.assert(tester.script.len <= seen.entries.len);
    Runner.observations = seen;
    defer Runner.observations = null;
    Runner.awake_ns = options.awake_ns;
    defer Runner.awake_ns = null;
    lambda.handle(tester.processInit(), Runner.invoke, .{});
}

pub fn expect_protocol(tester: *Tester, seen: *const Observations) !void {
    try tester.expectPostCount(tester.script.len);
    try std.testing.expectEqual(tester.script.len, seen.count);
    for (tester.script, seen.entries[0..seen.count], 0..) |event, entry, index| {
        try std.testing.expectEqualStrings(event.request_id, entry.request_id);
        try std.testing.expectEqualStrings(event.xray_trace, entry.request_trace);
        try std.testing.expectEqualStrings(event.xray_trace, entry.environment_trace);
        try std.testing.expectEqualStrings(event.invoked_arn, entry.invoked_arn);
        try std.testing.expectEqual(event.deadline_ms, entry.deadline_ms);
        const post = try tester.post(index);
        if (event.invocation_id.len > 0) {
            try std.testing.expectEqualStrings(
                event.invocation_id,
                post.header("Lambda-Runtime-Invocation-Id") orelse return error.MissingInvocationID,
            );
        } else {
            try std.testing.expectEqual(null, post.header("Lambda-Runtime-Invocation-Id"));
        }
    }
}

pub fn http_body(
    allocator: std.mem.Allocator,
    tester: *Tester,
    index: usize,
    status_code: u16,
) !std.json.Value {
    const post = try tester.post(index);
    const envelope = try std.json.parseFromSliceLeaky(std.json.Value, allocator, post.body, .{});
    try std.testing.expectEqual(status_code, envelope.object.get("statusCode").?.integer);
    try std.testing.expectEqualStrings(
        "application/json",
        envelope.object.get("headers").?.object.get("Content-Type").?.string,
    );
    return std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        envelope.object.get("body").?.string,
        .{},
    );
}
