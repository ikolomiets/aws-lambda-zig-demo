const std = @import("std");
const aws = @import("aws");
const lambda = @import("aws-lambda");
const completion_batch = @import("completion_batch");
const operation = @import("operation");
const sqs_queue = @import("sqs_queue");
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
    std.debug.assert(
        record_count_max * (operation.result_size_max + operation.uuid_string_size + 64) <
            completion_batch.encoded_message_size_max,
    );
    std.debug.assert(tigerbeetle_addresses_default.len > 0);
    std.debug.assert(tigerbeetle_addresses_default.len <= tigerbeetle_addresses_size_max);
}

var runtime_execution_adapter: ?ExecutionAdapter = null;
var runtime_completion_publisher: ?CompletionPublisher = null;

pub fn main(init: std.process.Init) void {
    var resources: RuntimeResources = undefined;
    resources.init(init) catch |err| {
        std.log.err("Lambda initialization failed: {s}", .{@errorName(err)});
        return;
    };
    defer resources.deinit();

    installRuntimeAdapters(
        ExecutionAdapter.init(&resources),
        CompletionPublisher.init(&resources),
    );
    defer uninstallRuntimeAdapters();
    lambda.handle(init, handler, .{});
}

fn handler(ctx: lambda.Context, event: []const u8) ![]const u8 {
    const execution = runtime_execution_adapter orelse {
        return error.ExecutionNotInitialized;
    };
    const publisher = runtime_completion_publisher orelse {
        return error.CompletionPublisherNotInitialized;
    };
    return handleInvocation(ctx.arena, event, execution, publisher);
}

