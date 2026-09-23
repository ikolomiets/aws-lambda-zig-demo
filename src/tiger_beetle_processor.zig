const std = @import("std");
const aws = @import("aws");
const lambda = @import("aws-lambda");
const processor_message = @import("processor_message");
const operation = @import("operation");
const sqs_queue = @import("sqs_queue");
const tigerbeetle = @import("tigerbeetle");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{
            .scope = .tiger_beetle_processor,
            .level = .debug,
        },
        .{
            .scope = .aws_sdk,
            .level = .debug,
        },
    },
};

const Allocator = std.mem.Allocator;
const record_count_max = 10;
const tigerbeetle_addresses_default = "10.200.0.2:3000";
const tigerbeetle_addresses_size_max = 4096;
const tigerbeetle_cluster_id_default = "0";
const log = std.log.scoped(.tiger_beetle_processor);

comptime {
    std.debug.assert(record_count_max > 0);
    std.debug.assert(record_count_max <= 10);
    std.debug.assert(processor_message.encoded_size_max < 1024 * 1024);
    std.debug.assert(processor_message.queue_url_size_max == sqs_queue.queue_url_size_max);
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

    fn createAccounts(
        resources: *RuntimeResources,
        accounts: []const tigerbeetle.Account,
        output: []tigerbeetle.CreateAccountResult,
    ) !usize {
        return resources.tigerbeetle_client.createAccounts(accounts, output);
    }

    fn createTransfers(
        resources: *RuntimeResources,
        transfers: []const tigerbeetle.Transfer,
        output: []tigerbeetle.CreateTransferResult,
    ) !usize {
        return resources.tigerbeetle_client.createTransfers(transfers, output);
    }

    fn lookupAccounts(
        resources: *RuntimeResources,
        ids: []const u128,
        output: []tigerbeetle.Account,
    ) !usize {
        return resources.tigerbeetle_client.lookupAccounts(ids, output);
    }

    fn sendCompletion(
        resources: *RuntimeResources,
        arena: Allocator,
        result_queue: ?[]const u8,
        body: []const u8,
    ) !void {
        return resources.completion_queue.sender.send(arena, result_queue orelse resources.completion_queue.queue_url, body);
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

const ExecutionAdapter = struct {
    context: *anyopaque,
    create_accounts_fn: *const fn (
        *anyopaque,
        []const tigerbeetle.Account,
        []tigerbeetle.CreateAccountResult,
    ) anyerror!usize,
    create_transfers_fn: *const fn (
        *anyopaque,
        []const tigerbeetle.Transfer,
        []tigerbeetle.CreateTransferResult,
    ) anyerror!usize,
    lookup_accounts_fn: *const fn (*anyopaque, []const u128, []tigerbeetle.Account) anyerror!usize,

    fn init(pointer: anytype) ExecutionAdapter {
        const Pointer = @TypeOf(pointer);
        const pointer_info = @typeInfo(Pointer);
        comptime std.debug.assert(pointer_info == .pointer);
        comptime std.debug.assert(pointer_info.pointer.size == .one);
        const Adapter = struct {
            fn createAccounts(
                context: *anyopaque,
                input: []const tigerbeetle.Account,
                output: []tigerbeetle.CreateAccountResult,
            ) anyerror!usize {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.createAccounts(input, output);
            }
            fn createTransfers(
                context: *anyopaque,
                input: []const tigerbeetle.Transfer,
                output: []tigerbeetle.CreateTransferResult,
            ) anyerror!usize {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.createTransfers(input, output);
            }
            fn lookupAccounts(
                context: *anyopaque,
                input: []const u128,
                output: []tigerbeetle.Account,
            ) anyerror!usize {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.lookupAccounts(input, output);
            }
        };
        return .{
            .context = pointer,
            .create_accounts_fn = Adapter.createAccounts,
            .create_transfers_fn = Adapter.createTransfers,
            .lookup_accounts_fn = Adapter.lookupAccounts,
        };
    }
    fn createAccounts(
        execution: ExecutionAdapter,
        input: []const tigerbeetle.Account,
        output: []tigerbeetle.CreateAccountResult,
    ) !usize {
        std.debug.assert(input.len > 0);
        std.debug.assert(output.len >= input.len);
        return execution.create_accounts_fn(execution.context, input, output);
    }
    fn createTransfers(
        execution: ExecutionAdapter,
        input: []const tigerbeetle.Transfer,
        output: []tigerbeetle.CreateTransferResult,
    ) !usize {
        std.debug.assert(input.len > 0);
        std.debug.assert(output.len >= input.len);
        return execution.create_transfers_fn(execution.context, input, output);
    }
    fn lookupAccounts(
        execution: ExecutionAdapter,
        input: []const u128,
        output: []tigerbeetle.Account,
    ) !usize {
        std.debug.assert(input.len > 0);
        std.debug.assert(output.len >= input.len);
        return execution.lookup_accounts_fn(execution.context, input, output);
    }
};

const CompletionPublisher = struct {
    context: *anyopaque,
    send_fn: *const fn (*anyopaque, Allocator, ?[]const u8, []const u8) anyerror!void,

    fn init(pointer: anytype) CompletionPublisher {
        const Pointer = @TypeOf(pointer);
        const pointer_info = @typeInfo(Pointer);
        comptime std.debug.assert(pointer_info == .pointer);
        comptime std.debug.assert(pointer_info.pointer.size == .one);

        const Adapter = struct {
            fn send(
                context: *anyopaque,
                arena: Allocator,
                result_queue: ?[]const u8,
                body: []const u8,
            ) anyerror!void {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.sendCompletion(arena, result_queue, body);
            }
        };
        return .{
            .context = pointer,
            .send_fn = Adapter.send,
        };
    }

    fn send(publisher: CompletionPublisher, arena: Allocator, result_queue: ?[]const u8, body: []const u8) !void {
        return publisher.send_fn(publisher.context, arena, result_queue, body);
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
    valid: processor_message.Message,
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

    var queued_operations: [record_count_max]processor_message.Message = undefined;
    var queued_record_indexes: [record_count_max]usize = undefined;
    const result_buffer = try allocator.create([operation.result_size_max]u8);
    defer allocator.destroy(result_buffer);
    const completion_buffer = try allocator.alloc(u8, completion_buffer_size);
    defer allocator.free(completion_buffer);
    var retry_records = [_]bool{false} ** record_count_max;
    var queued_count: usize = 0;
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
    var plans = [_]?Planning{null} ** record_count_max;
    defer for (plans[0..queued_count]) |planning| {
        if (planning) |value| if (value == .admitted) {
            allocator.free(value.admitted.commands);
            allocator.free(value.admitted.outcomes);
        };
    };
    for (queued_operations[0..queued_count], 0..) |*queued, index| {
        plans[index] = plan_body(allocator, &queued.body) catch null;
    }
    execute_phases(allocator, plans[0..queued_count], execution) catch |err| {
        log.debug("stage=native outcome=stopped error={s}", .{@errorName(err)});
    };
    publish_results(allocator, queued_operations[0..queued_count], plans[0..queued_count], queued_record_indexes[0..queued_count], retry_records[0..sqs_event.records.len], result_buffer, completion_buffer, publisher);

    return encodeFailureResponse(allocator, sqs_event.records, &retry_records);
}

// Transport count is independent of invocation delivery and native packet capacity.
const completion_count_max = 1;

fn publish_results(
    allocator: Allocator,
    queued: []const processor_message.Message,
    plans: []const ?Planning,
    record_indexes: []const usize,
    retry_records: []bool,
    result_buffer: *[operation.result_size_max]u8,
    completion_buffer: []u8,
    publisher: CompletionPublisher,
) void {
    std.debug.assert(queued.len == plans.len);
    std.debug.assert(queued.len == record_indexes.len);
    // A successful serial send acknowledges exactly its source, never an unsent suffix.
    for (record_indexes) |index| retry_records[index] = true;
    for (queued, plans, record_indexes) |*entry, planning, record_index| {
        const plan = &(planning orelse continue);
        const body = switch (plan.*) {
            .rejected => |*diagnostic| write_diagnostic(result_buffer, diagnostic),
            .admitted => |*admitted| write_result(result_buffer, admitted) catch continue,
        };
        const message = processor_message.frame(completion_buffer, entry.operation_id, body, null) catch return;
        publisher.send(allocator, entry.result_queue, message) catch return;
        retry_records[record_index] = false;
    }
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
    const queued = processor_message.decode(arena, body) catch |err| {
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
    return .{ .valid = queued };
}

// The independent native packet bound is deliberately unrelated to SQS delivery size.
const native_capacity = 8189;
const ChainRange = struct { operation_index: usize, start: usize, count: usize };
const ChainState = enum { unfinished, accepted, rejected };

fn family_offset(plan: *const Plan, family: Family) usize {
    return switch (family) {
        .create_accounts => 0,
        .create_transfers => plan.counts[0],
        .lookup_accounts => plan.counts[0] + plan.counts[1],
    };
}

fn packet_fits(used: usize, count: usize, capacity: usize) bool {
    std.debug.assert(capacity <= native_capacity);
    std.debug.assert(used <= capacity);
    std.debug.assert(count > 0 and count <= capacity);
    return count <= capacity - used;
}

fn classify_chain(comptime family: Family, reply: anytype) !ChainState {
    std.debug.assert(family != .lookup_accounts);
    std.debug.assert(reply.len > 0 and reply.len <= native_capacity);
    const created = if (family == .create_accounts) tigerbeetle.account_created else tigerbeetle.transfer_created;
    const exists = if (family == .create_accounts) tigerbeetle.account_exists else tigerbeetle.transfer_exists;
    const linked_failed = if (family == .create_accounts) tigerbeetle.account_linked_event_failed else tigerbeetle.transfer_linked_event_failed;
    var created_count: usize = 0;
    var decisive: ?usize = null;
    for (reply, 0..) |result, index| {
        if (result.status == created) {
            created_count += 1;
        } else if (result.status != linked_failed) {
            if (decisive != null) return error.InvalidCreationReply;
            decisive = index;
        }
    }
    if (created_count == reply.len) return .accepted;
    if (created_count != 0) return error.InvalidCreationReply;
    const index = decisive orelse return error.InvalidCreationReply;
    return if (index == 0 and reply[0].status == exists) .accepted else .rejected;
}

fn apply_creation_reply(
    comptime family: Family,
    plans: []?Planning,
    ranges: []const ChainRange,
    reply: anytype,
    submitted: usize,
) !void {
    std.debug.assert(submitted > 0 and submitted <= native_capacity);
    if (reply.len != submitted) return error.InvalidCreationReply;
    var covered: usize = 0;
    // No prefix is trustworthy until every chain in the packet has validated.
    for (ranges) |range| {
        std.debug.assert(range.start == covered);
        std.debug.assert(range.count > 0 and range.count <= submitted - covered);
        std.debug.assert(range.operation_index < plans.len);
        const plan = &plans[range.operation_index].?.admitted;
        std.debug.assert(range.count == plan.counts[@intFromEnum(family)]);
        _ = try classify_chain(family, reply[range.start..][0..range.count]);
        covered += range.count;
    }
    std.debug.assert(covered == submitted);
    for (ranges) |range| {
        const plan = &plans[range.operation_index].?.admitted;
        const results = reply[range.start..][0..range.count];
        const state = classify_chain(family, results) catch unreachable;
        plan.chains[@intFromEnum(family)] = state;
        const offset = family_offset(plan, family);
        for (results, 0..) |result, index| plan.outcomes[offset + index] = .{ .created = result.status };
        if (family == .create_accounts and state == .rejected) {
            const transfer_offset = family_offset(plan, .create_transfers);
            for (plan.outcomes[transfer_offset..][0..plan.counts[1]]) |*outcome| {
                outcome.* = .{ .skipped = "Transfer was not submitted because account creation was rejected." };
            }
        }
    }
}

fn account_fields_equal(left: *const tigerbeetle.Account, right: *const tigerbeetle.Account) bool {
    inline for (@typeInfo(tigerbeetle.Account).@"struct".fields) |field| {
        if (@field(left, field.name) != @field(right, field.name)) return false;
    }
    return true;
}

fn lookup_position_less(ids: []const u128, left: usize, right: usize) bool {
    return ids[left] < ids[right];
}

fn lookup_account_less(_: void, left: tigerbeetle.Account, right: tigerbeetle.Account) bool {
    return left.id < right.id;
}

fn correlate_lookup_reply(ids: []const u128, positions: []usize, reply: []tigerbeetle.Account) !void {
    std.debug.assert(ids.len > 0 and ids.len <= native_capacity);
    std.debug.assert(positions.len == ids.len);
    if (reply.len > ids.len) return error.InvalidLookupReply;
    for (positions, 0..) |*position, index| position.* = index;
    // Heapsort is nonrecursive with bounded O(n log n) worst-case work.
    std.sort.heap(usize, positions, ids, lookup_position_less);
    std.sort.heap(tigerbeetle.Account, reply, {}, lookup_account_less);
    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < positions.len) {
        const id = ids[positions[input_index]];
        var input_end = input_index + 1;
        while (input_end < positions.len and ids[positions[input_end]] == id) : (input_end += 1) {}
        if (output_index < reply.len and reply[output_index].id < id) return error.InvalidLookupReply;
        if (output_index < reply.len and reply[output_index].id == id) {
            var output_end = output_index + 1;
            while (output_end < reply.len and reply[output_end].id == id) : (output_end += 1) {
                if (!account_fields_equal(&reply[output_index], &reply[output_end])) return error.InvalidLookupReply;
            }
            if (output_end - output_index != input_end - input_index) return error.InvalidLookupReply;
            output_index = output_end;
        }
        input_index = input_end;
    }
    if (output_index != reply.len) return error.InvalidLookupReply;
}

const LookupTarget = struct { operation_index: usize, command_index: usize };
const NativeBuffers = struct {
    accounts: []tigerbeetle.Account,
    account_results: []tigerbeetle.CreateAccountResult,
    transfers: []tigerbeetle.Transfer,
    transfer_results: []tigerbeetle.CreateTransferResult,
    ids: []u128,
    lookup_results: []tigerbeetle.Account,
    positions: []usize,
    targets: []LookupTarget,
    ranges: []ChainRange,

    fn init(allocator: Allocator, capacity: usize, operation_count: usize) !NativeBuffers {
        std.debug.assert(capacity > 0 and capacity <= native_capacity);
        // The caller owns an arena: every allocation completes before the first native effect.
        return .{
            .accounts = try allocator.alloc(tigerbeetle.Account, capacity),
            .account_results = try allocator.alloc(tigerbeetle.CreateAccountResult, capacity),
            .transfers = try allocator.alloc(tigerbeetle.Transfer, capacity),
            .transfer_results = try allocator.alloc(tigerbeetle.CreateTransferResult, capacity),
            .ids = try allocator.alloc(u128, capacity),
            .lookup_results = try allocator.alloc(tigerbeetle.Account, capacity),
            .positions = try allocator.alloc(usize, capacity),
            .targets = try allocator.alloc(LookupTarget, capacity),
            .ranges = try allocator.alloc(ChainRange, @min(operation_count, capacity)),
        };
    }
};

fn submit_packet(
    comptime family: Family,
    plans: []?Planning,
    execution: ExecutionAdapter,
    buffers: *const NativeBuffers,
    count: usize,
    range_count: usize,
) !void {
    std.debug.assert(count > 0 and count <= buffers.ids.len);
    const ranges = buffers.ranges[0..range_count];
    switch (family) {
        .create_accounts => {
            const n = try execution.createAccounts(buffers.accounts[0..count], buffers.account_results[0..count]);
            if (n != count) return error.InvalidCreationReply;
            try apply_creation_reply(family, plans, ranges, buffers.account_results[0..n], count);
        },
        .create_transfers => {
            const n = try execution.createTransfers(buffers.transfers[0..count], buffers.transfer_results[0..count]);
            if (n != count) return error.InvalidCreationReply;
            try apply_creation_reply(family, plans, ranges, buffers.transfer_results[0..n], count);
        },
        .lookup_accounts => {
            const n = try execution.lookupAccounts(buffers.ids[0..count], buffers.lookup_results[0..count]);
            if (n > count) return error.InvalidLookupReply;
            const reply = buffers.lookup_results[0..n];
            try correlate_lookup_reply(buffers.ids[0..count], buffers.positions[0..count], reply);
            var reply_index: usize = 0;
            for (buffers.positions[0..count]) |position| {
                const target = buffers.targets[position];
                const plan = &plans[target.operation_index].?.admitted;
                const id = buffers.ids[position];
                while (reply_index < reply.len and reply[reply_index].id < id) : (reply_index += 1) {}
                plan.outcomes[target.command_index] = if (reply_index < reply.len and reply[reply_index].id == id)
                    .{ .found = reply[reply_index] }
                else
                    .{ .missing = "Account was not found." };
            }
        },
    }
}

fn execute_family(
    comptime family: Family,
    plans: []?Planning,
    execution: ExecutionAdapter,
    buffers: *const NativeBuffers,
) !void {
    var count: usize = 0;
    var range_count: usize = 0;
    for (plans, 0..) |*planning, operation_index| {
        if (planning.* == null or planning.*.? != .admitted) continue;
        const plan = &planning.*.?.admitted;
        if (family == .create_transfers and plan.chains[0] == .rejected) continue;
        const list_count = plan.counts[@intFromEnum(family)];
        if (list_count == 0) continue;
        if (!packet_fits(count, list_count, buffers.ids.len)) {
            try submit_packet(family, plans, execution, buffers, count, range_count);
            count = 0;
            range_count = 0;
        }
        buffers.ranges[range_count] = .{ .operation_index = operation_index, .start = count, .count = list_count };
        range_count += 1;
        const offset = family_offset(plan, family);
        for (plan.commands[offset..][0..list_count], 0..) |*command, index| {
            switch (family) {
                .create_accounts => buffers.accounts[count] = command.native.account,
                .create_transfers => buffers.transfers[count] = command.native.transfer,
                .lookup_accounts => {
                    buffers.ids[count] = command.id;
                    buffers.targets[count] = .{ .operation_index = operation_index, .command_index = offset + index };
                },
            }
            count += 1;
        }
    }
    if (count > 0) try submit_packet(family, plans, execution, buffers, count, range_count);
}

fn execute_phases(allocator: Allocator, plans: []?Planning, execution: ExecutionAdapter) !void {
    var command_count: usize = 0;
    for (plans) |planning| {
        if (planning) |value| if (value == .admitted) {
            command_count = try std.math.add(usize, command_count, value.admitted.commands.len);
        };
    }
    if (command_count == 0) return;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const buffers = try NativeBuffers.init(scratch.allocator(), @min(command_count, native_capacity), plans.len);
    inline for (families) |family| try execute_family(family, plans, execution, &buffers);
}

const success_outcome: CreateOutcome = .accepted;

const FakeExecution = struct {
    accounts: [record_count_max * command_count_max]tigerbeetle.Account = undefined,
    transfers: [record_count_max * command_count_max]tigerbeetle.Transfer = undefined,
    account_outcomes: [record_count_max * command_count_max]CreateOutcome = .{success_outcome} ** (record_count_max * command_count_max),
    transfer_outcomes: [record_count_max * command_count_max]CreateOutcome = .{success_outcome} ** (record_count_max * command_count_max),
    account_errors: [record_count_max * command_count_max]?anyerror = .{null} ** (record_count_max * command_count_max),
    transfer_errors: [record_count_max * command_count_max]?anyerror = .{null} ** (record_count_max * command_count_max),
    account_count: usize = 0,
    transfer_count: usize = 0,
    lookup_results: [record_count_max * command_count_max]tigerbeetle.Account = undefined,
    lookup_count: usize = 0,
    lookup_ids: [record_count_max * command_count_max]u128 = undefined,
    lookup_error: ?anyerror = null,
    account_reply_count: ?usize = null,
    transfer_reply_count: ?usize = null,
    trace: [12]Family = undefined,
    trace_count: usize = 0,

    fn record_call(fake: *FakeExecution, family: Family) void {
        fake.trace[fake.trace_count] = family;
        fake.trace_count += 1;
    }

    fn createAccounts(
        fake: *FakeExecution,
        input: []const tigerbeetle.Account,
        output: []tigerbeetle.CreateAccountResult,
    ) !usize {
        std.debug.assert(output.len >= input.len);
        fake.record_call(.create_accounts);
        std.debug.assert(fake.account_count + input.len <= record_count_max * command_count_max);
        for (input, 0..) |value, position| {
            const index = fake.account_count;
            fake.accounts[index] = value;
            fake.account_count += 1;
            if (fake.account_errors[index]) |err| return err;
            output[position] = std.mem.zeroes(tigerbeetle.CreateAccountResult);
            output[position].status = switch (fake.account_outcomes[index]) {
                .accepted => tigerbeetle.account_created,
                .rejected => |status| status,
            };
        }
        return fake.account_reply_count orelse input.len;
    }
    fn createTransfers(
        fake: *FakeExecution,
        input: []const tigerbeetle.Transfer,
        output: []tigerbeetle.CreateTransferResult,
    ) !usize {
        std.debug.assert(output.len >= input.len);
        fake.record_call(.create_transfers);
        std.debug.assert(fake.transfer_count + input.len <= record_count_max * command_count_max);
        for (input, 0..) |value, position| {
            const index = fake.transfer_count;
            fake.transfers[index] = value;
            fake.transfer_count += 1;
            if (fake.transfer_errors[index]) |err| return err;
            output[position] = std.mem.zeroes(tigerbeetle.CreateTransferResult);
            output[position].status = switch (fake.transfer_outcomes[index]) {
                .accepted => tigerbeetle.transfer_created,
                .rejected => |status| status,
            };
        }
        return fake.transfer_reply_count orelse input.len;
    }
    fn lookupAccounts(
        fake: *FakeExecution,
        input: []const u128,
        output: []tigerbeetle.Account,
    ) !usize {
        std.debug.assert(output.len >= input.len);
        fake.record_call(.lookup_accounts);
        @memcpy(fake.lookup_ids[0..input.len], input);
        if (fake.lookup_error) |err| return err;
        if (fake.lookup_count > input.len) return fake.lookup_count;
        @memcpy(output[0..fake.lookup_count], fake.lookup_results[0..fake.lookup_count]);
        return fake.lookup_count;
    }
};

const FakePublisher = struct {
    message: []const u8 = undefined,
    messages: [record_count_max][]const u8 = undefined,
    routes: [record_count_max]?[]const u8 = undefined,
    execution: ?*const FakeExecution = null,
    send_error: ?anyerror = null,
    account_count_at_send: usize = 0,
    transfer_count_at_send: usize = 0,
    send_count: u8 = 0,

    fn sendCompletion(
        fake: *FakePublisher,
        arena: Allocator,
        result_queue: ?[]const u8,
        body: []const u8,
    ) !void {
        fake.routes[fake.send_count] = result_queue;
        std.debug.assert(fake.send_count < record_count_max);
        std.debug.assert(body.len > 0);
        fake.message = try arena.dupe(u8, body);
        fake.messages[fake.send_count] = fake.message;
        if (fake.execution) |execution| {
            fake.account_count_at_send = execution.account_count;
            fake.transfer_count_at_send = execution.transfer_count;
        }
        fake.send_count += 1;
        if (fake.send_error) |err| return err;
    }
};

fn test_legacy_message(allocator: Allocator, id: u128) ![]u8 {
    const queued: operation.Operation = .{
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
    const message = try test_legacy_message(std.testing.allocator, 2);
    defer std.testing.allocator.free(message);

    const outcome = parseRecord(
        std.testing.failing_allocator,
        "message-0",
        message,
    );
    try std.testing.expect(outcome == .retry);
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

test "tiger_beetle_processor and AWS SDK debug logging are enabled in ReleaseSafe" {
    comptime {
        if (std_options.log_level != .info) @compileError("unexpected default log level");
        if (std_options.log_scope_levels.len != 2) @compileError("unexpected log scope count");
        if (std_options.log_scope_levels[0].scope != .tiger_beetle_processor) {
            @compileError("unexpected tiger_beetle_processor log scope");
        }
        if (std_options.log_scope_levels[0].level != .debug) {
            @compileError("tiger_beetle_processor debug logging is disabled");
        }
        if (std_options.log_scope_levels[1].scope != .aws_sdk) {
            @compileError("unexpected AWS SDK log scope");
        }
        if (std_options.log_scope_levels[1].level != .debug) {
            @compileError("AWS SDK debug logging is disabled");
        }
    }
}

test "execution adapter borrows all three batch outputs and preserves raw results" {
    var fake: FakeExecution = .{};
    const execution = ExecutionAdapter.init(&fake);
    var accounts = [_]tigerbeetle.Account{std.mem.zeroes(tigerbeetle.Account)} ** 2;
    accounts[0].id = 11;
    accounts[1].id = 22;
    var account_output: [2]tigerbeetle.CreateAccountResult = undefined;
    fake.account_outcomes[1] = .{ .rejected = 1234 };
    try std.testing.expectEqual(@as(usize, 2), try execution.createAccounts(
        &accounts,
        &account_output,
    ));
    try std.testing.expectEqual(tigerbeetle.account_created, account_output[0].status);
    try std.testing.expectEqual(@as(u32, 1234), account_output[1].status);
    try std.testing.expectEqual(@as(u128, 22), fake.accounts[1].id);

    var transfers = [_]tigerbeetle.Transfer{std.mem.zeroes(tigerbeetle.Transfer)} ** 2;
    transfers[0].id = 11;
    transfers[1].id = 22;
    var transfer_output: [2]tigerbeetle.CreateTransferResult = undefined;
    try std.testing.expectEqual(@as(usize, 2), try execution.createTransfers(
        &transfers,
        &transfer_output,
    ));
    try std.testing.expectEqual(tigerbeetle.transfer_created, transfer_output[1].status);
    fake.lookup_results[0] = accounts[1];
    fake.lookup_count = 1;
    var lookup_output: [2]tigerbeetle.Account = undefined;
    try std.testing.expectEqual(@as(usize, 1), try execution.lookupAccounts(
        &.{ 11, 22 },
        &lookup_output,
    ));
    try std.testing.expectEqual(@as(u128, 22), lookup_output[0].id);
}

test "preflight lookup plan preserves concrete IDs and repeated aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"lookup_accounts":[{"id":"1","alias":"same"},{"id":"2","alias":"same"}]}
    , .{});
    const result = try plan_body(arena.allocator(), &body);
    try std.testing.expect(result == .admitted);
    try std.testing.expectEqual(@as(u128, 1), result.admitted.commands[0].native.lookup);
    try std.testing.expectEqual(@as(u128, 2), result.admitted.commands[1].native.lookup);
    try std.testing.expectEqualStrings("same", result.admitted.commands[0].alias.?);
    try std.testing.expectEqualStrings("same", result.admitted.commands[1].alias.?);
}

// Uniform admission reserves the largest complete entry for every command.
const completion_buffer_size = processor_message.encoded_size_max;
const result_size_multiplier = 24;
const planned_result_size_max = std.math.mul(usize, operation.body_size_max, result_size_multiplier) catch unreachable;
const command_capacity_raw = (planned_result_size_max - 93) / 1435;
const command_count_max = std.math.floorPowerOfTwo(usize, command_capacity_raw);
comptime {
    std.debug.assert(planned_result_size_max == operation.result_size_max);
    std.debug.assert(record_count_max * command_count_max == 640);
    std.debug.assert(completion_buffer_size > processor_message.body_size_max);
    std.debug.assert(completion_buffer_size <= (1024 * 1024));
    std.debug.assert(command_capacity_raw == 68);
    std.debug.assert(command_count_max == 64);
    std.debug.assert(93 + 1435 * command_count_max <= planned_result_size_max);
}

const Family = enum { create_accounts, create_transfers, lookup_accounts };
const families = [_]Family{ .create_accounts, .create_transfers, .lookup_accounts };
const NativeCommand = union(enum) {
    account: tigerbeetle.Account,
    transfer: tigerbeetle.Transfer,
    lookup: u128,
};
const Command = struct {
    id: u128,
    alias: ?[]const u8,
    native: NativeCommand,
};
const CommandOutcome = union(enum) {
    unsubmitted,
    created: u32,
    found: tigerbeetle.Account,
    missing: []const u8,
    skipped: []const u8,
};
const Plan = struct {
    // Invocation-owned storage; alias slices borrow the unchanged parsed Body.
    commands: []Command,
    outcomes: []CommandOutcome,
    counts: [3]usize,
    chains: [2]ChainState = .{ .unfinished, .unfinished },
};
const Diagnostic = struct {
    family: ?Family = null,
    command_index: usize = 0,
    id: ?u128 = null,
    alias: ?[]const u8 = null,
    message: []const u8,
    field: ?[]const u8 = null,
    member_index: ?u32 = null,
};
const Planning = union(enum) { admitted: Plan, rejected: Diagnostic };

fn decimal(value: std.json.Value, minimum: u128, maximum: u128) !u128 {
    if (value != .string) return error.InvalidDecimal;
    const bytes = value.string;
    if (bytes.len == 0 or bytes.len > 39) return error.InvalidDecimal;
    if (bytes.len > 1 and bytes[0] == '0') return error.InvalidDecimal;
    for (bytes) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidDecimal;
    const number = std.fmt.parseInt(u128, bytes, 10) catch return error.InvalidDecimal;
    if (number < minimum or number > maximum) return error.InvalidDecimal;
    return number;
}

fn small_number(value: std.json.Value, maximum: u32) !u32 {
    // Match the pinned Value serializer, including collapsed 1.0/1e0 and retained -0.
    var bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    switch (value) {
        .integer, .float, .number_string => {},
        else => return error.InvalidNumber,
    }
    std.json.Stringify.value(value, .{}, &writer) catch return error.InvalidNumber;
    const spelling = writer.buffered();
    if (spelling.len == 0) return error.InvalidNumber;
    for (spelling) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidNumber;
    const number = std.fmt.parseInt(u32, spelling, 10) catch return error.InvalidNumber;
    if (number > maximum) return error.InvalidNumber;
    return number;
}

fn valid_alias(value: std.json.Value) ![]const u8 {
    if (value != .string) return error.InvalidAlias;
    if (value.string.len == 0 or value.string.len > 64) return error.InvalidAlias;
    if (!std.unicode.utf8ValidateSlice(value.string)) return error.InvalidAlias;
    return value.string;
}

fn known_field(family: ?Family, name: []const u8) bool {
    const names: []const []const u8 = if (family) |kind| switch (kind) {
        .create_accounts => &.{ "id", "alias", "flags", "ledger", "code" },
        .create_transfers => &.{ "id", "alias", "flags", "pending_id", "debit_account_id", "credit_account_id", "amount", "ledger", "code", "timeout" },
        .lookup_accounts => &.{ "id", "alias" },
    } else &.{ "create_accounts", "create_transfers", "lookup_accounts" };
    for (names) |known| if (std.mem.eql(u8, known, name)) return true;
    return false;
}

fn unknown_member(object: *const std.json.ObjectMap, family: ?Family) ?u32 {
    for (object.keys(), 0..) |name, index| {
        if (!known_field(family, name)) return @intCast(index);
    }
    return null;
}

fn field_error(field: []const u8, message: []const u8) Diagnostic {
    return .{ .field = field, .message = message };
}

const WireField = enum {
    id,
    alias,
    pending_id,
    debit_account_id,
    credit_account_id,
    amount,
    ledger,
    code,
    timeout,
};
const ParsedFields = struct {
    id: u128 = 0,
    alias: ?[]const u8 = null,
    pending_id: u128 = 0,
    debit_account_id: u128 = 0,
    credit_account_id: u128 = 0,
    amount: u128 = 0,
    ledger: u128 = 0,
    code: u128 = 0,
    timeout: u128 = 0,
    flags: u16 = 0,
};

fn validate_command(family: Family, value: *const std.json.Value, command: *Command) ?Diagnostic {
    if (value.* != .object) return .{ .message = "Expected a command object." };
    const object = &value.object;
    if (unknown_member(object, family)) |index| {
        return .{ .member_index = index, .message = "Unknown field." };
    }
    var fields: ParsedFields = .{};
    if (family != .lookup_accounts) {
        const raw = object.get("flags") orelse return field_error("flags", "Required field is missing.");
        fields.flags = @intCast(small_number(raw, 65535) catch
            return field_error("flags", "Expected an unsigned u16 integer."));
        const account_bounds = tigerbeetle.account_debits_must_not_exceed_credits |
            tigerbeetle.account_credits_must_not_exceed_debits;
        const account_allowed = account_bounds | tigerbeetle.account_history;
        const allowed = fields.flags == 0 or (switch (family) {
            .create_accounts => fields.flags & ~account_allowed == 0 and
                fields.flags & account_bounds != account_bounds,
            .create_transfers => fields.flags == tigerbeetle.transfer_pending or
                fields.flags == tigerbeetle.transfer_post_pending_transfer or
                fields.flags == tigerbeetle.transfer_void_pending_transfer,
            .lookup_accounts => unreachable,
        });
        if (!allowed) return field_error("flags", "Unsupported flags.");
    }
    const resolution = family == .create_transfers and
        (fields.flags == tigerbeetle.transfer_post_pending_transfer or
            fields.flags == tigerbeetle.transfer_void_pending_transfer);
    const pending = family == .create_transfers and fields.flags == tigerbeetle.transfer_pending;
    // Enum order is the public diagnostic precedence, independent of JSON member order.
    inline for (@typeInfo(WireField).@"enum".fields) |field_info| {
        const field: WireField = @enumFromInt(field_info.value);
        const name = field_info.name;
        if (known_field(family, name)) {
            if (validate_field(field, object.get(name), resolution, pending, &fields)) |problem| {
                return problem;
            }
        }
    }
    construct_command(family, &fields, command);
    return null;
}

fn validate_field(
    comptime field: WireField,
    raw: ?std.json.Value,
    resolution: bool,
    pending: bool,
    fields: *ParsedFields,
) ?Diagnostic {
    const name = @tagName(field);
    const reference = field == .debit_account_id or field == .credit_account_id;
    const forbidden = (field == .pending_id and !resolution) or (field == .timeout and !pending);
    if (forbidden) {
        if (raw != null) return field_error(name, "Field is forbidden in this transfer mode.");
        return null;
    }
    const required = field == .id or field == .amount or (field == .pending_id and resolution) or
        ((reference or field == .ledger or field == .code) and !resolution) or
        (field == .timeout and pending);
    const present = raw orelse {
        if (required) return field_error(name, "Required field is missing.");
        return null;
    };
    if (field == .alias) {
        fields.alias = valid_alias(present) catch
            return field_error(name, "Expected 1 to 64 bytes of UTF-8 alias text.");
    } else if (field == .id or field == .pending_id or reference or field == .amount) {
        const minimum: u128 = if (field == .amount or (resolution and reference)) 0 else 1;
        const maximum = std.math.maxInt(u128) - @as(u128, if (field == .amount) 0 else 1);
        @field(fields, name) = decimal(present, minimum, maximum) catch
            return field_error(name, "Expected a canonical decimal string in the allowed range.");
    } else {
        const maximum: u32 = if (field == .code) 65535 else std.math.maxInt(u32);
        @field(fields, name) = small_number(present, maximum) catch
            return field_error(name, "Expected an unsigned integer in the allowed range.");
        if (!resolution and @field(fields, name) == 0) {
            return field_error(name, "Expected a positive integer.");
        }
    }
    return null;
}

fn construct_command(family: Family, fields: *const ParsedFields, command: *Command) void {
    std.debug.assert(fields.id > 0);
    std.debug.assert(fields.id < std.math.maxInt(u128));
    command.* = .{ .id = fields.id, .alias = fields.alias, .native = undefined };
    switch (family) {
        .lookup_accounts => command.native = .{ .lookup = fields.id },
        .create_accounts => {
            var account = std.mem.zeroes(tigerbeetle.Account);
            account.id = fields.id;
            account.ledger = @intCast(fields.ledger);
            account.code = @intCast(fields.code);
            account.flags = fields.flags;
            command.native = .{ .account = account };
        },
        .create_transfers => {
            var transfer = std.mem.zeroes(tigerbeetle.Transfer);
            transfer.id = fields.id;
            transfer.pending_id = fields.pending_id;
            transfer.debit_account_id = fields.debit_account_id;
            transfer.credit_account_id = fields.credit_account_id;
            transfer.amount = fields.amount;
            transfer.ledger = @intCast(fields.ledger);
            transfer.code = @intCast(fields.code);
            transfer.timeout = @intCast(fields.timeout);
            transfer.flags = fields.flags;
            command.native = .{ .transfer = transfer };
        },
    }
}

fn command_relationship(command: *const Command) ?Diagnostic {
    if (command.native != .transfer) return null;
    const transfer = &command.native.transfer;
    const resolution = transfer.flags == tigerbeetle.transfer_post_pending_transfer or
        transfer.flags == tigerbeetle.transfer_void_pending_transfer;
    if (resolution and transfer.id == transfer.pending_id) {
        return field_error("pending_id", "Transfer ID and pending transfer ID must differ.");
    }
    if (transfer.debit_account_id != 0 and transfer.debit_account_id == transfer.credit_account_id) {
        return field_error("credit_account_id", "Debit and credit account IDs must differ.");
    }
    return null;
}

fn locate_diagnostic(diagnostic: Diagnostic, family: Family, index: usize, value: *const std.json.Value) Diagnostic {
    var located = diagnostic;
    located.family = family;
    located.command_index = index;
    // Projection is independent of the first validation error, including flags/unknown members.
    if (value.* == .object) {
        if (value.object.get("id")) |id| located.id = decimal(id, 1, std.math.maxInt(u128) - 1) catch null;
        if (value.object.get("alias")) |alias| located.alias = valid_alias(alias) catch null;
    }
    return located;
}

const ValidationId = struct {
    id: u128,
    command_index: usize,
};

// Even the smallest wire-valid command, {"id":"1"}, occupies ten Body bytes.
// Processor Message decoding enforces body_size_max before production validation.
const validation_id_count_max = processor_message.body_size_max / 10;

fn validation_id_less(_: void, left: ValidationId, right: ValidationId) bool {
    if (left.id == right.id) return left.command_index < right.command_index;
    return left.id < right.id;
}

fn first_duplicate_id(ids: []ValidationId) ?usize {
    std.debug.assert(ids.len <= validation_id_count_max);
    if (ids.len < 2) return null;
    std.sort.heap(ValidationId, ids, {}, validation_id_less);
    var first: ?usize = null;
    for (ids[1..], ids[0 .. ids.len - 1]) |current, previous| {
        std.debug.assert(current.command_index < ids.len);
        if (current.id != previous.id) continue;
        std.debug.assert(previous.command_index < current.command_index);
        if (first == null or current.command_index < first.?) first = current.command_index;
    }
    return first;
}

fn validate_body(body: *const std.json.Value, counts: *[3]usize) ?Diagnostic {
    counts.* = .{ 0, 0, 0 };
    if (body.* != .object) return .{ .message = "Expected a Body object." };
    if (unknown_member(&body.object, null)) |index| return .{ .member_index = index, .message = "Unknown field." };
    var ids: [validation_id_count_max]ValidationId = undefined;
    for (families, 0..) |family, family_index| {
        const list = body.object.get(@tagName(family)) orelse continue;
        if (list != .array) return field_error(@tagName(family), "Expected an array of commands.");
        counts[family_index] = list.array.items.len;
        var id_count: usize = 0;
        var first_problem: ?Diagnostic = null;
        for (list.array.items, 0..) |*value, index| {
            var command: Command = undefined;
            var diagnostic = validate_command(family, value, &command);
            if (diagnostic == null) {
                std.debug.assert(id_count == index);
                std.debug.assert(id_count < ids.len);
                ids[id_count] = .{ .id = command.id, .command_index = index };
                id_count += 1;
                diagnostic = command_relationship(&command);
            }
            if (diagnostic) |problem| {
                first_problem = locate_diagnostic(problem, family, index, value);
                break;
            }
        }
        // Excluding field failures but including relationship failures preserves precedence.
        // Only the validated prefix is sorted; the Body and execution order remain untouched.
        if (first_duplicate_id(ids[0..id_count])) |index| {
            std.debug.assert(index < list.array.items.len);
            const problem = field_error("id", "This ID repeats an earlier command's ID in the same list.");
            return locate_diagnostic(problem, family, index, &list.array.items[index]);
        }
        if (first_problem) |problem| return problem;
    }
    const count = std.math.add(usize, counts[0], counts[1]) catch unreachable;
    const total = std.math.add(usize, count, counts[2]) catch unreachable;
    if (total == 0) return .{ .message = "At least one command is required." };
    if (total > command_count_max) return .{ .message = "The Body exceeds the 64-command complete Result capacity." };
    return null;
}

fn plan_body(allocator: Allocator, body: *const std.json.Value) !Planning {
    var counts: [3]usize = undefined;
    if (validate_body(body, &counts)) |diagnostic| return .{ .rejected = diagnostic };
    const total = counts[0] + counts[1] + counts[2];
    std.debug.assert(total > 0);
    std.debug.assert(total <= command_count_max);
    const commands = try allocator.alloc(Command, total);
    errdefer allocator.free(commands);
    const outcomes = try allocator.alloc(CommandOutcome, total);
    errdefer allocator.free(outcomes);
    @memset(outcomes, .unsubmitted);
    var offset: usize = 0;
    for (families, 0..) |family, family_index| {
        if (counts[family_index] == 0) continue;
        const list = body.object.get(@tagName(family)).?.array.items;
        for (list, 0..) |*value, index| {
            const diagnostic = validate_command(family, value, &commands[offset]);
            std.debug.assert(diagnostic == null);
            const linked = index + 1 < list.len;
            switch (commands[offset].native) {
                .account => |*account| if (linked) {
                    account.flags |= tigerbeetle.account_linked;
                },
                .transfer => |*transfer| if (linked) {
                    transfer.flags |= tigerbeetle.transfer_linked;
                },
                .lookup => {},
            }
            offset += 1;
        }
    }
    std.debug.assert(offset == total);
    return .{ .admitted = .{ .commands = commands, .outcomes = outcomes, .counts = counts } };
}

test "valid message invalid Body publishes diagnostics and admits neighbors without demo effects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const invalid = try test_body_message(allocator, 1, "{\"create_accounts\":[{\"id\":\"1\",\"flags\":0,\"ledger\":1,\"code\":1}],\"lookup_accounts\":[null]}");
    const valid = try test_body_message(allocator, 2, "{\"lookup_accounts\":[{\"id\":\"1\"}]}");
    const event = try testEvent(allocator, &.{ invalid, valid, "{\"id\":\"broken\"}" });
    var execution: FakeExecution = .{};
    var publisher: FakePublisher = .{};
    const response = try handleInvocation(allocator, event, ExecutionAdapter.init(&execution), CompletionPublisher.init(&publisher));
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
    try std.testing.expectEqual(@as(u8, 0), execution.account_count);
    try std.testing.expectEqual(@as(u8, 0), execution.transfer_count);
    try std.testing.expectEqual(@as(usize, 0), execution.lookup_count);
    try std.testing.expectEqual(@as(u8, 2), publisher.send_count);
}

fn test_body_message(allocator: Allocator, id: u128, body_json: []const u8) ![]const u8 {
    const body = try std.json.parseFromSliceLeaky(std.json.Value, allocator, body_json, .{ .duplicate_field_behavior = .@"error" });
    return processor_message.encode(allocator, &.{ .operation_id = id, .body = body });
}

fn test_plan(allocator: Allocator, json: []const u8) !Planning {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{
        .duplicate_field_behavior = .@"error",
        .allocate = .alloc_always,
    });
    return plan_body(allocator, &value);
}

test "wire grammar and diagnostic precedence table" {
    const Case = struct { body: []const u8, family: ?Family = null, index: usize = 0, field: ?[]const u8 = null, member: ?u32 = null };
    const cases = [_]Case{
        .{ .body = "null" },                                                                                                                                                     .{ .body = "true" },                                                                                                           .{ .body = "[]" },                                                                                                           .{ .body = "{}" },
        .{ .body = "{\"create_accounts\":[],\"lookup_accounts\":[]}" },                                                                                                          .{ .body = "{\"lookup_accounts\":null}", .field = "lookup_accounts" },                                                         .{ .body = "{\"lookup_accounts\":{},\"bad\":0}", .member = 1 },                                                              .{ .body = "{\"Lookup_accounts\":[]}", .member = 0 },
        .{ .body = "{\"lookup_accounts\":[\"1\"]}", .family = .lookup_accounts },                                                                                                .{ .body = "{\"lookup_accounts\":[null]}", .family = .lookup_accounts },                                                       .{ .body = "{\"lookup_accounts\":[{}]}", .family = .lookup_accounts, .field = "id" },                                        .{ .body = "{\"lookup_accounts\":[{\"id\":\"01\",\"alias\":\"main\",\"bad\":0}]}", .family = .lookup_accounts, .member = 2 },
        .{ .body = "{\"create_accounts\":[{\"id\":null}]}", .family = .create_accounts, .field = "flags" },                                                                      .{ .body = "{\"create_accounts\":[{\"flags\":0,\"id\":null}]}", .family = .create_accounts, .field = "id" },                   .{ .body = "{\"lookup_accounts\":[{\"id\":\"1\"},{\"id\":\"1\"}]}", .family = .lookup_accounts, .index = 1, .field = "id" }, .{ .body = "{\"create_transfers\":[{\"id\":\"1\",\"flags\":4,\"pending_id\":\"1\",\"amount\":\"0\"}]}", .family = .create_transfers, .field = "pending_id" },
        .{ .body = "{\"create_transfers\":[{\"id\":\"1\",\"flags\":4,\"pending_id\":\"2\",\"amount\":\"0\",\"timeout\":0}]}", .family = .create_transfers, .field = "timeout" }, .{ .body = "{\"lookup_accounts\":false,\"create_accounts\":[{\"id\":\"1\"}]}", .family = .create_accounts, .field = "flags" },
    };
    for (cases) |case| {
        errdefer std.debug.print("wire case: {s}\n", .{case.body});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const result = try test_plan(arena.allocator(), case.body);
        try std.testing.expect(result == .rejected);
        const diagnostic = result.rejected;
        try std.testing.expectEqual(case.family, diagnostic.family);
        try std.testing.expectEqual(case.index, diagnostic.command_index);
        try std.testing.expectEqual(case.member, diagnostic.member_index);
        if (case.field) |field| try std.testing.expectEqualStrings(field, diagnostic.field.?) else try std.testing.expect(diagnostic.field == null);
    }
}

test "canonical decimal IDs amounts and reference boundaries" {
    const invalid = [_][]const u8{ "0", "340282366920938463463374607431768211455", "340282366920938463463374607431768211456", "", "01", "+1", "-1", " 1", "1 ", "1.0", "1e0", "0x1", "١" };
    for (invalid) |id| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const body = try std.fmt.allocPrint(arena.allocator(), "{{\"lookup_accounts\":[{{\"id\":\"{s}\"}}]}}", .{id});
        const result = try test_plan(arena.allocator(), body);
        try std.testing.expect(result == .rejected);
        try std.testing.expectEqualStrings("id", result.rejected.field.?);
    }
    const valid = [_][]const u8{ "1", "340282366920938463463374607431768211454", "\\u0031" };
    for (valid) |id| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const body = try std.fmt.allocPrint(arena.allocator(), "{{\"lookup_accounts\":[{{\"id\":\"{s}\"}}]}}", .{id});
        try std.testing.expect((try test_plan(arena.allocator(), body)) == .admitted);
    }
    const amounts = [_][]const u8{ "0", "1", "340282366920938463463374607431768211455" };
    for (amounts) |amount| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const body = try std.fmt.allocPrint(arena.allocator(), "{{\"create_transfers\":[{{\"id\":\"1\",\"pending_id\":\"2\",\"flags\":4,\"amount\":\"{s}\"}}]}}", .{amount});
        const result = try test_plan(arena.allocator(), body);
        try std.testing.expectEqual(try std.fmt.parseInt(u128, amount, 10), result.admitted.commands[0].native.transfer.amount);
        try std.testing.expectEqual(@as(u128, 0), result.admitted.commands[0].native.transfer.debit_account_id);
    }
}

