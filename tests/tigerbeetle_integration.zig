const std = @import("std");
const tigerbeetle = @import("tigerbeetle");
const c = @import("tigerbeetle_c");

const assert = std.debug.assert;

const cluster_id: u128 = 0;
const cluster_addresses = "127.0.0.1:3000";
const ledger: u32 = 1;
const account_code: u16 = 1;
const transfer_code: u16 = 1;
const transfer_amount: u128 = 10;
const linked_transfer_amount_total: u128 = transfer_amount * 2;
const unique_id_count = 19;

const account_linked_flag: u16 = @intCast(c.TB_ACCOUNT_LINKED);
const account_created: u32 = @intCast(c.TB_CREATE_ACCOUNT_CREATED);
const account_exists: u32 = @intCast(c.TB_CREATE_ACCOUNT_EXISTS);
const account_linked_event_failed: u32 = @intCast(
    c.TB_CREATE_ACCOUNT_LINKED_EVENT_FAILED,
);
const account_linked_event_chain_open: u32 = @intCast(
    c.TB_CREATE_ACCOUNT_LINKED_EVENT_CHAIN_OPEN,
);
const account_ledger_must_not_be_zero: u32 = @intCast(
    c.TB_CREATE_ACCOUNT_LEDGER_MUST_NOT_BE_ZERO,
);
const transfer_linked_flag: u16 = @intCast(c.TB_TRANSFER_LINKED);
const transfer_created: u32 = @intCast(c.TB_CREATE_TRANSFER_CREATED);
const transfer_linked_event_failed: u32 = @intCast(
    c.TB_CREATE_TRANSFER_LINKED_EVENT_FAILED,
);
const transfer_linked_event_chain_open: u32 = @intCast(
    c.TB_CREATE_TRANSFER_LINKED_EVENT_CHAIN_OPEN,
);
const debit_account_not_found: u32 = @intCast(
    c.TB_CREATE_TRANSFER_DEBIT_ACCOUNT_NOT_FOUND,
);

comptime {
    assert(c.TB_ACCOUNT_LINKED > 0);
    assert(c.TB_ACCOUNT_LINKED <= std.math.maxInt(u16));
    assert(c.TB_CREATE_ACCOUNT_CREATED <= std.math.maxInt(u32));
    assert(c.TB_CREATE_ACCOUNT_EXISTS <= std.math.maxInt(u32));
    assert(c.TB_CREATE_ACCOUNT_LINKED_EVENT_FAILED <= std.math.maxInt(u32));
    assert(c.TB_CREATE_ACCOUNT_LINKED_EVENT_CHAIN_OPEN <= std.math.maxInt(u32));
    assert(c.TB_CREATE_ACCOUNT_LEDGER_MUST_NOT_BE_ZERO <= std.math.maxInt(u32));
    assert(c.TB_TRANSFER_LINKED > 0);
    assert(c.TB_TRANSFER_LINKED <= std.math.maxInt(u16));
    assert(c.TB_CREATE_TRANSFER_CREATED <= std.math.maxInt(u32));
    assert(c.TB_CREATE_TRANSFER_LINKED_EVENT_FAILED <= std.math.maxInt(u32));
    assert(c.TB_CREATE_TRANSFER_LINKED_EVENT_CHAIN_OPEN <= std.math.maxInt(u32));
    assert(c.TB_CREATE_TRANSFER_DEBIT_ACCOUNT_NOT_FOUND <= std.math.maxInt(u32));
    assert(transfer_amount > 0);
    assert(linked_transfer_amount_total > transfer_amount);
    assert(unique_id_count <= 256);
}

