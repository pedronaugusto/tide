//! A calendar: how a clock's ticks read as a game's own time.
//!
//! Units nest, smallest first: a slot of ticks, a day of slots, a month of
//! days, a year of months. A unit's size is fixed or a repeating list of
//! sizes (months of 31, 28, 31… days), so a calendar is data and no date
//! arithmetic is written for it. Cycles count a unit round without nesting:
//! a week of seven days runs across months, a moon of twenty-nine and a half
//! days across weeks. A calendar's start is where the clock's tick zero falls
//! in it. From a tick, a calendar reads each unit's count since its start,
//! each unit's place in the next, and each cycle's place.

const std = @import("std");

pub const max_units = 8;
pub const max_cycles = 8;
/// The most sizes in a unit's repeating list: a four-hundred-year leap cycle of months is 4,800.
pub const max_sizes = 4800;
/// The most names a place takes, as riverrun's `one of` holds them.
pub const max_names = 256;
/// The most units `next` steps through looking for a time.
pub const max_search = 1 << 20;

pub const Error = error{
    OutOfMemory,
    NoUnits,
    TooManyUnits,
    TooManyCycles,
    TooManySizes,
    TooManyNames,
    EmptyName,
    /// A size of zero, or a repeating list with none.
    EmptySize,
    /// Names for a unit's places in a next unit of no fixed size, or not one name a place.
    NamesDoNotFit,
    /// A cycle over a unit the calendar does not have, of length zero, or starting past its end.
    BadCycle,
    /// The calendar's sizes overflow the ticks a clock counts.
    CalendarTooLarge,
};

pub const Size = union(enum) {
    fixed: u64,
    /// Repeating, in the order given: the first unit after the calendar's zero is the first.
    cycle: []const u32,
};

pub const Unit = struct {
    name: []const u8,
    /// In ticks for the first unit, in the unit before for each other.
    size: Size,
    /// The names of this unit's places in the next one, one each: the slots of a day, the days of a week as a
    /// unit, the months of a year. Empty: the place is a number.
    names: []const []const u8 = &.{},
};

pub const Cycle = struct {
    name: []const u8,
    /// The unit it counts round: a week counts days.
    unit: u8,
    length: u32,
    names: []const []const u8 = &.{},
    /// Its place at the calendar's zero: a week whose first day is a Friday starts at 4 of monday…sunday.
    offset: u32 = 0,
};

pub const Decl = struct {
    name: []const u8,
    units: []const Unit,
    cycles: []const Cycle = &.{},
    /// Where the clock's tick zero falls, in ticks from the calendar's zero.
    start: u64 = 0,
};

/// A tick read through a calendar.
pub const Moment = struct {
    /// Each unit's count since the calendar's zero.
    counts: [max_units]u64 = @splat(0),
    /// Each unit's place in the next unit up; the last unit has none.
    places: [max_units]u64 = @splat(0),
    /// Each cycle's place.
    cycles: [max_cycles]u64 = @splat(0),
};

/// A condition on a moment: a unit's place in the next, or a cycle's place, is `value`.
pub const Want = struct {
    what: union(enum) { place: u8, cycle: u8 },
    value: u64,
};

