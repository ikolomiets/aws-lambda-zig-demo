const std = @import("std");
const dynamodb = @import("dynamodb");
const operation = @import("operation");
const operations = @import("operation_persistence");
const messages = @import("processor_message");
const seat = @import("seat_reservation");
const events = @import("seat_reservation_persistence");
const intake = @import("intake_lambda");
const query = @import("query_lambda");
const completion = @import("seat_reservation_completion_processor");
const submission = @import("seat_reservation_processor");
const native = @import("tiger_beetle_processor");
const tigerbeetle = @import("tigerbeetle");
const c = @import("tigerbeetle_c");
const Allocator = std.mem.Allocator;
const uuid = "00000000-0000-0000-0000-000000000001";
const request = "{\"id\":\"" ++ uuid ++ "\",\"name\":\"SeatReservation\",\"body\":{" ++
    "\"command\":\"reserve_seats\",\"event_id\":\"00000000-0000-0000-0000-000000000002\"," ++
    "\"class\":\"general\",\"quantity\":2}}";
const ack = "{\"batchItemFailures\":[]}";

test "warm seat handlers reuse ready metadata across arenas and observe fresh balances" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    var effects = try ready_check_effects(storage.allocator());
    var admission_cache: events.ReadyCache = undefined;
    try admission_cache.init(std.testing.allocator, events.ReadyCache.budget_bytes_max);
    defer admission_cache.deinit();
    var completion_cache: events.ReadyCache = undefined;
    try completion_cache.init(std.testing.allocator, events.ReadyCache.budget_bytes_max);
    defer completion_cache.deinit();
    // Every invocation releases its own arena; only process-owned resources survive.
    for (0..3) |index| {
        var request_storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer request_storage.deinit();
        const arena = request_storage.allocator();
        if (index == 2) @constCast(&effects.lookup_accounts[0]).debits_pending = 5;
        const result = try cached_check_cycle(
            arena,
            &effects,
            &admission_cache,
            &completion_cache,
            index + 10,
        );
        const expected = if (index == 2)
            "{\"type\":\"SUCCESS\",\"payload\":{\"event_id\":\"00000000-0000-" ++
                "0000-0000-000000000002\",\"classes\":{\"general\":{\"total\":10,\"available\":5}}}}"
        else
            "{\"type\":\"SUCCESS\",\"payload\":{\"event_id\":\"00000000-0000-" ++
                "0000-0000-000000000002\",\"classes\":{\"general\":{\"total\":10,\"available\":10}}}}";
        try std.testing.expectEqualStrings(expected, result);
        try std.testing.expectEqual(@as(usize, 2), effects.event_reads);
    }
}

fn cached_check_cycle(
    arena: Allocator,
    effects: *Effects,
    admission_cache: *events.ReadyCache,
    completion_cache: *events.ReadyCache,
    operation_id: u128,
) ![]const u8 {
    const input = try std.fmt.allocPrint(
        arena,
        "{{\"id\":\"{s}\",\"name\":\"SeatReservation\",\"body\":{s}}}",
        .{ try seat.uuid_text(arena, operation_id), check_body },
    );
    const first = effects.sent.items.len;
    _ = try intake.test_support.submit(arena, &.{
        .input = input,
        .subject = "theatre",
        .operation_name = "SeatReservation",
    }, effects);
    try std.testing.expectEqualStrings(ack, try submission.handle_invocation(
        arena,
        try sqs_event(arena, effects.sent.items[first].body),
        &.{
            .events_table = "Events",
            .completion_queue = "seat-completion",
            .native_queue = "native",
            .ready_cache = admission_cache,
        },
        effects,
    ));
    try std.testing.expectEqualStrings(ack, try native.test_support.invoke(
        arena,
        try sqs_event(arena, effects.sent.items[first + 1].body),
        effects,
    ));
    try std.testing.expectEqualStrings(ack, try completion.handle_invocation(
        arena,
        try sqs_event(arena, effects.sent.items[first + 2].body),
        &.{
            .operations_table = "Operations",
            .now = 100,
            .ready_cache = completion_cache,
        },
        effects,
    ));
    const visible = try query.test_support.query_with_backend(arena, operation_id, "theatre", effects);
    try std.testing.expect(std.mem.indexOf(u8, visible, "available") != null);
    const saved = try effects.read(arena, operation_id);
    const buffer = try arena.create([operation.result_size_max]u8);
    return operation.writeCompletionJSON(buffer, &saved.state.completed);
}

test "warm submission observes uncached absence and readiness before disclosing classes" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var effects = try Effects.init(arena);
    const saved = effects.event;
    var cache: events.ReadyCache = undefined;
    try cache.init(std.testing.allocator, events.ReadyCache.budget_bytes_max);
    defer cache.deinit();
    const expected_reads = [_]usize{ 1, 2, 3, 3, 4, 5 };
    for ([_][]const u8{
        "event_unavailable", "event_not_ready",   "unknown_class",
        "unknown_class",     "event_unavailable", "event_unavailable",
    }, 0..) |expected, index| {
        if (index == 0) effects.event = null;
        if (index == 1) effects.event = saved;
        if (index == 2) effects.event.?.state = .ready;
        var request_storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer request_storage.deinit();
        const request_arena = request_storage.allocator();
        const input = try std.fmt.allocPrint(
            request_arena,
            "{{\"id\":\"{s}\",\"name\":\"SeatReservation\",\"body\":{{" ++
                "\"command\":\"reserve_seats\",\"event_id\":\"00000000-0000-" ++
                "0000-0000-000000000002\",\"class\":\"absent\",\"quantity\":1}}}}",
            .{try seat.uuid_text(request_arena, index + 10)},
        );
        const first = effects.sent.items.len;
        _ = try intake.test_support.submit(request_arena, &.{
            .input = input,
            .subject = if (index >= 4) "foreign" else "theatre",
            .operation_name = "SeatReservation",
        }, &effects);
        try std.testing.expectEqualStrings(ack, try submission.handle_invocation(
            request_arena,
            try sqs_event(request_arena, effects.sent.items[first].body),
            &.{
                .events_table = "Events",
                .completion_queue = "seat-completion",
                .ready_cache = &cache,
            },
            &effects,
        ));
        const rejection = try messages.decode(request_arena, effects.sent.items[first + 1].body);
        try std.testing.expectEqualStrings(expected, rejection.body.object.get("code").?.string);
        try std.testing.expectEqual(expected_reads[index], effects.event_reads);
    }
    try std.testing.expectEqual(@as(usize, 0), effects.updates);
    try std.testing.expectEqual(@as(u128, 100), effects.next_id);
}

test "warm completion observes uncached state transitions and rejects foreign cache reuse" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var effects = try ready_check_effects(arena);
    const output = try check_output(arena, &effects);
    const saved = effects.event;
    var cache: events.ReadyCache = undefined;
    try cache.init(std.testing.allocator, events.ReadyCache.budget_bytes_max);
    defer cache.deinit();
    for (0..4) |index| {
        if (index == 0) effects.event = null;
        if (index == 1) {
            effects.event = saved;
            effects.event.?.state = .creating;
        }
        if (index == 2) effects.event.?.state = .ready;
        var request_storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer request_storage.deinit();
        const request_arena = request_storage.allocator();
        try std.testing.expectEqualStrings(ack, try completion.handle_invocation(
            request_arena,
            try sqs_event(request_arena, output),
            &.{ .operations_table = "Operations", .now = 100, .ready_cache = &cache },
            &effects,
        ));
        try std.testing.expectEqual(@as(usize, @min(index + 2, 4)), effects.event_reads);
        const operation_saved = try effects.read(request_arena, 1);
        try std.testing.expectEqual(index >= 2, operation_saved.state == .completed);
    }
    var foreign = try messages.decode(arena, output);
    foreign.tenant = "foreign";
    const updates = effects.updates;
    try std.testing.expectEqualStrings(ack, try completion.handle_invocation(
        arena,
        try sqs_event(arena, try messages.encode(arena, &foreign)),
        &.{ .operations_table = "Operations", .now = 100, .ready_cache = &cache },
        &effects,
    ));
    try std.testing.expectEqual(updates, effects.updates);
    try std.testing.expectEqual(@as(usize, 5), effects.event_reads);
    try std.testing.expectEqual(@as(usize, 3), effects.diagnostics.items.len);
}

const confirm_request = "{\"id\":\"" ++ uuid ++ "\",\"name\":\"SeatReservation\",\"body\":{" ++
    "\"command\":\"confirm_seats\",\"event_id\":\"00000000-0000-0000-0000-000000000002\"," ++
    "\"class\":\"general\",\"pending_id\":\"77\"}}";

fn confirm_output(arena: Allocator, effects: *Effects) ![]const u8 {
    const first = effects.sent.items.len;
    _ = try intake.test_support.submit(arena, &.{
        .input = confirm_request,
        .subject = "theatre",
        .operation_name = "SeatReservation",
    }, effects);
    return native_attempt(arena, effects, effects.sent.items[first].body);
}

test "authenticated confirmation posts the whole matching hold and returns its pending ID" {
    for ([_]u32{
        tigerbeetle.transfer_created,
        tigerbeetle.transfer_exists,
        c.TB_CREATE_TRANSFER_PENDING_TRANSFER_ALREADY_POSTED,
    }) |status| {
        var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer storage.deinit();
        const arena = storage.allocator();
        var effects = try Effects.init(arena);
        effects.event.?.state = .ready;
        effects.transfer_statuses = &.{status};
        const output = try confirm_output(arena, &effects);
        const message = try messages.decode(arena, output);
        try std.testing.expectEqualStrings("77", message.context.object.get("pending_id").?.string);
        try std.testing.expectEqual(@as(u32, 4), message.context.object.count());
        const posting = effects.transfers[0];
        try std.testing.expectEqual(@as(u128, 101), posting.id);
        try std.testing.expectEqual(@as(u128, 77), posting.pending_id);
        try std.testing.expectEqual(@as(u128, 13), posting.debit_account_id);
        try std.testing.expectEqual(@as(u128, 12), posting.credit_account_id);
        try std.testing.expectEqual(std.math.maxInt(u128), posting.amount);
        try std.testing.expectEqual(@as(u32, 1001), posting.ledger);
        try std.testing.expectEqual(@as(u16, 2), posting.code);
        try std.testing.expectEqual(@as(u16, c.TB_TRANSFER_POST_PENDING_TRANSFER), posting.flags);
        try std.testing.expectEqual(@as(u32, 0), posting.timeout);
        try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, output));
        const saved = try effects.read(arena, 1);
        var buffer: [operation.result_size_max]u8 = undefined;
        try std.testing.expectEqualStrings(
            "{\"type\":\"SUCCESS\",\"payload\":{\"event_id\":" ++
                "\"00000000-0000-0000-0000-000000000002\",\"class\":\"general\"," ++
                "\"reservation_id\":\"77\"}}",
            try operation.writeCompletionJSON(&buffer, &saved.state.completed),
        );
        const visible = try query.test_support.query_with_backend(arena, 1, "theatre", &effects);
        try std.testing.expect(std.mem.indexOf(u8, visible, "reservation_id") != null);
        const foreign = try query.test_support.query_with_backend(arena, 1, "other", &effects);
        try std.testing.expect(std.mem.indexOf(u8, foreign, "reservation_id") == null);
        try std.testing.expectEqual(@as(usize, 0), effects.transactions);
        try std.testing.expectEqual(@as(u32, 1000), effects.high_water);
        try std.testing.expectEqual(seat.EventState.ready, effects.event.?.state);
    }
}

test "confirmation replay and a fresh already posted attempt keep the original reservation ID" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var effects = try Effects.init(arena);
    effects.event.?.state = .ready;
    _ = try confirm_output(arena, &effects);
    const posting = effects.transfers[0];
    effects.transfer_statuses = &.{tigerbeetle.transfer_exists};
    try std.testing.expectEqualStrings(ack, try native.test_support.invoke(
        arena,
        try sqs_event(arena, effects.sent.items[1].body),
        &effects,
    ));
    try std.testing.expectEqualDeep(posting, effects.transfers[0]);
    try std.testing.expectEqualStrings(ack, try complete_seat_message(
        arena,
        &effects,
        effects.sent.items[3].body,
    ));
    try std.testing.expectEqual(@as(usize, 0), effects.diagnostics.items.len);
    effects.transfer_statuses = &.{c.TB_CREATE_TRANSFER_PENDING_TRANSFER_ALREADY_POSTED};
    const fresh = try native_attempt(arena, &effects, effects.sent.items[0].body);
    try std.testing.expectEqual(@as(u128, 102), effects.transfers[0].id);
    try std.testing.expectEqual(@as(u128, 77), effects.transfers[0].pending_id);
    const before = effects.diagnostics.items.len;
    try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, fresh));
    try std.testing.expectEqual(before, effects.diagnostics.items.len);
    const saved = try effects.read(arena, 1);
    try std.testing.expectEqualStrings(
        "77",
        saved.state.completed.success.object.get("reservation_id").?.string,
    );
}

