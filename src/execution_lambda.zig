const std = @import("std");
const aws = @import("aws");
const lambda = @import("aws-lambda");
const operation = @import("operation");
const operation_persistence = @import("operation_persistence");
const tigerbeetle = @import("tigerbeetle");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{
            .scope = .execution,
            .level = .debug,
        },
        .{
            .scope = .aws_sdk,
            .level = .debug,
        },
    },
};

const Allocator = std.mem.Allocator;
const accounting_ledger: u32 = 1;
const accounting_code: u16 = 1;
const accounting_credit_account_id: u128 = 1;
const accounting_transfer_amount: u128 = 100;
const record_count_max = 10;
const tigerbeetle_addresses_default = "10.200.0.2:3000";
const tigerbeetle_addresses_size_max = 4096;
const tigerbeetle_cluster_id_default = "0";
const log = std.log.scoped(.execution);

comptime {
    std.debug.assert(accounting_ledger > 0);
    std.debug.assert(accounting_code > 0);
    std.debug.assert(accounting_credit_account_id > 0);
    std.debug.assert(accounting_transfer_amount > 0);
    std.debug.assert(record_count_max > 0);
    std.debug.assert(record_count_max <= 10);
    std.debug.assert(tigerbeetle_addresses_default.len > 0);
    std.debug.assert(tigerbeetle_addresses_default.len <= tigerbeetle_addresses_size_max);
}

var runtime_execution_adapter: ?ExecutionAdapter = null;

pub fn main(init: std.process.Init) void {
    var resources: RuntimeResources = undefined;
    resources.init(init) catch |err| {
        std.log.err("Lambda initialization failed: {s}", .{@errorName(err)});
        return;
    };
    defer resources.deinit();

    installRuntimeExecutionAdapter(ExecutionAdapter.init(&resources));
    defer uninstallRuntimeExecutionAdapter();
    lambda.handle(init, handler, .{});
}

fn handler(ctx: lambda.Context, event: []const u8) ![]const u8 {
    const execution = runtime_execution_adapter orelse {
        return error.ExecutionNotInitialized;
    };
    var clock: RealClock = .{ .io = ctx.io };
    return handleInvocation(ctx.arena, event, execution, Clock.init(&clock));
}

const RuntimeResources = struct {
    config: aws.Config,
    persistence: operation_persistence.Persistence,
    tigerbeetle_client: *tigerbeetle.Client,

    fn init(resources: *RuntimeResources, process_init: std.process.Init) !void {
        const tigerbeetle_config = tigerbeetleConfiguration(process_init.environ_map) catch {
            return error.TigerBeetleConfigurationFailure;
        };

        resources.config = aws.Config.load(
            process_init.gpa,
            process_init.io,
            process_init.environ_map,
            .{},
        ) catch return error.AWSConfigurationFailure;
        errdefer resources.config.deinit();

        operation_persistence.Persistence.init(
            &resources.persistence,
            process_init.gpa,
            &resources.config,
            process_init.environ_map,
        ) catch return error.PersistenceConfigurationFailure;
        errdefer resources.persistence.deinit();

        resources.tigerbeetle_client = tigerbeetle.Client.create(
            process_init.gpa,
            process_init.io,
            tigerbeetle_config.cluster_id,
            tigerbeetle_config.addresses,
        ) catch return error.TigerBeetleInitializationFailure;
    }

    fn deinit(resources: *RuntimeResources) void {
        resources.tigerbeetle_client.destroy();
        resources.persistence.deinit();
        resources.config.deinit();
        resources.* = undefined;
    }

    fn createAccount(
        resources: *RuntimeResources,
        account: *const tigerbeetle.Account,
    ) !CreateOutcome {
        const results = try resources.tigerbeetle_client.createAccounts(account[0..1]);
        defer resources.tigerbeetle_client.allocator.free(results);
        if (results.len != 1) return error.MalformedResult;

        return .{
            .status = results[0].status,
            .succeeded = tigerbeetle.create_account_succeeded(results[0].status),
        };
    }

    fn createTransfer(
        resources: *RuntimeResources,
        transfer: *const tigerbeetle.Transfer,
    ) !CreateOutcome {
        const results = try resources.tigerbeetle_client.createTransfers(transfer[0..1]);
        defer resources.tigerbeetle_client.allocator.free(results);
        if (results.len != 1) return error.MalformedResult;

        return .{
            .status = results[0].status,
            .succeeded = tigerbeetle.create_transfer_succeeded(results[0].status),
        };
    }

    fn complete(
        resources: *RuntimeResources,
        arena: Allocator,
        submitted: *const operation.Operation,
        now: operation.UnixSeconds,
    ) !void {
        return resources.persistence.complete(arena, submitted, now);
    }
};

