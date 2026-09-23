const std = @import("std");
const builtin = @import("builtin");
const c = @import("tigerbeetle_c");

const assert = std.debug.assert;

pub const Account = c.tb_account_t;
pub const Transfer = c.tb_transfer_t;
pub const CreateAccountResult = c.tb_create_account_result_t;
pub const CreateTransferResult = c.tb_create_transfer_result_t;

pub const account_linked: u16 = @intCast(c.TB_ACCOUNT_LINKED);
pub const account_debits_must_not_exceed_credits: u16 = @intCast(
    c.TB_ACCOUNT_DEBITS_MUST_NOT_EXCEED_CREDITS,
);
pub const account_credits_must_not_exceed_debits: u16 = @intCast(
    c.TB_ACCOUNT_CREDITS_MUST_NOT_EXCEED_DEBITS,
);
pub const account_history: u16 = @intCast(c.TB_ACCOUNT_HISTORY);
pub const transfer_linked: u16 = @intCast(c.TB_TRANSFER_LINKED);
pub const transfer_pending: u16 = @intCast(c.TB_TRANSFER_PENDING);
pub const transfer_post_pending_transfer: u16 = @intCast(c.TB_TRANSFER_POST_PENDING_TRANSFER);
pub const transfer_void_pending_transfer: u16 = @intCast(c.TB_TRANSFER_VOID_PENDING_TRANSFER);
pub const account_created: u32 = @intCast(c.TB_CREATE_ACCOUNT_CREATED);
pub const account_exists: u32 = @intCast(c.TB_CREATE_ACCOUNT_EXISTS);
pub const account_linked_event_failed: u32 = @intCast(c.TB_CREATE_ACCOUNT_LINKED_EVENT_FAILED);
pub const transfer_created: u32 = @intCast(c.TB_CREATE_TRANSFER_CREATED);
pub const transfer_exists: u32 = @intCast(c.TB_CREATE_TRANSFER_EXISTS);
pub const transfer_linked_event_failed: u32 = @intCast(c.TB_CREATE_TRANSFER_LINKED_EVENT_FAILED);

/// Canonical names come from the pinned native constants, without the C family prefix.
pub fn create_account_status_name(status: u32) ?[]const u8 {
    return creation_status_name("TB_CREATE_ACCOUNT_", status);
}

pub fn create_transfer_status_name(status: u32) ?[]const u8 {
    return creation_status_name("TB_CREATE_TRANSFER_", status);
}

fn creation_status_name(comptime prefix: []const u8, status: u32) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    inline for (@typeInfo(c).@"struct".decls) |decl| {
        if (comptime std.mem.startsWith(u8, decl.name, prefix) and
            !std.mem.eql(u8, decl.name, prefix ++ "STATUS"))
        {
            if (status == @field(c, decl.name)) {
                const name = comptime blk: {
                    const suffix = decl.name[prefix.len..];
                    assert(suffix.len > 0);
                    var lowercase: [suffix.len]u8 = undefined;
                    _ = std.ascii.lowerString(&lowercase, suffix);
                    break :blk lowercase;
                };
                return &name;
            }
        }
    }
    return null;
}

test "canonical creation status names cover pinned native families" {
    @setEvalBranchQuota(100_000);
    inline for (.{ "TB_CREATE_ACCOUNT_", "TB_CREATE_TRANSFER_" }) |prefix| {
        var count: usize = 0;
        inline for (@typeInfo(c).@"struct".decls) |decl| {
            if (comptime std.mem.startsWith(u8, decl.name, prefix) and
                !std.mem.eql(u8, decl.name, prefix ++ "STATUS"))
            {
                const name = creation_status_name(prefix, @field(c, decl.name)).?;
                try std.testing.expect(std.ascii.eqlIgnoreCase(decl.name[prefix.len..], name));
                for (name) |byte| try std.testing.expect(!std.ascii.isUpper(byte));
                count += 1;
            }
        }
        try std.testing.expect(count > 0);
        try std.testing.expectEqualStrings("created", creation_status_name(prefix, 0xffffffff).?);
        try std.testing.expectEqualStrings("linked_event_failed", creation_status_name(prefix, 1).?);
        try std.testing.expect(creation_status_name(prefix, 0) == null);
        try std.testing.expect(creation_status_name(prefix, 123456) == null);
    }
    try std.testing.expectEqualStrings("exists", create_account_status_name(21).?);
    try std.testing.expectEqualStrings("debit_account_not_found", create_transfer_status_name(21).?);
    try std.testing.expectEqualStrings("exists", create_transfer_status_name(46).?);
    try std.testing.expect(create_account_status_name(46) == null);
}

