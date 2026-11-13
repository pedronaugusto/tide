//! A game's time: its clocks, the calendars that read them, what is
//! scheduled on them, and the facts they keep current.
//!
//! The host moves a clock, by ticks (`advance`) or by its own elapsed time at
//! the clock's rate (`elapse`); no clock goes back. What came due on the way
//! is returned in time order, into the host's buffer, and the clock, its
//! calendars' places and the derived facts are written through the store,
//! each only when it changed. Rewinding is not a clock's: a host goes back by
//! restoring a saved moment, which rebuilds every schedule exactly as it was.

const std = @import("std");
const aegis = @import("aegis");
const facts = @import("riverrun").facts;
const rate_ = @import("rate.zig");
const calendar_ = @import("calendar.zig");
const queue_ = @import("queue.zig");
const schedule = @import("schedule.zig");

const Tide = @This();
const Calendar = calendar_.Calendar;
const Queue = queue_.Queue;
const FactId = facts.FactId;
pub const Rate = rate_.Rate;
pub const Recurrence = schedule.Recurrence;

pub const max_clocks = 32;
pub const max_calendars = 16;
pub const max_derived = 256;
/// The most schedules tide holds at once.
pub const max_room = 1 << 20;
/// The furthest a clock counts: a clock fact is a riverrun int.
pub const max_tick: u64 = std.math.maxInt(i64);

pub const ClockId = aegis.id.Id(enum { clock }, u8);
pub const CalendarId = aegis.id.Id(enum { calendar }, u8);

pub const Error = error{
    OutOfMemory,
    TooManyClocks,
    TooManyCalendars,
    TooManyDerived,
    RoomTooLarge,
    EmptyName,
    DuplicateName,
    UnknownClock,
    UnknownCalendar,
    /// A rate of zero `per`.
    BadRate,
    /// Facts named for a calendar's units or cycles it does not have.
    BadBinding,
    /// A recurrence with no step, a unit its calendar lacks, or a calendar of another clock.
    BadRecurrence,
    /// A derived fact over a unit its calendar lacks, or a per of zero.
    BadDerived,
    /// Past `max_tick`.
    ClockOverflow,
    /// Every schedule's room is taken.
    NoRoom,
} || calendar_.Error || facts.SetError;

pub const ClockDecl = struct {
    name: []const u8,
    /// The `(clock)` fact it keeps: null for a clock only the host reads.
    fact: ?FactId = null,
    rate: Rate = .one,
};

/// The facts a calendar keeps, by unit and by cycle; a null or a missing one is kept by none.
pub const Binding = struct {
    /// Each unit's count since the calendar's zero: `day`.
    counts: []const ?FactId = &.{},
    /// Each unit's place in the next, a `one of` where the unit names its places: `slot`.
    places: []const ?FactId = &.{},
    /// Each cycle's place, a `one of` where it names them: `weekday`.
    cycles: []const ?FactId = &.{},
};

pub const CalendarDecl = struct {
    clock: ClockId,
    decl: calendar_.Decl,
    binding: Binding = .{},
};

/// What a derived fact is counted in: ticks, or a calendar's unit, counted by the units begun between.
pub const Per = union(enum) {
    ticks: u64,
    unit: struct { calendar: CalendarId, unit: u8 },
};

/// A tick of a clock, and what a span to or from it is counted in.
pub const Mark = struct { clock: ClockId, at: u64, per: Per };

/// Time arithmetic the story's language leaves out, kept as an int fact.
pub const Derived = struct {
    fact: FactId,
    what: union(enum) {
        /// How much is left until the clock reaches `at`, never below zero: `days_left` until the fifth of May.
        until: Mark,
        /// How much has passed since the clock reached `at`, zero before.
        since: Mark,
        /// How far clock `a` has run past clock `b`, in whole `per`s, negative when behind.
        drift: struct { a: ClockId, b: ClockId, per: u64 },
    },
};

pub const Options = struct {
    clocks: []const ClockDecl,
    calendars: []const CalendarDecl = &.{},
    derived: []const Derived = &.{},
    /// How many schedules may be held at once.
    room: u32 = 1024,
    /// Where the clocks', calendars' and derived facts are written; null writes none.
    store: ?facts.Store = null,
};

/// A schedule, as `at`, `after` and `every` give it.
pub const Token = struct { slot: u32, generation: u32 };