const TestIds = struct {
    debit_account: u128,
    credit_account: u128,
    missing_lookup_account: u128,
    posted_transfer: u128,
    missing_debit_account: u128,
    rejected_transfer: u128,
    committed_account_first: u128,
    committed_account_second: u128,
    rolled_back_account: u128,
    invalid_ledger_account: u128,
    open_chain_account: u128,
    linked_debit_account: u128,
    linked_credit_account: u128,
    committed_transfer_first: u128,
    committed_transfer_second: u128,
    rolled_back_transfer: u128,
    linked_missing_debit_account: u128,
    invalid_debit_transfer: u128,
    open_chain_transfer: u128,

    fn generate(io: std.Io) !TestIds {
        const timestamp_ms_raw = std.Io.Clock.real.now(io).toMilliseconds();
        if (timestamp_ms_raw <= 0 or timestamp_ms_raw > std.math.maxInt(u48)) {
            return error.SystemClockOutOfRange;
        }

        var random_source = std.Random.IoSource{ .io = io };
        const random = random_source.interface();
        const random_tail_mask = std.math.maxInt(u80) - 0xff;
        const random_tail = random.int(u80) & random_tail_mask;
        const timestamp_ms: u48 = @intCast(timestamp_ms_raw);
        const base_id = (@as(u128, timestamp_ms) << 80) | @as(u128, random_tail);

        const ids: TestIds = .{
            .debit_account = base_id,
            .credit_account = base_id + 1,
            .missing_lookup_account = base_id + 2,
            .posted_transfer = base_id + 3,
            .missing_debit_account = base_id + 4,
            .rejected_transfer = base_id + 5,
            .committed_account_first = base_id + 6,
            .committed_account_second = base_id + 7,
            .rolled_back_account = base_id + 8,
            .invalid_ledger_account = base_id + 9,
            .open_chain_account = base_id + 10,
            .linked_debit_account = base_id + 11,
            .linked_credit_account = base_id + 12,
            .committed_transfer_first = base_id + 13,
            .committed_transfer_second = base_id + 14,
            .rolled_back_transfer = base_id + 15,
            .linked_missing_debit_account = base_id + 16,
            .invalid_debit_transfer = base_id + 17,
            .open_chain_transfer = base_id + 18,
        };
        ids.assert_valid();
        return ids;
    }

    fn assert_valid(ids: *const TestIds) void {
        const id_values = ids.values();
        for (id_values, 0..) |id, index| {
            assert(id != 0);
            assert(id != std.math.maxInt(u128));
            for (id_values[0..index]) |previous_id| {
                assert(id != previous_id);
            }
        }
    }

    fn values(ids: *const TestIds) [unique_id_count]u128 {
        return .{
            ids.debit_account,
            ids.credit_account,
            ids.missing_lookup_account,
            ids.posted_transfer,
            ids.missing_debit_account,
            ids.rejected_transfer,
            ids.committed_account_first,
            ids.committed_account_second,
            ids.rolled_back_account,
            ids.invalid_ledger_account,
            ids.open_chain_account,
            ids.linked_debit_account,
            ids.linked_credit_account,
            ids.committed_transfer_first,
            ids.committed_transfer_second,
            ids.rolled_back_transfer,
            ids.linked_missing_debit_account,
            ids.invalid_debit_transfer,
            ids.open_chain_transfer,
        };
    }

    fn print_failure(ids: *const TestIds, failure: anyerror) void {
        std.debug.print(
            "TigerBeetle live test failed: {s}\n" ++
                "  debit_account={x}\n" ++
                "  credit_account={x}\n" ++
                "  missing_lookup_account={x}\n" ++
                "  posted_transfer={x}\n" ++
                "  missing_debit_account={x}\n" ++
                "  rejected_transfer={x}\n" ++
                "  committed_account_first={x}\n" ++
                "  committed_account_second={x}\n" ++
                "  rolled_back_account={x}\n" ++
                "  invalid_ledger_account={x}\n" ++
                "  open_chain_account={x}\n" ++
                "  linked_debit_account={x}\n" ++
                "  linked_credit_account={x}\n" ++
                "  committed_transfer_first={x}\n" ++
                "  committed_transfer_second={x}\n" ++
                "  rolled_back_transfer={x}\n" ++
                "  linked_missing_debit_account={x}\n" ++
                "  invalid_debit_transfer={x}\n" ++
                "  open_chain_transfer={x}\n",
            .{
                @errorName(failure),
                ids.debit_account,
                ids.credit_account,
                ids.missing_lookup_account,
                ids.posted_transfer,
                ids.missing_debit_account,
                ids.rejected_transfer,
                ids.committed_account_first,
                ids.committed_account_second,
                ids.rolled_back_account,
                ids.invalid_ledger_account,
                ids.open_chain_account,
                ids.linked_debit_account,
                ids.linked_credit_account,
                ids.committed_transfer_first,
                ids.committed_transfer_second,
                ids.rolled_back_transfer,
                ids.linked_missing_debit_account,
                ids.invalid_debit_transfer,
                ids.open_chain_transfer,
            },
        );
    }
};