pub fn create_account_succeeded(status: u32) bool {
    return status == c.TB_CREATE_ACCOUNT_CREATED or
        status == c.TB_CREATE_ACCOUNT_EXISTS;
}

pub fn create_transfer_succeeded(status: u32) bool {
    return status == c.TB_CREATE_TRANSFER_CREATED or
        status == c.TB_CREATE_TRANSFER_EXISTS;
}

pub const Error = error{
    OutOfMemory,
    Unexpected,
    AddressInvalid,
    AddressLimitExceeded,
    SystemResources,
    NetworkSubsystem,
    ClientInvalid,
    ClientClosed,
    TooMuchData,
    ClientEvicted,
    ClientReleaseTooLow,
    ClientReleaseTooHigh,
    InvalidOperation,
    InvalidDataSize,
    MalformedResult,
};

comptime {
    assert(@sizeOf(u128) == 16);
    assert(@sizeOf(c.tb_client_t) == 32);
    assert(@alignOf(c.tb_client_t) == 8);
    assert(@sizeOf(c.tb_packet_t) == 88);
    assert(@alignOf(c.tb_packet_t) == 8);
    assert(@sizeOf(Account) == 128);
    assert(@sizeOf(Transfer) == 128);
    assert(@sizeOf(CreateAccountResult) == 16);
    assert(@sizeOf(CreateTransferResult) == 16);
    assert(@sizeOf(CreateAccountResult) <= @sizeOf(Account));
    assert(@sizeOf(CreateTransferResult) <= @sizeOf(Transfer));

    assert(c.TB_OPERATION_LOOKUP_ACCOUNTS <= std.math.maxInt(u8));
    assert(c.TB_OPERATION_CREATE_ACCOUNTS <= std.math.maxInt(u8));
    assert(c.TB_OPERATION_CREATE_TRANSFERS <= std.math.maxInt(u8));
    assert(c.TB_PACKET_INVALID_DATA_SIZE <= std.math.maxInt(u8));
}