pub const Calendar = struct {
    decl: Decl,
    /// For each unit of repeating sizes, the running sums of its list, one longer than the list.
    sums: [max_units][]const u64,

    pub fn init(gpa: std.mem.Allocator, decl: Decl) Error!Calendar {
        try validate(decl);
        var c: Calendar = .{ .decl = decl, .sums = @splat(&.{}) };
        errdefer c.deinit(gpa);
        for (decl.units, 0..) |u, i| if (u.size == .cycle) {
            const sizes = u.size.cycle;
            const sums = try gpa.alloc(u64, sizes.len + 1);
            sums[0] = 0;
            for (sizes, 0..) |s, k| sums[k + 1] = sums[k] + s;
            c.sums[i] = sums;
        };
        // the whole calendar's largest unit must fit a clock's count
        _ = c.startOf(decl.units.len - 1, 1) orelse return error.CalendarTooLarge;
        return c;
    }

    pub fn deinit(c: *Calendar, gpa: std.mem.Allocator) void {
        for (c.sums) |s| if (s.len > 0) gpa.free(s);
        c.* = undefined;
    }

    /// A clock's tick, read.
    pub fn moment(c: *const Calendar, tick: u64) Moment {
        var m: Moment = .{};
        var amount = tick +| c.decl.start;
        for (c.decl.units, 0..) |_, i| {
            const count, const place = c.split(i, amount);
            m.counts[i] = count;
            if (i > 0) m.places[i - 1] = place;
            amount = count;
        }
        for (c.decl.cycles, 0..) |cy, j| m.cycles[j] = (m.counts[cy.unit] +| cy.offset) % cy.length;
        return m;
    }

    /// The clock's tick at which unit `level`'s `count`-th begins, or null when that is before the clock's zero
    /// or past what a clock counts.
    pub fn tickOf(c: *const Calendar, level: usize, count: u64) ?u64 {
        const at = c.startOf(level, count) orelse return null;
        return std.math.sub(u64, at, c.decl.start) catch null;
    }

    /// The first tick at or after `from` where every condition holds, stepping by the finest unit they name.
    pub fn next(c: *const Calendar, from: u64, wants: []const Want) error{NoSuchTime}!u64 {
        if (wants.len == 0) return error.NoSuchTime;
        var level: usize = max_units;
        for (wants) |w| level = @min(level, switch (w.what) {
            .place => |u| u,
            .cycle => |j| c.decl.cycles[j].unit,
        });
        var count = c.moment(from).counts[level];
        if ((c.tickOf(level, count) orelse 0) < from) count += 1;
        for (0..max_search) |_| {
            const tick = c.tickOf(level, count) orelse return error.NoSuchTime;
            if (holds(c.moment(tick), wants)) return tick;
            count += 1;
        }
        return error.NoSuchTime;
    }

    // How many of unit `i` fit in `amount` of the unit before (ticks for the first), and what is left: the
    // place of the unit before in the one that `amount` falls in.
    fn split(c: *const Calendar, i: usize, amount: u64) struct { u64, u64 } {
        switch (c.decl.units[i].size) {
            .fixed => |s| return .{ amount / s, amount % s },
            .cycle => |sizes| {
                const sums = c.sums[i];
                const whole = sums[sizes.len];
                const rounds = amount / whole;
                const rest = amount % whole;
                // the last running sum not past `rest`
                var lo: usize = 0;
                var hi: usize = sizes.len;
                while (hi - lo > 1) {
                    const mid = (lo + hi) / 2;
                    if (sums[mid] <= rest) lo = mid else hi = mid;
                }
                return .{ rounds * sizes.len + lo, rest - sums[lo] };
            },
        }
    }

    /// The calendar's own tick (the clock's plus `start`) at which unit `level`'s `count`-th begins, or null
    /// past a u64.
    pub fn startOf(c: *const Calendar, level: usize, count: u64) ?u64 {
        var amount = count;
        var i = level + 1;
        while (i > 0) {
            i -= 1;
            amount = c.before(i, amount) orelse return null;
        }
        return amount;
    }

    // How much of the unit before (ticks for the first) comes before unit `i`'s `count`-th.
    fn before(c: *const Calendar, i: usize, count: u64) ?u64 {
        switch (c.decl.units[i].size) {
            .fixed => |s| return std.math.mul(u64, count, s) catch null,
            .cycle => |sizes| {
                const sums = c.sums[i];
                const rounds = std.math.mul(u64, count / sizes.len, sums[sizes.len]) catch return null;
                return std.math.add(u64, rounds, sums[count % sizes.len]) catch null;
            },
        }
    }
};

fn holds(m: Moment, wants: []const Want) bool {
    for (wants) |w| {
        const got = switch (w.what) {
            .place => |u| m.places[u],
            .cycle => |j| m.cycles[j],
        };
        if (got != w.value) return false;
    }
    return true;
}