const AccountBalance = struct {
    debits_pending: u128,
    debits_posted: u128,
    credits_pending: u128,
    credits_posted: u128,

    fn from_account(account: *const tigerbeetle.Account) AccountBalance {
        assert(account.id != 0);
        assert(account.id != std.math.maxInt(u128));
        return .{
            .debits_pending = account.debits_pending,
            .debits_posted = account.debits_posted,
            .credits_pending = account.credits_pending,
            .credits_posted = account.credits_posted,
        };
    }
};

const AccountBalancePair = struct {
    debit_account: AccountBalance,
    credit_account: AccountBalance,
};

test "live account, transfer, and linked chain operations" {
    const ids = try TestIds.generate(std.testing.io);
    run_live_scenario(&ids) catch |failure| {
        ids.print_failure(failure);
        return failure;
    };
}

fn run_live_scenario(ids: *const TestIds) !void {
    ids.assert_valid();
    const client = try tigerbeetle.Client.create(
        std.testing.allocator,
        std.testing.io,
        cluster_id,
        cluster_addresses,
    );
    defer client.destroy();

    const accounts = [_]tigerbeetle.Account{
        make_account(ids.debit_account),
        make_account(ids.credit_account),
    };
    try create_accounts(client, &accounts);
    try resubmit_account(client, accounts[0]);
    try verify_initial_lookup(client, ids);
    try create_posted_transfer(client, ids);
    try expect_posted_balances(
        client,
        ids.debit_account,
        ids.credit_account,
        transfer_amount,
    );
    try reject_missing_debit_transfer(client, ids);
    try expect_posted_balances(
        client,
        ids.debit_account,
        ids.credit_account,
        transfer_amount,
    );

    try create_linked_accounts_successfully(client, ids);
    try roll_back_linked_accounts(client, ids);
    try reject_open_account_chain(client, ids);

    const linked_transfer_accounts = [_]tigerbeetle.Account{
        make_account(ids.linked_debit_account),
        make_account(ids.linked_credit_account),
    };
    try create_accounts(client, &linked_transfer_accounts);
    try expect_posted_balances(
        client,
        ids.linked_debit_account,
        ids.linked_credit_account,
        0,
    );
    try create_linked_transfers_successfully(client, ids);
    try roll_back_linked_transfers(client, ids);
    try reject_open_transfer_chain(client, ids);
}

fn create_accounts(
    client: *tigerbeetle.Client,
    accounts: *const [2]tigerbeetle.Account,
) !void {
    const results = try client.createAccounts(accounts);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(account_created, results[0].status);
    try std.testing.expectEqual(account_created, results[1].status);
}

fn resubmit_account(client: *tigerbeetle.Client, account: tigerbeetle.Account) !void {
    const results = try client.createAccounts(&.{account});
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(account_exists, results[0].status);
}

fn verify_initial_lookup(client: *tigerbeetle.Client, ids: *const TestIds) !void {
    const lookup_ids = [_]u128{
        ids.debit_account,
        ids.credit_account,
        ids.missing_lookup_account,
    };
    const accounts = try client.lookupAccounts(&lookup_ids);
    defer std.testing.allocator.free(accounts);

    try std.testing.expectEqual(@as(usize, 2), accounts.len);
    try std.testing.expect(find_account(accounts, ids.debit_account) != null);
    try std.testing.expect(find_account(accounts, ids.credit_account) != null);
    try std.testing.expect(find_account(accounts, ids.missing_lookup_account) == null);
}

fn create_posted_transfer(client: *tigerbeetle.Client, ids: *const TestIds) !void {
    const transfer = make_transfer(
        ids.posted_transfer,
        ids.debit_account,
        ids.credit_account,
    );
    const results = try client.createTransfers(&.{transfer});
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(transfer_created, results[0].status);
}

fn reject_missing_debit_transfer(
    client: *tigerbeetle.Client,
    ids: *const TestIds,
) !void {
    const transfer = make_transfer(
        ids.rejected_transfer,
        ids.missing_debit_account,
        ids.credit_account,
    );
    const results = try client.createTransfers(&.{transfer});
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(debit_account_not_found, results[0].status);
}

