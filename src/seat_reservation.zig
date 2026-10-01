const std = @import("std");
const operation = @import("operation");
const processor_message = @import("processor_message");
const Allocator = std.mem.Allocator;

pub const class_count_max = 31;
pub const tag_size_max = 54;
pub const event_size_max = 16 * 1024;
pub const item_size_max = 32 * 1024;
pub const supply_max: u64 = 133_143_986_145;
pub const native_id_max: u128 = std.math.maxInt(u128) - 1;

comptime {
    std.debug.assert(class_count_max * @as(u64, std.math.maxInt(u32)) == supply_max);
    std.debug.assert(tag_size_max + "available-".len == 64);
    std.debug.assert(2 * class_count_max + 2 == 64);
}

/// Tags own their decoded bytes, including whitespace and Unicode spelling.
pub const Tag = struct {
    bytes: [tag_size_max]u8 = @splat(0),
    len: u8,

    pub fn init(text: []const u8) !Tag {
        if (text.len == 0 or text.len > tag_size_max) return error.InvalidTag;
        if (std.mem.eql(u8, text, "capacity")) return error.InvalidTag;
        if (std.mem.eql(u8, text, "allocation")) return error.InvalidTag;
        const view = std.unicode.Utf8View.init(text) catch return error.InvalidTag;
        var iterator = view.iterator();
        while (iterator.nextCodepoint()) |codepoint| {
            if (codepoint <= 0x1f) return error.InvalidTag;
            if (codepoint >= 0x7f and codepoint <= 0x9f) return error.InvalidTag;
        }
        var tag: Tag = .{ .len = @intCast(text.len) };
        @memcpy(tag.bytes[0..text.len], text);
        return tag;
    }

    pub fn slice(tag: *const Tag) []const u8 {
        std.debug.assert(tag.len > 0);
        std.debug.assert(tag.len <= tag_size_max);
        return tag.bytes[0..tag.len];
    }
};

pub const Class = struct { tag: Tag, total: u32 };
pub const CreateEvent = struct { classes: []const Class, timeout_seconds: u32 };
pub const ReserveSeats = struct { event_id: u128, class: Tag, quantity: u32 };
pub const ConfirmSeats = struct { event_id: u128, class: Tag, pending_id: u128 };
pub const Command = union(enum) {
    create_event: CreateEvent,
    reserve_seats: ReserveSeats,
    confirm_seats: ConfirmSeats,
    check_seats: u128,

    pub fn jsonStringify(command: Command, json: anytype) !void {
        try write_command(json, &command, null);
    }
};

pub const EventClass = struct { tag: Tag, total: u32, tb_account_id: u128 };
pub const EventState = enum { creating, ready, failed };
pub const EventKey = struct { tenant: []const u8, event_id: u128 };
pub const Event = struct {
    tenant: []const u8,
    event_id: u128,
    ledger: u32,
    timeout_seconds: u32,
    capacity_account_id: u128,
    allocation_account_id: u128,
    classes: []const EventClass,
    state: EventState,

    pub fn jsonStringify(event: Event, json: anytype) !void {
        try json.beginObject();
        try field(json, "tenant", event.tenant);
        try uuid_field(json, "event_id", event.event_id);
        try field(json, "ledger", event.ledger);
        try field(json, "timeout_seconds", event.timeout_seconds);
        try id_field(json, "capacity_account_id", event.capacity_account_id);
        try id_field(json, "allocation_account_id", event.allocation_account_id);
        try field(json, "state", @tagName(event.state));
        try json.objectField("classes");
        try json.beginObject();
        for (event.classes) |*class| {
            try json.objectField(class.tag.slice());
            try json.beginObject();
            try field(json, "total", class.total);
            try id_field(json, "tb_account_id", class.tb_account_id);
            try json.endObject();
        }
        try json.endObject();
        try json.endObject();
    }
};

pub const Context = struct {
    command: Command,
    reservation_id: ?u128,

    pub fn jsonStringify(context: Context, json: anytype) !void {
        try write_command(json, &context.command, context.reservation_id);
    }
};

pub fn encode_context(
    arena: Allocator,
    command: *const Command,
    reservation_id: ?u128,
) ![]const u8 {
    try validate_command(command);
    if (command.* == .reserve_seats) {
        try validate_native_id(reservation_id orelse return error.InvalidContext);
    } else {
        if (reservation_id != null) return error.InvalidContext;
    }
    return encode_bounded(arena, Context{
        .command = command.*,
        .reservation_id = reservation_id,
    }, processor_message.context_size_max);
}

pub fn decode_context(arena: Allocator, input: []const u8) !Context {
    var value = try parse_value(arena, input, processor_message.context_size_max);
    _ = try bounded_size(value, processor_message.context_size_max);
    if (value != .object) return error.InvalidContext;
    var reservation_id: ?u128 = null;
    if (value.object.get("reservation_id")) |id| {
        reservation_id = try native_id(try string_value(id));
        _ = value.object.orderedRemove("reservation_id");
    }
    const command = try command_from_value(arena, &value);
    _ = try encode_context(arena, &command, reservation_id);
    return .{ .command = command, .reservation_id = reservation_id };
}

pub const FailureCode = enum {
    invalid_request,
    event_unavailable,
    unknown_class,
    event_not_ready,
    event_failed,
    insufficient_seats,
    reservation_expired,
    invalid_reservation,
    operation_rejected,
};
pub const Availability = struct { tag: Tag, total: u32, available: u32 };
pub const Success = union(enum) {
    create_event: u128,
    reserve_seats: struct { request: ReserveSeats, reservation_id: u128 },
    confirm_seats: ConfirmSeats,
    check_seats: struct { event_id: u128, classes: []const Availability },
};
pub const Result = union(enum) {
    success: Success,
    failure: FailureCode,

    pub fn jsonStringify(result: Result, json: anytype) !void {
        try json.beginObject();
        try field(json, "type", if (result == .success) "SUCCESS" else "FAILURE");
        try json.objectField("payload");
        try json.beginObject();
        switch (result) {
            .failure => |code| try field(json, "code", @tagName(code)),
            .success => |*success| try write_success(json, success),
        }
        try json.endObject();
        try json.endObject();
    }
};