/// What came due.
pub const Due = struct {
    /// The host's, given when it was scheduled.
    key: u64,
    token: Token,
    clock: ClockId,
    /// When it came due: for several occurrences come due as one, the first.
    at: u64,
    /// How many occurrences it stands for: one, or more under `.once`.
    count: u64,
};

pub const Advanced = struct {
    due: []const Due,
    /// Ticks not yet advanced because the buffer filled: advance by them again to go on.
    left: u64,
};

pub const Clock = struct {
    name: []const u8,
    fact: ?FactId,
    now: u64 = 0,
    meter: rate_.Meter,
    queue: Queue,
    /// What its fact was last written as.
    written: ?u64 = null,
};

pub const Bound = struct {
    clock: ClockId,
    calendar: Calendar,
    binding: Binding,
    /// What was last written, to write only what changes.
    last: ?calendar_.Moment = null,
};

pub const Slot = struct {
    live: bool = false,
    generation: u32 = 0,
    key: u64 = 0,
    clock: ClockId = .fromRaw(0),
    order: u64 = 0,
    what: union(enum) {
        instant: u64,
        recurrence: struct { r: Recurrence, next: u64 },
    } = .{ .instant = 0 },
};

gpa: std.mem.Allocator,
store: ?facts.Store,
clocks: []Clock,
calendars: []Bound,
derived: []const Derived,
/// What each derived fact was last written as.
derived_last: []?i64,
slots: []Slot,
/// Each slot's place in its clock's queue.
places: []u32,
/// Slots free, the next taken from the end.
free: []u32,
free_len: u32,
/// The order the next schedule takes, so equal ticks come due as they were scheduled.
next_order: u64 = 0,
/// What `fromStory` read the declarations into, freed with the tide.
owned: ?*std.heap.ArenaAllocator = null,

pub fn init(gpa: std.mem.Allocator, options: Options) Error!Tide {
    try validate(options);
    var t: Tide = .{
        .gpa = gpa,
        .store = options.store,
        .clocks = &.{},
        .calendars = &.{},
        .derived = options.derived,
        .derived_last = &.{},
        .slots = &.{},
        .places = &.{},
        .free = &.{},
        .free_len = 0,
    };
    errdefer t.deinit();
    t.clocks = try gpa.alloc(Clock, options.clocks.len);
    for (t.clocks, options.clocks, 0..) |*c, d, i| {
        errdefer for (t.clocks[0..i]) |*done| done.queue.deinit(gpa);
        c.* = .{ .name = d.name, .fact = d.fact, .meter = .{ .rate = d.rate }, .queue = try .init(gpa, options.room) };
    }
    t.calendars = try gpa.alloc(Bound, options.calendars.len);
    for (t.calendars, options.calendars, 0..) |*b, d, i| {
        errdefer for (t.calendars[0..i]) |*done| done.calendar.deinit(gpa);
        b.* = .{ .clock = d.clock, .calendar = try .init(gpa, d.decl), .binding = d.binding };
    }
    t.derived_last = try gpa.alloc(?i64, options.derived.len);
    @memset(t.derived_last, null);
    try t.validateDerived();
    t.slots = try gpa.alloc(Slot, options.room);
    @memset(t.slots, .{});
    t.places = try gpa.alloc(u32, options.room);
    @memset(t.places, queue_.none);
    t.free = try gpa.alloc(u32, options.room);
    t.freeAll();
    return t;
}

pub fn deinit(t: *Tide) void {
    for (t.clocks) |*c| c.queue.deinit(t.gpa);
    t.gpa.free(t.clocks);
    for (t.calendars) |*b| b.calendar.deinit(t.gpa);
    t.gpa.free(t.calendars);
    t.gpa.free(t.derived_last);
    t.gpa.free(t.slots);
    t.gpa.free(t.places);
    t.gpa.free(t.free);
    if (t.owned) |arena| {
        arena.deinit();
        t.gpa.destroy(arena);
    }
    t.* = undefined;
}

/// Every slot free, the lowest taken first.
pub fn freeAll(t: *Tide) void {
    for (t.free, 0..) |*f, i| f.* = @intCast(t.free.len - 1 - i); // safe: room is at most max_room
    t.free_len = @intCast(t.free.len); // safe: room is at most max_room
}