fn create_linked_accounts_successfully(
    client: *tigerbeetle.Client,
    ids: *const TestIds,
) !void {
    var first_account = make_account(ids.committed_account_first);
    first_account.flags = account_linked_flag;
    const account_events = [_]tigerbeetle.Account{
        first_account,
        make_account(ids.committed_account_second),
    };
    const results = try client.createAccounts(&account_events);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(account_created, results[0].status);
    try std.testing.expectEqual(account_created, results[1].status);

    const lookup_ids = [_]u128{
        ids.committed_account_first,
        ids.committed_account_second,
    };
    const stored_accounts = try client.lookupAccounts(&lookup_ids);
    defer std.testing.allocator.free(stored_accounts);

    try std.testing.expectEqual(@as(usize, 2), stored_accounts.len);
    try std.testing.expect(find_account(stored_accounts, ids.committed_account_first) != null);
    try std.testing.expect(find_account(stored_accounts, ids.committed_account_second) != null);
}

fn roll_back_linked_accounts(
    client: *tigerbeetle.Client,
    ids: *const TestIds,
) !void {
    var first_account = make_account(ids.rolled_back_account);
    first_account.flags = account_linked_flag;
    var invalid_account = make_account(ids.invalid_ledger_account);
    invalid_account.ledger = 0;
    const accounts = [_]tigerbeetle.Account{ first_account, invalid_account };
    const results = try client.createAccounts(&accounts);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(account_linked_event_failed, results[0].status);
    try std.testing.expectEqual(account_ledger_must_not_be_zero, results[1].status);

    const lookup_ids = [_]u128{ ids.rolled_back_account, ids.invalid_ledger_account };
    const stored_accounts = try client.lookupAccounts(&lookup_ids);
    defer std.testing.allocator.free(stored_accounts);

    try std.testing.expectEqual(@as(usize, 0), stored_accounts.len);
    try std.testing.expect(find_account(stored_accounts, ids.rolled_back_account) == null);
    try std.testing.expect(find_account(stored_accounts, ids.invalid_ledger_account) == null);
}

fn reject_open_account_chain(
    client: *tigerbeetle.Client,
    ids: *const TestIds,
) !void {
    var account = make_account(ids.open_chain_account);
    account.flags = account_linked_flag;
    const results = try client.createAccounts(&.{account});
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(account_linked_event_chain_open, results[0].status);

    const accounts = try client.lookupAccounts(&.{ids.open_chain_account});
    defer std.testing.allocator.free(accounts);

    try std.testing.expectEqual(@as(usize, 0), accounts.len);
    try std.testing.expect(find_account(accounts, ids.open_chain_account) == null);
}

fn create_linked_transfers_successfully(
    client: *tigerbeetle.Client,
    ids: *const TestIds,
) !void {
    var first_transfer = make_transfer(
        ids.committed_transfer_first,
        ids.linked_debit_account,
        ids.linked_credit_account,
    );
    first_transfer.flags = transfer_linked_flag;
    const transfers = [_]tigerbeetle.Transfer{
        first_transfer,
        make_transfer(
            ids.committed_transfer_second,
            ids.linked_debit_account,
            ids.linked_credit_account,
        ),
    };
    const results = try client.createTransfers(&transfers);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(transfer_created, results[0].status);
    try std.testing.expectEqual(transfer_created, results[1].status);
    try expect_posted_balances(
        client,
        ids.linked_debit_account,
        ids.linked_credit_account,
        linked_transfer_amount_total,
    );
}

fn roll_back_linked_transfers(
    client: *tigerbeetle.Client,
    ids: *const TestIds,
) !void {
    const balances_before = try lookup_account_balances(
        client,
        ids.linked_debit_account,
        ids.linked_credit_account,
    );
    var first_transfer = make_transfer(
        ids.rolled_back_transfer,
        ids.linked_debit_account,
        ids.linked_credit_account,
    );
    first_transfer.flags = transfer_linked_flag;
    const transfers = [_]tigerbeetle.Transfer{
        first_transfer,
        make_transfer(
            ids.invalid_debit_transfer,
            ids.linked_missing_debit_account,
            ids.linked_credit_account,
        ),
    };
    const results = try client.createTransfers(&transfers);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(transfer_linked_event_failed, results[0].status);
    try std.testing.expectEqual(debit_account_not_found, results[1].status);

    const balances_after = try lookup_account_balances(
        client,
        ids.linked_debit_account,
        ids.linked_credit_account,
    );
    try std.testing.expectEqualDeep(balances_before, balances_after);
}