test "confirmation returns bounded expired invalid and definite rejection outcomes" {
    const cases = .{
        .{ c.TB_CREATE_TRANSFER_PENDING_TRANSFER_EXPIRED, "reservation_expired" },
        .{ c.TB_CREATE_TRANSFER_PENDING_TRANSFER_NOT_FOUND, "invalid_reservation" },
        .{ c.TB_CREATE_TRANSFER_PENDING_TRANSFER_NOT_PENDING, "invalid_reservation" },
        .{
            c.TB_CREATE_TRANSFER_PENDING_TRANSFER_HAS_DIFFERENT_DEBIT_ACCOUNT_ID,
            "invalid_reservation",
        },
        .{
            c.TB_CREATE_TRANSFER_PENDING_TRANSFER_HAS_DIFFERENT_CREDIT_ACCOUNT_ID,
            "invalid_reservation",
        },
        .{ c.TB_CREATE_TRANSFER_PENDING_TRANSFER_HAS_DIFFERENT_LEDGER, "invalid_reservation" },
        .{ c.TB_CREATE_TRANSFER_PENDING_TRANSFER_HAS_DIFFERENT_CODE, "invalid_reservation" },
        .{ c.TB_CREATE_TRANSFER_PENDING_TRANSFER_ALREADY_VOIDED, "operation_rejected" },
        .{ c.TB_CREATE_TRANSFER_ID_ALREADY_FAILED, "operation_rejected" },
    };
    inline for (cases) |case| {
        var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer storage.deinit();
        const arena = storage.allocator();
        var effects = try Effects.init(arena);
        effects.event.?.state = .ready;
        effects.transfer_statuses = &.{case[0]};
        const output = try confirm_output(arena, &effects);
        try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, output));
        const saved = try effects.read(arena, 1);
        try std.testing.expect(saved.state == .completed);
        var buffer: [operation.result_size_max]u8 = undefined;
        try std.testing.expectEqualStrings(
            "{\"type\":\"FAILURE\",\"payload\":{\"code\":\"" ++ case[1] ++ "\"}}",
            try operation.writeCompletionJSON(&buffer, &saved.state.completed),
        );
        const visible = try query.test_support.query_with_backend(arena, 1, "theatre", &effects);
        try std.testing.expect(std.mem.indexOf(u8, visible, case[1]) != null);
        try std.testing.expectEqual(@as(usize, 0), effects.diagnostics.items.len);
        try std.testing.expectEqual(seat.EventState.ready, effects.event.?.state);
    }
}

const inconsistent_confirmation_statuses = [_][]const u8{
    "linked_event_failed",
    "linked_event_chain_open",
    "unknown",
    "new_status",
    "exists_with_different_flags",
    "exists_with_different_pending_id",
    "exists_with_different_debit_account_id",
    "exists_with_different_credit_account_id",
    "exists_with_different_ledger",
    "exists_with_different_code",
    "exists_with_different_amount",
    "exists_with_different_timeout",
    "debit_account_not_found",
    "credit_account_not_found",
    "debit_account_already_closed",
    "credit_account_already_closed",
    "accounts_must_have_the_same_ledger",
    "transfer_must_have_the_same_ledger_as_accounts",
    "ledger_must_not_be_zero",
    "code_must_not_be_zero",
    "flags_are_mutually_exclusive",
    "pending_id_must_be_different",
    "timeout_reserved_for_pending_transfer",
    "exceeds_pending_transfer_amount",
    "pending_transfer_has_different_amount",
    "overflows_debits_posted",
    "overflows_credits_posted",
    "exceeds_credits",
    "exceeds_debits",
};

test "confirmation rejects incomplete conflicting and inconclusive evidence without a Result" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var effects = try Effects.init(arena);
    effects.event.?.state = .ready;
    const output = try confirm_output(arena, &effects);
    const entries = [_][]const u8{
        "[]",
        "[null]",
        "[{}]",
        "[{\"error_code\":null,\"alias\":\"confirm-general\"}]",
        "[{\"error_code\":\"created\",\"alias\":\"wrong\"}]",
        "[{\"error_code\":\"created\",\"alias\":\"confirm-general\",\"id\":\"101\"}]",
        "[{\"error_code\":\"created\",\"alias\":\"confirm-general\"}," ++
            "{\"error_code\":\"pending_transfer_expired\",\"alias\":\"confirm-general\"}]",
    };
    for (entries) |entry| {
        var message = try messages.decode(arena, output);
        message.body = try seat.parse_value(arena, try std.fmt.allocPrint(
            arena,
            "{{\"create_accounts\":[],\"create_transfers\":{s},\"lookup_accounts\":[]}}",
            .{entry},
        ), messages.body_size_max);
        try expect_invalid_reservation(arena, &effects, &message);
    }
    for (inconsistent_confirmation_statuses) |status| {
        var message = try messages.decode(arena, output);
        const entry = &message.body.object.getPtr("create_transfers").?.array.items[0];
        try entry.object.put(arena, "error_code", .{ .string = status });
        try expect_invalid_reservation(arena, &effects, &message);
    }
    for ([_][]const u8{ "create_accounts", "lookup_accounts" }) |family| {
        var message = try messages.decode(arena, output);
        try message.body.object.getPtr(family).?.array.append(.null);
        try expect_invalid_reservation(arena, &effects, &message);
    }
    for ([_][]const u8{ "command", "pending_id", "class", "event_id" }) |field| {
        var message = try messages.decode(arena, output);
        _ = message.context.object.orderedRemove(field);
        try expect_invalid_reservation(arena, &effects, &message);
    }
    var message = try messages.decode(arena, output);
    try message.context.object.put(arena, "posting_id", .{ .string = "101" });
    try expect_invalid_reservation(arena, &effects, &message);
    message = try messages.decode(arena, output);
    message.body = try seat.parse_value(arena, "{\"error\":\"ResponseLost\"}", 4096);
    try expect_invalid_reservation(arena, &effects, &message);
    try std.testing.expectEqual(@as(usize, 0), effects.updates);
}

test "confirmation authorizes ownership readiness and class before generating native work" {
    const expected = [_][]const u8{
        "event_unavailable",
        "event_unavailable",
        "event_not_ready",
        "event_failed",
        "unknown_class",
    };
    for (expected, 0..) |code, scenario| {
        var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer storage.deinit();
        const arena = storage.allocator();
        var effects = try Effects.init(arena);
        switch (scenario) {
            0 => effects.event = null,
            1 => effects.event.?.tenant = "foreign",
            2 => effects.event.?.state = .creating,
            3 => effects.event.?.state = .failed,
            4 => effects.event.?.state = .ready,
            else => unreachable,
        }
        const output = try submitted_rejection(
            arena,
            &effects,
            "{\"command\":\"confirm_seats\",\"event_id\":" ++
                "\"00000000-0000-0000-0000-000000000002\"," ++
                "\"class\":\"nonexistent\",\"pending_id\":\"77\"}",
        );
        try std.testing.expectEqualStrings("seat-completion", effects.sent.items[1].queue);
        try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, output));
        const saved = try effects.read(arena, 1);
        try std.testing.expectEqualStrings(
            code,
            saved.state.completed.failure.object.get("code").?.string,
        );
        const visible = try query.test_support.query_with_backend(arena, 1, "theatre", &effects);
        try std.testing.expect(std.mem.indexOf(u8, visible, code) != null);
        try std.testing.expectEqual(@as(u128, 100), effects.next_id);
        try std.testing.expectEqual(@as(u32, 1000), effects.high_water);
        try std.testing.expectEqual(@as(usize, 2), effects.sent.items.len);
    }
}

test "confirmation schema rejects non scalar and caller controlled native fields before reads" {
    const invalid_fields = .{
        .{ "class", "[\"general\"]" },
        .{ "class", "{\"general\":1}" },
        .{ "class", "null" },
        .{ "pending_id", "77" },
        .{ "pending_id", "\"077\"" },
        .{ "pending_id", "\"0\"" },
        .{ "pending_id", "\"340282366920938463463374607431768211455\"" },
        .{ "pending_id", "null" },
        .{ "event_id", "\"bad\"" },
        .{ "quantity", "2" },
        .{ "ledger", "1001" },
        .{ "tenant", "\"foreign\"" },
        .{ "debit_account_id", "\"13\"" },
        .{ "posting_id", "\"101\"" },
    };
    inline for (invalid_fields) |invalid| {
        var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer storage.deinit();
        const arena = storage.allocator();
        var effects = try Effects.init(arena);
        var input = try seat.parse_value(arena, confirm_request, 4096);
        const body = input.object.getPtr("body").?;
        try body.object.put(arena, invalid[0], try seat.parse_value(arena, invalid[1], 4096));
        effects.read_error = error.MustNotRead;
        const output = try submitted_rejection(
            arena,
            &effects,
            try seat.encode_bounded(arena, body.*, 4096),
        );
        effects.read_error = null;
        try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, output));
        const saved = try effects.read(arena, 1);
        try std.testing.expectEqualStrings(
            "invalid_request",
            saved.state.completed.failure.object.get("code").?.string,
        );
        try std.testing.expectEqual(@as(u128, 100), effects.next_id);
        try std.testing.expectEqual(@as(u32, 1000), effects.high_water);
        try std.testing.expectEqual(@as(usize, 2), effects.sent.items.len);
    }
}

fn expect_native_retry_after_restart(arena: Allocator, effects: *Effects, work: []const u8) !void {
    var invocation = std.heap.ArenaAllocator.init(arena);
    defer invocation.deinit();
    const response = try native.test_support.invoke(
        invocation.allocator(),
        try sqs_event(arena, work),
        effects,
    );
    try std.testing.expect(std.mem.indexOf(u8, response, "source-1") != null);
}

test "confirmation uncertainty retains source retry eligibility" {
    for ([_]bool{ false, true }) |after_effect| {
        var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer storage.deinit();
        const arena = storage.allocator();
        var effects = try Effects.init(arena);
        effects.event.?.state = .ready;
        _ = try intake.test_support.submit(arena, &.{
            .input = confirm_request,
            .subject = "theatre",
            .operation_name = "SeatReservation",
        }, &effects);
        const source = effects.sent.items[0].body;
        effects.send_error = error.ResponseLost;
        effects.send_before_error = after_effect;
        {
            var invocation = std.heap.ArenaAllocator.init(arena);
            defer invocation.deinit();
            const response = try submission.handle_invocation(
                invocation.allocator(),
                try sqs_event(arena, source),
                &.{
                    .events_table = "Events",
                    .native_queue = "native",
                    .completion_queue = "seat-completion",
                },
                &effects,
            );
            try std.testing.expect(std.mem.indexOf(u8, response, "source-1") != null);
        }
        effects.send_error = null;
        const work_index = effects.sent.items.len;
        // Retry constructs a fresh posting even when the first send may have succeeded.
        const output = try native_attempt(arena, &effects, source);
        const work = effects.sent.items[work_index].body;
        try std.testing.expectEqual(@as(u128, 102), effects.transfers[0].id);
        effects.native_funding_error = error.ResponseLost;
        effects.native_transfer_before_error = after_effect;
        try expect_native_retry_after_restart(arena, &effects, work);
        effects.native_funding_error = null;
        effects.transfer_statuses = &.{c.TB_CREATE_TRANSFER_PENDING_TRANSFER_ALREADY_POSTED};
        effects.native_send_error = error.ResponseLost;
        effects.native_send_before_error = after_effect;
        try expect_native_retry_after_restart(arena, &effects, work);
        effects.native_send_error = null;
        const completion_index = effects.sent.items.len;
        try std.testing.expectEqualStrings(ack, try native.test_support.invoke(
            arena,
            try sqs_event(arena, work),
            &effects,
        ));
        const repeated = effects.sent.items[completion_index].body;
        effects.write_error = error.ResponseLost;
        effects.commit_before_error = after_effect;
        const response = try complete_seat_message(arena, &effects, repeated);
        try std.testing.expectEqual(after_effect, std.mem.eql(u8, ack, response));
        effects.write_error = null;
        try std.testing.expectEqualStrings(ack, try complete_seat_message(
            arena,
            &effects,
            repeated,
        ));
        const winner = effects.operation_item.?;
        try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, output));
        try std.testing.expectEqual(winner.ptr, effects.operation_item.?.ptr);
        try std.testing.expectEqual(@as(usize, 0), effects.diagnostics.items.len);
    }
}

test "confirmation keeps the first valid success or failure across competing completions" {
    for ([_]bool{ false, true }) |failure_first| {
        var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer storage.deinit();
        const arena = storage.allocator();
        var effects = try Effects.init(arena);
        effects.event.?.state = .ready;
        const success = try confirm_output(arena, &effects);
        effects.transfer_statuses = &.{c.TB_CREATE_TRANSFER_PENDING_TRANSFER_EXPIRED};
        const failure = try native_attempt(arena, &effects, effects.sent.items[0].body);
        const first = if (failure_first) failure else success;
        const later = if (failure_first) success else failure;
        try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, first));
        const winner = effects.operation_item.?;
        try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, later));
        try std.testing.expectEqual(winner.ptr, effects.operation_item.?.ptr);
        const saved = try effects.read(arena, 1);
        try std.testing.expectEqual(failure_first, saved.state.completed == .failure);
        try std.testing.expectEqual(@as(usize, 0), effects.diagnostics.items.len);
    }
}

fn reserve_output(arena: Allocator, effects: *Effects) ![]const u8 {
    const first = effects.sent.items.len;
    _ = try intake.test_support.submit(arena, &.{
        .input = request,
        .subject = "theatre",
        .operation_name = "SeatReservation",
    }, effects);
    return native_attempt(arena, effects, effects.sent.items[first].body);
}