test "normalized small numbers range and negative zero" {
    const Case = struct { number: []const u8, accepted: bool };
    const cases = [_]Case{
        .{ .number = "1", .accepted = true },      .{ .number = "1.0", .accepted = true },
        .{ .number = "1e0", .accepted = true },    .{ .number = "4294967295", .accepted = true },
        .{ .number = "0", .accepted = false },     .{ .number = "-0", .accepted = false },
        .{ .number = "-0.0", .accepted = false },  .{ .number = "-1", .accepted = false },
        .{ .number = "1.5", .accepted = false },   .{ .number = "4294967296", .accepted = false },
        .{ .number = "\"1\"", .accepted = false }, .{ .number = "null", .accepted = false },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const json = try std.fmt.allocPrint(arena.allocator(), "{{\"create_accounts\":[{{\"id\":\"1\",\"flags\":0,\"ledger\":{s},\"code\":65535}}]}}", .{case.number});
        const queued = try test_body_message(arena.allocator(), 1, json);
        const parsed = parseRecord(arena.allocator(), "number", queued);
        try std.testing.expect(parsed == .valid);
        const result = try plan_body(arena.allocator(), &parsed.valid.body);
        errdefer std.debug.print("small number: {s}\n", .{case.number});
        try std.testing.expectEqual(case.accepted, result == .admitted);
    }
}

