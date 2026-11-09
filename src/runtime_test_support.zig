//! Test-owned observations survive the runtime's invocation arena resets.
const std = @import("std");
const lambda = @import("aws-lambda");
pub const Tester = lambda.Tester;

/// Own the fake Runtime API and observations independently of invocation arenas.
/// Keep the fixture in place after init(), since Tester holds pointers to itself.
pub const Fixture = struct {
    seen: Observations = .{},
    tester: Tester = undefined,
    tester_initialized: bool = false,

    pub fn allocator(self: *Fixture) std.mem.Allocator {
        return self.seen.arena.allocator();
    }

    pub fn init(self: *Fixture, script: []const Tester.Event) !void {
        std.debug.assert(!self.tester_initialized);
        try self.tester.init(std.testing.allocator, script);
        self.tester_initialized = true;
    }

    pub fn deinit(self: *Fixture) void {
        if (self.tester_initialized) self.tester.deinit();
        self.seen.deinit();
        self.* = undefined;
    }

    pub fn run_handler(
        self: *Fixture,
        options: RunOptions,
        comptime application_handler: anytype,
    ) !void {
        std.debug.assert(self.tester_initialized);
        run(&self.tester, &self.seen, options, application_handler);
        try expect_protocol(&self.tester, &self.seen);
    }
};

/// Build one SQS delivery using the real event parser's required fields.
pub fn sqs_event(
    allocator: std.mem.Allocator,
    message_id: []const u8,
    body: []const u8,
) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .Records = &.{.{
            .messageId = message_id,
            .receiptHandle = "receipt",
            .body = body,
            .attributes = std.json.Value{ .object = .empty },
            .messageAttributes = std.json.Value{ .object = .empty },
            .md5OfBody = "md5",
            .eventSource = "aws:sqs",
            .eventSourceARN = "arn",
            .awsRegion = "ca-central-1",
        }},
    }, .{});
}

/// Preserve source ordering and stable message IDs for partial-batch assertions.
pub fn sqs_batch_event(allocator: std.mem.Allocator, bodies: []const []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"Records\":[");
    for (bodies, 0..) |body, index| {
        if (index > 0) try output.writer.writeByte(',');
        try output.writer.print(
            "{{\"messageId\":\"message-{d}\",\"receiptHandle\":\"receipt-{d}\",\"body\":",
            .{ index, index },
        );
        try std.json.Stringify.value(body, .{}, &output.writer);
        try output.writer.writeAll(
            ",\"attributes\":{},\"messageAttributes\":{}," ++
                "\"eventSource\":\"aws:sqs\",\"eventSourceARN\":\"arn\"," ++
                "\"awsRegion\":\"ca-central-1\"}",
        );
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

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

pub const RunOptions = struct { awake_ns: ?i96 = null };

/// Observe metadata at the real private handler boundary without production hooks.
pub fn run(
    tester: *Tester,
    seen: *Observations,
    options: RunOptions,
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
