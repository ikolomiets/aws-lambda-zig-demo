const std = @import("std");
const operation = @import("operation");
const seat = @import("seat_reservation");
const Allocator = std.mem.Allocator;

pub const memory_size_max = 1024 * 1024;

pub const ReadyCache = struct {
    allocator: Allocator,
    entries: []Entry,
    count: usize = 0,
    newest: ?*Entry = null,
    oldest: ?*Entry = null,

    pub const budget_bytes_max = memory_size_max;

    /// Fixed slots include worst-case keys/classes and all list links. One allocation,
    /// no hash table or per-entry allocations, and no retained request-arena storage.
    pub fn init(self: *ReadyCache, allocator: Allocator, budget_bytes: usize) !void {
        if (budget_bytes < @sizeOf(ReadyCache) or budget_bytes > memory_size_max) {
            return error.InvalidCacheBudget;
        }
        const capacity = @divFloor(budget_bytes - @sizeOf(ReadyCache), @sizeOf(Entry));
        self.* = .{ .allocator = allocator, .entries = try allocator.alloc(Entry, capacity) };
        std.debug.assert(self.memory_size() <= budget_bytes);
    }

    pub fn deinit(self: *ReadyCache) void {
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn memory_size(self: *const ReadyCache) usize {
        return @sizeOf(ReadyCache) + self.entries.len * @sizeOf(Entry);
    }

    /// Returned slices borrow cache storage until the next insertion or deinit.
    pub fn get(self: *ReadyCache, key: *const seat.EventKey) !?seat.Event {
        try seat.validate_key(key);
        var cursor = self.newest;
        for (0..self.count) |_| {
            const entry = cursor.?;
            cursor = entry.next;
            if (entry.event.event_id != key.event_id) continue;
            if (!std.mem.eql(u8, entry.event.tenant, key.tenant)) continue;
            std.debug.assert(entry.event.state == .ready);
            self.remove(entry);
            self.prepend(entry);
            return entry.event;
        }
        std.debug.assert(cursor == null);
        return null;
    }

    pub fn put(self: *ReadyCache, event: *const seat.Event) !void {
        try seat.validate_event(event);
        if (event.state != .ready) return;
        // Budgets smaller than one complete slot bypass caching, without evictions.
        if (self.entries.len == 0) return;
        if (try self.get(&.{ .tenant = event.tenant, .event_id = event.event_id }) != null) return;
        const entry = if (self.count < self.entries.len) entry: {
            const unused = &self.entries[self.count];
            self.count += 1;
            break :entry unused;
        } else entry: {
            const victim = self.oldest.?;
            self.remove(victim);
            break :entry victim;
        };
        entry.event = event.*;
        @memcpy(entry.tenant[0..event.tenant.len], event.tenant);
        @memcpy(entry.classes[0..event.classes.len], event.classes);
        entry.event.tenant = entry.tenant[0..event.tenant.len];
        entry.event.classes = entry.classes[0..event.classes.len];
        self.prepend(entry);
        std.debug.assert(self.count <= self.entries.len);
    }

    fn remove(self: *ReadyCache, entry: *Entry) void {
        if (entry.previous) |previous| previous.next = entry.next else self.newest = entry.next;
        if (entry.next) |next| next.previous = entry.previous else self.oldest = entry.previous;
    }

    fn prepend(self: *ReadyCache, entry: *Entry) void {
        entry.previous = null;
        entry.next = self.newest;
        if (self.newest) |newest| newest.previous = entry else self.oldest = entry;
        self.newest = entry;
        std.debug.assert(self.newest.?.previous == null);
        std.debug.assert(self.oldest.?.next == null);
    }
};

const Entry = struct {
    event: seat.Event,
    tenant: [operation.tenant_size_max]u8,
    classes: [seat.class_count_max]seat.EventClass,
    previous: ?*Entry,
    next: ?*Entry,
};

comptime {
    std.debug.assert(@sizeOf(ReadyCache) + @sizeOf(Entry) <= memory_size_max);
}

fn test_event(arena: Allocator) !seat.Event {
    return .{
        .tenant = try arena.dupe(u8, "theatre"),
        .event_id = 2,
        .ledger = 1001,
        .timeout_seconds = 60,
        .capacity_account_id = 11,
        .allocation_account_id = 12,
        .classes = try arena.dupe(seat.EventClass, &.{.{
            .tag = try seat.Tag.init("general"),
            .total = 10,
            .tb_account_id = 13,
        }}),
        .state = .ready,
    };
}

test "ready cache owns metadata beyond the request arena and isolates the complete key" {
    var cache: ReadyCache = undefined;
    try cache.init(std.testing.allocator, memory_size_max);
    defer cache.deinit();
    {
        var request = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer request.deinit();
        var event = try test_event(request.allocator());
        try cache.put(&event);
        // Overwrite source slices before freeing the request to expose borrowed storage.
        @memset(@constCast(event.tenant), 'x');
        @constCast(event.classes)[0].total = 1;
    }
    const saved = (try cache.get(&.{ .tenant = "theatre", .event_id = 2 })).?;
    try std.testing.expectEqualStrings("theatre", saved.tenant);
    try std.testing.expectEqualStrings("general", saved.classes[0].tag.slice());
    try std.testing.expectEqual(@as(u32, 10), saved.classes[0].total);
    try std.testing.expectEqual(@as(u128, 13), saved.classes[0].tb_account_id);
    try std.testing.expectEqual(@as(?seat.Event, null), try cache.get(&.{
        .tenant = "other",
        .event_id = 2,
    }));
    try std.testing.expectEqual(@as(?seat.Event, null), try cache.get(&.{
        .tenant = "theatre",
        .event_id = 3,
    }));
}

test "ready cache evicts the least recently used key including promotions and tenant collisions" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    var cache: ReadyCache = undefined;
    try cache.init(std.testing.allocator, @sizeOf(ReadyCache) + 2 * @sizeOf(Entry));
    defer cache.deinit();
    var first = try test_event(storage.allocator());
    var second = first;
    second.tenant = "other";
    second.ledger = 1002;
    try cache.put(&first);
    try cache.put(&second);
    try std.testing.expectEqual(@as(u32, 1001), (try cache.get(&.{
        .tenant = "theatre",
        .event_id = 2,
    })).?.ledger);
    var third = first;
    third.event_id = (@as(u128, 1) << 127) + 2;
    try cache.put(&third);
    try std.testing.expect(try cache.get(&.{ .tenant = "other", .event_id = 2 }) == null);
    try std.testing.expect(try cache.get(&.{ .tenant = "theatre", .event_id = 2 }) != null);
    try std.testing.expect(try cache.get(&.{
        .tenant = "theatre",
        .event_id = third.event_id,
    }) != null);
    // Re-insertion is a hit and promotes rather than consuming another slot.
    try cache.put(&first);
    try cache.put(&second);
    try std.testing.expect(try cache.get(&.{
        .tenant = "theatre",
        .event_id = third.event_id,
    }) == null);
    try std.testing.expectEqual(@as(u32, 1002), (try cache.get(&.{
        .tenant = "other",
        .event_id = 2,
    })).?.ledger);
}

