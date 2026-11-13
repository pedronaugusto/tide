//! tide's block in a compiled story: what the story declares of its time,
//! as tide's compile pass wrote it beside riverrun's graph. Clocks,
//! calendars, derived facts and schedules, every instant already worked out
//! from the calendar, so loading is a translation and no calendar is read
//! twice. Facts and sections are the compiled story's ids; names stay the
//! story's, read from it.
//!
//! Little-endian, in this order: the clocks, the calendars with their units
//! and cycles, the derived facts, the schedules. Each list is a count and its
//! records. A reader never trusts the bytes: every count is bounded, every
//! tag known, and the block must end where its last record does.

const std = @import("std");
const calendar = @import("calendar.zig");
const schedule = @import("schedule.zig");
const aegis = @import("aegis");

/// The block's name in a compiled story.
pub const name = "tide";
/// Bumped when a record changes; a reader refuses another.
pub const version: u32 = 1;

/// A fact or section that is not there.
pub const none16: u16 = 0xFFFF;

pub const max_clocks = 32;
pub const max_calendars = 16;
pub const max_derived = 256;
pub const max_schedules = 1 << 16;
pub const max_sizes = 4096;

pub const Error = error{
    /// The bytes are not a block this reader wrote: cut short, too long, a count past its bound, an unknown tag.
    Malformed,
    OutOfMemory,
};

pub const Plan = struct {
    /// Each clock's `(clock)` fact; the fact's name is the clock's.
    clocks: []const u16,
    calendars: []const Cal,
    derived: []const Derived,
    schedules: []const Schedule,
};

pub const Cal = struct {
    /// The `(calendar)` section; its name is the calendar's.
    section: u32,
    clock: u8,
    start: u64,
    units: []const Unit,
    cycles: []const Cycle,
};

pub const Size = union(enum) { fixed: u64, cycle: []const u32 };

pub const Unit = struct {
    /// The part's name, which names the unit.
    name: []const u8,
    size: Size,
    /// The `one of` fact that holds its place in the next unit, whose values name the places.
    place: u16 = none16,
    /// The int fact that counts it since the calendar's zero.
    count: u16 = none16,
};

pub const Cycle = struct {
    name: []const u8,
    unit: u8,
    length: u32,
    offset: u32,
    place: u16 = none16,
};

pub const Per = union(enum) { ticks: u64, unit: struct { calendar: u8, unit: u8 } };

pub const Derived = struct {
    fact: u16,
    what: union(enum) {
        until: struct { clock: u8, at: u64, per: Per },
        since: struct { clock: u8, at: u64, per: Per },
        drift: struct { a: u8, b: u8, per: u64 },
    },
};

pub const Schedule = struct {
    /// The section that carries it, which is the key it comes due with.
    section: u32,
    clock: u8,
    first: u64,
    /// Null for one instant.
    every: ?schedule.Every = null,
    times: ?u64 = null,
    policy: schedule.Policy = .each,
};

// ---------------------------------------------------------------- writing

/// The block's bytes, on `gpa`, owned by the caller.
pub fn write(gpa: std.mem.Allocator, p: Plan) error{OutOfMemory}![]u8 {
    aegis.assert.invariant(p.clocks.len <= max_clocks, "a plan holds at most max_clocks clocks, as the compiler builds it");
    aegis.assert.invariant(p.calendars.len <= max_calendars, "a plan holds at most max_calendars calendars, as the compiler builds it");
    aegis.assert.invariant(p.derived.len <= max_derived, "a plan holds at most max_derived derived clocks, as the compiler builds it");
    aegis.assert.invariant(p.schedules.len <= max_schedules, "a plan holds at most max_schedules schedules, as the compiler builds it");
    var w: Writer = .{ .gpa = gpa };
    errdefer w.out.deinit(gpa);
    try w.int(u8, @intCast(p.clocks.len)); // safe: asserted above
    for (p.clocks) |c| try w.int(u16, c);
    try w.int(u8, @intCast(p.calendars.len)); // safe: asserted above
    for (p.calendars) |c| try w.cal(c);
    try w.int(u16, @intCast(p.derived.len)); // safe: asserted above
    for (p.derived) |d| try w.derived(d);
    try w.int(u32, @intCast(p.schedules.len)); // safe: asserted above
    for (p.schedules) |s| try w.sched(s);
    return w.out.toOwnedSlice(gpa);
}