const TigerBeetleConfiguration = struct {
    cluster_id: u128,
    addresses: []const u8,
};

fn tigerbeetleConfiguration(
    environment: *const std.process.Environ.Map,
) !TigerBeetleConfiguration {
    const cluster_id_raw = environment.get("TIGERBEETLE_CLUSTER_ID") orelse
        tigerbeetle_cluster_id_default;
    if (cluster_id_raw.len == 0) return error.InvalidConfiguration;
    for (cluster_id_raw) |character| {
        if (!std.ascii.isDigit(character)) return error.InvalidConfiguration;
    }
    const cluster_id = std.fmt.parseInt(u128, cluster_id_raw, 10) catch {
        return error.InvalidConfiguration;
    };

    const addresses = environment.get("TIGERBEETLE_ADDRESSES") orelse
        tigerbeetle_addresses_default;
    if (addresses.len == 0) return error.InvalidConfiguration;
    if (addresses.len > tigerbeetle_addresses_size_max) return error.InvalidConfiguration;
    for (addresses) |character| {
        if (std.ascii.isWhitespace(character)) return error.InvalidConfiguration;
    }

    return .{ .cluster_id = cluster_id, .addresses = addresses };
}

const CreateOutcome = struct {
    status: u32,
    succeeded: bool,
};

const ExecutionAdapter = struct {
    context: *anyopaque,
    create_account_fn: *const fn (
        *anyopaque,
        *const tigerbeetle.Account,
    ) anyerror!CreateOutcome,
    create_transfer_fn: *const fn (
        *anyopaque,
        *const tigerbeetle.Transfer,
    ) anyerror!CreateOutcome,
    complete_fn: *const fn (
        *anyopaque,
        Allocator,
        *const operation.Operation,
        operation.UnixSeconds,
    ) anyerror!void,

    fn init(pointer: anytype) ExecutionAdapter {
        const Pointer = @TypeOf(pointer);
        const pointer_info = @typeInfo(Pointer);
        comptime std.debug.assert(pointer_info == .pointer);
        comptime std.debug.assert(pointer_info.pointer.size == .one);

        const Adapter = struct {
            fn createAccount(
                context: *anyopaque,
                account: *const tigerbeetle.Account,
            ) anyerror!CreateOutcome {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.createAccount(account);
            }

            fn createTransfer(
                context: *anyopaque,
                transfer: *const tigerbeetle.Transfer,
            ) anyerror!CreateOutcome {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.createTransfer(transfer);
            }

            fn complete(
                context: *anyopaque,
                arena: Allocator,
                submitted: *const operation.Operation,
                now: operation.UnixSeconds,
            ) anyerror!void {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.complete(arena, submitted, now);
            }
        };
        return .{
            .context = pointer,
            .create_account_fn = Adapter.createAccount,
            .create_transfer_fn = Adapter.createTransfer,
            .complete_fn = Adapter.complete,
        };
    }

    fn createAccount(
        execution: ExecutionAdapter,
        account: *const tigerbeetle.Account,
    ) !CreateOutcome {
        return execution.create_account_fn(execution.context, account);
    }

    fn createTransfer(
        execution: ExecutionAdapter,
        transfer: *const tigerbeetle.Transfer,
    ) !CreateOutcome {
        return execution.create_transfer_fn(execution.context, transfer);
    }

    fn complete(
        execution: ExecutionAdapter,
        arena: Allocator,
        submitted: *const operation.Operation,
        now: operation.UnixSeconds,
    ) !void {
        return execution.complete_fn(execution.context, arena, submitted, now);
    }
};

