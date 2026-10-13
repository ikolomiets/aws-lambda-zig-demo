const std = @import("std");
const aws = @import("aws");
const dynamodb = @import("dynamodb");
const Allocator = std.mem.Allocator;
pub const Attribute = aws.map.MapEntry(dynamodb.types.AttributeValue);

pub const counter_id = "global";
pub const initial_high_water: u32 = 1000;
pub const allocation_attempts_max: u8 = 4;
pub const response_size_max = 8192;
pub const initialize_condition = "attribute_not_exists(#counter_id)";
pub const allocation_condition = "attribute_exists(#counter_id) AND " ++
    "attribute_type(#high_water, :number_type) AND #high_water = :expected AND " ++
    "#high_water >= :initial AND #high_water < :maximum";
pub const allocation_update = "SET #high_water = #high_water + :one";

comptime {
    std.debug.assert(initial_high_water > 0);
    std.debug.assert(initial_high_water < std.math.maxInt(u32));
    std.debug.assert(allocation_attempts_max > 0);
}

/// The selected physical table is the complete binding. Config outlives this client;
/// the counter owns its table name, while each method uses the caller's request arena.
pub const Counter = struct {
    client: dynamodb.Client,
    table_name: []const u8,

    pub fn init(
        target: *Counter,
        allocator: Allocator,
        config: *aws.Config,
        environment: *const std.process.Environ.Map,
    ) !void {
        const table = environment.get("LEDGER_COUNTER_TABLE_NAME") orelse
            return error.InvalidConfiguration;
        try validate_table_name(table);
        target.* = .{
            .client = dynamodb.Client.initWithOptions(allocator, config, .{
                // A retry after a lost UpdateItem response could consume another ledger.
                .max_attempts = 1,
                .max_response_size = response_size_max,
                .keep_alive = true,
            }),
            .table_name = try allocator.dupe(u8, table),
        };
        std.debug.assert(target.client.config == config);
        std.debug.assert(target.client.options.max_attempts.? == 1);
    }

    pub fn deinit(self: *Counter) void {
        self.client.allocator.free(self.table_name);
        self.client.deinit();
        self.* = undefined;
    }

    pub fn setup(self: *Counter, arena: Allocator) !u32 {
        var backend: SDKBackend = .{ .client = &self.client };
        return initialize(arena, self.table_name, &backend);
    }

    pub fn read(self: *Counter, arena: Allocator) !u32 {
        var backend: SDKBackend = .{ .client = &self.client };
        return read_counter(arena, self.table_name, &backend);
    }

    pub fn allocate(self: *Counter, arena: Allocator) !u32 {
        var backend: SDKBackend = .{ .client = &self.client };
        return allocate_ledger(arena, self.table_name, &backend);
    }
};

// Keep the effect-free test seam and client methods named for their callers.
const read_counter = read;
const allocate_ledger = allocate;

const SDKBackend = struct {
    client: *dynamodb.Client,

    fn put(self: *SDKBackend, arena: Allocator, request: dynamodb.PutItemInput) !void {
        var diagnostic: dynamodb.ServiceError = undefined;
        _ = self.client.putItem(arena, request, .{ .diagnostic = &diagnostic }) catch |err| {
            if (err != error.ServiceError) return error.MutationUncertain;
            defer diagnostic.deinit();
            return mutation_error(diagnostic.kind, error.CounterExists);
        };
    }

    fn get(
        self: *SDKBackend,
        arena: Allocator,
        request: dynamodb.GetItemInput,
    ) !?[]const Attribute {
        var diagnostic: dynamodb.ServiceError = undefined;
        const response = self.client.getItem(
            arena,
            request,
            .{ .diagnostic = &diagnostic },
        ) catch |err| {
            if (err == error.ServiceError) diagnostic.deinit();
            return error.AWSFailure;
        };
        return response.item;
    }

    fn update(
        self: *SDKBackend,
        arena: Allocator,
        request: dynamodb.UpdateItemInput,
    ) !?[]const Attribute {
        var diagnostic: dynamodb.ServiceError = undefined;
        const response = self.client.updateItem(
            arena,
            request,
            .{ .diagnostic = &diagnostic },
        ) catch |err| {
            if (err != error.ServiceError) return error.MutationUncertain;
            defer diagnostic.deinit();
            return mutation_error(diagnostic.kind, error.CounterChanged);
        };
        return response.attributes;
    }
};