fn native_attempt(arena: Allocator, effects: *Effects, input: []const u8) ![]const u8 {
    const first = effects.sent.items.len;
    try std.testing.expectEqualStrings(ack, try submission.handle_invocation(
        arena,
        try sqs_event(arena, input),
        &.{
            .events_table = "Events",
            .completion_queue = "seat-completion",
            .native_queue = "native",
        },
        effects,
    ));
    try std.testing.expectEqualStrings("native", effects.sent.items[first].queue);
    try std.testing.expectEqualStrings(ack, try native.test_support.invoke(
        arena,
        try sqs_event(arena, effects.sent.items[first].body),
        effects,
    ));
    return effects.sent.items[first + 1].body;
}

test "authenticated reservation returns the actual pending ID through completion and owner query" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var effects = try Effects.init(arena);
    effects.event.?.state = .ready;
    const output = try reserve_output(arena, &effects);
    const message = try messages.decode(arena, output);
    try std.testing.expectEqualStrings(
        "101",
        message.context.object.get("reservation_id").?.string,
    );
    const hold = effects.transfers[0];
    try std.testing.expectEqual(@as(u128, 101), hold.id);
    try std.testing.expectEqual(@as(u128, 13), hold.debit_account_id);
    try std.testing.expectEqual(@as(u128, 12), hold.credit_account_id);
    try std.testing.expectEqual(@as(u128, 2), hold.amount);
    try std.testing.expectEqual(@as(u32, 1001), hold.ledger);
    try std.testing.expectEqual(@as(u16, 2), hold.code);
    try std.testing.expectEqual(@as(u16, tigerbeetle.transfer_pending), hold.flags);
    try std.testing.expectEqual(@as(u32, 60), hold.timeout);
    try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, output));
    const visible = try query.test_support.query_with_backend(arena, 1, "theatre", &effects);
    const expected = "{\"type\":\"SUCCESS\",\"payload\":{\"event_id\":" ++
        "\"00000000-0000-0000-0000-000000000002\",\"class\":\"general\",\"quantity\":2," ++
        "\"reservation_id\":\"101\"}}";
    const saved = try effects.read(arena, 1);
    var buffer: [operation.result_size_max]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try operation.writeCompletionJSON(
        &buffer,
        &saved.state.completed,
    ));
    try std.testing.expect(std.mem.indexOf(u8, visible, "reservation_id") != null);
    const foreign = try query.test_support.query_with_backend(arena, 1, "other", &effects);
    try std.testing.expect(std.mem.indexOf(u8, foreign, "reservation_id") == null);
    try std.testing.expectEqual(@as(usize, 0), effects.transactions);
    try std.testing.expectEqual(@as(u32, 1000), effects.high_water);
    try std.testing.expectEqual(seat.EventState.ready, effects.event.?.state);
}

test "reservation capacity rejection and consumed attempt IDs produce code only failures" {
    const cases = .{
        .{ c.TB_CREATE_TRANSFER_EXCEEDS_CREDITS, "insufficient_seats" },
        .{ c.TB_CREATE_TRANSFER_ID_ALREADY_FAILED, "operation_rejected" },
    };
    inline for (cases) |case| {
        var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer storage.deinit();
        const arena = storage.allocator();
        var effects = try Effects.init(arena);
        effects.event.?.state = .ready;
        effects.transfer_statuses = &.{case[0]};
        const output = try reserve_output(arena, &effects);
        try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, output));
        const saved = try effects.read(arena, 1);
        try std.testing.expect(saved.state == .completed);
        var buffer: [operation.result_size_max]u8 = undefined;
        try std.testing.expectEqualStrings(
            "{\"type\":\"FAILURE\",\"payload\":{\"code\":\"" ++ case[1] ++ "\"}}",
            try operation.writeCompletionJSON(&buffer, &saved.state.completed),
        );
        const visible = try query.test_support.query_with_backend(arena, 1, "theatre", &effects);
        try std.testing.expect(std.mem.indexOf(u8, visible, case[1]) != null);
        try std.testing.expect(std.mem.indexOf(u8, visible, "reservation_id") == null);
        try std.testing.expectEqual(seat.EventState.ready, effects.event.?.state);
    }
}

test "fresh reservation attempts can leave abandoned holds and the first Result stays immutable" {
    for ([_]bool{ false, true }) |capacity_failure| {
        var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer storage.deinit();
        const arena = storage.allocator();
        var effects = try Effects.init(arena);
        effects.event.?.state = .ready;
        const delayed = try reserve_output(arena, &effects);
        if (capacity_failure) effects.transfer_statuses = &.{c.TB_CREATE_TRANSFER_EXCEEDS_CREDITS};
        const winner = try native_attempt(arena, &effects, effects.sent.items[0].body);
        try std.testing.expectEqual(@as(u128, 102), effects.transfers[0].id);
        try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, winner));
        const before = try query.test_support.query_with_backend(arena, 1, "theatre", &effects);
        try std.testing.expectEqualStrings(ack, try completion.handle_invocation(
            arena,
            try sqs_event(arena, delayed),
            &.{ .events_table = "Events", .operations_table = "Operations", .now = 2000 },
            &effects,
        ));
        try std.testing.expectEqualStrings(
            before,
            try query.test_support.query_with_backend(arena, 1, "theatre", &effects),
        );
        const saved = try effects.read(arena, 1);
        if (capacity_failure) {
            try std.testing.expectEqualStrings(
                "insufficient_seats",
                saved.state.completed.failure.object.get("code").?.string,
            );
        } else {
            try std.testing.expectEqualStrings(
                "102",
                saved.state.completed.success.object.get("reservation_id").?.string,
            );
        }
        try std.testing.expectEqual(@as(usize, 0), effects.transactions);
    }
}

test "constructed native reservation replay keeps every field and matching exists proves success" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var effects = try Effects.init(arena);
    effects.event.?.state = .ready;
    _ = try reserve_output(arena, &effects);
    const hold = effects.transfers[0];
    const first = effects.sent.items.len;
    effects.transfer_statuses = &.{tigerbeetle.transfer_exists};
    try std.testing.expectEqualStrings(ack, try native.test_support.invoke(
        arena,
        try sqs_event(arena, effects.sent.items[1].body),
        &effects,
    ));
    try std.testing.expectEqualDeep(hold, effects.transfers[0]);
    try std.testing.expectEqualStrings(ack, try complete_seat_message(
        arena,
        &effects,
        effects.sent.items[first].body,
    ));
    const saved = try effects.read(arena, 1);
    try std.testing.expectEqualStrings(
        "101",
        saved.state.completed.success.object.get("reservation_id").?.string,
    );
}

test "reservation uncertain dispatch publication and finalization survive invocation restarts" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var effects = try Effects.init(arena);
    effects.event.?.state = .ready;
    _ = try reserve_output(arena, &effects);
    const source = effects.sent.items[0].body;
    effects.send_error = error.ResponseLost;
    effects.send_before_error = true;
    {
        var invocation = std.heap.ArenaAllocator.init(arena);
        defer invocation.deinit();
        const response = try submission.handle_invocation(
            invocation.allocator(),
            try sqs_event(arena, source),
            &.{
                .events_table = "Events",
                .completion_queue = "seat-completion",
                .native_queue = "native",
            },
            &effects,
        );
        try std.testing.expect(std.mem.indexOf(u8, response, "source-1") != null);
    }
    effects.send_error = null;
    const uncertain_work = effects.sent.items[3].body;
    effects.native_send_error = error.ResponseLost;
    effects.native_send_before_error = true;
    const response = try native.test_support.invoke(
        arena,
        try sqs_event(arena, uncertain_work),
        &effects,
    );
    try std.testing.expect(std.mem.indexOf(u8, response, "source-1") != null);
    try std.testing.expectEqual(@as(u128, 102), effects.transfers[0].id);
    effects.native_send_error = null;
    effects.transfer_statuses = &.{tigerbeetle.transfer_exists};
    try std.testing.expectEqualStrings(ack, try native.test_support.invoke(
        arena,
        try sqs_event(arena, uncertain_work),
        &effects,
    ));
    const output = effects.sent.items[5].body;
    effects.write_error = error.WriteUnavailable;
    const retry = try complete_seat_message(arena, &effects, output);
    try std.testing.expect(std.mem.indexOf(u8, retry, "source-1") != null);
    effects.commit_before_error = true;
    try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, output));
    const saved = try effects.read(arena, 1);
    try std.testing.expectEqualStrings(
        "102",
        saved.state.completed.success.object.get("reservation_id").?.string,
    );
    effects.write_error = null;
    try std.testing.expectEqualStrings(ack, try complete_seat_message(
        arena,
        &effects,
        effects.sent.items[2].body,
    ));
}

const inconsistent_reservation_statuses = [_][]const u8{
    "linked_event_failed",
    "linked_event_chain_open",
    "unknown",
    "new_status",
    "exists_with_different_flags",
    "exists_with_different_amount",
    "exists_with_different_timeout",
    "exists_with_different_ledger",
    "debit_account_not_found",
    "credit_account_not_found",
    "debit_account_already_closed",
    "credit_account_already_closed",
    "transfer_must_have_the_same_ledger_as_accounts",
    "overflows_debits_pending",
    "overflows_credits_pending",
    "overflows_timeout",
    "pending_transfer_already_posted",
    "pending_transfer_expired",
    "exceeds_debits",
};

test "reservation incomplete conflicting and unknown native evidence never finalizes" {
    const entries = [_][]const u8{
        "[]",
        "[null]",
        "[{}]",
        "[{\"error_code\":null,\"alias\":\"reserve-general\"}]",
        "[{\"error_code\":\"created\",\"alias\":\"wrong\"}]",
        "[{\"error_code\":\"created\",\"alias\":\"reserve-general\",\"id\":\"101\"}]",
        "[{\"error_code\":\"created\",\"alias\":\"reserve-general\"}," ++
            "{\"error_code\":\"exceeds_credits\",\"alias\":\"reserve-general\"}]",
    };
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var effects = try Effects.init(arena);
    effects.event.?.state = .ready;
    const valid = try reserve_output(arena, &effects);
    for (entries) |entry| {
        var message = try messages.decode(arena, valid);
        const body = try std.fmt.allocPrint(
            arena,
            "{{\"create_accounts\":[],\"create_transfers\":{s},\"lookup_accounts\":[]}}",
            .{entry},
        );
        message.body = try seat.parse_value(arena, body, messages.body_size_max);
        try expect_invalid_reservation(arena, &effects, &message);
    }
    for (inconsistent_reservation_statuses) |status| {
        var message = try messages.decode(arena, valid);
        const entry = &message.body.object.getPtr("create_transfers").?.array.items[0];
        try entry.object.put(arena, "error_code", .{ .string = status });
        try expect_invalid_reservation(arena, &effects, &message);
    }
    for ([_][]const u8{ "create_accounts", "lookup_accounts" }) |family| {
        var message = try messages.decode(arena, valid);
        try message.body.object.getPtr(family).?.array.append(.null);
        try expect_invalid_reservation(arena, &effects, &message);
    }
    for ([_][]const u8{ "reservation_id", "quantity", "class", "event_id" }) |field| {
        var message = try messages.decode(arena, valid);
        _ = message.context.object.orderedRemove(field);
        try expect_invalid_reservation(arena, &effects, &message);
    }
    try std.testing.expectEqual(@as(usize, 0), effects.updates);
}

fn expect_invalid_reservation(
    arena: Allocator,
    effects: *Effects,
    message: *const messages.Message,
) !void {
    const before = effects.diagnostics.items.len;
    try std.testing.expectEqualStrings(ack, try complete_seat_message(
        arena,
        effects,
        try messages.encode(arena, message),
    ));
    try std.testing.expectEqual(before + 1, effects.diagnostics.items.len);
    const saved = try effects.read(arena, 1);
    try std.testing.expect(saved.state == .submitted);
    try std.testing.expectEqual(seat.EventState.ready, effects.event.?.state);
}