const Writer = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,

    fn int(w: *Writer, comptime T: type, v: T) error{OutOfMemory}!void {
        var buf: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buf, v, .little);
        try w.out.appendSlice(w.gpa, &buf);
    }

    fn bytes(w: *Writer, s: []const u8) error{OutOfMemory}!void {
        aegis.assert.invariant(s.len <= std.math.maxInt(u16), "a name fits its u16 length");
        try w.int(u16, @intCast(s.len)); // safe: asserted above
        try w.out.appendSlice(w.gpa, s);
    }

    fn cal(w: *Writer, c: Cal) error{OutOfMemory}!void {
        try w.int(u32, c.section);
        try w.int(u8, c.clock);
        try w.int(u64, c.start);
        aegis.assert.invariant(c.units.len <= calendar.max_units, "a calendar holds at most max_units units");
        aegis.assert.invariant(c.cycles.len <= calendar.max_cycles, "a calendar holds at most max_cycles cycles");
        try w.int(u8, @intCast(c.units.len)); // safe: asserted above
        for (c.units) |u| {
            try w.bytes(u.name);
            switch (u.size) {
                .fixed => |s| {
                    try w.int(u8, 0);
                    try w.int(u64, s);
                },
                .cycle => |sizes| {
                    try w.int(u8, 1);
                    aegis.assert.invariant(sizes.len <= max_sizes, "a cycle holds at most max_sizes sizes");
                    try w.int(u16, @intCast(sizes.len)); // safe: asserted above
                    for (sizes) |s| try w.int(u32, s);
                },
            }
            try w.int(u16, u.place);
            try w.int(u16, u.count);
        }
        try w.int(u8, @intCast(c.cycles.len)); // safe: asserted above
        for (c.cycles) |y| {
            try w.bytes(y.name);
            try w.int(u8, y.unit);
            try w.int(u32, y.length);
            try w.int(u32, y.offset);
            try w.int(u16, y.place);
        }
    }

    fn per(w: *Writer, p: Per) error{OutOfMemory}!void {
        switch (p) {
            .ticks => |t| {
                try w.int(u8, 0);
                try w.int(u64, t);
            },
            .unit => |u| {
                try w.int(u8, 1);
                try w.int(u8, u.calendar);
                try w.int(u8, u.unit);
            },
        }
    }

    fn derived(w: *Writer, d: Derived) error{OutOfMemory}!void {
        try w.int(u16, d.fact);
        switch (d.what) {
            inline .until, .since => |m, tag| {
                try w.int(u8, if (tag == .until) 0 else 1);
                try w.int(u8, m.clock);
                try w.int(u64, m.at);
                try w.per(m.per);
            },
            .drift => |m| {
                try w.int(u8, 2);
                try w.int(u8, m.a);
                try w.int(u8, m.b);
                try w.int(u64, m.per);
            },
        }
    }

    fn sched(w: *Writer, s: Schedule) error{OutOfMemory}!void {
        try w.int(u32, s.section);
        try w.int(u8, s.clock);
        try w.int(u64, s.first);
        if (s.every) |e| switch (e) {
            .ticks => |t| {
                try w.int(u8, 1);
                try w.int(u64, t);
            },
            .units => |u| {
                try w.int(u8, 2);
                try w.int(u8, u.calendar);
                try w.int(u8, u.unit);
                try w.int(u64, u.n);
            },
        } else try w.int(u8, 0);
        try w.int(u8, @intFromBool(s.times != null));
        try w.int(u64, s.times orelse 0);
        try w.int(u8, @backingInt(s.policy));
    }
};

// ---------------------------------------------------------------- reading

/// The plan in `bytes`, its lists on `arena`; names point into `bytes`, which must outlive it.
pub fn read(arena: std.mem.Allocator, bytes: []const u8) Error!Plan {
    var r: Reader = .{ .bytes = bytes };
    const clocks = try arena.alloc(u16, try r.count(u8, max_clocks));
    for (clocks) |*c| c.* = try r.int(u16);
    const cals = try arena.alloc(Cal, try r.count(u8, max_calendars));
    for (cals) |*c| c.* = try r.cal(arena);
    const derived = try arena.alloc(Derived, try r.count(u16, max_derived));
    for (derived) |*d| d.* = try r.derived();
    const scheds = try arena.alloc(Schedule, try r.count(u32, max_schedules));
    for (scheds) |*s| s.* = try r.sched();
    if (r.i != bytes.len) return error.Malformed;
    return .{ .clocks = clocks, .calendars = cals, .derived = derived, .schedules = scheds };
}