fn mutation_error(kind: dynamodb.ServiceError.Kind, conflict: anyerror) anyerror {
    return switch (kind) {
        .conditional_check_failed_exception => conflict,
        .provisioned_throughput_exceeded_exception,
        .request_limit_exceeded,
        .throttling_exception,
        => error.CounterTransient,
        .internal_server_error => error.MutationUncertain,
        .unknown => |unknown| if (unknown.http_status >= 400 and unknown.http_status < 500 and
            unknown.http_status != 408) error.AWSFailure else error.MutationUncertain,
        else => error.AWSFailure,
    };
}

pub fn initialize(arena: Allocator, table: []const u8, backend: anytype) !u32 {
    const request = try initialize_request(arena, table);
    backend.put(arena, request) catch |err| {
        if (err == error.CounterExists) return read(arena, table, backend);
        if (err == error.CounterTransient or err == error.AWSFailure) return err;
        return error.InitializationUncertain;
    };
    return initial_high_water;
}

pub fn read(arena: Allocator, table: []const u8, backend: anytype) !u32 {
    const request = try read_request(arena, table);
    const item = try backend.get(arena, request) orelse return error.CounterMissing;
    return decode_item(item);
}

/// A validated read guards integer storage. Its exact-value condition makes the increment
/// atomic across concurrent callers; only the returned update can allocate a ledger.
/// Retry only a definite conditional rejection, never a failed or malformed update response.
pub fn allocate(arena: Allocator, table: []const u8, backend: anytype) !u32 {
    for (0..allocation_attempts_max) |_| {
        const previous = try read(arena, table, backend);
        if (previous == std.math.maxInt(u32)) return error.CounterExhausted;
        const request = try allocation_request(arena, table, previous);
        const item = backend.update(arena, request) catch |err| {
            if (err == error.CounterChanged) continue;
            if (err == error.CounterTransient or err == error.AWSFailure) return err;
            return error.AllocationUncertain;
        } orelse return error.AllocationUncertain;
        const updated = decode_item(item) catch return error.AllocationUncertain;
        if (updated != previous + 1) return error.AllocationUncertain;
        std.debug.assert(updated > initial_high_water);
        return updated;
    }
    return error.CounterContended;
}

pub fn validate_table_name(table: []const u8) !void {
    if (table.len < 3 or table.len > 255) return error.InvalidConfiguration;
    for (table) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.') continue;
        return error.InvalidConfiguration;
    }
}

pub fn read_request(arena: Allocator, table: []const u8) !dynamodb.GetItemInput {
    try validate_table_name(table);
    const key = try arena.alloc(Attribute, 1);
    key[0] = .{ .key = "counter_id", .value = .{ .s = counter_id } };
    return .{ .table_name = try arena.dupe(u8, table), .key = key, .consistent_read = true };
}

pub fn initialize_request(arena: Allocator, table: []const u8) !dynamodb.PutItemInput {
    try validate_table_name(table);
    const names = try arena.alloc(aws.map.StringMapEntry, 1);
    names[0] = .{ .key = "#counter_id", .value = "counter_id" };
    return .{
        .table_name = try arena.dupe(u8, table),
        .item = try encode_item(arena, initial_high_water),
        .condition_expression = initialize_condition,
        .expression_attribute_names = names,
    };
}

pub fn allocation_request(
    arena: Allocator,
    table: []const u8,
    previous: u32,
) !dynamodb.UpdateItemInput {
    if (previous < initial_high_water) return error.CounterCorrupt;
    if (previous == std.math.maxInt(u32)) return error.CounterExhausted;
    const read_input = try read_request(arena, table);
    const names = try arena.alloc(aws.map.StringMapEntry, 2);
    names[0] = .{ .key = "#counter_id", .value = "counter_id" };
    names[1] = .{ .key = "#high_water", .value = "high_water" };
    const values = try arena.alloc(Attribute, 5);
    values[0] = .{ .key = ":expected", .value = .{
        .n = try std.fmt.allocPrint(arena, "{d}", .{previous}),
    } };
    values[1] = .{ .key = ":initial", .value = .{ .n = "1000" } };
    values[2] = .{ .key = ":maximum", .value = .{ .n = "4294967295" } };
    values[3] = .{ .key = ":one", .value = .{ .n = "1" } };
    values[4] = .{ .key = ":number_type", .value = .{ .s = "N" } };
    return .{
        .table_name = read_input.table_name,
        .key = read_input.key,
        .condition_expression = allocation_condition,
        .update_expression = allocation_update,
        .expression_attribute_names = names,
        .expression_attribute_values = values,
        .return_values = .all_new,
    };
}