test "native construction preserves namespaces chain bits post defaults and original hash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"lookup_accounts":[{"id":"1","alias":"x"}],"create_transfers":[{"id":"1","flags":2,"debit_account_id":"1","credit_account_id":"2","amount":"0","ledger":99,"code":1,"timeout":4294967295},{"id":"3","flags":4,"pending_id":"1","amount":"340282366920938463463374607431768211455"}],"create_accounts":[{"id":"1","alias":"x","flags":2,"ledger":1,"code":1},{"id":"2","flags":0,"ledger":2,"code":1}]}
    , .{});
    const before = try operation.operationHash("tenant", "test", &body);
    const plan = (try plan_body(arena.allocator(), &body)).admitted;
    try std.testing.expectEqualSlices(usize, &.{ 2, 2, 1 }, &plan.counts);
    var expected_account = std.mem.zeroes(tigerbeetle.Account);
    expected_account.id = 1;
    expected_account.flags = 3;
    expected_account.ledger = 1;
    expected_account.code = 1;
    try std.testing.expectEqualDeep(expected_account, plan.commands[0].native.account);
    try std.testing.expectEqual(@as(u16, 0), plan.commands[1].native.account.flags);
    var expected_transfer = std.mem.zeroes(tigerbeetle.Transfer);
    expected_transfer.id = 1;
    expected_transfer.flags = 3;
    expected_transfer.debit_account_id = 1;
    expected_transfer.credit_account_id = 2;
    expected_transfer.ledger = 99;
    expected_transfer.code = 1;
    expected_transfer.timeout = 4294967295;
    try std.testing.expectEqualDeep(expected_transfer, plan.commands[2].native.transfer);
    expected_transfer = std.mem.zeroes(tigerbeetle.Transfer);
    expected_transfer.id = 3;
    expected_transfer.pending_id = 1;
    expected_transfer.flags = 4;
    expected_transfer.amount = std.math.maxInt(u128);
    try std.testing.expectEqualDeep(expected_transfer, plan.commands[3].native.transfer);
    try std.testing.expectEqual(@as(u128, 1), plan.commands[4].native.lookup);
    const after = try operation.operationHash("tenant", "test", &body);
    try std.testing.expectEqualSlices(u8, &before, &after);
    for (plan.outcomes) |outcome| try std.testing.expect(outcome == .unsubmitted);
}

test "void chain construction and lost-reply replay retain original native requests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body =
        \\{"create_transfers":[{"id":"11","flags":2,"debit_account_id":"1","credit_account_id":"2","amount":"9","ledger":1,"code":1,"timeout":60},{"id":"12","flags":8,"pending_id":"11","amount":"0"}]}
    ;
    const first = (try test_plan(arena.allocator(), body)).admitted;
    const replay = (try test_plan(arena.allocator(), body)).admitted;
    try std.testing.expectEqualDeep(first.commands[0].native.transfer, replay.commands[0].native.transfer);
    try std.testing.expectEqualDeep(first.commands[1].native.transfer, replay.commands[1].native.transfer);
    try std.testing.expectEqual(@as(u16, tigerbeetle.transfer_pending | tigerbeetle.transfer_linked), first.commands[0].native.transfer.flags);
    try std.testing.expectEqual(@as(u16, tigerbeetle.transfer_void_pending_transfer), first.commands[1].native.transfer.flags);
    try std.testing.expectEqual(@as(u128, 0), first.commands[1].native.transfer.amount);
    const Result = tigerbeetle.CreateTransferResult;
    var statuses = [_]Result{std.mem.zeroes(Result)} ** 2;
    statuses[0].status = tigerbeetle.transfer_exists;
    statuses[1].status = tigerbeetle.transfer_linked_event_failed;
    try std.testing.expectEqual(ChainState.accepted, try classify_chain(.create_transfers, &statuses));
    statuses[0].status = tigerbeetle.transfer_linked_event_failed;
    statuses[1].status = tigerbeetle.transfer_exists;
    try std.testing.expectEqual(ChainState.rejected, try classify_chain(.create_transfers, &statuses));
    statuses[1].status = 123456;
    try std.testing.expectEqual(ChainState.rejected, try classify_chain(.create_transfers, &statuses));
}

test "aliases preserve escaped UTF-8 bytes and reject invalid decoded lengths" {
    const aliases = [_][]const u8{ "a", " " ** 64, "é" ** 32, "\\u0000", "é", "\\u0061" };
    const decoded = [_][]const u8{ "a", " " ** 64, "é" ** 32, "\x00", "é", "a" };
    for (aliases, decoded) |alias, expected| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const json = try std.fmt.allocPrint(arena.allocator(), "{{\"lookup_accounts\":[{{\"id\":\"1\",\"alias\":\"{s}\"}}]}}", .{alias});
        const plan = (try test_plan(arena.allocator(), json)).admitted;
        try std.testing.expectEqualStrings(expected, plan.commands[0].alias.?);
    }
    const invalid = [_][]const u8{ "", "a" ** 65, "é" ** 32 ++ "a" };
    for (invalid) |alias| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const json = try std.fmt.allocPrint(arena.allocator(), "{{\"lookup_accounts\":[{{\"id\":\"1\",\"alias\":\"{s}\"}}]}}", .{alias});
        const result = try test_plan(arena.allocator(), json);
        try std.testing.expectEqualStrings("alias", result.rejected.field.?);
        try std.testing.expect(result.rejected.alias == null);
    }
}

fn lookup_body(allocator: Allocator, count: usize, bad_suffix: bool) ![]u8 {
    std.debug.assert(count <= 100);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("{\"lookup_accounts\":[");
    for (0..count) |index| {
        if (index != 0) try writer.writer.writeByte(',');
        try writer.writer.print("{{\"id\":\"{d}\"}}", .{index + 1});
    }
    if (bad_suffix) try writer.writer.writeAll(",{\"id\":\"0\"}");
    try writer.writer.writeAll("]}");
    return writer.toOwnedSlice();
}

test "64 commands admitted 65 rejected and later wire error wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]usize{ 64, 65 }) |count| {
        const body = try lookup_body(arena.allocator(), count, false);
        const result = try test_plan(arena.allocator(), body);
        try std.testing.expectEqual(count == 64, result == .admitted);
        if (result == .rejected) try std.testing.expect(result.rejected.family == null);
    }
    const body = try lookup_body(arena.allocator(), 65, true);
    const result = try test_plan(arena.allocator(), body);
    try std.testing.expectEqual(@as(usize, 65), result.rejected.command_index);
    try std.testing.expectEqualStrings("id", result.rejected.field.?);
}

test "diagnostic prefix and independent projection have exact Result shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try test_plan(arena.allocator(), "{\"lookup_accounts\":[{\"id\":\"1\"},{\"id\":\"01\",\"alias\":\"main\",\"unexpected\":true},{\"id\":\"3\"}]}");
    const buffer = try arena.allocator().create([operation.result_size_max]u8);
    const encoded = write_diagnostic(buffer, &result.rejected);
    var writer: std.Io.Writer.Allocating = .init(arena.allocator());
    try writer.writer.writeAll(encoded);
    try std.testing.expectEqualStrings(
        \\{"create_accounts":[],"create_transfers":[],"lookup_accounts":[null,{"error_code":null,"alias":"main","message":"Unknown field.","member_index":2}]}
    , writer.written());
}