/// A synchronous, single-caller wrapper around the TigerBeetle C client.
///
/// The allocator's backing state and the `std.Io` implementation must outlive the client. All
/// output buffers are borrowed until return and must have capacity for every input. Requests and
/// `destroy` must never overlap for the same client.
pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    raw: c.tb_client_t,
    pinned_client_address: usize,
    pinned_raw_address: usize,
    initialized: bool,

    const Self = @This();

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        cluster_id: u128,
        addresses: []const u8,
    ) Error!*Self {
        return create_internal(allocator, io, cluster_id, addresses, .standard);
    }

    pub fn destroy(client: *Self) void {
        client.assert_pinned();
        assert(client.initialized);

        client.deinit_native();
        const allocator = client.allocator;
        allocator.destroy(client);
    }

    pub fn createAccounts(
        client: *Self,
        accounts: []const Account,
        output: []CreateAccountResult,
    ) Error!usize {
        assert(output.len >= accounts.len);
        if (accounts.len == 0) return 0;

        return client.submit(
            CreateAccountResult,
            operation_u8(c.TB_OPERATION_CREATE_ACCOUNTS),
            std.mem.sliceAsBytes(accounts),
            accounts.len,
            output,
        );
    }

    pub fn createTransfers(
        client: *Self,
        transfers: []const Transfer,
        output: []CreateTransferResult,
    ) Error!usize {
        assert(output.len >= transfers.len);
        if (transfers.len == 0) return 0;

        return client.submit(
            CreateTransferResult,
            operation_u8(c.TB_OPERATION_CREATE_TRANSFERS),
            std.mem.sliceAsBytes(transfers),
            transfers.len,
            output,
        );
    }

    /// Missing IDs have no corresponding result, so callers must match returned `Account.id`s.
    pub fn lookupAccounts(client: *Self, ids: []const u128, output: []Account) Error!usize {
        assert(output.len >= ids.len);
        if (ids.len == 0) return 0;

        return client.submit(
            Account,
            operation_u8(c.TB_OPERATION_LOOKUP_ACCOUNTS),
            std.mem.sliceAsBytes(ids),
            ids.len,
            output,
        );
    }

    fn create_echo(
        allocator: std.mem.Allocator,
        io: std.Io,
        cluster_id: u128,
        addresses: []const u8,
    ) Error!*Self {
        return create_internal(allocator, io, cluster_id, addresses, .echo);
    }

    fn create_internal(
        allocator: std.mem.Allocator,
        io: std.Io,
        cluster_id: u128,
        addresses: []const u8,
        init_kind: InitKind,
    ) Error!*Self {
        if (addresses.len > std.math.maxInt(u32)) {
            return error.AddressLimitExceeded;
        }

        const client = try allocator.create(Self);
        errdefer allocator.destroy(client);

        client.* = .{
            .allocator = allocator,
            .io = io,
            .raw = undefined,
            .pinned_client_address = @intFromPtr(client),
            .pinned_raw_address = @intFromPtr(&client.raw),
            .initialized = false,
        };
        client.assert_pinned();

        const cluster_id_le = encode_u128_le(cluster_id);
        const address_size: u32 = @intCast(addresses.len);
        const completion_context = client.pinned_client_address;
        const status = switch (init_kind) {
            .standard => c.tb_client_init(
                &client.raw,
                &cluster_id_le,
                @ptrCast(addresses.ptr),
                address_size,
                completion_context,
                on_completion,
            ),
            .echo => c.tb_client_init_echo(
                &client.raw,
                &cluster_id_le,
                @ptrCast(addresses.ptr),
                address_size,
                completion_context,
                on_completion,
            ),
        };
        try check_init_status(status);

        client.initialized = true;
        client.assert_pinned();
        return client;
    }

    fn submit(
        client: *Self,
        comptime Result: type,
        operation: u8,
        input: []const u8,
        result_count_max: usize,
        results: []Result,
    ) Error!usize {
        return client.submit_with(
            Result,
            operation,
            input,
            result_count_max,
            results,
            c.tb_client_submit,
        );
    }

    fn submit_with(
        client: *Self,
        comptime Result: type,
        operation: u8,
        input: []const u8,
        result_count_max: usize,
        results: []Result,
        comptime submit_native: anytype,
    ) Error!usize {
        assert(results.len >= result_count_max);
        comptime assert(@sizeOf(Result) > 0);
        if (!client.initialized) {
            return error.ClientClosed;
        }
        if (input.len > std.math.maxInt(u32)) {
            return error.TooMuchData;
        }

        client.assert_pinned();

        var request: Request = .{
            .io = client.io,
            .client_address = client.pinned_client_address,
            .result_buffer = std.mem.sliceAsBytes(results[0..result_count_max]),
            .result_alignment = @alignOf(Result),
            .result_element_size = @sizeOf(Result),
            .packet = undefined,
        };
        request.pin();
        request.prepare_packet(operation, input);

        try check_client_status(submit_native(&client.raw, &request.packet));
        request.wait();
        try check_packet_status(request.packet.status);

        const result_count = try request.result_count(Result, result_count_max);
        if (operation != operation_u8(c.TB_OPERATION_LOOKUP_ACCOUNTS) and
            result_count != result_count_max) return error.MalformedResult;
        return result_count;
    }

    fn deinit_native(client: *Self) void {
        client.assert_pinned();
        assert(client.initialized);

        const status = c.tb_client_deinit(&client.raw);
        assert(status == c.TB_CLIENT_OK);
        client.initialized = false;
        client.assert_pinned();
    }

    fn assert_pinned(client: *const Self) void {
        assert(client.pinned_client_address == @intFromPtr(client));
        assert(client.pinned_raw_address == @intFromPtr(&client.raw));
    }
};

const InitKind = enum {
    standard,
    echo,
};