fn write_success(json: anytype, success: *const Success) !void {
    switch (success.*) {
        .create_event => |id| try uuid_field(json, "event_id", id),
        .reserve_seats => |*reserve| {
            try uuid_field(json, "event_id", reserve.request.event_id);
            try field(json, "class", reserve.request.class.slice());
            try field(json, "quantity", reserve.request.quantity);
            try id_field(json, "reservation_id", reserve.reservation_id);
        },
        .confirm_seats => |*confirm| {
            try uuid_field(json, "event_id", confirm.event_id);
            try field(json, "class", confirm.class.slice());
            try id_field(json, "reservation_id", confirm.pending_id);
        },
        .check_seats => |*check| {
            try uuid_field(json, "event_id", check.event_id);
            try json.objectField("classes");
            try json.beginObject();
            for (check.classes) |*class| {
                try json.objectField(class.tag.slice());
                try json.beginObject();
                try field(json, "total", class.total);
                try field(json, "available", class.available);
                try json.endObject();
            }
            try json.endObject();
        },
    }
}

pub fn encode_result(arena: Allocator, result: *const Result) ![]const u8 {
    if (result.* == .success) switch (result.success) {
        .create_event => {},
        .reserve_seats => |*reserve| {
            const command: Command = .{ .reserve_seats = reserve.request };
            try validate_command(&command);
            try validate_native_id(reserve.reservation_id);
        },
        .confirm_seats => |*confirm| {
            const command: Command = .{ .confirm_seats = confirm.* };
            try validate_command(&command);
        },
        .check_seats => |*check| {
            try validate_class_count(check.classes.len);
            for (check.classes, 0..) |*class, index| {
                try validate_tag(&class.tag);
                if (class.total == 0 or class.available > class.total) return error.InvalidNumber;
                if (index > 0) try ordered_tags(&check.classes[index - 1].tag, &class.tag);
            }
        },
    };
    return encode_bounded(arena, result.*, operation.result_size_max);
}

/// The exact native input serializer is also used for pre-effect size admission.
pub const NativeBody = struct {
    command: *const Command,
    event: *const Event,
    attempt_id: u128,

    pub fn jsonStringify(body: NativeBody, json: anytype) !void {
        try json.beginObject();
        try json.objectField("create_accounts");
        try json.beginArray();
        if (body.command.* == .create_event) {
            try write_native_account(
                json,
                body.event.capacity_account_id,
                "capacity",
                body.event.ledger,
                3,
                "credits_must_not_exceed_debits",
            );
            try write_native_account(
                json,
                body.event.allocation_account_id,
                "allocation",
                body.event.ledger,
                2,
                "debits_must_not_exceed_credits",
            );
            for (body.event.classes) |*class| {
                try write_native_account(
                    json,
                    class.tb_account_id,
                    class.tag.slice(),
                    body.event.ledger,
                    1,
                    "debits_must_not_exceed_credits",
                );
            }
        }
        try json.endArray();
        try json.objectField("create_transfers");
        try json.beginArray();
        switch (body.command.*) {
            .create_event => for (body.event.classes) |*class| {
                try write_native_transfer(json, &.{
                    .id = class.tb_account_id,
                    .debit = body.event.capacity_account_id,
                    .credit = class.tb_account_id,
                    .amount = class.total,
                    .ledger = body.event.ledger,
                    .code = 1,
                    .alias_tag = &class.tag,
                    .alias_prefix = "available-",
                });
            },
            .reserve_seats, .confirm_seats => try write_seat_transfer(json, &body),
            .check_seats => {},
        }
        try json.endArray();
        try json.objectField("lookup_accounts");
        try json.beginArray();
        if (body.command.* == .check_seats) for (body.event.classes) |*class| {
            try json.beginObject();
            try id_field(json, "id", class.tb_account_id);
            try field(json, "alias", class.tag.slice());
            try json.endObject();
        };
        try json.endArray();
        try json.endObject();
    }
};

fn write_native_account(
    json: anytype,
    id: u128,
    alias: []const u8,
    ledger: u32,
    code: u16,
    flag: []const u8,
) !void {
    std.debug.assert(id > 0);
    std.debug.assert(id <= native_id_max);
    std.debug.assert(ledger > 0);
    std.debug.assert(code > 0);
    std.debug.assert(alias.len <= 64);
    try json.beginObject();
    try id_field(json, "id", id);
    try field(json, "alias", alias);
    try field(json, "ledger", ledger);
    try field(json, "code", code);
    try field(json, "flags", &[_][]const u8{flag});
    try json.endObject();
}

const NativeTransfer = struct {
    id: u128,
    debit: u128,
    credit: u128,
    amount: u128,
    ledger: u32,
    code: u16,
    alias_tag: *const Tag,
    alias_prefix: []const u8,
    flag: ?[]const u8 = null,
    pending_id: ?u128 = null,
    timeout: ?u32 = null,
};

fn write_native_transfer(json: anytype, transfer: *const NativeTransfer) !void {
    std.debug.assert(transfer.id > 0);
    std.debug.assert(transfer.id <= native_id_max);
    std.debug.assert(transfer.debit != transfer.credit);
    std.debug.assert(transfer.amount > 0);
    std.debug.assert(transfer.ledger > 0);
    var alias_buffer: [64]u8 = undefined;
    const alias = std.fmt.bufPrint(
        &alias_buffer,
        "{s}{s}",
        .{ transfer.alias_prefix, transfer.alias_tag.slice() },
    ) catch unreachable;
    try json.beginObject();
    try id_field(json, "id", transfer.id);
    try field(json, "alias", alias);
    try id_field(json, "debit_account_id", transfer.debit);
    try id_field(json, "credit_account_id", transfer.credit);
    try id_field(json, "amount", transfer.amount);
    try field(json, "ledger", transfer.ledger);
    try field(json, "code", transfer.code);
    if (transfer.flag) |flag| try field(json, "flags", &[_][]const u8{flag});
    if (transfer.pending_id) |id| try id_field(json, "pending_id", id);
    if (transfer.timeout) |timeout| try field(json, "timeout", timeout);
    try json.endObject();
}

fn write_seat_transfer(json: anytype, body: *const NativeBody) !void {
    const tag = switch (body.command.*) {
        .reserve_seats => |*reserve| &reserve.class,
        .confirm_seats => |*confirm| &confirm.class,
        else => unreachable,
    };
    const class = &body.event.classes[class_index(body.event, tag).?];
    var transfer: NativeTransfer = .{
        .id = body.attempt_id,
        .debit = class.tb_account_id,
        .credit = body.event.allocation_account_id,
        .amount = 0,
        .ledger = body.event.ledger,
        .code = 2,
        .alias_tag = tag,
        .alias_prefix = undefined,
    };
    switch (body.command.*) {
        .reserve_seats => |*reserve| {
            transfer.amount = reserve.quantity;
            transfer.flag = "pending";
            transfer.timeout = body.event.timeout_seconds;
            transfer.alias_prefix = "reserve-";
        },
        .confirm_seats => |*confirm| {
            transfer.amount = std.math.maxInt(u128);
            transfer.pending_id = confirm.pending_id;
            transfer.flag = "post_pending_transfer";
            transfer.alias_prefix = "confirm-";
        },
        else => unreachable,
    }
    try write_native_transfer(json, &transfer);
}