test "field mode matrix rejects omissions prohibited fields and unsupported flags" {
    const bodies = [_][]const u8{
        "{\"id\":\"1\",\"flags\":0,\"ledger\":1,\"code\":1}",
        "{\"id\":\"1\",\"flags\":0,\"debit_account_id\":\"2\",\"credit_account_id\":\"3\",\"amount\":\"0\",\"ledger\":1,\"code\":1}",
        "{\"id\":\"1\",\"flags\":2,\"debit_account_id\":\"2\",\"credit_account_id\":\"3\",\"amount\":\"0\",\"ledger\":1,\"code\":1,\"timeout\":1}",
        "{\"id\":\"1\",\"flags\":4,\"pending_id\":\"2\",\"amount\":\"0\"}",
        "{\"id\":\"1\",\"flags\":8,\"pending_id\":\"2\",\"amount\":\"0\"}",
    };
    for (bodies, 0..) |json, mode| {
        const family: Family = if (mode == 0) .create_accounts else .create_transfers;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const original = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});
        // Every member in these minimal mode fixtures is mandatory.
        for (original.object.keys()) |name| {
            var value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});
            _ = value.object.orderedRemove(name);
            var command: Command = undefined;
            const diagnostic = validate_command(family, &value, &command).?;
            try std.testing.expectEqualStrings(name, diagnostic.field.?);
        }
        const prohibited = [_][]const u8{ "user_data_128", "user_data_64", "user_data_32", "timestamp", "reserved", "debits_pending", "debits_posted", "credits_pending", "credits_posted", "linked", "mode", "unexpected" };
        for (prohibited) |name| {
            var value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});
            try value.object.put(allocator, name, .{ .integer = 0 });
            var command: Command = undefined;
            const diagnostic = validate_command(family, &value, &command).?;
            try std.testing.expectEqual(@as(?u32, @intCast(original.object.count())), diagnostic.member_index);
        }
        const invalid_flags: []const u32 = if (family == .create_accounts)
            &.{ 1, 3, 5, 6, 7, 9, 11, 13, 14, 15, 16, 32, 64, 128, 256, 65535, 65536 }
        else
            &.{ 1, 3, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15, 16, 32, 64, 128, 256, 65535, 65536 };
        for (invalid_flags) |flags| {
            var value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});
            try value.object.put(allocator, "flags", .{ .integer = flags });
            var command: Command = undefined;
            const diagnostic = validate_command(family, &value, &command).?;
            try std.testing.expectEqualStrings("flags", diagnostic.field.?);
        }
        // A valid required value becoming null always rejects at that same field.
        for (original.object.keys()) |name| {
            var value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});
            try value.object.put(allocator, name, .null);
            var command: Command = undefined;
            try std.testing.expectEqualStrings(name, validate_command(family, &value, &command).?.field.?);
        }
        if (mode == 1 or mode == 2) {
            var value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});
            try value.object.put(allocator, "pending_id", .{ .string = "0" });
            var command: Command = undefined;
            try std.testing.expectEqualStrings("pending_id", validate_command(family, &value, &command).?.field.?);
        }
        if (mode == 1 or mode == 3 or mode == 4) {
            var value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});
            try value.object.put(allocator, "timeout", .{ .integer = 0 });
            var command: Command = undefined;
            try std.testing.expectEqualStrings("timeout", validate_command(family, &value, &command).?.field.?);
        }
    }
}

test "account flag combinations and transfer modes are exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_]u16{ 0, 2, 4, 8, 10, 12 }) |flags| {
        const json = try std.fmt.allocPrint(
            allocator,
            "{{\"create_accounts\":[{{\"id\":\"1\",\"flags\":{d},\"ledger\":1,\"code\":1}}]}}",
            .{flags},
        );
        const plan = (try test_plan(allocator, json)).admitted;
        try std.testing.expectEqual(flags, plan.commands[0].native.account.flags);
    }
    for ([_]u16{ 0, 2, 4, 8 }) |flags| {
        const json = if (flags == 4 or flags == 8)
            try std.fmt.allocPrint(
                allocator,
                "{{\"create_transfers\":[{{\"id\":\"1\",\"pending_id\":\"2\",\"flags\":{d},\"amount\":\"0\"}}]}}",
                .{flags},
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "{{\"create_transfers\":[{{\"id\":\"1\",\"flags\":{d},\"debit_account_id\":\"2\",\"credit_account_id\":\"3\",\"amount\":\"0\",\"ledger\":1,\"code\":1{s}}}]}}",
                .{ flags, if (flags == 2) ",\"timeout\":1" else "" },
            );
        const plan = (try test_plan(allocator, json)).admitted;
        try std.testing.expectEqual(flags, plan.commands[0].native.transfer.flags);
    }
}

test "void fields inherit and direct relationships retain diagnostic precedence" {
    const cases = [_]struct { command: []const u8, field: ?[]const u8 }{
        .{ .command = "{\"id\":\"1\",\"flags\":8,\"pending_id\":\"2\",\"amount\":\"0\"}", .field = null },
        .{ .command = "{\"id\":\"1\",\"flags\":8,\"pending_id\":\"2\",\"amount\":\"42\",\"debit_account_id\":\"0\",\"credit_account_id\":\"0\",\"ledger\":0,\"code\":0}", .field = null },
        .{ .command = "{\"id\":\"1\",\"flags\":8,\"pending_id\":\"1\",\"amount\":\"0\"}", .field = "pending_id" },
        .{ .command = "{\"id\":\"1\",\"flags\":8,\"pending_id\":\"2\",\"amount\":\"0\",\"debit_account_id\":\"3\",\"credit_account_id\":\"3\"}", .field = "credit_account_id" },
        .{ .command = "{\"id\":\"1\",\"flags\":8,\"pending_id\":\"2\",\"amount\":\"0\",\"timeout\":0}", .field = "timeout" },
        .{ .command = "{\"id\":\"1\",\"flags\":8,\"pending_id\":\"2\"}", .field = "amount" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const json = try std.fmt.allocPrint(arena.allocator(), "{{\"create_transfers\":[{s}]}}", .{case.command});
        const plan = try test_plan(arena.allocator(), json);
        if (case.field) |field| {
            try std.testing.expectEqualStrings(field, plan.rejected.field.?);
        } else {
            try std.testing.expectEqual(@as(u16, 8), plan.admitted.commands[0].native.transfer.flags);
        }
    }
}

test "duplicates precede direct relationships and post references retain zero inheritance" {
    const cases = [_]struct { body: []const u8, field: ?[]const u8 }{
        .{ .body = "{\"create_accounts\":[{\"id\":\"1\",\"flags\":0,\"ledger\":1,\"code\":1},{\"id\":\"1\",\"flags\":0,\"ledger\":1,\"code\":1}]}", .field = "id" },
        .{ .body = "{\"create_transfers\":[{\"id\":\"1\",\"flags\":4,\"pending_id\":\"2\",\"amount\":\"0\"},{\"id\":\"1\",\"flags\":4,\"pending_id\":\"1\",\"amount\":\"0\"}]}", .field = "id" },
        .{ .body = "{\"create_transfers\":[{\"id\":\"1\",\"flags\":4,\"pending_id\":\"2\",\"amount\":\"0\",\"debit_account_id\":\"3\",\"credit_account_id\":\"3\"}]}", .field = "credit_account_id" },
        .{ .body = "{\"create_transfers\":[{\"id\":\"1\",\"flags\":4,\"pending_id\":\"2\",\"amount\":\"0\",\"debit_account_id\":\"0\",\"credit_account_id\":\"0\",\"ledger\":0,\"code\":0}]}", .field = null },
        .{ .body = "{\"create_transfers\":[{\"id\":\"1\",\"flags\":4,\"pending_id\":\"2\",\"amount\":\"0\",\"debit_account_id\":\"3\"}]}", .field = null },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const result = try test_plan(arena.allocator(), case.body);
        if (case.field) |field| try std.testing.expectEqualStrings(field, result.rejected.field.?) else try std.testing.expect(result == .admitted);
    }
}

test "sorted duplicate validation preserves original diagnostic precedence" {
    const cases = [_]struct { body: []const u8, index: usize, field: []const u8 }{
        .{ .body =
        \\{"lookup_accounts":[{"id":"9"},{"id":"9"},{"id":"1"},{"id":"1"},{"id":"9"}]}
        , .index = 1, .field = "id" },
        .{ .body =
        \\{"lookup_accounts":[{"id":"340282366920938463463374607431768211454"},{"id":"1"},{"id":"340282366920938463463374607431768211454"}]}
        , .index = 2, .field = "id" },
        .{ .body =
        \\{"lookup_accounts":[{"id":"1"},{"id":"1","alias":null}]}
        , .index = 1, .field = "alias" },
        .{ .body =
        \\{"lookup_accounts":[{"id":"1"},{"id":"1"},{"id":"2","alias":null}]}
        , .index = 1, .field = "id" },
        .{ .body =
        \\{"lookup_accounts":[{"id":"1","alias":null},{"id":"2"},{"id":"2"}]}
        , .index = 0, .field = "alias" },
        .{ .body =
        \\{"create_transfers":[{"id":"1","flags":4,"pending_id":"1","amount":"0"},{"id":"1","flags":4,"pending_id":"2","amount":"0"}]}
        , .index = 0, .field = "pending_id" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const result = try test_plan(arena.allocator(), case.body);
        try std.testing.expect(result == .rejected);
        try std.testing.expectEqual(case.index, result.rejected.command_index);
        try std.testing.expectEqualStrings(case.field, result.rejected.field.?);
    }
}

test "stack duplicate validation covers near-limit Bodies beyond admission" {
    for (0..3) |scenario| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var body: std.Io.Writer.Allocating = .init(arena.allocator());
        try body.writer.writeAll("{\"lookup_accounts\":[");
        // Three hundred descending IDs exercise sorting and approach the 4 KiB boundary.
        for (0..300) |index| {
            if (index != 0) try body.writer.writeByte(',');
            const id: usize = if (scenario == 1 and index == 299) 300 else 300 - index;
            try body.writer.print("{{\"id\":\"{d}\"", .{id});
            if (scenario == 2 and index == 299) try body.writer.writeAll(",\"alias\":null");
            try body.writer.writeByte('}');
        }
        try body.writer.writeAll("]}");
        try std.testing.expect(body.written().len > 3800);
        try std.testing.expect(body.written().len <= operation.body_size_max);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body.written(), .{});
        // Invalid Bodies need no allocator, including duplicate checks beyond command 64.
        const result = try plan_body(std.testing.failing_allocator, &parsed);
        try std.testing.expect(result == .rejected);
        if (scenario == 0) {
            try std.testing.expectEqualStrings("The Body exceeds the 64-command complete Result capacity.", result.rejected.message);
        } else {
            try std.testing.expectEqual(@as(usize, 299), result.rejected.command_index);
            try std.testing.expectEqualStrings(if (scenario == 1) "id" else "alias", result.rejected.field.?);
        }
    }
}

test "invalid envelopes never salvage an ID or publish Completion" {
    const invalid_bodies = [_][]const u8{
        "{\"lookup_accounts\":[],\"lookup_\\u0061ccounts\":[]}",
        "{\"lookup_accounts\":[{\"id\":\"1\",\"\\u0069d\":\"1\"}]}",
        "{\"lookup_accounts\":[}",
        "\"" ++ "a" ** 4097 ++ "\"",
        "{\"lookup_accounts\":[{\"id\":\"1\",\"alias\":\"\xff\"}]}",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (invalid_bodies) |body| {
        const message = try std.fmt.allocPrint(allocator, "{{\"id\":\"00112233-4455-6677-8899-aabbccddeeff\",\"tenant\":\"tenant-a\",\"name\":\"test\",\"body\":{s},\"state\":\"SUBMITTED\",\"last_updated\":1700000000,\"expires_at\":1700086400,\"hash\":\"" ++ "ab" ** 32 ++ "\"}}", .{body});
        if (operation.parseOutputJSON(allocator, message)) |_| {
            return error.InvalidEnvelopeWasAccepted;
        } else |err| {
            try std.testing.expect(err != error.OutOfMemory);
        }
        try std.testing.expect(parseRecord(allocator, "bad", message) == .acknowledged);
    }
    const mismatch = try test_legacy_message(allocator, 1);
    try std.testing.expect(parseRecord(allocator, "hash", mismatch) == .acknowledged);
    const event = try testEvent(allocator, &.{mismatch});
    var execution: FakeExecution = .{};
    var publisher: FakePublisher = .{};
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", try handleInvocation(allocator, event, ExecutionAdapter.init(&execution), CompletionPublisher.init(&publisher)));
    try std.testing.expectEqual(@as(u8, 0), publisher.send_count);
    try std.testing.expectEqual(@as(u8, 0), execution.account_count);
}

test "preflight publication failure retries only represented source records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const message = try test_body_message(allocator, 1, "true");
    const event = try testEvent(allocator, &.{ message, "malformed", message });
    var execution: FakeExecution = .{};
    var publisher: FakePublisher = .{ .send_error = error.SendFailed };
    const response = try handleInvocation(allocator, event, ExecutionAdapter.init(&execution), CompletionPublisher.init(&publisher));
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[{\"itemIdentifier\":\"message-0\"},{\"itemIdentifier\":\"message-2\"}]}", response);
    try std.testing.expectEqual(@as(u8, 0), execution.account_count);
    try std.testing.expectEqual(@as(u8, 0), execution.transfer_count);
    try std.testing.expectEqual(@as(u8, 1), publisher.send_count);
}

fn planning_allocation_case(allocator: Allocator, body: *const std.json.Value) !void {
    const result = try plan_body(allocator, body);
    defer allocator.free(result.admitted.commands);
    defer allocator.free(result.admitted.outcomes);
    try std.testing.expectEqual(@as(usize, 1), result.admitted.commands.len);
}

test "typed command and outcome allocation failures are reachable without effects or leaks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"lookup_accounts\":[{\"id\":\"1\"}]}", .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, planning_allocation_case, .{&body});
    const message = try test_body_message(arena.allocator(), 1, "{\"lookup_accounts\":[{\"id\":\"1\"}]}");
    const queued = parseRecord(arena.allocator(), "valid", message).valid;
    try std.testing.expectError(error.OutOfMemory, plan_body(std.testing.failing_allocator, &queued.body));
    const invalid_message = try test_body_message(arena.allocator(), 2, "true");
    const invalid = parseRecord(arena.allocator(), "invalid", invalid_message).valid;
    try std.testing.expect((try plan_body(std.testing.failing_allocator, &invalid.body)) == .rejected);
}

test "seeded family mixes admit uniformly and preserve independent positions" {
    const seed: u64 = 0x02ad_1155_2026;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    for (0..96) |case_index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const count: usize = if (case_index % 2 == 0) 64 else 65;
        var counts = [_]usize{0} ** 3;
        if (case_index < 6) {
            counts[case_index / 2] = count;
        } else {
            for (0..count) |_| counts[random.uintLessThan(usize, 3)] += 1;
        }
        var writer: std.Io.Writer.Allocating = .init(allocator);
        try writer.writer.writeByte('{');
        for (families, 0..) |family, fi| {
            if (fi != 0) try writer.writer.writeByte(',');
            try writer.writer.print("\"{s}\":[", .{@tagName(family)});
            for (0..counts[fi]) |index| {
                if (index != 0) try writer.writer.writeByte(',');
                try writer.writer.print("{{\"id\":\"{d}\"", .{index + 1});
                switch (family) {
                    .create_accounts => try writer.writer.writeAll(",\"flags\":0,\"ledger\":1,\"code\":1"),
                    .create_transfers => try writer.writer.writeAll(",\"flags\":4,\"pending_id\":\"999\",\"amount\":\"0\""),
                    .lookup_accounts => {},
                }
                try writer.writer.writeByte('}');
            }
            try writer.writer.writeByte(']');
        }
        try writer.writer.writeByte('}');
        errdefer std.debug.print("seed={x} case={d} input={s}\n", .{ seed, case_index, writer.written() });
        try std.testing.expect(writer.written().len <= 4096);
        const result = try test_plan(allocator, writer.written());
        try std.testing.expectEqual(count == 64, result == .admitted);
        if (result == .admitted) {
            try std.testing.expectEqualSlices(usize, &counts, &result.admitted.counts);
            var offset: usize = 0;
            for (counts, 0..) |family_count, fi| {
                for (0..family_count) |index| {
                    const command = &result.admitted.commands[offset];
                    try std.testing.expectEqual(@as(u128, index + 1), command.id);
                    if (fi < 2) {
                        const flags = if (fi == 0) command.native.account.flags else command.native.transfer.flags;
                        try std.testing.expectEqual(index + 1 < family_count, flags & 1 != 0);
                    }
                    offset += 1;
                }
            }
        }
    }
}

test "canonical creation names fit the complete Result size bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const commands = try allocator.alloc(Command, 64);
    const outcomes = try allocator.alloc(CommandOutcome, 64);
    const scratch = try allocator.create([operation.result_size_max]u8);
    inline for (.{ Family.create_accounts, Family.create_transfers }) |family| {
        // Enumerate the pinned status range plus the separate created sentinel.
        for (0..70) |index| {
            const code: u32 = if (index == 69) 0xffffffff else @intCast(index);
            const name = if (family == .create_accounts)
                tigerbeetle.create_account_status_name(code)
            else
                tigerbeetle.create_transfer_status_name(code);
            if (name == null) continue;
            for (commands, outcomes) |*command, *outcome| {
                command.* = .{
                    .id = std.math.maxInt(u128) - 1,
                    .alias = "\x00" ** 64,
                    .native = if (family == .create_accounts)
                        .{ .account = std.mem.zeroes(tigerbeetle.Account) }
                    else
                        .{ .transfer = std.mem.zeroes(tigerbeetle.Transfer) },
                };
                outcome.* = .{ .created = code };
            }
            const plan: Plan = .{
                .commands = commands,
                .outcomes = outcomes,
                .counts = if (family == .create_accounts) .{ 64, 0, 0 } else .{ 0, 64, 0 },
            };
            const encoded = try write_result(scratch, &plan);
            // The existing maximal lookup/message shape still dominates creation results.
            try std.testing.expect(encoded.len < 91933);
        }
    }
}

test "bounded serializer fixtures establish complete Result and diagnostic size proofs" {
    // Artificial maximal shapes reserve all escaping, not a claim about a realizable Body.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const commands = try allocator.alloc(Command, 64);
    const outcomes = try allocator.alloc(CommandOutcome, 64);
    for (commands, outcomes) |*command, *outcome| {
        command.* = .{ .id = std.math.maxInt(u128) - 1, .alias = "\x00" ** 64, .native = .{ .lookup = std.math.maxInt(u128) - 1 } };
        outcome.* = .{ .missing = "\x00" ** 160 };
    }
    const scratch = try allocator.create([operation.result_size_max]u8);
    var entry_writer = std.Io.Writer.fixed(scratch);
    try write_outcome(&entry_writer, &commands[0], &outcomes[0]);
    try std.testing.expectEqual(@as(usize, 1387), entry_writer.buffered().len);
    var plan: Plan = .{ .commands = commands, .outcomes = outcomes, .counts = .{ 0, 0, 64 } };
    try std.testing.expectEqual(@as(usize, 88896), (try write_result(scratch, &plan)).len);
    plan = .{ .commands = commands[0..0], .outcomes = outcomes[0..0], .counts = .{ 0, 0, 0 } };
    try std.testing.expectEqual(@as(usize, 65), (try write_result(scratch, &plan)).len);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    const diagnostic: Diagnostic = .{
        .family = .lookup_accounts,
        .command_index = 409,
        .id = std.math.maxInt(u128) - 1,
        .alias = "\x00" ** 64,
        .message = "\x00" ** 160,
        .field = "credit_account_id",
    };
    writer.clearRetainingCapacity();
    const buffer = try arena.allocator().create([operation.result_size_max]u8);
    const encoded = write_diagnostic(buffer, &diagnostic);
    try writer.writer.writeAll(encoded);
    try std.testing.expectEqual(@as(usize, 3525), writer.written().len);
    _ = try test_interpret_body(arena.allocator(), writer.written());
}