const Request = struct {
    io: std.Io,
    event: std.Io.Event = .unset,
    callback_finished: std.atomic.Value(bool) = .init(false),
    client_address: usize,
    result_buffer: []u8,
    result_alignment: usize = 1,
    result_element_size: usize = 1,
    result_size: usize = 0,
    callback_error: ?Error = null,
    packet: c.tb_packet_t,
    pinned_request_address: usize = 0,
    pinned_packet_address: usize = 0,

    fn pin(request: *Request) void {
        assert(request.pinned_request_address == 0);
        assert(request.pinned_packet_address == 0);

        request.pinned_request_address = @intFromPtr(request);
        request.pinned_packet_address = @intFromPtr(&request.packet);
        request.assert_pinned();
    }

    fn prepare_packet(request: *Request, operation: u8, input: []const u8) void {
        request.assert_pinned();
        assert(input.len > 0);
        assert(input.len <= std.math.maxInt(u32));

        request.packet.user_data = request;
        request.packet.data = @ptrCast(@constCast(input.ptr));
        request.packet.data_size = @intCast(input.len);
        request.packet.user_tag = 0;
        request.packet.operation = operation;
        request.packet.status = packet_status_u8(c.TB_PACKET_OK);
    }

    fn wait(request: *Request) void {
        request.assert_pinned();
        request.event.waitUncancelable(request.io);
        assert(request.event.isSet());
        // Event.set may still be inside futexWake after the waiter observes the event.
        // This final release/acquire handshake keeps that event storage alive as well.
        while (!request.callback_finished.load(.acquire)) {
            std.atomic.spinLoopHint();
        }
        request.assert_pinned();
    }

    fn complete(
        request: *Request,
        result: ?[*]const u8,
        result_size_raw: u32,
    ) void {
        request.assert_pinned();
        assert(!request.event.isSet());

        const result_size: usize = @intCast(result_size_raw);
        if (result_size > request.result_buffer.len or
            result_size % request.result_element_size != 0)
        {
            request.callback_error = error.MalformedResult;
        } else if (result_size > 0) {
            if (result) |source| {
                if (@intFromPtr(source) % request.result_alignment != 0) {
                    request.callback_error = error.MalformedResult;
                } else {
                    @memcpy(request.result_buffer[0..result_size], source[0..result_size]);
                    request.result_size = result_size;
                }
            } else {
                request.callback_error = error.MalformedResult;
            }
        } else {
            request.result_size = 0;
        }

        request.event.set(request.io);
        // Last access to borrowed request memory, including the event, on the callback thread.
        request.callback_finished.store(true, .release);
    }

    fn result_count(
        request: *const Request,
        comptime Result: type,
        result_count_max: usize,
    ) Error!usize {
        comptime assert(@sizeOf(Result) > 0);
        request.assert_pinned();
        assert(request.event.isSet());
        if (request.callback_error) |callback_error| {
            return callback_error;
        }
        if (request.result_size % @sizeOf(Result) != 0) {
            return error.MalformedResult;
        }

        const count = request.result_size / @sizeOf(Result);
        if (count > result_count_max) {
            return error.MalformedResult;
        }
        assert(request.result_size <= request.result_buffer.len);
        return count;
    }

    fn assert_pinned(request: *const Request) void {
        assert(request.pinned_request_address == @intFromPtr(request));
        assert(request.pinned_packet_address == @intFromPtr(&request.packet));
    }
};

/// The native callback copies all temporary bytes before publishing the one-shot event. It never
/// calls the application allocator because the callback executes on TigerBeetle's native thread.
fn on_completion(
    completion_context: usize,
    packet_c: [*c]c.tb_packet_t,
    _: u64,
    result_c: [*c]const u8,
    result_size: u32,
) callconv(.c) void {
    assert(packet_c != null);
    const packet: *c.tb_packet_t = packet_c;
    assert(packet.user_data != null);
    const user_data = packet.user_data orelse unreachable;
    const request: *Request = @ptrCast(@alignCast(user_data));

    request.assert_pinned();
    assert(completion_context == request.client_address);
    assert(packet == &request.packet);

    const result: ?[*]const u8 = if (result_c == null) null else @ptrCast(result_c);
    request.complete(result, result_size);
}

fn encode_u128_le(value: u128) [16]u8 {
    var bytes: [16]u8 = undefined;
    for (0..bytes.len) |index| {
        const shift: u7 = @intCast(index * 8);
        bytes[index] = @truncate(value >> shift);
    }
    return bytes;
}

fn operation_u8(operation: c_uint) u8 {
    assert(operation <= std.math.maxInt(u8));
    return @intCast(operation);
}

fn packet_status_u8(status: c_uint) u8 {
    assert(status <= std.math.maxInt(u8));
    return @intCast(status);
}

fn check_init_status(status: c.TB_INIT_STATUS) Error!void {
    switch (status) {
        c.TB_INIT_SUCCESS => {},
        c.TB_INIT_UNEXPECTED => return error.Unexpected,
        c.TB_INIT_OUT_OF_MEMORY => return error.OutOfMemory,
        c.TB_INIT_ADDRESS_INVALID => return error.AddressInvalid,
        c.TB_INIT_ADDRESS_LIMIT_EXCEEDED => return error.AddressLimitExceeded,
        c.TB_INIT_SYSTEM_RESOURCES => return error.SystemResources,
        c.TB_INIT_NETWORK_SUBSYSTEM => return error.NetworkSubsystem,
        else => return error.Unexpected,
    }
}

fn check_client_status(status: c.TB_CLIENT_STATUS) Error!void {
    switch (status) {
        c.TB_CLIENT_OK => {},
        c.TB_CLIENT_INVALID => return error.ClientInvalid,
        else => return error.ClientInvalid,
    }
}

fn check_packet_status(status: u8) Error!void {
    switch (status) {
        c.TB_PACKET_OK => {},
        c.TB_PACKET_TOO_MUCH_DATA => return error.TooMuchData,
        c.TB_PACKET_CLIENT_EVICTED => return error.ClientEvicted,
        c.TB_PACKET_CLIENT_RELEASE_TOO_LOW => return error.ClientReleaseTooLow,
        c.TB_PACKET_CLIENT_RELEASE_TOO_HIGH => return error.ClientReleaseTooHigh,
        c.TB_PACKET_CLIENT_SHUTDOWN => return error.ClientClosed,
        c.TB_PACKET_INVALID_OPERATION => return error.InvalidOperation,
        c.TB_PACKET_INVALID_DATA_SIZE => return error.InvalidDataSize,
        else => return error.MalformedResult,
    }
}