const Reader = struct {
    bytes: []const u8,
    i: usize = 0,

    fn int(r: *Reader, comptime T: type) Error!T {
        if (r.bytes.len - r.i < @sizeOf(T)) return error.Malformed;
        const v = std.mem.readInt(T, r.bytes[r.i..][0..@sizeOf(T)], .little);
        r.i += @sizeOf(T);
        return v;
    }

    fn count(r: *Reader, comptime T: type, bound: usize) Error!usize {
        const n = try r.int(T);
        if (n > bound) return error.Malformed;
        return n;
    }

    fn str(r: *Reader) Error![]const u8 {
        const n = try r.int(u16);
        if (r.bytes.len - r.i < n) return error.Malformed;
        defer r.i += n;
        return r.bytes[r.i..][0..n];
    }

    fn cal(r: *Reader, arena: std.mem.Allocator) Error!Cal {
        var c: Cal = .{ .section = try r.int(u32), .clock = try r.int(u8), .start = try r.int(u64), .units = &.{}, .cycles = &.{} };
        const units = try arena.alloc(Unit, try r.count(u8, calendar.max_units));
        for (units) |*u| {
            u.* = .{ .name = try r.str(), .size = .{ .fixed = 0 } };
            u.size = switch (try r.int(u8)) {
                0 => .{ .fixed = try r.int(u64) },
                1 => blk: {
                    const sizes = try arena.alloc(u32, try r.count(u16, max_sizes));
                    for (sizes) |*s| s.* = try r.int(u32);
                    break :blk .{ .cycle = sizes };
                },
                else => return error.Malformed,
            };
            u.place = try r.int(u16);
            u.count = try r.int(u16);
        }
        const cycles = try arena.alloc(Cycle, try r.count(u8, calendar.max_cycles));
        for (cycles) |*y| y.* = .{ .name = try r.str(), .unit = try r.int(u8), .length = try r.int(u32), .offset = try r.int(u32), .place = try r.int(u16) };
        c.units = units;
        c.cycles = cycles;
        return c;
    }

    fn per(r: *Reader) Error!Per {
        return switch (try r.int(u8)) {
            0 => .{ .ticks = try r.int(u64) },
            1 => .{ .unit = .{ .calendar = try r.int(u8), .unit = try r.int(u8) } },
            else => error.Malformed,
        };
    }

    fn derived(r: *Reader) Error!Derived {
        const fact = try r.int(u16);
        return switch (try r.int(u8)) {
            0 => .{ .fact = fact, .what = .{ .until = .{ .clock = try r.int(u8), .at = try r.int(u64), .per = try r.per() } } },
            1 => .{ .fact = fact, .what = .{ .since = .{ .clock = try r.int(u8), .at = try r.int(u64), .per = try r.per() } } },
            2 => .{ .fact = fact, .what = .{ .drift = .{ .a = try r.int(u8), .b = try r.int(u8), .per = try r.int(u64) } } },
            else => error.Malformed,
        };
    }

    fn sched(r: *Reader) Error!Schedule {
        var s: Schedule = .{ .section = try r.int(u32), .clock = try r.int(u8), .first = try r.int(u64) };
        s.every = switch (try r.int(u8)) {
            0 => null,
            1 => .{ .ticks = try r.int(u64) },
            2 => .{ .units = .{ .calendar = try r.int(u8), .unit = try r.int(u8), .n = try r.int(u64) } },
            else => return error.Malformed,
        };
        const has_times = try r.int(u8);
        const times = try r.int(u64);
        s.times = switch (has_times) {
            0 => null,
            1 => times,
            else => return error.Malformed,
        };
        s.policy = switch (try r.int(u8)) {
            0 => .each,
            1 => .once,
            else => return error.Malformed,
        };
        return s;
    }
};

test "a plan reads back as it was written" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const plan: Plan = .{
        .clocks = &.{3},
        .calendars = &.{.{ .section = 7, .clock = 0, .start = 2, .units = &.{
            .{ .name = "slot", .size = .{ .fixed = 1 }, .place = 4 },
            .{ .name = "month", .size = .{ .cycle = &.{ 31, 28 } }, .count = 5 },
        }, .cycles = &.{.{ .name = "week", .unit = 1, .length = 7, .offset = 3, .place = 6 }} }},
        .derived = &.{
            .{ .fact = 8, .what = .{ .until = .{ .clock = 0, .at = 136, .per = .{ .unit = .{ .calendar = 0, .unit = 1 } } } } },
            .{ .fact = 9, .what = .{ .drift = .{ .a = 0, .b = 0, .per = 4 } } },
        },
        .schedules = &.{.{ .section = 2, .clock = 0, .first = 27, .every = .{ .units = .{ .calendar = 0, .unit = 1, .n = 7 } }, .times = 5, .policy = .once }},
    };
    const bytes = try write(std.testing.allocator, plan);
    defer std.testing.allocator.free(bytes);
    const back = try read(arena.allocator(), bytes);
    try std.testing.expectEqual(@as(u16, 3), back.clocks[0]);
    try std.testing.expectEqualStrings("month", back.calendars[0].units[1].name);
    try std.testing.expectEqual(@as(u32, 28), back.calendars[0].units[1].size.cycle[1]);
    try std.testing.expectEqual(@as(u32, 3), back.calendars[0].cycles[0].offset);
    try std.testing.expectEqual(@as(u64, 136), back.derived[0].what.until.at);
    try std.testing.expectEqual(@as(u64, 4), back.derived[1].what.drift.per);
    try std.testing.expectEqual(@as(?u64, 5), back.schedules[0].times);
    try std.testing.expectEqual(schedule.Policy.once, back.schedules[0].policy);
    // cut short anywhere, or with a byte too many, it is refused
    for (0..bytes.len) |n| try std.testing.expectError(error.Malformed, read(arena.allocator(), bytes[0..n]));
    const longer = try std.mem.concat(std.testing.allocator, u8, &.{ bytes, &.{0} });
    defer std.testing.allocator.free(longer);
    try std.testing.expectError(error.Malformed, read(arena.allocator(), longer));
}

test "any bytes are read or refused, never crash" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [1024]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            _ = read(arena.allocator(), bytes) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.Malformed => {},
            };
        }
    }.one, .{});
}