test "hash normalization and explicit default identity remain unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const jsons = [_][]const u8{
        "{\"create_transfers\":[{\"id\":\"1\",\"flags\":4,\"pending_id\":\"2\",\"amount\":\"0\"}]}",
        "{ \"create_transfers\" : [ {\"id\":\"\\u0031\",\"flags\":4.0,\"pending_id\":\"2\",\"amount\":\"0\"} ] }",
        "{\"create_transfers\":[{\"id\":\"1\",\"flags\":4,\"pending_id\":\"2\",\"amount\":\"0\",\"ledger\":0}]}",
        "{\"create_transfers\":[{\"flags\":4,\"id\":\"1\",\"pending_id\":\"2\",\"amount\":\"0\"}]}",
    };
    var hashes: [4][32]u8 = undefined;
    var records: [4]tigerbeetle.Transfer = undefined;
    for (jsons, 0..) |json, index| {
        const message = try test_body_message(arena.allocator(), 1, json);
        const parsed = parseRecord(arena.allocator(), "hash", message).valid;
        hashes[index] = try operation.operationHash("tenant-a", "test", &parsed.body);
        records[index] = (try plan_body(arena.allocator(), &parsed.body)).admitted.commands[0].native.transfer;
    }
    try std.testing.expectEqualSlices(u8, &hashes[0], &hashes[1]);
    try std.testing.expect(!std.mem.eql(u8, &hashes[0], &hashes[2]));
    try std.testing.expect(!std.mem.eql(u8, &hashes[0], &hashes[3]));
    for (records[1..]) |record| try std.testing.expectEqualDeep(records[0], record);
}

test "routed numeric boundary table covers code timeout amount and every reference" {
    const pending = "{\"id\":\"1\",\"flags\":2,\"debit_account_id\":\"2\",\"credit_account_id\":\"3\",\"amount\":\"0\",\"ledger\":1,\"code\":1,\"timeout\":1}";
    const post = "{\"id\":\"1\",\"flags\":4,\"pending_id\":\"2\",\"amount\":\"0\"}";
    const Case = struct { field: []const u8, raw: []const u8, accepted: bool = false, post: bool = false };
    const cases = [_]Case{
        .{ .field = "code", .raw = "0" },                                                                                 .{ .field = "code", .raw = "65535", .accepted = true },
        .{ .field = "code", .raw = "65536" },                                                                             .{ .field = "code", .raw = "-0" },
        .{ .field = "code", .raw = "1.5" },                                                                               .{ .field = "code", .raw = "\"1\"" },
        .{ .field = "timeout", .raw = "0" },                                                                              .{ .field = "timeout", .raw = "0.0" },
        .{ .field = "timeout", .raw = "-0" },                                                                             .{ .field = "timeout", .raw = "-1" },
        .{ .field = "timeout", .raw = "1.5" },                                                                            .{ .field = "timeout", .raw = "\"1\"" },
        .{ .field = "timeout", .raw = "4294967295", .accepted = true },                                                   .{ .field = "timeout", .raw = "4294967296" },
        .{ .field = "timeout", .raw = "1e0", .accepted = true },                                                          .{ .field = "amount", .raw = "0" },
        .{ .field = "amount", .raw = "\"00\"" },                                                                          .{ .field = "amount", .raw = "\"340282366920938463463374607431768211456\"" },
        .{ .field = "amount", .raw = "\"340282366920938463463374607431768211455\"", .accepted = true },                   .{ .field = "debit_account_id", .raw = "\"0\"" },
        .{ .field = "debit_account_id", .raw = "\"340282366920938463463374607431768211454\"", .accepted = true },         .{ .field = "debit_account_id", .raw = "\"340282366920938463463374607431768211455\"" },
        .{ .field = "credit_account_id", .raw = "3" },                                                                    .{ .field = "credit_account_id", .raw = "\"03\"" },
        .{ .field = "credit_account_id", .raw = "\"0\"", .post = true, .accepted = true },                                .{ .field = "credit_account_id", .raw = "\"340282366920938463463374607431768211455\"", .post = true },
        .{ .field = "pending_id", .raw = "\"0\"", .post = true },                                                         .{ .field = "pending_id", .raw = "\"340282366920938463463374607431768211455\"", .post = true },
        .{ .field = "pending_id", .raw = "\"340282366920938463463374607431768211454\"", .post = true, .accepted = true }, .{ .field = "pending_id", .raw = "2", .post = true },
        .{ .field = "pending_id", .raw = "\"02\"", .post = true },                                                        .{ .field = "flags", .raw = "\"2\"" },
        .{ .field = "flags", .raw = "-0" },                                                                               .{ .field = "flags", .raw = "2.5" },
        .{ .field = "flags", .raw = "2e0", .accepted = true },
    };
    for (cases) |case| {
        errdefer std.debug.print("field={s} input={s} post={}\n", .{ case.field, case.raw, case.post });
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, if (case.post) post else pending, .{});
        const raw = try std.json.parseFromSliceLeaky(std.json.Value, allocator, case.raw, .{});
        try value.object.put(allocator, case.field, raw);
        var command: Command = undefined;
        const diagnostic = validate_command(.create_transfers, &value, &command);
        try std.testing.expectEqual(case.accepted, diagnostic == null);
        if (diagnostic) |problem| try std.testing.expectEqualStrings(case.field, problem.field.?);
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rejected = try test_plan(arena.allocator(), "{\"create_accounts\":[{\"id\":\"1\",\"alias\":null,\"flags\":6,\"ledger\":1,\"code\":1}]}");
    try std.testing.expectEqualStrings("flags", rejected.rejected.field.?);
    try std.testing.expectEqual(@as(?u128, 1), rejected.rejected.id);
    try std.testing.expect(rejected.rejected.alias == null);
}

test "Body-level diagnostics encode empty families and one payload error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const planning = try test_plan(arena.allocator(), "{\"lookup_accounts\":{}}");
    const buffer = try arena.allocator().create([operation.result_size_max]u8);
    const encoded = write_diagnostic(buffer, &planning.rejected);
    var writer: std.Io.Writer.Allocating = .init(arena.allocator());
    try writer.writer.writeAll(encoded);
    try std.testing.expectEqualStrings(
        \\{"create_accounts":[],"create_transfers":[],"lookup_accounts":[],"error":{"message":"Expected an array of commands.","field":"lookup_accounts"}}
    , writer.written());
}

test "direct Result writer preserves replay positions and refuses unfinished work" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const plan = (try test_plan(arena.allocator(), "{\"create_accounts\":[{\"id\":\"1\",\"flags\":0,\"ledger\":1,\"code\":1},{\"id\":\"2\",\"flags\":0,\"ledger\":1,\"code\":1}]}")).admitted;
    const buffer = try arena.allocator().create([operation.result_size_max]u8);
    try std.testing.expectError(error.UnfinishedOperation, write_result(buffer, &plan));
    plan.outcomes[0] = .{ .created = 21 };
    plan.outcomes[1] = .{ .created = 1 };
    try std.testing.expectEqualStrings(
        "{\"create_accounts\":[{\"error_code\":\"exists\"},{\"error_code\":\"linked_event_failed\"}],\"create_transfers\":[],\"lookup_accounts\":[]}",
        try write_result(buffer, &plan),
    );
}

// Preserve native outcomes; terminal interpretation belongs to the final processor.
fn write_result(
    buffer: *[operation.result_size_max]u8,
    plan: *const Plan,
) ![]const u8 {
    std.debug.assert(plan.commands.len <= command_count_max);
    std.debug.assert(plan.commands.len == plan.outcomes.len);
    std.debug.assert(plan.commands.len == plan.counts[0] + plan.counts[1] + plan.counts[2]);
    for (plan.outcomes) |*outcome| {
        if (outcome.* == .unsubmitted) return error.UnfinishedOperation;
    }
    var writer = std.Io.Writer.fixed(buffer);
    writer.writeAll("{") catch unreachable;
    var offset: usize = 0;
    for (families, 0..) |family, family_index| {
        if (family_index != 0) writer.writeAll(",") catch unreachable;
        writer.print("\"{s}\":[", .{@tagName(family)}) catch unreachable;
        for (0..plan.counts[family_index]) |index| {
            if (index != 0) writer.writeAll(",") catch unreachable;
            write_outcome(&writer, &plan.commands[offset], &plan.outcomes[offset]) catch unreachable;
            offset += 1;
        }
        writer.writeAll("]") catch unreachable;
    }
    writer.writeAll("}") catch unreachable;
    return writer.buffered();
}

fn write_alias(writer: *std.Io.Writer, alias: ?[]const u8) !void {
    if (alias) |text| {
        std.debug.assert(text.len <= 64);
        std.debug.assert(std.unicode.utf8ValidateSlice(text));
        try writer.writeAll(",\"alias\":");
        try std.json.Stringify.value(text, .{}, writer);
    }
}

fn write_message(writer: *std.Io.Writer, message: []const u8) !void {
    std.debug.assert(message.len > 0);
    std.debug.assert(message.len <= 160);
    std.debug.assert(std.unicode.utf8ValidateSlice(message));
    try writer.writeAll("\"message\":");
    try std.json.Stringify.value(message, .{}, writer);
}

fn write_outcome(writer: *std.Io.Writer, command: *const Command, outcome: *const CommandOutcome) !void {
    std.debug.assert(command.id > 0);
    std.debug.assert(command.id < std.math.maxInt(u128));
    switch (outcome.*) {
        .created => std.debug.assert(command.native != .lookup),
        .found, .missing => std.debug.assert(command.native == .lookup),
        .skipped => std.debug.assert(command.native == .transfer),
        .unsubmitted => unreachable,
    }
    try writer.writeAll("{");
    try writer.writeAll("\"error_code\":");
    switch (outcome.*) {
        .unsubmitted => unreachable,
        .created => |code| {
            const name = switch (command.native) {
                .account => tigerbeetle.create_account_status_name(code),
                .transfer => tigerbeetle.create_transfer_status_name(code),
                .lookup => unreachable,
            };
            if (name == null) log.warn("unmapped creation status: family={s} status={d}", .{
                @tagName(command.native), code,
            });
            try std.json.Stringify.value(name orelse "unknown", .{}, writer);
        },
        else => try writer.writeAll("null"),
    }
    try write_alias(writer, command.alias);
    switch (outcome.*) {
        .unsubmitted => unreachable,
        .created => {},
        .found => |*account| {
            std.debug.assert(account.id == command.id);
            try writer.writeAll(",\"account\":");
            try write_account(writer, account);
        },
        .missing, .skipped => |message| {
            try writer.writeAll(",");
            try write_message(writer, message);
        },
    }
    try writer.writeAll("}");
}

fn write_account(writer: *std.Io.Writer, account: *const tigerbeetle.Account) !void {
    try writer.writeAll("{");
    inline for (.{ "id", "debits_pending", "debits_posted", "credits_pending", "credits_posted", "user_data_128", "user_data_64", "user_data_32", "reserved", "ledger", "code", "flags", "timestamp" }, 0..) |field, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("\"{s}\":", .{field});
        const value = @field(account, field);
        if (@bitSizeOf(@TypeOf(value)) >= 64) {
            try writer.print("\"{d}\"", .{value});
        } else {
            try writer.print("{d}", .{value});
        }
    }
    try writer.writeAll("}");
}

fn write_diagnostic(buffer: *[operation.result_size_max]u8, diagnostic: *const Diagnostic) []const u8 {
    std.debug.assert(diagnostic.field == null or diagnostic.member_index == null);
    std.debug.assert(diagnostic.command_index <= processor_message.body_size_max / 10);
    var writer = std.Io.Writer.fixed(buffer);
    writer.writeAll("{") catch unreachable;
    for (families, 0..) |family, family_index| {
        if (family_index != 0) writer.writeAll(",") catch unreachable;
        writer.print("\"{s}\":[", .{@tagName(family)}) catch unreachable;
        if (diagnostic.family == family) {
            for (0..diagnostic.command_index) |_| writer.writeAll("null,") catch unreachable;
            write_diagnostic_entry(&writer, diagnostic) catch unreachable;
        }
        writer.writeAll("]") catch unreachable;
    }
    if (diagnostic.family == null) {
        writer.writeAll(",\"error\":") catch unreachable;
        write_diagnostic_entry(&writer, diagnostic) catch unreachable;
    }
    writer.writeAll("}") catch unreachable;
    return writer.buffered();
}

fn write_diagnostic_entry(writer: *std.Io.Writer, diagnostic: *const Diagnostic) !void {
    try writer.writeAll("{");
    if (diagnostic.family != null) {
        try writer.writeAll("\"error_code\":null");
        try write_alias(writer, diagnostic.alias);
        try writer.writeAll(",");
    }
    try write_message(writer, diagnostic.message);
    if (diagnostic.field) |field| {
        try writer.writeAll(",\"field\":");
        try std.json.Stringify.value(field, .{}, writer);
    }
    if (diagnostic.member_index) |index| try writer.print(",\"member_index\":{d}", .{index});
    try writer.writeAll("}");
}

test "creation and skipped transfer results omit IDs with and without aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_]?[]const u8{ null, "same" }) |alias| {
        for ([_]Family{ .create_accounts, .create_transfers }) |family| {
            const command: Command = .{
                .id = 42,
                .alias = alias,
                .native = if (family == .create_accounts)
                    .{ .account = std.mem.zeroes(tigerbeetle.Account) }
                else
                    .{ .transfer = std.mem.zeroes(tigerbeetle.Transfer) },
            };
            const outcomes = [_]CommandOutcome{
                .{ .created = 0xffffffff },
                .{ .created = 1 },
                .{ .skipped = "Transfer was not submitted because account creation was rejected." },
            };
            for (outcomes) |outcome| {
                if (family == .create_accounts and outcome == .skipped) continue;
                var bytes: [2048]u8 = undefined;
                var writer = std.Io.Writer.fixed(&bytes);
                try write_outcome(&writer, &command, &outcome);
                const entry = (try std.json.parseFromSliceLeaky(std.json.Value, allocator, writer.buffered(), .{})).object;
                try std.testing.expect(!entry.contains("id"));
                try std.testing.expectEqual(alias != null, entry.contains("alias"));
                try std.testing.expectEqual(outcome == .skipped, entry.contains("message"));
                if (outcome == .skipped) {
                    try std.testing.expect(entry.get("error_code").? == .null);
                } else {
                    try std.testing.expect(entry.get("error_code").? == .string);
                }
            }
            const diagnostic: Diagnostic = .{
                .family = family,
                .command_index = 1,
                .id = 42,
                .alias = alias,
                .message = "Unknown field.",
                .member_index = 2,
            };
            var bytes: [operation.result_size_max]u8 = undefined;
            const result = write_diagnostic(&bytes, &diagnostic);
            const decoded = try std.json.parseFromSliceLeaky(std.json.Value, allocator, result, .{});
            const entries = decoded.object.get(@tagName(family)).?.array.items;
            try std.testing.expectEqual(@as(usize, 2), entries.len);
            try std.testing.expect(entries[0] == .null);
            try std.testing.expect(!entries[1].object.contains("id"));
            try std.testing.expectEqual(alias != null, entries[1].object.contains("alias"));
        }
    }
}

test "lookup results omit outer IDs with and without aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_]?[]const u8{ null, "same" }) |alias| {
        const command: Command = .{ .id = 42, .alias = alias, .native = .{ .lookup = 42 } };
        var account = std.mem.zeroes(tigerbeetle.Account);
        account.id = 42;
        for ([_]CommandOutcome{ .{ .found = account }, .{ .missing = "Account was not found." } }) |outcome| {
            var bytes: [2048]u8 = undefined;
            var writer = std.Io.Writer.fixed(&bytes);
            try write_outcome(&writer, &command, &outcome);
            const entry = (try std.json.parseFromSliceLeaky(std.json.Value, allocator, writer.buffered(), .{})).object;
            try std.testing.expect(!entry.contains("id"));
            try std.testing.expectEqual(alias != null, entry.contains("alias"));
            try std.testing.expect(entry.get("error_code").? == .null);
            if (outcome == .found) {
                try std.testing.expectEqualStrings("42", entry.get("account").?.object.get("id").?.string);
            } else {
                try std.testing.expect(!entry.contains("account"));
            }
        }
        const diagnostic: Diagnostic = .{
            .family = .lookup_accounts,
            .command_index = 1,
            .id = 42,
            .alias = alias,
            .message = "Unknown field.",
            .member_index = 2,
        };
        var bytes: [operation.result_size_max]u8 = undefined;
        const result = write_diagnostic(&bytes, &diagnostic);
        const decoded = try std.json.parseFromSliceLeaky(std.json.Value, allocator, result, .{});
        const entries = decoded.object.get("lookup_accounts").?.array.items;
        try std.testing.expectEqual(@as(usize, 2), entries.len);
        try std.testing.expect(entries[0] == .null);
        try std.testing.expect(!entries[1].object.contains("id"));
        try std.testing.expect(!entries[1].object.contains("account"));
        try std.testing.expectEqual(alias != null, entries[1].object.contains("alias"));
    }
}

test "found Account projection preserves every native width and zero field" {
    var account = std.mem.zeroes(tigerbeetle.Account);
    inline for (.{ "id", "debits_pending", "debits_posted", "credits_pending", "credits_posted", "user_data_128", "user_data_64", "user_data_32", "reserved", "ledger", "code", "flags", "timestamp" }) |field| {
        @field(account, field) = std.math.maxInt(@TypeOf(@field(account, field)));
    }
    var bytes: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try write_account(&writer, &account);
    const expected =
        \\{"id":"340282366920938463463374607431768211455","debits_pending":"340282366920938463463374607431768211455","debits_posted":"340282366920938463463374607431768211455","credits_pending":"340282366920938463463374607431768211455","credits_posted":"340282366920938463463374607431768211455","user_data_128":"340282366920938463463374607431768211455","user_data_64":"18446744073709551615","user_data_32":4294967295,"reserved":4294967295,"ledger":4294967295,"code":65535,"flags":65535,"timestamp":"18446744073709551615"}
    ;
    try std.testing.expectEqualStrings(expected, writer.buffered());
    account = std.mem.zeroes(tigerbeetle.Account);
    writer = .fixed(&bytes);
    try write_account(&writer, &account);
    try std.testing.expectEqualStrings(
        \\{"id":"0","debits_pending":"0","debits_posted":"0","credits_pending":"0","credits_posted":"0","user_data_128":"0","user_data_64":"0","user_data_32":0,"reserved":0,"ledger":0,"code":0,"flags":0,"timestamp":"0"}
    , writer.buffered());
}

