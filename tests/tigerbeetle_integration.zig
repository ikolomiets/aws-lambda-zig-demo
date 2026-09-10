const std = @import("std");
const tigerbeetle = @import("tigerbeetle");
const c = @import("tigerbeetle_c");

const assert = std.debug.assert;

const cluster_id: u128 = 0;
const cluster_addresses_default = "127.0.0.1:3000";
const ledger: u32 = 7101;
const account_code: u16 = 1;
const transfer_code: u16 = 1;
const transfer_amount: u128 = 10;
const linked_transfer_amount_total: u128 = transfer_amount * 2;
const unique_id_count = 21;

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
const transfer_exists: u32 = @intCast(c.TB_CREATE_TRANSFER_EXISTS);
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
    assert(c.TB_CREATE_TRANSFER_EXISTS <= std.math.maxInt(u32));
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
    operation_account: u128,
    operation_credit_account: u128,

    fn generate() TestIds {
        const base_id: u128 = 0x74625f666978747572655f3100000100;

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
            .operation_account = base_id + 19,
            .operation_credit_account = base_id + 20,
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
            ids.operation_account,
            ids.operation_credit_account,
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
                "  open_chain_transfer={x}\n" ++
                "  operation_account={x}\n" ++
                "  operation_credit_account={x}\n",
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
                ids.operation_account,
                ids.operation_credit_account,
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

fn cluster_addresses() []const u8 {
    return if (std.c.getenv("TIGERBEETLE_ADDRESSES")) |addresses| std.mem.span(addresses) else cluster_addresses_default;
}

test "live account, transfer, and linked chain operations" {
    // The local runner attests ownership before this suite may mutate its endpoint.
    const owned = std.c.getenv("TIGERBEETLE_TEST_OWNED") orelse return error.FixtureOwnershipRequired;
    if (!std.mem.eql(u8, std.mem.span(owned), "fresh-local-cluster")) {
        return error.FixtureOwnershipRequired;
    }
    const ids = TestIds.generate();
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
        cluster_addresses(),
    );
    defer client.destroy();

    try run_execution_accounting_workflow(client, ids);

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

fn run_execution_accounting_workflow(
    client: *tigerbeetle.Client,
    ids: *const TestIds,
) !void {
    const prerequisite_account = make_account(ids.operation_credit_account);
    var prerequisite_created: [1]tigerbeetle.CreateAccountResult = undefined;
    try std.testing.expectEqual(@as(usize, 1), try client.createAccounts(
        &.{prerequisite_account},
        &prerequisite_created,
    ));
    try std.testing.expectEqual(account_created, prerequisite_created[0].status);
    const prerequisite_input = &[_]u128{ids.operation_credit_account};
    const prerequisite_buffer = try std.testing.allocator.alloc(
        tigerbeetle.Account,
        prerequisite_input.len,
    );
    defer std.testing.allocator.free(prerequisite_buffer);
    const prerequisite_count = try client.lookupAccounts(prerequisite_input, prerequisite_buffer);
    const prerequisite = prerequisite_buffer[0..prerequisite_count];
    try std.testing.expectEqual(@as(usize, 1), prerequisite.len);
    try std.testing.expectEqual(ids.operation_credit_account, prerequisite[0].id);
    try std.testing.expectEqual(ledger, prerequisite[0].ledger);
    const credit_before = AccountBalance.from_account(&prerequisite[0]);

    const account = make_account(ids.operation_account);
    const account_results_input = &[_]tigerbeetle.Account{account};
    const account_results_buffer = try std.testing.allocator.alloc(
        tigerbeetle.CreateAccountResult,
        account_results_input.len,
    );
    defer std.testing.allocator.free(account_results_buffer);
    const account_results_count = try client.createAccounts(
        account_results_input,
        account_results_buffer,
    );
    const account_results = account_results_buffer[0..account_results_count];
    try std.testing.expectEqual(@as(usize, 1), account_results.len);
    try std.testing.expect(tigerbeetle.create_account_succeeded(account_results[0].status));
    try std.testing.expectEqual(account_created, account_results[0].status);

    const account_replay_input = &[_]tigerbeetle.Account{account};
    const account_replay_buffer = try std.testing.allocator.alloc(
        tigerbeetle.CreateAccountResult,
        account_replay_input.len,
    );
    defer std.testing.allocator.free(account_replay_buffer);
    const account_replay_count = try client.createAccounts(
        account_replay_input,
        account_replay_buffer,
    );
    const account_replay = account_replay_buffer[0..account_replay_count];
    try std.testing.expectEqual(@as(usize, 1), account_replay.len);
    try std.testing.expect(tigerbeetle.create_account_succeeded(account_replay[0].status));
    try std.testing.expectEqual(account_exists, account_replay[0].status);

    var transfer = make_transfer(ids.operation_account, ids.operation_account, ids.operation_credit_account);
    transfer.amount = 100;
    const transfer_results_input = &[_]tigerbeetle.Transfer{transfer};
    const transfer_results_buffer = try std.testing.allocator.alloc(
        tigerbeetle.CreateTransferResult,
        transfer_results_input.len,
    );
    defer std.testing.allocator.free(transfer_results_buffer);
    const transfer_results_count = try client.createTransfers(
        transfer_results_input,
        transfer_results_buffer,
    );
    const transfer_results = transfer_results_buffer[0..transfer_results_count];
    try std.testing.expectEqual(@as(usize, 1), transfer_results.len);
    try std.testing.expect(tigerbeetle.create_transfer_succeeded(transfer_results[0].status));
    try std.testing.expectEqual(transfer_created, transfer_results[0].status);

    const transfer_replay_input = &[_]tigerbeetle.Transfer{transfer};
    const transfer_replay_buffer = try std.testing.allocator.alloc(
        tigerbeetle.CreateTransferResult,
        transfer_replay_input.len,
    );
    defer std.testing.allocator.free(transfer_replay_buffer);
    const transfer_replay_count = try client.createTransfers(
        transfer_replay_input,
        transfer_replay_buffer,
    );
    const transfer_replay = transfer_replay_buffer[0..transfer_replay_count];
    try std.testing.expectEqual(@as(usize, 1), transfer_replay.len);
    try std.testing.expect(tigerbeetle.create_transfer_succeeded(transfer_replay[0].status));
    try std.testing.expectEqual(transfer_exists, transfer_replay[0].status);

    const balances = try lookup_account_balances(
        client,
        ids.operation_account,
        ids.operation_credit_account,
    );
    const expected_credit_posted = try std.math.add(u128, credit_before.credits_posted, 100);
    try std.testing.expectEqual(@as(u128, 100), balances.debit_account.debits_posted);
    try std.testing.expectEqual(expected_credit_posted, balances.credit_account.credits_posted);
    try std.testing.expectEqual(
        credit_before.debits_pending,
        balances.credit_account.debits_pending,
    );
    try std.testing.expectEqual(
        credit_before.debits_posted,
        balances.credit_account.debits_posted,
    );
    try std.testing.expectEqual(
        credit_before.credits_pending,
        balances.credit_account.credits_pending,
    );
}

fn create_accounts(
    client: *tigerbeetle.Client,
    accounts: *const [2]tigerbeetle.Account,
) !void {
    const results_buffer = try std.testing.allocator.alloc(
        tigerbeetle.CreateAccountResult,
        accounts.len,
    );
    defer std.testing.allocator.free(results_buffer);
    const results_count = try client.createAccounts(accounts, results_buffer);
    const results = results_buffer[0..results_count];

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(account_created, results[0].status);
    try std.testing.expectEqual(account_created, results[1].status);
}

fn resubmit_account(client: *tigerbeetle.Client, account: tigerbeetle.Account) !void {
    const results_input = &[_]tigerbeetle.Account{account};
    const results_buffer = try std.testing.allocator.alloc(
        tigerbeetle.CreateAccountResult,
        results_input.len,
    );
    defer std.testing.allocator.free(results_buffer);
    const results_count = try client.createAccounts(results_input, results_buffer);
    const results = results_buffer[0..results_count];

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(account_exists, results[0].status);
}

fn verify_initial_lookup(client: *tigerbeetle.Client, ids: *const TestIds) !void {
    const lookup_ids = [_]u128{
        ids.debit_account,
        ids.credit_account,
        ids.missing_lookup_account,
    };
    const accounts_buffer = try std.testing.allocator.alloc(
        tigerbeetle.Account,
        lookup_ids.len,
    );
    defer std.testing.allocator.free(accounts_buffer);
    const accounts_count = try client.lookupAccounts(&lookup_ids, accounts_buffer);
    const accounts = accounts_buffer[0..accounts_count];

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
    const results_input = &[_]tigerbeetle.Transfer{transfer};
    const results_buffer = try std.testing.allocator.alloc(
        tigerbeetle.CreateTransferResult,
        results_input.len,
    );
    defer std.testing.allocator.free(results_buffer);
    const results_count = try client.createTransfers(results_input, results_buffer);
    const results = results_buffer[0..results_count];

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
    const results_input = &[_]tigerbeetle.Transfer{transfer};
    const results_buffer = try std.testing.allocator.alloc(
        tigerbeetle.CreateTransferResult,
        results_input.len,
    );
    defer std.testing.allocator.free(results_buffer);
    const results_count = try client.createTransfers(results_input, results_buffer);
    const results = results_buffer[0..results_count];

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
    const results_buffer = try std.testing.allocator.alloc(
        tigerbeetle.CreateAccountResult,
        account_events.len,
    );
    defer std.testing.allocator.free(results_buffer);
    const results_count = try client.createAccounts(&account_events, results_buffer);
    const results = results_buffer[0..results_count];

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(account_created, results[0].status);
    try std.testing.expectEqual(account_created, results[1].status);

    const lookup_ids = [_]u128{
        ids.committed_account_first,
        ids.committed_account_second,
    };
    const stored_accounts_buffer = try std.testing.allocator.alloc(
        tigerbeetle.Account,
        lookup_ids.len,
    );
    defer std.testing.allocator.free(stored_accounts_buffer);
    const stored_accounts_count = try client.lookupAccounts(
        &lookup_ids,
        stored_accounts_buffer,
    );
    const stored_accounts = stored_accounts_buffer[0..stored_accounts_count];

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
    const results_buffer = try std.testing.allocator.alloc(
        tigerbeetle.CreateAccountResult,
        accounts.len,
    );
    defer std.testing.allocator.free(results_buffer);
    const results_count = try client.createAccounts(&accounts, results_buffer);
    const results = results_buffer[0..results_count];

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(account_linked_event_failed, results[0].status);
    try std.testing.expectEqual(account_ledger_must_not_be_zero, results[1].status);

    const lookup_ids = [_]u128{ ids.rolled_back_account, ids.invalid_ledger_account };
    const stored_accounts_buffer = try std.testing.allocator.alloc(
        tigerbeetle.Account,
        lookup_ids.len,
    );
    defer std.testing.allocator.free(stored_accounts_buffer);
    const stored_accounts_count = try client.lookupAccounts(
        &lookup_ids,
        stored_accounts_buffer,
    );
    const stored_accounts = stored_accounts_buffer[0..stored_accounts_count];

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
    const results_input = &[_]tigerbeetle.Account{account};
    const results_buffer = try std.testing.allocator.alloc(
        tigerbeetle.CreateAccountResult,
        results_input.len,
    );
    defer std.testing.allocator.free(results_buffer);
    const results_count = try client.createAccounts(results_input, results_buffer);
    const results = results_buffer[0..results_count];

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(account_linked_event_chain_open, results[0].status);

    const accounts_input = &[_]u128{ids.open_chain_account};
    const accounts_buffer = try std.testing.allocator.alloc(
        tigerbeetle.Account,
        accounts_input.len,
    );
    defer std.testing.allocator.free(accounts_buffer);
    const accounts_count = try client.lookupAccounts(accounts_input, accounts_buffer);
    const accounts = accounts_buffer[0..accounts_count];

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
    const results_buffer = try std.testing.allocator.alloc(
        tigerbeetle.CreateTransferResult,
        transfers.len,
    );
    defer std.testing.allocator.free(results_buffer);
    const results_count = try client.createTransfers(&transfers, results_buffer);
    const results = results_buffer[0..results_count];

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
    const results_buffer = try std.testing.allocator.alloc(
        tigerbeetle.CreateTransferResult,
        transfers.len,
    );
    defer std.testing.allocator.free(results_buffer);
    const results_count = try client.createTransfers(&transfers, results_buffer);
    const results = results_buffer[0..results_count];

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
    const results_input = &[_]tigerbeetle.Transfer{transfer};
    const results_buffer = try std.testing.allocator.alloc(
        tigerbeetle.CreateTransferResult,
        results_input.len,
    );
    defer std.testing.allocator.free(results_buffer);
    const results_count = try client.createTransfers(results_input, results_buffer);
    const results = results_buffer[0..results_count];

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
    const accounts_buffer = try std.testing.allocator.alloc(
        tigerbeetle.Account,
        lookup_ids.len,
    );
    defer std.testing.allocator.free(accounts_buffer);
    const accounts_count = try client.lookupAccounts(&lookup_ids, accounts_buffer);
    const accounts = accounts_buffer[0..accounts_count];

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

fn owned_client() !*tigerbeetle.Client {
    const owned = std.c.getenv("TIGERBEETLE_TEST_OWNED") orelse return error.FixtureOwnershipRequired;
    if (!std.mem.eql(u8, std.mem.span(owned), "fresh-local-cluster")) return error.FixtureOwnershipRequired;
    return tigerbeetle.Client.create(std.testing.allocator, std.testing.io, cluster_id, cluster_addresses());
}

fn expect_accounts(client: *tigerbeetle.Client, input: []const tigerbeetle.Account, statuses: []const u32) !void {
    assert(input.len > 0 and input.len <= 16);
    assert(input.len == statuses.len);
    var output: [16]tigerbeetle.CreateAccountResult = undefined;
    try std.testing.expectEqual(input.len, try client.createAccounts(input, output[0..input.len]));
    for (statuses, output[0..input.len], 0..) |status, result, index| {
        errdefer std.debug.print("account id={d} index={d} expected={d} actual={d}\n", .{ input[index].id, index, status, result.status });
        try std.testing.expectEqual(status, result.status);
    }
}

fn expect_transfers(client: *tigerbeetle.Client, input: []const tigerbeetle.Transfer, statuses: []const u32) !void {
    assert(input.len > 0 and input.len <= 16);
    assert(input.len == statuses.len);
    var output: [16]tigerbeetle.CreateTransferResult = undefined;
    try std.testing.expectEqual(input.len, try client.createTransfers(input, output[0..input.len]));
    for (statuses, output[0..input.len], 0..) |status, result, index| {
        errdefer std.debug.print("transfer id={d} index={d} expected={d} actual={d}\n", .{ input[index].id, index, status, result.status });
        try std.testing.expectEqual(status, result.status);
    }
}

fn observe(client: *tigerbeetle.Client, id: u128) !tigerbeetle.Account {
    var output: [1]tigerbeetle.Account = undefined;
    try std.testing.expectEqual(@as(usize, 1), try client.lookupAccounts(&.{id}, &output));
    try std.testing.expectEqual(id, output[0].id);
    return output[0];
}

test "native immutable account chains duplicate regroup and reject different fields independently" {
    const client = try owned_client();
    defer client.destroy();
    var chain = [_]tigerbeetle.Account{ make_account(1001), make_account(1002) };
    chain[0].flags |= account_linked_flag;
    const neighbor = make_account(1003);
    try expect_accounts(client, &.{ chain[0], chain[1], chain[0], chain[1], neighbor }, &.{ account_created, account_created, account_exists, account_linked_event_failed, account_created });
    // Subset redelivery with changed neighbors retains each complete original chain.
    try expect_accounts(client, &.{ neighbor, chain[0], chain[1] }, &.{ account_exists, account_exists, account_linked_event_failed });
    var conflict = neighbor;
    conflict.code = 2;
    try expect_accounts(client, &.{ conflict, make_account(1004) }, &.{ c.TB_CREATE_ACCOUNT_EXISTS_WITH_DIFFERENT_CODE, account_created });
    var output: [5]tigerbeetle.Account = undefined;
    const n = try client.lookupAccounts(&.{ 1002, 1099, 1001, 1002, 1003 }, &output);
    try std.testing.expectEqual(@as(usize, 4), n);
    var copies: usize = 0;
    for (output[0..n]) |*account| {
        try std.testing.expect(account.id == 1001 or account.id == 1002 or account.id == 1003);
        if (account.id == 1002) {
            copies += 1;
            try std.testing.expectEqual(@as(u16, 1), account.code);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), copies);
    try std.testing.expectEqual(@as(u16, 1), (try observe(client, 1003)).code);
}

test "native linked transfers replay regroup shared accounts consumed IDs and fresh rejection reasons" {
    const client = try owned_client();
    defer client.destroy();
    try expect_accounts(client, &.{ make_account(2001), make_account(2002) }, &.{ account_created, account_created });
    var chain = [_]tigerbeetle.Transfer{ make_transfer(2011, 2001, 2002), make_transfer(2012, 2001, 2002) };
    chain[0].flags |= transfer_linked_flag;
    const neighbor = make_transfer(2013, 2001, 2002);
    try expect_transfers(client, &.{ chain[0], chain[1], chain[0], chain[1], neighbor }, &.{ transfer_created, transfer_created, transfer_exists, transfer_linked_event_failed, transfer_created });
    try expect_transfers(client, &.{ neighbor, chain[0], chain[1] }, &.{ transfer_exists, transfer_exists, transfer_linked_event_failed });
    try std.testing.expectEqual(@as(u128, 30), (try observe(client, 2001)).debits_posted);
    var conflict = neighbor;
    conflict.amount = 11;
    try expect_transfers(client, &.{conflict}, &.{c.TB_CREATE_TRANSFER_EXISTS_WITH_DIFFERENT_AMOUNT});
    var rejected = [_]tigerbeetle.Transfer{ make_transfer(2021, 2001, 2002), make_transfer(2022, 2099, 2002) };
    rejected[0].flags |= transfer_linked_flag;
    try expect_transfers(client, &rejected, &.{ transfer_linked_event_failed, debit_account_not_found });
    try expect_transfers(client, &rejected, &.{ transfer_linked_event_failed, c.TB_CREATE_TRANSFER_ID_ALREADY_FAILED });
    try std.testing.expectEqual(@as(u128, 30), (try observe(client, 2001)).debits_posted);
    // The linked-failed prefix was rolled back, not consumed: its failure remains at member 2.
    // Separate singleton rejection demonstrates that repairing a reference cannot revive its ID.
    const missing = make_transfer(2031, 2098, 2002);
    try expect_transfers(client, &.{missing}, &.{debit_account_not_found});
    try expect_accounts(client, &.{make_account(2098)}, &.{account_created});
    try expect_transfers(client, &.{missing}, &.{c.TB_CREATE_TRANSFER_ID_ALREADY_FAILED});
    const independent = make_transfer(2032, 2001, 2002);
    try expect_transfers(client, &.{ missing, independent }, &.{ c.TB_CREATE_TRANSFER_ID_ALREADY_FAILED, transfer_created });
    try std.testing.expectEqual(@as(u128, 40), (try observe(client, 2001)).debits_posted);
}

fn post_transfer(id: u128, pending_id: u128, amount: u128) tigerbeetle.Transfer {
    var transfer = std.mem.zeroes(tigerbeetle.Transfer);
    transfer.id = id;
    transfer.pending_id = pending_id;
    transfer.flags = tigerbeetle.transfer_post_pending_transfer;
    transfer.amount = amount;
    return transfer;
}

test "native zero partial full post inheritance replay and native mismatch rejection" {
    const client = try owned_client();
    defer client.destroy();
    try expect_accounts(client, &.{ make_account(3001), make_account(3002) }, &.{ account_created, account_created });
    const amounts = [_]u128{ 0, 4, std.math.maxInt(u128) };
    const posted = [_]u128{ 0, 4, 14 };
    for (amounts, 0..) |amount, index| {
        var pending = make_transfer(3010 + index, 3001, 3002);
        pending.flags = tigerbeetle.transfer_pending;
        pending.timeout = 60;
        try expect_transfers(client, &.{pending}, &.{transfer_created});
        try std.testing.expectEqual(@as(u128, 10), (try observe(client, 3001)).debits_pending);
        var post = post_transfer(3020 + index, pending.id, amount);
        if (index == 1) { // Explicit matching inheritance fields and zero defaults both work.
            post.debit_account_id = 3001;
            post.credit_account_id = 3002;
            post.ledger = ledger;
            post.code = transfer_code;
        }
        try expect_transfers(client, &.{post}, &.{transfer_created});
        try expect_transfers(client, &.{ pending, post }, &.{ transfer_exists, transfer_exists });
        const account = try observe(client, 3001);
        try std.testing.expectEqual(@as(u128, 0), account.debits_pending);
        try std.testing.expectEqual(posted[index], account.debits_posted);
    }
    var pending = make_transfer(3030, 3001, 3002);
    pending.flags = tigerbeetle.transfer_pending;
    pending.timeout = 60;
    try expect_transfers(client, &.{pending}, &.{transfer_created});
    var mismatch = post_transfer(3031, pending.id, 1);
    mismatch.ledger = ledger + 1;
    try expect_transfers(client, &.{mismatch}, &.{c.TB_CREATE_TRANSFER_PENDING_TRANSFER_HAS_DIFFERENT_LEDGER});
    const excessive = post_transfer(3032, pending.id, 11);
    try expect_transfers(client, &.{excessive}, &.{c.TB_CREATE_TRANSFER_EXCEEDS_PENDING_TRANSFER_AMOUNT});
    // Distinct posts share the pending reference: only the first can resolve it.
    const first = post_transfer(3033, pending.id, 1);
    const second = post_transfer(3034, pending.id, 1);
    try expect_transfers(client, &.{ first, second }, &.{ transfer_created, c.TB_CREATE_TRANSFER_PENDING_TRANSFER_ALREADY_POSTED });
    try std.testing.expectEqual(@as(u128, 15), (try observe(client, 3001)).debits_posted);
}

fn wait_pending_cleanup(client: *tigerbeetle.Client, id: u128) !void {
    for (0..200) |_| {
        if ((try observe(client, id)).debits_pending == 0) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(100), .awake);
    }
    // A timeout supplies no semantic evidence that the server violated expiry.
    return error.IncompleteExpiryEvidence;
}

test "native pending expiry cleanup replay does not renew and first late post rejects" {
    const client = try owned_client();
    defer client.destroy();
    try expect_accounts(client, &.{ make_account(4001), make_account(4002) }, &.{ account_created, account_created });
    var pending = make_transfer(4011, 4001, 4002);
    pending.flags = tigerbeetle.transfer_pending;
    pending.timeout = 1;
    try expect_transfers(client, &.{pending}, &.{transfer_created});
    try std.testing.expectEqual(@as(u128, 10), (try observe(client, 4001)).debits_pending);
    try wait_pending_cleanup(client, 4001);
    try expect_transfers(client, &.{pending}, &.{transfer_exists});
    try std.testing.expectEqual(@as(u128, 0), (try observe(client, 4001)).debits_pending);
    const post = post_transfer(4012, pending.id, 1);
    try expect_transfers(client, &.{post}, &.{c.TB_CREATE_TRANSFER_PENDING_TRANSFER_EXPIRED});
    // Expiry is nontransient in the pinned status table: it does not consume this post ID.
    try expect_transfers(client, &.{post}, &.{c.TB_CREATE_TRANSFER_PENDING_TRANSFER_EXPIRED});
    const account = try observe(client, 4001);
    try std.testing.expectEqual(@as(u128, 0), account.debits_pending);
    try std.testing.expectEqual(@as(u128, 0), account.debits_posted);
}

test "native fresh missing to found observations and discarded reply replay preserve effects" {
    const client = try owned_client();
    defer client.destroy();
    var output: [1]tigerbeetle.Account = undefined;
    try std.testing.expectEqual(@as(usize, 0), try client.lookupAccounts(&.{5001}, &output));
    try expect_accounts(client, &.{ make_account(5001), make_account(5002) }, &.{ account_created, account_created });
    try std.testing.expectEqual(@as(u128, 0), (try observe(client, 5001)).debits_posted);
    const transfer = make_transfer(5011, 5001, 5002);
    var discarded: [1]tigerbeetle.CreateTransferResult = undefined;
    _ = try client.createTransfers(&.{transfer}, &discarded); // Models a lost application reply, not process death.
    try std.testing.expectEqual(@as(u128, 10), (try observe(client, 5001)).debits_posted);
    const other = make_transfer(5012, 5001, 5002);
    try expect_transfers(client, &.{ other, transfer }, &.{ transfer_created, transfer_exists });
    try std.testing.expectEqual(@as(u128, 20), (try observe(client, 5001)).debits_posted);
}

const ConcurrentDuplicate = struct {
    client: *tigerbeetle.Client,
    input: *const [2]tigerbeetle.Transfer,
    ready: *std.atomic.Value(u32),
    start: *std.Io.Event,
    output: [2]tigerbeetle.CreateTransferResult = undefined,
    failure: ?anyerror = null,

    fn run(self: *ConcurrentDuplicate) void {
        _ = self.ready.fetchAdd(1, .release);
        self.start.waitUncancelable(std.testing.io);
        const count = self.client.createTransfers(self.input, &self.output) catch |err| {
            self.failure = err;
            return;
        };
        if (count != 2) self.failure = error.InvalidCount;
    }
};

test "native concurrent duplicate clients create one immutable chain effect" {
    const first = try owned_client();
    defer first.destroy();
    const second = try owned_client();
    defer second.destroy();
    try expect_accounts(first, &.{ make_account(6001), make_account(6002) }, &.{ account_created, account_created });
    var input = [_]tigerbeetle.Transfer{ make_transfer(6011, 6001, 6002), make_transfer(6012, 6001, 6002) };
    input[0].flags |= transfer_linked_flag;
    var ready: std.atomic.Value(u32) = .init(0);
    var start: std.Io.Event = .unset;
    var a: ConcurrentDuplicate = .{ .client = first, .input = &input, .ready = &ready, .start = &start };
    var b: ConcurrentDuplicate = .{ .client = second, .input = &input, .ready = &ready, .start = &start };
    const thread_a = try std.Thread.spawn(.{}, ConcurrentDuplicate.run, .{&a});
    var joined = false;
    defer if (!joined) thread_a.join();
    // Release any started worker even if the second thread cannot be allocated.
    const thread_b = std.Thread.spawn(.{}, ConcurrentDuplicate.run, .{&b}) catch |err| {
        start.set(std.testing.io);
        return err;
    };
    defer if (!joined) thread_b.join();
    defer start.set(std.testing.io);
    var both_ready = false;
    for (0..200) |_| {
        if (ready.load(.acquire) == 2) {
            both_ready = true;
            break;
        }
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect(both_ready);
    start.set(std.testing.io);
    thread_a.join();
    thread_b.join();
    joined = true;
    if (a.failure) |err| return err;
    if (b.failure) |err| return err;
    const created_reply = if (a.output[0].status == transfer_created) &a.output else &b.output;
    const replay_reply = if (a.output[0].status == transfer_created) &b.output else &a.output;
    try std.testing.expectEqual(transfer_created, created_reply[0].status);
    try std.testing.expectEqual(transfer_created, created_reply[1].status);
    try std.testing.expectEqual(transfer_exists, replay_reply[0].status);
    try std.testing.expectEqual(transfer_linked_event_failed, replay_reply[1].status);
    try std.testing.expectEqual(@as(u128, 20), (try observe(first, 6001)).debits_posted);
}

test "native discarded shared account reply replays intact subset with new neighbor before transfers" {
    const client = try owned_client();
    defer client.destroy();
    var first = [_]tigerbeetle.Account{ make_account(7001), make_account(7002), make_account(7003) };
    first[0].flags = account_linked_flag;
    var discarded: [3]tigerbeetle.CreateAccountResult = undefined;
    _ = try client.createAccounts(&first, &discarded);
    // Deliberately discard the application reply, then inspect durable native facts.
    // This does not simulate process termination or establish that termination aborts a write.
    const before = try observe(client, 7001);
    try std.testing.expectEqual(@as(u128, 0), before.debits_posted);
    try expect_accounts(client, &.{ make_account(7004), first[0], first[1] }, &.{ account_created, account_exists, account_linked_event_failed });
    const after = try observe(client, 7001);
    try std.testing.expectEqualDeep(before, after);
    const transfer = make_transfer(7010, 7001, 7002);
    try expect_transfers(client, &.{transfer}, &.{transfer_created});
    try std.testing.expectEqual(@as(u128, 10), (try observe(client, 7001)).debits_posted);
    try expect_accounts(client, first[0..2], &.{ account_exists, account_linked_event_failed });
    try expect_transfers(client, &.{transfer}, &.{transfer_exists});
    try std.testing.expectEqual(@as(u128, 10), (try observe(client, 7001)).debits_posted);
}