pub fn encode_item(arena: Allocator, high_water: u32) ![]const Attribute {
    if (high_water < initial_high_water) return error.CounterCorrupt;
    const item = try arena.alloc(Attribute, 2);
    item[0] = .{ .key = "counter_id", .value = .{ .s = counter_id } };
    item[1] = .{ .key = "high_water", .value = .{
        .n = try std.fmt.allocPrint(arena, "{d}", .{high_water}),
    } };
    return item;
}

pub fn decode_item(item: []const Attribute) !u32 {
    if (item.len != 2) return error.CounterCorrupt;
    var key_found = false;
    var high_water: ?u32 = null;
    for (item) |attribute| {
        if (std.mem.eql(u8, attribute.key, "counter_id")) {
            if (key_found or attribute.value != .s) return error.CounterCorrupt;
            const key = attribute.value.s orelse return error.CounterCorrupt;
            if (!std.mem.eql(u8, key, counter_id)) return error.CounterCorrupt;
            key_found = true;
        } else if (std.mem.eql(u8, attribute.key, "high_water")) {
            if (high_water != null or attribute.value != .n) return error.CounterCorrupt;
            const text = attribute.value.n orelse return error.CounterCorrupt;
            if (text.len == 0 or text.len > 10) return error.CounterCorrupt;
            for (text) |byte| if (!std.ascii.isDigit(byte)) return error.CounterCorrupt;
            high_water = std.fmt.parseInt(u32, text, 10) catch return error.CounterCorrupt;
            if (high_water.? < initial_high_water) return error.CounterCorrupt;
        } else return error.CounterCorrupt;
    }
    if (!key_found) return error.CounterCorrupt;
    return high_water orelse error.CounterCorrupt;
}

test "explicit setup preserves the global counter and first allocation returns 1001" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var database: TestDatabase = .{};
    const memory = arena.allocator();
    try std.testing.expectEqual(
        @as(u32, 1000),
        try initialize(memory, "shared-ledgers", &database),
    );
    try std.testing.expectEqual(@as(u32, 1001), try allocate(memory, "shared-ledgers", &database));
    try std.testing.expectEqual(
        @as(u32, 1001),
        try initialize(memory, "shared-ledgers", &database),
    );
    try std.testing.expectEqual(@as(u32, 1001), try read(memory, "shared-ledgers", &database));
}