const Clock = struct {
    context: *anyopaque,
    now_fn: *const fn (*anyopaque) operation.UnixSeconds,

    fn init(pointer: anytype) Clock {
        const Pointer = @TypeOf(pointer);
        const pointer_info = @typeInfo(Pointer);
        comptime std.debug.assert(pointer_info == .pointer);
        comptime std.debug.assert(pointer_info.pointer.size == .one);

        const Adapter = struct {
            fn now(context: *anyopaque) operation.UnixSeconds {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.now();
            }
        };
        return .{
            .context = pointer,
            .now_fn = Adapter.now,
        };
    }

    fn now(clock: Clock) operation.UnixSeconds {
        return clock.now_fn(clock.context);
    }
};

const RealClock = struct {
    io: std.Io,

    fn now(clock: *RealClock) operation.UnixSeconds {
        return std.Io.Clock.real.now(clock.io).toSeconds();
    }
};

fn installRuntimeExecutionAdapter(execution: ExecutionAdapter) void {
    std.debug.assert(runtime_execution_adapter == null);
    runtime_execution_adapter = execution;
    std.debug.assert(runtime_execution_adapter != null);
}

fn uninstallRuntimeExecutionAdapter() void {
    std.debug.assert(runtime_execution_adapter != null);
    runtime_execution_adapter = null;
    std.debug.assert(runtime_execution_adapter == null);
}

fn handleInvocation(
    allocator: Allocator,
    event: []const u8,
    execution: ExecutionAdapter,
    clock: Clock,
) ![]const u8 {
    const sqs_event = try lambda.sqs.parseEvent(allocator, event);
    defer sqs_event.deinit(allocator);
    if (sqs_event.records.len > record_count_max) return error.TooManyRecords;

    var failures: [record_count_max]lambda.sqs.BatchItemFailure = undefined;
    var failure_count: u8 = 0;
    for (sqs_event.records) |record| {
        log.debug("message_id={s} body={s}", .{ record.message_id, record.body });
        if (processRecord(allocator, record.message_id, record.body, execution, clock)) {
            std.debug.assert(failure_count < record_count_max);
            failures[failure_count] = .{ .item_identifier = record.message_id };
            failure_count += 1;
        }
    }
    std.debug.assert(failure_count <= sqs_event.records.len);

    return lambda.sqs.encodeResponse(allocator, .{
        .batch_item_failures = failures[0..failure_count],
    });
}

/// Returns true only when SQS must retry this record.
fn processRecord(
    arena: Allocator,
    message_id: []const u8,
    body: []const u8,
    execution: ExecutionAdapter,
    clock: Clock,
) bool {
    const submitted = operation.parseOutputJSON(arena, body) catch |err| {
        if (err == error.OutOfMemory) {
            log.debug("message_id={s} stage=parse outcome=retry error={s}", .{
                message_id,
                @errorName(err),
            });
            return true;
        }
        log.debug("message_id={s} outcome=acknowledged_invalid error={s}", .{
            message_id,
            @errorName(err),
        });
        return false;
    };
    validateQueuedOperation(&submitted) catch |err| {
        log.debug("message_id={s} outcome=acknowledged_invalid error={s}", .{
            message_id,
            @errorName(err),
        });
        return false;
    };

    const account = accountingAccount(submitted.id);
    const account_outcome = execution.createAccount(&account) catch |err| {
        log.debug("message_id={s} stage=account outcome=retry error={s}", .{
            message_id,
            @errorName(err),
        });
        return true;
    };
    if (!account_outcome.succeeded) {
        log.debug("message_id={s} stage=account outcome=rejected status={d}", .{
            message_id,
            account_outcome.status,
        });
        return false;
    }

    const transfer = accountingTransfer(submitted.id);
    const transfer_outcome = execution.createTransfer(&transfer) catch |err| {
        log.debug("message_id={s} stage=transfer outcome=retry error={s}", .{
            message_id,
            @errorName(err),
        });
        return true;
    };
    if (!transfer_outcome.succeeded) {
        log.debug("message_id={s} stage=transfer outcome=rejected status={d}", .{
            message_id,
            transfer_outcome.status,
        });
        return false;
    }

    const now = clock.now();
    execution.complete(arena, &submitted, now) catch |err| {
        if (err == error.OperationConflict) {
            log.debug("message_id={s} stage=completion outcome=acknowledged_conflict", .{
                message_id,
            });
            return false;
        }
        log.debug("message_id={s} stage=completion outcome=retry error={s}", .{
            message_id,
            @errorName(err),
        });
        return true;
    };
    log.debug("message_id={s} outcome=succeeded", .{message_id});
    return false;
}

