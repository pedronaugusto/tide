//! What is scheduled: instants and recurrences, and when each comes due.
//!
//! A recurrence is kept as its declaration and the number of the next
//! occurrence, and each occurrence is worked out from them when it is
//! needed, one at a time: "every Sunday evening" for ever costs one slot.
//! Every so many ticks is plain arithmetic; every so many units of a calendar
//! falls at the same place in each unit, so "the first of every month" stays
//! the first however long the month, and a place past a shorter unit's end
//! falls on its last tick.

const std = @import("std");
const Calendar = @import("calendar.zig").Calendar;

/// What a recurrence does when a jump passes several of its occurrences.
pub const Policy = enum(u8) {
    /// Each comes due on its own, in order.
    each = 0,
    /// They come due as one, with how many it stands for.
    once = 1,
};

pub const Every = union(enum) {
    ticks: u64,
    /// Every `n` of a calendar's unit `unit`, at the place in it the first occurrence has.
    units: struct { calendar: u8, unit: u8, n: u64 },
};

pub const Recurrence = struct {
    /// The tick of the first occurrence.
    first: u64,
    every: Every,
    /// How many occurrences in all; null for ever.
    times: ?u64 = null,
    policy: Policy = .each,

    /// The tick of occurrence `k`, or null past what a clock counts. `cal` is the calendar `every` names.
    pub fn occurrence(r: Recurrence, k: u64, cal: ?*const Calendar) ?u64 {
        switch (r.every) {
            .ticks => |p| return std.math.add(u64, r.first, std.math.mul(u64, k, p) catch return null) catch null,
            .units => |u| {
                const c = cal.?;
                const at = r.first +| c.decl.start;
                const c0 = c.moment(r.first).counts[u.unit];
                const begins = c.startOf(u.unit, c0) orelse return null;
                const into = at - begins;
                const count = std.math.add(u64, c0, std.math.mul(u64, k, u.n) catch return null) catch return null;
                const s = c.startOf(u.unit, count) orelse return null;
                const e = c.startOf(u.unit, count +| 1) orelse return null;
                const tick = s + @min(into, e - s - 1);
                return std.math.sub(u64, tick, c.decl.start) catch null;
            },
        }
    }

    /// How many occurrences from the `k`-th come at or before `target`, within `times`.
    pub fn upTo(r: Recurrence, k: u64, target: u64, cal: ?*const Calendar) u64 {
        const left = if (r.times) |t| (std.math.sub(u64, t, k) catch 0) else std.math.maxInt(u64);
        if (left == 0) return 0;
        const first = r.occurrence(k, cal) orelse return 0;
        if (first > target) return 0;
        const last: u64 = switch (r.every) {
            .ticks => |p| k + (target - first) / p,
            .units => |u| blk: {
                const c = cal.?;
                const c0 = c.moment(r.first).counts[u.unit];
                var kk = (c.moment(target).counts[u.unit] - c0) / u.n;
                // the occurrence in `target`'s unit may fall after it
                if (kk > k and (r.occurrence(kk, cal) orelse std.math.maxInt(u64)) > target) kk -= 1;
                break :blk kk;
            },
        };
        return @min(last - k + 1, left);
    }
};

/// Whether a recurrence can run: a step that moves time, and a unit its calendar has.
pub fn valid(r: Recurrence, cal: ?*const Calendar) bool {
    return switch (r.every) {
        .ticks => |p| p > 0,
        .units => |u| u.n > 0 and cal != null and u.unit < cal.?.decl.units.len,
    };
}

// ---------------------------------------------------------------- tests

const calendar = @import("calendar.zig");

test "every so many ticks, a number of times" {
    const r: Recurrence = .{ .first = 10, .every = .{ .ticks = 5 }, .times = 3 };
    try std.testing.expectEqual(@as(?u64, 20), r.occurrence(2, null));
    try std.testing.expectEqual(@as(u64, 3), r.upTo(0, 1000, null));
    try std.testing.expectEqual(@as(u64, 2), r.upTo(0, 15, null));
    try std.testing.expectEqual(@as(u64, 0), r.upTo(0, 9, null));
    try std.testing.expectEqual(@as(u64, 0), r.upTo(3, 1000, null));
}

test "the same place in every month, however long the month" {
    var c = try Calendar.init(std.testing.allocator, calendar.persona);
    defer c.deinit(std.testing.allocator);
    // the thirty-first of January, in the evening: then the last of each month
    const r: Recurrence = .{ .first = 30 * 4 + 3, .every = .{ .units = .{ .calendar = 0, .unit = 2, .n = 1 } } };
    try std.testing.expectEqual(@as(?u64, 58 * 4 + 3), r.occurrence(1, &c));
    try std.testing.expectEqual(@as(?u64, 89 * 4 + 3), r.occurrence(2, &c));
    // three months on, the occurrence in April's last evening has come; the one in May has not
    try std.testing.expectEqual(@as(u64, 4), r.upTo(0, 119 * 4 + 3, &c));
    try std.testing.expectEqual(@as(u64, 3), r.upTo(0, 119 * 4 + 2, &c));
}
