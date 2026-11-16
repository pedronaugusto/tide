//! A saved moment of tide: every clock's tick, rate, pause and carried
//! fraction, and every schedule with its order and a recurrence's next
//! occurrence. A clock's tick is a riverrun fact too; the snapshot keeps it
//! as well, so tide alone restores a moment exactly, and a restore writes
//! the facts back from it.
//!
//! Clocks and calendars are matched by name, so a save survives a game that
//! adds or renames one, and what no longer matches is reported, not guessed.
//! A restore may go back in time: it replaces every schedule with the saved
//! ones, so what follows comes due exactly as it did the first time. A
//! refused snapshot changes nothing.
//!
//!     "TIDESNAP" version:u16
//!     clocks:u16   { name now:u64 ticks:u32 per:u32 carry:u64 paused:u8 }
//!     calendars:u16 { name }
//!     next_order:u64
//!     slots:u32    { clock:u16 key:u64 order:u64 kind:u8 instant | recurrence }
//!     instant    = at:u64
//!     recurrence = first:u64 every times policy:u8 next:u64
//!     every      = 0 step:u64 | 1 calendar:u16 unit:u8 n:u64
//!     times      = 0 | 1 n:u64
//!     name       = len:u16 bytes
//!
//! Little-endian throughout.

const std = @import("std");
const Tide = @import("Tide.zig");
const schedule = @import("schedule.zig");
const queue = @import("queue.zig");

pub const magic = "TIDESNAP";
pub const version: u16 = 1;

pub const Error = error{
    OutOfMemory,
    /// Not a tide snapshot, of another version, cut short, or holding what no snapshot holds.
    BadSnapshot,
    /// More schedules than this tide has room for.
    NoRoom,
} || Tide.Error;

/// What a restore could not match.
pub const Report = struct {
    /// Clocks saved that this tide no longer has; their schedules are dropped.
    dropped_clocks: u32 = 0,
    /// Clocks this tide has that the save did not: they keep their tick.
    missing_clocks: u32 = 0,
    /// Schedules on a dropped clock, or in a calendar's units that no longer fit.
    dropped_schedules: u32 = 0,
};