const RuntimeResources = struct {
    config: aws.Config,
    completion_queue: sqs_queue.Queue,
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

        sqs_queue.Queue.init(
            &resources.completion_queue,
            process_init.gpa,
            &resources.config,
            process_init.environ_map,
            "COMPLETION_QUEUE_URL",
        ) catch return error.CompletionQueueConfigurationFailure;
        errdefer resources.completion_queue.deinit();

        resources.tigerbeetle_client = tigerbeetle.Client.create(
            process_init.gpa,
            process_init.io,
            tigerbeetle_config.cluster_id,
            tigerbeetle_config.addresses,
        ) catch return error.TigerBeetleInitializationFailure;
    }

    fn deinit(resources: *RuntimeResources) void {
        resources.tigerbeetle_client.destroy();
        resources.completion_queue.deinit();
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

        const status = results[0].status;
        if (tigerbeetle.create_account_succeeded(status)) return .accepted;
        return .{ .rejected = status };
    }

    fn createTransfer(
        resources: *RuntimeResources,
        transfer: *const tigerbeetle.Transfer,
    ) !CreateOutcome {
        const results = try resources.tigerbeetle_client.createTransfers(transfer[0..1]);
        defer resources.tigerbeetle_client.allocator.free(results);
        if (results.len != 1) return error.MalformedResult;

        const status = results[0].status;
        if (tigerbeetle.create_transfer_succeeded(status)) return .accepted;
        return .{ .rejected = status };
    }

    fn sendCompletion(
        resources: *RuntimeResources,
        arena: Allocator,
        body: []const u8,
    ) !void {
        return resources.completion_queue.send(arena, body);
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

const CreateOutcome = union(enum) {
    accepted,
    rejected: u32,
};

const FailureStage = enum {
    account,
    transfer,
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
        };
        return .{
            .context = pointer,
            .create_account_fn = Adapter.createAccount,
            .create_transfer_fn = Adapter.createTransfer,
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
};

const CompletionPublisher = struct {
    context: *anyopaque,
    send_fn: *const fn (*anyopaque, Allocator, []const u8) anyerror!void,

    fn init(pointer: anytype) CompletionPublisher {
        const Pointer = @TypeOf(pointer);
        const pointer_info = @typeInfo(Pointer);
        comptime std.debug.assert(pointer_info == .pointer);
        comptime std.debug.assert(pointer_info.pointer.size == .one);

        const Adapter = struct {
            fn send(
                context: *anyopaque,
                arena: Allocator,
                body: []const u8,
            ) anyerror!void {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.sendCompletion(arena, body);
            }
        };
        return .{
            .context = pointer,
            .send_fn = Adapter.send,
        };
    }

    fn send(publisher: CompletionPublisher, arena: Allocator, body: []const u8) !void {
        return publisher.send_fn(publisher.context, arena, body);
    }
};

fn installRuntimeAdapters(
    execution: ExecutionAdapter,
    publisher: CompletionPublisher,
) void {
    std.debug.assert(runtime_execution_adapter == null);
    std.debug.assert(runtime_completion_publisher == null);
    runtime_execution_adapter = execution;
    runtime_completion_publisher = publisher;
    std.debug.assert(runtime_execution_adapter != null);
    std.debug.assert(runtime_completion_publisher != null);
}

fn uninstallRuntimeAdapters() void {
    std.debug.assert(runtime_execution_adapter != null);
    std.debug.assert(runtime_completion_publisher != null);
    runtime_execution_adapter = null;
    runtime_completion_publisher = null;
    std.debug.assert(runtime_execution_adapter == null);
    std.debug.assert(runtime_completion_publisher == null);
}

const RecordParseOutcome = union(enum) {
    acknowledged,
    retry,
    valid: operation.Operation,
};

const ExecutionOutcome = union(enum) {
    retry,
    terminal: completion_batch.Entry,
};

fn handleInvocation(
    allocator: Allocator,
    event: []const u8,
    execution: ExecutionAdapter,
    publisher: CompletionPublisher,
) ![]const u8 {
    const sqs_event = try lambda.sqs.parseEvent(allocator, event);
    defer sqs_event.deinit(allocator);
    if (sqs_event.records.len > record_count_max) return error.TooManyRecords;

    var queued_operations: [record_count_max]operation.Operation = undefined;
    var queued_record_indexes: [record_count_max]usize = undefined;
    var entries: [record_count_max]completion_batch.Entry = undefined;
    var represented_record_indexes: [record_count_max]usize = undefined;
    var retry_records = [_]bool{false} ** record_count_max;
    var queued_count: usize = 0;
    var entry_count: usize = 0;
    for (sqs_event.records, 0..) |record, record_index| {
        log.debug("message_id={s} body={s}", .{ record.message_id, record.body });
        switch (parseRecord(allocator, record.message_id, record.body)) {
            .acknowledged => {},
            .retry => retry_records[record_index] = true,
            .valid => |queued| {
                std.debug.assert(queued_count < record_count_max);
                queued_operations[queued_count] = queued;
                queued_record_indexes[queued_count] = record_index;
                queued_count += 1;
            },
        }
    }
    for (queued_operations[0..queued_count], queued_record_indexes[0..queued_count]) |
        *queued,
        record_index,
    | {
        const message_id = sqs_event.records[record_index].message_id;
        switch (executeOperation(allocator, message_id, queued, execution)) {
            .retry => retry_records[record_index] = true,
            .terminal => |entry| {
                std.debug.assert(entry_count < queued_count);
                entries[entry_count] = entry;
                represented_record_indexes[entry_count] = record_index;
                entry_count += 1;
            },
        }
    }
    std.debug.assert(queued_count <= sqs_event.records.len);
    std.debug.assert(entry_count <= queued_count);
    std.debug.assert(entry_count <= sqs_event.records.len);

    publishCompletions(allocator, entries[0..entry_count], publisher) catch |err| {
        log.debug("stage=completion_publish outcome=retry error={s}", .{@errorName(err)});
        for (represented_record_indexes[0..entry_count]) |record_index| {
            std.debug.assert(record_index < sqs_event.records.len);
            retry_records[record_index] = true;
        }
    };

    return encodeFailureResponse(allocator, sqs_event.records, &retry_records);
}

fn publishCompletions(
    arena: Allocator,
    entries: []const completion_batch.Entry,
    publisher: CompletionPublisher,
) !void {
    if (entries.len == 0) return;
    std.debug.assert(entries.len <= record_count_max);
    const message = try completion_batch.encode(arena, &.{ .results = entries });
    try publisher.send(arena, message);
}

fn encodeFailureResponse(
    allocator: Allocator,
    records: []const lambda.sqs.Record,
    retry_records: *const [record_count_max]bool,
) ![]const u8 {
    std.debug.assert(records.len <= record_count_max);
    var failures: [record_count_max]lambda.sqs.BatchItemFailure = undefined;
    var failure_count: usize = 0;
    for (records, 0..) |record, record_index| {
        if (retry_records[record_index]) {
            failures[failure_count] = .{ .item_identifier = record.message_id };
            failure_count += 1;
        }
    }
    std.debug.assert(failure_count <= records.len);
    return lambda.sqs.encodeResponse(allocator, .{
        .batch_item_failures = failures[0..failure_count],
    });
}

fn parseRecord(
    arena: Allocator,
    message_id: []const u8,
    body: []const u8,
) RecordParseOutcome {
    const queued = operation.parseOutputJSON(arena, body) catch |err| {
        if (err == error.OutOfMemory) {
            log.debug("message_id={s} stage=parse outcome=retry error={s}", .{
                message_id,
                @errorName(err),
            });
            return .retry;
        }
        log.debug("message_id={s} outcome=acknowledged_invalid error={s}", .{
            message_id,
            @errorName(err),
        });
        return .acknowledged;
    };
    validateQueuedOperation(&queued) catch |err| {
        log.debug("message_id={s} outcome=acknowledged_invalid error={s}", .{
            message_id,
            @errorName(err),
        });
        return .acknowledged;
    };
    return .{ .valid = queued };
}

fn executeOperation(
    arena: Allocator,
    message_id: []const u8,
    queued: *const operation.Operation,
    execution: ExecutionAdapter,
) ExecutionOutcome {
    std.debug.assert(queued.status == .submitted);
    std.debug.assert(queued.body != null);

    const account = accountingAccount(queued.id);
    const account_outcome = execution.createAccount(&account) catch |err| {
        log.debug("message_id={s} stage=account outcome=retry error={s}", .{
            message_id,
            @errorName(err),
        });
        return .retry;
    };
    switch (account_outcome) {
        .accepted => {},
        .rejected => |status| return processRecordRejection(
            arena,
            message_id,
            queued.id,
            .account,
            status,
        ),
    }

    const transfer = accountingTransfer(queued.id);
    const transfer_outcome = execution.createTransfer(&transfer) catch |err| {
        log.debug("message_id={s} stage=transfer outcome=retry error={s}", .{
            message_id,
            @errorName(err),
        });
        return .retry;
    };
    switch (transfer_outcome) {
        .accepted => {},
        .rejected => |status| return processRecordRejection(
            arena,
            message_id,
            queued.id,
            .transfer,
            status,
        ),
    }

    const completion = successCompletion(arena, queued.id) catch |err| {
        log.debug("message_id={s} stage=completion_payload outcome=retry error={s}", .{
            message_id,
            @errorName(err),
        });
        return .retry;
    };
    log.debug("message_id={s} outcome=succeeded", .{message_id});
    return .{ .terminal = .{ .operation_id = queued.id, .result = completion } };
}

fn processRecordRejection(
    arena: Allocator,
    message_id: []const u8,
    operation_id: u128,
    stage: FailureStage,
    status: u32,
) ExecutionOutcome {
    log.debug("message_id={s} stage={s} outcome=rejected status={d}", .{
        message_id,
        @tagName(stage),
        status,
    });
    const completion = failureCompletion(arena, stage, status) catch |err| {
        log.debug("message_id={s} stage=completion_payload outcome=retry error={s}", .{
            message_id,
            @errorName(err),
        });
        return .retry;
    };
    return .{ .terminal = .{ .operation_id = operation_id, .result = completion } };
}

fn successCompletion(arena: Allocator, operation_id: u128) !operation.Completion {
    var id_buffer: [36]u8 = undefined;
    const transfer_id = try arena.dupe(u8, operation.uuidToString(operation_id, &id_buffer));
    var payload = try std.json.ObjectMap.init(arena, &.{}, &.{});
    try payload.put(arena, "transfer_id", .{ .string = transfer_id });
    std.debug.assert(payload.count() == 1);
    return .{ .success = .{ .object = payload } };
}

fn failureCompletion(
    arena: Allocator,
    stage: FailureStage,
    status: u32,
) !operation.Completion {
    const stage_name: []const u8 = switch (stage) {
        .account => "ACCOUNT",
        .transfer => "TRANSFER",
    };
    switch (stage) {
        .account => std.debug.assert(!tigerbeetle.create_account_succeeded(status)),
        .transfer => std.debug.assert(!tigerbeetle.create_transfer_succeeded(status)),
    }

    const stage_owned = try arena.dupe(u8, stage_name);
    var payload = try std.json.ObjectMap.init(arena, &.{}, &.{});
    try payload.put(arena, "stage", .{ .string = stage_owned });
    try payload.put(arena, "status", .{ .integer = @intCast(status) });
    std.debug.assert(payload.count() == 2);
    return .{ .failure = .{ .object = payload } };
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

fn validateQueuedOperation(queued: *const operation.Operation) !void {
    if (queued.status != .submitted) return error.InvalidState;
    if (queued.body == null) return error.MissingBody;
    std.debug.assert(queued.hash != null);
    std.debug.assert(queued.last_updated != null);
    std.debug.assert(queued.expires_at != null);
}

const success_outcome: CreateOutcome = .accepted;

const FakeExecution = struct {
    accounts: [record_count_max]tigerbeetle.Account = undefined,
    transfers: [record_count_max]tigerbeetle.Transfer = undefined,
    account_outcomes: [record_count_max]CreateOutcome = .{success_outcome} ** record_count_max,
    transfer_outcomes: [record_count_max]CreateOutcome = .{success_outcome} ** record_count_max,
    account_errors: [record_count_max]?anyerror = .{null} ** record_count_max,
    transfer_errors: [record_count_max]?anyerror = .{null} ** record_count_max,
    account_count: u8 = 0,
    transfer_count: u8 = 0,

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
};

const FakePublisher = struct {
    message: []const u8 = undefined,
    execution: ?*const FakeExecution = null,
    send_error: ?anyerror = null,
    account_count_at_send: u8 = 0,
    transfer_count_at_send: u8 = 0,
    send_count: u8 = 0,

    fn sendCompletion(
        fake: *FakePublisher,
        arena: Allocator,
        body: []const u8,
    ) !void {
        _ = arena;
        std.debug.assert(fake.send_count == 0);
        std.debug.assert(body.len > 0);
        fake.message = body;
        if (fake.execution) |execution| {
            fake.account_count_at_send = execution.account_count;
            fake.transfer_count_at_send = execution.transfer_count;
        }
        fake.send_count += 1;
        if (fake.send_error) |err| return err;
    }
};

fn testMessage(allocator: Allocator, id: u128) ![]u8 {
    const queued: operation.Operation = .{
        .id = id,
        .tenant = "tenant-a",
        .name = "echo",
        .body = .{ .bool = true },
        .status = .submitted,
        .last_updated = 1_700_000_000,
        .expires_at = 1_700_086_400,
        .hash = [_]u8{0xAB} ** 32,
    };
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try operation.writeOutputJSON(&output.writer, &queued);
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

test "success completion contains the canonical arena-owned transfer id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const completion = try successCompletion(
        arena.allocator(),
        0x00112233445566778899aabbccddeeff,
    );

    try std.testing.expect(completion == .success);
    try std.testing.expect(completion.success == .object);
    try std.testing.expectEqualStrings(
        "00112233-4455-6677-8899-aabbccddeeff",
        completion.success.object.get("transfer_id").?.string,
    );
    try std.testing.expectError(
        error.OutOfMemory,
        successCompletion(std.testing.failing_allocator, 1),
    );
}

test "failure completions contain exact arena-owned stages and raw statuses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct {
        stage: FailureStage,
        status: u32,
        expected: []const u8,
    }{
        .{
            .stage = .account,
            .status = 19,
            .expected = "{\"type\":\"FAILURE\",\"payload\":{\"stage\":\"ACCOUNT\",\"status\":19}}",
        },
        .{
            .stage = .transfer,
            .status = 22,
            .expected = "{\"type\":\"FAILURE\",\"payload\":{\"stage\":\"TRANSFER\",\"status\":22}}",
        },
    };
    for (cases) |case| {
        const completion = try failureCompletion(arena.allocator(), case.stage, case.status);
        var buffer: [operation.result_size_max]u8 = undefined;
        try std.testing.expectEqualStrings(
            case.expected,
            try operation.writeCompletionJSON(&buffer, &completion),
        );
    }
    try std.testing.expectError(
        error.OutOfMemory,
        failureCompletion(std.testing.failing_allocator, .account, 19),
    );
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