test "cluster ID encoding is explicitly little-endian" {
    const zero: [16]u8 = @splat(0);
    try std.testing.expectEqual(zero, encode_u128_le(0));

    const cluster_id: u128 = 0xa1a2a3a4_b1b2c1c2_d1d2e1e2_e3e4e5e6;
    const expected = [16]u8{
        0xe6, 0xe5, 0xe4, 0xe3,
        0xe2, 0xe1, 0xd2, 0xd1,
        0xc2, 0xc1, 0xb2, 0xb1,
        0xa4, 0xa3, 0xa2, 0xa1,
    };
    try std.testing.expectEqual(expected, encode_u128_le(cluster_id));
}

test "all initialization statuses map to wrapper errors" {
    try check_init_status(c.TB_INIT_SUCCESS);
    try std.testing.expectError(error.Unexpected, check_init_status(c.TB_INIT_UNEXPECTED));
    try std.testing.expectError(error.OutOfMemory, check_init_status(c.TB_INIT_OUT_OF_MEMORY));
    try std.testing.expectError(error.AddressInvalid, check_init_status(c.TB_INIT_ADDRESS_INVALID));
    try std.testing.expectError(
        error.AddressLimitExceeded,
        check_init_status(c.TB_INIT_ADDRESS_LIMIT_EXCEEDED),
    );
    try std.testing.expectError(
        error.SystemResources,
        check_init_status(c.TB_INIT_SYSTEM_RESOURCES),
    );
    try std.testing.expectError(
        error.NetworkSubsystem,
        check_init_status(c.TB_INIT_NETWORK_SUBSYSTEM),
    );
    try std.testing.expectError(error.Unexpected, check_init_status(std.math.maxInt(c_uint)));
}

test "all client statuses map to wrapper errors" {
    try check_client_status(c.TB_CLIENT_OK);
    try std.testing.expectError(error.ClientInvalid, check_client_status(c.TB_CLIENT_INVALID));
    try std.testing.expectError(error.ClientInvalid, check_client_status(std.math.maxInt(c_uint)));
}

test "all packet statuses map to wrapper errors" {
    try check_packet_status(packet_status_u8(c.TB_PACKET_OK));
    try std.testing.expectError(
        error.TooMuchData,
        check_packet_status(packet_status_u8(c.TB_PACKET_TOO_MUCH_DATA)),
    );
    try std.testing.expectError(
        error.ClientEvicted,
        check_packet_status(packet_status_u8(c.TB_PACKET_CLIENT_EVICTED)),
    );
    try std.testing.expectError(
        error.ClientReleaseTooLow,
        check_packet_status(packet_status_u8(c.TB_PACKET_CLIENT_RELEASE_TOO_LOW)),
    );
    try std.testing.expectError(
        error.ClientReleaseTooHigh,
        check_packet_status(packet_status_u8(c.TB_PACKET_CLIENT_RELEASE_TOO_HIGH)),
    );
    try std.testing.expectError(
        error.ClientClosed,
        check_packet_status(packet_status_u8(c.TB_PACKET_CLIENT_SHUTDOWN)),
    );
    try std.testing.expectError(
        error.InvalidOperation,
        check_packet_status(packet_status_u8(c.TB_PACKET_INVALID_OPERATION)),
    );
    try std.testing.expectError(
        error.InvalidDataSize,
        check_packet_status(packet_status_u8(c.TB_PACKET_INVALID_DATA_SIZE)),
    );
    try std.testing.expectError(error.MalformedResult, check_packet_status(std.math.maxInt(u8)));
}

test "linux client init maps file descriptor exhaustion to SystemResources" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const original_limits = try std.posix.getrlimit(.NOFILE);
    defer std.posix.setrlimit(.NOFILE, original_limits) catch unreachable;

    var exhausted_limits = original_limits;
    exhausted_limits.cur = 0;
    try std.posix.setrlimit(.NOFILE, exhausted_limits);

    const result = Client.create(
        std.testing.allocator,
        std.testing.io,
        0,
        "127.0.0.1:3000",
    );
    try std.testing.expectError(error.SystemResources, result);
}

test "account creation accepts only created and identical exists" {
    try std.testing.expect(create_account_succeeded(c.TB_CREATE_ACCOUNT_CREATED));
    try std.testing.expect(create_account_succeeded(c.TB_CREATE_ACCOUNT_EXISTS));
    try std.testing.expect(!create_account_succeeded(
        c.TB_CREATE_ACCOUNT_EXISTS_WITH_DIFFERENT_LEDGER,
    ));
    try std.testing.expect(!create_account_succeeded(
        c.TB_CREATE_ACCOUNT_LEDGER_MUST_NOT_BE_ZERO,
    ));
}