fn accountingAccount(operation_id: u128) tigerbeetle.Account {
    var account: tigerbeetle.Account = std.mem.zeroes(tigerbeetle.Account);
    account.id = operation_id;
    account.ledger = accounting_ledger;
    account.code = accounting_code;
    return account;
}

fn accountingTransfer(operation_id: u128) tigerbeetle.Transfer {
    var transfer: tigerbeetle.Transfer = std.mem.zeroes(tigerbeetle.Transfer);
    transfer.id = operation_id;
    transfer.debit_account_id = operation_id;
    transfer.credit_account_id = accounting_credit_account_id;
    transfer.amount = accounting_transfer_amount;
    transfer.ledger = accounting_ledger;
    transfer.code = accounting_code;
    return transfer;
}

fn validateQueuedOperation(submitted: *const operation.Operation) !void {
    if (submitted.state != .submitted) return error.InvalidState;
    if (submitted.body == null) return error.MissingBody;
    if (submitted.result != null) return error.UnexpectedResult;
    std.debug.assert(submitted.hash != null);
    std.debug.assert(submitted.last_updated != null);
    std.debug.assert(submitted.expires_at != null);
}

const success_outcome: CreateOutcome = .{ .status = 0, .succeeded = true };

const FakeExecution = struct {
    accounts: [record_count_max]tigerbeetle.Account = undefined,
    transfers: [record_count_max]tigerbeetle.Transfer = undefined,
    timestamps: [record_count_max]operation.UnixSeconds = undefined,
    account_outcomes: [record_count_max]CreateOutcome = .{success_outcome} ** record_count_max,
    transfer_outcomes: [record_count_max]CreateOutcome = .{success_outcome} ** record_count_max,
    account_errors: [record_count_max]?anyerror = .{null} ** record_count_max,
    transfer_errors: [record_count_max]?anyerror = .{null} ** record_count_max,
    completion_errors: [record_count_max]?anyerror = .{null} ** record_count_max,
    account_count: u8 = 0,
    transfer_count: u8 = 0,
    completion_count: u8 = 0,

    fn createAccount(
        fake: *FakeExecution,
        account: *const tigerbeetle.Account,
    ) !CreateOutcome {
        std.debug.assert(fake.account_count < record_count_max);
        const index = fake.account_count;
        fake.accounts[index] = account.*;
        fake.account_count += 1;
        if (fake.account_errors[index]) |err| return err;
        return fake.account_outcomes[index];
    }

    fn createTransfer(
        fake: *FakeExecution,
        transfer: *const tigerbeetle.Transfer,
    ) !CreateOutcome {
        std.debug.assert(fake.transfer_count < record_count_max);
        const index = fake.transfer_count;
        fake.transfers[index] = transfer.*;
        fake.transfer_count += 1;
        if (fake.transfer_errors[index]) |err| return err;
        return fake.transfer_outcomes[index];
    }

    fn complete(
        fake: *FakeExecution,
        arena: Allocator,
        submitted: *const operation.Operation,
        now: operation.UnixSeconds,
    ) !void {
        _ = arena;
        std.debug.assert(fake.completion_count < record_count_max);
        std.debug.assert(submitted.state == .submitted);
        std.debug.assert(submitted.body != null);
        std.debug.assert(submitted.result == null);
        const index = fake.completion_count;
        fake.timestamps[index] = now;
        fake.completion_count += 1;
        if (fake.completion_errors[index]) |err| return err;
    }
};

const FakeClock = struct {
    values: [record_count_max]operation.UnixSeconds = undefined,
    count: u8 = 0,

    fn now(clock: *FakeClock) operation.UnixSeconds {
        std.debug.assert(clock.count < record_count_max);
        const value = clock.values[clock.count];
        clock.count += 1;
        return value;
    }
};

fn testMessage(allocator: Allocator, id: u128) ![]u8 {
    const submitted: operation.Operation = .{
        .id = id,
        .tenant = "tenant-a",
        .name = "echo",
        .body = .{ .bool = true },
        .state = .submitted,
        .last_updated = 1_700_000_000,
        .expires_at = 1_700_086_400,
        .hash = [_]u8{0xAB} ** 32,
    };
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try operation.writeOutputJSON(&output.writer, &submitted);
    return output.toOwnedSlice();
}