pub fn encode_native_body(arena: Allocator, body: *const NativeBody) ![]const u8 {
    try validate_command(body.command);
    try validate_event(body.event);
    try validate_command_event(body.command, body.event);
    if (body.command.* == .reserve_seats or body.command.* == .confirm_seats) {
        try validate_native_id(body.attempt_id);
        if (body.command.* == .confirm_seats) {
            if (body.attempt_id == body.command.confirm_seats.pending_id) {
                return error.InvalidNativeID;
            }
        }
    }
    return encode_bounded(arena, body.*, processor_message.body_size_max);
}

fn validate_command_event(command: *const Command, event: *const Event) !void {
    switch (command.*) {
        .create_event => |*create| try validate_configuration(create, event),
        .reserve_seats => |*reserve| {
            if (reserve.event_id != event.event_id) return error.EventUnavailable;
            if (class_index(event, &reserve.class) == null) return error.UnknownClass;
        },
        .confirm_seats => |*confirm| {
            if (confirm.event_id != event.event_id) return error.EventUnavailable;
            if (class_index(event, &confirm.class) == null) return error.UnknownClass;
        },
        .check_seats => |id| if (id != event.event_id) {
            return error.EventUnavailable;
        },
    }
}

/// Compares the immutable configuration of a creation command or Event candidate.
/// Generated ledger/account IDs belong to the saved winner and are not compared.
pub fn validate_configuration(requested: anytype, saved: *const Event) !void {
    comptime std.debug.assert(@TypeOf(requested) == *const CreateEvent or
        @TypeOf(requested) == *const Event);
    std.debug.assert(requested.classes.len <= class_count_max);
    std.debug.assert(saved.classes.len <= class_count_max);
    if (requested.timeout_seconds != saved.timeout_seconds) return error.EventConflict;
    if (requested.classes.len != saved.classes.len) return error.EventConflict;
    for (requested.classes, saved.classes) |*input, *stored| {
        if (input.total != stored.total) return error.EventConflict;
        if (!std.mem.eql(u8, input.tag.slice(), stored.tag.slice())) return error.EventConflict;
    }
}

pub const AdmissionOptions = struct {
    operation_id: u128,
    tenant: []const u8,
    result_queue: []const u8,
};
pub const AdmissionSizes = struct {
    public_body: usize,
    context: usize,
    native_body: usize,
    result: usize,
    envelope: usize,
    logical_event: usize,
};

/// Reads may supply metadata; this function performs no allocation of native identities or effects.
/// Creation is proven with maximum-width synthetic IDs before a ledger or real IDs are allocated.
pub fn admit(
    arena: Allocator,
    command: *const Command,
    saved: ?*const Event,
    options: *const AdmissionOptions,
) !AdmissionSizes {
    try operation.validateTenant(options.tenant);
    const public_body = try encode_command(arena, command);
    var candidate: Event = undefined;
    const event = if (command.* == .create_event) event: {
        candidate = try admission_event(arena, &command.create_event, options);
        break :event &candidate;
    } else saved orelse return error.EventUnavailable;
    // Authorization and readiness precede class disclosure.
    if (!std.mem.eql(u8, event.tenant, options.tenant)) return error.EventUnavailable;
    if (command_event_id(command)) |id| {
        if (id != event.event_id) return error.EventUnavailable;
    }
    try validate_event(event);
    if (command.* != .create_event) switch (event.state) {
        .creating => return error.EventNotReady,
        .failed => return error.EventFailed,
        .ready => {},
    };
    const attempt_id = if (command.* == .confirm_seats and
        command.confirm_seats.pending_id == native_id_max) native_id_max - 1 else native_id_max;
    const context = try encode_context(
        arena,
        command,
        if (command.* == .reserve_seats) attempt_id else null,
    );
    const native = try encode_native_body(arena, &.{
        .command = command,
        .event = event,
        .attempt_id = attempt_id,
    });
    const result = try admission_result(arena, command, event, attempt_id);
    const message = try processor_message.encode(arena, &.{
        .operation_id = options.operation_id,
        .tenant = options.tenant,
        .result_queue = options.result_queue,
        .context = try parse_value(arena, context, processor_message.context_size_max),
        .body = try parse_value(arena, native, processor_message.body_size_max),
    });
    return .{
        .public_body = public_body.len,
        .context = context.len,
        .native_body = native.len,
        .result = result.len,
        .envelope = message.len,
        .logical_event = try bounded_size(event.*, event_size_max),
    };
}

fn command_event_id(command: *const Command) ?u128 {
    return switch (command.*) {
        .create_event => null,
        .reserve_seats => |reserve| reserve.event_id,
        .confirm_seats => |confirm| confirm.event_id,
        .check_seats => |id| id,
    };
}

pub fn uuid_text(arena: Allocator, id: u128) ![]const u8 {
    var buffer: [operation.uuid_string_size]u8 = undefined;
    return arena.dupe(u8, operation.uuidToString(id, &buffer));
}

fn admission_event(
    arena: Allocator,
    create: *const CreateEvent,
    options: *const AdmissionOptions,
) !Event {
    const classes = try arena.alloc(EventClass, create.classes.len);
    for (classes, create.classes, 0..) |*class, *input, index| {
        class.* = .{
            .tag = input.tag,
            .total = input.total,
            .tb_account_id = native_id_max - index - 2,
        };
    }
    return .{
        .tenant = options.tenant,
        .event_id = options.operation_id,
        .ledger = std.math.maxInt(u32),
        .timeout_seconds = create.timeout_seconds,
        .capacity_account_id = native_id_max,
        .allocation_account_id = native_id_max - 1,
        .classes = classes,
        .state = .creating,
    };
}