pub fn write(t: *const Tide, gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
    // the schedules in the order they were scheduled, so a restore queues them alike
    var live: std.ArrayList(u32) = .empty;
    defer live.deinit(gpa);
    for (t.slots, 0..) |s, i| if (s.live) try live.append(gpa, @intCast(i)); // safe: room is at most max_room
    std.mem.sort(u32, live.items, t, struct {
        fn before(tide: *const Tide, a: u32, b: u32) bool {
            return tide.slots[a].order < tide.slots[b].order;
        }
    }.before);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    writeAll(t, &out.writer, live.items) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeAll(t: *const Tide, w: *std.Io.Writer, live: []const u32) std.Io.Writer.Error!void {
    try w.writeAll(magic);
    try w.writeInt(u16, version, .little);
    try w.writeInt(u16, @intCast(t.clocks.len), .little); // safe: max_clocks
    for (t.clocks) |c| {
        try name(w, c.name);
        try w.writeInt(u64, c.now, .little);
        try w.writeInt(u32, c.meter.rate.ticks, .little);
        try w.writeInt(u32, c.meter.rate.per, .little);
        try w.writeInt(u64, c.meter.carry, .little);
        try w.writeByte(@intFromBool(c.meter.paused));
    }
    try w.writeInt(u16, @intCast(t.calendars.len), .little); // safe: max_calendars
    for (t.calendars) |b| try name(w, b.calendar.decl.name);
    try w.writeInt(u64, t.next_order, .little);
    try w.writeInt(u32, @intCast(live.len), .little); // safe: room is at most max_room
    for (live) |i| try slot(w, t.slots[i]);
}

fn name(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeInt(u16, @intCast(s.len), .little); // safe: names are short, as riverrun bounds them
    try w.writeAll(s);
}

fn slot(w: *std.Io.Writer, s: Tide.Slot) std.Io.Writer.Error!void {
    try w.writeInt(u16, s.clock.raw(), .little);
    try w.writeInt(u64, s.key, .little);
    try w.writeInt(u64, s.order, .little);
    switch (s.what) {
        .instant => |at| {
            try w.writeByte(0);
            try w.writeInt(u64, at, .little);
        },
        .recurrence => |rec| {
            try w.writeByte(1);
            try w.writeInt(u64, rec.r.first, .little);
            switch (rec.r.every) {
                .ticks => |p| {
                    try w.writeByte(0);
                    try w.writeInt(u64, p, .little);
                },
                .units => |u| {
                    try w.writeByte(1);
                    try w.writeInt(u16, u.calendar, .little);
                    try w.writeByte(u.unit);
                    try w.writeInt(u64, u.n, .little);
                },
            }
            try w.writeByte(@intFromBool(rec.r.times != null));
            try w.writeInt(u64, rec.r.times orelse 0, .little);
            try w.writeByte(@backingInt(rec.r.policy));
            try w.writeInt(u64, rec.next, .little);
        },
    }
}

// ---------------------------------------------------------------- reading

const SavedClock = struct { name: []const u8, now: u64, meter: @import("rate.zig").Meter };

const SavedSlot = struct { clock: u16, key: u64, order: u64, what: @FieldType(Tide.Slot, "what") };

const Saved = struct {
    clocks: []SavedClock,
    calendars: [][]const u8,
    next_order: u64,
    slots: []SavedSlot,

    fn deinit(s: *Saved, gpa: std.mem.Allocator) void {
        gpa.free(s.clocks);
        gpa.free(s.calendars);
        gpa.free(s.slots);
    }
};

/// Puts tide back at the saved moment, and writes its facts from it.
pub fn restore(t: *Tide, bytes: []const u8) Error!Report {
    var r: Reader = .{ .bytes = bytes };
    var saved = try read(t, &r);
    defer saved.deinit(t.gpa);
    if (r.at != bytes.len) return error.BadSnapshot;
    return apply(t, saved);
}

fn read(t: *const Tide, r: *Reader) Error!Saved {
    if (!std.mem.eql(u8, try r.take(magic.len), magic)) return error.BadSnapshot;
    if (try r.int(u16) != version) return error.BadSnapshot;
    const n_clocks = try r.int(u16);
    if (n_clocks > Tide.max_clocks) return error.BadSnapshot;
    const clocks = try t.gpa.alloc(SavedClock, n_clocks);
    errdefer t.gpa.free(clocks);
    for (clocks) |*c| {
        c.name = try r.name();
        c.now = try r.int(u64);
        const ticks = try r.int(u32);
        const per = try r.int(u32);
        const carry = try r.int(u64);
        const paused = try r.int(u8);
        if (c.now > Tide.max_tick or per == 0 or carry >= per or paused > 1) return error.BadSnapshot;
        c.meter = .{ .rate = .{ .ticks = ticks, .per = per }, .carry = carry, .paused = paused == 1 };
    }
    const n_calendars = try r.int(u16);
    if (n_calendars > Tide.max_calendars) return error.BadSnapshot;
    const calendars = try t.gpa.alloc([]const u8, n_calendars);
    errdefer t.gpa.free(calendars);
    for (calendars) |*c| c.* = try r.name();
    const next_order = try r.int(u64);
    const n_slots = try r.int(u32);
    if (n_slots > t.slots.len) return error.NoRoom;
    const slots = try t.gpa.alloc(SavedSlot, n_slots);
    errdefer t.gpa.free(slots);
    for (slots) |*s| s.* = try readSlot(r, n_clocks, n_calendars);
    return .{ .clocks = clocks, .calendars = calendars, .next_order = next_order, .slots = slots };
}

fn readSlot(r: *Reader, n_clocks: u16, n_calendars: u16) Error!SavedSlot {
    const clock = try r.int(u16);
    if (clock >= n_clocks) return error.BadSnapshot;
    const key = try r.int(u64);
    const order = try r.int(u64);
    switch (try r.int(u8)) {
        0 => {
            const at = try r.int(u64);
            if (at > Tide.max_tick) return error.BadSnapshot;
            return .{ .clock = clock, .key = key, .order = order, .what = .{ .instant = at } };
        },
        1 => {
            const first = try r.int(u64);
            const every: schedule.Every = switch (try r.int(u8)) {
                0 => .{ .ticks = try r.int(u64) },
                1 => .{ .units = .{ .calendar = std.math.cast(u8, try r.int(u16)) orelse return error.BadSnapshot, .unit = try r.int(u8), .n = try r.int(u64) } },
                else => return error.BadSnapshot,
            };
            if (every == .units and every.units.calendar >= n_calendars) return error.BadSnapshot;
            const has_times = try r.int(u8);
            const times = try r.int(u64);
            const policy = try r.int(u8);
            const next = try r.int(u64);
            if (first > Tide.max_tick or has_times > 1 or policy > 1) return error.BadSnapshot;
            if (has_times == 1 and next >= times) return error.BadSnapshot;
            const rec: schedule.Recurrence = .{ .first = first, .every = every, .times = if (has_times == 1) times else null, .policy = @fromBackingInt(@intCast(policy)) };
            return .{ .clock = clock, .key = key, .order = order, .what = .{ .recurrence = .{ .r = rec, .next = next } } };
        },
        else => return error.BadSnapshot,
    }
}

// Replaces tide's clocks' state and every schedule with the saved, then writes the facts.
fn apply(t: *Tide, saved: Saved) Error!Report {
    var report: Report = .{};
    var mapped: [Tide.max_clocks]?Tide.ClockId = @splat(null);
    for (saved.clocks, 0..) |c, i| {
        mapped[i] = t.clockNamed(c.name);
        if (mapped[i] == null) report.dropped_clocks += 1;
    }
    for (t.clocks) |c| {
        var found = false;
        for (saved.clocks) |sc| found = found or std.mem.eql(u8, sc.name, c.name);
        if (!found) report.missing_clocks += 1;
    }
    for (saved.clocks, 0..) |c, i| if (mapped[i]) |id| {
        const clock = &t.clocks[id.raw()];
        clock.now = c.now;
        clock.meter = c.meter;
    };
    for (t.clocks) |*c| {
        c.queue.len = 0;
        c.written = null;
    }
    @memset(t.places, queue.none);
    for (t.slots) |*s| s.live = false;
    t.freeAll();
    var next_order = saved.next_order;
    for (saved.slots) |s| {
        const clock = mapped[s.clock] orelse {
            report.dropped_schedules += 1;
            continue;
        };
        const what = remap(t, s.what, saved.calendars, clock) orelse {
            report.dropped_schedules += 1;
            continue;
        };
        const due = dueOf(t, what) orelse {
            report.dropped_schedules += 1;
            continue;
        };
        const before = t.next_order;
        t.next_order = s.order;
        _ = try t.take(clock, s.key, what, due);
        t.next_order = before;
        next_order = @max(next_order, s.order + 1);
    }
    t.next_order = next_order;
    for (t.calendars) |*b| b.last = null;
    @memset(t.derived_last, null);
    try t.sync();
    return report;
}

// A saved recurrence's calendar, by name, in this tide; null when it no longer fits.
fn remap(t: *const Tide, what: @FieldType(Tide.Slot, "what"), names: []const []const u8, clock: Tide.ClockId) ?@FieldType(Tide.Slot, "what") {
    if (what != .recurrence or what.recurrence.r.every != .units) return what;
    var out = what;
    const u = &out.recurrence.r.every.units;
    const id = t.calendarNamed(names[u.calendar]) orelse return null;
    const b = t.calendars[id.raw()];
    if (!b.clock.eql(clock) or u.unit >= b.calendar.decl.units.len or u.n == 0) return null;
    u.calendar = id.raw();
    return out;
}

fn dueOf(t: *const Tide, what: @FieldType(Tide.Slot, "what")) ?u64 {
    return switch (what) {
        .instant => |at| at,
        .recurrence => |rec| blk: {
            if (rec.r.every == .ticks and rec.r.every.ticks == 0) break :blk null;
            break :blk rec.r.occurrence(rec.next, t.calendarFor(rec.r));
        },
    };
}

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(r: *Reader, n: usize) Error![]const u8 {
        if (r.bytes.len - r.at < n) return error.BadSnapshot;
        const out = r.bytes[r.at..][0..n];
        r.at += n;
        return out;
    }

    fn int(r: *Reader, comptime T: type) Error!T {
        const b = try r.take(@sizeOf(T));
        return std.mem.readInt(T, b[0..@sizeOf(T)], .little);
    }

    fn name(r: *Reader) Error![]const u8 {
        const n = try r.int(u16);
        return r.take(n);
    }
};