fn testEvent(allocator: Allocator, bodies: []const []const u8) ![]u8 {
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

test "accounting events use the exact operation contract" {
    const id: u128 = 0x00112233445566778899aabbccddeeff;
    var expected_account: tigerbeetle.Account = std.mem.zeroes(tigerbeetle.Account);
    expected_account.id = id;
    expected_account.ledger = 1;
    expected_account.code = 1;
    try std.testing.expectEqualDeep(expected_account, accountingAccount(id));

    var expected_transfer: tigerbeetle.Transfer = std.mem.zeroes(tigerbeetle.Transfer);
    expected_transfer.id = id;
    expected_transfer.debit_account_id = id;
    expected_transfer.credit_account_id = 1;
    expected_transfer.amount = 100;
    expected_transfer.ledger = 1;
    expected_transfer.code = 1;
    try std.testing.expectEqualDeep(expected_transfer, accountingTransfer(id));
}

test "TigerBeetle configuration defaults and validates overrides" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();

    const defaults = try tigerbeetleConfiguration(&environment);
    try std.testing.expectEqual(@as(u128, 0), defaults.cluster_id);
    try std.testing.expectEqualStrings("10.200.0.2:3000", defaults.addresses);

    try environment.put("TIGERBEETLE_CLUSTER_ID", "340282366920938463463374607431768211455");
    try environment.put("TIGERBEETLE_ADDRESSES", "127.0.0.1:3000,127.0.0.1:3001");
    const configured = try tigerbeetleConfiguration(&environment);
    try std.testing.expectEqual(std.math.maxInt(u128), configured.cluster_id);
    try std.testing.expectEqualStrings(
        "127.0.0.1:3000,127.0.0.1:3001",
        configured.addresses,
    );

    const invalid_cluster_ids = [_][]const u8{
        "",
        "-1",
        "1a",
        "340282366920938463463374607431768211456",
    };
    for (invalid_cluster_ids) |invalid| {
        try environment.put("TIGERBEETLE_CLUSTER_ID", invalid);
        try std.testing.expectError(
            error.InvalidConfiguration,
            tigerbeetleConfiguration(&environment),
        );
    }
    try environment.put("TIGERBEETLE_CLUSTER_ID", "0");
    const invalid_addresses = [_][]const u8{
        "",
        "127.0.0.1:3000 127.0.0.1:3001",
        "\t3000",
    };
    for (invalid_addresses) |invalid| {
        try environment.put("TIGERBEETLE_ADDRESSES", invalid);
        try std.testing.expectError(
            error.InvalidConfiguration,
            tigerbeetleConfiguration(&environment),
        );
    }

    const oversized_addresses = "a" ** (tigerbeetle_addresses_size_max + 1);
    try environment.put("TIGERBEETLE_ADDRESSES", oversized_addresses);
    try std.testing.expectError(
        error.InvalidConfiguration,
        tigerbeetleConfiguration(&environment),
    );
}

test "valid records create accounting events before sampling completion timestamps" {
    const first = try testMessage(std.testing.allocator, 2);
    defer std.testing.allocator.free(first);
    const second = try testMessage(std.testing.allocator, 3);
    defer std.testing.allocator.free(second);
    const event = try testEvent(std.testing.allocator, &.{ first, second });
    defer std.testing.allocator.free(event);
    var fake: FakeExecution = .{};
    var clock: FakeClock = .{};
    clock.values[0] = 1_800_000_001;
    clock.values[1] = 1_800_000_002;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const response = try handleInvocation(
        arena.allocator(),
        event,
        ExecutionAdapter.init(&fake),
        Clock.init(&clock),
    );
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
    try std.testing.expectEqual(@as(u8, 2), fake.account_count);
    try std.testing.expectEqual(@as(u8, 2), fake.transfer_count);
    try std.testing.expectEqual(@as(u8, 2), fake.completion_count);
    try std.testing.expectEqual(@as(u8, 2), clock.count);
    try std.testing.expectEqualDeep(accountingAccount(2), fake.accounts[0]);
    try std.testing.expectEqualDeep(accountingTransfer(2), fake.transfers[0]);
    try std.testing.expectEqualDeep(accountingAccount(3), fake.accounts[1]);
    try std.testing.expectEqualDeep(accountingTransfer(3), fake.transfers[1]);
    try std.testing.expectEqual(@as(operation.UnixSeconds, 1_800_000_001), fake.timestamps[0]);
    try std.testing.expectEqual(@as(operation.UnixSeconds, 1_800_000_002), fake.timestamps[1]);
}