test "ready cache accounts for every byte and never allocates during hits inserts or eviction" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    var event = try test_event(storage.allocator());
    // The allocator permits exactly the advertised storage, with no room for a hidden index.
    var bytes: [memory_size_max - @sizeOf(ReadyCache)]u8 align(@alignOf(Entry)) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&bytes);
    var failing = std.testing.FailingAllocator.init(fixed.allocator(), .{ .fail_index = 1 });
    {
        var cache: ReadyCache = undefined;
        try cache.init(failing.allocator(), memory_size_max);
        defer cache.deinit();
        for (0..2 * @divFloor(bytes.len, @sizeOf(Entry))) |index| {
            event.event_id = index;
            try cache.put(&event);
            try std.testing.expect(try cache.get(&.{
                .tenant = event.tenant,
                .event_id = event.event_id,
            }) != null);
        }
        try std.testing.expectEqual(@as(usize, 1), failing.allocations);
        try std.testing.expectEqual(
            failing.allocated_bytes + @sizeOf(ReadyCache),
            cache.memory_size(),
        );
        try std.testing.expectEqual(fixed.end_index + @sizeOf(ReadyCache), cache.memory_size());
        try std.testing.expect(cache.memory_size() <= memory_size_max);
    }
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "ready cache exact slot boundary and oversized bypass respect the total budget" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const event = try test_event(storage.allocator());
    const exact_bytes = @sizeOf(ReadyCache) + @sizeOf(Entry);
    for ([_]usize{ exact_bytes - 1, exact_bytes }) |budget_bytes| {
        var cache: ReadyCache = undefined;
        try cache.init(std.testing.allocator, budget_bytes);
        defer cache.deinit();
        try cache.put(&event);
        const saved = try cache.get(&.{ .tenant = "theatre", .event_id = 2 });
        try std.testing.expectEqual(budget_bytes == exact_bytes, saved != null);
        try std.testing.expect(cache.memory_size() <= budget_bytes);
        if (saved != null) try std.testing.expectEqual(exact_bytes, cache.memory_size());
    }
}