const Sent = struct { queue: []const u8, body: []const u8 };
const Effects = struct {
    arena: Allocator,
    event: ?seat.Event = null,
    operation_item: ?[]const events.Attribute = null,
    sent: std.ArrayList(Sent) = .empty,
    diagnostics: std.ArrayList([]const u8) = .empty,
    send_error: ?anyerror = null,
    write_error: ?anyerror = null,
    read_error: ?anyerror = null,
    send_before_error: bool = false,
    commit_before_error: bool = false,
    log_error: bool = false,
    updates: usize = 0,
    event_reads: usize = 0,
    high_water: u32 = 1000,
    next_id: u128 = 100,
    accounts: [33]tigerbeetle.Account = undefined,
    transfers: [31]tigerbeetle.Transfer = undefined,
    account_statuses: ?[]const u32 = null,
    transfer_statuses: ?[]const u32 = null,
    allocation_error: ?anyerror = null,
    allocation_before_error: bool = false,
    insertion_error: ?anyerror = null,
    insertion_before_error: bool = false,
    insertion_winner: ?seat.Event = null,
    pair_read_error: ?anyerror = null,
    change_configuration: bool = false,
    transactions: usize = 0,
    native_funding_error: ?anyerror = null,
    native_transfer_before_error: bool = false,
    native_send_error: ?anyerror = null,
    native_send_before_error: bool = false,
    lookup_accounts: []const tigerbeetle.Account = &.{},

    pub fn createAccounts(
        self: *Effects,
        input: []const tigerbeetle.Account,
        output: []tigerbeetle.CreateAccountResult,
    ) !usize {
        @memcpy(self.accounts[0..input.len], input);
        for (output[0..input.len], 0..) |*entry, index| {
            entry.* = std.mem.zeroes(tigerbeetle.CreateAccountResult);
            if (self.account_statuses) |statuses| {
                entry.status = statuses[index];
            } else {
                entry.status = tigerbeetle.account_created;
            }
        }
        return input.len;
    }

    pub fn createTransfers(
        self: *Effects,
        input: []const tigerbeetle.Transfer,
        output: []tigerbeetle.CreateTransferResult,
    ) !usize {
        if (!self.native_transfer_before_error) if (self.native_funding_error) |err| return err;
        @memcpy(self.transfers[0..input.len], input);
        if (self.native_funding_error) |err| return err;
        for (output[0..input.len], 0..) |*entry, index| {
            entry.* = std.mem.zeroes(tigerbeetle.CreateTransferResult);
            if (self.transfer_statuses) |statuses| {
                entry.status = statuses[index];
            } else {
                entry.status = tigerbeetle.transfer_created;
            }
        }
        return input.len;
    }

    pub fn lookupAccounts(
        self: *Effects,
        _: []const u128,
        output: []tigerbeetle.Account,
    ) !usize {
        @memcpy(output[0..self.lookup_accounts.len], self.lookup_accounts);
        return self.lookup_accounts.len;
    }

    pub fn sendCompletion(
        self: *Effects,
        _: Allocator,
        route: ?[]const u8,
        body: []const u8,
    ) !void {
        if (!self.native_send_before_error) if (self.native_send_error) |err| return err;
        try self.sent.append(self.arena, .{
            .queue = try self.arena.dupe(u8, route.?),
            .body = try self.arena.dupe(u8, body),
        });
        if (self.native_send_error) |err| return err;
    }

    pub fn transact_write(
        self: *Effects,
        _: Allocator,
        input: dynamodb.TransactWriteItemsInput,
    ) !void {
        self.transactions += 1;
        if (self.change_configuration) self.event.?.ledger += 1;
        if (!self.commit_before_error) if (self.write_error) |err| return err;
        try std.testing.expectEqual(@as(usize, 2), input.transact_items.len);
        const event_update = input.transact_items[0].update.?;
        const saved = self.event orelse return error.ConditionConflict;
        const item = try events.encode_item(self.arena, &saved);
        const values = event_update.expression_attribute_values.?;
        for (item) |field| {
            const key = try std.fmt.allocPrint(self.arena, ":{s}", .{field.key});
            const expected = try std.json.Stringify.valueAlloc(
                self.arena,
                attribute(values, key),
                .{},
            );
            const actual = try std.json.Stringify.valueAlloc(self.arena, field.value, .{});
            if (!std.mem.eql(u8, expected, actual)) return error.ConditionConflict;
        }
        const lost_response = self.write_error;
        self.write_error = null;
        defer self.write_error = lost_response;
        try self.update(self.arena, input.transact_items[1].update.?);
        self.event.?.state = std.meta.stringToEnum(
            seat.EventState,
            attribute(values, ":terminal").s.?,
        ).?;
        if (lost_response) |err| return err;
    }

    pub fn transact_get(
        self: *Effects,
        arena: Allocator,
        input: dynamodb.TransactGetItemsInput,
    ) !dynamodb.TransactGetItemsOutput {
        if (self.pair_read_error) |err| return err;
        if (self.read_error) |err| return err;
        try std.testing.expectEqual(@as(usize, 2), input.transact_items.len);
        const responses = try arena.alloc(dynamodb.types.ItemResponse, 2);
        const event_item = if (self.event) |*saved| try events.encode_item(arena, saved) else null;
        responses[0] = .{ .item = event_item };
        responses[1] = .{ .item = self.operation_item };
        return .{ .responses = responses };
    }

    pub fn allocate(self: *Effects, _: Allocator) !u32 {
        if (!self.allocation_before_error) if (self.allocation_error) |err| return err;
        self.high_water += 1;
        if (self.allocation_error) |err| return err;
        return self.high_water;
    }

    pub fn generate_id(self: *Effects) !u128 {
        self.next_id += 1;
        return self.next_id;
    }

    pub fn put(self: *Effects, _: Allocator, input: dynamodb.PutItemInput) !void {
        if (self.insertion_winner) |winner| self.event = winner;
        if (self.event != null) return error.ConditionConflict;
        if (!self.insertion_before_error) if (self.insertion_error) |err| return err;
        self.event = try events.decode_item(self.arena, input.item);
        if (self.insertion_error) |err| return err;
    }

    fn init(arena: Allocator) !Effects {
        return .{ .arena = arena, .event = .{
            .tenant = "theatre",
            .event_id = 2,
            .ledger = 1001,
            .timeout_seconds = 60,
            .capacity_account_id = 11,
            .allocation_account_id = 12,
            .state = .creating,
            .classes = try arena.dupe(seat.EventClass, &.{.{
                .tag = try seat.Tag.init("general"),
                .total = 10,
                .tb_account_id = 13,
            }}),
        } };
    }

    pub fn create(
        self: *Effects,
        arena: Allocator,
        source: *const operation.Operation,
    ) !operation.Operation {
        const creation = try operations.create_request(self.arena, "Operations", source);
        self.operation_item = creation.item;
        return operations.decode_item(arena, creation.item);
    }

    pub fn get(
        self: *Effects,
        arena: Allocator,
        input: dynamodb.GetItemInput,
    ) !?[]const events.Attribute {
        try std.testing.expect(input.consistent_read.?);
        if (self.read_error) |err| return err;
        if (std.mem.eql(u8, input.table_name, "Events")) {
            self.event_reads += 1;
            if (self.event) |*event| {
                const tenant = input.key[0].value.s.?;
                if (try seat.canonical_uuid(input.key[1].value.s.?) != event.event_id) return null;
                if (std.mem.eql(
                    u8,
                    tenant,
                    event.tenant,
                )) return try events.encode_item(arena, event);
            }
            return null;
        }
        return self.operation_item;
    }

    pub fn send(self: *Effects, _: Allocator, queue: []const u8, body: []const u8) !void {
        if (!self.send_before_error) if (self.send_error) |err| return err;
        try self.sent.append(self.arena, .{
            .queue = try self.arena.dupe(u8, queue),
            .body = try self.arena.dupe(u8, body),
        });
        if (self.send_error) |err| return err;
    }

    pub fn update(self: *Effects, _: Allocator, input: dynamodb.types.Update) !void {
        self.updates += 1;
        if (!self.commit_before_error) if (self.write_error) |err| return err;
        const item = self.operation_item orelse return error.ConditionConflict;
        const saved = try operations.decode_item(self.arena, item);
        const values = input.expression_attribute_values.?;
        try std.testing.expect(
            std.mem.indexOf(
                u8,
                input.condition_expression.?,
                "attribute_not_exists(#result)",
            ) != null,
        );
        try std.testing.expect(std.mem.indexOf(u8, input.condition_expression.?, "hash") == null);
        if (!std.mem.eql(u8, saved.tenant, attribute(values, ":tenant").s.?) or
            !std.mem.eql(u8, saved.name, attribute(values, ":name").s.?) or
            saved.id != try operation.uuidFromString(attribute(values, ":id").s.?) or
            saved.state != .submitted) return error.ConditionConflict;
        var updated = try self.arena.alloc(events.Attribute, item.len + 1);
        @memcpy(updated[0..item.len], item);
        for (updated[0..item.len]) |*field| {
            if (std.mem.eql(u8, field.key, "state")) field.value = attribute(values, ":completed");
            if (std.mem.eql(u8, field.key, "last_updated")) field.value = attribute(values, ":now");
            if (std.mem.eql(
                u8,
                field.key,
                "expires_at",
            )) field.value = attribute(values, ":expires_at");
        }
        updated[item.len] = .{ .key = "result", .value = attribute(values, ":result") };
        // The service owns bytes independently of the invocation request arena.
        for (updated) |*field| {
            switch (field.value) {
                .s => |text| field.value = .{ .s = try self.arena.dupe(u8, text.?) },
                .n => |text| field.value = .{ .n = try self.arena.dupe(u8, text.?) },
                else => unreachable,
            }
        }
        self.operation_item = updated;
        if (self.write_error) |err| return err;
    }

    pub fn read(self: *Effects, arena: Allocator, id: u128) !operation.Operation {
        const input = try operations.read_request(arena, "Operations", id);
        return operations.decode_item(
            arena,
            try self.get(arena, input) orelse return error.OperationNotFound,
        );
    }

    pub fn report(self: *Effects, diagnostic: []const u8) !void {
        if (self.log_error) return error.LogDeliveryFailed;
        try self.diagnostics.append(self.arena, try self.arena.dupe(u8, diagnostic));
    }
};

const create_request = "{\"id\":\"" ++ uuid ++ "\",\"name\":\"SeatReservation\",\"body\":{" ++
    "\"command\":\"create_event\",\"classes\":{\"premium\":3,\"general\":10}," ++
    "\"timeout_seconds\":60}}";

test "authenticated creation saves identities and retries the same complete chains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var effects = try Effects.init(allocator);
    effects.event = null;
    _ = try intake.test_support.submit(allocator, &.{
        .input = create_request,
        .subject = "theatre",
        .operation_name = "SeatReservation",
    }, &effects);
    const input = try sqs_event(allocator, effects.sent.items[0].body);
    const options: submission.Options = .{
        .events_table = "Events",
        .completion_queue = "seat-completion",
        .native_queue = "native",
    };
    try std.testing.expectEqualStrings(ack, try submission.handle_invocation(
        allocator,
        input,
        &options,
        &effects,
    ));
    const saved = effects.event.?;
    try std.testing.expectEqual(@as(u128, 1), saved.event_id);
    try std.testing.expectEqual(@as(u32, 1001), saved.ledger);
    try std.testing.expectEqual(seat.EventState.creating, saved.state);
    const first = effects.sent.items[1];
    try std.testing.expectEqualStrings("native", first.queue);
    const work = try messages.decode(allocator, first.body);
    try std.testing.expectEqualStrings("theatre", work.tenant);
    try std.testing.expectEqualStrings("seat-completion", work.result_queue.?);
    try std.testing.expectEqual(
        @as(usize, 4),
        work.body.object.get("create_accounts").?.array.items.len,
    );
    try std.testing.expectEqualStrings("general", saved.classes[0].tag.slice());
    try std.testing.expectEqualStrings(ack, try submission.handle_invocation(
        allocator,
        input,
        &options,
        &effects,
    ));
    try std.testing.expectEqualStrings(first.body, effects.sent.items[2].body);
    try std.testing.expectEqual(@as(u32, 1001), effects.high_water);
}

fn creation_output(arena: Allocator, effects: *Effects) ![]const u8 {
    effects.event = null;
    _ = try intake.test_support.submit(arena, &.{
        .input = create_request,
        .subject = "theatre",
        .operation_name = "SeatReservation",
    }, effects);
    try std.testing.expectEqualStrings(ack, try submission.handle_invocation(
        arena,
        try sqs_event(arena, effects.sent.items[0].body),
        &.{
            .events_table = "Events",
            .completion_queue = "seat-completion",
            .native_queue = "native",
        },
        effects,
    ));
    try std.testing.expectEqualStrings(ack, try native.test_support.invoke(
        arena,
        try sqs_event(arena, effects.sent.items[1].body),
        effects,
    ));
    try std.testing.expectEqualStrings("seat-completion", effects.sent.items[2].queue);
    return effects.sent.items[2].body;
}

test "authenticated creation completes ready and success atomically through the native adapter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var effects = try Effects.init(allocator);
    const output = try creation_output(allocator, &effects);
    errdefer for (effects.diagnostics.items) |diagnostic| std.debug.print("{s}\n", .{diagnostic});
    try std.testing.expectEqualStrings(ack, try completion.handle_invocation(
        allocator,
        try sqs_event(allocator, output),
        &.{ .operations_table = "Operations", .now = 1001 },
        &effects,
    ));
    try std.testing.expectEqual(seat.EventState.ready, effects.event.?.state);
    const visible = try query.test_support.query_with_backend(allocator, 1, "theatre", &effects);
    try std.testing.expect(std.mem.indexOf(u8, visible, "SUCCESS") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "event_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "error_code") == null);
}

