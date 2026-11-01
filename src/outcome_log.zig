const std = @import("std");
const builtin = @import("builtin");

pub const size_max = 8 * 1024;
pub const Level = enum { INFO, WARN, ERROR };
pub const Component = enum {
    intake,
    seat_submission,
    seat_completion,
    tigerbeetle_executor,
    tigerbeetle_completion,
};
pub const Observer = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, []const u8) anyerror!void,
};
pub const Logger = struct {
    request_id: ?[]const u8 = null,
    observer: ?Observer = null,
};
pub const NativeCount = struct { family: []const u8, code: u32, count: u32 };
pub const Record = struct {
    schema_version: u8 = 1,
    level: Level = .ERROR,
    component: Component,
    stage: []const u8 = "invocation",
    outcome: []const u8 = "retry",
    lambda_request_id: ?[]const u8 = null,
    operation_id: ?[]const u8 = null,
    sqs_message_id: ?[]const u8 = null,
    command: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    failure_code: ?[]const u8 = null,
    result_type: ?[]const u8 = null,
    http_status: ?u16 = null,
    service_code: ?[]const u8 = null,
    service_http_status: ?u16 = null,
    service_request_id: ?[]const u8 = null,
    transport_error: ?[]const u8 = null,
    diagnostic_code: ?[]const u8 = null,
    native_status_counts: ?[]const NativeCount = null,
};

/// Invocation and record metadata stay on the caller's stack, never in runtime globals.
pub const Context = struct {
    logger: Logger,
    record: Record,
    uuid_buffer: [36]u8 = undefined,

    pub fn init(logger: Logger, component: Component) Context {
        return .{ .logger = logger, .record = .{
            .component = component,
            .lambda_request_id = logger.request_id,
        } };
    }

    pub fn identify(self: *Context, id: u128) void {
        const hex = std.fmt.bytesToHex(std.mem.toBytes(std.mem.nativeToBig(u128, id)), .lower);
        self.uuid_buffer = (hex[0..8].* ++ "-" ++ hex[8..12].* ++ "-" ++
            hex[12..16].* ++ "-" ++ hex[16..20].* ++ "-" ++ hex[20..32].*).*;
        self.record.operation_id = &self.uuid_buffer;
    }

    pub fn finish(
        self: *Context,
        level: Level,
        stage: []const u8,
        outcome: []const u8,
        reason: ?[]const u8,
    ) void {
        self.record.level = level;
        self.record.stage = stage;
        self.record.outcome = outcome;
        self.record.reason = reason;
    }

    pub fn emit(self: *const Context) void {
        emit_record(&self.logger, &self.record);
    }

    /// SDK diagnostics are borrowed only during this synchronous call, before deinit.
    pub fn aws_error(self: *const Context, err: anyerror, diagnostic: anytype) void {
        var detail = self.record;
        detail.outcome = "service_error";
        detail.level = .ERROR;
        detail.result_type = null;
        detail.reason = null;
        if (err == error.ServiceError) {
            const code = diagnostic.kind.code();
            detail.service_code = safe_code(code);
            detail.service_http_status = diagnostic.kind.httpStatus();
            detail.service_request_id = bounded(diagnostic.kind.requestId(), 256);
            if (std.mem.eql(u8, code, "ConditionalCheckFailedException")) detail.level = .INFO;
        } else {
            detail.transport_error = @errorName(err);
        }
        emit_record(&self.logger, &detail);
    }
};

pub fn recognized_command(value: *const std.json.Value) ?[]const u8 {
    if (value.* != .object) return null;
    const command = value.object.get("command") orelse return null;
    if (command != .string) return null;
    for ([_][]const u8{ "create_event", "reserve_seats", "confirm_seats", "check_seats" }) |name| {
        if (std.mem.eql(u8, name, command.string)) return name;
    }
    return null;
}

pub fn result_type(result: anytype) []const u8 {
    return if (result.* == .success) "SUCCESS" else "FAILURE";
}

fn bounded(value: ?[]const u8, limit: usize) ?[]const u8 {
    const bytes = value orelse return null;
    if (bytes.len == 0) return null;
    return bytes[0..@min(bytes.len, limit)];
}

fn safe_code(value: []const u8) ?[]const u8 {
    if (value.len == 0 or value.len > 128) return null;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return null;
    }
    return value;
}

fn emit_record(logger: *const Logger, record: *const Record) void {
    var buffer: [size_max]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var output = record.*;
    output.lambda_request_id = bounded(output.lambda_request_id, 256);
    output.sqs_message_id = bounded(output.sqs_message_id, 128);
    std.json.Stringify.value(output, .{}, &writer) catch return;
    std.debug.assert(writer.end <= size_max);
    if (logger.observer) |observer| {
        observer.write(observer.context, writer.buffered()) catch {};
    } else if (!builtin.is_test) {
        std.debug.print("{s}\n", .{writer.buffered()});
    }
}