const TestDatabase = struct {
    table_name: []const u8 = "shared-ledgers",
    high_water: ?u32 = null,
    put_error: ?anyerror = null,
    get_error: ?anyerror = null,
    update_error: ?anyerror = null,
    lose_after_put: bool = false,
    lose_after_update: bool = false,
    conflicts_remaining: u8 = 0,
    corrupt_item: ?[]const Attribute = null,
    invalid_update_response: bool = false,
    response_high_water: ?u32 = null,
    puts: u8 = 0,
    gets: u8 = 0,
    updates: u8 = 0,

    pub fn put(self: *TestDatabase, _: Allocator, request: dynamodb.PutItemInput) !void {
        self.puts += 1;
        try std.testing.expectEqualStrings(self.table_name, request.table_name);
        try std.testing.expectEqualStrings(
            "attribute_not_exists(#counter_id)",
            request.condition_expression.?,
        );
        try std.testing.expectEqual(@as(usize, 2), request.item.len);
        try std.testing.expectEqualStrings("counter_id", request.item[0].key);
        try std.testing.expectEqualStrings("global", request.item[0].value.s.?);
        try std.testing.expectEqualStrings("1000", request.item[1].value.n.?);
        if (self.put_error) |err| return err;
        if (self.high_water != null or self.corrupt_item != null) return error.CounterExists;
        self.high_water = 1000;
        if (self.lose_after_put) return error.MutationUncertain;
    }

    pub fn get(
        self: *TestDatabase,
        arena: Allocator,
        request: dynamodb.GetItemInput,
    ) !?[]const Attribute {
        self.gets += 1;
        try std.testing.expectEqualStrings(self.table_name, request.table_name);
        try std.testing.expectEqual(true, request.consistent_read.?);
        try std.testing.expectEqual(@as(usize, 1), request.key.len);
        try std.testing.expectEqualStrings("global", request.key[0].value.s.?);
        if (self.get_error) |err| return err;
        if (self.corrupt_item) |item| return item;
        return if (self.high_water) |value| try encode_item(arena, value) else null;
    }

    pub fn update(
        self: *TestDatabase,
        arena: Allocator,
        request: dynamodb.UpdateItemInput,
    ) !?[]const Attribute {
        self.updates += 1;
        try std.testing.expectEqualStrings(self.table_name, request.table_name);
        try std.testing.expectEqual(dynamodb.types.ReturnValue.all_new, request.return_values.?);
        try std.testing.expectEqualStrings(
            "attribute_exists(#counter_id) AND attribute_type(#high_water, :number_type) AND " ++
                "#high_water = :expected AND #high_water >= :initial AND #high_water < :maximum",
            request.condition_expression.?,
        );
        try std.testing.expectEqualStrings(
            "SET #high_water = #high_water + :one",
            request.update_expression.?,
        );
        try std.testing.expectEqual(@as(usize, 2), request.expression_attribute_names.?.len);
        try std.testing.expectEqualStrings(
            "counter_id",
            request.expression_attribute_names.?[0].value,
        );
        try std.testing.expectEqualStrings(
            "high_water",
            request.expression_attribute_names.?[1].value,
        );
        try std.testing.expectEqual(@as(usize, 1), request.key.len);
        try std.testing.expectEqualStrings("counter_id", request.key[0].key);
        try std.testing.expectEqualStrings("global", request.key[0].value.s.?);
        const values = request.expression_attribute_values.?;
        try std.testing.expectEqualStrings("1000", values[1].value.n.?);
        try std.testing.expectEqualStrings("4294967295", values[2].value.n.?);
        try std.testing.expectEqualStrings("1", values[3].value.n.?);
        try std.testing.expectEqualStrings("N", values[4].value.s.?);
        if (self.update_error) |err| return err;
        const current = self.high_water orelse return error.CounterChanged;
        if (self.conflicts_remaining > 0) {
            self.conflicts_remaining -= 1;
            self.high_water = current + 1;
            return error.CounterChanged;
        }
        const expected = try std.fmt.parseInt(u32, values[0].value.n.?, 10);
        if (current != expected) return error.CounterChanged;
        if (current == std.math.maxInt(u32)) return error.CounterChanged;
        self.high_water = current + 1;
        if (self.lose_after_update) return error.MutationUncertain;
        if (self.invalid_update_response) return null;
        if (self.response_high_water) |value| return try encode_item(arena, value);
        return try encode_item(arena, self.high_water.?);
    }
};

test "deployments tenants and different native clusters interleave one global sequence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var database: TestDatabase = .{};
    const participants = [_]struct {
        deployment: []const u8,
        tenant: []const u8,
        native_address: []const u8,
        native_cluster_id: u128,
        counter_table: []const u8,
    }{
        .{
            .deployment = "owner",
            .tenant = "a",
            .native_address = "cluster-a",
            .native_cluster_id = 1,
            .counter_table = "shared-ledgers",
        },
        .{
            .deployment = "reference",
            .tenant = "b",
            .native_address = "cluster-b",
            .native_cluster_id = 2,
            .counter_table = "shared-ledgers",
        },
        .{
            .deployment = "other-reference",
            .tenant = "a",
            .native_address = "cluster-c",
            .native_cluster_id = 1,
            .counter_table = "shared-ledgers",
        },
    };
    _ = try initialize(arena.allocator(), participants[0].counter_table, &database);
    const expected = [_]u32{ 1001, 1002, 1003, 1004, 1005, 1006 };
    for (expected, 0..) |ledger, index| {
        const participant = participants[index % participants.len];
        try std.testing.expectEqual(
            ledger,
            try allocate(arena.allocator(), participant.counter_table, &database),
        );
    }
    try std.testing.expectEqual(
        @as(u32, 1006),
        try read(arena.allocator(), "shared-ledgers", &database),
    );
    // A separate physical table is a separate allocator, independent of native cluster selection.
    var separate: TestDatabase = .{ .table_name = "separate-ledgers" };
    _ = try initialize(arena.allocator(), "separate-ledgers", &separate);
    try std.testing.expectEqual(
        @as(u32, 1001),
        try allocate(arena.allocator(), "separate-ledgers", &separate),
    );
}