test "definite funding rejection permanently fails creation and preserves the first terminal pair" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var effects = try Effects.init(allocator);
    effects.transfer_statuses = &.{
        c.TB_CREATE_TRANSFER_ID_ALREADY_FAILED, tigerbeetle.transfer_linked_event_failed,
    };
    const output = try creation_output(allocator, &effects);
    try std.testing.expectEqualStrings(ack, try completion.handle_invocation(
        allocator,
        try sqs_event(allocator, output),
        &.{ .operations_table = "Operations", .now = 1001 },
        &effects,
    ));
    try std.testing.expectEqual(seat.EventState.failed, effects.event.?.state);
    const visible = try query.test_support.query_with_backend(allocator, 1, "theatre", &effects);
    try std.testing.expect(std.mem.indexOf(u8, visible, "operation_rejected") != null);
    // A competing valid success cannot repair a failed Event or replace its failure Result.
    effects.transfer_statuses = null;
    _ = try native.test_support.invoke(
        allocator,
        try sqs_event(allocator, effects.sent.items[1].body),
        &effects,
    );
    try std.testing.expectEqualStrings(ack, try completion.handle_invocation(
        allocator,
        try sqs_event(allocator, effects.sent.items[3].body),
        &.{ .operations_table = "Operations", .now = 2000 },
        &effects,
    ));
    try std.testing.expectEqual(seat.EventState.failed, effects.event.?.state);
    try std.testing.expectEqualStrings(visible, try query.test_support.query_with_backend(
        allocator,
        1,
        "theatre",
        &effects,
    ));
}

fn complete_seat_message(arena: Allocator, effects: *Effects, body: []const u8) ![]const u8 {
    return completion.handle_invocation(arena, try sqs_event(arena, body), &.{
        .operations_table = "Operations",
        .events_table = "Events",
        .now = 1001,
    }, effects);
}

test "creation transaction uncertainty recognizes commits and retries unchanged pairs" {
    for ([_]bool{ false, true }) |committed| {
        var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer storage.deinit();
        const arena = storage.allocator();
        var effects = try Effects.init(arena);
        const output = try creation_output(arena, &effects);
        effects.write_error = error.LostTransactionResponse;
        effects.commit_before_error = committed;
        const response = try complete_seat_message(arena, &effects, output);
        try std.testing.expectEqual(committed, std.mem.eql(u8, ack, response));
        try std.testing.expectEqual(
            if (committed) seat.EventState.ready else .creating,
            effects.event.?.state,
        );
        try std.testing.expectEqual(committed, (try effects.read(arena, 1)).state == .completed);
        effects.write_error = null;
        // Discard all invocation-owned bytes and redeliver the saved completion.
        var invocation = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer invocation.deinit();
        try std.testing.expectEqualStrings(
            ack,
            try complete_seat_message(invocation.allocator(), &effects, output),
        );
        try std.testing.expectEqual(seat.EventState.ready, effects.event.?.state);
        try std.testing.expectEqual(@as(usize, if (committed) 1 else 2), effects.transactions);
    }
}

test "creation readback failures preserve retry eligibility after a lost commit response" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var effects = try Effects.init(arena);
    const output = try creation_output(arena, &effects);
    effects.write_error = error.LostResponse;
    effects.commit_before_error = true;
    effects.pair_read_error = error.TemporaryReadFailure;
    try std.testing.expect(!std.mem.eql(u8, ack, try complete_seat_message(arena, &effects, output)));
    try std.testing.expectEqual(seat.EventState.ready, effects.event.?.state);
    effects.pair_read_error = null;
    try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, output));
}

test "complete first-exists initialization replay establishes readiness without lookup evidence" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var effects = try Effects.init(arena);
    effects.account_statuses = &.{ tigerbeetle.account_exists, 1, 1, 1 };
    effects.transfer_statuses = &.{ tigerbeetle.transfer_exists, 1 };
    const output = try creation_output(arena, &effects);
    try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, output));
    try std.testing.expectEqual(seat.EventState.ready, effects.event.?.state);
    const saved = effects.event.?;
    try std.testing.expectEqual(saved.capacity_account_id, effects.accounts[0].id);
    try std.testing.expectEqual(@as(u16, 3), effects.accounts[0].code);
    try std.testing.expectEqual(@as(u16, 4 | 1), effects.accounts[0].flags);
    try std.testing.expectEqual(@as(u16, 2), effects.accounts[1].code);
    try std.testing.expectEqual(@as(u16, 2 | 1), effects.accounts[1].flags);
    for (saved.classes, 0..) |class, index| {
        try std.testing.expectEqual(class.tb_account_id, effects.accounts[index + 2].id);
        try std.testing.expectEqual(@as(u16, 1), effects.accounts[index + 2].code);
        try std.testing.expectEqual(class.tb_account_id, effects.transfers[index].id);
        try std.testing.expectEqual(
            class.tb_account_id,
            effects.transfers[index].credit_account_id,
        );
        try std.testing.expectEqual(
            saved.capacity_account_id,
            effects.transfers[index].debit_account_id,
        );
        try std.testing.expectEqual(@as(u128, class.total), effects.transfers[index].amount);
        try std.testing.expectEqual(@as(u16, 1), effects.transfers[index].code);
        try std.testing.expectEqual(saved.ledger, effects.transfers[index].ledger);
    }
}

test "malformed and inconclusive creation evidence never changes either record" {
    const Mutation = enum {
        truncated,
        late_exists,
        mixed,
        unknown,
        wrong_alias,
        extra_field,
        lookup,
        skip,
        bad_context,
        wrong_tenant,
        diagnostic,
        no_funding,
        extra_family,
    };
    inline for (std.meta.tags(Mutation)) |mutation| {
        var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer storage.deinit();
        const arena = storage.allocator();
        var effects = try Effects.init(arena);
        const output = try creation_output(arena, &effects);
        var message = try messages.decode(arena, output);
        const accounts = &message.body.object.getPtr("create_accounts").?.array;
        const funding = &message.body.object.getPtr("create_transfers").?.array;
        switch (mutation) {
            .truncated => accounts.items.len -= 1,
            .late_exists => {
                for (accounts.items) |*entry| {
                    try entry.object.put(arena, "error_code", .{ .string = "linked_event_failed" });
                }
                try accounts.items[1].object.put(arena, "error_code", .{ .string = "exists" });
            },
            .mixed => try funding.items[1].object.put(
                arena,
                "error_code",
                .{ .string = "linked_event_failed" },
            ),
            .unknown => try funding.items[0].object.put(
                arena,
                "error_code",
                .{ .string = "unknown" },
            ),
            .wrong_alias => try accounts.items[2].object.put(
                arena,
                "alias",
                .{ .string = "premium" },
            ),
            .extra_field => try accounts.items[0].object.put(arena, "id", .{ .string = "101" }),
            .lookup => try message.body.object.getPtr("lookup_accounts").?.array.append(.null),
            .skip => try funding.items[0].object.put(arena, "error_code", .null),
            .bad_context => try message.context.object.put(
                arena,
                "timeout_seconds",
                .{ .integer = 61 },
            ),
            .wrong_tenant => message.tenant = "foreign",
            .diagnostic => message.body = .null,
            .no_funding => funding.items.len = 0,
            .extra_family => try message.body.object.put(arena, "other", .null),
        }
        const encoded = try messages.encode(arena, &message);
        try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, encoded));
        try std.testing.expectEqual(seat.EventState.creating, effects.event.?.state);
        try std.testing.expect((try effects.read(arena, 1)).state == .submitted);
        try std.testing.expectEqual(@as(usize, 0), effects.transactions);
        try std.testing.expectEqual(@as(usize, 1), effects.diagnostics.items.len);
    }
}

test "contradictory creation pairs and changed configuration are diagnosed without repair" {
    const Mutation = enum {
        ready_submitted,
        failed_success,
        creating_completed,
        deleted_operation,
        foreign_operation,
        wrong_name,
        changed_configuration,
    };
    inline for (std.meta.tags(Mutation)) |mutation| {
        var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer storage.deinit();
        const arena = storage.allocator();
        var effects = try Effects.init(arena);
        const output = try creation_output(arena, &effects);
        switch (mutation) {
            .ready_submitted => effects.event.?.state = .ready,
            .failed_success, .creating_completed => {
                _ = try complete_seat_message(arena, &effects, output);
                effects.event.?.state = if (mutation == .failed_success) .failed else .creating;
            },
            .deleted_operation => effects.operation_item = null,
            .foreign_operation, .wrong_name => {
                for (@constCast(effects.operation_item.?)) |*field| {
                    const name = if (mutation == .foreign_operation) "tenant" else "name";
                    if (std.mem.eql(u8, name, field.key)) field.value = .{ .s = "other" };
                }
            },
            .changed_configuration => effects.change_configuration = true,
        }
        const state = effects.event.?.state;
        const before = try std.json.Stringify.valueAlloc(arena, effects.operation_item, .{});
        try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, output));
        try std.testing.expectEqual(state, effects.event.?.state);
        try std.testing.expectEqualStrings(
            before,
            try std.json.Stringify.valueAlloc(arena, effects.operation_item, .{}),
        );
        try std.testing.expectEqual(@as(usize, 1), effects.diagnostics.items.len);
    }
}

fn creation_submission(arena: Allocator, effects: *Effects) ![]const u8 {
    _ = try intake.test_support.submit(arena, &.{
        .input = create_request,
        .subject = "theatre",
        .operation_name = "SeatReservation",
    }, effects);
    return sqs_event(arena, effects.sent.items[0].body);
}

fn submit_creation(arena: Allocator, effects: *Effects, input: []const u8) ![]const u8 {
    return submission.handle_invocation(arena, input, &.{
        .events_table = "Events",
        .completion_queue = "seat-completion",
        .native_queue = "native",
    }, effects);
}

test "uncertain allocation and unresolved insertion leave gaps without dispatching candidates" {
    for ([_]bool{ false, true }) |insertion| {
        var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer storage.deinit();
        const arena = storage.allocator();
        var effects = try Effects.init(arena);
        effects.event = null;
        const input = try creation_submission(arena, &effects);
        if (insertion) {
            effects.insertion_error = error.LostResponse;
        } else {
            effects.allocation_error = error.LostResponse;
            effects.allocation_before_error = true;
        }
        try std.testing.expect(!std.mem.eql(u8, ack, try submit_creation(arena, &effects, input)));
        try std.testing.expect(effects.event == null);
        try std.testing.expectEqual(@as(usize, 1), effects.sent.items.len);
        try std.testing.expectEqual(@as(u32, 1001), effects.high_water);
        effects.insertion_error = null;
        effects.allocation_error = null;
        try std.testing.expectEqualStrings(ack, try submit_creation(arena, &effects, input));
        try std.testing.expectEqual(@as(u32, 1002), effects.event.?.ledger);
    }
}

test "insertion races and lost insert responses dispatch only the saved winner" {
    for ([_]bool{ false, true }) |competing| {
        var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer storage.deinit();
        const arena = storage.allocator();
        var winner_effects = try Effects.init(arena);
        _ = try creation_output(arena, &winner_effects);
        var winner = try seat.clone_event(arena, &winner_effects.event.?);
        winner.ledger = 2005;
        winner.capacity_account_id = 501;
        winner.allocation_account_id = 502;
        @constCast(winner.classes)[0].tb_account_id = 503;
        @constCast(winner.classes)[1].tb_account_id = 504;
        var effects = try Effects.init(arena);
        effects.event = null;
        const input = try creation_submission(arena, &effects);
        if (competing) effects.insertion_winner = winner else {
            effects.insertion_error = error.LostInsertResponse;
            effects.insertion_before_error = true;
        }
        try std.testing.expectEqualStrings(ack, try submit_creation(arena, &effects, input));
        const work = try messages.decode(arena, effects.sent.items[1].body);
        const saved = effects.event.?;
        const commands = work.body.object.get("create_accounts").?.array.items;
        try std.testing.expectEqual(
            saved.capacity_account_id,
            try seat.native_id(commands[0].object.get("id").?.string),
        );
        try std.testing.expectEqual(saved.ledger, commands[0].object.get("ledger").?.integer);
        if (competing) try std.testing.expectEqual(@as(u128, 501), saved.capacity_account_id);
        effects.insertion_error = null;
        try std.testing.expectEqualStrings(ack, try submit_creation(arena, &effects, input));
        try std.testing.expectEqualStrings(effects.sent.items[1].body, effects.sent.items[2].body);
        try std.testing.expectEqual(@as(u32, 1001), effects.high_water);
    }
}

test "lost native dispatch responses retain stable saved identities across invocation restarts" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var effects = try Effects.init(arena);
    effects.event = null;
    const input = try creation_submission(arena, &effects);
    effects.send_error = error.LostResponse;
    effects.send_before_error = true;
    try std.testing.expect(!std.mem.eql(u8, ack, try submit_creation(arena, &effects, input)));
    const first = effects.sent.items[1].body;
    effects.send_error = null;
    var invocation = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer invocation.deinit();
    try std.testing.expectEqualStrings(
        ack,
        try submit_creation(invocation.allocator(), &effects, input),
    );
    try std.testing.expectEqualStrings(first, effects.sent.items[2].body);
    try std.testing.expectEqual(@as(u32, 1001), effects.high_water);
}

test "partial initialization stays creating until account replay and complete funding" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var effects = try Effects.init(arena);
    effects.event = null;
    const input = try creation_submission(arena, &effects);
    try std.testing.expectEqualStrings(ack, try submit_creation(arena, &effects, input));
    const work = try sqs_event(arena, effects.sent.items[1].body);
    effects.native_funding_error = error.LostNativeResponse;
    try std.testing.expect(
        !std.mem.eql(u8, ack, try native.test_support.invoke(arena, work, &effects)),
    );
    try std.testing.expectEqual(@as(usize, 2), effects.sent.items.len);
    try std.testing.expectEqual(seat.EventState.creating, effects.event.?.state);
    try std.testing.expect((try effects.read(arena, 1)).state == .submitted);
    effects.native_funding_error = null;
    effects.account_statuses = &.{ tigerbeetle.account_exists, 1, 1, 1 };
    try std.testing.expectEqualStrings(ack, try native.test_support.invoke(arena, work, &effects));
    try std.testing.expectEqualStrings(
        ack,
        try complete_seat_message(arena, &effects, effects.sent.items[2].body),
    );
    try std.testing.expectEqual(seat.EventState.ready, effects.event.?.state);
}

