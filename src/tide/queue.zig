//! A clock's queue of what is scheduled on it: a binary min-heap by the tick
//! each comes due, then by the order it was scheduled in, so equal ticks come
//! due in a fixed order. It holds slot numbers and keeps each slot's place in
//! the heap, so a schedule is cancelled where it is, and the heap never holds
//! a dead entry. Its room is set when it is made; nothing allocates after.

const std = @import("std");

pub const none = std.math.maxInt(u32);

pub const Entry = struct {
    at: u64,
    order: u64,
    slot: u32,

    fn before(a: Entry, b: Entry) bool {
        return a.at < b.at or (a.at == b.at and a.order < b.order);
    }
};

pub const Queue = struct {
    items: []Entry,
    len: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, room: u32) error{OutOfMemory}!Queue {
        return .{ .items = try gpa.alloc(Entry, room) };
    }

    pub fn deinit(q: *Queue, gpa: std.mem.Allocator) void {
        gpa.free(q.items);
        q.* = undefined;
    }

    pub fn peek(q: *const Queue) ?Entry {
        return if (q.len == 0) null else q.items[0];
    }

    /// Adds `e`; `places[slot]` keeps its place. The queue has room: a slot is in one queue at most.
    pub fn push(q: *Queue, places: []u32, e: Entry) void {
        std.debug.assert(q.len < q.items.len);
        std.debug.assert(places[e.slot] == none);
        q.items[q.len] = e;
        places[e.slot] = q.len;
        q.len += 1;
        q.up(places, q.len - 1);
    }

    /// Takes the entry at `place` out.
    pub fn remove(q: *Queue, places: []u32, place: u32) Entry {
        std.debug.assert(place < q.len);
        const out = q.items[place];
        places[out.slot] = none;
        q.len -= 1;
        if (place == q.len) return out;
        q.items[place] = q.items[q.len];
        places[q.items[place].slot] = place;
        q.down(places, place);
        q.up(places, place);
        return out;
    }

    fn up(q: *Queue, places: []u32, from: u32) void {
        var i = from;
        while (i > 0) {
            const parent = (i - 1) / 2;
            if (!q.items[i].before(q.items[parent])) return;
            q.swap(places, i, parent);
            i = parent;
        }
    }

    fn down(q: *Queue, places: []u32, from: u32) void {
        var i = from;
        while (true) {
            const l = 2 * i + 1;
            if (l >= q.len) return;
            const r = l + 1;
            const least = if (r < q.len and q.items[r].before(q.items[l])) r else l;
            if (!q.items[least].before(q.items[i])) return;
            q.swap(places, i, least);
            i = least;
        }
    }

    fn swap(q: *Queue, places: []u32, a: u32, b: u32) void {
        std.mem.swap(Entry, &q.items[a], &q.items[b]);
        places[q.items[a].slot] = a;
        places[q.items[b].slot] = b;
    }
};

test "entries come out by tick, then by order, whatever was removed" {
    const gpa = std.testing.allocator;
    var q = try Queue.init(gpa, 16);
    defer q.deinit(gpa);
    var places: [16]u32 = @splat(none);
    const ats = [_]u64{ 9, 3, 7, 3, 1, 8, 2, 7 };
    for (ats, 0..) |at, i| q.push(&places, .{ .at = at, .order = i, .slot = @intCast(i) });
    _ = q.remove(&places, places[5]); // the 8
    var out: [7]u64 = undefined;
    var orders: [7]u64 = undefined;
    for (&out, &orders) |*a, *o| {
        const e = q.remove(&places, 0);
        a.* = e.at;
        o.* = e.order;
    }
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3, 3, 7, 7, 9 }, &out);
    try std.testing.expectEqualSlices(u64, &.{ 4, 6, 1, 3, 2, 7, 0 }, &orders);
    try std.testing.expect(q.peek() == null);
    for (places) |p| try std.testing.expectEqual(none, p);
}