test "transfer creation accepts only created and identical exists" {
    try std.testing.expect(create_transfer_succeeded(c.TB_CREATE_TRANSFER_CREATED));
    try std.testing.expect(create_transfer_succeeded(c.TB_CREATE_TRANSFER_EXISTS));
    try std.testing.expect(!create_transfer_succeeded(
        c.TB_CREATE_TRANSFER_EXISTS_WITH_DIFFERENT_AMOUNT,
    ));
    try std.testing.expect(!create_transfer_succeeded(
        c.TB_CREATE_TRANSFER_CREDIT_ACCOUNT_NOT_FOUND,
    ));
}

test "empty public operations borrow storage without native submission" {
    var client: Client = undefined;
    client = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .raw = undefined,
        .pinned_client_address = @intFromPtr(&client),
        .pinned_raw_address = @intFromPtr(&client.raw),
        // Any attempted submission would return ClientClosed and fail this test.
        .initialized = false,
    };

    const account_results = try client.createAccounts(&.{}, &.{});
    const transfer_results = try client.createTransfers(&.{}, &.{});
    const accounts = try client.lookupAccounts(&.{}, &.{});

    try std.testing.expectEqual(@as(usize, 0), account_results);
    try std.testing.expectEqual(@as(usize, 0), transfer_results);
    try std.testing.expectEqual(@as(usize, 0), accounts);
}

test "native echo completion copies into borrowed results" {
    const client = try Client.create_echo(std.testing.allocator, std.testing.io, 0, "3000");
    defer client.destroy();

    var account_a: Account = std.mem.zeroes(Account);
    account_a.id = 0x0102030405060708;
    account_a.ledger = 19;
    account_a.code = 7;
    var account_b: Account = std.mem.zeroes(Account);
    account_b.id = 0x8877665544332211;
    account_b.ledger = 23;
    account_b.code = 11;
    const input = [_]Account{ account_a, account_b };

    var output: [5]Account = undefined;
    const count = try client.submit(
        Account,
        operation_u8(c.TB_OPERATION_CREATE_ACCOUNTS),
        std.mem.sliceAsBytes(input[0..]),
        input.len,
        &output,
    );
    const echoed = output[0..count];

    try std.testing.expectEqual(input.len, echoed.len);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(input[0..]),
        std.mem.sliceAsBytes(echoed),
    );
}

test "completion may precede the uncancelable wait" {
    var result_buffer: [4]u8 = undefined;
    var request: Request = .{
        .io = std.testing.io,
        .client_address = 1,
        .result_buffer = &result_buffer,
        .packet = undefined,
    };
    request.pin();

    const source = [_]u8{ 1, 2, 3, 4 };
    request.complete(source[0..].ptr, source.len);
    request.wait();

    try std.testing.expectEqualSlices(u8, &source, &result_buffer);
    try std.testing.expectEqual(source.len, try request.result_count(u8, source.len));
}

test "callback rejects invalid result pointers and sizes" {
    var null_buffer: [4]u8 = undefined;
    var null_request: Request = .{
        .io = std.testing.io,
        .client_address = 1,
        .result_buffer = &null_buffer,
        .packet = undefined,
    };
    null_request.pin();
    null_request.complete(null, 1);
    null_request.wait();
    try std.testing.expectError(error.MalformedResult, null_request.result_count(u8, 4));

    var oversized_buffer: [4]u8 = undefined;
    var oversized_request: Request = .{
        .io = std.testing.io,
        .client_address = 1,
        .result_buffer = &oversized_buffer,
        .packet = undefined,
    };
    oversized_request.pin();
    const oversized_source = [_]u8{ 1, 2, 3, 4, 5 };
    oversized_request.complete(oversized_source[0..].ptr, oversized_source.len);
    oversized_request.wait();
    try std.testing.expectError(error.MalformedResult, oversized_request.result_count(u8, 4));

    var misaligned_buffer: [4]u8 = undefined;
    var misaligned_request: Request = .{
        .io = std.testing.io,
        .client_address = 1,
        .result_buffer = &misaligned_buffer,
        .packet = undefined,
    };
    misaligned_request.pin();
    const misaligned_source = [_]u8{ 1, 2, 3 };
    misaligned_request.complete(misaligned_source[0..].ptr, misaligned_source.len);
    misaligned_request.wait();
    try std.testing.expectError(
        error.MalformedResult,
        misaligned_request.result_count(u16, 2),
    );
}