test "rejected account initialization and its complete skipped funding never establish readiness" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var effects = try Effects.init(arena);
    effects.account_statuses = &.{ c.TB_CREATE_ACCOUNT_EXISTS_WITH_DIFFERENT_LEDGER, 1, 1, 1 };
    const output = try creation_output(arena, &effects);
    const message = try messages.decode(arena, output);
    const funding = message.body.object.get("create_transfers").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), funding.len);
    try std.testing.expect(funding[0].object.get("error_code").? == .null);
    try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, output));
    try std.testing.expectEqual(seat.EventState.creating, effects.event.?.state);
    try std.testing.expect((try effects.read(arena, 1)).state == .submitted);
    try std.testing.expectEqual(@as(usize, 1), effects.diagnostics.items.len);
}

test "31-class creation executes all 64 commands and atomically becomes ready" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var effects = try Effects.init(arena);
    effects.event = null;
    var classes: std.json.ObjectMap = .empty;
    for (0..31) |index| {
        const tag = try std.fmt.allocPrint(arena, "class-{d:0>2}", .{index});
        try classes.put(arena, tag, .{ .integer = std.math.maxInt(u32) });
    }
    const input = try std.json.Stringify.valueAlloc(arena, .{
        .id = uuid,
        .name = "SeatReservation",
        .body = .{
            .command = "create_event",
            .classes = std.json.Value{ .object = classes },
            .timeout_seconds = std.math.maxInt(u32),
        },
    }, .{});
    _ = try intake.test_support.submit(arena, &.{
        .input = input,
        .subject = "theatre",
        .operation_name = "SeatReservation",
    }, &effects);
    try std.testing.expectEqualStrings(ack, try submit_creation(
        arena,
        &effects,
        try sqs_event(arena, effects.sent.items[0].body),
    ));
    const work = try messages.decode(arena, effects.sent.items[1].body);
    try std.testing.expectEqual(
        @as(usize, 33),
        work.body.object.get("create_accounts").?.array.items.len,
    );
    try std.testing.expectEqual(
        @as(usize, 31),
        work.body.object.get("create_transfers").?.array.items.len,
    );
    try std.testing.expectEqualStrings(ack, try native.test_support.invoke(
        arena,
        try sqs_event(arena, effects.sent.items[1].body),
        &effects,
    ));
    try std.testing.expectEqualStrings(ack, try complete_seat_message(
        arena,
        &effects,
        effects.sent.items[2].body,
    ));
    try std.testing.expectEqual(seat.EventState.ready, effects.event.?.state);
}

test "creation response encoding failure after atomic commit preserves the terminal winner" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var effects = try Effects.init(arena);
    const output = try creation_output(arena, &effects);
    var failing = std.testing.FailingAllocator.init(arena, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, completion.handle_invocation(
        arena,
        try sqs_event(arena, output),
        &.{
            .operations_table = "Operations",
            .events_table = "Events",
            .now = 1001,
            .response_allocator = failing.allocator(),
        },
        &effects,
    ));
    try std.testing.expectEqual(seat.EventState.ready, effects.event.?.state);
    try std.testing.expect((try effects.read(arena, 1)).state == .completed);
    try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, output));
    try std.testing.expectEqual(@as(usize, 1), effects.transactions);
}

const check_body = "{\"command\":\"check_seats\",\"event_id\":\"00000000-0000-" ++
    "0000-0000-000000000002\"}";

fn check_output(arena: Allocator, effects: *Effects) ![]const u8 {
    const input = "{\"id\":\"" ++ uuid ++ "\",\"name\":\"SeatReservation\",\"body\":" ++
        check_body ++ "}";
    const first = effects.sent.items.len;
    _ = try intake.test_support.submit(arena, &.{
        .input = input,
        .subject = "theatre",
        .operation_name = "SeatReservation",
    }, effects);
    try std.testing.expectEqualStrings(ack, try submission.handle_invocation(
        arena,
        try sqs_event(arena, effects.sent.items[first].body),
        &.{
            .events_table = "Events",
            .completion_queue = "seat-completion",
            .native_queue = "native",
        },
        effects,
    ));
    try std.testing.expectEqualStrings("native", effects.sent.items[first + 1].queue);
    const work = try messages.decode(arena, effects.sent.items[first + 1].body);
    const lookups = work.body.object.get("lookup_accounts").?.array.items;
    try std.testing.expectEqual(effects.event.?.classes.len, lookups.len);
    for (effects.event.?.classes, lookups) |*class, lookup| {
        try std.testing.expectEqualStrings(class.tag.slice(), lookup.object.get("alias").?.string);
        try std.testing.expectEqual(
            class.tb_account_id,
            try seat.native_id(lookup.object.get("id").?.string),
        );
    }
    try std.testing.expectEqualStrings(ack, try native.test_support.invoke(
        arena,
        try sqs_event(arena, effects.sent.items[first + 1].body),
        effects,
    ));
    return effects.sent.items[first + 2].body;
}

test "authenticated availability observes all seats through native completion and owner query" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var effects = try ready_check_effects(arena);
    const account = @constCast(&effects.lookup_accounts[0]);
    account.debits_pending = 3;
    account.debits_posted = 2;
    const output = try check_output(arena, &effects);
    try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, output));
    const saved = try effects.read(arena, 1);
    const expected = "{\"type\":\"SUCCESS\",\"payload\":{\"event_id\":\"" ++
        "00000000-0000-0000-0000-000000000002\",\"classes\":{\"general\":" ++
        "{\"total\":10,\"available\":5}}}}";
    var buffer: [operation.result_size_max]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try operation.writeCompletionJSON(
        &buffer,
        &saved.state.completed,
    ));
    const visible = try query.test_support.query_with_backend(arena, 1, "theatre", &effects);
    try std.testing.expect(std.mem.indexOf(u8, visible, "available") != null);
    const foreign = try query.test_support.query_with_backend(arena, 1, "other", &effects);
    try std.testing.expect(std.mem.indexOf(u8, foreign, "available") == null);
    try std.testing.expectEqual(@as(usize, 0), effects.transactions);
    try std.testing.expectEqual(@as(u32, 1000), effects.high_water);
    try std.testing.expectEqual(seat.EventState.ready, effects.event.?.state);
}

test "31-class availability preserves byte order escaped tags and maximum integer totals" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var effects = try Effects.init(arena);
    const classes = try arena.alloc(seat.EventClass, 31);
    var accounts: [31]tigerbeetle.Account = undefined;
    for (classes, &accounts, 0..) |*class, *account, index| {
        const tag = try std.fmt.allocPrint(arena, "{d:0>2}" ++ "\"" ** 52, .{index});
        class.* = .{
            .tag = try seat.Tag.init(tag),
            .total = std.math.maxInt(u32),
            .tb_account_id = seat.native_id_max - index,
        };
        account.* = std.mem.zeroes(tigerbeetle.Account);
        account.id = class.tb_account_id;
        account.ledger = 1001;
        account.code = 1;
        account.flags = c.TB_ACCOUNT_DEBITS_MUST_NOT_EXCEED_CREDITS;
        if (index + 1 < classes.len) account.flags |= c.TB_ACCOUNT_LINKED;
        account.credits_posted = std.math.maxInt(u32);
        account.debits_posted = std.math.maxInt(u32) - 1;
        account.timestamp = std.math.maxInt(u64);
    }
    effects.event.?.classes = classes;
    effects.event.?.state = .ready;
    // The adapter must restore request order from a reversed native reply.
    std.mem.reverse(tigerbeetle.Account, &accounts);
    effects.lookup_accounts = &accounts;
    const output = try check_output(arena, &effects);
    var missing_link = try messages.decode(arena, output);
    const first = &missing_link.body.object.getPtr("lookup_accounts").?.array.items[0];
    const flags = first.object.getPtr("account").?.object.getPtr("flags").?;
    flags.array.items = flags.array.items[1..];
    try std.testing.expectEqualStrings(ack, try complete_seat_message(
        arena,
        &effects,
        try messages.encode(arena, &missing_link),
    ));
    try std.testing.expect((try effects.read(arena, 1)).state == .submitted);
    try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, output));
    const saved = try effects.read(arena, 1);
    try std.testing.expect(saved.state == .completed);
    const observed = saved.state.completed.success.object.get("classes").?.object;
    try std.testing.expectEqual(@as(usize, 31), observed.count());
    for (classes, observed.keys(), observed.values()) |*class, tag, value| {
        try std.testing.expectEqualStrings(class.tag.slice(), tag);
        try std.testing.expectEqual(@as(i64, 4_294_967_295), value.object.get("total").?.integer);
        try std.testing.expectEqual(@as(i64, 1), value.object.get("available").?.integer);
    }
    const response = try seat.parse_value(arena, try query.test_support.query_with_backend(
        arena,
        1,
        "theatre",
        &effects,
    ), messages.encoded_size_max);
    const visible = try operation.parseOutputJSON(arena, response.object.get("body").?.string);
    const visible_classes = visible.state.completed.success.object.get("classes").?.object;
    try std.testing.expectEqual(@as(usize, 31), visible_classes.count());
}

test "availability admission hides foreign events and rejects subsets before native work" {
    const Case = struct {
        state: ?seat.EventState = .ready,
        tenant: []const u8 = "theatre",
        body: []const u8 = check_body,
        code: []const u8,
    };
    const cases = [_]Case{
        .{ .state = null, .code = "event_unavailable" },
        .{ .tenant = "foreign", .code = "event_unavailable" },
        .{ .tenant = "foreign", .state = .failed, .code = "event_unavailable" },
        .{ .state = .creating, .code = "event_not_ready" },
        .{ .state = .failed, .code = "event_failed" },
        .{
            .body = "{\"command\":\"check_seats\",\"event_id\":\"00000000-0000-" ++
                "0000-0000-000000000002\",\"classes\":[\"general\"]}",
            .code = "invalid_request",
        },
    };
    for (cases) |case| {
        var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer storage.deinit();
        const arena = storage.allocator();
        var effects = try Effects.init(arena);
        if (case.state) |state| {
            effects.event.?.state = state;
            effects.event.?.tenant = case.tenant;
        } else effects.event = null;
        const output = try submitted_rejection(arena, &effects, case.body);
        try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, output));
        const saved = try effects.read(arena, 1);
        const code = saved.state.completed.failure.object.get("code").?.string;
        try std.testing.expectEqualStrings(case.code, code);
        try std.testing.expectEqualStrings("seat-completion", effects.sent.items[1].queue);
        try std.testing.expectEqual(@as(u32, 1000), effects.high_water);
        try std.testing.expectEqual(@as(usize, 0), effects.transactions);
    }
}

fn ready_check_effects(arena: Allocator) !Effects {
    var effects = try Effects.init(arena);
    effects.event.?.state = .ready;
    const accounts = try arena.alloc(tigerbeetle.Account, 1);
    accounts[0] = std.mem.zeroes(tigerbeetle.Account);
    accounts[0].id = 13;
    accounts[0].ledger = 1001;
    accounts[0].code = 1;
    accounts[0].flags = c.TB_ACCOUNT_DEBITS_MUST_NOT_EXCEED_CREDITS;
    accounts[0].credits_posted = 10;
    accounts[0].timestamp = 1;
    effects.lookup_accounts = accounts;
    return effects;
}