fn admission_result(
    arena: Allocator,
    command: *const Command,
    event: *const Event,
    attempt_id: u128,
) ![]const u8 {
    var availability: [class_count_max]Availability = undefined;
    for (event.classes, availability[0..event.classes.len]) |*class, *observation| {
        observation.* = .{ .tag = class.tag, .total = class.total, .available = class.total };
    }
    const result: Result = .{ .success = switch (command.*) {
        .create_event => .{ .create_event = event.event_id },
        .reserve_seats => |reserve| .{ .reserve_seats = .{
            .request = reserve,
            .reservation_id = attempt_id,
        } },
        .confirm_seats => |confirm| .{ .confirm_seats = confirm },
        .check_seats => |id| .{ .check_seats = .{
            .event_id = id,
            .classes = availability[0..event.classes.len],
        } },
    } };
    return encode_result(arena, &result);
}

/// Raw JSON is bounded before parsing; decoded duplicate keys are errors at every depth.
pub fn decode_command(arena: Allocator, input: []const u8) !Command {
    const value = try parse_value(arena, input, operation.body_size_max);
    return command_from_value(arena, &value);
}

/// Intake may already have normalized number spellings. This validates that complete value.
pub fn command_from_value(arena: Allocator, value: *const std.json.Value) !Command {
    _ = try bounded_size(value.*, operation.body_size_max);
    if (value.* != .object) return error.InvalidRequest;
    const name = try string_value(try required(value, "command"));
    if (std.mem.eql(u8, name, "create_event")) {
        try exact_fields(value, &.{ "command", "classes", "timeout_seconds" });
        const classes_value = try required(value, "classes");
        if (classes_value != .object) return error.InvalidClasses;
        try validate_class_count(classes_value.object.count());
        const classes = try arena.alloc(Class, classes_value.object.count());
        for (
            classes_value.object.keys(),
            classes_value.object.values(),
            classes,
        ) |tag, total, *class| {
            class.* = .{ .tag = try Tag.init(tag), .total = try positive_u32(total) };
        }
        std.mem.sort(Class, classes, {}, class_less_than);
        const command: Command = .{ .create_event = .{
            .classes = classes,
            .timeout_seconds = try positive_u32(try required(value, "timeout_seconds")),
        } };
        try validate_command(&command);
        return command;
    }
    if (std.mem.eql(u8, name, "reserve_seats")) {
        try exact_fields(value, &.{ "command", "event_id", "class", "quantity" });
        return .{ .reserve_seats = .{
            .event_id = try canonical_uuid(try string_value(try required(value, "event_id"))),
            .class = try Tag.init(try string_value(try required(value, "class"))),
            .quantity = try positive_u32(try required(value, "quantity")),
        } };
    }
    if (std.mem.eql(u8, name, "confirm_seats")) {
        try exact_fields(value, &.{ "command", "event_id", "class", "pending_id" });
        return .{ .confirm_seats = .{
            .event_id = try canonical_uuid(try string_value(try required(value, "event_id"))),
            .class = try Tag.init(try string_value(try required(value, "class"))),
            .pending_id = try native_id(try string_value(try required(value, "pending_id"))),
        } };
    }
    if (std.mem.eql(u8, name, "check_seats")) {
        try exact_fields(value, &.{ "command", "event_id" });
        return .{ .check_seats = try canonical_uuid(
            try string_value(try required(value, "event_id")),
        ) };
    }
    return error.UnknownCommand;
}

pub fn encode_command(arena: Allocator, command: *const Command) ![]const u8 {
    try validate_command(command);
    return encode_bounded(arena, command.*, operation.body_size_max);
}

pub fn validate_command(command: *const Command) !void {
    switch (command.*) {
        .create_event => |*create| {
            if (create.timeout_seconds == 0) return error.InvalidNumber;
            try validate_class_count(create.classes.len);
            var supply: u64 = 0;
            for (create.classes, 0..) |*class, index| {
                try validate_tag(&class.tag);
                if (class.total == 0) return error.InvalidNumber;
                supply = std.math.add(u64, supply, class.total) catch return error.InvalidNumber;
                if (index > 0) try ordered_tags(&create.classes[index - 1].tag, &class.tag);
            }
            if (supply > supply_max) return error.InvalidNumber;
        },
        .reserve_seats => |*reserve| {
            try validate_tag(&reserve.class);
            if (reserve.quantity == 0) return error.InvalidNumber;
        },
        .confirm_seats => |*confirm| {
            try validate_tag(&confirm.class);
            try validate_native_id(confirm.pending_id);
        },
        .check_seats => {},
    }
}

pub fn canonical_uuid(text: []const u8) !u128 {
    const id = operation.uuidFromString(text) catch return error.InvalidUUID;
    var buffer: [operation.uuid_string_size]u8 = undefined;
    if (!std.mem.eql(u8, text, operation.uuidToString(id, &buffer))) return error.InvalidUUID;
    return id;
}

pub fn native_id(text: []const u8) !u128 {
    if (text.len == 0 or text.len > 39) return error.InvalidNativeID;
    if (text[0] == '0') return error.InvalidNativeID;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidNativeID;
    const id = std.fmt.parseInt(u128, text, 10) catch return error.InvalidNativeID;
    try validate_native_id(id);
    return id;
}

pub fn validate_native_id(id: u128) !void {
    if (id == 0 or id > native_id_max) return error.InvalidNativeID;
}

pub fn positive_u32(value: std.json.Value) !u32 {
    switch (value) {
        .integer => |number| {
            if (number <= 0) return error.InvalidNumber;
            return std.math.cast(u32, number) orelse error.InvalidNumber;
        },
        .float => |number| {
            if (!std.math.isFinite(number)) return error.InvalidNumber;
            if (number < 1 or number > std.math.maxInt(u32)) return error.InvalidNumber;
            if (@trunc(number) != number) return error.InvalidNumber;
            return @intFromFloat(number);
        },
        else => return error.InvalidNumber,
    }
}