test "missing corrupt and exhausted counters never initialize or mutate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var database: TestDatabase = .{};
    try std.testing.expectError(
        error.CounterMissing,
        allocate(memory, "shared-ledgers", &database),
    );
    try std.testing.expectEqual(@as(u8, 0), database.puts);
    try std.testing.expectEqual(@as(u8, 0), database.updates);
    database.high_water = std.math.maxInt(u32) - 1;
    try std.testing.expectEqual(
        @as(u32, 4294967295),
        try allocate(memory, "shared-ledgers", &database),
    );
    try std.testing.expectError(
        error.CounterExhausted,
        allocate(memory, "shared-ledgers", &database),
    );
    const updates = database.updates;
    const invalid = [_][]const u8{
        "", "999", "4294967296", "-1000", "+1000", "1000.5", "1e3", " 1000",
    };
    for (invalid) |number| {
        const item = try memory.alloc(Attribute, 2);
        item[0] = .{ .key = "counter_id", .value = .{ .s = "global" } };
        item[1] = .{ .key = "high_water", .value = .{ .n = number } };
        database.corrupt_item = item;
        try std.testing.expectError(
            error.CounterCorrupt,
            read(memory, "shared-ledgers", &database),
        );
        try std.testing.expectError(
            error.CounterCorrupt,
            allocate(memory, "shared-ledgers", &database),
        );
        try std.testing.expectError(
            error.CounterCorrupt,
            initialize(memory, "shared-ledgers", &database),
        );
    }
    try std.testing.expectEqual(updates, database.updates);
    try std.testing.expectEqual(@as(u32, 4294967295), database.high_water.?);
}

test "uncertain allocation responses permit gaps and never trigger readback or retry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var database: TestDatabase = .{ .high_water = 1000, .update_error = error.MutationUncertain };
    try std.testing.expectError(
        error.AllocationUncertain,
        allocate(memory, "shared-ledgers", &database),
    );
    try std.testing.expectEqual(@as(u32, 1000), database.high_water.?);
    try std.testing.expectEqual(@as(u8, 1), database.gets);
    try std.testing.expectEqual(@as(u8, 1), database.updates);
    database.update_error = null;
    database.lose_after_update = true;
    try std.testing.expectError(
        error.AllocationUncertain,
        allocate(memory, "shared-ledgers", &database),
    );
    try std.testing.expectEqual(@as(u8, 2), database.gets);
    try std.testing.expectEqual(@as(u8, 2), database.updates);
    database.lose_after_update = false;
    // Reading 1001 proves only current state, not who allocated it.
    try std.testing.expectEqual(@as(u32, 1001), try read(memory, "shared-ledgers", &database));
    try std.testing.expectEqual(@as(u32, 1002), try allocate(memory, "shared-ledgers", &database));
    database.invalid_update_response = true;
    try std.testing.expectError(
        error.AllocationUncertain,
        allocate(memory, "shared-ledgers", &database),
    );
    try std.testing.expectEqual(@as(u32, 1003), database.high_water.?);
    database.invalid_update_response = false;
    database.response_high_water = 9000;
    try std.testing.expectError(
        error.AllocationUncertain,
        allocate(memory, "shared-ledgers", &database),
    );
    try std.testing.expectEqual(@as(u32, 1004), database.high_water.?);
}

test "only definite concurrent conditional rejections permit bounded retries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var database: TestDatabase = .{ .high_water = 1000, .conflicts_remaining = 1 };
    const memory = arena.allocator();
    try std.testing.expectEqual(@as(u32, 1002), try allocate(memory, "shared-ledgers", &database));
    database.conflicts_remaining = allocation_attempts_max;
    try std.testing.expectError(
        error.CounterContended,
        allocate(memory, "shared-ledgers", &database),
    );
    try std.testing.expectEqual(@as(u8, 6), database.updates);
    database.update_error = error.CounterTransient;
    try std.testing.expectError(
        error.CounterTransient,
        allocate(memory, "shared-ledgers", &database),
    );
    try std.testing.expectEqual(@as(u8, 7), database.updates);
    database.get_error = error.AWSFailure;
    try std.testing.expectError(error.AWSFailure, allocate(memory, "shared-ledgers", &database));
    try std.testing.expectEqual(@as(u8, 7), database.updates);
}