const InvalidAvailabilityCase = struct {
    target: enum { body, entry, account, context },
    field: []const u8,
    value: ?[]const u8 = null,
};
const invalid_availability_cases = [_]InvalidAvailabilityCase{
    .{ .target = .body, .field = "error", .value = "{}" },
    .{ .target = .body, .field = "create_accounts" },
    .{ .target = .body, .field = "create_accounts", .value = "[{}]" },
    .{ .target = .body, .field = "create_transfers", .value = "[{}]" },
    .{ .target = .body, .field = "lookup_accounts", .value = "[]" },
    .{ .target = .body, .field = "lookup_accounts", .value = "[null]" },
    .{ .target = .body, .field = "lookup_accounts", .value = "[null,null]" },
    .{ .target = .entry, .field = "error_code" },
    .{ .target = .entry, .field = "error_code", .value = "\"unknown\"" },
    .{ .target = .entry, .field = "error_code", .value = "\"created\"" },
    .{ .target = .entry, .field = "alias" },
    .{ .target = .entry, .field = "alias", .value = "\"other\"" },
    .{ .target = .entry, .field = "alias", .value = "null" },
    .{ .target = .entry, .field = "message", .value = "\"Account was not found.\"" },
    .{ .target = .entry, .field = "account" },
    .{ .target = .entry, .field = "account", .value = "null" },
    .{ .target = .account, .field = "unexpected", .value = "0" },
    .{ .target = .account, .field = "timestamp" },
    .{ .target = .account, .field = "timestamp", .value = "\"0\"" },
    .{ .target = .account, .field = "timestamp", .value = "\"18446744073709551616\"" },
    .{ .target = .account, .field = "id", .value = "\"12\"" },
    .{ .target = .account, .field = "ledger", .value = "1002" },
    .{ .target = .account, .field = "ledger", .value = "\"1001\"" },
    .{ .target = .account, .field = "code", .value = "2" },
    .{ .target = .account, .field = "flags", .value = "[]" },
    .{
        .target = .account,
        .field = "flags",
        .value = "[\"linked\",\"debits_must_not_exceed_credits\"]",
    },
    .{
        .target = .account,
        .field = "flags",
        .value = "[\"debits_must_not_exceed_credits\",\"closed\"]",
    },
    .{
        .target = .account,
        .field = "flags",
        .value = "[\"debits_must_not_exceed_credits\",\"debits_must_not_exceed_credits\"]",
    },
    .{ .target = .account, .field = "user_data_128", .value = "\"1\"" },
    .{ .target = .account, .field = "user_data_64", .value = "\"1\"" },
    .{ .target = .account, .field = "user_data_32", .value = "1" },
    .{ .target = .account, .field = "reserved", .value = "1" },
    .{ .target = .account, .field = "credits_pending", .value = "\"1\"" },
    .{ .target = .account, .field = "credits_posted", .value = "\"0\"" },
    .{ .target = .account, .field = "credits_posted", .value = "\"11\"" },
    .{ .target = .account, .field = "debits_posted", .value = "\"11\"" },
    .{ .target = .account, .field = "debits_pending", .value = "\"11\"" },
    .{
        .target = .account,
        .field = "debits_pending",
        .value = "\"340282366920938463463374607431768211455\"",
    },
    .{
        .target = .account,
        .field = "debits_pending",
        .value = "\"340282366920938463463374607431768211456\"",
    },
    .{ .target = .account, .field = "debits_pending", .value = "\"01\"" },
    .{ .target = .account, .field = "debits_pending", .value = "\"+1\"" },
    .{ .target = .account, .field = "debits_pending", .value = "\"-1\"" },
    .{ .target = .account, .field = "debits_pending", .value = "1" },
    .{ .target = .context, .field = "classes", .value = "[]" },
    .{
        .target = .context,
        .field = "event_id",
        .value = "\"00000000-0000-0000-0000-000000000003\"",
    },
};

test "malformed availability evidence acknowledges without inventing a terminal Result" {
    for (&invalid_availability_cases) |*case| {
        var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer storage.deinit();
        const arena = storage.allocator();
        var effects = try ready_check_effects(arena);
        var message = try messages.decode(arena, try check_output(arena, &effects));
        const entry = &message.body.object.getPtr("lookup_accounts").?.array.items[0];
        const object = switch (case.target) {
            .body => &message.body.object,
            .entry => &entry.object,
            .account => &entry.object.getPtr("account").?.object,
            .context => &message.context.object,
        };
        if (case.value) |value| {
            try object.put(arena, case.field, try seat.parse_value(arena, value, 4096));
        } else try std.testing.expect(object.swapRemove(case.field));
        try std.testing.expectEqualStrings(ack, try complete_seat_message(
            arena,
            &effects,
            try messages.encode(arena, &message),
        ));
        try std.testing.expectEqual(@as(usize, 1), effects.diagnostics.items.len);
        try std.testing.expectEqual(@as(usize, 0), effects.updates);
        try std.testing.expect((try effects.read(arena, 1)).state == .submitted);
        try std.testing.expectEqual(seat.EventState.ready, effects.event.?.state);
    }
}

test "delayed availability and lost write responses preserve the first complete observation" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var effects = try ready_check_effects(arena);
    const account = @constCast(&effects.lookup_accounts[0]);
    const first = try check_output(arena, &effects);
    account.debits_pending = 4;
    // Retry submission creates a newer observation while the first one is delayed.
    const second = try check_output(arena, &effects);
    effects.write_error = error.LostWriteResponse;
    effects.commit_before_error = true;
    try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, second));
    effects.write_error = null;
    const winner = effects.operation_item.?;
    try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, first));
    try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, second));
    try std.testing.expectEqual(winner.ptr, effects.operation_item.?.ptr);
    const saved = try effects.read(arena, 1);
    const observed = saved.state.completed.success.object.get("classes").?.object.get("general").?;
    try std.testing.expectEqual(@as(i64, 6), observed.object.get("available").?.integer);
    try std.testing.expectEqual(@as(usize, 0), effects.transactions);
}

test "missing native accounts and overcommitted balances never synthesize availability" {
    for ([_]bool{ true, false }) |missing| {
        var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer storage.deinit();
        const arena = storage.allocator();
        var effects = try ready_check_effects(arena);
        if (missing) {
            effects.lookup_accounts = &.{};
        } else {
            const account = @constCast(&effects.lookup_accounts[0]);
            account.debits_posted = 6;
            account.debits_pending = 5;
        }
        const output = try check_output(arena, &effects);
        try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, output));
        try std.testing.expectEqual(@as(usize, 1), effects.diagnostics.items.len);
        try std.testing.expectEqual(@as(usize, 0), effects.updates);
        try std.testing.expect((try effects.read(arena, 1)).state == .submitted);
    }
}

test "availability retries uncertain reads and writes and accepts a zero-seat observation" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var effects = try ready_check_effects(arena);
    const account = @constCast(&effects.lookup_accounts[0]);
    account.debits_posted = 6;
    account.debits_pending = 4;
    const output = try check_output(arena, &effects);
    effects.write_error = error.ServiceUnavailable;
    try std.testing.expect(!std.mem.eql(u8, ack, try complete_seat_message(arena, &effects, output)));
    try std.testing.expect((try effects.read(arena, 1)).state == .submitted);
    effects.write_error = null;
    effects.read_error = error.ServiceUnavailable;
    try std.testing.expect(!std.mem.eql(u8, ack, try complete_seat_message(arena, &effects, output)));
    effects.read_error = null;
    try std.testing.expectEqualStrings(ack, try complete_seat_message(arena, &effects, output));
    const saved = try effects.read(arena, 1);
    const observed = saved.state.completed.success.object.get("classes").?.object.get("general").?;
    try std.testing.expectEqual(@as(i64, 0), observed.object.get("available").?.integer);
    try std.testing.expectEqual(@as(usize, 0), effects.diagnostics.items.len);
}

fn sqs_event(arena: Allocator, body: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, .{ .Records = &.{.{
        .messageId = "source-1",
        .receiptHandle = "receipt",
        .body = body,
        .attributes = std.json.Value{ .object = .empty },
        .messageAttributes = std.json.Value{ .object = .empty },
        .md5OfBody = "md5",
        .eventSource = "aws:sqs",
        .eventSourceARN = "arn",
        .awsRegion = "ca-central-1",
    }} }, .{});
}

test "authenticated SeatReservation intake publishes a creating Event rejection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var effects = try Effects.init(allocator);
    const accepted = try intake.test_support.submit(allocator, &.{
        .input = request,
        .subject = "theatre",
        .operation_name = "SeatReservation",
    }, &effects);
    try std.testing.expect(std.mem.indexOf(u8, accepted, "SUBMITTED") != null);
    const source = effects.sent.items[0];
    const incoming = try messages.decode(allocator, source.body);
    try std.testing.expectEqualStrings("theatre", incoming.tenant);
    try std.testing.expect(incoming.context == .null);
    const response = try submission.handle_invocation(allocator, try sqs_event(
        allocator,
        source.body,
    ), &.{
        .events_table = "Events",
        .completion_queue = "seat-completion",
    }, &effects);
    try std.testing.expectEqualStrings(ack, response);
    try std.testing.expectEqual(@as(usize, 2), effects.sent.items.len);
    try std.testing.expectEqualStrings("seat-completion", effects.sent.items[1].queue);
    const outgoing = try messages.decode(allocator, effects.sent.items[1].body);
    try std.testing.expectEqualStrings(
        "event_not_ready",
        outgoing.body.object.get("code").?.string,
    );
    try std.testing.expectEqualStrings(
        "reserve_seats",
        outgoing.context.object.get("command").?.string,
    );
    try std.testing.expect(outgoing.result_queue == null);
}

fn attribute(item: []const events.Attribute, key: []const u8) dynamodb.types.AttributeValue {
    for (item) |field| if (std.mem.eql(u8, field.key, key)) return field.value;
    unreachable;
}

test "delayed rejection remains immutable and can be queried only by its authenticated owner" {
    var store_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer store_arena.deinit();
    const allocator = store_arena.allocator();
    var effects = try Effects.init(allocator);
    _ = try intake.test_support.submit(allocator, &.{
        .input = request,
        .subject = "theatre",
        .operation_name = "SeatReservation",
    }, &effects);
    _ = try submission.handle_invocation(allocator, try sqs_event(
        allocator,
        effects.sent.items[0].body,
    ), &.{
        .events_table = "Events",
        .completion_queue = "seat-completion",
    }, &effects);
    effects.event.?.state = .ready;
    const rejection = effects.sent.items[1].body;
    const response = try completion.handle_invocation(
        allocator,
        try sqs_event(allocator, rejection),
        &.{ .operations_table = "Operations", .now = 1001 },
        &effects,
    );
    try std.testing.expectEqualStrings(ack, response);
    const visible = try query.test_support.query_with_backend(allocator, 1, "theatre", &effects);
    try std.testing.expect(std.mem.indexOf(u8, visible, "event_not_ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "COMPLETED") != null);
    const foreign = try query.test_support.query_with_backend(allocator, 1, "foreign", &effects);
    try std.testing.expect(std.mem.indexOf(u8, foreign, "event_not_ready") == null);
    _ = try completion.handle_invocation(
        allocator,
        try sqs_event(allocator, rejection),
        &.{ .operations_table = "Operations", .now = 1002 },
        &effects,
    );
    const saved = try effects.read(allocator, 1);
    try std.testing.expectEqual(@as(?i64, 1001), saved.last_updated);
}

fn submitted_rejection(arena: Allocator, effects: *Effects, body: []const u8) ![]const u8 {
    const input = try std.fmt.allocPrint(
        arena,
        "{{\"id\":\"{s}\",\"name\":\"SeatReservation\",\"body\":{s}}}",
        .{ uuid, body },
    );
    _ = try intake.test_support.submit(arena, &.{
        .input = input,
        .subject = "theatre",
        .operation_name = "SeatReservation",
    }, effects);
    const response = try submission.handle_invocation(arena, try sqs_event(
        arena,
        effects.sent.items[0].body,
    ), &.{
        .events_table = "Events",
        .completion_queue = "seat-completion",
    }, effects);
    try std.testing.expectEqualStrings(ack, response);
    return effects.sent.items[1].body;
}

test "schema rejection preserves arbitrary invalid input as Context" {
    const invalid = [_][]const u8{
        "null",
        "[1,2]",
        "false",
        "42",
        "\"arbitrary\"",
        "{}",
        "{\"command\":\"reserve_seats\",\"event_id\":\"00000000-0000-" ++
            "0000-0000-000000000002\",\"class\":\"general\",\"quantity\":" ++
            "0}",
        "{\"command\":\"create_event\",\"classes\":{\"general\":1},\"" ++
            "timeout_seconds\":0}",
        "{\"command\":\"check_seats\",\"event_id\":\"bad\"}",
    };
    for (invalid) |body| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var effects = try Effects.init(allocator);
        // Schema errors win even when Event reads would fail.
        effects.read_error = error.TransientRead;
        const rejection = try submitted_rejection(allocator, &effects, body);
        effects.read_error = null;
        const message = try messages.decode(allocator, rejection);
        try std.testing.expectEqualStrings(
            "invalid_request",
            message.body.object.get("code").?.string,
        );
        _ = try completion.handle_invocation(
            allocator,
            try sqs_event(allocator, rejection),
            &.{ .operations_table = "Operations", .now = 1001 },
            &effects,
        );
        const visible = try query.test_support.query_with_backend(
            allocator,
            1,
            "theatre",
            &effects,
        );
        try std.testing.expect(std.mem.indexOf(u8, visible, "invalid_request") != null);
        try std.testing.expectEqual(seat.EventState.creating, effects.event.?.state);
        try std.testing.expectEqual(@as(usize, 2), effects.sent.items.len);
    }
}

test "Event ownership precedes readiness and class disclosure and transient reads retry" {
    for ([_]u8{ 0, 1, 2, 3, 4, 5 }) |scenario| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var effects = try Effects.init(allocator);
        switch (scenario) {
            0 => effects.event = null,
            1 => effects.event.?.tenant = "foreign",
            2 => effects.event.?.state = .creating,
            3 => effects.event.?.state = .failed,
            4 => effects.event.?.state = .ready,
            5 => effects.read_error = error.TransientRead,
            else => unreachable,
        }
        const source = try messages.encode(allocator, &.{
            .operation_id = 1,
            .tenant = "theatre",
            .context = .null,
            .body = try seat.parse_value(allocator, "{\"command\":\"reserve_seats\",\"event_id\":\"00000000-0000-" ++
                "0000-0000-000000000002\",\"class\":\"nonexistent\",\"quantit" ++
                "y\":1}", 4096),
        });
        const response = try submission.handle_invocation(
            allocator,
            try sqs_event(allocator, source),
            &.{ .events_table = "Events", .completion_queue = "seat-completion" },
            &effects,
        );
        if (scenario == 5) {
            try std.testing.expect(std.mem.indexOf(u8, response, "source-1") != null);
            try std.testing.expectEqual(@as(usize, 0), effects.sent.items.len);
        } else {
            try std.testing.expectEqualStrings(ack, response);
            const message = try messages.decode(allocator, effects.sent.items[0].body);
            const expected = [_][]const u8{
                "event_unavailable", "event_unavailable", "event_not_ready", "event_failed", "unknown_class",
            };
            try std.testing.expectEqualStrings(
                expected[scenario],
                message.body.object.get("code").?.string,
            );
        }
        try std.testing.expectEqual(@as(usize, 0), effects.updates);
    }
}