test "mixed source outcomes publish one exact aggregate after all execution" {
    var messages: [6][]u8 = undefined;
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
    };
    const event = try testEvent(std.testing.allocator, &bodies);
    defer std.testing.allocator.free(event);
    var fake: FakeExecution = .{};
    fake.account_outcomes[1] = .{ .rejected = 19 };
    fake.account_errors[2] = error.ClientClosed;
    fake.transfer_outcomes[1] = .{ .rejected = 22 };
    fake.transfer_errors[2] = error.TooMuchData;
    var publisher: FakePublisher = .{ .execution = &fake };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const response = try handleInvocation(
        arena.allocator(),
        event,
        ExecutionAdapter.init(&fake),
        CompletionPublisher.init(&publisher),
    );
    try std.testing.expectEqualStrings(
        "{\"batchItemFailures\":[{\"itemIdentifier\":\"message-3\"}," ++
            "{\"itemIdentifier\":\"message-5\"}]}",
        response,
    );
    try std.testing.expectEqual(@as(u8, 6), fake.account_count);
    try std.testing.expectEqual(@as(u8, 4), fake.transfer_count);
    try std.testing.expectEqual(@as(u8, 1), publisher.send_count);
    try std.testing.expectEqual(fake.account_count, publisher.account_count_at_send);
    try std.testing.expectEqual(fake.transfer_count, publisher.transfer_count_at_send);
    try std.testing.expectEqualStrings(
        "{\"results\":[" ++
            "{\"operation_id\":\"00000000-0000-0000-0000-000000000002\"," ++
            "\"result\":{\"type\":\"SUCCESS\",\"payload\":{" ++
            "\"transfer_id\":\"00000000-0000-0000-0000-000000000002\"}}}," ++
            "{\"operation_id\":\"00000000-0000-0000-0000-000000000003\"," ++
            "\"result\":{\"type\":\"FAILURE\",\"payload\":{" ++
            "\"stage\":\"ACCOUNT\",\"status\":19}}}," ++
            "{\"operation_id\":\"00000000-0000-0000-0000-000000000005\"," ++
            "\"result\":{\"type\":\"FAILURE\",\"payload\":{" ++
            "\"stage\":\"TRANSFER\",\"status\":22}}}," ++
            "{\"operation_id\":\"00000000-0000-0000-0000-000000000007\"," ++
            "\"result\":{\"type\":\"SUCCESS\",\"payload\":{" ++
            "\"transfer_id\":\"00000000-0000-0000-0000-000000000007\"}}}]}",
        publisher.message,
    );
    try std.testing.expect(std.mem.indexOf(u8, publisher.message, "tenant") == null);
    try std.testing.expect(std.mem.indexOf(u8, publisher.message, "state") == null);
    try std.testing.expect(std.mem.indexOf(u8, publisher.message, "hash") == null);
}