fn validate(o: Options) Error!void {
    if (o.clocks.len > max_clocks) return error.TooManyClocks;
    if (o.calendars.len > max_calendars) return error.TooManyCalendars;
    if (o.derived.len > max_derived) return error.TooManyDerived;
    if (o.room > max_room) return error.RoomTooLarge;
    for (o.clocks, 0..) |c, i| {
        if (c.name.len == 0) return error.EmptyName;
        if (!c.rate.valid()) return error.BadRate;
        for (o.clocks[0..i]) |p| if (std.mem.eql(u8, p.name, c.name)) return error.DuplicateName;
    }
    for (o.calendars, 0..) |b, i| {
        if (!within(b.clock, o.clocks.len)) return error.UnknownClock;
        if (b.binding.counts.len > b.decl.units.len or b.binding.places.len > b.decl.units.len or b.binding.cycles.len > b.decl.cycles.len) return error.BadBinding;
        for (o.calendars[0..i]) |p| if (std.mem.eql(u8, p.decl.name, b.decl.name)) return error.DuplicateName;
    }
}

fn validateDerived(t: *const Tide) Error!void {
    for (t.derived) |d| switch (d.what) {
        .until, .since => |w| {
            try t.clockOk(w.clock);
            switch (w.per) {
                .ticks => |p| if (p == 0) return error.BadDerived,
                .unit => |u| {
                    if (!within(u.calendar, t.calendars.len)) return error.UnknownCalendar;
                    const b = t.calendars[u.calendar.raw()];
                    if (!b.clock.eql(w.clock) or u.unit >= b.calendar.decl.units.len) return error.BadDerived;
                },
            }
        },
        .drift => |w| {
            try t.clockOk(w.a);
            try t.clockOk(w.b);
            if (w.per == 0) return error.BadDerived;
        },
    };
}

fn clockOk(t: *const Tide, c: ClockId) Error!void {
    if (!within(c, t.clocks.len)) return error.UnknownClock;
}

/// Whether `id` names one of `count` things: it comes before the count, by
/// the id's own order. A count past any id's range holds every id.
fn within(id: anytype, count: usize) bool {
    const limit = std.math.cast(@TypeOf(id.raw()), count) orelse return true;
    return id.compare(.fromRaw(limit)) == .lt;
}

// ---------------------------------------------------------------- reading

pub fn now(t: *const Tide, clock: ClockId) u64 {
    return t.clocks[clock.raw()].now;
}

pub fn calendar(t: *const Tide, id: CalendarId) *const Calendar {
    return &t.calendars[id.raw()].calendar;
}

/// A calendar's reading of its clock now.
pub fn moment(t: *const Tide, id: CalendarId) calendar_.Moment {
    const b = &t.calendars[id.raw()];
    return b.calendar.moment(t.now(b.clock));
}

pub fn clockNamed(t: *const Tide, name: []const u8) ?ClockId {
    for (t.clocks, 0..) |c, i| if (std.mem.eql(u8, c.name, name)) return .fromRaw(@intCast(i)); // safe: max_clocks
    return null;
}

pub fn calendarNamed(t: *const Tide, name: []const u8) ?CalendarId {
    for (t.calendars, 0..) |b, i| if (std.mem.eql(u8, b.calendar.decl.name, name)) return .fromRaw(@intCast(i)); // safe: max_calendars
    return null;
}

// ---------------------------------------------------------------- rates

/// A clock's rate from now on: per tick of elapsed time, or `Rate.zero` for a clock moved only by `advance`.
pub fn setRate(t: *Tide, clock: ClockId, rate: Rate) Error!void {
    try t.clockOk(clock);
    if (!rate.valid()) return error.BadRate;
    t.clocks[clock.raw()].meter.set(rate);
}

pub fn pause(t: *Tide, clock: ClockId, paused: bool) Error!void {
    try t.clockOk(clock);
    t.clocks[clock.raw()].meter.paused = paused;
}

// ---------------------------------------------------------------- scheduling

/// When `clock` reaches `tick`: due on the next advance if it already has.
pub fn at(t: *Tide, clock: ClockId, tick: u64, key: u64) Error!Token {
    try t.clockOk(clock);
    if (tick > max_tick) return error.ClockOverflow;
    return t.take(clock, key, .{ .instant = tick }, tick);
}

/// `ticks` from now on `clock`.
pub fn after(t: *Tide, clock: ClockId, ticks: u64, key: u64) Error!Token {
    try t.clockOk(clock);
    return t.at(clock, std.math.add(u64, t.now(clock), ticks) catch return error.ClockOverflow, key);
}