pub fn decode_event(arena: Allocator, input: []const u8) !Event {
    const value = try parse_value(arena, input, event_size_max);
    try exact_fields(
        &value,
        &.{
            "tenant",
            "event_id",
            "ledger",
            "timeout_seconds",
            "capacity_account_id",
            "allocation_account_id",
            "state",
            "classes",
        },
    );
    const classes_value = try required(&value, "classes");
    if (classes_value != .object) return error.InvalidClasses;
    try validate_class_count(classes_value.object.count());
    const classes = try arena.alloc(EventClass, classes_value.object.count());
    for (classes_value.object.keys(), classes_value.object.values(), classes) |tag, raw, *class| {
        try exact_fields(&raw, &.{ "total", "tb_account_id" });
        class.* = .{
            .tag = try Tag.init(tag),
            .total = try positive_u32(try required(&raw, "total")),
            .tb_account_id = try native_id(try string_value(try required(&raw, "tb_account_id"))),
        };
    }
    std.mem.sort(EventClass, classes, {}, event_class_less_than);
    const state = std.meta.stringToEnum(
        EventState,
        try string_value(try required(&value, "state")),
    ) orelse return error.InvalidState;
    const event: Event = .{
        .tenant = try string_value(try required(&value, "tenant")),
        .event_id = try canonical_uuid(try string_value(try required(&value, "event_id"))),
        .ledger = try positive_u32(try required(&value, "ledger")),
        .timeout_seconds = try positive_u32(try required(&value, "timeout_seconds")),
        .capacity_account_id = try native_id(try string_value(try required(
            &value,
            "capacity_account_id",
        ))),
        .allocation_account_id = try native_id(try string_value(try required(
            &value,
            "allocation_account_id",
        ))),
        .classes = classes,
        .state = state,
    };
    try validate_event(&event);
    return event;
}

pub fn encode_event(arena: Allocator, event: *const Event) ![]const u8 {
    try validate_event(event);
    return encode_bounded(arena, event.*, event_size_max);
}

pub fn validate_key(key: *const EventKey) !void {
    try operation.validateTenant(key.tenant);
}

pub fn validate_event(event: *const Event) !void {
    try operation.validateTenant(event.tenant);
    if (event.ledger == 0 or event.timeout_seconds == 0) return error.InvalidNumber;
    try validate_native_id(event.capacity_account_id);
    try validate_native_id(event.allocation_account_id);
    if (event.capacity_account_id == event.allocation_account_id) return error.DuplicateAccountID;
    _ = try total_supply(event);
    for (event.classes, 0..) |*class, index| {
        try validate_native_id(class.tb_account_id);
        if (class.tb_account_id == event.capacity_account_id) return error.DuplicateAccountID;
        if (class.tb_account_id == event.allocation_account_id) return error.DuplicateAccountID;
        for (event.classes[0..index]) |*previous| {
            if (previous.tb_account_id == class.tb_account_id) return error.DuplicateAccountID;
        }
    }
    _ = try bounded_size(event.*, event_size_max);
}

pub fn total_supply(event: *const Event) !u64 {
    try validate_class_count(event.classes.len);
    var total: u64 = 0;
    for (event.classes, 0..) |*class, index| {
        try validate_tag(&class.tag);
        if (class.total == 0) return error.InvalidNumber;
        total = std.math.add(u64, total, class.total) catch return error.InvalidNumber;
        if (index > 0) try ordered_tags(&event.classes[index - 1].tag, &class.tag);
    }
    if (total > supply_max) return error.InvalidNumber;
    std.debug.assert(total > 0);
    return total;
}

pub fn class_index(event: *const Event, tag: *const Tag) ?usize {
    std.debug.assert(event.classes.len <= class_count_max);
    for (event.classes, 0..) |*class, index| {
        if (std.mem.eql(u8, class.tag.slice(), tag.slice())) return index;
    }
    return null;
}

pub fn clone_event(arena: Allocator, event: *const Event) !Event {
    try validate_event(event);
    var copy = event.*;
    copy.tenant = try arena.dupe(u8, event.tenant);
    copy.classes = try arena.dupe(EventClass, event.classes);
    return copy;
}

fn event_class_less_than(_: void, left: EventClass, right: EventClass) bool {
    return std.mem.order(u8, left.tag.slice(), right.tag.slice()) == .lt;
}

fn validate_tag(tag: *const Tag) !void {
    if (tag.len == 0 or tag.len > tag_size_max) return error.InvalidTag;
    _ = try Tag.init(tag.slice());
}

pub fn parse_value(arena: Allocator, input: []const u8, size_max: usize) !std.json.Value {
    if (input.len > size_max) return error.InputTooLarge;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, input, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .max_value_len = size_max,
        .parse_numbers = true,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJSON,
    };
}

pub fn exact_fields(value: *const std.json.Value, names: []const []const u8) !void {
    if (value.* != .object) return error.InvalidRequest;
    if (value.object.count() != names.len) return error.InvalidFields;
    for (names) |name| if (!value.object.contains(name)) return error.InvalidFields;
}

pub fn required(value: *const std.json.Value, name: []const u8) !std.json.Value {
    if (value.* != .object) return error.InvalidRequest;
    return value.object.get(name) orelse error.InvalidFields;
}

pub fn string_value(value: std.json.Value) ![]const u8 {
    if (value != .string) return error.InvalidString;
    return value.string;
}

pub fn bounded_size(value: anytype, size_max: usize) !usize {
    var buffer: [256]u8 = undefined;
    var counter = std.Io.Writer.Discarding.init(&buffer);
    try std.json.Stringify.value(value, .{}, &counter.writer);
    if (counter.fullCount() > size_max) return error.EncodedValueTooLarge;
    return @intCast(counter.fullCount());
}

pub fn encode_bounded(arena: Allocator, value: anytype, size_max: usize) ![]const u8 {
    _ = try bounded_size(value, size_max);
    return std.json.Stringify.valueAlloc(arena, value, .{});
}

fn class_less_than(_: void, left: Class, right: Class) bool {
    return std.mem.order(u8, left.tag.slice(), right.tag.slice()) == .lt;
}

fn validate_class_count(count: usize) !void {
    if (count == 0 or count > class_count_max) return error.InvalidClasses;
}

fn ordered_tags(previous: *const Tag, current: *const Tag) !void {
    if (std.mem.order(u8, previous.slice(), current.slice()) != .lt) return error.InvalidClasses;
}

fn field(json: anytype, name: []const u8, value: anytype) !void {
    try json.objectField(name);
    try json.write(value);
}

fn uuid_field(json: anytype, name: []const u8, id: u128) !void {
    var buffer: [operation.uuid_string_size]u8 = undefined;
    try field(json, name, operation.uuidToString(id, &buffer));
}

fn id_field(json: anytype, name: []const u8, id: u128) !void {
    var buffer: [39]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{id}) catch unreachable;
    try field(json, name, text);
}