test "realizable lookup Body carries found data larger than 4 KiB through Completion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var body: std.Io.Writer.Allocating = .init(allocator);
    try body.writer.writeAll("{\"lookup_accounts\":[");
    for (0..64) |index| {
        if (index != 0) try body.writer.writeAll(",");
        try body.writer.print("{{\"id\":\"{d}\",\"alias\":\"same\"}}", .{index + 1});
    }
    try body.writer.writeAll("]}");
    try std.testing.expect(body.written().len < 4096);
    const plan = (try test_plan(allocator, body.written())).admitted;
    for (plan.outcomes, 0..) |*outcome, index| {
        var account = std.mem.zeroes(tigerbeetle.Account);
        account.id = index + 1;
        account.debits_posted = std.math.maxInt(u128);
        account.flags = 65535;
        outcome.* = .{ .found = account };
    }
    plan.outcomes[63] = .{ .missing = "Account was not found." };
    const buffer = try allocator.create([operation.result_size_max]u8);
    const result = try write_result(buffer, &plan);
    try std.testing.expect(result.len > 4096);
    const transport = try allocator.alloc(u8, completion_buffer_size);
    const message = try processor_message.frame(transport, 1, result, null);
    const decoded = try test_results(allocator, &.{message});
    const entry = decoded.results[0].valid;
    try std.testing.expectEqual(@as(u128, 1), entry.operation_id);
    const payload = entry.result.failure.object;
    try std.testing.expect(!payload.contains("operation_id"));
    const lookups = payload.get("lookup_accounts").?.array.items;
    try std.testing.expectEqual(@as(usize, 64), lookups.len);
    for (lookups[0..63], 1..) |lookup, requested_id| {
        try std.testing.expect(!lookup.object.contains("id"));
        try std.testing.expectEqual(requested_id, try std.fmt.parseInt(usize, lookup.object.get("account").?.object.get("id").?.string, 10));
        try std.testing.expectEqualStrings("same", lookup.object.get("alias").?.string);
        try std.testing.expectEqualStrings("340282366920938463463374607431768211455", lookup.object.get("account").?.object.get("debits_posted").?.string);
    }
    try std.testing.expectEqualStrings("Account was not found.", lookups[63].object.get("message").?.string);
}

fn invocation_allocation_case(allocator: Allocator, event: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var execution: FakeExecution = .{};
    var publisher: FakePublisher = .{};
    _ = try handleInvocation(arena.allocator(), event, ExecutionAdapter.init(&execution), CompletionPublisher.init(&publisher));
}

test "invocation scratch and Completion storage clean up allocation failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const message = try test_body_message(arena.allocator(), 1, "true");
    const event = try testEvent(arena.allocator(), &.{message});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, invocation_allocation_case, .{event});
}

test "mixed FAILURE retains writes skipped transfers found observations and aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const plan = (try test_plan(arena.allocator(),
        \\{"create_accounts":[{"id":"1","flags":0,"ledger":1,"code":1}],"create_transfers":[{"id":"3","flags":0,"debit_account_id":"1","credit_account_id":"2","amount":"1","ledger":1,"code":1}],"lookup_accounts":[{"id":"1","alias":"same"},{"id":"2","alias":"same"}]}
    )).admitted;
    plan.outcomes[0] = .{ .created = 4294967295 };
    plan.outcomes[1] = .{ .created = 22 };
    var account = std.mem.zeroes(tigerbeetle.Account);
    account.id = 1;
    plan.outcomes[2] = .{ .found = account };
    plan.outcomes[3] = .{ .missing = "Account was not found." };
    const buffer = try arena.allocator().create([operation.result_size_max]u8);
    const result = try write_result(buffer, &plan);
    try std.testing.expectEqualStrings(
        \\{"create_accounts":[{"error_code":"created"}],"create_transfers":[{"error_code":"credit_account_not_found"}],"lookup_accounts":[{"error_code":null,"alias":"same","account":{"id":"1","debits_pending":"0","debits_posted":"0","credits_pending":"0","credits_posted":"0","user_data_128":"0","user_data_64":"0","user_data_32":0,"reserved":0,"ledger":0,"code":0,"flags":0,"timestamp":"0"}},{"error_code":null,"alias":"same","message":"Account was not found."}]}
    , result);
    plan.outcomes[0] = .{ .created = 2 };
    plan.outcomes[1] = .{ .skipped = "Transfer was not submitted because account creation was rejected." };
    const skipped = try write_result(buffer, &plan);
    const decoded = try test_interpret_body(arena.allocator(), skipped);
    const transfer = decoded.failure.object.get("create_transfers").?.array.items[0].object;
    try std.testing.expect(transfer.get("error_code").? == .null);
    try std.testing.expectEqualStrings("Transfer was not submitted because account creation was rejected.", transfer.get("message").?.string);
}

const execution_body =
    \\{"create_accounts":[{"id":"1","flags":0,"ledger":1,"code":1},{"id":"2","flags":0,"ledger":1,"code":1}],"create_transfers":[{"id":"3","flags":0,"debit_account_id":"1","credit_account_id":"2","amount":"10","ledger":1,"code":1}],"lookup_accounts":[{"id":"2","alias":"credit"},{"id":"1","alias":"debit"}]}
;

fn test_invoke(allocator: Allocator, bodies: []const []const u8, fake: *FakeExecution, publisher: *FakePublisher) ![]const u8 {
    const messages = try allocator.alloc([]const u8, bodies.len);
    for (bodies, 0..) |body, index| messages[index] = try test_body_message(allocator, index + 1, body);
    return handleInvocation(allocator, try testEvent(allocator, messages), ExecutionAdapter.init(fake), CompletionPublisher.init(publisher));
}

test "family barriers intact duplicate chains and sparse repeated lookup aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: FakeExecution = .{};
    fake.account_outcomes[2] = .{ .rejected = tigerbeetle.account_exists };
    fake.account_outcomes[3] = .{ .rejected = tigerbeetle.account_linked_event_failed };
    fake.transfer_outcomes[1] = .{ .rejected = tigerbeetle.transfer_exists };
    var account = std.mem.zeroes(tigerbeetle.Account);
    account.id = 1;
    account.debits_posted = 10;
    fake.lookup_results[0] = account;
    fake.lookup_results[1] = account;
    fake.lookup_count = 2;
    var publisher: FakePublisher = .{};
    const response = try test_invoke(arena.allocator(), &.{ execution_body, execution_body }, &fake, &publisher);
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
    try std.testing.expectEqualSlices(Family, &families, fake.trace[0..fake.trace_count]);
    try std.testing.expectEqual(@as(usize, 4), fake.account_count);
    try std.testing.expectEqual(@as(usize, 2), fake.transfer_count);
    for (fake.accounts[0..4], 0..) |account_input, index| {
        try std.testing.expectEqual(@as(u16, if (index % 2 == 0) tigerbeetle.account_linked else 0), account_input.flags);
    }
    for (fake.transfers[0..2]) |transfer| try std.testing.expectEqual(@as(u16, 0), transfer.flags);
    try std.testing.expectEqualSlices(u128, &.{ 2, 1, 2, 1 }, fake.lookup_ids[0..4]);
    const decoded = try test_results(arena.allocator(), publisher.messages[0..publisher.send_count]);
    try std.testing.expectEqual(@as(usize, 2), decoded.results.len);
    for (decoded.results) |entry| {
        const payload = entry.valid.result.failure.object;
        const lookups = payload.get("lookup_accounts").?.array.items;
        try std.testing.expectEqualStrings("credit", lookups[0].object.get("alias").?.string);
        try std.testing.expect(lookups[0].object.get("account") == null);
        try std.testing.expectEqualStrings("debit", lookups[1].object.get("alias").?.string);
        try std.testing.expectEqualStrings("10", lookups[1].object.get("account").?.object.get("debits_posted").?.string);
    }
}

test "account rejection skips only its transfers and lookup follows either rejection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: FakeExecution = .{};
    fake.account_outcomes[0] = .{ .rejected = 8 };
    fake.account_outcomes[1] = .{ .rejected = tigerbeetle.account_linked_event_failed };
    fake.transfer_outcomes[0] = .{ .rejected = 22 };
    var publisher: FakePublisher = .{};
    _ = try test_invoke(arena.allocator(), &.{ execution_body, execution_body }, &fake, &publisher);
    try std.testing.expectEqualSlices(Family, &families, fake.trace[0..fake.trace_count]);
    try std.testing.expectEqual(@as(usize, 1), fake.transfer_count);
    const decoded = try test_results(arena.allocator(), publisher.messages[0..publisher.send_count]);
    const skipped = decoded.results[0].valid.result.failure.object.get("create_transfers").?.array.items[0].object;
    try std.testing.expect(skipped.get("error_code").? == .null);
    try std.testing.expect(skipped.get("message") != null);
    const rejected = decoded.results[1].valid.result.failure.object.get("create_transfers").?.array.items[0].object;
    try std.testing.expectEqualStrings("credit_account_not_found", rejected.get("error_code").?.string);
}

test "creation layouts validate entire packet before mutation for both families" {
    inline for (.{ Family.create_accounts, Family.create_transfers }) |family| {
        const Result = if (family == .create_accounts) tigerbeetle.CreateAccountResult else tigerbeetle.CreateTransferResult;
        const created = if (family == .create_accounts) tigerbeetle.account_created else tigerbeetle.transfer_created;
        const exists = if (family == .create_accounts) tigerbeetle.account_exists else tigerbeetle.transfer_exists;
        const failed = if (family == .create_accounts) tigerbeetle.account_linked_event_failed else tigerbeetle.transfer_linked_event_failed;
        const cases = [_]struct { statuses: [2]u32, expected: ?ChainState }{
            .{ .statuses = .{ created, created }, .expected = .accepted },
            .{ .statuses = .{ exists, failed }, .expected = .accepted },
            .{ .statuses = .{ failed, exists }, .expected = .rejected },
            .{ .statuses = .{ 123456, failed }, .expected = .rejected },
            .{ .statuses = .{ created, failed }, .expected = null },
            .{ .statuses = .{ failed, failed }, .expected = null },
            .{ .statuses = .{ exists, exists }, .expected = null },
            .{ .statuses = .{ created, exists }, .expected = null },
        };
        for (cases) |case| {
            var results = [_]Result{std.mem.zeroes(Result)} ** 2;
            for (&results, case.statuses) |*result, status| result.status = status;
            if (case.expected) |expected| {
                try std.testing.expectEqual(expected, try classify_chain(family, &results));
            } else try std.testing.expectError(error.InvalidCreationReply, classify_chain(family, &results));
        }
        var singleton = [_]Result{std.mem.zeroes(Result)};
        singleton[0].status = exists;
        try std.testing.expectEqual(ChainState.accepted, try classify_chain(family, &singleton));
    }
    for ([_]?usize{ 0, 1, 3, 5, null }) |count| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: FakeExecution = .{};
        fake.account_reply_count = count;
        if (count == null) fake.account_outcomes[3] = .{ .rejected = tigerbeetle.account_exists };
        var publisher: FakePublisher = .{};
        const response = try test_invoke(arena.allocator(), &.{ execution_body, execution_body }, &fake, &publisher);
        try std.testing.expectEqualStrings("{\"batchItemFailures\":[{\"itemIdentifier\":\"message-0\"},{\"itemIdentifier\":\"message-1\"}]}", response);
        try std.testing.expectEqualSlices(Family, &.{.create_accounts}, fake.trace[0..fake.trace_count]);
        try std.testing.expectEqual(@as(u8, 0), publisher.send_count);
    }
}

test "unmapped creation statuses publish unknown without retry" {
    // These fixtures deliberately produce warnings; keep successful tests quiet.
    const previous_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = previous_log_level;

    inline for (.{ Family.create_accounts, Family.create_transfers }) |family| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: FakeExecution = .{};
        if (family == .create_accounts) {
            fake.account_outcomes[2] = .{ .rejected = 123456 };
            fake.account_outcomes[3] = .{ .rejected = tigerbeetle.account_linked_event_failed };
        } else {
            fake.transfer_outcomes[1] = .{ .rejected = 123456 };
        }
        var publisher: FakePublisher = .{};
        const response = try test_invoke(
            arena.allocator(),
            &.{ execution_body, execution_body },
            &fake,
            &publisher,
        );
        try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
        try std.testing.expectEqual(@as(u8, 2), publisher.send_count);
        try std.testing.expectEqualSlices(Family, &families, fake.trace[0..fake.trace_count]);
        const batch = try test_results(arena.allocator(), publisher.messages[0..publisher.send_count]);
        try std.testing.expectEqual(@as(usize, 2), batch.results.len);
        const payload = batch.results[1].valid.result.failure.object;
        const entries = payload.get(@tagName(family)).?.array.items;
        try std.testing.expectEqualStrings("unknown", entries[0].object.get("error_code").?.string);
    }
}

test "request errors stop each phase and publish later fully determined Operations" {
    for (families, 0..) |family, phase| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: FakeExecution = .{};
        switch (family) {
            .create_accounts => fake.account_errors[0] = error.NativeUnavailable,
            .create_transfers => fake.transfer_errors[0] = error.NativeUnavailable,
            .lookup_accounts => fake.lookup_error = error.NativeUnavailable,
        }
        var publisher: FakePublisher = .{};
        const account_only = "{\"create_accounts\":[{\"id\":\"9\",\"flags\":0,\"ledger\":1,\"code\":1}]}";
        const response = try test_invoke(arena.allocator(), &.{ execution_body, account_only, "true" }, &fake, &publisher);
        try std.testing.expectEqualSlices(Family, families[0 .. phase + 1], fake.trace[0..fake.trace_count]);
        try std.testing.expectEqualStrings(if (phase == 0)
            "{\"batchItemFailures\":[{\"itemIdentifier\":\"message-0\"},{\"itemIdentifier\":\"message-1\"}]}"
        else
            "{\"batchItemFailures\":[{\"itemIdentifier\":\"message-0\"}]}", response);
        const decoded = try test_results(arena.allocator(), publisher.messages[0..publisher.send_count]);
        try std.testing.expectEqual(@as(usize, if (phase == 0) 1 else 2), decoded.results.len);
        if (phase > 0) try std.testing.expect(decoded.results[0].valid.result == .success);
    }
}

test "lookup validation rejects unknown partial excess inconsistent groups before any routing" {
    const ids = [_]u128{ 3, 1, 2, 1 };
    const cases = [_][]const u128{ &.{ 1, 2 }, &.{ 1, 1, 1 }, &.{ 1, 1, 4 }, &.{ 1, 1, 2, 3, 3 } };
    for (cases) |returned| {
        var accounts: [5]tigerbeetle.Account = undefined;
        for (returned, 0..) |id, index| {
            accounts[index] = std.mem.zeroes(tigerbeetle.Account);
            accounts[index].id = id;
        }
        var positions: [4]usize = undefined;
        try std.testing.expectError(error.InvalidLookupReply, correlate_lookup_reply(&ids, &positions, accounts[0..returned.len]));
    }
    inline for (@typeInfo(tigerbeetle.Account).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "id")) continue;
        var accounts = [_]tigerbeetle.Account{std.mem.zeroes(tigerbeetle.Account)} ** 2;
        accounts[0].id = 1;
        accounts[1].id = 1;
        @field(accounts[1], field.name) = 1;
        var positions: [4]usize = undefined;
        try std.testing.expectError(error.InvalidLookupReply, correlate_lookup_reply(&ids, &positions, &accounts));
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: FakeExecution = .{};
    fake.lookup_count = 1;
    fake.lookup_results[0] = std.mem.zeroes(tigerbeetle.Account);
    fake.lookup_results[0].id = 2; // A valid-looking prefix, but only one of two required copies.
    var publisher: FakePublisher = .{};
    const response = try test_invoke(arena.allocator(), &.{ execution_body, execution_body }, &fake, &publisher);
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[{\"itemIdentifier\":\"message-0\"},{\"itemIdentifier\":\"message-1\"}]}", response);
    try std.testing.expectEqual(@as(u8, 0), publisher.send_count);
}

const PackingExecution = struct {
    calls: usize = 0,
    seen: usize = 0,
    sizes: [4]usize = undefined,
    input_address: ?usize = null,
    output_address: ?usize = null,
    fail_second: bool = false,
    malformed_second: bool = false,

    fn createAccounts(self: *PackingExecution, input: []const tigerbeetle.Account, output: []tigerbeetle.CreateAccountResult) !usize {
        try std.testing.expect(input.len > 0 and input.len <= native_capacity);
        if (self.input_address) |address| try std.testing.expectEqual(address, @intFromPtr(input.ptr));
        if (self.output_address) |address| try std.testing.expectEqual(address, @intFromPtr(output.ptr));
        self.input_address = @intFromPtr(input.ptr);
        self.output_address = @intFromPtr(output.ptr);
        self.sizes[self.calls] = input.len;
        self.calls += 1;
        for (input, 0..) |account, index| {
            try std.testing.expectEqual(@as(u128, self.seen + index + 1), account.id);
            output[index] = std.mem.zeroes(tigerbeetle.CreateAccountResult);
            output[index].status = tigerbeetle.account_created;
        }
        try std.testing.expectEqual(@as(u16, 0), input[input.len - 1].flags & tigerbeetle.account_linked);
        self.seen += input.len;
        if (self.calls == 2 and self.fail_second) return error.NativeUnavailable;
        if (self.calls == 2 and self.malformed_second) output[output.len - 1].status = tigerbeetle.account_exists;
        return input.len;
    }
    fn createTransfers(_: *PackingExecution, _: []const tigerbeetle.Transfer, _: []tigerbeetle.CreateTransferResult) !usize {
        return error.UnexpectedTransfer;
    }
    fn lookupAccounts(_: *PackingExecution, _: []const u128, _: []tigerbeetle.Account) !usize {
        return error.UnexpectedLookup;
    }
};

fn synthetic_plans(allocator: Allocator, counts: []const usize) ![]?Planning {
    const plans = try allocator.alloc(?Planning, counts.len);
    var id: u128 = 1;
    for (plans, counts) |*planning, count| {
        const commands = try allocator.alloc(Command, count);
        const outcomes = try allocator.alloc(CommandOutcome, count);
        @memset(outcomes, .unsubmitted);
        for (commands, 0..) |*command, index| {
            var account = std.mem.zeroes(tigerbeetle.Account);
            account.id = id;
            account.flags = if (index + 1 < count) tigerbeetle.account_linked else 0;
            command.* = .{ .id = id, .alias = null, .native = .{ .account = account } };
            id += 1;
        }
        planning.* = .{ .admitted = .{ .commands = commands, .outcomes = outcomes, .counts = .{ count, 0, 0 } } };
    }
    return plans;
}

test "exact 8189 capacity flushes next intact chain reuses buffers and preserves earlier packet facts" {
    for (0..3) |mode| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var counts = [_]usize{64} ** 129;
        counts[127] = 61; // 127 * 64 + 61 = 8189; the next chain remains intact.
        const plans = try synthetic_plans(arena.allocator(), &counts);
        var fake: PackingExecution = .{ .fail_second = mode == 1, .malformed_second = mode == 2 };
        const result = execute_phases(arena.allocator(), plans, ExecutionAdapter.init(&fake));
        if (mode == 1) try std.testing.expectError(error.NativeUnavailable, result) else if (mode == 2)
            try std.testing.expectError(error.InvalidCreationReply, result)
        else
            try result;
        try std.testing.expectEqualSlices(usize, &.{ 8189, 64 }, fake.sizes[0..fake.calls]);
        for (plans[0..128]) |planning| {
            try std.testing.expectEqual(ChainState.accepted, planning.?.admitted.chains[0]);
            for (planning.?.admitted.outcomes) |outcome| try std.testing.expectEqual(tigerbeetle.account_created, outcome.created);
        }
        for (plans[128].?.admitted.outcomes) |outcome| {
            if (mode == 0) try std.testing.expect(outcome == .created) else try std.testing.expect(outcome == .unsubmitted);
        }
    }
}