/// A recurrence on `clock`; one in a calendar's units must name a calendar of the same clock.
pub fn every(t: *Tide, clock: ClockId, r: Recurrence, key: u64) Error!Token {
    try t.clockOk(clock);
    const cal = try t.calendarOf(clock, r);
    if (!schedule.valid(r, cal) or r.first > max_tick) return error.BadRecurrence;
    const first = r.occurrence(0, cal) orelse return error.BadRecurrence;
    if (r.times != null and r.times.? == 0) return error.BadRecurrence;
    return t.take(clock, key, .{ .recurrence = .{ .r = r, .next = 0 } }, first);
}

fn calendarOf(t: *const Tide, clock: ClockId, r: Recurrence) Error!?*const Calendar {
    if (r.every != .units) return null;
    const id = r.every.units.calendar;
    if (id >= t.calendars.len or !t.calendars[id].clock.eql(clock)) return error.BadRecurrence;
    return &t.calendars[id].calendar;
}

/// Takes a free slot for a schedule due at `due`, in the order `next_order` gives.
pub fn take(t: *Tide, clock: ClockId, key: u64, what: @FieldType(Slot, "what"), due: u64) Error!Token {
    if (t.free_len == 0) return error.NoRoom;
    t.free_len -= 1;
    const slot = t.free[t.free_len];
    const s = &t.slots[slot];
    s.* = .{ .live = true, .generation = s.generation +% 1, .key = key, .clock = clock, .order = t.next_order, .what = what };
    t.next_order += 1;
    t.clocks[clock.raw()].queue.push(t.places, .{ .at = due, .order = s.order, .slot = slot });
    return .{ .slot = slot, .generation = s.generation };
}

/// Cancels a schedule; false when it already came due for the last time or was cancelled.
pub fn cancel(t: *Tide, token: Token) bool {
    if (token.slot >= t.slots.len) return false;
    const s = &t.slots[token.slot];
    if (!s.live or s.generation != token.generation) return false;
    _ = t.clocks[s.clock.raw()].queue.remove(t.places, t.places[token.slot]);
    t.release(token.slot);
    return true;
}

/// Cancels every schedule the host gave `key`; how many.
pub fn cancelKey(t: *Tide, key: u64) u32 {
    var n: u32 = 0;
    for (t.slots, 0..) |s, i| if (s.live and s.key == key) {
        n += @intFromBool(t.cancel(.{ .slot = @intCast(i), .generation = s.generation })); // safe: room is at most max_room
    };
    return n;
}

fn release(t: *Tide, slot: u32) void {
    t.slots[slot].live = false;
    t.free[t.free_len] = slot;
    t.free_len += 1;
}

// ---------------------------------------------------------------- moving time

/// Moves `clock` on by `ticks`, returning what came due on the way in time order. If `out` fills, the clock
/// stops where it is and `left` says how far it still has to go.
pub fn advance(t: *Tide, clock: ClockId, ticks: u64, out: []Due) Error!Advanced {
    try t.clockOk(clock);
    const c = &t.clocks[clock.raw()];
    const target = std.math.add(u64, c.now, ticks) catch return error.ClockOverflow;
    if (target > max_tick) return error.ClockOverflow;
    var n: usize = 0;
    while (c.queue.peek()) |e| {
        if (e.at > target) break;
        if (n == out.len) {
            c.now = @max(c.now, e.at);
            try t.write(clock, false);
            return .{ .due = out[0..n], .left = target - c.now };
        }
        c.now = @max(c.now, e.at);
        out[n] = t.pop(clock, target);
        n += 1;
    }
    c.now = target;
    try t.write(clock, false);
    return .{ .due = out[0..n], .left = 0 };
}

/// Moves `clock` on by the host's elapsed time, at its rate.
pub fn elapse(t: *Tide, clock: ClockId, elapsed: u64, out: []Due) Error!Advanced {
    try t.clockOk(clock);
    return t.advance(clock, t.clocks[clock.raw()].meter.convert(elapsed), out);
}