fn reject_open_transfer_chain(
    client: *tigerbeetle.Client,
    ids: *const TestIds,
) !void {
    const balances_before = try lookup_account_balances(
        client,
        ids.linked_debit_account,
        ids.linked_credit_account,
    );
    var transfer = make_transfer(
        ids.open_chain_transfer,
        ids.linked_debit_account,
        ids.linked_credit_account,
    );
    transfer.flags = transfer_linked_flag;
    const results = try client.createTransfers(&.{transfer});
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(transfer_linked_event_chain_open, results[0].status);

    const balances_after = try lookup_account_balances(
        client,
        ids.linked_debit_account,
        ids.linked_credit_account,
    );
    try std.testing.expectEqualDeep(balances_before, balances_after);
}

fn expect_posted_balances(
    client: *tigerbeetle.Client,
    debit_account_id: u128,
    credit_account_id: u128,
    posted_amount: u128,
) !void {
    const balances = try lookup_account_balances(
        client,
        debit_account_id,
        credit_account_id,
    );
    const expected: AccountBalancePair = .{
        .debit_account = .{
            .debits_pending = 0,
            .debits_posted = posted_amount,
            .credits_pending = 0,
            .credits_posted = 0,
        },
        .credit_account = .{
            .debits_pending = 0,
            .debits_posted = 0,
            .credits_pending = 0,
            .credits_posted = posted_amount,
        },
    };
    try std.testing.expectEqualDeep(expected, balances);
}

fn lookup_account_balances(
    client: *tigerbeetle.Client,
    debit_account_id: u128,
    credit_account_id: u128,
) !AccountBalancePair {
    assert(debit_account_id != 0);
    assert(credit_account_id != 0);
    assert(debit_account_id != credit_account_id);

    const lookup_ids = [_]u128{ credit_account_id, debit_account_id };
    const accounts = try client.lookupAccounts(&lookup_ids);
    defer std.testing.allocator.free(accounts);

    try std.testing.expectEqual(@as(usize, 2), accounts.len);
    const debit_account = find_account(accounts, debit_account_id) orelse {
        return error.DebitAccountMissing;
    };
    const credit_account = find_account(accounts, credit_account_id) orelse {
        return error.CreditAccountMissing;
    };

    return .{
        .debit_account = AccountBalance.from_account(debit_account),
        .credit_account = AccountBalance.from_account(credit_account),
    };
}

fn find_account(
    accounts: []const tigerbeetle.Account,
    id: u128,
) ?*const tigerbeetle.Account {
    for (accounts) |*account| {
        if (account.id == id) {
            return account;
        }
    }
    return null;
}

fn make_account(id: u128) tigerbeetle.Account {
    assert(id != 0);
    assert(id != std.math.maxInt(u128));
    return .{
        .id = id,
        .debits_pending = 0,
        .debits_posted = 0,
        .credits_pending = 0,
        .credits_posted = 0,
        .user_data_128 = 0,
        .user_data_64 = 0,
        .user_data_32 = 0,
        .reserved = 0,
        .ledger = ledger,
        .code = account_code,
        .flags = 0,
        .timestamp = 0,
    };
}

fn make_transfer(id: u128, debit_account_id: u128, credit_account_id: u128) tigerbeetle.Transfer {
    assert(id != 0);
    assert(id != std.math.maxInt(u128));
    assert(debit_account_id != 0);
    assert(debit_account_id != std.math.maxInt(u128));
    assert(credit_account_id != 0);
    assert(credit_account_id != std.math.maxInt(u128));
    assert(debit_account_id != credit_account_id);

    return .{
        .id = id,
        .debit_account_id = debit_account_id,
        .credit_account_id = credit_account_id,
        .amount = transfer_amount,
        .pending_id = 0,
        .user_data_128 = 0,
        .user_data_64 = 0,
        .user_data_32 = 0,
        .timeout = 0,
        .ledger = ledger,
        .code = transfer_code,
        .flags = 0,
        .timestamp = 0,
    };
}