test "seeded whole chain packing preserves order boundaries and greedy request counts" {
    const seed = 0x4c696e6b;
    var random_state: std.Random.DefaultPrng = .init(seed);
    const random = random_state.random();
    for (0..32) |case| {
        errdefer std.debug.print("packing seed={d} case={d}\n", .{ seed, case });
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var counts: [300]usize = undefined;
        var expected_calls: usize = 1;
        var remaining: usize = native_capacity;
        for (&counts) |*count| {
            count.* = random.intRangeAtMost(usize, 1, 64);
            if (count.* > remaining) {
                expected_calls += 1;
                remaining = native_capacity;
            }
            remaining -= count.*;
        }
        const plans = try synthetic_plans(arena.allocator(), &counts);
        var fake: PackingExecution = .{};
        try execute_phases(arena.allocator(), plans, ExecutionAdapter.init(&fake));
        try std.testing.expectEqual(expected_calls, fake.calls);
        for (plans) |planning| try std.testing.expectEqual(ChainState.accepted, planning.?.admitted.chains[0]);
    }
}

test "seeded unordered lookup copies validate and route every original position" {
    const seed = 0x4c6f6f6b;
    var random_state: std.Random.DefaultPrng = .init(seed);
    const random = random_state.random();
    for (0..32) |case| {
        errdefer std.debug.print("lookup seed={d} case={d}\n", .{ seed, case });
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var plans: [4]?Planning = undefined;
        var fake: FakeExecution = .{};
        for (&plans) |*planning| {
            var ids: [16]u128 = undefined;
            for (&ids, 0..) |*id, index| id.* = index + 1;
            random.shuffle(u128, &ids);
            const commands = try allocator.alloc(Command, 16);
            const outcomes = try allocator.alloc(CommandOutcome, 16);
            @memset(outcomes, .unsubmitted);
            for (commands, ids) |*command, id| {
                command.* = .{ .id = id, .alias = "same", .native = .{ .lookup = id } };
                if (id % 3 != 0) {
                    var account = std.mem.zeroes(tigerbeetle.Account);
                    account.id = id;
                    account.credits_posted = id * 7;
                    fake.lookup_results[fake.lookup_count] = account;
                    fake.lookup_count += 1;
                }
            }
            planning.* = .{ .admitted = .{ .commands = commands, .outcomes = outcomes, .counts = .{ 0, 0, 16 } } };
        }
        random.shuffle(tigerbeetle.Account, fake.lookup_results[0..fake.lookup_count]);
        try execute_phases(allocator, &plans, ExecutionAdapter.init(&fake));
        try std.testing.expectEqualSlices(Family, &.{.lookup_accounts}, fake.trace[0..fake.trace_count]);
        for (plans, 0..) |planning, operation_index| {
            const plan = planning.?.admitted;
            for (plan.commands, plan.outcomes, 0..) |command, outcome, index| {
                try std.testing.expectEqual(command.id, fake.lookup_ids[operation_index * 16 + index]);
                if (command.id % 3 == 0) {
                    try std.testing.expect(outcome == .missing);
                } else {
                    try std.testing.expectEqual(command.id, outcome.found.id);
                    try std.testing.expectEqual(command.id * 7, outcome.found.credits_posted);
                }
            }
        }
    }
}

fn workspace_allocation_case(allocator: Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const planning = try test_plan(arena.allocator(), execution_body);
    var plans = [_]?Planning{planning};
    var fake: FakeExecution = .{};
    execute_phases(allocator, &plans, ExecutionAdapter.init(&fake)) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), fake.trace_count);
        for (plans[0].?.admitted.outcomes) |outcome| try std.testing.expect(outcome == .unsubmitted);
        return err;
    };
    try std.testing.expectEqual(@as(usize, 3), fake.trace_count);
}

test "every native workspace allocation failure precedes effects and releases scratch" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, workspace_allocation_case, .{});
}

test "maximum admitted invocation uses three native calls and ten individual result sends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var body: std.Io.Writer.Allocating = .init(allocator);
    try body.writer.writeAll("{\"create_accounts\":[{\"id\":\"1\",\"flags\":0,\"ledger\":1,\"code\":1}],\"create_transfers\":[{\"id\":\"2\",\"flags\":0,\"debit_account_id\":\"1\",\"credit_account_id\":\"3\",\"amount\":\"1\",\"ledger\":1,\"code\":1}],\"lookup_accounts\":[");
    for (0..62) |index| {
        if (index > 0) try body.writer.writeAll(",");
        try body.writer.print("{{\"id\":\"{d}\"}}", .{index + 1});
    }
    try body.writer.writeAll("]}");
    try std.testing.expect(body.written().len <= operation.body_size_max);
    const bodies = [_][]const u8{body.written()} ** record_count_max;
    var fake: FakeExecution = .{};
    var publisher: FakePublisher = .{};
    var measured: std.testing.FailingAllocator = .init(allocator, .{});
    const response = try test_invoke(measured.allocator(), &bodies, &fake, &publisher);
    errdefer std.debug.print("maximum invocation: allocated_bytes={d} allocations={d} native_calls={d} sends={d}\n", .{
        measured.allocated_bytes, measured.allocations, fake.trace_count, publisher.send_count,
    });
    try std.testing.expect(measured.allocated_bytes < 8 * 1024 * 1024);
    try std.testing.expect(measured.allocations < 10000);
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
    try std.testing.expectEqual(@as(usize, 10), fake.account_count);
    try std.testing.expectEqual(@as(usize, 10), fake.transfer_count);
    try std.testing.expectEqualSlices(Family, &families, fake.trace[0..fake.trace_count]);
    try std.testing.expectEqual(@as(u8, 10), publisher.send_count);
    const decoded = try test_results(allocator, publisher.messages[0..publisher.send_count]);
    try std.testing.expectEqual(@as(usize, 10), decoded.results.len);
    for (decoded.results) |entry| try std.testing.expectEqual(@as(usize, 62), entry.valid.result.failure.object.get("lookup_accounts").?.array.items.len);
}

test "malformed final creation range cannot publish a valid looking prefix in either family" {
    const account_body = "{\"create_accounts\":[{\"id\":\"1\",\"flags\":0,\"ledger\":1,\"code\":1},{\"id\":\"2\",\"flags\":0,\"ledger\":1,\"code\":1}]}";
    const transfer_body = "{\"create_transfers\":[{\"id\":\"3\",\"flags\":0,\"debit_account_id\":\"1\",\"credit_account_id\":\"2\",\"amount\":\"1\",\"ledger\":1,\"code\":1},{\"id\":\"4\",\"flags\":0,\"debit_account_id\":\"1\",\"credit_account_id\":\"2\",\"amount\":\"1\",\"ledger\":1,\"code\":1}]}";
    for ([_][]const u8{ account_body, transfer_body }, 0..) |body, family| {
        for ([_]?usize{ 0, 1, 3, 5, null }) |count| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var fake: FakeExecution = .{};
            if (family == 0) {
                fake.account_reply_count = count;
                if (count == null) fake.account_outcomes[3] = .{ .rejected = tigerbeetle.account_exists };
            } else {
                fake.transfer_reply_count = count;
                if (count == null) fake.transfer_outcomes[3] = .{ .rejected = tigerbeetle.transfer_exists };
            }
            var publisher: FakePublisher = .{};
            const response = try test_invoke(arena.allocator(), &.{ body, body }, &fake, &publisher);
            try std.testing.expectEqualStrings("{\"batchItemFailures\":[{\"itemIdentifier\":\"message-0\"},{\"itemIdentifier\":\"message-1\"}]}", response);
            try std.testing.expectEqual(@as(usize, 1), fake.trace_count);
            try std.testing.expectEqual(@as(u8, 0), publisher.send_count);
        }
    }
}

test "fully found created and replayed Operations publish SUCCESS with actual codes" {
    for (0..2) |attempt| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: FakeExecution = .{};
        if (attempt == 1) {
            fake.account_outcomes[0] = .{ .rejected = tigerbeetle.account_exists };
            fake.account_outcomes[1] = .{ .rejected = tigerbeetle.account_linked_event_failed };
            fake.transfer_outcomes[0] = .{ .rejected = tigerbeetle.transfer_exists };
        }
        for (0..2) |index| {
            fake.lookup_results[index] = std.mem.zeroes(tigerbeetle.Account);
            fake.lookup_results[index].id = index + 1;
        }
        fake.lookup_count = 2;
        var publisher: FakePublisher = .{};
        const response = try test_invoke(arena.allocator(), &.{execution_body}, &fake, &publisher);
        try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
        const decoded = try test_results(arena.allocator(), publisher.messages[0..publisher.send_count]);
        const payload = decoded.results[0].valid.result.success.object;
        const accounts = payload.get("create_accounts").?.array.items;
        try std.testing.expectEqualStrings(if (attempt == 0) "created" else "exists", accounts[0].object.get("error_code").?.string);
        try std.testing.expectEqualStrings(if (attempt == 0) "created" else "linked_event_failed", accounts[1].object.get("error_code").?.string);
    }
}

fn executable_invocation_allocation_case(allocator: Allocator, event: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var execution: FakeExecution = .{};
    var publisher: FakePublisher = .{};
    const response = try handleInvocation(arena.allocator(), event, ExecutionAdapter.init(&execution), CompletionPublisher.init(&publisher));
    try std.testing.expect(execution.trace_count == 0 or execution.trace_count == 3);
    if (publisher.send_count > 0) try std.testing.expectEqual(@as(usize, 3), execution.trace_count);
    try std.testing.expect(response.len > 0);
}

test "executable invocation allocation faults include post effect publication and response cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const message = try test_body_message(arena.allocator(), 1, execution_body);
    const event = try testEvent(arena.allocator(), &.{message});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executable_invocation_allocation_case, .{event});
}

const SerialPublisher = struct {
    messages: [4][]const u8 = undefined,
    calls: usize = 0,
    fail_at: ?usize = null,
    ambiguous: bool = false,

    fn sendCompletion(self: *SerialPublisher, allocator: Allocator, result_queue: ?[]const u8, body: []const u8) !void {
        _ = result_queue;
        std.debug.assert(self.calls < self.messages.len);
        const index = self.calls;
        self.calls += 1;
        if (self.fail_at == index and !self.ambiguous) return error.SendFailed;
        self.messages[index] = try allocator.dupe(u8, body);
        if (self.fail_at == index) return error.SendFailed;
    }
};

test "serial publication skips unfinished records and preserves successful prefix on either send failure" {
    for ([_]?usize{ null, 0, 1, 2 }) |fail_at| {
        for ([_]bool{ false, true }) |ambiguous| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            const terminal_count = 2 * completion_count_max + 1;
            const queued_count = terminal_count + 1;
            const queued = try allocator.alloc(processor_message.Message, queued_count);
            const plans = try allocator.alloc(?Planning, queued_count);
            var indexes: [queued_count]usize = undefined;
            var retries = [_]bool{false} ** queued_count;
            for (queued, plans, &indexes, 0..) |*entry, *plan, *index, i| {
                const message = try test_body_message(allocator, i + 1, "true");
                entry.* = (parseRecord(allocator, "source", message)).valid;
                plan.* = try plan_body(allocator, &entry.body);
                index.* = i;
            }
            // An unfinished source must not block later terminal Results.
            plans[completion_count_max] = null;
            const result = try allocator.create([operation.result_size_max]u8);
            const buffer = try allocator.alloc(u8, completion_buffer_size);
            var publisher: SerialPublisher = .{ .fail_at = fail_at, .ambiguous = ambiguous };
            publish_results(allocator, queued, plans, &indexes, &retries, result, buffer, CompletionPublisher.init(&publisher));
            try std.testing.expectEqual(@as(usize, if (fail_at) |n| n + 1 else 3), publisher.calls);
            var terminal_index: usize = 0;
            for (retries, 0..) |retry, i| {
                if (i == completion_count_max) {
                    try std.testing.expect(retry);
                    continue;
                }
                try std.testing.expectEqual(if (fail_at) |n| terminal_index / completion_count_max >= n else false, retry);
                terminal_index += 1;
            }
            var next_id: u128 = 1;
            const captured = if (fail_at) |n| n + @intFromBool(ambiguous) else 3;
            for (publisher.messages[0..captured], 0..) |message, send_index| {
                const batch = try test_results(allocator, &.{message});
                try std.testing.expectEqual(@as(usize, if (send_index == 2) 1 else completion_count_max), batch.results.len);
                for (batch.results) |entry| {
                    if (next_id == completion_count_max + 1) next_id += 1;
                    try std.testing.expectEqual(next_id, entry.valid.operation_id);
                    const expected = write_diagnostic(result, &plans[@intCast(next_id - 1)].?.rejected);
                    const actual = try allocator.create([operation.result_size_max]u8);
                    try std.testing.expectEqualStrings(expected, try test_result_body(actual, &entry.valid.result));
                    next_id += 1;
                }
            }
        }
    }
}

test "large lookup and mixed Results traverse Completion conditional persistence and authenticated query first wins" {
    const tiger_beetle_completion_processor = @import("tiger_beetle_completion_processor");
    const persistence = @import("operation_persistence");
    const query = @import("query_lambda");
    for ([_]bool{ false, true }) |mixed| {
        for ([_]bool{ false, true }) |reverse| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            var body: std.Io.Writer.Allocating = .init(allocator);
            try body.writer.writeByte('{');
            if (mixed) try body.writer.writeAll("\"create_accounts\":[{\"id\":\"1\",\"flags\":0,\"ledger\":1,\"code\":1}],");
            try body.writer.writeAll("\"lookup_accounts\":[");
            for (0..32) |i| {
                if (i != 0) try body.writer.writeByte(',');
                try body.writer.print("{{\"id\":\"{d}\",\"alias\":\"same\"}}", .{i + 1});
            }
            try body.writer.writeAll("]}");
            const original = try test_body_message(allocator, 1, body.written());
            const queued = (parseRecord(allocator, "source", original)).valid;
            const stored_operation = try test_stored_operation(allocator, &queued);
            var store = persistence.test_support.Store.init(&stored_operation);
            var messages: [2][]const u8 = undefined;
            for (&messages, 0..) |*message, attempt| {
                // Only the queued bytes survive invocation restart. No saved native observation.
                var execution: FakeExecution = .{};
                execution.lookup_count = if (attempt == 0) 32 else 31;
                for (execution.lookup_results[0..execution.lookup_count], 0..) |*account, i| {
                    account.* = std.mem.zeroes(tigerbeetle.Account);
                    account.id = i + 1;
                    account.debits_posted = if (attempt == 0) 90 else 70;
                    account.user_data_128 = std.math.maxInt(u128);
                }
                if (attempt == 1) execution.account_outcomes[0] = .{ .rejected = tigerbeetle.account_exists };
                var publisher: FakePublisher = .{};
                const response = try handleInvocation(allocator, try testEvent(allocator, &.{original}), ExecutionAdapter.init(&execution), CompletionPublisher.init(&publisher));
                try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
                try std.testing.expectEqualSlices(Family, if (mixed) &.{ .create_accounts, .lookup_accounts } else &.{.lookup_accounts}, execution.trace[0..execution.trace_count]);
                try std.testing.expect(publisher.message.len > 4096);
                message.* = publisher.message;
            }
            const first: usize = @intFromBool(reverse);
            for ([_]usize{ first, 1 - first, first }) |arrival| {
                const response = try tiger_beetle_completion_processor.test_support.invoke(allocator, messages[arrival], &store);
                try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
            }
            try std.testing.expectEqual(@as(usize, 1), store.writes);
            const stored = try store.read(allocator, 1);
            const queried = try query.test_support.query(allocator, &stored);
            const outer = try std.json.parseFromSliceLeaky(std.json.Value, allocator, queried, .{});
            try std.testing.expectEqual(@as(i64, 200), outer.object.get("statusCode").?.integer);
            const restored = try operation.parseOutputJSON(allocator, outer.object.get("body").?.string);
            const expected = (try test_results(allocator, &.{messages[first]})).results[0].valid.result;
            const expected_buffer = try allocator.create([operation.result_size_max]u8);
            const actual_buffer = try allocator.create([operation.result_size_max]u8);
            try std.testing.expectEqualStrings(try operation.writeCompletionJSON(expected_buffer, &expected), try operation.writeCompletionJSON(actual_buffer, &restored.state.completed));
            const payload = if (reverse) restored.state.completed.failure else restored.state.completed.success;
            const lookups = payload.object.get("lookup_accounts").?.array.items;
            try std.testing.expectEqual(@as(usize, 32), lookups.len);
            try std.testing.expectEqualStrings(if (reverse) "70" else "90", lookups[0].object.get("account").?.object.get("debits_posted").?.string);
            try std.testing.expectEqualStrings("340282366920938463463374607431768211455", lookups[0].object.get("account").?.object.get("user_data_128").?.string);
        }
    }
}

test "individual completion retry preserves other persisted results and source acknowledgements" {
    const tiger_beetle_completion_processor = @import("tiger_beetle_completion_processor");
    const persistence = @import("operation_persistence");
    for ([_]bool{ false, true }) |completed_subset| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var execution: FakeExecution = .{};
        var publisher: FakePublisher = .{};
        const source_response = try test_invoke(allocator, &.{ "true", "true", "true" }, &execution, &publisher);
        try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", source_response);
        try std.testing.expectEqual(@as(usize, 0), execution.trace_count);
        var store: persistence.test_support.Store = .{};
        for (&store.entries, 0..) |*entry, i| {
            const message = (parseRecord(allocator, "source", try test_body_message(allocator, i + 1, "true"))).valid;
            entry.* = try test_stored_operation(allocator, &message);
        }
        if (completed_subset) {
            // A different aggregate has already completed the middle entry.
            try store.completeById(allocator, 2, &.{ .success = .{ .string = "earlier winner" } }, 1_700_000_000);
        }
        store.fail_at = store.calls + 2;
        for (publisher.messages[0..2]) |message| {
            _ = try tiger_beetle_completion_processor.test_support.invoke(allocator, message, &store);
        }
        const failed = try tiger_beetle_completion_processor.test_support.invoke(allocator, publisher.messages[2], &store);
        try std.testing.expectEqualStrings("{\"batchItemFailures\":[{\"itemIdentifier\":\"message-0\"}]}", failed);
        try std.testing.expectEqual(@as(usize, 2), store.writes);
        try std.testing.expect(store.entries[2].?.state == .submitted);
        store.fail_at = null;
        const replayed = try tiger_beetle_completion_processor.test_support.invoke(allocator, publisher.messages[2], &store);
        try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", replayed);
        try std.testing.expectEqual(@as(usize, 3), store.writes);
        _ = try tiger_beetle_completion_processor.test_support.invoke(allocator, publisher.message, &store);
        try std.testing.expectEqual(@as(usize, 3), store.writes);
        const batch = try test_results(allocator, publisher.messages[0..publisher.send_count]);
        for (store.entries, batch.results, 0..) |slot, decoded, i| {
            if (completed_subset and i == 1) {
                try std.testing.expectEqualStrings("earlier winner", slot.?.state.completed.success.string);
                try std.testing.expectEqual(@as(i64, 1_700_000_000), slot.?.last_updated.?);
            } else {
                const expected = try allocator.create([operation.result_size_max]u8);
                const actual = try allocator.create([operation.result_size_max]u8);
                try std.testing.expectEqualStrings(try operation.writeCompletionJSON(expected, &decoded.valid.result), try operation.writeCompletionJSON(actual, &slot.?.state.completed));
            }
        }
    }
}