fn write_command(json: anytype, command: *const Command, reservation_id: ?u128) !void {
    try json.beginObject();
    try field(json, "command", @tagName(command.*));
    switch (command.*) {
        .create_event => |*create| {
            try json.objectField("classes");
            try json.beginObject();
            for (create.classes) |*class| try field(json, class.tag.slice(), class.total);
            try json.endObject();
            try field(json, "timeout_seconds", create.timeout_seconds);
        },
        .reserve_seats => |*reserve| {
            try uuid_field(json, "event_id", reserve.event_id);
            try field(json, "class", reserve.class.slice());
            try field(json, "quantity", reserve.quantity);
            if (reservation_id) |id| try id_field(json, "reservation_id", id);
        },
        .confirm_seats => |*confirm| {
            try uuid_field(json, "event_id", confirm.event_id);
            try field(json, "class", confirm.class.slice());
            try id_field(json, "pending_id", confirm.pending_id);
        },
        .check_seats => |id| try uuid_field(json, "event_id", id),
    }
    try json.endObject();
}

test "creation preserves decoded tags and orders classes by unsigned UTF-8 bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const command = try decode_command(arena.allocator(),
        \\{"command":"create_event","classes":{"é":2,"a":3," A ":4},"timeout_seconds":5}
    );
    try std.testing.expectEqualStrings(" A ", command.create_event.classes[0].tag.slice());
    try std.testing.expectEqualStrings("a", command.create_event.classes[1].tag.slice());
    try std.testing.expectEqualStrings("é", command.create_event.classes[2].tag.slice());
    try std.testing.expectEqualStrings(
        \\{"command":"create_event","classes":{" A ":4,"a":3,"é":2},"timeout_seconds":5}
    , try encode_command(arena.allocator(), &command));
}

test "commands reject decoded duplicates and scalar reserve admits one class only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const invalid = [_][]const u8{
        \\{"command":"create_event","classes":{"a":1,"\u0061":2},"timeout_seconds":1}
        ,
        \\{"command":"check_seats","command":"check_seats","event_id":"00000000-0000-0000-0000-000000000000"}
        ,
        \\{"command":"reserve_seats","event_id":"00000000-0000-0000-0000-000000000000","class":["a","b"],"quantity":1}
        ,
        \\{"command":"confirm_seats","event_id":"00000000-0000-0000-0000-000000000000","class":{"a":1},"pending_id":"1"}
        ,
    };
    for (invalid) |input| {
        if (decode_command(allocator, input)) |_| return error.InvalidCommandAccepted else |err| {
            try std.testing.expect(err != error.OutOfMemory);
        }
    }
    const reserve = try decode_command(allocator,
        \\{"command":"reserve_seats","event_id":"00000000-0000-0000-0000-000000000000","class":"a","quantity":4294967295}
    );
    try std.testing.expectEqual(@as(u32, 4_294_967_295), reserve.reserve_seats.quantity);
}

test "event metadata round trips owned tenant tags and immutable account identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = try std.testing.allocator.dupe(u8,
        \\{"tenant":"tenant-a","event_id":"00000000-0000-0000-0000-000000000001","ledger":1001,"timeout_seconds":30,"capacity_account_id":"1","allocation_account_id":"2","state":"creating","classes":{"a":{"total":10,"tb_account_id":"3"}}}
    );
    defer std.testing.allocator.free(input);
    const event = try decode_event(arena.allocator(), input);
    @memset(input, 'x');
    try std.testing.expectEqualStrings("tenant-a", event.tenant);
    try std.testing.expectEqual(@as(u128, 3), event.classes[0].tb_account_id);
    try std.testing.expectEqual(@as(u64, 10), try total_supply(&event));
    _ = try decode_event(arena.allocator(), try encode_event(arena.allocator(), &event));
}

test "reserve Context carries its attempt ID and confirmation carries only the pending ID" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const reserve = try decode_command(arena.allocator(),
        \\{"command":"reserve_seats","event_id":"00000000-0000-0000-0000-000000000001","class":"a","quantity":2}
    );
    try std.testing.expectEqualStrings(
        \\{"command":"reserve_seats","event_id":"00000000-0000-0000-0000-000000000001","class":"a","quantity":2,"reservation_id":"123"}
    , try encode_context(arena.allocator(), &reserve, 123));
    const confirm = try decode_command(arena.allocator(),
        \\{"command":"confirm_seats","event_id":"00000000-0000-0000-0000-000000000001","class":"a","pending_id":"123"}
    );
    try std.testing.expectEqualStrings(
        try encode_command(arena.allocator(), &confirm),
        try encode_context(arena.allocator(), &confirm, null),
    );
    try std.testing.expectError(
        error.InvalidContext,
        encode_context(arena.allocator(), &confirm, 124),
    );
}

test "31 maximum classes pass real serialization admission before generated identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var classes: [31]Class = undefined;
    for (&classes, 0..) |*class, index| {
        var bytes: [54]u8 = @splat('"');
        bytes[0] = @intCast('A' + index);
        class.* = .{ .tag = try Tag.init(&bytes), .total = std.math.maxInt(u32) };
    }
    const command: Command = .{ .create_event = .{
        .classes = &classes,
        .timeout_seconds = std.math.maxInt(u32),
    } };
    const options: AdmissionOptions = .{
        .operation_id = std.math.maxInt(u128),
        .tenant = "\x00" ** 64,
        .result_queue = "\"" ** 2048,
    };
    const sizes = try admit(allocator, &command, null, &options);
    try std.testing.expect(sizes.public_body <= 4096);
    try std.testing.expectEqual(sizes.public_body, sizes.context);
    try std.testing.expect(sizes.native_body < 33329);
    try std.testing.expect(sizes.envelope < 115328);
    const event = try admission_event(allocator, &command.create_event, &options);
    try std.testing.expectEqual(@as(u64, 133_143_986_145), try total_supply(&event));
    const native = try parse_value(allocator, try encode_native_body(allocator, &.{
        .command = &command,
        .event = &event,
        .attempt_id = 1,
    }), processor_message.body_size_max);
    try std.testing.expectEqual(
        @as(usize, 33),
        native.object.get("create_accounts").?.array.items.len,
    );
    try std.testing.expectEqual(
        @as(usize, 31),
        native.object.get("create_transfers").?.array.items.len,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        native.object.get("lookup_accounts").?.array.items.len,
    );
    var ready = event;
    ready.state = .ready;
    const check: Command = .{ .check_seats = event.event_id };
    const check_sizes = try admit(allocator, &check, &ready, &options);
    try std.testing.expect(check_sizes.result < operation.result_size_max);
    const public = try parse_value(
        allocator,
        try admission_result(allocator, &check, &ready, 1),
        operation.result_size_max,
    );
    try std.testing.expectEqual(
        @as(usize, 31),
        public.object.get("payload").?.object.get("classes").?.object.count(),
    );
}