const reserve_body = "{\"command\":\"reserve_seats\",\"event_id\":\"00000000-0000-" ++
    "0000-0000-000000000002\",\"class\":\"general\",\"quantity\":" ++
    "2}";

test "uncertain publication and finalization survive invocation restarts" {
    var store = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer store.deinit();
    const allocator = store.allocator();
    var effects = try Effects.init(allocator);
    _ = try intake.test_support.submit(allocator, &.{
        .input = request,
        .subject = "theatre",
        .operation_name = "SeatReservation",
    }, &effects);
    const source = effects.sent.items[0].body;
    effects.send_before_error = true;
    effects.send_error = error.SendResponseLost;
    {
        var invocation = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer invocation.deinit();
        const arena = invocation.allocator();
        const response = try submission.handle_invocation(
            arena,
            try sqs_event(arena, source),
            &.{ .events_table = "Events", .completion_queue = "seat-completion" },
            &effects,
        );
        try std.testing.expect(std.mem.indexOf(u8, response, "source-1") != null);
    }
    effects.send_error = null;
    _ = try submission.handle_invocation(
        allocator,
        try sqs_event(allocator, source),
        &.{ .events_table = "Events", .completion_queue = "seat-completion" },
        &effects,
    );
    try std.testing.expectEqual(@as(usize, 3), effects.sent.items.len);
    try std.testing.expectEqualStrings(effects.sent.items[1].body, effects.sent.items[2].body);
    effects.write_error = error.WriteResponseLost;
    effects.commit_before_error = true;
    effects.read_error = error.ReadUncertain;
    {
        var invocation = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer invocation.deinit();
        const arena = invocation.allocator();
        const response = try completion.handle_invocation(
            arena,
            try sqs_event(arena, effects.sent.items[1].body),
            &.{ .operations_table = "Operations", .now = 1001 },
            &effects,
        );
        try std.testing.expect(std.mem.indexOf(u8, response, "source-1") != null);
    }
    effects.read_error = null;
    effects.write_error = null;
    const response = try completion.handle_invocation(
        allocator,
        try sqs_event(allocator, effects.sent.items[2].body),
        &.{ .operations_table = "Operations", .now = 1002 },
        &effects,
    );
    try std.testing.expectEqualStrings(ack, response);
    const saved = try effects.read(allocator, 1);
    try std.testing.expectEqual(@as(?i64, 1001), saved.last_updated);
    const visible = try query.test_support.query_with_backend(allocator, 1, "theatre", &effects);
    try std.testing.expect(std.mem.indexOf(u8, visible, "event_not_ready") != null);
}

test "unproven condition conflicts and transient writes remain retryable" {
    for ([_]anyerror{ error.ConditionConflict, error.TransientWrite }) |failure| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var effects = try Effects.init(allocator);
        const rejection = try submitted_rejection(allocator, &effects, reserve_body);
        effects.write_error = failure;
        const response = try completion.handle_invocation(
            allocator,
            try sqs_event(allocator, rejection),
            &.{ .operations_table = "Operations", .now = 1001 },
            &effects,
        );
        try std.testing.expect(std.mem.indexOf(u8, response, "source-1") != null);
        const saved = try effects.read(allocator, 1);
        try std.testing.expectEqual(operation.StateTag.submitted, operation.stateTag(&saved.state));
        try std.testing.expectEqual(@as(?i64, 1000), saved.last_updated);
    }
}

test "valid readback acknowledges lost writes and preserves a different winner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var effects = try Effects.init(allocator);
    const rejection = try submitted_rejection(allocator, &effects, reserve_body);
    effects.write_error = error.WriteResponseLost;
    effects.commit_before_error = true;
    const response = try completion.handle_invocation(
        allocator,
        try sqs_event(allocator, rejection),
        &.{ .operations_table = "Operations", .now = 1001 },
        &effects,
    );
    try std.testing.expectEqualStrings(ack, response);
    effects.write_error = null;
    var duplicate = try messages.decode(allocator, rejection);
    duplicate.body = try seat.parse_value(allocator, "{\"code\":\"invalid_request\"}", 4096);
    const output = try messages.encode(allocator, &duplicate);
    try std.testing.expectEqualStrings(
        ack,
        try completion.handle_invocation(
            allocator,
            try sqs_event(allocator, output),
            &.{ .operations_table = "Operations", .now = 1002 },
            &effects,
        ),
    );
    const saved = try effects.read(allocator, 1);
    try std.testing.expectEqualStrings(
        "event_not_ready",
        saved.state.completed.failure.object.get("code").?.string,
    );
    try std.testing.expectEqual(@as(?i64, 1001), saved.last_updated);
}

test "response encoding failure after publication or commit leaves replay protected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var effects = try Effects.init(allocator);
    const rejection = try submitted_rejection(allocator, &effects, reserve_body);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, submission.handle_invocation(allocator, try sqs_event(
        allocator,
        effects.sent.items[0].body,
    ), &.{
        .events_table = "Events",
        .completion_queue = "seat-completion",
        .response_allocator = failing.allocator(),
    }, &effects));
    try std.testing.expectEqual(@as(usize, 3), effects.sent.items.len);
    try std.testing.expectError(error.OutOfMemory, completion.handle_invocation(allocator, try sqs_event(
        allocator,
        rejection,
    ), &.{
        .operations_table = "Operations",
        .now = 1001,
        .response_allocator = failing.allocator(),
    }, &effects));
    try std.testing.expectEqualStrings(
        ack,
        try completion.handle_invocation(
            allocator,
            try sqs_event(allocator, rejection),
            &.{ .operations_table = "Operations", .now = 1002 },
            &effects,
        ),
    );
    const saved = try effects.read(allocator, 1);
    try std.testing.expectEqual(@as(?i64, 1001), saved.last_updated);
}

test "malformed envelopes and route overrides diagnose without effects" {
    const prefix = "{\"operation_id\":\"" ++ uuid ++ "\",\"tenant\":\"theatre\",";
    const invalid = [_][]const u8{
        "not-json",
        "{}",
        "[]",
        prefix ++ "\"body\":{}}",
        prefix ++ "\"body\":{},\"context\":null,\"extra\":1}",
        prefix ++ "\"body\":{},\"context\":null,\"result_queue\":\"override\"}",
        prefix ++ "\"body\":{},\"context\":null,\"tenant\":\"duplicate\"}",
        prefix ++ "\"body\":{},\"context\":null,\"operation_id\":\"invalid\"}",
    };
    for (invalid) |body| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var effects = try Effects.init(allocator);
        const input = try sqs_event(allocator, body);
        try std.testing.expectEqualStrings(
            ack,
            try submission.handle_invocation(
                allocator,
                input,
                &.{ .events_table = "Events", .completion_queue = "seat-completion" },
                &effects,
            ),
        );
        try std.testing.expectEqualStrings(
            ack,
            try completion.handle_invocation(
                allocator,
                input,
                &.{ .operations_table = "Operations", .now = 1001 },
                &effects,
            ),
        );
        try std.testing.expectEqual(@as(usize, 0), effects.sent.items.len);
        try std.testing.expectEqual(@as(usize, 0), effects.updates);
        try std.testing.expectEqual(@as(usize, 2), effects.diagnostics.items.len);
        for (effects.diagnostics.items) |diagnostic| {
            try std.testing.expect(diagnostic.len <= 8192);
            const parsed = try seat.parse_value(allocator, diagnostic, 8192);
            try std.testing.expectEqualStrings("ERROR", parsed.object.get("level").?.string);
            try std.testing.expectEqualStrings("source-1", parsed.object.get("sqs_id").?.string);
            try std.testing.expectEqual(
                @as(i64, @intCast(body.len)),
                parsed.object.get("body_length").?.integer,
            );
            try std.testing.expect(!parsed.object.get("truncated").?.bool);
        }
    }
}

test "mixed local native and unknown failure Bodies are not public business rejections" {
    const invalid = [_][]const u8{
        "{\"code\":\"event_failed\",\"create_accounts\":[],\"create_t" ++
            "ransfers\":[],\"lookup_accounts\":[]}",
        "{\"create_accounts\":[],\"create_transfers\":[],\"lookup_accounts\":[]}",
        "{\"code\":\"unknown\"}",
        "{\"code\":\"insufficient_seats\"}",
        "null",
    };
    for (invalid) |body| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var effects = try Effects.init(allocator);
        const source = try messages.encode(allocator, &.{
            .operation_id = 1,
            .tenant = "theatre",
            .context = .null,
            .body = try seat.parse_value(allocator, body, 4096),
        });
        try std.testing.expectEqualStrings(
            ack,
            try completion.handle_invocation(
                allocator,
                try sqs_event(allocator, source),
                &.{ .operations_table = "Operations", .now = 1001 },
                &effects,
            ),
        );
        try std.testing.expectEqual(@as(usize, 0), effects.updates);
        try std.testing.expectEqual(@as(usize, 1), effects.diagnostics.items.len);
    }
}

test "diagnostics escape bytes and truncate without requiring log delivery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var effects = try Effects.init(allocator);
    const large = try allocator.alloc(u8, messages.encoded_size_max + 1);
    @memset(large, '\n');
    @memcpy(large[0..6], "\"\\\x00\xff\n\r");
    submission.diagnose(
        allocator,
        .submission,
        "MalformedEnvelope",
        "source-1",
        large,
        null,
        &effects,
    );
    const diagnostic = effects.diagnostics.items[0];
    try std.testing.expect(diagnostic.len <= 8192);
    const parsed = try seat.parse_value(allocator, diagnostic, 8192);
    try std.testing.expect(parsed.object.get("truncated").?.bool);
    try std.testing.expectEqual(
        @as(i64, @intCast(large.len)),
        parsed.object.get("body_length").?.integer,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, parsed.object.get("preview").?.string, "\\xff") != null,
    );
    effects.log_error = true;
    try std.testing.expectEqualStrings(
        ack,
        try completion.handle_invocation(
            allocator,
            try sqs_event(allocator, "bad-envelope"),
            &.{ .operations_table = "Operations", .now = 1001 },
            &effects,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), effects.updates);
}

test "conflicting identity and malformed terminal readback diagnose without mutation" {
    for ([_][]const u8{ "tenant", "name", "id", "state" }) |field_name| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var effects = try Effects.init(allocator);
        const rejection = try submitted_rejection(allocator, &effects, reserve_body);
        const item = try allocator.dupe(events.Attribute, effects.operation_item.?);
        for (item) |*field| {
            if (!std.mem.eql(u8, field.key, field_name)) continue;
            const value: []const u8 = if (std.mem.eql(
                u8,
                field_name,
                "state",
            )) "COMPLETED" else if (std.mem.eql(
                u8,
                field_name,
                "id",
            )) "00000000-0000-0000-0000-000000000099" else "foreign";
            field.value = .{ .s = value };
        }
        effects.operation_item = item;
        const response = try completion.handle_invocation(
            allocator,
            try sqs_event(allocator, rejection),
            &.{ .operations_table = "Operations", .now = 1001 },
            &effects,
        );
        try std.testing.expectEqualStrings(ack, response);
        try std.testing.expectEqual(@as(usize, 1), effects.diagnostics.items.len);
        try std.testing.expectEqualDeep(item, effects.operation_item.?);
    }
}

test "seat invocation adapters reject empty and multiple SQS records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var effects = try Effects.init(allocator);
    const empty = "{\"Records\":[]}";
    try std.testing.expectError(
        error.EmptySQSEvent,
        submission.handle_invocation(
            allocator,
            empty,
            &.{ .events_table = "Events", .completion_queue = "seat-completion" },
            &effects,
        ),
    );
    try std.testing.expectError(
        error.EmptySQSEvent,
        completion.handle_invocation(
            allocator,
            empty,
            &.{ .operations_table = "Operations", .now = 1001 },
            &effects,
        ),
    );
    const single = try seat.parse_value(allocator, try sqs_event(allocator, "{}"), 4096);
    const record = single.object.get("Records").?.array.items[0];
    const multiple = try std.json.Stringify.valueAlloc(
        allocator,
        .{ .Records = &.{ record, record } },
        .{},
    );
    try std.testing.expectError(
        error.TooManyRecords,
        submission.handle_invocation(
            allocator,
            multiple,
            &.{ .events_table = "Events", .completion_queue = "seat-completion" },
            &effects,
        ),
    );
    try std.testing.expectError(
        error.TooManyRecords,
        completion.handle_invocation(
            allocator,
            multiple,
            &.{ .operations_table = "Operations", .now = 1001 },
            &effects,
        ),
    );
}