test "no terminal results produce no aggregate send" {
    const message = try testMessage(std.testing.allocator, 2);
    defer std.testing.allocator.free(message);
    const event = try testEvent(std.testing.allocator, &.{ "{invalid", message });
    defer std.testing.allocator.free(event);
    var fake: FakeExecution = .{};
    fake.account_errors[0] = error.ClientClosed;
    var publisher: FakePublisher = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const response = try handleInvocation(
        arena.allocator(),
        event,
        ExecutionAdapter.init(&fake),
        CompletionPublisher.init(&publisher),
    );
    try std.testing.expectEqualStrings(
        "{\"batchItemFailures\":[{\"itemIdentifier\":\"message-1\"}]}",
        response,
    );
    try std.testing.expectEqual(@as(u8, 1), fake.account_count);
    try std.testing.expectEqual(@as(u8, 0), fake.transfer_count);
    try std.testing.expectEqual(@as(u8, 0), publisher.send_count);
}

test "aggregate send failure retries represented records in source order" {
    var messages: [3][]u8 = undefined;
    for (&messages, 0..) |*message, index| {
        message.* = try testMessage(std.testing.allocator, index + 2);
    }
    defer for (messages) |message| std.testing.allocator.free(message);
    const event = try testEvent(
        std.testing.allocator,
        &.{ messages[0], messages[1], "{invalid", messages[2] },
    );
    defer std.testing.allocator.free(event);
    var fake: FakeExecution = .{};
    fake.account_errors[1] = error.ClientClosed;
    fake.account_outcomes[2] = .{ .rejected = 19 };
    var publisher: FakePublisher = .{ .send_error = error.AWSFailure };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const response = try handleInvocation(
        arena.allocator(),
        event,
        ExecutionAdapter.init(&fake),
        CompletionPublisher.init(&publisher),
    );
    try std.testing.expectEqualStrings(
        "{\"batchItemFailures\":[{\"itemIdentifier\":\"message-0\"}," ++
            "{\"itemIdentifier\":\"message-1\"}," ++
            "{\"itemIdentifier\":\"message-3\"}]}",
        response,
    );
    try std.testing.expectEqual(@as(u8, 1), publisher.send_count);
    const decoded = try completion_batch.decode(arena.allocator(), publisher.message);
    try std.testing.expectEqual(@as(usize, 2), decoded.results.len);
    try std.testing.expect(decoded.results[0] == .valid);
    try std.testing.expectEqual(@as(u128, 2), decoded.results[0].valid.operation_id);
    try std.testing.expect(decoded.results[1] == .valid);
    try std.testing.expectEqual(@as(u128, 4), decoded.results[1].valid.operation_id);
}