test "rejections are acknowledged before timestamp sampling or completion" {
    const message = try testMessage(std.testing.allocator, 2);
    defer std.testing.allocator.free(message);
    const event = try testEvent(std.testing.allocator, &.{message});
    defer std.testing.allocator.free(event);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var account_rejection: FakeExecution = .{};
    account_rejection.account_outcomes[0] = .{ .status = 19, .succeeded = false };
    var account_clock: FakeClock = .{};
    const account_response = try handleInvocation(
        arena.allocator(),
        event,
        ExecutionAdapter.init(&account_rejection),
        Clock.init(&account_clock),
    );
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", account_response);
    try std.testing.expectEqual(@as(u8, 1), account_rejection.account_count);
    try std.testing.expectEqual(@as(u8, 0), account_rejection.transfer_count);
    try std.testing.expectEqual(@as(u8, 0), account_rejection.completion_count);
    try std.testing.expectEqual(@as(u8, 0), account_clock.count);

    var transfer_rejection: FakeExecution = .{};
    transfer_rejection.transfer_outcomes[0] = .{ .status = 22, .succeeded = false };
    var transfer_clock: FakeClock = .{};
    const transfer_response = try handleInvocation(
        arena.allocator(),
        event,
        ExecutionAdapter.init(&transfer_rejection),
        Clock.init(&transfer_clock),
    );
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", transfer_response);
    try std.testing.expectEqual(@as(u8, 1), transfer_rejection.account_count);
    try std.testing.expectEqual(@as(u8, 1), transfer_rejection.transfer_count);
    try std.testing.expectEqual(@as(u8, 0), transfer_rejection.completion_count);
    try std.testing.expectEqual(@as(u8, 0), transfer_clock.count);
}

test "mixed outcomes report exact retryable identifiers and continue processing" {
    var messages: [8][]u8 = undefined;
    for (&messages, 0..) |*message, index| {
        message.* = try testMessage(std.testing.allocator, index + 2);
    }
    defer for (messages) |message| std.testing.allocator.free(message);
    const bodies = [_][]const u8{
        messages[0],
        "{invalid",
        messages[1],
        messages[2],
        messages[3],
        messages[4],
        messages[5],
        messages[6],
        messages[7],
    };
    const event = try testEvent(std.testing.allocator, &bodies);
    defer std.testing.allocator.free(event);
    var fake: FakeExecution = .{};
    fake.account_outcomes[1] = .{ .status = 19, .succeeded = false };
    fake.account_errors[2] = error.ClientClosed;
    fake.transfer_outcomes[1] = .{ .status = 22, .succeeded = false };
    fake.transfer_errors[2] = error.TooMuchData;
    fake.completion_errors[1] = error.OperationConflict;
    fake.completion_errors[2] = error.AWSFailure;
    var clock: FakeClock = .{};
    clock.values[0] = 1_800_000_001;
    clock.values[1] = 1_800_000_002;
    clock.values[2] = 1_800_000_003;
    clock.values[3] = 1_800_000_004;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const response = try handleInvocation(
        arena.allocator(),
        event,
        ExecutionAdapter.init(&fake),
        Clock.init(&clock),
    );
    try std.testing.expectEqualStrings(
        "{\"batchItemFailures\":[{\"itemIdentifier\":\"message-3\"}," ++
            "{\"itemIdentifier\":\"message-5\"}," ++
            "{\"itemIdentifier\":\"message-7\"}]}",
        response,
    );
    try std.testing.expectEqual(@as(u8, 8), fake.account_count);
    try std.testing.expectEqual(@as(u8, 6), fake.transfer_count);
    try std.testing.expectEqual(@as(u8, 4), fake.completion_count);
    try std.testing.expectEqual(@as(u8, 4), clock.count);
    try std.testing.expectEqual(@as(u128, 9), fake.accounts[7].id);
    try std.testing.expectEqual(@as(u128, 9), fake.transfers[5].id);
}