test "all commands enforce exact fields types numbers and canonical identifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const bases = [_][]const u8{
        \\{"command":"create_event","classes":{"a":1},"timeout_seconds":1}
        ,
        \\{"command":"reserve_seats","event_id":"00000000-0000-0000-0000-000000000001","class":"a","quantity":1}
        ,
        \\{"command":"confirm_seats","event_id":"00000000-0000-0000-0000-000000000001","class":"a","pending_id":"1"}
        ,
        \\{"command":"check_seats","event_id":"00000000-0000-0000-0000-000000000001"}
        ,
    };
    for (bases) |input| {
        const command = try decode_command(allocator, input);
        const canonical = try encode_command(allocator, &command);
        try std.testing.expectEqualStrings(input, canonical);
        const object = try parse_value(allocator, input, 4096);
        for (object.object.keys()) |key| {
            var missing = try parse_value(allocator, input, 4096);
            _ = missing.object.orderedRemove(key);
            try expect_invalid_command(allocator, &missing);
            var wrong = try parse_value(allocator, input, 4096);
            try wrong.object.put(allocator, key, .null);
            try expect_invalid_command(allocator, &wrong);
        }
        for ([_][]const u8{
            "tenant",
            "ledger",
            "event",
            "flags",
            "result_queue",
            "classes_extra",
        }) |key| {
            var extra = try parse_value(allocator, input, 4096);
            try extra.object.put(allocator, key, .{ .integer = 1 });
            try expect_invalid_command(allocator, &extra);
        }
    }
    for ([_][]const u8{
        "0",
        "-0",
        "-0.0",
        "1.5",
        "4294967296",
        "-1",
        "\"1\"",
        "null",
        "true",
        "1e100",
        "1e-100",
    }) |number| {
        try std.testing.expectError(
            error.InvalidNumber,
            positive_u32(try parse_value(allocator, number, 4096)),
        );
    }
    for ([_][]const u8{
        "01",
        "0",
        "-1",
        "+1",
        " 1",
        "1 ",
        "1.0",
        "1e0",
        "１",
        "",
        "340282366920938463463374607431768211455",
        "340282366920938463463374607431768211456",
    }) |id| {
        try std.testing.expectError(error.InvalidNativeID, native_id(id));
    }
    try std.testing.expectEqual(
        native_id_max,
        try native_id("340282366920938463463374607431768211454"),
    );
    try std.testing.expectEqual(
        @as(u128, 0),
        try canonical_uuid("00000000-0000-0000-0000-000000000000"),
    );
    try std.testing.expectError(
        error.InvalidUUID,
        canonical_uuid("00112233-4455-6677-8899-AABBCCDDEEFF"),
    );
}

fn expect_invalid_command(arena: Allocator, value: *const std.json.Value) !void {
    if (command_from_value(arena, value)) |_| return error.InvalidCommandAccepted else |err| {
        try std.testing.expect(err != error.OutOfMemory);
    }
}

test "tag byte boundaries permit distinct Unicode spellings and exclude every control" {
    _ = try Tag.init("a" ** 54);
    _ = try Tag.init("é" ** 27);
    _ = try Tag.init(" ");
    _ = try Tag.init("Capacity");
    _ = try Tag.init("\u{200d}");
    for ([_][]const u8{ "", "a" ** 55, "é" ** 28, "capacity", "allocation", "\xff" }) |text| {
        try std.testing.expectError(error.InvalidTag, Tag.init(text));
    }
    for (0..0xa0) |codepoint| {
        if (codepoint > 0x1f and codepoint < 0x7f) continue;
        var bytes: [4]u8 = undefined;
        const size = try std.unicode.utf8Encode(@intCast(codepoint), &bytes);
        try std.testing.expectError(error.InvalidTag, Tag.init(bytes[0..size]));
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const command = try decode_command(arena.allocator(),
        \\{"command":"create_event","classes":{"é":1,"é":1," A ":1,"a":1},"timeout_seconds":1}
    );
    try std.testing.expectEqual(@as(usize, 4), command.create_event.classes.len);
    try std.testing.expectEqualStrings("é", command.create_event.classes[2].tag.slice());
    try std.testing.expectError(error.InvalidTag, decode_command(arena.allocator(),
        \\{"command":"create_event","classes":{"\u0063apacity":1},"timeout_seconds":1}
    ));
}

test "raw and compact boundaries reject entire inputs without admitting prefixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const input =
        \\{"command":"check_seats","event_id":"00000000-0000-0000-0000-000000000001"}
    ;
    const padded = try allocator.alloc(u8, 4097);
    @memset(padded, ' ');
    @memcpy(padded[0..input.len], input);
    _ = try decode_command(allocator, padded[0..4096]);
    try std.testing.expectError(error.InputTooLarge, decode_command(allocator, padded));
    for ([_]usize{ 4096, 98304, 16384 }) |limit| {
        const text = try allocator.alloc(u8, limit - 1);
        @memset(text, 'x');
        try std.testing.expectEqual(limit, try bounded_size(text[0 .. limit - 2], limit));
        try std.testing.expectError(
            error.EncodedValueTooLarge,
            encode_bounded(allocator, text, limit),
        );
    }
    const completion = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"SUCCESS\",\"payload\":\"{s}\"}}",
        .{"x" ** (98304 - 31)},
    );
    try std.testing.expectEqual(@as(usize, 98304), completion.len);
    _ = try operation.parseCompletionJSON(allocator, completion);
    const too_large = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"SUCCESS\",\"payload\":\"{s}\"}}",
        .{"x" ** (98304 - 30)},
    );
    try std.testing.expectError(
        error.ResultTooLarge,
        operation.parseCompletionJSON(allocator, too_large),
    );
}

test "admission authorizes event identity before readiness and class existence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const request: Command = .{ .reserve_seats = .{
        .event_id = 1,
        .class = try Tag.init("unknown"),
        .quantity = 1,
    } };
    const options: AdmissionOptions = .{
        .operation_id = 2,
        .tenant = "tenant-a",
        .result_queue = "https://sqs.example.invalid/results",
    };
    var event = try decode_event(allocator,
        \\{"tenant":"tenant-b","event_id":"00000000-0000-0000-0000-000000000001","ledger":1,"timeout_seconds":1,"capacity_account_id":"1","allocation_account_id":"2","state":"creating","classes":{"a":{"total":10,"tb_account_id":"3"}}}
    );
    try std.testing.expectError(error.EventUnavailable, admit(allocator, &request, null, &options));
    try std.testing.expectError(
        error.EventUnavailable,
        admit(allocator, &request, &event, &options),
    );
    event.tenant = "tenant-a";
    event.event_id = 3;
    try std.testing.expectError(
        error.EventUnavailable,
        admit(allocator, &request, &event, &options),
    );
    event.event_id = 1;
    try std.testing.expectError(error.EventNotReady, admit(allocator, &request, &event, &options));
    event.state = .failed;
    try std.testing.expectError(error.EventFailed, admit(allocator, &request, &event, &options));
    event.state = .ready;
    try std.testing.expectError(error.UnknownClass, admit(allocator, &request, &event, &options));
}