/// Test observer owns copies because production emission borrows a fixed stack buffer.
pub const TestObserver = struct {
    arena: std.mem.Allocator,
    records: std.array_list.Managed(Record),
    fail: bool = false,

    pub fn init(arena: std.mem.Allocator) TestObserver {
        return .{ .arena = arena, .records = .init(arena) };
    }
    pub fn logger(self: *TestObserver) Logger {
        return .{ .request_id = "lambda-test", .observer = .{ .context = self, .write = write } };
    }
    fn write(pointer: *anyopaque, bytes: []const u8) !void {
        const self: *TestObserver = @ptrCast(@alignCast(pointer));
        try std.testing.expect(bytes.len <= size_max);
        const parsed = try std.json.parseFromSlice(Record, self.arena, bytes, .{ .allocate = .alloc_always });
        try self.records.append(parsed.value);
        if (self.fail) return error.ObserverUnavailable;
    }
};

test "JSON escaping, bounded metadata and observer failures do not escape emission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var observer = TestObserver.init(arena.allocator());
    observer.fail = true;
    var context = Context.init(observer.logger(), .intake);
    context.identify(1);
    context.record.sqs_message_id = "quote\"\n\\";
    context.finish(.INFO, "publish", "accepted", null);
    context.emit();
    try std.testing.expectEqualStrings("quote\"\n\\", observer.records.items[0].sqs_message_id.?);
    try std.testing.expectEqualStrings("00000000-0000-0000-0000-000000000001", observer.records.items[0].operation_id.?);
    context.record.sqs_message_id = "x" ** 10000;
    context.emit();
    try std.testing.expectEqual(@as(usize, 128), observer.records.items[1].sqs_message_id.?.len);
    try std.testing.expect(observer.records.items[1].result_type == null);
}

test "oversized detail is dropped as a whole and service messages never enter records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var observer = TestObserver.init(arena.allocator());
    var context = Context.init(observer.logger(), .intake);
    context.record.reason = "x" ** (size_max + 1);
    context.emit();
    try std.testing.expectEqual(@as(usize, 0), observer.records.items.len);
    context.record.reason = null;
    const Diagnostic = struct {
        kind: Kind,
        const Kind = struct {
            code_value: []const u8 = "AccessDeniedException",
            pub fn code(self: @This()) []const u8 {
                return self.code_value;
            }
            pub fn httpStatus(_: @This()) u16 {
                return 403;
            }
            pub fn requestId(_: @This()) []const u8 {
                return "service-request";
            }
        };
    };
    context.aws_error(error.ServiceError, &Diagnostic{ .kind = .{} });
    context.aws_error(error.ConnectionResetByPeer, &Diagnostic{ .kind = .{} });
    try std.testing.expectEqualStrings("AccessDeniedException", observer.records.items[0].service_code.?);
    try std.testing.expectEqual(@as(?u16, 403), observer.records.items[0].service_http_status);
    try std.testing.expectEqualStrings("service-request", observer.records.items[0].service_request_id.?);
    try std.testing.expect(observer.records.items[0].transport_error == null);
    try std.testing.expect(observer.records.items[1].service_code == null);
    try std.testing.expectEqualStrings("ConnectionResetByPeer", observer.records.items[1].transport_error.?);
    context.aws_error(error.ServiceError, &Diagnostic{ .kind = .{ .code_value = "ConditionalCheckFailedException" } });
    try std.testing.expectEqual(Level.INFO, observer.records.items[2].level);
    context.aws_error(error.ServiceError, &Diagnostic{ .kind = .{ .code_value = "unsafe caller text" } });
    try std.testing.expect(observer.records.items[3].service_code == null);
    try std.testing.expect(!@hasField(Record, "body"));
    try std.testing.expect(!@hasField(Record, "tenant"));
    try std.testing.expect(!@hasField(Record, "token"));
}

test "maximum native status detail fits the fixed buffer with correlation metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var observer = TestObserver.init(arena.allocator());
    var context = Context.init(observer.logger(), .tigerbeetle_executor);
    context.identify(std.math.maxInt(u128));
    context.record.sqs_message_id = "sqs-message";
    var counts: [64]NativeCount = undefined;
    for (&counts, 0..) |*count, index| count.* = .{
        .family = "create_transfers",
        .code = std.math.maxInt(u32) - @as(u32, @intCast(index)),
        .count = 64,
    };
    context.record.native_status_counts = &counts;
    context.finish(.INFO, "native", "native_status", null);
    context.emit();
    try std.testing.expectEqual(@as(usize, 1), observer.records.items.len);
    try std.testing.expectEqual(@as(usize, 64), observer.records.items[0].native_status_counts.?.len);
}
