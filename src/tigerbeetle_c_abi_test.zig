const std = @import("std");
const c = @import("tigerbeetle_c");

const assert = std.debug.assert;

comptime {
    assert(@sizeOf(c.tb_uint128_t) == 16);
    assert(@sizeOf(c.tb_client_t) == 32);
    assert(@alignOf(c.tb_client_t) == 8);
    assert(@sizeOf(c.tb_packet_t) == 88);
    assert(@alignOf(c.tb_packet_t) == 8);
    assert(@sizeOf(c.tb_account_t) == 128);
    assert(@sizeOf(c.tb_transfer_t) == 128);
    assert(@sizeOf(c.tb_create_account_result_t) == 16);
    assert(@sizeOf(c.tb_create_transfer_result_t) == 16);

    assert(c.TB_OPERATION_LOOKUP_ACCOUNTS == 140);
    assert(c.TB_OPERATION_CREATE_ACCOUNTS == 146);
    assert(c.TB_OPERATION_CREATE_TRANSFERS == 147);
    assert(c.TB_CREATE_ACCOUNT_CREATED == std.math.maxInt(c_uint));
    assert(c.TB_CREATE_TRANSFER_CREATED == std.math.maxInt(c_uint));
    assert(c.TB_PACKET_OK == 0);
    assert(c.TB_INIT_SUCCESS == 0);
    assert(c.TB_CLIENT_OK == 0);
}

test "translated C ABI initializes and deinitializes the echo client" {
    const cluster_id: [16]u8 = @splat(0);
    const address = "3000";
    const address_len: u32 = @intCast(address.len);
    var client: c.tb_client_t = undefined;

    const init_status = c.tb_client_init_echo(
        &client,
        &cluster_id,
        address.ptr,
        address_len,
        0,
        completion_unexpected,
    );
    try std.testing.expectEqual(@as(c_uint, c.TB_INIT_SUCCESS), init_status);

    const deinit_status = c.tb_client_deinit(&client);
    try std.testing.expectEqual(@as(c_uint, c.TB_CLIENT_OK), deinit_status);
}

fn completion_unexpected(
    _: usize,
    _: [*c]c.tb_packet_t,
    _: u64,
    _: [*c]const u8,
    _: u32,
) callconv(.c) void {
    @panic("the ABI lifecycle smoke test does not submit a packet");
}