test "reserve and full confirm serializers bind authorized accounts and exact public Results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const event = try decode_event(allocator,
        \\{"tenant":"tenant-a","event_id":"00000000-0000-0000-0000-000000000001","ledger":1001,"timeout_seconds":30,"capacity_account_id":"1","allocation_account_id":"2","state":"ready","classes":{"a":{"total":10,"tb_account_id":"3"}}}
    );
    const options: AdmissionOptions = .{
        .operation_id = 2,
        .tenant = "tenant-a",
        .result_queue = "https://sqs.example.invalid/results",
    };
    const reserve: Command = .{ .reserve_seats = .{
        .event_id = 1,
        .class = try Tag.init("a"),
        .quantity = 2,
    } };
    _ = try admit(allocator, &reserve, &event, &options);
    const native = try encode_native_body(
        allocator,
        &.{ .command = &reserve, .event = &event, .attempt_id = 123 },
    );
    try std.testing.expectEqualStrings(
        \\{"create_accounts":[],"create_transfers":[{"id":"123","alias":"reserve-a","debit_account_id":"3","credit_account_id":"2","amount":"2","ledger":1001,"code":2,"flags":["pending"],"timeout":30}],"lookup_accounts":[]}
    , native);
    const context = try decode_context(allocator, try encode_context(allocator, &reserve, 123));
    try std.testing.expectEqual(@as(?u128, 123), context.reservation_id);
    const confirm: Command = .{ .confirm_seats = .{
        .event_id = 1,
        .class = try Tag.init("a"),
        .pending_id = 123,
    } };
    _ = try admit(allocator, &confirm, &event, &options);
    try std.testing.expectEqualStrings(
        \\{"create_accounts":[],"create_transfers":[{"id":"124","alias":"confirm-a","debit_account_id":"3","credit_account_id":"2","amount":"340282366920938463463374607431768211455","ledger":1001,"code":2,"flags":["post_pending_transfer"],"pending_id":"123"}],"lookup_accounts":[]}
    , try encode_native_body(
        allocator,
        &.{ .command = &confirm, .event = &event, .attempt_id = 124 },
    ));
    const reserve_result: Result = .{ .success = .{ .reserve_seats = .{
        .request = reserve.reserve_seats,
        .reservation_id = 123,
    } } };
    try std.testing.expectEqualStrings(
        \\{"type":"SUCCESS","payload":{"event_id":"00000000-0000-0000-0000-000000000001","class":"a","quantity":2,"reservation_id":"123"}}
    , try encode_result(allocator, &reserve_result));
    const confirm_result: Result = .{ .success = .{ .confirm_seats = confirm.confirm_seats } };
    try std.testing.expectEqualStrings(
        \\{"type":"SUCCESS","payload":{"event_id":"00000000-0000-0000-0000-000000000001","class":"a","reservation_id":"123"}}
    , try encode_result(allocator, &confirm_result));
    try std.testing.expectEqualStrings(
        \\{"type":"FAILURE","payload":{"code":"invalid_request"}}
    , try encode_result(allocator, &.{ .failure = .invalid_request }));
    try std.testing.expectError(
        error.InvalidContext,
        decode_context(allocator, try encode_command(allocator, &reserve)),
    );
    try std.testing.expectError(error.InvalidContext, encode_context(allocator, &reserve, null));
}

test "class count and normalized integers retain the accepted ceiling and number semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_]usize{ 0, 1, 31, 32 }) |count| {
        const classes = try allocator.alloc(Class, count);
        for (classes, 0..) |*class, index| {
            const text = try std.fmt.allocPrint(allocator, "class-{d:0>2}", .{index});
            class.* = .{ .tag = try Tag.init(text), .total = 1 };
        }
        const command: Command = .{ .create_event = .{ .classes = classes, .timeout_seconds = 1 } };
        if (count == 0 or count == 32) {
            try std.testing.expectError(error.InvalidClasses, encode_command(allocator, &command));
        } else {
            const decoded = try decode_command(allocator, try encode_command(allocator, &command));
            try std.testing.expectEqual(count, decoded.create_event.classes.len);
        }
    }
    const parsed = try operation.parseInputJSON(allocator,
        \\{"id":"00000000-0000-0000-0000-000000000001","name":"SeatReservation","body":{"command":"create_event","classes":{"a":1e0},"timeout_seconds":1.0}}
    , .{ .tenant = "tenant-a", .now = 1 });
    const envelope = try processor_message.encode(allocator, &.{
        .operation_id = parsed.id,
        .tenant = parsed.tenant,
        .body = parsed.body.?,
        .context = .null,
    });
    const message = try processor_message.decode(allocator, envelope);
    const command = try command_from_value(allocator, &message.body);
    try std.testing.expectEqual(@as(u32, 1), command.create_event.classes[0].total);
    try std.testing.expectEqual(@as(u32, 1), command.create_event.timeout_seconds);
}

test "metadata and Context accept exact raw boundaries and reject over-boundary input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const event_text =
        \\{"tenant":"tenant-a","event_id":"00000000-0000-0000-0000-000000000001","ledger":1,"timeout_seconds":1,"capacity_account_id":"1","allocation_account_id":"2","state":"creating","classes":{"a":{"total":1,"tb_account_id":"3"}}}
    ;
    const raw_event = try allocator.alloc(u8, 16385);
    @memset(raw_event, ' ');
    @memcpy(raw_event[0..event_text.len], event_text);
    _ = try decode_event(allocator, raw_event[0..16384]);
    try std.testing.expectError(error.InputTooLarge, decode_event(allocator, raw_event));
    const context_text =
        \\{"command":"check_seats","event_id":"00000000-0000-0000-0000-000000000001"}
    ;
    const raw_context = try allocator.alloc(u8, 4097);
    @memset(raw_context, ' ');
    @memcpy(raw_context[0..context_text.len], context_text);
    _ = try decode_context(allocator, raw_context[0..4096]);
    try std.testing.expectError(error.InputTooLarge, decode_context(allocator, raw_context));
}