fn validate(d: Decl) Error!void {
    if (d.name.len == 0) return error.EmptyName;
    if (d.units.len == 0) return error.NoUnits;
    if (d.units.len > max_units) return error.TooManyUnits;
    if (d.cycles.len > max_cycles) return error.TooManyCycles;
    for (d.units, 0..) |u, i| {
        if (u.name.len == 0) return error.EmptyName;
        switch (u.size) {
            .fixed => |s| if (s == 0) return error.EmptySize,
            .cycle => |sizes| {
                if (sizes.len == 0) return error.EmptySize;
                if (sizes.len > max_sizes) return error.TooManySizes;
                for (sizes) |s| if (s == 0) return error.EmptySize;
            },
        }
        if (u.names.len == 0) continue;
        if (u.names.len > max_names) return error.TooManyNames;
        // a place's names need a next unit that always holds that many
        if (i + 1 == d.units.len) return error.NamesDoNotFit;
        const up = d.units[i + 1].size;
        if (up != .fixed or up.fixed != u.names.len) return error.NamesDoNotFit;
        for (u.names) |n| if (n.len == 0) return error.EmptyName;
    }
    for (d.cycles) |cy| {
        if (cy.name.len == 0) return error.EmptyName;
        if (cy.unit >= d.units.len or cy.length == 0 or cy.offset >= cy.length) return error.BadCycle;
        if (cy.names.len > max_names) return error.TooManyNames;
        if (cy.names.len != 0 and cy.names.len != cy.length) return error.NamesDoNotFit;
    }
}

// ---------------------------------------------------------------- tests

/// Persona's kind: four slots a day, seven days a week as a cycle, months of real lengths in a year.
pub const persona: Decl = .{
    .name = "year",
    .units = &.{
        .{ .name = "slot", .size = .{ .fixed = 1 }, .names = &.{ "morning", "noon", "afternoon", "evening" } },
        .{ .name = "day", .size = .{ .fixed = 4 } },
        .{ .name = "month", .size = .{ .cycle = &.{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 } } },
        .{ .name = "year", .size = .{ .fixed = 12 } },
    },
    .cycles = &.{.{ .name = "weekday", .unit = 1, .length = 7, .names = &.{ "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday" } }},
};

test "a tick reads as slots, days, months and weekdays" {
    var c = try Calendar.init(std.testing.allocator, persona);
    defer c.deinit(std.testing.allocator);
    // day 40 is the tenth of February; its evening is slot 3
    const m = c.moment(40 * 4 + 3);
    try std.testing.expectEqual(@as(u64, 3), m.places[0]);
    try std.testing.expectEqual(@as(u64, 40), m.counts[1]);
    try std.testing.expectEqual(@as(u64, 9), m.places[1]);
    try std.testing.expectEqual(@as(u64, 1), m.places[2]);
    try std.testing.expectEqual(@as(u64, 40 % 7), m.cycles[0]);
    // the first of March, and of the next January
    try std.testing.expectEqual(@as(?u64, 59 * 4), c.tickOf(2, 2));
    try std.testing.expectEqual(@as(?u64, 365 * 4), c.tickOf(2, 12));
}

test "the next Sunday evening, from anywhere in the week" {
    var c = try Calendar.init(std.testing.allocator, persona);
    defer c.deinit(std.testing.allocator);
    const sunday_evening = [_]Want{ .{ .what = .{ .cycle = 0 }, .value = 6 }, .{ .what = .{ .place = 0 }, .value = 3 } };
    try std.testing.expectEqual(@as(u64, 6 * 4 + 3), try c.next(0, &sunday_evening));
    try std.testing.expectEqual(@as(u64, 6 * 4 + 3), try c.next(6 * 4 + 3, &sunday_evening));
    try std.testing.expectEqual(@as(u64, 13 * 4 + 3), try c.next(6 * 4 + 4, &sunday_evening));
}

test "a calendar that does not hold together is refused" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.NamesDoNotFit, Calendar.init(gpa, .{ .name = "x", .units = &.{
        .{ .name = "slot", .size = .{ .fixed = 1 }, .names = &.{ "a", "b" } },
        .{ .name = "day", .size = .{ .fixed = 4 } },
    } }));
    try std.testing.expectError(error.BadCycle, Calendar.init(gpa, .{ .name = "x", .units = &.{.{ .name = "day", .size = .{ .fixed = 1 } }}, .cycles = &.{.{ .name = "w", .unit = 1, .length = 7 }} }));
    try std.testing.expectError(error.EmptySize, Calendar.init(gpa, .{ .name = "x", .units = &.{.{ .name = "day", .size = .{ .fixed = 0 } }} }));
    try std.testing.expectError(error.CalendarTooLarge, Calendar.init(gpa, .{ .name = "x", .units = &.{
        .{ .name = "a", .size = .{ .fixed = 1 << 40 } },
        .{ .name = "b", .size = .{ .fixed = 1 << 40 } },
    } }));
}