// Takes the first entry off the clock's queue as what came due, and queues a recurrence's next occurrence.
fn pop(t: *Tide, clock: ClockId, target: u64) Due {
    const q = &t.clocks[clock.raw()].queue;
    const e = q.remove(t.places, 0);
    const s = &t.slots[e.slot];
    const due: Due = .{ .key = s.key, .token = .{ .slot = e.slot, .generation = s.generation }, .clock = clock, .at = e.at, .count = 1 };
    switch (s.what) {
        .instant => {
            t.release(e.slot);
            return due;
        },
        .recurrence => |*rec| {
            // glint-ignore: Z026 -- a recurrence's calendar was checked when it was scheduled
            const cal = t.calendarOf(clock, rec.r) catch unreachable;
            const count = if (rec.r.policy == .once) @max(1, rec.r.upTo(rec.next, target, cal)) else 1;
            rec.next += count;
            const done = if (rec.r.times) |n| rec.next >= n else false;
            const following = if (done) null else rec.r.occurrence(rec.next, cal);
            if (following) |f| q.push(t.places, .{ .at = f, .order = e.order, .slot = e.slot }) else t.release(e.slot);
            var d = due;
            d.count = count;
            return d;
        },
    }
}

// ---------------------------------------------------------------- facts

/// Writes every fact tide keeps, whether it changed or not: after the host loads, or makes a new store.
pub fn sync(t: *Tide) Error!void {
    for (t.clocks, 0..) |_, i| try t.write(.fromRaw(@intCast(i)), true); // safe: max_clocks
}

// The facts that read `clock`: the clock's own, its calendars', and the derived facts over it.
fn write(t: *Tide, clock: ClockId, force: bool) Error!void {
    const store = t.store orelse return;
    const c = &t.clocks[clock.raw()];
    if (c.fact) |f| if (force or c.written != c.now) {
        try store.set(f, .{ .int = @intCast(c.now) }); // safe: below max_tick
        c.written = c.now;
    };
    for (t.calendars) |*b| if (b.clock.eql(clock)) try writeCalendar(store, b, c.now, force);
    for (t.derived, t.derived_last) |d, *last| {
        if (!reads(d, clock)) continue;
        const v = t.derive(d);
        if (!force and last.* != null and last.*.? == v) continue;
        try store.set(d.fact, .{ .int = v });
        last.* = v;
    }
}

fn writeCalendar(store: facts.Store, b: *Bound, tick: u64, force: bool) Error!void {
    const m = b.calendar.moment(tick);
    const old = b.last;
    const decl = b.calendar.decl;
    for (b.binding.counts, 0..) |f, i| if (f) |id| {
        if (force or old == null or old.?.counts[i] != m.counts[i]) try store.set(id, .{ .int = @intCast(@min(m.counts[i], max_tick)) }); // safe: clamped
    };
    for (b.binding.places, 0..) |f, i| if (f) |id| {
        if (force or old == null or old.?.places[i] != m.places[i]) try store.set(id, place(decl.units[i].names.len, m.places[i]));
    };
    for (b.binding.cycles, 0..) |f, j| if (f) |id| {
        if (force or old == null or old.?.cycles[j] != m.cycles[j]) try store.set(id, place(decl.cycles[j].names.len, m.cycles[j]));
    };
    b.last = m;
}

// A place: a `one of` where it has names, a number where it has none.
fn place(names: usize, v: u64) facts.Value {
    if (names > 0) return .{ .one_of = @intCast(v) }; // safe: below names, at most max_names
    return .{ .int = @intCast(@min(v, max_tick)) }; // safe: clamped
}

fn reads(d: Derived, clock: ClockId) bool {
    return switch (d.what) {
        .until, .since => |w| w.clock.eql(clock),
        .drift => |w| w.a.eql(clock) or w.b.eql(clock),
    };
}

/// A derived fact's value now.
pub fn derive(t: *const Tide, d: Derived) i64 {
    return switch (d.what) {
        .until => |w| t.between(w.per, t.now(w.clock), w.at),
        .since => |w| t.between(w.per, w.at, t.now(w.clock)),
        .drift => |w| blk: {
            const a: i128 = t.now(w.a);
            const b: i128 = t.now(w.b);
            break :blk @intCast(@divFloor(a - b, w.per)); // safe: both below max_tick
        },
    };
}

// How many `per`s from `from` to `to`, zero when `to` is earlier: whole ticks counted, or units begun.
fn between(t: *const Tide, per: Per, from: u64, to: u64) i64 {
    if (to <= from) return 0;
    const n = switch (per) {
        .ticks => |p| (to - from) / p,
        .unit => |u| blk: {
            const cal = t.calendar(u.calendar);
            break :blk cal.moment(to).counts[u.unit] - cal.moment(from).counts[u.unit];
        },
    };
    return @intCast(@min(n, max_tick)); // safe: clamped
}

test {
    _ = @import("tide_test.zig");
}