test "restarted deliveries repeat original chains after every interruption without a recovery journal" {
    const Boundary = enum { account_error, account_malformed, after_accounts, after_transfers, rejected_lookup, before_publish, lost_ack };
    for (std.enums.values(Boundary)) |boundary| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const original = try test_body_message(allocator, 1, execution_body);
        const event = try testEvent(allocator, &.{original});
        // These copies are assertions only. The restarted driver receives only original JSON.
        var original_accounts: [2]tigerbeetle.Account = undefined;
        var original_transfer: tigerbeetle.Transfer = undefined;
        {
            var invocation = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer invocation.deinit();
            var execution: FakeExecution = .{};
            switch (boundary) {
                .account_error => execution.account_errors[1] = error.LostReply,
                .account_malformed => execution.account_reply_count = 1,
                .after_accounts => execution.transfer_errors[0] = error.Interrupted,
                .after_transfers => execution.lookup_error = error.Interrupted,
                .rejected_lookup => {
                    execution.transfer_outcomes[0] = .{ .rejected = 21 };
                    execution.lookup_error = error.Interrupted;
                },
                .before_publish, .lost_ack => {},
            }
            var publisher: FakePublisher = .{};
            if (boundary == .before_publish) publisher.send_error = error.AmbiguousSend;
            const response = try handleInvocation(invocation.allocator(), event, ExecutionAdapter.init(&execution), CompletionPublisher.init(&publisher));
            try std.testing.expectEqualStrings(if (boundary == .lost_ack) "{\"batchItemFailures\":[]}" else "{\"batchItemFailures\":[{\"itemIdentifier\":\"message-0\"}]}", response);
            const phase_count: usize = switch (boundary) {
                .account_error, .account_malformed => 1,
                .after_accounts => 2,
                else => 3,
            };
            try std.testing.expectEqualSlices(Family, families[0..phase_count], execution.trace[0..execution.trace_count]);
            try std.testing.expectEqual(@as(u8, if (boundary == .before_publish or boundary == .lost_ack) 1 else 0), publisher.send_count);
            @memcpy(&original_accounts, execution.accounts[0..2]);
            if (phase_count > 1) original_transfer = execution.transfers[0];
        }
        var invocation = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer invocation.deinit();
        var execution: FakeExecution = .{};
        execution.account_outcomes[0] = .{ .rejected = tigerbeetle.account_exists };
        execution.account_outcomes[1] = .{ .rejected = tigerbeetle.account_linked_event_failed };
        execution.transfer_outcomes[0] = .{ .rejected = if (boundary == .rejected_lookup) 68 else tigerbeetle.transfer_exists };
        execution.lookup_count = 2;
        for (execution.lookup_results[0..2], 0..) |*account, i| {
            account.* = std.mem.zeroes(tigerbeetle.Account);
            account.id = i + 1;
            account.credits_posted = 70;
        }
        var publisher: FakePublisher = .{};
        const response = try handleInvocation(invocation.allocator(), event, ExecutionAdapter.init(&execution), CompletionPublisher.init(&publisher));
        try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
        try std.testing.expectEqualSlices(Family, &families, execution.trace[0..execution.trace_count]);
        for (original_accounts, execution.accounts[0..2]) |expected, actual| try std.testing.expectEqualDeep(expected, actual);
        if (boundary != .account_error and boundary != .account_malformed) try std.testing.expectEqualDeep(original_transfer, execution.transfers[0]);
        try std.testing.expectEqualSlices(u128, &.{ 2, 1 }, execution.lookup_ids[0..2]);
        const entry = (try test_results(invocation.allocator(), publisher.messages[0..publisher.send_count])).results[0].valid;
        try std.testing.expectEqual(@as(u128, 1), entry.operation_id);
        const payload = if (boundary == .rejected_lookup) entry.result.failure else entry.result.success;
        try std.testing.expect(!payload.object.contains("operation_id"));
        const transfers = payload.object.get("create_transfers").?.array.items;
        try std.testing.expectEqualStrings(if (boundary == .rejected_lookup) "id_already_failed" else "exists", transfers[0].object.get("error_code").?.string);
        const lookups = payload.object.get("lookup_accounts").?.array.items;
        try std.testing.expectEqualStrings("credit", lookups[0].object.get("alias").?.string);
        try std.testing.expectEqualStrings("70", lookups[0].object.get("account").?.object.get("credits_posted").?.string);
        // Exact complete bytes are checked against independently constructed typed outcomes.
        var expected_plan = (try test_plan(allocator, execution_body)).admitted;
        expected_plan.chains = .{ .accepted, if (boundary == .rejected_lookup) .rejected else .accepted };
        expected_plan.outcomes[0] = .{ .created = tigerbeetle.account_exists };
        expected_plan.outcomes[1] = .{ .created = tigerbeetle.account_linked_event_failed };
        expected_plan.outcomes[2] = .{ .created = if (boundary == .rejected_lookup) 68 else tigerbeetle.transfer_exists };
        expected_plan.outcomes[3] = .{ .found = execution.lookup_results[1] };
        expected_plan.outcomes[4] = .{ .found = execution.lookup_results[0] };
        const expected_buffer = try allocator.create([operation.result_size_max]u8);
        const actual_buffer = try allocator.create([operation.result_size_max]u8);
        try std.testing.expectEqualStrings(try write_result(expected_buffer, &expected_plan), try test_result_body(actual_buffer, &entry.result));
    }
}

test "repeated unresolved deliveries never manufacture exhaustion FAILURE" {
    for (0..5) |_| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var execution: FakeExecution = .{};
        execution.lookup_error = error.SyntheticTermination;
        var publisher: FakePublisher = .{};
        const response = try test_invoke(arena.allocator(), &.{execution_body}, &execution, &publisher);
        try std.testing.expectEqualSlices(Family, &families, execution.trace[0..execution.trace_count]);
        try std.testing.expectEqualStrings("{\"batchItemFailures\":[{\"itemIdentifier\":\"message-0\"}]}", response);
        try std.testing.expectEqual(@as(u8, 0), publisher.send_count);
    }
}

test "bounded individual publication preserves successful prefix after ambiguous send" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var queued: [3]processor_message.Message = undefined;
    var plans: [3]?Planning = undefined;
    for (&queued, &plans, 0..) |*entry, *plan, i| {
        const message = (parseRecord(allocator, "source", try test_body_message(allocator, i + 1, "true"))).valid;
        entry.* = message;
        plan.* = try plan_body(allocator, &entry.body);
    }
    const result = try allocator.create([operation.result_size_max]u8);
    const buffer = try allocator.alloc(u8, completion_buffer_size);
    const single_size = (try processor_message.frame(buffer, 1, write_diagnostic(result, &plans[0].?.rejected), null)).len;
    var retries = [_]bool{false} ** 3;
    var publisher: SerialPublisher = .{ .fail_at = 1, .ambiguous = true };
    publish_results(allocator, &queued, &plans, &.{ 0, 1, 2 }, &retries, result, buffer[0..single_size], CompletionPublisher.init(&publisher));
    try std.testing.expectEqualSlices(bool, &.{ false, true, true }, &retries);
    try std.testing.expectEqual(@as(usize, 2), publisher.calls);
    for (publisher.messages[0..2], 0..) |message, i| {
        try std.testing.expectEqual(single_size, message.len);
        const batch = try test_results(allocator, &.{message});
        try std.testing.expectEqual(@as(usize, 1), batch.results.len);
        try std.testing.expectEqual(@as(u128, i + 1), batch.results[0].valid.operation_id);
    }
}

test "redelivery regroups only intact original chains after a lost shared reply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const original = try test_body_message(allocator, 17, execution_body);
    const neighbor = try test_body_message(allocator, 18, "{\"create_accounts\":[{\"id\":\"9\",\"flags\":0,\"ledger\":1,\"code\":1}]}");
    {
        var first = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer first.deinit();
        var execution: FakeExecution = .{ .account_reply_count = 0 };
        var publisher: FakePublisher = .{};
        const response = try handleInvocation(first.allocator(), try testEvent(first.allocator(), &.{ original, neighbor }), ExecutionAdapter.init(&execution), CompletionPublisher.init(&publisher));
        try std.testing.expectEqualStrings("{\"batchItemFailures\":[{\"itemIdentifier\":\"message-0\"},{\"itemIdentifier\":\"message-1\"}]}", response);
        try std.testing.expectEqualSlices(Family, &.{.create_accounts}, execution.trace[0..execution.trace_count]);
        try std.testing.expectEqual(@as(usize, 3), execution.account_count);
        try std.testing.expectEqual(@as(u8, 0), publisher.send_count);
    }
    const different_neighbor = try test_body_message(allocator, 19, "{\"create_accounts\":[{\"id\":\"10\",\"flags\":0,\"ledger\":1,\"code\":1}]}");
    var execution: FakeExecution = .{};
    execution.account_outcomes[1] = .{ .rejected = tigerbeetle.account_exists };
    execution.account_outcomes[2] = .{ .rejected = tigerbeetle.account_linked_event_failed };
    var publisher: FakePublisher = .{};
    const response = try handleInvocation(allocator, try testEvent(allocator, &.{ different_neighbor, original }), ExecutionAdapter.init(&execution), CompletionPublisher.init(&publisher));
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
    try std.testing.expectEqualSlices(Family, &families, execution.trace[0..execution.trace_count]);
    for ([_]u128{ 10, 1, 2 }, execution.accounts[0..3], [_]u16{ 0, tigerbeetle.account_linked, 0 }) |id, account, flags| {
        try std.testing.expectEqual(id, account.id);
        try std.testing.expectEqual(flags, account.flags);
    }
    const batch = try test_results(allocator, publisher.messages[0..publisher.send_count]);
    try std.testing.expectEqual(@as(u128, 19), batch.results[0].valid.operation_id);
    try std.testing.expectEqual(@as(u128, 17), batch.results[1].valid.operation_id);
    try std.testing.expectEqualStrings("exists", batch.results[1].valid.result.failure.object.get("create_accounts").?.array.items[0].object.get("error_code").?.string);
}

test "pending resolution replay retains original timeout amount and inheritance sentinels" {
    const modes = [_]struct { flags: u16, amount: []const u8, parsed_amount: u128 }{
        .{ .flags = 4, .amount = "340282366920938463463374607431768211455", .parsed_amount = std.math.maxInt(u128) },
        .{ .flags = 8, .amount = "0", .parsed_amount = 0 },
        .{ .flags = 8, .amount = "10", .parsed_amount = 10 },
    };
    for (modes) |mode| {
        for (0..2) |attempt| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const body = try std.fmt.allocPrint(
                arena.allocator(),
                "{{\"create_transfers\":[{{\"id\":\"3\",\"flags\":2,\"debit_account_id\":\"1\",\"credit_account_id\":\"2\",\"amount\":\"10\",\"ledger\":1,\"code\":1,\"timeout\":7}},{{\"id\":\"4\",\"flags\":{d},\"pending_id\":\"3\",\"amount\":\"{s}\"}}]}}",
                .{ mode.flags, mode.amount },
            );
            var execution: FakeExecution = .{};
            if (attempt == 1) {
                execution.transfer_outcomes[0] = .{ .rejected = tigerbeetle.transfer_exists };
                execution.transfer_outcomes[1] = .{ .rejected = tigerbeetle.transfer_linked_event_failed };
            }
            var publisher: FakePublisher = .{ .send_error = if (attempt == 0) error.AmbiguousSend else null };
            const response = try test_invoke(arena.allocator(), &.{body}, &execution, &publisher);
            try std.testing.expectEqualStrings(if (attempt == 0) "{\"batchItemFailures\":[{\"itemIdentifier\":\"message-0\"}]}" else "{\"batchItemFailures\":[]}", response);
            try std.testing.expectEqualSlices(Family, &.{.create_transfers}, execution.trace[0..execution.trace_count]);
            const pending = execution.transfers[0];
            const post = execution.transfers[1];
            try std.testing.expectEqual(@as(u128, 3), pending.id);
            try std.testing.expectEqual(@as(u32, 7), pending.timeout);
            try std.testing.expectEqual(@as(u16, 3), pending.flags);
            try std.testing.expectEqual(@as(u128, 4), post.id);
            try std.testing.expectEqual(@as(u128, 3), post.pending_id);
            try std.testing.expectEqual(mode.parsed_amount, post.amount);
            try std.testing.expectEqual(@as(u128, 0), post.debit_account_id);
            try std.testing.expectEqual(@as(u128, 0), post.credit_account_id);
            try std.testing.expectEqual(@as(u32, 0), post.ledger);
            try std.testing.expectEqual(@as(u16, 0), post.code);
            try std.testing.expectEqual(@as(u32, 0), post.timeout);
            try std.testing.expectEqual(mode.flags, post.flags);
            const result = (try test_results(arena.allocator(), publisher.messages[0..publisher.send_count])).results[0].valid.result;
            try std.testing.expect(result == .success);
        }
    }
}

test "response allocation failure after successful publication leaves safe whole invocation redelivery" {
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    const event = try testEvent(outer.allocator(), &.{try test_body_message(outer.allocator(), 1, execution_body)});
    var after_send: usize = 0;
    var before_send: usize = 0;
    var reached_success = false;
    // Fail logical allocations above the arena, including a response that fits an existing chunk.
    for (0..1000) |fail_index| {
        var invocation = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer invocation.deinit();
        var failing = std.testing.FailingAllocator.init(invocation.allocator(), .{ .fail_index = fail_index });
        var execution: FakeExecution = .{};
        var publisher: FakePublisher = .{};
        const response = handleInvocation(failing.allocator(), event, ExecutionAdapter.init(&execution), CompletionPublisher.init(&publisher)) catch |err| {
            // Allocating JSON writers report allocation failure as WriteFailed.
            try std.testing.expect(err == error.OutOfMemory or err == error.WriteFailed);
            if (publisher.send_count == 1) {
                try std.testing.expectEqualSlices(Family, &families, execution.trace[0..execution.trace_count]);
                after_send += 1;
            } else before_send += 1;
            continue;
        };
        try std.testing.expectEqualStrings(if (publisher.send_count == 1)
            "{\"batchItemFailures\":[]}"
        else
            "{\"batchItemFailures\":[{\"itemIdentifier\":\"message-0\"}]}", response);
        if (!failing.has_induced_failure) {
            reached_success = true;
            break;
        }
    }
    try std.testing.expect(reached_success);
    try std.testing.expect(before_send > 0);
    try std.testing.expect(after_send > 0);
}

test "internal route overrides publication destination while outgoing route is absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const input = "{\"operation_id\":\"00112233-4455-6677-8899-aabbccddeeff\",\"body\":true,\"result_queue\":\"https://sqs.example.invalid/next\"}";
    var execution: FakeExecution = .{};
    var publisher: FakePublisher = .{};
    const response = try handleInvocation(allocator, try testEvent(allocator, &.{input}), ExecutionAdapter.init(&execution), CompletionPublisher.init(&publisher));
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
    try std.testing.expectEqual(@as(u8, 1), publisher.send_count);
    try std.testing.expectEqualStrings("https://sqs.example.invalid/next", publisher.routes[0].?);
    const result = try processor_message.decode(allocator, publisher.messages[0]);
    try std.testing.expect(result.result_queue == null);
    try std.testing.expect(result.body.object.contains("error"));
    try std.testing.expect(!result.body.object.contains("type"));
    try std.testing.expect(!result.body.object.contains("payload"));
}

// Tests observe separately published messages through the actual codec and final interpreter.
const TestResults = struct {
    results: []const struct { valid: struct { operation_id: u128, result: operation.Completion } },
};
fn test_results(allocator: Allocator, messages: []const []const u8) !TestResults {
    const results = try allocator.alloc(@typeInfo(@TypeOf(@as(TestResults, undefined).results)).pointer.child, messages.len);
    for (messages, results) |bytes, *entry| {
        const message = try processor_message.decode(allocator, bytes);
        entry.* = .{ .valid = .{
            .operation_id = message.operation_id,
            .result = try @import("tiger_beetle_completion_processor").test_support.interpret(&message.body),
        } };
    }
    return .{ .results = results };
}
fn test_interpret_body(allocator: Allocator, bytes: []const u8) !operation.Completion {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{});
    return @import("tiger_beetle_completion_processor").test_support.interpret(&value);
}
fn test_result_body(buffer: []u8, result: *const operation.Completion) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    const body = switch (result.*) {
        .success, .failure => |value| value,
    };
    try std.json.Stringify.value(body, .{}, &writer);
    return writer.buffered();
}
fn test_stored_operation(allocator: Allocator, message: *const processor_message.Message) !operation.Operation {
    _ = allocator;
    return .{ .id = message.operation_id, .tenant = "tenant-a", .name = "test", .body = null, .state = .submitted, .last_updated = 1700000000, .expires_at = 1700086400, .hash = try operation.operationHash("tenant-a", "test", &message.body) };
}

test "internal Body above public intake cap reaches admission and missing route uses default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const text = try allocator.alloc(u8, processor_message.body_size_max - 2);
    @memset(text, 'x');
    const input = try processor_message.encode(allocator, &.{ .operation_id = 1, .body = .{ .string = text } });
    var execution: FakeExecution = .{};
    var publisher: FakePublisher = .{};
    const response = try handleInvocation(allocator, try testEvent(allocator, &.{input}), ExecutionAdapter.init(&execution), CompletionPublisher.init(&publisher));
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
    try std.testing.expectEqual(@as(u8, 1), publisher.send_count);
    try std.testing.expect(publisher.routes[0] == null);
    try std.testing.expectEqual(@as(usize, 0), execution.trace_count);
    const output = try processor_message.decode(allocator, publisher.messages[0]);
    try std.testing.expectEqualStrings("Expected a Body object.", output.body.object.get("error").?.object.get("message").?.string);
}

test "large internal command diagnostic preserves its prefix within the output bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var body = std.Io.Writer.Allocating.init(allocator);
    try body.writer.writeAll("{\"lookup_accounts\":[");
    for (0..5000) |index| {
        if (index > 0) try body.writer.writeByte(',');
        try body.writer.print("{{\"id\":\"{d}\"}}", .{index + 1});
    }
    try body.writer.writeAll(",{\"id\":\"5001\",\"alias\":null}]}");
    try std.testing.expect(body.written().len > operation.body_size_max);
    try std.testing.expect(body.written().len <= processor_message.body_size_max);
    var execution: FakeExecution = .{};
    var publisher: FakePublisher = .{};
    const response = try test_invoke(allocator, &.{body.written()}, &execution, &publisher);
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", response);
    try std.testing.expectEqual(@as(usize, 0), execution.trace_count);
    const message = try processor_message.decode(allocator, publisher.messages[0]);
    const entries = message.body.object.get("lookup_accounts").?.array.items;
    try std.testing.expectEqual(@as(usize, 5001), entries.len);
    for (entries[0..5000]) |entry| try std.testing.expect(entry == .null);
    try std.testing.expectEqualStrings("alias", entries[5000].object.get("field").?.string);
    // The final consumer can wrap the entire diagnostic without losing its prefix.
    const result = try @import("tiger_beetle_completion_processor").test_support.interpret(&message.body);
    try std.testing.expect(result == .failure);
    try std.testing.expect((try operation.completionEncodedSize(&result)) <= operation.result_size_max);
}