test "non-submitted bodyless and result-bearing operations are acknowledged" {
    const hash = "ab" ** 32;
    const records = [_][]const u8{
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"tenant-a\",\"name\":\"echo\",\"body\":true," ++
            "\"state\":\"RUNNING\",\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400,\"hash\":\"" ++ hash ++ "\"}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"tenant-a\",\"name\":\"echo\"," ++
            "\"state\":\"SUBMITTED\",\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400,\"hash\":\"" ++ hash ++ "\"}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"tenant-a\",\"name\":\"echo\",\"body\":true," ++
            "\"state\":\"SUBMITTED\",\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400,\"result\":null,\"hash\":\"" ++ hash ++ "\"}",
    };
    const event = try testEvent(std.testing.allocator, &records);
    defer std.testing.allocator.free(event);
    var fake: FakeExecution = .{};
    var clock: FakeClock = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const response = try handleInvocation(
        arena.allocator(),
        event,
        ExecutionAdapter.init(&fake),
        Clock.init(&clock),
    );
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
    try std.testing.expectEqual(@as(u8, 0), fake.account_count);
    try std.testing.expectEqual(@as(u8, 0), fake.transfer_count);
    try std.testing.expectEqual(@as(u8, 0), fake.completion_count);
    try std.testing.expectEqual(@as(u8, 0), clock.count);
}

test "record parsing allocation failure is retryable" {
    const message = try testMessage(std.testing.allocator, 2);
    defer std.testing.allocator.free(message);
    var fake: FakeExecution = .{};
    var clock: FakeClock = .{};

    try std.testing.expect(processRecord(
        std.testing.failing_allocator,
        "message-0",
        message,
        ExecutionAdapter.init(&fake),
        Clock.init(&clock),
    ));
    try std.testing.expectEqual(@as(u8, 0), fake.account_count);
    try std.testing.expectEqual(@as(u8, 0), fake.transfer_count);
    try std.testing.expectEqual(@as(u8, 0), fake.completion_count);
    try std.testing.expectEqual(@as(u8, 0), clock.count);
}

test "malformed non-SQS and oversized batch events are rejected" {
    var fake: FakeExecution = .{};
    var clock: FakeClock = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.InvalidInput,
        handleInvocation(
            arena.allocator(),
            "{}",
            ExecutionAdapter.init(&fake),
            Clock.init(&clock),
        ),
    );

    const event =
        \\{"Records":[{"messageId":"message-1","receiptHandle":"receipt-1",
        \\"body":"body","attributes":{},"messageAttributes":{},
        \\"eventSource":"aws:sns","eventSourceARN":"arn","awsRegion":"region"}]}
    ;
    try std.testing.expectError(
        error.UnexpectedEventSource,
        handleInvocation(
            arena.allocator(),
            event,
            ExecutionAdapter.init(&fake),
            Clock.init(&clock),
        ),
    );

    const bodies = [_][]const u8{"invalid"} ** (record_count_max + 1);
    const oversized = try testEvent(std.testing.allocator, &bodies);
    defer std.testing.allocator.free(oversized);
    try std.testing.expectError(
        error.TooManyRecords,
        handleInvocation(
            arena.allocator(),
            oversized,
            ExecutionAdapter.init(&fake),
            Clock.init(&clock),
        ),
    );
}

test "execution and AWS SDK debug logging are enabled in ReleaseSafe" {
    comptime {
        if (std_options.log_level != .info) @compileError("unexpected default log level");
        if (std_options.log_scope_levels.len != 2) @compileError("unexpected log scope count");
        if (std_options.log_scope_levels[0].scope != .execution) {
            @compileError("unexpected execution log scope");
        }
        if (std_options.log_scope_levels[0].level != .debug) {
            @compileError("execution debug logging is disabled");
        }
        if (std_options.log_scope_levels[1].scope != .aws_sdk) {
            @compileError("unexpected AWS SDK log scope");
        }
        if (std_options.log_scope_levels[1].level != .debug) {
            @compileError("AWS SDK debug logging is disabled");
        }
    }
}