test "ready cache retains maximum tenant and every class without borrowing source arrays" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    var event = try test_event(storage.allocator());
    var classes: [seat.class_count_max]seat.EventClass = undefined;
    for (&classes, 0..) |*class, index| {
        var text: [2]u8 = undefined;
        class.* = .{
            .tag = try seat.Tag.init(try std.fmt.bufPrint(&text, "{d:0>2}", .{index})),
            .total = std.math.maxInt(u32),
            .tb_account_id = index + 100,
        };
    }
    event.tenant = "é" ** 32;
    event.classes = &classes;
    var cache: ReadyCache = undefined;
    try cache.init(std.testing.allocator, memory_size_max);
    defer cache.deinit();
    try cache.put(&event);
    for (&classes) |*class| class.total = 1;
    const saved = (try cache.get(&.{ .tenant = "é" ** 32, .event_id = 2 })).?;
    try std.testing.expectEqual(@as(usize, 64), saved.tenant.len);
    try std.testing.expectEqual(@as(usize, 31), saved.classes.len);
    try std.testing.expectEqualStrings("00", saved.classes[0].tag.slice());
    try std.testing.expectEqualStrings("30", saved.classes[30].tag.slice());
    try std.testing.expectEqual(seat.supply_max, try seat.total_supply(&saved));
}

test "ready cache excludes non ready and invalid metadata and handles allocation failures" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    var event = try test_event(storage.allocator());
    var cache: ReadyCache = undefined;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        cache.init(failing.allocator(), memory_size_max),
    );
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
    try std.testing.expectError(error.InvalidCacheBudget, cache.init(
        std.testing.allocator,
        memory_size_max + 1,
    ));
    try cache.init(std.testing.allocator, memory_size_max);
    defer cache.deinit();
    for ([_]seat.EventState{ .creating, .failed }) |state| {
        event.state = state;
        try cache.put(&event);
        try std.testing.expect(try cache.get(&.{ .tenant = "theatre", .event_id = 2 }) == null);
    }
    event.state = .ready;
    event.ledger = 0;
    try std.testing.expectError(error.InvalidNumber, cache.put(&event));
    try std.testing.expect(try cache.get(&.{ .tenant = "theatre", .event_id = 2 }) == null);
    event.ledger = 1001;
    try cache.put(&event);
    try std.testing.expect(try cache.get(&.{ .tenant = "theatre", .event_id = 2 }) != null);
}