test "uncertain first-time setup can be rerun explicitly without replacing saved state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var database: TestDatabase = .{ .put_error = error.MutationUncertain };
    const memory = arena.allocator();
    try std.testing.expectError(
        error.InitializationUncertain,
        initialize(memory, "shared-ledgers", &database),
    );
    try std.testing.expectEqual(@as(u8, 0), database.gets);
    database.put_error = null;
    database.lose_after_put = true;
    try std.testing.expectError(
        error.InitializationUncertain,
        initialize(memory, "shared-ledgers", &database),
    );
    try std.testing.expectEqual(@as(u8, 0), database.gets);
    database.lose_after_put = false;
    try std.testing.expectEqual(
        @as(u32, 1000),
        try initialize(memory, "shared-ledgers", &database),
    );
}

test "configured counter owns its table binding and requests outlive configuration storage" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    var config: aws.Config = undefined;
    var counter: Counter = undefined;
    try std.testing.expectError(
        error.InvalidConfiguration,
        Counter.init(&counter, std.testing.allocator, &config, &environment),
    );
    for ([_][]const u8{ "", "ab", "a" ** 256, "table with spaces", "x/y" }) |table| {
        try environment.put("LEDGER_COUNTER_TABLE_NAME", table);
        try std.testing.expectError(
            error.InvalidConfiguration,
            Counter.init(&counter, std.testing.allocator, &config, &environment),
        );
    }
    try environment.put("LEDGER_COUNTER_TABLE_NAME", "shared-ledgers");
    try Counter.init(&counter, std.testing.allocator, &config, &environment);
    defer counter.deinit();
    environment.deinit();
    try std.testing.expectEqualStrings("shared-ledgers", counter.table_name);
    try std.testing.expectEqual(@as(?u32, 1), counter.client.options.max_attempts);
    try std.testing.expectEqual(@as(usize, 8192), counter.client.options.max_response_size);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source = std.heap.ArenaAllocator.init(std.testing.allocator);
    const table = try source.allocator().dupe(u8, counter.table_name);
    const request = try allocation_request(arena.allocator(), table, 1000);
    const setup_request = try initialize_request(arena.allocator(), table);
    source.deinit();
    const encoded = try aws.json.jsonStringify(request, arena.allocator());
    try std.testing.expect(
        std.mem.indexOf(u8, encoded, "\"counter_id\":{\"S\":\"global\"}") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, encoded, "cluster_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"ReturnValues\":\"ALL_NEW\"") != null);
    try std.testing.expectEqualStrings("shared-ledgers", setup_request.table_name);
    try std.testing.expectEqual(@as(u32, 1000), try decode_item(setup_request.item));
}

test "stored records reject wrong keys types duplicates missing and additional attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const key: Attribute = .{ .key = "counter_id", .value = .{ .s = "global" } };
    const number: Attribute = .{ .key = "high_water", .value = .{ .n = "1000" } };
    const corrupt = [_][]const Attribute{
        &.{},
        &.{key},
        &.{number},
        &.{ key, key },
        &.{ number, number },
        &.{ key, number, .{ .key = "cluster_id", .value = .{ .n = "1" } } },
        &.{ .{ .key = "counter_id", .value = .{ .s = "other" } }, number },
        &.{ .{ .key = "counter_id", .value = .{ .n = "1" } }, number },
        &.{ .{ .key = "counter_id", .value = .{ .s = null } }, number },
        &.{ key, .{ .key = "high_water", .value = .{ .s = "1000" } } },
        &.{ key, .{ .key = "high_water", .value = .{ .n = null } } },
    };
    for (corrupt) |item| {
        var database: TestDatabase = .{ .corrupt_item = item };
        try std.testing.expectError(
            error.CounterCorrupt,
            read(memory, "shared-ledgers", &database),
        );
        try std.testing.expectError(
            error.CounterCorrupt,
            allocate(memory, "shared-ledgers", &database),
        );
        try std.testing.expectError(
            error.CounterCorrupt,
            initialize(memory, "shared-ledgers", &database),
        );
        try std.testing.expectEqual(@as(u8, 0), database.updates);
        try std.testing.expectEqual(@as(?u32, null), database.high_water);
    }
}