test "echo client remains pinned through native deinitialization" {
    const client = try Client.create_echo(
        std.testing.allocator,
        std.testing.io,
        0xa1a2a3a4_b1b2c1c2_d1d2e1e2_e3e4e5e6,
        "3000",
    );
    defer {
        if (client.initialized) {
            client.deinit_native();
        }
        std.testing.allocator.destroy(client);
    }

    const client_address = @intFromPtr(client);
    const raw_address = @intFromPtr(&client.raw);
    try std.testing.expectEqual(client_address, client.pinned_client_address);
    try std.testing.expectEqual(raw_address, client.pinned_raw_address);

    var completion_context: usize = 0;
    try check_client_status(c.tb_client_completion_context(&client.raw, &completion_context));
    try std.testing.expectEqual(client_address, completion_context);

    client.deinit_native();
    try std.testing.expectEqual(client_address, @intFromPtr(client));
    try std.testing.expectEqual(raw_address, @intFromPtr(&client.raw));
}

// This fixture is the approved C submission seam: it never acquires ownership on error.
const SubmitFixture = struct {
    fn invalid(_: [*c]c.tb_client_t, _: [*c]c.tb_packet_t) callconv(.c) c.TB_CLIENT_STATUS {
        return c.TB_CLIENT_INVALID;
    }

    fn reply(comptime byte_count: u32) type {
        return struct {
            fn submit(_: [*c]c.tb_client_t, packet: [*c]c.tb_packet_t) callconv(.c) c.TB_CLIENT_STATUS {
                const request: *Request = @ptrCast(@alignCast(packet.*.user_data.?));
                var source: [48]u8 align(16) = @splat(0);
                on_completion(request.client_address, packet, 0, &source, byte_count);
                @memset(&source, 255);
                return c.TB_CLIENT_OK;
            }
        };
    }

    fn empty(_: [*c]c.tb_client_t, packet: [*c]c.tb_packet_t) callconv(.c) c.TB_CLIENT_STATUS {
        const request: *Request = @ptrCast(@alignCast(packet.*.user_data.?));
        on_completion(request.client_address, packet, 0, null, 0);
        return c.TB_CLIENT_OK;
    }
};

test "creation rejects an empty reply while lookup accepts missing accounts" {
    const client = try Client.create_echo(std.testing.allocator, std.testing.io, 0, "3000");
    defer client.destroy();
    const input = [_]u128{42};
    var output: [1]CreateAccountResult = undefined;
    try std.testing.expectError(error.MalformedResult, client.submit_with(
        CreateAccountResult,
        operation_u8(c.TB_OPERATION_CREATE_ACCOUNTS),
        std.mem.sliceAsBytes(&input),
        1,
        &output,
        SubmitFixture.empty,
    ));
    var accounts: [1]Account = undefined;
    try std.testing.expectEqual(@as(usize, 0), try client.submit_with(
        Account,
        operation_u8(c.TB_OPERATION_LOOKUP_ACCOUNTS),
        std.mem.sliceAsBytes(&input),
        1,
        &accounts,
        SubmitFixture.empty,
    ));
}

test "immediate submit error leaves output reusable for another call and deinit" {
    const client = try Client.create_echo(std.testing.allocator, std.testing.io, 0, "3000");
    defer client.destroy();
    const input = [_]Account{std.mem.zeroes(Account)};
    var output = [_]Account{std.mem.zeroes(Account)};
    output[0].id = 99;
    try std.testing.expectError(error.ClientInvalid, client.submit_with(
        Account,
        operation_u8(c.TB_OPERATION_CREATE_ACCOUNTS),
        std.mem.sliceAsBytes(&input),
        1,
        &output,
        SubmitFixture.invalid,
    ));
    try std.testing.expectEqual(@as(u128, 99), output[0].id);
    try std.testing.expectEqual(@as(usize, 1), try client.submit(
        Account,
        operation_u8(c.TB_OPERATION_CREATE_ACCOUNTS),
        std.mem.sliceAsBytes(&input),
        1,
        &output,
    ));
    try std.testing.expectEqual(@as(u128, 0), output[0].id);
}

const DelayedCompletion = struct {
    fn run(request: *Request) void {
        // Delay until the caller actually waits; no scheduling sleeps or timing oracle.
        while (@atomicLoad(std.Io.Event, &request.event, .acquire) != .waiting) {
            std.atomic.spinLoopHint();
        }
        var source = [_]u8{ 7, 8, 9, 10 };
        request.complete(&source, source.len);
        @memset(&source, 0);
    }
};