test "duplicate operations remain terminal and share one aggregate send" {
    const message = try testMessage(std.testing.allocator, 2);
    defer std.testing.allocator.free(message);
    const event = try testEvent(std.testing.allocator, &.{ message, message });
    defer std.testing.allocator.free(event);
    var fake: FakeExecution = .{};
    var publisher: FakePublisher = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const response = try handleInvocation(
        arena.allocator(),
        event,
        ExecutionAdapter.init(&fake),
        CompletionPublisher.init(&publisher),
    );
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
    try std.testing.expectEqual(@as(u8, 2), fake.account_count);
    try std.testing.expectEqual(@as(u8, 2), fake.transfer_count);
    try std.testing.expectEqual(@as(u8, 1), publisher.send_count);
    const decoded = try completion_batch.decode(arena.allocator(), publisher.message);
    try std.testing.expectEqual(@as(usize, 2), decoded.results.len);
    for (decoded.results) |result| {
        try std.testing.expect(result == .valid);
        try std.testing.expectEqual(@as(u128, 2), result.valid.operation_id);
    }
}

test "unsupported queued operation schemas are acknowledged" {
    const hash = "ab" ** 32;
    const records = [_][]const u8{
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"tenant-a\",\"name\":\"echo\",\"body\":true," ++
            "\"state\":\"UNKNOWN\",\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400,\"hash\":\"" ++ hash ++ "\"}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"tenant-a\",\"name\":\"echo\",\"body\":true," ++
            "\"state\":\"COMPLETED\",\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400,\"result\":{" ++
            "\"type\":\"SUCCESS\",\"payload\":true},\"hash\":\"" ++ hash ++ "\"}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"tenant-a\",\"name\":\"echo\",\"body\":true," ++
            "\"state\":\"COMPLETED\",\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400,\"result\":{" ++
            "\"type\":\"FAILURE\",\"payload\":false},\"hash\":\"" ++ hash ++ "\"}",
        "{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\"," ++
            "\"tenant\":\"tenant-a\",\"name\":\"echo\",\"body\":true," ++
            "\"state\":\"COMPLETED\",\"last_updated\":1700000000," ++
            "\"expires_at\":1700086400,\"result\":{" ++
            "\"type\":\"success\",\"payload\":true},\"hash\":\"" ++ hash ++ "\"}",
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
    var publisher: FakePublisher = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const response = try handleInvocation(
        arena.allocator(),
        event,
        ExecutionAdapter.init(&fake),
        CompletionPublisher.init(&publisher),
    );
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
    try std.testing.expectEqual(@as(u8, 0), fake.account_count);
    try std.testing.expectEqual(@as(u8, 0), fake.transfer_count);
    try std.testing.expectEqual(@as(u8, 0), publisher.send_count);
}

test "record parsing allocation failure is retryable" {
    const message = try testMessage(std.testing.allocator, 2);
    defer std.testing.allocator.free(message);

    const outcome = parseRecord(
        std.testing.failing_allocator,
        "message-0",
        message,
    );
    try std.testing.expect(outcome == .retry);
}

test "aggregate encoding allocation failure occurs before send" {
    const entries = [_]completion_batch.Entry{.{
        .operation_id = 2,
        .result = .{ .success = .{ .bool = true } },
    }};
    var publisher: FakePublisher = .{};

    try std.testing.expectError(
        error.OutOfMemory,
        publishCompletions(
            std.testing.failing_allocator,
            &entries,
            CompletionPublisher.init(&publisher),
        ),
    );
    try std.testing.expectEqual(@as(u8, 0), publisher.send_count);
}

test "malformed non-SQS and oversized batch events are rejected" {
    var fake: FakeExecution = .{};
    var publisher: FakePublisher = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.InvalidInput,
        handleInvocation(
            arena.allocator(),
            "{}",
            ExecutionAdapter.init(&fake),
            CompletionPublisher.init(&publisher),
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
            CompletionPublisher.init(&publisher),
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
            CompletionPublisher.init(&publisher),
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