test "delayed callback copies ephemeral bytes before borrowed storage can be reused" {
    var output: [4]u8 = undefined;
    var request: Request = .{
        .io = std.testing.io,
        .client_address = 1,
        .result_buffer = &output,
        .packet = undefined,
    };
    request.pin();
    const thread = try std.Thread.spawn(.{}, DelayedCompletion.run, .{&request});
    defer thread.join();
    request.wait();
    try std.testing.expect(request.callback_finished.load(.acquire));
    try std.testing.expectEqualSlices(u8, &.{ 7, 8, 9, 10 }, &output);
    @memset(&output, 42);
}

test "callback rejects unaligned source without modifying borrowed output" {
    var output = [_]u8{42} ** 16;
    var source: [17]u8 align(16) = @splat(0);
    var request: Request = .{
        .io = std.testing.io,
        .client_address = 1,
        .result_buffer = &output,
        .result_alignment = 16,
        .result_element_size = 16,
        .packet = undefined,
    };
    request.pin();
    request.complete(source[1..].ptr, 16);
    request.wait();
    try std.testing.expectError(error.MalformedResult, request.result_count(u128, 1));
    try std.testing.expectEqualSlices(u8, &(@as([16]u8, @splat(42))), &output);
}

test "request path needs no allocator and preserves unused output capacity" {
    const client = try Client.create_echo(std.testing.allocator, std.testing.io, 0, "3000");
    defer client.destroy();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    client.allocator = failing.allocator();
    defer client.allocator = std.testing.allocator;
    const input = [_]Account{std.mem.zeroes(Account)};
    const output = try std.testing.allocator.alloc(Account, 2);
    defer std.testing.allocator.free(output);
    output[1] = std.mem.zeroes(Account);
    output[1].id = 123;
    for (0..3) |_| {
        try std.testing.expectEqual(@as(usize, 1), try client.submit(
            Account,
            operation_u8(c.TB_OPERATION_CREATE_ACCOUNTS),
            std.mem.sliceAsBytes(&input),
            1,
            output,
        ));
    }
    try std.testing.expectEqual(@as(u128, 123), output[1].id);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "client allocation failure releases initialization ownership" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Client.create(
        failing.allocator(),
        std.testing.io,
        0,
        "3000",
    ));
}

test "both creation families require exact counts including zero short and excess replies" {
    const client = try Client.create_echo(std.testing.allocator, std.testing.io, 0, "3000");
    defer client.destroy();
    const input = [_]u128{ 11, 22 };
    inline for (.{ CreateAccountResult, CreateTransferResult }) |Result| {
        const operation = if (Result == CreateAccountResult)
            operation_u8(c.TB_OPERATION_CREATE_ACCOUNTS)
        else
            operation_u8(c.TB_OPERATION_CREATE_TRANSFERS);
        var output: [3]Result = undefined;
        inline for (.{ 0, 1, 16, 48 }) |byte_count| {
            try std.testing.expectError(error.MalformedResult, client.submit_with(
                Result,
                operation,
                std.mem.sliceAsBytes(&input),
                2,
                &output,
                SubmitFixture.reply(byte_count).submit,
            ));
        }
        try std.testing.expectEqual(@as(usize, 2), try client.submit_with(
            Result,
            operation,
            std.mem.sliceAsBytes(&input),
            2,
            &output,
            SubmitFixture.reply(32).submit,
        ));
        try std.testing.expectEqual(@as(u32, 0), output[0].status);
    }
}

test "native submit rejects a closed handle without acquiring the packet" {
    const client = try Client.create_echo(std.testing.allocator, std.testing.io, 0, "3000");
    defer std.testing.allocator.destroy(client);
    client.deinit_native();
    var packet: c.tb_packet_t = std.mem.zeroes(c.tb_packet_t);
    packet.user_tag = 123;
    try std.testing.expectError(error.ClientInvalid, check_client_status(
        c.tb_client_submit(&client.raw, &packet),
    ));
    try std.testing.expectEqual(@as(u64, 123), packet.user_tag);
}

test "full native batch uses bounded off-stack borrowed buffers" {
    const count = 8189;
    const client = try Client.create_echo(std.testing.allocator, std.testing.io, 0, "3000");
    defer client.destroy();
    const input = try std.testing.allocator.alloc(Account, count);
    defer std.testing.allocator.free(input);
    for (input, 0..) |*account, index| {
        account.* = std.mem.zeroes(Account);
        account.id = index + 1;
    }
    const output = try std.testing.allocator.alloc(Account, count);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqual(@as(usize, count), try client.submit(
        Account,
        operation_u8(c.TB_OPERATION_CREATE_ACCOUNTS),
        std.mem.sliceAsBytes(input),
        count,
        output,
    ));
    try std.testing.expectEqual(@as(u128, 1), output[0].id);
    try std.testing.expectEqual(@as(u128, 8189), output[count - 1].id);
}
